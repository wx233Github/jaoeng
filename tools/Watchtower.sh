#!/usr/bin/env bash
#
# Docker 自动更新助手 (v2.20.6 - 默认关闭清屏版)
#
set -euo pipefail

# 【终极修复】不信任上游环境，强制自我设定为 UTF-8
export LC_ALL=C.utf8

VERSION="2.20.6-clear-off-by-default"

SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"
if [ ! -w "$(dirname "$CONFIG_FILE")" ]; then
  CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# 颜色定义
if [ -t 1 ]; then
  COLOR_GREEN="\033[0;32m"
  COLOR_RED="\033[0;31m"
  COLOR_YELLOW="\033[0;33m"
  COLOR_BLUE="\033[0;34m"
  COLOR_CYAN="\033[0;36m"
  COLOR_RESET="\033[0m"
else
  COLOR_GREEN=""; COLOR_RED=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""; COLOR_RESET=""
fi

# --- 启动环境检查 ---
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${COLOR_RED}❌ 错误: 未检测到 'docker' 命令。请先安装 Docker。${COLOR_RESET}"
  exit 1
fi

if ! docker ps -q >/dev/null 2>&1; then
    echo -e "${COLOR_RED}❌ 错误:无法连接到 Docker 守护进程 (Docker Daemon)。${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}   请确认 Docker 服务是否已启动并正在运行。${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}   您可以尝试使用以下命令启动 Docker 服务:${COLOR_RESET}"
    echo -e "${COLOR_CYAN}   sudo systemctl start docker${COLOR_RESET}"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${COLOR_YELLOW}⚠️ 警告: 未检测到 'jq'。脚本将使用兼容模式，但建议安装 jq 以获得最佳性能。${COLOR_RESET}"
fi

DATE_D_CAPABLE="false"
if date -d "now" >/dev/null 2>&1; then
  DATE_D_CAPABLE="true"
elif command -v gdate >/dev/null 2>&1 && gdate -d "now" +%s >/dev/null 2>&1; then
  DATE_D_CAPABLE="true"
fi
if [ "$DATE_D_CAPABLE" = "false" ]; then
  echo -e "${COLOR_YELLOW}⚠️ 警告: 系统 'date' 命令不支持 '-d' 选项。日志时间相关功能将受限。${COLOR_RESET}"
fi

# Default config vars
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_LABELS="${WATCHTOWER_LABELS:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-300}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-4}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
log_info(){ printf "%b[信息] %s%b\n" "$COLOR_BLUE" "$*" "$COLOR_RESET"; }
log_warn(){ printf "%b[警告] %s%b\n" "$COLOR_YELLOW" "$*" "$COLOR_RESET"; }
log_err(){ printf "%b[错误] %s%b\n" "$COLOR_RED" "$*" "$COLOR_RESET"; }

_parse_watchtower_timestamp_from_log_line() {
  local log_line="$1"; local timestamp=""
  timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi
  timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi
  timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi
  echo ""; return 1
}

_date_to_epoch() {
  local dt="$1"; [ -z "$dt" ] && echo "" && return
  if [ "$DATE_D_CAPABLE" = "true" ]; then
    if date -d "$dt" +%s >/dev/null 2>&1; then date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo "");
    elif command -v gdate >/dev/null 2>&1 && gdate -d "$dt" +%s >/dev/null 2>&1; then gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""); fi
  else log_warn "⚠️ 'date' 或 'gdate' 不支持，无法解析时间戳。"; echo ""; fi
}

load_config(){ if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null || true; fi; }
load_config

save_config(){
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
  cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_LABELS="${WATCHTOWER_LABELS}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
EOF
  chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。路径: $CONFIG_FILE"; log_info "✅ 配置已保存到 $CONFIG_FILE"
}

confirm_action() { read -r -p "$(echo -e "${COLOR_YELLOW}$1 (y/n): ${COLOR_RESET}")" choice; case "$choice" in y|Y ) return 0 ;; * ) return 1 ;; esac; }
press_enter_to_continue() { read -r -p "$(echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}")"; }

send_notify() {
  local MSG="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then curl -s --retry 3 --retry-delay 5 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$MSG" >/dev/null || log_warn "⚠️ Telegram 通知发送失败。"; fi
  if [ -n "$EMAIL_TO" ]; then if command -v mail &>/dev/null; then echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || log_warn "⚠️ Email 通知发送失败。"; else log_warn "⚠️ 邮件通知启用但未检测到 mail 命令。"; fi; fi
}

