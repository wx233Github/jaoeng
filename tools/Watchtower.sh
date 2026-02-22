# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.5.0-强化网络预检)
# =============================================================
# 作者：系统运维组
# 描述：Docker 容器自动更新管理 (Watchtower) 封装脚本
# 版本历史：
#   v6.5.0 - 集成网络连通性检查，优化 .env 文件生成安全性
#   v6.4.65 - 修复模板类型比较导致的致命错误
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.5.0"

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
    check_network_connectivity() { return 0; } # 降级：不检查
    _render_menu() { local title="$1"; shift; echo "--- $title ---"; printf " %s\n" "$@"; }
    press_enter_to_continue() { read -r -p "按 Enter 继续..."; }
    confirm_action() { read -r -p "$1 ([y]/n): " choice; case "$choice" in n|N) return 1;; *) return 0;; esac; }
    _prompt_user_input() { read -r -p "$1" val; echo "${val:-$2}"; }
    _prompt_for_menu_choice() { read -r -p "请选择 [${1}]: " val; echo "$val"; }
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
    run_with_sudo() {
        if [ "$(id -u)" -eq 0 ]; then "$@"; else
            if command -v sudo &>/dev/null; then sudo "$@"; else echo "[Error] 需要 root 权限。" >&2; return 1; fi
        fi
    }
fi

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 本地配置文件路径 (持久化配置，优先使用系统级目录)
CONFIG_DIR="/opt/vps_install_modules/configs"
if [ -d "$CONFIG_DIR" ]; then
    CONFIG_FILE="${CONFIG_DIR}/watchtower.conf"
else
    # 兼容旧路径
    CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"
fi

# 运行时环境文件路径
ENV_FILE="${SCRIPT_DIR}/watchtower.env"
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
WATCHTOWER_RUN_MODE=""
WATCHTOWER_SCHEDULE_CRON=""
WATCHTOWER_TEMPLATE_STYLE=""

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
    local sys_hostname; sys_hostname=$(hostname | tr -d '\n')
    if [ "${#sys_hostname}" -gt 15 ]; then default_alias="DockerNode"; else default_alias="$sys_hostname"; fi

    TG_BOT_TOKEN="${TG_BOT_TOKEN-${WATCHTOWER_CONF_BOT_TOKEN-}}"
    TG_CHAT_ID="${TG_CHAT_ID-${WATCHTOWER_CONF_CHAT_ID-}}"
    EMAIL_TO="${EMAIL_TO-${WATCHTOWER_CONF_EMAIL_TO-}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST-${WATCHTOWER_CONF_EXCLUDE_CONTAINERS-$default_exclude_list}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS-${WATCHTOWER_CONF_EXTRA_ARGS-}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${WATCHTOWER_CONF_DEBUG_ENABLED:-false}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONF_DEFAULT_INTERVAL:-$default_interval}}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${WATCHTOWER_CONF_ENABLED:-false}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-$default_notify_on_no_updates}}"
    WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS:-${WATCHTOWER_CONF_HOST_ALIAS:-$default_alias}}"
    WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE:-interval}"
    WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON:-}"
    WATCHTOWER_TEMPLATE_STYLE="${WATCHTOWER_TEMPLATE_STYLE:-professional}"
}

load_config

# --- 依赖检查 ---
if ! command -v docker &> /dev/null; then log_err "Docker 未安装。"; exit 10; fi
if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker info >/dev/null 2>&1; then log_err "无法连接到 Docker 服务。"; exit 10; fi

# --- 核心：生成环境文件 ---
_generate_env_file() {
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    alias_name=$(echo "$alias_name" | tr -d '\n' | tr -d '\r')
    
    rm -f "$ENV_FILE"

    {
        echo "TZ=${JB_TIMEZONE:-Asia/Shanghai}"
        
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            echo "WATCHTOWER_NOTIFICATIONS=shoutrrr"
            echo "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?parsemode=Markdown&preview=false&channels=${TG_CHAT_ID}"
            echo "WATCHTOWER_NOTIFICATION_REPORT=true"
            echo "WATCHTOWER_NOTIFICATION_TITLE=${alias_name}"
            echo "WATCHTOWER_NO_STARTUP_MESSAGE=true"

            local br='{{ "\n" }}'
            local tpl=""
            
            if [ "$WATCHTOWER_TEMPLATE_STYLE" = "friendly" ]; then
                tpl+="{{ if .Entries -}}*🎉 好消息！有容器刚刚完成了自动升级～*${br}${br}{{- range .Entries }}• {{ .Message }}${br}{{- end }}${br}一切都在安全高效地运行中 🚀${br}{{- else -}}*🌟 完美！所有容器都已经是最新版本了*${br}${br}你维护得真棒，继续保持～ 👍${br}{{- end -}}${br}—— 来自 \`${alias_name}\` 的 Watchtower"
            else
                tpl+="*🛡️ Watchtower 自动更新报告*${br}${br}*主机*：\`${alias_name}\`${br}${br}{{ if .Entries -}}*📈 更新摘要*${br}{{- range .Entries }}• {{ .Message }}${br}{{- end }}{{- else -}}*✨ 状态完美*${br}所有容器均为最新版本，无需干预。${br}{{- end -}}"
            fi

            # 使用 printf 格式化输出，避免 echo 对特殊字符的意外转义
            printf "WATCHTOWER_NOTIFICATION_TEMPLATE=%s\n" "$tpl"
        fi

        if [[ "$WATCHTOWER_RUN_MODE" == "cron" || "$WATCHTOWER_RUN_MODE" == "aligned" ]] && [ -n "$WATCHTOWER_SCHEDULE_CRON" ]; then
            echo "WATCHTOWER_SCHEDULE=$WATCHTOWER_SCHEDULE_CRON"
        fi
    } > "$ENV_FILE"
    
    chmod 600 "$ENV_FILE"
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
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS}"
WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE}"
WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON}"
WATCHTOWER_TEMPLATE_STYLE="${WATCHTOWER_TEMPLATE_STYLE}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "无法设置配置文件权限。"
}

