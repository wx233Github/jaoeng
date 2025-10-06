#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.7.8-增加Docker服务状态检查)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.7.8"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    # 如果 utils.sh 未找到，提供一个临时的 log_err 函数以避免脚本立即崩溃
    log_err() { echo "[错误] $*" >&2; }
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
    exit 10 # 以代码10退出，主脚本会将其识别为“正常返回”
fi

# --- 终极修复：增加 Docker 服务 (daemon) 状态检查 ---
if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker info >/dev/null 2>&1; then
    log_err "无法连接到 Docker 服务 (daemon)。"
    log_err "请确保 Docker 正在运行，您可以使用以下命令尝试启动它："
    log_info "  sudo systemctl start docker"
    log_info "  或者"
    log_info "  sudo service docker start"
    exit 10 # 正常退出，返回主菜单
fi


# 本地配置文件路径
CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# --- 模块变量 ---
# 预先声明所有变量，避免潜在的未定义错误
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

# 使用清晰、分步的优先级加载逻辑
load_config(){
    # 优先级 3 (最低): 设置硬编码的后备默认值
    local default_interval="300"
    local default_cron_hour="4"

    # 优先级 2: 从 install.sh 传递的环境变量加载配置
    TG_BOT_TOKEN="${WATCHTOWER_CONF_BOT_TOKEN:-}"
    TG_CHAT_ID="${WATCHTOWER_CONF_CHAT_ID:-}"
    EMAIL_TO="${WATCHTOWER_CONF_EMAIL_TO:-}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_CONF_EXCLUDE_LIST:-}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_CONF_EXTRA_ARGS:-}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_CONF_DEBUG_ENABLED:-false}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONF_CONFIG_INTERVAL:-$default_interval}"
    WATCHTOWER_ENABLED="${WATCHTOWER_CONF_ENABLED:-false}"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON:-}"
    CRON_HOUR="${WATCHTOWER_CONF_CRON_HOUR:-$default_cron_hour}"
    CRON_TASK_ENABLED="${WATCHTOWER_CONF_TASK_ENABLED:-false}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-false}"

    # 优先级 1 (最高): 如果存在本地配置文件，则加载它，覆盖以上所有设置
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" &>/dev/null || true
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

send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        (curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "text=${message}" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1) &
    fi
}

_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2" # 例如 "一次性更新" 或 "Watchtower模式"

    local docker_run_args=(-e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_image="containrrr/watchtower"
    local wt_args=("--cleanup")
    local container_names=()

    if [ "$mode_description" = "一次性更新" ]; then
        docker_run_args+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi
    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)

    local template_temp_file="" # Initialize local variable for template file

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        log_info "✅ 检测到 Telegram 配置，将为 Watchtower 启用通知。"
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&ParseMode=Markdown")
        
        # 修复拼写错误 UPDates -> UPDATES
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            docker_run_args+=(-e WATCHTOWER_REPORT_NO_UPDATES=true)
            log_info "✅ 将启用 '无更新也通知' 模式。"
        else
            log_info "ℹ️ 将启用 '仅有更新才通知' 模式。"
        fi

        # 将 Go Template 模板内容写入一个临时文件
        cat <<'EOF' > "/tmp/watchtower_notification_template.$$.gohtml"
🐳 *Docker 容器更新报告*

*服务器:* `{{.Host}}`

{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*
{{range .Updated}}
- 🔄 *{{.Name}}*
  🖼️ *镜像:* `{{.ImageName}}`
  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}

⏰ *时间:* `{{.Time.Format "2006-01-02 15:04:05"}}`
EOF
        template_temp_file="/tmp/watchtower_notification_template.$$.gohtml"
        chmod 644 "$template_temp_file"
        
        # 将临时文件挂载到容器内部，并通过环境变量指定其路径
        docker_run_args+=(-v "${template_temp_file}:/etc/watchtower/notification.gohtml:ro")
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE_FILE=/etc/watchtower/notification.gohtml")
    fi

    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
        wt_args+=("--debug")
    fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then
        read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"
        wt_args+=("${extra_tokens[@]}")
    fi

    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    
    local included_containers
    if [ -n "$final_exclude_list" ]; then
        log_info "发现排除规则: ${final_exclude_list}"
        local exclude_pattern
        exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        included_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
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
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    _print_header "正在启动 $mode_description"
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    local final_cmd_str=""
    for arg in "${final_command_to_run[@]}"; do
        final_cmd_str+=" $(printf %q "$arg")"
    done
    echo -e "${CYAN}执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo ${final_cmd_str}${NC}"
    
    set +e;
    JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
    local rc=$?
    set -e
    
    if [ -n "$template_temp_file" ] && [ -f "$template_temp_file" ]; then
        rm -f "$template_temp_file" 2>/dev/null || true
    fi

    if [ "$mode_description" = "一次性更新" ]; then
        if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi
        return $rc
    else
        sleep 3
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."
    set +e
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null
    set -e
    
    local interval="${WATCHTOWER_CONFIG_INTERVAL}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower模式"; then
        log_err "Watchtower 重建失败！"
        WATCHTOWER_ENABLED="false"
        save_config
        return 1
    fi
    send_notify "🔄 Watchtower 服务已重建并启动。"
    log_success "Watchtower 重建成功。"
}

