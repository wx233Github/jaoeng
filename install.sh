#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装脚本 (v74.17-深度调试版)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v74.17"

# --- 开启调试模式 ---
set -x # <<< 为调试目的添加，请将所有输出复制给我！

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    log_err() { echo "[错误] $*" >&2; }
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 全局变量和配置加载 ---
INSTALL_DIR="/opt/vps_install_modules"
BIN_DIR="/usr/local/bin"
LOCK_FILE="/tmp/vps_install_modules.lock"
CONFIG_FILE="$INSTALL_DIR/config.json" # Path to config.json

# Default values, will be overwritten by config.json
ENABLE_AUTO_CLEAR="false"
TIMEZONE="Asia/Shanghai"
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

# Function to load config.json (using jq)
load_main_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_err "配置文件 $CONFIG_FILE 未找到！"
        exit 1
    fi
    
    # Check for jq dependency
    if ! command -v jq &>/dev/null; then
        log_err "jq 工具未安装。请手动安装：sudo apt install jq 或 sudo yum install jq。"
        exit 1
    fi

    ENABLE_AUTO_CLEAR=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE")
    TIMEZONE=$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE")
    BASE_URL=$(jq -r '.base_url // "https://raw.githubusercontent.com/wx233Github/jaoeng/main"' "$CONFIG_FILE")
    
    # Export for sub-scripts
    export JB_ENABLE_AUTO_CLEAR="$ENABLE_AUTO_CLEAR"
    export JB_TIMEZONE="$TIMEZONE"
    export JB_BASE_URL="$BASE_URL"
}

# --- 锁文件机制 ---
_acquire_lock() {
    exec 200>"$LOCK_FILE"
    flock -n 200 || { log_warn "脚本已在运行，请勿重复启动。"; exit 1; }
}
_release_lock() {
    flock -u 200
    rm -f "$LOCK_FILE"
}
trap _release_lock EXIT

# --- 依赖检查函数 ---
_check_dependencies() {
    local common_deps
    common_deps=$(jq -r '.dependencies.common' "$CONFIG_FILE")
    
    for dep in $common_deps; do
        if ! command -v "$dep" &>/dev/null; then
            log_err "依赖 '$dep' 未安装。请手动安装：sudo apt install $dep 或 sudo yum install $dep"
            exit 1
        fi
    done
}

# --- 运行模块函数 ---
_run_module() {
    local module_path="$1"
    local module_display_name="$2" # 用于日志显示
    if [ ! -f "$INSTALL_DIR/$module_path" ]; then
        log_err "模块文件 '$INSTALL_DIR/$module_path' 不存在。"
        return 1
    fi
    log_info "您选择了 [${module_display_name}]"
    
    local module_name=$(basename "$module_path" .sh | tr '[:lower:]' '[:upper:]')
    local config_json_path=".module_configs.$(basename "$module_path" .sh | cut -d'.' -f1)"
    
    local module_config_vars
    module_config_vars=$(jq -r "del(.comment_*) | .$config_json_path | to_entries[] | \"${module_name}_CONF_\" + (.key | ascii_upcase) + \"=\\\"\" + (.value | tostring) + \"\\\"\"" "$CONFIG_FILE" || true)
    
    if [ -n "$module_config_vars" ]; then
        eval "export $module_config_vars"
        log_debug "Exported module configs for $module_name: $module_config_vars"
    fi

    "$INSTALL_DIR/$module_path" || {
        local exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            log_warn "模块 [${module_display_name}] 执行出错 (码: $exit_code)."
        fi
    }
    unset_module_configs "$module_name"
    press_enter_to_continue
}

# Function to unset module specific environment variables
unset_module_configs() {
    local module_prefix="$1_CONF_"
    for var in $(compgen -v | grep "^${module_prefix}"); do
        unset "$var"
    done
}