select_labels_interactive() {
    local available_labels_str="${WT_AVAILABLE_LABELS:-}"; if [ -z "$available_labels_str" ]; then read -r -p "未扫描到可用标签。请输入要筛选的标签 (留空则不筛选): " WATCHTOWER_LABELS; return; fi
    IFS=',' read -r -a available_labels <<< "$available_labels_str"; local selected_labels=(); if [ -n "$WATCHTOWER_LABELS" ]; then IFS=',' read -r -a selected_labels <<< "$WATCHTOWER_LABELS"; fi
    while true; do
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
        echo -e "${COLOR_YELLOW}请选择要启用自动更新的标签 (按数字键切换选择状态):${COLOR_RESET}"
        for i in "${!available_labels[@]}"; do
            local label="${available_labels[$i]}"; local is_selected=" "; for sel_label in "${selected_labels[@]}"; do if [[ "$sel_label" == "$label" ]]; then is_selected="✔"; break; fi; done
            echo -e " ${YELLOW}$((i+1)).${COLOR_RESET} [${COLOR_GREEN}${is_selected}${COLOR_RESET}] $label"
        done
        echo "-----------------------------------------------------"; echo -e "${COLOR_CYAN}当前已选: ${selected_labels[*]:-无}${COLOR_RESET}"
        read -r -p "输入数字选择/取消，'c' 确认，'a' 全选/全不选，'q' 取消: " choice
        case "$choice" in
            q|Q) selected_labels=(); break ;; c|C|"") break ;; a|A) if [ ${#selected_labels[@]} -eq ${#available_labels[@]} ]; then selected_labels=(); else selected_labels=("${available_labels[@]}"); fi ;;
            *) if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#available_labels[@]}" ]; then
                    local target_label="${available_labels[$((choice-1))]}"; local found=false; local temp_labels=()
                    for item in "${selected_labels[@]}"; do if [[ "$item" == "$target_label" ]]; then found=true; else temp_labels+=("$item"); fi; done
                    if $found; then selected_labels=("${temp_labels[@]}"); else selected_labels+=("$target_label"); fi
                else log_warn "无效输入。" && sleep 1; fi ;;
        esac
    done; WATCHTOWER_LABELS=$(IFS=,; echo "${selected_labels[*]}")
}

show_container_info() {
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
    echo -e "${COLOR_YELLOW}📋 交互式容器管理 📋${COLOR_RESET}"; echo "--------------------------------------------------------------------------------------------------------------------------------"
    printf "%-5s %-25s %-45s %-20s\n" "编号" "容器名称" "镜像" "状态"; echo "--------------------------------------------------------------------------------------------------------------------------------"
    local containers=(); local i=1
    while IFS='|' read -r name image status; do
      containers+=("$name"); local status_colored="$status"
      if [[ "$status" =~ ^Up ]]; then status_colored="${COLOR_GREEN}${status}${COLOR_RESET}"; elif [[ "$status" =~ ^Exited|Created ]]; then status_colored="${COLOR_RED}${status}${COLOR_RESET}"; else status_colored="${COLOR_YELLOW}${status}${COLOR_RESET}"; fi
      printf "%-5s %-25s %-45s %b\n" "$i" "$name" "$image" "$status_colored"; i=$((i+1))
    done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
    echo "--------------------------------------------------------------------------------------------------------------------------------"
    read -r -p "请输入容器编号进行操作，或按 'q'/'Enter' 返回: " choice
    case "$choice" in
      q|Q|"") return ;;
      *) if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo -e "${COLOR_RED}❌ 无效输入。${COLOR_RESET}"; sleep 1; continue; fi
        if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#containers[@]}" ]; then echo -e "${COLOR_RED}❌ 编号超出范围。${COLOR_RESET}"; sleep 1; continue; fi
        local selected_container="${containers[$((choice-1))]}"; if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
        echo -e "${COLOR_CYAN}正在操作容器: ${selected_container}${COLOR_RESET}"; echo "----------------------------------------"
        echo "1) 查看实时日志 (tail -f)"; echo "2) 重启容器"; echo "3) 停止容器"; echo "4) 强制删除容器"; echo "q) 返回列表"
        read -r -p "请为 '${selected_container}' 选择操作: " action
        case "$action" in
          1) echo -e "${COLOR_YELLOW}日志 (Ctrl+C 停止)...${COLOR_RESET}"; docker logs -f --tail 100 "$selected_container" || true; press_enter_to_continue ;;
          2) echo "正在重启..."; if docker restart "$selected_container"; then echo -e "${COLOR_GREEN}✅ 重启成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 重启失败。${COLOR_RESET}"; fi; sleep 1 ;;
          3) echo "正在停止..."; if docker stop "$selected_container"; then echo -e "${COLOR_GREEN}✅ 停止成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 停止失败。${COLOR_RESET}"; fi; sleep 1 ;;
          4) if confirm_action "警告：强制删除 '${selected_container}'？"; then echo "正在删除..."; if docker rm -f "$selected_container"; then echo -e "${COLOR_GREEN}✅ 删除成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 删除失败。${COLOR_RESET}"; fi; sleep 1; else echo "已取消。"; fi ;;
          q|Q|"") ;; *) echo -e "${COLOR_RED}❌ 无效操作。${COLOR_RESET}"; sleep 1 ;;
        esac ;;
    esac
  done
}

