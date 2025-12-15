# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v3.15.0-文案微调版)
# - 优化: API Token 输入提示更符合直觉。
# - 移除: 冗余的 CA 推荐日志信息。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v3.15.0"

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
# SECTION: 辅助功能函数 (私有)
# =============================================================

_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    local svc
    for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then
            echo "$svc"
            return
        fi
    done
}

_get_cert_files() {
    local domain="$1"
    CERT_FILE="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    CONF_FILE="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
    if [ ! -f "$CERT_FILE" ]; then
        CERT_FILE="$HOME/.acme.sh/${domain}/fullchain.cer"
        CONF_FILE="$HOME/.acme.sh/${domain}/${domain}.conf"
    fi
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

# 参数1: 可选，预设域名 (用于重新配置模式)
_apply_for_certificate() {
    local PRESET_DOMAIN="$1"
    
    log_info "--- 申请/重新配置证书 ---"
    
    local DOMAIN SERVER_IP DOMAIN_IP
    
    if [ -n "$PRESET_DOMAIN" ]; then
        DOMAIN="$PRESET_DOMAIN"
        log_info "目标域名: ${CYAN}$DOMAIN${NC}"
    else
        while true; do
            DOMAIN=$(_prompt_user_input "请输入你的主域名: ")
            if [ -z "$DOMAIN" ]; then log_warn "域名不能为空。"; continue; fi
            break
        done
    fi

    # --- 切换 CA (默认推荐 Let's Encrypt) ---
    echo ""
    # 移除了之前的 log_info 建议提示
    local CA_SERVER="letsencrypt"
    
    local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
    _render_menu "选择 CA 机构" "${ca_list[@]}"
    local ca_choice
    ca_choice=$(_prompt_for_menu_choice "1-3")
    case "$ca_choice" in
        1) CA_SERVER="letsencrypt" ;;
        2) CA_SERVER="zerossl" ;;
        3) CA_SERVER="google" ;;
        *) CA_SERVER="letsencrypt" ;;
    esac
    
    if [ -n "$CA_SERVER" ]; then
        log_info "正在设置默认 CA 为: $CA_SERVER ..."
        "$ACME_BIN" --set-default-ca --server "$CA_SERVER"
    fi
    # -------------------------

    local USE_WILDCARD=""
    echo -ne "${YELLOW}是否申请泛域名证书 (*.$DOMAIN)？ (y/[N]): ${NC}"
    read -r wild_choice
    if [[ "$wild_choice" == "y" || "$wild_choice" == "Y" ]]; then
        USE_WILDCARD="*.$DOMAIN"
        log_info "已启用泛域名: $USE_WILDCARD"
    else
        log_info "不申请泛域名。"
    fi

    local INSTALL_PATH
    INSTALL_PATH=$(_prompt_user_input "证书保存路径 [默认: /etc/ssl/$DOMAIN]: " "/etc/ssl/$DOMAIN")
    
    local active_svc
    active_svc=$(_detect_web_service)
    local default_reload="systemctl reload nginx"
    [ -n "$active_svc" ] && default_reload="systemctl reload $active_svc"

    local RELOAD_CMD
    RELOAD_CMD=$(_prompt_user_input "重载命令 [默认: $default_reload]: " "$default_reload")

    local -a method_display=("1. standalone (HTTP验证, 80端口)" "2. dns_cf (Cloudflare API)" "3. dns_ali (阿里云 API)")
    _render_menu "验证方式" "${method_display[@]}"
    local VERIFY_CHOICE
    VERIFY_CHOICE=$(_prompt_for_menu_choice "1-3")
    
    local METHOD PRE_HOOK POST_HOOK

    # 读取历史配置 (用于自动填充)
    local account_conf="$HOME/.acme.sh/account.conf"
    
    case "$VERIFY_CHOICE" in
        1) 
            METHOD="standalone"
            if run_with_sudo ss -tuln | grep -q ":80\s"; then
                log_err "80端口被占用。"
                run_with_sudo ss -tuln | grep ":80\s"
                return 1
            fi
            if confirm_action "配置自动续期钩子 (自动停/启 Web服务)?"; then
                local svc_guess="${active_svc:-nginx}"
                local svc
                svc=$(_prompt_user_input "服务名称 (如 $svc_guess): " "$svc_guess")
                PRE_HOOK="systemctl stop $svc"
                POST_HOOK="systemctl start $svc"
            fi
            ;;
        2) 
            METHOD="dns_cf"
            echo ""
            log_info "【安全】Token 仅驻留内存用后即焚。推荐使用 API Token (Edit Zone DNS)。"
            
            # 尝试从 account.conf 读取历史 Token
            local def_token=""
            local def_acc=""
            if [ -f "$account_conf" ]; then
                def_token=$(grep "^SAVED_CF_Token=" "$account_conf" | cut -d= -f2- | tr -d "'\"")
                def_acc=$(grep "^SAVED_CF_Account_ID=" "$account_conf" | cut -d= -f2- | tr -d "'\"")
            fi
            
            local p_token="输入 CF_Token"
            [ -n "$def_token" ] && p_token+=" (回车复用已保存)"
            local p_acc="输入 CF_Account_ID"
            [ -n "$def_acc" ] && p_acc+=" (回车复用已保存)"

            local cf_token cf_acc
            cf_token=$(_prompt_user_input "$p_token: " "")
            cf_acc=$(_prompt_user_input "$p_acc: " "")
            
            # 逻辑：如果输入为空且有默认值，则使用默认值
            if [ -z "$cf_token" ] && [ -n "$def_token" ]; then
                cf_token="$def_token"
                echo -e "${CYAN}  -> 已使用保存的 Token${NC}"
            fi
            if [ -z "$cf_acc" ] && [ -n "$def_acc" ]; then
                cf_acc="$def_acc"
                echo -e "${CYAN}  -> 已使用保存的 Account ID${NC}"
            fi
            
            [ -z "$cf_token" ] || [ -z "$cf_acc" ] && { log_err "信息不完整。"; return 1; }
            export CF_Token="$cf_token"
            export CF_Account_ID="$cf_acc"
            ;;
        3) 
            METHOD="dns_ali"
            log_info "【安全】Key/Secret 仅驻留内存用后即焚。"
            
            local def_key=""
            local def_sec=""
            if [ -f "$account_conf" ]; then
                def_key=$(grep "^SAVED_Ali_Key=" "$account_conf" | cut -d= -f2- | tr -d "'\"")
                def_sec=$(grep "^SAVED_Ali_Secret=" "$account_conf" | cut -d= -f2- | tr -d "'\"")
            fi

            local p_key="输入 Ali_Key"
            [ -n "$def_key" ] && p_key+=" (回车复用已保存)"
            local p_sec="输入 Ali_Secret"
            [ -n "$def_sec" ] && p_sec+=" (回车复用已保存)"

            local ali_key ali_sec
            ali_key=$(_prompt_user_input "$p_key: " "")
            ali_sec=$(_prompt_user_input "$p_sec: " "")
            
            if [ -z "$ali_key" ] && [ -n "$def_key" ]; then
                ali_key="$def_key"
                echo -e "${CYAN}  -> 已使用保存的 Key${NC}"
            fi
            if [ -z "$ali_sec" ] && [ -n "$def_sec" ]; then
                ali_sec="$def_sec"
                echo -e "${CYAN}  -> 已使用保存的 Secret${NC}"
            fi
            
            [ -z "$ali_key" ] || [ -z "$ali_sec" ] && { log_err "信息不完整。"; return 1; }
            export Ali_Key="$ali_key"
            export Ali_Secret="$ali_sec"
            ;;
        *) return ;;
    esac

    if [[ "$CA_SERVER" == "zerossl" ]] && ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
         log_info "检查 ZeroSSL 账户..."
         local reg_email
         reg_email=$(_prompt_user_input "若需使用 ZeroSSL，请输入邮箱注册 (回车跳过): " "")
         if [ -n "$reg_email" ]; then
             "$ACME_BIN" --register-account -m "$reg_email" --server zerossl || log_warn "ZeroSSL 注册跳过。"
         fi
    fi

    log_info "🚀 正在申请证书..."
    
    local ISSUE_CMD=("$ACME_BIN" --issue -d "$DOMAIN")
    
    if [[ "$METHOD" == "standalone" ]]; then
        ISSUE_CMD+=(--standalone)
    else
        ISSUE_CMD+=(--dns "$METHOD")
    fi
    
    if [ -n "$USE_WILDCARD" ]; then ISSUE_CMD+=(-d "$USE_WILDCARD"); fi
    if [ -n "$PRE_HOOK" ]; then ISSUE_CMD+=(--pre-hook "$PRE_HOOK"); fi
    if [ -n "$POST_HOOK" ]; then ISSUE_CMD+=(--post-hook "$POST_HOOK"); fi
    
    ISSUE_CMD+=(--force)
    if [ -n "$CA_SERVER" ]; then ISSUE_CMD+=(--server "$CA_SERVER"); fi

    if ! "${ISSUE_CMD[@]}"; then
        log_err "证书申请失败！日志如下:"
        [ -f "$HOME/.acme.sh/acme.sh.log" ] && tail -n 20 "$HOME/.acme.sh/acme.sh.log"
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    
    log_success "证书生成成功，正在安装..."
    run_with_sudo mkdir -p "$INSTALL_PATH"

    if ! "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$INSTALL_PATH/$DOMAIN.key" \
        --fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
        --reloadcmd      "$RELOAD_CMD"; then
        log_err "安装失败。"
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    
    run_with_sudo bash -c "date +'%Y-%m-%d %H:%M:%S' > '$INSTALL_PATH/.apply_time'"
    log_success "完成！路径: $INSTALL_PATH"
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret
}

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

        echo ""
        local i
        for ((i=0; i<${#domains[@]}; i++)); do
            local d="${domains[i]}"
            local CERT_FILE CONF_FILE
            _get_cert_files "$d"
            
            local status_text="未知"
            local days_info=""
            local date_str="未知"
            local next_renew_str="自动/未知"
            local color="$NC"
            local install_path="未知"
            local ca_str="未知"

            if [ -f "$CERT_FILE" ]; then
                local end_date; end_date=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
                if [ -n "$end_date" ]; then
                    local end_ts; end_ts=$(date -d "$end_date" +%s)
                    local left_days=$(( (end_ts - $(date +%s)) / 86400 ))
                    date_str=$(date -d "$end_date" +%F 2>/dev/null || echo "Err")

                    if (( left_days < 0 )); then
                        color="$RED"; status_text="已过期"; days_info="过期 ${left_days#-} 天"
                    elif (( left_days < 30 )); then
                        color="$YELLOW"; status_text="即将到期"; days_info="剩余 $left_days 天"
                    else
                        color="$GREEN"; status_text="有效"; days_info="剩余 $left_days 天"
                    fi
                fi
                
                local issuer
                issuer=$(openssl x509 -issuer -noout -in "$CERT_FILE" 2>/dev/null)
                if [[ "$issuer" == *"ZeroSSL"* ]]; then ca_str="ZeroSSL"
                elif [[ "$issuer" == *"Let's Encrypt"* ]]; then ca_str="Let's Encrypt"
                else ca_str="Other"
                fi
            else
                color="$RED"; status_text="文件丢失"; days_info="无文件"
            fi
            
            if [ -f "$CONF_FILE" ]; then
                local raw_path; raw_path=$(grep "^Le_RealFullChainPath=" "$CONF_FILE" | cut -d= -f2- | tr -d "'\"")
                [ -n "$raw_path" ] && install_path=$(dirname "$raw_path")
                local next_ts; next_ts=$(grep "^Le_NextRenewTime=" "$CONF_FILE" | cut -d= -f2- | tr -d "'\"")
                [ -n "$next_ts" ] && next_renew_str=$(date -d "@$next_ts" +%F 2>/dev/null || echo "Err")
            fi

            printf "${GREEN}[ %d ] %s${NC} (CA: %s)\n" "$((i+1))" "$d" "$ca_str"
            printf "  ├─ 路 径 : %s\n" "$install_path"
            printf "  ├─ 续 期 : %s (计划)\n" "$next_renew_str"
            printf "  └─ 证 书 : ${color}%s (%s , %s 到 期)${NC}\n" "$status_text" "$days_info" "$date_str"
            echo -e "${CYAN}····························································${NC}"
        done
        
        local choice_idx
        choice_idx=$(_prompt_user_input "请输入序号管理 (按 Enter 返回主菜单): " "")
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then return; fi

        if ! [[ "$choice_idx" =~ ^[0-9]+$ ]] || (( choice_idx < 1 || choice_idx > ${#domains[@]} )); then
            log_err "无效序号。"
            press_enter_to_continue
            continue
        fi

        local SELECTED_DOMAIN="${domains[$((choice_idx-1))]}"
        
        while true; do
            local -a action_menu=("1. 查看详情 (Details)" "2. 强制续期 (Force Renew)" "3. 删除证书 (Delete)" "4. 重新申请/切换模式 (Re-issue)")
            _render_menu "管理: $SELECTED_DOMAIN" "${action_menu[@]}"
            
            local action
            action=$(_prompt_for_menu_choice "1-4")
            
            case "$action" in
                1)
                    local CERT_FILE CONF_FILE
                    _get_cert_files "$SELECTED_DOMAIN"
                    if [ -f "$CERT_FILE" ]; then
                        echo -e "${CYAN}--- 证书详情 ---${NC}"
                        openssl x509 -in "$CERT_FILE" -noout -text | grep -E "Issuer:|Not After|Subject:|DNS:"
                        echo -e "${CYAN}----------------${NC}"
                        log_info "文件路径: $CERT_FILE"
                    else
                        log_err "找不到证书文件。"
                    fi
                    press_enter_to_continue
                    ;;
                2)
                    log_info "正在准备续期 $SELECTED_DOMAIN ..."
                    local port_conflict="false"
                    local temp_stop_svc=""
                    
                    if run_with_sudo ss -tuln | grep -q ":80\s"; then
                        log_warn "检测到 80 端口占用 (可能影响 Standalone 模式)。"
                        temp_stop_svc=$(_detect_web_service)
                        
                        if [ -n "$temp_stop_svc" ]; then
                            echo -e "${YELLOW}发现服务: $temp_stop_svc 正在运行。${NC}"
                            if confirm_action "是否临时停止 $temp_stop_svc 以释放端口? (续期后自动启动)"; then
                                port_conflict="true"
                            fi
                        fi
                    fi
                    
                    [ "$port_conflict" == "true" ] && { log_info "正在停止 $temp_stop_svc ..."; run_with_sudo systemctl stop "$temp_stop_svc"; }
                    
                    log_info "执行续期命令..."
                    local renew_success="false"
                    if "$ACME_BIN" --renew -d "$SELECTED_DOMAIN" --force --ecc; then
                        log_success "续期指令执行成功！"
                        renew_success="true"
                    else
                        local err_code=$?
                        local log_tail=""; [ -f "$HOME/.acme.sh/acme.sh.log" ] && log_tail=$(tail -n 15 "$HOME/.acme.sh/acme.sh.log")
                        
                        if [[ "$port_conflict" == "true" && "$log_tail" == *"Reload error"* ]]; then
                            log_success "证书可能已生成 (Reload 跳过，因服务已停止)。"
                            renew_success="true"
                        else
                            log_err "续期失败 (Code: $err_code)。"
                            echo "$log_tail"
                            
                            if [[ "$log_tail" == *"retryafter"* ]]; then
                                echo ""
                                log_warn "检测到 CA 限制错误 (retryafter)。请使用选项 [4. 重新申请] 并切换到 Let's Encrypt。"
                            fi
                        fi
                    fi
                    
                    if [ "$port_conflict" == "true" ]; then
                        log_info "正在重启 $temp_stop_svc ..."
                        run_with_sudo systemctl start "$temp_stop_svc"
                        if [ "$renew_success" == "true" ]; then
                            log_success "服务已启动，新证书应已生效。"
                        else
                            log_warn "服务已恢复 (使用旧证书)。"
                        fi
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
                4)
                    if confirm_action "此操作将覆盖原有配置 (可修复配置错误或切换CA)。确认继续?"; then
                         _apply_for_certificate "$SELECTED_DOMAIN"
                         press_enter_to_continue
                         break 2 
                    fi
                    ;;
                ""|"0") break ;;
                *) log_warn "无效选项" ;;
            esac
        done
    done
}

_system_maintenance() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a sys_menu=("1. 诊断自动续期" "2. 升级 acme.sh" "3. 开启自动更新" "4. 关闭自动更新")
        _render_menu "系统维护" "${sys_menu[@]}"
        local sys_choice
        sys_choice=$(_prompt_for_menu_choice "1-4")
        
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
            2) "$ACME_BIN" --upgrade; press_enter_to_continue ;;
            3) "$ACME_BIN" --upgrade --auto-upgrade; press_enter_to_continue ;;
            4) "$ACME_BIN" --upgrade --auto-upgrade 0; press_enter_to_continue ;;
            ""|"0") return ;;
            *) log_warn "无效选项" ;;
        esac
    done
}

main_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a menu_items=("1. 申请证书 (New Certificate)" "2. 证书管理 (Manage Certificates)" "3. 系统设置 (Settings)")
        _render_menu "🔐 SSL 证书管理 (acme.sh)" "${menu_items[@]}"
        
        local choice
        choice=$(_prompt_for_menu_choice "1-3")

        case "$choice" in
            1) _apply_for_certificate; press_enter_to_continue ;;
            2) _manage_certificates ;;
            3) _system_maintenance ;;
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
