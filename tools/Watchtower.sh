#!/bin/bash
# =============================================================
# 🚀 Watchtower 管理模块 (v6.0.0-最终架构)
# - 新增: 引入了全新的 `--monitor` 后台日志监控模式，该模式将彻底接管所有通知功能。
# - 统一: 无论是自动扫描还是手动扫描，都由后台监控进程捕获日志、解析结果并发送精美的自定义通知。
# - 移除: 所有 Watchtower 原生的通知参数，不再依赖其内置的、存在兼容性问题的通知功能。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.0.0"

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

# --- 依赖检查 ---
if ! command -v docker &> /dev/null; then
    log_err "Docker 未安装。此模块需要 Docker 才能运行。"
    log_err "请返回主菜单，先使用 Docker 模块进行安装。"
    exit 10
fi

# --- Docker 服务 (daemon) 状态检查 ---
if ! docker info >/dev/null 2>&1; then
    log_err "无法连接到 Docker 服务 (daemon)。"
    log_err "请确保 Docker 正在运行，您可以使用以下命令尝试启动它："
    log_info "  sudo systemctl start docker"
    log_info "  或者"
    log_info "  sudo service docker start"
    exit 10
fi

# 本地配置文件路径
CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# --- 模块变量 ---
TG_BOT_TOKEN=""
TG_CHAT_ID=""
WATCHTOWER_EXCLUDE_LIST=""
WATCHTOWER_EXTRA_ARGS=""
WATCHTOWER_DEBUG_ENABLED=""
WATCHTOWER_CONFIG_INTERVAL=""
WATCHTOWER_ENABLED=""
WATCHTOWER_NOTIFY_ON_NO_UPDATES=""

# --- 配置加载与保存 ---
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" &>/dev/null || true
    fi
    local default_interval="21600"
    local default_exclude_list="portainer,portainer_agent"
    local default_notify_on_no_updates="true"

    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${WATCHTOWER_CONF_BOT_TOKEN:-}}"
    TG_CHAT_ID="${TG_CHAT_ID:-${WATCHTOWER_CONF_CHAT_ID:-}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-$default_exclude_list}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-${WATCHTOWER_CONF_EXTRA_ARGS:-}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${WATCHTOWER_CONF_DEBUG_ENABLED:-false}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONF_DEFAULT_INTERVAL:-$default_interval}}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${WATCHTOWER_CONF_ENABLED:-false}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-$default_notify_on_no_updates}}"
}

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}

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
    local date_str="$1"
    if date -d "$date_str" "+%s" >/dev/null 2>&1; then
        date -d "$date_str" "+%s"
    elif command -v gdate >/dev/null 2>&1; then
        gdate -d "$date_str" "+%s"
    else
        echo "0"
    fi
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

send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data
        data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" \
            '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        
        # 使用 timeout 确保 curl 不会卡住脚本, 并且在后台运行
        timeout 15s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url" &
    fi
}

_extract_interval_from_cmd(){
    local cmd_json="$1"
    local interval=""
    if command -v jq &>/dev/null; then
        interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
    else
        local tokens; read -r -a tokens <<< "$(echo "$cmd_json" | tr -d '[],"')"
        local prev=""
        for t in "${tokens[@]}"; do
            if [ "$prev" = "--interval" ]; then
                interval="$t"
                break
            fi
            prev="$t"
        done
    fi
    interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g')
    if [ -z "$interval" ]; then
        echo ""
    else
        echo "$interval"
    fi
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
    local logs
    logs=$(get_watchtower_all_raw_logs 2>/dev/null || true)
    if [ -z "$logs" ]; then 
        echo ""; 
        return 1; 
    fi
    
    local line ts
    if echo "$logs" | grep -qiE "permission denied|cannot connect"; then
        echo -e "${RED}错误:权限不足${NC}"
        return 1
    fi
    line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    if [ -n "$line" ]; then
        ts=$(_parse_watchtower_timestamp_from_log_line "$line")
        if [ -n "$ts" ]; then
            echo "$ts"
            return 0
        fi
    fi
    echo ""
    return 1
}