_start_watchtower_container_logic(){
  local wt_interval="$1"; local mode_description="$2"
  echo "⬇️ 正在拉取 Watchtower 镜像..."; set +e; docker pull containrrr/watchtower >/dev/null 2>&1 || true; set -e
  local cmd_parts
  if [ "$mode_description" = "一次性更新" ]; then
    cmd_parts=(docker run -e TZ=Asia/Shanghai --rm --name watchtower-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once)
  else
    cmd_parts=(docker run -e TZ=Asia/Shanghai -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-${WATCHTOWER_CONFIG_INTERVAL:-300}}")
  fi
  if [ -n "${WT_EXCLUDE_CONTAINERS:-}" ]; then log_info "已应用排除规则: ${WT_EXCLUDE_CONTAINERS}"; fi
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      cmd_parts+=(-e "WATCHTOWER_NOTIFICATION_URL='telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}'")
      cmd_parts+=(-e WATCHTOWER_REPORT=true)
      echo -e "${COLOR_GREEN}ℹ️ 已配置 Watchtower Telegram 报告 (每次运行后)。${COLOR_RESET}"
  fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi
  if [ -n "$WATCHTOWER_LABELS" ]; then cmd_parts+=("--label-enable"); fi
  if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  echo -e "${COLOR_BLUE}--- 正在启动 $mode_description ---${COLOR_RESET}"
  if [ -n "$WATCHTOWER_LABELS" ]; then cmd_parts+=("$WATCHTOWER_LABELS"); fi
  if [ -n "${WT_EXCLUDE_CONTAINERS:-}" ]; then IFS=',' read -r -a exclude_array <<< "$WT_EXCLUDE_CONTAINERS"; cmd_parts+=("${exclude_array[@]}"); fi
  echo -e "${COLOR_CYAN}执行命令: ${cmd_parts[*]} ${COLOR_RESET}"
  set +e; "${cmd_parts[@]}"; local rc=$?; set -e
  if [ "$mode_description" = "一次性更新" ]; then
    if [ $rc -eq 0 ]; then echo -e "${COLOR_GREEN}✅ $mode_description 完成。${COLOR_RESET}"; return 0; else echo -e "${COLOR_RED}❌ $mode_description 失败，返回码: $rc。${COLOR_RESET}"; return 1; fi
  else
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_GREEN}✅ $mode_description 启动成功。${COLOR_RESET}"; return 0; else echo -e "${COLOR_RED}❌ $mode_description 启动失败。${COLOR_RESET}"; send_notify "❌ Docker 助手：Watchtower 启动失败。"; return 1; fi
  fi
}

_prompt_for_interval() {
  local current_interval_s="$1"; local prompt_msg="$2"; local input_interval=""; local result_interval=""
  while true; do
    read -r -p "$prompt_msg (例: 300s/2h/1d, 默认 ${current_interval_s}s): " input_interval; input_interval=${input_interval:-${current_interval_s}s}
    if [[ "$input_interval" =~ ^([0-9]+)s$ ]]; then result_interval=${BASH_REMATCH[1]}; break;
    elif [[ "$input_interval" =~ ^([0-9]+)h$ ]]; then result_interval=$((${BASH_REMATCH[1]}*3600)); break;
    elif [[ "$input_interval" =~ ^([0-9]+)d$ ]]; then result_interval=$((${BASH_REMATCH[1]}*86400)); break;
    elif [[ "$input_interval" =~ ^[0-9]+$ ]]; then result_interval="${input_interval}"; break;
    else echo -e "${COLOR_RED}❌ 格式错误...${COLOR_RESET}"; fi
  done; echo "$result_interval"
}

