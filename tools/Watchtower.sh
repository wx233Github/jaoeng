#!/usr/bin/env bash
#
# Docker 自动更新助手 (v3.8.5 - 终极毕业版)
#
set -euo pipefail

export LC_ALL=C.utf8

VERSION="v3.8.5-graduated"

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
    local len=${1:-62}; local char="─"; printf '%*s' "$len" | tr ' ' "$char"
}

_print_header() {
    local title=" $1 "; local total_width=62
    local title_len; title_len=$(echo -n "$title" | wc -m)
    local padding_total=$((total_width - title_len))
    if [ $padding_total -lt 0 ]; then padding_total=0; fi
    local padding_left=$((padding_total / 2))
    echo; echo -e "${COLOR_YELLOW}╭$(generate_line $padding_left)${title}$(generate_line $((padding_total - padding_left)))╮${COLOR_RESET}"
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
  local timezone="${JB_TIMEZONE:-Asia/Shanghai}"; local cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" -d --name watchtower --restart unless-stopped -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval "${wt_interval:-300}"); if [ "$mode_description" = "一次性更新" ]; then cmd_parts=(docker run -e "TZ=${timezone}" -h "$(hostname)" --rm --name watchtower-once -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once); fi
  if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
      cmd_parts+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@${TG_CHAT_ID}?parse_mode=Markdown"); if [[ "${WT_CONF_ENABLE_REPORT}" == "true" ]]; then cmd_parts+=(-e WATCHTOWER_REPORT=true); fi
      local NOTIFICATION_TEMPLATE='🐳 *Docker 容器更新报告*\n\n*服务器:* `{{.Host}}`\n\n{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*\n{{range .Updated}}\n- 🔄 *{{.Name}}*\n  🖼️ *镜像:* `{{.ImageName}}`\n  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*\n  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}\n\n⏰ *时间:* `{{.Report.Time.Format "2006-01-02 15:04:05"}}`'; cmd_parts+=(-e WATCHTOWER_NOTIFICATION_TEMPLATE="$NOTIFICATION_TEMPLATE")
  fi
  if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then cmd_parts+=("--debug"); fi; if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"; cmd_parts+=("${extra_tokens[@]}"); fi
  local final_exclude_list=""; local source_msg=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本内部"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; source_msg="config.json"; fi
  local containers_to_monitor=(); if [ -n "$final_exclude_list" ]; then
      log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"; local exclude_pattern; exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g'); local included_containers; included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
      if [ -n "$included_containers" ]; then readarray -t containers_to_monitor <<< "$included_containers"; log_info "计算后的监控范围: ${containers_to_monitor[*]}"; else log_warn "排除规则导致监控列表为空！"; fi
  else log_info "未发现排除规则，Watchtower 将监控所有容器。"; fi
  _print_header "正在启动 $mode_description"
  if [ ${#containers_to_monitor[@]} -gt 0 ]; then cmd_parts+=("${containers_to_monitor[@]}"); fi
  echo -e "${COLOR_CYAN}执行命令: ${cmd_parts[*]} ${COLOR_RESET}"; set +e; "${cmd_parts[@]}"; local rc=$?; set -e
  if [ "$mode_description" = "一次性更新" ]; then if [ $rc -eq 0 ]; then echo -e "${COLOR_GREEN}✅ $mode_description 完成。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ $mode_description 失败。${COLOR_RESET}"; fi; return $rc
  else sleep 3; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_GREEN}✅ $mode_description 启动成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ $mode_description 启动失败。${COLOR_RESET}"; send_notify "❌ Watchtower 启动失败。"; fi; return 0; fi
}
_configure_telegram() { read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT; TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"; read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT; TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"; log_info "Telegram 配置已更新。"; }
_configure_email() { read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT; EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"; log_info "Email 配置已更新。"; }
notification_menu() {
    while true; do
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "⚙️ 通知配置 ⚙️"; local tg_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$TG_BOT_TOKEN" ]; then tg_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi; local email_status="${COLOR_RED}未配置${COLOR_RESET}"; if [ -n "$EMAIL_TO" ]; then email_status="${COLOR_GREEN}已配置${COLOR_RESET}"; fi; printf " 1. 配置 Telegram  (%b)\n" "$tg_status"; printf " 2. 配置 Email      (%b)\n" "$email_status"; echo " 3. 发送测试通知"; echo " 4. 清空所有通知配置"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; press_enter_to_continue ;; 2) _configure_email; save_config; press_enter_to_continue ;;
            3) if [[ -z "$TG_BOT_TOKEN" && -z "$EMAIL_TO" ]]; then log_warn "请先配置至少一种通知方式。"; else log_info "正在发送测试..."; send_notify "这是一条来自 Docker 助手 v${VERSION} 的*测试消息*。"; log_info "测试通知已发送。"; fi; press_enter_to_continue ;;
            4) if confirm_action "确定要清空所有通知配置吗?"; then TG_BOT_TOKEN=""; TG_CHAT_ID=""; EMAIL_TO=""; save_config; log_info "所有通知配置已清空。"; else log_info "操作已取消。"; fi; press_enter_to_continue ;;
            "") return ;; *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
