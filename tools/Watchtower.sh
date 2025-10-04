#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.3.1 - Final Targeted UI Fix)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.3.1"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=C.UTF-8

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
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
CONFIG_FILE="/etc/docker-auto-update.conf"; if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then CONFIG_FILE="$HOME/.docker-auto-update.conf"; fi
load_config(){ if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" &>/dev/null || true; fi; }; load_config
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"; TG_CHAT_ID="${TG_CHAT_ID:-}"; EMAIL_TO="${EMAIL_TO:-}"; WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"; WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"; WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-}"; WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"; DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"; CRON_HOUR="${CRON_HOUR:-4}"; CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"; WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"

# --- 辅助函数 & 日志系统 ---
log_info(){ printf "%b[信息] %s%b\n" "$COLOR_BLUE" "$*" "$COLOR_RESET"; }; log_warn(){ printf "%b[警告] %s%b\n" "$COLOR_YELLOW" "$*" "$COLOR_RESET"; }; log_err(){ printf "%b[错误] %s%b\n" "$COLOR_RED" "$*" "$COLOR_RESET"; }

send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        (curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "text=${message}" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1) &
    fi
}

_format_seconds_to_human() { local seconds="$1"; if ! echo "$seconds" | grep -qE '^[0-9]+$'; then echo "N/A"; return; fi; if [ "$seconds" -lt 3600 ]; then echo "${seconds}s"; else local hours; hours=$(expr $seconds / 3600); echo "${hours}h"; fi; }
generate_line() { local len=${1:-62}; local char="─"; local line=""; local i=0; while [ $i -lt $len ]; do line="$line$char"; i=$(expr $i + 1); done; echo "$line"; }

