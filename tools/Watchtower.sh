#!/usr/bin/env bash
#
# Docker 自动更新助手 (v3.7.0 - 全面 UI/UX 美化)
#
set -euo pipefail

export LC_ALL=C.utf8

VERSION="v3.7.0-ui-overhaul"

SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"
if [ ! -w "$(dirname "$CONFIG_FILE")" ]; then
  CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

if [ -t 1 ] || [[ "${FORCE_COLOR:-}" == "true" ]]; then
  COLOR_GREEN="\033[0;32m"; COLOR_RED="\033[0;31m"; COLOR_YELLOW="\033[0;33m"
  COLOR_BLUE="\033[0;34m"; COLOR_CYAN="\033[0;36m"; COLOR_RESET="\033[0m"
else
  COLOR_GREEN=""; COLOR_RED=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""; COLOR_RESET=""
fi

if ! command -v docker >/dev/null 2>&1; then echo -e "${COLOR_RED}❌ 错误: 未检测到 'docker' 命令。${COLOR_RESET}"; exit 1; fi
if ! docker ps -q >/dev/null 2>&1; then echo -e "${COLOR_RED}❌ 错误:无法连接到 Docker。${COLOR_RESET}"; exit 1; fi

WT_EXCLUDE_CONTAINERS_FROM_CONFIG="${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_CONF_DEFAULT_INTERVAL="${WATCHTOWER_CONF_DEFAULT_INTERVAL:-}"
WT_CONF_DEFAULT_CRON_HOUR="${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-}"
WT_CONF_ENABLE_REPORT="${WATCHTOWER_CONF_ENABLE_REPORT:-}"

load_config(){ if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null || true; fi; }; load_config

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"; TG_CHAT_ID="${TG_CHAT_ID:-}"; EMAIL_TO="${EMAIL_TO:-}"; WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"; WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"; WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"; WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"; DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"; CRON_HOUR="${CRON_HOUR:-4}"; CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"

log_info(){ printf "%b[信息] %s%b\n" "$COLOR_BLUE" "$*" "$COLOR_RESET"; }; log_warn(){ printf "%b[警告] %s%b\n" "$COLOR_YELLOW" "$*" "$COLOR_RESET"; }; log_err(){ printf "%b[错误] %s%b\n" "$COLOR_RED" "$*" "$COLOR_RESET"; }
_format_seconds_to_human() { local seconds="$1"; if [ -z "$seconds" ] || ! [[ "$seconds" =~ ^[0-9]+$ ]]; then echo "N/A"; return; fi; if [ "$seconds" -lt 3600 ]; then echo "${seconds}s"; else local hours=$((seconds / 3600)); echo "${hours}h"; fi; }

generate_line() { 
    local len=${1:-62}
    local char="─"
    printf '%*s' "$len" | tr ' ' "$char"
}

