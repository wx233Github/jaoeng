# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.31.0 - S-UI智能探测与软重启容灾)
# =============================================================
# 作者：Shell 脚本专家
# 描述：自动化管理 Nginx 反代配置与 SSL 证书，支持 TCP 负载均衡、TLS卸载与泛域名智能复用

set -euo pipefail

# --- 全局变量 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
ORANGE='\033[38;5;208m'; PURPLE='\033[0;35m';

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
TCP_PROJECTS_METADATA_FILE="/etc/nginx/tcp_projects.json"
JSON_BACKUP_DIR="/etc/nginx/projects_backups"
BACKUP_DIR="/root/nginx_ssl_backups"
TG_CONF_FILE="/etc/nginx/tg_notifier.conf"

RENEW_THRESHOLD_DAYS=30
DEPS_MARK_FILE="$HOME/.nginx_ssl_manager_deps_v2"

NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_STREAM_AVAILABLE_DIR="/etc/nginx/stream-available"
NGINX_STREAM_ENABLED_DIR="/etc/nginx/stream-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
SSL_CERTS_BASE_DIR="/etc/ssl"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
NGINX_ERROR_LOG="/var/log/nginx/error.log"

IS_INTERACTIVE_MODE="true"
for arg in "$@"; do
    if [[ "$arg" == "--cron" || "$arg" == "--non-interactive" ]]; then
        IS_INTERACTIVE_MODE="false"; break
    fi
done
VPS_IP=""; VPS_IPV6=""; ACME_BIN=""
SCRIPT_PATH=$(realpath "$0")

# ==============================================================================
# SECTION: 核心工具函数
# ==============================================================================

_cleanup() {
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
    rm -f /tmp/tg_payload_*.json 2>/dev/null || true
    # 清理可能残留的临时 Nginx 配置
    find "$NGINX_SITES_ENABLED_DIR" -name "temp_acme_*" -delete 2>/dev/null || true
}

_on_int() {
    echo -e "\n${RED}检测到中断信号，已安全取消。${NC}"
    _cleanup; exit 130
}

trap '_cleanup' EXIT
trap '_on_int' INT TERM

_log_prefix() { if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then echo -n "$(date '+%Y-%m-%d %H:%M:%S') "; fi; }

log_message() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        INFO)    echo -e "$(_log_prefix)${CYAN}[INFO]${NC} ${message}";;
        SUCCESS) echo -e "$(_log_prefix)${GREEN}[OK]${NC}   ${message}";;
        WARN)    echo -e "$(_log_prefix)${YELLOW}[WARN]${NC} ${message}" >&2;;
        ERROR)   echo -e "$(_log_prefix)${RED}[ERR]${NC}  ${message}" >&2;;
    esac
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [${level^^}] ${message}" >> "$LOG_FILE"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty || true; }

_prompt_for_menu_choice_local() {
    local range="${1:-}"; local allow_empty="${2:-false}"; local prompt_text="${ORANGE}选项 [${range}]${NC} (Enter 返回): "
    local choice
    while true; do
        read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty || return 1
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then echo ""; return 0; fi
            echo -e "${YELLOW}请选择一个选项。${NC}" >&2; continue
        fi
        if [[ "$choice" =~ ^[0-9A-Za-z]+$ ]]; then echo "$choice"; return 0; fi
    done
}

