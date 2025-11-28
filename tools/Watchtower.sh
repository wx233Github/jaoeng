# =============================================================
# 🚀 Watchtower 自动更新管理器 (v6.5.0-挂载修复版)
# - 核心修复: 改用文件挂载方式注入通知模板，彻底解决环境变量传参导致模板失效的问题。
# - 交互升级: 修改配置后会自动检测运行状态并提示重建容器。
# - 视觉降噪: 模板文件内置关键词过滤，屏蔽无关的配置日志。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v6.5.0"

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

if ! declare -f run_with_sudo &>/dev/null; then
  log_err "致命错误: run_with_sudo 函数未定义。请确保从 install.sh 启动此脚本。"
  exit 1
fi

# 配置文件与模板路径
CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"
HOST_TEMPLATE_FILE="$HOME/.watchtower_notification.tpl" # 宿主机上的模板文件路径

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

# --- 配置加载 ---
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" &>/dev/null || true
    fi
    local default_interval="21600"
    local default_cron_hour="4"
    local default_exclude_list="portainer,portainer_agent"
    local default_notify_on_no_updates="true"
    local default_alias; if [ ${#HOSTNAME} -gt 15 ]; then default_alias="DockerNode"; else default_alias="$(hostname)"; fi

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
    WATCHTOWER_HOST_ALIAS="${WATCHTOWER_HOST_ALIAS:-${WATCHTOWER_CONF_HOST_ALIAS:-$default_alias}}"
}
load_config

# --- 依赖检查 ---
if ! command -v docker &> /dev/null; then log_err "Docker 未安装。"; exit 10; fi
if ! docker info >/dev/null 2>&1; then log_err "Docker 服务未运行。"; exit 10; fi

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
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}

_print_header() { echo -e "\n${BLUE}--- ${1} ---${NC}"; }

_format_seconds_to_human(){
    local s="$1"; if ! [[ "$s" =~ ^[0-9]+$ ]] || [ "$s" -le 0 ]; then echo "N/A"; return; fi
    local d=$((s/86400)); local h=$(((s%86400)/3600)); local m=$(((s%3600)/60)); local sec=$((s%60)); local r=""
    [ "$d" -gt 0 ] && r+="${d}天"; [ "$h" -gt 0 ] && r+="${h}小时"; [ "$m" -gt 0 ] && r+="${m}分"; [ "$sec" -gt 0 ] && r+="${sec}秒"
    echo "${r:-0秒}"
}

# --- 核心：生成并写入模板文件 ---
_write_template_file() {
    local show_no_updates="$1"
    
    # 使用 cat EOF 将模板写入宿主机文件
    # 逻辑：只显示包含 "Found", "Stopping", "Creating", "Updated" 等关键词的行
    # 从而屏蔽 "Using notifications", "Checking" 等干扰信息
    cat > "$HOST_TEMPLATE_FILE" <<EOF
{{- \$events := .Entries -}}
{{- \$realUpdates := false -}}
{{- range \$events -}}
  {{- if or (contains .Message "Found new") (contains .Message "Stopping") (contains .Message "Creating") (contains .Message "Updated") -}}
    {{- \$realUpdates = true -}}
  {{- end -}}
{{- end -}}

{{- if \$realUpdates -}}
🚀 *执行日志:*
{{- range \$events }}
  {{- if or (contains .Message "Found new") (contains .Message "Stopping") (contains .Message "Creating") (contains .Message "Updated") }}
> {{ .Message }}
  {{- end }}
{{- end }}

{{- else if eq "${show_no_updates}" "true" -}}
✅ *检查完成*
所有服务均为最新。
{{- end -}}
EOF
}

_check_and_prompt_rebuild() {
    # 检查 Watchtower 是否正在运行
    if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
        echo ""
        if confirm_action "检测到 Watchtower 正在运行。配置已变更，是否立即重建以生效？"; then
            _rebuild_watchtower
        else
            log_warn "配置已保存，但将在下次重建容器时生效。"
        fi
    fi
}