_get_watchtower_remaining_time(){
    local interval_seconds="$1"
    local raw_logs="$2"
    local current_epoch
    current_epoch=$(date +%s)

    if [ -z "$raw_logs" ]; then
        echo -e "${YELLOW}N/A${NC}"
        return
    fi

    local last_event_line
    last_event_line=$(echo "$raw_logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)

    if [ -z "$last_event_line" ]; then
        echo -e "${YELLOW}等待首次扫描...${NC}"
        return
    fi

    local last_event_timestamp_str=""
    local next_expected_check_epoch=0
    
    if [[ "$last_event_line" == *"Scheduling first run"* ]]; then
        last_event_timestamp_str=$(echo "$last_event_line" | sed -n 's/.*Scheduling first run: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p')
        next_expected_check_epoch=$(_date_to_epoch "$last_event_timestamp_str")
    else
        if [ -z "$interval_seconds" ]; then
             echo -e "${YELLOW}N/A${NC}"
             return
        fi
        last_event_timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_event_line")
        local last_event_epoch=$(_date_to_epoch "$last_event_timestamp_str")
        
        if [ "$last_event_epoch" -eq 0 ]; then
            echo -e "${YELLOW}计算中...${NC}"
            return
        fi

        if [[ "$last_event_line" == *"Session done"* ]]; then
            next_expected_check_epoch=$((last_event_epoch + interval_seconds))
            while [ "$next_expected_check_epoch" -le "$current_epoch" ]; do
                next_expected_check_epoch=$((next_expected_check_epoch + interval_seconds))
            done
        elif [[ "$last_event_line" == *"Starting Watchtower"* ]]; then
            echo -e "${YELLOW}等待首次调度...${NC}"
            return
        fi
    fi

    if [ "$next_expected_check_epoch" -eq 0 ]; then
        echo -e "${YELLOW}计算中...${NC}"
        return
    fi

    local remaining_seconds=$((next_expected_check_epoch - current_epoch))

    if [ "$remaining_seconds" -gt 0 ]; then
        local hours=$((remaining_seconds / 3600))
        local minutes=$(( (remaining_seconds % 3600) / 60 ))
        local seconds=$(( remaining_seconds % 60 ))
        printf "%b%02d时%02d分%02d秒%b" "$GREEN" "$hours" "$minutes" "$seconds" "$NC"
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

    if [ "$interactive_mode" = "true" ]; then
        docker_run_args+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi

    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    
    # 移除所有Watchtower原生通知参数，因为我们将手动处理
    
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$final_exclude_list" ]; then
        if [ "$interactive_mode" = "false" ]; then log_info "正在应用排除规则: ${final_exclude_list}"; fi
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ -z "${container_names[*]}" ] && [ "$interactive_mode" = "false" ]; then
            log_err "排除规则导致监控列表为空，Watchtower 无法启动。"
            return 1
        fi
        if [ "$interactive_mode" = "false" ]; then log_info "计算后的监控范围: ${container_names[*]}"; fi
    else 
        if [ "$interactive_mode" = "false" ]; then log_info "未发现排除规则，Watchtower 将监控所有容器。"; fi
    fi

    if [ "$interactive_mode" = "false" ]; then echo "⬇️ 正在拉取 Watchtower 镜像..."; fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    if [ "$interactive_mode" = "false" ]; then _print_header "正在启动 $mode_description"; fi
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    if [ "$interactive_mode" = "false" ]; then
        local final_cmd_str=""; for arg in "${final_command_to_run[@]}"; do final_cmd_str+=" $(printf %q "$arg")"; done
        echo -e "${CYAN}执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo ${final_cmd_str}${NC}"
    fi

    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
    
    if [ "$interactive_mode" = "true" ]; then
        # 手动扫描的通知由日志监控器处理
        if [ $rc -eq 0 ]; then log_success "一次性扫描完成，等待监控器发送报告..."; else log_err "一次性扫描失败。"; fi
        return $rc
    else
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "$mode_description 启动成功。"
            # 启动日志监控器
            start_log_monitor
        else
            log_err "$mode_description 启动失败。"
        fi
        return 0
    fi
}

