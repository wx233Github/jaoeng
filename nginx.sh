# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v3.0.0-深度重构版)
# =============================================================
# - 优化: UI 交互全面对齐 acme.sh 脚本风格 (卡片列表/统一菜单)。
# - 修复: 智能服务检测、中断处理、依赖管理。
# - 新增: 更健壮的项目配置逻辑与状态显示。

set -euo pipefail

# --- 全局配置 ---
LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
RENEW_THRESHOLD_DAYS=30

# --- Nginx 路径 ---
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
NGINX_CUSTOM_SNIPPETS_DIR="/etc/nginx/custom_snippets"
SSL_CERTS_BASE_DIR="/etc/ssl"

# --- 模式判断 ---
IS_INTERACTIVE_MODE="true"
if [[ " $* " =~ " --cron " || " $* " =~ " --non-interactive " ]]; then
    IS_INTERACTIVE_MODE="false"
fi

# --- 加载通用工具函数库 (内联简化版，确保独立运行) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m';

_log_prefix() { echo -n "$(date '+%Y-%m-%d %H:%M:%S') "; }
log_message() {
    local level="$1" msg="$2"
    case "$level" in
        INFO) echo -e "$(_log_prefix)${CYAN}[信息]${NC} $msg";;
        SUCCESS) echo -e "$(_log_prefix)${GREEN}[成功]${NC} $msg";;
        WARN) echo -e "$(_log_prefix)${YELLOW}[警告]${NC} $msg" >&2;;
        ERROR) echo -e "$(_log_prefix)${RED}[错误]${NC} $msg" >&2;;
    esac
    echo "[$(_log_prefix)] [$level] $msg" >> "$LOG_FILE"
}

generate_line() { local len=${1:-40}; printf "%${len}s" "" | sed "s/ /-/g"; }
press_enter_to_continue() { [ "$IS_INTERACTIVE_MODE" = "true" ] && read -r -p "按 Enter 继续..."; }
confirm_action() { 
    [ "$IS_INTERACTIVE_MODE" = "false" ] && return 0
    read -r -p "$1 ([y]/n): " c; [[ "$c" == "n" || "$c" == "N" ]] && return 1 || return 0
}
_prompt_user_input() { 
    local p="$1" d="$2"
    if [ "$IS_INTERACTIVE_MODE" = "false" ]; then echo "$d"; return; fi
    read -r -p "${YELLOW}$p${NC} ${d:+[默认: $d] }: " v; echo "${v:-$d}"
}
_prompt_for_menu_choice() { 
    if [ "$IS_INTERACTIVE_MODE" = "false" ]; then return 1; fi
    read -r -p "${ORANGE}请选择 [$1] (Enter返回): ${NC}" v; echo "$v"
}
_render_menu() { echo ""; echo "--- $1 ---"; shift; for l in "$@"; do echo -e "$l"; done; echo ""; }

# --- 核心辅助函数 ---
check_root() { if [ "$(id -u)" -ne 0 ]; then log_message ERROR "需 root 权限。"; exit 1; fi; }
cleanup_temp() { rm -f /tmp/acme_cmd_log.* 2>/dev/null; }
trap cleanup_temp EXIT
trap 'log_message WARN "操作中断。"; exit 10' INT

# --- 初始化环境 ---
initialize_environment() {
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$NGINX_CUSTOM_SNIPPETS_DIR" "$SSL_CERTS_BASE_DIR"
    if [ ! -f "$PROJECTS_METADATA_FILE" ]; then echo "[]" > "$PROJECTS_METADATA_FILE"; fi
    
    # 依赖检查
    local deps="nginx curl socat openssl jq"
    for pkg in $deps; do
        if ! command -v "$pkg" &>/dev/null; then
            log_message WARN "安装依赖: $pkg..."
            apt-get update -qq && apt-get install -y -qq "$pkg" >/dev/null || yum install -y -q "$pkg" >/dev/null
        fi
    done
    
    # acme.sh 检查
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    if [ ! -f "$ACME_BIN" ]; then
        log_message WARN "安装 acme.sh..."
        curl https://get.acme.sh | sh -s email=my@example.com >/dev/null
    fi
}

