# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v2.0.0-重构与UI统一)
# - 重构: 脚本完全重写，以集成 utils.sh 并实现模块化功能。
# - 优化: 全面统一UI风格，包括菜单、日志和输入提示。
# - 修复: 移除了冗余的退出选项，并采用标准返回逻辑。
# - 增强: 标准化了权限处理，所有特权操作均使用 run_with_sudo。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v2.0.0"

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
    # 在没有 utils.sh 的情况下提供基础的日志功能
    log_err() { echo "[错误] $*" >&2; }
    log_info() { echo "[信息] $*"; }
    log_warn() { echo "[警告] $*"; }
    log_success() { echo "[成功] $*"; }
    _render_menu() { local title="$1"; shift; echo "--- $title ---"; printf " %s\n" "$@"; }
    press_enter_to_continue() { read -r -p "按 Enter 继续..."; }
    confirm_action() { read -r -p "$1 ([y]/n): " choice; case "$choice" in n|N) return 1;; *) return 0;; esac; }
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
  log_err "致命错误: run_with_sudo 函数未定义。请确保从 install.sh 启动此脚本。"
  exit 1
fi

# --- 全局变量 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"

# =============================================================
# SECTION: 核心功能函数
# =============================================================

_check_dependencies() {
    if ! command -v socat &>/dev/null; then
        log_warn "未检测到 socat，它是 HTTP 验证所必需的。"
        if confirm_action "是否尝试自动安装 socat?"; then
            if command -v apt-get &>/dev/null; then
                run_with_sudo apt-get update && run_with_sudo apt-get install -y socat
            elif command -v yum &>/dev/null; then
                run_with_sudo yum install -y socat
            else
                log_err "无法自动安装 socat，请手动安装后重试。"
                return 1
            fi
            log_success "socat 安装成功。"
        else
            log_warn "用户取消安装 socat。HTTP 验证模式可能无法使用。"
        fi
    fi

    if [[ ! -f "$ACME_BIN" ]]; then
        log_warn "首次运行，正在安装 acme.sh ..."
        local email
        email=$(_prompt_user_input "请输入一个邮箱用于 acme.sh 注册 (推荐): " "")
        local cmd="curl https://get.acme.sh | sh"
        if [ -n "$email" ]; then
            cmd+=" -s email=$email"
        fi
        if ! eval "$cmd"; then
            log_err "acme.sh 安装失败！"
            return 1
        fi
        log_success "acme.sh 安装成功。"
    fi
    # 确保 PATH 更新
    export PATH="$HOME/.acme.sh:$PATH"
}