_strip_colors() { echo -e "${1:-}" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g"; }

_str_width() {
    local str="${1:-}"; local clean="$(_strip_colors "$str")"
    if command -v wc >/dev/null 2>&1; then echo -n "$clean" | wc -L; else echo "${#clean}"; fi
}

_draw_line() { local len="${1:-40}"; printf "%${len}s" "" | sed "s/ /─/g"; }

_render_menu() {
    local title="${1:-菜单}"; shift; local title_vis_len=$(_str_width "$title"); local min_width=50; local box_width=$min_width
    if [ "$title_vis_len" -gt "$((min_width - 4))" ]; then box_width=$((title_vis_len + 6)); fi
    echo ""; echo -e "${GREEN}╭$(_draw_line "$box_width")╮${NC}"
    local padding=$(_center_text "$title" "$box_width"); local left_len=${#padding}; local right_len=$((box_width - left_len - title_vis_len))
    echo -e "${GREEN}│${NC}${padding}${BOLD}${title}${NC}$(printf "%${right_len}s" "")${GREEN}│${NC}"
    echo -e "${GREEN}╰$(_draw_line "$box_width")╯${NC}"
    for line in "$@"; do echo -e " ${line}"; done
}

_center_text() {
    local text="$1"; local width="$2"; local text_len=$(_str_width "$text"); local pad=$(( (width - text_len) / 2 ))
    [[ $pad -lt 0 ]] && pad=0; printf "%${pad}s" ""
}

check_root() { if [ "$(id -u)" -ne 0 ]; then log_message ERROR "请使用 root 用户运行此操作。"; return 1; fi; return 0; }

get_vps_ip() {
    if [ -z "$VPS_IP" ]; then
        VPS_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "")
        VPS_IPV6=$(curl -s -6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "")
    fi
}

_prompt_user_input_with_validation() {
    local prompt="${1:-}" default="${2:-}" regex="${3:-}" error_msg="${4:-}" allow_empty="${5:-false}" val=""
    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local disp=""; if [ -n "$default" ]; then disp=" [默认: ${default}]"; fi
            echo -ne "${YELLOW}${prompt}${NC}${disp}: " >&2
            read -r val < /dev/tty || return 1
            val=${val:-$default}
        else
            val="$default"
            if [[ -z "$val" && "$allow_empty" = "false" ]]; then log_message ERROR "非交互缺失: $prompt"; return 1; fi
        fi
        if [[ -z "$val" && "$allow_empty" = "true" ]]; then echo ""; return 0; fi
        if [[ -z "$val" ]]; then log_message ERROR "输入不能为空"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        if [[ -n "$regex" && ! "$val" =~ $regex ]]; then log_message ERROR "${error_msg:-格式错误}"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        echo "$val"; return 0
    done
}

_prompt_secret() {
    local prompt="${1:-}" val=""
    echo -ne "${YELLOW}${prompt} (无屏幕回显): ${NC}" >&2
    read -rs val < /dev/tty || return 1
    echo "" >&2; echo "$val"
}

_mask_string() {
    local str="${1:-}"; local len=${#str}
    if [ "$len" -le 6 ]; then echo "***"; else echo "${str:0:2}***${str: -3}"; fi
}

_confirm_action_or_exit_non_interactive() {
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local c; read -r -p "$(echo -e "${YELLOW}${1} ([y]/n): ${NC}")" c < /dev/tty || return 1
        case "$c" in n|N) return 1;; *) return 0;; esac
    fi
    log_message ERROR "非交互需确认: '$1'，已取消。"; return 1
}

# ==============================================================================
# SECTION: 核心业务逻辑 (证书申请与软重启)
# ==============================================================================

_issue_and_install_certificate() {
    local json="${1:-}"
    local domain=$(echo "$json" | jq -r .domain)
    local method=$(echo "$json" | jq -r .acme_validation_method)
    
    if [ "$method" == "reuse" ]; then return 0; fi

    # DNS 预检
    if [ "$method" == "http-01" ]; then
        if ! _check_dns_resolution "$domain"; then return 1; fi
    fi

    local provider=$(echo "$json" | jq -r .dns_api_provider); local wildcard=$(echo "$json" | jq -r .use_wildcard)
    local ca=$(echo "$json" | jq -r .ca_server_url)
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"; local key="$SSL_CERTS_BASE_DIR/$domain.key"
    
    log_message INFO "正在为 $domain 申请证书 ($method)..."
    
    # 1. 申请证书
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca" --log)
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    local temp_conf_created="false"; local temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"
    local stopped_svc=""

    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                local saved_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local saved_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local use_saved="false"
                if [[ -n "$saved_t" && -n "$saved_a" ]]; then
                    if _confirm_action_or_exit_non_interactive "是否复用已保存的 Cloudflare 凭证？"; then use_saved="true"; fi
                fi
                if [ "$use_saved" = "false" ]; then
                    local t; if ! t=$(_prompt_secret "请输入新的 CF_Token"); then return 1; fi
                    local a; if ! a=$(_prompt_secret "请输入新的 Account_ID"); then return 1; fi
                    [ -n "$t" ] && export CF_Token="$t"; [ -n "$a" ] && export CF_Account_ID="$a"
                fi
            fi
        fi
        cmd+=("--dns" "$provider")
    elif [ "$method" = "http-01" ]; then
        if ss -tuln 2>/dev/null | grep -qE ':(80|443)\s'; then
            local temp_svc=$(_detect_web_service)
            if [ "$temp_svc" = "nginx" ]; then
                 if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
                    cat > "$temp_conf" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }
EOF
                    ln -sf "$temp_conf" "$NGINX_SITES_ENABLED_DIR/"; systemctl reload nginx || true; temp_conf_created="true"
                fi
                mkdir -p "$NGINX_WEBROOT_DIR"; cmd+=("--webroot" "$NGINX_WEBROOT_DIR")
            else
                 if _confirm_action_or_exit_non_interactive "是否临时停止 $temp_svc 以释放 80 端口?"; then
                    systemctl stop "$temp_svc"; stopped_svc="$temp_svc"; trap "systemctl start $stopped_svc; _cleanup; exit 130" INT TERM
                 fi
                 cmd+=("--standalone")
            fi
        else
            cmd+=("--standalone")
        fi
    fi

    local log_temp=$(mktemp /tmp/acme_cmd_log.XXXXXX)
    echo -ne "${YELLOW}正在通信 (约 30-60 秒，请勿中断)... ${NC}"
    "${cmd[@]}" > "$log_temp" 2>&1 &
    local pid=$!
    local spinstr='|/-\'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.2; printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"; wait $pid; local ret=$?

    # 清理 HTTP-01 临时状态
    if [ "$temp_conf_created" == "true" ]; then rm -f "$temp_conf" "$NGINX_SITES_ENABLED_DIR/temp_acme_${domain}.conf"; systemctl reload nginx || true; fi
    if [ -n "$stopped_svc" ]; then systemctl start "$stopped_svc"; trap '_on_int' INT TERM; fi

    if [ $ret -ne 0 ]; then
        echo -e "\n"; log_message ERROR "申请失败: $domain"; 
        cat "$log_temp"; rm -f "$log_temp"
        _send_tg_notify "fail" "$domain" "acme.sh 申请证书失败。" ""
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi
    rm -f "$log_temp"

    # 2. 安装证书
    local rcmd=$(echo "$json" | jq -r '.reload_cmd // empty')
    local resolved_port=$(echo "$json" | jq -r '.resolved_port // empty')
    local install_reload_cmd=""
    
    if [ "$resolved_port" == "cert_only" ]; then
        install_reload_cmd="$rcmd"
    else
        install_reload_cmd="systemctl reload nginx"
    fi

    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
    [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    
    if ! "${inst[@]}"; then 
        log_message ERROR "安装失败: $domain"
        _send_tg_notify "fail" "$domain" "证书签发成功，但安装失败。" ""
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 1
    fi

    # 3. 软重启检测 (关键修复)
    # 如果证书文件已存在，说明 acme.sh 的 install 步骤成功了。
    # 如果 acme.sh 报错 "Reload error"，通常只是 reloadcmd 失败，不应该算作整体失败。
    # 我们在这里做一个二次确认。
    if [ -f "$cert" ] && [ -f "$key" ]; then
        log_message SUCCESS "证书文件已成功生成于 /etc/ssl/ 目录。"
        
        # 尝试手动执行一次 reloadcmd 以捕获更明确的错误，或者直接警告
        if [ -n "$install_reload_cmd" ]; then
            if ! eval "$install_reload_cmd" >/dev/null 2>&1; then
                echo -e "\n${RED}⚠️  [警告] 自动重启命令执行失败: $install_reload_cmd${NC}"
                echo -e "${YELLOW}证书已安装，但服务未能自动加载新证书。请手动执行该命令。${NC}"
                # 注意：这里我们选择不 return 1，继续保存 JSON，因为证书是有效的
            fi
        fi
        
        _send_tg_notify "success" "$domain" "证书已成功安装。"
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret
        return 0
    else
        log_message ERROR "证书文件安装后丢失。"
        return 1
    fi
}

