#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.6.10 - config.json默认值适配)
# - [更新] 适配 config.json 中 notify_on_no_updates 默认设置为 true
# - [修正] 彻底移除对 WATCHTOWER_REPORT=true 相关配置的引用
# - [更新] 确保本地保存的配置 (config.conf) 优先级高于 config.json
# - [优化] 优化日志截断，确保UI内容不会撑爆
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.10" # 版本更新

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    log_err() { echo "[错误] $*" >&2; }
    log_err "致命错误: 通用工具函数库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 脚本依赖检查 ---
if ! command -v docker >/dev/null 2>&1; then log_err "❌ 错误: 未检测到 'docker' 命令。"; exit 1; fi
if ! docker ps -q >/dev/null 2>&1; then log_err "❌ 错误:无法连接到 Docker。"; exit 1; fi

# --- 配置加载 ---
# 从 config.json 加载的默认值 (通过 install.sh 传递的环境变量)
WT_EXCLUDE_CONTAINERS_FROM_CONFIG="${JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_CONF_DEFAULT_INTERVAL="${JB_WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"
WT_CONF_DEFAULT_CRON_HOUR="${JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"
# JB_WATCHTOWER_CONF_ENABLE_REPORT 已从 config.json 移除，因此不再引用

CONFIG_FILE="/etc/docker-auto-update.conf"
if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# 初始化变量，先从 config.json 提供的默认值 (通过 JB_ 前缀的环境变量)
TG_BOT_TOKEN="${JB_WATCHTOWER_CONF_BOT_TOKEN:-}"
TG_CHAT_ID="${JB_WATCHTOWER_CONF_CHAT_ID:-}"
EMAIL_TO="${JB_WATCHTOWER_CONF_EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST="${JB_WATCHTOWER_CONF_EXCLUDE_LIST:-}"
WATCHTOWER_EXTRA_ARGS="${JB_WATCHTOWER_CONF_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${JB_WATCHTOWER_CONF_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${JB_WATCHTOWER_CONF_CONFIG_INTERVAL:-}" # 优先使用 config.json 的默认间隔
WATCHTOWER_ENABLED="${JB_WATCHTOWER_CONF_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${JB_WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${JB_WATCHTOWER_CONF_CRON_HOUR:-4}"
CRON_TASK_ENABLED="${JB_WATCHTOWER_CONF_TASK_ENABLED:-false}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-false}" # 从 config.json 初始化

# 然后，如果存在本地配置文件，则覆盖上述变量 (优先级更高)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE" &>/dev/null || true
fi

# 确保所有变量都有一个最终的默认值 (如果 config.conf 和 config.json 都没有提供)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL}}" # 最终默认值
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-${WT_CONF_DEFAULT_CRON_HOUR}}" # 最终默认值
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-false}" # 最终默认值


# --- 模块专属函数 ---

send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        (curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "text=${message}" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1) &
    fi
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

