#!/usr/bin/env bash
# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.6.1-完整防截断修正版)
# =============================================================
# 作者：系统运维组
# 版本历史：
#   v6.6.1 - 修复末尾被意外截断问题，确保可完全执行
#   v6.6.0 - 强制配置文件安全降级，实装网络预检
# =============================================================

SCRIPT_VERSION="v6.6.1"

set -euo pipefail
export LANG="${LANG:-en_US.UTF_8}"
export LC_ALL="${LC_ALL:-C.UTF_8}"

UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    log_err() { echo "[错误] $*" >&2; }
    log_info() { echo "[信息] $*"; }
    log_warn() { echo "[警告] $*"; }
    log_success() { echo "[成功] $*"; }
    check_network_connectivity() { return 0; }
    _render_menu() { local title="$1"; shift; echo "--- $title ---"; printf " %s\n" "$@"; }
    press_enter_to_continue() { read -r -p "按 Enter 继续..." < /dev/tty; }
    confirm_action() { local choice; read -r -p "$1 ([y]/n): " choice < /dev/tty; case "$choice" in n|N) return 1;; *) return 0;; esac; }
    _prompt_user_input() { local val; read -r -p "$1" val < /dev/tty; echo "${val:-$2}"; }
    _prompt_for_menu_choice() { local val; read -r -p "请选择 [${1}]: " val < /dev/tty; echo "$val"; }
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
fi

if ! declare -f run_with_sudo >/dev/null 2>&1; then
    run_with_sudo() { if [ "$(id -u)" -eq 0 ]; then "$@"; else if command -v sudo >/dev/null 2>&1; then sudo "$@"; else return 1; fi; fi; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/opt/vps_install_modules/configs"
CONFIG_FILE="${CONFIG_DIR}/watchtower.conf"
LEGACY_CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

ENV_FILE="${SCRIPT_DIR}/watchtower.env"
ENV_FILE_LAST_RUN="${SCRIPT_DIR}/watchtower.env.last_run"

TG_BOT_TOKEN=""
TG_CHAT_ID=""
EMAIL_TO=""
WATCHTOWER_EXCLUDE_LIST=""
WATCHTOWER_EXTRA_ARGS=""
WATCHTOWER_DEBUG_ENABLED=""
WATCHTOWER_CONFIG_INTERVAL=""
WATCHTOWER_ENABLED=""
WATCHTOWER_NOTIFY_ON_NO_UPDATES=""
WATCHTOWER_HOST_ALIAS=""
WATCHTOWER_RUN_MODE=""
WATCHTOWER_SCHEDULE_CRON=""
WATCHTOWER_TEMPLATE_STYLE=""

load_config(){
    if [ ! -f "$CONFIG_FILE" ] && [ -f "$LEGACY_CONFIG_FILE" ]; then
        log_warn "迁移旧版配置至系统安全目录..."
        run_with_sudo mkdir -p "$CONFIG_DIR"
        run_with_sudo cp -f "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
        run_with_sudo chown root:root "$CONFIG_FILE"
        run_with_sudo chmod 600 "$CONFIG_FILE"
        rm -f "$LEGACY_CONFIG_FILE" 2>/dev/null || true
    fi

    if [ -f "$CONFIG_FILE" ]; then
        if [ -r "$CONFIG_FILE" ]; then source "$CONFIG_FILE" >/dev/null 2>&1 || true
        else eval "$(run_with_sudo cat "$CONFIG_FILE" 2>/dev/null)" || true; fi
    fi

    local sys_hostname; sys_hostname=$(hostname | tr -d '\n')
    local default_alias; if [ ${#sys_hostname} -gt 15 ]; then default_alias="DockerNode"; else default_alias="$sys_hostname"; fi

    TG_BOT_TOKEN="${TG_BOT_TOKEN-${WATCHTOWER_CONF_BOT_TOKEN-}}"
    TG_CHAT_ID="${TG_CHAT_ID-${WATCHTOWER_CONF_CHAT_ID-}}"
    EMAIL_TO="${EMAIL_TO-${WATCHTOWER_CONF_EMAIL_TO-}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST-${WATCHTOWER_CONF_EXCLUDE_CONTAINERS-portainer,portainer_agent}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS-${WATCHTOWER_CONF_EXTRA_ARGS-}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-21600}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-true}"
    WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS:-$default_alias}"
    WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE:-interval}"
    WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON:-}"
    WATCHTOWER_TEMPLATE_STYLE="${WATCHTOWER_TEMPLATE_STYLE:-professional}"
}

