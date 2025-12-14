# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v2.3.2-中断处理与交互确认)
# =============================================================
# - 修复: (流程) 新增 Ctrl+C 中断处理，现在按 Ctrl+C 会优雅退出到父脚本菜单。
# - 增强: (交互) 为“检查并续期所有证书”选项增加了 [y/n] 确认步骤。

set -euo pipefail # 启用：遇到未定义的变量即退出，遇到非零退出码即退出，管道中任何命令失败即退出

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
# SECTION: 核心工具函数 (日志, 清理, 权限, IP, 输入)
# ==============================================================================

_log_prefix() {
    if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then
        echo -n "$(date '+%Y-%m-%d %H:%M:%S') "
    fi
}

log_message() {
    local level="$1" message="$2"
    local color_code="" level_prefix=""
    case "$level" in
        INFO)    echo -e "$(_log_prefix)${CYAN}[信 息]${NC} ${message}";;
        SUCCESS) echo -e "$(_log_prefix)${GREEN}[成 功]${NC} ${message}";;
        WARN)    echo -e "$(_log_prefix)${YELLOW}[警 告]${NC} ${message}" >&2;;
        ERROR)   echo -e "$(_log_prefix)${RED}[错 误]${NC} ${message}" >&2;;
        DEBUG)   if [ "${JB_DEBUG_MODE:-false}" = "true" ]; then echo -e "$(_log_prefix)${YELLOW}[DEBUG]${NC} ${message}" >&2; fi;;
        *)       echo -e "$(_log_prefix)${NC}[UNKNOWN] ${message}";;
    esac
    
    local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level^^}] ${message}" >> "$LOG_FILE"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }

_prompt_for_menu_choice_local() {
    local numeric_range="$1"
    local func_options="${2:-}"
    local prompt_text="${ORANGE}>${NC} 选项 "

    if [ -n "$numeric_range" ]; then
        local start="${numeric_range%%-*}"
        local end="${numeric_range##*-}"
        if [ "$start" = "$end" ]; then
            prompt_text+="[${ORANGE}${start}${NC}] "
        else
            prompt_text+="[${ORANGE}${start}${NC}-${end}] "
        fi
    fi

    if [ -n "$func_options" ]; then
        local start="${func_options%%,*}"
        local rest="${func_options#*,}"
        if [ "$start" = "$rest" ]; then
             prompt_text+="[${ORANGE}${start}${NC}] "
        else
             prompt_text+="[${ORANGE}${start}${NC},${rest}] "
        fi
    fi
    
    prompt_text+="(↩ 返回): "
    
    local choice
    read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty
    echo "$choice"
}

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
    for line in "${lines[@]}"; do local current_line_visual_width=$(_get_visual_width "$line"); if [ "$current_line_visual_width" -gt "$max_content_width" ]; then max_content_width="$current_line_visual_width"; fi; done
    local box_inner_width=$max_content_width; if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    if [ -n "$title" ]; then local padding_total=$((box_inner_width - title_width)); local padding_left=$((padding_total / 2)); local padding_right=$((padding_total - padding_left)); echo -e "${GREEN}│${NC}$(printf '%*s' "$padding_left")${BOLD}${title}${NC}$(printf '%*s' "$padding_right")${GREEN}│${NC}"; fi
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"; for line in "${lines[@]}"; do echo -e "${line}"; done
    local box_total_physical_width=$(( box_inner_width + 2 )); echo -e "${GREEN}$(generate_line "$box_total_physical_width" "─")${NC}"
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
    log_message INFO "VPS 公网 IP (IPv4): $VPS_IP"
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "")
    if [[ -n "$VPS_IPV6" ]]; then log_message INFO "VPS 公网 IP (IPv6): $VPS_IPV6"; fi
}

