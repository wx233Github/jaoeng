# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.14.0-日志交互修复)
# =============================================================
# - 修复: 查看日志时 Ctrl+C 可正常退出查看模式而不终止脚本。
# - 优化: 日志初始化提示中文化。

set -euo pipefail

# --- 全局变量 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
RENEW_THRESHOLD_DAYS=30
DEPS_MARK_FILE="$HOME/.nginx_ssl_manager_deps_v1"

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

# ==============================================================================
# SECTION: 核心工具函数
# ==============================================================================

_log_prefix() {
    if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then echo -n "$(date '+%Y-%m-%d %H:%M:%S') "; fi
}

log_message() {
    local level="$1" message="$2"
    case "$level" in
        INFO)    echo -e "$(_log_prefix)${CYAN}ℹ️  [信息]${NC} ${message}";;
        SUCCESS) echo -e "$(_log_prefix)${GREEN}✅ [成功]${NC} ${message}";;
        WARN)    echo -e "$(_log_prefix)${YELLOW}⚠️  [警告]${NC} ${message}" >&2;;
        ERROR)   echo -e "$(_log_prefix)${RED}❌ [错误]${NC} ${message}" >&2;;
    esac
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level^^}] ${message}" >> "$LOG_FILE"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}⌨️  按 Enter 键继续...${NC}")" < /dev/tty; }

_prompt_for_menu_choice_local() {
    local range="$1"
    local allow_empty="${2:-false}"
    local prompt_text="${ORANGE}👉 选项 [${range}]${NC} (↩ 返回): "
    local choice
    while true; do
        read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then echo ""; return; fi
            echo -e "${YELLOW}⚠️  请选择一个选项。${NC}" >&2
            continue
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then echo "$choice"; return; fi
    done
}

generate_line() {
    local len=${1:-40}; printf "%${len}s" "" | sed "s/ /─/g"
}

_render_menu() {
    local title="$1"; shift; 
    local max_width=42
    local title_len=${#title}
    if [ "$title_len" -gt "$max_width" ]; then max_width=$title_len; fi
    max_width=$((max_width + 4))

    echo ""
    echo -e "${GREEN}╭$(generate_line "$max_width")╮${NC}"
    local pad_left=$(( (max_width - title_len) / 2 ))
    local pad_right=$(( max_width - title_len - pad_left ))
    echo -e "${GREEN}│${NC}$(printf "%${pad_left}s" "")${BOLD}${title}${NC}$(printf "%${pad_right}s" "")${GREEN}│${NC}"
    echo -e "${GREEN}╰$(generate_line "$max_width")╯${NC}"
    
    for line in "$@"; do echo -e " ${line}"; done
}

cleanup_temp_files() {
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
}
# 定义全局陷阱函数
_on_exit() {
    cleanup_temp_files
    exit 10
}
trap _on_exit INT TERM

check_root() {
    if [ "$(id -u)" -ne 0 ]; then log_message ERROR "请使用 root 用户运行此操作。"; return 1; fi
    return 0
}

ensure_vps_ip() {
    if [ -z "$VPS_IP" ]; then
        VPS_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "")
        VPS_IPV6=$(curl -s -6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "")
    fi
}

_prompt_user_input_with_validation() {
    local prompt="$1" default="$2" regex="$3" error_msg="$4" allow_empty="${5:-false}" val=""
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local disp=""
            if [ -n "$default" ]; then disp=" [默认: ${default}]"
            fi
            echo -ne "${YELLOW}🔹 ${prompt}${NC}${disp}: " >&2
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
        local c; read -r -p "$(echo -e "${YELLOW}❓ $1 ([y]/n): ${NC}")" c < /dev/tty
        case "$c" in n|N) return 1;; *) return 0;; esac
    fi
    log_message ERROR "非交互需确认: '$1'，已取消。"; return 1
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
    local deps="nginx curl socat openssl jq idn dnsutils nano"
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
        log_message SUCCESS "acme.sh 安装成功 (已开启自动更新)。"
        return 0
    fi
    log_message ERROR "acme.sh 安装失败"; return 1
}

control_nginx() {
    local action="$1"
    if ! nginx -t >/dev/null 2>&1; then log_message ERROR "Nginx 配置错误"; nginx -t; return 1; fi
    systemctl "$action" nginx || { log_message ERROR "Nginx $action 失败"; return 1; }
    return 0
}

