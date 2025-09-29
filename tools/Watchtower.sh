#!/usr/bin/env bash
#
# Docker 自动更新助手（完整可执行脚本 - 修复日志读取顺序 & main_menu）
# Version: 2.17.35-fixed-option7-final-refactored-v2
#
set -euo pipefail
IFS='\n\t'

VERSION="2.17.35-fixed-option7-final-refactored-v2"
SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"
if [ ! -w "$(dirname "$CONFIG_FILE")" ]; then
  CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# Colors
if [ -t 1 ]; then
  COLOR_GREEN="\033[0m\033[0;32m"
  COLOR_RED="\033[0m\033[0;31m"
  COLOR_YELLOW="\033[0m\033[0;33m"
  COLOR_BLUE="\033[0m\033[0;34m"
  COLOR_CYAN="\033[0m\033[0;36m"
  COLOR_RESET="\033[0m"
else
  COLOR_GREEN=""; COLOR_RED=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""; COLOR_RESET=""
fi

# basic checks
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${COLOR_RED}❌ 未检测到 docker 客户端，请安装并确保当前用户可访问 Docker。${COLOR_RESET}"
  exit 1
fi

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${COLOR_YELLOW}⚠️ 未检测到 jq（可选），脚本会使用降级解析方式。建议安装 jq 以获得更准确的功能。${COLOR_RESET}"
fi

# Check for date -d capability
DATE_D_CAPABLE="false"
if date -d "now" >/dev/null 2>&1; then
  DATE_D_CAPABLE="true"
elif command -v gdate >/dev/null 2>&1 && gdate -d "now" +%s >/dev/null 2>&1; then # Added +%s for a more robust check on gdate
  DATE_D_CAPABLE="true"
fi
if [ "$DATE_D_CAPABLE" = "false" ]; then
  echo -e "${COLOR_YELLOW}⚠️ 未检测到支持 '-d' 选项的 'date' 或 'gdate' 命令。日志查询过去24小时功能可能会受限，将回退到最近200行。${COLOR_RESET}"
fi


# Default config vars
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_LABELS="${WATCHTOWER_LABELS:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-300}"
WATCHTOWER_CONFIG_SELF_UPDATE_MODE="${WATCHTOWER_CONFIG_SELF_UPDATE_MODE:-false}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-4}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"

# logging helpers
log_info(){ printf "%b[INFO] %s%b\n" "$COLOR_BLUE" "$*" "$COLOR_RESET"; }
log_warn(){ printf "%b[WARN] %s%b\n" "$COLOR_YELLOW" "$*" "$COLOR_RESET"; }
log_err(){ printf "%b[ERROR] %s%b\n" "$COLOR_RED" "$*" "$COLOR_RESET"; }

# Function to parse various Watchtower log timestamp formats
_parse_watchtower_timestamp_from_log_line() {
  local log_line="$1"
  local timestamp=""

  # Try specific "time=" format (older Watchtower logs)
  timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true)
  if [ -n "$timestamp" ]; then
    echo "$timestamp"
    return 0
  fi

  # Try ISO-like format at the beginning of the line (newer Watchtower logs),
  # including seconds with optional milliseconds/nanoseconds.
  # Example: "2023-10-27T10:30:05Z" or "2023-10-27T10:30:05.123Z" or "2023-10-27T10:30:05.123456789"
  timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true)
  if [ -n "$timestamp" ]; then
    echo "$timestamp"
    return 0
  fi
  
  # Try to extract "YYYY-MM-DD HH:MM:SS" from a line like "Scheduling first run: YYYY-MM-DD HH:MM:SS +0000 UTC"
  timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
  if [ -n "$timestamp" ]; then
    echo "$timestamp"
    return 0
  fi

  # If all else fails, return empty
  echo ""
  return 1
}

_date_to_epoch() {
  local dt="$1"
  [ -z "$dt" ] && echo "" && return
  if [ "$DATE_D_CAPABLE" = "true" ]; then
    if date -d "$dt" +%s >/dev/null 2>&1; then
      date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析时间 '$dt' 失败。"; echo "")
    elif command -v gdate >/dev/null 2>&1 && gdate -d "$dt" +%s >/dev/null 2>&1; then # Redundant if DATE_D_CAPABLE is true, but kept for clarity
      gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析时间 '$dt' 失败。"; echo "")
    fi
  else
    log_warn "⚠️ 未检测到支持 '-d' 选项的 'date' 或 'gdate' 命令，无法将时间 '$dt' 解析为时间戳。"
    echo ""
  fi
}

# config load/save
load_config(){
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || true
  fi
}
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
WATCHTOWER_CONFIG_interval="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_CONFIG_SELF_UPDATE_MODE="${WATCHTOWER_CONFIG_SELF_UPDATE_MODE}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
EOF
  chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限到 600。请手动检查并调整。文件路径: $CONFIG_FILE"
  log_info "✅ 配置已保存到 $CONFIG_FILE"
}

confirm_action() {
  local PROMPT_MSG="$1"
  read -r -p "$(echo -e "${COLOR_YELLOW}$PROMPT_MSG (y/n): ${COLOR_RESET}")" choice
  case "$choice" in
    y|Y ) return 0 ;;
    * ) return 1 ;;
  esac
}

press_enter_to_continue() {
  echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}"
  # drain
  while read -t 0 -r; do read -r; done || true
  read -r || true
}

