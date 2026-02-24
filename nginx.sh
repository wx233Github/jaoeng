#!/usr/bin/env bash
# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.31.2 - UI对齐与功能精简)
# =============================================================
# 作者：Shell 脚本专家
# 描述：自动化管理 Nginx 反代配置与 SSL 证书，支持 TCP 负载均衡、TLS卸载与泛域名智能复用

set -euo pipefail

# --- 全局变量 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m'; PURPLE='\033[0;35m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
TCP_PROJECTS_METADATA_FILE="/etc/nginx/tcp_projects.json"
JSON_BACKUP_DIR="/etc/nginx/projects_backups"
BACKUP_DIR="/root/nginx_ssl_backups"
TG_CONF_FILE="/etc/nginx/tg_notifier.conf"

RENEW_THRESHOLD_DAYS=30
DEPS_MARK_FILE="$HOME/.nginx_ssl_manager_deps_v2"

NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_STREAM_AVAILABLE_DIR="/etc/nginx/stream-available"
NGINX_STREAM_ENABLED_DIR="/etc/nginx/stream-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
SSL_CERTS_BASE_DIR="/etc/ssl"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
NGINX_ERROR_LOG="/var/log/nginx/error.log"

IS_INTERACTIVE_MODE="true"
for arg in "$@"; do
    if [[ "$arg" == "--cron" || "$arg" == "--non-interactive" ]]; then
        IS_INTERACTIVE_MODE="false"; break
    fi
done
VPS_IP=""; VPS_IPV6=""; ACME_BIN=""
SCRIPT_PATH=$(realpath "$0")

# ==============================================================================
# SECTION: 核心工具函数与信号捕获
# ==============================================================================

_cleanup() {
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
    rm -f /tmp/tg_payload_*.json 2>/dev/null || true
}

_on_int() {
    echo -e "\n${RED}检测到中断信号，已安全取消操作并清理残留文件。${NC}"
    _cleanup; exit 130
}

trap '_cleanup' EXIT
trap '_on_int' INT TERM

_log_prefix() { if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then echo -n "$(date '+%Y-%m-%d %H:%M:%S') "; fi; }

log_message() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        INFO)    echo -e "$(_log_prefix)${CYAN}[INFO]${NC} ${message}";;
        SUCCESS) echo -e "$(_log_prefix)${GREEN}[OK]${NC}   ${message}";;
        WARN)    echo -e "$(_log_prefix)${YELLOW}[WARN]${NC} ${message}" >&2;;
        ERROR)   echo -e "$(_log_prefix)${RED}[ERR]${NC}  ${message}" >&2;;
    esac
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level^^}] ${message}" >> "$LOG_FILE"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty || true; }

_prompt_for_menu_choice_local() {
    local range="${1:-}"; local allow_empty="${2:-false}"; local prompt_text="${ORANGE}选项 [${range}]${NC} (Enter 返回): "
    local choice
    while true; do
        read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty || return 1
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then echo ""; return 0; fi
            echo -e "${YELLOW}请选择一个选项。${NC}" >&2; continue
        fi
        if [[ "$choice" =~ ^[0-9A-Za-z]+$ ]]; then echo "$choice"; return 0; fi
    done
}

_prompt_user_input_with_validation() {
    local prompt="${1:-}" default="${2:-}" regex="${3:-}" error_msg="${4:-}" allow_empty="${5:-false}" visual_default="${6:-}"
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local disp=""
            if [ -n "$visual_default" ]; then
                disp=" [默认: ${visual_default}]"
            elif [ -n "$default" ]; then
                disp=" [默认: ${default}]"
            fi
            echo -ne "${YELLOW}${prompt}${NC}${disp}: " >&2
            read -r val < /dev/tty || return 1
            val=${val:-$default}
        else
            val="$default"
            if [[ -z "$val" && "$allow_empty" = "false" ]]; then log_message ERROR "非交互缺失: $prompt"; return 1; fi
        fi
        if [[ -z "$val" && "$allow_empty" = "true" ]]; then echo ""; return 0; fi
        if [[ -z "$val" ]]; then log_message ERROR "输入不能为空"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        if [[ -n "$regex" && ! "$val" =~ $regex ]]; then log_message ERROR "${error_msg:-格式错误}"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        echo "$val"; return 0
    done
}

_prompt_secret() {
    local prompt="${1:-}" val=""
    echo -ne "${YELLOW}${prompt} (无屏幕回显): ${NC}" >&2
    read -rs val < /dev/tty || return 1
    echo "" >&2; echo "$val"
}

_mask_string() {
    local str="${1:-}"; local len=${#str}
    if [ "$len" -le 6 ]; then echo "***"; else echo "${str:0:2}***${str: -3}"; fi
}

_mask_ip() {
    local ip="${1:-}"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip" | awk -F. '{print $1"."$2".*.*"}'
    elif [[ "$ip" =~ .*:.* ]]; then
        echo "$ip" | awk -F: '{print $1":"$2"::***"}'
    else
        echo "***"
    fi
}

_confirm_action_or_exit_non_interactive() {
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local c; read -r -p "$(echo -e "${YELLOW}${1} ([y]/n): ${NC}")" c < /dev/tty || return 1
        case "$c" in n|N) return 1;; *) return 0;; esac
    fi
    log_message ERROR "非交互需确认: '$1'，已取消。"; return 1
}

_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    local svc; for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then echo "$svc"; return; fi
    done
}

# ==============================================================================
# SECTION: UI 渲染函数 (兼容中文宽度)
# ==============================================================================

generate_line() {
    local len=${1:-40}; local char=${2:-"─"}
    if [ "$len" -le 0 ]; then echo ""; return; fi
    printf "%${len}s" "" | sed "s/ /$char/g"
}

_get_visual_width() {
    local text="$1"; local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    if [ -z "$plain_text" ]; then echo 0; return; fi
    if command -v python3 &>/dev/null; then
        python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<< "$plain_text" 2>/dev/null || echo "${#plain_text}"
    elif command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
        echo -n "$plain_text" | wc -m
    else
        echo "${#plain_text}"
    fi
}

