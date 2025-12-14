# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v2.7.0-深度优化版)
# =============================================================
# - 逻辑: 引入 ECC 证书路径自动探测，修复路径拼接隐患。
# - 交互: 新增 CA 机构选择，泛域名默认关闭以降低错误率。
# - 健壮: 增强 HTTP 验证模式下的端口冲突检测。

set -euo pipefail

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
# SECTION: 核心工具函数 & UI 渲染
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
    local text="${ORANGE}👉 选项 [${range}]${NC} (↩ 返回): "
    local choice; read -r -p "$(echo -e "$text")" choice < /dev/tty
    echo "$choice"
}

generate_line() {
    local len=${1:-40}; printf "%${len}s" "" | sed "s/ /─/g"
}

_render_menu() {
    local title="$1"; shift; local -a lines=("$@")
    local max_width=42
    for line in "${lines[@]}"; do
        local len=${#line}
        [ "$len" -gt "$max_width" ] && max_width=$len
    done
    max_width=$((max_width + 4))

    echo ""
    echo -e "${GREEN}╭$(generate_line "$max_width")╮${NC}"
    
    local title_len=${#title}
    local pad_left=$(( (max_width - title_len) / 2 ))
    local pad_right=$(( max_width - title_len - pad_left ))
    echo -e "${GREEN}│${NC}$(printf "%${pad_left}s" "")${BOLD}${title}${NC}$(printf "%${pad_right}s" "")${GREEN}│${NC}"
    echo -e "${GREEN}├$(generate_line "$max_width")┤${NC}"
    
    for line in "${lines[@]}"; do
        local plain=$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')
        local p_len=${#plain}
        local pad=$(( max_width - p_len - 2 ))
        echo -e "${GREEN}│${NC} ${line}$(printf "%${pad}s" "")${GREEN}│${NC}"
    done
    echo -e "${GREEN}╰$(generate_line "$max_width")╯${NC}"
}

cleanup_temp_files() {
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
}
trap cleanup_temp_files EXIT

check_root() {
    if [ "$(id -u)" -ne 0 ]; then log_message ERROR "请使用 root 用户运行此操作。"; return 1; fi
    return 0
}

get_vps_ip() {
    VPS_IP=$(curl -s https://api.ipify.org)
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "")
}

_prompt_user_input_with_validation() {
    local prompt="$1" default="$2" regex="$3" error_msg="$4" allow_empty="${5:-false}" val=""
    
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local disp=""
            if [ -n "$default" ]; then disp=" [默认: ${default}]"
            elif [ "$allow_empty" = "true" ]; then disp=" [可空]"
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
    local deps="nginx curl socat openssl jq idn dnsutils nano"
    local missing=0
    for pkg in $deps; do
        if ! command -v "$pkg" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null; then
            log_message WARN "缺失: $pkg，安装中..."
            apt update -y >/dev/null 2>&1 && apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "安装 $pkg 失败"; return 1; }
            missing=1
        fi
    done
    [ "$missing" -eq 1 ] && log_message SUCCESS "依赖就绪。"
    return 0
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then return 0; fi
    log_message WARN "acme.sh 未安装，开始安装..."
    local email; email=$(_prompt_user_input_with_validation "注册邮箱" "" "" "" "true")
    local cmd="curl https://get.acme.sh | sh"
    [ -n "$email" ] && cmd+=" -s email=$email"
    if eval "$cmd"; then initialize_environment; log_message SUCCESS "acme.sh 安装成功"; return 0; fi
    log_message ERROR "acme.sh 安装失败"; return 1
}

control_nginx() {
    local action="$1"
    if ! nginx -t >/dev/null 2>&1; then log_message ERROR "Nginx 配置错误"; nginx -t; return 1; fi
    systemctl "$action" nginx || { log_message ERROR "Nginx $action 失败"; return 1; }
    return 0
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
    # 路径使用保存的绝对路径
    local cert=$(echo "$json" | jq -r .cert_file)
    local key=$(echo "$json" | jq -r .key_file)

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

# ==============================================================================
# SECTION: 业务逻辑 (证书申请)
# ==============================================================================

_issue_and_install_certificate() {
    local json="$1"
    local domain=$(echo "$json" | jq -r .domain)
    local method=$(echo "$json" | jq -r .acme_validation_method)
    local provider=$(echo "$json" | jq -r .dns_api_provider)
    local wildcard=$(echo "$json" | jq -r .use_wildcard)
    local ca=$(echo "$json" | jq -r .ca_server_url)
    
    # 动态获取安装路径
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key="$SSL_CERTS_BASE_DIR/$domain.key"

    log_message INFO "正在为 $domain 申请证书 ($method)..."
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca")
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    # 安全：DNS 密钥实时询问，用后即焚
    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            log_message INFO "🔐 请输入 Cloudflare Token (仅内存暂存)"
            local t=$(_prompt_user_input_with_validation "CF_Token" "" "" "不能为空" "false")
            local a=$(_prompt_user_input_with_validation "Account_ID" "" "" "不能为空" "false")
            export CF_Token="$t" CF_Account_ID="$a"
        elif [ "$provider" = "dns_ali" ]; then
            log_message INFO "🔐 请输入 Aliyun Key (仅内存暂存)"
            local k=$(_prompt_user_input_with_validation "Ali_Key" "" "" "不能为空" "false")
            local s=$(_prompt_user_input_with_validation "Ali_Secret" "" "" "不能为空" "false")
            export Ali_Key="$k" Ali_Secret="$s"
        fi
        cmd+=("--dns" "$provider")
    elif [ "$method" = "http-01" ]; then
        cmd+=("-w" "$NGINX_WEBROOT_DIR")
        cat > "$NGINX_SITES_AVAILABLE_DIR/acme.temp" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root ${NGINX_WEBROOT_DIR}; } }
EOF
        ln -sf "$NGINX_SITES_AVAILABLE_DIR/acme.temp" "$NGINX_SITES_ENABLED_DIR/"
        
        # 增强: 确保 Nginx 正常重载
        if ! control_nginx reload; then
            log_message ERROR "Nginx 重载失败，无法进行 HTTP 验证。"
            return 1
        fi
    fi

    local log_temp=$(mktemp)
    if ! "${cmd[@]}" > "$log_temp" 2>&1; then
        log_message ERROR "申请失败: $domain"; cat "$log_temp"; rm -f "$log_temp"
        [ "$method" = "http-01" ] && { _remove_and_disable_nginx_config "acme.temp"; control_nginx reload; }
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    rm -f "$log_temp"
    [ "$method" = "http-01" ] && _remove_and_disable_nginx_config "acme.temp"

    log_message INFO "证书签发成功，安装中..."
    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --reloadcmd "true")
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
    local cur="${1:-{\}}"
    local domain=$(echo "$cur" | jq -r '.domain // ""')
    
    if [ -z "$domain" ]; then
        domain=$(_prompt_user_input_with_validation "🌐 主域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "格式无效" "false") || return 1
    fi
    
    local name=$(echo "$cur" | jq -r '.name // ""')
    local target=$(_prompt_user_input_with_validation "🔌 后端目标 (容器名/端口)" "$name" "" "" "false") || return 1
    
    local type="local_port" port="$target"
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -wq "$target"; then
        type="docker"
        port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' | head -n1)
        if [ -z "$port" ]; then
            port=$(_prompt_user_input_with_validation "⚠️ 未检测到端口，手动输入" "80" "^[0-9]+$" "无效端口" "false") || return 1
        fi
    fi

    local m_idx=$([ "$(echo "$cur" | jq -r '.acme_validation_method')" = "dns-01" ] && echo "2" || echo "1")
    local m_sel=$(_prompt_user_input_with_validation "🔒 验证方式 (1.http, 2.dns)" "$m_idx" "^[12]$" "" "false")
    local method=$([ "$m_sel" -eq 1 ] && echo "http-01" || echo "dns-01")
    
    local provider="" wildcard="n"
    if [ "$method" = "dns-01" ]; then
        local p_idx=$([ "$(echo "$cur" | jq -r '.dns_api_provider')" = "dns_ali" ] && echo "2" || echo "1")
        local p_sel=$(_prompt_user_input_with_validation "📡 DNS提供商 (1.CF, 2.Ali)" "$p_idx" "^[12]$" "" "false")
        provider=$([ "$p_sel" -eq 1 ] && echo "dns_cf" || echo "dns_ali")
        # 优化: 泛域名默认选 N，防止新手错误
        wildcard=$(_prompt_user_input_with_validation "✨ 申请泛域名 (y/[n])" "$(echo "$cur" | jq -r '.use_wildcard // "n"')" "^[yYnN]$" "" "false")
    fi

    local c_idx=$([ "$(echo "$cur" | jq -r '.ca_server_name')" = "zerossl" ] && echo "2" || echo "1")
    local c_sel=$(_prompt_user_input_with_validation "🏢 选择CA (1.LE, 2.ZeroSSL)" "$c_idx" "^[12]$" "" "false")
    local ca_name=$([ "$c_sel" -eq 1 ] && echo "letsencrypt" || echo "zerossl")
    local ca_url=$([ "$c_sel" -eq 1 ] && echo "https://acme-v02.api.letsencrypt.org/directory" || echo "https://acme.zerossl.com/v2/DV90")
    
    # 自动探测 ECC 路径（与证书脚本逻辑保持一致）
    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"
    local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    
    jq -n \
        --arg d "$domain" --arg t "$type" --arg n "$target" --arg p "$port" \
        --arg m "$method" --arg dp "$provider" --arg w "$wildcard" \
        --arg cu "$ca_url" --arg cn "$ca_name" \
        --arg cf "$cf" --arg kf "$kf" \
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf}'
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
        
        local info="Port: $port"
        [ "$type" = "docker" ] && info="Docker: $(echo "$p" | jq -r '.name') ($port)"
        
        local status="${RED}缺失${NC}"
        local details=""
        
        # 增强: 检查是否存在
        if [[ -f "$cert" ]]; then
            local end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            local ts=$(date -d "$end" +%s 2>/dev/null || echo 0)
            local days=$(( (ts - $(date +%s)) / 86400 ))
            
            if (( days < 0 )); then status="${RED}已过期${NC}";
            elif (( days <= 30 )); then status="${YELLOW}即将到期${NC}";
            else status="${GREEN}有效${NC}"; fi
            details="(${days}天)"
        fi
        
        printf "${GREEN}[ %d ] %s${NC}\n" "$idx" "$domain"
        printf "  ├─ 🎯 目标 : %s\n" "$info"
        printf "  └─ 📜 证书 : %s %s\n" "$status" "$details"
        echo -e "${CYAN}····························································${NC}"
    done
}