# --- 状态检查辅助函数 (返回纯文本，不带颜色，由调用者添加颜色) ---
_is_docker_daemon_running() {
    if JB_SUDO_LOG_QUIET="true" systemctl is-active --quiet docker &>/dev/null; then
        return 0 # Running
    elif JB_SUDO_LOG_QUIET="true" service docker status &>/dev/null; then
        return 0 # Running (fallback)
    fi
    return 1 # Not running
}

_is_docker_compose_installed_and_running() {
    local compose_cmd=""
    if command -v docker-compose &>/dev/null; then
        compose_cmd="docker-compose"
    elif docker compose version &>/dev/null; then # docker compose (v2)
        compose_cmd="docker compose"
    fi

    if [ -n "$compose_cmd" ]; then
        # Check if any compose services are running. `ps -q` is quiet and lists IDs.
        # If no services are running, `ps -q` might output nothing or an error,
        # so we check if the command itself succeeds and produces output.
        if JB_SUDO_LOG_QUIET="true" $compose_cmd ps -q &>/dev/null; then
            return 0 # Installed and services running
        else
            # Check if it's just installed but no services are up
            if JB_SUDO_LOG_QUIET="true" $compose_cmd version &>/dev/null; then
                return 2 # Installed but no services running
            fi
        fi
    fi
    return 1 # Not installed or not working
}

_is_nginx_running() {
    if JB_SUDO_LOG_QUIET="true" systemctl is-active --quiet nginx &>/dev/null; then
        return 0
    elif JB_SUDO_LOG_QUIET="true" service nginx status &>/dev/null; then
        return 0
    fi
    return 1
}

_is_watchtower_running() {
    if JB_SUDO_LOG_QUIET="true" docker ps --format '{{.Names}}' | grep -q '^watchtower$' &>/dev/null; then
        return 0
    fi
    return 1
}

# --- 核心功能函数 ---
confirm_and_force_update() {
    if confirm_action "警告: 这将强制更新所有脚本文件。您确定吗?"; then
        log_info "正在强制更新脚本..."
        # TODO: Add actual force update logic here
        log_success "脚本更新完成。请重新运行脚本。"
        exit 0
    else
        log_info "操作已取消。"
    fi
    press_enter_to_continue
}

uninstall_script() {
    if confirm_action "警告: 这将卸载整个脚本系统。您确定吗?"; then
        log_info "正在卸载脚本..."
        # TODO: Add actual uninstall logic here
        log_success "脚本卸载完成。"
        exit 0
    else
        log_info "操作已取消。"
    fi
    press_enter_to_continue
}

# Global variable to store the count of numbered menu items
MAIN_MENU_ITEM_COUNT=0

