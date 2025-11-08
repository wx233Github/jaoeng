# =============================================================
# 🚀 Watchtower 管理模块 (v6.3.2-修复后台进程函数继承)
# - BUG修复: 通过 `export -f run_with_sudo` 将函数导出到子Shell，彻底解决了后台监控器因找不到函数定义而启动即崩溃的致命问题。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.3.2"

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
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
  log_err "致命错误: run_with_sudo 函数未定义。请确保从 install.sh 启动此脚本。"
  exit 1
fi

# 本地配置文件路径
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
DOCKER_COMPOSE_PROJECT_DIR_CRON=""
CRON_HOUR=""
CRON_TASK_ENABLED=""
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
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-${WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON:-}}"
    CRON_HOUR="${CRON_HOUR:-${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-$default_cron_hour}}"
    CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-${WATCHTOWER_CONF_TASK_ENABLED:-false}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-$default_notify_on_no_updates}}"
}

# 预加载一次配置以进行早期检查
load_config

# --- 依赖检查 ---
if ! command -v docker &> /dev/null; then
    log_err "Docker 未安装。此模块需要 Docker 才能运行。"
    log_err "请返回主菜单，先使用 Docker 模块进行安装。"
    exit 10
fi

if [ -n "$TG_BOT_TOKEN" ] && ! command -v jq &> /dev/null; then
    log_err "检测到 Telegram 已配置，但系统缺少 'jq' 命令。"
    log_err "jq 是发送格式化通知所必需的。请先安装它。"
    log_info "  Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y jq"
    log_info "  CentOS/RHEL:   sudo yum install -y epel-release && sudo yum install -y jq"
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
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
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
    local mode="${2:-async}" # 'async' or 'sync'

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data
        data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" \
            '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        
        local curl_cmd=(timeout 15s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url")

        if [ "$mode" = "sync" ]; then
            "${curl_cmd[@]}"
        else
            "${curl_cmd[@]}" &
        fi
    fi
}

# 新增函数：处理间隔输入
_prompt_for_interval() {
    local default_interval_seconds="$1"
    local prompt_message="$2"
    local input_value
    local current_display_value="$(_format_seconds_to_human "$default_interval_seconds")"

    while true; do
        input_value=$(_prompt_user_input "${prompt_message} (例如: 3600, 1h, 30m, 1d, 当前: ${current_display_value}): " "")
        
        if [ -z "$input_value" ]; then
            log_warn "输入为空，将使用当前默认值: ${current_display_value} (${default_interval_seconds}秒)"
            echo "$default_interval_seconds"
            return 0
        fi

        local seconds=0
        if [[ "$input_value" =~ ^[0-9]+$ ]]; then
            seconds="$input_value"
        elif [[ "$input_value" =~ ^([0-9]+)s$ ]]; then
            seconds="${BASH_REMATCH[1]}"
        elif [[ "$input_value" =~ ^([0-9]+)m$ ]]; then
            seconds=$(( "${BASH_REMATCH[1]}" * 60 ))
        elif [[ "$input_value" =~ ^([0-9]+)h$ ]]; then
            seconds=$(( "${BASH_REMATCH[1]}" * 3600 ))
        elif [[ "$input_value" =~ ^([0-9]+)d$ ]]; then
            seconds=$(( "${BASH_REMATCH[1]}" * 86400 ))
        else
            log_warn "无效的间隔格式。请使用秒数 (如 3600) 或带单位 (如 1h, 30m, 1d)。"
            sleep 1
            continue
        fi

        if [ "$seconds" -gt 0 ]; then
            echo "$seconds"
            return 0
        else
            log_warn "间隔必须是正数。"
            sleep 1
        fi
    done
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
    load_config

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
    
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$final_exclude_list" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then
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
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "正在启动一次性扫描... (日志将实时显示)"
        local scan_logs rc
        set +e
        scan_logs=$(JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}" 2>&1)
        rc=$?
        set -e
        echo "$scan_logs"

        if [ $rc -eq 0 ]; then
            log_success "一次性扫描完成。"
            if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
                log_info "正在解析扫描结果并生成报告..."
                if _process_log_chunk "$scan_logs" "sync"; then
                    log_success "报告已发送。"
                else
                    log_info "根据配置，无更新时无需发送通知。"
                fi
            fi
        else
            log_err "一次性扫描失败。"
        fi
        return $rc
    else
        if [ "$interactive_mode" = "false" ]; then
            local final_cmd_str=""; for arg in "${final_command_to_run[@]}"; do final_cmd_str+=" $(printf %q "$arg")"; done
            echo -e "${CYAN}执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo ${final_cmd_str}${NC}"
        fi
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
        
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "$mode_description 启动成功。"
            start_log_monitor
        else
            log_err "$mode_description 启动失败。"
        fi
        return 0
    fi
}

