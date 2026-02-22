#!/usr/bin/env bash
# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.6.0 - 完整版与安全审计)
# =============================================================
# 作者：系统运维组
# 描述：Docker 容器自动更新管理 (Watchtower) 封装脚本
# 版本历史：
#   v6.6.0 - 完整实装网络预检，强制配置文件权限安全降级，修复截断遗失代码
#   v6.5.1 - 修复模板类型比较导致的致命错误与主机名显示问题
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.6.0"

# --- 严格模式与环境设定 ---
set -euo pipefail
export LANG="${LANG:-en_US.UTF_8}"
export LC_ALL="${LC_ALL:-C.UTF_8}"

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    # 基础容错兜底：确保在无 utils.sh 环境下不崩溃
    log_err() { printf "[错误] %s\n" "$*" >&2; }
    log_info() { printf "[信息] %s\n" "$*"; }
    log_warn() { printf "[警告] %s\n" "$*" >&2; }
    log_success() { printf "[成功] %s\n" "$*"; }
    check_network_connectivity() { return 0; } # 降级：假装网络永远正常
    _render_menu() { local title="$1"; shift; echo "--- $title ---"; printf " %s\n" "$@"; }
    press_enter_to_continue() { read -r -p "按 Enter 继续..." < /dev/tty; }
    confirm_action() { local choice; read -r -p "$1 ([y]/n): " choice < /dev/tty; case "$choice" in n|N) return 1;; *) return 0;; esac; }
    _prompt_user_input() { local val; read -r -p "$1" val < /dev/tty; echo "${val:-$2}"; }
    _prompt_for_menu_choice() { local val; read -r -p "请选择 [${1}]: " val < /dev/tty; echo "$val"; }
    GREEN=""; NC=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; ORANGE="";
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo >/dev/null 2>&1; then
    run_with_sudo() {
        if [ "$(id -u)" -eq 0 ]; then
            "$@"
        else
            if command -v sudo >/dev/null 2>&1; then
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

# 安全增强：配置文件统一管控路径
CONFIG_DIR="/opt/vps_install_modules/configs"
CONFIG_FILE="${CONFIG_DIR}/watchtower.conf"
LEGACY_CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# 运行时环境文件路径
ENV_FILE="${SCRIPT_DIR}/watchtower.env"
ENV_FILE_LAST_RUN="${SCRIPT_DIR}/watchtower.env.last_run"

# --- 模块变量初始化 ---
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

# --- 配置加载与安全迁移 ---
load_config(){
    # 平滑迁移机制
    if [ ! -f "$CONFIG_FILE" ] && [ -f "$LEGACY_CONFIG_FILE" ]; then
        log_warn "检测到用户目录下的旧版配置，将其迁移至安全系统目录..."
        run_with_sudo mkdir -p "$CONFIG_DIR"
        run_with_sudo cp -f "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
        run_with_sudo chown root:root "$CONFIG_FILE"
        run_with_sudo chmod 600 "$CONFIG_FILE"
        rm -f "$LEGACY_CONFIG_FILE" 2>/dev/null || true
    fi

    if [ -f "$CONFIG_FILE" ]; then
        # 考虑到权限可能是 600 root:root，需要确保有权限读取
        if [ -r "$CONFIG_FILE" ]; then
            # shellcheck source=/dev/null
            source "$CONFIG_FILE" >/dev/null 2>&1 || true
        else
            # 若无读权限但拥有 sudo
            eval "$(run_with_sudo cat "$CONFIG_FILE" 2>/dev/null)" || true
        fi
    fi

    local default_interval="21600"
    local default_cron_hour="4"
    local default_exclude_list="portainer,portainer_agent"
    local default_notify_on_no_updates="true"
    local default_alias
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
    WATCHTOWER_TEMPLATE_STYLE="${WATCHTOWER_TEMPLATE_STYLE:-professional}"
}

# 预加载配置
load_config

# --- 依赖检查 ---
if ! command -v docker >/dev/null 2>&1; then
    log_err "Docker 未安装。此模块需要 Docker 才能运行。"
    exit 10
fi

if [ -n "${TG_BOT_TOKEN:-}" ] && ! command -v jq >/dev/null 2>&1; then
    log_warn "建议安装 'jq' 以便使用脚本内的'发送测试通知'功能。"
fi

if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker info >/dev/null 2>&1; then
    log_err "无法连接到 Docker 服务 (daemon)。请确保 Docker 正在运行且当前用户有权访问。"
    exit 10
fi

save_config(){
    local tmp_conf
    tmp_conf=$(mktemp)

    cat > "$tmp_conf" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-}"
WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS:-}"
WATCHTOWER_RUN_MODE="${WATCHTOWER_RUN_MODE:-}"
WATCHTOWER_SCHEDULE_CRON="${WATCHTOWER_SCHEDULE_CRON:-}"
WATCHTOWER_TEMPLATE_STYLE="${WATCHTOWER_TEMPLATE_STYLE:-}"
EOF

    run_with_sudo mkdir -p "$CONFIG_DIR"
    run_with_sudo chown root:root "$CONFIG_DIR" 2>/dev/null || true
    
    run_with_sudo mv "$tmp_conf" "$CONFIG_FILE"
    run_with_sudo chown root:root "$CONFIG_FILE" 2>/dev/null || true
    run_with_sudo chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

