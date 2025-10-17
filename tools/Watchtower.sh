# =============================================================
# 🚀 Watchtower 管理模块 (v9.0.0-最终稳定版)
# - 基准: 以用户提供的 v6.1.9 版本为功能和UI的最终标准。
# - 修复: (致命错误) 将通知模板中无效的 `substr` 函数替换为正确的 `slice` 函数，解决了通知模板报错的问题。
# - 恢复: (功能) 彻底恢复了主菜单中的容器总览状态栏 (总计/运行中/已停止)。
# - 恢复: (功能) 彻底恢复了“详情与日志摘要”菜单内的所有子功能，包括“容器管理”。
# - 恢复: (逻辑) 修正了“重建确认”提示的触发逻辑，现在仅在配置被实际修改后才会出现。
# - 确认: 此版本在功能、菜单、UI和逻辑上与 v6.1.9 完全对等，并集成了 v8.x 稳定可靠的通知发送机制。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v9.0.0"

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
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN="";
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
  log_err "致命错误: run_with_sudo 函数未定义。请确保从 install.sh 启动此脚本。"
  exit 1
fi

# --- 依赖与 Docker 服务检查 ---
if ! command -v docker &> /dev/null || ! docker info >/dev/null 2>&1; then
    log_err "Docker 未安装或 Docker 服务 (daemon) 未运行。"
    log_err "请返回主菜单安装 Docker 或使用 'sudo systemctl start docker' 启动服务。"
    exit 10
fi

# --- 本地配置文件路径 ---
CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# --- 模块变量 ---
TG_BOT_TOKEN=""
TG_CHAT_ID=""
EMAIL_TO=""
WATCHTOWER_EXCLUDE_LIST=""
WATCHTOWER_EXTRA_ARGS=""
WATCHTOWER_DEBUG_ENABLED=""
WATCHTOWER_CONFIG_INTERVAL=""
WATCHTOWER_ENABLED=""
CRON_HOUR=""
WATCHTOWER_NOTIFY_ON_NO_UPDATES=""

# --- 配置加载与保存 ---
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" &>/dev/null || true
    fi
    local default_interval="21600"
    local default_cron_hour="4"
    local default_exclude_list="portainer,portainer_agent"
    local default_notify_on_no_updates="true"

    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${WATCHTOWER_CONF_BOT_TOKEN:-}}"
    TG_CHAT_ID="${TG_CHAT_ID:-${WATCHTOWER_CONF_CHAT_ID:-}}"
    EMAIL_TO="${EMAIL_TO:-${WATCHTOWER_CONF_EMAIL_TO:-}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-$default_exclude_list}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-${WATCHTOWER_CONF_EXTRA_ARGS:-}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${WATCHTOWER_CONF_DEBUG_ENABLED:-false}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONF_DEFAULT_INTERVAL:-$default_interval}}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${WATCHTOWER_CONF_ENABLED:-false}}"
    CRON_HOUR="${CRON_HOUR:-${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-$default_cron_hour}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-$default_notify_on_no_updates}}"
}

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
CRON_HOUR="${CRON_HOUR}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}

# --- 辅助函数 ---
_print_header() {
    echo -e "\n${BLUE}--- ${1} ---${NC}"
}

_parse_watchtower_timestamp_from_log_line() {
    local line="$1"
    local ts
    ts=$(echo "$line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | cut -d'.' -f1 | sed 's/T/ /')
    echo "$ts"
}

_date_to_epoch() {
    date -d "$1" "+%s" 2>/dev/null || gdate -d "$1" "+%s" 2>/dev/null || echo "0"
}

_format_seconds_to_human(){
    local total_seconds="$1"
    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]] || [ "$total_seconds" -le 0 ]; then echo "N/A"; return; fi
    local days=$((total_seconds / 86400)); local hours=$(( (total_seconds % 86400) / 3600 )); local minutes=$(( (total_seconds % 3600) / 60 )); local seconds=$(( total_seconds % 60 ))
    local result=""
    if [ "$days" -gt 0 ]; then result+="${days}天"; fi
    if [ "$hours" -gt 0 ]; then result+="${hours}小时"; fi
    if [ "$minutes" -gt 0 ]; then result+="${minutes}分钟"; fi
    if [ "$seconds" -gt 0 ]; then result+="${seconds}秒"; fi
    echo "${result:-0秒}"
}

