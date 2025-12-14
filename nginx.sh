# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v2.4.0-UI重构版)
# - 核心: 保留基于 projects.json 的管理逻辑。
# - UI: 升级为卡片式列表，与 acme.sh 助手风格统一。
# - 修复: 增强 Ctrl+C 中断处理与交互确认。
# =============================================================

# --- 严格模式 ---
set -uo pipefail # 移除 -e 以防止 grep/jq 返回非零时意外退出，改为手动处理错误

# --- 全局变量和颜色 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
RENEW_THRESHOLD_DAYS=30

# --- Nginx 路径 ---
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
NGINX_CUSTOM_SNIPPETS_DIR="/etc/nginx/custom_snippets"
SSL_CERTS_BASE_DIR="/etc/ssl"

# --- 运行模式 ---
IS_INTERACTIVE_MODE="true"
for arg in "$@"; do
    if [[ "$arg" == "--cron" || "$arg" == "--non-interactive" ]]; then
        IS_INTERACTIVE_MODE="false"; break
    fi
done
VPS_IP=""; VPS_IPV6=""; ACME_BIN=""

# ==============================================================================
# SECTION: 通用工具函数 (UI, 日志, 交互)
# ==============================================================================

_log_prefix() { echo -n "$(date '+%Y-%m-%d %H:%M:%S') "; }

log_message() {
    local level="$1" message="$2"
    case "$level" in
        INFO)    echo -e "${CYAN}[信 息]${NC} ${message}";;
        SUCCESS) echo -e "${GREEN}[成 功]${NC} ${message}";;
        WARN)    echo -e "${YELLOW}[警 告]${NC} ${message}" >&2;;
        ERROR)   echo -e "${RED}[错 误]${NC} ${message}" >&2;;
    esac
    # 写入日志文件
    echo "[$(_log_prefix)] [${level}] ${message}" >> "$LOG_FILE"
}

generate_line() { local len=${1:-40}; printf "%${len}s" "" | sed "s/ /-/g"; }

press_enter_to_continue() {
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty
    fi
}

confirm_action() {
    local prompt="$1"
    if [ "$IS_INTERACTIVE_MODE" = "false" ]; then return 0; fi # 非交互模式默认 yes
    read -r -p "$(echo -e "${YELLOW}$prompt ([y]/n): ${NC}")" choice < /dev/tty
    case "$choice" in n|N) return 1 ;; *) return 0 ;; esac
}

_prompt_user_input() {
    local prompt="$1" default="$2" regex="$3" err_msg="$4"
    local input
    
    # 非交互模式直接返回默认值
    if [ "$IS_INTERACTIVE_MODE" = "false" ]; then
        echo "$default"; return 0
    fi

    while true; do
        local display_prompt="${prompt}"
        [ -n "$default" ] && display_prompt+=" [默认: $default]"
        
        read -r -p "$(echo -e "${YELLOW}${display_prompt}: ${NC}")" input < /dev/tty
        input=${input:-$default}

        if [ -n "$regex" ] && [[ ! "$input" =~ $regex ]]; then
            log_message ERROR "${err_msg:-输入格式错误}"
            continue
        fi
        
        # 允许空值的情况(如果regex允许空或未设置regex)
        echo "$input"
        return 0
    done
}

_prompt_for_menu_choice() {
    local range="$1"
    read -r -p "$(echo -e "${ORANGE}>${NC} 请选择 [${range}] (Enter 返回): ")" choice < /dev/tty
    echo "$choice"
}