configure_nginx_projects() {
    local json; json=$(_gather_project_details) || return
    local domain=$(echo "$json" | jq -r .domain)

    if [ -n "$(_get_project_json "$domain")" ]; then
        _confirm_action_or_exit_non_interactive "域名 $domain 已存在，是否覆盖？" || return
    fi

    if ! _issue_and_install_certificate "$json"; then
        log_message ERROR "配置失败：证书申请未通过。"
        return
    fi
    
    _write_and_enable_nginx_config "$domain" "$json"
    if ! control_nginx reload; then
        _remove_and_disable_nginx_config "$domain"
        return
    fi

    _save_project_json "$json"
    log_message SUCCESS "项目 $domain 配置完成。"
}

_handle_renew_cert() {
    local d; d=$(_prompt_user_input_with_validation "请输入域名" "" "" "" "false") || return
    local p=$(_get_project_json "$d")
    [ -z "$p" ] && { log_message ERROR "项目不存在"; return; }
    _issue_and_install_certificate "$p" && control_nginx reload
}

_handle_delete_project() {
    local d; d=$(_prompt_user_input_with_validation "请输入域名" "" "" "" "false") || return
    [ -z "$(_get_project_json "$d")" ] && { log_message ERROR "项目不存在"; return; }
    
    if _confirm_action_or_exit_non_interactive "确认彻底删除 $d 及其证书？"; then
        _remove_and_disable_nginx_config "$d"
        "$ACME_BIN" --remove -d "$d" --ecc >/dev/null 2>&1
        rm -f "$SSL_CERTS_BASE_DIR/$d.cer" "$SSL_CERTS_BASE_DIR/$d.key"
        _delete_project_json "$d"
        control_nginx reload
    fi
}