_get_visual_width() {
    local text="$1"
    local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local processed_text; processed_text=$(echo "$plain_text" | sed 's/ //g')
    local width=0; local i=0
    while [ $i -lt ${#processed_text} ]; do
        char=${processed_text:$i:1}
        if [ "$(echo -n "$char" | wc -c)" -gt 1 ]; then width=$((width + 2)); else width=$((width + 1)); fi
        i=$((i + 1))
    done
    echo $width
}

_render_menu() {
    local title="$1"; shift; local lines_str="$@"; local max_width=0; local line_width
    line_width=$(_get_visual_width "$title"); if [ $line_width -gt $max_width ]; then max_width=$line_width; fi
    local old_ifs=$IFS; IFS=$'\n'
    for line in $lines_str; do line_width=$(_get_visual_width "$line"); if [ $line_width -gt $max_width ]; then max_width=$line_width; fi; done
    IFS=$old_ifs
    local box_width; box_width=$(expr $max_width + 6); if [ $box_width -lt 40 ]; then box_width=40; fi
    local title_width; title_width=$(_get_visual_width "$title"); local padding_total; padding_total=$(expr $box_width - $title_width); local padding_left; padding_left=$(expr $padding_total / 2); local left_padding; left_padding=$(printf '%*s' "$padding_left"); local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    echo ""; echo -e "${COLOR_YELLOW}╭$(generate_line "$box_width")╮${COLOR_RESET}"; echo -e "${COLOR_YELLOW}│${left_padding}${title}${right_padding}${COLOR_YELLOW}│${COLOR_RESET}"; echo -e "${COLOR_YELLOW}╰$(generate_line "$box_width")╯${COLOR_RESET}"
    IFS=$'\n'; for line in $lines_str; do echo -e "$line"; done; IFS=$old_ifs
    echo -e "${COLOR_BLUE}$(generate_line $(expr $box_width + 2))${COLOR_RESET}"
}

# =============================================================
# START: New dynamic renderer for specific complex menus
# =============================================================
_render_dynamic_box() {
    local title="$1"
    local box_width="$2"
    shift 2
    local content_str="$@"
    
    local title_width; title_width=$(_get_visual_width "$title")
    local top_bottom_border; top_bottom_border=$(generate_line "$box_width")
    local padding_total; padding_total=$(expr $box_width - $title_width)
    local padding_left; padding_left=$(expr $padding_total / 2)
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    
    echo ""
    echo -e "${COLOR_YELLOW}╭${top_bottom_border}╮${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}│${left_padding}${title}${right_padding}${COLOR_YELLOW}│${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}╰${top_bottom_border}╯${COLOR_RESET}"
    
    local old_ifs=$IFS; IFS=$'\n'
    for line in $content_str; do
        echo -e "$line"
    done
    IFS=$old_ifs
}
# =============================================================
# END: New dynamic renderer
# =============================================================

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
press_enter_to_continue() { read -r -p "$(echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}")"; }
_render_simple_lines() {
    local indent="$1"; shift; local lines=("$@")
    for line in "${lines[@]}"; do
        echo -e "${indent}${line}"
    done
}
confirm_action() { read -r -p "$(echo -e "${COLOR_YELLOW}$1 ([y]/n): ${COLOR_RESET}")" choice; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

# ... All functions from _start_watchtower_container_logic to just before show_watchtower_details are unchanged ...
# (Pasting them for completeness)
_start_watchtower_container_logic(){
  local wt_interval="$1"; local mode_description="$2"; echo "⬇️ 正在拉取 Watchtower 镜像..."; set +e; docker pull containrrr/watchtower >/dev/null 2>&1 || true; set -e
  local timezone="${JB_TIMEZONE:-Asia/Shanghai}"; local cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-300}"); if [ "$mode_description" = "一次性更新" ]; then cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" --rm --name watchtower-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once); fi
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      cmd_parts+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}?parse_mode=Markdown"); if [ "${WT_CONF_ENABLE_REPORT}" = "true" ]; then cmd_parts+=(-e WATCHTOWER_REPORT=true); fi
      local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Report.Time.Format "2006-01-02 15:04:05"}}`'; cmd_parts+=(-e WATCHTOWER_NOTIFICATION_TEMPLATE="$NOTIFICATION_TEMPLATE")
  fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi; if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  local final_exclude_list=""; local source_msg=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本内部"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; source_msg="config.json"; fi
  if [ -n "$final_exclude_list" ]; then
      log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"; local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g'); local included_containers; included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
      if [ -n "$included_containers" ]; then cmd_parts+=($included_containers); log_info "计算后的监控范围: ${included_containers}"; else log_warn "排除规则导致监控列表为空！"; fi
  else log_info "未发现排除规则，Watchtower 将监控所有容器。"; fi
  _print_header "正在启动 $mode_description"; echo -e "${COLOR_CYAN}执行命令: ${cmd_parts[*]} ${COLOR_RESET}"; set +e; "${cmd_parts[@]}"; local rc=$?; set -e
  if [ "$mode_description" = "一次性更新" ]; then if [ $rc -eq 0 ]; then echo -e "${COLOR_GREEN}✅ $mode_description 完成。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ $mode_description 失败。${COLOR_RESET}"; fi; return $rc
  else sleep 3; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_GREEN}✅ $mode_description 启动成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ $mode_description 启动失败。${COLOR_RESET}"; fi; return 0; fi
}
_configure_telegram() { read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"; read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"; log_info "Telegram 配置已更新。"; }
_configure_email() { read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; log_info "Email 配置已更新。"; }
notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi
        local email_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$EMAIL_TO" ]; then email_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi
        local items_str; items_str=$(cat <<-EOF
  1. › 配置 Telegram  ($tg_status)
  2. › 配置 Email      ($email_status)
  3. › 发送测试通知
  4. › 清空所有通知配置
EOF
)
        _render_menu "⚙️ 通知配置 ⚙️" "$items_str"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${SCRIPT_VERSION} 的*测试消息*。"; log_info "测试通知已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
_parse_watchtower_timestamp_from_log_line() { local log_line="$1"; local timestamp=""; timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$ts"; return 0; fi; echo ""; return 1; }
_date_to_epoch() { local dt="$1"; [ -z "$dt" ] && echo "" && return; if date -d "now" >/dev/null 2>&1; then date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""); elif command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1; then gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""); else log_warn "⚠️ 'date' 或 'gdate' 不支持。"; echo ""; fi; }
show_container_info() { while true; do if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; local header_line; header_line=$(printf "%-5s %-25s %-45s %-20s" "编号" "名称" "镜像" "状态"); local content_lines="$header_line"; local containers=(); local i=1; while IFS='|' read -r name image status; do containers+=("$name"); local status_colored="$status"; if echo "$status" | grep -qE '^Up'; then status_colored="${COLOR_GREEN}运行中${COLOR_RESET}"; elif echo "$status" | grep -qE '^Exited|Created'; then status_colored="${COLOR_RED}已退出${COLOR_RESET}"; else status_colored="${COLOR_YELLOW}${status}${COLOR_RESET}"; fi; content_lines="$content_lines\n$(printf "%-5s %-25.25s %-45.45s %b" "$i" "$name" "$image" "$status_colored")"; i=$(expr $i + 1); done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}'); content_lines="$content_lines\n\n a. 全部启动 (Start All)   s. 全部停止 (Stop All)"; _render_menu "📋 容器管理 📋" "$content_lines"; read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice; case "$choice" in "") return ;; a|A) if confirm_action "确定要启动所有已停止的容器吗?"; then log_info "正在启动..."; local stopped_containers; stopped_containers=$(docker ps -aq -f status=exited); if [ -n "$stopped_containers" ]; then docker start $stopped_containers &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; s|S) if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then log_info "正在停止..."; local running_containers; running_containers=$(docker ps -q); if [ -n "$running_containers" ]; then docker stop $running_containers &>/dev/null || true; fi; log_success "操作完成。"; press_enter_to_continue; else log_info "操作已取消。"; fi ;; *) if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then log_warn "无效输入或编号超范围。"; sleep 1; continue; fi; local selected_container="${containers[$(expr $choice - 1)]}"; if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; local action_items; action_items=$(cat <<-EOF
  1. › 查看日志 (Logs)
  2. › 重启 (Restart)
  3. › 停止 (Stop)
  4. › 删除 (Remove)
  5. › 查看详情 (Inspect)
  6. › 进入容器 (Exec)
EOF
); _render_menu "操作容器: ${selected_container}" "$action_items"; read -r -p " └──> 请选择, 或按 Enter 返回: " action; case "$action" in 1) echo -e "${COLOR_YELLOW}日志 (Ctrl+C 停止)...${COLOR_RESET}"; trap '' INT; docker logs -f --tail 100 "$selected_container" || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue ;; 2) echo "重启中..."; if docker restart "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1 ;; 3) echo "停止中..."; if docker stop "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1 ;; 4) if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then echo "删除中..."; if docker rm -f "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1; else echo "已取消。"; fi ;; 5) _print_header "容器详情: ${selected_container}"; (docker inspect "$selected_container" | jq '.' 2>/dev/null || docker inspect "$selected_container") | less -R; ;; 6) if [ "$(docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]; then log_warn "容器未在运行，无法进入。"; else log_info "尝试进入容器... (输入 'exit' 退出)"; docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true; fi; press_enter_to_continue ;; *) ;; esac ;; esac; done; }
_prompt_for_interval() { local default_value="$1"; local prompt_msg="$2"; local input_interval=""; local result_interval=""; local formatted_default=$(_format_seconds_to_human "$default_value"); while true; do read -r -p "$prompt_msg (例: 300s/2h/1d, [回车]使用 ${formatted_default}): " input_interval; input_interval=${input_interval:-${default_value}s}; if echo "$input_interval" | grep -qE '^([0-9]+)s$'; then result_interval=$(echo "$input_interval" | sed 's/s//'); break; elif echo "$input_interval" | grep -qE '^([0-9]+)h$'; then result_interval=$(expr $(echo "$input_interval" | sed 's/h//') \* 3600); break; elif echo "$input_interval" | grep -qE '^([0-9]+)d$'; then result_interval=$(expr $(echo "$input_interval" | sed 's/d//') \* 86400); break; elif echo "$input_interval" | grep -qE '^[0-9]+$'; then result_interval="${input_interval}"; break; else echo -e "${COLOR_RED}❌ 格式错误...${COLOR_RESET}"; fi; done; echo "$result_interval"; }
configure_exclusion_list() { declare -A excluded_map; if [ -n "$WATCHTOWER_EXCLUDE_LIST" ]; then local IFS=,; for container_name in $WATCHTOWER_EXCLUDE_LIST; do container_name=$(echo "$container_name" | xargs); if [ -n "$container_name" ]; then excluded_map["$container_name"]=1; fi; done; unset IFS; fi; while true; do if [ "${JB_ENABLE_AUTO_CLEAR:-}" = "true" ]; then clear; fi; local all_containers_array=(); while IFS= read -r line; do all_containers_array+=("$line"); done < <(docker ps --format '{{.Names}}'); local items_str=""; local i=0; while [ $i -lt ${#all_containers_array[@]} ]; do local container="${all_containers_array[$i]}"; local is_excluded=" "; if [ -n "${excluded_map[$container]+_}" ]; then is_excluded="✔"; fi; items_str="$items_str\n  $(expr $i + 1). [${COLOR_GREEN}${is_excluded}${COLOR_RESET}] $container"; i=$(expr $i + 1); done; items_str=${items_str#\\n}; local current_excluded_display=""; if [ ${#excluded_map[@]} -gt 0 ]; then current_excluded_display=$(IFS=, ; echo "${!excluded_map[*]}"); fi; items_str="$items_str\n"; items_str="$items_str\n${COLOR_CYAN}当前排除 (脚本内): ${current_excluded_display:-(空, 将使用 config.json)}${COLOR_RESET}"; items_str="$items_str\n${COLOR_CYAN}备用排除 (config.json): ${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-无}${COLOR_RESET}"; _render_menu "配置排除列表 (高优先级)" "$items_str"; read -r -p " └──> 输入数字(可用','分隔)切换, 'c'确认, [回车]使用备用配置: " choice; case "$choice" in c|C) break ;; "") excluded_map=(); log_info "已清空脚本内配置，将使用 config.json 的备用配置。"; sleep 1.5; break ;; *) local clean_choice; clean_choice=$(echo "$choice" | tr -d ' '); IFS=',' read -r -a selected_indices <<< "$clean_choice"; local has_invalid_input=false; for index in "${selected_indices[@]}"; do if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#all_containers_array[@]} ]; then local target_container="${all_containers_array[$(expr $index - 1)]}"; if [ -n "${excluded_map[$target_container]+_}" ]; then unset excluded_map["$target_container"]; else excluded_map["$target_container"]=1; fi; elif [ -n "$index" ]; then has_invalid_input=true; fi; done; if [ "$has_invalid_input" = "true" ]; then log_warn "输入 '${choice}' 中包含无效选项，已忽略。"; sleep 1.5; fi ;; esac; done; local final_excluded_list=""; if [ ${#excluded_map[@]} -gt 0 ]; then final_excluded_list=$(IFS=,; echo "${!excluded_map[*]}"); fi; WATCHTOWER_EXCLUDE_LIST="$final_excluded_list"; }
configure_watchtower(){ _print_header "🚀 Watchtower 配置"; local WT_INTERVAL_TMP="$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL:-300}}" "请输入检查间隔 (config.json 默认: $(_format_seconds_to_human "${WT_CONF_DEFAULT_INTERVAL:-300}"))")"; log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"; sleep 1; configure_exclusion_list; read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice; local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"; if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then read -r -p "请输入额外参数: " temp_extra_args; fi; read -r -p "是否启用调试模式? (y/N): " debug_choice; local temp_debug_enabled="false"; if echo "$debug_choice" | grep -qE '^[Yy]$'; then temp_debug_enabled="true"; fi; _print_header "配置确认"; local final_exclude_list; final_exclude_list="${WATCHTOWER_EXCLUDE_LIST:-${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-无}}"; local source_msg; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then source_msg="脚本"; else source_msg="config.json"; fi; printf " 检查间隔: %s\n" "$(_format_seconds_to_human "$WT_INTERVAL_TMP")"; printf " 排除列表 (%s): %s\n" "$source_msg" "${final_exclude_list//,/, }"; printf " 额外参数: %s\n" "${temp_extra_args:-无}"; printf " 调试模式: %s\n" "$temp_debug_enabled"; echo -e "${COLOR_YELLOW}╰$(generate_line)╯${COLOR_RESET}"; read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice; if echo "$confirm_choice" | grep -qE '^[Nn]$'; then log_info "操作已取消."; return 10; fi; WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"; WATCHTOWER_ENABLED="true"; save_config; set +e; docker rm -f watchtower &>/dev/null || true; set -e; if ! _start_watchtower_container_logic "$WT_INTERVAL_TMP" "Watchtower模式"; then echo -e "${COLOR_RED}❌ Watchtower 启动失败。${COLOR_RESET}"; return 1; fi; return 0; }
manage_tasks(){ while true; do if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; local items="  1. › 停止/移除 Watchtower\n  2. › 重启 Watchtower"; _render_menu "⚙️ 任务管理 ⚙️" "$items"; read -r -p " └──> 请选择, 或按 Enter 返回: " choice; case "$choice" in 1) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then if confirm_action "确定移除 Watchtower？"; then set +e; docker rm -f watchtower &>/dev/null; set -e; WATCHTOWER_ENABLED="false"; save_config; send_notify "🗑️ Watchtower 已从您的服务器移除。"; echo -e "${COLOR_GREEN}✅ 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;; 2) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo "正在重启..."; if docker restart watchtower; then send_notify "🔄 Watchtower 服务已重启。"; echo -e "${COLOR_GREEN}✅ 重启成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 重启失败。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;; *) if [ -z "$choice" ]; then return; else log_warn "无效选项"; sleep 1; fi;; esac; done; }
get_watchtower_all_raw_logs(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 1; fi; docker logs --tail 2000 watchtower 2>&1 || true; }
_extract_interval_from_cmd(){ local cmd_json="$1"; local interval=""; if command -v jq >/dev/null 2>&1; then interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true); else local tokens; read -r -a tokens <<< "$(echo "$cmd_json" | tr -d '[],"')"; local prev=""; for t in "${tokens[@]}"; do if [ "$prev" = "--interval" ]; then interval="$t"; break; fi; prev="$t"; done; fi; interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g'); if [ -z "$interval" ]; then echo ""; else echo "$interval"; fi; }
_get_watchtower_remaining_time(){ local int="$1"; local logs="$2"; if [ -z "$int" ] || [ -z "$logs" ]; then echo -e "${YELLOW}N/A${COLOR_RESET}"; return; fi; local log_line=""; local ts=""; local epoch=0; local rem=0; log_line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true); if [ -z "$log_line" ]; then echo -e "${YELLOW}等待首次扫描...${COLOR_RESET}"; return; fi; ts=$(_parse_watchtower_timestamp_from_log_line "$log_line"); epoch=$(_date_to_epoch "$ts"); if [ "$epoch" -gt 0 ]; then if [[ "$log_line" == *"Session done"* ]]; then rem=$(expr $int - \( $(date +%s) - $epoch \)); elif [[ "$log_line" == *"Scheduling first run"* ]]; then rem=$(expr $epoch - $(date +%s)); elif [[ "$log_line" == *"Starting Watchtower"* ]]; then rem=$(expr \( $epoch + 5 + $int \) - $(date +%s)); fi; if [ "$rem" -gt 0 ]; then printf "%b%02d时%02d分%02d秒%b" "$COLOR_GREEN" $(expr $rem / 3600) $(expr \( $rem % 3600 \) / 60) $(expr $rem % 60) "$COLOR_RESET"; else printf "%b即将进行%b" "$COLOR_GREEN" "$COLOR_RESET"; fi; else echo -e "${YELLOW}计算中...${NC}"; fi; }
get_watchtower_inspect_summary(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 2; fi; local cmd; cmd=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]"); _extract_interval_from_cmd "$cmd" 2>/dev/null || true; }
get_last_session_time(){ local logs; logs=$(get_watchtower_all_raw_logs 2>/dev/null || true); if [ -z "$logs" ]; then echo ""; return 1; fi; local line=""; local ts=""; if echo "$logs" | grep -qiE "permission denied|cannot connect"; then echo -e "${RED}错误:权限不足${NC}"; return 1; fi; line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true); if [ -n "$line" ]; then ts=$(_parse_watchtower_timestamp_from_log_line "$line"); if [ -n "$ts" ]; then echo "$ts"; return 0; fi; fi; echo ""; return 1; }
get_updates_last_24h(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 1; fi; local since=""; if date -d "24 hours ago" >/dev/null 2>&1; then since=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true); elif command -v gdate >/dev/null 2>&1; then since=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true); fi; local raw_logs=""; if [ -n "$since" ]; then raw_logs=$(docker logs --since "$since" watchtower 2>&1 || true); fi; if [ -z "$raw_logs" ]; then raw_logs=$(docker logs --tail 200 watchtower 2>&1 || true); fi; echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|permission denied|cannot connect|Could not do a head request" || true; }
_format_and_highlight_log_line(){ local line="$1"; local ts; ts=$(_parse_watchtower_timestamp_from_log_line "$line"); case "$line" in *"Session done"*) local f; f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p'); local s; s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p'); local u; u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p'); local c="$COLOR_GREEN"; if [ "${f:-0}" -gt 0 ]; then c="$COLOR_YELLOW"; fi; printf "%s %b%s%b\n" "$ts" "$c" "✅ 扫描: ${s:-?}, 更新: ${u:-?}, 失败: ${f:-?}" "$COLOR_RESET"; return ;; *"Found new"*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$COLOR_RESET"; return ;; *"Stopping "*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$COLOR_RESET"; return ;; *"Creating "*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$COLOR_RESET"; return ;; *"No new images found"*) printf "%s %b%s%b\n" "$ts" "$COLOR_CYAN" "ℹ️ 未发现新镜像。" "$COLOR_RESET"; return ;; *"Scheduling first run"*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🕒 首次运行已调度" "$COLOR_RESET"; return ;; *"Starting Watchtower"*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "✨ Watchtower 已启动" "$COLOR_RESET"; return ;; *) if echo "$line" | grep -qiE "\b(unauthorized|failed|error)\b|permission denied|cannot connect|Could not do a head request"; then local msg; msg=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p'); if [ -z "$msg" ]; then msg=$(echo "$line" | sed -E 's/.*(level=(error|warn|info)|time="[^"]*")\s*//g'); fi; printf "%s %b%s%b\n" "$ts" "$COLOR_RED" "❌ 错误: ${msg:-$line}" "$COLOR_RESET"; fi; return ;; esac; }

# =============================================================
# START: MODIFIED show_watchtower_details with dynamic box
# =============================================================
show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi;
        
        local title="📊 Watchtower 详情与管理 📊"
        local interval; interval=$(get_watchtower_inspect_summary 2>/dev/null || true)
        local raw_logs; raw_logs=$(get_watchtower_all_raw_logs)
        local countdown; countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        
        local old_ifs=$IFS; IFS=$'\n'
        local content_lines_array=(
            "上次活动: $(get_last_session_time :- "未检测到")"
            "下次检查: $countdown"
        )
        local updates; updates=$(get_updates_last_24h || true)
        
        content_lines_array+=(" ") # Spacer
        content_lines_array+=("最近 24h 摘要：")
        
        if [ -z "$updates" ]; then
            content_lines_array+=("无日志事件。")
        else
            while IFS= read -r line; do
                content_lines_array+=("$(_format_and_highlight_log_line "$line")")
            done <<< "$updates"
        fi
        
        local max_width=0
        max_width=$(_get_visual_width "$title")
        
        for line in "${content_lines_array[@]}"; do
            local line_width; line_width=$(_get_visual_width "$line")
            if [ "$line_width" -gt "$max_width" ]; then
                max_width=$line_width
            fi
        done
        
        local box_width; box_width=$(expr $max_width + 6)
        
        # Build the final content string
        printf -v content_str '%s\n' "${content_lines_array[@]}"
        
        # Use the new dedicated renderer
        _render_dynamic_box "$title" "$box_width" "$content_str"
        echo -e "${COLOR_BLUE}$(generate_line $(expr $box_width + 2))${COLOR_RESET}"
        
        IFS=$old_ifs
        read -r -p " └──> [1] 实时日志, [2] 容器管理, [3] 触发扫描, [Enter] 返回: " pick
        case "$pick" in
            1) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "\n按 Ctrl+C 停止..."; trap '' INT; docker logs --tail 200 -f watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue; else echo -e "\n${COLOR_RED}Watchtower 未运行。${COLOR_RESET}"; press_enter_to_continue; fi ;;
            2) show_container_info ;;
            3) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then log_info "正在发送 SIGHUP 信号以触发扫描..."; if docker kill -s SIGHUP watchtower; then log_success "信号已发送！请在下方查看实时日志..."; echo -e "按 Ctrl+C 停止..."; sleep 2; trap '' INT; docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; else log_error "发送信号失败！"; fi; else log_warn "Watchtower 未运行，无法触发扫描。"; fi; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}
# =============================================================
# END: MODIFIED show_watchtower_details
# =============================================================

run_watchtower_once(){ echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower${COLOR_RESET}"; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_YELLOW}⚠️ Watchtower 正在后台运行。${COLOR_RESET}"; if ! confirm_action "是否继续？"; then echo -e "${COLOR_YELLOW}已取消。${COLOR_RESET}"; return 0; fi; fi; if ! _start_watchtower_container_logic "" "一次性更新"; then return 1; fi; return 0; }
view_and_edit_config(){ local -a config_items; config_items=( "TG Token|TG_BOT_TOKEN|string" "TG Chat ID|TG_CHAT_ID|string" "Email|EMAIL_TO|string" "额外参数|WATCHTOWER_EXTRA_ARGS|string" "调试模式|WATCHTOWER_DEBUG_ENABLED|bool" "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval" "Watchtower 启用状态|WATCHTOWER_ENABLED|bool" "Cron 执行小时|CRON_HOUR|number_range|0-23" "Cron 项目目录|DOCKER_COMPOSE_PROJECT_DIR_CRON|string" "Cron 任务启用状态|CRON_TASK_ENABLED|bool" ); while true; do if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; load_config; local content_lines=""; local i; for i in "${!config_items[@]}"; do local item="${config_items[$i]}"; local label; label=$(echo "$item" | cut -d'|' -f1); local var_name; var_name=$(echo "$item" | cut -d'|' -f2); local type; type=$(echo "$item" | cut -d'|' -f3); local current_value="${!var_name}"; local display_text=""; local color="${COLOR_CYAN}"; case "$type" in string) if [ -n "$current_value" ]; then color="${COLOR_GREEN}"; display_text="$current_value"; else color="${COLOR_RED}"; display_text="未设置"; fi ;; bool) if [ "$current_value" = "true" ]; then color="${COLOR_GREEN}"; display_text="是"; else color="${COLOR_CYAN}"; display_text="否"; fi ;; interval) display_text=$(_format_seconds_to_human "$current_value"); if [ "$display_text" != "N/A" ]; then color="${COLOR_GREEN}"; else color="${COLOR_RED}"; display_text="未设置"; fi ;; number_range) if [ -n "$current_value" ]; then color="${COLOR_GREEN}"; display_text="$current_value"; else color="${COLOR_RED}"; display_text="未设置"; fi ;; esac; content_lines+=$(printf "\n %2d. %-20s: %b%s%b" "$(expr $i + 1)" "$label" "$color" "$display_text" "$COLOR_RESET"); done; _render_menu "⚙️ 配置查看与编辑 ⚙️" "$content_lines"; read -r -p " └──> 输入编号编辑, 或按 Enter 返回: " choice; if [ -z "$choice" ]; then return; fi; if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then log_warn "无效选项。"; sleep 1; continue; fi; local selected_index=$(expr $choice - 1); local selected_item="${config_items[$selected_index]}"; local label; label=$(echo "$selected_item" | cut -d'|' -f1); local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2); local type; type=$(echo "$selected_item" | cut -d'|' -f3); local extra; extra=$(echo "$selected_item" | cut -d'|' -f4); local current_value="${!var_name}"; local new_value=""; case "$type" in string) read -r -p "请输入新的 '$label' (当前: $current_value): " new_value; declare "$var_name"="${new_value:-$current_value}" ;; bool) read -r -p "是否启用 '$label'? (y/N): " new_value; if echo "$new_value" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi ;; interval) new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔"); if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi ;; number_range) local min; min=$(echo "$extra" | cut -d'-' -f1); local max; max=$(echo "$extra" | cut -d'-' -f2); while true; do read -r -p "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " new_value; if [ -z "$new_value" ]; then break; fi; if echo "$new_value" | grep -qE '^[0-9]+$' && [ "$new_value" -ge "$min" ] && [ "$new_value" -le "$max" ]; then declare "$var_name"="$new_value"; break; else log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"; fi; done ;; esac; save_config; log_info "'$label' 已更新."; sleep 1; done; }
update_menu(){ while true; do if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; local items="  1. › 🚀 Watchtower (推荐, 名称排除)\n  2. › ⚙️ Systemd Timer (Compose 项目)\n  3. › 🕑 Cron (Compose 项目)"; _render_menu "选择更新模式" "$items"; read -r -p " └──> 选择或按 Enter 返回: " c; case "$c" in 1) configure_watchtower; break ;; *) if [ -z "$c" ]; then break; else log_warn "无效选择。"; sleep 1; fi;; esac; done; }

main_menu(){
    if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi; load_config
    local STATUS_RAW="未运行"; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then STATUS_RAW="已启动"; fi
    local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${COLOR_GREEN}已启动${COLOR_RESET}"; else STATUS_COLOR="${COLOR_RED}未运行${COLOR_RESET}"; fi
    local interval=""; local raw_logs=""; if [ "$STATUS_RAW" = "已启动" ]; then interval=$(get_watchtower_inspect_summary); raw_logs=$(get_watchtower_all_raw_logs); fi
    local COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}"); local TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l); local RUNNING=$(docker ps --format '{{.ID}}' | wc -l); local STOPPED=$(expr $TOTAL - $RUNNING)
    local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"; FINAL_EXCLUDE_SOURCE="脚本"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; FINAL_EXCLUDE_SOURCE="config.json"; fi
    local NOTIFY_STATUS=""; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi; if [ -n "$EMAIL_TO" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi
    local header_text="Docker 助手 v${SCRIPT_VERSION}"
    
    local -a status_lines
    status_lines+=("🕝 Watchtower 状态: ${STATUS_COLOR} (名称排除模式)")
    status_lines+=("⏳ 下次检查: ${COUNTDOWN}")
    status_lines+=("📦 容器概览: 总计 $TOTAL (${COLOR_GREEN}运行中 ${RUNNING}${COLOR_RESET}, ${COLOR_RED}已停止 ${STOPPED}${COLOR_RESET})")
    if [ -n "$FINAL_EXCLUDE_LIST" ]; then 
        status_lines+=("🚫 排除列表: ${COLOR_YELLOW}${FINAL_EXCLUDE_LIST//,/, }${COLOR_RESET} (${COLOR_CYAN}${FINAL_EXCLUDE_SOURCE}${COLOR_RESET})")
    fi
    if [ -n "$NOTIFY_STATUS" ]; then 
        status_lines+=("🔔 通知已启用: ${COLOR_GREEN}${NOTIFY_STATUS}${COLOR_RESET}")
    fi
    local simple_status_block; simple_status_block=$(_render_simple_lines " " "${status_lines[@]}")
    
    local -a menu_options
    menu_options+=(" "); menu_options+=("主菜单："); menu_options+=("  1. › 配置 Watchtower"); menu_options+=("  2. › 配置通知"); menu_options+=("  3. › 任务管理"); menu_options+=("  4. › 查看/编辑配置 (底层)"); menu_options+=("  5. › 手动更新所有容器"); menu_options+=("  6. › 详情与管理")
    
    printf -v content_str '%s\n' "$simple_status_block" "${menu_options[@]}"
    _render_menu "$header_text" "$content_str"
    read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice
    case "$choice" in
      1) configure_watchtower || true; press_enter_to_continue; main_menu ;;
      2) notification_menu; main_menu ;;
      3) manage_tasks; main_menu ;;
      4) view_and_edit_config; main_menu ;;
      5) run_watchtower_once; press_enter_to_continue; main_menu ;;
      6) show_watchtower_details; main_menu ;;
      "") exit 10 ;; 
      *) log_warn "无效选项。"; sleep 1; main_menu ;;
    esac
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
