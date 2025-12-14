# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v3.0.0-深度重构版)
# - 核心: 集成新版 acme.sh 脚本的健壮逻辑 (Standalone/DNS API)。
# - UI: 升级为现代卡片式界面，支持详细状态显示。
# - 增强: 自动检测端口冲突，支持智能服务启停。
# =============================================================

set -eo pipefail

# --- 全局变量和颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
RENEW_THRESHOLD_DAYS=30

# --- Nginx 路径变量 ---
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
NGINX_CUSTOM_SNIPPETS_DIR="/etc/nginx/custom_snippets"
SSL_CERTS_BASE_DIR="/etc/ssl"

# --- 模式与全局状态 ---
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
    if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then
        echo -n "$(date '+%Y-%m-%d %H:%M:%S') "
    fi
}

log_message() {
    local level="$1" message="$2"
    case "$level" in
        INFO)    echo -e "$(_log_prefix)${CYAN}[信 息]${NC} ${message}";;
        SUCCESS) echo -e "$(_log_prefix)${GREEN}[成 功]${NC} ${message}";;
        WARN)    echo -e "$(_log_prefix)${YELLOW}[警 告]${NC} ${message}" >&2;;
        ERROR)   echo -e "$(_log_prefix)${RED}[错 误]${NC} ${message}" >&2;;
        *)       echo -e "$(_log_prefix)${NC}[LOG] ${message}";;
    esac
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level}] ${message}" >> "$LOG_FILE"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }

_prompt_for_menu_choice_local() {
    local range="$1"
    local prompt="${ORANGE}>${NC} 选项 "
    if [ -n "$range" ]; then prompt+="[${ORANGE}${range}${NC}] "; fi
    prompt+="(↩ 返回): "
    local choice; read -r -p "$(echo -e "$prompt")" choice < /dev/tty
    echo "$choice"
}

generate_line() {
    local len=${1:-40}; printf "%${len}s" "" | sed "s/ /-/g"
}

_render_menu() {
    echo -e "\n${GREEN}--- $1 ---${NC}"; shift; for l in "$@"; do echo -e "$l"; done
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then log_message ERROR "请使用 root 用户运行。"; return 1; fi
}

get_vps_ip() {
    VPS_IP=$(curl -s https://api.ipify.org)
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "")
}

_prompt_user_input_with_validation() {
    local msg="$1" default="$2" regex="$3" err="$4" allow_empty="${5:-false}" val=""
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local disp_def="${default:-$( [ "$allow_empty" = "true" ] && echo "空" || echo "无" )}"
            echo -e "${YELLOW}${msg} [默认: ${disp_def}]: ${NC}" >&2
            read -r val; val=${val:-$default}
        else
            val="$default"
            if [[ -z "$val" && "$allow_empty" = "false" ]]; then return 1; fi
        fi
        if [[ -z "$val" && "$allow_empty" = "true" ]]; then echo ""; return 0; fi
        if [[ -z "$val" ]]; then log_message ERROR "输入不能为空。"; continue; fi
        if [[ -n "$regex" && ! "$val" =~ $regex ]]; then log_message ERROR "${err:-格式错误}"; continue; fi
        echo "$val"; return 0
    done
}

_confirm_action_or_exit_non_interactive() {
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local c; read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" c < /dev/tty
        [[ "$c" =~ ^([Yy]|)$ ]] && return 0 || return 1
    fi
    return 1 # Non-interactive defaults to no for safety
}

_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    for s in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$s"; then echo "$s"; return; fi
    done
}

# ==============================================================================
# SECTION: 核心逻辑
# ==============================================================================

initialize_environment() {
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    export PATH="$HOME/.acme.sh:$PATH"
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR"
    if [ ! -f "$PROJECTS_METADATA_FILE" ]; then echo "[]" > "$PROJECTS_METADATA_FILE"; fi
}

