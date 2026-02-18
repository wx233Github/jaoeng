# =============================================================
# Nginx 反向代理 + HTTPS 证书管理助手 (v4.17.2-中文面板优化版)
# =============================================================
# 作者：Shell 脚本专家
# 描述：自动化管理 Nginx 反代配置与 SSL 证书，优化中文面板 UI
# 版本历史：
#   v4.17.2 - 汉化标题，优化盒子对齐，移除自动清屏
#   v4.17.1 - 优化仪表盘 UI 为盒子风格，彻底移除 Emoji

set -euo pipefail

# --- 全局变量 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m'; PURPLE='\033[0;35m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
BACKUP_DIR="/root/nginx_ssl_backups"
RENEW_THRESHOLD_DAYS=30
DEPS_MARK_FILE="$HOME/.nginx_ssl_manager_deps_v2"

NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
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
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level^^}] ${message}" >> "$LOG_FILE"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }

_prompt_for_menu_choice_local() {
    local range="${1:-}"
    local allow_empty="${2:-false}"
    local prompt_text="${ORANGE}选项 [${range}]${NC} (Enter 返回): "
    local choice
    while true; do
        read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then echo ""; return; fi
            echo -e "${YELLOW}请选择一个选项。${NC}" >&2
            continue
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then echo "$choice"; return; fi
    done
}

generate_line() {
    local len=${1:-40}; printf "%${len}s" "" | sed "s/ /─/g"
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

_render_menu() {
    local title="${1:-菜单}"; shift; 
    local title_vis_len=$(_str_width "$title")
    local min_width=50
    local box_width=$min_width
    if [ "$title_vis_len" -gt "$((min_width - 4))" ]; then
        box_width=$((title_vis_len + 6))
    fi

    echo ""
    echo -e "${GREEN}╭$(generate_line "$box_width")╮${NC}"
    local pad_total=$((box_width - title_vis_len))
    local pad_left=$((pad_total / 2))
    local pad_right=$((pad_total - pad_left))
    echo -e "${GREEN}│${NC}$(printf "%${pad_left}s" "")${BOLD}${title}${NC}$(printf "%${pad_right}s" "")${GREEN}│${NC}"
    echo -e "${GREEN}╰$(generate_line "$box_width")╯${NC}"
    
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
            read -r val
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

_confirm_action_or_exit_non_interactive() {
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local c; read -r -p "$(echo -e "${YELLOW}${1} ([y]/n): ${NC}")" c < /dev/tty
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
# SECTION: 环境初始化
# ==============================================================================

initialize_environment() {
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
    if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
    export PATH="$(dirname "$ACME_BIN"):$PATH"
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR" "$BACKUP_DIR"
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then echo "[]" > "$PROJECTS_METADATA_FILE"; fi
}

install_dependencies() {
    if [ -f "$DEPS_MARK_FILE" ]; then return 0; fi
    local deps="nginx curl socat openssl jq idn dnsutils nano wc"
    local missing=0
    for pkg in $deps; do
        if ! command -v "$pkg" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null; then
            log_message WARN "缺失: $pkg，安装中..."
            if [ "$missing" -eq 0 ]; then apt update -y >/dev/null 2>&1; fi
            apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "安装 $pkg 失败"; return 1; }
            missing=1
        fi
    done
    touch "$DEPS_MARK_FILE"
    [ "$missing" -eq 1 ] && log_message SUCCESS "依赖就绪。"
    return 0
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then 
        "$ACME_BIN" --upgrade --auto-upgrade >/dev/null 2>&1 || true
        return 0
    fi
    log_message WARN "acme.sh 未安装，开始安装..."
    local email; email=$(_prompt_user_input_with_validation "注册邮箱" "" "" "" "true")
    local cmd="curl https://get.acme.sh | sh"
    [ -n "$email" ] && cmd+=" -s email=$email"
    if eval "$cmd"; then 
        initialize_environment
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

_get_nginx_status() {
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}Nginx (运行中)${NC}"
    else
        echo -e "${RED}Nginx (已停止)${NC}"
    fi
}

_restart_nginx_ui() {
    log_message INFO "正在重启 Nginx..."
    if control_nginx restart; then log_message SUCCESS "Nginx 重启成功。"; fi
}

_view_file_with_tail() {
    local file="${1:-}"
    if [ ! -f "$file" ]; then
        log_message ERROR "文件不存在: $file"
        return
    fi
    echo -e "${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}"
    trap ':' INT
    tail -f -n 50 "$file" || true
    trap _on_exit INT
    echo -e "\n${CYAN}--- 日志查看结束 ---${NC}"
}

_view_acme_log() {
    local log_file="$HOME/.acme.sh/acme.sh.log"
    if [ ! -f "$log_file" ]; then log_file="/root/.acme.sh/acme.sh.log"; fi
    if [ ! -f "$log_file" ]; then
        touch "$log_file"
        echo "日志文件已初始化。" > "$log_file"
    fi
    _view_file_with_tail "$log_file"
}

_view_nginx_global_log() {
    echo ""
    _render_menu "Nginx 全局日志" "1. 访问日志 (Access Log)" "2. 错误日志 (Error Log)"
    local c=$(_prompt_for_menu_choice_local "1-2" "true")
    local log_path=""
    case "$c" in
        1) log_path="$NGINX_ACCESS_LOG" ;;
        2) log_path="$NGINX_ERROR_LOG" ;;
        *) return ;;
    esac
    _view_file_with_tail "$log_path"
}