# --- 全新的日志监控模块 ---
LOG_MONITOR_PID_FILE="/tmp/watchtower_monitor.pid"

# 解析日志块并发送通知
_process_log_chunk() {
    local chunk="$1"
    
    # 检查是否是手动触发的扫描
    local is_manual_scan=false
    if echo "$chunk" | grep -q "Running a one time update"; then
        is_manual_scan=true
    fi

    local session_line
    session_line=$(echo "$chunk" | grep "Session done" | tail -n 1)
    if [ -z "$session_line" ]; then return; fi

    local scanned updated failed hostname report_message
    scanned=$(echo "$session_line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p'); scanned=${scanned:-0}
    updated=$(echo "$session_line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p'); updated=${updated:-0}
    failed=$(echo "$session_line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p'); failed=${failed:-0}
    
    # 如果没有更新，且未开启“无更新也通知”，则直接返回
    if [ "$updated" -eq 0 ] && [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" != "true" ]; then
        return
    fi

    hostname=$(hostname)
    local time_now
    time_now=$(date '+%Y-%m-%d %H:%M:%S')
    
    local title="*自动扫描报告*"
    if [ "$is_manual_scan" = true ]; then
        title="*手动扫描报告*"
    fi
    
    local updated_details=""
    if [ "$updated" -gt 0 ]; then
        # 提取更新详情
        local creating_lines
        creating_lines=$(echo "$chunk" | grep "Creating")
        while IFS= read -r line; do
            local container_name image_name old_id new_id
            container_name=$(echo "$line" | sed -n 's/.*Creating \/\([^ ]*\).*/\1/p')
            
            # 查找对应的 Stopping 行来获取镜像信息
            local stopping_line
            stopping_line=$(echo "$chunk" | grep "Stopping /${container_name} ")
            image_name=$(echo "$stopping_line" | sed -n 's/.*with image \(.*\)/\1/p' | cut -d':' -f1-2) # 保留 tag
            
            # 查找 Found new image 行
            local found_line
            found_line=$(echo "$chunk" | grep "Found new ${image_name}")
            old_id=$(echo "$found_line" | sed -n 's/.*ID \([a-zA-Z0-9]*\).*/\1/p' | cut -c 1-12)
            new_id=$(echo "$found_line" | sed -n 's/.*new ID \([a-zA-Z0-9]*\).*/\1/p' | cut -c 1-12)

            updated_details+="\n- 🔄 *${container_name}*\n  🖼️ \`\`\`${image_name}\`\`\`\n  🆔 \`${old_id}\` -> \`${new_id}\`"
        done <<< "$creating_lines"
        
        report_message="${title}\n\n✅ *扫描完成！共更新 ${updated} 个容器。*\n*服务器:* \`${hostname}\`${updated_details}\n\n⏰ *时间:* \`${time_now}\`"
    else
        report_message="${title}\n\n✅ *扫描完成！未发现可更新的容器。*\n- *服务器:* \`${hostname}\`\n- *扫描总数:* ${scanned} 个\n- *失败:* ${failed} 个\n\n⏰ *时间:* \`${time_now}\`"
    fi
    
    send_notify "$report_message"
}

# 日志监控后台进程
log_monitor_process() {
    # 加载配置以获取通知设置
    load_config
    
    local chunk=""
    
    # 确保只监控新产生的日志
    local since
    since=$(date '+%Y-%m-%dT%H:%M:%S')

    # 使用 stdbuf 禁用输出缓冲，确保日志实时性
    stdbuf -oL docker logs --since "$since" -f watchtower 2>&1 | while IFS= read -r line; do
        # 检查是否是新会话的开始
        if [[ "$line" == *"Starting"/watchtower* || "$line" == *"Running a one time update"* ]]; then
            # 如果 chunk 不为空, 说明上一个会话可能异常中断了, 处理它
            if [ -n "$chunk" ]; then
                _process_log_chunk "$chunk"
            fi
            # 重置 chunk
            chunk=""
        fi
        
        chunk+="$line"$'\n'
        
        # 如果是会话结束标志, 处理当前 chunk
        if echo "$line" | grep -q "Session done"; then
            _process_log_chunk "$chunk"
            chunk="" # 重置
        fi
    done
}

start_log_monitor() {
    if [ -f "$LOG_MONITOR_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOG_MONITOR_PID_FILE")
        if ps -p "$old_pid" > /dev/null; then
            log_info "日志监控器已在运行 (PID: $old_pid)。"
            return
        fi
    fi
    
    log_info "正在后台启动日志监控器..."
    # 将监控进程放到后台
    nohup bash -c "'$0' --monitor" >/dev/null 2>&1 &
    local monitor_pid=$!
    echo "$monitor_pid" > "$LOG_MONITOR_PID_FILE"
    
    # 等待一小会确保进程启动
    sleep 1
    if ps -p "$monitor_pid" > /dev/null; then
        log_success "日志监控器已启动 (PID: $monitor_pid)。"
    else
        log_err "日志监控器启动失败！"
        rm -f "$LOG_MONITOR_PID_FILE"
    fi
}

stop_log_monitor() {
    if [ -f "$LOG_MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$LOG_MONITOR_PID_FILE")
        if ps -p "$pid" > /dev/null; then
            log_info "正在停止日志监控器 (PID: $pid)..."
            kill "$pid"
            sleep 1
            if ! ps -p "$pid" > /dev/null; then
                log_success "日志监控器已停止。"
            else
                log_warn "无法停止日志监控器，请手动操作: kill $pid"
            fi
        fi
        rm -f "$LOG_MONITOR_PID_FILE"
    else
        log_info "日志监控器未在运行。"
    fi
}
# --- 日志监控模块结束 ---


_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."; 
    stop_log_monitor
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    local interval="${WATCHTOWER_CONFIG_INTERVAL}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower (无通知模式)"; then
        log_err "Watchtower 重建失败！"; WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
    send_notify "🔄 Watchtower 服务已重建并启动。日志监控器将接管通知。"
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
    local TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN_INPUT=$(_prompt_user_input "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " "$TG_BOT_TOKEN")
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT}"
    local TG_CHAT_ID_INPUT; TG_CHAT_ID_INPUT=$(_prompt_user_input "请输入 Chat ID (当前: ${TG_CHAT_ID}): " "$TG_CHAT_ID")
    TG_CHAT_ID="${TG_CHAT_ID_INPUT}"
    
    local notify_on_no_updates_choice
    notify_on_no_updates_choice=$(_prompt_user_input "是否在没有容器更新时也发送 Telegram 通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " "")
    
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    log_info "Telegram 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi
        
        local -a content_array=(
            "1. 配置 Telegram (状态: $tg_status, 无更新也通知: $notify_on_no_updates_status)"
            "2. 发送测试通知"
            "3. 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) _configure_telegram; save_config; stop_log_monitor; start_log_monitor; press_enter_to_continue ;;
            2) if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_warn "请先配置 Telegram。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} の*测试消息*。"; log_info "测试通知已发送。"; fi; press_enter_to_continue ;;
            3) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "所有通知配置已清空。"; stop_log_monitor; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

configure_watchtower(){
    local current_interval_for_prompt="${WATCHTOWER_CONFIG_INTERVAL}"
    local WT_INTERVAL_TMP
    WT_INTERVAL_TMP="$(_prompt_for_interval "$current_interval_for_prompt" "请输入检查间隔")"
    log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"
    sleep 1
    
    configure_exclusion_list
    
    local extra_args_choice
    extra_args_choice=$(_prompt_user_input "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " "")
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then 
        local temp_extra_args_input
        temp_extra_args_input=$(_prompt_user_input "请输入额外参数: " "$temp_extra_args")
        temp_extra_args="${temp_extra_args_input}"
    fi
    
    local debug_choice
    debug_choice=$(_prompt_user_input "是否启用调试模式? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " "")
    local temp_debug_enabled="false"
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi
    
    local final_exclude_list_display="${WATCHTOWER_EXCLUDE_LIST:-无}"
    local -a confirm_array=(
        "检查间隔: $(_format_seconds_to_human "$WT_INTERVAL_TMP")" 
        "排除列表: ${final_exclude_list_display//,/, }" 
        "额外参数: ${temp_extra_args:-无}" 
        "调试模式: $temp_debug_enabled"
    )
    _render_menu "配置确认" "${confirm_array[@]}"; read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice < /dev/tty
    if echo "$confirm_choice" | grep -qE '^[Nn]$'; then log_info "操作已取消。"; return 10; fi
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"; WATCHTOWER_ENABLED="true"; save_config
    _rebuild_watchtower || return 1; return 0
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local monitor_status="${RED}未运行${NC}"
        if [ -f "$LOG_MONITOR_PID_FILE" ] && ps -p "$(cat "$LOG_MONITOR_PID_FILE")" >/dev/null; then
             monitor_status="${GREEN}运行中 (PID: $(cat "$LOG_MONITOR_PID_FILE"))${NC}"
        fi
        local -a items_array=(
            "1. 停止/移除 Watchtower" 
            "2. 重建 Watchtower"
            "3. 日志监控器状态: ${monitor_status}"
            "4. 手动 [启动] 日志监控器"
            "5. 手动 [停止] 日志监控器"
        )
        _render_menu "⚙️ 任务管理 ⚙️" "${items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定移除 Watchtower？"; then 
                        stop_log_monitor
                        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
                        WATCHTOWER_ENABLED="false"; save_config
                        send_notify "🗑️ Watchtower 已从您的服务器移除。"
                        echo -e "${GREEN}✅ 已移除。${NC}"
                    fi
                else 
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue 
                ;;
            2) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定要重建 Watchtower 吗？"; then
                        _rebuild_watchtower
                    else
                        log_info "操作已取消。"
                    fi
                else 
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue
                ;;
            3) press_enter_to_continue ;;
            4) start_log_monitor; press_enter_to_continue ;;
            5) stop_log_monitor; press_enter_to_continue ;;
            "") return ;; 
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
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
        
        local monitor_status="${RED}未运行${NC}"
        if [ -f "$LOG_MONITOR_PID_FILE" ] && ps -p "$(cat "$LOG_MONITOR_PID_FILE")" >/dev/null; then
             monitor_status="${GREEN}运行中${NC}"
        fi

        local header_text="Watchtower 管理"
        
        local -a content_array=(
            "🕝 Watchtower 状态: ${STATUS_COLOR}" 
            "🔔 通知模式: ${GREEN}脚本日志监控 (${monitor_status})${NC}"
            "⏳ 下次检查: ${COUNTDOWN}" 
            "📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        
        content_array+=("" "主菜单：" 
            "1. 启用并配置 Watchtower" 
            "2. 配置通知 (由监控器使用)" 
            "3. 任务管理" 
            "4. 手动触发一次性扫描"
        )
        _render_menu "$header_text" "${content_array[@]}"; read -r -p " └──> 输入选项或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) run_watchtower_once; press_enter_to_continue ;;
          "") return 0 ;;
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main(){ 
    # --- 新增: 命令行参数处理 ---
    case "${1:-}" in
        --monitor)
            log_monitor_process
            exit 0
            ;;
        --run-once)
            run_watchtower_once
            exit $?
            ;;
    esac

    trap 'echo -e "\n操作被中断。"; exit 10' INT
    log_info "欢迎使用 Watchtower 模块 ${SCRIPT_VERSION}" >&2
    main_menu
    exit 10
}

main "$@"