send_notify() {
  local MSG="$1"
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
    curl -s --retry 3 --retry-delay 5 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=$MSG" >/dev/null || log_warn "⚠️ Telegram 通知发送失败。"
  fi
  if [ -n "$EMAIL_TO" ]; then
    if command -v mail &>/dev/null; then
      echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || log_warn "⚠️ Email 通知发送失败。"
    else
      log_warn "⚠️ 邮件通知启用但未检测到 mail 命令。"
    fi
  fi
}

get_docker_compose_command_main() {
  if command -v docker compose &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    echo ""
  F
}

# -------------------------
# show_container_info
# -------------------------
show_container_info() {
  echo -e "${COLOR_YELLOW}📋 Docker 容器信息：${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}ℹ️ 提示：获取应用版本可能需要对每个运行中的容器执行 'docker exec'，容器越多耗时越长。${COLOR_RESET}"
  printf "% -25s %-45s %-25s %-20s %-15s\n" "容器名称" "镜像" "创建时间" "状态" "应用版本"
  echo "--------------------------------------------------------------------------------------------------------------------------------"
  docker ps -a --format '{{.Names}}|{{.Image}}|{{.CreatedAt}}|{{.Status}}' | while IFS='|' read -r name image created status; do
    local APP_VERSION="N/A"
    local IMAGE_NAME_FOR_LABELS
    IMAGE_NAME_FOR_LABELS=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)

    if [ -n "$IMAGE_NAME_FOR_LABELS" ]; then
      set +e
      APP_VERSION=$(docker image inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)
      APP_VERSION=${APP_VERSION:-}
      if [ -z "$APP_VERSION" ]; then
        APP_VERSION=$(docker image inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "app.version"}}' 2>/dev/null || true)
      fi
      set -e
      APP_VERSION=$(echo "$APP_VERSION" | head -n1 | cut -c 1-20 | tr -d '\n')
      if [ -z "$APP_VERSION" ]; then APP_VERSION="N/A"; fi
    fi

    local is_running
    is_running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo "false")
    if [ "$APP_VERSION" = "N/A" ] && [ "$is_running" = "true" ]; then
      local CONTAINER_APP_EXECUTABLE
      CONTAINER_APP_EXECUTABLE=$(docker exec "$name" sh -c "find /app -maxdepth 1 -type f -executable -print -quit" 2>/dev/null || true)
      if [ -n "$CONTAINER_APP_EXECUTABLE" ]; then
        set +e
        local RAW_VERSION
        # Use timeout for docker exec to prevent hanging on unresponsive containers
        if command -v timeout >/dev/null 2>&1; then
          RAW_VERSION=$(timeout 5s docker exec "$name" sh -c "$CONTAINER_APP_EXECUTABLE --version 2>/dev/null || echo 'N/A'" 2>/dev/null || true)
        else
          RAW_VERSION=$(docker exec "$name" sh -c "$CONTAINER_APP_EXECUTABLE --version 2>/dev/null || echo 'N/A'" 2>/dev/null || true)
        fi
        set -e
        APP_VERSION=$(echo "$RAW_VERSION" | head -n1 | cut -c 1-20 | tr -d '\n')
        if [ -z "$APP_VERSION" ];then APP_VERSION="N/A"; fi
      fi
    fi

    printf "% -25s %-45s %-25s %-20s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
  done
  press_enter_to_continue
}

# -------------------------
# start watchtower
# -------------------------
_start_watchtower_container_logic(){
  local wt_interval="$1"
  local enable_self_update="$2" # This variable is currently unused in the script but kept for future expansion.
  local mode_description="$3"

  echo "⬇️ 正在拉取 Watchtower 镜像..."
  set +e
  docker pull containrrr/watchtower >/dev/null 2>&1 || true
  set -e

  local cmd_parts
  if [ "$mode_description" = "一次性更新" ]; then
    cmd_parts=(docker run -e TZ=Asia/Shanghai --rm --run-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-${WATCHTOWER_CONFIG_INTERVAL:-300}}")
  else
    cmd_parts=(docker run -e TZ=Asia/Shanghai -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-${WATCHTOWER_CONFIG_INTERVAL:-300}}")
  fi

  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
    cmd_parts+=("--debug")
  fi
  if [ -n "$WATCHTOWER_LABELS" ]; then
    cmd_parts+=("--label-enable" "$WATCHTOWER_LABELS")
  fi
  if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then
    # WARNING: This simple split may not work for complex arguments with spaces in values.
    # It's recommended to put each argument as a separate token in WATCHTOWER_EXTRA_ARGS, e.g., "--arg1 val1 --arg2 val2"
    read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"
    cmd_parts+=("${extra_tokens[@]}")
  fi

  echo -e "${COLOR_BLUE}--- 正在启动 $mode_description ---${COLOR_RESET}"
  set +e
  "${cmd_parts[@]}" 2>&1 || true
  local rc=$?
  set -e
  if [ "$mode_description" = "一次性更新" ]; then
    if [ $rc -eq 0 ]; then
      echo -e "${COLOR_GREEN}✅ $mode_description 完成。${COLOR_RESET}"
      send_notify "✅ Docker 自动更新助手：$mode_description 成功。"
      return 0
    else
      echo -e "${COLOR_RED}❌ $mode_description 失败。请查看命令输出。${COLOR_RESET}"
      send_notify "❌ Docker 自动更新助手：$mode_description 失败。"
      return 1
    fi
  else
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
      echo -e "${COLOR_GREEN}✅ $mode_description 启动成功。${COLOR_RESET}"
      send_notify "✅ Docker 自动更新助手：$mode_description 启动成功。"
      return 0
    else
      echo -e "${COLOR_RED}❌ $mode_description 启动失败，请检查 Docker 日志或尝试手动运行 Watchtower 命令。${COLOR_RESET}"
      send_notify "❌ Docker 自动更新助手：$mode_description 启动失败。"
      return 1
    fi
  fi
}

