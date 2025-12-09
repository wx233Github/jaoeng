# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v4.1.0-稳定回归版)
# - 修复: 还原证书申请逻辑至 v3.7.0，解决执行出错问题。
# - UI: 证书列表移除 CA 机构显示。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.1.0"

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
    # 简易回退模式
    log_err() { echo -e "\033[31m[Error]\033[0m $*" >&2; }
    log_info() { echo -e "\033[36m[Info]\033[0m $*"; }
    log_warn() { echo -e "\033[33m[Warn]\033[0m $*"; }
    log_success() { echo -e "\033[32m[Success]\033[0m $*"; }
    generate_line() { local l=${1:-40}; printf "%${l}s" "" | sed "s/ /-/g"; }
    press_enter_to_continue() { read -r -p "Press Enter..."; }
    confirm_action() { read -r -p "$1 (y/n): " c; [[ "$c" == "y" ]] && return 0 || return 1; }
    _prompt_user_input() { read -r -p "$1" v; echo "${v:-$2}"; }
    _prompt_for_menu_choice() { read -r -p "Choice: " v; echo "$v"; }
    _render_menu() { echo "--- $1 ---"; shift; for l in "$@"; do echo "$l"; done; }
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; NC="\033[0m"; ORANGE="\033[33m";
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then run_with_sudo() { "$@"; }; fi

# --- 全局变量 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"

# =============================================================
# SECTION: 私有辅助函数 (逻辑复用)
# =============================================================

# 1. 查找证书文件路径 (优先ECC，回退RSA)
_get_cert_path() {
    local d=$1
    local ecc="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    if [[ -f "$ecc" ]]; then echo "$ecc"; else echo "$HOME/.acme.sh/${d}/fullchain.cer"; fi
}

# 2. 查找配置文件路径
_get_conf_path() {
    local d=$1
    local ecc="$HOME/.acme.sh/${d}_ecc/${d}.conf"
    if [[ -f "$ecc" ]]; then echo "$ecc"; else echo "$HOME/.acme.sh/${d}/${d}.conf"; fi
}

# 3. 智能检测 Web 服务 (用于续期和申请时的建议)
_detect_web_service() {
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nginx; then echo "nginx"; return; fi
        if systemctl is-active --quiet apache2; then echo "apache2"; return; fi
        if systemctl is-active --quiet httpd; then echo "httpd"; return; fi
        if systemctl is-active --quiet caddy; then echo "caddy"; return; fi
    fi
    echo ""
}

# 4. 解析证书详情 (输出为全局变量)
_parse_cert_info() {
    local cert_path="$1"
    # 重置全局变量
    CERT_STATUS="未知"; CERT_DAYS="未知"; CERT_DATE="未知"; CERT_COLOR="$NC"

    if [[ ! -f "$cert_path" ]]; then
        CERT_STATUS="文件丢失"; CERT_COLOR="$RED"; return
    fi

    local end_date; end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    
    if [[ -n "$end_date" ]]; then
        local end_ts; end_ts=$(date -d "$end_date" +%s)
        local now_ts; now_ts=$(date +%s)
        local left_days=$(( (end_ts - now_ts) / 86400 ))
        CERT_DATE=$(date -d "$end_date" +%F 2>/dev/null || echo "Err")
        
        if (( left_days < 0 )); then
            CERT_COLOR="$RED"; CERT_STATUS="已过期"; CERT_DAYS="过期 ${left_days#-} 天"
        elif (( left_days < 30 )); then
            CERT_COLOR="$YELLOW"; CERT_STATUS="即将到期"; CERT_DAYS="剩余 $left_days 天"
        else
            CERT_COLOR="$GREEN"; CERT_STATUS="有效"; CERT_DAYS="剩余 $left_days 天"
        fi
    fi
}

# 5. 处理 Standalone 端口冲突 (仅用于管理模块的续期逻辑)
_handle_standalone_conflict() {
    local svc_name=$(_detect_web_service)
    local needs_restart="false"

    if run_with_sudo ss -tuln | grep -q ":80\s"; then
        if [[ -n "$svc_name" ]]; then
            log_warn "端口 80 被 $svc_name 占用。"
            if confirm_action "临时停止 $svc_name 以继续续期?"; then
                log_info "停止 $svc_name ..."
                run_with_sudo systemctl stop "$svc_name"
                needs_restart="true"
            else
                return 1 # 用户拒绝
            fi
        else
            log_warn "端口 80 被未知进程占用，Standalone 模式可能失败。"
        fi
    fi
    echo "$needs_restart:$svc_name"
}

# =============================================================
# SECTION: 核心业务函数
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

# --- 还原后的申请逻辑 (v3.7.0版本) ---
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
    local detected_svc=$(_detect_web_service)
    if [ -n "$detected_svc" ]; then
        detected_reload="systemctl reload $detected_svc"
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