install_dependencies() {
    local deps="nginx curl socat openssl jq dnsutils"
    for pkg in $deps; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            log_message WARN "安装 $pkg..."
            apt update -y >/dev/null && apt install -y "$pkg" >/dev/null || log_message ERROR "$pkg 安装失败"
        fi
    done
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then return 0; fi
    log_message INFO "安装 acme.sh..."
    local email; email=$(_prompt_user_input_with_validation "请输入邮箱" "" "" "" "true")
    local cmd="curl https://get.acme.sh | sh"
    if [ -n "$email" ]; then cmd+=" -s email=$email"; fi
    if eval "$cmd"; then log_message SUCCESS "acme.sh 安装成功"; else log_message ERROR "acme.sh 安装失败"; return 1; fi
}

control_nginx() {
    if ! nginx -t >/dev/null 2>&1; then log_message ERROR "Nginx 配置错误"; return 1; fi
    systemctl "$1" nginx || log_message ERROR "Nginx $1 失败"
}

_get_project_json() {
    jq -c ".[] | select(.domain == \"$1\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""
}

_save_project_json() {
    local json="$1" domain=$(echo "$json" | jq -r .domain)
    local tmp=$(mktemp)
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq "(.[] | select(.domain == \"$domain\")) = $json" "$PROJECTS_METADATA_FILE" > "$tmp"
    else
        jq ". + [$json]" "$PROJECTS_METADATA_FILE" > "$tmp"
    fi
    mv "$tmp" "$PROJECTS_METADATA_FILE"
}

_delete_project_json() {
    local tmp=$(mktemp)
    jq "del(.[] | select(.domain == \"$1\"))" "$PROJECTS_METADATA_FILE" > "$tmp" && mv "$tmp" "$PROJECTS_METADATA_FILE"
}

