#!/bin/bash
# =============================================================
# 🚀 Watchtower 管理模块 (v4.9.8-核心语法修复)
# - 修复: _extract_interval_from_cmd 函数中缺失的 'fi' 关键字，解决语法错误 (line 151)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.9.8"

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
    # 优先级: 
    # 1. 本地配置文件 ($CONFIG_FILE) - 用户自定义的最高优先级
    # 2. 从 config.json 传入的环境变量 (WATCHTOWER_CONF_*) - 全局默认值
    # 3. 脚本内部的硬编码默认值 - 最终备用

    # 1. 先加载本地用户配置 (如果存在), 这会预填充变量
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" &>/dev/null || true
    fi

    # 2. 为尚未被本地配置设置的变量，从环境变量(config.json)或硬编码值加载
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

_prompt_for_interval() {
    local current_val="${1:-300}"
    local prompt_text="${2:-请输入检查间隔}"
    local human_readable_current
    human_readable_current=$(_format_seconds_to_human "$current_val")
    
    local source_info=""
    if [ -f "$CONFIG_FILE" ]; then
        local local_val; local_val=$(grep '^WATCHTOWER_CONFIG_INTERVAL=' "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
        if [ "$local_val" = "$current_val" ]; then
            source_info="${CYAN} (来自本地配置)${NC}"
        fi
    fi
    if [ -z "$source_info" ]; then
         source_info="${CYAN} (来自 config.json)${NC}"
    fi

    # 使用 echo -ne 打印带颜色的提示，避免转义符泄露
    echo -ne "$prompt_text (例如: 5m, 2h, 1d), 当前: ${human_readable_current}${source_info}: "
    read -r user_input < /dev/tty
    user_input=$(echo "$user_input" | tr '[:upper:]' '[:lower:]' | xargs)
    
    if [ -z "$user_input" ]; then
        echo "$current_val"
        return
    fi
    
    local num; num=$(echo "$user_input" | sed 's/[^0-9]*//g')
    local unit; unit=$(echo "$user_input" | sed 's/[0-9]*//g')
    
    if [ -z "$num" ]; then
        log_warn "无效输入, 使用当前值: $human_readable_current"
        echo "$current_val"
        return
    fi
    
    case "$unit" in
        d|day|days) echo $((num * 86400)) ;;
        h|hour|hours) echo $((num * 3600)) ;;
        m|min|minute|minutes) echo $((num * 60)) ;;
        s|sec|second|seconds|*) echo "$num" ;;
    esac
}

send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data="{\"chat_id\":\"${TG_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"Markdown\"}"
        curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url" &
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
    if [ -z "$logs" ]; then echo ""; return 1; fi
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
    local int="$1"
    local logs="$2"
    if [ -z "$int" ] || [ -z "$logs" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local log_line ts epoch rem
    log_line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)

    if [ -z "$log_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    ts=$(_parse_watchtower_timestamp_from_log_line "$log_line")
    epoch=$(_date_to_epoch "$ts")

    if [ "$epoch" -gt 0 ]; then
        if [[ "$log_line" == *"Session done"* ]]; then
            rem=$((int - ($(date +%s) - epoch) ))
        elif [[ "$log_line" == *"Scheduling first run"* ]]; then
            rem=$((epoch - $(date +%s)))
        elif [[ "$log_line" == *"Starting Watchtower"* ]]; then
            echo -e "${YELLOW}等待首次调度...${NC}"; return;
        fi

        if [ "$rem" -gt 0 ]; then
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" $((rem / 3600)) $(((rem % 3600) / 60)) $((rem % 60)) "$NC"
        else
            local overdue=$(( -rem ))
            printf "%b已逾期 %02d分%02d秒, 正在等待...%b" "$YELLOW" $((overdue / 60)) $((overdue % 60)) "$NC"
        fi
    else
        echo -e "${YELLOW}计算中...${NC}"
    fi
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

_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2"
    local docker_run_args=(-e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_image="containrrr/watchtower"; local wt_args=("--cleanup"); local container_names=()
    if [ "$mode_description" = "一次性更新" ]; then
        docker_run_args+=(--rm --name watchtower-once); wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name watchtower --restart unless-stopped); wt_args+=(--interval "${wt_interval:-300}")
    fi
    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    local template_temp_file=""
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        log_info "✅ 检测到 Telegram 配置，将为 Watchtower 启用通知。"
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&ParseMode=Markdown")
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            docker_run_args+=(-e WATCHTOWER_REPORT_NO_UPDATES=true); log_info "✅ 将启用 '无更新也通知' 模式。"
        else log_info "ℹ️ 将启用 '仅有更新才通知' 模式。"; fi
        cat <<'EOF' > "/tmp/watchtower_notification_template.$$.gohtml"
🐳 *Docker 容器更新报告*
*服务器:* `{{.Host}}`
{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*
{{range .Updated}}- 🔄 *{{.Name}}*
  🖼️ *镜像:* `{{.ImageName}}`
  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}
⏰ *时间:* `{{.Time.Format "2006-01-02 15:04:05"}}`
EOF
        template_temp_file="/tmp/watchtower_notification_template.$$.gohtml"; chmod 644 "$template_temp_file"
        docker_run_args+=(-v "${template_temp_file}:/etc/watchtower/notification.gohtml:ro"); docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE_FILE=/etc/watchtower/notification.gohtml")
    fi
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; local included_containers
    if [ -n "$final_exclude_list" ]; then
        log_info "发现排除规则: ${final_exclude_list}"
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        included_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ -n "$included_containers" ]; then log_info "计算后的监控范围: ${included_containers}"; read -r -a container_names <<< "$included_containers"; else log_warn "排除规则导致监控列表为空！"; fi
    else log_info "未发现排除规则，Watchtower 将监控所有容器。"; fi
    echo "⬇️ 正在拉取 Watchtower 镜像..."; set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    _print_header "正在启动 $mode_description"
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    local final_cmd_str=""; for arg in "${final_command_to_run[@]}"; do final_cmd_str+=" $(printf %q "$arg")"; done
    echo -e "${CYAN}执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo ${final_cmd_str}${NC}"
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
    if [ -n "$template_temp_file" ] && [ -f "$template_temp_file" ]; then rm -f "$template_temp_file" 2>/dev/null || true; fi
    if [ "$mode_description" = "一次性更新" ]; then
        if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi; return $rc
    else
        sleep 3; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; fi; return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."; set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    local interval="${WATCHTOWER_CONFIG_INTERVAL}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower模式"; then
        log_err "Watchtower 重建失败！"; WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
    send_notify "🔄 Watchtower 服务已重建并启动。"; log_success "Watchtower 重建成功。"
}

