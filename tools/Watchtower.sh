# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.4.3-修复Read退出码)
# - BUG修复: 修复 heredoc 读取变量时因 EOF 返回码导致脚本中断的问题 (代码: 1)。
# - 稳定性: 确保在 set -e 模式下模板变量能正确赋值。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.4.3"

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

# 预加载一次配置
load_config

# --- 依赖检查 ---
if ! command -v docker &> /dev/null; then
    log_err "Docker 未安装。此模块需要 Docker 才能运行。"
    exit 10
fi

# jq 仍需保留用于“发送测试通知”功能
if [ -n "$TG_BOT_TOKEN" ] && ! command -v jq &> /dev/null; then
    log_warn "建议安装 'jq' 以便使用脚本内的'发送测试通知'功能。"
fi

# --- Docker 服务状态检查 ---
if ! docker info >/dev/null 2>&1; then
    log_err "无法连接到 Docker 服务 (daemon)。请确保 Docker 正在运行。"
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

# 仅用于手动测试按钮
send_test_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        if ! command -v jq &>/dev/null; then log_err "缺少 jq，无法发送测试通知。"; return; fi
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data
        data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" \
            '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        timeout 10s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url"
    fi
}

_prompt_for_interval() {
    local default_interval_seconds="$1"
    local prompt_message="$2"
    local input_value
    local current_display_value="$(_format_seconds_to_human "$default_interval_seconds")"

    while true; do
        input_value=$(_prompt_user_input "${prompt_message} (例如: 3600, 1h, 30m, 1d, 当前: ${current_display_value}): " "")
        
        if [ -z "$input_value" ]; then
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
            log_warn "无效格式。"
            continue
        fi

        if [ "$seconds" -gt 0 ]; then
            echo "$seconds"
            return 0
        else
            log_warn "间隔必须是正数。"
        fi
    done
}