_prompt_user_input_with_validation() {
    local prompt_message="$1" default_value="$2" validation_regex="$3"
    local validation_error_message="$4" allow_empty_input="${5:-false}" input_value=""
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local display_default="${default_value:-$( [ "$allow_empty_input" = "true" ] && echo "空" || echo "无" )}"
            echo -e "${YELLOW}${prompt_message} [默认: ${display_default}]: ${NC}" >&2
            read -rp "> " input_value; input_value=${input_value:-$default_value}
        else
            input_value="$default_value"
            if [[ -z "$input_value" && "$allow_empty_input" = "false" ]]; then
                log_message ERROR "在非交互模式下，无法获取输入 '$prompt_message' 且无默认值。"
                return 1
            fi
        fi
        if [[ -z "$input_value" && "$allow_empty_input" = "true" ]]; then echo ""; return 0; fi
        if [[ -z "$input_value" ]]; then log_message ERROR "输入不能为空。"; if [ "$IS_INTERACTIVE_MODE" = "false" ]; then return 1; fi; continue; fi
        if [[ -n "$validation_regex" && ! "$input_value" =~ $validation_regex ]]; then
            log_message ERROR "${validation_error_message:-输入格式不正确。}"
            if [ "$IS_INTERACTIVE_MODE" = "false" ]; then return 1; fi; continue
        fi
        echo "$input_value"; return 0
    done
}

_confirm_action_or_exit_non_interactive() {
    local prompt_message="$1"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local choice
        read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice < /dev/tty
        [[ "$choice" =~ ^([Yy]|)$ ]] && return 0 || return 1
    fi
    log_message ERROR "在非交互模式下，需要用户确认才能继续 '$prompt_message'。操作已取消。"
    return 1
}

# ==============================================================================
# SECTION: 依赖与环境检查 (acme.sh, Nginx, Docker, etc.)
# ==============================================================================

initialize_environment() {
    log_message INFO "脚本开始执行: $(date +"%Y-%m-%d %H:%M:%S")"
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
    if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
    export PATH="$(dirname "$ACME_BIN"):$PATH"
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" \
               "$NGINX_CUSTOM_SNIPPETS_DIR" "$SSL_CERTS_BASE_DIR"
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
    fi
}

install_dependencies() {
    local deps="nginx curl socat openssl jq idn dnsutils nano"
    local missing_deps_found=0 failed=0
    for pkg in $deps; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            if [ "$missing_deps_found" -eq 0 ]; then
                log_message INFO "发现缺失依赖，开始检查并安装 (适用于 Debian/Ubuntu)..."
                if ! apt update -y >/dev/null 2>&1; then log_message ERROR "apt update 失败。"; return 1; fi
                missing_deps_found=1
            fi
            log_message WARN "正在安装 $pkg..."
            if ! apt install -y "$pkg" >/dev/null 2>&1; then
                log_message ERROR "安装 $pkg 失败。"; failed=1
            fi
        fi
    done
    if [ "$failed" -eq 1 ]; then return 1; fi
    if [ "$missing_deps_found" -eq 1 ]; then
        log_message SUCCESS "所有依赖检查完毕。"
    fi
    return 0
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then log_message SUCCESS "acme.sh 已就绪 ($ACME_BIN)。"; return 0; fi
    log_message WARN "acme.sh 未安装，正在安装..."
    local email; email=$(_prompt_user_input_with_validation "请输入用于ACME的邮箱(可留空)" "" "" "" "true")
    local cmd="curl https://get.acme.sh | sh"
    if [ -n "$email" ]; then cmd+=" -s email=$email"; fi
    if ! eval "$cmd"; then log_message ERROR "acme.sh 安装失败！"; return 1; fi
    initialize_environment # Re-initialize to find the new acme.sh path
    log_message SUCCESS "acme.sh 安装成功并已就绪。"
    return 0
}

control_nginx() {
    local action="$1"
    if ! nginx -t >/dev/null 2>&1; then
        log_message ERROR "Nginx 配置语法错误！"; nginx -t; return 1;
    fi
    if ! systemctl "$action" nginx; then
        log_message ERROR "Nginx ${action} 失败！请检查服务状态。"; return 1;
    fi
    log_message SUCCESS "Nginx 服务已成功 ${action}。"
    return 0
}