_parse_watchtower_timestamp_from_log_line() { local log_line="$1"; local timestamp=""; timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true); if [ -n "$timestamp" ]; then echo "$timestamp"; return 0; fi; echo ""; return 1; }
_date_to_epoch() { local dt="$1"; [ -z "$dt" ] && echo "" && return; if [ "$(date -d "now" >/dev/null 2>&1 && echo true)" = "true" ]; then date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""); elif [ "$(command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1 && echo true)" = "true" ]; then gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""); else log_warn "⚠️ 'date' 或 'gdate' 不支持。"; echo ""; fi; }
show_container_info() {
    while true; do 
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "📋 容器管理 📋"; 
        printf "%-5s %-25s %-45s %-20s\n" "编号" "名称" "镜像" "状态"; 
        local containers=(); local i=1; 
        while IFS='|' read -r name image status; do 
            containers+=("$name"); local status_colored="$status"; 
            if [[ "$status" =~ ^Up ]]; then status_colored="${COLOR_GREEN}运行中${COLOR_RESET}"; 
            elif [[ "$status" =~ ^Exited|Created ]]; then status_colored="${COLOR_RED}已退出${COLOR_RESET}"; 
            else status_colored="${COLOR_YELLOW}${status}${COLOR_RESET}"; fi; 
            printf "%-5s %-25.25s %-45.45s %b\n" "$i" "$name" "$image" "$status_colored"; i=$((i+1)); 
        done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}'); 
        echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}";
        echo " a. 全部启动 (Start All)   s. 全部停止 (Stop All)"
        read -r -p "输入编号进入管理菜单, 'a'/'s' 批量操作, 或按 Enter 返回: " choice
        case "$choice" in 
            "") return ;; 
            a|A)
                if confirm_action "确定要启动所有已停止的容器吗?"; then
                    log_info "正在启动..."; local stopped_containers; stopped_containers=$(docker ps -aq -f status=exited); if [ -n "$stopped_containers" ]; then docker start $stopped_containers &>/dev/null || true; fi; log_success "操作完成。"
                    press_enter_to_continue
                else log_info "操作已取消。"; fi ;;
            s|S)
                if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then
                    log_info "正在停止..."; local running_containers; running_containers=$(docker ps -q); if [ -n "$running_containers" ]; then docker stop $running_containers &>/dev/null || true; fi; log_success "操作完成。"
                    press_enter_to_continue
                else log_info "操作已取消。"; fi ;;
            *) 
                if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo -e "${COLOR_RED}❌ 无效输入。${COLOR_RESET}"; sleep 1; continue; fi; 
                if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#containers[@]}" ]; then echo -e "${COLOR_RED}❌ 编号超范围。${COLOR_RESET}"; sleep 1; continue; fi; 
                local selected_container="${containers[$((choice-1))]}"; 
                if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; 
                _print_header "操作容器: ${selected_container}"; 
                echo " 1. 查看日志 (Logs)"; echo " 2. 重启 (Restart)"; echo " 3. 停止 (Stop)"; echo " 4. 删除 (Remove)"; echo " 5. 查看详情 (Inspect)"; echo " 6. 进入容器 (Exec)";
                echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; 
                read -r -p "请选择, 或按 Enter 返回: " action; 
                case "$action" in 
                    1) echo -e "${COLOR_YELLOW}日志 (Ctrl+C 停止)...${COLOR_RESET}"; trap '' INT; docker logs -f --tail 100 "$selected_container" || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue ;; 
                    2) echo "重启中..."; if docker restart "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1 ;; 
                    3) echo "停止中..."; if docker stop "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1 ;; 
                    4) if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then echo "删除中..."; if docker rm -f "$selected_container"; then echo -e "${COLOR_GREEN}✅ 成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 失败。${COLOR_RESET}"; fi; sleep 1; else echo "已取消。"; fi ;;
                    5) _print_header "容器详情: ${selected_container}"; (docker inspect "$selected_container" | jq '.' 2>/dev/null || docker inspect "$selected_container") | less -R; ;;
                    6) if [[ "$(docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]]; then log_warn "容器未在运行，无法进入。"; else log_info "尝试进入容器... (输入 'exit' 退出)"; docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true; fi; press_enter_to_continue ;;
                    *) ;;
                esac 
            ;; 
        esac; 
    done; 
}
_prompt_for_interval() { local default_value="$1"; local prompt_msg="$2"; local input_interval=""; local result_interval=""; local formatted_default=$(_format_seconds_to_human "$default_value"); while true; do read -r -p "$prompt_msg (例: 300s/2h/1d, [回车]使用 ${formatted_default}): " input_interval; input_interval=${input_interval:-${default_value}s}; if [[ "$input_interval" =~ ^([0-9]+)s$ ]]; then result_interval=${BASH_REMATCH[1]}; break; elif [[ "$input_interval" =~ ^([0-9]+)h$ ]]; then result_interval=$((${BASH_REMATCH[1]}*3600)); break; elif [[ "$input_interval" =~ ^([0-9]+)d$ ]]; then result_interval=$((${BASH_REMATCH[1]}*86400)); break; elif [[ "$input_interval" =~ ^[0-9]+$ ]]; then result_interval="${input_interval}"; break; else echo -e "${COLOR_RED}❌ 格式错误...${COLOR_RESET}"; fi; done; echo "$result_interval"; }