load_config
if ! command -v docker >/dev/null 2>&1; then log_err "缺少 Docker。"; exit 10; fi

save_config(){
    local tmp_conf; tmp_conf=$(mktemp)
    cat > "$tmp_conf" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-}"
WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS:-}"
WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE:-}"
WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON:-}"
WATCHTOWER_TEMPLATE_STYLE="${WATCHTOWER_TEMPLATE_STYLE:-}"
EOF
    run_with_sudo mkdir -p "$CONFIG_DIR"
    run_with_sudo mv "$tmp_conf" "$CONFIG_FILE"
    run_with_sudo chown root:root "$CONFIG_FILE"
    run_with_sudo chmod 600 "$CONFIG_FILE"
}

_print_header() { echo -e "\n${BLUE}--- ${1} ---${NC}"; }
_format_seconds_to_human(){
    local s="$1"; if ! [[ "$s" =~ ^[0-9]+$ ]] || [ "$s" -le 0 ]; then echo "N/A"; return; fi
    local d=$((s/86400)) h=$(((s%86400)/3600)) m=$(((s%3600)/60)) sec=$((s%60)) r=""
    [ "$d" -gt 0 ] && r+="${d}天"; [ "$h" -gt 0 ] && r+="${h}小时"
    [ "$m" -gt 0 ] && r+="${m}分"; [ "$sec" -gt 0 ] && r+="${sec}秒"
    echo "${r:-0秒}"
}
_escape_markdown() { echo "$1" | sed 's/_/\\_/g; s/*/\\*/g; s/`/\\`/g; s/\[/\\[/g'; }

send_test_notify() {
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        if ! command -v jq >/dev/null 2>&1; then log_err "缺少 jq。"; return; fi
        check_network_connectivity "api.telegram.org" 5 || log_warn "TG API 无法连接。"
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data; data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$1" '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        timeout 10s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url"
    fi
}

_generate_env_file() {
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    alias_name=$(echo "$alias_name" | tr -d '\n\r')
    rm -f "$ENV_FILE"
    {
        echo "TZ=${JB_TIMEZONE:-Asia/Shanghai}"
        if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
            echo "WATCHTOWER_NOTIFICATIONS=shoutrrr"
            echo "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?parsemode=Markdown&preview=false&channels=${TG_CHAT_ID}"
            echo "WATCHTOWER_NOTIFICATION_REPORT=true"
            echo "WATCHTOWER_NOTIFICATION_TITLE=${alias_name}"
            echo "WATCHTOWER_NO_STARTUP_MESSAGE=true"
            local br='{{ "\n" }}' tpl=""
            if [ "${WATCHTOWER_TEMPLATE_STYLE:-professional}" = "friendly" ]; then
                tpl+="{{ if .Entries -}}*🎉 有容器更新了～*${br}${br}{{- range .Entries }}• {{ .Message }}${br}{{- end }}${br}高效运行中🚀${br}{{- else -}}*🌟 容器均最新*${br}{{- end -}}${br}—— \`${alias_name}\`"
            else
                tpl+="*🛡️ 更新报告*${br}*主机*: \`${alias_name}\`${br}{{ if .Entries -}}*📈 更新*${br}{{- range .Entries }}• {{ .Message }}${br}{{- end }}{{- else -}}*✨ 完美*${br}容器均为最新。${br}{{- end -}}"
            fi
            printf "WATCHTOWER_NOTIFICATION_TEMPLATE=%s\n" "$tpl"
        fi
        if [[ "${WATCHTOWER_RUN_MODE:-}" =~ ^(cron|aligned)$ ]] && [ -n "${WATCHTOWER_SCHEDULE_CRON:-}" ]; then
            echo "WATCHTOWER_SCHEDULE=$WATCHTOWER_SCHEDULE_CRON"
        fi
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
}

_start_watchtower_container_logic(){
    local wt_interval="$1" mode_description="$2" interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower" container_names=() run_hostname="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    _generate_env_file

    local docker_run_args=("-h" "${run_hostname}" "--env-file" "$ENV_FILE" "-v" "/var/run/docker.sock:/var/run/docker.sock")
    local wt_args=("--cleanup") run_container_name="watchtower"

    if [ "$interactive_mode" = "true" ]; then
        run_container_name="watchtower-once"
        docker_run_args+=("--rm" "--name" "$run_container_name"); wt_args+=("--run-once")
    else
        docker_run_args+=("-d" "--name" "$run_container_name" "--restart" "unless-stopped")
        if [[ ! "${WATCHTOWER_RUN_MODE:-}" =~ ^(cron|aligned)$ ]]; then wt_args+=("--interval" "${wt_interval:-300}"); fi
    fi
    if [ "${WATCHTOWER_DEBUG_ENABLED:-}" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "${WATCHTOWER_EXTRA_ARGS:-}" ]; then read -r -a extras <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extras[@]}"); fi
    
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST:-}"
    if [ -n "$final_exclude_list" ]; then
        local pattern; pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then log_err "监控范围为空，取消。"; return 1; fi
    fi

    if [ "$interactive_mode" = "false" ]; then 
        check_network_connectivity "registry-1.docker.io" 5 || log_warn "拉取受阻。"
        echo "⬇️ 拉取镜像..."
    fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1; set -e
    
    local cmd=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]:-}")
    if [ "$interactive_mode" = "true" ]; then
        log_info "手动扫描..."
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${cmd[@]}"
        log_success "扫描结束"
    else
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${cmd[@]}" >/dev/null; set -e
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "服务就绪"; cp -f "$ENV_FILE" "$ENV_FILE_LAST_RUN"
        else log_err "启动失败"; fi
    fi
}

