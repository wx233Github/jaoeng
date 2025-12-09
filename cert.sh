# =============================================================
# 🚀 SSL 证书管理助手 (acme.sh) (v4.0.0-轻量重构版)
# - 重构: 抽象公共函数，大幅减少代码冗余。
# - 优化: 逻辑更紧凑，保持全功能 (卡片UI/自动续期/端口处理)。
# =============================================================

# --- 基础设定 ---
SCRIPT_VERSION="v4.0.0"
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}
ACME_BIN="$HOME/.acme.sh/acme.sh"

# --- 加载工具库 (含极简回退) ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
[ -f "$UTILS_PATH" ] && source "$UTILS_PATH"
# 如果工具库未加载，定义最小化回退函数
if ! declare -f log_info >/dev/null; then
    log_info() { echo -e "[Info] $*"; }
    log_warn() { echo -e "[Warn] $*"; }
    log_err()  { echo -e "[Error] $*" >&2; }
    log_success() { echo -e "[Success] $*"; }
    generate_line() { printf "%${1:-40}s" "" | sed "s/ /-/g"; }
    press_enter_to_continue() { read -r -p "Press Enter..."; }
    confirm_action() { read -r -p "$1 (y/n): " c; [[ "$c" == "y" ]] && return 0 || return 1; }
    _prompt_user_input() { read -r -p "$1" v; echo "${v:-$2}"; }
    _prompt_for_menu_choice() { read -r -p "Choice: " v; echo "$v"; }
    _render_menu() { echo "--- $1 ---"; shift; for l in "$@"; do echo "$l"; done; }
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""; BOLD=""; ORANGE="";
fi
if ! declare -f run_with_sudo &>/dev/null; then run_with_sudo() { "$@"; }; fi

# =============================================================
# SECTION: 公共辅助函数 (DRY核心)
# =============================================================

# 检测当前运行的 Web 服务 (返回: nginx, apache2, httpd, caddy 或 空)
_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then echo "$svc"; return; fi
    done
}

# 获取证书相关文件路径 (输出变量: CERT_FILE, CONF_FILE)
_get_cert_files() {
    local d="$1"
    CERT_FILE="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    CONF_FILE="$HOME/.acme.sh/${d}_ecc/${d}.conf"
    # 回退兼容 RSA
    if [ ! -f "$CERT_FILE" ]; then 
        CERT_FILE="$HOME/.acme.sh/${d}/fullchain.cer"
        CONF_FILE="$HOME/.acme.sh/${d}/${d}.conf"
    fi
}

# 安装依赖
_check_dependencies() {
    if ! command -v socat &>/dev/null; then
        log_warn "未检测到 socat。"
        confirm_action "自动安装 socat?" && {
            (command -v apt-get >/dev/null && run_with_sudo apt-get update && run_with_sudo apt-get install -y socat) || \
            (command -v yum >/dev/null && run_with_sudo yum install -y socat) || return 1
            log_success "socat 安装成功。"
        }
    fi
    if [[ ! -f "$ACME_BIN" ]]; then
        log_warn "安装 acme.sh ..."
        local e; e=$(_prompt_user_input "注册邮箱 (可选): " "")
        local cmd="curl https://get.acme.sh | sh"
        [ -n "$e" ] && cmd+=" -s email=$e"
        eval "$cmd" || { log_err "安装失败"; return 1; }
        log_success "acme.sh 安装成功。"
    fi
    export PATH="$HOME/.acme.sh:$PATH"
}

# =============================================================
# SECTION: 核心业务逻辑
# =============================================================

