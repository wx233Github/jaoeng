# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v3.0.0-架构重构版)
# - 重构: 采用"对象管理"模式，将列表/续期/删除整合为单一入口。
# - 优化: 主菜单精简为3个核心选项。
# - 修复: 彻底解决操作结束后的重复回车等待问题。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v3.0.0"

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
    local detected_reload="systemctl reload nginx"
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nginx; then detected_reload="systemctl reload nginx";
        elif systemctl is-active --quiet apache2; then detected_reload="systemctl reload apache2";
        elif systemctl is-active --quiet httpd; then detected_reload="systemctl reload httpd";
        elif systemctl is-active --quiet caddy; then detected_reload="systemctl reload caddy"; fi
    fi
    local RELOAD_CMD
    RELOAD_CMD=$(_prompt_user_input "重载命令 [默认: $detected_reload]: " "$detected_reload")

    # 验证方式选择
    local method_options=("1. standalone (HTTP验证, 需80端口)" "2. dns_cf (Cloudflare API)" "3. dns_ali (阿里云 API)")
    _render_menu "验证方式" "${method_options[@]}"
    local VERIFY_CHOICE
    VERIFY_CHOICE=$(_prompt_for_menu_choice "1-3")
    local METHOD
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
            if confirm_action "配置自动续期钩子 (自动停/启 Web服务)?"; then
                local svc_guess="nginx"
                if [[ "$RELOAD_CMD" == *"apache"* ]]; then svc_guess="apache2"; fi
                local svc
                svc=$(_prompt_user_input "服务名称 (如 $svc_guess): " "$svc_guess")
                PRE_HOOK="systemctl stop $svc"
                POST_HOOK="systemctl start $svc"
            fi
            ;;
        2) 
            METHOD="dns_cf"
            local cf_token cf_acc
            cf_token=$(_prompt_user_input "输入 CF_Token: " "")
            cf_acc=$(_prompt_user_input "输入 CF_Account_ID: " "")
            [ -z "$cf_token" ] || [ -z "$cf_acc" ] && { log_err "信息不完整。"; return 1; }
            export CF_Token="$cf_token"
            export CF_Account_ID="$cf_acc"
            ;;
        3) 
            METHOD="dns_ali"
            local ali_key ali_sec
            ali_key=$(_prompt_user_input "输入 Ali_Key: " "")
            ali_sec=$(_prompt_user_input "输入 Ali_Secret: " "")
            [ -z "$ali_key" ] || [ -z "$ali_sec" ] && { log_err "信息不完整。"; return 1; }
            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_sec"
            ;;
        *) return ;;
    esac

    # ZeroSSL 检查
    if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
         log_info "检查账户..."
         local reg_email
         reg_email=$(_prompt_user_input "若需使用 ZeroSSL，请输入邮箱注册 (回车跳过): " "")
         if [ -n "$reg_email" ]; then
             "$ACME_BIN" --register-account -m "$reg_email" --server zerossl || log_warn "ZeroSSL 注册跳过。"
         fi
    fi

    log_info "🚀 正在申请证书..."
    local ISSUE_CMD=("$ACME_BIN" --issue -d "$DOMAIN" --"$METHOD")
    if [ -n "$USE_WILDCARD" ]; then ISSUE_CMD+=(-d "$USE_WILDCARD"); fi
    if [ -n "$PRE_HOOK" ]; then ISSUE_CMD+=(--pre-hook "$PRE_HOOK"); fi
    if [ -n "$POST_HOOK" ]; then ISSUE_CMD+=(--post-hook "$POST_HOOK"); fi
    
    if ! "${ISSUE_CMD[@]}"; then
        log_err "证书申请失败！日志如下:"
        [ -f "$HOME/.acme.sh/acme.sh.log" ] && tail -n 20 "$HOME/.acme.sh/acme.sh.log"
        return 1
    fi
    
    log_success "证书生成成功，正在安装..."
    run_with_sudo mkdir -p "$INSTALL_PATH"

    if ! "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$INSTALL_PATH/$DOMAIN.key" \
        --fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
        --reloadcmd      "$RELOAD_CMD"; then
        log_err "安装失败。"
        return 1
    fi
    
    run_with_sudo bash -c "date +'%Y-%m-%d %H:%M:%S' > '$INSTALL_PATH/.apply_time'"
    log_success "完成！路径: $INSTALL_PATH"
}