configure_watchtower(){
  echo -e "${COLOR_YELLOW}🚀 Watchtower模式${COLOR_RESET}"
  local WT_INTERVAL_TMP="$(_prompt_for_interval "${WT_CONF_DEFAULT_INTERVAL:-${WATCHTOWER_CONFIG_INTERVAL:-300}}" "请输入检查间隔")"; if [ -z "$WT_INTERVAL_TMP" ]; then echo -e "${COLOR_RED}❌ 操作取消。${COLOR_RESET}"; return 1; fi
  WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; read -r -p "是否配置标签筛选？(y/N, 推荐): " label_choice
  if [[ "$label_choice" =~ ^[Yy]$ ]]; then select_labels_interactive; else WATCHTOWER_LABELS=""; fi
  read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
  if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then read -r -p "请输入额外参数: " WATCHTOWER_EXTRA_ARGS; else WATCHTOWER_EXTRA_ARGS=""; fi
  read -r -p "是否启用调试模式? (y/N, 当前: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")): " debug_choice
  WATCHTOWER_DEBUG_ENABLED=$([[ "$debug_choice" =~ ^[Yy]$ ]] && echo "true" || echo "false"); WATCHTOWER_ENABLED="true"; save_config
  set +e; docker rm -f watchtower &>/dev/null || true; set -e
  if ! _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" "Watchtower模式"; then echo -e "${COLOR_RED}❌ Watchtower 启动失败。${COLOR_RESET}"; return 1; fi; return 0
}

configure_cron_task(){
  echo -e "${COLOR_YELLOW}🕑 Cron定时任务模式${COLOR_RESET}"; local CRON_HOUR_TEMP=""; local DIR_TEMP=""
  while true; do
    read -r -p "请输入每天更新的小时 (0-23, 当前: ${WT_CONF_DEFAULT_CRON_HOUR:-${CRON_HOUR:-4}}): " h_in; h_in=${h_in:-${WT_CONF_DEFAULT_CRON_HOUR:-${CRON_HOUR:-4}}}
    if [[ "$h_in" =~ ^[0-9]+$ ]] && [ "$h_in" -ge 0 ] && [ "$h_in" -le 23 ]; then CRON_HOUR_TEMP="$h_in"; break; else echo -e "${COLOR_RED}❌ 小时无效。${COLOR_RESET}"; fi
  done
  while true; do
    read -r -p "请输入 Docker Compose 项目目录 (当前: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}): " d_in; d_in=${d_in:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}
    if [ -z "$d_in" ]; then echo -e "${COLOR_RED}❌ 路径不能为空。${COLOR_RESET}"; elif [ ! -d "$d_in" ]; then echo -e "${COLOR_RED}❌ 目录不存在。${COLOR_RESET}"; else DIR_TEMP="$d_in"; break; fi
  done
  CRON_HOUR="$CRON_HOUR_TEMP"; DOCKER_COMPOSE_PROJECT_DIR_CRON="$DIR_TEMP"; CRON_TASK_ENABLED="true"; save_config
  local SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"; local LOG="/var/log/docker-auto-update-cron.log"
  echo '#!/bin/bash' > "$SCRIPT"; echo "export TZ=Asia/Shanghai" >> "$SCRIPT"; echo "echo \"\$(date '+%Y-%m-%d %H:%M:%S') - 开始更新...\" >> \"$LOG\" 2>&1" >> "$SCRIPT"; echo "cd \"$DOCKER_COMPOSE_PROJECT_DIR_CRON\" >> \"$LOG\" 2>&1 || exit 1" >> "$SCRIPT"; echo "docker compose pull >> \"$LOG\" 2>&1 && docker compose up -d --remove-orphans >> \"$LOG\" 2>&1 && docker image prune -f >> \"$LOG\" 2>&1" >> "$SCRIPT"; chmod +x "$SCRIPT"; (crontab -l 2>/dev/null | grep -v "$SCRIPT" || true; echo "0 $CRON_HOUR * * * $SCRIPT") | crontab -
  send_notify "✅ Cron 设置完成，每天 $CRON_HOUR 点更新。"; echo -e "${COLOR_GREEN}🎉 Cron 设置成功！${COLOR_RESET}"; echo "日志: $LOG"
}

configure_systemd_timer() {
    echo -e "${COLOR_YELLOW}⚙️ Systemd Timer 模式${COLOR_RESET}"; if ! command -v systemctl &>/dev/null; then log_err "错误: 未检测到 systemctl。"; return 1; fi
    local DIR_TEMP; while true; do read -r -p "请输入 Docker Compose 项目目录: " d_in; if [ -z "$d_in" ]; then log_warn "路径不能为空。"; elif [ ! -d "$d_in" ]; then log_warn "目录不存在。"; else DIR_TEMP="$d_in"; break; fi; done
    local SERVICE="/etc/systemd/system/docker-compose-update.service"; local TIMER="/etc/systemd/system/docker-compose-update.timer"
    log_info "创建 service 文件..."; echo -e "[Unit]\nDescription=Daily Docker Compose Update for $DIR_TEMP\nAfter=network.target docker.service\nRequires=docker.service\n[Service]\nType=oneshot\nExecStart=/bin/sh -c 'cd \"$DIR_TEMP\" && docker compose pull && docker compose up -d --remove-orphans && docker image prune -f'" > "$SERVICE"
    log_info "创建 timer 文件..."; local h=${WT_CONF_DEFAULT_CRON_HOUR:-3}; echo -e "[Unit]\nDescription=Run docker-compose-update daily\n[Timer]\nOnCalendar=daily\nPersistent=true\nRandomizedDelaySec=1h\nOnCalendar=*-*-* ${h}:00:00\n[Install]\nWantedBy=timers.target" > "$TIMER"
    log_info "重载 systemd..."; systemctl daemon-reload; systemctl enable --now docker-compose-update.timer; log_success "Systemd Timer 设置成功！"; echo -e "任务将于每天 ${h} 点左右执行。\n状态: ${COLOR_CYAN}systemctl status docker-compose-update.timer${COLOR_RESET}\n日志: ${COLOR_CYAN}journalctl -u docker-compose-update.service${COLOR_RESET}"
}