_apply_for_certificate() {
    log_info "--- 申请新证书 ---"
    local DOMAIN; DOMAIN=$(_prompt_user_input "请输入主域名: ")
    [ -z "$DOMAIN" ] && return

    # 1. 解析验证
    local SIP; SIP=$(curl -s https://api.ipify.org)
    local DIP; DIP=$(dig +short "$DOMAIN" A | head -n1)
    if [ "$DIP" != "$SIP" ]; then
        log_warn "IP不匹配 (本机:$SIP != 域名:$DIP)"
        confirm_action "强制继续?" || return
    fi

    # 2. 配置参数
    local USE_WILDCARD=""; confirm_action "申请泛域名 (*.$DOMAIN)?" && USE_WILDCARD="*.$DOMAIN"
    local INSTALL_PATH; INSTALL_PATH=$(_prompt_user_input "安装路径 [默认: /etc/ssl/$DOMAIN]: " "/etc/ssl/$DOMAIN")
    
    local svc=$(_detect_web_service)
    local def_reload="systemctl reload ${svc:-nginx}"
    local RELOAD_CMD; RELOAD_CMD=$(_prompt_user_input "重载命令 [默认: $def_reload]: " "$def_reload")

    # 3. 验证方式
    _render_menu "验证方式" "1. Standalone (80端口)" "2. Cloudflare API" "3. Aliyun API"
    local METHOD; local PRE_HOOK=""; local POST_HOOK=""
    case "$(_prompt_for_menu_choice "1-3")" in
        1)  METHOD="standalone"
            if run_with_sudo ss -tuln | grep -q ":80\s"; then
                log_err "80端口被占用。"
                return 1
            fi
            if confirm_action "自动停止/启动 Web 服务 ($svc)?"; then
                PRE_HOOK="systemctl stop $svc"; POST_HOOK="systemctl start $svc"
            fi ;;
        2)  METHOD="dns_cf"
            export CF_Token=$(_prompt_user_input "CF_Token: " "")
            export CF_Account_ID=$(_prompt_user_input "CF_Account_ID: " "") ;;
        3)  METHOD="dns_ali"
            export Ali_Key=$(_prompt_user_input "Ali_Key: " "")
            export Ali_Secret=$(_prompt_user_input "Ali_Secret: " "") ;;
        *) return ;;
    esac

    # 4. ZeroSSL 注册
    if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
        local m=$(_prompt_user_input "ZeroSSL 注册邮箱 (可选): " "")
        [ -n "$m" ] && "$ACME_BIN" --register-account -m "$m" --server zerossl
    fi

    # 5. 执行
    local ISSUE_CMD=("$ACME_BIN" --issue -d "$DOMAIN" --"$METHOD")
    [ -n "$USE_WILDCARD" ] && ISSUE_CMD+=(-d "$USE_WILDCARD")
    [ -n "$PRE_HOOK" ] && ISSUE_CMD+=(--pre-hook "$PRE_HOOK" --post-hook "$POST_HOOK")

    log_info "🚀 开始申请..."
    if ! "${ISSUE_CMD[@]}"; then
        log_err "申请失败，日志尾部:"
        tail -n 10 "$HOME/.acme.sh/acme.sh.log"
        return 1
    fi

    log_info "正在安装..."
    run_with_sudo mkdir -p "$INSTALL_PATH"
    "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$INSTALL_PATH/$DOMAIN.key" --fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
        --reloadcmd "$RELOAD_CMD"
    
    log_success "完成! 证书位于: $INSTALL_PATH"
}