# Helper function for interval input and validation
_prompt_for_interval() {
  local current_interval_s="$1"
  local prompt_msg="$2"
  local input_interval=""
  local result_interval=""

  while true; do
    read -r -p "$prompt_msg (例如 300s / 2h / 1d 或纯数字秒，默认 ${current_interval_s}s): " input_interval
    input_interval=${input_interval:-${current_interval_s}s}
    if [[ "$input_interval" =~ ^([0-9]+)s$ ]]; then
      result_interval=${BASH_REMATCH[1]}; break
    elif [[ "$input_interval" =~ ^([0-9]+)h$ ]]; then
      result_interval=$((${BASH_REMATCH[1]}*3600)); break
    elif [[ "$input_interval" =~ ^([0-9]+)d$ ]]; then
      result_interval=$((${BASH_REMATCH[1]}*86400)); break
    elif [[ "$input_interval" =~ ^[0-9]+$ ]]; then
      result_interval="${input_interval}"; break
    else
      echo -e "${COLOR_RED}❌ 输入格式错误，请使用 '300s','2h','1d' 或纯数字(秒)。${COLOR_RESET}"
    fi
  done
  echo "$result_interval"
}

# -------------------------
# configure_watchtower
# -------------------------
configure_watchtower(){
  echo -e "${COLOR_YELLOW}🚀 Watchtower模式 ${COLOR_RESET}"
  
  local WT_INTERVAL_TMP="$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-300}" "请输入检查更新间隔")"
  if [ -z "$WT_INTERVAL_TMP" ]; then
    echo -e "${COLOR_RED}❌ 间隔时间设置失败，操作取消。${COLOR_RESET}"
    return 1
  fi
  WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"

  read -r -p "是否为 Watchtower 配置标签筛选？(y/N, 当前: ${WATCHTOWER_LABELS:-无}): " label_choice
  if [[ "$label_choice" =~ ^[Yy]$ ]]; then
    read -r -p "请输入 Watchtower 筛选标签 (空输入取消): " WATCHTOWER_LABELS
  else
    WATCHTOWER_LABELS=""
  fi

  read -r -p "是否为 Watchtower 配置额外启动参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
  if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then
    read -r -p "请输入 Watchtower 额外参数 (空输入取消): " WATCHTOWER_EXTRA_ARGS
  else
    WATCHTOWER_EXTRA_ARGS=""
  fi

  read -r -p "是否启用 Watchtower 调试模式 (--debug)？(y/N, 当前: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")): " debug_choice
  if [[ "$debug_choice" =~ ^[Yy]$ ]]; then WATCHTOWER_DEBUG_ENABLED="true"; else WATCHTOWER_DEBUG_ENABLED="false"; fi

  WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false" # Self-update mode is removed from options
  WATCHTOWER_ENABLED="true"
  save_config

  set +e
  docker rm -f watchtower &>/dev/null || true
  set -e

  if ! _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" "false" "Watchtower模式"; then
    echo -e "${COLOR_RED}❌ Watchtower 启动失败。请检查配置或Docker日志。${COLOR_RESET}"
    return 1
  fi
  echo "您可以使用选项2查看 Docker 容器信息，选项7查看 Watchtower 详情。"
  return 0
}