manage_tasks(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
    echo -e "${COLOR_YELLOW}⚙️ 任务管理 ⚙️${COLOR_RESET}"; echo "1) 停止/移除 Watchtower"; echo "2) 移除 Cron 任务"; echo "3) 移除 Systemd Timer"; echo "4) 重启 Watchtower"; echo "q) 返回"
    read -r -p "请选择: " choice
    case "$choice" in
      1) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then if confirm_action "确定停止并移除 Watchtower？"; then set +e; docker stop watchtower &>/dev/null; docker rm watchtower &>/dev/null; set -e; WATCHTOWER_ENABLED="false"; save_config; send_notify "🗑️ Watchtower 已移除"; echo -e "${COLOR_GREEN}✅ 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;;
      2) local SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"; if crontab -l 2>/dev/null | grep -q "$SCRIPT"; then if confirm_action "确定移除 Cron 任务？"; then (crontab -l 2>/dev/null | grep -v "$SCRIPT") | crontab -; rm -f "$SCRIPT" 2>/dev/null || true; CRON_TASK_ENABLED="false"; save_config; send_notify "🗑️ Cron 任务已移除"; echo -e "${COLOR_GREEN}✅ Cron 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ 未发现 Cron 任务。${COLOR_RESET}"; fi; press_enter_to_continue ;;
      3) if systemctl list-timers | grep -q "docker-compose-update.timer"; then if confirm_action "确定移除 Systemd Timer？"; then systemctl disable --now docker-compose-update.timer &>/dev/null; rm -f /etc/systemd/system/docker-compose-update.{service,timer}; systemctl daemon-reload; log_info "Systemd Timer 已移除。"; fi; else echo -e "${COLOR_YELLOW}ℹ️ 未发现 Systemd Timer。${COLOR_RESET}"; fi; press_enter_to_continue ;;
      4) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo "正在重启..."; if docker restart watchtower; then send_notify "🔄 Watchtower 已重启"; echo -e "${COLOR_GREEN}✅ 重启成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 重启失败。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;;
      q|Q|"") return ;; *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;;
    esac
  done
}

get_watchtower_all_raw_logs(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 1; fi; docker logs --tail 2000 watchtower 2>&1 || true; }

_extract_interval_from_cmd(){
  local cmd_json="$1"; local interval=""; if command -v jq >/dev/null 2>&1; then interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true); else local tokens_str; tokens_str=$(echo "$cmd_json" | tr -d '[],"' | xargs); local tokens=( $tokens_str ); local prev=""; for t in "${tokens[@]}"; do if [ "$prev" = "--interval" ]; then interval="$t"; break; fi; prev="$t"; done; fi
  interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g'); [ -z "$interval" ] && echo "" || echo "$interval"
}

_get_watchtower_remaining_time(){
  local wt_interval_running="$1"; local raw_logs="$2"; if [ -z "$wt_interval_running" ] || [ -z "$raw_logs" ]; then echo -e "${COLOR_YELLOW}N/A${COLOR_RESET}"; return; fi; if ! echo "$raw_logs" | grep -q "Session done"; then echo -e "${COLOR_YELLOW}等待首次扫描...${COLOR_RESET}"; return; fi
  local last_check_log; last_check_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true); local last_check_timestamp_str=""; if [ -n "$last_check_log" ]; then last_check_timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_check_log"); fi
  if [ -n "$last_check_timestamp_str" ]; then
    local last_check_epoch; last_check_epoch=$(_date_to_epoch "$last_check_timestamp_str")
    if [ -n "$last_check_epoch" ]; then local current_epoch; current_epoch=$(date +%s); local time_since_last_check=$((current_epoch - last_check_epoch)); local remaining_time=$((wt_interval_running - time_since_last_check)); if [ "$remaining_time" -gt 0 ]; then local h=$((remaining_time / 3600)); local m=$(((remaining_time % 3600) / 60)); local s=$((remaining_time % 60)); printf "%b%02d时%02d分%02d秒%b" "$COLOR_GREEN" "$h" "$m" "$s" "$COLOR_RESET"; else printf "%b即将进行%b" "$COLOR_GREEN" "$COLOR_RESET"; fi; else echo -e "${COLOR_RED}时间解析失败${COLOR_RESET}"; fi
  else echo -e "${COLOR_YELLOW}未找到扫描日志${COLOR_RESET}"; fi
}