_write_and_enable_nginx_config() {
    local domain="$1" json="$2"
    local port=$(echo "$json" | jq -r .resolved_port)
    local cert=$(echo "$json" | jq -r .cert_file)
    local key=$(echo "$json" | jq -r .key_file)
    local snippet=$(echo "$json" | jq -r .custom_snippet)
    
    local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    local inc=""
    if [[ -n "$snippet" && "$snippet" != "null" ]]; then inc="include $snippet;"; fi

    cat > "$conf" <<EOF
server {
    listen 80; listen [::]:80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2; listen [::]:443 ssl http2;
    server_name $domain;
    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    $inc
    location / {
        proxy_pass http://127.0.0.1:$port;
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

# --- 证书申请核心逻辑 (集成了新版优化) ---
_issue_and_install_certificate() {
    local json="$1"
    local domain=$(echo "$json" | jq -r .domain)
    local method=$(echo "$json" | jq -r .acme_validation_method)
    local dns_prov=$(echo "$json" | jq -r .dns_api_provider)
    local wild=$(echo "$json" | jq -r .use_wildcard)
    local ca_server=$(echo "$json" | jq -r .ca_server_name)
    local cert_file=$(echo "$json" | jq -r .cert_file)
    local key_file=$(echo "$json" | jq -r .key_file)

    log_message INFO "开始为 $domain 申请证书 ($method)..."
    
    # 1. 准备 Issue 命令
    local issue_cmd=("$ACME_BIN" --issue -d "$domain")
    if [ "$wild" = "y" ]; then issue_cmd+=("-d" "*.$domain"); fi
    if [ "$ca_server" = "letsencrypt" ]; then issue_cmd+=(--server letsencrypt); else issue_cmd+=(--server zerossl); fi
    issue_cmd+=(--force)

    # 2. 处理验证方式
    local port_conflict="false"
    local temp_stop_svc=""

    if [ "$method" = "standalone" ]; then
        issue_cmd+=(--standalone)
        if ss -tuln | grep -q ":80\s"; then
            log_message WARN "80 端口被占用，尝试自动处理..."
            temp_stop_svc=$(_detect_web_service)
            if [ -n "$temp_stop_svc" ]; then
                log_message INFO "临时停止 $temp_stop_svc..."
                systemctl stop "$temp_stop_svc"
                port_conflict="true"
            else
                log_message ERROR "无法识别占用 80 端口的服务，请手动停止。"
                return 1
            fi
        fi
    elif [ "$method" = "dns-01" ]; then
        if [ "$dns_prov" = "dns_cf" ]; then
            # 尝试从环境变量或输入获取，这里简化为假设环境变量已设置 (实际应在 gather 中设置)
            issue_cmd+=(--dns dns_cf)
        elif [ "$dns_prov" = "dns_ali" ]; then
            issue_cmd+=(--dns dns_ali)
        fi
    fi

    # 3. 执行申请
    if ! "${issue_cmd[@]}"; then
        log_message ERROR "证书申请失败！"
        if [ "$port_conflict" = "true" ]; then systemctl start "$temp_stop_svc"; fi
        return 1
    fi

    # 4. 恢复服务
    if [ "$port_conflict" = "true" ]; then
        systemctl start "$temp_stop_svc"
        log_message INFO "$temp_stop_svc 已重启。"
    fi

    # 5. 安装证书
    mkdir -p "$SSL_CERTS_BASE_DIR"
    local install_cmd=("$ACME_BIN" --install-cert -d "$domain" --ecc \
        --key-file "$key_file" --fullchain-file "$cert_file" \
        --reloadcmd "systemctl reload nginx")
    
    if [ "$wild" = "y" ]; then install_cmd+=("-d" "*.$domain"); fi
    
    if ! "${install_cmd[@]}"; then
        log_message ERROR "证书安装失败！"
        return 1
    fi
    
    log_message SUCCESS "证书申请并安装成功。"
    return 0
}

_gather_project_details() {
    local old_json="${1:-{\}}"
    local domain=$(echo "$old_json" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        domain=$(_prompt_user_input_with_validation "请输入主域名" "" "" "无效" "false") || return 1
    fi
    
    local port=$(echo "$old_json" | jq -r '.resolved_port // ""')
    port=$(_prompt_user_input_with_validation "请输入后端端口" "$port" "^[0-9]+$" "无效" "false") || return 1

    local method_idx=1
    [ "$(echo "$old_json" | jq -r .acme_validation_method)" = "dns-01" ] && method_idx=2
    local method_choice=$(_prompt_user_input_with_validation "验证方式 (1.Standalone, 2.DNS API)" "$method_idx" "^[12]$" "" "false")
    local method="standalone"
    local dns_prov=""
    local wild="n"

    if [ "$method_choice" -eq 2 ]; then
        method="dns-01"
        local prov_idx=1
        [ "$(echo "$old_json" | jq -r .dns_api_provider)" = "dns_ali" ] && prov_idx=2
        local p_choice=$(_prompt_user_input_with_validation "DNS 提供商 (1.Cloudflare, 2.Aliyun)" "$prov_idx" "^[12]$" "" "false")
        [ "$p_choice" -eq 1 ] && dns_prov="dns_cf" || dns_prov="dns_ali"
        
        # 安全提示
        log_message INFO "需设置 API 环境变量 (Token 仅暂存内存)。"
        if [ "$dns_prov" = "dns_cf" ]; then
            export CF_Token=$(_prompt_user_input_with_validation "CF_Token" "" "" "" "false")
            export CF_Account_ID=$(_prompt_user_input_with_validation "CF_Account_ID" "" "" "" "false")
        else
            export Ali_Key=$(_prompt_user_input_with_validation "Ali_Key" "" "" "" "false")
            export Ali_Secret=$(_prompt_user_input_with_validation "Ali_Secret" "" "" "" "false")
        fi
        
        local w_def=$(echo "$old_json" | jq -r '.use_wildcard // "n"')
        wild=$(_prompt_user_input_with_validation "申请泛域名? (y/n)" "$w_def" "^[yYnN]$" "" "false")
    fi

    local ca_choice=$(_prompt_user_input_with_validation "CA 机构 (1.Let's Encrypt, 2.ZeroSSL)" "1" "^[12]$" "" "false")
    local ca_name="letsencrypt"
    [ "$ca_choice" -eq 2 ] && ca_name="zerossl"

    jq -n \
        --arg d "$domain" --arg p "$port" --arg m "$method" --arg dp "$dns_prov" \
        --arg w "$wild" --arg ca "$ca_name" \
        --arg c "$SSL_CERTS_BASE_DIR/$domain.cer" --arg k "$SSL_CERTS_BASE_DIR/$domain.key" \
        '{domain:$d, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_name:$ca, cert_file:$c, key_file:$k}'
}

_display_projects_list() {
    local json="$1"
    local i=0
    echo "$json" | jq -c '.[]' | while read -r p; do
        i=$((i+1))
        local d=$(echo "$p" | jq -r .domain)
        local port=$(echo "$p" | jq -r .resolved_port)
        local cf=$(echo "$p" | jq -r .cert_file)
        
        local status="未知"; local color="$NC"; local date_str=""
        if [ -f "$cf" ]; then
            local end=$(openssl x509 -enddate -noout -in "$cf" 2>/dev/null | cut -d= -f2)
            local end_ts=$(date -d "$end" +%s 2>/dev/null)
            local now=$(date +%s)
            local left=$(( (end_ts - now) / 86400 ))
            date_str=$(date -d "$end" +%F)
            if (( left < 0 )); then color="$RED"; status="已过期";
            elif (( left < 30 )); then color="$YELLOW"; status="即将到期";
            else color="$GREEN"; status="有效"; fi
            status="$status (剩 $left 天)"
        else
            color="$RED"; status="文件丢失"
        fi

        printf "${GREEN}[ %d ] %s${NC}\n" "$i" "$d"
        printf "  ├─ 目标: 本地端口 %s\n" "$port"
        printf "  └─ 证书: ${color}%s${NC} | 到期: %s\n" "$status" "$date_str"
        echo -e "${CYAN}····························································${NC}"
    done
}

configure_nginx_projects() {
    local json; json=$(_gather_project_details) || return 1
    local d=$(echo "$json" | jq -r .domain)
    
    if ! _issue_and_install_certificate "$json"; then return 1; fi
    _write_and_enable_nginx_config "$d" "$json"
    control_nginx reload && _save_project_json "$json"
    
    # 清理环境变量
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret
}

manage_configs() {
    while true; do
        local ps; ps=$(jq . "$PROJECTS_METADATA_FILE")
        if [ "$(echo "$ps" | jq 'length')" -eq 0 ]; then log_message WARN "无项目"; break; fi
        
        _render_menu "项目列表"
        _display_projects_list "$ps"
        
        local choice=$(_prompt_for_menu_choice_local "1-3" "d-删除, r-续期")
        # 简单实现，实际可扩展选择特定项目
        if [[ "$choice" == "d" ]]; then
             local d=$(_prompt_user_input_with_validation "输入域名删除" "" "" "" "false")
             _delete_project_json "$d"; _remove_and_disable_nginx_config "$d"
        elif [[ "$choice" == "r" ]]; then
             local d=$(_prompt_user_input_with_validation "输入域名续期" "" "" "" "false")
             local p=$(_get_project_json "$d")
             [ -n "$p" ] && _issue_and_install_certificate "$p"
        elif [[ "$choice" == "" ]]; then break; fi
    done
}

# --- 入口 ---
trap 'echo -e "\n退出"; exit 10' INT
check_root
initialize_environment
install_dependencies
install_acme_sh
get_vps_ip

while true; do
    _render_menu "Nginx 代理管理器" "1. 新建配置" "2. 管理配置" "3. 退出"
    c=$(_prompt_for_menu_choice_local "1-3")
    case "$c" in
        1) configure_nginx_projects; press_enter_to_continue ;;
        2) manage_configs; press_enter_to_continue ;;
        3) exit 0 ;;
    esac
done