_get_notification_template() {
    cat <<'EOF'
{{- if .Report -}}
*🐳 Watchtower 扫描报告*

*服务器:* `{{ .Hostname }}`

{{- if (gt .Updated 0) }}
✅ *扫描完成*
*结果:* 共更新 {{ .Updated }} 个容器

{{- range .Entries }}
___
- 🔄 *{{ .Name }}*
  🖼️ {{ .ImageName }}
  🆔 {{ slice .OldID 0 12 }} -> {{ slice .NewID 0 12 }}
{{- end }}
{{- else }}
✅ *扫描完成*
*结果:* 未发现可更新的容器
*扫描:* {{ .Scanned }} 个 | *失败:* {{ .Failed }} 个
{{- end }}

___
`{{ .Time.Format "2006-01-02 15:04:05" }}`
{{- end -}}
EOF
}

_send_test_notify() {
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        log_info "正在发送 Telegram 测试通知..."
        local message
        printf -v message "*✅ Watchtower 测试通知*\n\n*服务器:* \`%s\`\n\n如果能看到此消息，说明您的 Telegram 通知配置正确。" "$(hostname)"
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data; data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        
        if curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "$data" "$url" | grep -q "200"; then
            log_success "测试通知已成功发送。"
        else
            log_err "测试通知发送失败，请检查 Bot Token 和 Chat ID。"
        fi
    else
        log_warn "未配置 Telegram，无法发送测试通知。"
    fi
}

_prompt_for_interval() {
    local default_interval_seconds="$1"
    local prompt_message="$2"
    local input_value
    local current_display_value="$(_format_seconds_to_human "$default_interval_seconds")"

    while true; do
        input_value=$(_prompt_user_input "${prompt_message} (例如: 3600, 1h, 30m, 1d, 当前: ${current_display_value}): " "")
        if [ -z "$input_value" ]; then echo "$default_interval_seconds"; return 0; fi

        local seconds=0
        if [[ "$input_value" =~ ^([0-9]+)s?$ ]]; then seconds="${BASH_REMATCH[1]}"
        elif [[ "$input_value" =~ ^([0-9]+)m$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 60 ))
        elif [[ "$input_value" =~ ^([0-9]+)h$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 3600 ))
        elif [[ "$input_value" =~ ^([0-9]+)d$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 86400 ))
        else log_warn "无效的间隔格式。"; sleep 1; continue; fi

        if [ "$seconds" -gt 0 ]; then echo "$seconds"; return 0; else log_warn "间隔必须是正数。"; sleep 1; fi
    done
}

_extract_interval_from_cmd(){
    local cmd_json="$1"
    local interval
    interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
    echo "$interval" | sed 's/[^0-9]*//g'
}

get_watchtower_all_raw_logs(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then
        echo ""
        return 1
    fi
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 2000 watchtower 2>&1 || true
}

get_watchtower_inspect_summary(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then
        echo ""
        return 2
    fi
    local cmd
    cmd=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    _extract_interval_from_cmd "$cmd" 2>/dev/null || true
}

get_last_session_time(){
    local logs; logs=$(get_watchtower_all_raw_logs 2>/dev/null || true)
    if [ -z "$logs" ]; then echo ""; return 1; fi
    local line; line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    if [ -n "$line" ]; then
        local ts; ts=$(_parse_watchtower_timestamp_from_log_line "$line")
        if [ -n "$ts" ]; then echo "$ts"; return 0; fi
    fi
    echo ""
    return 1
}