get_watchtower_inspect_summary(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 2; fi; local cmd_json; cmd_json=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]"); _extract_interval_from_cmd "$cmd_json" 2>/dev/null || true; }

get_last_session_time(){
  local raw_logs; raw_logs=$(get_watchtower_all_raw_logs 2>/dev/null || true); if [ -z "$raw_logs" ]; then echo ""; return 1; fi; local last_log_line=""; local timestamp_str=""
  if echo "$raw_logs" | grep -qiE "permission denied|cannot connect"; then echo -e "${COLOR_RED}错误:权限不足${COLOR_RESET}"; return 1; fi
  last_log_line=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true); if [ -n "$last_log_line" ]; then timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line"); if [ -n "$timestamp_str" ]; then echo "$timestamp_str"; return 0; fi; fi
  last_log_line=$(echo "$raw_logs" | grep -E "Scheduling first run" | tail -n 1 || true); if [ -n "$last_log_line" ]; then timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line"); if [ -n "$timestamp_str" ]; then echo "$timestamp_str (首次)"; return 0; fi; fi
  last_log_line=$(echo "$raw_logs" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z? INFO' | tail -n 1 || true); if [ -n "$last_log_line" ]; then timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line"); if [ -n "$timestamp_str" ]; then echo "$timestamp_str (活动)"; return 0; fi; fi
  echo ""; return 1
}

get_updates_last_24h(){
  if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 1; fi; local since_arg=""; if [ "$DATE_D_CAPABLE" = "true" ]; then if date -d "24 hours ago" +%s >/dev/null 2>&1; then since_arg=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true); elif command -v gdate >/dev/null 2>&1; then since_arg=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true); fi; fi
  local raw=""; if [ -n "$since_arg" ]; then raw=$(docker logs --since "$since_arg" watchtower 2>&1 || true); fi; if [ -z "$raw" ]; then raw=$(docker logs --tail 200 watchtower 2>&1 || true); fi
  echo "$raw" | grep -E "Session done|Found new|Stopping /|Creating /|No new images found|unauthorized|Scheduling first run|Could not do a head request|Starting Watchtower" || true
}

_format_and_highlight_log_line(){
  local line="$1"; local timestamp; timestamp=$(_parse_watchtower_timestamp_from_log_line "$line")
  case "$line" in
    *"Session done"*) local f; f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p'); local s; s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p'); local u; u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p'); if [[ -n "$s" && -n "$u" && -n "$f" ]]; then local c="$COLOR_GREEN"; if [ "$f" -gt 0 ]; then c="$COLOR_YELLOW"; fi; printf "%s %b%s%b\n" "$timestamp" "$c" "✅ 扫描: ${s}, 更新: ${u}, 失败: ${f}" "$COLOR_RESET"; else printf "%s %b%s%b\n" "$timestamp" "$COLOR_GREEN" "$line" "$COLOR_RESET"; fi; return ;;
    *"Found new"*) printf "%s %b%s%b\n" "$timestamp" "$COLOR_GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$COLOR_RESET"; return ;;
    *"Stopping "*) printf "%s %b%s%b\n" "$timestamp" "$COLOR_GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$COLOR_RESET"; return ;;
    *"Creating "*) printf "%s %b%s%b\n" "$timestamp" "$COLOR_GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$COLOR_RESET"; return ;;
    *"No new images found"*) printf "%s %b%s%b\n" "$timestamp" "$COLOR_CYAN" "ℹ️ 未发现新镜像。" "$COLOR_RESET"; return ;;
    *"Scheduling first run"*) printf "%s %b%s%b\n" "$timestamp" "$COLOR_GREEN" "🕒 首次运行已调度" "$COLOR_RESET"; return ;;
    *"Starting Watchtower"*) printf "%s %b%s%b\n" "$timestamp" "$COLOR_GREEN" "✨ Watchtower 已启动" "$COLOR_RESET"; return ;;
  esac
  if echo "$line" | grep -qiE "\b(unauthorized|failed|error)\b|permission denied|cannot connect|Could not do a head request"; then
      local error_message; error_message=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p'); if [ -z "$error_message" ]; then error_message=$(echo "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z? *//; s/.*time="[^"]*" *//; s/level=(error|warn|info) *//'); fi
      printf "%s %b%s%b\n" "$timestamp" "$COLOR_RED" "❌ 错误: ${error_message:-$line}" "$COLOR_RESET"; return
  fi; echo "$line"
}

