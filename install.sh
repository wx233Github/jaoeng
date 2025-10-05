#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装脚本 (v4.6.15)
#
# 功能:
# - 自动从 Git 仓库拉取或更新模块化脚本。
# - 解析 config.json 配置文件，动态生成主菜单。
# - 为模块脚本设置环境变量，传递配置参数。
# - 提供统一的入口和交互界面。
#
# 使用:
# 1. 将此脚本放置在服务器任意位置。
# 2. 创建一个 config.json 文件，定义 Git 仓库和模块。
# 3. 运行 ./install.sh 启动菜单。
# =============================================================

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.15"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 全局变量 ---
# 脚本安装目录 (相对于 install.sh 的位置)
# 默认为 /opt/vps_install_modules，如果用户没有 /opt 权限，则回退到 $HOME/vps_install_modules
BASE_DIR="/opt/vps_install_modules"
if ! [ -w "$(dirname "$BASE_DIR")" ] && ! [ -d "$BASE_DIR" ]; then
    BASE_DIR="$HOME/vps_install_modules"
fi

# 配置文件路径 (相对于 install.sh 的位置)
CONFIG_FILE_PATH="$(dirname "$0")/config.json"
# Git 仓库地址 (将从 config.json 读取)
GIT_REPO=""
# Git 仓库分支 (将从 config.json 读取)
GIT_BRANCH=""
# 通用工具函数库路径
UTILS_PATH="${BASE_DIR}/utils.sh"