_rebuild_watchtower() {
    log_info "重建服务..."
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower >/dev/null 2>&1; set -e
    if ! _start_watchtower_container_logic "${WATCHTOWER_CONFIG_INTERVAL:-}" "监控模式"; then
        WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
    local safe_alias=$(_escape_markdown "${WATCHTOWER_HOST_ALIAS:-DockerNode}") time_now=$(_escape_markdown "$(date "+%Y-%m-%d %H:%M:%S")")
    send_test_notify "🔔 *配置更新*\n节点: \`${safe_alias}\`\n时间: \`${time_now}\`\n服务已重启生效。"
}

_prompt_for_interval() {
    local def="$1" msg="$2" input curr="$(_format_seconds_to_human "$def")"
    while true; do
        input=$(_prompt_user_input "$msg (如: 1h, 30m, 当前: $curr): " "")
        if [ -z "$input" ]; then echo "$def"; return 0; fi
        local s=0
        if [[ "$input" =~ ^[0-9]+$ ]]; then s="$input"
        elif [[ "$input" =~ ^([0-9]+)s$ ]]; then s="${BASH_REMATCH[1]}"
        elif [[ "$input" =~ ^([0-9]+)m$ ]]; then s=$(( "${BASH_REMATCH[1]}" * 60 ))
        elif [[ "$input" =~ ^([0-9]+)h$ ]]; then s=$(( "${BASH_REMATCH[1]}" * 3600 ))
        else log_warn "格式错误"; continue; fi
        if [ "$s" -gt 0 ]; then echo "$s"; return 0; fi
    done
}