_get_nginx_status() {
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}🟢 Nginx (运行中)${NC}"
    else
        echo -e "${RED}🔴 Nginx (已停止)${NC}"
    fi
}

_restart_nginx_ui() {
    log_message INFO "正在重启 Nginx..."
    if control_nginx restart; then log_message SUCCESS "Nginx 重启成功。"; fi
}

_view_file_with_tail() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log_message ERROR "文件不存在: $file"
        return
    fi
    echo -e "${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}"
    
    # 临时覆盖 INT 信号处理，使其只停止 tail 命令
    trap 'echo -e "\n${CYAN}--- 日志查看结束 ---${NC}"; return' INT
    tail -f -n 50 "$file" || true
    # 恢复全局陷阱
    trap _on_exit INT
}

_view_acme_log() {
    local log_file="$HOME/.acme.sh/acme.sh.log"
    if [ ! -f "$log_file" ]; then log_file="/root/.acme.sh/acme.sh.log"; fi
    if [ ! -f "$log_file" ]; then
        log_message WARN "日志文件未找到，正在尝试初始化..."
        "$ACME_BIN" --version --log >/dev/null 2>&1 || true
        if [ ! -f "$log_file" ]; then
            mkdir -p "$(dirname "$log_file")"
            touch "$log_file"
            echo "[信息] 日志文件已初始化。" > "$log_file"
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

# ==============================================================================
# SECTION: 数据与文件管理
# ==============================================================================

_get_project_json() { jq -c ".[] | select(.domain == \"$1\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""; }

_save_project_json() {
    local json="$1" domain=$(echo "$json" | jq -r .domain) temp=$(mktemp)
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq "(.[] | select(.domain == \"$domain\")) = $json" "$PROJECTS_METADATA_FILE" > "$temp"
    else
        jq ". + [$json]" "$PROJECTS_METADATA_FILE" > "$temp"
    fi
    if [ $? -eq 0 ]; then mv "$temp" "$PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}

_delete_project_json() {
    local temp=$(mktemp)
    jq "del(.[] | select(.domain == \"$1\"))" "$PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$PROJECTS_METADATA_FILE"
}

_write_and_enable_nginx_config() {
    local domain="$1" json="$2" conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    local port=$(echo "$json" | jq -r .resolved_port)
    
    if [ "$port" == "cert_only" ]; then return 0; fi

    local cert=$(echo "$json" | jq -r .cert_file)
    local key=$(echo "$json" | jq -r .key_file)

    if [[ -z "$port" || "$port" == "null" ]]; then
        log_message ERROR "配置生成失败: 端口为空，请检查项目配置。"
        return 1
    fi

    # 延迟获取 IP
    ensure_vps_ip

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

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    ln -sf "$conf" "$NGINX_SITES_ENABLED_DIR/"
}

_remove_and_disable_nginx_config() {
    rm -f "$NGINX_SITES_AVAILABLE_DIR/$1.conf" "$NGINX_SITES_ENABLED_DIR/$1.conf"
}

_view_nginx_config() {
    local domain="$1"
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

_view_project_access_log() {
    local domain="$1"
    echo ""
    _render_menu "查看日志: $domain" "1. 访问日志 (Access Log)" "2. 错误日志 (Error Log)"
    local c=$(_prompt_for_menu_choice_local "1-2")
    local log_path=""
    case "$c" in
        1) log_path="$NGINX_ACCESS_LOG" ;;
        2) log_path="$NGINX_ERROR_LOG" ;;
        *) return ;;
    esac
    _view_file_with_tail "$log_path"
}

# ==============================================================================
# SECTION: 业务逻辑 (证书申请)
# ==============================================================================

_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    local svc
    for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then echo "$svc"; return; fi
    done
}

_get_cert_files() {
    local domain="$1"
    CERT_FILE="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    CONF_FILE="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
    if [ ! -f "$CERT_FILE" ]; then
        CERT_FILE="$HOME/.acme.sh/${domain}/fullchain.cer"
        CONF_FILE="$HOME/.acme.sh/${domain}/${domain}.conf"
    fi
}