# --- 日志监控模块 ---
LOG_MONITOR_PID_FILE="/tmp/watchtower_monitor.pid"

_process_log_chunk() {
    local chunk="$1"
    local mode="${2:-async}" # 'async' or 'sync'
    load_config
    
    local session_line
    session_line=$(echo "$chunk" | grep "Session done" | tail -n 1)
    if [ -z "$session_line" ]; then return 1; fi

    local updated hostname report_message
    updated=$(echo "$session_line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p'); updated=${updated:-0}
    
    if [ "$updated" -eq 0 ] && [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" != "true" ]; then
        return 1
    fi

    hostname=$(hostname)
    
    if [ "$updated" -gt 0 ]; then
        local updated_details=""
        
        # 提取被停止和被创建的容器列表
        local stopped_containers; stopped_containers=$(echo "$chunk" | sed -n 's/.*Stopping \/\([^ ]*\).*/\1/p' | sort -u)
        local created_containers; created_containers=$(echo "$chunk" | sed -n 's/.*Creating \/\([^ ]*\).*/\1/p' | sort -u)
        
        # 使用 grep 交叉比对，找出交集，这是最稳健的方法
        local recreated_containers; recreated_containers=$(echo "$stopped_containers" | grep -F -x -f - <(echo "$created_containers"))

        if [ -n "$recreated_containers" ]; then
            while IFS= read -r container; do
                updated_details+=$(printf "\n • \`%s\`" "$container")
            done <<< "$recreated_containers"
        else
            # 最终回退方案，虽然在新逻辑下几乎不可能触发
            updated_details="\n • _(无法解析具体的容器名称)_"
        fi
        
        printf -v report_message "🚀 *新版本已部署!*\n\n在服务器 \`%s\` 上，\n我们为您更新了 %s 个服务:\n\n*✨ 更新内容:*\n%s\n\n所有服务均已平稳重启。" \
            "$hostname" \
            "$updated" \
            "$updated_details"
    else
        printf -v report_message "✅ *同步检查完成*\n\n服务器 \`%s\` 上的所有\nDocker 服务都已是最新版本，无需操作。" \
            "$hostname"
    fi
    
    send_notify "$report_message" "$mode"
    return 0
}

log_monitor_process() {
    local chunk=""
    local since
    since=$(date '+%Y-%m-%dT%H:%M:%S')

    stdbuf -oL run_with_sudo docker logs --since "$since" -f watchtower 2>&1 | while IFS= read -r line; do
        if [[ "$line" == *"Starting Watchtower"* || "$line" == *"Running a one time update"* ]]; then
            if [ -n "$chunk" ]; then
                _process_log_chunk "$chunk"
            fi
            chunk=""
        fi
        
        chunk+="$line"$'\n'
        
        if echo "$line" | grep -q "Session done"; then
            _process_log_chunk "$chunk"
            chunk=""
        fi
    done
}

start_log_monitor() {
    # 导出函数，使其在 nohup 的子 Shell 中可用
    export -f run_with_sudo

    if [ -f "$LOG_MONITOR_PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$LOG_MONITOR_PID_FILE")
        if ps -p "$old_pid" > /dev/null; then
            log_info "日志监控器已在运行 (PID: $old_pid)。"
            return
        fi
    fi
    
    log_info "正在后台启动日志监控器..."
    nohup bash -c "'$0' --monitor" >/dev/null 2>&1 &
    local monitor_pid=$!
    echo "$monitor_pid" > "$LOG_MONITOR_PID_FILE"
    
    sleep 1
    if ps -p "$monitor_pid" > /dev/null; then
        log_success "日志监控器已启动 (PID: $monitor_pid)。"
    else
        log_err "日志监控器启动失败！"
        rm -f "$LOG_MONITOR_PID_FILE"
    fi
}

stop_log_monitor() {
    if [ ! -f "$LOG_MONITOR_PID_FILE" ]; then
        log_info "日志监控器未在运行。"
        return
    fi

    local pid
    pid=$(cat "$LOG_MONITOR_PID_FILE")
    if ! ps -p "$pid" > /dev/null; then
        log_info "日志监控器 (PID: $pid) 已不存在。"
        rm -f "$LOG_MONITOR_PID_FILE"
        return
    fi
    
    log_info "正在停止日志监控器 (PID: $pid)..."
    kill "$pid"
    
    for _ in {1..3}; do
        if ! ps -p "$pid" > /dev/null; then
            log_success "日志监控器已停止。"
            rm -f "$LOG_MONITOR_PID_FILE"
            return
        fi
        sleep 1
    done

    log_warn "日志监控器未能正常停止，正在强制终止..."
    kill -9 "$pid"
    sleep 1

    if ! ps -p "$pid" > /dev/null; then
        log_success "日志监控器已被强制停止。"
    else
        log_err "无法停止日志监控器，请手动操作: kill -9 $pid"
    fi
    rm -f "$LOG_MONITOR_PID_FILE"
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."; 
    stop_log_monitor
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    local interval="${WATCHTOWER_CONFIG_INTERVAL}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower (监控模式)"; then
        log_err "Watchtower 重建失败！"; WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
    send_notify "🔄 Watchtower 服务已重建并启动。日志监控器将接管通知。" "sync"
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

_configure_email() {
    local EMAIL_TO_INPUT
    EMAIL_TO_INPUT=$(_prompt_user_input "请输入接收邮箱 (当前: ${EMAIL_TO}): " "$EMAIL_TO")
    EMAIL_TO="${EMAIL_TO_INPUT}"
    log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi
        
        local -a content_array=(
            "1. 配置 Telegram (状态: $tg_status, 无更新也通知: $notify_on_no_updates_status)"
            "2. 配置 Email (状态: $email_status) (当前未使用)"
            "3. 发送测试通知"
            "4. 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-4")
        case "$choice" in
            1) _configure_telegram; save_config; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_warn "请先配置 Telegram。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} の*测试消息*。" "sync"; log_success "测试通知已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "所有通知配置已清空。"; stop_log_monitor; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

configure_watchtower(){
    local current_interval_for_prompt="${WATCHTOWER_CONFIG_INTERVAL}"
    local WT_INTERVAL_TMP
    WT_INTERVAL_TMP=$(_prompt_for_interval "$current_interval_for_prompt" "请输入检查间隔")
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
    _render_menu "配置确认" "${confirm_array[@]}"
    local confirm_choice
    confirm_choice=$(_prompt_for_menu_choice "")
    if echo "$confirm_choice" | grep -qE '^[Nn]$'; then log_info "操作已取消。"; return 10; fi
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"; WATCHTOWER_ENABLED="true"; save_config
    _rebuild_watchtower || return 1; return 0
}

configure_exclusion_list() {
    declare -A excluded_map; local initial_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$initial_exclude_list" ]; then 
        local IFS=,; 
        for container_name in $initial_exclude_list; do 
            container_name=$(echo "$container_name" | xargs); 
            if [ -n "$container_name" ]; then 
                excluded_map["$container_name"]=1; 
            fi; 
        done; 
        unset IFS; 
    fi
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; 
        local -a all_containers_array=(); 
        while IFS= read -r line; do all_containers_array+=("$line"); done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}'); 
        local -a items_array=(); local i=0
        while [ $i -lt ${#all_containers_array[@]} ]; do 
            local container="${all_containers_array[$i]}"; 
            local is_excluded=" "; 
            if [ -n "${excluded_map[$container]+_}" ]; then is_excluded="✔"; fi; 
            items_array+=("$((i + 1)). [${GREEN}${is_excluded}${NC}] $container"); 
            i=$((i + 1)); 
        done
        items_array+=("")
        local current_excluded_display="无"
        if [ ${#excluded_map[@]} -gt 0 ]; then
            local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; current_excluded_display="${keys[*]}"; IFS="$old_ifs"
        fi
        items_array+=("${CYAN}当前排除: ${current_excluded_display}${NC}")
        _render_menu "配置排除列表" "${items_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "数字" "c,回车")
        case "$choice" in
            c|C) break ;;
            "") 
                excluded_map=()
                log_info "已清空排除列表。"
                sleep 1
                continue
                ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' '); IFS=',' read -r -a selected_indices <<< "$clean_choice"; local has_invalid_input=false
                for index in "${selected_indices[@]}"; do
                    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#all_containers_array[@]} ]; then
                        local target_container="${all_containers_array[$((index - 1))]}"; if [ -n "${excluded_map[$target_container]+_}" ]; then unset excluded_map["$target_container"]; else excluded_map["$target_container"]=1; fi
                    elif [ -n "$index" ]; then has_invalid_input=true; fi
                done
                if [ "$has_invalid_input" = "true" ]; then log_warn "输入 '${choice}' 中包含无效选项，已忽略。"; sleep 1.5; fi
                ;;
        esac
    done
    local final_excluded_list=""; if [ ${#excluded_map[@]} -gt 0 ]; then local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; final_excluded_list="${keys[*]}"; IFS="$old_ifs"; fi
    WATCHTOWER_EXCLUDE_LIST="$final_excluded_list"
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
            "3. 日志监控器: ${monitor_status}"
            "4. 手动 [启动] 日志监控器"
            "5. 手动 [停止] 日志监控器"
        )
        _render_menu "⚙️ 任务管理 ⚙️" "${items_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定移除 Watchtower？"; then 
                        stop_log_monitor
                        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
                        WATCHTOWER_ENABLED="false"; save_config
                        send_notify "🗑️ Watchtower 已从您的服务器移除。" "sync"
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

_format_and_highlight_log_line(){
    local line="$1"
    local ts=$(_parse_watchtower_timestamp_from_log_line "$line")
    case "$line" in
        *"Session done"*)
            local f s u c
            f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p')
            s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p')
            u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p')
            c="$GREEN"
            if [ "${f:-0}" -gt 0 ]; then c="$YELLOW"; fi
            printf "%s %b%s%b\n" "$ts" "$c" "✅ 扫描: ${s:-?}, 更新: ${u:-?}, 失败: ${f:-?}" "$NC"
            ;;
        *"Found new"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$NC"
            ;;
        *"Stopping "*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$NC"
            ;;
        *"Creating "*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$NC"
            ;;
        *"No new images found"*)
            printf "%s %b%s%b\n" "$ts" "$CYAN" "ℹ️ 未发现新镜像。" "$NC"
            ;;
        *"Scheduling first run"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🕒 首次运行已调度" "$NC"
            ;;
        *"Starting Watchtower"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "✨ Watchtower 已启动" "$NC"
            ;;
        *)
            if echo "$line" | grep -qiE "\b(unauthorized|failed|error|fatal)\b|permission denied|cannot connect|Could not do a head request|Notification template error|Could not use configured notification template"; then
                local msg
                msg=$(echo "$line" | sed -n 's/.*error="\([^"]*\)".*/\1/p' | tr -d '\n')
                if [ -z "$msg" ] && [[ "$line" == *"msg="* ]]; then
                    msg=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p' | tr -d '\n')
                fi
                if [ -z "$msg" ]; then
                    msg=$(echo "$line" | sed -E 's/.*(level=(error|warn|info|fatal)|time="[^"]*")\s*//g' | tr -d '\n')
                fi
                local full_msg="${msg:-$line}"
                local truncated_msg
                if [ ${#full_msg} -gt 50 ]; then
                    truncated_msg="${full_msg:0:47}..."
                else
                    truncated_msg="$full_msg"
                fi
                printf "%s %b%s%b\n" "$ts" "$RED" "❌ 错误: ${truncated_msg}" "$NC"
            fi
            ;;
    esac
}

get_updates_last_24h(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then
        echo ""
        return 1
    fi
    local since
    if date -d "24 hours ago" >/dev/null 2>&1; then
        since=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    elif command -v gdate >/dev/null 2>&1; then
        since=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    fi
    local raw_logs
    if [ -n "$since" ]; then
        raw_logs=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --since "$since" watchtower 2>&1 || true)
    fi
    if [ -z "$raw_logs" ]; then
        raw_logs=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 200 watchtower 2>&1 || true)
    fi
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|fatal|permission denied|cannot connect|Could not do a head request|Notification template error|Could not use configured notification template" || true
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local title="📊 Watchtower 详情与管理 📊"
        local interval raw_logs COUNTDOWN updates
        
        set +e
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        set -e
        
        COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")

        local monitor_status="${RED}未运行${NC}"
        if [ -f "$LOG_MONITOR_PID_FILE" ] && ps -p "$(cat "$LOG_MONITOR_PID_FILE")" >/dev/null; then
             monitor_status="${GREEN}运行中 (PID: $(cat "$LOG_MONITOR_PID_FILE"))${NC}"
        fi
        
        local -a content_lines_array=(
            "⏱️  ${CYAN}当前状态${NC}"
            "    ${YELLOW}上次活动:${NC} $(get_last_session_time || echo 'N/A')" 
            "    ${YELLOW}下次检查:${NC} ${COUNTDOWN}"
            "    ${YELLOW}通知监控:${NC} ${monitor_status}"
            "" 
            "📜  ${CYAN}最近 24h 摘要${NC}"
        )
        
        updates=$(get_updates_last_24h || true)
        if [ -z "$updates" ]; then 
            content_lines_array+=("    无日志事件。"); 
        else 
            while IFS= read -r line; do content_lines_array+=("    $(_format_and_highlight_log_line "$line")"); done <<< "$updates"; 
        fi
        
        _render_menu "$title" "${content_lines_array[@]}"
        
        read -r -p "$(echo -e "> ${ORANGE}[1]${NC}实时日志 ${ORANGE}[2]${NC}容器管理 ${ORANGE}[3]${NC}触发扫描 (↩ 返回): ")" pick < /dev/tty
        case "$pick" in
            1) if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo -e "\n按 Ctrl+C 停止..."; trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue; else echo -e "\n${RED}Watchtower 未运行。${NC}"; press_enter_to_continue; fi ;;
            2) show_container_info ;;
            3) run_watchtower_once; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