# -------------------------
# configure_cron_task
# -------------------------
configure_cron_task(){
  echo -e "${COLOR_YELLOW}🕑 Cron定时任务模式${COLOR_RESET}"
  local CRON_HOUR_TEMP=""
  local DOCKER_COMPOSE_PROJECT_DIR_TEMP=""

  while true; do
    read -r -p "请输入每天更新的小时 (0-23, 当前: ${CRON_HOUR:-4}): " CRON_HOUR_INPUT
    CRON_HOUR_INPUT=${CRON_HOUR_INPUT:-${CRON_HOUR:-4}}
    if [[ "$CRON_HOUR_INPUT" =~ ^[0-9]+$ ]] && [ "$CRON_HOUR_INPUT" -ge 0 ] && [ "$CRON_HOUR_INPUT" -le 23 ]; then
      CRON_HOUR_TEMP="$CRON_HOUR_INPUT"; break
    else
      echo -e "${COLOR_RED}❌ 小时输入无效，请在 0-23 之间输入。${COLOR_RESET}"
    fi
  done

  while true; do
    read -r -p "请输入 Docker Compose 文件所在的完整目录路径 (例如 /opt/my_docker_project, 当前: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}): " DOCKER_COMPOSE_PROJECT_DIR_INPUT
    DOCKER_COMPOSE_PROJECT_DIR_INPUT=${DOCKER_COMPOSE_PROJECT_DIR_INPUT:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}
    if [ -z "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
      echo -e "${COLOR_RED}❌ 路径不能为空。${COLOR_RESET}"
    elif [ ! -d "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
      echo -e "${COLOR_RED}❌ 指定目录不存在。${COLOR_RESET}"
    else
      DOCKER_COMPOSE_PROJECT_DIR_TEMP="$DOCKER_COMPOSE_PROJECT_DIR_INPUT"; break
    fi
  done

  CRON_HOUR="$CRON_HOUR_TEMP"
  DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_TEMP"
  CRON_TASK_ENABLED="true"
  save_config

  CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
  LOG_FILE="/var/log/docker-auto-update-cron.log"

  cat > "$CRON_UPDATE_SCRIPT" <<'EOF_INNER_SCRIPT'
#!/bin/bash
export TZ=Asia/Shanghai
PROJECT_DIR="{{PROJECT_DIR}}"
LOG_FILE="{{LOG_FILE}}"

echo "
$(date '+%Y-%m-%d %H:%M:%S') - 开始执行 Docker Compose 更新，项目目录: $PROJECT_DIR" >> "$LOG_FILE" 2>&1
if [ ! -d "$PROJECT_DIR" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：项目目录不存在 $PROJECT_DIR" >> "$LOG_FILE" 2>&1
  exit 1
fi

cd "$PROJECT_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') - 无法切换目录 $PROJECT_DIR" >> "$LOG_FILE" 2>&1; exit 1; }

if command -v docker compose &>/dev/null && docker compose version >/dev/null 2>&1; then
  DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  DOCKER_COMPOSE_CMD="docker-compose"
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') - 未找到 docker compose 或 docker-compose" >> "$LOG_FILE" 2>&1
  exit 1
fi

"$DOCKER_COMPOSE_CMD" pull >> "$LOG_FILE" 2>&1 || true
"$DOCKER_COMPOSE_CMD" up -d --remove-orphans >> "$LOG_FILE" 2>&1 || true
docker image prune -f >> "$LOG_FILE" 2>&1 || true

echo "$(date '+%Y-%m-%d %H:%M:%S') - 更新完成" >> "$LOG_FILE" 2>&1
EOF_INNER_SCRIPT

  sed -i "s|{{PROJECT_DIR}}|$DOCKER_COMPOSE_PROJECT_DIR_CRON|g" "$CRON_UPDATE_SCRIPT"
  sed -i "s|{{LOG_FILE}}|$LOG_FILE|g" "$CRON_UPDATE_SCRIPT"
  chmod +x "$CRON_UPDATE_SCRIPT"

  crontab -l 2>/dev/null > /tmp/crontab.backup.$$ || true
  (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT" || true; echo "0 $CRON_HOUR * * * $CRON_UPDATE_SCRIPT") | crontab -
  echo "crontab 已备份：/tmp/crontab.backup.$$"

  send_notify "✅ Cron 定时任务配置完成，每天 $CRON_HOUR 点更新容器，项目目录：$DOCKER_COMPOSE_PROJECT_DIR_CRON"
  echo -e "${COLOR_GREEN}🎉 Cron 定时任务设置成功！${COLOR_RESET}"
  echo "更新日志: $LOG_FILE"
  return 0
}

# -------------------------
# manage_tasks
# -------------------------
manage_tasks(){
  echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
  echo "1) 停止并移除 Watchtower 容器"
  echo "2) 移除 Cron 定时任务"
  read -r -p "请选择 [1-2] 或按 Enter 返回: " MANAGE_CHOICE
  if [ -z "$MANAGE_CHOICE" ]; then return 0; fi
  case "$MANAGE_CHOICE" in
    1)
      if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        if confirm_action "确定停止并移除 Watchtower 吗？"; then
          set +e
          docker stop watchtower &>/dev/null || true
          docker rm watchtower &>/dev/null || true
          set -e
          WATCHTOWER_CONFIG_INTERVAL=""
          WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"
          WATCHTOWER_ENABLED="false"
          save_config
          send_notify "🗑️ Watchtower 已移除"
          echo -e "${COLOR_GREEN}✅ 已停止并移除。${COLOR_RESET}"
        fi
      else
        echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未检测到。${COLOR_RESET}"
      fi
      ;;
    2)
      CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
      if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
        if confirm_action "确定移除 Cron 任务吗？"; then
          (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT") | crontab -
          set +e
          rm -f "$CRON_UPDATE_SCRIPT" &>/dev/null || true
          set -e
          DOCKER_COMPOSE_PROJECT_DIR_CRON=""
          CRON_HOUR=""
          CRON_TASK_ENABLED="false"
          save_config
          send_notify "🗑️ Cron 任务已移除"
          echo -e "${COLOR_GREEN}✅ Cron 任务已移除。${COLOR_RESET}"
        fi
      else
        echo -e "${COLOR_YELLOW}ℹ️ 未检测到由本脚本配置的 Cron 任务。${COLOR_RESET}"
      fi
      ;;
    *)
      echo -e "${COLOR_YELLOW}ℹ️ 已取消。${COLOR_RESET}"
      ;;
  esac
  return 0
}

# -------------------------
# log helpers
# -------------------------
get_watchtower_all_raw_logs(){
  local temp_log_file
  temp_log_file=$(mktemp /tmp/watchtower_raw_logs.XXXXXX) || temp_log_file="/tmp/watchtower_raw_logs.$$"
  trap 'rm -f "$temp_log_file"' RETURN

  if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
    echo ""
    return 1
  fi

  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 20s docker logs --tail 5000 watchtower > "$temp_log_file" 2>/dev/null || true
  else
    docker logs --tail 5000 watchtower > "$temp_log_file" 2>/dev/null || true
  fi
  set -e

  cat "$temp_log_file" || true
}

_extract_interval_from_cmd(){
  local cmd_json="$1"
  local interval=""
  if command -v jq >/dev/null 2>&1; then
    interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
  else
    # Fallback without jq: improved parsing but still limited compared to jq for complex args.
    # We strip array brackets and quotes, then split tokens by common delimiters (", ", " ",).
    local tokens_str
    # 使用 tr 删除引号和逗号，然后用 xargs 将多个空格压缩为单个空格
    tokens_str=$(echo "$cmd_json" | tr -d '[],"' | xargs)
    local tokens=( $tokens_str ) # Bash will split this string by IFS (space, tab, newline)
    local prev=""
    for t in "${tokens[@]}"; do
      if [ "$prev" = "--interval" ]; then
        interval="$t"; break
      fi
      prev="$t"
    done
  fi
  # Clean up potential remaining non-numeric chars for interval
  interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g')
  [ -z "$interval" ] && echo "" || echo "$interval"
}

_get_watchtower_remaining_time(){
  local wt_interval_running="$1"
  local raw_logs="$2"
  if ! echo "$raw_logs" | grep -q "Session done"; then
    echo "${COLOR_YELLOW}⚠️ 等待首次扫描完成${COLOR_RESET}"
    return
  fi
  local last_check_log
  last_check_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
  local last_check_timestamp_str=""
  if [ -n "$last_check_log" ]; then
    last_check_timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_check_log")
  fi
  if [ -n "$last_check_timestamp_str" ]; then
    local last_check_epoch
    last_check_epoch=$(_date_to_epoch "$last_check_timestamp_str")
    if [ -n "$last_check_epoch" ]; then
      local current_epoch
      current_epoch=$(date +%s)
      local time_since_last_check=$((current_epoch - last_check_epoch))
      local remaining_time=$((wt_interval_running - time_since_last_check))
      if [ "$remaining_time" -gt 0 ]; then
        local hours=$((remaining_time / 3600))
        local minutes=$(((remaining_time % 3600) / 60))
        local seconds=$((remaining_time % 60))
        printf "%b%02d时 %02d分 %02d秒%b\n" "$COLOR_GREEN" "$hours" "$minutes" "$seconds" "$COLOR_RESET"
      else
        printf "%b即将进行或已超时 (%ds)%b\n" "$COLOR_GREEN" "$remaining_time" "$COLOR_RESET"
      fi
    else
      echo "${COLOR_RED}❌ 日志时间解析失败，无法计算倒计时${COLOR_RESET}"
    fi
  else
    echo "${COLOR_YELLOW}⚠️ 未找到最近扫描日志 (Session done) 中的有效时间戳${COLOR_RESET}"
  fi
}

# -------------------------
# inspect + last session helpers
# -------------------------
get_watchtower_inspect_summary(){
  if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
    echo "Watchtower: 未检测到 'watchtower' 容器"
    echo ""
    return 2
  fi

  local cmd_json restart_policy
  cmd_json=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
  restart_policy=$(docker inspect watchtower --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown")

  echo "=== Watchtower Inspect ==="
  echo "容器: watchtower"
  echo "RestartPolicy: ${restart_policy}"
  echo "Cmd: ${cmd_json}"

  local interval
  interval=$(_extract_interval_from_cmd "$cmd_json" 2>/dev/null || true)
  if [ -n "$interval" ]; then
    echo "检测到 --interval: ${interval}s"
  else
    echo "未能解析到 --interval（将使用脚本配置或默认值）"
  fi

  # 最后一行输出 interval（或空）
  echo "${interval}"
  return 0
}

get_last_session_time(){
  local raw_logs
  raw_logs=$(get_watchtower_all_raw_logs 2>/dev/null || true)

  if [ -z "$raw_logs" ]; then
    echo "" # No logs at all
    return 1
  fi

  local last_log_line=""
  local timestamp_str=""

  # 优先级 1: "Session done" (上次完成扫描)
  last_log_line=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
  if [ -n "$last_log_line" ]; then
    timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line")
    if [ -n "$timestamp_str" ]; then
      echo "$timestamp_str"
      return 0
    fi
  fi

  # 优先级 2: "Scheduling first run" (首次调度/启动时间)
  last_log_line=$(echo "$raw_logs" | grep -E "Scheduling first run" | tail -n 1 || true)
  if [ -n "$last_log_line" ]; then
    # 尝试提取行首的ISO时间戳，表示容器启动时间
    timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line")
    if [ -n "$timestamp_str" ]; then
      echo "$timestamp_str (首次调度)"
      return 0
    fi
    # 尝试提取行内的调度时间（如果格式特殊）
    timestamp_str=$(echo "$last_log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
    if [ -n "$timestamp_str" ]; then
      echo "$timestamp_str (首次调度)"
      return 0
    fi
  fi
  
  # 优先级 3: 任何带有 ISO 格式时间戳的 INFO 级别日志 (最近的活动日志)
  last_log_line=$(echo "$raw_logs" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z? INFO' | tail -n 1 || true)
  if [ -n "$last_log_line" ]; then
    timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line")
    if [ -n "$timestamp_str" ]; then
      echo "$timestamp_str (最近活动)"
      return 0
    fi
  fi

  # 最低优先级: 获取最后一条日志的原始文本 (可能不包含有效时间)
  last_log_line=$(echo "$raw_logs" | tail -n 1 || true)
  if [ -n "$last_log_line" ]; then
    # 尝试从最后一行日志中解析时间戳
    timestamp_str=$(_parse_watchtower_timestamp_from_log_line "$last_log_line")
    if [ -n "$timestamp_str" ]; then
      echo "$timestamp_str (最近活动)"
      return 0
    else
      echo "$last_log_line (原始日志)" # 如果无法解析时间戳，显示原始日志行
      return 0
    fi
  fi

  echo "" # 仍然没有找到任何可用的日志信息
  return 1
}

# -------------------------
# get_updates_last_24h
# -------------------------
get_updates_last_24h(){
  if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
    echo ""
    return 1
  fi

  local since_arg=""
  if [ "$DATE_D_CAPABLE" = "true" ]; then
    # Use 'date -d' or 'gdate -d' to get the timestamp for '--since'
    if date -d "24 hours ago" +%s >/dev/null 2>&1; then
      since_arg=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    elif command -v gdate >/dev/null 2>&1 && gdate -d "24 hours ago" +%s >/dev/null 2>&1; then
      since_arg=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    fi
  fi

  local raw=""
  if [ -n "$since_arg" ]; then
    raw=$(docker logs --since "$since_arg" watchtower 2>/dev/null || true)
  fi

  if [ -z "$raw" ]; then # If --since failed or not available, fallback to --tail
    raw=$(docker logs --tail 200 watchtower 2>/dev/null || true)
    log_warn "⚠️ 无法获取过去 24 小时完整日志，已回退到显示最近 200 行。"
  fi

  if [ -z "$raw" ]; then
    echo ""
    return 1
  fi

  local filtered
  # 增加了 "Starting Watchtower" 以捕获启动事件
  filtered=$(echo "$raw" | grep -E "Session done|Found new image for container|No new images found for container|container was updated|Unable to update|unauthorized|Scheduling first run|Could not do a head request|Stopping container|Starting container|Pulling image|Starting Watchtower" || true)

  if [ -z "$filtered" ]; then
    echo ""
    return 1
  fi

  echo "$filtered"
  return 0
}

_highlight_line(){
  local line="$1"
  if echo "$line" | grep -qi -E "unauthorized|authentication required|Could not do a head request|Unable to update|skipped because of an error|error|failed"; then
    printf "%b%s%b\n" "$COLOR_RED" "$line" "$COLOR_RESET"
  elif echo "$line" | grep -qi -E "Found new image for container|container was updated|Creating new container|Pulling image|Starting container|Stopping container|Starting Watchtower|Session done|Scheduling first run"; then # 增加更多高亮关键词
    printf "%b%s%b\n" "$COLOR_GREEN" "$line" "$COLOR_RESET"
  elif echo "$line" | grep -qi -E "No new images found for container"; then
    printf "%b%s%b\n" "$COLOR_CYAN" "$line" "$COLOR_RESET"
  else
    echo "$line"
  fi
}

# -------------------------
# show_watchtower_details
# -------------------------
show_watchtower_details(){
  clear
  echo "=== Watchtower 运行详情与更新记录 ==="
  if ! command -v docker &>/dev/null; then
    echo "Docker 不可用。"
    press_enter_to_continue
    return
  fi

  local interval_secs=""
  if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
    interval_secs=$(get_watchtower_inspect_summary | tail -n1)
  else
    echo "Watchtower 容器未运行。"
    interval_secs=""
  fi

  echo "----------------------------------------"
  local last_session_timestamp_display
  local last_session_timestamp_epoch_raw # 用于计算倒计时，可能不带后缀
  last_session_timestamp_display=$(get_last_session_time 2>/dev/null || true)
  
  if [ -n "$last_session_timestamp_display" ]; then
    # 从显示字符串中提取纯时间戳用于 epoch 转换
    last_session_timestamp_epoch_raw=$(echo "$last_session_timestamp_display" | sed -E 's/ \((首次调度|最近活动|原始日志)\)//' || true)
    echo "上次扫描/活动: $last_session_timestamp_display"
  else
    echo "未检测到 Watchtower 任何有效日志记录。"
  fi

  if [ -n "$interval_secs" ] && [ -n "$last_session_timestamp_epoch_raw" ]; then
    local last_epoch
    last_epoch=$(_date_to_epoch "$last_session_timestamp_epoch_raw")
    if [ -n "$last_epoch" ]; then
      local now_epoch
      now_epoch=$(date +%s)
      local remaining
      remaining=$(( last_epoch + interval_secs - now_epoch ))
      if [ "$remaining" -le 0 ]; then
        echo "下次检查：即将进行或已超时 (${remaining}s)"
      else
        local hh=$(( remaining / 3600 ))
        local mm=$(((remaining % 3600) / 60))
        local ss=$(( remaining % 60 ))
        printf "下次检查倒计时: %02d时 %02d分 %02d秒\n" "$hh" "$mm" "$ss"
      fi
    else
      echo "无法将上次活动时间解析为时间戳，无法计算倒计时。"
    fi
  else
    echo "下次检查倒计时: 无法计算 (缺少上次活动时间或 Watchtower 运行间隔)"
  fi

  echo "----------------------------------------"
  echo "过去 24 小时的更新摘要（高亮重要事件）："
  echo
  local updates
  updates=$(get_updates_last_24h || true)
  if [ -z "$updates" ]; then
    echo "未检测到 Watchtower 相关日志事件。"
  else
    echo "$updates" | tail -n 200 | while IFS= read -r line; do
      _highlight_line "$line"
    done
  fi

  echo "----------------------------------------"
  while true; do
    echo "选项："
    echo " 1) 查看最近 200 行 Watchtower 日志 (实时 tail 模式)"
    echo " 2) 导出过去 24 小时摘要到 /tmp/watchtower_updates_$(date +%s).log"
    echo " (按回车直接返回上一层)"
    read -r -p "请选择 (直接回车返回): " pick

    if [ -z "$pick" ]; then
      return
    fi

    case "$pick" in
      1)
        echo "按 Ctrl+C 停止查看，随后回到详情页。"
        docker logs --tail 200 -f watchtower 2>/dev/null || true
        echo "已停止查看日志，返回 Watchtower 详情..."
        ;;
      2)
        outfile="/tmp/watchtower_updates_$(date +%s).log"
        echo "导出摘要到: $outfile"
        if [ -n "$updates" ]; then
          echo "$updates" > "$outfile"
        else
          # Fallback if updates variable was empty, try to get fresh logs
          if [ "$DATE_D_CAPABLE" = "true" ]; then
            docker logs --since "$(date -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" watchtower 2>/dev/null > "$outfile" || docker logs --tail 200 watchtower 2>/dev/null > "$outfile" || true
          else
            docker logs --tail 200 watchtower 2>/dev/null > "$outfile" || true
          fi
        fi
        echo "导出完成。"
        ;;
      0)
        return
        ;;
      *)
        echo "无效选择，请输入 1/2/0 或按回车返回。"
        ;;
    esac
  done
}

