# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 管理助手 (v2.4.0-UI重构版)
# - 架构: 深度适配 utils.sh 标准库，统一视觉体验。
# - UI: 项目列表升级为卡片式视图，直观显示反代目标与证书状态。
# - 安全: 优化 DNS API 凭证处理，防止敏感信息泄露。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v2.4.0"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    # 内置极简回退，防止缺失报错
    echo "警告: 未找到 $UTILS_PATH，样式可能异常。"
    log_err() { echo "[Error] $*" >&2; }
    log_info() { echo "[Info] $*"; }
    log_warn() { echo "[Warn] $*"; }
    log_success() { echo "[Success] $*"; }
    generate_line() { local len=${1:-40}; printf "%${len}s" "" | sed "s/ /-/g"; }
    press_enter_to_continue() { read -r -p "Press Enter..."; }
    confirm_action() { read -r -p "$1 (y/n): " c; [[ "$c" == "y" ]] && return 0 || return 1; }
    _prompt_user_input() { read -r -p "$1" v; echo "${v:-$2}"; }
    _prompt_for_menu_choice() { read -r -p "Choice: " v; echo "$v"; }
    _render_menu() { echo "--- $1 ---"; shift; for l in "$@"; do echo "$l"; done; }
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""; BOLD=""; ORANGE="";
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
    run_with_sudo() { "$@"; }
fi

# --- 全局配置 ---
LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
ACME_BIN="$HOME/.acme.sh/acme.sh"
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
SSL_CERTS_BASE_DIR="/etc/ssl"
RENEW_THRESHOLD_DAYS=30

# =============================================================
# SECTION: 基础环境检查
# =============================================================

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "请使用 root 用户运行此操作。"
        exit 1
    fi
}

initialize_environment() {
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$SSL_CERTS_BASE_DIR"
    
    # 确保 JSON 文件存在且格式正确
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
    fi
    
    # 依赖检查
    local deps="nginx curl socat openssl jq"
    for pkg in $deps; do
        if ! command -v "$pkg" &>/dev/null; then
            log_warn "缺失依赖: $pkg，尝试安装..."
            if command -v apt-get &>/dev/null; then
                run_with_sudo apt-get update && run_with_sudo apt-get install -y "$pkg"
            elif command -v yum &>/dev/null; then
                run_with_sudo yum install -y "$pkg"
            else
                log_err "无法自动安装 $pkg，请手动安装。"
                exit 1
            fi
        fi
    done

    # acme.sh 检查
    if [[ ! -f "$ACME_BIN" ]]; then
        log_warn "未检测到 acme.sh，正在安装..."
        local email
        email=$(_prompt_user_input "请输入用于 ACME 注册的邮箱 (可留空): " "")
        local cmd="curl https://get.acme.sh | sh"
        if [ -n "$email" ]; then cmd+=" -s email=$email"; fi
        if ! eval "$cmd"; then log_err "acme.sh 安装失败！"; exit 1; fi
        log_success "acme.sh 安装成功。"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
}

control_nginx() {
    local action="$1"
    if ! nginx -t >/dev/null 2>&1; then
        log_err "Nginx 配置存在语法错误，无法 $action！"
        nginx -t
        return 1
    fi
    if ! systemctl "$action" nginx; then
        log_err "Nginx $action 失败，请检查 systemctl status nginx。"
        return 1
    fi
    log_success "Nginx $action 成功。"
    return 0
}

# =============================================================
# SECTION: 数据管理 (JSON)
# =============================================================