_issue_and_install_certificate() {
    local json="$1"
    if [[ -z "$json" ]] || [[ "$json" == "null" ]]; then
        log_message WARN "未收到有效配置信息，流程中止。"
        return 1
    fi

    local domain=$(echo "$json" | jq -r .domain)
    # 增加双重检查
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
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca")
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                log_message INFO "🔐 请输入 Cloudflare Token (仅内存暂存)"
                local def_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
                local t=$(_prompt_user_input_with_validation "CF_Token" "$def_t" "" "不能为空" "false")
                local def_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"")
                local a=$(_prompt_user_input_with_validation "Account_ID" "$def_a" "" "不能为空" "false")
                export CF_Token="$t" CF_Account_ID="$a"
            fi
        elif [ "$provider" = "dns_ali" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                log_message INFO "🔐 请输入 Aliyun Key (仅内存暂存)"
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
                if _confirm_action_or_exit_non_interactive "是否临时停止 $temp_svc 以释放端口? (续期后自动启动)"; then
                    port_conflict="true"
                fi
            else
                log_message WARN "无法识别服务，请手动检查。"
            fi
        fi
        
        if [ "$port_conflict" == "true" ]; then
            log_message INFO "停止 $temp_svc ..."
            systemctl stop "$temp_svc"
        fi
        
        cmd+=("--standalone")
    fi

    local log_temp=$(mktemp)
    if ! "${cmd[@]}" > "$log_temp" 2>&1; then
        log_message ERROR "申请失败: $domain"
        cat "$log_temp"
        local err_log=$(cat "$log_temp")
        rm -f "$log_temp"
        
        # 恢复服务
        if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then
            log_message INFO "重启 $temp_svc ..."
            systemctl start "$temp_svc"
        fi
        
        if [[ "$err_log" == *"retryafter"* ]]; then
            echo -e "\n${RED}检测到 CA 限制 (retryafter)${NC}"
            if _confirm_action_or_exit_non_interactive "是否切换 CA 到 Let's Encrypt 并重试?"; then
                log_message INFO "正在切换默认 CA ..."
                "$ACME_BIN" --set-default-ca --server letsencrypt
                
                # 更新 JSON 中的 CA 设置
                json=$(echo "$json" | jq '.ca_server_url = "https://acme-v02.api.letsencrypt.org/directory"')
                
                log_message INFO "正在重试申请..."
                _issue_and_install_certificate "$json" # 递归调用一次
                return $?
            fi
        fi

        if [[ "$err_log" == *"504 Gateway Time-out"* ]]; then
            echo -e "\n${RED}诊断: 504 Gateway Time-out${NC}"
            log_message WARN "原因可能是 Cloudflare 小黄云导致。建议切换 DNS 模式。"
        fi

        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    rm -f "$log_temp"

    if [[ "$method" == "http-01" && "$port_conflict" == "true" ]]; then
        log_message INFO "重启 $temp_svc ..."
        systemctl start "$temp_svc"
    fi

    log_message INFO "证书签发成功，安装中..."
    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --reloadcmd "systemctl reload nginx")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    
    if ! "${inst[@]}"; then 
        log_message ERROR "安装失败: $domain"
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret
    return 0
}