### [REWRITTEN] ###
# This function has been completely rewritten for robustness and simplicity.
configure_exclusion_list() {
    # 1. Get all container names into a standard indexed array.
    local all_containers=()
    readarray -t all_containers < <(docker ps --format '{{.Names}}')
    
    # 2. Use an associative array (hash map) for efficient and robust status tracking.
    #    Requires Bash 4+.
    declare -A excluded_map
    if [[ -n "$WATCHTOWER_EXCLUDE_LIST" ]]; then
        # Populate the map from the existing comma-separated string.
        local IFS=','
        for container_name in $WATCHTOWER_EXCLUDE_LIST; do
            # Trim whitespace just in case
            container_name=$(echo "$container_name" | xargs)
            if [[ -n "$container_name" ]]; then
                excluded_map["$container_name"]=1
            fi
        done
        unset IFS
    fi

    while true; do
        if [[ "${JB_ENABLE_AUTO_CLEAR:-}" == "true" ]]; then clear; fi
        _print_header "配置排除列表 (高优先级)"

        # 3. Display the menu. Status is checked directly from the map (O(1) lookup).
        for i in "${!all_containers[@]}"; do
            local container="${all_containers[$i]}"
            local is_excluded=" "
            # '-v' checks for key existence, safer than checking for value.
            if [[ -v excluded_map["$container"] ]]; then
                is_excluded="✔"
            fi
            echo -e " ${COLOR_YELLOW}$((i+1)).${COLOR_RESET} [${COLOR_GREEN}${is_excluded}${COLOR_RESET}] $container"
        done
        
        # Build the current exclusion list string for display purposes.
        local current_excluded_display=""
        if ((${#excluded_map[@]} > 0)); then
            current_excluded_display=$(IFS=, ; echo "${!excluded_map[*]}")
        fi

        echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
        echo -e "${COLOR_CYAN}当前排除 (脚本内): ${current_excluded_display:-(空, 将使用 config.json)}${COLOR_RESET}"
        echo -e "${COLOR_CYAN}备用排除 (config.json): ${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-无}${COLOR_RESET}"
        echo -e "${COLOR_BLUE}操作提示: 输入数字(可用','分隔)切换, 'c'确认, [回车]使用备用配置${COLOR_RESET}"
        read -r -p "请选择: " choice

        case "$choice" in
            c|C) break ;;
            "") 
                excluded_map=() # Clear the map, simple and clean.
                log_info "已清空脚本内配置，将使用 config.json 的备用配置。"; sleep 1.5; 
                break 
                ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' ')
                IFS=',' read -r -a selected_indices <<< "$clean_choice"
                
                local has_invalid_input=false
                for index in "${selected_indices[@]}"; do
                    # 4. Validate input.
                    if [[ "$index" =~ ^[0-9]+$ && "$index" -ge 1 && "$index" -le ${#all_containers[@]} ]]; then
                        local target_container="${all_containers[$((index-1))]}"
                        
                        # 5. Toggle status in the map. This is the new, simple, and robust core logic.
                        if [[ -v excluded_map["$target_container"] ]]; then
                            unset excluded_map["$target_container"] # Remove if exists
                        else
                            excluded_map["$target_container"]=1 # Add if not exists
                        fi
                    else
                        # Only flag as invalid if the token is not an empty string (e.g., from "1,2,").
                        if [[ -n "$index" ]]; then
                            has_invalid_input=true
                        fi
                    fi
                done

                if [[ "$has_invalid_input" == "true" ]]; then
                    log_warn "输入 '${choice}' 中包含无效选项，已忽略。"; sleep 1.5
                fi
                ;;
        esac
    done

    # 6. Convert the map keys back to the final comma-separated string to be saved.
    local final_excluded_list=""
    if ((${#excluded_map[@]} > 0)); then
        # This is a robust way to join array keys with a comma.
        final_excluded_list=$(IFS=,; echo "${!excluded_map[*]}")
    fi
    WATCHTOWER_EXCLUDE_LIST="$final_excluded_list"
}


configure_watchtower(){ 
    _print_header "🚀 Watchtower 配置"; local current_saved_interval="${WATCHTOWER_CONFIG_INTERVAL}"; local config_json_interval="${WT_CONF_DEFAULT_INTERVAL:-300}"; local prompt_default="${current_saved_interval:-$config_json_interval}"; local prompt_text="请输入检查间隔 (config.json 默认: $(_format_seconds_to_human "$config_json_interval"))"; local WT_INTERVAL_TMP="$(_prompt_for_interval "$prompt_default" "$prompt_text")"; log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"; sleep 1; configure_exclusion_list; read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice; if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then read -r -p "请输入额外参数: " temp_extra_args; else temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"; fi; read -r -p "是否启用调试模式? (y/N): " debug_choice; local temp_debug_enabled=$([[ "$debug_choice" =~ ^[Yy]$ ]] && echo "true" || echo "false"); 
    _print_header "配置确认"; printf " 检查间隔: %s\n" "$(_format_seconds_to_human "$WT_INTERVAL_TMP")"; local final_exclude_list=""; local source_msg=""; if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"; source_msg="脚本"; else final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-无}"; source_msg="config.json"; fi; printf " 排除列表 (%s): %s\n" "$source_msg" "${final_exclude_list//,/, }"; printf " 额外参数: %s\n" "${temp_extra_args:-无}"; printf " 调试模式: %s\n" "$temp_debug_enabled"; echo -e "${COLOR_YELLOW}╰$(generate_line)╯${COLOR_RESET}"; read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice
    if [[ "$confirm_choice" =~ ^[Nn]$ ]]; then log_info "操作已取消。"; return 10; fi
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"; WATCHTOWER_EXTRA_ARGS="$temp_extra_args"; WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"; WATCHTOWER_ENABLED="true"; save_config; set +e; docker rm -f watchtower &>/dev/null || true; set -e; if ! _start_watchtower_container_logic "$WT_INTERVAL_TMP" "Watchtower模式"; then echo -e "${COLOR_RED}❌ Watchtower 启动失败。${COLOR_RESET}"; return 1; fi; return 0;
}
manage_tasks(){ while true; do if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "⚙️ 任务管理 ⚙️"; echo " 1. 停止/移除 Watchtower"; echo " 2. 移除 Cron"; echo " 3. 移除 Systemd Timer"; echo " 4. 重启 Watchtower"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "请选择, 或按 Enter 返回: " choice; case "$choice" in 1) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then if confirm_action "确定移除 Watchtower？"; then set +e; docker rm -f watchtower &>/dev/null; set -e; WATCHTOWER_ENABLED="false"; save_config; send_notify "🗑️ Watchtower 已移除"; echo -e "${COLOR_GREEN}✅ 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;; 2) local SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"; if crontab -l 2>/dev/null | grep -q "$SCRIPT"; then if confirm_action "确定移除 Cron？"; then (crontab -l 2>/dev/null | grep -v "$SCRIPT") | crontab -; rm -f "$SCRIPT" 2>/dev/null || true; CRON_TASK_ENABLED="false"; save_config; send_notify "🗑️ Cron 已移除"; echo -e "${COLOR_GREEN}✅ Cron 已移除。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ 未发现 Cron 任务。${COLOR_RESET}"; fi; press_enter_to_continue ;; 3) if systemctl list-timers | grep -q "docker-compose-update.timer"; then if confirm_action "确定移除 Systemd Timer？"; then systemctl disable --now docker-compose-update.timer &>/dev/null; rm -f /etc/systemd/system/docker-compose-update.{service,timer}; systemctl daemon-reload; log_info "Systemd Timer 已移除。"; fi; else echo -e "${COLOR_YELLOW}ℹ️ 未发现 Systemd Timer。${COLOR_RESET}"; fi; press_enter_to_continue ;; 4) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo "正在重启..."; if docker restart watchtower; then send_notify "🔄 Watchtower 已重启"; echo -e "${COLOR_GREEN}✅ 重启成功。${COLOR_RESET}"; else echo -e "${COLOR_RED}❌ 重启失败。${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 未运行。${COLOR_RESET}"; fi; press_enter_to_continue ;; "") return ;; *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;; esac; done; }
get_watchtower_all_raw_logs(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 1; fi; docker logs --tail 2000 watchtower 2>&1 || true; }
_extract_interval_from_cmd(){ local cmd_json="$1"; local interval=""; if command -v jq >/dev/null 2>&1; then interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true); else local tokens=( $(echo "$cmd_json" | tr -d '[],"' | xargs) ); local prev=""; for t in "${tokens[@]}"; do if [ "$prev" = "--interval" ]; then interval="$t"; break; fi; prev="$t"; done; fi; interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g'); [ -z "$interval" ] && echo "" || echo "$interval"; }
_get_watchtower_remaining_time(){ local int="$1"; local logs="$2"; if [ -z "$int" ] || [ -z "$logs" ]; then echo -e "${COLOR_YELLOW}N/A${COLOR_RESET}"; return; fi; if ! echo "$logs" | grep -q "Session done"; then if echo "$logs" | grep -q "Scheduling first run"; then local first_run_log; first_run_log=$(echo "$logs" | grep "Scheduling first run" | tail -n 1); local ts; ts=$(_parse_watchtower_timestamp_from_log_line "$first_run_log"); if [ -n "$ts" ]; then local epoch; epoch=$(_date_to_epoch "$ts"); if [ -n "$epoch" ]; then local rem=$((epoch - $(date +%s))); if [ "$rem" -gt 0 ]; then printf "%b%02d时%02d分%02d秒%b" "$COLOR_GREEN" $((rem/3600)) $(((rem%3600)/60)) $((rem%60)) "$COLOR_RESET"; else printf "%b即将进行%b" "$COLOR_GREEN" "$COLOR_RESET"; fi; return; fi; fi; fi; echo -e "${COLOR_YELLOW}等待首次扫描...${COLOR_RESET}"; return; fi; local log; log=$(echo "$logs" | grep -E "Session done" | tail -n 1 || true); local ts=""; if [ -n "$log" ]; then ts=$(_parse_watchtower_timestamp_from_log_line "$log"); fi; if [ -n "$ts" ]; then local epoch; epoch=$(_date_to_epoch "$ts"); if [ -n "$epoch" ]; then local rem=$((int - ( $(date +%s) - epoch ))); if [ "$rem" -gt 0 ]; then printf "%b%02d时%02d分%02d秒%b" "$COLOR_GREEN" $((rem/3600)) $(((rem%3600)/60)) $((rem%60)) "$COLOR_RESET"; else printf "%b即将进行%b" "$COLOR_GREEN" "$COLOR_RESET"; fi; else echo -e "${COLOR_RED}时间解析失败${COLOR_RESET}"; fi; else echo -e "${COLOR_YELLOW}未找到扫描日志${COLOR_RESET}"; fi; }
get_watchtower_inspect_summary(){ if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 2; fi; local cmd; cmd=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]"); _extract_interval_from_cmd "$cmd" 2>/dev/null || true; }
get_last_session_time(){ local logs; logs=$(get_watchtower_all_raw_logs 2>/dev/null || true); if [ -z "$logs" ]; then echo ""; return 1; fi; local line=""; local ts=""; if echo "$logs" | grep -qiE "permission denied|cannot connect"; then echo -e "${COLOR_RED}错误:权限不足${COLOR_RESET}"; return 1; fi; line=$(echo "$logs" | grep -E "Session done" | tail -n 1 || true); if [ -n "$line" ]; then ts=$(_parse_watchtower_timestamp_from_log_line "$line"); if [ -n "$ts" ]; then echo "$ts"; return 0; fi; fi; line=$(echo "$logs" | grep -E "Scheduling first run" | tail -n 1 || true); if [ -n "$line" ]; then ts=$(_parse_watchtower_timestamp_from_log_line "$line"); if [ -n "$ts" ]; then echo "$ts (首次)"; return 0; fi; fi; line=$(echo "$logs" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z? INFO' | tail -n 1 || true); if [ -n "$line" ]; then ts=$(_parse_watchtower_timestamp_from_log_line "$line"); if [ -n "$ts" ]; then echo "$ts (活动)"; return 0; fi; fi; echo ""; return 1; }
get_updates_last_24h(){ 
    if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo ""; return 1; fi; local since=""; if [ "$(date -d "24 hours ago" >/dev/null 2>&1 && echo true)" = "true" ]; then since=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true); elif [ "$(command -v gdate >/dev/null 2>&1 && echo true)" = "true" ]; then since=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true); fi; local raw_logs=""; if [ -n "$since" ]; then raw_logs=$(docker logs --since "$since" watchtower 2>&1 || true); fi; if [ -z "$raw_logs" ]; then raw_logs=$(docker logs --tail 200 watchtower 2>&1 || true); fi
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|permission denied|cannot connect|Could not do a head request" || true
}
_format_and_highlight_log_line(){ local line="$1"; local ts; ts=$(_parse_watchtower_timestamp_from_log_line "$line"); case "$line" in *"Session done"*) local f; f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p'); local s; s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p'); local u; u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p'); if [[ -n "$s" && -n "$u" && -n "$f" ]]; then local c="$COLOR_GREEN"; if [ "$f" -gt 0 ]; then c="$COLOR_YELLOW"; fi; printf "%s %b%s%b\n" "$ts" "$c" "✅ 扫描: ${s}, 更新: ${u}, 失败: ${f}" "$COLOR_RESET"; else printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "$line" "$COLOR_RESET"; fi; return ;; *"Found new"*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$COLOR_RESET"; return ;; *"Stopping "*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$COLOR_RESET"; return ;; *"Creating "*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$COLOR_RESET"; return ;; *"No new images found"*) printf "%s %b%s%b\n" "$ts" "$COLOR_CYAN" "ℹ️ 未发现新镜像。" "$COLOR_RESET"; return ;; *"Scheduling first run"*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "🕒 首次运行已调度" "$COLOR_RESET"; return ;; *"Starting Watchtower"*) printf "%s %b%s%b\n" "$ts" "$COLOR_GREEN" "✨ Watchtower 已启动" "$COLOR_RESET"; return ;; esac; if echo "$line" | grep -qiE "\b(unauthorized|failed|error)\b|permission denied|cannot connect|Could not do a head request"; then local msg; msg=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p'); if [ -z "$msg" ]; then msg=$(echo "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z? *//; s/.*time="[^"]*" *//; s/level=(error|warn|info) *//'); fi; printf "%s %b%s%b\n" "$ts" "$COLOR_RED" "❌ 错误: ${msg:-$line}" "$COLOR_RESET"; printf "   %b💡 [建议]: 认证失败。如果您使用私有仓库，请检查 Docker 登录凭证。%b\n" "$COLOR_YELLOW" "$COLOR_RESET"; return; fi; echo "$line"; }
show_watchtower_details(){ 
    while true; do
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "📊 Watchtower 详情与管理 📊"; local interval; interval=$(get_watchtower_inspect_summary 2>/dev/null || true); echo "上次活动: $(get_last_session_time :- "未检测到")"; local raw_logs countdown; raw_logs=$(get_watchtower_all_raw_logs); countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}"); printf "下次检查: %s\n" "$countdown"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; echo "最近 24h 摘要："; local updates; updates=$(get_updates_last_24h || true); if [ -z "$updates" ]; then echo "无日志事件。"; else echo "$updates" | tail -n 200 | while IFS= read -r line; do _format_and_highlight_log_line "$line"; done; fi; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "[1] 实时日志, [2] 管理容器, [3] 立即触发扫描, [Enter] 返回: " pick; 
        case "$pick" in
            1) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "\n按 Ctrl+C 停止..."; trap '' INT; docker logs --tail 200 -f watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; press_enter_to_continue; else echo -e "\n${COLOR_RED}Watchtower 未运行。${COLOR_RESET}"; press_enter_to_continue; fi ;;
            2) show_container_info ;;
            3) if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then log_info "正在发送 SIGHUP 信号以触发扫描..."; if docker kill -s SIGHUP watchtower; then log_success "信号已发送！请在下方查看实时日志..."; echo -e "按 Ctrl+C 停止..."; sleep 2; trap '' INT; docker logs -f --tail 100 watchtower || true; trap 'echo -e "\n操作被中断。"; exit 10' INT; else log_error "发送信号失败！"; fi; else log_warn "Watchtower 未运行，无法触发扫描。"; fi; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}