# ==============================================================================
# SECTION: 数据与文件管理封装 (JSON & Nginx Conf)
# ==============================================================================

_get_project_json() {
    local domain="$1"
    jq -c ".[] | select(.domain == \"$domain\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""
}

_save_project_json() {
    local project_json_to_save="$1"
    local domain_to_save=$(echo "$project_json_to_save" | jq -r .domain)
    local temp_file=$(mktemp)
    if [ -n "$(_get_project_json "$domain_to_save")" ]; then # Update existing
        jq "(.[] | select(.domain == \"$domain_to_save\")) = $project_json_to_save" "$PROJECTS_METADATA_FILE" > "$temp_file"
    else # Add new
        jq ". + [$project_json_to_save]" "$PROJECTS_METADATA_FILE" > "$temp_file"
    fi
    if [ $? -eq 0 ]; then
        mv "$temp_file" "$PROJECTS_METADATA_FILE"
        log_message DEBUG "元数据已为 $domain_to_save 保存。"
        return 0
    else
        log_message ERROR "保存元数据 $domain_to_save 失败！"; rm -f "$temp_file"; return 1
    fi
}

_delete_project_json() {
    local domain_to_delete="$1"
    local temp_file=$(mktemp)
    jq "del(.[] | select(.domain == \"$domain_to_delete\"))" "$PROJECTS_METADATA_FILE" > "$temp_file"
    if [ $? -eq 0 ]; then
        mv "$temp_file" "$PROJECTS_METADATA_FILE"
        log_message SUCCESS "已从元数据中移除项目 $domain_to_delete。"
        return 0
    else
        log_message ERROR "从元数据中移除项目 $domain_to_delete 失败！"; rm -f "$temp_file"; return 1
    fi
}

