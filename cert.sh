# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v4.0.0-核心重构版)
# - 重构: 提取证书查找、日期解析、服务检测为公共函数。
# - 优化: 大幅减少冗余代码，提升脚本可维护性。
# - 功能: 保持 v3.7.0 所有特性 (CA显示/续期时间/端口修复)。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.0.0"

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
# 用法: _get_cert_path "domain.com"
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

# 3. 智能检测 Web 服务
_detect_web_service() {
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet nginx; then echo "nginx"; return; fi
        if systemctl is-active --quiet apache2; then echo "apache2"; return; fi
        if systemctl is-active --quiet httpd; then echo "httpd"; return; fi
        if systemctl is-active --quiet caddy; then echo "caddy"; return; fi
    fi
    echo ""
}

# 4. 解析证书详情 (输出为全局变量，减少重复调用 openssl)
_parse_cert_info() {
    local cert_path="$1"
    # 重置全局变量
    CERT_STATUS="未知"; CERT_DAYS="未知"; CERT_DATE="未知"; CERT_CA="未知"; CERT_COLOR="$NC"

    if [[ ! -f "$cert_path" ]]; then
        CERT_STATUS="文件丢失"; CERT_COLOR="$RED"; return
    fi

    local end_date; end_date=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
    local issuer; issuer=$(openssl x509 -issuer -noout -in "$cert_path" 2>/dev/null)

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

    if [[ "$issuer" == *"ZeroSSL"* ]]; then CERT_CA="ZeroSSL"
    elif [[ "$issuer" == *"Let's Encrypt"* ]]; then CERT_CA="Let's Encrypt"
    elif [[ "$issuer" == *"Google"* ]]; then CERT_CA="Google Public CA"
    else CERT_CA="Other CA"; fi
}

# 5. 处理 Standalone 端口冲突
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
    # 返回 needs_restart 状态 (通过全局变量或 echo)
    echo "$needs_restart:$svc_name"
}

# =============================================================
# SECTION: 业务功能函数
# =============================================================

_check_dependencies() {
    if ! command -v socat &>/dev/null; then
        log_warn "未检测到 socat。"
        confirm_action "自动安装 socat?" && {
            if command -v apt-get &>/dev/null; then run_with_sudo apt-get update && run_with_sudo apt-get install -y socat
            elif command -v yum &>/dev/null; then run_with_sudo yum install -y socat
            else log_err "请手动安装 socat。"; return 1; fi
        }
    fi
    if [[ ! -f "$ACME_BIN" ]]; then
        log_warn "未安装 acme.sh。"
        local m=$(_prompt_user_input "注册邮箱: " "")
        local cmd="curl https://get.acme.sh | sh"
        [[ -n "$m" ]] && cmd+=" -s email=$m"
        eval "$cmd" || { log_err "安装失败"; return 1; }
    fi
    export PATH="$HOME/.acme.sh:$PATH"
}

_apply_for_certificate() {
    log_info "--- 申请新证书 ---"
    local domain; domain=$(_prompt_user_input "请输入域名: ")
    [[ -z "$domain" ]] && return

    # 解析验证
    local s_ip; s_ip=$(curl -s https://api.ipify.org)
    local d_ip; d_ip=$(dig +short "$domain" A | head -n1)
    if [[ "$d_ip" != "$s_ip" ]]; then
        log_warn "IP 不匹配 (本机:$s_ip 域名:$d_ip)"
        confirm_action "强制继续?" || return
    fi

    local wc=""; confirm_action "申请泛域名 (*.$domain)?" && wc="*.$domain"
    local path; path=$(_prompt_user_input "保存路径 [/etc/ssl/$domain]: " "/etc/ssl/$domain")
    
    local svc=$(_detect_web_service)
    local reload_cmd="systemctl reload ${svc:-nginx}"
    reload_cmd=$(_prompt_user_input "重载命令 [$reload_cmd]: " "$reload_cmd")

    local method_idx=$(_prompt_for_menu_choice "1-3" "1.Standalone,2.DNS_CF,3.DNS_Ali")
    local method="standalone"; local pre=""; local post=""
    
    case "$method_idx" in
        1)
            method="standalone"
            if run_with_sudo ss -tuln | grep -q ":80\s"; then
                log_err "80 端口被占用。"
                return 1
            fi
            if confirm_action "配置自动停/启钩子?"; then
                local s=${svc:-nginx}
                s=$(_prompt_user_input "服务名 [$s]: " "$s")
                pre="systemctl stop $s"; post="systemctl start $s"
            fi
            ;;
        2)
            method="dns_cf"
            local t=$(_prompt_user_input "CF_Token: " ""); local a=$(_prompt_user_input "CF_Account_ID: " "")
            [[ -z "$t" || -z "$a" ]] && return 1
            export CF_Token="$t" CF_Account_ID="$a"
            ;;
        3)
            method="dns_ali"
            local k=$(_prompt_user_input "Ali_Key: " ""); local s=$(_prompt_user_input "Ali_Secret: " "")
            [[ -z "$k" || -z "$s" ]] && return 1
            export Ali_Key="$k" Ali_Secret="$s"
            ;;
    esac

    # ZeroSSL 检查
    if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
        local m=$(_prompt_user_input "ZeroSSL 注册邮箱 (可选): " "")
        [[ -n "$m" ]] && "$ACME_BIN" --register-account -m "$m" --server zerossl
    fi

    local issue_cmd=("$ACME_BIN" --issue -d "$domain" --"$method")
    [[ -n "$wc" ]] && issue_cmd+=(-d "$wc")
    [[ -n "$pre" ]] && issue_cmd+=(--pre-hook "$pre")
    [[ -n "$post" ]] && issue_cmd+=(--post-hook "$post")

    if ! "${issue_cmd[@]}"; then
        log_err "申请失败。查看日志: tail -n 20 ~/.acme.sh/acme.sh.log"
        return 1
    fi

    run_with_sudo mkdir -p "$path"
    "$ACME_BIN" --install-cert -d "$domain" --ecc \
        --key-file "$path/$domain.key" --fullchain-file "$path/$domain.crt" \
        --reloadcmd "$reload_cmd" || { log_err "安装失败"; return 1; }
        
    run_with_sudo bash -c "date +'%Y-%m-%d %H:%M:%S' > '$path/.apply_time'"
    log_success "成功安装至: $path"
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

            printf "${GREEN}[ %d ] %s${NC}\n" "$((i+1))" "$d"
            printf "  ├─ 续 期 : %s (计划)\n" "$next_renew"
            printf "  ├─ 机 构 : %s\n" "$CERT_CA"
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
