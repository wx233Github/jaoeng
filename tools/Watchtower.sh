# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.4.62-通知排版重构版)
# =============================================================
# 作者：系统运维组
# 描述：Docker 容器自动更新管理 (Watchtower) 封装脚本
# 版本历史：
#   v6.4.62 - 重构 Telegram 通知排版；移除冗余终端日志
#   v6.4.61 - 美化 Telegram 通知为 Markdown 格式；移除冗余样式配置
#   ...

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.4.62"

# --- 严格模式与环境设定 ---
set -euo pipefail
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
    _prompt_user_input() { read -r -p "$1" val; echo "${val:-$2}"; }
    _prompt_for_menu_choice() { read -r -p "请选择 [${1}]: " val; echo "$val"; }
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
fi

# --- 确保 run_with_sudo 函数可用 (增强版兜底) ---
if ! declare -f run_with_sudo &>/dev/null; then
    run_with_sudo() {
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        else
            if command -v sudo &>/dev/null; then
                sudo "$@"
            else
                echo "[Error] 需要 root 权限执行此操作，且未找到 sudo 命令。" >&2
                return 1
            fi
        fi
    }
fi

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 本地配置文件路径 (持久化配置)
CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# 运行时环境文件路径
ENV_FILE="${SCRIPT_DIR}/watchtower.env"
# 上一次成功运行的环境文件副本
ENV_FILE_LAST_RUN="${SCRIPT_DIR}/watchtower.env.last_run"

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
WATCHTOWER_HOST_ALIAS=""
# 调度变量
WATCHTOWER_RUN_MODE=""      # "interval", "aligned", "cron"
WATCHTOWER_SCHEDULE_CRON=""

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
    local default_alias
    # 确保 hostname 没有换行符
    local sys_hostname; sys_hostname=$(hostname | tr -d '\n')
    if [ ${#sys_hostname} -gt 15 ]; then default_alias="DockerNode"; else default_alias="$sys_hostname"; fi

    TG_BOT_TOKEN="${TG_BOT_TOKEN-${WATCHTOWER_CONF_BOT_TOKEN-}}"
    TG_CHAT_ID="${TG_CHAT_ID-${WATCHTOWER_CONF_CHAT_ID-}}"
    EMAIL_TO="${EMAIL_TO-${WATCHTOWER_CONF_EMAIL_TO-}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST-${WATCHTOWER_CONF_EXCLUDE_CONTAINERS-$default_exclude_list}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS-${WATCHTOWER_CONF_EXTRA_ARGS-}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${WATCHTOWER_CONF_DEBUG_ENABLED:-false}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONF_DEFAULT_INTERVAL:-$default_interval}}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${WATCHTOWER_CONF_ENABLED:-false}}"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-${WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON:-}}"
    CRON_HOUR="${CRON_HOUR:-${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-$default_cron_hour}}"
    CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-${WATCHTOWER_CONF_TASK_ENABLED:-false}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-$default_notify_on_no_updates}}"
    WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS:-${WATCHTOWER_CONF_HOST_ALIAS:-$default_alias}}"
    
    WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE:-interval}"
    WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON:-}"
}

# 预加载一次配置
load_config

# --- 依赖检查 ---
if ! command -v docker &> /dev/null; then
    log_err "Docker 未安装。此模块需要 Docker 才能运行。"
    exit 10
fi

if [ -n "$TG_BOT_TOKEN" ] && ! command -v jq &> /dev/null; then
    log_warn "建议安装 'jq' 以便使用脚本内的'发送测试通知'功能。"
fi

if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker info >/dev/null 2>&1; then
    log_err "无法连接到 Docker 服务 (daemon)。请确保 Docker 正在运行且当前用户有权访问。"
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
WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS}"
WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE}"
WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}

_print_header() {
    echo -e "\n${BLUE}--- ${1} ---${NC}"
}

_format_seconds_to_human(){
    local total_seconds="$1"
    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]] || [ "$total_seconds" -le 0 ]; then echo "N/A"; return; fi
    local days=$((total_seconds / 86400))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))
    local result=""
    if [ "$days" -gt 0 ]; then result+="${days}天"; fi
    if [ "$hours" -gt 0 ]; then result+="${hours}小时"; fi
    if [ "$minutes" -gt 0 ]; then result+="${minutes}分钟"; fi
    if [ "$seconds" -gt 0 ]; then result+="${seconds}秒"; fi
    echo "${result:-0秒}"
}