_write_and_enable_nginx_config() {
    local domain="$1" project_json="$2"
    local conf_path="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    local proxy_target_url="http://127.0.0.1:$(echo "$project_json" | jq -r .resolved_port)"
    local cert_file=$(echo "$project_json" | jq -r .cert_file)
    local key_file=$(echo "$project_json" | jq -r .key_file)
    local snippet_path=$(echo "$project_json" | jq -r .custom_snippet)
    local snippet_content=""
    if [[ -n "$snippet_path" && "$snippet_path" != "null" ]]; then
        snippet_content="\n    include $snippet_path;"
    fi

    local listen_80="listen 80;"; local listen_443="listen 443 ssl http2;"
    if [[ -n "$VPS_IPV6" ]]; then
        listen_80+="\n    listen [::]:80;"
        listen_443+="\n    listen [::]:443 ssl http2;"
    fi

    cat > "$conf_path" << EOF
server {
    ${listen_80}
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
server {
    ${listen_443}
    server_name ${domain};

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    add_header Strict-Transport-Security "max-age=31536000;" always;
${snippet_content}
    location / {
        proxy_pass ${proxy_target_url};
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
    ln -sf "$conf_path" "$NGINX_SITES_ENABLED_DIR/"
    log_message SUCCESS "Nginx 配置文件已为 $domain 生成并启用。"
}

_remove_and_disable_nginx_config() {
    local domain="$1"
    rm -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    rm -f "$NGINX_SITES_ENABLED_DIR/$domain.conf"
    log_message SUCCESS "Nginx 配置文件已为 $domain 移除并禁用。"
}

# ==============================================================================
# SECTION: 核心业务逻辑 (证书申请, 项目配置)
# ==============================================================================

_issue_and_install_certificate() {
    local project_json="$1"
    local domain=$(echo "$project_json" | jq -r .domain)
    local method=$(echo "$project_json" | jq -r .acme_validation_method)
    local dns_provider=$(echo "$project_json" | jq -r .dns_api_provider)
    local wildcard=$(echo "$project_json" | jq -r .use_wildcard)
    local ca_url=$(echo "$project_json" | jq -r .ca_server_url)
    local cert_file=$(echo "$project_json" | jq -r .cert_file)
    local key_file=$(echo "$project_json" | jq -r .key_file)

    log_message WARN "正在为 $domain 申请证书 (方式: $method)..."
    local issue_cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca_url")
    if [ "$wildcard" = "y" ]; then issue_cmd+=("-d" "*.$domain"); fi

    if [ "$method" = "http-01" ]; then
        issue_cmd+=("-w" "$NGINX_WEBROOT_DIR")
        cat > "$NGINX_SITES_AVAILABLE_DIR/acme_challenge.conf" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root ${NGINX_WEBROOT_DIR}; } }
EOF
        ln -sf "$NGINX_SITES_AVAILABLE_DIR/acme_challenge.conf" "$NGINX_SITES_ENABLED_DIR/"
        if ! control_nginx reload; then return 1; fi
    elif [ "$method" = "dns-01" ]; then
        issue_cmd+=("--dns" "$dns_provider")
    fi

    local acme_log; acme_log=$(mktemp)
    if ! "${issue_cmd[@]}" > "$acme_log" 2>&1; then
        log_message ERROR "证书申请失败 for $domain!"; cat "$acme_log"; rm -f "$acme_log"
        if [ "$method" = "http-01" ]; then _remove_and_disable_nginx_config "acme_challenge"; control_nginx reload >/dev/null 2>&1; fi
        return 1
    fi
    rm -f "$acme_log"
    if [ "$method" = "http-01" ]; then _remove_and_disable_nginx_config "acme_challenge"; fi

    log_message INFO "证书签发成功, 正在安装..."
    local install_cmd=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key_file" --fullchain-file "$cert_file" --reloadcmd "true")
    if [ "$wildcard" = "y" ]; then install_cmd+=("-d" "*.$domain"); fi
    if ! "${install_cmd[@]}"; then log_message ERROR "证书安装失败 for $domain!"; return 1; fi
    
    return 0
}

_gather_project_details() {
    local current_project_json="${1:-{\}}" # Default to empty JSON object
    local domain=$(echo "$current_project_json" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        domain=$(_prompt_user_input_with_validation "请输入主域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "域名格式无效" "false") || return 1
    fi
    
    local current_target_name=$(echo "$current_project_json" | jq -r '.name // ""')
    local target_input=$(_prompt_user_input_with_validation "请输入后端目标 (Docker容器名 或 本地端口)" "$current_target_name" "" "" "false") || return 1
    
    local type="local_port" name="$target_input" port="$target_input"
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -wq "$target_input"; then
        type="docker"
        port=$(docker inspect "$target_input" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' | head -n1)
        if [ -z "$port" ]; then
            port=$(_prompt_user_input_with_validation "未检测到映射端口, 请手动输入容器内部端口" "80" "^[0-9]+$" "端口无效" "false") || return 1
        fi
    fi

    local current_method_num=$([ "$(echo "$current_project_json" | jq -r '.acme_validation_method')" = "dns-01" ] && echo "2" || echo "1")
    local method_choice=$(_prompt_user_input_with_validation "选择验证方式 (1. http-01, 2. dns-01)" "$current_method_num" "^[12]$" "" "false")
    local method=$([ "$method_choice" -eq 1 ] && echo "http-01" || echo "dns-01")
    
    local dns_provider="" wildcard="n"
    if [ "$method" = "dns-01" ]; then
        local current_provider_num=$([ "$(echo "$current_project_json" | jq -r '.dns_api_provider')" = "dns_ali" ] && echo "2" || echo "1")
        local provider_choice=$(_prompt_user_input_with_validation "选择DNS提供商 (1. Cloudflare, 2. Aliyun)" "$current_provider_num" "^[12]$" "" "false")
        dns_provider=$([ "$provider_choice" -eq 1 ] && echo "dns_cf" || echo "dns_ali")
        
        local current_wildcard=$(echo "$current_project_json" | jq -r '.use_wildcard // "n"')
        wildcard=$(_prompt_user_input_with_validation "是否申请泛域名 (y/n)" "$current_wildcard" "^[yYnN]$" "" "false")
    fi

    local current_ca_num=$([ "$(echo "$current_project_json" | jq -r '.ca_server_name')" = "zerossl" ] && echo "2" || echo "1")
    local ca_choice=$(_prompt_user_input_with_validation "选择CA (1. Let's Encrypt, 2. ZeroSSL)" "$current_ca_num" "^[12]$" "" "false")
    local ca_name=$([ "$ca_choice" -eq 1 ] && echo "letsencrypt" || echo "zerossl")
    local ca_url=$([ "$ca_choice" -eq 1 ] && echo "https://acme-v02.api.letsencrypt.org/directory" || echo "https://acme.zerossl.com/v2/DV90")
    
    local current_snippet=$(echo "$current_project_json" | jq -r '.custom_snippet // ""')
    local snippet_path=$(_prompt_user_input_with_validation "输入自定义Nginx片段路径 (可留空)" "$current_snippet" "" "" "true")

    jq -n \
        --arg domain "$domain" --arg type "$type" --arg name "$name" --arg resolved_port "$port" \
        --arg custom_snippet "$snippet_path" --arg acme_method "$method" \
        --arg dns_provider "$dns_provider" --arg wildcard "$wildcard" \
        --arg ca_url "$ca_url" --arg ca_name "$ca_name" \
        --arg cert_file "$SSL_CERTS_BASE_DIR/$domain.cer" \
        --arg key_file "$SSL_CERTS_BASE_DIR/$domain.key" \
        '{domain: $domain, type: $type, name: $name, resolved_port: $resolved_port, custom_snippet: $custom_snippet, acme_validation_method: $acme_method, dns_api_provider: $dns_provider, use_wildcard: $wildcard, ca_server_url: $ca_url, ca_server_name: $ca_name, cert_file: $cert_file, key_file: $key_file}'
}

# ==============================================================================
# SECTION: 用户交互与主流程 (菜单, 创建, 管理)
# ==============================================================================

_display_projects_list() {
    local PROJECTS_ARRAY_RAW="$1"
    local INDEX=0
    local total_width=60

    echo "$PROJECTS_ARRAY_RAW" | jq -c '.[]' | while read -r project_json; do
        INDEX=$((INDEX + 1))
        local DOMAIN=$(echo "$project_json" | jq -r '.domain // "未知"')
        local CERT_FILE=$(echo "$project_json" | jq -r '.cert_file')
        local KEY_FILE=$(echo "$project_json" | jq -r '.key_file')
        local PROJECT_TYPE=$(echo "$project_json" | jq -r '.type // "未知"')
        local PROJECT_NAME=$(echo "$project_json" | jq -r '.name // "未知"')
        local RESOLVED_PORT=$(echo "$project_json" | jq -r '.resolved_port // "未知"')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard // "n"')

        local PROJECT_DETAIL_DISPLAY=""
        if [ "$PROJECT_TYPE" = "docker" ]; then
            PROJECT_DETAIL_DISPLAY="docker | ${PROJECT_NAME} (${RESOLVED_PORT})"
        else
            PROJECT_DETAIL_DISPLAY="local_port | ${RESOLVED_PORT}"
        fi
        
        local WILDCARD_DISPLAY="$([ "$USE_WILDCARD" = "y" ] && echo "是" || echo "否")"

        local STATUS_COLOR="$RED"
        local STATUS_TEXT="缺失"
        local CERT_INFO_STR=""

        if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
            local END_DATE; END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || echo "未知日期")
            local END_TS; END_TS=$(date -d "$END_DATE" +%s 2>/dev/null || echo 0)
            local NOW_TS; NOW_TS=$(date +%s)
            
            if [[ "$END_TS" -ne 0 ]]; then
                local LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))
                local FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y-%m-%d")
                if (( LEFT_DAYS < 0 )); then
                    STATUS_COLOR="$RED"; STATUS_TEXT="已过期"
                elif (( LEFT_DAYS <= RENEW_THRESHOLD_DAYS )); then
                    STATUS_COLOR="$YELLOW"; STATUS_TEXT="即将到期"
                else
                    STATUS_COLOR="$GREEN"; STATUS_TEXT="有效"
                fi
                CERT_INFO_STR="(剩余 ${LEFT_DAYS} 天, ${FORMATTED_END_DATE} 到期)"
            else
                STATUS_COLOR="$YELLOW"; STATUS_TEXT="日期未知"
            fi
        fi
        
        echo -e "${BOLD}[ ${INDEX} ] ${CYAN}${DOMAIN}${NC}"
        echo -e "  ├─ ${YELLOW}目标:${NC} ${PROJECT_DETAIL_DISPLAY}"
        echo -e "  └─ ${YELLOW}证书:${NC} ${STATUS_COLOR}${STATUS_TEXT}${NC} ${CERT_INFO_STR} | ${YELLOW}泛域:${NC} ${WILDCARD_DISPLAY}"
        if [ "$(echo "$PROJECTS_ARRAY_RAW" | jq 'length')" -gt "$INDEX" ]; then
             echo -e "${GREEN}$(generate_line "$total_width" "·")${NC}"
        fi
    done
}


configure_nginx_projects() {
    log_message INFO "--- 🚀 配置新项目 ---"
    local new_project_json; new_project_json=$(_gather_project_details) || { log_message ERROR "项目信息收集失败。"; return 10; }
    local domain=$(echo "$new_project_json" | jq -r .domain)

    if [ -n "$(_get_project_json "$domain")" ]; then
        if ! _confirm_action_or_exit_non_interactive "域名 $domain 已存在，是否覆盖？"; then
            log_message WARN "已取消操作。"; return 10;
        fi
    fi

    if ! _issue_and_install_certificate "$new_project_json"; then
        log_message ERROR "证书流程失败，配置未应用。"; return 1;
    fi
    
    _write_and_enable_nginx_config "$domain" "$new_project_json"
    if ! control_nginx reload; then
        _remove_and_disable_nginx_config "$domain"
        log_message ERROR "Nginx重载失败，配置已回滚。"; return 1;
    fi

    if ! _save_project_json "$new_project_json"; then return 1; fi
    log_message SUCCESS "项目 $domain 配置成功！"
    return 0
}

_handle_renew_cert() {
    local domain; domain=$(_prompt_user_input_with_validation "请输入要续期的域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "域名格式无效" "false") || return 1
    local project_json; project_json=$(_get_project_json "$domain")
    if [ -z "$project_json" ]; then log_message ERROR "未找到项目 $domain。"; return 1; fi
    _issue_and_install_certificate "$project_json" && control_nginx reload
}

_handle_delete_project() {
    local domain; domain=$(_prompt_user_input_with_validation "请输入要删除的域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "域名格式无效" "false") || return 1
    if [ -z "$(_get_project_json "$domain")" ]; then log_message ERROR "未找到项目 $domain。"; return 1; fi
    if ! _confirm_action_or_exit_non_interactive "确认彻底删除项目 $domain 及其所有配置和证书？"; then return 0; fi
    
    _remove_and_disable_nginx_config "$domain"
    "$ACME_BIN" --remove -d "$domain" --ecc >/dev/null 2>&1
    rm -f "$SSL_CERTS_BASE_DIR/$domain.cer" "$SSL_CERTS_BASE_DIR/$domain.key"
    _delete_project_json "$domain"
    control_nginx reload
}

_handle_edit_project() {
    local domain; domain=$(_prompt_user_input_with_validation "请输入要编辑的域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "域名格式无效" "false") || return 1
    local current_project_json; current_project_json=$(_get_project_json "$domain")
    if [ -z "$current_project_json" ]; then log_message ERROR "未找到项目 $domain。"; return 1; fi

    local updated_project_json; updated_project_json=$(_gather_project_details "$current_project_json") || return 1
    
    if ! _issue_and_install_certificate "$updated_project_json"; then
        log_message ERROR "证书流程失败，配置未更新。"; return 1;
    fi
    
    _write_and_enable_nginx_config "$domain" "$updated_project_json"
    if ! control_nginx reload; then
        log_message ERROR "Nginx重载失败，请手动检查。"; return 1;
    fi

    if ! _save_project_json "$updated_project_json"; then return 1; fi
    log_message SUCCESS "项目 $domain 更新成功！"
}

_handle_manage_snippets() {
    local domain; domain=$(_prompt_user_input_with_validation "请输入要管理片段的域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "域名格式无效" "false") || return 1
    local project_json; project_json=$(_get_project_json "$domain")
    if [ -z "$project_json" ]; then log_message ERROR "未找到项目 $domain。"; return 1; fi
    
    local new_snippet_path; new_snippet_path=$(_prompt_user_input_with_validation "请输入新的片段路径 (留空则为删除)" "$(echo "$project_json" | jq -r .custom_snippet)" "" "" "true") || return 1
    
    local updated_project_json; updated_project_json=$(echo "$project_json" | jq --arg path "$new_snippet_path" '.custom_snippet = $path')
    
    _write_and_enable_nginx_config "$domain" "$updated_project_json"
    if ! control_nginx reload; then
        log_message ERROR "Nginx重载失败，配置已回滚。正在恢复旧配置..."
        _write_and_enable_nginx_config "$domain" "$project_json"
        control_nginx reload >/dev/null 2>&1
        return 1
    fi
    
    _save_project_json "$updated_project_json"
    log_message SUCCESS "片段配置已更新 for $domain."
}

_handle_import_project() {
    log_message INFO "--- 📥 导入现有 Nginx 配置 ---"
    local domain; domain=$(_prompt_user_input_with_validation "请输入要导入的主域名" "" "[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}" "域名格式无效" "false") || return 1
    local conf_path="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if [ ! -f "$conf_path" ]; then log_message ERROR "配置文件 $conf_path 未找到。"; return 1; fi
    if [ -n "$(_get_project_json "$domain")" ]; then
        if ! _confirm_action_or_exit_non_interactive "项目 $domain 已存在，是否覆盖元数据？"; then return 0; fi
    fi

    log_message INFO "将根据现有配置尝试填充信息，请确认或修改。"
    local imported_project_json; imported_project_json=$(_gather_project_details "{\"domain\":\"$domain\"}") || return 1
    
    _save_project_json "$imported_project_json"
    log_message SUCCESS "项目 $domain 已导入。建议立即使用'编辑'功能检查并重新申请证书以确保续期正常。"
}

manage_configs() {
    while true; do
        local projects; projects=$(jq . "$PROJECTS_METADATA_FILE")
        if [ "$(echo "$projects" | jq 'length')" -eq 0 ]; then
            log_message WARN "当前无任何项目。";
            if _confirm_action_or_exit_non_interactive "是否导入一个现有项目？"; then
                _handle_import_project
                continue 
            else
                break;
            fi
        fi
        
        _render_menu "项 目 管 理"
        _display_projects_list "$projects"
        
        local -a menu_items=(
            "1. ✏️ 编辑项目"
            "2. 🔄 手动续期"
            "3. 🗑️ 删除项目"
            "4. ⚙️ 管理自定义片段"
            "5. 📥 导入现有项目"
        )
        for item in "${menu_items[@]}"; do echo -e "$item"; done
        echo -e "${GREEN}$(generate_line 60 "─")${NC}"

        local choice; choice=$(_prompt_for_menu_choice_local "1-5")
        local should_pause=true
        
        case "$choice" in
            1) _handle_edit_project ;;
            2) _handle_renew_cert ;;
            3) _handle_delete_project ;;
            4) _handle_manage_snippets ;;
            5) _handle_import_project ;;
            "") break ;;
            *) log_message ERROR "无效选择。"; should_pause=false ;;
        esac
        
        if [ "$should_pause" = true ]; then
            press_enter_to_continue
        fi
    done
}