run_watchtower_once(){ echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower${COLOR_RESET}"; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${COLOR_YELLOW}⚠️ Watchtower 正在后台运行。${COLOR_RESET}"; if ! confirm_action "是否继续？"; then echo -e "${COLOR_YELLOW}已取消。${COLOR_RESET}"; return 0; fi; fi; if ! _start_watchtower_container_logic "" "一次性更新"; then return 1; fi; return 0; }
view_and_edit_config(){ 
    while true; do 
        if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; load_config; _print_header "⚙️ 配置查看与编辑 ⚙️"; local text; local color;
        if [ -n "${TG_BOT_TOKEN:-}" ]; then color="${COLOR_GREEN}"; text="已设置"; else color="${COLOR_RED}"; text="未设置"; fi; printf " 1. TG Token: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ -n "${TG_CHAT_ID:-}" ]; then color="${COLOR_GREEN}"; text="${TG_CHAT_ID}"; else color="${COLOR_RED}"; text="未设置"; fi; printf " 2. TG Chat ID:   %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ -n "${EMAIL_TO:-}" ]; then color="${COLOR_GREEN}"; text="${EMAIL_TO}"; else color="${COLOR_RED}"; text="未设置"; fi; printf " 3. Email:     %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ -n "${WATCHTOWER_EXTRA_ARGS:-}" ]; then color="${COLOR_GREEN}"; text="${WATCHTOWER_EXTRA_ARGS}"; else color="${COLOR_CYAN}"; text="无"; fi; printf " 4. 额外参数: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ "${WATCHTOWER_DEBUG_ENABLED:-false}" = "true" ]; then color="${COLOR_GREEN}"; text="是"; else color="${COLOR_CYAN}"; text="否"; fi; printf " 5. 调试模式: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        text=$(_format_seconds_to_human "${WATCHTOWER_CONFIG_INTERVAL:-}"); if [ "$text" != "N/A" ]; then color="${COLOR_GREEN}"; else color="${COLOR_RED}"; text="未设置"; fi; printf " 6. 间隔: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ "${WATCHTOWER_ENABLED:-false}" = "true" ]; then color="${COLOR_GREEN}"; text="是"; else color="${COLOR_RED}"; text="否"; fi; printf " 7. 启用状态: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ -n "${CRON_HOUR:-}" ]; then color="${COLOR_GREEN}"; text="${CRON_HOUR}"; else color="${COLOR_RED}"; text="未设置"; fi; printf " 8. Cron 小时:      %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ -n "${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}" ]; then color="${COLOR_GREEN}"; text="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"; else color="${COLOR_RED}"; text="未设置"; fi; printf " 9. Cron 目录: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        if [ "${CRON_TASK_ENABLED:-false}" = "true" ]; then color="${COLOR_GREEN}"; text="是"; else color="${COLOR_RED}"; text="否"; fi; printf "10. Cron 状态: %b%s%b\n" "$color" "$text" "$COLOR_RESET";
        echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "输入编号编辑, 或按 Enter 返回: " choice
        case "$choice" in 
            1) read -r -p "新 Token: " a; TG_BOT_TOKEN="${a:-$TG_BOT_TOKEN}"; save_config ;; 2) read -r -p "新 Chat ID: " a; TG_CHAT_ID="${a:-$TG_CHAT_ID}"; save_config ;; 3) read -r -p "新 Email: " a; EMAIL_TO="${a:-$EMAIL_TO}"; save_config ;; 4) read -r -p "新额外参数: " a; WATCHTOWER_EXTRA_ARGS="${a:-}"; save_config ;; 5) read -r -p "启用调试？(y/n): " d; WATCHTOWER_DEBUG_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 6) local new_interval=$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-300}" "新间隔"); if [ -n "$new_interval" ]; then WATCHTOWER_CONFIG_INTERVAL="$new_interval"; save_config; fi ;; 7) read -r -p "启用 Watchtower？(y/n): " d; WATCHTOWER_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 8) while true; do read -r -p "新 Cron 小时(0-23): " a; if [ -z "$a" ]; then break; fi; if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 0 ] && [ "$a" -le 23 ]; then CRON_HOUR="$a"; save_config; break; else echo "无效"; fi; done ;; 9) read -r -p "新 Cron 目录: " a; DOCKER_COMPOSE_PROJECT_DIR_CRON="${a:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}"; save_config ;; 10) read -r -p "启用 Cron？(y/n): " d; CRON_TASK_ENABLED=$([ "$d" =~ ^[Yy]$ ] && echo "true" || echo "false"); save_config ;; 
            "") return ;; *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;; 
        esac; 
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 10 ]; then sleep 0.5; fi; 
    done; 
}
update_menu(){ while true; do if [[ "${JB_ENABLE_AUTO_CLEAR}" == "true" ]]; then clear; fi; _print_header "选择更新模式"; echo " 1. 🚀 Watchtower (推荐, 名称排除)"; echo " 2. ⚙️ Systemd Timer (Compose 项目)"; echo " 3. 🕑 Cron (Compose 项目)"; echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"; read -r -p "选择或按 Enter 返回: " c; case "$c" in 1) configure_watchtower; break ;; 2) configure_systemd_timer; break ;; 3) configure_cron_task; break ;; "") break ;; *) echo -e "${COLOR_YELLOW}无效选择。${COLOR_RESET}"; sleep 1 ;; esac; done; }
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
    
    echo -e " 🕝 Watchtower 状态: $STATUS_COLOR (名称排除模式)"
    echo -e "      ⏳ 下次检查: $COUNTDOWN"
    echo -e "      📦 容器概览: 总计 $TOTAL (${COLOR_GREEN}运行中 ${RUNNING}${COLOR_RESET}, ${COLOR_RED}已停止 ${STOPPED}${COLOR_RESET})"
    
    local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE=""
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"; FINAL_EXCLUDE_SOURCE="脚本"; elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_CONFIG:-}" ]; then FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_CONFIG}"; FINAL_EXCLUDE_SOURCE="config.json"; fi
    if [ -n "$FINAL_EXCLUDE_LIST" ]; then echo -e " 🚫 排除列表 (${FINAL_EXCLUDE_SOURCE}): ${COLOR_YELLOW}${FINAL_EXCLUDE_LIST//,/, }${COLOR_RESET}"; fi
    local NOTIFY_STATUS=""; if [[ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi; if [[ -n "$EMAIL_TO" ]]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS+=", Email"; else NOTIFY_STATUS="Email"; fi; fi; if [ -n "$NOTIFY_STATUS" ]; then echo -e " 🔔 通知已启用: ${COLOR_GREEN}${NOTIFY_STATUS}${COLOR_RESET}"; fi
    
    echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
    echo " 主菜单："
    echo " 1. 配置 Watchtower"
    echo " 2. 配置通知"
    echo " 3. 任务管理"
    echo " 4. 查看/编辑配置 (底层)"
    echo " 5. 手动更新所有容器"
    echo " 6. 详情与管理"
    echo -e "${COLOR_BLUE}$(generate_line)${COLOR_RESET}"
    read -r -p "输入选项 [1-6] 或按 Enter 返回: " choice
    
    case "$choice" in
      1) configure_watchtower || true; press_enter_to_continue ;;
      2) notification_menu ;;
      3) manage_tasks ;;
      4) view_and_edit_config ;;
      5) run_watchtower_once; press_enter_to_continue ;;
      6) show_watchtower_details ;;
      "") exit 10 ;; 
      *) echo -e "${COLOR_RED}❌ 无效选项。${COLOR_RESET}"; sleep 1 ;;
    esac
  done
}

# 脚本主入口，增加命令行参数处理
main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT

    # 如果第一个参数是 --run-once，则直接执行一次性更新任务
    if [[ "${1:-}" == "--run-once" ]]; then
        run_watchtower_once
        # 根据执行结果返回退出码
        exit $?
    fi

    # 否则，显示主菜单
    main_menu
    exit 10
}

# 将所有命令行参数传递给 main 函数
main "$@"