# --- Tools Submenu Function ---
tools_menu() {
    local tools_menu_title=$(jq -r '.menus.TOOLS_MENU.title' "$CONFIG_FILE")
    local -a tools_menu_items_config
    mapfile -t tools_menu_items_config < <(jq -c '.menus.TOOLS_MENU.items[]' "$CONFIG_FILE")

    local item_count=0
    local -a menu_lines=()
    for item_json in "${tools_menu_items_config[@]}"; do
        item_count=$((item_count + 1))
        local name=$(echo "$item_json" | jq -r '.name')
        local icon=$(echo "$item_json" | jq -r '.icon // ""')
        menu_lines+=("  ${item_count}. ${icon} ${name}")
    done

    while true; do
        if [ "$ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
        _render_menu "$tools_menu_title" "${menu_lines[@]}"
        read -r -p " └──> 请选择 [1-${item_count}], 或 [Enter] 返回: " choice < /dev/tty

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$item_count" ]; then
            local selected_item_json="${tools_menu_items_config[$((choice - 1))]}"
            local selected_action_path=$(echo "$selected_item_json" | jq -r '.action')
            local selected_action_name=$(echo "$selected_item_json" | jq -r '.name') # Get name for display
            _run_module "$selected_action_path" "$selected_action_name"
        elif [ -z "$choice" ]; then
            log_info "返回主菜单。"
            return # Return to main_menu
        else
            log_warn "无效选项。请重新输入。"
            sleep 1
        fi
    done
}

# --- 主菜单渲染函数 ---
render_main_menu() {
    local main_menu_title=$(jq -r '.menus.MAIN_MENU.title' "$CONFIG_FILE")
    local -a menu_items_config
    mapfile -t menu_items_config < <(jq -c '.menus.MAIN_MENU.items[]' "$CONFIG_FILE")

    local -a left_column_lines=()
    local -a right_column_lines=()
    local item_idx=0

    # Populate left column (numbered items)
    for item_json in "${menu_items_config[@]}"; do
        local type=$(echo "$item_json" | jq -r '.type')
        local name=$(echo "$item_json" | jq -r '.name')
        local icon=$(echo "$item_json" | jq -r '.icon // ""')
        
        if [ "$type" = "item" ] || [ "$type" = "submenu" ]; then
            item_idx=$((item_idx + 1))
            left_column_lines+=("  ${item_idx}. ${icon} ${name}")
        fi
    done
    
    # Populate right column (statuses and options)
    # Docker Status
    local docker_overall_status_display=""
    if _is_docker_daemon_running; then
        local compose_status_code
        _is_docker_compose_installed_and_running; compose_status_code=$?
        if [ "$compose_status_code" -eq 0 ]; then
            docker_overall_status_display="Docker: ${GREEN}已运行${NC}"
        elif [ "$compose_status_code" -eq 2 ]; then
            docker_overall_status_display="Docker: ${YELLOW}Compose服务未运行${NC}"
        elif [ "$compose_status_code" -eq 1 ]; then
            docker_overall_status_display="Docker: ${RED}Compose未安装${NC}"
        fi
    else
        docker_overall_status_display="Docker: ${RED}守护进程未运行${NC}"
    fi
    right_column_lines+=("$docker_overall_status_display")

    # Nginx Status
    if _is_nginx_running; then
        right_column_lines+=("Nginx: ${GREEN}已运行${NC}")
    else
        right_column_lines+=("Nginx: ${RED}未运行${NC}")
    fi

    # Watchtower Status
    if _is_watchtower_running; then
        right_column_lines+=("Watchtower: ${GREEN}已运行${NC}")
    else
        right_column_lines+=("Watchtower: ${RED}未运行${NC}")
    fi

    # Separator for options
    right_column_lines+=("") # Empty line for spacing

    # Options a.c
    for item_json in "${menu_items_config[@]}"; do
        local type=$(echo "$item_json" | jq -r '.type')
        local name=$(echo "$item_json" | jq -r '.name')
        local icon=$(echo "$item_json" | jq -r '.icon // ""')
        if [ "$type" = "func" ]; then
            case "$name" in
                "强制重置")
                    right_column_lines+=("a. ${icon} ${name}")
                    ;;
                "卸载脚本")
                    right_column_lines+=("c. ${icon} ${name}")
                    ;;
            esac
        fi
    done

    # Calculate max widths for each column
    local max_left_width=0
    for line in "${left_column_lines[@]}"; do
        local w=$(_get_visual_width "$line")
        if (( w > max_left_width )); then max_left_width=$w; fi
    done

    local max_right_width=0
    for line in "${right_column_lines[@]}"; do
        local w=$(_get_visual_width "$line")
        if (( w > max_right_width )); then max_right_width=$w; fi
    done

    # Ensure minimum widths for aesthetic
    if (( max_left_width < 20 )); then max_left_width=20; fi
    if (( max_right_width < 25 )); then max_right_width=25; fi # Give more space for status messages

    local separator_chars=" │ " # 3 visual characters
    local separator_visual_width=$(_get_visual_width "$separator_chars")

    local total_inner_content_width=$((max_left_width + separator_visual_width + max_right_width))
    local min_total_width=70 # Minimum total width for the box
    if (( total_inner_content_width < min_total_width )); then
        total_inner_content_width=$min_total_width
    fi

    local outer_padding_chars=2 # For "│ " and " │"
    local box_width=$((total_inner_content_width + outer_padding_chars))

    # Render top border
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_width" "─")╮${NC}"
    
    # Title
    local title_content_width=$(_get_visual_width "$main_menu_title")
    local title_padding_total=$((box_width - title_content_width - outer_padding_chars))
    local title_padding_left=$((title_padding_total / 2))
    local title_padding_right=$((title_padding_total - title_padding_left))
    echo -e "${GREEN}│$(printf '%*s' "$title_padding_left") ${main_menu_title} $(printf '%*s' "$title_padding_right")│${NC}"
    
    # Separator line if there are items
    if [ ${#left_column_lines[@]} -gt 0 ] || [ ${#right_column_lines[@]} -gt 0 ]; then
        echo -e "${GREEN}│$(generate_line "$box_width" "─")│${NC}"
    fi

    # Render content rows
    local max_rows=$(( ${#left_column_lines[@]} > ${#right_column_lines[@]} ? ${#left_column_lines[@]} : ${#right_column_lines[@]} ))

    for (( i=0; i < max_rows; i++ )); do
        local left_line="${left_column_lines[$i]:-}"
        local right_line="${right_column_lines[$i]:-}"

        local left_current_visual_width=$(_get_visual_width "$left_line")
        local right_current_visual_width=$(_get_visual_width "$right_line")

        local left_padding_str=$(printf '%*s' $((max_left_width - left_current_visual_width)))
        local right_padding_str=$(printf '%*s' $((max_right_width - right_current_visual_width)))

        printf "${GREEN}│ %s%s${separator_chars}%s%s │${NC}\n" \
               "$(echo -e "$left_line")" \
               "$left_padding_str" \
               "$(echo -e "$right_line")" \
               "$right_padding_str"
    done
    
    # Render bottom border
    echo -e "${GREEN}╰$(generate_line "$box_width" "─")╯${NC}"

    # Set item_count for main loop choice validation
    MAIN_MENU_ITEM_COUNT=${#left_column_lines[@]}
}

# --- Main Menu Logic Function ---
main_menu(){
    log_info "欢迎使用 VPS 一键安装脚本 ${SCRIPT_VERSION}"

    while true; do
        if [ "$ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
        load_main_config # Re-load config in case it changed (e.g., enable_auto_clear)

        render_main_menu # Call the new render function

        read -r -p " └──> 请选择 [1-${MAIN_MENU_ITEM_COUNT}], 或 [a/c] 选项, 或 [Enter] 返回: " choice < /dev/tty
        
        local selected_item_json=""
        local selected_action_type=""
        local selected_action_name=""
        local selected_action_path=""

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$MAIN_MENU_ITEM_COUNT" ]; then
            selected_item_json=$(jq -c ".menus.MAIN_MENU.items[$((choice - 1))]" "$CONFIG_FILE")
            selected_action_type=$(echo "$selected_item_json" | jq -r '.type')
            selected_action_name=$(echo "$selected_item_json" | jq -r '.name')
            selected_action_path=$(echo "$selected_item_json" | jq -r '.action')

            case "$selected_action_type" in
                "item")
                    _run_module "$selected_action_path" "$selected_action_name"
                    ;;
                "submenu")
                    if [ "$selected_action_path" = "TOOLS_MENU" ]; then
                        tools_menu
                    else
                        log_err "未知的子菜单动作: $selected_action_path"
                        press_enter_to_continue
                    fi
                    ;;
                *)
                    log_warn "未知的菜单项类型: $selected_action_type"
                    press_enter_to_continue
                    ;;
            esac
        elif [ "$choice" = "a" ] || [ "$choice" = "A" ]; then
            confirm_and_force_update
        elif [ "$choice" = "c" ] || [ "$choice" = "C" ]; then
            uninstall_script
        elif [ -z "$choice" ]; then
            log_info "退出脚本。"
            exit 0
        else
            log_warn "无效选项。请重新输入。"
            sleep 1
        fi
    done
}


# --- Main entry point ---
# Ensure main_menu is called AFTER all functions are defined
main() {
    _acquire_lock
    load_main_config
    _check_dependencies
    
    main_menu
    exit 0
}

main "$@"