_print_header() { echo -e "\n${BLUE}--- ${1} ---${NC}"; }

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

_escape_markdown() {
    # 严格转义 Markdown 特殊字符
    echo "$1" | sed 's/_/\\_/g; s/*/\\*/g; s/`/\\`/g; s/\[/\\[/g'
}

send_test_notify() {
    local message="$1"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        if ! command -v jq >/dev/null 2>&1; then log_err "缺少 jq，无法发送通知。"; return; fi
        
        check_network_connectivity "api.telegram.org" 5 || log_warn "连接 Telegram API 超时或受阻。"

        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data
        data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        timeout 10s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url" || log_err "请求被强行中断或失败。"
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
        if [[ "$input_value" =~ ^[0-9]+$ ]]; then seconds="$input_value"
        elif [[ "$input_value" =~ ^([0-9]+)s$ ]]; then seconds="${BASH_REMATCH[1]}"
        elif [[ "$input_value" =~ ^([0-9]+)m$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 60 ))
        elif [[ "$input_value" =~ ^([0-9]+)h$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 3600 ))
        elif [[ "$input_value" =~ ^([0-9]+)d$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 86400 ))
        else log_warn "无效格式。"; continue; fi

        if [ "$seconds" -gt 0 ]; then echo "$seconds"; return 0; else log_warn "间隔必须是正数。"; fi
    done
}