_render_menu() {
    local title="$1"; shift; local -a lines=("$@")
    local max_content_width=0
    local title_width=$(_get_visual_width "$title")
    max_content_width=$title_width
    for line in "${lines[@]}"; do
        local current_line_visual_width=$(_get_visual_width "$line")
        if [ "$current_line_visual_width" -gt "$max_content_width" ]; then
            max_content_width="$current_line_visual_width"
        fi
    done
    local box_inner_width=$max_content_width
    if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi
    echo ""
    echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    if [ -n "$title" ]; then
        local padding_total=$((box_inner_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        echo -e "${GREEN}│${NC}$(printf '%*s' "$padding_left")${BOLD}${title}${NC}$(printf '%*s' "$padding_right")${GREEN}│${NC}"
    fi
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
    for line in "${lines[@]}"; do
        echo -e "${line}"
    done
    local box_total_physical_width=$(( box_inner_width + 2 ))
    echo -e "${GREEN}$(generate_line "$box_total_physical_width" "─")${NC}"
}

_draw_dashboard() {
    local nginx_v=$(nginx -v 2>&1 | awk -F/ '{print $2}' | cut -d' ' -f1)
    local uptime_raw=$(uptime -p | sed 's/up //')
    local count=$(jq '. | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    local tcp_count=$(jq '. | length' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    local warn_count=0
    if [ -f "$PROJECTS_METADATA_FILE" ]; then
        warn_count=$(jq '[.[] | select(.cert_file) | select(.cert_file | test(".cer$"))] | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    fi
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs | cut -d, -f1-3 2>/dev/null || echo "unknown")
    
    local title="Nginx 管理面板 v4.31.2"
    local line1="Nginx: ${nginx_v} | 运行: ${uptime_raw} | 负载: ${load}"
    local line2="HTTP : ${count} 个 | TCP : ${tcp_count} 个 | 告警 : ${warn_count}"
    
    local max_width=$(_get_visual_width "$title")
    local w1=$(_get_visual_width "$line1")
    local w2=$(_get_visual_width "$line2")
    [ "$w1" -gt "$max_width" ] && max_width=$w1
    [ "$w2" -gt "$max_width" ] && max_width=$w2
    [ "$max_width" -lt 50 ] && max_width=50
    
    local inner_width=$max_width
    
    echo ""
    echo -e "${GREEN}╭$(generate_line "$inner_width" "─")╮${NC}"
    
    local title_vis_width=$(_get_visual_width "$title")
    local title_pad_total=$((inner_width - title_vis_width))
    local title_pad_left=$((title_pad_total / 2))
    local title_pad_right=$((title_pad_total - title_pad_left))
    echo -e "${GREEN}│${NC}$(printf '%*s' "$title_pad_left")${BOLD}${title}${NC}$(printf '%*s' "$title_pad_right")${GREEN}│${NC}"
    
    echo -e "${GREEN}╰$(generate_line "$inner_width" "─")╯${NC}"
    
    local pad1=$((inner_width - w1))
    local pad2=$((inner_width - w2))
    echo -e " ${line1}$(printf '%*s' "$pad1")"
    echo -e " ${line2}$(printf '%*s' "$pad2")"
    
    echo -e "${GREEN}$(generate_line $((inner_width + 2)) "─")${NC}"
}

# ==============================================================================
# SECTION: DNS 预检模块
# ==============================================================================

_check_dns_resolution() {
    local domain="${1:-}"
    log_message INFO "正在预检域名解析: $domain ..."
    get_vps_ip

    local resolved_ips=""
    if command -v dig >/dev/null 2>&1; then
        resolved_ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | xargs)
    elif command -v host >/dev/null 2>&1; then
        resolved_ips=$(host -t A "$domain" 2>/dev/null | grep "has address" | awk '{print $NF}' | xargs)
    else
        log_message WARN "未安装 dig/host 工具，跳过 DNS 预检。"
        return 0
    fi

    if [ -z "$resolved_ips" ]; then
        log_message ERROR "❌ DNS 解析失败: 域名 $domain 当前未解析到任何 IP 地址。"
        echo -e "${RED}请先前往您的 DNS 服务商添加一条 A 记录，指向本机 IP: ${VPS_IP}${NC}"
        if ! _confirm_action_or_exit_non_interactive "DNS 未生效，是否强制继续申请？"; then return 1; fi
        return 0
    fi

    if [[ " $resolved_ips " == *" $VPS_IP "* ]]; then
        log_message SUCCESS "✅ DNS 校验通过: $domain --> $VPS_IP"
    else
        log_message WARN "⚠️  DNS 解析异常!"
        echo -e "${YELLOW}本机 IP : ${VPS_IP}${NC}"
        echo -e "${YELLOW}解析 IP : ${resolved_ips}${NC}"
        echo -e "${RED}解析结果不包含本机 IP。如果您开启了 Cloudflare CDN (橙色云)，这是正常的，请选择 'y' 继续。${NC}"
        if ! _confirm_action_or_exit_non_interactive "解析结果不匹配，是否强制继续？"; then return 1; fi
    fi
    return 0
}

# ==============================================================================
# SECTION: TG 机器人通知模块
# ==============================================================================

setup_tg_notifier() {
    echo -e "\n${CYAN}--- Telegram 机器人通知设置 ---${NC}"
    local curr_token="" curr_chat="" curr_name=""
    if [ -f "$TG_CONF_FILE" ]; then
        source "$TG_CONF_FILE"
        curr_token="${TG_BOT_TOKEN:-}"
        curr_chat="${TG_CHAT_ID:-}"
        curr_name="${SERVER_NAME:-}"
        echo -e "\n${GREEN}当前已配置:${NC}"
        echo -e " 机器人 Token : $(_mask_string "$curr_token")"
        echo -e " 会话 ID      : $(_mask_string "$curr_chat")"
        echo -e " 服务器备注   : $curr_name"
        if ! _confirm_action_or_exit_non_interactive "是否要重新配置或关闭通知？"; then return; fi
    fi

    local action
    _render_menu "配置操作" "1. 开启/修改通知配置" "2. 清除配置 (关闭通知)"
    if ! action=$(_prompt_for_menu_choice_local "1-2" "true"); then return; fi
    
    if [ "$action" = "2" ]; then
        rm -f "$TG_CONF_FILE"
        log_message SUCCESS "Telegram 通知已关闭。"
        return
    fi

    local real_tk_default="${curr_token:-}"
    local vis_tk_default=""
    if [ -n "$curr_token" ]; then 
        vis_tk_default="$(_mask_string "$curr_token")"
    else 
        vis_tk_default="86888"
    fi
    
    local tk
    if ! tk=$(_prompt_user_input_with_validation "请输入 Bot Token (如 1234:ABC...)" "$real_tk_default" "" "" "false" "$vis_tk_default"); then return; fi
    
    local real_cid_default="${curr_chat:-}"
    local vis_cid_default=""
    if [ -n "$curr_chat" ]; then 
        vis_cid_default="$(_mask_string "$curr_chat")"
    else 
        vis_cid_default="无"
    fi
    
    local cid
    if ! cid=$(_prompt_user_input_with_validation "请输入 Chat ID (如 123456789 或 -100123...)" "$real_cid_default" "^-?[0-9]+$" "格式错误，只能包含数字或负号" "false" "$vis_cid_default"); then return; fi
    
    local sname
    if ! sname=$(_prompt_user_input_with_validation "请输入这台服务器的备注 (如 日本主机)" "$curr_name" "" "" "false"); then return; fi

    cat > "$TG_CONF_FILE" << EOF
TG_BOT_TOKEN="${tk}"
TG_CHAT_ID="${cid}"
SERVER_NAME="${sname}"
EOF
    chmod 600 "$TG_CONF_FILE"
    
    log_message INFO "正在发送测试消息 (同步模式)..."
    if _send_tg_notify "success" "测试域名" "恭喜！您的 Telegram 通知系统已成功挂载。" "$sname" "true"; then
        log_message SUCCESS "测试消息发送成功！请检查 Telegram 客户端。"
    else
        log_message ERROR "测试消息发送失败！请检查上方的错误提示。"
        if ! _confirm_action_or_exit_non_interactive "是否保留此配置？"; then rm -f "$TG_CONF_FILE"; fi
    fi
}

_send_tg_notify() {
    local status_type="${1:-}"
    local domain="${2:-}"
    local detail_msg="${3:-}"
    local sname="${4:-}"
    local debug="${5:-false}"
    
    if [ ! -f "$TG_CONF_FILE" ]; then return 0; fi
    source "$TG_CONF_FILE"
    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then return 0; fi

    get_vps_ip

    local display_ip=$(_mask_ip "$VPS_IP")
    local display_ipv6=$(_mask_ip "$VPS_IPV6")

    local title="" status_text="" emoji=""
    if [ "$status_type" == "success" ]; then
        title="证书续期成功"; status_text="✅ 续订完成"; emoji="✅"
    else
        title="异常警报"; status_text="⚠️ 续订失败"; emoji="⚠️"
    fi

    local ipv6_line=""
    if [ -n "$VPS_IPV6" ]; then ipv6_line="
🌐<b>IPv6:</b> <code>${display_ipv6}</code>"; fi

    local current_time=$(date "+%Y-%m-%d %H:%M:%S (%Z)")
    
    local text_body="<b>${emoji} ${title}</b>

🖥<b>服务器:</b> ${sname:-未知主机}
🌐<b>IPv4:</b> <code>${display_ip:-未知}</code>${ipv6_line}

📄<b>状态:</b> ${status_text}
🎯<b>域名:</b> <code>${domain}</code>
⌚<b>时间:</b> ${current_time}

📃<b>详细描述:</b>
<i>${detail_msg}</i>"

    local button_url="http://${domain}/"
    if [ "$debug" == "true" ]; then button_url="https://core.telegram.org/bots/api"; fi

    local kb_json='{"inline_keyboard":[[{"text":"📊 访问实例","url":"'"$button_url"'"}]]}'
    local payload_file=$(mktemp /tmp/tg_payload_XXXXXX.json)
    
    if ! jq -n --arg cid "$TG_CHAT_ID" --arg txt "$text_body" --argjson kb "$kb_json" \
        '{chat_id: $cid, text: $txt, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: $kb}' > "$payload_file"; then
        log_message ERROR "构造 TG JSON 失败。"
        rm -f "$payload_file"; return 1
    fi

    local curl_cmd=(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d @"$payload_file" \
        --connect-timeout 10 --max-time 15)

    local ret_code=0
    if [ "$debug" == "true" ]; then
        echo -e "${CYAN}>>> 发送请求到 Telegram API...${NC}"
        local resp
        resp=$("${curl_cmd[@]}" 2>&1) || ret_code=$?
        echo -e "${CYAN}<<< Telegram 响应:${NC}\n$resp"
        if [ $ret_code -ne 0 ] || ! echo "$resp" | jq -e '.ok' >/dev/null 2>&1; then ret_code=1; fi
    else
        "${curl_cmd[@]}" >/dev/null 2>&1 &
        ret_code=$?
    fi

    rm -f "$payload_file"
    return $ret_code
}

# ==============================================================================
# SECTION: 环境初始化与依赖
# ==============================================================================

install_dependencies() {
    if [ -f "$DEPS_MARK_FILE" ]; then return 0; fi
    local deps="nginx curl socat openssl jq idn dnsutils nano wc dnsutils"
    local missing=0
    for pkg in $deps; do
        if ! command -v "$pkg" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null; then
            log_message WARN "缺失: $pkg，安装中..."
            if [ "$missing" -eq 0 ]; then apt update -y >/dev/null 2>&1 || true; fi
            apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "安装 $pkg 失败"; return 1; }
            missing=1
        fi
    done
    touch "$DEPS_MARK_FILE"
    [ "$missing" -eq 1 ] && log_message SUCCESS "依赖就绪。"
    return 0
}

_setup_logrotate() {
    if [ ! -d /etc/logrotate.d ]; then return 0; fi
    if [ ! -f /etc/logrotate.d/nginx ]; then
        log_message INFO "自动补全 Nginx 缺失的日志切割配置..."
        cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then kill -USR1 `cat /var/run/nginx.pid`; fi
    endscript
}
EOF
    fi
    if [ ! -f /etc/logrotate.d/nginx_ssl_manager ]; then
        log_message INFO "注入本面板运行日志 切割规则..."
        cat > /etc/logrotate.d/nginx_ssl_manager << EOF
${LOG_FILE} {
    weekly
    missingok
    rotate 12
    compress
    delaycompress
    notifempty
    create 0644 root root
}
EOF
    fi
}