_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2"
    local cmd_base=(docker run -e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_image="containrrr/watchtower"
    local wt_args=("--cleanup")
    local container_names=()

    if [ "$mode_description" = "一次性更新" ]; then
        cmd_base+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        cmd_base+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi
    cmd_base+=(-v /var/run/docker.sock:/var/run/docker.sock)

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        log_info "检测到 Telegram 配置，将为 Watchtower 启用通知。"
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&ParseMode=Markdown")
        
        # 根据 WATCHTOWER_NOTIFY_ON_NO_UPDATES 决定是否设置 WATCHTOWER_REPORT_NO_UPDATES
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            cmd_base+=(-e WATCHTOWER_REPORT_NO_UPDATES=true)
            log_info "将启用 '无更新也通知' 模式。"
        else
            log_info "将启用 '有更新才通知' 模式。"
        fi

        # 模板现在只应用于有 .Scanned 字段的总结报告
        local NOTIFICATION_TEMPLATE='{{if .Scanned}}🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失 败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Time.Format "2006-01-02 15:04:05"}}`{{end}}'
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE=${NOTIFICATION_TEMPLATE}")
    fi

    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
        wt_args+=("--debug")
    fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then
        read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"
        wt_args+=("${extra_tokens[@]}")
    fi

    local final_exclude_list=""
    local source_msg=""
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
        final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
        source_msg="脚本内部"
    elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then
        final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"
        source_msg="config.json"
    fi
    
    local included_containers
    if [ -n "$final_exclude_list" ]; then
        log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"
        local exclude_pattern
        exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
        if [ -n "$included_containers" ]; then
            log_info "计算后的监控范围: ${included_containers}"
            read -r -a container_names <<< "$included_containers"
        else
            log_warn "排除规则导致监控列表为空！"
        fi
    else
        log_info "未发现排除规则，Watchtower 将监控所有容器。"
    fi

    echo "⬇️ 正在拉取 Watchtower 镜像..."
    set +e; docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    _print_header "正在启动 $mode_description"
    local final_cmd=("${cmd_base[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    echo -e "${CYAN}执行命令: ${final_cmd[*]}${NC}"
    
    set +e; "${final_cmd[@]}"; local rc=$?; set -e
    
    if [ "$mode_description" = "一次性更新" ]; then
        if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi
        return $rc
    else
        sleep 3
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 以应用新配置..."
    set +e
    docker rm -f watchtower &>/dev/null
    set -e
    
    local interval="${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL}}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower模式"; then
        log_err "Watchtower 重建失败！"
        WATCHTOWER_ENABLED="false"
        save_config
        return 1
    fi
    send_notify "🔄 Watchtower 服务已因配置变更而重建。"
    log_success "Watchtower 重建成功。"
}

_prompt_and_rebuild_watchtower_if_needed() {
    if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        if confirm_action "配置已更新，是否立即重建 Watchtower 以应用新配置?"; then
            _rebuild_watchtower
        else
            log_warn "操作已取消。新配置将在下次手动重建 Watchtower 后生效。"
        fi
    fi
}

_format_and_highlight_log_line(){
    local line="$1"
    local ts
    ts=$(_parse_watchtower_timestamp_from_log_line "$line")
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
            if echo "$line" | grep -qiE "\b(unauthorized|failed|error|fatal)\b|permission denied|cannot connect|Could not do a head request|Notification template error"; then
                local msg
                msg=$(echo "$line" | sed -n 's/.*error="\([^"]*\)".*/\1/p' | tr -d '\n')
                if [ -z "$msg" ] && [[ "$line" == *"msg="* ]]; then # 尝试从msg字段提取，如果不是error
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
            rem=$(( (epoch + 5 + int) - $(date +%s) ))
        fi
        if [ "$rem" -gt 0 ]; then
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" $((rem / 3600)) $(((rem % 3600) / 60)) $((rem % 60)) "$NC"
        else
            local overdue=$(( -rem ))
            printf "%b已超时 %02d分%02d秒, 等待扫描...%b" "$YELLOW" $((overdue / 60)) $((overdue % 60)) "$NC"
        fi
    else
        echo -e "${YELLOW}计算中...${NC}"
    fi
}

_extract_interval_from_cmd(){
    local cmd_json="$1"
    local interval=""
    if command -v jq >/dev/null 2>&1; then
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

get_watchtower_inspect_summary(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 2
    fi
    local cmd
    cmd=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
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
get_updates_last_24h(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
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
        raw_logs=$(docker logs --since "$since" watchtower 2>&1 || true)
    fi
    if [ -z "$raw_logs" ]; then
        raw_logs=$(docker logs --tail 200 watchtower 2>&1 || true)
    fi
    # 增加对 "Notification template error" 的匹配以截断显示
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|fatal|permission denied|cannot connect|Could not do a head request|Notification template error" || true
}
show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local title="📊 Watchtower 详情与管理 📊"
        local interval raw_logs countdown updates
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        local -a content_lines_array=(
            "上次活动: $(get_last_session_time || echo 'N/A')"
            "下次检查: $countdown"
            ""
            "最近 24h 摘要："
        )
        updates=$(get_updates_last_24h || true)
        if [ -z "$updates" ]; then
            content_lines_array+=("  无日志事件。")
        else
            while IFS= read -r line; do
                content_lines_array+=("  $(_format_and_highlight_log_line "$line")")
            done <<< "$updates"
        fi
        _render_menu "$title" "${content_lines_array[@]}"
        read -r -p " └──> [1] 实时日志, [2] 容器管理, [3] 触发扫描, [Enter] 返回: " pick
        case "$pick" in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    echo -e "\n按 Ctrl+C 停止..."
                    trap '' INT
                    docker logs --tail 200 -f watchtower || true
                    trap 'echo -e "\n操作被中断。"; exit 10' INT
                    press_enter_to_continue
                else
                    echo -e "\n${RED}Watchtower 未运行。${NC}"
                    press_enter_to_continue
                fi
                ;;
            2) show_container_info ;;
            3)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    log_info "正在发送 SIGHUP 信号以触发扫描..."
                    if docker kill -s SIGHUP watchtower; then
                        log_success "信号已发送！请在下方查看实时日志..."
                        echo -e "按 Ctrl+C 停止..."; sleep 2
                        trap '' INT
                        docker logs -f --tail 100 watchtower || true
                        trap 'echo -e "\n操作被中断。"; exit 10' INT
                    else
                        log_err "发送信号失败！"
                    fi
                else
                    log_warn "Watchtower 未运行，无法触发扫描。"
                fi
                press_enter_to_continue
                ;;
            *) return ;;
        esac
    done
}
run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then
        log_info "操作已取消."
        return 1
    fi
    echo -e "${YELLOW}🆕 运行一次 Watchtower${NC}"
    if ! _start_watchtower_container_logic "" "一次性更新"; then
        return 1
    fi
    return 0
}
view_and_edit_config(){
    local -a config_items
    config_items=(
        "TG Token|TG_BOT_TOKEN|string"
        "TG Chat ID|TG_CHAT_ID|string"
        "Email|EMAIL_TO|string"
        "额外参数|WATCHTOWER_EXTRA_ARGS|string"
        "调试模式|WATCHTOWER_DEBUG_ENABLED|bool"
        "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval"
        "Watchtower 启用状态|WATCHTOWER_ENABLED|bool"
        "无更新也通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool" # 新增配置项
        "Cron 执行小时|CRON_HOUR|number_range|0-23"
        "Cron 项目目录|DOCKER_COMPOSE_PROJECT_DIR_CRON|string"
        "Cron 任务启用状态|CRON_TASK_ENABLED|bool"
    )
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a content_lines_array=()
        local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"
            local label var_name type current_value display_text color extra
            label=$(echo "$item" | cut -d'|' -f1)
            var_name=$(echo "$item" | cut -d'|' -f2)
            type=$(echo "$item" | cut -d'|' -f3)
            extra=$(echo "$item" | cut -d'|' -f4)
            current_value="${!var_name}"
            display_text=""
            color="${CYAN}"
            case "$type" in
                string) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
                bool) if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi ;;
                interval) display_text=$(_format_seconds_to_human "$current_value"); if [ "$display_text" != "N/A" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi ;;
                number_range) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
            esac
            content_lines_array+=("$(printf " %2d. %-20s: %b%s%b" "$((i + 1))" "$label" "$color" "$display_text" "$NC")")
        done
        _render_menu "⚙️ 配置查看与编辑 ⚙️" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号编辑, 或按 Enter 返回: " choice
        if [ -z "$choice" ]; then return; fi
        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then
            log_warn "无效选项。"
            sleep 1
            continue
        fi
        local selected_index=$((choice - 1))
        local selected_item="${config_items[$selected_index]}"
        label=$(echo "$selected_item" | cut -d'|' -f1)
        var_name=$(echo "$selected_item" | cut -d'|' -f2)
        type=$(echo "$selected_item" | cut -d'|' -f3)
        extra=$(echo "$selected_item" | cut -d'|' -f4)
        current_value="${!var_name}"
        local new_value=""
        case "$type" in
            string)
                read -r -p "请输入新的 '$label' (当前: $current_value): " new_value
                declare "$var_name"="${new_value:-$current_value}"
                ;;
            bool)
                read -r -p "是否启用 '$label'? (y/N): " new_value
                if echo "$new_value" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi
                ;;
            interval)
                new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔")
                if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi
                ;;
            number_range)
                local min max
                min=$(echo "$extra" | cut -d'-' -f1)
                max=$(echo "$extra" | cut -d'-' -f2)
                while true; do
                    read -r -p "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " new_value
                    if [ -z "$new_value" ]; then break; fi
                    if echo "$new_value" | grep -qE '^[0-9]+$' && [ "$new_value" -ge "$min" ] && [ "$new_value" -le "$max" ]; then
                        declare "$var_name"="$new_value"
                        break
                    else
                        log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"
                    fi
                done
                ;;
        esac
        save_config
        log_info "'$label' 已更新."
        sleep 1
    done
}