show_watchtower_details(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
    echo "=== Watchtower 运行详情与更新记录 ==="; local interval; interval=$(get_watchtower_inspect_summary 2>/dev/null || true)
    echo "----------------------------------------"; local last_time; last_time=$(get_last_session_time)
    if [ -n "$last_time" ]; then echo "上次活动: $last_time"; else echo "上次活动: 未检测到"; fi
    local raw_logs countdown; raw_logs=$(get_watchtower_all_raw_logs); countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}"); printf "下次检查: %s\n" "$countdown"
    echo "----------------------------------------"; echo "最近 24 小时更新摘要："; echo
    local updates; updates=$(get_updates_last_24h || true)
    if [ -z "$updates" ]; then echo "无相关日志事件。"; else echo "$updates" | tail -n 200 | while IFS= read -r line; do _format_and_highlight_log_line "$line"; done; fi
    echo "----------------------------------------"
    read -r -p "查看实时日志请输入 '1'，按 Enter 返回..." pick
    if [[ "$pick" == "1" ]]; then
      if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "\n按 Ctrl+C 停止查看..."; docker logs --tail 200 -f watchtower 2>/dev/null || true; else echo -e "\n${COLOR_RED}Watchtower 未运行。${COLOR_RESET}"; fi
      press_enter_to_continue
    else return; fi
  done
}

configure_notify(){
  echo -e "${COLOR_YELLOW}⚙️ 通知配置 ⚙️${COLOR_RESET}"; read -r -p "启用 Telegram 通知？(y/N): " tchoice
  if [[ "$tchoice" =~ ^[Yy]$ ]]; then read -r -p "请输入 Bot Token (当前: ${TG_BOT_TOKEN:-空}): " TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"; read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID:-空}): " TG_CHAT_ID_INPUT; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"; else TG_BOT_TOKEN=""; TG_CHAT_ID=""; fi
  read -r -p "启用 Email 通知？(y/N): " echoice
  if [[ "$echoice" =~ ^[Yy]$ ]]; then read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO:-空}): " EMAIL_TO_INPUT; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; else EMAIL_TO=""; fi
  save_config; if [[ -n "$TG_BOT_TOKEN" || -n "$EMAIL_TO" ]]; then if confirm_action "配置已保存。是否发送一条测试通知？"; then echo "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${VERSION} 的测试消息。"; echo -e "${COLOR_GREEN}✅ 已发送。${COLOR_RESET}"; fi; fi
}

run_watchtower_once(){
  echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower${COLOR_RESET}"
  if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_YELLOW}⚠️ Watchtower 正在后台运行。${COLOR_RESET}"; if ! confirm_action "是否继续运行一次性更新？"; then echo -e "${COLOR_YELLOW}已取消。${COLOR_RESET}"; return 0; fi; fi
  if ! _start_watchtower_container_logic "" "一次性更新"; then return 1; fi; return 0
}

view_and_edit_config(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
    load_config; echo -e "${COLOR_YELLOW}⚙️ 脚本配置查看与编辑 ⚙️${COLOR_RESET}"; echo "-------------------------------------------------------------------------------------------------------------------"
    echo " 1) Telegram Bot Token: ${TG_BOT_TOKEN:-未设置}"; echo " 2) Telegram Chat ID:   ${TG_CHAT_ID:-未设置}"; echo " 3) Email 接收地址:     ${EMAIL_TO:-未设置}"; echo " 4) Watchtower 标签筛选: ${WATCHTOWER_LABELS:-无}"; echo " 5) Watchtower 额外参数: ${WATCHTOWER_EXTRA_ARGS:-无}"; echo " 6) Watchtower 调试模式: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")"; echo " 7) Watchtower 配置间隔: ${WATCHTOWER_CONFIG_INTERVAL:-未设置} 秒"; echo " 8) Watchtower 启用状态: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")"; echo " 9) Cron 更新小时:      ${CRON_HOUR:-未设置}"; echo "10) Cron 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"; echo "11) Cron 启用状态: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")"; echo "-------------------------------------------------------------------------------------------------------------------"
    read -r -p "请输入要编辑的编号，或按 Enter 返回: " choice
    case "$choice" in
      1) read -r -p "新 Token: " a; TG_BOT_TOKEN="${a:-$TG_BOT_TOKEN}"; save_config ;; 2) read -r -p "新 Chat ID: " a; TG_CHAT_ID="${a:-$TG_CHAT_ID}"; save_config ;; 3) read -r -p "新 Email: " a; EMAIL_TO="${a:-$EMAIL_TO}"; save_config ;; 4) read -r -p "新标签: " a; WATCHTOWER_LABELS="${a:-}"; save_config ;; 5) read -r -p "新额外参数: " a; WATCHTOWER_EXTRA_ARGS="${a:-}"; save_config ;; 6) read -r -p "启用调试？(y/n): " d; WATCHTOWER_DEBUG_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;;
      7) local new_interval=$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-300}" "新间隔"); if [ -n "$new_interval" ]; then WATCHTOWER_CONFIG_INTERVAL="$new_interval"; save_config; fi ;;
      8) read -r -p "启用 Watchtower？(y/n): " d; WATCHTOWER_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 9) while true; do read -r -p "新 Cron 小时(0-23): " a; if [ -z "$a" ]; then break; fi; if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 0 ] && [ "$a" -le 23 ]; then CRON_HOUR="$a"; save_config; break; else echo "无效"; fi; done ;; 10) read -r -p "新 Cron 目录: " a; DOCKER_COMPOSE_PROJECT_DIR_CRON="${a:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}"; save_config ;; 11) read -r -p "启用 Cron？(y/n): " d; CRON_TASK_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;;
      "") return ;; *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;;
    esac; if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 11 ]; then sleep 0.5; fi
  done
}

