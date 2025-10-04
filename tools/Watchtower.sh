#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.4.3 - New UI Style)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.4.3"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF-8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"; if [ -f "$UTILS_PATH" ]; then source "$UTILS_PATH"; else log_err() { echo "[错误] $*" >&2; }; log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"; exit 1; fi

# --- 脚本依赖检查 ---
if ! command -v docker >/dev/null 2>&1; then log_err "❌ 错误: 未检测到 'docker' 命令。"; exit 1; fi
if ! docker ps -q >/dev/null 2>&1; then log_err "❌ 错误:无法连接到 Docker。"; exit 1; fi

# --- 配置加载 ---
WT_EXCLUDE_CONTAINERS_FROM_CONFIG="${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"; WT_CONF_DEFAULT_INTERVAL="${WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"; WT_CONF_DEFAULT_CRON_HOUR="${WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"; WT_CONF_ENABLE_REPORT="${WATCHTOWER_CONF_ENABLE_REPORT:-true}"; CONFIG_FILE="/etc/docker-auto-update.conf"; if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then CONFIG_FILE="$HOME/.docker-auto-update.conf"; fi
load_config(){ if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null || true; fi; }; load_config
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"; TG_CHAT_ID="${TG_CHAT_ID:-}"; EMAIL_TO="${EMAIL_TO:-}"; WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"; WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"; WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"; WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"; DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"; CRON_HOUR="${CRON_HOUR:-4}"; CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"; WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"

# =============================================================
# 关键改动: 模块专属的UI渲染函数
# =============================================================
_render_watchtower_menu() {
    local title="$1"; shift
    
    local -a status_lines=()
    local docker_status="→ Docker：${GREEN}🟢 正常${NC}"
    local nginx_status="→ Nginx ：${YELLOW}🟡 检查中${NC}" # 示例
    local wt_status="→ Watchtower：${CYAN}🔄 同步中${NC}" # 示例
    
    status_lines+=("$docker_status")
    status_lines+=("$nginx_status")
    status_lines+=("$wt_status")

    echo ""; echo -e "${CYAN}≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈${NC}"
    echo -e "★ ${title}  ·  状态：${GREEN}已更新 ✓${NC}"
    echo -e "${BLUE}--------------------------------${NC}"
    for line in "${status_lines[@]}"; do
        echo -e "$line"
    done
    echo -e "${BLUE}--------------------------------${NC}"
    
    for line in "$@"; do
        echo -e "$line"
    done
    
    echo -e "${CYAN}≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈${NC}"
}


# --- 模块专属函数 ---
send_notify() { local message="$1"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then (curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" --data-urlencode "text=${message}" -d "chat_id=${TG_CHAT_ID}" -d "parse_mode=Markdown" >/dev/null 2>&1) &; fi; }
_format_seconds_to_human() { local seconds="$1"; if ! echo "$seconds" | grep -qE '^[0-9]+$'; then echo "N/A"; return; fi; if [ "$seconds" -lt 3600 ]; then echo "${seconds}s"; else local hours; hours=$((seconds / 3600)); echo "${hours}h"; fi; }
save_config(){ mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true; cat > "$CONFIG_FILE" <<EOF
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
chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"; }
_start_watchtower_container_logic(){
  local wt_interval="$1"; local mode_description="$2"; echo "⬇️ 正在拉取 Watchtower 镜像..."; set +e; docker pull containrrr/watchtower >/dev/null 2>&1 || true; set -e
  local timezone="${JB_TIMEZONE:-Asia/Shanghai}"; local cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-300}"); if [ "$mode_description" = "一次性更新" ]; then cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" --rm --name watchtower-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once); fi
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then cmd_parts+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}?parse_mode=Markdown"); if [ "${WT_CONF_ENABLE_REPORT}" = "true" ]; then cmd_parts+=(-e WATCHTOWER_REPORT=true); fi; local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Report.Time.Format "2006-01-02 15:04:05"}}`'; cmd_parts+=(-e WATCHTOWER_NOTIFICATION_TEMPLATE="$NOTIFICATION_TEMPLATE"); fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi; if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  local final_exclude_list=""; local source_msg=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本内部"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; source_msg="config.json"; fi
  if [ -n "$final_exclude_list" ]; then log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"; local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g'); local included_containers; included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true); if [ -n "$included_containers" ]; then cmd_parts+=($included_containers); log_info "计算后的监控范围: ${included_containers}"; else log_warn "排除规则导致监控列表为空！"; fi; else log_info "未发现排除规则，Watchtower 将监控所有容器。"; fi
  _render_watchtower_menu "正在启动 $mode_description" "  ${CYAN}执行命令: ${cmd_parts[*]} ${NC}"; set +e; "${cmd_parts[@]}"; local rc=$?; set -e
  if [ "$mode_description" = "一次性更新" ]; then if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi; return $rc; else sleep 3; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; fi; return 0; fi
}
_prompt_and_restart_watchtower_if_needed() { if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then if confirm_action "配置已更新，是否立即重启 Watchtower 以应用新配置?"; then log_info "正在重启 Watchtower..."; if docker restart watchtower; then send_notify "🔄 Watchtower 服务已因配置变更而重启。"; log_success "Watchtower 重启成功。"; else log_err "Watchtower 重启失败！"; fi; else log_warn "操作已取消。新配置将在下次手动重启或重开 Watchtower 后生效。"; fi; fi; }
_configure_telegram() { read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"; read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"; log_info "Telegram 配置已更新。"; }
_configure_email() { read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; log_info "Email 配置已更新。"; }
notification_menu() {
    while true; do if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi; local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local -a items_array=("  1. › 配置 Telegram  ($tg_status)" "  2. › 配置 Email      ($email_status)" "  3. › 发送测试通知" "  4. › 清空所有通知配置")
        _render_watchtower_menu "通知配置" "${items_array[@]}"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; _prompt_and_restart_watchtower_if_needed; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${SCRIPT_VERSION} 的*测试消息*。"; log_info "测试通知已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; _prompt_and_restart_watchtower_if_needed; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
_parse_watchtower_timestamp_from_log_line() { local log_line="$1"; local timestamp=""; timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; echo ""; return 1; }
_date_to_epoch() { local dt="$1"; [ -z "$dt" ] && echo "" && return; if date -d "now" >/dev/null 2>&1; then date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""); elif command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1; then gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""); else log_warn "⚠️ 'date' 或 'gdate' 不支持。"; echo ""; fi; }
show_container_info() { 
    while true; do if [ "${JB_ENAB