# --- 核心：生成环境文件 ---
_generate_env_file() {
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    alias_name=$(echo "$alias_name" | tr -d '\n\r')
    
    rm -f "$ENV_FILE"

    {
        echo "TZ=${JB_TIMEZONE:-Asia/Shanghai}"
        if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
            echo "WATCHTOWER_NOTIFICATIONS=shoutrrr"
            echo "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?parsemode=Markdown&preview=false&channels=${TG_CHAT_ID}"
            echo "WATCHTOWER_NOTIFICATION_REPORT=true"
            echo "WATCHTOWER_NOTIFICATION_TITLE=${alias_name}"
            echo "WATCHTOWER_NO_STARTUP_MESSAGE=true"

            local br='{{ "\n" }}'
            local tpl=""
            
            if [ "${WATCHTOWER_TEMPLATE_STYLE:-professional}" = "friendly" ]; then
                tpl+="{{ if .Entries -}}"
                tpl+="*🎉 好消息！有容器刚刚完成了自动升级～*${br}${br}"
                tpl+="{{- range .Entries }}• {{ .Message }}${br}{{- end }}${br}"
                tpl+="一切都在安全高效地运行中 🚀${br}"
                tpl+="{{- else -}}"
                tpl+="*🌟 完美！所有容器都已经是最新版本了*${br}${br}"
                tpl+="你维护得真棒，继续保持～ 👍${br}"
                tpl+="{{- end -}}${br}"
                tpl+="—— 来自 \`${alias_name}\` 的 Watchtower"
            else
                tpl+="*🛡️ Watchtower 自动更新报告*${br}${br}"
                tpl+="*主机*：\`${alias_name}\`${br}${br}"
                tpl+="{{ if .Entries -}}"
                tpl+="*📈 更新摘要*${br}"
                tpl+="{{- range .Entries }}• {{ .Message }}${br}{{- end }}"
                tpl+="{{- else -}}"
                tpl+="*✨ 状态完美*${br}所有容器均为最新版本，无需干预。${br}"
                tpl+="{{- end -}}"
            fi

            # 严格防转义写入
            printf "WATCHTOWER_NOTIFICATION_TEMPLATE=%s\n" "$tpl"
        fi

        if [[ "${WATCHTOWER_RUN_MODE:-}" =~ ^(cron|aligned)$ ]] && [ -n "${WATCHTOWER_SCHEDULE_CRON:-}" ]; then
            echo "WATCHTOWER_SCHEDULE=$WATCHTOWER_SCHEDULE_CRON"
        fi
    } > "$ENV_FILE"
    
    chmod 600 "$ENV_FILE" 2>/dev/null || true
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

    local docker_run_args=("-h" "${run_hostname}" "--env-file" "$ENV_FILE")
    local wt_args=("--cleanup")

    local run_container_name="watchtower"
    if [ "$interactive_mode" = "true" ]; then
        run_container_name="watchtower-once"
        docker_run_args+=("--rm" "--name" "$run_container_name")
        wt_args+=("--run-once")
    else
        docker_run_args+=("-d" "--name" "$run_container_name" "--restart" "unless-stopped")
        if [[ "${WATCHTOWER_RUN_MODE:-}" != "cron" && "${WATCHTOWER_RUN_MODE:-}" != "aligned" ]]; then
            log_info "⏳ 启用间隔循环模式: ${wt_interval:-300}秒"
            wt_args+=("--interval" "${wt_interval:-300}")
        else
            log_info "⏰ 启用 Cron 调度模式: ${WATCHTOWER_SCHEDULE_CRON:-}"
        fi
    fi

    docker_run_args+=("-v" "/var/run/docker.sock:/var/run/docker.sock")
    
    if [ "${WATCHTOWER_DEBUG_ENABLED:-}" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "${WATCHTOWER_EXTRA_ARGS:-}" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST:-}"
    if [ -n "$final_exclude_list" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then
            log_err "忽略名单导致监控范围为空，服务无法启动。"
            return 1
        fi
        if [ "$interactive_mode" = "false" ]; then log_info "已计算监控范围 (${#container_names[@]} 个容器)。"; fi
    fi

    if [ "$interactive_mode" = "false" ]; then 
        check_network_connectivity "registry-1.docker.io" 5 || log_warn "连接 Docker Hub 失败，拉取镜像可能耗时或报错。"
        echo "⬇️ 正在拉取 Watchtower 镜像..."
    fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    if [ "$interactive_mode" = "false" ]; then _print_header "正在启动 $mode_description"; fi
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]:-}")
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "正在执行立即更新扫描... (显示实时日志)"
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        log_success "扫描任务已结束"
        return 0
    else
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}" >/dev/null; local rc=$?; set -e
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "核心服务已就绪 [$mode_description]"
            cp -f "$ENV_FILE" "$ENV_FILE_LAST_RUN"
        else
            log_err "$mode_description 启动失败"
        fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."; 
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower >/dev/null 2>&1; set -e
    local interval="${WATCHTOWER_CONFIG_INTERVAL:-}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower (监控模式)"; then
        log_err "Watchtower 重建失败！"
        WATCHTOWER_ENABLED="false"
        save_config
        return 1
    fi
    
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    local safe_alias; safe_alias=$(_escape_markdown "$alias_name")
    local time_now; time_now=$(date "+%Y-%m-%d %H:%M:%S")
    local safe_time; safe_time=$(_escape_markdown "$time_now")
    
    local msg="🔔 *Watchtower 配置更新*