# --- 项目配置管理 (JSON) ---
_get_project() { jq -c ".[] | select(.domain == \"$1\")" "$PROJECTS_METADATA_FILE" 2>/dev/null; }
_save_project() {
    local json="$1" domain=$(echo "$json" | jq -r .domain)
    local tmp=$(mktemp)
    if [ -n "$(_get_project "$domain")" ]; then
        jq "(.[] | select(.domain == \"$domain\")) = $json" "$PROJECTS_METADATA_FILE" > "$tmp"
    else
        jq ". + [$json]" "$PROJECTS_METADATA_FILE" > "$tmp"
    fi
    mv "$tmp" "$PROJECTS_METADATA_FILE"
}
_delete_project() {
    local domain="$1" tmp=$(mktemp)
    jq "del(.[] | select(.domain == \"$domain\"))" "$PROJECTS_METADATA_FILE" > "$tmp" && mv "$tmp" "$PROJECTS_METADATA_FILE"
}

# --- Nginx 配置生成 ---
_write_nginx_conf() {
    local domain="$1" json="$2"
    local port=$(echo "$json" | jq -r .resolved_port)
    local cert=$(echo "$json" | jq -r .cert_file)
    local key=$(echo "$json" | jq -r .key_file)
    local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    
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
    systemctl reload nginx || log_message ERROR "Nginx 重载失败，请检查配置。"
}

# --- 证书申请流程 ---
_issue_cert() {
    local json="$1"
    local domain=$(echo "$json" | jq -r .domain)
    local method=$(echo "$json" | jq -r .acme_validation_method)
    local ca=$(echo "$json" | jq -r .ca_server_url)
    
    log_message INFO "开始为 $domain 申请证书..."
    
    local cmd=("$ACME_BIN" --issue -d "$domain" --server "$ca" --force)
    
    if [ "$method" = "http-01" ]; then
        # 临时 Nginx 配置用于验证
        local v_conf="$NGINX_SITES_AVAILABLE_DIR/acme_temp.conf"
        echo "server { listen 80; server_name $domain; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }" > "$v_conf"
        ln -sf "$v_conf" "$NGINX_SITES_ENABLED_DIR/" && systemctl reload nginx
        cmd+=(-w "$NGINX_WEBROOT_DIR")
    else
        # DNS 模式需用户提前配置好环境变量 (简化处理)
        local provider=$(echo "$json" | jq -r .dns_api_provider)
        cmd+=(--dns "$provider")
    fi
    
    if "${cmd[@]}"; then
        log_message SUCCESS "证书申请成功。"
        "$ACME_BIN" --install-cert -d "$domain" \
            --key-file "$(echo "$json" | jq -r .key_file)" \
            --fullchain-file "$(echo "$json" | jq -r .cert_file)" \
            --reloadcmd "systemctl reload nginx"
        local ret=$?
        # 清理临时验证配置
        [ "$method" = "http-01" ] && rm -f "$v_conf" "$NGINX_SITES_ENABLED_DIR/acme_temp.conf" && systemctl reload nginx
        return $ret
    else
        log_message ERROR "申请失败。"
        [ "$method" = "http-01" ] && rm -f "$v_conf" "$NGINX_SITES_ENABLED_DIR/acme_temp.conf" && systemctl reload nginx
        return 1
    fi
}

# --- 核心功能菜单 ---

# 1. 配置新项目
configure_project() {
    log_message INFO ">>> 配置新项目"
    local domain=$(_prompt_user_input "请输入域名" "")
    [ -z "$domain" ] && return
    
    # 检查是否已存在
    if [ -n "$(_get_project "$domain")" ]; then
        confirm_action "项目已存在，是否覆盖?" || return
    fi
    
    local port=$(_prompt_user_input "请输入后端端口 (如 8080)" "")
    local method=$(_prompt_user_input "验证方式 (1.http 2.dns)" "1")
    local method_str="http-01"
    local dns_provider=""
    
    if [ "$method" == "2" ]; then
        method_str="dns-01"
        local dp=$(_prompt_user_input "DNS提供商 (1.cf 2.ali)" "1")
        [ "$dp" == "1" ] && dns_provider="dns_cf" || dns_provider="dns_ali"
        log_message WARN "请确保已在当前 Shell 导出 API 环境变量 (CF_Token 等)。"
    fi
    
    # 构建 JSON
    local cert_path="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key_path="$SSL_CERTS_BASE_DIR/$domain.key"
    local json=$(jq -n \
        --arg d "$domain" --arg p "$port" --arg m "$method_str" \
        --arg dp "$dns_provider" --arg c "$cert_path" --arg k "$key_path" \
        --arg ca "https://acme-v02.api.letsencrypt.org/directory" \
        '{domain:$d, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, cert_file:$c, key_file:$k, ca_server_url:$ca}')
    
    if _issue_cert "$json"; then
        _write_nginx_conf "$domain" "$json"
        _save_project "$json"
        log_message SUCCESS "项目 $domain 配置完成。"
    fi
}