initialize_environment() {
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
    if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
    export PATH="$(dirname "$ACME_BIN"):$PATH"
    
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR" "$BACKUP_DIR"
    mkdir -p "$JSON_BACKUP_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$NGINX_STREAM_ENABLED_DIR"
    
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then echo "[]" > "$PROJECTS_METADATA_FILE"; fi
    if [ ! -f "$TCP_PROJECTS_METADATA_FILE" ] || ! jq -e . "$TCP_PROJECTS_METADATA_FILE" > /dev/null 2>&1; then echo "[]" > "$TCP_PROJECTS_METADATA_FILE"; fi

    if [ -f "/etc/nginx/conf.d/gzip_optimize.conf" ]; then
        if ! nginx -t >/dev/null 2>&1; then
            if nginx -t 2>&1 | grep -q "gzip"; then
                rm -f "/etc/nginx/conf.d/gzip_optimize.conf"
                log_message WARN "清理与主配置冲突的 Gzip 文件。"
            fi
        fi
    fi

    if [ -f /etc/nginx/nginx.conf ] && ! grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
        cat >> /etc/nginx/nginx.conf << EOF

# TCP/UDP Stream Proxy Auto-injected
stream {
    include ${NGINX_STREAM_ENABLED_DIR}/*.conf;
}
EOF
        systemctl reload nginx || true
    fi

    _setup_logrotate
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then return 0; fi
    log_message WARN "acme.sh 未安装，开始安装..."
    local email; if ! email=$(_prompt_user_input_with_validation "注册邮箱" "" "" "" "true"); then return 1; fi
    local cmd="curl https://get.acme.sh | sh"
    [ -n "$email" ] && cmd+=" -s email=$email"
    if eval "$cmd"; then 
        ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
        if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
        "$ACME_BIN" --upgrade --auto-upgrade >/dev/null 2>&1 || true
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > /tmp/cron.bak || true
        echo "0 3 * * * $SCRIPT_PATH --cron >> $LOG_FILE 2>&1" >> /tmp/cron.bak
        crontab /tmp/cron.bak; rm -f /tmp/cron.bak
        log_message SUCCESS "acme.sh 安装成功。"
        return 0
    fi
    log_message ERROR "acme.sh 安装失败"; return 1
}

control_nginx() {
    local action="${1:-reload}"
    if ! nginx -t >/dev/null 2>&1; then log_message ERROR "Nginx 配置错误"; nginx -t; return 1; fi
    systemctl "$action" nginx || { log_message ERROR "Nginx $action 失败"; return 1; }
    return 0
}

# ==============================================================================
# SECTION: 安全与高级特性 (CF 防御, 备份机制)
# ==============================================================================

_update_cloudflare_ips() {
    log_message INFO "正在拉取最新的 Cloudflare IP 列表..."
    local temp_allow=$(mktemp)
    
    if curl -sS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 > "$temp_allow" && \
       echo "" >> "$temp_allow" && \
       curl -sS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 >> "$temp_allow"; then
        mkdir -p /etc/nginx/snippets /etc/nginx/conf.d
        local temp_cf_allow=$(mktemp); local temp_cf_real=$(mktemp)
        echo "# Cloudflare Allow List" > "$temp_cf_allow"; echo "# Cloudflare Real IP" > "$temp_cf_real"
        
        while read -r ip; do
            [ -z "$ip" ] && continue
            echo "allow $ip;" >> "$temp_cf_allow"; echo "set_real_ip_from $ip;" >> "$temp_cf_real"
        done < <(grep -E '^[0-9a-fA-F.:]+(/[0-9]+)?$' "$temp_allow")
        
        echo "deny all;" >> "$temp_cf_allow"; echo "real_ip_header CF-Connecting-IP;" >> "$temp_cf_real"
        mv "$temp_cf_allow" /etc/nginx/snippets/cf_allow.conf; mv "$temp_cf_real" /etc/nginx/conf.d/cf_real_ip.conf
        log_message SUCCESS "Cloudflare IP 列表更新完成。底层文件已准备就绪。"
        
        echo -e "\n${ORANGE}${BOLD}📢 [安全提示] 核心库已下载完毕！但防御规则尚未生效至各个网站。${NC}"
        echo -e "${YELLOW}只有在现有 Nginx 项目中显式开启了 CF 严格模式，您的源站 IP 才会被真正隐藏保护。${NC}"
        
        if _confirm_action_or_exit_non_interactive "是否立刻启动【安全巡检】，为您排查并开启尚未防御的网站？"; then
            local all_projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
            if [ -n "$all_projects" ]; then
                local modified=0
                while read -r p; do
                    [ -z "$p" ] && continue
                    local d=$(echo "$p" | jq -r .domain); local cs=$(echo "$p" | jq -r '.cf_strict_mode // "n"')
                    local port=$(echo "$p" | jq -r .resolved_port)
                    if [ "$port" != "cert_only" ] && [ "$cs" != "y" ]; then
                        echo -e "\n👉 发现暴露项目: ${CYAN}$d${NC}"
                        if _confirm_action_or_exit_non_interactive "是否为 $d 开启防御 (仅允许通过 CF CDN 访问，拉黑直接访问源站的扫描器)?"; then
                            local new_p=$(echo "$p" | jq '.cf_strict_mode = "y"')
                            if _save_project_json "$new_p"; then _write_and_enable_nginx_config "$d" "$new_p"; modified=1; log_message SUCCESS "已为 $d 注入防火墙规则。"; fi
                        fi
                    fi
                done <<< "$all_projects"
                if [ "$modified" -eq 1 ]; then 
                    control_nginx reload
                    log_message SUCCESS "所有变更已生效，恭喜！您被选中的网站现已进入隐身状态。"
                else echo -e "${GREEN}无需修改，目前所有适用网站均已配置完毕。${NC}"; fi
            else echo -e "${YELLOW}未发现可以配置的 HTTP 项目。${NC}"; fi
        fi
    else log_message ERROR "获取 Cloudflare IP 列表失败，请检查 VPS 的国际网络连通性。"; fi
    rm -f "$temp_allow" "$temp_cf_allow" "$temp_cf_real" 2>/dev/null || true
}

_snapshot_projects_json() {
    local target_file="${1:-$PROJECTS_METADATA_FILE}"
    if [ -f "$target_file" ]; then
        local base_name=$(basename "$target_file" .json)
        local snap_name="${JSON_BACKUP_DIR}/${base_name}_$(date +%Y%m%d_%H%M%S).json.bak"
        cp "$target_file" "$snap_name"
        ls -tp "${JSON_BACKUP_DIR}/${base_name}_*.bak" 2>/dev/null | grep -v '/$' | tail -n +11 | xargs -I {} rm -- "{}" 2>/dev/null || true
    fi
}

_handle_backup_restore() {
    _render_menu "维护选项与灾备工具" "1. 备份与恢复面板 (数据层)" "2. 重建所有 HTTP 配置 (应用层)" "3. 修复定时任务 (系统层)"
    local c; if ! c=$(_prompt_for_menu_choice_local "1-3" "true"); then return; fi
    case "$c" in
        1)
            _render_menu "备份与恢复系统" "1. 创建新备份 (打包所有配置与证书)" "2. 从完整备份包还原" "3. 从 本地快照 回滚元数据"
            local bc; if ! bc=$(_prompt_for_menu_choice_local "1-3" "true"); then return; fi
            case "$bc" in
                1)
                    local ts=$(date +%Y%m%d_%H%M%S); local backup_file="$BACKUP_DIR/nginx_manager_backup_$ts.tar.gz"
                    log_message INFO "正在打包备份..."
                    if tar -czf "$backup_file" -C / "$PROJECTS_METADATA_FILE" "$TCP_PROJECTS_METADATA_FILE" "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$SSL_CERTS_BASE_DIR" 2>/dev/null; then log_message SUCCESS "备份成功: $backup_file"; else log_message ERROR "备份失败。"; fi ;;
                2)
                    echo -e "\n${CYAN}可用备份列表:${NC}"; ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || { log_message WARN "无可用备份。"; return; }
                    local file_path; if ! file_path=$(_prompt_user_input_with_validation "请输入完整备份文件路径" "" "" "" "true"); then return; fi
                    if [ -z "$file_path" ]; then return; fi; if [ ! -f "$file_path" ]; then log_message ERROR "文件不存在"; return; fi
                    if _confirm_action_or_exit_non_interactive "警告：还原将覆盖当前配置，是否继续？"; then
                        systemctl stop nginx || true; log_message INFO "正在解压还原..."
                        if tar -xzf "$file_path" -C /; then log_message SUCCESS "还原完成。"; control_nginx restart; else log_message ERROR "解压失败。"; fi
                    fi ;;
                3)
                    _render_menu "选择要回滚的数据类型" "1. 恢复 HTTP 项目" "2. 恢复 TCP 项目"
                    local snap_type; if ! snap_type=$(_prompt_for_menu_choice_local "1-2" "true"); then return; fi
                    local target_file=""; local filter_str=""
                    if [ "$snap_type" = "1" ]; then target_file="$PROJECTS_METADATA_FILE"; filter_str="projects_"; fi
                    if [ "$snap_type" = "2" ]; then target_file="$TCP_PROJECTS_METADATA_FILE"; filter_str="tcp_projects_"; fi
                    [ -z "$target_file" ] && return
                    
                    echo -e "\n${CYAN}可用快照 (${filter_str}):${NC}"; ls -lh "$JSON_BACKUP_DIR"/${filter_str}*.bak 2>/dev/null || { log_message WARN "无快照。"; return; }
                    local snap_path; if ! snap_path=$(_prompt_user_input_with_validation "请输入要恢复的快照路径" "" "" "" "true"); then return; fi
                    if [ -n "$snap_path" ] && [ -f "$snap_path" ]; then
                        if _confirm_action_or_exit_non_interactive "这将会回滚记录，确认执行？"; then
                            _snapshot_projects_json "$target_file"; cp "$snap_path" "$target_file"
                            log_message SUCCESS "数据回滚完毕！(建议返回上级菜单执行 '重建所有 HTTP 配置' 同步 Nginx)"
                        fi
                    fi ;;
            esac ;;
        2) _rebuild_all_nginx_configs ;;
        3) _manage_cron_jobs ;;
    esac
}

# ==============================================================================
# SECTION: 日志与运维
# ==============================================================================

_view_file_with_tail() {
    local file="${1:-}"; if [ ! -f "$file" ]; then log_message ERROR "文件不存在: $file"; return; fi
    echo -e "${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}"; tail -f -n 50 "$file" || true; echo -e "\n${CYAN}--- 日志查看结束 ---${NC}"
}
_view_acme_log() { local f="$HOME/.acme.sh/acme.sh.log"; [ ! -f "$f" ] && f="/root/.acme.sh/acme.sh.log"; _view_file_with_tail "$f"; }
_view_nginx_global_log() {
    _render_menu "Nginx 全局日志" "1. 访问日志" "2. 错误日志"
    local c; if ! c=$(_prompt_for_menu_choice_local "1-2" "true"); then return; fi
    case "$c" in 1) _view_file_with_tail "$NGINX_ACCESS_LOG" ;; 2) _view_file_with_tail "$NGINX_ERROR_LOG" ;; esac
}

_manage_cron_jobs() {
    echo -e "\n${CYAN}--- 系统定时任务 (Cron) 诊断与修复 ---${NC}"
    local has_acme=0 has_manager=0
    if crontab -l 2>/dev/null | grep -q "\.acme\.sh/acme\.sh"; then has_acme=1; fi
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --cron"; then has_manager=1; fi
    
    echo -e " 1. acme.sh 原生续期进程 : $( [ $has_acme -eq 1 ] && echo -e "${GREEN}正常运行${NC}" || echo -e "${RED}缺失${NC}" )"
    echo -e " 2. 本面板接管守护进程   : $( [ $has_manager -eq 1 ] && echo -e "${GREEN}正常运行${NC}" || echo -e "${RED}缺失${NC}" )"
    echo ""
    
    if [ $has_acme -eq 1 ] && [ $has_manager -eq 1 ]; then
        echo -e "${GREEN}系统定时任务状态完全健康，无需干预。${NC}"
    else
        echo -e "${YELLOW}检测到必需的定时任务不完整，正在自动执行修复...${NC}"
        "$ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > /tmp/cron.bak || true
        echo "0 3 * * * $SCRIPT_PATH --cron >> $LOG_FILE 2>&1" >> /tmp/cron.bak
        crontab /tmp/cron.bak; rm -f /tmp/cron.bak
        log_message SUCCESS "定时任务修复完毕，系统级容灾续期已挂载。"
    fi
    press_enter_to_continue
}

# ==============================================================================
# SECTION: 数据与 HTTP 代理配置
# ==============================================================================

_get_project_json() { jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""; }

_save_project_json() {
    local json="${1:-}"; if [ -z "$json" ]; then return 1; fi
    _snapshot_projects_json; local domain=$(echo "$json" | jq -r .domain); local temp=$(mktemp)
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq --argjson new_val "$json" --arg d "$domain" 'map(if .domain == $d then $new_val else . end)' "$PROJECTS_METADATA_FILE" > "$temp"
    else
        jq --argjson new_val "$json" '. + [$new_val]' "$PROJECTS_METADATA_FILE" > "$temp"
    fi
    if [ $? -eq 0 ]; then mv "$temp" "$PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}

_delete_project_json() {
    _snapshot_projects_json; local temp=$(mktemp)
    jq --arg d "${1:-}" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$PROJECTS_METADATA_FILE"
}

_write_and_enable_nginx_config() {
    local domain="${1:-}"; local json="${2:-}"; local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if [ -z "$json" ]; then log_message ERROR "配置生成失败: 传入 JSON 为空。"; return 1; fi

    local port=$(echo "$json" | jq -r .resolved_port)
    if [ "$port" == "cert_only" ]; then return 0; fi

    local cert=$(echo "$json" | jq -r .cert_file); local key=$(echo "$json" | jq -r .key_file)
    local max_body=$(echo "$json" | jq -r '.client_max_body_size // empty'); local custom_cfg=$(echo "$json" | jq -r '.custom_config // empty')
    local cf_strict=$(echo "$json" | jq -r '.cf_strict_mode // "n"')
    
    local body_cfg=""; [[ -n "$max_body" && "$max_body" != "null" ]] && body_cfg="client_max_body_size ${max_body};"
    local extra_cfg=""; [[ -n "$custom_cfg" && "$custom_cfg" != "null" ]] && extra_cfg="$custom_cfg"
    local cf_strict_cfg=""
    if [ "$cf_strict" == "y" ]; then
        [ ! -f "/etc/nginx/snippets/cf_allow.conf" ] && _update_cloudflare_ips
        cf_strict_cfg="include /etc/nginx/snippets/cf_allow.conf;"
    fi

    if [[ -z "$port" || "$port" == "null" ]]; then log_message ERROR "端口为空，请检查项目配置。"; return 1; fi
    get_vps_ip

    cat > "$conf" << EOF
server {
    listen 80;
    $( [[ -n "$VPS_IPV6" ]] && echo "listen [::]:80;" )
    server_name ${domain};
    
    location /.well-known/acme-challenge/ { root ${NGINX_WEBROOT_DIR}; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    $( [[ -n "$VPS_IPV6" ]] && echo "listen [::]:443 ssl http2;" )
    server_name ${domain};

    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    add_header Strict-Transport-Security "max-age=31536000;" always;

    ${body_cfg}
    ${cf_strict_cfg}
    ${extra_cfg}

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
    ln -sf "$conf" "$NGINX_SITES_ENABLED_DIR/"
}

_remove_and_disable_nginx_config() { rm -f "$NGINX_SITES_AVAILABLE_DIR/${1:-}.conf" "$NGINX_SITES_ENABLED_DIR/${1:-}.conf"; }
_view_nginx_config() {
    local domain="${1:-}"; local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if [ ! -f "$conf" ]; then log_message WARN "此项目未生成配置文件。"; return; fi
    echo -e "\n${GREEN}=== 配置文件: $domain ===${NC}\n$(cat "$conf")\n${GREEN}=======================${NC}"
}

_rebuild_all_nginx_configs() {
    log_message INFO "准备基于现有记录从零重建所有 Nginx HTTP 代理文件..."
    if ! _confirm_action_or_exit_non_interactive "这将会覆盖当前所有 Nginx HTTP 代理配置文件，是否继续？"; then return; fi
    local all_projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
    if [ -z "$all_projects" ]; then log_message WARN "没有任何项目记录可供重建。"; return; fi
    
    local success=0 fail=0
    while read -r p; do
        [ -z "$p" ] && continue
        local d=$(echo "$p" | jq -r .domain); local port=$(echo "$p" | jq -r .resolved_port)
        if [ "$port" == "cert_only" ]; then continue; fi
        log_message INFO "重建配置文件: $d ..."
        if _write_and_enable_nginx_config "$d" "$p"; then success=$((success+1)); else fail=$((fail+1)); log_message ERROR "重建失败: $d"; fi
    done <<< "$all_projects"
    log_message INFO "正在重载 Nginx..."
    if control_nginx reload; then log_message SUCCESS "重建完成。成功: $success, 失败: $fail"; else log_message ERROR "Nginx 重载失败！"; fi
}

# ==============================================================================
# SECTION: 数据与 TCP 代理配置 (Stream Proxy + 负载均衡 + TLS)
# ==============================================================================

_save_tcp_project_json() {
    local json="${1:-}"; if [ -z "$json" ]; then return 1; fi
    _snapshot_projects_json "$TCP_PROJECTS_METADATA_FILE"
    
    local port=$(echo "$json" | jq -r .listen_port); local temp=$(mktemp)
    local existing=$(jq -c --arg p "$port" '.[] | select(.listen_port == $p)' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        jq --argjson new_val "$json" --arg p "$port" 'map(if .listen_port == $p then $new_val else . end)' "$TCP_PROJECTS_METADATA_FILE" > "$temp"
    else
        jq --argjson new_val "$json" '. + [$new_val]' "$TCP_PROJECTS_METADATA_FILE" > "$temp"
    fi
    if [ $? -eq 0 ]; then mv "$temp" "$TCP_PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}

_write_and_enable_tcp_config() {
    local port="${1:-}"; local json="${2:-}"; local conf="$NGINX_STREAM_AVAILABLE_DIR/tcp_${port}.conf"
    local target=$(echo "$json" | jq -r .target); local tls_enabled=$(echo "$json" | jq -r '.tls_enabled // "n"' )
    local listen_flag=""; local ssl_block=""
    
    if [ "$tls_enabled" == "y" ]; then
        local ssl_cert=$(echo "$json" | jq -r .ssl_cert); local ssl_key=$(echo "$json" | jq -r .ssl_key)
        listen_flag="ssl"
        ssl_block="
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';"
    fi

    local upstream_block=""
    local proxy_pass_target="${target}"

    if [[ "$target" == *","* ]]; then
        proxy_pass_target="tcp_backend_${port}"
        upstream_block="upstream ${proxy_pass_target} {"
        IFS=',' read -ra ADDR <<< "$target"
        for i in "${ADDR[@]}"; do upstream_block+=$'\n    server '"${i};"; done
        upstream_block+=$'\n}\n'
    fi

    cat > "$conf" << EOF
${upstream_block}
server {
    listen ${port} ${listen_flag};
    proxy_pass ${proxy_pass_target};
${ssl_block}
}
EOF
    ln -sf "$conf" "$NGINX_STREAM_ENABLED_DIR/"
}

configure_tcp_proxy() {
    _render_menu "配置 TCP 代理与负载均衡"
    local name; if ! name=$(_prompt_user_input_with_validation "项目备注名称" "MyTCP" "" "" "false"); then return; fi
    local l_port; if ! l_port=$(_prompt_user_input_with_validation "本机监听端口" "" "^[0-9]+$" "无效端口" "false"); then return; fi
    local target; if ! target=$(_prompt_user_input_with_validation "目标地址 (单节点如 1.1.1.1:80，多节点负载用逗号分隔如 1.1:80,2.2:80)" "" "^[a-zA-Z0-9.-]+:[0-9]+(,[a-zA-Z0-9.-]+:[0-9]+)*$" "格式错误 (必须包含端口，多个用英文逗号)" "false"); then return; fi
    
    local tls_enabled="n"; local ssl_cert=""; local ssl_key=""
    if _confirm_action_or_exit_non_interactive "是否开启 TLS/SSL 加密卸载 (TCP over TLS)?"; then
        tls_enabled="y"
        local http_projects=$(jq -c '.[] | select(.cert_file != null and .cert_file != "")' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
        if [ -z "$http_projects" ]; then log_message ERROR "未发现可用证书。"; return 1; fi
        
        echo -e "\n${CYAN}请选择要用于加密流量的证书：${NC}"
        local idx=0; declare -a domain_list cert_list key_list
        while read -r p; do
            [ -z "$p" ] && continue; idx=$((idx+1))
            domain_list[$idx]=$(echo "$p" | jq -r .domain)
            cert_list[$idx]=$(echo "$p" | jq -r .cert_file)
            key_list[$idx]=$(echo "$p" | jq -r .key_file)
            echo -e " ${GREEN}${idx}.${NC} ${domain_list[$idx]}"
        done <<< "$http_projects"
        
        local c_idx
        while true; do
            if ! c_idx=$(_prompt_user_input_with_validation "请输入序号" "" "^[0-9]+$" "无效序号" "false"); then return; fi
            if [ "$c_idx" -ge 1 ] && [ "$c_idx" -le "$idx" ]; then ssl_cert="${cert_list[$c_idx]}"; ssl_key="${key_list[$c_idx]}"; break
            else log_message ERROR "序号越界"; fi
        done
    fi

    local json=$(jq -n --arg n "$name" --arg lp "$l_port" --arg t "$target" --arg te "$tls_enabled" --arg sc "$ssl_cert" --arg sk "$ssl_key" \
        '{name:$n, listen_port:$lp, target:$t, tls_enabled:$te, ssl_cert:$sc, ssl_key:$sk}')
    
    if _write_and_enable_tcp_config "$l_port" "$json"; then
        if control_nginx reload; then
            _save_tcp_project_json "$json"
            log_message SUCCESS "TCP 代理已成功配置 ($l_port) [TLS: $tls_enabled]。"
        else
            log_message ERROR "Nginx 重载失败，可能端口已被占用或配置语法有误。"
            rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${l_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${l_port}.conf"
            control_nginx reload || true
        fi
    fi
}

manage_tcp_configs() {
    while true; do
        local all=$(jq . "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo "[]"); local count=$(echo "$all" | jq 'length')
        if [ "$count" -eq 0 ]; then log_message WARN "暂无 TCP 项目。"; break; fi
        
        printf "${BOLD}%-4s %-10s %-5s %-12s %-22s${NC}\n" "ID" "端口" "TLS" "备注" "目标地址"; echo "──────────────────────────────────────────────────────────"
        local idx=0
        echo "$all" | jq -c '.[]' | while read -r p; do
            idx=$((idx + 1)); local port=$(echo "$p" | jq -r '.listen_port'); local name=$(echo "$p" | jq -r '.name // "-"')
            local target=$(echo "$p" | jq -r '.target'); local short_target="${target:0:22}"; [ ${#target} -gt 22 ] && short_target="${target:0:19}..."
            local tls=$(echo "$p" | jq -r '.tls_enabled // "n"'); local tls_str="${RED}否${NC}"; [ "$tls" == "y" ] && tls_str="${GREEN}是${NC}"
            printf "%-4d ${GREEN}%-10s${NC} %-14s %-12s %-22s\n" "$idx" "$port" "$tls_str" "${name:0:10}" "$short_target"
        done; echo ""
        
        local choice_idx; if ! choice_idx=$(_prompt_user_input_with_validation "请输入序号选择 TCP 项目 (回车返回)" "" "^[0-9]*$" "无效序号" "true"); then return; fi
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then break; fi
        if [ "$choice_idx" -gt "$count" ]; then log_message ERROR "序号越界"; continue; fi
        
        local selected_port=$(echo "$all" | jq -r ".[$((choice_idx-1))].listen_port")
        
        _render_menu "管理 TCP: 端口 $selected_port" "1. 删除项目" "2. 查看配置"
        local cc; if ! cc=$(_prompt_for_menu_choice_local "1-2" "true"); then continue; fi
        case "$cc" in
            1) 
                if _confirm_action_or_exit_non_interactive "确认删除 TCP 代理 $selected_port？"; then
                    rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${selected_port}.conf"
                    _snapshot_projects_json "$TCP_PROJECTS_METADATA_FILE"
                    local temp=$(mktemp)
                    jq --arg p "$selected_port" 'del(.[] | select(.listen_port == $p))' "$TCP_PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$TCP_PROJECTS_METADATA_FILE"
                    control_nginx reload; log_message SUCCESS "TCP 项目 $selected_port 删除成功。"
                fi ;;
            2) cat "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" 2>/dev/null || echo "配置文件不存在"; press_enter_to_continue ;;
        esac
    done
}

# ==============================================================================
# SECTION: 业务逻辑 (证书申请与主流程)
# ==============================================================================

_issue_and_install_certificate() {
    local json="${1:-}"
    local domain=$(echo "$json" | jq -r .domain)
    local method=$(echo "$json" | jq -r .acme_validation_method)
    
    if [ "$method" == "reuse" ]; then return 0; fi

    if [ "$method" == "http-01" ]; then
        if ! _check_dns_resolution "$domain"; then return 1; fi
    fi

    local provider=$(echo "$json" | jq -r .dns_api_provider); local wildcard=$(echo "$json" | jq -r .use_wildcard)
    local ca=$(echo "$json" | jq -r .ca_server_url)
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"; local key="$SSL_CERTS_BASE_DIR/$domain.key"
    
    log_message INFO "正在为 $domain 申请证书 ($method)..."
    
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca" --log)
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    local temp_conf_created="false"; local temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"
    local stopped_svc=""

    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                local saved_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local saved_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local use_saved="false"
                if [[ -n "$saved_t" && -n "$saved_a" ]]; then
                    if _confirm_action_or_exit_non_interactive "是否复用已保存的 Cloudflare 凭证？"; then use_saved="true"; fi
                fi
                if [ "$use_saved" = "false" ]; then
                    local t; if ! t=$(_prompt_secret "请输入新的 CF_Token"); then return 1; fi
                    local a; if ! a=$(_prompt_secret "请输入新的 Account_ID"); then return 1; fi
                    [ -n "$t" ] && export CF_Token="$t"; [ -n "$a" ] && export CF_Account_ID="$a"
                fi
            fi
        fi
        cmd+=("--dns" "$provider")
    elif [ "$method" = "http-01" ]; then
        if ss -tuln 2>/dev/null | grep -qE ':(80|443)\s'; then
            local temp_svc=$(_detect_web_service)
            if [ "$temp_svc" = "nginx" ]; then
                 if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
                    cat > "$temp_conf" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }
EOF
                    ln -sf "$temp_conf" "$NGINX_SITES_ENABLED_DIR/"; systemctl reload nginx || true; temp_conf_created="true"
                fi
                mkdir -p "$NGINX_WEBROOT_DIR"; cmd+=("--webroot" "$NGINX_WEBROOT_DIR")
            else
                 if _confirm_action_or_exit_non_interactive "是否临时停止 $temp_svc 以释放 80 端口?"; then
                    systemctl stop "$temp_svc"; stopped_svc="$temp_svc"; trap "systemctl start $stopped_svc; _cleanup; exit 130" INT TERM
                 fi
                 cmd+=("--standalone")
            fi
        else
            cmd+=("--standalone")
        fi
    fi

    local log_temp=$(mktemp /tmp/acme_cmd_log.XXXXXX)
    echo -ne "${YELLOW}正在通信 (约 30-60 秒，请勿中断)... ${NC}"
    "${cmd[@]}" > "$log_temp" 2>&1 &
    local pid=$!
    local spinstr='|/-\'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.2; printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"; wait $pid; local ret=$?

    if [ "$temp_conf_created" == "true" ]; then rm -f "$temp_conf" "$NGINX_SITES_ENABLED_DIR/temp_acme_${domain}.conf"; systemctl reload nginx || true; fi
    if [ -n "$stopped_svc" ]; then systemctl start "$stopped_svc"; trap '_on_int' INT TERM; fi

    if [ $ret -ne 0 ]; then
        echo -e "\n"; log_message ERROR "申请失败: $domain"; 
        cat "$log_temp"; rm -f "$log_temp"
        _send_tg_notify "fail" "$domain" "acme.sh 申请证书失败。" ""
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    rm -f "$log_temp"

    local rcmd=$(echo "$json" | jq -r '.reload_cmd // empty')
    local resolved_port=$(echo "$json" | jq -r '.resolved_port // empty')
    local install_reload_cmd=""
    
    if [ "$resolved_port" == "cert_only" ]; then
        install_reload_cmd="$rcmd"
    else
        install_reload_cmd="systemctl reload nginx"
    fi

    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
    [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    
    "${inst[@]}" >/dev/null 2>&1
    local acme_ret=$?

    if [ -f "$cert" ] && [ -f "$key" ]; then
        log_message SUCCESS "证书文件已成功生成于 /etc/ssl/ 目录。"
        if [ $acme_ret -ne 0 ]; then
            echo -e "\n${RED}⚠️  [警告] 自动重启命令执行失败: $install_reload_cmd${NC}"
            echo -e "${YELLOW}证书已安装，但服务未能自动加载新证书。请手动执行该命令。${NC}"
        fi
        _send_tg_notify "success" "$domain" "证书已成功安装。"
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 0
    else
        log_message ERROR "证书文件安装后丢失。"
        return 1
    fi
}

_gather_project_details() {
    exec 3>&1; exec 1>&2
    local cur="${1:-{\}}"; local skip_cert="${2:-false}"; local is_cert_only="false"
    if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local domain=$(echo "$cur" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        if ! domain=$(_prompt_user_input_with_validation "主域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式无效" "false"); then exec 1>&3; return 1; fi
    fi

    if [ "$skip_cert" == "false" ]; then
        if ! _check_dns_resolution "$domain"; then
            echo -e "${RED}域名配置已取消。${NC}"
            exec 1>&3; return 1
        fi
    fi

    local wc_match=""
    if [ "$skip_cert" == "false" ]; then
        local all_wcs=$(jq -c '.[] | select(.use_wildcard == "y" and .cert_file != null)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
        while read -r wp; do
            [ -z "$wp" ] && continue
            local wd=$(echo "$wp" | jq -r .domain)
            if [[ "$domain" == *".$wd" || "$domain" == "$wd" ]]; then wc_match="$wd"; break; fi
        done <<< "$all_wcs"
    fi

    local reuse_wc="false"; local wc_cert=""; local wc_key=""
    if [ -n "$wc_match" ]; then
        echo -e "\n${GREEN}🎯 智能提示: 检测到系统中已存在匹配的泛域名证书 (*.${wc_match})${NC}" >&2
        if _confirm_action_or_exit_non_interactive "是否直接绑定复用该证书，实现免验证零延迟上线？"; then
            reuse_wc="true"
            local wp=$(_get_project_json "$wc_match")
            wc_cert=$(echo "$wp" | jq -r .cert_file); wc_key=$(echo "$wp" | jq -r .key_file)
        fi
    fi

    local type="cert_only"; local name="证书"; local port="cert_only"
    local max_body=$(echo "$cur" | jq -r '.client_max_body_size // empty')
    local custom_cfg=$(echo "$cur" | jq -r '.custom_config // empty')
    local cf_strict=$(echo "$cur" | jq -r '.cf_strict_mode // "n"')
    local reload_cmd=$(echo "$cur" | jq -r '.reload_cmd // empty')

    if [ "$is_cert_only" == "false" ]; then
        name=$(echo "$cur" | jq -r '.name // ""'); [ "$name" == "证书" ] && name=""
        while true; do
            local target; if ! target=$(_prompt_user_input_with_validation "后端目标 (容器名/端口)" "$name" "" "" "false"); then exec 1>&3; return 1; fi
            type="local_port"; port="$target"
            if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
                type="docker"; exec 1>&3
                port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)
                exec 1>&2
                if [ -z "$port" ]; then 
                    if ! port=$(_prompt_user_input_with_validation "未检测到端口，手动输入" "80" "^[0-9]+$" "无效端口" "false"); then exec 1>&3; return 1; fi
                fi
                break
            fi
            if [[ "$port" =~ ^[0-9]+$ ]]; then break; fi
            log_message ERROR "错误: '$target' 既不是容器也不是端口。" >&2
        done
    fi

    local method="http-01"; local provider=""; local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"; local ca_name="letsencrypt"

    if [ "$reuse_wc" == "true" ]; then method="reuse"; skip_cert="true"; fi

    if [ "$skip_cert" == "true" ]; then
        if [ "$reuse_wc" == "false" ]; then
            method=$(echo "$cur" | jq -r '.acme_validation_method // "http-01"'); provider=$(echo "$cur" | jq -r '.dns_api_provider // ""')
            wildcard=$(echo "$cur" | jq -r '.use_wildcard // "n"'); ca_server=$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')
        fi
    else
        local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
        _render_menu "选择 CA 机构" "${ca_list[@]}"
        local ca_choice; while true; do ca_choice=$(_prompt_for_menu_choice_local "1-3"); [ -n "$ca_choice" ] && break; done
        case "$ca_choice" in
            1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
            2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;;
            3) ca_server="google"; ca_name="google" ;;
        esac
        
        local -a method_display=("1. http-01 (智能无中断 Webroot / Standalone)" "2. dns_cf  (Cloudflare API)" "3. dns_ali (阿里云 API)")
        _render_menu "验证方式" "${method_display[@]}" >&2
        local v_choice; while true; do v_choice=$(_prompt_for_menu_choice_local "1-3"); [ -n "$v_choice" ] && break; done
        case "$v_choice" in
            1) method="http-01" ;;
            2|3)
                method="dns-01"; [ "$v_choice" = "2" ] && provider="dns_cf" || provider="dns_ali"
                if ! wildcard=$(_prompt_user_input_with_validation "是否申请泛域名? (y/[n])" "n" "^[yYnN]$" "" "false"); then exec 1>&3; return 1; fi ;;
        esac
    fi

    if [ "$is_cert_only" == "false" ]; then
        local cf_strict_default="n"
        [ "$cf_strict" == "y" ] && cf_strict_default="y"
        if _confirm_action_or_exit_non_interactive "是否开启 Cloudflare 严格安全防御?"; then cf_strict="y"; else cf_strict="n"; fi
    else
        if [ "$skip_cert" == "false" ]; then
            echo -e "\n${CYAN}--- 配置外部重载组件 (Reload Hook) ---${NC}" >&2
            
            local auto_sui_cmd=""
            if systemctl list-units --type=service | grep -q "s-ui.service"; then auto_sui_cmd="systemctl restart s-ui"
            elif systemctl list-units --type=service | grep -q "x-ui.service"; then auto_sui_cmd="systemctl restart x-ui"; fi

            local opt1_text="S-UI / 3x-ui / x-ui"
            if [ -n "$auto_sui_cmd" ]; then opt1_text="${opt1_text} (自动识别: ${auto_sui_cmd##* })"; fi

            local -a hook_opts=(
                "1. ${opt1_text}" 
                "2. V2Ray 原生服务 (systemctl restart v2ray)" 
                "3. Xray 原生服务 (systemctl restart xray)" 
                "4. Nginx 服务 (systemctl reload nginx)" 
                "5. 手动输入自定义 Shell 命令" 
                "6. 跳过"
            )
            _render_menu "自动重启预设方案" "${hook_opts[@]}" >&2
            local hk; while true; do hk=$(_prompt_for_menu_choice_local "1-6"); [ -n "$hk" ] && break; done
            case "$hk" in
                1) reload_cmd="$auto_sui_cmd" ;;
                2) reload_cmd="systemctl restart v2ray" ;;
                3) reload_cmd="systemctl restart xray" ;;
                4) reload_cmd="systemctl reload nginx" ;;
                5) if ! reload_cmd=$(_prompt_user_input_with_validation "请输入完整 Shell 命令" "" "" "" "true"); then exec 1>&3; return 1; fi ;;
                6) reload_cmd="" ;;
            esac
        fi
    fi

    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"; local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    if [ "$reuse_wc" == "true" ]; then cf="$wc_cert"; kf="$wc_key"; fi

    jq -n --arg d "${domain:-}" --arg t "${type:-local_port}" --arg n "${name:-}" --arg p "${port:-}" \
        --arg m "${method:-http-01}" --arg dp "${provider:-}" --arg w "${wildcard:-n}" \
        --arg cu "${ca_server:-}" --arg cn "${ca_name:-}" --arg cf "${cf:-}" --arg kf "${kf:-}" \
        --arg mb "${max_body:-}" --arg cc "${custom_cfg:-}" --arg cs "${cf_strict:-n}" --arg rc "${reload_cmd:-}" \
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf, client_max_body_size:$mb, custom_config:$cc, cf_strict_mode:$cs, reload_cmd:$rc}' >&3
    exec 1>&3
}

_display_projects_list() {
    local json="${1:-}"; if [ -z "$json" ] || [ "$json" == "[]" ]; then echo "暂无数据"; return; fi
    printf "${BOLD}%-4s %-26s %-15s %-12s %-s${NC}\n" "ID" "域名" "状态(余天)" "下期计划" "目标"
    echo "────────────────────────────────────────────────────────────────────────"
    local idx=0
    echo "$json" | jq -c '.[]' | while read -r p; do
        idx=$((idx + 1)); local domain=$(echo "$p" | jq -r '.domain // "未知"'); local type=$(echo "$p" | jq -r '.type')
        local port=$(echo "$p" | jq -r '.resolved_port'); local cert=$(echo "$p" | jq -r '.cert_file')
        local method=$(echo "$p" | jq -r '.acme_validation_method')
        local target_str="Port:$port"; [ "$type" = "docker" ] && target_str="Docker:$port"; [ "$port" == "cert_only" ] && target_str="CertOnly"
        local status_str="缺失"
        local status_color="$RED"; local renew_date="-"
        
        if [ "$method" == "reuse" ]; then
            renew_date="(跟随主域)"
        else
            local conf_file="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"; [ ! -f "$conf_file" ] && conf_file="$HOME/.acme.sh/${domain}/${domain}.conf"
            if [ -f "$conf_file" ]; then
                local next_ts=$(grep "^Le_NextRenewTime=" "$conf_file" | cut -d= -f2- | tr -d "'\"" || true)
                if [ -n "$next_ts" ]; then renew_date=$(date -d "@$next_ts" +%F 2>/dev/null || echo "Err"); fi
            fi
        fi

        if [[ -f "$cert" ]]; then
            local end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2); local end_ts=$(date -d "$end" +%s 2>/dev/null || echo 0)
            local days=$(( (end_ts - $(date +%s)) / 86400 ))
            if (( days < 0 )); then status_str="过期(${days}天)"; status_color="$RED"
            elif (( days <= 30 )); then status_str="急需(${days}天)"; status_color="$YELLOW"
            else status_str="正常(${days}天)"; status_color="$GREEN"; fi
        else status_str="未安装    "; fi
        
        printf "%-4d %-26s ${status_color}%-14s${NC} %-12s %-s\n" "$idx" "$domain" "$status_str" "$renew_date" "${target_str:0:18}"
    done; echo ""
}

manage_configs() {
    while true; do
        local all=$(jq . "$PROJECTS_METADATA_FILE"); local count=$(echo "$all" | jq 'length')
        if [ "$count" -eq 0 ]; then log_message WARN "暂无项目。"; break; fi
        echo ""; _display_projects_list "$all"
        local choice_idx; if ! choice_idx=$(_prompt_user_input_with_validation "请输入序号选择项目 (回车返回)" "" "^[0-9]*$" "无效序号" "true"); then return; fi
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then break; fi
        if [ "$choice_idx" -gt "$count" ]; then log_message ERROR "序号越界"; continue; fi
        local selected_domain=$(echo "$all" | jq -r ".[$((choice_idx-1))].domain")
        
        _render_menu "管理: $selected_domain" "1. 查看证书详情 (中文诊断)" "2. 手动续期" "3. 删除项目" "4. 查看 Nginx 配置" "5. 重新配置 (目标/防御/Hook等)" "6. 修改证书申请与续期设置 (不立即续期)" "7. 添加自定义指令"
        local cc; if ! cc=$(_prompt_for_menu_choice_local "1-7" "true"); then continue; fi
        case "$cc" in
            1) _handle_cert_details "$selected_domain" ;;
            2) _handle_renew_cert "$selected_domain" ;;
            3) _handle_delete_project "$selected_domain"; break ;; 
            4) _handle_view_config "$selected_domain" ;;
            5) _handle_reconfigure_project "$selected_domain" ;;
            6) _handle_modify_renew_settings "$selected_domain" ;;
            7) _handle_set_custom_config "$selected_domain" ;;
            "") continue ;;
        esac
    done
}

_handle_renew_cert() { 
    local d="${1:-}"; local p=$(_get_project_json "$d"); [ -z "$p" ] && return
    _issue_and_install_certificate "$p" && control_nginx reload
    press_enter_to_continue
}

_handle_delete_project() { 
    local d="${1:-}"
    if _confirm_action_or_exit_non_interactive "确认彻底删除 $d 及其证书？"; then
        _remove_and_disable_nginx_config "$d"; "$ACME_BIN" --remove -d "$d" --ecc >/dev/null 2>&1 || true
        rm -f "$SSL_CERTS_BASE_DIR/$d.cer" "$SSL_CERTS_BASE_DIR/$d.key"; _delete_project_json "$d"; control_nginx reload
        log_message SUCCESS "项目 $d 已成功删除。"
    fi
    press_enter_to_continue
}
_handle_view_config() { _view_nginx_config "${1:-}"; press_enter_to_continue; }
_handle_reconfigure_project() {
    local d="${1:-}"; local cur=$(_get_project_json "$d"); log_message INFO "正在重配 $d ..."
    local port=$(echo "$cur" | jq -r .resolved_port); local mode=""; [ "$port" == "cert_only" ] && mode="cert_only"
    local skip_cert="true"; if _confirm_action_or_exit_non_interactive "是否连同证书也重新申请/重载?"; then skip_cert="false"; fi
    local new; if ! new=$(_gather_project_details "$cur" "$skip_cert" "$mode"); then log_message WARN "取消。"; return; fi
    if [ "$skip_cert" == "false" ]; then if ! _issue_and_install_certificate "$new"; then log_message ERROR "证书申请失败。"; return 1; fi; fi
    if [ "$mode" != "cert_only" ]; then _write_and_enable_nginx_config "$d" "$new"; fi
    control_nginx reload && _save_project_json "$new" && log_message SUCCESS "重配成功"; press_enter_to_continue
}
_handle_modify_renew_settings() {
    local d="${1:-}"; local cur=$(_get_project_json "$d")
    local current_method=$(echo "$cur" | jq -r '.acme_validation_method')
    if [ "$current_method" == "reuse" ]; then log_message WARN "此项目正在复用泛域名证书，请前往主域名修改续期设置。"; press_enter_to_continue; return; fi

    echo -e "\n${CYAN}--- 修改证书续期设置: $d ---${NC}"
    local -a ca_list=("1. Let's Encrypt" "2. ZeroSSL" "3. Google Public CA" "4. 保持不变")
    _render_menu "选择新的 CA 机构" "${ca_list[@]}"
    local ca_choice; if ! ca_choice=$(_prompt_for_menu_choice_local "1-4" "false"); then return; fi
    local ca_server=$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')
    local ca_name=$(echo "$cur" | jq -r '.ca_server_name // "letsencrypt"')
    case "$ca_choice" in
        1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
        2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;;
        3) ca_server="google"; ca_name="google" ;;
    esac

    local -a method_display=("1. http-01 (智能 Webroot)" "2. dns_cf (Cloudflare API)" "3. dns_ali (阿里云 API)" "4. 保持不变")
    _render_menu "选择新的验证方式" "${method_display[@]}"
    local v_choice; if ! v_choice=$(_prompt_for_menu_choice_local "1-4" "false"); then return; fi
    local method=$(echo "$cur" | jq -r '.acme_validation_method // "http-01"'); local provider=$(echo "$cur" | jq -r '.dns_api_provider // ""')
    case "$v_choice" in
        1) method="http-01"; provider="" ;;
        2) method="dns-01"; provider="dns_cf" ;;
        3) method="dns-01"; provider="dns_ali" ;;
    esac

    local new_json=$(echo "$cur" | jq --arg cu "$ca_server" --arg cn "$ca_name" --arg m "$method" --arg dp "$provider" '.ca_server_url=$cu | .ca_server_name=$cn | .acme_validation_method=$m | .dns_api_provider=$dp')
    if _save_project_json "$new_json"; then log_message SUCCESS "设置已更新，将在证书快到期时自动应用。"; else log_message ERROR "保存配置失败。"; fi
    press_enter_to_continue
}
_handle_set_custom_config() {
    local d="${1:-}"; local cur=$(_get_project_json "$d"); local current_val=$(echo "$cur" | jq -r '.custom_config // "无"')
    echo -e "\n${CYAN}当前自定义配置:${NC}\n$current_val\n${YELLOW}请输入完整的 Nginx 指令 (需以分号结尾)。回车不修改; 输入 'clear' 清空${NC}"
    local new_val; if ! new_val=$(_prompt_user_input_with_validation "指令内容" "" "" "" "true"); then return; fi
    if [ -z "$new_val" ]; then return; fi
    local json_val="$new_val"; [ "$new_val" == "clear" ] && json_val=""; local new_json=$(echo "$cur" | jq --arg v "$json_val" '.custom_config = $v')
    if _save_project_json "$new_json"; then _write_and_enable_nginx_config "$d" "$new_json"; if control_nginx reload; then log_message SUCCESS "已应用。"; else log_message ERROR "重载失败！回滚配置..."; _write_and_enable_nginx_config "$d" "$cur"; control_nginx reload; fi; fi
    press_enter_to_continue
}
_handle_cert_details() { 
    local d="${1:-}"; local cur=$(_get_project_json "$d"); local cert="$SSL_CERTS_BASE_DIR/$d.cer"
    if [ -f "$cert" ]; then 
        echo -e "\n${CYAN}════════════ 证书详细诊断信息 ════════════${NC}"
        local issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed -n 's/.*O = \([^,]*\).*/\1/p' || echo "未知")
        [ -z "$issuer" ] && issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed -n 's/.*CN = \([^,]*\).*/\1/p' || echo "未知")
        local subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed -n 's/.*CN = \([^,]*\).*/\1/p' || echo "未知")
        local end_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2); local end_ts=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
        local days=$(( (end_ts - $(date +%s)) / 86400 ))
        local dns_names=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:\K[^,]+' | xargs | sed 's/ /, /g' || echo "无")
        local method=$(echo "$cur" | jq -r '.acme_validation_method // "未知"'); local provider=$(echo "$cur" | jq -r '.dns_api_provider // ""'); local method_zh="未知"
        case "$method" in "http-01") method_zh="HTTP 网站根目录验证" ;; "dns-01") method_zh="DNS API 验证 (${provider:-未知})" ;; "reuse") method_zh="泛域名智能复用" ;; esac

        echo -e "${BOLD}颁发机构 (CA) :${NC} $issuer\n${BOLD}证书主域名     :${NC} $subject\n${BOLD}包含子域名     :${NC} $dns_names"
        if (( days < 0 )); then echo -e "${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${RED}(已过期 ${days#-} 天)${NC}"
        elif (( days <= 30 )); then echo -e "${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${YELLOW}(剩余 $days 天 - 急需续期)${NC}"
        else echo -e "${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${GREEN}(剩余 $days 天)${NC}"; fi
        echo -e "${BOLD}配置的验证方式 :${NC} $method_zh\n${CYAN}══════════════════════════════════════════${NC}"
    else log_message ERROR "证书文件不存在: $cert"; fi
    press_enter_to_continue
}

