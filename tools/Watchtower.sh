#!/usr/bin/env bash
# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.5.1-配置文件安全加固)
# =============================================================
# 作者：系统运维组
# 描述：Docker 容器自动更新管理 (Watchtower) 封装脚本
# 版本历史：
#   v6.5.1 - 强制配置文件归属于 root(600)，修复脚本不完整问题
#   v6.5.0 - 集成网络连通性检查，优化 .env 文件生成安全性
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.5.1"

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
    # 降级函数，确保在无 utils.sh 的环境下也能基本运行
    log_err() { echo "[错误] $*" >&2; }
    log_info() { echo "[信息] $*"; }
    log_warn() { echo "[警告] $*"; }
    log_success() { echo "[成功] $*"; }
    check_network_connectivity() { return 0; }
    _render_menu() { local title="$1"; shift; echo "--- $title ---"; printf " %s\n" "$@"; }
    press_enter_to_continue() { read -r -p "按 Enter 继续..."; }
    confirm_action() { local choice; read -r -p "$1 ([y]/n): " choice; case "$choice" in n|N) return 1;; *) return 0;; esac; }
    _prompt_user_input() { local val; read -r -p "$1" val; echo "${val:-$2}"; }
    _prompt_for_menu_choice() { local val; read -r -p "请选择 [${1}]: " val; echo "$val"; }
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

# 本地配置文件路径 (安全优先，兼容旧版)
CONFIG_DIR="/opt/vps_install_modules/configs"
CONFIG_FILE="${CONFIG_DIR}/watchtower.conf"
LEGACY_CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# 运行时环境文件路径
ENV_FILE="${SCRIPT_DIR}/watchtower.env"
ENV_FILE_LAST_RUN="${SCRIPT_DIR}/watchtower.env.last_run"

# --- 模块变量 (定义默认值) ---
TG_BOT_TOKEN=""
TG_CHAT_ID=""
WATCHTOWER_EXCLUDE_LIST="portainer,portainer_agent"
WATCHTOWER_EXTRA_ARGS=""
WATCHTOWER_DEBUG_ENABLED="false"
WATCHTOWER_CONFIG_INTERVAL="21600"
WATCHTOWER_ENABLED="false"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"
WATCHTOWER_HOST_ALIAS="$(hostname | tr -d '\n' | cut -c -15)"
WATCHTOWER_RUN_MODE="interval"
WATCHTOWER_SCHEDULE_CRON=""
WATCHTOWER_TEMPLATE_STYLE="professional"

# --- 配置加载与保存 ---
load_config(){
    # 优先加载新路径，其次加载旧路径
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" &>/dev/null || true
    elif [ -f "$LEGACY_CONFIG_FILE" ]; then
        log_warn "检测到旧版配置文件，将自动迁移至新路径。"
        # shellcheck source=/dev/null
        source "$LEGACY_CONFIG_FILE" &>/dev/null || true
    fi
}

save_config(){
    # 安全加固：写入临时文件，然后以 root 身份移动并设置权限
    local tmp_conf; tmp_conf=$(mktemp)
    
    cat > "$tmp_conf" <<EOF
# Watchtower 模块配置文件 (自动生成于 $(date))
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
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

    # 确保目录存在且归属 root
    run_with_sudo mkdir -p "$CONFIG_DIR"
    run_with_sudo chown root:root "$CONFIG_DIR"
    
    # 移动、设置所有权和权限
    run_with_sudo mv "$tmp_conf" "$CONFIG_FILE"
    run_with_sudo chown root:root "$CONFIG_FILE"
    run_with_sudo chmod 600 "$CONFIG_FILE"

    # 如果旧文件存在，则安全删除
    if [ -f "$LEGACY_CONFIG_FILE" ]; then
        rm -f "$LEGACY_CONFIG_FILE"
    fi
}

# --- 预加载配置与依赖检查 ---
load_config
if ! command -v docker &> /dev/null; then log_err "Docker 未安装。"; exit 10; fi
if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker info >/dev/null 2>&1; then log_err "无法连接到 Docker 服务。"; exit 10; fi

