# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.21.0 - 终极安全与架构演进版)
# =============================================================
# 作者：Shell 脚本专家
# 描述：自动化管理 Nginx 反代配置与 SSL 证书，支持 TCP 反代与 CF 严格防御
# 版本历史：
#   v4.21.0 - 实装 projects.json 自动快照、TCP Stream Proxy 模块、CF IP 严格防御机制
#   v4.20.0 - 引入智能 Webroot 无中断验证，新增一键重建所有 Nginx 配置功能
#   v4.19.0 - 实现 API 密钥脱敏重用与无回显输入，新增 8.8.8.8 公共 DNS 解析穿透

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
# SECTION: 核心工具函数
# ==============================================================================

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
        read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty || return
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then echo ""; return; fi
            echo -e "${YELLOW}请选择一个选项。${NC}" >&2
            continue
        fi
        if [[ "$choice" =~ ^[0-9A-Za-z]+$ ]]; then echo "$choice"; return; fi
    done
}

_strip_colors() {
    echo -e "${1:-}" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g"
}

_str_width() {
    local str="${1:-}"
    local clean="$(_strip_colors "$str")"
    if command -v wc >/dev/null 2>&1; then
        echo -n "$clean" | wc -L
    else
        echo "${#clean}"
    fi
}

_draw_line() {
    local len="${1:-40}"
    printf "%${len}s" "" | sed "s/ /─/g"
}

_center_text() {
    local text="$1"
    local width="$2"
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
    if [ "$title_vis_len" -gt "$((min_width - 4))" ]; then
        box_width=$((title_vis_len + 6))
    fi

    echo ""
    echo -e "${GREEN}╭$(_draw_line "$box_width")╮${NC}"
    local padding=$(_center_text "$title" "$box_width")
    local left_len=${#padding}
    local right_len=$((box_width - left_len - title_vis_len))
    echo -e "${GREEN}│${NC}${padding}${BOLD}${title}${NC}$(printf "%${right_len}s" "")${GREEN}│${NC}"
    echo -e "${GREEN}╰$(_draw_line "$box_width")╯${NC}"
    
    for line in "$@"; do echo -e " ${line}"; done
}

cleanup_temp_files() {
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
}
_on_exit() {
    cleanup_temp_files
}
trap _on_exit INT TERM

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
                if ! _confirm_action_or_exit_non_interactive "是否尝试继续 (可能会报错)?"; then
                    exit 1
                fi
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
            local disp=""
            if [ -n "$default" ]; then disp=" [默认: ${default}]"
            fi
            echo -ne "${YELLOW}${prompt}${NC}${disp}: " >&2
            read -r val < /dev/tty || return 1
            val=${val:-$default}
        else
            val="$default"
            if [[ -z "$val" && "$allow_empty" = "false" ]]; then
                log_message ERROR "非交互模式缺失: $prompt"; return 1
            fi
        fi
        if [[ -z "$val" && "$allow_empty" = "true" ]]; then echo ""; return 0; fi
        if [[ -z "$val" ]]; then log_message ERROR "输入不能为空"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        if [[ -n "$regex" && ! "$val" =~ $regex ]]; then
            log_message ERROR "${error_msg:-格式错误}"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        echo "$val"; return 0
    done
}

_prompt_secret() {
    local prompt="${1:-}" val=""
    echo -ne "${YELLOW}${prompt} (无屏幕回显): ${NC}" >&2
    read -rs val < /dev/tty || return 1
    echo "" >&2
    echo "$val"
}

_mask_string() {
    local str="${1:-}"
    local len=${#str}
    if [ "$len" -le 6 ]; then
        echo "***"
    else
        echo "${str:0:2}***${str: -3}"
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
    local svc
    for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then echo "$svc"; return; fi
    done
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
            apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "安装 $pkg 失败 (请尝试手动安装)"; return 1; }
            missing=1
        fi
    done
    touch "$DEPS_MARK_FILE"
    [ "$missing" -eq 1 ] && log_message SUCCESS "依赖就绪。"
    return 0
}