# --- Markdown 转义工具 ---
_escape_markdown() {
    # 转义 Markdown (V1) 特殊字符: _ * ` [
    # 使用 sed 确保这些字符在 JSON 字符串或 Telegram 解析中不会出错
    echo "$1" | sed 's/_/\\_/g; s/*/\\*/g; s/`/\\`/g; s/\[/\\[/g'
}

send_test_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        if ! command -v jq &>/dev/null; then log_err "缺少 jq，无法发送测试通知。"; return; fi
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data
        # 强制使用 Markdown 模式
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

# --- 核心：生成环境文件 ---
_generate_env_file() {
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    alias_name=$(echo "$alias_name" | tr -d '\n' | tr -d '\r')
    
    rm -f "$ENV_FILE"

    echo "TZ=${JB_TIMEZONE:-Asia/Shanghai}" >> "$ENV_FILE"
    
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        echo "WATCHTOWER_NOTIFICATIONS=shoutrrr" >> "$ENV_FILE"
        # 使用 Markdown 模式
        echo "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?parsemode=Markdown&preview=false&channels=${TG_CHAT_ID}" >> "$ENV_FILE"
        echo "WATCHTOWER_NOTIFICATION_REPORT=true" >> "$ENV_FILE"
        
        # 使用纯 ASCII 标题
        echo "WATCHTOWER_NOTIFICATION_TITLE=Watchtower-Report" >> "$ENV_FILE"
        echo "WATCHTOWER_NO_STARTUP_MESSAGE=true" >> "$ENV_FILE"

        local br='{{ "\n" }}'
        local tpl=""
        
        # Markdown 美化模板 (重新设计)
        # 逻辑主体
        tpl+="{{if .Entries -}}"
        
        # 有更新的情况
        tpl+="🚀 *Watchtower 更新完成*${br}"
        tpl+="${br}"
        tpl+="📦 *更新列表:*${br}"
        tpl+="{{- range .Entries }}"
        tpl+="• \`{{ .Image }}\`${br}"
        # tpl+="  _{{ .Message }}_${br}" # 移除冗余信息，保持清爽
        tpl+="{{- end }}"
        
        tpl+="{{- else -}}"
        
        # 无更新的情况
        tpl+="✅ *Watchtower 巡检完成*${br}"
        tpl+="${br}"
        tpl+="所有容器均为最新。${br}"
        
        tpl+="{{- end -}}"
        
        # 底部元数据
        tpl+="${br}"
        tpl+="🏷 节点: \`${alias_name}\`"

        echo "WATCHTOWER_NOTIFICATION_TEMPLATE=$tpl" >> "$ENV_FILE"
    fi

    if [[ "$WATCHTOWER_RUN_MODE" == "cron" || "$WATCHTOWER_RUN_MODE" == "aligned" ]] && [ -n "$WATCHTOWER_SCHEDULE_CRON" ]; then
        echo "WATCHTOWER_SCHEDULE=$WATCHTOWER_SCHEDULE_CRON" >> "$ENV_FILE"
    fi
    
    chmod 600 "$ENV_FILE"
}

# --- 核心启动逻辑 ---
_start_watchtower_container_logic(){
    load_config

    local wt_interval="$1"
    local mode_description="$2"
    local interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower"
    local container_names=()
    
    local run_hostname="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    _generate_env_file

    local docker_run_args=(-h "${run_hostname}")
    docker_run_args+=(--env-file "$ENV_FILE")

    local wt_args=("--cleanup")

    local run_container_name="watchtower"
    if [ "$interactive_mode" = "true" ]; then
        run_container_name="watchtower-once"
        docker_run_args+=(--rm --name "$run_container_name")
        wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name "$run_container_name" --restart unless-stopped)
        
        if [[ "$WATCHTOWER_RUN_MODE" != "cron" && "$WATCHTOWER_RUN_MODE" != "aligned" ]]; then
            log_info "⏳ 启用间隔循环模式: ${wt_interval:-300}秒"
            wt_args+=(--interval "${wt_interval:-300}")
        else
            log_info "⏰ 启用 Cron 调度模式: $WATCHTOWER_SCHEDULE_CRON"
        fi
    fi

    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
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
            echo -e "${CYAN}执行命令: JB_SUDO_LOG_QUIET=true run_with_sudo docker run --env-file $ENV_FILE ...${NC}"
        fi
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
        
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "核心服务已就绪 [$mode_description]"
            # log_info "ℹ️  环境变量文件已生成: $ENV_FILE"  <-- 已移除冗余日志
            cp -f "$ENV_FILE" "$ENV_FILE_LAST_RUN"
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
    
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    local safe_alias; safe_alias=$(_escape_markdown "$alias_name")
    local time_now; time_now=$(date "+%Y-%m-%d %H:%M:%S")
    local safe_time; safe_time=$(_escape_markdown "$time_now")
    
    # 构造 Markdown 美化消息 (重新设计)
    local msg="⚙️ *配置变更生效*