_prompt_and_rebuild_watchtower_if_needed() {
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        if confirm_action "配置已更新，是否立即重建 Watchtower 以应用新配置?"; then
            _rebuild_watchtower
        else
            log_warn "操作已取消。新配置将在下次手动重建 Watchtower 后生效。"
        fi
    fi
}

_configure_telegram() {
    read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT < /dev/tty
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"
    read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT < /dev/tty
    TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"
    read -r -p "是否在没有容器更新时也发送 Telegram 通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " notify_on_no_updates_choice < /dev/tty
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then
        WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"
    else 
        WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"
    fi
    log_info "Telegram 配置已更新。"
}

_configure_email() {
    read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT < /dev/tty
    EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"
    log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi

        local -a items_array=(
            "  1. › 配置 Telegram  ($tg_status, 无更新也通知: $notify_on_no_updates_status)"
            "  2. › 配置 Email      ($email_status)"
            "  3. › 发送测试通知"
            "  4. › 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
            1) _configure_telegram; save_config; _prompt_and_rebuild_watchtower_if_needed; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3)
                if [ -z "$TG_BOT_TOKEN" ] && [ -z "$EMAIL_TO" ]; then
                    log_warn "请先配置至少一种通知方式。"
                else
                    log_info "正在发送测试..."
                    send_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} 的*测试消息*。"
                    log_info "测试通知已发送。请检查你的 Telegram 或邮箱。"
                fi
                press_enter_to_continue
                ;;
            4)
                if confirm_action "确定要清空所有通知配置吗?"; then
                    TG_BOT_TOKEN=""
                    TG_CHAT_ID=""
                    EMAIL_TO=""
                    WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"
                    save_config
                    log_info "所有通知配置已清空。"
                    _prompt_and_rebuild_watchtower_if_needed
                else
                    log_info "操作已取消。"
                fi
                press_enter_to_continue
                ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