configure_exclusion_list() {
    declare -A ex; local IFS=,; for c in ${WATCHTOWER_EXCLUDE_LIST:-}; do c=$(echo "$c" | xargs); [ -n "$c" ] && ex["$c"]=1; done; unset IFS
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a all=(); while IFS= read -r line; do all+=("$line"); done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}')
        local -a items=(); local i=0
        while [ $i -lt ${#all[@]} ]; do 
            local c="${all[$i]}" m=" "; [ -n "${ex[$c]+_}" ] && m="✔"
            items+=("$((i + 1)). [${GREEN}${m}${NC}] $c"); i=$((i + 1))
        done
        items+=("")
        local d="无"; if [ ${#ex[@]} -gt 0 ]; then local keys=("${!ex[@]}"); local o="$IFS"; IFS=,; d="${keys[*]}"; IFS="$o"; fi
        items+=("${CYAN}当前忽略: ${d}${NC}")
        _render_menu "忽略更新名单" "${items[@]}"
        
        local choice; read -r -p "选择 (c 结束, 回车清空): " choice < /dev/tty
        case "$choice" in
            c|C) break ;;
            "") if [ ${#ex[@]} -gt 0 ]; then if confirm_action "清空?"; then ex=(); fi; fi; continue ;;
            *) local idx; IFS=',' read -r -a idx <<< "$(echo "$choice" | tr -d ' ')"
                for x in "${idx[@]}"; do
                    if [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le ${#all[@]} ]; then
                        local t="${all[$((x - 1))]}"; if [ -n "${ex[$t]+_}" ]; then unset ex["$t"]; else ex["$t"]=1; fi
                    fi
                done ;;
        esac
    done
    local res=""; if [ ${#ex[@]} -gt 0 ]; then local keys=("${!ex[@]}"); local o="$IFS"; IFS=,; res="${keys[*]}"; IFS="$o"; fi
    WATCHTOWER_EXCLUDE_LIST="$res"
}

_configure_schedule() {
    echo -e "${CYAN}运行模式:${NC}\n1. 间隔循环\n2. Cron (高级)"
    local choice; choice=$(_prompt_for_menu_choice "1-2")
    if [ "$choice" = "1" ]; then
        local h; h=$(_prompt_user_input "每几小时? (0=分钟): " "")
        if [ "${h:-0}" -gt 0 ]; then
            echo -e "1. 此时起\n2. 整点\n3. 半点"
            local a; a=$(_prompt_for_menu_choice "1-3")
            if [ "$a" = "1" ]; then WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$((h * 3600)); else
                WATCHTOWER_RUN_MODE="aligned"; local min="0"; [ "$a" = "3" ] && min="30"
                WATCHTOWER_SCHEDULE_CRON="0 $min */$h * * *"
            fi
        else
            WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$(_prompt_for_interval "300" "频率")
        fi
    elif [ "$choice" = "2" ]; then
        WATCHTOWER_RUN_MODE="cron"; read -r -p "Cron 表达式: " WATCHTOWER_SCHEDULE_CRON < /dev/tty
    fi
}

configure_watchtower(){
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null; then
        if ! confirm_action "已运行，将覆盖，继续?"; then return 10; fi
    fi
    _configure_schedule; sleep 0.5; configure_exclusion_list
    
    local ea; ea=$(_prompt_user_input "额外参数(y/N): " "")
    if echo "$ea" | grep -qE '^[Yy]$'; then read -r -p "新参数(空格清空): " ea < /dev/tty; [[ "$ea" =~ ^\ +$ ]] && ea=""; WATCHTOWER_EXTRA_ARGS="$ea"; fi
    
    local dbg; dbg=$(_prompt_user_input "启用 Debug(y/N): " "")
    if echo "$dbg" | grep -qE '^[Yy]$'; then WATCHTOWER_DEBUG_ENABLED="true"; else WATCHTOWER_DEBUG_ENABLED="false"; fi
    
    WATCHTOWER_ENABLED="true"
    save_config; _rebuild_watchtower || return 1; return 0
}

notification_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg="${RED}未配${NC}"; [ -n "${TG_BOT_TOKEN:-}" ] && tg="${GREEN}已配${NC}"
        _render_menu "通知配置" "1. Telegram ($tg)" "2. 别名 (${WATCHTOWER_HOST_ALIAS:-默认})" "3. 发测试通知" "4. 清空"
        local c; c=$(_prompt_for_menu_choice "1-4")
        case "$c" in
            1) read -r -p "Token: " TG_BOT_TOKEN < /dev/tty; read -r -p "ChatID: " TG_CHAT_ID < /dev/tty
               local st; st=$(_prompt_for_menu_choice "1.专业版 2.活泼版")
               [ "$st" = "2" ] && WATCHTOWER_TEMPLATE_STYLE="friendly" || WATCHTOWER_TEMPLATE_STYLE="professional"
               save_config; _rebuild_watchtower ;;
            2) read -r -p "别名: " a < /dev/tty; [ -n "$a" ] && WATCHTOWER_HOST_ALIAS="$a" && save_config && _rebuild_watchtower ;;
            3) send_test_notify "*🔔 测试* 成功。"; press_enter_to_continue ;;
            4) TG_BOT_TOKEN=""; TG_CHAT_ID=""; save_config; _rebuild_watchtower ;;
            "") return ;;
        esac
    done
}

