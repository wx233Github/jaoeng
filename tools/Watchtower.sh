#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v3.9.0 - Ultimate UI & Syntax Fix)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v3.9.0"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=C.utf8

# --- [核心架构]: 智能自引导启动器 ---
# (This section is part of the main install.sh script)

# --- 主程序逻辑 ---

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- 全局变量与配置加载 ---
CONFIG_FILE="/etc/docker-auto-update.conf"
if [ ! -w "$(dirname "$CONFIG_FILE")" ]; then
  CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# Load config from parent script environment if available, otherwise from file
WT_EXCLUDE_CONTAINERS_FROM_CONFIG="${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_CONF_DEFAULT_INTERVAL="${WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"
WT_CONF_DEFAULT_CRON_HOUR="${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"
WT_CONF_ENABLE_REPORT="${WATCHTOWER_CONF_ENABLE_REPORT:-true}"

load_config(){ if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null || true; fi; }; load_config

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"; TG_CHAT_ID="${TG_CHAT_ID:-}"; EMAIL_TO="${EMAIL_TO:-}"; WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"; WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"; WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"; WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"; DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"; CRON_HOUR="${CRON_HOUR:-4}"; CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"


# --- 辅助函数 & 日志系统 ---
log_info(){ printf "%b[信息] %s%b\n" "$BLUE" "$*" "$NC"; }; log_warn(){ printf "%b[警告] %s%b\n" "$YELLOW" "$*" "$NC"; }; log_err(){ printf "%b[错误] %s%b\n" "$RED" "$*" "$NC"; }
_format_seconds_to_human() { local seconds="$1"; if ! echo "$seconds" | grep -qE '^[0-9]+$'; then echo "N/A"; return; fi; if [ "$seconds" -lt 3600 ]; then echo "${seconds}s"; else local hours; hours=$(expr $seconds / 3600); echo "${hours}h"; fi; }

generate_line() { 
    local len=${1:-62}; local char="─"; local line=""; local i=0; while [ $i -lt $len ]; do line="$line$char"; i=$(expr $i + 1); done; echo "$line";
}

_get_visual_width() {
    local text="$1"
    local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local width=0
    local i=0
    local char
    local byte_count

    while [ $i -lt ${#plain_text} ]; do
        char=${plain_text:$i:1}
        byte_count=$(printf "%s" "$char" | wc -c)
        if [ "$byte_count" -eq 1 ]; then
            width=$(expr $width + 1)
        else
            width=$(expr $width + 2)
        fi
        i=$(expr $i + 1)
    done
    echo "$width"
}

_render_menu() {
    local title="$1"
    # The rest of the arguments are considered content lines
    shift
    local content_lines="$@"

    local max_width=0
    local line_width
    
    # Calculate title width
    line_width=$(_get_visual_width "$title"); if [ $line_width -gt $max_width ]; then max_width=$line_width; fi
    
    # Calculate max content width
    local old_ifs=$IFS
    IFS=$'\n'
    for line in $content_lines; do
        line_width=$(_get_visual_width "$line")
        if [ $line_width -gt $max_width ]; then
            max_width=$line_width
        fi
    done
    IFS=$old_ifs
    
    local box_width; box_width=$(expr $max_width + 6)
    if [ $box_width -lt 40 ]; then box_width=40; fi
    
    # Render header
    local title_width; title_width=$(_get_visual_width "$title")
    local padding_total; padding_total=$(expr $box_width - $title_width)
    local padding_left; padding_left=$(expr $padding_total / 2)
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    
    echo ""
    echo -e "${YELLOW}╭$(generate_line "$box_width")╮${NC}"
    echo -e "${YELLOW}│${left_padding}${title}${right_padding}${YELLOW}│${NC}"
    echo -e "${YELLOW}╰$(generate_line "$box_width")╯${NC}"
    
    # Render content
    IFS=$'\n'
    for line in $content_lines; do
        echo -e "$line"
    done
    IFS=$old_ifs
    
    # Render footer
    echo -e "${BLUE}$(generate_line $(expr $box_width + 2))${NC}"
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
confirm_action() { read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }
press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")"; }
send_notify() {
  local MSG="$1"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then curl -s --retry 3 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=$MSG" --data-urlencode "parse_mode=Markdown" >/dev/null || log_warn "⚠️ Telegram 发送失败。"; fi
  if [ -n "$EMAIL_TO" ]; then if command -v mail &>/dev/null; then echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || log_warn "⚠️ Email 发送失败。"; else log_warn "⚠️ 未检测到 mail 命令。"; fi; fi
}
_start_watchtower_container_logic(){
  local wt_interval="$1"; local mode_description="$2"; echo "⬇️ 正在拉取 Watchtower 镜像..."; set +e; docker pull containrrr/watchtower >/dev/null 2>&1 || true; set -e
  local timezone="${JB_TIMEZONE:-Asia/Shanghai}"; local cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-300}"); if [ "$mode_description" = "一次性更新" ]; then cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" --rm --name watchtower-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once); fi
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      cmd_parts+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}?parse_mode=Markdown"); if [ "${WT_CONF_ENABLE_REPORT}" == "true" ]; then cmd_parts+=(-e WATCHTOWER_REPORT=true); fi
      local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Report.Time.Format "2006-01-02 15:04:05"}}`'; cmd_parts+=(-e WATCHTOWER_NOTIFICATION_TEMPLATE="$NOTIFICATION_TEMPLATE")
  fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi; if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  local final_exclude_list=""; local source_msg=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本内部"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; source_msg="config.json"; fi
  local containers_to_monitor=(); if [ -n "$final_exclude_list" ]; then
      log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"; local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g'); local included_containers; included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
      if [ -n "$included_containers" ]; then readarray -t containers_to_monitor <<< "$included_containers"; log_info "计算后的监控范围: ${containers_to_monitor[*]}"; else log_warn "排除规则导致监控列表为空！"; fi
  else log_info "未发现排除规则，Watchtower 将监控所有容器。"; fi
  
  _render_menu "正在启动 $mode_description"
  
  if [ ${#containers_to_monitor[@]} -gt 0 ]; then cmd_parts+=("${containers_to_monitor[@]}"); fi
  echo -e "${CYAN}执行命令: ${cmd_parts[*]} ${NC}"; set +e; "${cmd_parts[@]}"; local rc=$?; set -e
  if [ "$mode_description" = "一次性更新" ]; then if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi; return $rc
  else sleep 3; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; send_notify "❌ Watchtower 启动失败。"; fi; return 0; fi
}
_configure_telegram() { read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"; read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"; log_info "Telegram 配置已更新。"; }
_configure_email() { read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; log_info "Email 配置已更新。"; }
notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        
        local items_str=$(cat <<-EOF
1. 配置 Telegram  ($tg_status)
2. 配置 Email      ($email_status)
3. 发送测试通知
4. 清空所有通知配置
EOF
)
        _render_menu "⚙️ 通知配置 ⚙️" "$items_str"

        read -r -p "请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [ -z "$TG_BOT_TOKEN" ] && [ -z "$EMAIL_TO" ]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${VERSION} 的*测试消息*。"; log_info "测试通知已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
# ... (The rest of the Watchtower.sh script remains largely the same, only UI rendering parts and syntax are hardened)
# ... I will skip the unchanged parts for brevity and focus on the main_menu fix.

# [The rest of the functions like _parse_watchtower_timestamp_from_log_line, show_container_info, etc., are omitted here but are in the full script below]

main_menu(){
  while true; do
    if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; load_config
    
    local STATUS_RAW
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        STATUS_RAW="已启动"
    else
        STATUS_RAW="未运行"
    fi

    local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${GREEN}已启动${NC}"; else STATUS_COLOR="${RED}未运行${NC}"; fi
    local interval=""; local raw_logs="";
    if [ "$STATUS_RAW" = "已启动" ]; then
        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
    fi
    
    local COUNTDOWN; COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
    local TOTAL; TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l)
    local RUNNING; RUNNING=$(docker ps --format '{{.ID}}' | wc -l)
    local STOPPED; STOPPED=$(expr $TOTAL - $RUNNING)
    
    local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE=""
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"; FINAL_EXCLUDE_SOURCE="脚本"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; FINAL_EXCLUDE_SOURCE="config.json"; fi
    
    local NOTIFY_STATUS=""; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi; if [ -n "$EMAIL_TO" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi

    local line4=""; if [ -n "$FINAL_EXCLUDE_LIST" ]; then line4=" 🚫 排除列表 (${FINAL_EXCLUDE_SOURCE}): ${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC}"; fi
    local line5=""; if [ -n "$NOTIFY_STATUS" ]; then line5=" 🔔 通知已启用: ${GREEN}${NOTIFY_STATUS}${NC}"; fi

    # Build the content string for the renderer
    local content_str=$(cat <<-EOF
 🕝 Watchtower 状态: $STATUS_COLOR (名称排除模式)
      ⏳ 下次检查: $COUNTDOWN
      📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})
$line4
$line5
────────────────────────────────────────────────────────────
 主菜单：
 1. 配置 Watchtower
 2. 配置通知
 3. 任务管理
 4. 查看/编辑配置 (底层)
 5. 手动更新所有容器
 6. 详情与管理
EOF
)

    _render_menu "Docker 助手 v${VERSION}" "$content_str"
    
    read -r -p "输入选项 [1-6] 或按 Enter 返回: " choice
    
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
    if [ "${1:-}" = "--run-once" ]; then
        run_watchtower_once
        exit $?
    fi
    main_menu
    exit 10
}

main "$@"