_view_project_access_log() {
    local domain="${1:-}"
    if [ ! -f "$NGINX_ACCESS_LOG" ]; then
        log_message ERROR "全局访问日志不存在: $NGINX_ACCESS_LOG"
        return
    fi
    echo -e "${CYAN}--- 实时访问日志: $domain (Ctrl+C 退出) ---${NC}"
    echo -e "${YELLOW}正在 grep 全局日志...${NC}"
    trap ':' INT
    tail -f "$NGINX_ACCESS_LOG" | grep --line-buffered "$domain" || true
    trap _on_exit INT
    echo -e "\n${CYAN}--- 日志查看结束 ---${NC}"
}

# ==============================================================================
# SECTION: 备份与还原 (Backup & Restore)
# ==============================================================================

_handle_backup_restore() {
    echo ""
    _render_menu "备份与还原系统" \
        "1. 创建新备份 (Projects + Configs + Certs)" \
        "2. 从备份还原" \
        "3. 查看备份目录"
        
    case "$(_prompt_for_menu_choice_local "1-3" "true")" in
        1)
            local ts=$(date +%Y%m%d_%H%M%S)
            local backup_file="$BACKUP_DIR/nginx_manager_backup_$ts.tar.gz"
            log_message INFO "正在打包备份..."
            # 备份列表: projects.json, Nginx 配置, SSL 证书目录
            if tar -czf "$backup_file" -C / "$PROJECTS_METADATA_FILE" "$NGINX_SITES_AVAILABLE_DIR" "$SSL_CERTS_BASE_DIR" 2>/dev/null; then
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
        *) return ;;
    esac
    press_enter_to_continue
}

# ==============================================================================
# SECTION: 数据与文件管理
# ==============================================================================

_get_project_json() { 
    jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""
}