# -------------------------
# configure_notify
# -------------------------
configure_notify(){
  echo -e "${COLOR_YELLOW}⚙️ 通知配置${COLOR_RESET}"
  read -r -p "是否启用 Telegram 通知？(y/N, 当前: $([ -n "$TG_BOT_TOKEN" ] && echo "已启用" || echo "未设置")): " tchoice
  if [[ "$tchoice" =~ ^[Yy]$ ]]; then
    read -r -p "请输入 Telegram Bot Token (当前: ${TG_BOT_TOKEN:-空，回车保留}): " TG_BOT_TOKEN_INPUT
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"
    read -r -p "请输入 Telegram Chat ID (当前: ${TG_CHAT_ID:-空，回车保留}): " TG_CHAT_ID_INPUT
    TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"
  else
    TG_BOT_TOKEN=""; TG_CHAT_ID=""
  fi
  read -r -p "是否启用 Email 通知？(y/N, 当前: $([ -n "$EMAIL_TO" ] && echo "已启用" || echo "未设置")): " echoice
  if [[ "$echoice" =~ ^[Yy]$ ]]; then
    read -r -p "请输入接收通知的邮箱地址 (当前: ${EMAIL_TO:-空，回车保留}): " EMAIL_TO_INPUT
    EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"
  else
    EMAIL_TO=""
  fi
  save_config
  echo -e "${COLOR_GREEN}通知配置已保存。${COLOR_RESET}"
}