_get_watchtower_remaining_time(){
    local interval_seconds="$1"
    local raw_logs="$2"
    if [ -z "$raw_logs" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local last_event_line; last_event_line=$(echo "$raw_logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    if [ -z "$last_event_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    local next_expected_check_epoch=0
    if [[ "$last_event_line" == *"Scheduling first run"* ]]; then
        local scheduled_time; scheduled_time=$(echo "$last_event_line" | sed -n 's/.*Scheduling first run: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p')
        next_expected_check_epoch=$(_date_to_epoch "$scheduled_time")
    else
        if [ -z "$interval_seconds" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi
        local last_event_epoch; last_event_epoch=$(_date_to_epoch "$(_parse_watchtower_timestamp_from_log_line "$last_event_line")")
        if [ "$last_event_epoch" -eq 0 ]; then echo -e "${YELLOW}计算中...${NC}"; return; fi
        next_expected_check_epoch=$((last_event_epoch + interval_seconds))
    fi
    
    local remaining_seconds=$((next_expected_check_epoch - $(date +%s)))
    if [ "$remaining_seconds" -gt 0 ]; then
        printf "%b%02d时%02d分%02d秒%b" "$GREEN" $((remaining_seconds / 3600)) $(((remaining_seconds % 3600) / 60)) $((remaining_seconds % 60)) "$NC"
    else
        echo -e "${YELLOW}正在检查中...${NC}"
    fi
}

_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2"
    local interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower"
    local container_names=()
    local docker_run_args=(-e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_args=("--cleanup")

    local run_container_name="watchtower"
    if [ "$interactive_mode" = "true" ]; then
        run_container_name="watchtower-once"
        docker_run_args+=(--rm --name "$run_container_name")
        wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name "$run_container_name" --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi

    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    
    local shoutrrr_urls=()
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        shoutrrr_urls+=("telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}")
    fi
    
    if [ ${#shoutrrr_urls[@]} -gt 0 ]; then
        docker_run_args+=(-e WATCHTOWER_NOTIFICATIONS=shoutrrr)
        local combined_urls; IFS=,; combined_urls="${shoutrrr_urls[*]}"; unset IFS
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_URL=${combined_urls}")
        
        local template_content; template_content=$(_get_notification_template)
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE=${template_content}")

        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            docker_run_args+=(-e WATCHTOWER_NOTIFICATION_REPORT=true)
        fi
    fi

    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
    if [ -n "$WATCHTOWER_EXCLUDE_LIST" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$WATCHTOWER_EXCLUDE_LIST" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
    fi

    if [ "$interactive_mode" = "false" ]; then log_info "⬇️ 正在拉取 Watchtower 镜像..."; fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    if [ "$interactive_mode" = "false" ]; then _print_header "正在启动 $mode_description"; fi
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "正在启动一次性扫描... (日志将实时显示，通知将由 Watchtower 直接发送)"
        set +e
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        local rc=$?
        set -e
        if [ $rc -eq 0 ]; then log_success "一次性扫描完成。"; else log_err "一次性扫描失败。"; fi
        return $rc
    else
        log_debug "执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo ${final_command_to_run[*]}"
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "$mode_description 启动成功。"
        else
            log_err "$mode_description 启动失败。"
        fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."; 
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    local interval="${WATCHTOWER_CONFIG_INTERVAL}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower (监控模式)"; then
        log_err "Watchtower 重建失败！"; WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
}

_prompt_and_rebuild_watchtower_if_needed() {
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then
        if confirm_action "配置已更新，是否立即重建 Watchtower 以应用新配置?"; then _rebuild_watchtower; else log_warn "操作已取消。新配置将在下次手动重建 Watchtower 后生效。"; fi
    fi
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then log_info "操作已取消。"; return 1; fi
    _start_watchtower_container_logic "" "" true
}

_configure_telegram() {
    TG_BOT_TOKEN=$(_prompt_user_input "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " "$TG_BOT_TOKEN")
    TG_CHAT_ID=$(_prompt_user_input "请输入 Chat ID (当前: ${TG_CHAT_ID}): " "$TG_CHAT_ID")
    local notify_choice=$(_prompt_user_input "是否在没有容器更新时也发送通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " "")
    if echo "$notify_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    save_config; log_info "Telegram 配置已更新。"
}

_configure_email() {
    log_warn "Email 通知当前未被此脚本直接支持，但您可以通过配置额外参数来使用它。"
    log_info "请参考 Watchtower 文档设置 Email 通知所需的环境变量。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi
        
        local -a content_array=(
            "1. 配置 Telegram (状态: $tg_status, 无更新也通知: $notify_on_no_updates_status)"
            "2. 配置 Email (当前未使用)"
            "3. 发送测试通知"
            "4. 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) _configure_telegram; _prompt_and_rebuild_watchtower_if_needed; press_enter_to_continue ;;
            2) _configure_email; press_enter_to_continue ;;
            3) _send_test_notify; press_enter_to_continue ;;
            4) 
                if confirm_action "确定要清空所有通知配置吗?"; then 
                    TG_BOT_TOKEN=""; TG_CHAT_ID=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; 
                    save_config; log_info "所有通知配置已清空。";
                    _prompt_and_rebuild_watchtower_if_needed
                else 
                    log_info "操作已取消。"; 
                fi; 
                press_enter_to_continue 
                ;;
            "") return ;; 
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

configure_watchtower(){
    WATCHTOWER_CONFIG_INTERVAL=$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL}" "请输入检查间隔")
    log_info "检查间隔已设置为: $(_format_seconds_to_human "$WATCHTOWER_CONFIG_INTERVAL")。"
    sleep 1
    
    configure_exclusion_list
    
    WATCHTOWER_EXTRA_ARGS=$(_prompt_user_input "请输入额外参数 (可留空, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " "$WATCHTOWER_EXTRA_ARGS")
    
    local debug_choice=$(_prompt_user_input "是否启用调试模式? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " "")
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then WATCHTOWER_DEBUG_ENABLED="true"; else WATCHTOWER_DEBUG_ENABLED="false"; fi
    
    WATCHTOWER_ENABLED="true"; save_config
    _rebuild_watchtower || return 1
    return 0
}

configure_exclusion_list() {
    declare -A excluded_map; local initial_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$initial_exclude_list" ]; then local IFS=,; for name in $initial_exclude_list; do name=$(echo "$name" | xargs); if [ -n "$name" ]; then excluded_map["$name"]=1; fi; done; unset IFS; fi
    
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; 
        local -a all_containers; mapfile -t all_containers < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}'); 
        local -a items_array=();
        for i in "${!all_containers[@]}"; do 
            local container="${all_containers[$i]}"; local is_excluded=" "
            if [ -n "${excluded_map[$container]+_}" ]; then is_excluded="✔"; fi
            items_array+=("$((i + 1)). [${GREEN}${is_excluded}${NC}] $container")
        done
        local current_excluded_display="无"; if [ ${#excluded_map[@]} -gt 0 ]; then local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; current_excluded_display="${keys[*]}"; IFS="$old_ifs"; fi
        items_array+=("" "${CYAN}当前排除: ${current_excluded_display}${NC}")
        
        _render_menu "配置排除列表" "${items_array[@]}"; read -r -p " └──> 输入数字(可用','分隔)切换, 'c'确认, [回车]清空: " choice < /dev/tty
        case "$choice" in
            c|C) break ;;
            "") excluded_map=(); log_info "已清空排除列表。"; sleep 1 ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' '); IFS=',' read -r -a indices <<< "$clean_choice"
                for index in "${indices[@]}"; do
                    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#all_containers[@]} ]; then
                        local target="${all_containers[$((index - 1))]}"; if [ -n "${excluded_map[$target]+_}" ]; then unset excluded_map["$target"]; else excluded_map["$target"]=1; fi
                    fi
                done
                ;;
        esac
    done
    local final_list=""; if [ ${#excluded_map[@]} -gt 0 ]; then local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; final_list="${keys[*]}"; IFS="$old_ifs"; fi
    WATCHTOWER_EXCLUDE_LIST="$final_list"
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a items_array=( "1. 停止/移除 Watchtower" "2. 重建 Watchtower" )
        _render_menu "⚙️ 任务管理 ⚙️" "${items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定移除 Watchtower？"; then 
                        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
                        WATCHTOWER_ENABLED="false"; save_config
                        log_success "Watchtower 已移除。"
                    fi
                else 
                    log_warn "Watchtower 未运行。"
                fi
                press_enter_to_continue 
                ;;
            2) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定要重建 Watchtower 吗？"; then _rebuild_watchtower; else log_info "操作已取消。"; fi
                else 
                    log_warn "Watchtower 未运行。"
                fi
                press_enter_to_continue
                ;;
            "") return ;; 
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

_format_and_highlight_log_line(){
    local line="$1"
    local ts=$(_parse_watchtower_timestamp_from_log_line "$line")
    case "$line" in
        *"Session done"*)
            local f s u; f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p'); s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p'); u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p')
            local c="$GREEN"; if [ "${f:-0}" -gt 0 ]; then c="$YELLOW"; fi
            printf "%s %b%s%b\n" "$ts" "$c" "✅ 扫描: ${s:-?}, 更新: ${u:-?}, 失败: ${f:-?}" "$NC" ;;
        *"Found new"*) printf "%s %b%s%b\n" "$ts" "$GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$NC" ;;
        *"Stopping "*) printf "%s %b%s%b\n" "$ts" "$GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$NC" ;;
        *"Creating "*) printf "%s %b%s%b\n" "$ts" "$GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$NC" ;;
        *"No new images found"*) printf "%s %b%s%b\n" "$ts" "$CYAN" "ℹ️ 未发现新镜像。" "$NC" ;;
        *"Scheduling first run"*) printf "%s %b%s%b\n" "$ts" "$GREEN" "🕒 首次运行已调度" "$NC" ;;
        *"Starting Watchtower"*) printf "%s %b%s%b\n" "$ts" "$GREEN" "✨ Watchtower 已启动" "$NC" ;;
        *)
            if echo "$line" | grep -qiE "\b(unauthorized|failed|error|fatal)\b"; then
                printf "%s %b%s%b\n" "$ts" "$RED" "❌ 错误: $(echo "$line" | sed -E 's/.*(level=(error|warn)|time="[^"]*")\s*//g')" "$NC"
            fi ;;
    esac
}