_save_project_json() {
    local json="${1:-}" 
    if [ -z "$json" ]; then return 1; fi
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
    
    local body_cfg=""
    if [[ -n "$max_body" && "$max_body" != "null" ]]; then
        body_cfg="client_max_body_size ${max_body};"
    fi
    
    local extra_cfg=""
    if [[ -n "$custom_cfg" && "$custom_cfg" != "null" ]]; then
        extra_cfg="$custom_cfg"
    fi

    if [[ -z "$port" || "$port" == "null" ]]; then
        log_message ERROR "配置生成失败: 端口为空，请检查项目配置。"
        return 1
    fi

    get_vps_ip

    if [ -z "${domain:-}" ]; then
        log_message ERROR "内部错误：生成配置时域名未定义。"
        return 1
    fi

    cat > "$conf" << EOF
server {
    listen 80;
    $( [[ -n "$VPS_IPV6" ]] && echo "listen [::]:80;" )
    server_name ${domain};
    return 301 https://\$host\$request_uri;
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

    # 用户自定义配置
    ${body_cfg}
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

# ==============================================================================
# SECTION: 业务逻辑 (证书申请)
# ==============================================================================

_get_cert_files() {
    local domain="${1:-}"
    CERT_FILE="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    CONF_FILE="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
    if [ ! -f "$CERT_FILE" ]; then
        CERT_FILE="$HOME/.acme.sh/${domain}/fullchain.cer"
        CONF_FILE="$HOME/.acme.sh/${domain}/${domain}.conf"
    fi
}

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

    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                log_message INFO "请输入 Cloudflare Token (仅内存暂存)"
                local def_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
                local t=$(_prompt_user_input_with_validation "CF_Token" "$def_t" "" "不能为空" "false")
                local def_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
                local a=$(_prompt_user_input_with_validation "Account_ID" "$def_a" "" "不能为空" "false")
                export CF_Token="$t" CF_Account_ID="$a"
            fi
        elif [ "$provider" = "dns_ali" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                log_message INFO "请输入 Aliyun Key (仅内存暂存)"
                local def_k=$(grep "^SAVED_Ali_Key=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
                local k=$(_prompt_user_input_with_validation "Ali_Key" "$def_k" "" "不能为空" "false")
                local def_s=$(grep "^SAVED_Ali_Secret=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
                local s=$(_prompt_user_input_with_validation "Ali_Secret" "$def_s" "" "不能为空" "false")
                export Ali_Key="$k" Ali_Secret="$s"
            fi
        fi
        cmd+=("--dns" "$provider")
    elif [ "$method" = "http-01" ]; then
        local port_conflict="false"
        local temp_svc=""
        if run_with_sudo ss -tuln | grep -q ":80\s"; then
            log_message WARN "检测到 80 端口占用 (Standalone 模式可能失败)。"
            temp_svc=$(_detect_web_service)
            if [ -n "$temp_svc" ]; then
                log_message INFO "发现服务: $temp_svc"
                if [ "$IS_INTERACTIVE_MODE" = "false" ]; then
                    port_conflict="true"
                    log_message INFO "Cron 模式自动操作: 临时停止 $temp_svc 以释放端口。"
                else
                    if _confirm_action_or_exit_non_interactive "是否临时停止 $temp_svc 以释放端口? (续期后自动启动)"; then
                        port_conflict="true"
                    fi
                fi
            else
                log_message WARN "无法识别服务，请手动检查。"
            fi
        fi
        
        if [ "$port_conflict" == "true" ]; then
            log_message INFO "停止 $temp_svc ..."
            systemctl stop "$temp_svc"
            trap "echo; log_message WARN '检测到中断，正在恢复 $temp_svc ...'; systemctl start $temp_svc; cleanup_temp_files; exit 130" INT TERM
        fi
        
        cmd+=("--standalone")
    fi

    local log_temp=$(mktemp)
    echo -ne "${YELLOW}正在与 CA 服务器通信 (约 30-60 秒，请勿中断)... ${NC}"
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
                log_message INFO "正在切换默认 CA ..."
                "$ACME_BIN" --set-default-ca --server letsencrypt
                json=$(echo "$json" | jq '.ca_server_url = "https://acme-v02.api.letsencrypt.org/directory"')
                log_message INFO "正在重试申请..."
                _issue_and_install_certificate "$json"
                return $?
            fi
        fi

        # ==================== 智能诊断模块 ====================
        echo -e "\n${YELLOW}--- 智能故障诊断助手 ---${NC}"
        local diag_found="false"

        if command -v dig >/dev/null; then
            local aaaa_rec=$(dig AAAA +short "$domain" 2>/dev/null | head -n 1)
            if [ -n "$aaaa_rec" ]; then
                echo -e "${ORANGE}检测到 IPv6 (AAAA) 记录: $aaaa_rec${NC}"
                echo -e "Let's Encrypt 优先通过 IPv6 验证。如果本机未配置 IPv6 或防火墙未放行，验证必挂。"
                echo -e "建议: 在 DNS 解析处暂时删除 AAAA 记录，仅保留 A 记录。"
                diag_found="true"
            fi
        fi

        if [[ "$err_log" == *"Cloudflare"* ]] || (command -v dig >/dev/null && dig +short "$domain" | grep -qE "^172\.|^104\."); then
            echo -e "${ORANGE}检测到 Cloudflare CDN 特征${NC}"
            echo -e "HTTP-01 验证无法穿透 CDN 防护模式。"
            echo -e "建议: 请在 Cloudflare 控制台将小黄云 (Proxy) 关闭，改为 '仅DNS' (灰云)。"
            diag_found="true"
        fi

        if [[ "$err_log" == *"Connection refused"* ]]; then
             echo -e "${RED}连接被拒绝 (Connection refused)${NC}"
             echo -e "建议: 检查 80 端口是否开放 (ufw/安全组)，或 Nginx 是否正在运行。"
             diag_found="true"
        elif [[ "$err_log" == *"Timeout"* ]]; then
             echo -e "${RED}连接超时 (Timeout)${NC}"
             echo -e "建议: 检查防火墙是否拦截了海外 IP (Let's Encrypt 服务器主要在海外)。"
             diag_found="true"
        elif [[ "$err_log" == *"404 Not Found"* ]]; then
             echo -e "${RED}404 Not Found${NC}"
             echo -e "验证文件无法被访问。如果是 Standalone 模式，确保 80 端口未被其他服务占用。"
             diag_found="true"
        fi

        if [ "$diag_found" == "false" ]; then
            echo -e "暂无具体建议，请仔细检查上方 acme.sh 详细日志。"
        fi
        echo -e "${YELLOW}------------------------${NC}"
        # =======================================================

        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    rm -f "$log_temp"

    if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then
        log_message INFO "重启 $temp_svc ..."
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

_draw_dashboard_simple() {
    # 移除 clear，保留上下文
    local nginx_v=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    local uptime=$(uptime -p | sed 's/up //')
    local count=$(jq '. | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)
    local warn_count=0
    
    if [ -f "$PROJECTS_METADATA_FILE" ]; then
        warn_count=$(jq '[.[] | select(.cert_file) | select(.cert_file | test(".cer$"))] | length' "$PROJECTS_METADATA_FILE")
    fi

    # 计算负载字符串长度以动态调整
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local path_len=${#NGINX_SITES_ENABLED_DIR}
    
    echo ""
    echo -e "${GREEN}╭──────────────────────────────────────────────────────────────╮${NC}"
    # 汉化标题，调整对齐
    printf "${GREEN}│${NC} ${BOLD}%-56s${NC} ${GREEN}│${NC}\n" "Nginx 证书管理面板 v4.17.2"
    echo -e "${GREEN}├──────────────────────────────────────────────────────────────┤${NC}"
    # 调整信息展示，使其在盒子里对齐
    printf "${GREEN}│${NC} Nginx: %-15s | 运行: %-25s ${GREEN}│${NC}\n" "${GREEN}${nginx_v}${NC}" "${GREEN}${uptime}${NC}"
    printf "${GREEN}│${NC} 负载 : %-50s ${GREEN}│${NC}\n" "${YELLOW}${load}${NC}"
    printf "${GREEN}│${NC} 项目 : ${BOLD}%-2s${NC} | 告警 : ${RED}%-2s${NC} | 路径 : %-22s ${GREEN}│${NC}\n" "${count}" "${warn_count:-0}" "/etc/nginx/sites-enabled"
    echo -e "${GREEN}╰──────────────────────────────────────────────────────────────╯${NC}"
}

manage_configs() {
    while true; do
        local all=$(jq . "$PROJECTS_METADATA_FILE")
        local count=$(echo "$all" | jq 'length')
        if [ "$count" -eq 0 ]; then
            log_message WARN "暂无项目。"
            break
        fi
        
        echo ""
        _display_projects_list "$all"
        
        local choice_idx
        choice_idx=$(_prompt_user_input_with_validation "请输入序号选择项目 (回车返回)" "" "^[0-9]*$" "无效序号" "true")
        
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then break; fi
        if [ "$choice_idx" -gt "$count" ]; then log_message ERROR "序号越界"; continue; fi
        
        local selected_domain
        selected_domain=$(echo "$all" | jq -r ".[$((choice_idx-1))].domain")
        
        _render_menu "管理: $selected_domain" \
            "1. 查看证书详情" \
            "2. 手动续期" \
            "3. 删除项目" \
            "4. 查看配置" \
            "5. 查看日志" \
            "6. 重新配置" \
            "7. 设置上传大小限制 (Max Body Size)" \
            "8. 添加自定义 Nginx 配置 (Advanced)"
        
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
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

_handle_renew_cert() {
    local d="${1:-}"
    local p=$(_get_project_json "$d")
    [ -z "$p" ] && { log_message ERROR "项目不存在"; return; }
    _issue_and_install_certificate "$p" && control_nginx reload
    press_enter_to_continue
}

_handle_delete_project() {
    local d="${1:-}"
    if _confirm_action_or_exit_non_interactive "确认彻底删除 $d 及其证书？"; then
        _remove_and_disable_nginx_config "$d"
        "$ACME_BIN" --remove -d "$d" --ecc >/dev/null 2>&1
        rm -f "$SSL_CERTS_BASE_DIR/$d.cer" "$SSL_CERTS_BASE_DIR/$d.key"
        _delete_project_json "$d"
        control_nginx reload
    fi
    press_enter_to_continue
}

_handle_view_config() {
    local d="${1:-}"
    _view_nginx_config "$d"
    press_enter_to_continue
}

_handle_reconfigure_project() {
    local d="${1:-}"
    local cur=$(_get_project_json "$d")
    log_message INFO "正在重配 $d ..."
    
    local port=$(echo "$cur" | jq -r .resolved_port)
    local mode=""
    [ "$port" == "cert_only" ] && mode="cert_only"

    local skip_cert="true"
    if _confirm_action_or_exit_non_interactive "是否重新申请/续期证书 (Renew Cert)?"; then
        skip_cert="false"
    fi

    local new
    if ! new=$(_gather_project_details "$cur" "$skip_cert" "$mode"); then
        log_message WARN "重配取消。"
        return
    fi
    
    if [ "$skip_cert" == "false" ]; then
        if ! _issue_and_install_certificate "$new"; then
            log_message ERROR "证书申请失败，重配终止。"
            return 1
        fi
    else
        log_message INFO "已跳过证书申请，仅更新配置。"
    fi

    if [ "$mode" != "cert_only" ]; then
        _write_and_enable_nginx_config "$d" "$new"
    fi
    control_nginx reload && _save_project_json "$new" && log_message SUCCESS "重配成功"
    press_enter_to_continue
}

_handle_set_max_body_size() {
    local d="${1:-}"
    local cur=$(_get_project_json "$d")
    local current_val=$(echo "$cur" | jq -r '.client_max_body_size // "默认(1m)"')
    
    echo ""
    echo -e "${CYAN}当前设置: $current_val${NC}"
    echo "请输入新的限制大小 (例如: 10m, 500m, 1g)。"
    echo "直接回车 = 不修改; 输入 'default' = 恢复 Nginx 默认(1m)"
    
    local new_val=$(_prompt_user_input_with_validation "限制大小" "" "^[0-9]+[kKmMgG]$|^default$" "格式错误 (示例: 10m)" "true")
    
    if [ -z "$new_val" ]; then return; fi
    
    local json_val="$new_val"
    if [ "$new_val" == "default" ]; then json_val=""; fi
    
    local new_json=$(echo "$cur" | jq --arg v "$json_val" '.client_max_body_size = $v')
    
    if [ -z "$new_json" ]; then
        log_message ERROR "JSON 处理失败。"
        return
    fi

    if _save_project_json "$new_json"; then
        _write_and_enable_nginx_config "$d" "$new_json"
        control_nginx reload
        log_message SUCCESS "已更新 $d 的上传限制 -> ${json_val:-默认}。"
    else
        log_message ERROR "保存配置失败。"
    fi
    press_enter_to_continue
}

_handle_set_custom_config() {
    local d="${1:-}"
    local cur=$(_get_project_json "$d")
    local current_val=$(echo "$cur" | jq -r '.custom_config // "无"')
    
    echo ""
    echo -e "${CYAN}当前自定义配置:${NC}"
    echo "$current_val"
    echo -e "${YELLOW}请输入完整的 Nginx 指令 (需以分号结尾)。${NC}"
    echo "例如: proxy_read_timeout 600s; add_header X-Custom 1;"
    echo "直接回车 = 不修改; 输入 'clear' = 清空自定义配置"
    
    local new_val=$(_prompt_user_input_with_validation "指令内容" "" "" "" "true")
    
    if [ -z "$new_val" ]; then return; fi
    
    local json_val="$new_val"
    if [ "$new_val" == "clear" ]; then json_val=""; fi
    
    local new_json=$(echo "$cur" | jq --arg v "$json_val" '.custom_config = $v')
    
    if [ -z "$new_json" ]; then
        log_message ERROR "JSON 处理失败。"
        return
    fi

    if _save_project_json "$new_json"; then
        _write_and_enable_nginx_config "$d" "$new_json"
        if control_nginx reload; then
            log_message SUCCESS "自定义配置已应用。"
        else
            log_message ERROR "Nginx 重载失败！请检查指令语法是否正确。"
            log_message WARN "正在回滚配置..."
            _write_and_enable_nginx_config "$d" "$cur"
            control_nginx reload
        fi
    else
        log_message ERROR "保存配置失败。"
    fi
    press_enter_to_continue
}

_handle_cert_details() {
    local d="${1:-}"
    local cert="$SSL_CERTS_BASE_DIR/$d.cer"
    if [ -f "$cert" ]; then
        echo -e "${CYAN}--- 证书详情 ($d) ---${NC}"
        openssl x509 -in "$cert" -noout -text | grep -E "Issuer:|Not After|Subject:|DNS:"
        echo -e "${CYAN}-----------------------${NC}"
    else
        log_message ERROR "证书文件不存在。"
    fi
    press_enter_to_continue
}

check_and_auto_renew_certs() {
    log_message INFO "正在检查所有证书..."
    local success=0 fail=0
    
    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r p; do
        local d=$(echo "$p" | jq -r .domain)
        local f=$(echo "$p" | jq -r .cert_file)
        
        echo -ne "检查: $d ... "
        
        if [ ! -f "$f" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$f"; then
            echo -e "${YELLOW}即将到期，开始续期...${NC}"
            if _issue_and_install_certificate "$p"; then 
                success=$((success+1))
                echo -e "   ${GREEN}续期成功${NC}"
            else 
                fail=$((fail+1))
                echo -e "   ${RED}续期失败 (查看日志)${NC}"
            fi
        else
            echo -e "${GREEN}有效期充足${NC}"
        fi
    done
    control_nginx reload
    log_message INFO "批量续期结果: $success 成功, $fail 失败。"
}

configure_nginx_projects() {
    local mode="${1:-standard}" # standard or cert_only
    local json
    
    echo ""
    echo -e "${CYAN}开始配置新项目...${NC}"
    
    if ! json=$(_gather_project_details "{}" "false" "$mode"); then
        log_message WARN "用户取消配置。"
        return
    fi
    
    # 申请证书
    if ! _issue_and_install_certificate "$json"; then
        log_message ERROR "证书申请失败，项目未保存。"
        return
    fi
    
    # 如果不是纯证书模式，生成 Nginx 配置
    if [ "$mode" != "cert_only" ]; then
        local domain=$(echo "$json" | jq -r .domain)
        if _write_and_enable_nginx_config "$domain" "$json"; then
            control_nginx reload
            log_message SUCCESS "Nginx 配置已生成并加载。"
        else
            log_message ERROR "Nginx 配置生成失败。"
            return
        fi
    fi
    
    # 保存元数据
    _save_project_json "$json"
    log_message SUCCESS "项目配置已保存。"
    
    # 提示查看
    local domain=$(echo "$json" | jq -r .domain)
    if [ "$mode" != "cert_only" ]; then
        echo -e "\n您的网站已上线: https://${domain}"
    else
        echo -e "\n证书已就绪: /etc/ssl/${domain}.cer"
    fi
}

main_menu() {
    while true; do
        _draw_dashboard_simple
        
        echo -e "${PURPLE}【核心业务】${NC}"
        echo -e " 1. 配置新项目 (New Project)"
        echo -e " 2. 项目管理 (Manage Projects)"
        echo -e " 3. 仅申请证书 (Cert Only)"
        echo ""
        echo -e "${PURPLE}【运维监控】${NC}"
        echo -e " 4. 批量续期 (Auto Renew All)"
        echo -e " 5. 查看 acme.sh 运行日志"
        echo -e " 6. 查看 Nginx 运行日志"
        echo ""
        echo -e "${PURPLE}【系统维护】${NC}"
        echo -e " 7. 定时任务管理 (Cron)"
        echo -e " 8. 备份与还原 (Backup & Restore)"
        
        echo ""
        case "$(_prompt_for_menu_choice_local "1-8" "true")" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) manage_configs ;;
            3) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            4) 
                if _confirm_action_or_exit_non_interactive "确认检查所有项目？"; then
                    check_and_auto_renew_certs
                    press_enter_to_continue
                fi ;;
            5) _view_acme_log; press_enter_to_continue ;;
            6) _view_nginx_global_log; press_enter_to_continue ;;
            7) _manage_cron_jobs; press_enter_to_continue ;;
            8) _handle_backup_restore ;;
            "") return 0 ;;
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

trap '_on_exit' INT TERM
if ! check_root; then exit 1; fi
initialize_environment

if [[ " $* " =~ " --cron " ]]; then check_and_auto_renew_certs; exit $?; fi

install_dependencies && install_acme_sh && main_menu
exit $?