# -------------------------
# run_watchtower_once
# -------------------------
run_watchtower_once(){
  echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower (立即检查并更新)${COLOR_RESET}"
  if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
    echo -e "${COLOR_YELLOW}⚠️ Watchtower 容器已在后台运行。${COLOR_RESET}"
    if ! confirm_action "是否继续运行一次性 Watchtower 更新？"; then
      echo -e "${COLOR_YELLOW}已取消。${COLOR_RESET}"
      press_enter_to_continue
      return 0
    fi
  fi
  if ! _start_watchtower_container_logic "" "false" "一次性更新"; then
    press_enter_to_continue
    return 1
  fi
  press_enter_to_continue
  return 0
}

# -------------------------
# view_and_edit_config
# -------------------------
view_and_edit_config(){
  echo -e "${COLOR_YELLOW}🔍 脚本配置查看与编辑：${COLOR_RESET}"
  echo -e "${COLOR_YELLOW}⚠️ 注意：直接编辑配置文件 ($CONFIG_FILE) 可能导致语法错误，请谨慎。${COLOR_RESET}"
  echo "-------------------------------------------------------------------------------------------------------------------"
  echo "1) Telegram Bot Token: ${TG_BOT_TOKEN:-未设置}"
  echo "2) Telegram Chat ID:   ${TG_CHAT_ID:-未设置}"
  echo "3) Email 接收地址:     ${EMAIL_TO:-未设置}"
  echo "4) Watchtower 标签筛选: ${WATCHTOWER_LABELS:-无}"
  echo "5) Watchtower 额外参数: ${WATCHTOWER_EXTRA_ARGS:-无}"
  echo "6) Watchtower 调试模式: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")"
  echo "7) Watchtower 配置间隔: ${WATCHTOWER_CONFIG_INTERVAL:-未设置} 秒"
  echo "8) Watchtower 脚本配置启用: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")"
  echo "9) Cron 更新小时:      ${CRON_HOUR:-未设置}"
  echo "10) Cron Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
  echo "11) Cron 脚本配置启用: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")"
  echo "-------------------------------------------------------------------------------------------------------------------"
  read -r -p "请输入编号 (1-11) 或按 Enter 返回: " edit_choice
  if [ -z "$edit_choice" ]; then return 0; fi
  case "$edit_choice" in
    1) read -r -p "新的 Telegram Bot Token (空不改): " a; TG_BOT_TOKEN="${a:-$TG_BOT_TOKEN}"; save_config ;; 
    2) read -r -p "新的 Telegram Chat ID (空不改): " a; TG_CHAT_ID="${a:-$TG_CHAT_ID}"; save_config ;; 
    3) read -r -p "新的 Email (空不改): " a; EMAIL_TO="${a:-$EMAIL_TO}"; save_config ;; 
    4) read -r -p "新的 Watchtower 标签 (空取消): " a; WATCHTOWER_LABELS="${a:-}"; save_config ;; 
    5) read -r -p "新的 Watchtower 额外参数 (空取消): " a; WATCHTOWER_EXTRA_ARGS="${a:-}"; save_config ;; 
    6) read -r -p "启用 Watchtower 调试 (--debug)？(y/n): " d; WATCHTOWER_DEBUG_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 
    7)
      local new_interval=$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-300}" "请输入新的 Watchtower 检查间隔")
      if [ -n "$new_interval" ]; then
        WATCHTOWER_CONFIG_INTERVAL="$new_interval"
        save_config
      else
        echo -e "${COLOR_YELLOW}⚠️ Watchtower 检查间隔未更改。${COLOR_RESET}"
      fi
      ;; 
    8) read -r -p "启用 Watchtower 脚本配置？(y/n, 当前: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")): " d; WATCHTOWER_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 
    9) 
      local new_cron_hour=""
      while true; do
        read -r -p "新的 Cron 小时 (0-23, 空不改): " a
        if [ -z "$a" ]; then new_cron_hour="${CRON_HOUR}"; break; fi
        if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 0 ] && [ "$a" -le 23 ]; then
          new_cron_hour="$a"; break
        else
          echo -e "${COLOR_RED}❌ 小时输入无效，请在 0-23 之间输入。${COLOR_RESET}"
        fi
      done
      CRON_HOUR="${new_cron_hour}"; save_config ;; 
    10) read -r -p "新的 Cron 项目目录 (空取消): " a; DOCKER_COMPOSE_PROJECT_DIR_CRON="${a:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}"; save_config ;; 
    11) read -r -p "启用 Cron 脚本配置？(y/n, 当前: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")): " d; CRON_TASK_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 
    *) echo "返回" ;; 
  esac
  return 0
}