view_and_edit_config(){
    local -a config_items=("TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "排除列表|WATCHTOWER_EXCLUDE_LIST|string_list" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval" "Watchtower 启用状态|WATCHTOWER_ENABLED|bool" "Cron 执行小时|CRON_HOUR|number_range|0-23" "Cron 项目目录|DOCKER_COMPOSE_PROJECT_DIR_CRON|string" "Cron 任务启用状态|CRON_TASK_ENABLED|bool" "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool")
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
        _render_menu "⚙️ 配置查看与编辑 (底层) ⚙️" "${content_lines_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-${#config_items[@]}")
        if [ -z "$choice" ]; then return; fi
        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then log_warn "无效选项。"; sleep 1; continue; fi
        local selected_index=$((choice - 1)); local selected_item="${config_items[$selected_index]}"; local label; label=$(echo "$selected_item" | cut -d'|' -f1); local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2); local type; type=$(echo "$selected_item" | cut -d'|' -f3); local extra; extra=$(echo "$selected_item" | cut -d'|' -f4); local current_value="${!var_name}"; local new_value=""
        
        case "$type" in
            string|string_list) 
                local new_value_input
                new_value_input=$(_prompt_user_input "请输入新的 '$label' (当前: $current_value): " "$current_value")
                declare "$var_name"="${new_value_input}" 
                ;;
            bool) 
                local new_value_input
                new_value_input=$(_prompt_user_input "是否启用 '$label'? (y/N, 当前: $current_value): " "")
                if echo "$new_value_input" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi 
                ;;
            interval) 
                new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔")
                if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi 
                ;;
            number_range)
                local min; min=$(echo "$extra" | cut -d'-' -f1); local max; max=$(echo "$extra" | cut -d'-' -f2)
                while true; do 
                    local new_value_input
                    new_value_input=$(_prompt_user_input "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " "$current_value")
                    new_value="${new_value_input}"
                    if [ -z "$new_value" ]; then break; fi
                    if echo "$new_value" | grep -qE '^[0-9]+$' && [ "$new_value" -ge "$min" ] && [ "$new_value" -le "$max" ]; then 
                        declare "$var_name"="$new_value"; 
                        break; 
                    else 
                        log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"; 
                    fi
                done 
                ;;
        esac
        save_config; log_info "'$label' 已更新。"; sleep 1
    done
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
            if echo "$status" | grep -qE '^Up'; then 
                status_colored="${GREEN}运行中${NC}"
            elif echo "$status" | grep -qE '^Exited|Created'; then 
                status_colored="${RED}已退出${NC}"
            else 
                status_colored="${YELLOW}${status}${NC}"
            fi
            content_lines_array+=("$(printf "%2d   %-15s %-35s %s" "$i" "$name" "$image" "$status_colored")")
            i=$((i + 1))
        done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        
        content_lines_array+=("" "a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-${#containers[@]}" "a,s")
        case "$choice" in 
            "") return ;;
            a|A) if confirm_action "确定要启动所有已停止的容器吗?"; then log_info "正在启动..."; local stopped_containers; stopped_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -aq -f status=exited); if [ -n "$stopped_containers" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker start $stopped_containers &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            s|S) if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then log_info "正在停止..."; local running_containers; running_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -q); if [ -n "$running_containers" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop $running_containers &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then log_warn "无效输入或编号超范围。"; sleep 1; continue; fi
                local selected_container="${containers[$((choice - 1))]}"; if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
                local -a action_items_array=( "1. 查看日志 (Logs)" "2. 重启 (Restart)" "3. 停止 (Stop)" "4. 删除 (Remove)" "5. 查看详情 (Inspect)" "6. 进入容器 (Exec)" )
                _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"
                local action
                action=$(_prompt_for_menu_choice "1-6")
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
            "4. 查看/编辑配置 (底层)" 
            "5. 详情与管理"
        )
        _render_menu "$header_text" "${content_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) view_and_edit_config ;;
          5) show_watchtower_details ;;
          "") return 0 ;;
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main(){ 
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