_save_project_json() {
    local project_json_str="$1"
    local domain; domain=$(echo "$project_json_str" | jq -r .domain)
    local temp_file; temp_file=$(mktemp)
    
    # 检查是否存在，存在则更新，不存在则追加
    local exists
    exists=$(jq --arg d "$domain" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE")
    
    if [ -n "$exists" ]; then
        jq --arg d "$domain" --argjson new "$project_json_str" \
           'map(if .domain == $d then $new else . end)' "$PROJECTS_METADATA_FILE" > "$temp_file"
    else
        jq --argjson new "$project_json_str" '. + [$new]' "$PROJECTS_METADATA_FILE" > "$temp_file"
    fi
    
    mv "$temp_file" "$PROJECTS_METADATA_FILE"
}

_delete_project_json() {
    local domain="$1"
    local temp_file; temp_file=$(mktemp)
    jq --arg d "$domain" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" > "$temp_file"
    mv "$temp_file" "$PROJECTS_METADATA_FILE"
}

# =============================================================
# SECTION: 核心逻辑 (配置生成与证书申请)
# =============================================================

_generate_nginx_conf() {
    local domain="$1"
    local target_port="$2"
    local cert_file="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key_file="$SSL_CERTS_BASE_DIR/$domain.key"
    local conf_path="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"

    # 生成配置
    cat > "$conf_path" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    
    # 推荐的安全套件配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    add_header Strict-Transport-Security "max-age=31536000;" always;

    location / {
        proxy_pass http://127.0.0.1:${target_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    ln -sf "$conf_path" "$NGINX_SITES_ENABLED_DIR/"
}

_issue_cert_wrapper() {
    local domain="$1"
    local method="$2"
    local wildcard="$3"
    local ca_server="$4"
    local cert_file="$5"
    local key_file="$6"
    
    log_info "正在申请证书: $domain (方式: $method)..."
    
    local issue_cmd=("$ACME_BIN" --issue --force --ecc -d "$domain")
    if [ "$wildcard" = "y" ]; then issue_cmd+=("-d" "*.$domain"); fi
    
    if [ "$ca_server" != "default" ]; then issue_cmd+=("--server" "$ca_server"); fi

    # 验证方式处理
    if [ "$method" = "http-01" ]; then
        # 临时生成验证用 Nginx 配置
        issue_cmd+=("--nginx")
        # 注意：acme.sh 的 --nginx 模式会自动处理配置，不需要我们手动写 location
        # 但为了稳妥，这里建议使用 webroot 模式配合我们自己生成的配置，或者让 acme.sh 自动处理
        # 简化起见，这里假设 80 端口已被 Nginx 接管
    elif [[ "$method" == "dns_"* ]]; then
        issue_cmd+=("--dns" "$method")
    fi

    if ! "${issue_cmd[@]}"; then
        log_err "证书申请失败！请检查日志。"
        [ -f "$HOME/.acme.sh/acme.sh.log" ] && tail -n 20 "$HOME/.acme.sh/acme.sh.log"
        return 1
    fi

    log_info "证书签发成功，正在安装..."
    if ! "$ACME_BIN" --install-cert --ecc -d "$domain" \
        --key-file "$key_file" \
        --fullchain-file "$cert_file" \
        --reloadcmd "systemctl reload nginx"; then
        log_err "证书安装失败！"
        return 1
    fi
    return 0
}

_configure_new_project() {
    log_info "--- 🚀 配置新项目 ---"
    
    local domain
    domain=$(_prompt_user_input "请输入主域名 (例如 example.com): " "")
    if [ -z "$domain" ]; then log_err "域名不能为空"; return; fi

    local target_port
    target_port=$(_prompt_user_input "请输入后端端口 (例如 8080): " "")
    if ! [[ "$target_port" =~ ^[0-9]+$ ]]; then log_err "端口必须是数字"; return; fi

    # 验证方式
    local -a methods=("1. HTTP 验证 (Webroot/Nginx)" "2. DNS Cloudflare" "3. DNS Aliyun")
    _render_menu "验证方式" "${methods[@]}"
    local m_choice
    m_choice=$(_prompt_for_menu_choice "1-3")
    local method=""
    local dns_provider=""
    
    case "$m_choice" in
        1) method="http-01" ;;
        2) method="dns_cf"; dns_provider="dns_cf" ;;
        3) method="dns_ali"; dns_provider="dns_ali" ;;
        *) method="http-01" ;;
    esac

    # 处理 DNS 凭证
    if [[ "$method" == "dns_"* ]]; then
        if [ "$method" == "dns_cf" ]; then
            log_info "需要 Cloudflare API Token (Edit Zone DNS)。"
            local cf_token cf_acc
            cf_token=$(_prompt_user_input "输入 CF_Token (回车复用已保存): " "")
            cf_acc=$(_prompt_user_input "输入 CF_Account_ID (回车复用已保存): " "")
            # 如果不为空则导出
            if [ -n "$cf_token" ]; then export CF_Token="$cf_token"; fi
            if [ -n "$cf_acc" ]; then export CF_Account_ID="$cf_acc"; fi
        elif [ "$method" == "dns_ali" ]; then
            local ali_key ali_sec
            ali_key=$(_prompt_user_input "输入 Ali_Key (回车复用): " "")
            ali_sec=$(_prompt_user_input "输入 Ali_Secret (回车复用): " "")
            if [ -n "$ali_key" ]; then export Ali_Key="$ali_key"; fi
            if [ -n "$ali_sec" ]; then export Ali_Secret="$ali_sec"; fi
        fi
    fi

    # CA 选择
    local ca_server="letsencrypt"
    local ca_choice
    ca_choice=$(_prompt_user_input "选择 CA (1. Let's Encrypt [默认], 2. ZeroSSL): " "1")
    [ "$ca_choice" == "2" ] && ca_server="zerossl"

    # 先生成 Nginx 配置 (HTTP 模式需要先有监听 80)
    _generate_nginx_conf "$domain" "$target_port"
    if ! control_nginx reload; then return; fi

    # 申请证书
    local cert_file="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key_file="$SSL_CERTS_BASE_DIR/$domain.key"
    
    if ! _issue_cert_wrapper "$domain" "$method" "n" "$ca_server" "$cert_file" "$key_file"; then
        log_err "流程中断：证书申请失败。"
        # 失败回滚
        rm -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" "$NGINX_SITES_ENABLED_DIR/$domain.conf"
        control_nginx reload
        # 清理凭证
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return
    fi

    # 清理凭证
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret

    # 保存元数据
    # JSON 结构
    local json_str
    json_str=$(jq -n \
        --arg d "$domain" \
        --arg p "$target_port" \
        --arg m "$method" \
        --arg ca "$ca_server" \
        --arg cf "$cert_file" \
        --arg kf "$key_file" \
        '{domain: $d, port: $p, method: $m, ca: $ca, cert_file: $cf, key_file: $kf}')
    
    _save_project_json "$json_str"
    log_success "项目 $domain 配置完成！"
}