# -------------------------
# main menu
# -------------------------
main_menu(){
  while true; do
    clear
    echo "==================== VPS 容器管理 ===================="
    local WATCHTOWER_STATUS LAST_CHECK_DISPLAY TOTAL RUNNING STOPPED
    WATCHTOWER_STATUS="$(docker ps --format '{{.Names}}' | grep -q '^watchtower$' && echo '已启动' || echo '未运行')"

    LAST_CHECK_DISPLAY=$(get_last_session_time 2>/dev/null || true)
    LAST_CHECK_DISPLAY="${LAST_CHECK_DISPLAY:-未检测到Watchtower日志活动}" # 如果没有任何日志，显示更清晰的提示

    TOTAL=$(docker ps -a -q 2>/dev/null | wc -l)
    RUNNING=$(docker ps -q 2>/dev/null | wc -l)
    STOPPED=$((TOTAL - RUNNING))

    printf "🟢 Watchtower 状态: %s\n" "$WATCHTOWER_STATUS"
    printf "🟡 上次更新检查/活动: %s\n" "$LAST_CHECK_DISPLAY" # 修改显示文本
    printf "📦 容器总数: %s (运行: %s, 停止: %s)\n\n" "$TOTAL" "$RUNNING" "$STOPPED"

    echo "主菜单选项："
    echo "1) 🔄 设置更新模式"
    echo "2) 📋 查看容器信息"
    echo "3) 🔔 配置通知"
    echo "4) ⚙️ 任务管理"
    echo "5) 📝 查看/编辑脚本配置"
    echo "6) 🆕 手动运行 Watchtower"
    echo "7) 🔍 查看 Watchtower 运行详情和更新记录"
    echo
    read -r -p "请输入选项 [1-7] 或 q 退出: " choice
    case "$choice" in
      1) update_menu ;; 
      2) show_container_info ;; 
      3) configure_notify ;; 
      4) manage_tasks ;; 
      5) view_and_edit_config ;; 
      6) run_watchtower_once ;; 
      7) show_watchtower_details ;; 
      q|Q) echo "退出."; exit 0 ;; 
      *) echo -e "${COLOR_YELLOW}无效选项${COLOR_RESET}"; sleep 1 ;; 
    esac
  done
}

update_menu(){
  echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
  echo "1) Watchtower 模式"
  echo "2) Cron 定时任务 模式"
  read -r -p "选择 [1-2] 或回车返回: " c
  if [ -z "$c" ]; then return 0; fi
  case "$c" in
    1) configure_watchtower ;; 
    2) configure_cron_task ;; 
    *) echo -e "${COLOR_YELLOW}无效选择，已取消。${COLOR_RESET}" ;; 
  esac
}

# main
main(){
  echo ""
  echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
  echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION${COLOR_RESET}"
  echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
  echo ""
  main_menu
}

main
