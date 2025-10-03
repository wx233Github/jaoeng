#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v3.9.6 - Self-Ensured Bash Environment)
# =============================================================

# --- [Guard]: Ensure this script is run with bash, not sh/dash ---
if [ -z "$BASH_VERSION" ] && [ -z "$_BASH_GUARD_" ]; then
    if [ -x "/bin/bash" ]; then
        export _BASH_GUARD_=1
        exec /bin/bash "$0" "$@"
    else
        echo "Error: /bin/bash is not available. This script requires bash to run." >&2
        exit 1
    fi
fi
unset _BASH_GUARD_

# --- 脚本元数据 ---
SCRIPT_VERSION="v3.9.6"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=C.utf8


# --- 颜色定义 ---
if [[ -t 1 || "${FORCE_COLOR:-}" == "true" ]]; then
  COLOR_GREEN="\033[0;32m"; COLOR_RED="\033[0;31m"; COLOR_YELLOW="\033[0;33m"
  COLOR_BLUE="\033[0;34m"; COLOR_CYAN="\033[0;36m"; COLOR_RESET="\033[0m"
else
  COLOR_GREEN=""; COLOR_RED=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""; COLOR_RESET=""
fi

if ! command -v docker >/dev/null 2>&1; then echo -e "${COLOR_RED}❌ 错误: 未检测到 'docker' 命令。${COLOR_RESET}"; exit 1; fi
if ! docker ps -q >/dev/null 2>&1; then echo -e "${COLOR_RED}❌ 错误:无法连接到 Docker。${COLOR_RESET}"; exit 1; fi