manage_tasks(){
    _render_menu "运维" "1. 卸载" "2. 重建"
    local c; c=$(_prompt_for_menu_choice "1-2")
    if [ "$c" = "1" ]; then run_with_sudo docker rm -f watchtower >/dev/null 2>&1; WATCHTOWER_ENABLED="false"; save_config; log_success "已卸载"; press_enter_to_continue
    elif [ "$c" = "2" ]; then _rebuild_watchtower; press_enter_to_continue; fi
}

_parse_watchtower_timestamp_from_log_line() { echo "$1" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | cut -d'.' -f1 | sed 's/T/ /'; }
_extract_interval_from_cmd(){ echo "$1" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true; }
_extract_schedule_from_env(){ JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Env}}' 2>/dev/null | jq -r '.[] | select(startswith("WATCHTOWER_SCHEDULE=")) | split("=")[1]' | head -n1 || true; }
get_watchtower_inspect_summary(){ local c; c=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null); _extract_interval_from_cmd "$c"; }
get_watchtower_all_raw_logs(){ JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 200 watchtower 2>&1 || true; }

_get_watchtower_next_run_time(){
    local int="$1" logs="$2" env="$3"
    if [ -n "$env" ]; then echo -e "${CYAN}Cron: $env${NC}"; return; fi
    if [ -z "$logs" ] || [ -z "$int" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi
    local line; line=$(echo "$logs" | grep -E "Session done|Scheduling first run" | tail -n 1 || true)
    if [ -z "$line" ]; then echo -e "${YELLOW}待首扫...${NC}"; return; fi
    local curr; curr=$(date +%s); local ts; ts=$(_parse_watchtower_timestamp_from_log_line "$line")
    if [ -n "$ts" ]; then
        local last; last=$(date -d "$ts" "+%s" 2>/dev/null || gdate -d "$ts" "+%s" 2>/dev/null || echo "")
        if [ -n "$last" ]; then
            local nxt=$((last + int)); while [ "$nxt" -le "$curr" ]; do nxt=$((nxt + int)); done
            local r=$((nxt - curr)) h=$((r/3600)) m=$(((r%3600)/60)) s=$((r%60))
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" "$h" "$m" "$s" "$NC"; return
        fi
    fi
    echo -e "${YELLOW}计算中...${NC}"
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local int raw env CD
        set +e; int=$(get_watchtower_inspect_summary || true); raw=$(get_watchtower_all_raw_logs || true); env=$(_extract_schedule_from_env); set -e
        CD=$(_get_watchtower_next_run_time "${int}" "${raw}" "${env}")
        local -a arr=("⏳ 下次: ${CD}" "" "📜 日志摘要:")
        local tail; tail=$(echo "$raw" | tail -n 5); while IFS= read -r l; do arr+=("   ${l:0:75}"); done <<< "$tail"
        _render_menu "看板" "${arr[@]}"
        local p; read -r -p "$(echo -e "> ${ORANGE}[1]${NC}日志流 ${ORANGE}[2]${NC}容器 ${ORANGE}[3]${NC}扫描 (↩ 返回): ")" p < /dev/tty
        case "$p" in
            1) trap '' INT; run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'exit 10' INT; press_enter_to_continue ;;
            2) run_with_sudo docker ps -a --format "table {{.Names}}\t{{.Status}}"; press_enter_to_continue ;;
            3) _start_watchtower_container_logic "" "" true; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local st="${RED}未运行${NC}"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then st="${GREEN}已启动${NC}"; fi
        local nt="${CYAN}关闭${NC}"; [ -n "${TG_BOT_TOKEN:-}" ] && nt="${GREEN}TG${NC}"
        
        local -a m=( "状态: $st" "通知: $nt" "" "1. 部署/配置" "2. 通知设置" "3. 运维卸载" "4. 日志看板" )
        _render_menu "Watchtower 管理" "${m[@]}"
        local c; c=$(_prompt_for_menu_choice "1-4")
        case "$c" in
            1) set +e; configure_watchtower; local r=$?; set -e; [ "$r" -ne 10 ] && press_enter_to_continue ;;
            2) notification_menu ;;
            3) manage_tasks ;;
            4) show_watchtower_details ;;
            "") return 0 ;;
        esac
    done
}

main(){ 
    case "${1:-}" in --run-once) _start_watchtower_container_logic "" "" true; exit $? ;; esac
    trap 'echo -e "\n终止。"; exit 10' INT TERM
    main_menu
    exit 10
}

main "$@"

# EOF (确保解析不被截断)