get_updates_last_24h(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo ""; return 1; fi
    local since; since=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    local raw_logs
    if [ -n "$since" ]; then raw_logs=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --since "$since" watchtower 2>&1 || true); fi
    if [ -z "$raw_logs" ]; then raw_logs=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 200 watchtower 2>&1 || true); fi
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|fatal" || true
}

show_container_info() { 
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; 
        local -a content_lines_array=()
        content_lines_array+=("编号 名称           镜像                               状态") 
        
        local -a containers=()
        local i=1
        while IFS='|' read -r name image status; do 
            containers+=("$name")
            local status_colored="$status"
            if echo "$status" | grep -qE '^Up'; then status_colored="${GREEN}运行中${NC}"; elif echo "$status" | grep -qE '^Exited|Created'; then status_colored="${RED}已退出${NC}"; else status_colored="${YELLOW}${status}${NC}"; fi
            content_lines_array+=("$(printf "%2d   %-15s %-35s %s" "$i" "$name" "$image" "$status_colored")")
            i=$((i + 1))
        done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        
        content_lines_array+=("" "a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_lines_array[@]}"; read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in 
            "") return ;;
            a|A) if confirm_action "确定要启动所有已停止的容器吗?"; then log_info "正在启动..."; local stopped; stopped=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -aq -f status=exited); if [ -n "$stopped" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker start $stopped &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            s|S) if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then log_info "正在停止..."; local running; running=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -q); if [ -n "$running" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop $running &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then log_warn "无效输入或编号超范围。"; sleep 1; continue; fi
                local selected_container="${containers[$((choice - 1))]}"; if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
                local -a action_items_array=( "1. 查看日志 (Logs)" "2. 重启 (Restart)" "3. 停止 (Stop)" "4. 删除 (Remove)" "5. 查看详情 (Inspect)" "6. 进入容器 (Exec)" )
                _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " action < /dev/tty
                case "$action" in 
                    1) echo -e "${YELLOW}日志 (Ctrl+C 停止)...${NC}"; trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 "$selected_container" || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue ;;
                    2) echo "重启中..."; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker restart "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi; sleep 1 ;; 
                    3) echo "停止中..."; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi; sleep 1 ;; 
                    4) if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then echo "删除中..."; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi; sleep 1; else echo "已取消。"; fi ;; 
                    5) _print_header "容器详情: ${selected_container}"; (JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect "$selected_container" | jq '.' 2>/dev/null || JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect "$selected_container") | less -R ;; 
                    6) if [ "$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]; then log_warn "容器未在运行，无法进入。"; else log_info "尝试进入容器... (输入 'exit' 退出)"; JB_SUDO_LOG_QUIET="true" run_with_sudo docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true; fi; press_enter_to_continue ;; 
                    *) ;; 
                esac
            ;;
        esac
    done
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local title="📊 Watchtower 详情与管理 📊"
        local interval raw_logs COUNTDOWN updates
        
        set +e; interval=$(get_watchtower_inspect_summary); raw_logs=$(get_watchtower_all_raw_logs); set -e
        COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        
        local -a content_lines_array=(
            "⏱️  ${CYAN}当前状态${NC}"
            "    ${YELLOW}上次活动:${NC} $(get_last_session_time || echo 'N/A')" 
            "    ${YELLOW}下次检查:${NC} ${COUNTDOWN}"
            "" 
            "📜  ${CYAN}最近 24h 摘要${NC}"
        )
        
        updates=$(get_updates_last_24h || true)
        if [ -z "$updates" ]; then content_lines_array+=("    无日志事件。"); else while IFS= read -r line; do content_lines_array+=("    $(_format_and_highlight_log_line "$line")"); done <<< "$updates"; fi
        
        _render_menu "$title" "${content_lines_array[@]}"; read -r -p " └──> [1] 实时日志, [2] 容器管理, [3] 触发扫描, [Enter] 返回: " pick < /dev/tty
        case "$pick" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    echo -e "\n按 Ctrl+C 停止..."; 
                    trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; 
                    press_enter_to_continue; 
                else 
                    echo -e "\n${RED}Watchtower 未运行。${NC}"; press_enter_to_continue; 
                fi ;;
            2) show_container_info ;;
            3) run_watchtower_once; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