# --- IO 修复版: 彻底分离 UI 与 数据流 ---
_gather_project_details() {
    exec 3>&1
    exec 1>&2

    local cur="${1:-{\}}"
    local skip_cert="${2:-false}"
    local is_cert_only="false"
    if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local domain=$(echo "$cur" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        domain=$(_prompt_user_input_with_validation "🌐 主域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "格式无效" "false") || { exec 1>&3; return 1; }
    fi
    
    local type="cert_only"
    local name="证书"
    local port="cert_only"

    if [ "$is_cert_only" == "false" ]; then
        name=$(echo "$cur" | jq -r '.name // ""')
        [ "$name" == "证书" ] && name=""
        
        while true; do
            local target=$(_prompt_user_input_with_validation "🔌 后端目标 (容器名/端口)" "$name" "" "" "false") || { exec 1>&3; return 1; }
            type="local_port"; port="$target"
            
            local is_docker="false"
            if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
                type="docker"
                exec 1>&3
                port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)
                exec 1>&2
                
                is_docker="true"
                if [ -z "$port" ]; then
                    port=$(_prompt_user_input_with_validation "⚠️ 未检测到端口，手动输入" "80" "^[0-9]+$" "无效端口" "false") || { exec 1>&3; return 1; }
                fi
                break
            fi
            
            if [[ "$port" =~ ^[0-9]+$ ]]; then break; fi
            log_message ERROR "错误: '$target' 既不是容器也不是端口，请重试。" >&2
        done
    fi

    # 默认值
    local method="http-01"
    local provider=""
    local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"
    local ca_name="letsencrypt"

    if [ "$skip_cert" == "true" ]; then
        # 继承旧值 (使用 // 默认值防止 null)
        method=$(echo "$cur" | jq -r '.acme_validation_method // "http-01"')
        provider=$(echo "$cur" | jq -r '.dns_api_provider // ""')
        wildcard=$(echo "$cur" | jq -r '.use_wildcard // "n"')
        ca_server=$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')
        ca_name=$(echo "$cur" | jq -r '.ca_server_name // "letsencrypt"')
    else
        # 交互选择
        local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
        _render_menu "选择 CA 机构" "${ca_list[@]}"
        local ca_choice
        while true; do
            ca_choice=$(_prompt_for_menu_choice_local "1-3")
            if [ -z "$ca_choice" ]; then 
                log_message WARN "请选择一个选项。" >&2
                continue
            fi
            break
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
            1) 
                method="http-01" 
                if [ "$is_cert_only" == "false" ]; then
                    log_message WARN "注意: 稍后脚本将占用 80 端口，请确保无冲突。" >&2
                fi
                ;;
            2) 
                method="dns-01"; provider="dns_cf"
                wildcard=$(_prompt_user_input_with_validation "✨ 申请泛域名 (y/[n])" "n" "^[yYnN]$" "" "false")
                ;;
            3) 
                method="dns-01"; provider="dns_ali"
                wildcard=$(_prompt_user_input_with_validation "✨ 申请泛域名 (y/[n])" "n" "^[yYnN]$" "" "false")
                ;;
            *) method="http-01" ;;
        esac
    fi

    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"
    local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    
    # 最终输出 JSON
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
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf}' >&3
    
    exec 1>&3
}

# ==============================================================================
# SECTION: 交互菜单
# ==============================================================================

_display_projects_list() {
    local json="$1" idx=0
    echo "$json" | jq -c '.[]' | while read -r p; do
        idx=$((idx + 1))
        local domain=$(echo "$p" | jq -r '.domain // "未知"')
        local type=$(echo "$p" | jq -r '.type')
        local port=$(echo "$p" | jq -r '.resolved_port')
        local cert=$(echo "$p" | jq -r '.cert_file')
        
        local info="本地端口: $port"
        [ "$type" = "docker" ] && info="容器: $(echo "$p" | jq -r '.name') ($port)"
        [ "$port" == "cert_only" ] && info="(纯证书模式)"
        
        local status="${RED}缺失${NC}"
        local details=""
        local next_renew="自动/未知"
        
        local conf_file="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
        [ ! -f "$conf_file" ] && conf_file="$HOME/.acme.sh/${domain}/${domain}.conf"
        if [ -f "$conf_file" ]; then
            local next_ts=$(grep "^Le_NextRenewTime=" "$conf_file" | cut -d= -f2- | tr -d "'\"")
            if [ -n "$next_ts" ]; then
                next_renew=$(date -d "@$next_ts" +%F 2>/dev/null || echo "Err")
            fi
        fi

        if [[ -f "$cert" ]]; then
            local end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            local ts=$(date -d "$end" +%s 2>/dev/null || echo 0)
            local days=$(( (ts - $(date +%s)) / 86400 ))
            
            if (( days < 0 )); then status="${RED}已过期${NC}";
            elif (( days <= 30 )); then status="${YELLOW}即将到期${NC}";
            else status="${GREEN}有效${NC}"; fi
            details="(剩余 $days 天)"
        fi
        
        printf "${GREEN}[ %d ] %s${NC}\n" "$idx" "$domain"
        printf "  ├─ 🎯 目 标 : %s\n" "$info"
        printf "  ├─ ⏱️ 续 期 : %s\n" "$next_renew"
        echo -e "  └─ 📜 证 书 : ${status} ${details}"
        echo -e "${CYAN}····························································${NC}"
    done
}