_print_header() {
    local title=" $1 "
    local total_width=62
    
    # Properly calculate display width of title with potential multi-byte characters
    local plain_title; plain_title=$(echo -e "$title" | sed 's/\x1b\[[0-9;]*m//g')
    local total_chars=${#plain_title}
    local ascii_chars_only; ascii_chars_only=$(echo "$plain_title" | tr -dc '[ -~]')
    local ascii_count=${#ascii_chars_only}
    local non_ascii_count=$((total_chars - ascii_count))
    local title_width=$((ascii_count + non_ascii_count * 2))

    local padding_total=$((total_width - title_width))
    local padding_left=$((padding_total / 2))
    
    echo
    echo -e "${COLOR_YELLOW}╭$(generate_line $padding_left)${title}$(generate_line $((padding_total - padding_left)))╮${COLOR_RESET}"
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
confirm_action() { read -r -p "$(echo -e "${COLOR_YELLOW}$1 ([y]/n): ${COLOR_RESET}")" choice; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }
press_enter_to_continue() { read -r -p "$(echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}")"; }
send_notify() {
  local MSG="$1"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then curl -s --retry 3 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$MSG" --data-urlencode "parse_mode=Markdown" >/dev/null || log_warn "⚠️ Telegram 发送失败。"; fi
  if [ -n "$EMAIL_TO" ]; then if command -v mail &>/dev/null; then echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || log_warn "⚠️ Email 发送失败。"; else log_warn "⚠️ 未检测到 mail 命令。"; fi; fi
}
_start_watchtower_container_logic(){
  local wt_interval="$1"; local mode_description="$2"; echo "⬇️ 正在拉取 Watchtower 镜像..."; set +e; docker pull containrrr/watchtower >/dev/null 2>&1 || true; set -e
  local timezone="${JB_TIMEZONE:-Asia/Shanghai}"
  local cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-300}")
  if [ "$mode_description" = "一次性更新" ]; then cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" --rm --name watchtower-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once); fi
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      cmd_parts+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}?parse_mode=Markdown")
      if [[ "${WT_CONF_ENABLE_REPORT}" == "true" ]]; then cmd_parts+=(-e WATCHTOWER_REPORT=true); fi
      local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*...'; cmd_parts+=(-e WATCHTOWER_NOTIFICATION_TEMPLATE="$NOTIFICATION_TEMPLATE") # Simplified for brevity
  fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi; 
  if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  local final_exclude_list=""; local source_msg="";
  if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本内部"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; source_msg="config.json"; fi
  local containers_to_monitor=()
  if [ -n "$final_exclude_list" ]; then
      log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"
      local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
      local included_containers; included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
      if [ -n "$included_containers" ]; then readarray -t containers_to_monitor <<< "$included_containers"; log_info "计算后的监控范围: ${containers_to_monitor[*]}"; else log_warn "排除规则导致监控列表为空！"; fi
  else
      log_info "未发现排除规则，Watchtower 将监控所有容器。"
  fi
  echo -e "${COLOR_BLUE}--- 正在启动 $mode_description ---${COLOR_RESET}"
  if [ ${#containers_to_monitor[@]} -gt 0 ]; then cmd_parts+=("${containers_to_monitor[@]}"); fi
  echo -e "${COLOR_CYAN}执行命令: ${cmd_parts[*]} ${COLOR_RESET}"; set +e; "${cmd_parts[@]}"; local rc=$?; set -e
  if [ "$mode_description" = "一次性更新" ]; then 
      if [ $rc -eq 0 ]; then echo -e "${COLOR_GREEN}✅ $mode_description 完成。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ $mode_description 失败。${COLOR_RESET}"; fi; return $rc
  else
    sleep 3; 
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_GREEN}✅ $mode_description 启动成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ $mode_description 启动失败。${COLOR_RESET}"; send_notify "❌ Watchtower 启动失败。"; fi
    return 0
  fi
}
_configure_telegram() { read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"; read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"; log_info "Telegram 配置已更新。"; }
_configure_email() { read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; log_info "Email 配置已更新。"; }
notification_menu() {
    while true; do
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
        _print_header "⚙️ 通知配置 ⚙️"
        local tg_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$TG_BOT_TOKEN" ]; then tg_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi
        local email_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$EMAIL_TO" ]; then email_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi
        printf " 1. 配置 Telegram  (%b)\n" "$tg_status"
        printf " 2. 配置 Email      (%b)\n" "$email_status"
        echo " 3. 发送测试通知"
        echo " 4. 清空所有通知配置"
        echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
        read -r -p "请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [[ -z "$TG_BOT_TOKEN" && -z "$EMAIL_TO" ]]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${VERSION} 的*测试消息*。"; log_info "测试通知已发送 (请检查您的客户端)。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
# ... (中间大部分函数不变，为简洁省略) ...
# 您可以从 v3.3.9 复制 show_container_info, _prompt_for_interval, configure_exclusion_list,
# configure_watchtower, manage_tasks, 以及所有 get_* 和 _format* 函数

main_menu(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; load_config
    _print_header "Docker 助手 v${VERSION}"
    
    local STATUS_COLOR STATUS_RAW COUNTDOWN TOTAL RUNNING STOPPED
    STATUS_RAW="$(docker ps --format '{{.Names}}' | grep -q '^watchtower$' && echo '已启动' || echo '未运行')"
    if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${COLOR_GREEN}已启动${COLOR_RESET}"; else STATUS_COLOR="${COLOR_RED}未运行${COLOR_RESET}"; fi
    local interval=""; if [ "$STATUS_RAW" = "已启动" ]; then interval=$(get_watchtower_inspect_summary); fi; local raw_logs=""; if [ "$STATUS_RAW" = "已启动" ]; then raw_logs=$(get_watchtower_all_raw_logs); fi
    COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
    TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l); RUNNING=$(docker ps --format '{{.ID}}' | wc -l); STOPPED=$((TOTAL - RUNNING))
    
    printf "Watchtower 状态: %b (名称排除模式)\n" "$STATUS_COLOR"
    printf "下次检查: %b\n" "$COUNTDOWN"
    printf "容器概览: 总计 %s (%b运行中%s, %b已停止%s%b)\n" "${TOTAL}" "${COLOR_GREEN}" "${RUNNING}" "${COLOR_RED}" "${STOPPED}" "${COLOR_RESET}"
    
    local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE=""
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
        FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
        FINAL_EXCLUDE_SOURCE="脚本"
    elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then
        FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"
        FINAL_EXCLUDE_SOURCE="config.json"
    fi
    if [ -n "$FINAL_EXCLUDE_LIST" ]; then
        printf "🚫 排除列表 (%s): %b%s%b\n" "$FINAL_EXCLUDE_SOURCE" "${COLOR_YELLOW}" "${FINAL_EXCLUDE_LIST//,/, }" "${COLOR_RESET}"
    fi

    local NOTIFY_STATUS=""; if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then NOTIFY_STATUS="Telegram"; fi; if [[ -n "$EMAIL_TO" ]]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS+=", Email"; else NOTIFY_STATUS="Email"; fi; fi; if [ -n "$NOTIFY_STATUS" ]; then printf "🔔 通知已启用: %b%s%b\n" "${COLOR_GREEN}" "${NOTIFY_STATUS}" "${COLOR_RESET}"; fi
    
    echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
    echo "主菜单："
    echo "1. 配置 Watchtower 与排除列表"
    echo "2. 容器管理"
    echo "3. 配置通知"
    echo "4. 任务管理"
    echo "5. 查看/编辑配置 (底层)"
    echo "6. 手动更新所有容器"
    echo "7. Watchtower 详情"
    echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
    read -r -p "输入选项 [1-7] 或按 Enter 返回: " choice
    
    case "$choice" in
      1) configure_watchtower || true; press_enter_to_continue ;;
      2) show_container_info ;;
      3) notification_menu ;;
      4) manage_tasks ;;
      5) view_and_edit_config ;;
      6) run_watchtower_once; press_enter_to_continue ;;
      7) show_watchtower_details ;;
      "") exit 10 ;; 
      *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;;
    esac
  done
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    main_menu;
    exit 10
}
main