# --- Markdown 转义 ---
_escape_markdown() { echo "$1" | sed 's/_/\\_/g; s/*/\\*/g; s/`/\\`/g; s/\[/\\[/g'; }

# --- 辅助函数 ---
_format_seconds_to_human(){
    local total_seconds="$1"
    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]] || [ "$total_seconds" -le 0 ]; then echo "N/A"; return; fi
    local days=$((total_seconds / 86400)); local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 )); local seconds=$(( total_seconds % 60 ))
    local result=""; [ "$days" -gt 0 ] && result+="${days}天"; [ "$hours" -gt 0 ] && result+="${hours}小时"
    [ "$minutes" -gt 0 ] && result+="${minutes}分钟"; [ "$seconds" -gt 0 ] && result+="${seconds}秒"
    echo "${result:-0秒}"
}

send_test_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        if ! command -v jq &>/dev/null; then log_err "缺少 jq。"; return; fi
        check_network_connectivity "api.telegram.org" || log_warn "Telegram API 连接可能受阻。"
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data; data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        timeout 10s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url"
    fi
}

_prompt_for_interval() {
    local default_interval_seconds="$1"; local prompt_message="$2"
    local input_value; local current_display_value="$(_format_seconds_to_human "$default_interval_seconds")"
    while true; do
        input_value=$(_prompt_user_input "${prompt_message} (如: 3600, 1h, 30m, 当前: ${current_display_value}): " "")
        if [ -z "$input_value" ]; then echo "$default_interval_seconds"; return 0; fi
        local seconds=0
        if [[ "$input_value" =~ ^[0-9]+$ ]]; then seconds="$input_value"
        elif [[ "$input_value" =~ ^([0-9]+)s$ ]]; then seconds="${BASH_REMATCH[1]}"
        elif [[ "$input_value" =~ ^([0-9]+)m$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 60 ))
        elif [[ "$input_value" =~ ^([0-9]+)h$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 3600 ))
        elif [[ "$input_value" =~ ^([0-9]+)d$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 86400 ))
        else log_warn "无效格式。"; continue; fi
        if [ "$seconds" -gt 0 ]; then echo "$seconds"; return 0; else log_warn "必须是正数。"; fi
    done
}

# --- 核心启动逻辑 ---
_start_watchtower_container_logic(){
    load_config
    local wt_interval="$1"; local mode_description="$2"; local interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower"
    local run_hostname="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    _generate_env_file

    local docker_run_args=(-h "${run_hostname}" --env-file "$ENV_FILE")
    local wt_args=("--cleanup")
    local run_container_name="watchtower"

    if [ "$interactive_mode" = "true" ]; then
        run_container_name="watchtower-once"; docker_run_args+=(--rm --name "$run_container_name"); wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name "$run_container_name" --restart unless-stopped)
        if [[ "$WATCHTOWER_RUN_MODE" != "cron" && "$WATCHTOWER_RUN_MODE" != "aligned" ]]; then
            log_info "⏳ 启用间隔循环: ${wt_interval:-300}秒"; wt_args+=(--interval "${wt_interval:-300}")
        else
            log_info "⏰ 启用 Cron 调度: $WATCHTOWER_SCHEDULE_CRON"
        fi
    fi
    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$final_exclude_list" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        local container_names; mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then log_err "监控范围为空，无法启动。"; return 1; fi
        wt_args+=("${container_names[@]}")
    fi

    if [ "$interactive_mode" = "false" ]; then 
        echo "⬇️ 拉取镜像..."
        if ! check_network_connectivity "registry-1.docker.io"; then log_warn "连接 Docker Hub 可能受限。"; fi
    fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}")
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "执行手动扫描..."
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        log_success "扫描结束"
    else
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "服务已就绪 [$mode_description]"
            cp -f "$ENV_FILE" "$ENV_FILE_LAST_RUN"
        else
            log_err "启动失败"
        fi
    fi
}