_start_watchtower_container_logic(){
    load_config
    local wt_interval="$1"
    local mode_description="$2"
    local interactive_mode="${3:-false}"
    local wt_image="containrrr/watchtower"
    local container_names=()
    
    local run_hostname="${WATCHTOWER_HOST_ALIAS:-DockerNode}"
    local docker_run_args=(-e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "${run_hostname}")
    local wt_args=("--cleanup")

    # 1. 处理通知配置
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        # 生成模板文件到宿主机
        _write_template_file "${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
        
        # 挂载模板文件到容器内部 /etc/watchtower/notification.tpl
        docker_run_args+=(-v "${HOST_TEMPLATE_FILE}:/etc/watchtower/notification.tpl")
        
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATIONS=shoutrrr")
        # 移除 title 参数，避免 Shoutrrr 解析错误
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&preview=false")
        
        # 修改标题前缀
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_TITLE_TAG=Watchtower")
        
        # 关键：指定模板文件路径，而不是传递内容字符串
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE=/etc/watchtower/notification.tpl")
        
        # 启用报告模式
        docker_run_args+=(-e "WATCHTOWER_NOTIFICATION_REPORT=true")
        
        log_info "✅ Telegram 通知已启用 (挂载模式)"
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
    
    # 排除列表逻辑
    local final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$final_exclude_list" ]; then
        local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        mapfile -t container_names < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower|watchtower-once)$" || true)
        if [ ${#container_names[@]} -eq 0 ] && [ "$interactive_mode" = "false" ]; then
            log_err "忽略名单导致监控范围为空，无法启动。"
            return 1
        fi
        if [ "$interactive_mode" = "false" ]; then log_info "监控范围: ${container_names[*]}"; fi
    else 
        if [ "$interactive_mode" = "false" ]; then log_info "监控所有容器。"; fi
    fi

    if [ "$interactive_mode" = "false" ]; then echo "⬇️ 拉取镜像..."; fi
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    if [ "$interactive_mode" = "false" ]; then _print_header "启动 $mode_description"; fi
    
    local final_command_to_run=(docker run "${docker_run_args[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    if [ "$interactive_mode" = "true" ]; then
        log_info "正在执行立即更新扫描... (输出实时日志)"
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"
        log_success "手动扫描结束"
        return 0
    else
        if [ "$interactive_mode" = "false" ]; then
            local final_cmd_str=""; for arg in "${final_command_to_run[@]}"; do final_cmd_str+=" $(printf %q "$arg")"; done
            echo -e "${CYAN}执行命令: ... docker run ...${NC}"
        fi
        set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo "${final_command_to_run[@]}"; local rc=$?; set -e
        
        sleep 1
        if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then
            log_success "服务启动成功 [$mode_description]"
        else
            log_err "服务启动失败"
        fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower..."; 
    set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e
    local interval="${WATCHTOWER_CONFIG_INTERVAL}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower (监控模式)"; then
        log_err "重建失败！"; WATCHTOWER_ENABLED="false"; save_config; return 1
    fi
    send_test_notify "🔄 服务已重建。这是一条测试消息，验证 Telegram 通道通畅。"
}

run_watchtower_once(){
    if ! confirm_action "运行一次 Watchtower 更新所有容器？"; then log_info "已取消"; return 1; fi
    _start_watchtower_container_logic "" "" true
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
        if [[ "$input_value" =~ ^[0-9]+$ ]]; then seconds="$input_value";
        elif [[ "$input_value" =~ ^([0-9]+)s$ ]]; then seconds="${BASH_REMATCH[1]}";
        elif [[ "$input_value" =~ ^([0-9]+)m$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 60 ));
        elif [[ "$input_value" =~ ^([0-9]+)h$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 3600 ));
        elif [[ "$input_value" =~ ^([0-9]+)d$ ]]; then seconds=$(( "${BASH_REMATCH[1]}" * 86400 ));
        else log_warn "格式无效"; continue; fi
        if [ "$seconds" -gt 0 ]; then echo "$seconds"; return 0; else log_warn "必须为正数"; fi
    done
}

send_test_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        if ! command -v jq &>/dev/null; then log_err "缺少 jq"; return; fi
        local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        local data; data=$(jq -n --arg chat_id "$TG_CHAT_ID" --arg text "$message" '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')
        timeout 10s curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$data" "$url"
    fi
}

_configure_telegram() {
    local TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN_INPUT=$(_prompt_user_input "Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " "$TG_BOT_TOKEN")
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT}"
    local TG_CHAT_ID_INPUT; TG_CHAT_ID_INPUT=$(_prompt_user_input "Chat ID (当前: ${TG_CHAT_ID}): " "$TG_CHAT_ID")
    TG_CHAT_ID="${TG_CHAT_ID_INPUT}"
    local notify_on_no_updates_choice; notify_on_no_updates_choice=$(_prompt_user_input "无更新时也通知？(Y/n, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " "")
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Nn]$'; then WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; else WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"; fi
    save_config
    _check_and_prompt_rebuild
}