🏷 节点: \`${safe_alias}\`
⏱ 时间: \`${safe_time}\`
⚙️ *状态*: 服务已重建并重启
📝 *详情*: 配置已重新加载，监控任务正常运行中。"
    send_test_notify "$msg"
}

_prompt_rebuild_if_needed() {
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then return; fi
    if [ ! -f "$ENV_FILE_LAST_RUN" ]; then return; fi

    local temp_env; temp_env=$(mktemp)
    local original_env_file="$ENV_FILE"
    ENV_FILE="$temp_env"
    _generate_env_file
    ENV_FILE="$original_env_file"
    
    local current_hash; current_hash=$(md5sum "$ENV_FILE_LAST_RUN" 2>/dev/null | awk '{print $1}')
    local new_hash; new_hash=$(md5sum "$temp_env" 2>/dev/null | awk '{print $1}')
    rm -f "$temp_env"

    if [ "$current_hash" != "$new_hash" ]; then
        echo -e "\n${RED}⚠️ 检测到配置变更未生效，建议在主菜单中重新[部署/重新配置服务]以应用。${NC}"
    fi
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then log_info "操作已取消。"; return 1; fi
    _start_watchtower_container_logic "" "" true
}

_configure_telegram() {
    echo -e "当前 Token: ${GREEN}${TG_BOT_TOKEN:-[未设置]}${NC}"
    local val
    read -r -p "请输入 Telegram Bot Token (回车保持, 空格清空): " val < /dev/tty
    if [[ "$val" =~ ^\ +$ ]]; then TG_BOT_TOKEN=""; log_info "Token 已清空。"; elif [ -n "$val" ]; then TG_BOT_TOKEN="$val"; fi

    echo -e "当前 Chat ID: ${GREEN}${TG_CHAT_ID:-[未设置]}${NC}"
    read -r -p "请输入 Chat ID (回车保持, 空格清空): " val < /dev/tty
    if [[ "$val" =~ ^\ +$ ]]; then TG_CHAT_ID=""; log_info "Chat ID 已清空。"; elif [ -n "$val" ]; then TG_CHAT_ID="$val"; fi
    
    local notify_on_no_updates_choice
    notify_on_no_updates_choice=$(_prompt_user_input "是否在没有容器更新时也发送通知? (Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-true}): " "")
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    
    echo -e "${CYAN}请选择通知模板风格:${NC}"
    echo "1. 专业/详细版 (Professional)"
    echo "2. 亲切/活泼版 (Friendly)"
    local style_choice; style_choice=$(_prompt_for_menu_choice "1-2")
    case "$style_choice" in
        2) WATCHTOWER_TEMPLATE_STYLE="friendly" ;;
        *) WATCHTOWER_TEMPLATE_STYLE="professional" ;;
    esac
    
    save_config
    log_info "通知配置已保存。"
    _prompt_rebuild_if_needed
}

_configure_alias() {
    echo -e "当前别名: ${GREEN}${WATCHTOWER_HOST_ALIAS:-DockerNode}${NC}"
    local val
    read -r -p "设置服务器别名 (回车保持, 空格恢复默认): " val < /dev/tty
    if [[ "$val" =~ ^\ +$ ]]; then WATCHTOWER_HOST_ALIAS="DockerNode"; log_info "已恢复默认别名。"
    elif [ -n "$val" ]; then WATCHTOWER_HOST_ALIAS="$val"; fi
    save_config
    log_info "别名已设置为: $WATCHTOWER_HOST_ALIAS"
    _prompt_rebuild_if_needed
}

_configure_email() {
    echo -e "当前 Email: ${GREEN}${EMAIL_TO:-[未设置]}${NC}"
    local val
    read -r -p "请输入接收邮箱 (回车保持, 空格清空): " val < /dev/tty
    if [[ "$val" =~ ^\ +$ ]]; then EMAIL_TO=""; log_info "Email 已清空。"; elif [ -n "$val" ]; then EMAIL_TO="$val"; fi
    save_config
    log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local alias_status="${CYAN}${WATCHTOWER_HOST_ALIAS:-默认}${NC}"
        
        local -a content_array=(
            "1. 配置 Telegram (状态: $tg_status, 风格: ${WATCHTOWER_TEMPLATE_STYLE:-professional})"
            "2. 设置服务器别名 (当前: $alias_status)"
            "3. 配置 Email (当前未使用)"
            "4. 发送手动测试通知"
            "5. 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"
        local choice; choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) _configure_telegram; press_enter_to_continue ;;
            2) _configure_alias; press_enter_to_continue ;;
            3) _configure_email; press_enter_to_continue ;;
            4) 
                if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then log_warn "请先配置 Telegram。"
                else log_info "发送测试消息..."; local safe_ver=$(_escape_markdown "$SCRIPT_VERSION"); send_test_notify "*🔔 手动测试*\n来自 \`${safe_ver}\`。状态: ✅ 成功连接"; log_success "已尝试发送。"; fi
                press_enter_to_continue ;;
            5) 
                if confirm_action "清空所有通知配置?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "已清空。"; _prompt_rebuild_if_needed; fi
                press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

_configure_schedule() {
    echo -e "${CYAN}请选择运行模式:${NC}\n1. 间隔循环 (可对齐整点)\n2. 自定义 Cron (高级)"
    local mode_choice; mode_choice=$(_prompt_for_menu_choice "1-2")
    
    if [ "$mode_choice" = "1" ]; then
        local interval_hour=""
        while true; do
            interval_hour=$(_prompt_user_input "每隔几小时运行? (0=使用分钟): " "")
            if [[ "$interval_hour" =~ ^[0-9]+$ ]]; then break; fi
            log_warn "请输入数字。"
        done
        
        if [ "$interval_hour" -gt 0 ]; then
            echo -e "${CYAN}选择对齐:${NC}\n1. 从现在起算\n2. 对齐整点(:00)\n3. 对齐半点(:30)"
            local align_choice; align_choice=$(_prompt_for_menu_choice "1-3")
            if [ "$align_choice" = "1" ]; then
                WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$((interval_hour * 3600)); WATCHTOWER_SCHEDULE_CRON=""
            else
                WATCHTOWER_RUN_MODE="aligned"; local minute="0"; [ "$align_choice" = "3" ] && minute="30"
                WATCHTOWER_SCHEDULE_CRON="0 $minute */$interval_hour * * *"; WATCHTOWER_CONFIG_INTERVAL="0"
            fi
        else
            WATCHTOWER_RUN_MODE="interval"
            WATCHTOWER_CONFIG_INTERVAL=$(_prompt_for_interval "300" "频率")
            WATCHTOWER_SCHEDULE_CRON=""
        fi
    elif [ "$mode_choice" = "2" ]; then
        WATCHTOWER_RUN_MODE="cron"
        echo -e "${CYAN}6段 Cron (秒 分 时 日 月 周)${NC}"
        read -r -p "表达式 (留空保留原值): " cron_input < /dev/tty
        if [ -n "$cron_input" ]; then WATCHTOWER_SCHEDULE_CRON="$cron_input"; WATCHTOWER_CONFIG_INTERVAL="0"; fi
    fi
}

configure_watchtower(){
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then
        if ! confirm_action "Watchtower 运行中，将覆盖设置，继续?"; then return 10; fi
    fi

    _configure_schedule; sleep 0.5; configure_exclusion_list
    
    local extra_args_choice; extra_args_choice=$(_prompt_user_input "配置额外参数？(y/N): " "")
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then 
        echo -e "当前: ${GREEN}${temp_extra_args:-[无]}${NC}"
        local val; read -r -p "新参数 (空格清空): " val < /dev/tty
        if [[ "$val" =~ ^\ +$ ]]; then temp_extra_args=""; elif [ -n "$val" ]; then temp_extra_args="$val"; fi
    fi
    
    local debug_choice; debug_choice=$(_prompt_user_input "启用 Debug? (y/N): " "")
    local temp_debug_enabled="false"; if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi
    
    WATCHTOWER_EXTRA_ARGS="$temp_extra_args"
    WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"
    WATCHTOWER_ENABLED="true"
    save_config
    _rebuild_watchtower || return 1; return 0
}

configure_exclusion_list() {
    declare -A excluded_map; local initial_exclude_list="${WATCHTOWER_EXCLUDE_LIST:-}"
    if [ -n "$initial_exclude_list" ]; then 
        local IFS=,; for c in $initial_exclude_list; do c=$(echo "$c" | xargs); [ -n "$c" ] && excluded_map["$c"]=1; done; unset IFS
    fi
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a all_containers_array=(); while IFS= read -r line; do all_containers_array+=("$line"); done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}')
        local -a items_array=(); local i=0
        while [ $i -lt ${#all_containers_array[@]} ]; do 
            local container="${all_containers_array[$i]}"; local is_excluded=" "
            if [ -n "${excluded_map[$container]+_}" ]; then is_excluded="✔"; fi
            items_array+=("$((i + 1)). [${GREEN}${is_excluded}${NC}] $container"); i=$((i + 1))
        done
        items_array+=("")
        local current_excluded_display="无"
        if [ ${#excluded_map[@]} -gt 0 ]; then local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; current_excluded_display="${keys[*]}"; IFS="$old_ifs"; fi
        items_array+=("${CYAN}当前忽略: ${current_excluded_display}${NC}")
        _render_menu "忽略更新名单" "${items_array[@]}"
        
        local choice; read -r -p "选择 (数字切换, c 结束, 回车清空): " choice < /dev/tty
        case "$choice" in
            c|C) break ;;
            "") if [ ${#excluded_map[@]} -gt 0 ]; then if confirm_action "清空名单?"; then excluded_map=(); fi; fi; continue ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' '); IFS=',' read -r -a selected_indices <<< "$clean_choice"
                for index in "${selected_indices[@]}"; do
                    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#all_containers_array[@]} ]; then
                        local target="${all_containers_array[$((index - 1))]}"; if [ -n "${excluded_map[$target]+_}" ]; then unset excluded_map["$target"]; else excluded_map["$target"]=1; fi
                    fi
                done ;;
        esac
    done
    local final_excluded_list=""; if [ ${#excluded_map[@]} -gt 0 ]; then local keys=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; final_excluded_list="${keys[*]}"; IFS="$old_ifs"; fi
    WATCHTOWER_EXCLUDE_LIST="$final_excluded_list"
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        _render_menu "⚙️ 服务运维 ⚙️" "1. 停止并移除服务 (卸载)" "2. 重建服务 (应用新配置)"
        local choice; choice=$(_prompt_for_menu_choice "1-2")
        case "$choice" in
            1) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then 
                    if confirm_action "确定卸载 Watchtower 吗？"; then 
                        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower >/dev/null 2>&1; set -e
                        WATCHTOWER_ENABLED="false"; save_config; echo -e "${GREEN}✅ 已移除。${NC}"
                    fi
                else echo -e "${YELLOW}Watchtower 未运行。${NC}"; fi; press_enter_to_continue ;;
            2) 
                if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then 
                    if confirm_action "重建 Watchtower？"; then _rebuild_watchtower; fi
                else echo -e "${YELLOW}Watchtower 未运行。${NC}"; fi; press_enter_to_continue ;;
            "") return ;; *) sleep 1 ;;
        esac
    done
}

_parse_watchtower_timestamp_from_log_line() {
    local line="$1"; local ts
    ts=$(echo "$line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | cut -d'.' -f1 | sed 's/T/ /')
    echo "$ts"
}

_extract_interval_from_cmd(){
    local cmd_json="$1"; local interval=""
    if command -v jq >/dev/null 2>&1; then
        interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
    else
        local tokens; read -r -a tokens <<< "$(echo "$cmd_json" | tr -d '[],"')"
        local prev=""
        for t in "${tokens[@]}"; do if [ "$prev" = "--interval" ]; then interval="$t"; break; fi; prev="$t"; done
    fi
    interval=$(echo "$interval" | sed -n 's/[^0-9]//g;p')
    if [ -z "$interval" ]; then echo ""; else echo "$interval"; fi
}

_extract_schedule_from_env(){
    if ! command -v jq >/dev/null 2>&1; then echo ""; return; fi
    local env_json; env_json=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Env}}' 2>/dev/null || echo "[]")
    echo "$env_json" | jq -r '.[] | select(startswith("WATCHTOWER_SCHEDULE=")) | split("=")[1]' | head -n1 || true
}

get_watchtower_inspect_summary(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then echo ""; return 2; fi
    local cmd; cmd=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    _extract_interval_from_cmd "$cmd" 2>/dev/null || true
}

get_watchtower_all_raw_logs(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then echo ""; return 1; fi
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 500 watchtower 2>&1 || true
}

_calculate_next_cron() {
    local cron_expr="$1"; local sec min hour day month dow
    read -r sec min hour day month dow <<< "$cron_expr"
    if [[ "$sec" == "0" && "$min" == "0" ]]; then
        if [[ "$day" == "*" && "$month" == "*" && "$dow" == "*" ]]; then
            if [[ "$hour" == "*" ]]; then echo "每小时整点"
            elif [[ "$hour" =~ ^\*/([0-9]+)$ || "$hour" =~ \*/([0-9]+) ]]; then echo "每 ${BASH_REMATCH[1]} 小时"
            elif [[ "$hour" =~ ^[0-9]+$ ]]; then echo "每天 ${hour}:00"
            else echo "$cron_expr"; fi
        else echo "$cron_expr"; fi
    elif [[ "$sec" == "0" && "$hour" == "*" && "$day" == "*" ]]; then
        if [[ "$min" =~ \*/([0-9]+) ]]; then echo "每 ${BASH_REMATCH[1]} 分钟"; else echo "$cron_expr"; fi
    else echo "$cron_expr"; fi
}

_get_watchtower_next_run_time(){
    local interval_seconds="$1" raw_logs="$2" schedule_env="$3"
    if [ -n "$schedule_env" ]; then local readable; readable=$(_calculate_next_cron "$schedule_env"); echo -e "${CYAN}定时: ${readable}${NC}"; return; fi
    if [ -z "$raw_logs" ] || [ -z "$interval_seconds" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local last_event_line; last_event_line=$(echo "$raw_logs" | grep -E "Session done|Scheduling first run" | tail -n 1 || true)
    if [ -z "$last_event_line" ]; then echo -e "${YELLOW}等待首扫...${NC}"; return; fi

    local current_epoch; current_epoch=$(date +%s)
    local ts_str; ts_str=$(_parse_watchtower_timestamp_from_log_line "$last_event_line")
    
    if [ -n "$ts_str" ]; then
        local last_epoch=""
        if date -d "$ts_str" "+%s" >/dev/null 2>&1; then last_epoch=$(date -d "$ts_str" "+%s")
        elif command -v gdate >/dev/null 2>&1; then last_epoch=$(gdate -d "$ts_str" "+%s"); fi
        
        if [ -n "$last_epoch" ]; then
            local next_epoch=$((last_epoch + interval_seconds))
            while [ "$next_epoch" -le "$current_epoch" ]; do next_epoch=$((next_epoch + interval_seconds)); done
            local remaining=$((next_epoch - current_epoch))
            local h=$((remaining / 3600)) m=$(( (remaining % 3600) / 60 )) s=$(( remaining % 60 ))
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" "$h" "$m" "$s" "$NC"; return
        fi
    fi
    echo -e "${YELLOW}计算中...${NC}"
}

show_container_info() {
    _print_header "容器状态看板"
    if ! command -v docker >/dev/null 2>&1; then log_err "Docker 未找到。"; return; fi
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}"
    echo ""; press_enter_to_continue
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local interval raw_logs schedule_env COUNTDOWN
        set +e; interval=$(get_watchtower_inspect_summary || true); raw_logs=$(get_watchtower_all_raw_logs || true); schedule_env=$(_extract_schedule_from_env); set -e
        COUNTDOWN=$(_get_watchtower_next_run_time "${interval}" "${raw_logs}" "${schedule_env}")
        
        local -a content_array=("⏱️  ${CYAN}下一次扫描:${NC} ${COUNTDOWN}" "" "📜  ${CYAN}最近日志摘要:${NC}")
        local logs_tail; logs_tail=$(echo "$raw_logs" | tail -n 5)
        while IFS= read -r line; do content_array+=("    ${line:0:80}..."); done <<< "$logs_tail"
        
        _render_menu "📊 详情与管理 📊" "${content_array[@]}"
        local pick; read -r -p "$(echo -e "> ${ORANGE}[1]${NC}实时日志 ${ORANGE}[2]${NC}容器看板 ${ORANGE}[3]${NC}触发扫描 (↩ 返回): ")" pick < /dev/tty
        case "$pick" in
            1) if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then trap '' INT; JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'exit 10' INT; else echo -e "${RED}未运行。${NC}"; fi; press_enter_to_continue ;;
            2) show_container_info ;;
            3) run_watchtower_once; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

view_and_edit_config(){
    local -a config_items=("TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "忽略名单|WATCHTOWER_EXCLUDE_LIST|string_list" "服务器别名|WATCHTOWER_HOST_ALIAS|string" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "运行模式|WATCHTOWER_RUN_MODE|schedule" "检测频率|WATCHTOWER_CONFIG_INTERVAL|interval" "通知风格|WATCHTOWER_TEMPLATE_STYLE|string")
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local -a content_array=(); local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"; local label; label=$(echo "$item" | cut -d'|' -f1); local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3); local val="${!var_name}"; local disp=""; local col="${CYAN}"
            case "$type" in
                string) if [ -n "$val" ]; then col="${GREEN}"; disp="$val"; else col="${RED}"; disp="未设置"; fi ;;
                string_list) if [ -n "$val" ]; then col="${YELLOW}"; disp="${val//,/, }"; else col="${CYAN}"; disp="无"; fi ;;
                bool) if [ "$val" = "true" ]; then col="${GREEN}"; disp="是"; else col="${CYAN}"; disp="否"; fi ;;
                interval) if [[ "${WATCHTOWER_RUN_MODE:-}" =~ ^(cron|aligned)$ ]]; then disp="禁用"; col="${YELLOW}"; else disp=$(_format_seconds_to_human "$val"); [ "$disp" != "N/A" ] && [ -n "$val" ] && col="${GREEN}" || { col="${RED}"; disp="未设置"; }; fi ;;
                schedule) if [[ "$val" =~ ^(cron|aligned)$ ]]; then disp="Cron ($WATCHTOWER_SCHEDULE_CRON)"; col="${GREEN}"; else disp="间隔 ($(_format_seconds_to_human "${WATCHTOWER_CONFIG_INTERVAL:-0}"))"; col="${CYAN}"; fi ;;
            esac
            content_array+=("$(printf "%2d. %s: %s%s%s" "$((i + 1))" "$label" "$col" "$disp" "$NC")")
        done
        _render_menu "高级参数编辑器" "${content_array[@]}"
        local choice; choice=$(_prompt_for_menu_choice "1-${#config_items[@]}")
        if [ -z "$choice" ]; then return; fi
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then continue; fi
        local item="${config_items[$((choice - 1))]}"; local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3)
        case "$type" in
            string|string_list) 
                if [ "$var_name" = "WATCHTOWER_EXCLUDE_LIST" ]; then configure_exclusion_list
                elif [ "$var_name" = "WATCHTOWER_TEMPLATE_STYLE" ]; then
                    local p; p=$(_prompt_for_menu_choice "1. professional, 2. friendly")
                    [ "$p" = "2" ] && declare "$var_name"="friendly" || declare "$var_name"="professional"
                else
                    local v; read -r -p "新值 (空格清空): " v < /dev/tty
                    if [[ "$v" =~ ^\ +$ ]]; then declare "$var_name"=""; elif [ -n "$v" ]; then declare "$var_name"="$v"; fi
                fi ;;
            bool) local b; b=$(_prompt_user_input "启用? (y/N): " ""); if echo "$b" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi ;;
            interval) 
                if [[ "${WATCHTOWER_RUN_MODE:-}" =~ ^(cron|aligned)$ ]]; then log_warn "当前为定时任务模式，请修改'运行模式'。"; sleep 2
                else local nv; nv=$(_prompt_for_interval "${!var_name:-300}" "新间隔"); [ -n "$nv" ] && declare "$var_name"="$nv"; fi ;;
            schedule) _configure_schedule ;;
        esac
        save_config; _prompt_rebuild_if_needed; sleep 1
    done
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local STATUS_RAW="未运行"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower' >/dev/null 2>&1; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR="${RED}未运行${NC}"; [ "$STATUS_RAW" = "已启动" ] && STATUS_COLOR="${GREEN}已启动${NC}"
        
        local notify_mode="${CYAN}关闭${NC}"; if [ -n "${TG_BOT_TOKEN:-}" ]; then notify_mode="${GREEN}Telegram${NC}"; fi
        local interval=""; local raw_logs=""; local schedule_env=""
        if [ "$STATUS_RAW" = "已启动" ]; then 
            interval=$(get_watchtower_inspect_summary || true)
            raw_logs=$(get_watchtower_all_raw_logs || true)
            schedule_env=$(_extract_schedule_from_env)
        fi
        local COUNTDOWN=$(_get_watchtower_next_run_time "${interval}" "${raw_logs}" "${schedule_env}")
        local TOTAL; TOTAL=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.ID}}' 2>/dev/null | wc -l || echo "0")
        local RUNNING; RUNNING=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.ID}}' 2>/dev/null | wc -l || echo "0"); local STOPPED=$((TOTAL - RUNNING))

        local -a main_content=(
            "🕝 运行状态: ${STATUS_COLOR}" 
            "🔔 消息通知: ${notify_mode}"
            "⏳ 下次扫描: ${COUNTDOWN}" 
            "📦 容器统计: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
            "" "1. 部署/配置服务" "2. 通知设置" "3. 服务管理" "4. 高级参数" "5. 看板与日志"
        )
        _render_menu "Watchtower 管理器 (v${SCRIPT_VERSION})" "${main_content[@]}"
        local choice; choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) set +e; configure_watchtower; local rc=$?; set -e; [ "$rc" -ne 10 ] && press_enter_to_continue ;;
            2) notification_menu ;;
            3) manage_tasks ;;
            4) view_and_edit_config ;;
            5) show_watchtower_details ;;
            "") return 0 ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

main(){ 
    case "${1:-}" in --run-once) run_watchtower_once; exit $? ;; esac
    trap 'echo -e "\n操作被中断。"; exit 10' INT TERM