_apply_for_certificate() {
    log_info "--- 申请新证书 ---"
    
    local DOMAIN SERVER_IP DOMAIN_IP
    while true; do
        DOMAIN=$(_prompt_user_input "请输入你的主域名 (例如 example.com): ")
        if [ -z "$DOMAIN" ]; then log_warn "域名不能为空。"; continue; fi

        log_info "正在验证域名解析..."
        SERVER_IP=$(curl -s https://api.ipify.org)
        DOMAIN_IP=$(dig +short "$DOMAIN" A | head -n1)

        if [ -z "$DOMAIN_IP" ]; then
            log_err "无法获取域名解析IP，请检查域名是否正确或DNS是否已生效。"
            if ! confirm_action "是否要忽略此错误并继续？"; then return; fi
            break
        elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
            log_warn "域名解析与本机IP不符！"
            log_info "  服务器公网IP: $SERVER_IP"
            log_info "  域名解析到的IP: $DOMAIN_IP"
            if ! confirm_action "这可能导致证书申请失败。是否强制继续？"; then continue; fi
            log_warn "已选择强制继续申请。"
            break
        else
            log_success "域名解析正确。"
            break
        fi
    done

    local USE_WILDCARD=""
    if confirm_action "是否申请泛域名证书 (*.$DOMAIN)？"; then
        USE_WILDCARD="*.$DOMAIN"
    fi

    local INSTALL_PATH
    INSTALL_PATH=$(_prompt_user_input "请输入证书保存路径 [默认: /etc/ssl/$DOMAIN]: " "/etc/ssl/$DOMAIN")
    local RELOAD_CMD
    RELOAD_CMD=$(_prompt_user_input "证书更新后执行的服务重载命令 [默认: systemctl reload nginx]: " "systemctl reload nginx")

    log_info "请选择证书颁发机构 (CA):"
    local ca_options=("ZeroSSL (默认)" "Let’s Encrypt")
    _render_menu "CA 选择" "${ca_options[@]}"
    local CA_CHOICE
    CA_CHOICE=$(_prompt_for_menu_choice "1-2")
    local CA
    case "$CA_CHOICE" in
        2) CA="letsencrypt" ;;
        *) CA="zerossl" ;;
    esac

    log_info "请选择验证方式:"
    local method_options=("standalone (HTTP验证, 需开放80端口，推荐)" "dns_cf (Cloudflare DNS API)" "dns_ali (阿里云 DNS API)")
    _render_menu "验证方式" "${method_options[@]}"
    local VERIFY_CHOICE
    VERIFY_CHOICE=$(_prompt_for_menu_choice "1-3")
    local METHOD
    case "$VERIFY_CHOICE" in
        2) METHOD="dns_cf" ;;
        3) METHOD="dns_ali" ;;
        *) METHOD="standalone" ;;
    esac
    
    if [ "$METHOD" = "standalone" ]; then
        log_info "检查80端口占用情况..."
        if run_with_sudo ss -tuln | grep -q ":80\s"; then
            log_err "80端口已被占用，standalone 模式需要空闲的80端口。"
            run_with_sudo ss -tuln | grep ":80\s"
            return 1
        fi
        log_success "80端口空闲。"

        if [ "$CA" = "zerossl" ] && ! "$ACME_BIN" --list-account | grep -q "ZeroSSL.com"; then
             local ACCOUNT_EMAIL
             ACCOUNT_EMAIL=$(_prompt_user_input "检测到未注册ZeroSSL账户，请输入注册邮箱: ")
             if [ -z "$ACCOUNT_EMAIL" ]; then log_err "邮箱不能为空！"; return 1; fi
             "$ACME_BIN" --register-account -m "$ACCOUNT_EMAIL" --server "$CA"
        fi
    fi
    
    if [[ "$METHOD" == "dns_cf" ]]; then
        log_warn "请确保已按 acme.sh 文档正确设置环境变量 CF_Token 和 CF_Account_ID。"
    elif [[ "$METHOD" == "dns_ali" ]]; then
        log_warn "请确保已按 acme.sh 文档正确设置环境变量 Ali_Key 和 Ali_Secret。"
    fi

    log_info "🚀 正在申请证书，请稍候..."
    local ISSUE_CMD=("$ACME_BIN" --issue -d "$DOMAIN" --server "$CA" --"$METHOD")
    if [ -n "$USE_WILDCARD" ]; then
        ISSUE_CMD+=(-d "$USE_WILDCARD")
    fi
    
    if ! "${ISSUE_CMD[@]}"; then
        log_err "证书申请失败！请检查端口、域名解析或API密钥，并查看上方的错误日志。"
        return 1
    fi
    
    log_success "证书生成成功，正在安装..."
    run_with_sudo mkdir -p "$INSTALL_PATH"

    if ! "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$INSTALL_PATH/$DOMAIN.key" \
        --fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
        --reloadcmd      "$RELOAD_CMD"; then
        log_err "证书安装失败！"
        return 1
    fi
    
    run_with_sudo bash -c "date +'%Y-%m-%d %H:%M:%S' > '$INSTALL_PATH/.apply_time'"
    
    log_success "证书申请并安装成功！"
    log_info "  证书路径: $INSTALL_PATH"
}