_prompt_and_rebuild_watchtower_if_needed() {
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then
        if confirm_action "配置已更新，是否立即重建 Watchtower 以应用新配置?"; then _rebuild_watchtower; else log_warn "操作已取消。新配置将在下次手动重建 Watchtower 后生效。"; fi
    fi
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then log_info "操作已取消。"; return 1; fi
    echo -e "${YELLOW}🆕 运行一次 Watchtower${NC}"
    if ! _start_watchtower_container_logic "" "一次性更新"; then return 1; fi
    return 0
}

_configure_telegram() {
    read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT < /dev/tty; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"
    read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT < /dev/tty; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"
    read -r -p "是否在没有容器更新时也发送 Telegram 通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " notify_on_no_updates_choice < /dev/tty
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    log_info "Telegram 配置已更新。"
}

_configure_email() {
    read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT < /dev/tty; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi
        local -a items_array=("1. › 配置 Telegram│$tg_status, 无更新也通知: $notify_on_no_updates_status" "2. › 配置 Email│$email_status" "3. › 发送测试通知" "4. › 清空所有通知配置")
        _render_menu "⚙️ 通知配置 ⚙️" "${items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) _configure_telegram; save_config; _prompt_and_rebuild_watchtower_if_needed; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [ -z "$TG_BOT_TOKEN" ] && [ -z "$EMAIL_TO" ]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} 的*测试消息*。"; log_info "测试通知已发送。请检查你的 Telegram 或邮箱。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "所有通知配置已清空。"; _prompt_and_rebuild_watchtower_if_needed; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

show_container_info() { 
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; local -a content_lines_array=()
        content_lines_array+=("编号│名称│镜像│状态")
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
            content_lines_array+=("$i│$name│$image│$status_colored")
            i=$((i + 1))
        done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        
        content_lines_array+=("")
        content_lines_array+=("a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in 
            "") return ;;
            a|A) if confirm_action "确定要启动所有已停止的容器吗?"; then log_info "正在启动..."; local stopped_containers; stopped_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -aq -f status=exited); if [ -n "$stopped_containers" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker start $stopped_containers &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            s|S) if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then log_info "正在停止..."; local running_containers; running_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -q); if [ -n "$running_containers" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop $running_containers &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then log_warn "无效输入或编号超范围。"; sleep 1; continue; fi
                local selected_container="${containers[$((choice - 1))]}"; if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
                local -a action_items_array=("1. › 查看日志 (Logs)" "2. › 重启 (Restart)" "3. › 停止 (Stop)" "4. › 删除 (Remove)" "5. › 查看详情 (Inspect)" "6. › 进入容器 (Exec)"); _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " action < /dev/tty
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

configure_exclusion_list() {
    declare -A excluded_map; local initial_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$initial_exclude_list" ]; then local IFS=,; for container_name in $initial_exclude_list; do container_name=$(echo "$container_name" | xargs); if [ -n "$container_name" ]; then excluded_map["$container_name"]=1; fi; done; unset IFS; fi
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; local -a all_containers_array=(); while IFS= read -r line; do all_containers_array+=("$line"); done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}'); local -a items_array=(); local i=0
        while [ $i -lt ${#all_containers_array[@]} ]; do local container="${all_containers_array[$i]}"; local is_excluded=" "; if [ -n "${excluded_map[$container]+_}" ]; then is_excluded="✔"; fi; items_array+=("$((i + 1)). [${GREEN}${is_excluded}${NC}] $container"); i=$((i + 1)); done
        items_array+=("")
        local current_excluded_display="无"
        if [ ${#excluded_map[@]} -gt 0 ]; then
            local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; current_excluded_display="${keys[*]}"; IFS="$old_ifs"
        fi
        items_array+=("${CYAN}当前排除: ${current_excluded_display}${NC}")
        _render_menu "配置排除列表" "${items_array[@]}"; read -r -p " └──> 输入数字(可用','分隔)切换, 'c'确认, [回车]清空: " choice < /dev/tty
        case "$choice" in
            c|C) break ;;
            "") excluded_map=(); log_info "已清空排除列表。"; sleep 1.5; break ;;
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

configure_watchtower(){
    # 修复：移除 _print_header，避免空行和提示符消失
    log_info "🚀 Watchtower 配置"
    local current_interval_for_prompt="${WATCHTOWER_CONFIG_INTERVAL}"
    
    # 修复：直接捕获 _prompt_for_interval 的返回值
    local WT_INTERVAL_TMP
    WT_INTERVAL_TMP="$(_prompt_for_interval "$current_interval_for_prompt" "请输入检查间隔")"
    
    log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"
    sleep 1
    
    configure_exclusion_list
    read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice < /dev/tty; local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then read -r -p "请输入额外参数: " temp_extra_args < /dev/tty; fi
    read -r -p "是否启用调试模式? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " debug_choice < /dev/tty; local temp_debug_enabled="false"
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi
    local final_exclude_list_display="${WATCHTOWER_EXCLUDE_LIST:-无}"
    local -a confirm_array=("检查间隔│$(_format_seconds_to_human "$WT_INTERVAL_TMP")" "排除列表│${final_exclude_list_display//,/, }" "额外参数│${temp_extra_args:-无}" "调试模式│$temp_debug_enabled")
    _render_menu "配置确认" "${confirm_array[@]}"; read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice < /dev/tty
    if echo "$confirm_choice" | grep -qE '^[Nn]$'; then log_info "操作已取消。"; return 10; fi
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"; WATCHTOWER_ENABLED="true"; save_config
    _rebuild_watchtower || return 1; return 0
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a items_array=("1. › 停止/移除 Watchtower" "2. › 重建 Watchtower")
        _render_menu "⚙️ 任务管理 ⚙️" "${items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定移除 Watchtower？"; then 
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
                    _rebuild_watchtower
                else 
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue
                ;;
            "") return ;; 
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local title="📊 Watchtower 详情与管理 📊"; local interval raw_logs countdown updates
        
        set +e
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        set -e
        
        countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        local -a content_lines_array=("上次活动:│$(get_last_session_time || echo 'N/A')" "下次检查:│$countdown" "" "最近 24h 摘要：")
        updates=$(get_updates_last_24h || true)
        if [ -z "$updates" ]; then content_lines_array+=("  无日志事件。"); else while IFS= read -r line; do content_lines_array+=("  $(_format_and_highlight_log_line "$line")"); done <<< "$updates"; fi
        _render_menu "$title" "${content_lines_array[@]}"; read -r -p " └──> [1] 实时日志, [2] 容器管理, [3] 触发扫描, [Enter] 返回: " pick < /dev/tty
        case "$pick" in
            1) if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo -e "\n按 Ctrl+C 停止..."; trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 200 -f watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue; else echo -e "\n${RED}Watchtower 未运行。${NC}"; press_enter_to_continue; fi ;;
            2) show_container_info ;;
            3) if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then log_info "正在发送 SIGHUP 信号以触发扫描..."; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker kill -s SIGHUP watchtower; then log_success "信号已发送！请在下方查看实时日志..."; echo -e "按 Ctrl+C 停止..."; sleep 2; trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; else log_err "发送信号失败！"; fi; else log_warn "Watchtower 未运行，无法触发扫描。"; fi; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