check_and_auto_renew_certs() {
    log_message INFO "--- 🔄 检查并自动续期所有证书 ---"
    local renewed_count=0 failed_count=0
    jq -c '.[] | select(.acme_validation_method != "imported")' "$PROJECTS_METADATA_FILE" | while read -r project_json; do
        local domain=$(echo "$project_json" | jq -r .domain)
        local cert_file=$(echo "$project_json" | jq -r .cert_file)
        if [ ! -f "$cert_file" ]; then
            log_message WARN "证书文件不存在 for $domain, 跳过。"
            continue
        fi
        if ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$cert_file"; then
            log_message WARN "证书 $domain 即将到期，开始续期..."
            if _issue_and_install_certificate "$project_json"; then
                renewed_count=$((renewed_count + 1))
            else
                failed_count=$((failed_count + 1))
            fi
        else
            log_message INFO "证书 $domain 无需续期。"
        fi
    done
    control_nginx reload >/dev/null 2>&1
    log_message INFO "--- 续期完成: ${renewed_count} 成功, ${failed_count} 失败 ---"
    return 0
}

manage_acme_accounts() {
    while true; do
        local -a menu_items=(
            "1. 📜 查看已注册账户"
            "2. ➕ 注册新账户"
            "3. ⭐ 设置默认账户"
        )
        _render_menu "acme.sh 账户管理" "${menu_items[@]}"
        
        local choice; choice=$(_prompt_for_menu_choice_local "1-3")
        local should_pause=true
        
        case "$choice" in
            1) "$ACME_BIN" --list ;;
            2)
                local email; email=$(_prompt_user_input_with_validation "请输入新账户邮箱" "" "" "邮箱格式无效" "false") || { should_pause=false; continue; }
                local ca_choice=$(_prompt_user_input_with_validation "选择CA (1. Let's Encrypt, 2. ZeroSSL)" "1" "^[12]$" "" "false")
                local server_url=$([ "$ca_choice" -eq 1 ] && echo "letsencrypt" || echo "zerossl")
                "$ACME_BIN" --register-account -m "$email" --server "$server_url"
                ;;
            3)
                "$ACME_BIN" --list
                local email; email=$(_prompt_user_input_with_validation "请输入要设为默认的邮箱" "" "" "邮箱格式无效" "false") || { should_pause=false; continue; }
                "$ACME_BIN" --set-account -m "$email"
                ;;
            "") break ;;
            *) log_message ERROR "无效选择。"; should_pause=false ;;
        esac
        
        if [ "$should_pause" = true ]; then
            press_enter_to_continue
        fi
    done
}