_list_certificates() {
    log_info "--- 查看已申请证书 ---"
    if ! [ -f "$ACME_BIN" ]; then log_err "acme.sh 未安装，无法查询。"; return; fi
    
    local cert_list
    cert_list=$("$ACME_BIN" --list)
    if [ -z "$cert_list" ]; then
        log_warn "未找到任何由 acme.sh 管理的证书。"
        return
    fi
    
    echo "$cert_list" | tail -n +2 | while IFS=' ' read -r main_domain keylength san_domains ca created renew; do
        local cert_file="$HOME/.acme.sh/${main_domain}_ecc/fullchain.cer"
        if ! [ -f "$cert_file" ]; then
            cert_file="$HOME/.acme.sh/${main_domain}/fullchain.cer"
        fi
        if ! [ -f "$cert_file" ]; then
            printf "${RED}%-30s | 状态未知 (找不到证书文件)${NC}\n" "$main_domain"
            continue
        fi

        local end_date; end_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local end_ts; end_ts=$(date -d "$end_date" +%s)
        local now_ts; now_ts=$(date +%s)
        local left_days=$(( (end_ts - now_ts) / 86400 ))

        local status_color status_text
        if (( left_days < 0 )); then
            status_color="$RED"
            status_text="已过期"
        elif (( left_days <= 30 )); then
            status_color="$YELLOW"
            status_text="即将到期"
        else
            status_color="$GREEN"
            status_text="有效"
        fi

        printf "${status_color}%-30s | 状态: %-8s | 剩余: %3d天${NC}\n" "$main_domain" "$status_text" "$left_days"
    done
}

_renew_certificate() {
    log_info "--- 手动续期证书 ---"
    local DOMAIN
    DOMAIN=$(_prompt_user_input "请输入要续期的域名: ")
    if [ -z "$DOMAIN" ]; then log_err "域名不能为空！"; return; fi

    log_info "🚀 正在为 $DOMAIN 续期证书..."
    if "$ACME_BIN" --renew -d "$DOMAIN" --force --ecc; then
        log_success "续期命令执行成功: $DOMAIN"
    else
        log_err "续期命令执行失败: $DOMAIN"
    fi
}

_delete_certificate() {
    log_info "--- 删除证书 ---"
    local DOMAIN
    DOMAIN=$(_prompt_user_input "请输入要删除的域名: ")
    if [ -z "$DOMAIN" ]; then log_err "域名不能为空！"; return; fi

    if confirm_action "⚠️ 确认删除证书及已安装目录 /etc/ssl/$DOMAIN ？此操作不可恢复！"; then
        log_info "正在从 acme.sh 移除 $DOMAIN..."
        "$ACME_BIN" --remove -d "$DOMAIN" --ecc || log_warn "acme.sh 移除证书时可能出错，但将继续删除文件。"
        
        log_info "正在删除已安装的证书文件 /etc/ssl/$DOMAIN..."
        if [ -d "/etc/ssl/$DOMAIN" ]; then
            run_with_sudo rm -rf "/etc/ssl/$DOMAIN"
            log_success "已删除目录 /etc/ssl/$DOMAIN"
        else
            log_warn "目录 /etc/ssl/$DOMAIN 不存在，跳过删除。"
        fi
    else
        log_info "已取消删除操作。"
    fi
}

main_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a menu_items=(
            "1. 申请新证书"
            "2. 查看已申请证书"
            "3. 手动续期证书"
            "4. 删除证书"
        )
        _render_menu "🔐 SSL 证书管理 (acme.sh)" "${menu_items[@]}"
        
        local choice
        choice=$(_prompt_for_menu_choice "1-4")

        case "$choice" in
            1) _apply_for_certificate ;;
            2) _list_certificates ;;
            3) _renew_certificate ;;
            4) _delete_certificate ;;
            "") return 10 ;; # 标准返回逻辑
            *) log_warn "无效选项。" ;;
        esac
        press_enter_to_continue
    done
}

main() {
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    if [ "$(id -u)" -ne 0 ]; then
        log_err "此脚本需要以 root 权限运行，因为它需要管理系统级证书和端口。"
        exit 1
    fi
    log_info "欢迎使用 SSL 证书管理模块 v${SCRIPT_VERSION}"
    _check_dependencies || return 1
    main_menu
}

main "$@"
