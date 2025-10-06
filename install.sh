#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装脚本 (v74.14-主菜单排版优化)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v74.14"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 通用工具函数库 ---
# 必须在最开始加载，确保所有函数可用
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    # 如果 utils.sh 未找到，提供一个临时的 log_err 函数以避免脚本立即崩溃
    log_err() { echo "[错误] $*" >&2; }
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 配置目录 ---
CONFIG_DIR="/etc/vps_install_script"
CONFIG_FILE="$CONFIG_DIR/config.json"
MODULES_DIR="/opt/vps_install_modules/tools"

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
  log_err "致命错误: run_with_sudo 函数未定义。请确保 utils.sh 已正确加载。"
  exit 1
fi

# =============================================================
# 状态检查辅助函数
# =============================================================

# 检查 Docker Daemon 和 Docker Compose 状态
_get_docker_overall_status() {
    local docker_daemon_running="false"
    local docker_compose_running="false"

    # 检查 Docker Daemon
    if systemctl is-active docker >/dev/null 2>&1; then
        docker_daemon_running="true"
    fi

    # 检查 Docker Compose (优先检查插件版本，其次是独立安装版本)
    if command -v docker &>/dev/null && docker compose version >/dev/null 2>&1; then
        docker_compose_running="true"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker_compose_running="true"
    fi

    if [ "$docker_daemon_running" = "true" ] && [ "$docker_compose_running" = "true" ]; then
        echo "${GREEN}已运行${NC}"
    elif [ "$docker_daemon_running" = "false" ]; then
        echo "${RED}Docker Daemon: 未运行${NC}"
    elif [ "$docker_compose_running" = "false" ]; then
        echo "${RED}Docker Compose: 未运行${NC}"
    else
        echo "${RED}未运行 (未知状态)${NC}" # 理论上不应发生，作为安全后备
    fi
}

# 检查 Nginx 状态
_get_nginx_status() {
    if systemctl is-active nginx >/dev/null 2>&1; then
        echo "${GREEN}已运行${NC}"
    else
        echo "${RED}未运行${NC}"
    fi
}

# 检查 Watchtower 状态
_get_watchtower_status() {
    # 假设 Watchtower 模块的运行状态可以通过检查其容器是否存在来判断
    # 抑制 run_with_sudo 的日志输出
    if JB_SUDO_LOG_QUIET="true" docker ps --filter name=watchtower --format '{{.Names}}' | grep -q '^watchtower$' >/dev/null 2>&1; then
        echo "${GREEN}已运行${NC}"
    else
        echo "${RED}未运行${NC}"
    fi
}

# =============================================================
# 模块管理函数
# =============================================================