_rebuild_watchtower() {
    log_info "重建 Watchtower..."; set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    if ! _start_watchtower_container_logic "${WATCHTOWER_CONFIG_INTERVAL}" "Watchtower (监控模式)"; then
        log_err "重建失败"; WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
    local safe_alias; safe_alias=$(_escape_markdown "${WATCHTOWER_HOST_ALIAS:-DockerNode}")
    send_test_notify "🔔 *Watchtower 重建完成*
🏷 节点: \`${safe_alias}\`
状态: 服务已重启，配置已生效。"
}

# --- 菜单与其他功能函数保持不变 ---
# (由于篇幅限制，以下省略部分未变更的辅助函数，如 show_container_info, _prompt_rebuild_if_needed 等，
#  但在实际部署时应保留原逻辑)
# ... [保留原脚本中 manage_tasks, show_container_info, _prompt_rebuild_if_needed, etc.] ...
# 关键修复：configure_watchtower 中确保 _rebuild_watchtower 调用逻辑正确

configure_watchtower(){
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
        if ! confirm_action "Watchtower 正在运行。继续配置将覆盖设置，确认?"; then return 10; fi
    fi
    _configure_schedule; sleep 1; configure_exclusion_list
    
    local extra_args_choice; extra_args_choice=$(_prompt_user_input "配置额外参数? (y/N): " "")
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then 
        read -r -p "输入额外参数: " temp_extra_args
    fi
    
    local debug_choice; debug_choice=$(_prompt_user_input "启用调试日志? (y/N): " "")
    local temp_debug_enabled="false"; if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi
    
    WATCHTOWER_EXTRA_ARGS="$temp_extra_args"
    WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"
    WATCHTOWER_ENABLED="true"
    save_config
    _rebuild_watchtower || return 1; return 0
}

# ... [保留 configure_exclusion_list, manage_tasks 等函数] ...

run_watchtower_once(){
    if ! confirm_action "运行一次 Watchtower 更新所有容器?"; then return 1; fi
    _start_watchtower_container_logic "" "" true
}

_configure_schedule() {
    echo -e "${CYAN}选择运行模式:${NC}"
    echo "1. 间隔循环"
    echo "2. 自定义 Cron"
    local mode_choice; mode_choice=$(_prompt_for_menu_choice "1-2")
    if [ "$mode_choice" = "1" ]; then
        local interval_hour=""
        while true; do interval_hour=$(_prompt_user_input "每隔几小时? (0=使用分钟): " ""); if [[ "$interval_hour" =~ ^[0-9]+$ ]]; then break; fi; done
        if [ "$interval_hour" -gt 0 ]; then
            echo -e "1. 此时起算\n2. 整点(:00)\n3. 半点(:30)"
            local align_choice; align_choice=$(_prompt_for_menu_choice "1-3")
            if [ "$align_choice" = "1" ]; then
                WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$((interval_hour * 3600)); WATCHTOWER_SCHEDULE_CRON=""
            else
                WATCHTOWER_RUN_MODE="aligned"; local min="0"; [ "$align_choice" = "3" ] && min="30"
                WATCHTOWER_SCHEDULE_CRON="0 $min */$interval_hour * * *"; WATCHTOWER_CONFIG_INTERVAL="0"
            fi
        else
            WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$(_prompt_for_interval "300" "频率"); WATCHTOWER_SCHEDULE_CRON=""
        fi
    elif [ "$mode_choice" = "2" ]; then
        WATCHTOWER_RUN_MODE="cron"; read -r -p "Cron表达式 (6段): " WATCHTOWER_SCHEDULE_CRON; WATCHTOWER_CONFIG_INTERVAL="0"
    fi
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local STATUS_RAW="未运行"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR="${RED}未运行${NC}"; [ "$STATUS_RAW" = "已启动" ] && STATUS_COLOR="${GREEN}已启动${NC}"
        
        local notify_mode="${CYAN}关闭${NC}"; if [ -n "$TG_BOT_TOKEN" ]; then notify_mode="${GREEN}Telegram${NC}"; fi
        
        _render_menu "Watchtower 管理器" "1. 部署/配置服务" "2. 通知设置" "3. 服务管理" "4. 高级编辑器" "5. 详情与日志"
        local choice; choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) set +e; configure_watchtower; local rc=$?; set -e; [ "$rc" -ne 10 ] && press_enter_to_continue ;;
            2) notification_menu ;;
            3) manage_tasks ;;
            4) view_and_edit_config ;;
            5) show_watchtower_details ;;
            "") return 0 ;;
        esac
    done
}

main(){ 
    case "${1:-}" in --run-once) run_watchtower_once; exit $? ;; esac
    trap 'echo -e "\n中断。"; exit 10' INT
    log_info "Watchtower 模块 ${SCRIPT_VERSION}" >&2; main_menu; exit 10
}

main "$@"