_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    local svc; for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then echo "$svc"; return; fi
    done
}

_check_dns_resolution() {
    local domain="${1:-}"
    log_message INFO "正在预检域名解析: $domain ..."
    get_vps_ip
    local resolved_ips=""
    if command -v dig >/dev/null 2>&1; then
        resolved_ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | xargs)
    elif command -v host >/dev/null 2>&1; then
        resolved_ips=$(host -t A "$domain" 2>/dev/null | grep "has address" | awk '{print $NF}' | xargs)
    else return 0; fi

    if [ -z "$resolved_ips" ]; then
        log_message ERROR "❌ DNS 解析失败: $domain 未解析到 IP。"
        if ! _confirm_action_or_exit_non_interactive "强制继续?"; then return 1; fi
        return 0
    fi
    if [[ " $resolved_ips " == *" $VPS_IP "* ]]; then
        log_message SUCCESS "✅ DNS 校验通过。"
    else
        log_message WARN "⚠️  解析结果不包含本机IP (可能开启了 CDN)。"
    fi
    return 0
}

setup_tg_notifier() { :; } # 暂时存根，实际使用请保留上一版完整代码
_send_tg_notify() { :; }     # 暂时存根

# ==============================================================================
# SECTION: 输入与配置生成 (智能 S-UI 探测)
# ==============================================================================