_manage_certificates() {
    [ ! -f "$ACME_BIN" ] && return
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        
        # 获取列表
        local domains=()
        while read -r line; do
            [[ "$line" == Main_Domain* ]] && continue
            local d; d=$(echo "$line" | awk '{print $1}')
            [ -n "$d" ] && domains+=("$d")
        done < <("$ACME_BIN" --list)

        [ ${#domains[@]} -eq 0 ] && { log_warn "无证书。"; return; }

        # 渲染列表
        echo ""
        for ((i=0; i<${#domains[@]}; i++)); do
            local d="${domains[i]}"
            _get_cert_files "$d"
            
            local status="未知"; local days_info="N/A"; local date_str="N/A"
            local ca_str="未知"; local path="未知"; local next="自动/未知"; local clr="$NC"

            # 解析证书
            if [ -f "$CERT_FILE" ]; then
                local end=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
                local issuer=$(openssl x509 -issuer -noout -in "$CERT_FILE" 2>/dev/null)
                
                if [ -n "$end" ]; then
                    local left=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
                    date_str=$(date -d "$end" +%F)
                    if (( left < 0 )); then clr="$RED"; status="已过期"; 
                    elif (( left < 30 )); then clr="$YELLOW"; status="即将到期"; 
                    else clr="$GREEN"; status="有效"; fi
                    days_info="$left 天"
                else clr="$RED"; status="解析失败"; fi
                
                [[ "$issuer" == *"ZeroSSL"* ]] && ca_str="ZeroSSL"
                [[ "$issuer" == *"Let's Encrypt"* ]] && ca_str="Let's Encrypt"
                [[ "$issuer" == *"Google"* ]] && ca_str="Google"
            else clr="$RED"; status="文件丢失"; fi

            # 解析配置
            if [ -f "$CONF_FILE" ]; then
                local p; p=$(grep "^Le_RealFullChainPath=" "$CONF_FILE" | cut -d= -f2- | tr -d "'\"")
                [ -n "$p" ] && path=$(dirname "$p")
                local t; t=$(grep "^Le_NextRenewTime=" "$CONF_FILE" | cut -d= -f2- | tr -d "'\"")
                [ -n "$t" ] && next=$(date -d "@$t" +%F 2>/dev/null)
            fi

            printf "${GREEN}[ %d ] %s${NC}\n" "$((i+1))" "$d"
            printf "  ├─ 续 期 : %s\n" "$next"
            printf "  ├─ 机 构 : %s\n" "$ca_str"
            printf "  ├─ 路 径 : %s\n" "$path"
            printf "  └─ 证 书 : ${clr}%s (剩余 %s , %s 到期)${NC}\n" "$status" "$days_info" "$date_str"
            echo -e "${CYAN}····························································${NC}"
        done

        local idx=$(_prompt_user_input "输入序号管理 (Enter 返回): " "")
        [ -z "$idx" ] && return
        [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#domains[@]} )) && continue
        
        local SEL="${domains[$((idx-1))]}"
        _get_cert_files "$SEL"

        while true; do
            _render_menu "管理: $SEL" "1. 详情 (Details)" "2. 强制续期 (Force Renew)" "3. 删除 (Remove)" "0. 返回"
            case "$(_prompt_for_menu_choice "1-3/0")" in
                1)  if [ -f "$CERT_FILE" ]; then
                        openssl x509 -in "$CERT_FILE" -noout -text | grep -E "Issuer:|Not After|Subject:|DNS:"
                        log_info "文件: $CERT_FILE"
                    else log_err "文件不存在"; fi 
                    press_enter_to_continue ;;
                2)  log_info "准备续期..."
                    local conflict=""; local svc=$(_detect_web_service)
                    if run_with_sudo ss -tuln | grep -q ":80\s" && [ -n "$svc" ]; then
                        log_warn "端口80被 $svc 占用。"
                        confirm_action "临时停止 $svc 以续期?" && conflict="true"
                    fi
                    
                    [ "$conflict" ] && run_with_sudo systemctl stop "$svc"
                    
                    set +e
                    "$ACME_BIN" --renew -d "$SEL" --force --ecc
                    local res=$?
                    set -e
                    
                    if [ $res -eq 0 ]; then log_success "续期成功"; 
                    elif [ "$conflict" ]; then log_warn "acme.sh 报错(预期内Reload失败)，新证书已生成。"; 
                    else log_err "续期失败"; fi
                    
                    [ "$conflict" ] && { run_with_sudo systemctl start "$svc"; log_success "$svc 已恢复"; }
                    press_enter_to_continue ;;
                3)  confirm_action "确认删除?" && {
                        "$ACME_BIN" --remove -d "$SEL" --ecc || true
                        [ -d "/etc/ssl/$SEL" ] && run_with_sudo rm -rf "/etc/ssl/$SEL"
                        log_success "已删除"; break 2
                    } ;;
                0|*) break ;;
            esac
        done
    done
}

_system_maintenance() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        _render_menu "维护" "1. 诊断 Cron" "2. 升级 Core" "3. 开启自动更新" "4. 关闭自动更新" "0. 返回"
        case "$(_prompt_for_menu_choice "1-4/0")" in
            1)  systemctl is-active --quiet cron || systemctl is-active --quiet crond || log_warn "Cron 未运行"
                crontab -l 2>/dev/null | grep -q "acme.sh" || { log_warn "任务丢失"; confirm_action "修复?" && "$ACME_BIN" --install-cronjob; }
                press_enter_to_continue ;;
            2)  "$ACME_BIN" --upgrade; press_enter_to_continue ;;
            3)  "$ACME_BIN" --upgrade --auto-upgrade; press_enter_to_continue ;;
            4)  "$ACME_BIN" --upgrade --auto-upgrade 0; press_enter_to_continue ;;
            0|*) return ;;
        esac
    done
}

main() {
    trap 'echo -e "\n中断"; exit 1' INT
    [ "$(id -u)" -ne 0 ] && { log_err "需 root 权限"; exit 1; }
    log_info "SSL Manager ${SCRIPT_VERSION}"
    _check_dependencies || return 1
    
    while true; do
        [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ] && clear
        _render_menu "SSL 证书管理" "1. 申请证书" "2. 管理证书" "3. 系统维护"
        case "$(_prompt_for_menu_choice "1-3")" in
            1) _apply_for_certificate; press_enter_to_continue ;;
            2) _manage_certificates ;;
            3) _system_maintenance ;;
            *) exit 0 ;;
        esac
    done
}

main "$@"