update_menu(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"; echo "1) 🚀 Watchtower 模式 (推荐)"; echo "2) ⚙️ Systemd Timer 模式"; echo "3) 🕑 Cron 定时任务 模式"; echo "q) 返回"
    read -r -p "选择 [1-3] 或 q 返回: " c
    case "$c" in
      1) configure_watchtower; break ;; 2) configure_systemd_timer; break ;; 3) configure_cron_task; break ;; q|Q|"") break ;; *) echo -e "${COLOR_YELLOW}无效选择。${COLOR_RESET}"; sleep 1 ;;
    esac
  done
}

main_menu(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; 键，然后 clear; fi
    load_config
    echo "==================== Docker 自动更新与管理助手 v${VERSION} ===================="
    local STATUS_COLOR STATUS_RAW COUNTDOWN TOTAL RUNNING STOPPED
    STATUS_RAW="$(docker ps --format '{{.Names}}' | grep -q '^watchtower$' && echo '已启动' || echo '未运行')"
    if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${COLOR_GREEN}已启动${COLOR_RESET}"; else STATUS_COLOR="${COLOR_RED}未运行${COLOR_RESET}"; fi
    local interval=""; if [ "$STATUS_RAW" = "已启动" ]; then interval=$(get_watchtower_inspect_summary); fi
    local raw_logs=""; if [ "$STATUS_RAW" = "已启动" ]; then raw_logs=$(get_watchtower_all_raw_logs); fi
    COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
    TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l); RUNNING=$(docker ps --format '{{.ID}}' | wc -l); STOPPED=$((TOTAL - RUNNING))
    printf "Watchtower 状态: %b\n" "$STATUS_COLOR"
    printf "下次检查倒计时: %b\n" "$COUNTDOWN"
    printf "容器概览: 总数 %s (%b运行中%s, %b已停止%s)\n" "${TOTAL}" "${COLOR_GREEN}" "${RUNNING}" "${COLOR_RED}" "${STOPPED}"
    local NOTIFY_STATUS=""; if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then NOTIFY_STATUS="Telegram"; fi
    if [[ -n "$EMAIL_TO" ]]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS+=", Email"; else NOTIFY_STATUS="Email"; fi; fi
    if [ -n "$NOTIFY_STATUS" ]; 键，然后 printf "🔔 通知已启用: %b%s%b\n" "${COLOR_GREEN}" "${NOTIFY_STATUS}" "${COLOR_RESET}"; fi
    echo; echo "主菜单选项："
    echo "1) 🔄 设置更新模式"; echo "2) 📋 交互式容器管理"; echo "3) 🔔 配置通知"; echo "4) ⚙️ 任务管理"; echo "5) 📝 查看/编辑配置"; echo "6) ⚡ 手动运行一次更新"; echo "7) 🔍 查看 Watchtower 详情"; echo
    read -r -p "请输入选项 [1-7] 或按 Enter 返回: " choice
    case "$choice" 在
      1) update_menu; press_enter_to_continue ;; 2) show_container_info ;; 3) configure_notify; press_enter_to_continue ;;
      4) manage_tasks ;; 5) view_and_edit_config ;; 6) run_watchtower_once; press_enter_to_continue ;;
      7) show_watchtower_details ;; "") exit 10 ;; *) echo -e "${COLOR_RED}无效选项。${COLOR_RESET}"; sleep 1 ;;
    esac
  done
}

main(){
    main_menu
}

main