# --- 日志函数 ---
# 为了在加载 utils.sh 之前也能使用，这里预定义
log_info() { echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S') [信息] $*${NC}"; }
log_success() { echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [成功] $*${NC}"; }
log_warn() { echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [警告] $*${NC}" >&2; }
log_err() { echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [错误] $*${NC}" >&2; }

# --- 核心功能函数 ---

# 检查依赖项
check_dependencies() {
    local missing_deps=()
    command -v jq &>/dev/null || missing_deps+=("jq")
    command -v git &>/dev/null || missing_deps+=("git")
    command -v docker &>/dev/null || missing_deps+=("docker")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_err "缺少必要的依赖: ${missing_deps[*]}"
        log_info "请使用您的包管理器安装它们。例如:"
        log_info "  - Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}"
        log_info "  - CentOS/RHEL:   sudo yum install -y epel-release && sudo yum install -y ${missing_deps[*]}"
        exit 1
    fi
}

# 更新脚本仓库
update_script_repo() {
    if [ -z "$GIT_REPO" ]; then
        log_err "Git 仓库地址未在 config.json 中配置！"
        exit 1
    fi
    
    # 确保基础目录存在
    mkdir -p "$BASE_DIR" || { log_err "无法创建目录: $BASE_DIR"; exit 1; }

    if [ -d "$BASE_DIR/.git" ]; then
        log_info "检测到本地仓库，尝试更新..."
        cd "$BASE_DIR"
        # 尝试stash本地更改，以避免更新冲突
        git stash &>/dev/null
        if git pull origin "${GIT_BRANCH:-main}"; then
            log_success "脚本仓库已更新至最新版本。"
        else
            log_err "更新失败！请检查网络连接或手动解决 Git 冲突。"
            exit 1
        fi
        git stash pop &>/dev/null || true # 尝试恢复之前的更改
        cd - >/dev/null
    else
        log_info "本地仓库未找到，正在从 $GIT_REPO 克隆..."
        if git clone --branch "${GIT_BRANCH:-main}" "$GIT_REPO" "$BASE_DIR"; then
            log_success "脚本仓库克隆成功。"
        else
            log_err "克隆失败！请检查仓库地址和网络连接。"
            exit 1
        fi
    fi
    
    # 加载通用工具函数库
    if [ -f "$UTILS_PATH" ]; then
        source "$UTILS_PATH"
    else
        log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
        exit 1
    fi
}

# 从 config.json 加载和导出配置
load_and_export_config() {
    if ! [ -f "$CONFIG_FILE_PATH" ]; then
        log_err "配置文件 config.json 未在脚本同级目录下找到！"
        exit 1
    fi

    # 读取 Git 配置
    GIT_REPO=$(jq -r '.git_repo // ""' "$CONFIG_FILE_PATH")
    GIT_BRANCH=$(jq -r '.git_branch // ""' "$CONFIG_FILE_PATH")

    # 读取并导出全局配置
    # 使用 jq 遍历 .global_settings 对象的所有键
    local global_keys=$(jq -r '.global_settings | keys[]' "$CONFIG_FILE_PATH")
    for key in $global_keys; do
        local value=$(jq -r ".global_settings[\"$key\"]" "$CONFIG_FILE_PATH")
        # 转换为大写并添加 JB_ 前缀作为环境变量名
        local env_var_name="JB_$(echo "$key" | tr '[:lower:]' '[:upper:]')"
        export "$env_var_name"="$value"
        # log_info "导出全局配置: $env_var_name=$value"
    done

    # 读取并导出模块配置
    # 使用 jq 遍历 .modules 数组
    local num_modules=$(jq '.modules | length' "$CONFIG_FILE_PATH")
    for i in $(seq 0 $((num_modules - 1))); do
        local module_enabled=$(jq -r ".modules[$i].enabled" "$CONFIG_FILE_PATH")
        if [ "$module_enabled" != "true" ]; then
            continue
        fi

        local module_name=$(jq -r ".modules[$i].name" "$CONFIG_FILE_PATH")
        local module_prefix="JB_$(echo "$module_name" | tr '[:lower:]' '[:upper:]')"

        # 遍历模块配置对象的所有键
        local module_keys=$(jq -r ".modules[$i] | keys[]" "$CONFIG_FILE_PATH")
        for key in $module_keys; do
            # 跳过 'name', 'description', 'script', 'enabled' 这类元数据键
            if [[ "$key" == "name" || "$key" == "description" || "$key" == "script" || "$key" == "enabled" ]]; then
                continue
            fi
            
            # 使用 jq -c 确保 JSON 对象/数组被作为紧凑的单行字符串读取
            local value=$(jq -c ".modules[$i][\"$key\"]" "$CONFIG_FILE_PATH")
            # 移除值的外部双引号（如果存在）
            value="${value#\"}"
            value="${value%\"}"

            local env_var_name="${module_prefix}_$(echo "$key" | tr '[:lower:]' '[:upper:]')"
            export "$env_var_name"="$value"
            # log_info "导出模块配置: $env_var_name=$value"
        done
    done
}

# 显示主菜单
main_menu() {
    while true; do
        # 每次循环都检查是否需要自动清屏
        if [ "${JB_ENABLE_AUTO_CLEAR:-true}" = "true" ]; then
            clear
        fi

        local menu_title="🚀 VPS 模块化工具箱 ${SCRIPT_VERSION} 🚀"
        local -a menu_items=()
        local -a script_paths=()

        # 从 config.json 动态构建菜单项
        local num_modules=$(jq '.modules | length' "$CONFIG_FILE_PATH")
        local item_index=1
        for i in $(seq 0 $((num_modules - 1))); do
            local module_enabled=$(jq -r ".modules[$i].enabled" "$CONFIG_FILE_PATH")
            if [ "$module_enabled" != "true" ]; then
                continue
            fi

            local name=$(jq -r ".modules[$i].name" "$CONFIG_FILE_PATH")
            local description=$(jq -r ".modules[$i].description" "$CONFIG_FILE_PATH")
            local script=$(jq -r ".modules[$i].script" "$CONFIG_FILE_PATH")
            
            menu_items+=("  ${item_index}. › ${name} - ${description}")
            script_paths+=("${BASE_DIR}/${script}")
            item_index=$((item_index + 1))
        done

        menu_items+=("") # 添加空行作为分隔
        menu_items+=("  u. › 更新脚本库")
        menu_items+=("  q. › 退出")

        _render_menu "$menu_title" "${menu_items[@]}"
        read -r -p " └──> 请输入选项: " choice

        case "$choice" in
            [1-9]|[1-9][0-9])
                if [ "$choice" -ge 1 ] && [ "$choice" -le ${#script_paths[@]} ]; then
                    local selected_script="${script_paths[$((choice - 1))]}"
                    if [ -f "$selected_script" ] && [ -x "$selected_script" ]; then
                        # 执行模块脚本
                        "$selected_script"
                        # 模块脚本退出后，提示用户按回车返回主菜单
                        press_enter_to_continue
                    elif [ -f "$selected_script" ]; then
                        log_warn "脚本 '$selected_script' 没有执行权限，正在尝试添加..."
                        chmod +x "$selected_script"
                        log_info "权限已添加，请重试。"
                        sleep 2
                    else
                        log_err "脚本 '$selected_script' 未找到！"
                        sleep 2
                    fi
                else
                    log_warn "无效选项。"
                    sleep 1
                fi
                ;;
            u|U)
                update_script_repo
                press_enter_to_continue
                ;;
            q|Q)
                echo "感谢使用，再见！"
                exit 0
                ;;
            *)
                log_warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

# --- 主程序入口 ---
main() {
    # 捕获中断信号 (Ctrl+C)
    trap 'echo -e "\n操作被中断。"; exit 130' INT

    # 检查依赖
    check_dependencies

    # 加载并导出配置
    load_and_export_config

    # 更新脚本仓库
    update_script_repo

    # 显示主菜单
    main_menu
}

# 执行主程序
main "$@"