show_container_info() { 
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a content_lines_array=()
        local header_line; header_line=$(printf "%-5s %-25s %-45s %-20s" "编号" "名称" "镜像" "状态")
        content_lines_array+=("$header_line")
        local -a containers=()
        local i=1
        while IFS='|' read -r name image status; do 
            containers+=("$name")
            local status_colored="$status"
            if echo "$status" | grep -qE '^Up'; then status_colored="${GREEN}运行中${NC}"
            elif echo "$status" | grep -qE '^Exited|Created'; then status_colored="${RED}已退出${NC}"
            else status_colored="${YELLOW}${status}${NC}"; fi
            content_lines_array+=("$(printf "%-5s %-25.25s %-45.45s %b" "$i" "$name" "$image" "$status_colored")")
            i=$((i + 1))
        done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        content_lines_array+=("")
        content_lines_array+=(" a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in 
            "") return ;;
            a|A)
                if confirm_action "确定要启动所有已停止的容器吗?"; then
                    log_info "正在启动..."
                    local stopped_containers; stopped_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -aq -f status=exited)
                    if [ -n "$stopped_containers" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker start $stopped_containers &>/dev/null || true; fi
                    log_success "操作完成。"
                    press_enter_to_continue
                else
                    log_info "操作已取消。"
                fi
                ;; 
            s|S)
                if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then
                    log_info "正在停止..."
                    local running_containers; running_containers=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -q)
                    if [ -n "$running_containers" ]; then JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop $running_containers &>/dev/null || true; fi
                    log_success "操作完成。"
                    press_enter_to_continue
                else
                    log_info "操作已取消。"
                fi
                ;; 
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
                    log_warn "无效输入或编号超范围。"
                    sleep 1
                    continue
                fi
                local selected_container="${containers[$((choice - 1))]}"
                if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
                local -a action_items_array=(
                    "  1. › 查看日志 (Logs)"
                    "  2. › 重启 (Restart)"
                    "  3. › 停止 (Stop)"
                    "  4. › 删除 (Remove)"
                    "  5. › 查看详情 (Inspect)"
                    "  6. › 进入容器 (Exec)"
                )
                _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"
                read -r -p " └──> 请选择, 或按 Enter 返回: " action < /dev/tty
                case "$action" in 
                    1)
                        echo -e "${YELLOW}日志 (Ctrl+C 停止)...${NC}"
                        trap '' INT
                        JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 "$selected_container" || true
                        trap 'echo -e "\n操作被中断。"; exit 10' INT
                        press_enter_to_continue
                        ;;
                    2)
                        echo "重启中..."
                        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker restart "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                        sleep 1
                        ;; 
                    3)
                        echo "停止中..."
                        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                        sleep 1
                        ;; 
                    4)
                        if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then
                            echo "删除中..."
                            if JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                            sleep 1
                        else
                            echo "已取消。"
                        fi
                        ;; 
                    5)
                        _print_header "容器详情: ${selected_container}"
                        (JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect "$selected_container" | jq '.' 2>/dev/null || JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect "$selected_container") | less -R
                        ;; 
                    6)
                        if [ "$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]; then
                            log_warn "容器未在运行，无法进入。"
                        else
                            log_info "尝试进入容器... (输入 'exit' 退出)"
                            JB_SUDO_LOG_QUIET="true" run_with_sudo docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true
                        fi
                        press_enter_to_continue
                        ;; 
                    *) ;; 
                esac
            ;;
        esac
    done
}

# ... [The rest of the script is identical to the previous version and is omitted for brevity] ...
# ... [configure_exclusion_list, configure_watchtower, manage_tasks, and all log/status functions] ...

# --- Main Menu and Execution ---
main_menu(){
    log_info "欢迎使用 Watchtower 模块 ${SCRIPT_VERSION}"

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        load_config # Reload config every time to reflect changes

        local STATUS_RAW="未运行"; 
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${GREEN}已启动${NC}"; else STATUS_COLOR="${RED}未运行${NC}"; fi
        
        local interval=""; local raw_logs="";
        if [ "$STATUS_RAW" = "已启动" ]; then
            interval=$(get_watchtower_inspect_summary)
            raw_logs=$(get_watchtower_all_raw_logs)
        fi
        
        local COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        
        # Robust container counting
        local TOTAL; TOTAL=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l || echo "0")
        local RUNNING; RUNNING=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.ID}}' 2>/dev/null | wc -l || echo "0")
        local STOPPED=$((TOTAL - RUNNING))

        local FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-无}"

        local NOTIFY_STATUS="";
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi
        if [ -n "$EMAIL_TO" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS (无更新也通知)"; else NOTIFY_STATUS="(无更新也通知)"; fi
        fi

        local header_text="Watchtower 管理"
        
        local -a content_array=(
            " 🕝 Watchtower 状态: ${STATUS_COLOR} (名称排除模式)"
            " ⏳ 下次检查: ${COUNTDOWN}"
            " 📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        if [ "$FINAL_EXCLUDE_LIST" != "无" ]; then content_array+=(" 🚫 排 除 列 表 : ${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC}"); fi
        if [ -n "$NOTIFY_STATUS" ]; then content_array+=(" 🔔 通 知 已 启 用 : ${GREEN}${NOTIFY_STATUS}${NC}"); fi
        
        content_array+=(""
            "主菜单："
            "  1. › 配 置  Watchtower"
            "  2. › 配 置 通 知"
            "  3. › 任 务 管 理"
            "  4. › 查 看 /编 辑 配 置  (底 层 )"
            "  5. › 手 动 更 新 所 有 容 器"
            "  6. › 详 情 与 管 理"
        )
        
        _render_menu "$header_text" "${content_array[@]}"
        read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice < /dev/tty
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) view_and_edit_config ;;
          5) run_watchtower_once; press_enter_to_continue ;;
          6) show_watchtower_details ;;
          "") exit 10 ;; # 返回主脚本菜单
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    if [ "${1:-}" = "--run-once" ]; then run_watchtower_once; exit $?; fi
    main_menu
    exit 10 # 退出脚本
}

main "$@"