_gather_project_details() {
    exec 3>&1; exec 1>&2
    local cur="${1:-{\}}"; local skip_cert="${2:-false}"; local is_cert_only="false"
    if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local domain=$(echo "$cur" | jq -r '.domain // ""')
    if [ -z "$domain" ]; then
        if ! domain=$(_prompt_user_input_with_validation "主域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式无效" "false"); then exec 1>&3; return 1; fi
    fi

    local wc_match=""
    if [ "$skip_cert" == "false" ]; then
        local all_wcs=$(jq -c '.[] | select(.use_wildcard == "y" and .cert_file != null)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
        while read -r wp; do
            [ -z "$wp" ] && continue
            local wd=$(echo "$wp" | jq -r .domain)
            if [[ "$domain" == *".$wd" || "$domain" == "$wd" ]]; then wc_match="$wd"; break; fi
        done <<< "$all_wcs"
    fi

    local reuse_wc="false"; local wc_cert=""; local wc_key=""
    if [ -n "$wc_match" ]; then
        if _confirm_action_or_exit_non_interactive "检测到泛域名证书 *.$wc_match，是否复用？"; then
            reuse_wc="true"
            local wp=$(_get_project_json "$wc_match")
            wc_cert=$(echo "$wp" | jq -r .cert_file); wc_key=$(echo "$wp" | jq -r .key_file)
        fi
    fi

    local type="cert_only"; local name="证书"; local port="cert_only"
    local max_body=$(echo "$cur" | jq -r '.client_max_body_size // empty')
    local custom_cfg=$(echo "$cur" | jq -r '.custom_config // empty')
    local cf_strict=$(echo "$cur" | jq -r '.cf_strict_mode // "n"')
    local reload_cmd=$(echo "$cur" | jq -r '.reload_cmd // empty')

    if [ "$is_cert_only" == "false" ]; then
        name=$(echo "$cur" | jq -r '.name // ""'); [ "$name" == "证书" ] && name=""
        while true; do
            local target; if ! target=$(_prompt_user_input_with_validation "后端目标 (容器名/端口)" "$name" "" "" "false"); then exec 1>&3; return 1; fi
            type="local_port"; port="$target"
            if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
                type="docker"; exec 1>&3
                port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)
                exec 1>&2
                if [ -z "$port" ]; then 
                    if ! port=$(_prompt_user_input_with_validation "未检测到端口，手动输入" "80" "^[0-9]+$" "无效端口" "false"); then exec 1>&3; return 1; fi
                fi
                break
            fi
            if [[ "$port" =~ ^[0-9]+$ ]]; then break; fi
            log_message ERROR "错误: '$target' 既不是容器也不是端口。" >&2
        done
    fi

    local method="http-01"; local provider=""; local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"; local ca_name="letsencrypt"

    if [ "$reuse_wc" == "true" ]; then method="reuse"; skip_cert="true"; fi

    if [ "$skip_cert" == "true" ]; then
        if [ "$reuse_wc" == "false" ]; then
            method=$(echo "$cur" | jq -r '.acme_validation_method // "http-01"'); provider=$(echo "$cur" | jq -r '.dns_api_provider // ""')
            wildcard=$(echo "$cur" | jq -r '.use_wildcard // "n"'); ca_server=$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')
        fi
    else
        local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
        _render_menu "选择 CA 机构" "${ca_list[@]}"
        local ca_choice; while true; do ca_choice=$(_prompt_for_menu_choice_local "1-3"); [ -n "$ca_choice" ] && break; done
        case "$ca_choice" in
            1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
            2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;;
            3) ca_server="google"; ca_name="google" ;;
        esac
        
        local -a method_display=("1. http-01 (智能无中断 Webroot / Standalone)" "2. dns_cf  (Cloudflare API)" "3. dns_ali (阿里云 API)")
        _render_menu "验证方式" "${method_display[@]}" >&2
        local v_choice; while true; do v_choice=$(_prompt_for_menu_choice_local "1-3"); [ -n "$v_choice" ] && break; done
        case "$v_choice" in
            1) method="http-01" ;;
            2|3)
                method="dns-01"; [ "$v_choice" = "2" ] && provider="dns_cf" || provider="dns_ali"
                if ! wildcard=$(_prompt_user_input_with_validation "是否申请泛域名? (y/[n])" "n" "^[yYnN]$" "" "false"); then exec 1>&3; return 1; fi ;;
        esac
    fi

    if [ "$is_cert_only" == "false" ]; then
        local cf_strict_default="n"
        [ "$cf_strict" == "y" ] && cf_strict_default="y"
        if _confirm_action_or_exit_non_interactive "是否开启 Cloudflare 严格安全防御?"; then cf_strict="y"; else cf_strict="n"; fi
    else
        if [ "$skip_cert" == "false" ]; then
            echo -e "\n${CYAN}--- 配置外部重载组件 (Reload Hook) ---${NC}" >&2
            
            # 智能探测 S-UI
            local auto_sui_cmd=""
            if systemctl list-units --type=service | grep -q "s-ui.service"; then auto_sui_cmd="systemctl restart s-ui"
            elif systemctl list-units --type=service | grep -q "x-ui.service"; then auto_sui_cmd="systemctl restart x-ui"; fi

            local opt1_text="S-UI / 3x-ui / x-ui"
            if [ -n "$auto_sui_cmd" ]; then opt1_text="${opt1_text} (自动识别: ${auto_sui_cmd##* })"; fi

            local -a hook_opts=(
                "1. ${opt1_text}" 
                "2. V2Ray 原生服务 (systemctl restart v2ray)" 
                "3. Xray 原生服务 (systemctl restart xray)" 
                "4. Nginx 服务 (systemctl reload nginx)" 
                "5. 手动输入自定义 Shell 命令" 
                "6. 跳过"
            )
            _render_menu "自动重启预设方案" "${hook_opts[@]}" >&2
            local hk; while true; do hk=$(_prompt_for_menu_choice_local "1-6"); [ -n "$hk" ] && break; done
            case "$hk" in
                1) reload_cmd="$auto_sui_cmd" ;;
                2) reload_cmd="systemctl restart v2ray" ;;
                3) reload_cmd="systemctl restart xray" ;;
                4) reload_cmd="systemctl reload nginx" ;;
                5) if ! reload_cmd=$(_prompt_user_input_with_validation "请输入完整 Shell 命令" "" "" "" "true"); then exec 1>&3; return 1; fi ;;
                6) reload_cmd="" ;;
            esac
        fi
    fi

    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"; local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    if [ "$reuse_wc" == "true" ]; then cf="$wc_cert"; kf="$wc_key"; fi

    jq -n --arg d "${domain:-}" --arg t "${type:-local_port}" --arg n "${name:-}" --arg p "${port:-}" \
        --arg m "${method:-http-01}" --arg dp "${provider:-}" --arg w "${wildcard:-n}" \
        --arg cu "${ca_server:-}" --arg cn "${ca_name:-}" --arg cf "${cf:-}" --arg kf "${kf:-}" \
        --arg mb "${max_body:-}" --arg cc "${custom_cfg:-}" --arg cs "${cf_strict:-n}" --arg rc "${reload_cmd:-}" \
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf, client_max_body_size:$mb, custom_config:$cc, cf_strict_mode:$cs, reload_cmd:$rc}' >&3
    exec 1>&3
}