check_and_auto_renew_certs() {
    log_message INFO "正在执行 Cron 守护检测并批量续期..."
    local success=0 fail=0
    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r p; do
        local d=$(echo "$p" | jq -r .domain); local f=$(echo "$p" | jq -r .cert_file); local m=$(echo "$p" | jq -r '.acme_validation_method')
        echo -ne "检查: $d ... "
        if [ "$m" == "reuse" ]; then echo -e "跳过(跟随主域)"; continue; fi
        if [ ! -f "$f" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$f"; then
            echo -e "${YELLOW}触发续期...${NC}"
            if _issue_and_install_certificate "$p"; then success=$((success+1)); else fail=$((fail+1)); fi
        else echo -e "${GREEN}有效期充足${NC}"; fi
    done
    control_nginx reload || true; log_message INFO "批量任务结束: $success 成功, $fail 失败。"
}

configure_nginx_projects() {
    local mode="${1:-standard}"; local json
    echo -e "\n${CYAN}开始配置新项目...${NC}"
    if ! json=$(_gather_project_details "{}" "false" "$mode"); then log_message WARN "用户取消配置。"; return; fi
    
    _issue_and_install_certificate "$json"
    local ret=$?
    local domain=$(echo "$json" | jq -r .domain)
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"

    if [ -f "$cert" ]; then
        _save_project_json "$json"
        if [ $ret -ne 0 ]; then
            log_message WARN "证书已生成并保存配置，但服务重启失败，请手动处理。"
        else
            log_message SUCCESS "配置已保存。"
            [ "$mode" != "cert_only" ] && echo -e "\n网站已上线: https://$(echo "$json" | jq -r .domain)" || echo -e "\n证书已就绪: /etc/ssl/${domain}.cer"
        fi
    else
        log_message ERROR "证书申请失败，未保存。"
    fi
}

# ==============================================================================
# SECTION: 主流程 UI
# ==============================================================================

main_menu() {
    while true; do
        _draw_dashboard
        echo -e "${PURPLE}【HTTP(S) 业务】${NC}"
        echo -e " 1. 配置新域名反代 (New HTTP Proxy)"
        echo -e " 2. HTTP 项目管理 (Manage HTTP)"
        echo -e " 3. 仅申请证书 (支持为 S-UI/V2Ray 绑定重载钩子)"
        echo ""
        echo -e "${PURPLE}【TCP 负载均衡】${NC}"
        echo -e " 4. 配置 TCP 反代/负载均衡 (New Stream Proxy)"
        echo -e " 5. 管理 TCP 反向代理 (Manage Stream)"
        echo ""
        echo -e "${PURPLE}【运维监控与系统维护】${NC}"
        echo -e " 6. 批量续期 (Auto Renew All)"
        echo -e " 7. 查看日志 (Logs - Nginx/acme)"
        echo -e " 8. ${ORANGE}${BOLD}更新 Cloudflare 防御 IP 库 (强烈建议防源站被扫配置)${NC}"
        echo -e " 9. 备份/还原与配置重建 (灾备数据与 Nginx 恢复组合技)"
        echo -e "10. 设置 Telegram 机器人通知 (TG Bot Notify)"
        echo ""
        
        local c; if ! c=$(_prompt_for_menu_choice_local "1-10" "true"); then break; fi
        case "$c" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) manage_configs ;;
            3) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            4) configure_tcp_proxy; press_enter_to_continue ;;
            5) manage_tcp_configs ;;
            6) if _confirm_action_or_exit_non_interactive "确认检查所有项目？"; then check_and_auto_renew_certs; press_enter_to_continue; fi ;;
            7) _render_menu "查看日志" "1. Nginx 全局访问/错误日志" "2. acme.sh 证书运行日志"
               local log_c; if log_c=$(_prompt_for_menu_choice_local "1-2" "true"); then [ "$log_c" = "1" ] && _view_nginx_global_log || _view_acme_log; press_enter_to_continue; fi ;;
            8) _update_cloudflare_ips; press_enter_to_continue ;;
            9) _handle_backup_restore ;;
            10) setup_tg_notifier; press_enter_to_continue ;;
            "") return 0 ;;
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

if ! check_root; then exit 1; fi
check_os_compatibility
install_dependencies 
initialize_environment

if [[ " $* " =~ " --cron " ]]; then check_and_auto_renew_certs; exit $?; fi
install_acme_sh && main_menu
exit $?