WT_EXCLUDE_CONTAINERS_FROM_CONFIG="${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_CONF_DEFAULT_INTERVAL="${WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"
WT_CONF_DEFAULT_CRON_HOUR="${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"
WT_CONF_ENABLE_REPORT="${WATCHTOWER_CONF_ENABLE_REPORT:-true}"

CONFIG_FILE="/etc/docker-auto-update.conf"
if [[ ! -w "$(dirname "$CONFIG_FILE")" ]]; then
  CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

load_config(){ if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE" &>/dev/null || true; fi; }; load_config

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"; TG_CHAT_ID="${TG_CHAT_ID:-}"; EMAIL_TO="${EMAIL_TO:-}"; WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"; WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"; WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"; WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"; DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"; CRON_HOUR="${CRON_HOUR:-4}"; CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"


# --- 辅助函数 & 日志系统 ---
log_info(){ printf "%b[信息] %s%b\n" "$COLOR_BLUE" "$*" "$COLOR_RESET"; }; log_warn(){ printf "%b[警告] %s%b\n" "$COLOR_YELLOW" "$*" "$COLOR_RESET"; }; log_err(){ printf "%b[错误] %s%b\n" "$COLOR_RED" "$*" "$COLOR_RESET"; }
_format_seconds_to_human() { local seconds="$1"; if ! [[ "$seconds" =~ ^[0-9]+$ ]]; then echo "N/A"; return; fi; if (( seconds < 3600 )); then echo "${seconds}s"; else local hours=$((seconds / 3600)); echo "${hours}h"; fi; }

generate_line() { 
    local len=${1:-62}; local char="─"; local line=""; for ((i=0; i<len; i++)); do line+="$char"; done; echo "$line";
}

_get_visual_width() {
    local text="$1"
    local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local width=0
    local i=0
    local char
    while (( i < ${#plain_text} )); do
        char="${plain_text:i:1}"
        if [[ "$char" =~ [/ -~] ]]; then
            ((width++))
        else
            width=$((width + 2))
        fi
        ((i++))
    done
    echo "$width"
}

_render_menu() {
    local title="$1"
    shift
    
    local -a lines
    readarray -t lines <<< "$@"
    
    local max_width=0
    local line_width
    
    line_width=$(_get_visual_width "$title"); if (( line_width > max_width )); then max_width=$line_width; fi
    
    for line in "${lines[@]}"; do
        line_width=$(_get_visual_width "$line")
        if (( line_width > max_width )); then
            max_width=$line_width
        fi
    done
    
    local box_width=$((max_width + 6))
    if (( box_width < 40 )); then box_width=40; fi
    
    local title_width; title_width=$(_get_visual_width "$title")
    local padding_total=$((box_width - title_width))
    local padding_left=$((padding_total / 2))
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$((padding_total - padding_left))")
    
    echo ""
    echo -e "${COLOR_YELLOW}╭$(generate_line "$box_width")╮${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}│${left_padding}${title}${right_padding}${COLOR_YELLOW}│${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}╰$(generate_line "$box_width")╯${COLOR_RESET}"
    
    for line in "${lines[@]}"; do
        echo -e "$line"
    done
    
    echo -e "${COLOR_BLUE}$(generate_line $((box_width + 2)))${COLOR_RESET}"
}

_print_header() {
    _render_menu "$1" ""
}


save_config(){
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true; cat > "$CONFIG_FILE" <<EOF
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
  chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。";
}
# ... (The rest of the script is unchanged and therefore omitted for brevity)
# The full code is provided in the previous turn.
# ...
main_menu(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; load_config
    
    local STATUS_RAW
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        STATUS_RAW="已启动"
    else
        STATUS_RAW="未运行"
    fi

    local STATUS_COLOR; if [[ "$STATUS_RAW" == "已启动" ]]; then STATUS_COLOR="${COLOR_GREEN}已启动${COLOR_RESET}"; else STATUS_COLOR="${COLOR_RED}未运行${COLOR_RESET}"; fi
    local interval=""; local raw_logs="";
    if [[ "$STATUS_RAW" == "已启动" ]]; then
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
    fi
    
    local COUNTDOWN; COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
    local TOTAL; TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l)
    local RUNNING; RUNNING=$(docker ps --format '{{.ID}}' | wc -l)
    local STOPPED=$((TOTAL - RUNNING))
    
    local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE=""
    if [[ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]]; then FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"; FINAL_EXCLUDE_SOURCE="脚本"; elif [[ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]]; then FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; FINAL_EXCLUDE_SOURCE="config.json"; fi
    
    local NOTIFY_STATUS=""; if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then NOTIFY_STATUS="Telegram"; fi; if [[ -n "$EMAIL_TO" ]]; then if [[ -n "$NOTIFY_STATUS" ]]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi

    local header_text="Docker 助手 v${VERSION}"
    
    local -a lines_to_render
    lines_to_render+=(" 🕝 Watchtower 状态: $STATUS_COLOR (名称排除模式)")
    lines_to_render+=("      ⏳ 下次检查: $COUNTDOWN")
    lines_to_render+=("      📦 容器概览: 总计 $TOTAL (${COLOR_GREEN}运行中 ${RUNNING}${COLOR_RESET}, ${COLOR_RED}已停止 ${STOPPED}${COLOR_RESET})")
    if [[ -n "$FINAL_EXCLUDE_LIST" ]]; then lines_to_render+=(" 🚫 排除列表 (${FINAL_EXCLUDE_SOURCE}): ${COLOR_YELLOW}${FINAL_EXCLUDE_LIST//,/, }${COLOR_RESET}"); fi
    if [[ -n "$NOTIFY_STATUS" ]]; then lines_to_render+=(" 🔔 通知已启用: ${COLOR_GREEN}${NOTIFY_STATUS}${COLOR_RESET}"); fi
    lines_to_render+=("") # Spacer
    lines_to_render+=(" 主菜单：")
    lines_to_render+=("  1. › 配置 Watchtower")
    lines_to_render+=("  2. › 配置通知")
    lines_to_render+=("  3. › 任务管理")
    lines_to_render+=("  4. › 查看/编辑配置 (底层)")
    lines_to_render+=("  5. › 手动更新所有容器")
    lines_to_render+=("  6. › 详情与管理")

    # Use printf to pass lines safely to the renderer
    printf -v content_str '%s\n' "${lines_to_render[@]}"
    _render_menu "$header_text" "$content_str"
    
    read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice
    
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
    if [[ "${1:-}" == "--run-once" ]]; then
        run_watchtower_once
        exit $?
    fi
    main_menu
    exit 10
}

main "$@"