_handle_edit_project() {
    local d; d=$(_prompt_user_input_with_validation "请输入域名" "" "" "" "false") || return
    local cur=$(_get_project_json "$d")
    [ -z "$cur" ] && { log_message ERROR "项目不存在"; return; }

    local new; new=$(_gather_project_details "$cur") || return
    if _issue_and_install_certificate "$new"; then
        _write_and_enable_nginx_config "$d" "$new"
        control_nginx reload && _save_project_json "$new" && log_message SUCCESS "更新成功"
    fi
}

_handle_import_project() {
    local d; d=$(_prompt_user_input_with_validation "请输入域名" "" "" "" "false") || return
    if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$d.conf" ]; then
        log_message ERROR "配置文件不存在。"
        return
    fi
    local json; json=$(_gather_project_details "{\"domain\":\"$d\"}") || return
    _save_project_json "$json" && log_message SUCCESS "导入完成。"
}

manage_configs() {
    while true; do
        local all=$(jq . "$PROJECTS_METADATA_FILE")
        if [ "$(echo "$all" | jq 'length')" -eq 0 ]; then
            log_message WARN "暂无项目。"
            _confirm_action_or_exit_non_interactive "是否导入现有配置？" && { _handle_import_project; continue; }
            break
        fi
        
        echo ""
        _display_projects_list "$all"
        
        local -a opts=("1. ✏️  编辑项目" "2. 🔄 手动续期" "3. 🗑️  删除项目" "4. 📥 导入项目")
        _render_menu "项目管理" "${opts[@]}"
        
        case "$(_prompt_for_menu_choice_local "1-4")" in
            1) _handle_edit_project ;;
            2) _handle_renew_cert ;;
            3) _handle_delete_project ;;
            4) _handle_import_project ;;
            "") break ;;
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
        _render_menu "Nginx 证书与反代管理" \
            "1. 🚀 配置新项目 (New Project)" \
            "2. 📂 项目管理 (Manage Projects)" \
            "3. 🔄 批量续期 (Auto Renew All)"
            
        case "$(_prompt_for_menu_choice_local "1-3")" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) manage_configs ;;
            3) 
                if _confirm_action_or_exit_non_interactive "确认检查所有项目？"; then
                    check_and_auto_renew_certs
                    press_enter_to_continue
                fi ;;
            "") log_message INFO "👋 Bye."; return 10 ;;
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

# --- 入口 ---
trap 'echo -e "\n${YELLOW}中断退出...${NC}"; exit 10' INT TERM
if ! check_root; then exit 1; fi
initialize_environment

if [[ " $* " =~ " --cron " ]]; then check_and_auto_renew_certs; exit $?; fi

install_dependencies && install_acme_sh && get_vps_ip && main_menu
exit $?
