# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v3.4.0-卡片式列表UI)
# - UI: 证书列表改为卡片式布局，信息更直观。
# - 新增: 尝试自动读取并显示证书的实际安装路径。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v3.4.0"

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
    
    # 智能检测 Web 服务器
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
    local -a method_display=("1. standalone (HTTP验证, 需80端口)" "2. dns_cf (Cloudflare API)" "3. dns_ali (阿里云 API)")
    _render_menu "验证方式" "${method_display[@]}"
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
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        log_info "正在扫描证书详情 (请稍候)..."
        
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

        # UI: 卡片式列表
        echo ""
        local i
        for ((i=0; i<${#domains[@]}; i++)); do
            local d="${domains[i]}"
            
            # 1. 查找证书文件
            local cert_file="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
            local conf_file="$HOME/.acme.sh/${d}_ecc/${d}.conf"
            
            # 回退到 RSA 目录
            if [ ! -f "$cert_file" ]; then 
                cert_file="$HOME/.acme.sh/${d}/fullchain.cer"
                conf_file="$HOME/.acme.sh/${d}/${d}.conf"
            fi
            
            local status_text="未知"
            local days_info=""
            local date_str="未知"
            local color="$NC"
            local install_path="自动安装路径未知"

            # 2. 解析证书信息 (状态、日期)
            if [ -f "$cert_file" ]; then
                local end_date; end_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                if [ -n "$end_date" ]; then
                    local end_ts; end_ts=$(date -d "$end_date" +%s)
                    local now_ts; now_ts=$(date +%s)
                    local left_days=$(( (end_ts - now_ts) / 86400 ))
                    date_str=$(date -d "$end_date" +%F 2>/dev/null || echo "Err")

                    if (( left_days < 0 )); then
                        color="$RED"; status_text="已过期"; days_info="过期 ${left_days#-} 天"
                    elif (( left_days < 30 )); then
                        color="$YELLOW"; status_text="即将到期"; days_info="剩余 $left_days 天"
                    else
                        color="$GREEN"; status_text="有效"; days_info="剩余 $left_days 天"
                    fi
                fi
            else
                color="$RED"
                status_text="文件丢失"
                days_info="无文件"
            fi
            
            # 3. 解析安装路径 (从 .conf 文件读取 Le_RealFullChainPath)
            if [ -f "$conf_file" ]; then
                local raw_path
                # 尝试提取 Le_RealFullChainPath='/etc/ssl/xxx'
                raw_path=$(grep "^Le_RealFullChainPath=" "$conf_file" | cut -d= -f2- | tr -d "'\"")
                if [ -n "$raw_path" ]; then
                    install_path=$(dirname "$raw_path")
                fi
            fi

            # 4. 打印卡片
            printf "${GREEN}[ %d ] %s${NC}\n" "$((i+1))" "$d"
            printf "  ├─ 路 径 : %s\n" "$install_path"
            printf "  └─ 证 书 : ${color}%s (%s , %s 到 期)${NC}\n" "$status_text" "$days_info" "$date_str"
            echo -e "${CYAN}····························································${NC}"
        done
        
        # 5. 选择操作
        local choice_idx
        choice_idx=$(_prompt_user_input "请输入序号管理 (按 Enter 返回主菜单): " "")
        
        if [ -z "$choice_idx" ]; then return; fi 
        if [ "$choice_idx" == "0" ]; then return; fi

        if ! [[ "$choice_idx" =~ ^[0-9]+$ ]] || (( choice_idx < 1 || choice_idx > ${#domains[@]} )); then
            log_err "无效序号。"
            press_enter_to_continue
            continue
        fi

        local SELECTED_DOMAIN="${domains[$((choice_idx-1))]}"
        
        while true; do
            local -a action_menu=(
                "1. 查看详细信息 (Details)"
                "2. 强制续期 (Force Renew)"
                "3. 删除证书 (Remove)"
                "0. 返回列表"
            )
            _render_menu "管理: $SELECTED_DOMAIN" "${action_menu[@]}"
            
            local action
            action=$(_prompt_for_menu_choice "1-3/0")
            
            case "$action" in
                1)
                    local cert_file="$HOME/.acme.sh/${SELECTED_DOMAIN}_ecc/fullchain.cer"
                    [ ! -f "$cert_file" ] && cert_file="$HOME/.acme.sh/${SELECTED_DOMAIN}/fullchain.cer"
                    if [ -f "$cert_file" ]; then
                        echo -e "${CYAN}--- 证书详情 ---${NC}"
                        openssl x509 -in "$cert_file" -noout -text | grep -E "Issuer:|Not After|Subject:|DNS:"
                        echo -e "${CYAN}----------------${NC}"
                        log_info "文件路径: $cert_file"
                    else
                        log_err "找不到证书文件。"
                    fi
                    press_enter_to_continue
                    ;;
                2)
                    log_info "正在续期 $SELECTED_DOMAIN ..."
                    if "$ACME_BIN" --renew -d "$SELECTED_DOMAIN" --force --ecc; then
                        log_success "续期成功。"
                    else
                        log_err "续期失败。"
                        [ -f "$HOME/.acme.sh/acme.sh.log" ] && tail -n 10 "$HOME/.acme.sh/acme.sh.log"
                    fi
                    press_enter_to_continue
                    ;;
                3)
                    if confirm_action "⚠️  确认彻底删除 $SELECTED_DOMAIN ?"; then
                        "$ACME_BIN" --remove -d "$SELECTED_DOMAIN" --ecc || true
                        if [ -d "/etc/ssl/$SELECTED_DOMAIN" ]; then
                            run_with_sudo rm -rf "/etc/ssl/$SELECTED_DOMAIN"
                        fi
                        log_success "已删除。"
                        break 2 
                    fi
                    ;;
                0|"")
                    break 
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
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
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
                press_enter_to_continue
                ;;
            2)
                "$ACME_BIN" --upgrade
                press_enter_to_continue
                ;;
            3)
                "$ACME_BIN" --upgrade --auto-upgrade
                press_enter_to_continue
                ;;
            4)
                "$ACME_BIN" --upgrade --auto-upgrade 0
                press_enter_to_continue
                ;;
            0|"")
                return
                ;;
            *)
                log_warn "无效选项"
                ;;
        esac
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
            1) 
                _apply_for_certificate
                press_enter_to_continue
                ;;
            2) 
                _manage_certificates 
                ;;
            3) 
                _system_maintenance 
                ;;
            "") return 10 ;; 
            *) log_warn "无效选项。" ; press_enter_to_continue ;;
        esac
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