服务已重建并重启，监控任务正常运行。

🏷 节点: \`${safe_alias}\`
⏱ 时间: \`${safe_time}\`"
    
    send_test_notify "$msg"
}

_prompt_rebuild_if_needed() {
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
        return
    fi
    if [ ! -f "$ENV_FILE_LAST_RUN" ]; then
        return
    fi

    local temp_env
    temp_env=$(mktemp)
    local original_env_file="$ENV_FILE"
    ENV_FILE="$temp_env"
    _generate_env_file
    ENV_FILE="$original_env_file"
    
    local current_hash
    current_hash=$(md5sum "$ENV_FILE_LAST_RUN" 2>/dev/null | awk '{print $1}')
    local new_hash
    new_hash=$(md5sum "$temp_env" 2>/dev/null | awk '{print $1}')
    
    rm -f "$temp_env"

    if [ "$current_hash" != "$new_hash" ]; then
        echo ""
        echo -e "${RED}⚠️ 检测到配置已变更 (Diff Found)，建议前往'服务运维'重建服务以生效。${NC}"
    fi
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then log_info "操作已取消。"; return 1; fi
    _start_watchtower_container_logic "" "" true
}

_configure_telegram() {
    echo -e "当前 Token: ${GREEN}${TG_BOT_TOKEN:-[未设置]}${NC}"
    local val
    read -r -p "请输入 Telegram Bot Token (回车保持, 空格清空): " val
    if [[ "$val" =~ ^\ +$ ]]; then
        TG_BOT_TOKEN=""
        log_info "Token 已清空。"
    elif [ -n "$val" ]; then
        TG_BOT_TOKEN="$val"
    fi

    echo -e "当前 Chat ID: ${GREEN}${TG_CHAT_ID:-[未设置]}${NC}"
    read -r -p "请输入 Chat ID (回车保持, 空格清空): " val
    if [[ "$val" =~ ^\ +$ ]]; then
        TG_CHAT_ID=""
        log_info "Chat ID 已清空。"
    elif [ -n "$val" ]; then
        TG_CHAT_ID="$val"
    fi
    
    local notify_on_no_updates_choice
    notify_on_no_updates_choice=$(_prompt_user_input "是否在没有容器更新时也发送 Telegram 通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " "")
    
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    
    save_config
    log_info "通知配置已保存。"
    _prompt_rebuild_if_needed
}

_configure_alias() {
    echo -e "当前别名: ${GREEN}${WATCHTOWER_HOST_ALIAS:-DockerNode}${NC}"
    local val
    read -r -p "设置服务器别名 (回车保持, 空格恢复默认): " val
    if [[ "$val" =~ ^\ +$ ]]; then
        WATCHTOWER_HOST_ALIAS="DockerNode"
        log_info "已恢复默认别名。"
    elif [ -n "$val" ]; then
        WATCHTOWER_HOST_ALIAS="$val"
    fi
    save_config
    log_info "服务器别名已设置为: $WATCHTOWER_HOST_ALIAS"
    _prompt_rebuild_if_needed
}

_configure_email() {
    echo -e "当前 Email: ${GREEN}${EMAIL_TO:-[未设置]}${NC}"
    local val
    read -r -p "请输入接收邮箱 (回车保持, 空格清空): " val
    if [[ "$val" =~ ^\ +$ ]]; then
        EMAIL_TO=""
        log_info "Email 已清空。"
    elif [ -n "$val" ]; then
        EMAIL_TO="$val"
    fi
    save_config
    log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local alias_status="${CYAN}${WATCHTOWER_HOST_ALIAS:-默认}${NC}"
        
        local -a content_array=(
            "1. 配置 Telegram (状态: $tg_status)"
            "2. 设置服务器别名 (当前: $alias_status)"
            "3. 配置 Email (当前未使用)"
            "4. 发送手动测试通知 (使用 curl)"
            "5. 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) _configure_telegram; press_enter_to_continue ;;
            2) _configure_alias; press_enter_to_continue ;;
            3) _configure_email; press_enter_to_continue ;;
            4) 
                if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then 
                    log_warn "请先配置 Telegram。"
                else 
                    log_info "正在发送 Markdown 测试消息..."
                    local safe_ver; safe_ver=$(_escape_markdown "$SCRIPT_VERSION")
                    send_test_notify "*🔔 手动测试消息*
来自 Docker 助手 \`${safe_ver}\` 的测试。
*状态:* ✅ 成功连接"
                    log_success "测试请求已发送。"
                fi; press_enter_to_continue 
                ;;
            5) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "所有通知配置已清空。"; _prompt_rebuild_if_needed; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

_configure_schedule() {
    echo -e "${CYAN}请选择运行模式:${NC}"
    echo "1. 间隔循环 (每隔 X 小时/分钟，可选择对齐整点)"
    echo "2. 自定义 Cron 表达式 (高级)"
    
    local mode_choice
    mode_choice=$(_prompt_for_menu_choice "1-2")
    
    if [ "$mode_choice" = "1" ]; then
        local interval_hour=""
        while true; do
            interval_hour=$(_prompt_user_input "每隔几小时运行一次? (输入 0 表示使用分钟): " "")
            if [[ "$interval_hour" =~ ^[0-9]+$ ]]; then break; fi
            log_warn "请输入数字。"
        done
        
        if [ "$interval_hour" -gt 0 ]; then
            echo -e "${CYAN}请选择对齐方式:${NC}"
            echo "1. 从现在开始计时 (容器启动时间 + 间隔)"
            echo "2. 对齐到整点 (:00)"
            echo "3. 对齐到半点 (:30)"
            local align_choice=$(_prompt_for_menu_choice "1-3")
            
            if [ "$align_choice" = "1" ]; then
                WATCHTOWER_RUN_MODE="interval"
                WATCHTOWER_CONFIG_INTERVAL=$((interval_hour * 3600))
                WATCHTOWER_SCHEDULE_CRON=""
                log_info "已设置: 每 $interval_hour 小时运行一次 (立即生效)"
            else
                WATCHTOWER_RUN_MODE="aligned"
                local minute="0"
                if [ "$align_choice" = "3" ]; then minute="30"; fi
                WATCHTOWER_SCHEDULE_CRON="0 $minute */$interval_hour * * *"
                log_info "已设置: 每 $interval_hour 小时在 :$minute 运行 (Cron: $WATCHTOWER_SCHEDULE_CRON)"
                WATCHTOWER_CONFIG_INTERVAL="0"
            fi
        else
            WATCHTOWER_RUN_MODE="interval"
            local min_val=$(_prompt_for_interval "300" "请输入运行频率")
            WATCHTOWER_CONFIG_INTERVAL="$min_val"
            WATCHTOWER_SCHEDULE_CRON=""
            log_info "已设置: 每 $(_format_seconds_to_human "$min_val") 运行一次"
        fi
        
    elif [ "$mode_choice" = "2" ]; then
        WATCHTOWER_RUN_MODE="cron"
        echo -e "${CYAN}请输入 6段 Cron 表达式 (秒 分 时 日 月 周)${NC}"
        echo -e "示例: ${GREEN}0 0 4 * * *${NC}   (每天凌晨 4 点)"
        echo -e "示例: ${GREEN}0 0 * * * *${NC}   (每小时整点)"
        
        local cron_input
        read -r -p "Cron表达式 (留空保留原值): " cron_input
        
        if [ -n "$cron_input" ]; then
            WATCHTOWER_SCHEDULE_CRON="$cron_input"
            WATCHTOWER_CONFIG_INTERVAL="0"
            log_info "Cron 已设置为: $WATCHTOWER_SCHEDULE_CRON"
        else
            log_warn "未输入，保留原设置: ${WATCHTOWER_SCHEDULE_CRON:-无}"
        fi
    fi
}

configure_watchtower(){
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
        if ! confirm_action "Watchtower 正在运行。进入配置可能会覆盖当前设置，是否继续?"; then
            return 10
        fi
    fi

    _configure_schedule
    sleep 1
    configure_exclusion_list
    
    local extra_args_choice
    extra_args_choice=$(_prompt_user_input "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " "")
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then 
        echo -e "当前额外参数: ${GREEN}${temp_extra_args:-[无]}${NC}"
        local val
        read -r -p "请输入额外参数 (回车保持, 空格清空): " val
        if [[ "$val" =~ ^\ +$ ]]; then
            temp_extra_args=""
            log_info "额外参数已清空。"
        elif [ -n "$val" ]; then
            temp_extra_args="$val"
        fi
    fi
    
    local debug_choice
    debug_choice=$(_prompt_user_input "是否启用调试日志 (Debug)? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " "")
    local temp_debug_enabled="false"
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi
    
    local final_exclude_list_display="${WATCHTOWER_EXCLUDE_LIST:-无}"
    local mode_display="间隔循环 ($(_format_seconds_to_human "${WATCHTOWER_CONFIG_INTERVAL:-0}"))"
    if [[ "$WATCHTOWER_RUN_MODE" == "cron" || "$WATCHTOWER_RUN_MODE" == "aligned" ]]; then
        mode_display="Cron调度 ($WATCHTOWER_SCHEDULE_CRON)"
    fi

    local -a confirm_array=(
        "运行模式: $mode_display"
        "忽略名单: ${final_exclude_list_display//,/, }" 
        "额外参数: ${temp_extra_args:-无}" 
        "调试模式: $temp_debug_enabled"
    )
    _render_menu "配置确认" "${confirm_array[@]}"
    local confirm_choice
    confirm_choice=$(_prompt_for_menu_choice "")
    if echo "$confirm_choice" | grep -qE '^[Nn]$'; then log_info "操作已取消。"; return 10; fi
    
    WATCHTOWER_EXTRA_ARGS="$temp_extra_args"
    WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"
    WATCHTOWER_ENABLED="true"
    save_config
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
        read -r -p "请选择 (数字切换, c 结束, 回车清空): " choice
        
        case "$choice" in
            c|C) break ;;
            "") 
                if [ ${#excluded_map[@]} -eq 0 ]; then
                    log_info "当前列表已为空。"
                    sleep 1
                    continue
                fi
                if confirm_action "确定要清空忽略名单吗？(清空后将自动监控所有新容器)"; then
                    excluded_map=()
                    log_info "已清空忽略名单。"
                else
                    log_info "取消清空。"
                fi
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
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; 
        local -a items_array=(
            "1. 停止并移除服务 (卸载)" 
            "2. 重建服务 (应用新配置)"
        )
        _render_menu "⚙️ 服务运维 ⚙️" "${items_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-2")
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then 
                    echo -e "${RED}警告: 即将停止并移除 Watchtower 容器。${NC}"
                    if confirm_action "确定要继续吗？"; then 
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

# --- 辅助函数：解析日志时间戳 ---
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

_extract_schedule_from_env(){
    if ! command -v jq &>/dev/null; then echo ""; return; fi
    local env_json
    env_json=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Env}}' 2>/dev/null || echo "[]")
    echo "$env_json" | jq -r '.[] | select(startswith("WATCHTOWER_SCHEDULE=")) | split("=")[1]' | head -n1 || true
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

# --- Cron 下次执行时间计算 (纯Bash强化版) ---
_calculate_next_cron() {
    local cron_expr="$1"
    
    # 解析常用格式，增加对 */N 的健壮支持
    local sec min hour day month dow
    read -r sec min hour day month dow <<< "$cron_expr"
    
    if [[ "$sec" == "0" && "$min" == "0" ]]; then
        if [[ "$day" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
            # 处理 */N 格式
            if [[ "$hour" == "*" ]]; then
                echo "每小时整点"
            elif [[ "$hour" =~ ^\*/([0-9]+)$ || "$hour" =~ \*/([0-9]+) ]]; then
                echo "每 ${BASH_REMATCH[1]} 小时 (整点)"
            elif [[ "$hour" =~ ^[0-9]+$ ]]; then
                echo "每天 ${hour}:00:00"
            else
                echo "$cron_expr"
            fi
        else
            echo "$cron_expr"
        fi
    elif [[ "$sec" == "0" ]]; then
        # 处理分钟级 */N
        if [[ "$hour" == "*" && "$day" == "*" ]]; then
             if [[ "$min" =~ \*/([0-9]+) ]]; then
                echo "每 ${BASH_REMATCH[1]} 分钟"
             else
                echo "$cron_expr"
             fi
        else
            echo "$cron_expr"
        fi
    else
        echo "$cron_expr"
    fi
}

_get_watchtower_next_run_time(){
    local interval_seconds="$1"
    local raw_logs="$2"
    local schedule_env="$3"
    
    if [ -n "$schedule_env" ]; then
        local readable_schedule
        readable_schedule=$(_calculate_next_cron "$schedule_env")
        echo -e "${CYAN}定时任务: ${readable_schedule}${NC}"
        return
    fi
    
    if [ -z "$raw_logs" ] || [ -z "$interval_seconds" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local last_event_line
    last_event_line=$(echo "$raw_logs" | grep -E "Session done|Scheduling first run" | tail -n 1 || true)

    if [ -z "$last_event_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    local next_epoch=0
    local current_epoch; current_epoch=$(date +%s)

    local ts_str
    ts_str=$(_parse_watchtower_timestamp_from_log_line "$last_event_line")
    
    if [ -n "$ts_str" ]; then
        local last_epoch
        if date -d "$ts_str" "+%s" >/dev/null 2>&1; then last_epoch=$(date -d "$ts_str" "+%s"); 
        elif command -v gdate >/dev/null; then last_epoch=$(gdate -d "$ts_str" "+%s"); fi
        
        if [ -n "$last_epoch" ]; then
            next_epoch=$((last_epoch + interval_seconds))
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

show_container_info() {
    _print_header "容器状态看板"
    echo -e "${CYAN}说明: 下表列出了当前 Docker 主机上的容器，Watchtower 将根据配置监控这些容器的镜像更新。${NC}"
    echo ""
    
    if ! command -v docker &> /dev/null; then
        log_err "Docker 未找到。"
        return
    fi

    # 使用 docker ps 原生表格格式，清晰且健壮
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}"
    
    echo ""
    press_enter_to_continue
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local title="📊 详情与管理 📊"
        local interval raw_logs COUNTDOWN schedule_env
        
        set +e
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        schedule_env=$(_extract_schedule_from_env)
        set -e
        
        COUNTDOWN=$(_get_watchtower_next_run_time "${interval}" "${raw_logs}" "${schedule_env}")
        
        local -a content_lines_array=(
            "⏱️  ${CYAN}当前状态${NC}"
            "    ${YELLOW}下一次扫描:${NC} ${COUNTDOWN}"
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
    # 移除单独的 Cron 表达式选项，整合到运行模式中
    local -a config_items=("TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "忽略名单|WATCHTOWER_EXCLUDE_LIST|string_list" "服务器别名|WATCHTOWER_HOST_ALIAS|string" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "运行模式|WATCHTOWER_RUN_MODE|schedule" "检测频率|WATCHTOWER_CONFIG_INTERVAL|interval")
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config; 
        local -a content_lines_array=(); local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"; local label; label=$(echo "$item" | cut -d'|' -f1); local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3); local current_value="${!var_name}"; local display_text=""; local color="${CYAN}"
            case "$type" in
                string) if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi ;;
                string_list) if [ -n "$current_value" ]; then color="${YELLOW}"; display_text="${current_value//,/, }"; else color="${CYAN}"; display_text="无"; fi ;;
                bool) if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi ;;
                interval) 
                    if [[ "$WATCHTOWER_RUN_MODE" == "cron" || "$WATCHTOWER_RUN_MODE" == "aligned" ]]; then
                        display_text="禁用 (已启用Cron)"; color="${YELLOW}"
                    else
                        display_text=$(_format_seconds_to_human "$current_value"); if [ "$display_text" != "N/A" ] && [ -n "$current_value" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi 
                    fi
                    ;;
                schedule)
                    if [[ "$current_value" == "cron" || "$current_value" == "aligned" ]]; then
                        display_text="Cron调度 (${WATCHTOWER_SCHEDULE_CRON})"; color="${GREEN}"
                    else
                        display_text="间隔循环 ($(_format_seconds_to_human "${WATCHTOWER_CONFIG_INTERVAL:-0}"))"; color="${CYAN}"
                    fi
                    ;;
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
                if [ "$var_name" = "WATCHTOWER_EXCLUDE_LIST" ]; then
                    configure_exclusion_list
                else
                    echo -e "当前 ${label}: ${GREEN}${current_value:-[未设置]}${NC}"
                    read -r -p "请输入新值 (回车保持, 空格清空): " val
                    if [[ "$val" =~ ^\ +$ ]]; then declare "$var_name"=""; log_info "'$label' 已清空。"; elif [ -n "$val" ]; then declare "$var_name"="$val"; fi
                fi
                ;;
            bool) 
                local new_value_input
                new_value_input=$(_prompt_user_input "是否启用 '$label'? (y/N, 当前: $current_value): " "")
                if echo "$new_value_input" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi 
                ;;
            interval) 
                if [[ "$WATCHTOWER_RUN_MODE" == "cron" || "$WATCHTOWER_RUN_MODE" == "aligned" ]]; then
                    log_warn "当前处于定时任务模式，设置间隔不会生效。请修改 '运行模式'。"
                    sleep 2
                else
                    new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔")
                    if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi 
                fi
                ;;
            schedule)
                _configure_schedule
                ;;
        esac
        save_config; log_info "'$label' 已更新。"; 
        _prompt_rebuild_if_needed
        sleep 1
    done
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local STATUS_RAW="未运行"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${GREEN}已启动${NC}"; else STATUS_COLOR="${RED}未运行${NC}"; fi
        local interval=""; local raw_logs=""; local schedule_env=""
        if [ "$STATUS_RAW" = "已启动" ]; then 
            interval=$(get_watchtower_inspect_summary || true)
            raw_logs=$(get_watchtower_all_raw_logs || true)
            schedule_env=$(_extract_schedule_from_env)
        fi
        local COUNTDOWN=$(_get_watchtower_next_run_time "${interval}" "${raw_logs}" "${schedule_env}")
        local TOTAL; TOTAL=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l || echo "0")
        local RUNNING; RUNNING=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.ID}}' 2>/dev/null | wc -l || echo "0"); local STOPPED=$((TOTAL - RUNNING))
        
        local notify_mode="${CYAN}关闭${NC}"
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            notify_mode="${GREEN}Telegram${NC}"
        fi
        
        # --- 状态指示：检查配置是否变更 ---
        local config_mtime; config_mtime=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)
        local container_created; container_created=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect --format '{{.Created}}' watchtower 2>/dev/null || echo "")
        local warning_msg=""
        if [ "$STATUS_RAW" = "已启动" ] && [ -n "$container_created" ]; then
            local container_ts; container_ts=$(date -d "$container_created" +%s 2>/dev/null || echo 0)
            # 只有当配置修改时间明显晚于容器创建时间（5秒以上）才提示
            if [ "$config_mtime" -gt "$((container_ts + 5))" ]; then
                warning_msg=" ${YELLOW}⚠️ 配置未生效 (需重建)${NC}"
                STATUS_COLOR="${YELLOW}待重启${NC}"
            fi
        fi

        local header_text="Watchtower 自动更新管理器"
        
        local -a content_array=(
            "🕝 服务运行状态: ${STATUS_COLOR}${warning_msg}" 
            "🔔 消息通知渠道: ${notify_mode}"
            "⏳ 下一次扫描: ${COUNTDOWN}" 
            "📦 受控容器统计: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        
        content_array+=("" "主菜单：" 
            "1. 部署/重新配置服务 (核心设置)" 
            "2. 通知参数设置 (Token/ID/别名)" 
            "3. 服务管理与卸载" 
            "4. 高级参数编辑器" 
            "5. 实时日志与容器看板"
        )
        _render_menu "$header_text" "${content_array[@]}"
        local choice
        choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            # 修正：捕获返回码，避免因 set -e 导致非0返回码直接退出脚本
            1) 
                set +e
                configure_watchtower
                local rc=$?
                set -e
                if [ "$rc" -ne 10 ]; then 
                    press_enter_to_continue
                fi 
                ;;
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