_render_menu() {
    local title="$1"; shift
    echo ""
    echo -e "${GREEN}╭$(generate_line 50 "─")╮${NC}"
    local padding=$(( (50 - ${#title}) / 2 ))
    printf "${GREEN}│${NC}%*s${BOLD}%s${NC}%*s${GREEN}│${NC}\n" $padding "" "$title" $padding ""
    echo -e "${GREEN}├$(generate_line 50 "─")┤${NC}"
    for line in "$@"; do
        echo -e "${GREEN}│${NC} $line"
    done
    echo -e "${GREEN}╰$(generate_line 50 "─")╯${NC}"
}

cleanup_temp_files() {
    # 清理逻辑
    : 
}
# 设置中断陷阱
trap 'echo -e "\n${RED}[中断] 用户取消操作。${NC}"; exit 1' INT

check_root() {
    if [ "$(id -u)" -ne 0 ]; then log_message ERROR "请使用 root 用户运行。"; exit 1; fi
}

get_vps_ip() {
    VPS_IP=$(curl -s https://api.ipify.org)
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "")
}

# ==============================================================================
# SECTION: 核心业务逻辑 (Nginx & ACME)
# ==============================================================================

initialize_environment() {
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" \
               "$NGINX_CUSTOM_SNIPPETS_DIR" "$SSL_CERTS_BASE_DIR"
    
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
    fi
}

install_dependencies() {
    local deps="nginx curl socat openssl jq"
    for pkg in $deps; do
        if ! command -v "$pkg" &>/dev/null; then
            log_message WARN "正在安装依赖: $pkg ..."
            if command -v apt &>/dev/null; then apt update -y && apt install -y "$pkg"
            elif command -v yum &>/dev/null; then yum install -y "$pkg"
            fi
        fi
    done
    
    if [ ! -f "$ACME_BIN" ]; then
        log_message WARN "安装 acme.sh ..."
        local email; email=$(_prompt_user_input "请输入邮箱(注册ACME)" "" "" "")
        curl https://get.acme.sh | sh -s email="$email"
        source ~/.bashrc
    fi
}

control_nginx() {
    local action="$1"
    if ! nginx -t >/dev/null 2>&1; then
        log_message ERROR "Nginx 配置语法错误！请检查配置文件。"
        return 1
    fi
    systemctl "$action" nginx
}

# --- JSON 操作封装 ---
_get_project_json() {
    jq -c ".[] | select(.domain == \"$1\")" "$PROJECTS_METADATA_FILE" 2>/dev/null
}

_save_project_json() {
    local json="$1"
    local domain; domain=$(echo "$json" | jq -r .domain)
    local tmp; tmp=$(mktemp)
    
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq "(.[] | select(.domain == \"$domain\")) = $json" "$PROJECTS_METADATA_FILE" > "$tmp"
    else
        jq ". + [$json]" "$PROJECTS_METADATA_FILE" > "$tmp"
    fi
    mv "$tmp" "$PROJECTS_METADATA_FILE"
}

_delete_project_json() {
    local domain="$1"
    local tmp; tmp=$(mktemp)
    jq "del(.[] | select(.domain == \"$domain\"))" "$PROJECTS_METADATA_FILE" > "$tmp"
    mv "$tmp" "$PROJECTS_METADATA_FILE"
}

# --- Nginx 配置生成 ---
_write_nginx_config() {
    local domain="$1" project_json="$2"
    local port; port=$(echo "$project_json" | jq -r .resolved_port)
    local snippet; snippet=$(echo "$project_json" | jq -r .custom_snippet)
    
    local conf_str="
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate /etc/ssl/${domain}.cer;
    ssl_certificate_key /etc/ssl/${domain}.key;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
    
    $( [ -n "$snippet" ] && [ "$snippet" != "null" ] && echo "include $snippet;" )

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }
}"
    echo "$conf_str" > "$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    ln -sf "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" "$NGINX_SITES_ENABLED_DIR/"
}

# --- 证书申请逻辑 ---
_issue_cert() {
    local json="$1"
    local domain; domain=$(echo "$json" | jq -r .domain)
    local method; method=$(echo "$json" | jq -r .acme_validation_method)
    local ca; ca=$(echo "$json" | jq -r .ca_server_url)
    
    log_message INFO "正在为 $domain 申请证书 (CA: $ca)..."
    
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca")
    
    if [ "$method" = "http-01" ]; then
        cmd+=("-w" "$NGINX_WEBROOT_DIR")
        # 生成临时验证配置
        echo "server { listen 80; server_name $domain; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }" > "$NGINX_SITES_AVAILABLE_DIR/acme_temp.conf"
        ln -sf "$NGINX_SITES_AVAILABLE_DIR/acme_temp.conf" "$NGINX_SITES_ENABLED_DIR/"
        control_nginx reload
    elif [ "$method" = "dns-01" ]; then
        local dns; dns=$(echo "$json" | jq -r .dns_api_provider)
        cmd+=("--dns" "$dns")
    fi
    
    if ! "${cmd[@]}"; then
        log_message ERROR "证书申请失败！"
        [ -f "$HOME/.acme.sh/acme.sh.log" ] && tail -n 10 "$HOME/.acme.sh/acme.sh.log"
        # 清理临时配置
        [ "$method" = "http-01" ] && { rm "$NGINX_SITES_ENABLED_DIR/acme_temp.conf"; control_nginx reload; }
        return 1
    fi
    
    [ "$method" = "http-01" ] && { rm "$NGINX_SITES_ENABLED_DIR/acme_temp.conf"; }
    
    log_message INFO "正在安装证书..."
    "$ACME_BIN" --install-cert --ecc -d "$domain" \
        --key-file "/etc/ssl/${domain}.key" \
        --fullchain-file "/etc/ssl/${domain}.cer" \
        --reloadcmd "systemctl reload nginx"
        
    return 0
}

# ==============================================================================
# SECTION: 用户交互与菜单
# ==============================================================================

# 收集项目信息 (交互式)
_gather_info() {
    local exist_json="${1:-}"
    local domain def_port def_method
    
    # 提取默认值
    if [ -n "$exist_json" ]; then
        domain=$(echo "$exist_json" | jq -r .domain)
        def_port=$(echo "$exist_json" | jq -r .resolved_port)
        def_method=$(echo "$exist_json" | jq -r .acme_validation_method)
    else
        domain=$(_prompt_user_input "请输入域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式错误")
    fi
    
    local port=$(_prompt_user_input "后端端口 (Docker/本地端口)" "$def_port" "^[0-9]+$" "必须是数字")
    
    local method="http-01"
    echo -e "${YELLOW}选择验证方式:${NC} 1. HTTP验证(80端口)  2. DNS API"
    local m_choice=$(_prompt_user_input "选择" "1" "^[12]$" "")
    [ "$m_choice" == "2" ] && method="dns-01"
    
    local dns_provider=""
    if [ "$method" == "dns-01" ]; then
        echo -e "${YELLOW}DNS 提供商:${NC} 1. Cloudflare  2. Aliyun"
        local d_choice=$(_prompt_user_input "选择" "1" "^[12]$" "")
        [ "$d_choice" == "1" ] && dns_provider="dns_cf" || dns_provider="dns_ali"
    fi
    
    # 构造 JSON
    jq -n \
        --arg d "$domain" --arg p "$port" --arg m "$method" --arg dns "$dns_provider" \
        --arg ca "https://acme-v02.api.letsencrypt.org/directory" \
        '{domain: $d, resolved_port: $p, acme_validation_method: $m, dns_api_provider: $dns, ca_server_url: $ca, cert_file: ("/etc/ssl/"+$d+".cer"), key_file: ("/etc/ssl/"+$d+".key")}'
}

# 显示项目列表 (卡片式)
_list_projects() {
    local projects; projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE")
    if [ -z "$projects" ]; then echo -e "${YELLOW}当前无项目。${NC}"; return; fi
    
    local i=0
    echo "$projects" | while read -r p; do
        i=$((i+1))
        local d=$(echo "$p" | jq -r .domain)
        local port=$(echo "$p" | jq -r .resolved_port)
        local cert=$(echo "$p" | jq -r .cert_file)
        
        local status="${RED}缺失${NC}"
        local expire=""
        
        if [ -f "$cert" ]; then
            local end_date=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
            local end_ts=$(date -d "$end_date" +%s)
            local now_ts=$(date +%s)
            local left=$(( (end_ts - now_ts) / 86400 ))
            
            if (( left < 0 )); then status="${RED}已过期${NC}"
            elif (( left < 30 )); then status="${YELLOW}临期($left天)${NC}"
            else status="${GREEN}有效${NC}"; fi
            expire="(${left}天, $(date -d "$end_date" +%Y-%m-%d))"
        fi
        
        printf "${GREEN}[ %d ] %s${NC}\n" "$i" "$d"
        printf "  ├─ 目标: %s\n" "127.0.0.1:$port"
        printf "  └─ 证书: %s %s\n" "$status" "$expire"
        echo -e "${CYAN}··················································${NC}"
    done
}

# --- 菜单动作处理 ---

action_new() {
    local json; json=$(_gather_info)
    local domain; domain=$(echo "$json" | jq -r .domain)
    
    if [ -n "$(_get_project_json "$domain")" ]; then
        if ! confirm_action "域名 $domain 已存在，是否覆盖?"; then return; fi
    fi
    
    if _issue_cert "$json"; then
        _write_nginx_config "$domain" "$json"
        _save_project_json "$json"
        control_nginx reload
        log_message SUCCESS "配置完成！"
    fi
}

action_renew_all() {
    if ! confirm_action "确定要检查并续期所有证书吗？"; then return; fi
    
    local renewed=0
    # 临时文件存 JSON 列表
    local tmp_list=$(mktemp)
    jq -c '.[]' "$PROJECTS_METADATA_FILE" > "$tmp_list"
    
    while read -r p; do
        local d=$(echo "$p" | jq -r .domain)
        local cert=$(echo "$p" | jq -r .cert_file)
        
        if [ ! -f "$cert" ]; then
            log_message WARN "$d 证书文件缺失，尝试重新申请..."
            _issue_cert "$p" && renewed=$((renewed+1))
            continue
        fi
        
        # 检查是否过期 (30天)
        if ! openssl x509 -checkend $((30 * 86400)) -noout -in "$cert" >/dev/null; then
            log_message INFO "$d 证书即将到期，正在续期..."
            _issue_cert "$p" && renewed=$((renewed+1))
        else
            log_message INFO "$d 证书有效，跳过。"
        fi
    done < "$tmp_list"
    rm "$tmp_list"
    
    if [ "$renewed" -gt 0 ]; then
        control_nginx reload
        log_message SUCCESS "完成！共续期 $renewed 个证书。"
    else
        log_message INFO "所有证书均在有效期内。"
    fi
}

action_delete() {
    local domain=$(_prompt_user_input "请输入要删除的域名" "" "" "")
    if [ -z "$(_get_project_json "$domain")" ]; then log_message ERROR "项目不存在。"; return; fi
    
    if confirm_action "⚠️ 确认彻底删除 $domain (含Nginx配置和证书)?"; then
        rm -f "$NGINX_SITES_ENABLED_DIR/$domain.conf"
        rm -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
        "$ACME_BIN" --remove -d "$domain" --ecc >/dev/null 2>&1
        rm -f "/etc/ssl/${domain}.cer" "/etc/ssl/${domain}.key"
        _delete_project_json "$domain"
        control_nginx reload
        log_message SUCCESS "删除成功。"
    fi
}

action_manage_acme() {
    local choice=$(_prompt_for_menu_choice "1-2")
    if [ "$choice" == "1" ]; then
        "$ACME_BIN" --list
    elif [ "$choice" == "2" ]; then
        local email=$(_prompt_user_input "邮箱" "" "" "")
        "$ACME_BIN" --register-account -m "$email" --server letsencrypt
    fi
}

main_menu() {
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then clear; fi
        _render_menu "Nginx 证书管理系统" \
            "1. 配置新项目 (Nginx + SSL)" \
            "2. 项目列表" \
            "3. 批量检查续期" \
            "4. 删除项目" \
            "5. ACME 账户管理"
        
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            _list_projects # 在主菜单下方常驻显示简略列表
        fi

        local choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) action_new; press_enter_to_continue ;;
            2) press_enter_to_continue ;; # 列表已显示，暂停即可
            3) action_renew_all; press_enter_to_continue ;;
            4) action_delete; press_enter_to_continue ;;
            5) action_manage_acme; press_enter_to_continue ;;
            "") exit 0 ;;
            *) log_message ERROR "无效选项" ;;
        esac
    done
}

# --- 入口 ---
check_root
initialize_environment
install_dependencies

if [ "$IS_INTERACTIVE_MODE" = "false" ]; then
    action_renew_all
else
    main_menu
fi
