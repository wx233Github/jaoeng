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

# =============================================================
# START: Final _get_visual_width function (FIXED)
# =============================================================
_get_visual_width() {
    local text="$1"
    # 移除颜色代码
    local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    
    local width=0
    local i=0
    while [ $i -lt ${#plain_text} ]; do
        char=${plain_text:$i:1}
        # Check byte length of the character
        if [ "$(echo -n "$char" | wc -c)" -gt 1 ]; then
            width=$((width + 2))
        else
            width=$((width + 1))
        fi
        i=$((i + 1))
    done
    echo $width
}
# =============================================================
# END: Final _get_visual_width function
# =============================================================

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

_render_dynamic_box() {
    local title="$1"; local box_width="$2"; shift 2; local content_str="$@"
    local title_width; title_width=$(_get_visual_width "$title"); local top_bottom_border; top_bottom_border=$(generate_line "$box_width"); local padding_total; padding_total=$(expr $box_width - $title_width); local padding_left; padding_left=$(expr $padding_total / 2); local left_padding; left_padding=$(printf '%*s' "$padding_left"); local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    echo ""; echo -e "${COLOR_YELLOW}╭${top_bottom_border}╮${COLOR_RESET}"; echo -e "${COLOR_YELLOW}│${left_padding}${title}${right_padding}${COLOR_YELLOW}│${COLOR_RESET}"; echo -e "${COLOR_YELLOW}╰${top_bottom_border}╯${COLOR_RESET}"
    local old_ifs=$IFS; IFS=$'\n'
    for line in $content_str; do echo -e "$line"; done
    IFS=$old_ifs
}
_print_header() { _render_menu "$1" ""; }

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
    for line in "${lines[@]}"; do echo -e "${indent}${line}"; done
}
confirm_action() { read -r -p "$(echo -e "${COLOR_YELLOW}$1 ([y]/n): ${COLOR_RESET}")" choice; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

# ... (Omitted unchanged functions for brevity) ...

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
        
        content_lines_array+=(" ")
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
            if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi
        done
        
        local box_width; box_width=$(expr $max_width + 6)
        
        printf -v content_str '%s\n' "${content_lines_array[@]}"
        
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

# ... (rest of the file is unchanged, pasting for completeness)
# All functions from run_watchtower_once to the end are the same.
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