main_menu() {
    while true; do
        local -a menu_items=(
            "1. 🚀 配置新的 Nginx 反向代理和 HTTPS 证书"
            "2. 📂 查看与管理已配置项目"
            "3. 🔄 检查并自动续期所有证书"
            "4. 🔑 管理 acme.sh 账户"
        )
        _render_menu "Nginx / HTTPS 证书管理主菜单" "${menu_items[@]}"

        local choice; choice=$(_prompt_for_menu_choice_local "1-4")
        case "$choice" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) manage_configs ;;
            3) 
                if _confirm_action_or_exit_non_interactive "这将检查所有项目的证书并尝试续期。是否继续？"; then
                    check_and_auto_renew_certs
                    press_enter_to_continue
                else
                    log_message INFO "操作已取消。"
                fi
                ;;
            4) manage_acme_accounts ;;
            "") log_message INFO "👋 已退出。"; return 10 ;;
            *) log_message ERROR "无效选择。" ;;
        esac
    done
}

# --- 脚本入口 ---
trap 'log_message WARN "用户中断操作，正在返回..."; exit 10;' INT TERM
if ! check_root; then exit 1; fi
initialize_environment

if [[ " $* " =~ " --cron " || " $* " =~ " --non-interactive " ]]; then
    check_and_auto_renew_certs
    exit $?
fi

install_dependencies && install_acme_sh && get_vps_ip && main_menu
exit $?