_configure_alias() {
    local new_alias; new_alias=$(_prompt_user_input "设置服务器别名 (用于通知标题): " "${WATCHTOWER_HOST_ALIAS}")
    if [ -z "$new_alias" ]; then new_alias="DockerNode"; fi
    WATCHTOWER_HOST_ALIAS="$new_alias"
    save_config
    _check_and_prompt_rebuild
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local alias_status="${CYAN}${WATCHTOWER_HOST_ALIAS:-默认}${NC}"
        local -a content_array=("1. 配置 Telegram ($tg_status)" "2. 设置服务器别名 ($alias_status)" "3. 发送手动测试通知" "4. 清空配置")
        _render_menu "⚙️ 通知配置 ⚙️" "${content_array[@]}"
        local choice; choice=$(_prompt_for_menu_choice "1-4")
        case "$choice" in
            1) _configure_telegram ;;
            2) _configure_alias ;;
            3) if [ -z "$TG_BOT_TOKEN" ]; then log_warn "请先配置"; else send_test_notify "测试消息"; log_success "已发送"; fi; press_enter_to_continue ;;
            4) if confirm_action "清空所有配置？"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"; save_config; log_info "已清空"; _check_and_prompt_rebuild; fi ;;
            "") return ;; *) log_warn "无效"; sleep 1 ;;
        esac
    done
}

configure_watchtower(){
    local current_interval="${WATCHTOWER_CONFIG_INTERVAL}"
    local new_interval; new_interval=$(_prompt_for_interval "$current_interval" "检测频率")
    
    configure_exclusion_list
    
    local extra_args_choice; extra_args_choice=$(_prompt_user_input "配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " "")
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then temp_extra_args=$(_prompt_user_input "输入参数: " "$temp_extra_args"); fi
    
    WATCHTOWER_CONFIG_INTERVAL="$new_interval"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_ENABLED="true"
    save_config
    _check_and_prompt_rebuild
}

configure_exclusion_list() {
    declare -A excluded_map; local initial_list="${WATCHTOWER_EXCLUDE_LIST}"
    if [ -n "$initial_list" ]; then local IFS=,; for c in $initial_list; do c=$(echo "$c" | xargs); [ -n "$c" ] && excluded_map["$c"]=1; done; unset IFS; fi
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a all_c=(); while IFS= read -r line; do all_c+=("$line"); done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}')
        local -a items=(); local i=0
        while [ $i -lt ${#all_c[@]} ]; do 
            local c="${all_c[$i]}"; local mk=" "; [ -n "${excluded_map[$c]+_}" ] && mk="✔"; items+=("$((i + 1)). [${GREEN}${mk}${NC}] $c"); i=$((i + 1))
        done
        items+=("")
        local curr_disp="无"; if [ ${#excluded_map[@]} -gt 0 ]; then local k=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; curr_disp="${k[*]}"; IFS="$old_ifs"; fi
        items+=("${CYAN}当前忽略: ${curr_disp}${NC}")
        _render_menu "忽略更新名单" "${items[@]}"
        local choice; choice=$(_prompt_for_menu_choice "数字" "c,回车")
        case "$choice" in
            c|C) break ;;
            "") excluded_map=(); log_info "已清空"; continue ;;
            *)
                local clean_c=$(echo "$choice" | tr -d ' '); IFS=',' read -r -a idxs <<< "$clean_c"
                for idx in "${idxs[@]}"; do
                    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le ${#all_c[@]} ]; then
                        local tc="${all_c[$((idx - 1))]}"; if [ -n "${excluded_map[$tc]+_}" ]; then unset excluded_map["$tc"]; else excluded_map["$tc"]=1; fi
                    fi
                done
                ;;
        esac
    done
    local final=""; if [ ${#excluded_map[@]} -gt 0 ]; then local k=("${!excluded_map[@]}"); local old_ifs="$IFS"; IFS=,; final="${k[*]}"; IFS="$old_ifs"; fi
    WATCHTOWER_EXCLUDE_LIST="$final"
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local -a items=("1. 停止/移除服务" "2. 重建服务 (应用配置)")
        _render_menu "⚙️ 服务运维 ⚙️" "${items[@]}"
        local choice; choice=$(_prompt_for_menu_choice "1-2")
        case "$choice" in
            1) if confirm_action "移除 Watchtower？"; then set +e; JB_SUDO_LOG_QUIET="true" run_with_sudo docker rm -f watchtower &>/dev/null; set -e; WATCHTOWER_ENABLED="false"; save_config; echo -e "${GREEN}✅ 已移除${NC}"; fi; press_enter_to_continue ;;
            2) if confirm_action "重建 Watchtower？"; then _rebuild_watchtower; fi; press_enter_to_continue ;;
            "") return ;; *) sleep 1 ;;
        esac
    done
}