initialize_environment() {
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
    if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
    export PATH="$(dirname "$ACME_BIN"):$PATH"
    
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR" "$BACKUP_DIR"
    mkdir -p "$JSON_BACKUP_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$NGINX_STREAM_ENABLED_DIR"
    
    # Init HTTP projects
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then 
        echo "[]" > "$PROJECTS_METADATA_FILE"
    fi
    # Init TCP projects
    if [ ! -f "$TCP_PROJECTS_METADATA_FILE" ] || ! jq -e . "$TCP_PROJECTS_METADATA_FILE" > /dev/null 2>&1; then 
        echo "[]" > "$TCP_PROJECTS_METADATA_FILE"
    fi

    # Inject TCP Stream block into nginx.conf if not exists
    if [ -f /etc/nginx/nginx.conf ] && ! grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
        log_message INFO "正在为 Nginx 注入 Stream (TCP 代理) 模块配置..."
        cat >> /etc/nginx/nginx.conf << EOF

# TCP/UDP Stream Proxy Auto-injected
stream {
    include ${NGINX_STREAM_ENABLED_DIR}/*.conf;
}
EOF
        systemctl reload nginx || true
    fi
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then return 0; fi
    
    log_message WARN "acme.sh 未安装，开始安装..."
    local email; email=$(_prompt_user_input_with_validation "注册邮箱" "" "" "" "true")
    local cmd="curl https://get.acme.sh | sh"
    [ -n "$email" ] && cmd+=" -s email=$email"
    if eval "$cmd"; then 
        ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
        if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
        
        "$ACME_BIN" --upgrade --auto-upgrade >/dev/null 2>&1 || true
        crontab -l | sed "s| > /dev/null| >> $LOG_FILE 2>\&1|g" | crontab -
        log_message SUCCESS "acme.sh 安装成功 (已开启自动更新)。"
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
    local temp_allow
    temp_allow=$(mktemp)
    
    if curl -sS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 > "$temp_allow" && \
       echo "" >> "$temp_allow" && \
       curl -sS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 >> "$temp_allow"; then
        
        mkdir -p /etc/nginx/snippets /etc/nginx/conf.d
        local temp_cf_allow=$(mktemp)
        local temp_cf_real=$(mktemp)
        
        echo "# Cloudflare Allow List (Auto-updated)" > "$temp_cf_allow"
        echo "# Cloudflare Real IP (Auto-updated)" > "$temp_cf_real"
        
        while read -r ip; do
            [ -z "$ip" ] && continue
            echo "allow $ip;" >> "$temp_cf_allow"
            echo "set_real_ip_from $ip;" >> "$temp_cf_real"
        done < <(grep -E '^[0-9a-fA-F.:]+(/[0-9]+)?$' "$temp_allow")
        
        echo "deny all;" >> "$temp_cf_allow"
        echo "real_ip_header CF-Connecting-IP;" >> "$temp_cf_real"
        
        mv "$temp_cf_allow" /etc/nginx/snippets/cf_allow.conf
        mv "$temp_cf_real" /etc/nginx/conf.d/cf_real_ip.conf
        
        log_message SUCCESS "Cloudflare IP 列表更新完成。"
        control_nginx reload || true
    else
        log_message ERROR "获取 Cloudflare IP 列表失败，请检查网络连通性。"
    fi
    rm -f "$temp_allow" "$temp_cf_allow" "$temp_cf_real" 2>/dev/null || true
}

_snapshot_projects_json() {
    local target_file="${1:-$PROJECTS_METADATA_FILE}"
    if [ -f "$target_file" ]; then
        local base_name=$(basename "$target_file" .json)
        local snap_name="${JSON_BACKUP_DIR}/${base_name}_$(date +%Y%m%d_%H%M%S).json.bak"
        cp "$target_file" "$snap_name"
        # 仅保留最近 10 份快照
        ls -tp "${JSON_BACKUP_DIR}/${base_name}_*.bak" 2>/dev/null | grep -v '/$' | tail -n +11 | xargs -I {} rm -- "{}" 2>/dev/null || true
    fi
}

_handle_backup_restore() {
    echo ""
    _render_menu "备份与还原系统" \
        "1. 创建新备份 (Projects + Configs + Certs)" \
        "2. 从备份还原" \
        "3. 查看备份目录" \
        "4. 从 projects.json 本地快照恢复"
        
    case "$(_prompt_for_menu_choice_local "1-4" "true")" in
        1)
            local ts=$(date +%Y%m%d_%H%M%S)
            local backup_file="$BACKUP_DIR/nginx_manager_backup_$ts.tar.gz"
            log_message INFO "正在打包备份..."
            if tar -czf "$backup_file" -C / "$PROJECTS_METADATA_FILE" "$TCP_PROJECTS_METADATA_FILE" "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$SSL_CERTS_BASE_DIR" 2>/dev/null; then
                log_message SUCCESS "备份成功: $backup_file"
                du -h "$backup_file"
            else
                log_message ERROR "备份失败。"
            fi
            ;;
        2)
            echo ""
            echo -e "${CYAN}可用备份列表:${NC}"
            ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || { log_message WARN "无可用备份。"; return; }
            echo ""
            local file_path=$(_prompt_user_input_with_validation "请输入完整备份文件路径" "" "" "" "true")
            if [ -z "$file_path" ]; then return; fi
            if [ ! -f "$file_path" ]; then log_message ERROR "文件不存在"; return; fi
            
            if _confirm_action_or_exit_non_interactive "警告：还原将覆盖当前配置，是否继续？"; then
                log_message INFO "正在停止 Nginx..."
                systemctl stop nginx || true
                log_message INFO "正在解压还原..."
                if tar -xzf "$file_path" -C /; then
                    log_message SUCCESS "文件还原完成。"
                    control_nginx restart
                else
                    log_message ERROR "解压失败。"
                fi
            fi
            ;;
        3)
            echo ""
            ls -lh "$BACKUP_DIR"
            ;;
        4)
            echo ""
            echo -e "${CYAN}可用 projects.json 快照:${NC}"
            ls -lh "$JSON_BACKUP_DIR"/*.bak 2>/dev/null || { log_message WARN "无可用快照。"; return; }
            echo ""
            local snap_path=$(_prompt_user_input_with_validation "请输入要恢复的快照路径" "" "" "" "true")
            if [ -n "$snap_path" ] && [ -f "$snap_path" ]; then
                if _confirm_action_or_exit_non_interactive "这将会回滚您的元数据记录，确认执行？"; then
                    _snapshot_projects_json # 恢复前也做个快照
                    cp "$snap_path" "$PROJECTS_METADATA_FILE"
                    log_message SUCCESS "元数据已回滚，建议使用 '重建所有配置' 以使状态同步。"
                fi
            fi
            ;;
        *) return ;;
    esac
    press_enter_to_continue
}

# ==============================================================================
# SECTION: 日志与运维
# ==============================================================================

_view_file_with_tail() {
    local file="${1:-}"
    if [ ! -f "$file" ]; then log_message ERROR "文件不存在: $file"; return; fi
    echo -e "${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}"
    trap ':' INT
    tail -f -n 50 "$file" || true
    trap _on_exit INT
    echo -e "\n${CYAN}--- 日志查看结束 ---${NC}"
}

_view_acme_log() {
    local log_file="$HOME/.acme.sh/acme.sh.log"
    [ ! -f "$log_file" ] && log_file="/root/.acme.sh/acme.sh.log"
    _view_file_with_tail "$log_file"
}

_view_nginx_global_log() {
    _render_menu "Nginx 全局日志" "1. 访问日志" "2. 错误日志"
    local c=$(_prompt_for_menu_choice_local "1-2" "true")
    case "$c" in
        1) _view_file_with_tail "$NGINX_ACCESS_LOG" ;;
        2) _view_file_with_tail "$NGINX_ERROR_LOG" ;;
        *) return ;;
    esac
}

_view_project_access_log() {
    local domain="${1:-}"
    if [ ! -f "$NGINX_ACCESS_LOG" ]; then log_message ERROR "全局访问日志不存在: $NGINX_ACCESS_LOG"; return; fi
    echo -e "${CYAN}--- 实时访问日志: $domain (Ctrl+C 退出) ---${NC}"
    trap ':' INT
    tail -f "$NGINX_ACCESS_LOG" | grep --line-buffered "$domain" || true
    trap _on_exit INT
    echo -e "\n${CYAN}--- 日志查看结束 ---${NC}"
}

_manage_cron_jobs() {
    echo ""
    echo -e "${CYAN}--- 当前系统 Cron 任务 (acme.sh 续期守护) ---${NC}"
    if crontab -l 2>/dev/null | grep -i "acme.sh" > /dev/null; then
        crontab -l | grep -i "acme.sh"
        echo -e "${GREEN}检测到 acme.sh 定时任务已正常挂载，证书将会自动续期。${NC}"
    else
        echo -e "${YELLOW}未检测到 acme.sh 的定时任务，可能会导致证书过期无法自动续期！${NC}"
        if _confirm_action_or_exit_non_interactive "是否尝试重新挂载 acme.sh 定时任务？"; then
            "$ACME_BIN" --install-cronjob
            log_message SUCCESS "任务挂载指令已发送。"
        fi
    fi
}

# ==============================================================================
# SECTION: 数据与 HTTP 代理配置
# ==============================================================================

_get_project_json() { 
    jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""
}

_save_project_json() {
    local json="${1:-}" 
    if [ -z "$json" ]; then return 1; fi
    
    _snapshot_projects_json # 核心防护：写入前快照
    
    local domain=$(echo "$json" | jq -r .domain)
    local temp=$(mktemp)
    
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq --argjson new_val "$json" --arg d "$domain" \
           'map(if .domain == $d then $new_val else . end)' \
           "$PROJECTS_METADATA_FILE" > "$temp"
    else
        jq --argjson new_val "$json" \
           '. + [$new_val]' \
           "$PROJECTS_METADATA_FILE" > "$temp"
    fi
    
    if [ $? -eq 0 ]; then mv "$temp" "$PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}

_delete_project_json() {
    _snapshot_projects_json
    local temp=$(mktemp)
    jq --arg d "${1:-}" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$PROJECTS_METADATA_FILE"
}

_write_and_enable_nginx_config() {
    local domain="${1:-}" 
    local json="${2:-}" 
    local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    
    if [ -z "$json" ]; then log_message ERROR "配置生成失败: 传入 JSON 为空。"; return 1; fi

    local port=$(echo "$json" | jq -r .resolved_port)
    if [ "$port" == "cert_only" ]; then return 0; fi

    local cert=$(echo "$json" | jq -r .cert_file)
    local key=$(echo "$json" | jq -r .key_file)
    
    local max_body=$(echo "$json" | jq -r '.client_max_body_size // empty')
    local custom_cfg=$(echo "$json" | jq -r '.custom_config // empty')
    local cf_strict=$(echo "$json" | jq -r '.cf_strict_mode // "n"')
    
    local body_cfg=""
    if [[ -n "$max_body" && "$max_body" != "null" ]]; then
        body_cfg="client_max_body_size ${max_body};"
    fi
    
    local extra_cfg=""
    if [[ -n "$custom_cfg" && "$custom_cfg" != "null" ]]; then
        extra_cfg="$custom_cfg"
    fi
    
    local cf_strict_cfg=""
    if [ "$cf_strict" == "y" ]; then
        if [ ! -f "/etc/nginx/snippets/cf_allow.conf" ]; then
            _update_cloudflare_ips
        fi
        cf_strict_cfg="include /etc/nginx/snippets/cf_allow.conf;"
    fi

    if [[ -z "$port" || "$port" == "null" ]]; then
        log_message ERROR "配置生成失败: 端口为空，请检查项目配置。"
        return 1
    fi

    get_vps_ip

    cat > "$conf" << EOF
server {
    listen 80;
    $( [[ -n "$VPS_IPV6" ]] && echo "listen [::]:80;" )
    server_name ${domain};
    
    # 拦截 Let's Encrypt 验证请求，实现无感知续期
    location /.well-known/acme-challenge/ {
        root ${NGINX_WEBROOT_DIR};
    }
    
    # 其余所有请求强制跳转 HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
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

    # 用户自定义配置与防御策略
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

_remove_and_disable_nginx_config() {
    rm -f "$NGINX_SITES_AVAILABLE_DIR/${1:-}.conf" "$NGINX_SITES_ENABLED_DIR/${1:-}.conf"
}

_view_nginx_config() {
    local domain="${1:-}"
    local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if [ ! -f "$conf" ]; then
        log_message WARN "此项目未生成 Nginx 配置文件 (可能是纯证书模式)。"
        return
    fi
    echo ""
    echo -e "${GREEN}=== 配置文件: $domain ===${NC}"
    cat "$conf"
    echo -e "${GREEN}=======================${NC}"
}

_rebuild_all_nginx_configs() {
    echo ""
    log_message INFO "准备重建所有 HTTP Nginx 配置文件..."
    if ! _confirm_action_or_exit_non_interactive "这将会覆盖当前所有 Nginx HTTP 代理配置文件，是否继续？"; then
        return
    fi
    
    local all_projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
    if [ -z "$all_projects" ]; then
        log_message WARN "没有任何项目记录可供重建。"
        return
    fi
    
    local success=0 fail=0
    
    while read -r p; do
        [ -z "$p" ] && continue
        local d=$(echo "$p" | jq -r .domain)
        local port=$(echo "$p" | jq -r .resolved_port)
        
        if [ "$port" == "cert_only" ]; then continue; fi
        
        log_message INFO "重建配置文件: $d ..."
        if _write_and_enable_nginx_config "$d" "$p"; then
            success=$((success+1))
        else
            fail=$((fail+1))
            log_message ERROR "配置文件重建失败: $d"
        fi
    done <<< "$all_projects"
    
    log_message INFO "正在重载 Nginx 以应用所有新配置..."
    if control_nginx reload; then
        log_message SUCCESS "重建完成。成功: $success, 失败: $fail"
    else
        log_message ERROR "Nginx 重载失败，请检查配置文件语法！"
    fi
}

# ==============================================================================
# SECTION: 数据与 TCP 代理配置 (Stream)
# ==============================================================================

_save_tcp_project_json() {
    local json="${1:-}"
    if [ -z "$json" ]; then return 1; fi
    _snapshot_projects_json "$TCP_PROJECTS_METADATA_FILE"
    
    local port=$(echo "$json" | jq -r .listen_port)
    local temp=$(mktemp)
    
    local existing=$(jq -c --arg p "$port" '.[] | select(.listen_port == $p)' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        jq --argjson new_val "$json" --arg p "$port" \
           'map(if .listen_port == $p then $new_val else . end)' \
           "$TCP_PROJECTS_METADATA_FILE" > "$temp"
    else
        jq --argjson new_val "$json" \
           '. + [$new_val]' \
           "$TCP_PROJECTS_METADATA_FILE" > "$temp"
    fi
    
    if [ $? -eq 0 ]; then mv "$temp" "$TCP_PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}

_write_and_enable_tcp_config() {
    local port="${1:-}"
    local json="${2:-}"
    local conf="$NGINX_STREAM_AVAILABLE_DIR/tcp_${port}.conf"
    
    local target=$(echo "$json" | jq -r .target)
    
    cat > "$conf" << EOF
server {
    listen ${port};
    proxy_pass ${target};
}
EOF
    ln -sf "$conf" "$NGINX_STREAM_ENABLED_DIR/"
}

configure_tcp_proxy() {
    echo -e "\n${CYAN}--- 配置 TCP 代理 (Stream Proxy) ---${NC}"
    local name=$(_prompt_user_input_with_validation "项目备注名称" "MyTCP" "" "" "false") || return
    local l_port=$(_prompt_user_input_with_validation "本机监听端口" "" "^[0-9]+$" "无效端口" "false") || return
    local target=$(_prompt_user_input_with_validation "目标地址 (如 127.0.0.1:3306)" "" "^[a-zA-Z0-9.-]+:[0-9]+$" "格式错误 (需包含端口)" "false") || return
    
    local json=$(jq -n --arg n "$name" --arg lp "$l_port" --arg t "$target" '{name:$n, listen_port:$lp, target:$t}')
    
    if _write_and_enable_tcp_config "$l_port" "$json"; then
        if control_nginx reload; then
            _save_tcp_project_json "$json"
            log_message SUCCESS "TCP 代理已成功配置 ($l_port -> $target)。"
        else
            log_message ERROR "Nginx 重载失败，可能端口已被占用。"
            rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${l_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${l_port}.conf"
            control_nginx reload || true
        fi
    fi
}

manage_tcp_configs() {
    while true; do
        local all=$(jq . "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo "[]")
        local count=$(echo "$all" | jq 'length')
        if [ "$count" -eq 0 ]; then
            log_message WARN "暂无 TCP 项目。"
            break
        fi
        
        echo ""
        printf "${BOLD}%-6s %-15s %-12s %-20s${NC}\n" "ID" "监听端口" "备注" "目标地址"
        echo "────────────────────────────────────────────────────────"
        local idx=0
        echo "$all" | jq -c '.[]' | while read -r p; do
            idx=$((idx + 1))
            local port=$(echo "$p" | jq -r '.listen_port')
            local name=$(echo "$p" | jq -r '.name // "-"')
            local target=$(echo "$p" | jq -r '.target')
            printf "%-6d ${GREEN}%-15s${NC} %-12s %-20s\n" "$idx" "$port" "${name:0:10}" "$target"
        done
        echo ""
        
        local choice_idx=$(_prompt_user_input_with_validation "请输入序号选择 TCP 项目 (回车返回)" "" "^[0-9]*$" "无效序号" "true")
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then break; fi
        if [ "$choice_idx" -gt "$count" ]; then log_message ERROR "序号越界"; continue; fi
        
        local selected_port=$(echo "$all" | jq -r ".[$((choice_idx-1))].listen_port")
        
        _render_menu "管理 TCP 代理: 端口 $selected_port" "1. 删除项目" "2. 查看配置"
        case "$(_prompt_for_menu_choice_local "1-2" "true")" in
            1) 
                if _confirm_action_or_exit_non_interactive "确认删除 TCP 代理 $selected_port？"; then
                    rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${selected_port}.conf"
                    _snapshot_projects_json "$TCP_PROJECTS_METADATA_FILE"
                    local temp=$(mktemp)
                    jq --arg p "$selected_port" 'del(.[] | select(.listen_port == $p))' "$TCP_PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$TCP_PROJECTS_METADATA_FILE"
                    control_nginx reload
                    log_message SUCCESS "删除成功。"
                fi ;;
            2)
                cat "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" 2>/dev/null || echo "配置文件不存在"
                press_enter_to_continue ;;
            "") continue ;;
        esac
    done
}

# ==============================================================================
# SECTION: 业务逻辑 (证书申请与主流程)
# ==============================================================================

_issue_and_install_certificate() {
    local json="${1:-}"
    if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
        log_message WARN "未收到有效配置信息，流程中止。"
        return 1
    fi

    local domain=$(echo "$json" | jq -r .domain)
    if [[ -z "$domain" || "$domain" == "null" ]]; then
        log_message ERROR "内部错误: 域名为空。"
        return 1
    fi

    local method=$(echo "$json" | jq -r .acme_validation_method)
    local provider=$(echo "$json" | jq -r .dns_api_provider)
    local wildcard=$(echo "$json" | jq -r .use_wildcard)
    local ca=$(echo "$json" | jq -r .ca_server_url)
    
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key="$SSL_CERTS_BASE_DIR/$domain.key"

    log_message INFO "正在为 $domain 申请证书 ($method)..."
    
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca" --log)
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    local temp_conf_created="false"
    local temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"

    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                local saved_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local saved_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local use_saved="false"
                if [[ -n "$saved_t" && -n "$saved_a" ]]; then
                    log_message INFO "检测到 acme.sh 已保存 Cloudflare 凭证 (Token: $(_mask_string "$saved_t"))"
                    if _confirm_action_or_exit_non_interactive "是否直接复用已保存的凭证？"; then use_saved="true"; fi
                fi
                if [ "$use_saved" = "false" ]; then
                    local t=$(_prompt_secret "请输入新的 CF_Token"); local a=$(_prompt_secret "请输入新的 Account_ID")
                    [ -n "$t" ] && export CF_Token="$t"; [ -n "$a" ] && export CF_Account_ID="$a"
                fi
            fi
        elif [ "$provider" = "dns_ali" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                local saved_k=$(grep "^SAVED_Ali_Key=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local saved_s=$(grep "^SAVED_Ali_Secret=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local use_saved="false"
                if [[ -n "$saved_k" && -n "$saved_s" ]]; then
                    log_message INFO "检测到 acme.sh 已保存 Aliyun 凭证 (Key: $(_mask_string "$saved_k"))"
                    if _confirm_action_or_exit_non_interactive "是否直接复用已保存的凭证？"; then use_saved="true"; fi
                fi
                if [ "$use_saved" = "false" ]; then
                    local k=$(_prompt_secret "请输入新的 Ali_Key"); local s=$(_prompt_secret "请输入新的 Ali_Secret")
                    [ -n "$k" ] && export Ali_Key="$k"; [ -n "$s" ] && export Ali_Secret="$s"
                fi
            fi
        fi
        cmd+=("--dns" "$provider")
    elif [ "$method" = "http-01" ]; then
        local port_conflict="false"
        local temp_svc=""
        
        if ss -tuln 2>/dev/null | grep -qE ':(80|443)\s'; then
            temp_svc=$(_detect_web_service)
            if [ "$temp_svc" = "nginx" ]; then
                log_message INFO "检测到 Nginx 已运行，启动无中断 Webroot 模式。"
                if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
                    cat > "$temp_conf" <<EOF
server {
    listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; }
}
EOF
                    ln -sf "$temp_conf" "$NGINX_SITES_ENABLED_DIR/"
                    systemctl reload nginx || true
                    temp_conf_created="true"
                fi
                mkdir -p "$NGINX_WEBROOT_DIR"
                cmd+=("--webroot" "$NGINX_WEBROOT_DIR")
            else
                log_message WARN "检测到 80 端口被 $temp_svc 占用 (无法使用 Webroot 模式)。"
                if [ "$IS_INTERACTIVE_MODE" = "false" ]; then
                    port_conflict="true"
                    log_message INFO "Cron 模式: 临时停止 $temp_svc 以释放端口。"
                else
                    if _confirm_action_or_exit_non_interactive "是否临时停止 $temp_svc 以释放端口? (续期后自动启动)"; then port_conflict="true"; fi
                fi
                
                if [ "$port_conflict" == "true" ]; then
                    log_message INFO "停止 $temp_svc ..."
                    systemctl stop "$temp_svc"
                    trap "echo; log_message WARN '检测到中断，正在恢复 $temp_svc ...'; systemctl start $temp_svc; cleanup_temp_files; exit 130" INT TERM
                fi
                cmd+=("--standalone")
            fi
        else
            cmd+=("--standalone")
        fi
    fi

    local log_temp=$(mktemp)
    echo -ne "${YELLOW}正在通信 (约 30-60 秒，请勿中断)... ${NC}"
    "${cmd[@]}" > "$log_temp" 2>&1 &
    local pid=$!
    local spinstr='|/-\'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.2
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    wait $pid
    local ret=$?

    if [ "$temp_conf_created" == "true" ]; then
        rm -f "$temp_conf" "$NGINX_SITES_ENABLED_DIR/temp_acme_${domain}.conf"
        systemctl reload nginx || true
    fi

    if [ $ret -ne 0 ]; then
        echo -e "\n"
        log_message ERROR "申请失败: $domain"
        cat "$log_temp"
        local err_log=$(cat "$log_temp")
        rm -f "$log_temp"
        
        if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then
            log_message INFO "重启 $temp_svc ..."
            systemctl start "$temp_svc"
            trap _on_exit INT TERM
        fi
        
        if [[ "$err_log" == *"retryafter"* ]]; then
            echo -e "\n${RED}检测到 CA 限制 (retryafter)${NC}"
            if _confirm_action_or_exit_non_interactive "是否切换 CA 到 Let's Encrypt 并重试?"; then
                "$ACME_BIN" --set-default-ca --server letsencrypt
                json=$(echo "$json" | jq '.ca_server_url = "https://acme-v02.api.letsencrypt.org/directory"')
                _issue_and_install_certificate "$json"
                return $?
            fi
        fi
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    rm -f "$log_temp"

    if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then
        systemctl start "$temp_svc"
        trap _on_exit INT TERM
    fi

    log_message INFO "证书签发成功，安装中..."
    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --reloadcmd "systemctl reload nginx" --log)
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    
    if ! "${inst[@]}"; then 
        log_message ERROR "安装失败: $domain"
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret
    return 0
}

_gather_project_details() {
    exec 3>&1
    exec 1>&2
    
    local cur="${1:-{\}}"
    local skip_cert="${2:-false}"
    local is_cert_only="false"
    if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local domain=$(echo "$cur" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        domain=$(_prompt_user_input_with_validation "主域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式无效，请输入正确的域名" "false") || { exec 1>&3; return 1; }
    fi
    
    local type="cert_only"; local name="证书"; local port="cert_only"
    local max_body=$(echo "$cur" | jq -r '.client_max_body_size // empty')
    local custom_cfg=$(echo "$cur" | jq -r '.custom_config // empty')
    local cf_strict=$(echo "$cur" | jq -r '.cf_strict_mode // "n"')

    if [ "$is_cert_only" == "false" ]; then
        name=$(echo "$cur" | jq -r '.name // ""')
        [ "$name" == "证书" ] && name=""
        
        while true; do
            local target=$(_prompt_user_input_with_validation "后端目标 (容器名/端口)" "$name" "" "" "false") || { exec 1>&3; return 1; }
            type="local_port"; port="$target"
            local is_docker="false"
            if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
                type="docker"; exec 1>&3
                port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)
                exec 1>&2
                is_docker="true"
                if [ -z "$port" ]; then port=$(_prompt_user_input_with_validation "未检测到端口，手动输入" "80" "^[0-9]+$" "无效端口" "false") || { exec 1>&3; return 1; }; fi
                break
            fi
            if [[ "$port" =~ ^[0-9]+$ ]]; then break; fi
            log_message ERROR "错误: '$target' 既不是容器也不是端口，请重试。" >&2
        done
    fi

    local method="http-01"; local provider=""; local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"; local ca_name="letsencrypt"

    if [ "$skip_cert" == "true" ]; then
        method=$(echo "$cur" | jq -r '.acme_validation_method // "http-01"')
        provider=$(echo "$cur" | jq -r '.dns_api_provider // ""')
        wildcard=$(echo "$cur" | jq -r '.use_wildcard // "n"')
        ca_server=$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')
        ca_name=$(echo "$cur" | jq -r '.ca_server_name // "letsencrypt"')
    else
        local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
        _render_menu "选择 CA 机构" "${ca_list[@]}"
        local ca_choice
        while true; do
            ca_choice=$(_prompt_for_menu_choice_local "1-3")
            [ -n "$ca_choice" ] && break
        done
        case "$ca_choice" in
            1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
            2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;;
            3) ca_server="google"; ca_name="google" ;;
        esac
        
        local -a method_display=(
            "1. http-01 (智能无中断 Webroot / Standalone)" 
            "2. dns_cf  (Cloudflare API, 无视CDN限制)" 
            "3. dns_ali (阿里云 API, 无视CDN限制)"
        )
        _render_menu "验证方式" "${method_display[@]}" >&2
        local v_choice
        while true; do
            v_choice=$(_prompt_for_menu_choice_local "1-3")
            [ -n "$v_choice" ] && break
        done
        
        case "$v_choice" in
            1) method="http-01" ;;
            2|3)
                method="dns-01"
                [ "$v_choice" = "2" ] && provider="dns_cf" || provider="dns_ali"
                wildcard=$(_prompt_user_input_with_validation "是否申请泛域名? (y/[n])" "n" "^[yYnN]$" "" "false") ;;
        esac
    fi

    if [ "$is_cert_only" == "false" ]; then
        if [ "$provider" == "dns_cf" ] || _confirm_action_or_exit_non_interactive "是否开启 Cloudflare 严格安全防御 (仅允许 CF 节点访问，防真实IP被扫)?"; then
            cf_strict="y"
        else
            cf_strict="n"
        fi
    fi

    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"
    local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    
    jq -n \
        --arg d "${domain:-}" --arg t "${type:-local_port}" --arg n "${name:-}" --arg p "${port:-}" \
        --arg m "${method:-http-01}" --arg dp "${provider:-}" --arg w "${wildcard:-n}" \
        --arg cu "${ca_server:-}" --arg cn "${ca_name:-}" --arg cf "${cf:-}" --arg kf "${kf:-}" \
        --arg mb "${max_body:-}" --arg cc "${custom_cfg:-}" --arg cs "${cf_strict:-n}" \
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf, client_max_body_size:$mb, custom_config:$cc, cf_strict_mode:$cs}' >&3
    
    exec 1>&3
}

_display_projects_list() {
    local json="${1:-}" 
    if [ -z "$json" ] || [ "$json" == "[]" ]; then echo "暂无数据"; return; fi
    
    printf "${BOLD}%-4s %-10s %-12s %-20s %-s${NC}\n" "ID" "状态" "续期" "目标" "域名"
    echo "──────────────────────────────────────────────────────────────────────"
    
    local idx=0
    echo "$json" | jq -c '.[]' | while read -r p; do
        idx=$((idx + 1))
        local domain=$(echo "$p" | jq -r '.domain // "未知"')
        local type=$(echo "$p" | jq -r '.type')
        local port=$(echo "$p" | jq -r '.resolved_port')
        local cert=$(echo "$p" | jq -r '.cert_file')
        
        local target_str="Port:$port"
        [ "$type" = "docker" ] && target_str="Docker:$port"
        [ "$port" == "cert_only" ] && target_str="CertOnly"
        
        local status_str="缺失  "; local status_color="$RED"; local renew_date="-"
        local conf_file="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
        [ ! -f "$conf_file" ] && conf_file="$HOME/.acme.sh/${domain}/${domain}.conf"
        if [ -f "$conf_file" ]; then
            local next_ts=$(grep "^Le_NextRenewTime=" "$conf_file" | cut -d= -f2- | tr -d "'\"")
            if [ -n "$next_ts" ]; then renew_date=$(date -d "@$next_ts" +%F 2>/dev/null || echo "Err"); fi
        fi

        if [[ -f "$cert" ]]; then
            local end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            local ts=$(date -d "$end" +%s 2>/dev/null || echo 0)
            local days=$(( (ts - $(date +%s)) / 86400 ))
            if (( days < 0 )); then status_str="已过期"; status_color="$RED"
            elif (( days <= 30 )); then status_str="将过期"; status_color="$YELLOW"
            else status_str="运行中"; status_color="$GREEN"
            fi
        else
            status_str="未安装"
        fi
        
        printf "%-4d ${status_color}%-10s${NC} %-12s %-20s %-s\n" "$idx" "$status_str" "$renew_date" "${target_str:0:20}" "${domain}"
    done
    echo ""
}

_draw_dashboard() {
    local nginx_v=$(nginx -v 2>&1 | awk -F/ '{print $2}' | cut -d' ' -f1) 
    local uptime_raw=$(uptime -p | sed 's/up //')
    if [ ${#uptime_raw} -gt 45 ]; then uptime_raw="${uptime_raw:0:42}..."; fi
    
    local count=$(jq '. | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    local tcp_count=$(jq '. | length' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    local warn_count=0
    if [ -f "$PROJECTS_METADATA_FILE" ]; then
        warn_count=$(jq '[.[] | select(.cert_file) | select(.cert_file | test(".cer$"))] | length' "$PROJECTS_METADATA_FILE")
    fi
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs | cut -d, -f1-3)

    local title="Nginx 管理面板 v4.21.0"
    
    echo ""
    echo -e "${GREEN}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${GREEN}│${NC}                         ${BOLD}${title}${NC}                         ${GREEN}│${NC}"
    echo -e "${GREEN}╰────────────────────────────────────────────────────────────────────────╯${NC}"
    
    echo -e " Nginx: ${GREEN}${nginx_v}${NC} | 运行: ${GREEN}${uptime_raw}${NC} | 负载: ${YELLOW}${load}${NC}"
    echo -e " HTTP : ${BOLD}${count}${NC} 个 | TCP : ${BOLD}${tcp_count}${NC} 个 | 告警 : ${RED}${warn_count}${NC}"
    
    echo -e "${GREEN}──────────────────────────────────────────────────────────────────────────${NC}"
}

manage_configs() {
    while true; do
        local all=$(jq . "$PROJECTS_METADATA_FILE")
        local count=$(echo "$all" | jq 'length')
        if [ "$count" -eq 0 ]; then log_message WARN "暂无项目。"; break; fi
        
        echo ""
        _display_projects_list "$all"
        
        local choice_idx=$(_prompt_user_input_with_validation "请输入序号选择项目 (回车返回)" "" "^[0-9]*$" "无效序号" "true")
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then break; fi
        if [ "$choice_idx" -gt "$count" ]; then log_message ERROR "序号越界"; continue; fi
        
        local selected_domain=$(echo "$all" | jq -r ".[$((choice_idx-1))].domain")
        
        _render_menu "管理: $selected_domain" "1. 查看证书详情" "2. 手动续期" "3. 删除项目" "4. 查看配置" "5. 查看日志" "6. 重新配置" "7. 设置上传限制" "8. 添加自定义指令"
        case "$(_prompt_for_menu_choice_local "1-8" "true")" in
            1) _handle_cert_details "$selected_domain" ;;
            2) _handle_renew_cert "$selected_domain" ;;
            3) _handle_delete_project "$selected_domain"; break ;; 
            4) _handle_view_config "$selected_domain" ;;
            5) _view_project_access_log "$selected_domain" ;;
            6) _handle_reconfigure_project "$selected_domain" ;;
            7) _handle_set_max_body_size "$selected_domain" ;;
            8) _handle_set_custom_config "$selected_domain" ;;
            "") continue ;;
        esac
    done
}

_handle_renew_cert() {
    local d="${1:-}"; local p=$(_get_project_json "$d")
    [ -z "$p" ] && { log_message ERROR "项目不存在"; return; }
    _issue_and_install_certificate "$p" && control_nginx reload; press_enter_to_continue
}

_handle_delete_project() {
    local d="${1:-}"
    if _confirm_action_or_exit_non_interactive "确认彻底删除 $d 及其证书？"; then
        _remove_and_disable_nginx_config "$d"
        "$ACME_BIN" --remove -d "$d" --ecc >/dev/null 2>&1 || true
        rm -f "$SSL_CERTS_BASE_DIR/$d.cer" "$SSL_CERTS_BASE_DIR/$d.key"
        _delete_project_json "$d"
        control_nginx reload
    fi
    press_enter_to_continue
}

_handle_view_config() { _view_nginx_config "${1:-}"; press_enter_to_continue; }

_handle_reconfigure_project() {
    local d="${1:-}"; local cur=$(_get_project_json "$d")
    log_message INFO "正在重配 $d ..."
    local port=$(echo "$cur" | jq -r .resolved_port); local mode=""
    [ "$port" == "cert_only" ] && mode="cert_only"

    local skip_cert="true"
    if _confirm_action_or_exit_non_interactive "是否重新申请/续期证书 (Renew Cert)?"; then skip_cert="false"; fi

    local new; if ! new=$(_gather_project_details "$cur" "$skip_cert" "$mode"); then log_message WARN "重配取消。"; return; fi
    if [ "$skip_cert" == "false" ]; then
        if ! _issue_and_install_certificate "$new"; then log_message ERROR "证书申请失败，重配终止。"; return 1; fi
    fi

    if [ "$mode" != "cert_only" ]; then _write_and_enable_nginx_config "$d" "$new"; fi
    control_nginx reload && _save_project_json "$new" && log_message SUCCESS "重配成功"; press_enter_to_continue
}

_handle_set_max_body_size() {
    local d="${1:-}"; local cur=$(_get_project_json "$d"); local current_val=$(echo "$cur" | jq -r '.client_max_body_size // "默认(1m)"')
    echo -e "\n${CYAN}当前设置: $current_val${NC}\n请输入新的限制大小 (例如: 10m, 500m, 1g)。直接回车不修改; 输入 'default' 恢复 Nginx 默认"
    local new_val=$(_prompt_user_input_with_validation "限制大小" "" "^[0-9]+[kKmMgG]$|^default$" "格式错误" "true")
    if [ -z "$new_val" ]; then return; fi
    local json_val="$new_val"; [ "$new_val" == "default" ] && json_val=""
    local new_json=$(echo "$cur" | jq --arg v "$json_val" '.client_max_body_size = $v')
    
    if _save_project_json "$new_json"; then
        _write_and_enable_nginx_config "$d" "$new_json"
        control_nginx reload && log_message SUCCESS "更新 $d 上传限制 -> ${json_val:-默认}。"
    fi
    press_enter_to_continue
}

_handle_set_custom_config() {
    local d="${1:-}"; local cur=$(_get_project_json "$d"); local current_val=$(echo "$cur" | jq -r '.custom_config // "无"')
    echo -e "\n${CYAN}当前自定义配置:${NC}\n$current_val\n${YELLOW}请输入完整的 Nginx 指令 (需以分号结尾)。直接回车不修改; 输入 'clear' 清空${NC}"
    local new_val=$(_prompt_user_input_with_validation "指令内容" "" "" "" "true")
    if [ -z "$new_val" ]; then return; fi
    local json_val="$new_val"; [ "$new_val" == "clear" ] && json_val=""
    local new_json=$(echo "$cur" | jq --arg v "$json_val" '.custom_config = $v')
    
    if _save_project_json "$new_json"; then
        _write_and_enable_nginx_config "$d" "$new_json"
        if control_nginx reload; then
            log_message SUCCESS "自定义配置已应用。"
        else
            log_message ERROR "Nginx 重载失败！回滚配置..."
            _write_and_enable_nginx_config "$d" "$cur"; control_nginx reload
        fi
    fi
    press_enter_to_continue
}

_handle_cert_details() {
    local cert="$SSL_CERTS_BASE_DIR/${1:-}.cer"
    if [ -f "$cert" ]; then
        echo -e "${CYAN}--- 证书详情 ---${NC}"
        openssl x509 -in "$cert" -noout -text | grep -E "Issuer:|Not After|Subject:|DNS:"
        echo -e "${CYAN}----------------${NC}"
    else
        log_message ERROR "证书文件不存在。"
    fi
    press_enter_to_continue
}

check_and_auto_renew_certs() {
    log_message INFO "正在检查所有证书..."
    local success=0 fail=0
    
    # 自动更新 CF IP 防火墙列表，确保严格模式始终放行正确的源
    if [ -f "/etc/nginx/snippets/cf_allow.conf" ]; then
        _update_cloudflare_ips
    fi
    
    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r p; do
        local d=$(echo "$p" | jq -r .domain); local f=$(echo "$p" | jq -r .cert_file)
        echo -ne "检查: $d ... "
        if [ ! -f "$f" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$f"; then
            echo -e "${YELLOW}即将到期，开始续期...${NC}"
            if _issue_and_install_certificate "$p"; then 
                success=$((success+1)); echo -e "   ${GREEN}续期成功${NC}"
            else 
                fail=$((fail+1)); echo -e "   ${RED}续期失败 (查看日志)${NC}"
            fi
        else
            echo -e "${GREEN}有效期充足${NC}"
        fi
    done
    control_nginx reload
    log_message INFO "批量续期结果: $success 成功, $fail 失败。"
}

configure_nginx_projects() {
    local mode="${1:-standard}"; local json
    echo -e "\n${CYAN}开始配置新项目...${NC}"
    if ! json=$(_gather_project_details "{}" "false" "$mode"); then log_message WARN "用户取消配置。"; return; fi
    if ! _issue_and_install_certificate "$json"; then log_message ERROR "证书申请失败，未保存。"; return; fi
    
    if [ "$mode" != "cert_only" ]; then
        local domain=$(echo "$json" | jq -r .domain)
        if _write_and_enable_nginx_config "$domain" "$json"; then
            control_nginx reload; log_message SUCCESS "配置已生成并加载。"
        else
            log_message ERROR "Nginx 配置生成失败。"; return
        fi
    fi
    _save_project_json "$json"
    log_message SUCCESS "配置已保存。"
    
    local domain=$(echo "$json" | jq -r .domain)
    [ "$mode" != "cert_only" ] && echo -e "\n网站已上线: https://${domain}" || echo -e "\n证书已就绪: /etc/ssl/${domain}.cer"
}

main_menu() {
    while true; do
        _draw_dashboard
        
        echo -e "${PURPLE}【HTTP(S) 业务】${NC}"
        echo -e " 1. 配置新域名反代 (New HTTP Proxy)"
        echo -e " 2. HTTP 项目管理 (Manage HTTP)"
        echo -e " 3. 仅申请证书 (Cert Only)"
        echo ""
        echo -e "${PURPLE}【TCP 负载均衡】${NC}"
        echo -e " 4. 配置 TCP 反向代理 (New Stream Proxy)"
        echo -e " 5. 管理 TCP 反向代理 (Manage Stream)"
        echo ""
        echo -e "${PURPLE}【运维监控与系统维护】${NC}"
        echo -e " 6. 批量续期 (Auto Renew All)"
        echo -e " 7. 查看日志 (Logs - Nginx/acme)"
        echo -e " 8. 更新 Cloudflare 严格防御 IP 库"
        echo -e " 9. 备份/还原与配置重建 (Backup & Rebuild)"
        
        echo ""
        case "$(_prompt_for_menu_choice_local "1-9" "true")" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) manage_configs ;;
            3) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            4) configure_tcp_proxy; press_enter_to_continue ;;
            5) manage_tcp_configs ;;
            6) 
                if _confirm_action_or_exit_non_interactive "确认检查所有项目？"; then
                    check_and_auto_renew_certs; press_enter_to_continue
                fi ;;
            7) 
                _render_menu "查看日志" "1. Nginx 全局" "2. acme.sh 运行"
                case "$(_prompt_for_menu_choice_local "1-2" "true")" in
                    1) _view_nginx_global_log; press_enter_to_continue ;;
                    2) _view_acme_log; press_enter_to_continue ;;
                esac ;;
            8) _update_cloudflare_ips; press_enter_to_continue ;;
            9) 
                _render_menu "维护选项" "1. 备份与恢复面板" "2. 重建所有 HTTP 配置" "3. 修复定时任务"
                case "$(_prompt_for_menu_choice_local "1-3" "true")" in
                    1) _handle_backup_restore ;;
                    2) _rebuild_all_nginx_configs; press_enter_to_continue ;;
                    3) _manage_cron_jobs; press_enter_to_continue ;;
                esac ;;
            "") return 0 ;;
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

trap '_on_exit' INT TERM
if ! check_root; then exit 1; fi

check_os_compatibility
install_dependencies 
initialize_environment

if [[ " $* " =~ " --cron " ]]; then check_and_auto_renew_certs; exit $?; fi

install_acme_sh && main_menu
exit $?
