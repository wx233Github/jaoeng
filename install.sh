#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v5.3 - 交互终极版)
# 特性:
# - 持久化缓存 & 快捷指令 (jb)
# - 入口脚本自动更新, 精细退出码处理, 依赖检查
# - 健壮的网络操作 (带超时)
# - 支持多级子菜单，易于扩展
# - 优化交互：主菜单回车退出，子菜单回车返回
# - 修正子脚本环境变量传递，实现完美静默返回
# =============================================================

# --- 严格模式 ---
set -eo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 辅助函数 ---
log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
    exit 1
}

# --- 核心配置 ---
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
INSTALL_DIR="/opt/vps_install_modules"
SCRIPT_PATH="$INSTALL_DIR/install.sh"
BIN_DIR="/usr/local/bin"

# ====================== 菜单定义 ======================
MAIN_MENU=(
    "item:Docker 相关:docker.sh"
    "item:Nginx 相关:nginx.sh"
    "submenu:常用工具:TOOLS_MENU"
    "item:证书申请:cert.sh"
    "func:更新所有模块缓存:update_all_modules_parallel"
)

TOOLS_MENU=(
    "item:Watchtower (Docker 更新):Watchtower.sh"
    "item:BBR/系统网络优化:tcp.sh"
    "item:系统信息查看:sysinfo.sh"
    "back:返回主菜单:main_menu"
)

# ====================== 检查与初始化 ======================
check_dependencies() {
    log_info "正在检查系统依赖..."
    local missing_deps=()
    local deps=("curl" "cmp" "ln")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少必要的命令: ${missing_deps[*]}. 请先安装它们。"
    fi
    log_success "所有依赖项均已满足。"
}