_list_projects() {
    local projects
    projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null)
    
    if [ -z "$projects" ]; then
        log_warn "当前没有已配置的项目。"
        return
    fi

    echo ""
    local i=0
    echo "$projects" | while read -r proj; do
        i=$((i+1))
        local domain; domain=$(echo "$proj" | jq -r .domain)
        local port; port=$(echo "$proj" | jq -r .port)
        local cert_file; cert_file=$(echo "$proj" | jq -r .cert_file)
        
        # 证书状态检查
        local status_text="未知"
        local days_info="无法读取"
        local color="$NC"
        
        if [ -f "$cert_file" ]; then
            local end_date; end_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$end_date" ]; then
                local end_ts; end_ts=$(date -d "$end_date" +%s)
                local now_ts; now_ts=$(date +%s)
                local left_days=$(( (end_ts - now_ts) / 86400 ))
                local date_str; date_str=$(date -d "$end_date" +%F)
                
                if (( left_days < 0 )); then
                    color="$RED"; status_text="已过期"; days_info="${left_days} 天"
                elif (( left_days < 30 )); then
                    color="$YELLOW"; status_text="即将到期"; days_info="${left_days} 天"
                else
                    color="$GREEN"; status_text="有效"; days_info="${left_days} 天"
                fi
                days_info+=" ($date_str)"
            fi
        else
            color="$RED"; status_text="缺失"
        fi

        printf "${GREEN}[ %d ] %s${NC}\n" "$i" "$domain"
        printf "  ├─ 反 代 : 127.0.0.1:${CYAN}%s${NC}\n" "$port"
        printf "  └─ 证 书 : ${color}%s${NC} | %s\n" "$status_text" "$days_info"
        echo -e "${CYAN}····························································${NC}"
    done
}