# --- 整合管理模块 ---
_manage_certificates() {
    if ! [ -f "$ACME_BIN" ]; then log_err "acme.sh 未安装。"; return; fi

    while true; do
        log_info "正在扫描证书列表..."
        local raw_list
        raw_list=$("$ACME_BIN" --list)

        local domains=()
        if [ -n "$raw_list" ]; then
            while read -r line; do
                if [[ "$line" == Main_Domain* ]]; then continue; fi
                local d
                d=$(echo "$line" | awk '{print $1}')
                [ -n "$d" ] && domains+=("$d")
            done <<< "$raw_list"
        fi

        if [ ${#domains[@]} -eq 0 ]; then
            log_warn "当前没有管理的证书。"
            return
        fi

        # 1. 展示列表
        echo "================ 证书列表 ================"
        printf "%-4s | %-25s | %s\n" "No." "域名" "状态"
        echo "------------------------------------------"
        local i
        for ((i=0; i<${#domains[@]}; i++)); do
            local d="${domains[i]}"
            # 简易状态检查 (不读取文件，仅根据 acme list 存在性)
            printf "%-4d | %-25s | %s\n" "$((i+1))" "$d" "已管理"
        done
        echo "=========================================="
        
        # 2. 选择对象
        local choice_idx
        choice_idx=$(_prompt_user_input "请输入序号管理证书 (0 返回主菜单): " "0")
        
        if [ "$choice_idx" == "0" ]; then return; fi
        if ! [[ "$choice_idx" =~ ^[0-9]+$ ]] || (( choice_idx < 1 || choice_idx > ${#domains[@]} )); then
            log_err "无效序号。"
            continue # 重新循环列表
        fi

        local SELECTED_DOMAIN="${domains[$((choice_idx-1))]}"
        
        # 3. 对选中的对象进行操作
        while true; do
            local -a action_menu=(
                "1. 查看详细信息 (Check Details)"
                "2. 强制续期 (Force Renew)"
                "3. 删除证书 (Remove)"
                "0. 返回列表"
            )
            _render_menu "管理: $SELECTED_DOMAIN" "${action_menu[@]}"
            local action
            action=$(_prompt_for_menu_choice "1-3/0")
            
            case "$action" in
                1)
                    # 查看详情
                    local cert_file="$HOME/.acme.sh/${SELECTED_DOMAIN}_ecc/fullchain.cer"
                    [ ! -f "$cert_file" ] && cert_file="$HOME/.acme.sh/${SELECTED_DOMAIN}/fullchain.cer"
                    if [ -f "$cert_file" ]; then
                        openssl x509 -in "$cert_file" -noout -text | grep -E "Issuer:|Not After|Subject:"
                        log_info "物理文件位置: $cert_file"
                    else
                        log_err "找不到证书文件。"
                    fi
                    read -r -p "按 Enter 返回..." 
                    ;;
                2)
                    # 续期
                    log_info "正在续期 $SELECTED_DOMAIN ..."
                    if "$ACME_BIN" --renew -d "$SELECTED_DOMAIN" --force --ecc; then
                        log_success "续期成功。"
                    else
                        log_err "续期失败。"
                        [ -f "$HOME/.acme.sh/acme.sh.log" ] && tail -n 10 "$HOME/.acme.sh/acme.sh.log"
                    fi
                    read -r -p "按 Enter 返回..."
                    ;;
                3)
                    # 删除
                    if confirm_action "⚠️ 确认彻底删除 $SELECTED_DOMAIN ?"; then
                        "$ACME_BIN" --remove -d "$SELECTED_DOMAIN" --ecc || true
                        if [ -d "/etc/ssl/$SELECTED_DOMAIN" ]; then
                            run_with_sudo rm -rf "/etc/ssl/$SELECTED_DOMAIN"
                        fi
                        log_success "已删除。"
                        break 2 # 跳出两层循环，回到列表刷新
                    fi
                    ;;
                0)
                    break # 跳出操作循环，回到列表
                    ;;
                *) 
                    log_warn "无效选项" 
                    ;;
            esac
        done
    done
}

# --- 整合系统维护模块 ---
_system_maintenance() {
    while true; do
        local -a sys_menu=(
            "1. 诊断自动续期 (Check Auto-Renew)"
            "2. 升级 acme.sh (Upgrade Core)"
            "3. 开启自动更新 (Enable Auto-Upgrade)"
            "4. 关闭自动更新 (Disable Auto-Upgrade)"
            "0. 返回主菜单"
        )
        _render_menu "系统维护" "${sys_menu[@]}"
        local sys_choice
        sys_choice=$(_prompt_for_menu_choice "1-4/0")
        
        case "$sys_choice" in
            1)
                log_info "检查 Cron 服务..."
                if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
                    log_success "Cron 服务运行中。"
                else
                    log_err "Cron 未运行。"
                    confirm_action "尝试启动?" && (run_with_sudo systemctl enable --now cron 2>/dev/null || run_with_sudo systemctl enable --now crond 2>/dev/null)
                fi
                if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                    log_success "Crontab 任务存在。"
                else
                    log_err "Crontab 任务缺失。"
                    confirm_action "修复?" && "$ACME_BIN" --install-cronjob
                fi
                ;;
            2)
                "$ACME_BIN" --upgrade
                ;;
            3)
                "$ACME_BIN" --upgrade --auto-upgrade
                ;;
            4)
                "$ACME_BIN" --upgrade --auto-upgrade 0
                ;;
            0)
                return
                ;;
            *)
                log_warn "无效选项"
                ;;
        esac
        echo "" # 空行美化
    done
}

main_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a menu_items=(
            "1. 申请新证书 (Apply New Cert)"
            "2. 证书列表与管理 (List & Manage)"
            "3. 系统维护与设置 (System Settings)"
        )
        _render_menu "🔐 SSL 证书管理 (acme.sh)" "${menu_items[@]}"
        
        local choice
        choice=$(_prompt_for_menu_choice "1-3")

        case "$choice" in
            1) _apply_for_certificate ;;
            2) _manage_certificates ;;
            3) _system_maintenance ;;
            "") return 10 ;; 
            *) log_warn "无效选项。" ;;
        esac
        
        # 统一的暂停点，仅在主循环的一轮结束时出现
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
