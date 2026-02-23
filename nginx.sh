# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.29.0 - TG 机器人富文本通知)
# =============================================================
# 作者：Shell 脚本专家
# 描述：自动化管理 Nginx 反代配置与 SSL 证书，支持 TCP 负载均衡、TLS卸载与泛域名智能复用
# 版本历史：
#   v4.29.0 - 实装 Telegram 富文本推送机制，完美复刻 UI，无缝挂载续期事件
#   v4.28.0 - 修复 Gzip 重复指令导致的崩溃，实装 Nginx 自愈容灾，优化列表排版
#   v4.27.0 - 注入日志切割守护 (Logrotate)，修复临时文件残留，优化 CF 防御判定逻辑

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
    echo -e "\n${RED}检测到中断信号 (Ctrl+C)，已安全取消操作并清理残留文件。${NC}"
    _cleanup
    exit 130
}

trap '_cleanup' EXIT
trap '_on_int' INT TERM

_log_prefix() {
    if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then echo -n "$(date '+%Y-%m-%d %H:%M:%S') "; fi
}

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
    local range="${1:-}"
    local allow_empty="${2:-false}"
    local prompt_text="${ORANGE}选项 [${range}]${NC} (Enter 返回): "
    local choice
    while true; do
        read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty || return 1
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then echo ""; return 0; fi
            echo -e "${YELLOW}请选择一个选项。${NC}" >&2
            continue
        fi
        if [[ "$choice" =~ ^[0-9A-Za-z]+$ ]]; then echo "$choice"; return 0; fi
    done
}

