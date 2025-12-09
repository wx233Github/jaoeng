# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v2.6.0-智能检测版)
# - 移除: 默认 CA 切换菜单。
# - 新增: 申请失败自动打印错误日志。
# - 优化: 自动检测 Web 服务器类型 (Nginx/Apache) 推荐重载命令。
# - 修复: ZeroSSL 注册逻辑现适用于所有验证模式。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v2.6.0"

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
    _prompt_user_input() { read -r -p "$1" val; echo "${val:-$2}"; }
    _prompt_for_menu_choice() { read -r -p "请选择 [$1]: " val; echo "$val"; }
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
    log_err "警告: 通用工具库 $UTILS_PATH 未找到，使用内置回退模式。"
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
    run_with_sudo() { "$@"; }
    log_warn "run_with_sudo 未定义，默认直接执行命令。"
fi

# --- 全局变量 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"

# =============================================================
# SECTION: 辅助功能函数 (Private)
# =============================================================

_select_domain_from_menu() {
    SELECTED_DOMAIN=""
    if ! [ -f "$ACME_BIN" ]; then
        log_err "acme.sh 未安装。"
        return 1
    fi

    local raw_list
    raw_list=$("$ACME_BIN" --list)

    local domains=()
    if [ -n "$raw_list" ]; then
        while read -r line; do
            if [[ "$line" == Main_Domain* ]]; then continue; fi
            local d
            d=$(echo "$line" | awk '{print $1}')
            if [ -n "$d" ]; then domains+=("$d"); fi
        done <<< "$raw_list"
    fi

    if [ ${#domains[@]} -eq 0 ]; then
        log_warn "未找到任何已管理的证书。"
        return 1
    fi

    local menu_display=()
    local i
    for ((i=0; i<${#domains[@]}; i++)); do
        menu_display+=("$((i+1)). ${domains[i]}")
    done

    _render_menu "选择域名" "${menu_display[@]}"
    
    local choice_idx
    choice_idx=$(_prompt_user_input "请输入序号 (1-${#domains[@]}) 或按 Enter 取消: " "")

    if [ -z "$choice_idx" ]; then log_info "操作取消。"; return 1; fi
    if ! [[ "$choice_idx" =~ ^[0-9]+$ ]]; then log_err "输入无效。"; return 1; fi
    if (( choice_idx < 1 || choice_idx > ${#domains[@]} )); then log_err "序号超出范围。"; return 1; fi

    SELECTED_DOMAIN="${domains[$((choice_idx-1))]}"
    return 0
}

# =============================================================
# SECTION: 核心功能函数
# =============================================================

_check_dependencies() {
    if ! command -v socat &>/dev/null; then
        log_warn "未检测到 socat (HTTP验证必需)。"
        if confirm_action "是否自动安装 socat?"; then
            if command -v apt-get &>/dev/null; then
                run_with_sudo apt-get update && run_with_sudo apt-get install -y socat
            elif command -v yum &>/dev/null; then
                run_with_sudo yum install -y socat
            else
                log_err "无法自动安装，请手动安装 socat。"
                return 1
            fi
            log_success "socat 安装成功。"
        fi
    fi

    if [[ ! -f "$ACME_BIN" ]]; then
        log_warn "首次运行，正在安装 acme.sh ..."
        local email
        email=$(_prompt_user_input "请输入注册邮箱 (推荐): " "")
        local cmd="curl https://get.acme.sh | sh"
        if [ -n "$email" ]; then cmd+=" -s email=$email"; fi
        if ! eval "$cmd"; then log_err "安装失败！"; return 1; fi
        log_success "acme.sh 安装成功。"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
}

_apply_for_certificate() {
    log_info "--- 申请新证书 ---"
    
    local DOMAIN SERVER_IP DOMAIN_IP
    while true; do
        DOMAIN=$(_prompt_user_input "请输入你的主域名: ")
        if [ -z "$DOMAIN" ]; then log_warn "域名不能为空。"; continue; fi

        log_info "正在验证域名解析..."
        SERVER_IP=$(curl -s https://api.ipify.org)
        DOMAIN_IP=$(dig +short "$DOMAIN" A | head -n1)

        if [ -z "$DOMAIN_IP" ]; then
            log_err "无法获取域名解析IP。"
            if ! confirm_action "是否忽略并继续？"; then return; fi
            break
        elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
            log_warn "解析IP ($DOMAIN_IP) 与本机IP ($SERVER_IP) 不符！"
            if ! confirm_action "强制继续？"; then continue; fi
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
    INSTALL_PATH=$(_prompt_user_input "证书保存路径 [默认: /etc/ssl/$DOMAIN]: " "/etc/ssl/$DOMAIN")
    
    # --- 智能检测 Web 服务器 ---
    local detected_reload="systemctl reload nginx" # 默认回退值
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nginx; then
            detected_reload="systemctl reload nginx"
        elif systemctl is-active --quiet apache2; then
            detected_reload="systemctl reload apache2"
        elif systemctl is-active --quiet httpd; then
            detected_reload="systemctl reload httpd"
        elif systemctl is-active --quiet caddy; then
            detected_reload="systemctl reload caddy"
        fi
    fi
    # --------------------------

    local RELOAD_CMD
    RELOAD_CMD=$(_prompt_user_input "重载命令 [默认: $detected_reload]: " "$detected_reload")

    # 验证方式选择
    local method_options=("1. standalone (HTTP验证, 需80端口)" "2. dns_cf (Cloudflare API)" "3. dns_ali (阿里云 API)")
    _render_menu "验证方式" "${method_options[@]}"
    local VERIFY_CHOICE
    VERIFY_CHOICE=$(_prompt_for_menu_choice "1-3")
    local METHOD
    local CA="zerossl" # 默认逻辑，acme.sh现在可能默认ZeroSSL

    local PRE_HOOK=""
    local POST_HOOK=""

    case "$VERIFY_CHOICE" in
        1) 
            METHOD="standalone"
            if run_with_sudo ss -tuln | grep -q ":80\s"; then
                log_err "80端口被占用。"
                run_with_sudo ss -tuln | grep ":80\s"
                return 1
            fi
            
            if confirm_action "是否配置自动续期钩子 (自动停/启 Web服务) ?"; then
                local svc_guess="nginx"
                if [[ "$RELOAD_CMD" == *"apache"* ]]; then svc_guess="apache2"; fi
                if [[ "$RELOAD_CMD" == *"httpd"* ]]; then svc_guess="httpd"; fi
                
                local svc
                svc=$(_prompt_user_input "服务名称 (如 $svc_guess): " "$svc_guess")
                PRE_HOOK="systemctl stop $svc"
                POST_HOOK="systemctl start $svc"
            fi
            ;;
        2) 
            METHOD="dns_cf"
            log_info "需提供 Cloudflare API 信息。"
            local cf_token cf_acc
            cf_token=$(_prompt_user_input "输入 CF_Token: " "")
            cf_acc=$(_prompt_user_input "输入 CF_Account_ID: " "")
            if [ -z "$cf_token" ] || [ -z "$cf_acc" ]; then log_err "信息不完整。"; return 1; fi
            export CF_Token="$cf_token"
            export CF_Account_ID="$cf_acc"
            ;;
        3) 
            METHOD="dns_ali"
            log_info "需提供阿里云 API 信息。"
            local ali_key ali_sec
            ali_key=$(_prompt_user_input "输入 Ali_Key: " "")
            ali_sec=$(_prompt_user_input "输入 Ali_Secret: " "")
            if [ -z "$ali_key" ] || [ -z "$ali_sec" ]; then log_err "信息不完整。"; return 1; fi
            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_sec"
            ;;
        *) return ;;
    esac

    # --- 修复：ZeroSSL 全局账户检测 ---
    # 无论何种模式，只要 acme.sh 决定使用 ZeroSSL，就需要账户
    # 简单起见，我们主动检测是否注册了账户，如果没有且当前环境没有默认CA设置，则注册
    if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
         # 这里是一种防御性编程，如果不确定用户是否要用 ZeroSSL，
         # 我们可以尝试注册一个，反正 acme.sh 支持多账户
         log_info "检查 ZeroSSL 账户..."
         local reg_email
         reg_email=$(_prompt_user_input "若需使用 ZeroSSL，请输入邮箱注册 (回车跳过): " "")
         if [ -n "$reg_email" ]; then
             "$ACME_BIN" --register-account -m "$reg_email" --server zerossl || log_warn "ZeroSSL 注册失败或已存在。"
         fi
    fi
    # -------------------------------

    log_info "🚀 正在申请证书..."
    local ISSUE_CMD=("$ACME_BIN" --issue -d "$DOMAIN")
    
    ISSUE_CMD+=(--"$METHOD")
    if [ -n "$USE_WILDCARD" ]; then ISSUE_CMD+=(-d "$USE_WILDCARD"); fi
    if [ -n "$PRE_HOOK" ]; then ISSUE_CMD+=(--pre-hook "$PRE_HOOK"); fi
    if [ -n "$POST_HOOK" ]; then ISSUE_CMD+=(--post-hook "$POST_HOOK"); fi
    
    # 执行申请，并捕获失败
    if ! "${ISSUE_CMD[@]}"; then
        log_err "⚠️  证书申请失败！"
        log_info "--- 正在读取 acme.sh 错误日志 (最后 20 行) ---"
        local log_file="$HOME/.acme.sh/acme.sh.log"
        if [ -f "$log_file" ]; then
            tail -n 20 "$log_file"
        else
            echo "日志文件不存在: $log_file"
        fi
        log_info "------------------------------------------------"
        log_err "请根据上方日志检查 DNS 解析、API 密钥或端口占用情况。"
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
    log_success "完成！证书路径: $INSTALL_PATH"
}

_list_certificates() {
    log_info "--- 查看已申请证书 ---"
    if ! [ -f "$ACME_BIN" ]; then log_err "acme.sh 未安装。"; return; fi
    
    local cert_list
    cert_list=$("$ACME_BIN" --list)
    if [ -z "$cert_list" ]; then log_warn "无证书。"; return; fi
    
    echo "$cert_list" | tail -n +2 | while IFS=' ' read -r main_domain keylength san_domains ca created renew; do
        local cert_file="$HOME/.acme.sh/${main_domain}_ecc/fullchain.cer"
        [ ! -f "$cert_file" ] && cert_file="$HOME/.acme.sh/${main_domain}/fullchain.cer"
        
        if ! [ -f "$cert_file" ]; then
            printf "${RED}%-30s | 状态未知${NC}\n" "$main_domain"
            continue
        fi

        local end_date; end_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
        local end_ts; end_ts=$(date -d "$end_date" +%s)
        local left_days=$(( (end_ts - $(date +%s)) / 86400 ))

        local color="$GREEN"
        [ "$left_days" -lt 30 ] && color="$YELLOW"
        [ "$left_days" -lt 0 ] && color="$RED"

        printf "${color}%-25s | 剩余: %3d天 | CA: %-10s${NC}\n" "$main_domain" "$left_days" "$ca"
    done
}

_renew_certificate() {
    log_info "--- 手动续期证书 ---"
    if ! _select_domain_from_menu; then return; fi
    local DOMAIN="$SELECTED_DOMAIN"
    
    log_info "🚀 正在续期 $DOMAIN ..."
    if "$ACME_BIN" --renew -d "$DOMAIN" --force --ecc; then
        log_success "成功: $DOMAIN"
    else
        log_err "失败: $DOMAIN"
        log_info "--- 错误日志 (最后 10 行) ---"
        tail -n 10 "$HOME/.acme.sh/acme.sh.log" || true
    fi
}

_delete_certificate() {
    log_info "--- 删除证书 ---"
    if ! _select_domain_from_menu; then return; fi
    local DOMAIN="$SELECTED_DOMAIN"

    if confirm_action "⚠️ 确认删除 $DOMAIN 及其安装文件？"; then
        "$ACME_BIN" --remove -d "$DOMAIN" --ecc || true
        if [ -d "/etc/ssl/$DOMAIN" ]; then
            run_with_sudo rm -rf "/etc/ssl/$DOMAIN"
            log_success "已删除 /etc/ssl/$DOMAIN"
        fi
        log_success "删除完成。"
    fi
}

_diagnose_auto_renew() {
    log_info "--- 诊断自动续期 ---"
    if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
        log_success "Cron 服务运行中。"
    else
        log_err "Cron 服务未运行！"
        confirm_action "尝试启动 Cron?" && (run_with_sudo systemctl enable --now cron 2>/dev/null || run_with_sudo systemctl enable --now crond 2>/dev/null)
    fi

    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        log_success "Crontab 任务存在。"
    else
        log_err "Crontab 任务缺失！"
        confirm_action "修复任务?" && "$ACME_BIN" --install-cronjob
    fi
}

_upgrade_acme_sh() {
    log_info "--- 升级/配置 acme.sh ---"
    local ver; ver=$("$ACME_BIN" --version | head -n 1)
    log_info "版本: $ver"
    
    local -a menu=("1. 立即升级" "2. 开启自动更新" "3. 关闭自动更新")
    _render_menu "选项" "${menu[@]}"
    local c; c=$(_prompt_for_menu_choice "1-3")
    case "$c" in
        1) "$ACME_BIN" --upgrade ;;
        2) "$ACME_BIN" --upgrade --auto-upgrade ;;
        3) "$ACME_BIN" --upgrade --auto-upgrade 0 ;;
    esac
}

main_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a menu_items=(
            "1. 申请新证书"
            "2. 查看已申请证书"
            "3. 手动续期证书"
            "4. 删除证书"
            "5. 诊断/修复自动续期"
            "6. 升级/配置 acme.sh"
        )
        _render_menu "🔐 SSL 证书管理 (acme.sh)" "${menu_items[@]}"
        
        local choice
        choice=$(_prompt_for_menu_choice "1-6")

        case "$choice" in
            1) _apply_for_certificate ;;
            2) _list_certificates ;;
            3) _renew_certificate ;;
            4) _delete_certificate ;;
            5) _diagnose_auto_renew ;;
            6) _upgrade_acme_sh ;;
            "") return 10 ;; 
            *) log_warn "无效选项。" ;;
        esac
        press_enter_to_continue
    done
}

main() {
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    if [ "$(id -u)" -ne 0 ]; then
        log_err "请使用 root 权限运行。"
        exit 1
    fi
    log_info "SSL 证书管理模块 ${SCRIPT_VERSION}"
    _check_dependencies || return 1
    main_menu
}

main "$@"