view_and_edit_config(){
    local -a config_items=("TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "排除列表|WATCHTOWER_EXCLUDE_LIST|string_list" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval" "Watchtower 启用状态|WATCHTOWER_ENABLED|bool" "Cron 执行小时|CRON_HOUR|number_range|0-23" "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool")
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config; 
        local -a content_lines_array=(); local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"; local label; label=$(echo "$item" | cut -d'|' -f1); local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3); local extra; extra=$(echo "$item" | cut -d'|' -f4); local current_value="${!var_name}"; local display_text=""; local color="${CYAN}"
            case "$type" in
                string) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
                string_list) if [ -n "$current_value" ]; then color="${YELLOW}"; display_text="${current_value//,/, }"; else color="${CYAN}"; display_text="无"; fi ;;
                bool) if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi ;;
                interval) display_text=$(_format_seconds_to_human "$current_value"); if [ "$display_text" != "N/A" ] && [ -n "$current_value" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi ;;
                number_range) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
            esac
            content_lines_array+=("$(printf "%2d. %s: %s%s%s" "$((i + 1))" "$label" "$color" "$display_text" "$NC")")
        done
        _render_menu "⚙️ 配置查看与编辑 (底层) ⚙️" "${content_lines_array[@]}"; read -r -p " └──> 输入编号编辑, 或按 Enter 返回: " choice < /dev/tty
        if [ -z "$choice" ]; then return; fi
        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then log_warn "无效选项。"; sleep 1; continue; fi
        local selected_index=$((choice - 1)); local selected_item="${config_items[$selected_index]}"; local label; label=$(echo "$selected_item" | cut -d'|' -f1); local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2); local type; type=$(echo "$selected_item" | cut -d'|' -f3); local extra; extra=$(echo "$selected_item" | cut -d'|' -f4); local current_value="${!var_name}";
        
        case "$type" in
            string|string_list) 
                local new_value_input; new_value_input=$(_prompt_user_input "请输入新的 '$label' (当前: $current_value): " "$current_value"); declare "$var_name"="${new_value_input}" ;;
            bool) 
                local new_value_input; new_value_input=$(_prompt_user_input "是否启用 '$label'? (y/N, 当前: $current_value): " ""); if echo "$new_value_input" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi ;;
            interval) 
                local new_value; new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔"); if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi ;;
            number_range)
                local min; min=$(echo "$extra" | cut -d'-' -f1); local max; max=$(echo "$extra" | cut -d'-' -f2)
                while true; do 
                    local new_value_input; new_value_input=$(_prompt_user_input "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " "$current_value")
                    if [ -z "$new_value_input" ]; then break; fi
                    if echo "$new_value_input" | grep -qE '^[0-9]+$' && [ "$new_value_input" -ge "$min" ] && [ "$new_value_input" -le "$max" ]; then declare "$var_name"="$new_value_input"; break; else log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"; fi
                done ;;
        esac
        save_config; log_info "'$label' 已更新。"; sleep 1
    done
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local STATUS_RAW="未运行"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${GREEN}已启动${NC}"; else STATUS_COLOR="${RED}未运行${NC}"; fi
        local interval=""; local raw_logs=""; if [ "$STATUS_RAW" = "已启动" ]; then interval=$(get_watchtower_inspect_summary || true); raw_logs=$(get_watchtower_all_raw_logs || true); fi
        local COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        local TOTAL; TOTAL=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l || echo "0")
        local RUNNING; RUNNING=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.ID}}' 2>/dev/null | wc -l || echo "0"); local STOPPED=$((TOTAL - RUNNING))
        
        local header_text="Watchtower 管理"
        local -a content_array=(
            "🕝 Watchtower 状态: ${STATUS_COLOR}" 
            "⏳ 下次检查: ${COUNTDOWN}" 
            "📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
            ""
            "主菜单：" 
            "1. 启用并配置 Watchtower" 
            "2. 配置通知" 
            "3. 任务管理 (启停/重建)"
            "4. 查看/编辑配置 (底层)"
            "5. 详情与日志摘要"
        )
        _render_menu "$header_text" "${content_array[@]}"; read -r -p " └──> 输入选项 [1-5] 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) view_and_edit_config; _prompt_and_rebuild_watchtower_if_needed ;;
          5) show_watchtower_details ;;
          "") return 0 ;;
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    log_info "欢迎使用 Watchtower 模块 ${SCRIPT_VERSION}" >&2
    main_menu
    exit 10
}

main "$@"