# 2. 管理项目
manage_projects() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null)
        if [ -z "$projects" ]; then log_message WARN "暂无项目。"; return; fi
        
        echo ""; echo "--- 项目列表 ---"
        local i=0
        local domains=()
        while read -r p; do
            i=$((i+1))
            local d=$(echo "$p" | jq -r .domain)
            local port=$(echo "$p" | jq -r .resolved_port)
            local cert=$(echo "$p" | jq -r .cert_file)
            domains+=("$d")
            
            # 状态检查
            local status_text="${RED}未配置${NC}"
            if [ -f "$cert" ]; then
                local end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
                local end_ts=$(date -d "$end" +%s)
                local days=$(( (end_ts - $(date +%s)) / 86400 ))
                if [ $days -gt 30 ]; then status_text="${GREEN}有效 ($days天)${NC}"; else status_text="${YELLOW}即将过期 ($days天)${NC}"; fi
            fi
            
            printf "[ %d ] %-20s -> :%-5s | %s\n" "$i" "$d" "$port" "$status_text"
        done <<< "$projects"
        
        local choice_idx=$(_prompt_user_input "输入序号管理 (Enter返回)" "")
        [ -z "$choice_idx" ] && return
        
        if ! [[ "$choice_idx" =~ ^[0-9]+$ ]] || [ "$choice_idx" -gt "${#domains[@]}" ]; then
            log_message ERROR "无效序号。"
            continue
        fi
        
        local sel_domain="${domains[$((choice_idx-1))]}"
        local sel_json=$(_get_project "$sel_domain")
        
        _render_menu "管理: $sel_domain" "1. 手动续期" "2. 修改端口" "3. 删除项目"
        local act=$(_prompt_user_input "选择操作" "")
        
        case "$act" in
            1) _issue_cert "$sel_json" && press_enter_to_continue ;;
            2) 
                local new_port=$(_prompt_user_input "新端口" "")
                if [ -n "$new_port" ]; then
                    local new_json=$(echo "$sel_json" | jq --arg p "$new_port" '.resolved_port = $p')
                    _write_nginx_conf "$sel_domain" "$new_json"
                    _save_project "$new_json"
                    log_message SUCCESS "端口已更新。"
                fi
                ;;
            3)
                if confirm_action "确认删除 $sel_domain ?"; then
                    rm -f "$NGINX_SITES_AVAILABLE_DIR/$sel_domain.conf" "$NGINX_SITES_ENABLED_DIR/$sel_domain.conf"
                    systemctl reload nginx
                    _delete_project "$sel_domain"
                    log_message SUCCESS "已删除。"
                fi
                ;;
        esac
    done
}

# 3. 自动续期检测
auto_renew_all() {
    log_message INFO "开始检查所有证书..."
    local projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null)
    while read -r p; do
        local d=$(echo "$p" | jq -r .domain)
        local cert=$(echo "$p" | jq -r .cert_file)
        
        if [ ! -f "$cert" ]; then
            log_message WARN "$d 证书丢失，尝试重新申请..."
            _issue_cert "$p"
            continue
        fi
        
        if ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$cert"; then
            log_message WARN "$d 证书即将过期，续期中..."
            _issue_cert "$p"
        else
            log_message INFO "$d 证书有效，跳过。"
        fi
    done <<< "$projects"
    log_message SUCCESS "检查完成。"
}

# --- 主菜单 ---
main_menu() {
    while true; do
        _render_menu "Nginx 代理 & 证书管理" \
            "1. 配置新代理 (New Proxy)" \
            "2. 项目管理 (Manage)" \
            "3. 批量续期检测 (Renew All)"
            
        local c=$(_prompt_for_menu_choice "1-3")
        case "$c" in
            1) configure_project; press_enter_to_continue ;;
            2) manage_projects ;;
            3) 
                if confirm_action "确认检查所有证书?"; then
                    auto_renew_all
                    press_enter_to_continue
                fi
                ;;
            "") exit 0 ;;
        esac
    done
}

# --- 入口 ---
check_root
initialize_environment

if [ "$IS_INTERACTIVE_MODE" = "false" ]; then
    auto_renew_all
else
    main_menu
fi