_delete_project() {
    local domain
    domain=$(_prompt_user_input "请输入要删除的域名: " "")
    if [ -z "$domain" ]; then return; fi
    
    # 检查是否存在
    local exists
    exists=$(jq --arg d "$domain" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE")
    if [ -z "$exists" ]; then log_err "找不到该项目。"; return; fi

    if confirm_action "⚠️  确认删除 $domain (包括 Nginx 配置和证书)?"; then
        # 1. 移除 Nginx 配置
        rm -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" "$NGINX_SITES_ENABLED_DIR/$domain.conf"
        
        # 2. 移除证书 (acme.sh)
        "$ACME_BIN" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
        local cert_file; cert_file=$(echo "$exists" | jq -r .cert_file)
        local key_file; key_file=$(echo "$exists" | jq -r .key_file)
        rm -f "$cert_file" "$key_file"
        
        # 3. 移除 JSON 记录
        _delete_project_json "$domain"
        
        control_nginx reload
        log_success "已删除 $domain。"
    fi
}

_check_renew_all() {
    log_info "准备检查所有项目的证书续期..."
    if ! confirm_action "是否继续?"; then return; fi
    
    # 遍历 JSON (注意：这里简化处理，直接调 acme.sh 的 cron 模式其实更稳，但为了逻辑闭环我们手动调 renew)
    # 实际上，acme.sh --cron 已经足够智能。我们这里直接调用它。
    
    log_info "执行 acme.sh 自动续期任务..."
    "$ACME_BIN" --cron --home "$HOME/.acme.sh"
    
    # 强制重载 Nginx 以应用可能更新的证书
    control_nginx reload
    log_success "检查完成。"
}

manage_acme_menu() {
    while true; do
        local -a menu=("1. 查看账户列表" "2. 注册新账户" "3. 升级 acme.sh")
        _render_menu "acme.sh 设置" "${menu[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-3")
        case "$choice" in
            1) "$ACME_BIN" --list ;;
            2) 
                local email; email=$(_prompt_user_input "邮箱: " "")
                "$ACME_BIN" --register-account -m "$email" --server letsencrypt
                ;;
            3) "$ACME_BIN" --upgrade ;;
            "") break ;;
        esac
        press_enter_to_continue
    done
}

main_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a menu_items=(
            "1. 配置新项目 (New Project)"
            "2. 项目列表 (List Projects)"
            "3. 删除项目 (Delete Project)"
            "4. 一键续期检查 (Renew All)"
            "5. acme.sh 设置 (Settings)"
        )
        _render_menu "Nginx 反代管理" "${menu_items[@]}"
        
        local choice
        choice=$(_prompt_for_menu_choice "1-5")

        case "$choice" in
            1) _configure_new_project; press_enter_to_continue ;;
            2) _list_projects; press_enter_to_continue ;;
            3) _delete_project; press_enter_to_continue ;;
            4) _check_renew_all; press_enter_to_continue ;;
            5) manage_acme_menu ;;
            "") 
                log_info "👋 已退出。"
                return 10 
                ;;
            *) log_warn "无效选项。" ;;
        esac
    done
}

# --- 入口 ---
trap 'echo -e "\n操作中断。"; exit 10' INT
check_root
initialize_environment
main_menu