# --- 核心启动逻辑 ---
_start_watchtower_container_logic(){
    load_config

    local wt_interval="$1"
    local mode_description="$2"
    local interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower"
    local container_names=()
    local docker_run_args=(-e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_args=("--cleanup")

    # 1. 配置原生通知环境变量
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        
        local template_content
        local show_no_updates="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"

        # 关键修正：添加 || true 以防止 set -e 在 read 读到 EOF 时退出
        read -r -d '' template_content <<EOF || true
{{- if .Entries -}}
🚀 *新版本已部署!*
节点: \`{{ .Title }}\`

📝 *变更日志:*
{{- range .Entries }}
• {{ .Message }}
{{- end }}

{{- else if eq "${show_no_updates}" "true" -}}
✅ *同步检查完成*
节点: \`{{ .Title }}\`
所有服务均为最新。
{{- end -}}
EOF
        
        # 传递环境变量
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATIONS=shoutrrr")
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&preview=false&title=$(hostname)")
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE=$template_content")
        
        # 启用 Report 模式 (每次检查完生成一份报告)
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_REPORT=true")
        
        log_info "✅ Telegram 通知通道已激活"
    else
        log_info "ℹ️ 未配置 Telegram，将不发送通知"
    fi

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
    
    # 处理排除列表
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$final_exclude_list" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then
            log_err "忽略名单导致监控范围为空，服务无法启动。"
            return 1
        fi
        if [ "$interactive_mode" = "false" ]; then log_info "计算后的监控范围: ${container_names[*]}"; fi
    else 
        if [ "$interactive_mode" = "false" ]; then log_info "未发现忽略名单，将监控所有容器。"; fi
    fi

    if [ "$interactive_mode" = "false" ]; then echo "⬇️ 正在拉取 Watchtower 镜像..."; fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    if [ "$interactive_mode" = "false" ]; then _print_header "正在启动 $mode_description"; fi
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "正在执行立即更新扫描... (显示实时日志)"
        log_info "提示：本次扫描的报告将同步发送至 Telegram"
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        log_success "手动更新扫描任务已结束"
        return 0
    else
        if [ "$interactive_mode" = "false" ]; then
            local final_cmd_str=""; for arg in "${final_command_to_run[@]}"; do final_cmd_str+=" $(printf %q "$arg")"; done
            echo -e "${CYAN}执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo ${final_cmd_str}${NC}"
        fi
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
        
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "$mode_description 启动成功"
        else
            log_err "$mode_description 启动失败"
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
    send_test_notify "🔄 服务已重建。这是一条来自脚本的测试通知，实际更新通知将由 Watchtower 直接发送。"
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then log_info "操作已取消。"; return 1; fi
    _start_watchtower_container_logic "" "" true
}

_configure_telegram() {
    local TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN_INPUT=$(_prompt_user_input "请输入 Telegram Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " "$TG_BOT_TOKEN")
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT}"
    local TG_CHAT_ID_INPUT; TG_CHAT_ID_INPUT=$(_prompt_user_input "请输入 Chat ID (当前: ${TG_CHAT_ID}): " "$TG_CHAT_ID")
    TG_CHAT_ID="${TG_CHAT_ID_INPUT}"
    
    local notify_on_no_updates_choice
    notify_on_no_updates_choice=$(_prompt_user_input "是否在没有容器更新时也发送 Telegram 通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " "")
    
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    log_info "Telegram 通知参数已保存，需重建服务生效。"
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
            "3. 发送手动测试通知 (使用 curl)"
            "4. 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-4")
        case "$choice" in
            1) _configure_telegram; save_config; log_warn "💡 修改配置后，请前往'服务运维'菜单重建 Watchtower。"; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_warn "请先配置 Telegram。"; else log_info "正在发送测试..."; send_test_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} の*手动测试消息*。"; log_success "测试请求已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "所有通知配置已清空。"; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

configure_watchtower(){
    local current_interval_for_prompt="${WATCHTOWER_CONFIG_INTERVAL}"
    local WT_INTERVAL_TMP
    WT_INTERVAL_TMP=$(_prompt_for_interval "$current_interval_for_prompt" "请输入检测频率")
    log_info "检测频率已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"
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
    debug_choice=$(_prompt_user_input "是否启用调试日志 (Debug)? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " "")
    local temp_debug_enabled="false"
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi
    
    local final_exclude_list_display="${WATCHTOWER_EXCLUDE_LIST:-无}"
    local -a confirm_array=(
        "检测频率: $(_format_seconds_to_human "$WT_INTERVAL_TMP")" 
        "忽略名单: ${final_exclude_list_display//,/, }" 
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
        items_array+=("${CYAN}当前忽略: ${current_excluded_display}${NC}")
        _render_menu "配置忽略更新的容器" "${items_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "数字" "c,回车")
        case "$choice" in
            c|C) break ;;
            "") 
                excluded_map=()
                log_info "已清空忽略名单。"
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
        local -a items_array=(
            "1. 停止/移除服务" 
            "2. 重建服务 (应用新配置)"
        )
        _render_menu "⚙️ 服务运维 ⚙️" "${items_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-2")
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    if confirm_action "确定移除 Watchtower？"; then 
                        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
                        WATCHTOWER_ENABLED="false"; save_config
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
            "") return ;; 
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

# --- 辅助函数：解析日志时间戳 (仅保留用于详情展示) ---
_parse_watchtower_timestamp_from_log_line() {
    local line="$1"
    local ts
    ts=$(echo "$line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | cut -d'.' -f1 | sed 's/T/ /')
    echo "$ts"
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
    interval=$(echo "$interval" | sed -n 's/[^0-9]//g;p')
    if [ -z "$interval" ]; then echo ""; else echo "$interval"; fi
}

get_watchtower_inspect_summary(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo ""; return 2; fi
    local cmd
    cmd=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    _extract_interval_from_cmd "$cmd" 2>/dev/null || true
}

get_watchtower_all_raw_logs(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo ""; return 1; fi
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 500 watchtower 2>&1 || true
}

_get_watchtower_next_run_time(){
    local interval_seconds="$1"
    local raw_logs="$2"
    
    if [ -z "$raw_logs" ] || [ -z "$interval_seconds" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local last_event_line
    last_event_line=$(echo "$raw_logs" | grep -E "Session done|Scheduling first run" | tail -n 1 || true)

    if [ -z "$last_event_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    local next_epoch=0
    local current_epoch; current_epoch=$(date +%s)

    # 简单估算：最后一次完成时间 + 间隔
    local ts_str
    ts_str=$(_parse_watchtower_timestamp_from_log_line "$last_event_line")
    
    if [ -n "$ts_str" ]; then
        local last_epoch
        if date -d "$ts_str" "+%s" >/dev/null 2>&1; then last_epoch=$(date -d "$ts_str" "+%s"); 
        elif command -v gdate >/dev/null; then last_epoch=$(gdate -d "$ts_str" "+%s"); fi
        
        if [ -n "$last_epoch" ]; then
            next_epoch=$((last_epoch + interval_seconds))
            # 如果计算出的下一次时间已经过去了，说明 Watchtower 正在运行或即将运行
            while [ "$next_epoch" -le "$current_epoch" ]; do
                next_epoch=$((next_epoch + interval_seconds))
            done
            
            local remaining=$((next_epoch - current_epoch))
             local h=$((remaining / 3600)); local m=$(( (remaining % 3600) / 60 )); local s=$(( remaining % 60 ))
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" "$h" "$m" "$s" "$NC"
            return
        fi
    fi
    echo -e "${YELLOW}计算中...${NC}"
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local title="📊 详情与管理 📊"
        local interval raw_logs COUNTDOWN
        
        set +e
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        set -e
        
        COUNTDOWN=$(_get_watchtower_next_run_time "${interval}" "${raw_logs}")
        
        local -a content_lines_array=(
            "⏱️  ${CYAN}当前状态${NC}"
            "    ${YELLOW}下一次扫描倒计时:${NC} ${COUNTDOWN}"
            "" 
            "📜  ${CYAN}最近日志摘要 (最后 5 行)${NC}"
        )
        
        local logs_tail
        logs_tail=$(echo "$raw_logs" | tail -n 5)
        while IFS= read -r line; do
             content_lines_array+=("    ${line:0:80}...")
        done <<< "$logs_tail"
        
        _render_menu "$title" "${content_lines_array[@]}"
        
        read -r -p "$(echo -e "> ${ORANGE}[1]${NC}实时日志 ${ORANGE}[2]${NC}容器看板 ${ORANGE}[3]${NC}触发扫描 (↩ 返回): ")" pick < /dev/tty
        case "$pick" in
            1) if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo -e "\n按 Ctrl+C 停止..."; trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue; else echo -e "\n${RED}Watchtower 未运行。${NC}"; press_enter_to_continue; fi ;;
            2) show_container_info ;;
            3) run_watchtower_once; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

view_and_edit_config(){
    local -a config_items=("TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "忽略名单|WATCHTOWER_EXCLUDE_LIST|string_list" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "检测频率|WATCHTOWER_CONFIG_INTERVAL|interval" "服务启用状态|WATCHTOWER_ENABLED|bool" "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool")
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config; 
        local -a content_lines_array=(); local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"; local label; label=$(echo "$item" | cut -d'|' -f1); local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3); local current_value="${!var_name}"; local display_text=""; local color="${CYAN}"
            case "$type" in
                string) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
                string_list) if [ -n "$current_value" ]; then color="${YELLOW}"; display_text="${current_value//,/, }"; else color="${CYAN}"; display_text="无"; fi ;;
                bool) if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi ;;
                interval) display_text=$(_format_seconds_to_human "$current_value"); if [ "$display_text" != "N/A" ] && [ -n "$current_value" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi ;;
            esac
            content_lines_array+=("$(printf "%2d. %s: %s%s%s" "$((i + 1))" "$label" "$color" "$display_text" "$NC")")
        done
        _render_menu "⚙️ 高级参数编辑器 ⚙️" "${content_lines_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-${#config_items[@]}")
        if [ -z "$choice" ]; then return; fi
        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then log_warn "无效选项。"; sleep 1; continue; fi
        local selected_index=$((choice - 1)); local selected_item="${config_items[$selected_index]}"; local label; label=$(echo "$selected_item" | cut -d'|' -f1); local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2); local type; type=$(echo "$selected_item" | cut -d'|' -f3); local current_value="${!var_name}"; local new_value=""
        
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
        _render_menu "📋 容器看板 📋" "${content_array[@]}"
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
        local COUNTDOWN=$(_get_watchtower_next_run_time "${interval}" "${raw_logs}")
        local TOTAL; TOTAL=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l || echo "0")
        local RUNNING; RUNNING=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.ID}}' 2>/dev/null | wc -l || echo "0"); local STOPPED=$((TOTAL - RUNNING))
        
        local notify_mode="${CYAN}关闭${NC}"
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            notify_mode="${GREEN}Telegram${NC}"
        fi
        
        local header_text="Watchtower 自动更新管理器"
        
        local -a content_array=(
            "🕝 服务运行状态: ${STATUS_COLOR}" 
            "🔔 消息通知渠道: ${notify_mode}"
            "⏳ 下一次扫描倒计时: ${COUNTDOWN}" 
            "📦 受控容器统计: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        
        content_array+=("" "主菜单：" 
            "1. 部署/重新配置服务 (核心设置)" 
            "2. 通知参数设置 (Token/ID)" 
            "3. 服务运维 (停止/重建/卸载)" 
            "4. 高级参数编辑器" 
            "5. 实时日志与容器看板"
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
    # 原生通知模式下不需要 --monitor 参数，
    # 但保留 --run-once 供其他脚本调用
    case "${1:-}" in
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