# --- 核心：生成环境文件 ---
_generate_env_file() {
    local alias_name="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    alias_name=$(echo "$alias_name" | tr -d '\n\r')
    
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
                tpl+="{{ if .Entries -}}*🎉 好消息！有容器完成了升级～*${br}${br}{{- range .Entries }}• {{ .Message }}${br}{{- end }}${br}一切都在高效运行中 🚀${br}{{- else -}}*🌟 完美！所有容器都是最新版*${br}${br}你维护得真棒～ 👍${br}{{- end -}}${br}—— 来自 \`${alias_name}\`"
            else
                tpl+="*🛡️ Watchtower 报告*${br}${br}*主机*: \`${alias_name}\`${br}${br}{{ if .Entries -}}*📈 更新摘要*${br}{{- range .Entries }}• {{ .Message }}${br}{{- end }}{{- else -}}*✨ 状态完美*${br}所有容器均为最新，无需干预。${br}{{- end -}}"
            fi
            printf "WATCHTOWER_NOTIFICATION_TEMPLATE=%s\n" "$tpl"
        fi
        if [[ "$WATCHTOWER_RUN_MODE" =~ ^(cron|aligned)$ ]] && [ -n "$WATCHTOWER_SCHEDULE_CRON" ]; then
            echo "WATCHTOWER_SCHEDULE=$WATCHTOWER_SCHEDULE_CRON"
        fi
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# --- 核心启动逻辑 ---
_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2"
    local interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower"
    _generate_env_file

    local docker_run_args=("-h" "${WATCHTOWER_HOST_ALIAS:-DockerNode}" "--env-file" "$ENV_FILE" "-v" "/var/run/docker.sock:/var/run/docker.sock")
    local wt_args=("--cleanup")
    local run_container_name="watchtower"

    if [ "$interactive_mode" = "true" ]; then
        run_container_name="watchtower-once"
        docker_run_args+=("--rm" "--name" "$run_container_name")
        wt_args+=("--run-once")
    else
        docker_run_args+=("-d" "--name" "$run_container_name" "--restart" "unless-stopped")
        if [[ ! "$WATCHTOWER_RUN_MODE" =~ ^(cron|aligned)$ ]]; then
            wt_args+=("--interval" "${wt_interval:-300}")
        fi
    fi
    
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then wt_args+=("--debug"); fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; wt_args+=("${extra_tokens[@]}"); fi
    
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    local container_names_to_watch=()
    if [ -n "$final_exclude_list" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names_to_watch < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names_to_watch[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then log_err "监控范围为空，无法启动。"; return 1; fi
    fi

    if [ "$interactive_mode" = "false" ]; then
        log_info "正在拉取最新 Watchtower 镜像..."
        if ! check_network_connectivity "registry-1.docker.io"; then log_warn "连接 Docker Hub 可能受限。"; fi
    fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null; set -e
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names_to_watch[@]:-}")
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "执行手动扫描..."
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        log_success "扫描结束"
    else
        log_info "正在启动 $mode_description..."
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; set -e
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "服务已就绪"
            cp -f "$ENV_FILE" "$ENV_FILE_LAST_RUN"
        else
            log_err "启动失败"
        fi
    fi
}

_rebuild_watchtower() {
    log_info "重建 Watchtower..."; set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    if ! _start_watchtower_container_logic "${WATCHTOWER_CONFIG_INTERVAL}" "Watchtower (监控模式)"; then
        WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
}

run_watchtower_once(){
    if ! confirm_action "运行一次 Watchtower 更新所有容器?"; then return 1; fi
    _start_watchtower_container_logic "" "" true
}

# ... (菜单和交互函数，由于是完整脚本，全部恢复)
_escape_markdown() { echo "$1" | sed 's/_/\\_/g; s/*/\\*/g; s/`/\\`/g; s/\[/\\[/g'; }
send_test_notify() {
    if ! command -v jq &>/dev/null; then log_err "缺少 jq。"; return; fi
    check_network_connectivity "api.telegram.org" || log_warn "TG API 连接可能受阻。"
    local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    local data; data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$1" '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
    timeout 10s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url"
}
_prompt_for_interval() {
    local default="$1" msg="$2" current="$(_format_seconds_to_human "$default")" input
    while true; do
        input=$(_prompt_user_input "$msg (如: 1h, 30m, 当前: $current): " "")
        if [ -z "$input" ]; then echo "$default"; return 0; fi
        local s=0
        if [[ "$input" =~ ^([0-9]+)$ ]]; then s="$input"
        elif [[ "$input" =~ ^([0-9]+)s$ ]]; then s="${BASH_REMATCH[1]}"
        elif [[ "$input" =~ ^([0-9]+)m$ ]]; then s=$(( "${BASH_REMATCH[1]}" * 60 ))
        elif [[ "$input" =~ ^([0-9]+)h$ ]]; then s=$(( "${BASH_REMATCH[1]}" * 3600 ))
        elif [[ "$input" =~ ^([0-9]+)d$ ]]; then s=$(( "${BASH_REMATCH[1]}" * 86400 ))
        else log_warn "无效格式。"; continue; fi
        if [ "$s" -gt 0 ]; then echo "$s"; return 0; fi
    done
}
_configure_schedule() {
    echo -e "1. 间隔循环\n2. 自定义 Cron"
    local choice; choice=$(_prompt_for_menu_choice "1-2")
    if [ "$choice" = "1" ]; then
        local h; h=$(_prompt_user_input "每隔几小时? (0=使用分钟): " "")
        if [ "${h:-0}" -gt 0 ]; then
            echo -e "1. 此时起算\n2. 整点(:00)\n3. 半点(:30)"; local align; align=$(_prompt_for_menu_choice "1-3")
            if [ "$align" = "1" ]; then WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$((h * 3600)); else
                WATCHTOWER_RUN_MODE="aligned"; local min="0"; [ "$align" = "3" ] && min="30"; WATCHTOWER_SCHEDULE_CRON="0 $min */$h * * *"
            fi
        else WATCHTOWER_RUN_MODE="interval"; WATCHTOWER_CONFIG_INTERVAL=$(_prompt_for_interval "300" "频率"); fi
    elif [ "$choice" = "2" ]; then WATCHTOWER_RUN_MODE="cron"; read -r -p "Cron表达式 (6段): " WATCHTOWER_SCHEDULE_CRON; fi
}
configure_watchtower(){
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then
        if ! confirm_action "Watchtower 正在运行。继续将覆盖配置，确认?"; then return 10; fi
    fi
    _configure_schedule; configure_exclusion_list; WATCHTOWER_ENABLED="true"; save_config; _rebuild_watchtower
}
configure_exclusion_list(){
    declare -A excluded; local IFS=,; for c in $WATCHTOWER_EXCLUDE_LIST; do [ -n "$c" ] && excluded["$c"]=1; done; unset IFS
    while true; do
        mapfile -t all < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}')
        local -a items; for i in "${!all[@]}"; do local c="${all[i]}"; items+=("$((i+1)). [${excluded[$c]+✔}] $c"); done
        _render_menu "配置忽略名单" "${items[@]}"; local choice; read -r -p "选择切换 (c 结束): " choice
        if [[ "$choice" =~ ^(c|C|)$ ]]; then break; fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#all[@]}" ]; then
            local c="${all[$((choice-1))]}"; if [ -n "${excluded[$c]+_}" ]; then unset excluded["$c"]; else excluded["$c"]=1; fi
        fi
    done
    local keys=("${!excluded[@]}"); local old_ifs="$IFS"; IFS=,; WATCHTOWER_EXCLUDE_LIST="${keys[*]}"; IFS="$old_ifs"
}
notification_menu(){
    while true; do
        _render_menu "通知配置" "1. Telegram" "2. 服务器别名" "3. 测试通知"
        local choice; choice=$(_prompt_for_menu_choice "1-3")
        case "$choice" in
            1) read -r -p "Bot Token: " TG_BOT_TOKEN; read -r -p "Chat ID: " TG_CHAT_ID ;;
            2) read -r -p "服务器别名: " WATCHTOWER_HOST_ALIAS ;;
            3) send_test_notify "*🔔 手动测试*\n来自 Watchtower 模块的测试。" ;;
            *) save_config; return ;;
        esac
    done
}
manage_tasks(){
    _render_menu "服务运维" "1. 停止并卸载" "2. 重建服务"
    local choice; choice=$(_prompt_for_menu_choice "1-2")
    if [ "$choice" = "1" ]; then
        run_with_sudo docker rm -f watchtower; WATCHTOWER_ENABLED="false"; save_config; log_success "已卸载"
    elif [ "$choice" = "2" ]; then _rebuild_watchtower; fi
}
show_watchtower_details(){
    log_info "正在获取实时日志 (Ctrl+C 停止)..."
    trap '' INT; run_with_sudo docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n中断。"; exit 10' INT
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local status="${RED}未运行${NC}"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then status="${GREEN}已启动${NC}"; fi
        local notify_mode="${CYAN}关闭${NC}"; if [ -n "$TG_BOT_TOKEN" ]; then notify_mode="${GREEN}Telegram${NC}"; fi
        _render_menu "Watchtower 管理器 (v${SCRIPT_VERSION})" "状态: $status" "通知: $notify_mode" "" "1. 部署/配置服务" "2. 通知设置" "3. 服务管理" "4. 手动扫描一次" "5. 实时日志"
        local choice; choice=$(_prompt_for_menu_choice "1-5")
        case "$choice" in
            1) set +e; configure_watchtower; local rc=$?; set -e; [ "$rc" -ne 10 ] && press_enter_to_continue ;;
            2) notification_menu; press_enter_to_continue ;;
            3) manage_tasks; press_enter_to_continue ;;
            4) run_watchtower_once; press_enter_to_continue ;;
            5) show_watchtower_details; press_enter_to_continue ;;
            "") return 0 ;;
            *) log_warn "无效选项"; sleep 1 ;;
        esac
    done
}

main(){ 
    case "${1:-}" in --run-once) run_watchtower_once; exit $? ;; esac
    trap 'echo -e "\n中断。"; exit 10' INT
    log_info "Watchtower 模块 ${SCRIPT_VERSION}" >&2
    main_menu
    exit 10
}

main "$@"