configure_nginx_projects() {
    local is_cert_only="false"
    if [ "${1:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local json
    if ! json=$(_gather_project_details "{}" "false" "${1:-}"); then
        log_message WARN "信息收集已取消或失败。"
        return 0
    fi
    
    local domain=$(echo "$json" | jq -r .domain)

    if [ -n "$(_get_project_json "$domain")" ]; then
        if ! _confirm_action_or_exit_non_interactive "域名 $domain 已存在，是否覆盖？"; then
            log_message INFO "用户取消操作。"
            return 0
        fi
    fi

    if ! _issue_and_install_certificate "$json"; then
        log_message ERROR "配置失败：证书申请未通过。"
        return
    fi
    
    if [ "$is_cert_only" == "false" ]; then
        if ! _write_and_enable_nginx_config "$domain" "$json"; then return 1; fi
        if ! control_nginx reload; then
            _remove_and_disable_nginx_config "$domain"
            return
        fi
    fi

    _save_project_json "$json"
    log_message SUCCESS "项目 $domain 配置完成。"
}

_handle_renew_cert() {
    local d="$1"
    local p=$(_get_project_json "$d")
    [ -z "$p" ] && { log_message ERROR "项目不存在"; return; }
    _issue_and_install_certificate "$p" && control_nginx reload
}

_handle_delete_project() {
    local d="$1"
    if _confirm_action_or_exit_non_interactive "确认彻底删除 $d 及其证书？"; then
        _remove_and_disable_nginx_config "$d"
        "$ACME_BIN" --remove -d "$d" --ecc >/dev/null 2>&1
        rm -f "$SSL_CERTS_BASE_DIR/$d.cer" "$SSL_CERTS_BASE_DIR/$d.key"
        _delete_project_json "$d"
        control_nginx reload
    fi
}

_handle_view_config() {
    local d="$1"
    _view_nginx_config "$d"
}

_handle_reconfigure_project() {
    local d="$1"
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

_handle_cert_details() {
    local d="$1"
    local cert="$SSL_CERTS_BASE_DIR/$d.cer"
    if [ -f "$cert" ]; then
        echo -e "${CYAN}--- 证书详情 ($d) ---${NC}"
        openssl x509 -in "$cert" -noout -text | grep -E "Issuer:|Not After|Subject:|DNS:"
        echo -e "${CYAN}-----------------------${NC}"
    else
        log_message ERROR "证书文件不存在。"
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
        
        _render_menu "Manage: $selected_domain" \
            "1. 🔍 查看证书详情" \
            "2. 🔄 手动续期" \
            "3. 🗑️  删除项目" \
            "4. 📝 查看配置" \
            "5. 📊 查看日志" \
            "6. ⚙️  重新配置"
        
        case "$(_prompt_for_menu_choice_local "1-6")" in
            1) _handle_cert_details "$selected_domain" ;;
            2) _handle_renew_cert "$selected_domain" ;;
            3) _handle_delete_project "$selected_domain"; break ;; 
            4) _handle_view_config "$selected_domain" ;;
            5) _view_project_access_log "$selected_domain" ;;
            6) _handle_reconfigure_project "$selected_domain" ;;
            "") continue ;;
            *) log_message ERROR "无效选择" ;;
        esac
        press_enter_to_continue
    done
}

check_and_auto_renew_certs() {
    log_message INFO "正在检查所有证书..."
    local success=0 fail=0
    
    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r p; do
        local d=$(echo "$p" | jq -r .domain)
        local f=$(echo "$p" | jq -r .cert_file)
        
        if [ ! -f "$f" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$f"; then
            log_message WARN "正在续期: $d"
            if _issue_and_install_certificate "$p"; then success=$((success+1)); else fail=$((fail+1)); fi
        fi
    done
    control_nginx reload
    log_message INFO "结果: $success 成功, $fail 失败。"
}

main_menu() {
    while true; do
        local nginx_status="$(_get_nginx_status)"
        _render_menu "Nginx 证书与反代管理" \
            "1. ${nginx_status}" \
            "2. 📝 仅申请证书 (Cert Only)" \
            "3. 🚀 配置新项目 (New Project)" \
            "4. 📂 项目管理 (Manage Projects)" \
            "5. 🔄 批量续期 (Auto Renew All)" \
            "6. 📜 查看 acme.sh 运行日志" \
            "7. 📜 查看 Nginx 运行日志"
            
        case "$(_prompt_for_menu_choice_local "1-7")" in
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
            "") log_message INFO "👋 Bye."; return 10 ;;
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

# --- 入口 ---
trap '_on_exit' INT TERM
if ! check_root; then exit 1; fi
initialize_environment

if [[ " $* " =~ " --cron " ]]; then check_and_auto_renew_certs; exit $?; fi

install_dependencies && install_acme_sh && get_vps_ip && main_menu
exit $?