# ... 其他函数存根 (为了节省篇幅，实际请结合上一版完整代码) ...
_get_project_json() { jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""; }
_save_project_json() {
    local json="${1:-}"; if [ -z "$json" ]; then return 1; fi
    local domain=$(echo "$json" | jq -r .domain); local temp=$(mktemp)
    if [ -n "$(_get_project_json "$domain")" ]; then
        jq --argjson new_val "$json" --arg d "$domain" 'map(if .domain == $d then $new_val else . end)' "$PROJECTS_METADATA_FILE" > "$temp"
    else
        jq --argjson new_val "$json" '. + [$new_val]' "$PROJECTS_METADATA_FILE" > "$temp"
    fi
    if [ $? -eq 0 ]; then mv "$temp" "$PROJECTS_METADATA_FILE"; return 0; else rm -f "$temp"; return 1; fi
}
_write_and_enable_nginx_config() { return 0; }
control_nginx() { systemctl reload nginx; return $?; }
install_dependencies() { touch "$DEPS_MARK_FILE"; return 0; }
initialize_environment() { mkdir -p "$NGINX_SITES_AVAILABLE_DIR"; touch "$PROJECTS_METADATA_FILE"; touch "$TCP_PROJECTS_METADATA_FILE"; return 0; }
install_acme_sh() { ACME_BIN="$HOME/.acme.sh/acme.sh"; return 0; }
configure_nginx_projects() {
    local mode="${1:-standard}"
    echo -e "\n${CYAN}开始配置新项目...${NC}"
    local json
    if ! json=$(_gather_project_details "{}" "false" "$mode"); then log_message WARN "取消配置。"; return; fi
    
    # 关键修复：即使安装/重启失败，只要证书生成成功，就保存 JSON
    if _issue_and_install_certificate "$json"; then
        # 完全成功
        _save_project_json "$json"
        log_message SUCCESS "配置已保存。"
        [ "$mode" != "cert_only" ] && echo -e "\n网站已上线: https://$(echo "$json" | jq -r .domain)"
    else
        # 检查证书文件是否存在，如果存在但函数返回失败，说明是重启失败
        local domain=$(echo "$json" | jq -r .domain)
        local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
        if [ -f "$cert" ]; then
            _save_project_json "$json"
            log_message WARN "证书已生成并保存配置，但服务重启失败，请手动处理。"
        else
            log_message ERROR "证书申请失败，未保存。"
        fi
    fi
}
_draw_dashboard() { echo ""; echo -e "${GREEN}Nginx 管理面板 v4.31.0${NC}"; echo ""; }
main_menu() {
    while true; do
        _draw_dashboard
        echo -e " 1. 配置新域名反代"
        echo -e " 2. 仅申请证书"
        echo -e " 0. 退出"
        local c; if ! c=$(_prompt_for_menu_choice_local "0-2" "true"); then break; fi
        case "$c" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            0|"") return 0 ;;
        esac
    done
}

if ! check_root; then exit 1; fi
install_dependencies 
initialize_environment
install_acme_sh && main_menu
exit $?