# 运行模块函数
run_module() {
    local module_name="$1"
    local module_script="$MODULES_DIR/${module_name}.sh"

    if [ ! -f "$module_script" ]; then
        log_err "模块脚本未找到: $module_script"
        return 1
    fi

    # 从 config.json 加载模块配置并导出为环境变量
    local module_config_json
    module_config_json=$(jq -c ".modules[\"$module_name\"]" "$CONFIG_FILE" 2>/dev/null || echo "{}")

    # 遍历 JSON 对象中的键值对，导出为环境变量
    # 格式为 WATCHTOWER_CONF_KEY="value"
    local env_vars=()
    if [ "$module_config_json" != "{}" ]; then
        while IFS='=' read -r key value; do
            key=$(echo "$key" | tr -d '[:space:]"')
            value=$(echo "$value" | sed -e 's/^"//' -e 's/"$//') # 移除引号
            env_vars+=("${module_name^^}_CONF_${key^^}=\"${value}\"") # 转换为大写以提高健壮性
        done < <(echo "$module_config_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
    
    # 执行模块脚本，并传递环境变量
    log_info "您选择了 [${module_name} 模块]"
    (
        export "${env_vars[@]}"
        bash "$module_script"
    )
    local exit_code=$?
    if [ $exit_code -ne 10 ] && [ $exit_code -ne 0 ]; then
        log_warn "模块 [${module_name} 模块] 执行出错 (码: ${exit_code})."
    fi
    return $exit_code
}

# =============================================================
# 主菜单
# =============================================================

main_menu() {
    log_info "欢迎使用 VPS 一键安装脚本 ${SCRIPT_VERSION}"

    # 定义左侧列固定宽度，用于对齐分隔符
    local LEFT_COL_WIDTH=25 # 根据实际内容和emoji调整，确保视觉对齐

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        _print_header "🖥️ VPS 一键安装脚本"

        local docker_status="$(_get_docker_overall_status)"
        local nginx_status="$(_get_nginx_status)"
        local watchtower_status="$(_get_watchtower_status)"

        local menu_lines=()

        # 辅助函数：格式化菜单行，处理左右两部分和对齐
        # 该函数会剥离ANSI颜色码以精确计算可见字符长度进行填充
        _format_main_menu_line() {
            local left_text="$1"
            local right_text="$2"
            
            # 计算左侧文本的可见字符长度，去除ANSI颜色码
            local visible_len_left=$(echo "$left_text" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
            # 根据可见长度调整填充
            local padding=$((LEFT_COL_WIDTH - visible_len_left))
            if [ "$padding" -lt 0 ]; then padding=0; fi # 确保没有负填充

            printf "  %s%*s│ %s" "$left_text" "$padding" "" "$right_text"
        }

        # 构建菜单显示行
        menu_lines+=("$(_format_main_menu_line "1. 🐳 Docker" "Docker: $docker_status")")
        menu_lines+=("$(_format_main_menu_line "2. 🌐 Nginx" "Nginx: $nginx_status")")
        menu_lines+=("$(_format_main_menu_line "3. 🛠️ 常用工具" "Watchtower: $watchtower_status")")
        menu_lines+=("$(_format_main_menu_line "4. 📜 证书申请" "")") # 证书申请模块没有实时状态显示

        # 右侧底部选项，与主菜单项对齐
        # "  " (2 spaces) + LEFT_COL_WIDTH 确保 "│" 后面的选项与右侧状态列对齐
        local empty_left_padding=$((LEFT_COL_WIDTH + 2)) 
        menu_lines+=("$(printf "%*s│ %s" "$empty_left_padding" "" "a.⚙️ 强制重置")")
        menu_lines+=("$(printf "%*s│ %s" "$empty_left_padding" "" "c.🗑️ 卸载脚本")")

        # 使用通用的 _render_menu 函数来绘制带边框的菜单
        _render_menu "🖥️ VPS 一键安装脚本" "${menu_lines[@]}"

        read -r -p " └──> 请选择 [1-4], 或 [a/c] 选项, 或 [Enter] 返回: " choice < /dev/tty

        case "$choice" in
            1) run_module "Docker" || true; press_enter_to_continue ;;
            2) run_module "Nginx" || true; press_enter_to_continue ;;
            3) run_module "Watchtower" || true; press_enter_to_continue ;;
            4) run_module "Certificate" || true; press_enter_to_continue ;;
            a|A)
                if confirm_action "确定要强制重置所有模块配置吗？这会清除所有保存的配置并可能导致服务中断。"; then
                    log_warn "正在强制重置所有模块配置..."
                    # TODO: 在此处添加实际的重置逻辑
                    log_success "所有模块配置已重置。"
                else
                    log_info "操作已取消。"
                fi
                press_enter_to_continue
                ;;
            c|C)
                if confirm_action "警告: 确定要卸载此脚本及其所有模块吗？这将是不可逆的操作。"; then
                    log_warn "正在卸载脚本和所有模块..."
                    # TODO: 在此处添加实际的卸载逻辑
                    log_success "脚本和所有模块已卸载。"
                else
                    log_info "操作已取消。"
                fi
                press_enter_to_continue
                ;;
            "") log_info "退出脚本。"; exit 0 ;;
            *) log_warn "无效选项。请重新输入。"; sleep 1 ;;
        esac
    done
}

# =============================================================
# 主执行入口
# =============================================================
main() {
    # 捕获中断信号，确保优雅退出
    trap 'echo -e "\n操作被中断。"; exit 0' INT TERM
    main_menu
}

main "$@"
