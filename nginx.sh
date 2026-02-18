# =============================================================
# Nginx 反向代理 + HTTPS 证书管理助手 (v4.16.2-中文表格优化版)
# =============================================================
# 作者：Shell 脚本专家
# 描述：自动化管理 Nginx 反代配置与 SSL 证书，优化中文表格显示
# 版本历史：
#   v4.16.2 - 汉化并重构项目列表表格，修复对齐问题
#   v4.16.1 - 移除所有 Emoji，项目列表改为表格显示

set -euo pipefail

# --- 全局变量 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
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
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR"
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
    
    if [ -x "$ACME_BIN" ]; then "$ACME_BIN" --version >/dev/null 2>&1 || true; fi

    if [ ! -f "$log_file" ]; then
        mkdir -p "$(dirname "$log_file")"
        touch "$log_file"
        echo "日志文件已初始化。" > "$log_file"
    else
        if grep -q "Log initialized." "$log_file"; then
            sed -i 's/Log initialized./日志文件已初始化。/g' "$log_file"
        fi
    fi

    if [ -f "$log_file" ]; then
        echo -e "\n${CYAN}=== acme.sh 运行日志 ===${NC}"
        _view_file_with_tail "$log_file"
    else
        log_message ERROR "无法创建或读取日志文件: $log_file"
    fi
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

_gather_project_details() {
    exec 3>&1
    exec 1>&2
    
    local cur="${1:-{\}}"
    local skip_cert="${2:-false}"
    local is_cert_only="false"
    if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local domain=$(echo "$cur" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        domain=$(_prompt_user_input_with_validation "主域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "格式无效" "false") || { exec 1>&3; return 1; }
    fi
    
    local type="cert_only"
    local name="证书"
    local port="cert_only"
    local max_body=$(echo "$cur" | jq -r '.client_max_body_size // empty')
    local custom_cfg=$(echo "$cur" | jq -r '.custom_config // empty')

    if [ "$is_cert_only" == "false" ]; then
        name=$(echo "$cur" | jq -r '.name // ""')
        [ "$name" == "证书" ] && name=""
        
        while true; do
            local target=$(_prompt_user_input_with_validation "后端目标 (容器名/端口)" "$name" "" "" "false") || { exec 1>&3; return 1; }
            type="local_port"; port="$target"
            local is_docker="false"
            if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
                type="docker"
                exec 1>&3
                port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)
                exec 1>&2
                is_docker="true"
                if [ -z "$port" ]; then
                    port=$(_prompt_user_input_with_validation "未检测到端口，手动输入" "80" "^[0-9]+$" "无效端口" "false") || { exec 1>&3; return 1; }
                fi
                break
            fi
            if [[ "$port" =~ ^[0-9]+$ ]]; then break; fi
            log_message ERROR "错误: '$target' 既不是容器也不是端口，请重试。" >&2
        done
    fi

    local method="http-01"
    local provider=""
    local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"
    local ca_name="letsencrypt"

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
            *) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
        esac
        if [[ "$ca_name" == "zerossl" ]] && ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
             log_message INFO "检测到未注册 ZeroSSL，请输入邮箱注册..." >&2
             local reg_email=$(_prompt_user_input_with_validation "注册邮箱" "" "" "" "false")
             "$ACME_BIN" --register-account -m "$reg_email" --server zerossl >&2 || log_message WARN "ZeroSSL 注册跳过" >&2
        fi
        local -a method_display=("1. standalone (HTTP验证, 80端口)" "2. dns_cf (Cloudflare API)" "3. dns_ali (阿里云 API)")
        _render_menu "验证方式" "${method_display[@]}" >&2
        local v_choice
        while true; do
            v_choice=$(_prompt_for_menu_choice_local "1-3")
            [ -n "$v_choice" ] && break
        done
        case "$v_choice" in
            1) method="http-01" 
                if [ "$is_cert_only" == "false" ]; then log_message WARN "注意: 稍后脚本将占用 80 端口，请确保无冲突。" >&2; fi ;;
            2) method="dns-01"; provider="dns_cf"
                wildcard=$(_prompt_user_input_with_validation "申请泛域名 (y/[n])" "n" "^[yYnN]$" "" "false") ;;
            3) method="dns-01"; provider="dns_ali"
                wildcard=$(_prompt_user_input_with_validation "申请泛域名 (y/[n])" "n" "^[yYnN]$" "" "false") ;;
            *) method="http-01" ;;
        esac
    fi

    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"
    local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    
    jq -n \
        --arg d "${domain:-}" \
        --arg t "${type:-local_port}" \
        --arg n "${name:-}" \
        --arg p "${port:-}" \
        --arg m "${method:-http-01}" \
        --arg dp "${provider:-}" \
        --arg w "${wildcard:-n}" \
        --arg cu "${ca_server:-}" \
        --arg cn "${ca_name:-}" \
        --arg cf "${cf:-}" \
        --arg kf "${kf:-}" \
        --arg mb "${max_body:-}" \
        --arg cc "${custom_cfg:-}" \
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf, client_max_body_size:$mb, custom_config:$cc}' >&3
    
    exec 1>&3
}