view_and_edit_config(){
    local -a config_items=("TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "排除列表|WATCHTOWER_EXCLUDE_LIST|string_list" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval" "Watchtower 启用状态|WATCHTOWER_ENABLED|bool" "Cron 执行小时|CRON_HOUR|number_range|0-23" "Cron 项目目录|DOCKER_COMPOSE_PROJECT_DIR_CRON|string" "Cron 任务启用状态|CRON_TASK_ENABLED|bool" "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool")
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config; local -a content_lines_array=(); local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"; local label; label=$(echo "$item" | cut -d'|' -f1); local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3); local extra; extra=$(echo "$item" | cut -d'|' -f4); local current_value="${!var_name}"; local display_text=""; local color="${CYAN}"
            case "$type" in
                string) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
                string_list) if [ -n "$current_value" ]; then color="${YELLOW}"; display_text="${current_value//,/, }"; else color="${CYAN}"; display_text="无"; fi ;;
                bool) if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi ;;
                interval) display_text=$(_format_seconds_to_human "$current_value"); if [ "$display_text" != "N/A" ] && [ -n "$current_value" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi ;;
                number_range) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
            esac
            content_lines_array+=("$(printf "%2d. %s" "$((i + 1))" "$label")│${color}${display_text}${NC}")
        done
        _render_menu "⚙️ 配置查看与编辑 (底层) ⚙️" "${content_lines_array[@]}"; read -r -p " └──> 输入编号编辑, 或按 Enter 返回: " choice < /dev/tty
        if [ -z "$choice" ]; then return; fi
        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then log_warn "无效选项。"; sleep 1; continue; fi
        local selected_index=$((choice - 1)); local selected_item="${config_items[$selected_index]}"; local label; label=$(echo "$selected_item" | cut -d'|' -f1); local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2); local type; type=$(echo "$selected_item" | cut -d'|' -f3); local extra; extra=$(echo "$selected_item" | cut -d'|' -f4); local current_value="${!var_name}"; local new_value=""
        case "$type" in
            string|string_list) read -r -p "请输入新的 '$label' (当前: $current_value): " new_value < /dev/tty; declare "$var_name"="${new_value:-$current_value}" ;;
            bool) read -r -p "是否启用 '$label'? (y/N, 当前: $current_value): " new_value < /dev/tty; if echo "$new_value" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi ;;
            interval) new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔"); if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi ;;
            number_range)
                local min; min=$(echo "$extra" | cut -d'-' -f1); local max; max=$(echo "$extra" | cut -d'-' -f2)
                while true; do read -r -p "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " new_value < /dev/tty; if [ -z "$new_value" ]; then break; fi; if echo "$new_value" | grep -qE '^[0-9]+$' && [ "$new_value" -ge "$min" ] && [ "$new_value" -le "$max" ]; then declare "$var_name"="$new_value"; break; else log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"; fi; done ;;
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
        local FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-无}"; local NOTIFY_STATUS=""; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi
        if [ -n "$EMAIL_TO" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS (无更新也通知)"; else NOTIFY_STATUS="(无更新也通知)"; fi; fi
        local header_text="Watchtower 管理"
        local -a content_array=(
            "🕝 Watchtower 状态:│${STATUS_COLOR} (名称排除模式)" 
            "⏳ 下次检查:│${COUNTDOWN}" 
            "📦 容器概览:│总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        if [ "$FINAL_EXCLUDE_LIST" != "无" ]; then content_array+=("🚫 排 除 列 表 :│${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC}"); fi
        if [ -n "$NOTIFY_STATUS" ]; then content_array+=("🔔 通 知 已 启 用 :│${GREEN}${NOTIFY_STATUS}${NC}"); fi
        content_array+=("" "主菜单：" "1. › 配 置  Watchtower" "2. › 配 置 通 知" "3. › 任 务 管 理" "4. › 查 看 /编 辑 配 置  (底 层 )" "5. › 手 动 更 新 所 有 容 器" "6. › 详 情 与 管 理")
        _render_menu "$header_text" "${content_array[@]}"; read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) view_and_edit_config ;;
          5) run_watchtower_once; press_enter_to_continue ;;
          6) show_watchtower_details ;;
          "") exit 10 ;;
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    log_info "欢迎使用 Watchtower 模块 ${SCRIPT_VERSION}"
    if [ "${1:-}" = "--run-once" ]; then run_watchtower_once; exit $?; fi
    main_menu
    exit 10
}

main "$@"