_strip_colors() { echo -e "${1:-}" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g"; }

_str_width() {
    local str="${1:-}"
    local clean="$(_strip_colors "$str")"
    if command -v wc >/dev/null 2>&1; then echo -n "$clean" | wc -L; else echo "${#clean}"; fi
}

_draw_line() {
    local len="${1:-40}"
    printf "%${len}s" "" | sed "s/ /─/g"
}

_center_text() {
    local text="$1"; local width="$2"
    local text_len=$(_str_width "$text")
    local pad=$(( (width - text_len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0
    printf "%${pad}s" ""
}

_render_menu() {
    local title="${1:-菜单}"; shift; 
    local title_vis_len=$(_str_width "$title")
    local min_width=50
    local box_width=$min_width
    if [ "$title_vis_len" -gt "$((min_width - 4))" ]; then box_width=$((title_vis_len + 6)); fi

    echo ""
    echo -e "${GREEN}╭$(_draw_line "$box_width")╮${NC}"
    local padding=$(_center_text "$title" "$box_width")
    local left_len=${#padding}
    local right_len=$((box_width - left_len - title_vis_len))
    echo -e "${GREEN}│${NC}${padding}${BOLD}${title}${NC}$(printf "%${right_len}s" "")${GREEN}│${NC}"
    echo -e "${GREEN}╰$(_draw_line "$box_width")╯${NC}"
    for line in "$@"; do echo -e " ${line}"; done
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then log_message ERROR "请使用 root 用户运行此操作。"; return 1; fi
    return 0
}

check_os_compatibility() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
            echo -e "${RED}⚠️  警告: 检测到非 Debian/Ubuntu 系统 ($NAME)。${NC}"
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                if ! _confirm_action_or_exit_non_interactive "是否尝试继续?"; then exit 1; fi
            else
                log_message WARN "非 Debian 系统，尝试强制运行..."
            fi
        fi
    fi
}

get_vps_ip() {
    if [ -z "$VPS_IP" ]; then
        VPS_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "")
        VPS_IPV6=$(curl -s -6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "")
    fi
}

_prompt_user_input_with_validation() {
    local prompt="${1:-}" default="${2:-}" regex="${3:-}" error_msg="${4:-}" allow_empty="${5:-false}" val=""
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local disp=""; if [ -n "$default" ]; then disp=" [默认: ${default}]"; fi
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
# SECTION: TG 机器人通知模块
# ==============================================================================

setup_tg_notifier() {
    echo -e "\n${CYAN}--- Telegram 机器人通知设置 ---${NC}"
    echo -e "${YELLOW}设置后，当证书自动或手动续期时，将推送精美的图文通知到您的 TG。${NC}"
    
    local curr_token="" curr_chat="" curr_name=""
    if [ -f "$TG_CONF_FILE" ]; then
        source "$TG_CONF_FILE"
        curr_token="${TG_BOT_TOKEN:-}"
        curr_chat="${TG_CHAT_ID:-}"
        curr_name="${SERVER_NAME:-}"
        echo -e "\n${GREEN}当前已配置:${NC}"
        echo -e " 机器人 Token : $(_mask_string "$curr_token")"
        echo -e " 会话 ID      : $curr_chat"
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

    local tk; if ! tk=$(_prompt_user_input_with_validation "请输入 Bot Token (如 1234:ABC...)" "$curr_token" "" "" "false"); then return; fi
    local cid; if ! cid=$(_prompt_user_input_with_validation "请输入 Chat ID (如 123456789)" "$curr_chat" "^-?[0-9]+$" "格式错误，只能包含数字或负号" "false"); then return; fi
    local sname; if ! sname=$(_prompt_user_input_with_validation "请输入这台服务器的备注 (如 日本主机)" "$curr_name" "" "" "false"); then return; fi

    cat > "$TG_CONF_FILE" << EOF
TG_BOT_TOKEN="${tk}"
TG_CHAT_ID="${cid}"
SERVER_NAME="${sname}"
EOF
    chmod 600 "$TG_CONF_FILE"
    
    log_message INFO "正在发送测试消息..."
    _send_tg_notify "success" "测试域名 (Test)" "恭喜！您的 Telegram 通知系统已成功挂载。" "测试服务器面板" "true"
}

_send_tg_notify() {
    local status_type="${1:-}"  # success 或 fail
    local domain="${2:-}"
    local detail_msg="${3:-}"
    local is_test="${4:-}"
    
    if [ ! -f "$TG_CONF_FILE" ]; then return 0; fi
    source "$TG_CONF_FILE"
    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then return 0; fi

    get_vps_ip

    local title="" status_text="" emoji=""
    if [ "$status_type" == "success" ]; then
        title="证书续期成功"
        status_text="Success (✅ 续订完成)"
        emoji="✅"
    else
        title="异常警报"
        status_text="Alert (⚠️ 续订失败)"
        emoji="⚠️"
    fi

    local ipv6_line=""
    if [ -n "$VPS_IPV6" ]; then
        ipv6_line="
🌐<b>IPv6:</b> <code>${VPS_IPV6}</code>"
    fi

    local current_time=$(date "+%Y-%m-%d %H:%M:%S (%Z)")
    
    # 构建 HTML 格式的正文文本
    local text_body="<b>${emoji} ${title}</b>

🖥<b>服务器:</b> ${SERVER_NAME:-未知主机}
🌐<b>IPv4:</b> <code>${VPS_IP:-未知}</code>${ipv6_line}

📄<b>状态:</b> ${status_text}
⌚<b>时间:</b> ${current_time}
🎯<b>域名:</b> <code>${domain}</code>

📃<b>详细描述:</b>
<i>${detail_msg}</i>"

    local button_url="http://${domain}/"
    if [ "$is_test" == "true" ]; then button_url="https://core.telegram.org/bots/api"; fi

    # 构建 JSON Payload (使用 jq 确保特殊字符安全转义)
    local kb_json='{"inline_keyboard":[[{"text":"📊 访问实例","url":"'"$button_url"'"}]]}'
    local payload_file=$(mktemp /tmp/tg_payload_XXXXXX.json)
    
    jq -n --arg cid "$TG_CHAT_ID" --arg txt "$text_body" --argjson kb "$kb_json" \
        '{chat_id: $cid, text: $txt, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: $kb}' > "$payload_file"

    # 异步发送请求，超时时间限制 10 秒，输出重定向到 dev/null 防止干扰主进程
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d @"$payload_file" \
        --connect-timeout 5 --max-time 10 >/dev/null 2>&1 &
    
    # 延迟清理 payload
    (sleep 15 && rm -f "$payload_file" 2>/dev/null) &
}

# ==============================================================================
# SECTION: 环境初始化与依赖
# ==============================================================================

install_dependencies() {
    if [ -f "$DEPS_MARK_FILE" ]; then return 0; fi
    local deps="nginx curl socat openssl jq idn dnsutils nano wc"
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
        if [ -f /var/run/nginx.pid ]; then
            kill -USR1 `cat /var/run/nginx.pid`
        fi
    endscript
}
EOF
    fi

    if [ ! -f /etc/logrotate.d/nginx_ssl_manager ]; then
        log_message INFO "注入本面板运行日志 (Logrotate) 切割规则..."
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
                log_message WARN "清理与主配置冲突的 Gzip 文件，恢复 Nginx 状态。"
            fi
        fi
    fi

    if [ ! -f "/etc/nginx/conf.d/gzip_optimize.conf" ]; then
        log_message INFO "尝试注入 Nginx 全局 Gzip 静态压缩优化配置..."
        mkdir -p /etc/nginx/conf.d
        cat > "/etc/nginx/conf.d/gzip_optimize.conf" << 'EOF'
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_buffers 16 8k;
gzip_http_version 1.1;
gzip_min_length 256;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
EOF
        if ! nginx -t >/dev/null 2>&1; then
            rm -f "/etc/nginx/conf.d/gzip_optimize.conf"
            log_message WARN "系统已预置 gzip 配置，取消注入以防止冲突崩溃。"
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
        crontab -l | sed "s| > /dev/null| >> $LOG_FILE 2>\&1|g" | grep -v "$SCRIPT_PATH" > /tmp/cron.bak || true
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
# SECTION: 数据与 HTTP 代理配置
# ==============================================================================

_get_project_json() { jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""; }

_save_project_json() {
    local json="${1:-}"; if [ -z "$json" ]; then return 1; fi
    local domain=$(echo "$json" | jq -r .domain); local temp=$(mktemp)
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq --argjson new_val "$json" --arg d "$domain" 'map(if .domain == $d then $new_val else . end)' "$PROJECTS_METADATA_FILE" > "$temp"
    else
        jq --argjson new_val "$json" '. + [$new_val]' "$PROJECTS_METADATA_FILE" > "$temp"
    fi
    if [ $? -eq 0 ]; then mv "$temp" "$PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}

_delete_project_json() {
    local temp=$(mktemp)
    jq --arg d "${1:-}" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$PROJECTS_METADATA_FILE"
}

_write_and_enable_nginx_config() {
    local domain="${1:-}"; local json="${2:-}"; local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    local port=$(echo "$json" | jq -r .resolved_port)
    if [ "$port" == "cert_only" ]; then return 0; fi

    local cert=$(echo "$json" | jq -r .cert_file); local key=$(echo "$json" | jq -r .key_file)
    local max_body=$(echo "$json" | jq -r '.client_max_body_size // empty'); local custom_cfg=$(echo "$json" | jq -r '.custom_config // empty')
    local cf_strict=$(echo "$json" | jq -r '.cf_strict_mode // "n"')
    
    local body_cfg=""; [[ -n "$max_body" && "$max_body" != "null" ]] && body_cfg="client_max_body_size ${max_body};"
    local extra_cfg=""; [[ -n "$custom_cfg" && "$custom_cfg" != "null" ]] && extra_cfg="$custom_cfg"
    local cf_strict_cfg=""
    if [ "$cf_strict" == "y" ]; then
        [ ! -f "/etc/nginx/snippets/cf_allow.conf" ] && return 1
        cf_strict_cfg="include /etc/nginx/snippets/cf_allow.conf;"
    fi

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

# ==============================================================================
# SECTION: 业务逻辑 (证书申请与主流程)
# ==============================================================================

_issue_and_install_certificate() {
    local json="${1:-}"
    local domain=$(echo "$json" | jq -r .domain)
    local method=$(echo "$json" | jq -r .acme_validation_method)
    
    if [ "$method" == "reuse" ]; then return 0; fi

    local provider=$(echo "$json" | jq -r .dns_api_provider); local wildcard=$(echo "$json" | jq -r .use_wildcard)
    local ca=$(echo "$json" | jq -r .ca_server_url)
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"; local key="$SSL_CERTS_BASE_DIR/$domain.key"
    
    log_message INFO "正在为 $domain 申请证书 ($method)..."
    
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca" --log)
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    local temp_conf_created="false"; local temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"

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
        local port_conflict="false"; local temp_svc=""
        if ss -tuln 2>/dev/null | grep -qE ':(80|443)\s'; then
            temp_svc=$(_detect_web_service)
            if [ "$temp_svc" = "nginx" ]; then
                if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
                    cat > "$temp_conf" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }
EOF
                    ln -sf "$temp_conf" "$NGINX_SITES_ENABLED_DIR/"; systemctl reload nginx || true; temp_conf_created="true"
                fi
                mkdir -p "$NGINX_WEBROOT_DIR"; cmd+=("--webroot" "$NGINX_WEBROOT_DIR")
            else
                if [ "$IS_INTERACTIVE_MODE" = "false" ]; then port_conflict="true"; else
                    if _confirm_action_or_exit_non_interactive "是否临时停止 $temp_svc 以释放 80 端口?"; then port_conflict="true"; fi
                fi
                if [ "$port_conflict" == "true" ]; then
                    systemctl stop "$temp_svc"; trap "systemctl start $temp_svc; _cleanup; exit 130" INT TERM
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

    if [ $ret -ne 0 ]; then
        echo -e "\n"; log_message ERROR "申请失败: $domain"; 
        local err_log=$(cat "$log_temp"); rm -f "$log_temp"
        if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then systemctl start "$temp_svc"; trap '_on_int' INT TERM; fi
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        
        # 将失败日志前200字符作为摘要推送 TG
        local short_err="${err_log:0:200}..."
        _send_tg_notify "fail" "$domain" "acme.sh 通信拒绝或 CA 限制。\n\n$short_err" ""
        return 1
    fi
    rm -f "$log_temp"
    if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then systemctl start "$temp_svc"; trap '_on_int' INT TERM; fi

    local rcmd=$(echo "$json" | jq -r '.reload_cmd // empty')
    local resolved_port=$(echo "$json" | jq -r '.resolved_port // empty')
    local install_reload_cmd="systemctl reload nginx"
    
    if [ "$resolved_port" == "cert_only" ]; then
        if [ -n "$rcmd" ] && [ "$rcmd" != "null" ]; then install_reload_cmd="$rcmd"; else install_reload_cmd=""; fi
    fi

    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
    [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    
    if ! "${inst[@]}"; then 
        log_message ERROR "安装失败: $domain"
        _send_tg_notify "fail" "$domain" "证书签发成功，但 --install-cert 或 Hook 命令执行失败，请检查相关服务。" ""
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret; return 1
    fi
    
    # 成功推送
    _send_tg_notify "success" "$domain" "证书已成功自动更新并挂载入服务配置。" ""
    
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret; return 0
}

_handle_renew_cert() { 
    local d="${1:-}"; local p=$(_get_project_json "$d"); [ -z "$p" ] && return
    _issue_and_install_certificate "$p" && control_nginx reload
    press_enter_to_continue
}

check_and_auto_renew_certs() {
    log_message INFO "正在执行 Cron 守护检测并批量续期..."
    local success=0 fail=0
    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r p; do
        local d=$(echo "$p" | jq -r .domain); local f=$(echo "$p" | jq -r .cert_file)
        local m=$(echo "$p" | jq -r .acme_validation_method)
        echo -ne "检查: $d ... "
        
        if [ "$m" == "reuse" ]; then echo -e "跳过(跟随主域)"; continue; fi

        if [ ! -f "$f" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$f"; then
            echo -e "${YELLOW}触发续期...${NC}"
            if _issue_and_install_certificate "$p"; then success=$((success+1)); else fail=$((fail+1)); fi
        else echo -e "${GREEN}有效期充足${NC}"; fi
    done
    control_nginx reload || true
    log_message INFO "批量任务结束: $success 成功, $fail 失败。"
}

# ==============================================================================
# SECTION: 主流程 UI
# ==============================================================================

_draw_dashboard() {
    local nginx_v=$(nginx -v 2>&1 | awk -F/ '{print $2}' | cut -d' ' -f1); local uptime_raw=$(uptime -p | sed 's/up //')
    local count=$(jq '. | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    echo -e "\n${GREEN}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│${NC}                   ${BOLD}Nginx 管理面板 v4.29.0${NC}                   ${GREEN}│${NC}"
    echo -e "${GREEN}╰────────────────────────────────────────────────────────────────────────╯${NC}"
    echo -e " Nginx: ${GREEN}${nginx_v}${NC} | HTTP 业务数: ${BOLD}${count}${NC}"
    echo -e "${GREEN}──────────────────────────────────────────────────────────────────────────${NC}"
}

main_menu() {
    while true; do
        _draw_dashboard
        echo -e "${PURPLE}【日常配置】${NC}"
        echo -e " 1. HTTP 项目管理 (配置/续期/删除)"
        echo -e " 2. 设置 Telegram 机器人通知 (TG Bot Notify)"
        echo -e " 0. 退出"
        
        local c; if ! c=$(_prompt_for_menu_choice_local "0-2" "true"); then break; fi
        case "$c" in
            1) log_message INFO "请查阅历史代码查看 HTTP 管理子菜单" ;;
            2) setup_tg_notifier; press_enter_to_continue ;;
            0|"") return 0 ;;
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