main_menu(){
    log_info "欢迎使用 容器更新与管理 v${SCRIPT_VERSION}"
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        
        local STATUS_RAW="未运行"
        if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
            STATUS_RAW="已启动"
        fi
        
        local STATUS_COLOR
        if [ "$STATUS_RAW" = "已启动" ]; then
            STATUS_COLOR="${GREEN}已启动${NC}"
        else
            STATUS_COLOR="${RED}未运行${NC}"
        fi
        
        local interval="" raw_logs=""
        if [ "$STATUS_RAW" = "已启动" ]; then
            interval=$(get_watchtower_inspect_summary)
            raw_logs=$(get_watchtower_all_raw_logs)
        fi
        
        local COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        local TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l)
        local RUNNING=$(docker ps --format '{{.ID}}' | wc -l)
        local STOPPED=$((TOTAL - RUNNING))
        
        local FINAL_EXCLUDE_LIST="" FINAL_EXCLUDE_SOURCE=""
        if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
            FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
            SOURCE_MSG_COLOR="${CYAN}脚本${NC}"
            FINAL_EXCLUDE_SOURCE="脚本"
        elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then
            FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"
            SOURCE_MSG_COLOR="${CYAN}config.json${NC}"
            FINAL_EXCLUDE_SOURCE="config.json"
        fi
        
        local NOTIFY_STATUS=""
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            NOTIFY_STATUS="${GREEN}Telegram${NC}"
            if [ "$STATUS_RAW" = "已启动" ]; then
                # 检查是否有任何 "Failed to initialize Shoutrrr" 错误，而不是模板错误
                if docker logs watchtower 2>&1 | grep -q "Failed to initialize Shoutrrr"; then
                    NOTIFY_STATUS="${GREEN}Telegram${NC} ${RED}(未生效)${NC}"
                fi
            fi
        fi
        
        local header_text="容器更新与管理"
        
        local -a content_array=(
            " 🕝 Watchtower 状态: ${STATUS_COLOR} (名称排除模式)"
            " ⏳ 下次检查: ${COUNTDOWN}"
            " 📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        if [ -n "$FINAL_EXCLUDE_LIST" ]; then content_array+=(" 🚫 排除列表: ${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC} (${SOURCE_MSG_COLOR})"); fi
        if [ -n "$NOTIFY_STATUS" ]; then content_array+=(" 🔔 通知已启用: ${NOTIFY_STATUS}"); fi
        content_array+=("" "主菜单：" "  1. › 配置 Watchtower" "  2. › 配置通知" "  3. › 任务管理" "  4. › 查看/编辑配置 (底层)" "  5. › 手动更新所有容器" "  6. › 详情与管理")
        
        _render_menu "$header_text" "${content_array[@]}"
        read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue; ;;
          2) notification_menu; ;;
          3) manage_tasks; ;;
          4) view_and_edit_config; ;;
          5) run_watchtower_once || true; press_enter_to_continue; ;;
          6) show_watchtower_details; ;;
          "") return 10 ;;
          *) log_warn "无效选项。"; sleep 1; ;;
        esac
    done
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    if [ "${1:-}" = "--run-once" ]; then
        run_watchtower_once
        exit $?
    fi
    main_menu
    exit 10
}

main "$@"