if [ "$(id -u)" -ne 0 ]; then log_error "请使用 root 用户运行此脚本"; fi
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# ====================== 入口脚本自我管理 ======================
save_entry_script() {
    log_info "正在检查并保存入口脚本到 $SCRIPT_PATH..."
    if ! curl -fsSL --connect-timeout 5 --max-time 30 "$BASE_URL/install.sh" -o "$SCRIPT_PATH"; then
        if [[ "$0" == /dev/fd/* || "$0" == "bash" ]]; then
            log_error "无法自动保存入口脚本。请检查网络或直接下载脚本到本地运行。"
        else
           cp "$0" "$SCRIPT_PATH"
        fi
    fi
    chmod +x "$SCRIPT_PATH"
}

setup_shortcut() {
    if [ ! -L "$BIN_DIR/jb" ] || [ "$(readlink "$BIN_DIR/jb")" != "$SCRIPT_PATH" ]; then
        ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"
        log_success "快捷指令 'jb' 已创建。未来可直接输入 'jb' 运行。"
    fi
}

self_update() {
    if [[ "$0" == "/dev/fd/"* || "$0" == "bash" ]]; then return; fi
    log_info "正在检查入口脚本更新..."
    local temp_script="/tmp/install.sh.tmp"
    if curl -fsSL --connect-timeout 5 --max-time 30 "$BASE_URL/install.sh" -o "$temp_script"; then
        if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then
            log_info "检测到新版本，正在自动更新..."
            mv "$temp_script" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
            log_success "脚本已更新！正在重新启动..."
            exec bash "$SCRIPT_PATH" "$@"
        fi
        rm -f "$temp_script"
    else
        log_warning "无法连接 GitHub 检查更新，将使用当前版本。"
        rm -f "$temp_script"
    fi
}

# ====================== 模块管理与执行 ======================
download_module_to_cache() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    local url="$BASE_URL/$script_name"
    if curl -fsSL --connect-timeout 5 --max-time 60 "$url" -o "$local_file"; then
        if [ -s "$local_file" ]; then return 0; else rm -f "$local_file"; return 1; fi
    else
        return 1
    fi
}

precache_modules_background() {
    log_info "正在后台静默预缓存所有模块..."
    (
        for menu_array_name in "MAIN_MENU" "TOOLS_MENU"; do
            declare -n menu_ref="$menu_array_name"
            for entry in "${menu_ref[@]}"; do
                type="${entry%%:*}"
                if [ "$type" == "item" ]; then
                    script_name=$(echo "$entry" | cut -d: -f3); download_module_to_cache "$script_name" &
                fi
            done
        done
        wait
    ) &
}

update_all_modules_parallel() {
    log_info "正在并行更新所有模块缓存..."
    local pids=()
    for menu_array_name in "MAIN_MENU" "TOOLS_MENU"; do
        declare -n menu_ref="$menu_array_name"
        for entry in "${menu_ref[@]}"; do
            type="${entry%%:*}"
            if [ "$type" == "item" ]; then
                script_name=$(echo "$entry" | cut -d: -f3); download_module_to_cache "$script_name" & pids+=($!)
            fi
        done
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    log_success "所有模块缓存更新完成！"
    read -p "$(echo -e "${BLUE}按回车键继续...${NC}")"
}

# 【已修正】执行模块并处理其退出码 (终极版)
execute_module() {
    local script_name="$1"
    local display_name="$2"
    local local_path="$INSTALL_DIR/$script_name"

    log_info "您选择了 [$display_name]"

    if [ ! -f "$local_path" ]; then
        log_info "本地未找到模块 [$script_name]，正在下载..."
        if ! download_module_to_cache "$script_name"; then
            log_error "下载模块 $script_name 失败。请检查网络。"
            read -p "$(echo -e "${YELLOW}按回车键返回...${NC}")"
            return
        fi
    fi
    chmod +x "$local_path"

    # --- 核心修改 ---
    # 1. 通过 "VAR=value command" 的方式传递 IS_NESTED_CALL 环境变量给子进程。
    # 2. 捕获子脚本的退出码。
    local exit_code=0
    ( IS_NESTED_CALL=true bash "$local_path" ) || exit_code=$?

    # 3. 根据退出码进行精细处理。
    if [ "$exit_code" -eq 10 ]; then
        # 退出码为 10 时，子脚本请求静默返回主菜单。
        # 我们在这里不做任何操作，直接结束函数，主循环会自然显示菜单。
        : # ':' 是一个空命令，表示“什么都不做”，让逻辑更清晰。
    elif [ "$exit_code" -eq 0 ]; then
        # 退出码为 0 时，表示子脚本成功完成了一个实际操作。
        log_success "模块 [$display_name] 执行完毕。"
        read -p "$(echo -e "${BLUE}按回车键返回主菜单...${NC}")"
    else
        # 其他非零退出码表示执行出错。
        log_warning "模块 [$display_name] 执行时发生错误 (退出码: $exit_code)。"
        read -p "$(echo -e "${YELLOW}按回车键返回主菜单...${NC}")"
    fi
}

# ====================== 【核心】通用菜单显示函数 ======================
display_menu() {
    local menu_name=$1
    declare -n menu_items=$menu_name

    local header_text="🚀 VPS 一键安装入口 (v5.3)"
    if [ "$menu_name" != "MAIN_MENU" ]; then header_text="🛠️ ${menu_name//_/ }"; fi

    echo ""; echo -e "${BLUE}==========================================${NC}"; echo -e "  ${header_text}"; echo -e "${BLUE}==========================================${NC}"

    local i=1
    for item in "${menu_items[@]}"; do
        local display_text=$(echo "$item" | cut -d: -f2); echo -e " ${YELLOW}$i.${NC} $display_text"; ((i++))
    done
    echo ""

    if [ "$menu_name" == "MAIN_MENU" ]; then
        read -p "$(echo -e "${BLUE}请选择操作 (1-${#menu_items[@]}) 或按 Enter 退出:${NC} ")" choice
    else
        read -p "$(echo -e "${BLUE}请选择操作 (1-${#menu_items[@]}) 或按 Enter 返回:${NC} ")" choice
    fi

    if [ -z "$choice" ]; then
        if [ "$menu_name" == "MAIN_MENU" ]; then
            log_info "已退出脚本。"
            exit 0
        else
            return 1
        fi
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#menu_items[@]}" ]; then
        log_warning "无效选项，请重新输入。"; sleep 1; return 0
    fi

    local selected_item="${menu_items[$((choice-1))]}"
    local type=$(echo "$selected_item" | cut -d: -f1)
    local name=$(echo "$selected_item" | cut -d: -f2)
    local action=$(echo "$selected_item" | cut -d: -f3)

    case "$type" in
        item) execute_module "$action" "$name" ;;
        submenu) display_menu "$action" ;;
        func) "$action" ;;
        back) return 1 ;;
        exit) log_info "退出脚本。"; exit 0 ;;
    esac
    return 0
}

# ====================== 主程序入口 ======================
main() {
    check_dependencies
    if [ ! -f "$SCRIPT_PATH" ]; then save_entry_script; fi
    setup_shortcut
    self_update
    precache_modules_background

    while true; do display_menu "MAIN_MENU"; done
}

main "$@"