get_watchtower_inspect_summary(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo ""; return 2; fi
    local cmd; cmd=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    if command -v jq &>/dev/null; then echo "$cmd" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true; fi
}

get_watchtower_all_raw_logs(){
    if ! JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}' | grep -qFx 'watchtower'; then echo ""; return 1; fi
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs --tail 500 watchtower 2>&1 || true
}

show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local interval; interval=$(get_watchtower_inspect_summary)
        local raw_logs; raw_logs=$(get_watchtower_all_raw_logs)
        local -a lines=("⏱️  ${CYAN}状态${NC}" "    ${YELLOW}检测间隔:${NC} ${interval:-300}秒" "" "📜  ${CYAN}日志摘要${NC}")
        local logs_tail; logs_tail=$(echo "$raw_logs" | tail -n 5)
        while IFS= read -r line; do lines+=("    ${line:0:80}..."); done <<< "$logs_tail"
        _render_menu "📊 详情 📊" "${lines[@]}"
        read -r -p "$(echo -e "> ${ORANGE}[1]${NC}日志 ${ORANGE}[2]${NC}看板 ${ORANGE}[3]${NC}扫描 (↩ 返回): ")" pick < /dev/tty
        case "$pick" in
            1) JB_SUDO_LOG_QUIET="true" run_with_sudo docker logs -f --tail 100 watchtower || true; press_enter_to_continue ;;
            2) show_container_info ;;
            3) run_watchtower_once; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

show_container_info() {
    # 简化版容器列表展示，仅展示核心信息
    if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
    echo "--- 容器看板 ---"
    JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    echo ""
    press_enter_to_continue
}

main_menu(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi; load_config
        local status_color="${RED}停止${NC}"; if JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -qFx 'watchtower'; then status_color="${GREEN}运行中${NC}"; fi
        local notify_mode="${CYAN}关${NC}"; if [ -n "$TG_BOT_TOKEN" ]; then notify_mode="${GREEN}Telegram${NC}"; fi
        local total; total=$(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a -q | wc -l)
        local -a content=("状态: ${status_color}" "通知: ${notify_mode}" "容器: $total 个" "" "1. 部署/配置 (核心)" "2. 通知设置" "3. 运维 (停止/重建)" "4. 详情/日志")
        _render_menu "Watchtower 管理" "${content[@]}"
        local choice; choice=$(_prompt_for_menu_choice "1-4")
        case "$choice" in
          1) configure_watchtower ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) show_watchtower_details ;;
          "") return 0 ;;
          *) sleep 1 ;;
        esac
    done
}

main(){ 
    case "${1:-}" in --run-once) run_watchtower_once; exit $? ;; esac
    trap 'echo -e "\n中断"; exit 10' INT
    log_info "Watchtower ${SCRIPT_VERSION}" >&2
    main_menu
    exit 10
}

main "$@"