_manage_certificates() {
    [[ ! -f "$ACME_BIN" ]] && { log_err "acme.sh 未安装"; return; }

    while true; do
        [[ "${JB_ENABLE_AUTO_CLEAR:-false}" == "true" ]] && clear
        log_info "扫描证书..."
        
        local raw_list; raw_list=$("$ACME_BIN" --list)
        local domains=()
        while read -r line; do
            [[ "$line" == Main_Domain* ]] && continue
            local d; d=$(echo "$line" | awk '{print $1}')
            [[ -n "$d" ]] && domains+=("$d")
        done <<< "$raw_list"

        [[ ${#domains[@]} -eq 0 ]] && { log_warn "无证书"; return; }

        echo ""
        for ((i=0; i<${#domains[@]}; i++)); do
            local d="${domains[i]}"
            local cert_path=$(_get_cert_path "$d")
            local conf_path=$(_get_conf_path "$d")
            
            # 解析基本信息
            _parse_cert_info "$cert_path"
            
            # 解析额外配置
            local install_path="未知"; local next_renew="自动/未知"
            if [[ -f "$conf_path" ]]; then
                local rp; rp=$(grep "^Le_RealFullChainPath=" "$conf_path" | cut -d= -f2- | tr -d "'\"")
                [[ -n "$rp" ]] && install_path=$(dirname "$rp")
                local nt; nt=$(grep "^Le_NextRenewTime=" "$conf_path" | cut -d= -f2- | tr -d "'\"")
                [[ -n "$nt" ]] && next_renew=$(date -d "@$nt" +%F 2>/dev/null)
            fi

            # UI: 移除机构显示
            printf "${GREEN}[ %d ] %s${NC}\n" "$((i+1))" "$d"
            printf "  ├─ 续 期 : %s (计划)\n" "$next_renew"
            printf "  ├─ 路 径 : %s\n" "$install_path"
            printf "  └─ 证 书 : ${CERT_COLOR}%s (%s , %s 到 期)${NC}\n" "$CERT_STATUS" "$CERT_DAYS" "$CERT_DATE"
            echo -e "${CYAN}····························································${NC}"
        done

        local idx=$(_prompt_user_input "输入序号管理 (Enter 返回): " "")
        [[ -z "$idx" || "$idx" == "0" ]] && return
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#domains[@]} )); then
            log_err "无效序号"; press_enter_to_continue; continue
        fi

        local sel_domain="${domains[$((idx-1))]}"
        
        while true; do
            _render_menu "管理: $sel_domain" "1. 查看详情" "2. 强制续期" "3. 删除证书" "0. 返回"
            local act=$(_prompt_for_menu_choice "1-3/0")
            case "$act" in
                1)
                    local cp=$(_get_cert_path "$sel_domain")
                    if [[ -f "$cp" ]]; then
                        echo -e "${CYAN}--- Info ---${NC}"; openssl x509 -in "$cp" -noout -text | grep -E "Issuer:|Not After|DNS:"; echo -e "${CYAN}------------${NC}"
                    else log_err "文件不存在"; fi
                    press_enter_to_continue
                    ;;
                2)
                    log_info "准备续期 $sel_domain ..."
                    # 处理端口冲突
                    local conflict_res
                    conflict_res=$(_handle_standalone_conflict) || { log_warn "已取消续期"; continue; }
                    
                    local restart_needed="${conflict_res%%:*}"
                    local svc_name="${conflict_res#*:}"

                    # 执行续期 (允许 Reload 失败)
                    set +e
                    "$ACME_BIN" --renew -d "$sel_domain" --force --ecc
                    local ret=$?
                    set -e

                    if [ $ret -eq 0 ]; then log_success "续期成功";
                    elif [ "$restart_needed" == "true" ]; then log_warn "acme.sh 返回非0 (因服务停止导致Reload失败，属预期行为)";
                    else log_err "续期失败"; fi
                    
                    if [ "$restart_needed" == "true" ]; then
                        log_info "重启 $svc_name ..."
                        run_with_sudo systemctl start "$svc_name"
                    fi
                    press_enter_to_continue
                    ;;
                3)
                    confirm_action "确认删除 $sel_domain ?" && {
                        "$ACME_BIN" --remove -d "$sel_domain" --ecc || true
                        [[ -d "/etc/ssl/$sel_domain" ]] && run_with_sudo rm -rf "/etc/ssl/$sel_domain"
                        log_success "已删除"; break 2
                    }
                    ;;
                0|"") break ;;
            esac
        done
    done
}

_system_maintenance() {
    while true; do
        [[ "${JB_ENABLE_AUTO_CLEAR:-false}" == "true" ]] && clear
        _render_menu "系统维护" "1. 诊断自动续期" "2. 升级 acme.sh" "3. 开启自动更新" "4. 关闭自动更新" "0. 返回"
        local c=$(_prompt_for_menu_choice "1-4/0")
        case "$c" in
            1)
                log_info "检查 Cron..."
                if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then log_success "Cron 运行中"; else log_err "Cron 未运行"; fi
                if crontab -l 2>/dev/null | grep -q "acme.sh"; then log_success "任务存在"; else
                    confirm_action "任务缺失，修复?" && "$ACME_BIN" --install-cronjob
                fi
                ;;
            2) "$ACME_BIN" --upgrade ;;
            3) "$ACME_BIN" --upgrade --auto-upgrade ;;
            4) "$ACME_BIN" --upgrade --auto-upgrade 0 ;;
            0|"") return ;;
        esac
        press_enter_to_continue
    done
}

main() {
    trap 'echo -e "\n操作中断"; exit 10' INT
    [[ "$(id -u)" -ne 0 ]] && { log_err "需 root 权限"; exit 1; }
    log_info "SSL 证书管理 ${SCRIPT_VERSION}"
    _check_dependencies || return 1
    
    while true; do
        [[ "${JB_ENABLE_AUTO_CLEAR:-false}" == "true" ]] && clear
        _render_menu "主菜单" "1. 申请证书" "2. 管理证书 (列表/续期/删除)" "3. 系统维护"
        local c=$(_prompt_for_menu_choice "1-3")
        case "$c" in
            1) _apply_for_certificate; press_enter_to_continue ;;
            2) _manage_certificates ;;
            3) _system_maintenance ;;
            "") exit ;;
            *) log_warn "无效选项"; press_enter_to_continue ;;
        esac
    done
}

main "$@"
