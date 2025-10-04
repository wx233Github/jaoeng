#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.5.8 - 全面重构健壮性版本)
# - 将所有易错的单行函数重构为多行，彻底解决运行时错误
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.5.8"

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
WT_EXCLUDE_CONTAINERS_FROM_CONFIG="${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_CONF_DEFAULT_INTERVAL="${WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"
WT_CONF_DEFAULT_CRON_HOUR="${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"
WT_CONF_ENABLE_REPORT="${WATCHTOWER_CONF_ENABLE_REPORT:-true}"
CONFIG_FILE="/etc/docker-auto-update.conf"
if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE" &>/dev/null || true
fi
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-4}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"

# --- 模块专属函数 (全面重构) ---

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
        if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then
            log_info "操作已取消."
            return 1
        fi
        cmd_base+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        cmd_base+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi
    cmd_base+=(-v /var/run/docker.sock:/var/run/docker.sock)

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}?parse_mode=Markdown")
        if [ "${WT_CONF_ENABLE_REPORT}" = "true" ]; then
            cmd_base+=(-e WATCHTOWER_REPORT=true)
        fi
        local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Report.Time.Format "2006-01-02 15:04:05"}}`'
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

_prompt_and_restart_watchtower_if_needed() {
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        if confirm_action "配置已更新，是否立即重启 Watchtower 以应用新配置?"; then
            log_info "正在重启 Watchtower..."
            if docker restart watchtower; then
                send_notify "🔄 Watchtower 服务已因配置变更而重启。"
                log_success "Watchtower 重启成功。"
            else
                log_err "Watchtower 重启失败！"
            fi
        else
            log_warn "操作已取消。新配置将在下次手动重启或重开 Watchtower 后生效。"
        fi
    fi
}

_configure_telegram() {
    read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"
    read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT
    TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"
    log_info "Telegram 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local -a items_array=("  1. › 配置 Telegram  ($tg_status)" "  2. › 配置 Email      ($email_status)" "  3. › 发送测试通知" "  4. › 清空所有通知配置")
        _render_menu "⚙️ 通知配置 ⚙️" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; _prompt_and_restart_watchtower_if_needed; press_enter_to_continue ;;
            2) log_warn "Email 功能暂未实现。"; press_enter_to_continue ;; # Simplified
            3) if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_warn "请先配置 Telegram 通知。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${SCRIPT_VERSION} 的*测试消息*。"; log_info "测试通知已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; _prompt_and_restart_watchtower_if_needed; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

_parse_watchtower_timestamp_from_log_line() {
    local log_line="$1"
    local timestamp
    timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi
    timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true)
    if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi
    timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi
    echo ""
    return 1
}

_date_to_epoch() {
    local dt="$1"
    [ -z "$dt" ] && echo "" && return
    if date -d "now" >/dev/null 2>&1; then
        date -d "$dt" +%s 2>/dev/null || echo ""
    elif command -v gdate >/dev/null 2>&1; then
        gdate -d "$dt" +%s 2>/dev/null || echo ""
    else
        echo ""
    fi
}

show_container_info() { 
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a content_lines_array=()
        local header_line
        header_line=$(printf "%-5s %-25s %-45s %-20s" "编号" "名称" "镜像" "状态")
        content_lines_array+=("$header_line")
        local -a containers=()
        local i=1
        while IFS='|' read -r name image status; do 
            containers+=("$name")
            local status_colored="$status"
            if echo "$status" | grep -qE '^Up'; then status_colored="${GREEN}运行中${NC}"; elif echo "$status" | grep -qE '^Exited|Created'; then status_colored="${RED}已退出${NC}"; else status_colored="${YELLOW}${status}${NC}"; fi
            content_lines_array+=("$(printf "%-5s %-25.25s %-45.45s %b" "$i" "$name" "$image" "$status_colored")")
            i=$((i + 1))
        done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        content_lines_array+=("")
        content_lines_array+=(" a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice
        case "$choice" in 
            "") return ;;
            a|A) if confirm_action "确定要启动所有已停止的容器吗?"; then log_info "正在启动..."; docker start $(docker ps -aq -f status=exited) &>/dev/null || true; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; 
            s|S) if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then log_info "正在停止..."; docker stop $(docker ps -q) &>/dev/null || true; log_success "操作完成。"; else log_info "操作已取消。"; fi ;; 
            *) 
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
                    log_warn "无效输入或编号超范围。"
                    sleep 1
                    continue
                fi
                local selected_container="${containers[$((choice - 1))]}"
                if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
                local -a action_items_array=("  1. › 查看日志 (Logs)" "  2. › 重启 (Restart)" "  3. › 停止 (Stop)" "  4. › 删除 (Remove)" "  5. › 查看详情 (Inspect)" "  6. › 进入容器 (Exec)")
                _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"
                read -r -p " └──> 请选择, 或按 Enter 返回: " action
                case "$action" in 
                   1) echo -e "${YELLOW}日志 (Ctrl+C 停止)...${NC}"; trap '' INT; docker logs -f --tail 100 "$selected_container" || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue ;;
                   2) echo "重启中..."; if docker restart "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi; sleep 1 ;; 
                   3) echo "停止中..."; if docker stop "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi; sleep 1 ;; 
                   4) if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then echo "删除中..."; if docker rm -f "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi; sleep 1; else echo "已取消。"; fi ;; 
                   5) _print_header "容器详情: ${selected_container}"; (docker inspect "$selected_container" | jq '.' 2>/dev/null || docker inspect "$selected_container") | less -R; ;; 
                   6) if [ "$(docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]; then log_warn "容器未在运行，无法进入。"; else log_info "尝试进入容器... (输入 'exit' 退出)"; docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true; fi; press_enter_to_continue ;; 
                   *) ;; 
               esac ;;
        esac
    done
}

# --- [重构区] 以下是为解决运行时错误而重构的函数 ---

get_watchtower_all_raw_logs() {
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 1
    fi
    docker logs --tail 2000 watchtower 2>&1 || true
}

get_watchtower_inspect_summary() {
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 1
    fi
    local cmd
    cmd=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    
    if command -v jq >/dev/null 2>&1; then
        echo "$cmd" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true
    else
        # Fallback for no jq
        local tokens; read -r -a tokens <<< "$(echo "$cmd" | tr -d '[],"')"
        local prev_token=""
        for token in "${tokens[@]}"; do
            if [ "$prev_token" = "--interval" ]; then
                echo "$token" | sed 's/[^0-9].*$//; s/[^0-9]*//g'
                return
            fi
            prev_token="$token"
        done
    fi
}

get_last_session_time() {
    local logs
    logs=$(get_watchtower_all_raw_logs)
    if [ -z "$logs" ]; then echo "N/A"; return 1; fi
    
    if echo "$logs" | grep -qiE "permission denied|cannot connect"; then
        echo -e "${RED}错误:权限不足${NC}"
        return 1
    fi
    
    local last_event_line
    last_event_line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    
    if [ -n "$last_event_line" ]; then
        local ts
        ts=$(_parse_watchtower_timestamp_from_log_line "$last_event_line")
        if [ -n "$ts" ]; then
            echo "$ts"
            return 0
        fi
    fi
    echo "未检测到"
    return 1
}

_get_watchtower_remaining_time() {
    local int="$1"
    local logs="$2"
    if [ -z "$int" ] || [ -z "$logs" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local log_line
    log_line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    if [ -z "$log_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    local ts epoch rem
    ts=$(_parse_watchtower_timestamp_from_log_line "$log_line")
    epoch=$(_date_to_epoch "$ts")

    if [ -z "$epoch" ] || [ "$epoch" -eq 0 ]; then
        echo -e "${YELLOW}计算中...${NC}"
        return
    fi
    
    if [[ "$log_line" == *"Session done"* ]]; then
        rem=$((int - ($(date +%s) - epoch) ))
    elif [[ "$log_line" == *"Scheduling first run"* ]]; then
        rem=$((epoch - $(date +%s)))
    elif [[ "$log_line" == *"Starting Watchtower"* ]]; then
        rem=$(( (epoch + 5 + int) - $(date +%s) ))
    else
        rem=-1 # Should not happen
    fi

    if [ "$rem" -gt 0 ]; then
        printf "%b%02d时%02d分%02d秒%b" "$GREEN" $((rem / 3600)) $(((rem % 3600) / 60)) $((rem % 60)) "$NC"
    else
        printf "%b即将进行%b" "$GREEN" "$NC"
    fi
}

get_updates_last_24h() {
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then return 1; fi
    
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
    
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|permission denied|cannot connect|Could not do a head request" || true
}

_format_and_highlight_log_line() {
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
            if echo "$line" | grep -qiE "\b(unauthorized|failed|error)\b|permission denied|cannot connect|Could not do a head request"; then
                local msg
                msg=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p')
                if [ -z "$msg" ]; then
                    msg=$(echo "$line" | sed -E 's/.*(level=(error|warn|info)|time="[^"]*")\s*//g')
                fi
                printf "%s %b%s%b\n" "$ts" "$RED" "❌ 错误: ${msg:-$line}" "$NC"
            fi
            ;;
    esac
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
            "上次活动: $(get_last_session_time)"
            "下次检查: $countdown"
            ""
            "最近 24h 摘要："
        )
        
        updates=$(get_updates_last_24h)
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
                        echo -e "按 Ctrl+C 停止..."
                        sleep 2
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

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        
        local STATUS_RAW="未运行"
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
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
            FINAL_EXCLUDE_SOURCE="脚本"
        elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then
            FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"
            FINAL_EXCLUDE_SOURCE="config.json"
        fi
        
        local NOTIFY_STATUS=""
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi
        if [ -n "$EMAIL_TO" ]; then
            if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi
        fi
        
        local header_text="Docker 助手 v${SCRIPT_VERSION}"
        
        local -a content_array=(
            " 🕝 Watchtower 状态: ${STATUS_COLOR} (名称排除模式)"
            " ⏳ 下次检查: ${COUNTDOWN}"
            " 📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        if [ -n "$FINAL_EXCLUDE_LIST" ]; then content_array+=(" 🚫 排除列表: ${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC} (${CYAN}${FINAL_EXCLUDE_SOURCE}${NC})"); fi
        if [ -n "$NOTIFY_STATUS" ]; then content_array+=(" 🔔 通知已启用: ${GREEN}${NOTIFY_STATUS}${NC}"); fi
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
