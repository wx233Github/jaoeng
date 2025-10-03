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
    
    local plain_title; plain_title=$(echo -e "$title" | sed 's/\x1b\[[0-9;]*m//g')
    local total_chars=${#plain_title}
    local ascii_chars_only; ascii_chars_only=$(echo "$plain_title" | tr -dc '[ -~]')
    local ascii_count=${#ascii_chars_only}
    local non_ascii_count=$((total_chars - ascii_count))
    local title_width=$((ascii_count + non_ascii_count * 2))

    local padding_total=$((total_width - title_width))
    if [ $padding_total -lt 0 ]; then padding_total=0; fi
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
      local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Report.Time.Format "2006-01-02 15:04:05"}}`'; cmd_parts+=(-e WATCHTOWER_NOTIFICATION_TEMPLATE="$NOTIFICATION_TEMPLATE")
  fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi; 
  if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  local final_exclude_list=""; local source_msg=""
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
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "⚙️ 通知配置 ⚙️"; local tg_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$TG_BOT_TOKEN" ]; then tg_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi; local email_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$EMAIL_TO" ]; then email_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi; printf " 1. 配置 Telegram  (%b)\n" "$tg_status"; printf " 2. 配置 Email      (%b)\n" "$email_status"; echo " 3. 发送测试通知"; echo " 4. 清空所有通知配置"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [[ -z "$TG_BOT_TOKEN" && -z "$EMAIL_TO" ]]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${VERSION} 的*测试消息*。"; log_info "测试通知已发送 (请检查您的客户端)。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
_parse_watchtower_timestamp_from_log_line() { local log_line="$1"; local timestamp=""; timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; echo ""; return 1; }
_date_to_epoch() { local dt="$1"; [ -z "$dt" ] && echo "" && return; if [ "$(date -d "now" >/dev/null 2>&1 && echo true)" = "true" ]; then date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""); elif [ "$(command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1 && echo true)" = "true" ]; then gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""); else log_warn "⚠️ 'date' 或 'gdate' 不支持。"; echo ""; fi; }
show_container_info() { while true; do if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "📋 容器管理 📋"; printf "%-5s %-25s %-45s %-20s\n" "编号" "名称" "镜像" "状态"; local containers=(); local i=1; while IFS='|' read -r name image status; do containers+=("$name"); local status_colored="$status"; if [[ "$status" =~ ^Up ]]; then status_colored="${COLOR_GREEN}${status}${COLOR_RESET}"; elif [[ "$status" =~ ^Exited|Created ]]; then status_colored="${COLOR_RED}${status}${COLOR_RESET}"; else status_colored="${COLOR_YELLOW}${status}${COLOR_RESET}"; fi; printf "%-5s %-25s %-45s %b\n" "$i" "$name" "$image" "$status_colored"; i=$((i+1)); done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}'); echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "输入编号操作, 或按 Enter 返回: " choice; case "$choice" in "") return ;; *) if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo -e "${COLOR_RED}❌ 无效输入。${COLOR_RESET}"; sleep 1; continue; fi; if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#containers[@]}" ]; then echo -e "${COLOR_RED}❌ 编号超范围。${COLOR_RESET}"; sleep 1; continue; fi; local selected_container="${containers[$((choice-1))]}"; if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "操作容器: ${selected_container}"; echo "1. 日志"; echo "2. 重启"; echo "3. 停止"; echo "4. 删除"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "请选择, 或按 Enter 返回: " action; case "$action" in 1) echo -e "${COLOR_YELLOW}日志 (Ctrl+C 停止)...${COLOR_RESET}"; trap '' INT; docker logs -f --tail 100 "$selected_container" || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue ;; 2) echo "重启中..."; if docker restart "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1 ;; 3) echo "停止中..."; if docker stop "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1 ;; 4) if confirm_action "警告: 删除 '${selected_container}'？"; then echo "删除中..."; if docker rm -f "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1; else echo "已取消。"; fi ;; *) echo -e "${COLOR_RED}❌ 无效操作。${COLOR_RESET}"; sleep 1 ;; esac ;; esac; done; }
_prompt_for_interval() { local default_value="$1"; local prompt_msg="$2"; local input_interval=""; local result_interval=""; local formatted_default=$(_format_seconds_to_human "$default_value"); while true; do read -r -p "$prompt_msg (例: 300s/2h/1d, [回车]使用 ${formatted_default}): " input_interval; input_interval=${input_interval:-${default_value}s}; if [[ "$input_interval" =~ ^([0-9]+)s$ ]]; then result_interval=${BASH_REMATCH[1]}; break; elif [[ "$input_interval" =~ ^([0-9]+)h$ ]]; then result_interval=$((${BASH_REMATCH[1]}*3600)); break; elif [[ "$input_interval" =~ ^([0-9]+)d$ ]]; then result_interval=$((${BASH_REMATCH[1]}*86400)); break; elif [[ "$input_interval" =~ ^[0-9]+$ ]]; then result_interval="${input_interval}"; break; else echo -e "${COLOR_RED}❌ 格式错误...${COLOR_RESET}"; fi; done; echo "$result_interval"; }
configure_exclusion_list() {
    local all_containers=(); readarray -t all_containers < <(docker ps --format '{{.Names}}')
    local excluded_arr=(); if [ -n "$WATCHTOWER_EXCLUDE_LIST" ]; then IFS=',' read -r -a excluded_arr <<< "$WATCHTOWER_EXCLUDE_LIST"; fi
    while true; do
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "配置排除列表 (高优先级)";
        for i in "${!all_containers[@]}"; do
            local container="${all_containers[$i]}"; local is_excluded=" "; for item in "${excluded_arr[@]}"; do if [[ "$item" == "$container" ]]; then is_excluded="✔"; break; fi; done
            echo -e " ${YELLOW}$((i+1)).${NC} [${GREEN}${is_excluded}${NC}] $container"
        done
        echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
        echo -e "${CYAN}当前排除 (脚本内): ${excluded_arr[*]:-(空, 将使用 config.json)}${NC}"
        echo -e "${CYAN}备用排除 (config.json): ${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-无}${NC}"
        echo -e "${BLUE}操作提示: 输入数字(可用','分隔)切换, 'c'确认, [回车]使用备用配置${NC}"
        read -r -p "请选择: " choice
        case "$choice" in
            c|C) break ;;
            "") excluded_arr=(); log_info "已清空脚本内配置，将使用 config.json 的备用配置。"; sleep 1.5; break ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' '); IFS=',' read -r -a selected_indices <<< "$clean_choice"; local has_invalid_input=false
                for index in "${selected_indices[@]}"; do
                    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le "${#all_containers[@]}" ]; then
                        local target="${all_containers[$((index-1))]}"; local found=false; local temp_arr=()
                        for item in "${excluded_arr[@]}"; do if [[ "$item" == "$target" ]]; then found=true; else temp_arr+=("$item"); fi; done
                        if $found; then excluded_arr=("${temp_arr[@]}"); else excluded_arr+=("$target"); fi
                    else has_invalid_input=true; fi
                done
                if $has_invalid_input; then log_warn "输入 '${choice}' 中包含无效选项，已忽略。"; sleep 1.5; fi
            ;;
        esac
    done
    WATCHTOWER_EXCLUDE_LIST=$(IFS=,; echo "${excluded_arr[*]}")
}
configure_watchtower(){ 
    _print_header "🚀 Watchtower 配置"
    local current_saved_interval="${WATCHTOWER_CONFIG_INTERVAL}"; local config_json_interval="${WT_CONF_DEFAULT_INTERVAL:-300}"; local prompt_default="${current_saved_interval:-$config_json_interval}"; local prompt_text="请输入检查间隔 (config.json 默认: $(_format_seconds_to_human "$config_json_interval"))"; local WT_INTERVAL_TMP="$(_prompt_for_interval "$prompt_default" "$prompt_text")"; log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"; sleep 1; configure_exclusion_list; read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice; if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then read -r -p "请输入额外参数: " temp_extra_args; else temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"; fi; read -r -p "是否启用调试模式? (y/N): " debug_choice; local temp_debug_enabled=$([[ "$debug_choice" =~ ^[Yy]$ ]] && echo "true" || echo "false"); 
    echo; _print_header "配置确认"
    printf " 检查间隔: %s\n" "$(_format_seconds_to_human "$WT_INTERVAL_TMP")"
    local final_exclude_list=""; local source_msg=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本"; else final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-无}"; source_msg="config.json"; fi
    printf " 排除列表 (%s): %s\n" "$source_msg" "${final_exclude_list//,/, }"
    printf " 额外参数: %s\n" "${temp_extra_args:-无}"
    printf " 调试模式: %s\n" "$temp_debug_enabled"
    echo -e "${COLOR_YELLOW}╰$(generate_line)╯${COLOR_RESET}"
    read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice
    if [[ "$confirm_choice" =~ ^[Nn]$ ]]; then log_info "操作已取消。"; return 10; fi
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"; WATCHTOWER_ENABLED="true"; save_config
    set +e; docker rm -f watchtower &>/dev/null || true; set -e
    if ! _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" "Watchtower模式"; then echo -e "${COLOR_RED}❌ Watchtower 启动失败。${COLOR_RESET}"; return 1; fi
    return 0
}
manage_tasks(){ while true; do if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "⚙️ 任务管理 ⚙️"; echo " 1. 停止/移除 Watchtower"; echo " 2. 移除 Cron"; echo " 3. 移除 Systemd Timer"; echo " 4. 重启 Watchtower"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "请选择, 或按 Enter 返回: " choice; case "$choice" in 1) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then if confirm_action "确定移除 Watchtower？"; then set +e; docker rm -f watchtower &>/dev/null; set -e; WATCHTOWER_ENABLED="false"; save_config; send_notify "🗑️ Watchtower 已移除"; echo -e "${COLOR_GREEN}✅ 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;; 2) local SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"; if crontab -l 2>/dev/null | grep -q "$SCRIPT"; then if confirm_action "确定移除 Cron？"; then (crontab -l 2>/dev/null | grep -v "$SCRIPT") | crontab -; rm -f "$SCRIPT" 2>/dev/null || true; CRON_TASK_ENABLED="false"; save_config; send_notify "🗑️ Cron 已移除"; echo -e "${COLOR_GREEN}✅ Cron 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ 未发现 Cron 任务。${COLOR_RESET}"; fi; press_enter_to_continue ;; 3) if systemctl list-timers | grep -q "docker-compose-update.timer"; then if confirm_action "确定移除 Systemd Timer？"; then systemctl disable --now docker-compose-update.timer &>/dev/null; rm -f /etc/systemd/system/docker-compose-update.{service,timer}; systemctl daemon-reload; log_info "Systemd Timer 已移除。"; fi; else echo -e "${COLOR_YELLOW}ℹ️ 未发现 Systemd Timer。${COLOR_RESET}"; fi; press_enter_to_continue ;; 4) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo "正在重启..."; if docker restart watchtower; then send_notify "🔄 Watchtower 已重启"; echo -e "${COLOR_GREEN}✅ 重启成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 重启失败。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;; "") return ;; *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;; esac; done; }
# ... (get* and _format* functions are unchanged) ...
main_menu(){
  while true; do
    if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; load_config
    _print_header "Docker 助手 v${VERSION}"
    # ... (status display logic is unchanged) ...
    echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
    echo "主菜单："
    echo " 1. 配置 Watchtower 与排除列表"
    # ... (other menu items) ...
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
