# =============================================================
# 🚀 vps-install-modules (v1.3.1-菜单逻辑修复)
# - 修复: 修正了 `tools_menu` 中，当没有特殊操作按键时，依然会显示
#         多余文字 "或 [] 操 作 ," 的界面瑕疵。
# - 优化: 菜单提示信息现在会根据是否存在特殊操作按键来动态生成，
#         使界面更整洁、逻辑更严谨。
# =============================================================

# --- Script Metadata ---
SCRIPT_VERSION="v1.3.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"
TOOLS_DIR="${SCRIPT_DIR}/tools"
UTILS_PATH="${SCRIPT_DIR}/utils.sh"

# --- Strict Mode & Environment Setup ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}
export SCRIPT_DIR MODULES_DIR TOOLS_DIR
# Load utility functions
if [ ! -f "$UTILS_PATH" ]; then
    echo "[FATAL] Utility script '$UTILS_PATH' not found. Exiting." >&2
    exit 1
fi
# shellcheck source=utils.sh
source "$UTILS_PATH"

# --- Global State ---
declare -A JB_ENV_VARS
load_env_vars

# --- Core Functions ---

run_module() {
    local script_name="$1"
    local script_path="${MODULES_DIR}/${script_name}.sh"
    if [ -f "$script_path" ]; then
        log_info "🚀 Executing module: ${script_name}"
        # Execute with bash in a subshell to isolate environment
        (bash "$script_path")
        local exit_code=$?
        if [ $exit_code -ne 10 ]; then # 10 is the exit code for returning to the menu
            handle_exit_code "$exit_code" "${script_name}"
        fi
    else
        log_err "Module script not found: ${script_path}"
    fi
}

run_tool() {
    local script_name="$1"
    local script_path="${TOOLS_DIR}/${script_name}.sh"
    if [ -f "$script_path" ]; then
        log_info "🚀 Executing tool: ${script_name}"
        (bash "$script_path")
        local exit_code=$?
        if [ $exit_code -ne 10 ]; then
            handle_exit_code "$exit_code" "${script_name}"
        fi
    else
        log_err "Tool script not found: ${script_path}"
    fi
}

self_update() {
    _print_header "🔄 脚本更新"
    if [ ! -d ".git" ]; then
        log_err "This script is not a git repository. Cannot update."
        return
    fi
    log_info "Fetching latest version from git..."
    if git pull; then
        log_success "Update successful. Please restart the script."
        exit 0
    else
        log_err "Update failed. Please check for errors."
    fi
}

cleanup() {
    _print_header "🧹 清理缓存与日志"
    local temp_files
    temp_files=$(find /tmp -maxdepth 1 -type f -user "$(id -un)" -name "vps_install_*.log" 2>/dev/null)
    
    if [ -n "$temp_files" ]; then
        log_info "Found temporary log files:"
        echo "$temp_files"
        if confirm_action "Delete these temporary log files?"; then
            rm -f /tmp/vps_install_*.log
            log_success "Temporary logs cleaned up."
        else
            log_info "Cleanup cancelled."
        fi
    else
        log_info "No temporary log files found to clean up."
    fi
}

# --- Menus ---

main_menu() {
    while true; do
        auto_clear_screen
        local -a menu_items=(
            "基础环境 (Docker, Nginx)"
            "常用工具"
            "流媒体"
            "下载工具"
            "监控与告警"
            "网络工具"
            "其他"
        )
        local -a special_keys=("u" "c" "q")
        local special_keys_display; IFS=','; special_keys_display="${special_keys[*]}"; unset IFS

        _render_menu "🚀 VPS 一键安装与管理脚本 🚀" "${menu_items[@]}"
        
        read -r -p " └──> 请选择 [1-${#menu_items[@]}], 或 [${special_keys_display}] 操作, [Enter] 返回 : " choice
        
        case "$choice" in
            1) run_module "base_env" ;;
            2) tools_menu ;;
            3) run_module "streaming" ;;
            4) run_module "downloaders" ;;
            5) run_module "monitoring" ;;
            6) run_module "network" ;;
            7) run_module "others" ;;
            u|U) self_update; press_enter_to_continue ;;
            c|C) cleanup; press_enter_to_continue ;;
            q|Q) log_info "👋 Exiting. Goodbye!"; exit 0 ;;
            "") log_info "👋 Exiting. Goodbye!"; exit 0 ;;
            *) handle_invalid_option ;;
        esac
    done
}

tools_menu() {
    while true; do
        auto_clear_screen
        local -a menu_items=(
            "Watchtower (Docker 更新)"
        )
        local -a special_keys=() # No special keys for this menu yet
        
        _render_menu "🛠️ 常用工具" "${menu_items[@]}"
        
        # --- FIX: Conditionally build the prompt ---
        local special_keys_prompt=""
        if [ ${#special_keys[@]} -gt 0 ]; then
            local special_keys_display; IFS=','; special_keys_display="${special_keys[*]}"; unset IFS
            special_keys_prompt=" 或 [${special_keys_display}] 操作 ,"
        fi
        
        read -r -p " └──> 请选择 [1-${#menu_items[@]}],${special_keys_prompt} [Enter] 返回 : " choice
        
        case "$choice" in
            1) run_tool "Watchtower" ;;
            "") return ;;
            *) handle_invalid_option ;;
        esac
    done
}

# --- Main Execution ---
main() {
    trap 'echo -e "\nInterrupt signal received. Exiting gracefully."; exit 130' INT
    check_sudo_password_or_exit
    main_menu
}

main "$@"