_display_projects_list() {
    local json="${1:-}" 
    if [ -z "$json" ] || [ "$json" == "[]" ]; then echo "暂无数据"; return; fi
    
    # 汉化表头，调整顺序
    printf "${BOLD}%-4s %-10s %-12s %-20s %-s${NC}\n" "ID" "状态" "续期" "目标" "域名"
    echo "----------------------------------------------------------------------"
    
    local idx=0
    echo "$json" | jq -c '.[]' | while read -r p; do
        idx=$((idx + 1))
        local domain=$(echo "$p" | jq -r '.domain // "未知"')
        local type=$(echo "$p" | jq -r '.type')
        local port=$(echo "$p" | jq -r '.resolved_port')
        local cert=$(echo "$p" | jq -r '.cert_file')
        
        # 格式化目标列
        local target_str="端口:$port"
        [ "$type" = "docker" ] && target_str="Docker:$port"
        [ "$port" == "cert_only" ] && target_str="纯证书"
        
        # 格式化状态与续期
        local status_str="缺失  " # 3个汉字宽度(6字节视觉)+2空 = 8? 不，按3汉字对齐
        local status_color="$RED"
        local renew_date="-"
        
        # 获取续期时间
        local conf_file="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
        [ ! -f "$conf_file" ] && conf_file="$HOME/.acme.sh/${domain}/${domain}.conf"
        if [ -f "$conf_file" ]; then
            local next_ts=$(grep "^Le_NextRenewTime=" "$conf_file" | cut -d= -f2- | tr -d "'\"")
            if [ -n "$next_ts" ]; then
                renew_date=$(date -d "@$next_ts" +%F 2>/dev/null || echo "Err")
            fi
        fi

        # 获取证书状态 (统一使用3个汉字)
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
        
        # 打印行 (ID, 状态, 续期, 目标, 域名)
        # 注意: 状态列使用 ${status_color} 但为了对齐，不能让 printf 计算颜色代码长度
        # 汉字在 printf 中占 3 bytes (UTF-8)，显示占 2 char width。
        # "运行中" = 9 bytes. 设为 %-10s (9 bytes + 1 space).
        printf "%-4d ${status_color}%-10s${NC} %-12s %-20s %-s\n" \
            "$idx" "$status_str" "$renew_date" "${target_str:0:20}" "${domain}"
    done
    echo ""
}

_manage_cron_jobs() {
    local acme_cron_status="${RED}未发现${NC}"
    if crontab -l 2>/dev/null | grep -q "acme.sh --cron"; then
        acme_cron_status="${GREEN}已存在${NC}"
    fi

    local script_cron_status="${RED}未发现${NC}"
    local is_installed="false"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --cron"; then
        script_cron_status="${GREEN}已存在${NC}"
        is_installed="true"
    fi
    
    local line1="1. acme.sh 原生任务 : ${acme_cron_status}"
    local line2="2. 本脚本续期任务   : ${script_cron_status}"
    
    _render_menu "定时任务 (Cron) 管理" "$line1" "$line2"
    
    echo ""
    if [ "$is_installed" == "true" ]; then
        echo -e "${YELLOW}检测到本脚本任务已存在。${NC}"
        if _confirm_action_or_exit_non_interactive "是否强制重置/修复定时任务配置?"; then
            crontab -l > /tmp/cron.bk 2>/dev/null || true
            grep -v "$SCRIPT_PATH --cron" /tmp/cron.bk > /tmp/cron.new || true
            echo "0 3 * * * /bin/bash $SCRIPT_PATH --cron >> $LOG_FILE 2>&1" >> /tmp/cron.new
            crontab /tmp/cron.new
            rm -f /tmp/cron.bk /tmp/cron.new
            log_message SUCCESS "定时任务已重置。"
        fi
    else
        echo -e "${YELLOW}建议添加任务以确保证书自动续期 (<30天)。${NC}"
        if _confirm_action_or_exit_non_interactive "是否添加每日自动续期任务?"; then
            crontab -l > /tmp/cron.bk 2>/dev/null || true
            grep -v "$SCRIPT_PATH --cron" /tmp/cron.bk > /tmp/cron.new || true
            echo "0 3 * * * /bin/bash $SCRIPT_PATH --cron >> $LOG_FILE 2>&1" >> /tmp/cron.new
            crontab /tmp/cron.new
            rm -f /tmp/cron.bk /tmp/cron.new
            log_message SUCCESS "定时任务已添加: 每天 03:00 执行。"
        fi
    fi
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
        
        case "$(_prompt_for_menu_choice_local "1-8")" in
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
        press_enter_to_continue
    done
}

_handle_renew_cert() {
    local d="${1:-}"
    local p=$(_get_project_json "$d")
    [ -z "$p" ] && { log_message ERROR "项目不存在"; return; }
    _issue_and_install_certificate "$p" && control_nginx reload
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
}

_handle_view_config() {
    local d="${1:-}"
    _view_nginx_config "$d"
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
        local nginx_status="$(_get_nginx_status)"
        _render_menu "Nginx 证书与反代管理" \
            "1. ${nginx_status}" \
            "2. 仅申请证书 (Cert Only)" \
            "3. 配置新项目 (New Project)" \
            "4. 项目管理 (Manage Projects)" \
            "5. 批量续期 (Auto Renew All)" \
            "6. 查看 acme.sh 运行日志" \
            "7. 查看 Nginx 运行日志" \
            "8. 定时任务管理 (Cron)"
            
        case "$(_prompt_for_menu_choice_local "1-8" "true")" in
            1) _restart_nginx_ui; press_enter_to_continue ;;
            2) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            3) configure_nginx_projects; press_enter_to_continue ;;
            4) manage_configs ;;
            5) 
                if _confirm_action_or_exit_non_interactive "确认检查所有项目？"; then
                    check_and_auto_renew_certs
                    press_enter_to_continue
                fi ;;
            6) _view_acme_log; press_enter_to_continue ;;
            7) _view_nginx_global_log; press_enter_to_continue ;;
            8) _manage_cron_jobs; press_enter_to_continue ;;
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
