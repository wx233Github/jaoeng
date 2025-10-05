#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装脚本 (v4.6.12-Legacy - 未使用UI主题/统一配置前版本)
# - [旧版] 菜单项硬编码在脚本内部，不从 config.json 加载。
# - [旧版] 不包含 UI 主题设置功能。
# - [旧版] 配置管理方式与 v4.6.15-UnifiedConfig 版本不同。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.12-Legacy"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 基础路径和文件 ---
INSTALL_DIR="/opt/vps_install_modules"
BIN_DIR="/usr/local/bin"
CONFIG_FILE="/etc/docker-auto-update.conf" # 旧版配置路径，可能与模块冲突
LOCK_FILE="/tmp/vps_install_modules.lock"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
base_url="$DEFAULT_BASE_URL" # 旧版，通常直接使用这个URL

# --- 临时日志函数 (在 utils.sh 加载前使用) ---
_temp_log_err() { echo -e "\033[0;31m[错误]\033[0m $*" >&2; }
_temp_log_info() { echo -e "\033[0;34m[信息]\033[0m $*"; }
_temp_log_success() { echo -e "\033[0;32m[成功]\033[0m $*"; }
_temp_log_warn() { echo -e "\033[0;33m[警告]\033[0m $*" >&2; }

# --- 确保 jq 已安装 (旧版可能不强制要求，但为了兼容性保留) ---
ensure_jq_installed() {
    if ! command -v jq &>/dev/null; then
        _temp_log_err "jq 命令未找到。部分功能可能受限。请手动安装 jq。"
        # 旧版通常不会自动安装，这里为了减少中断，只警告
    fi
}
ensure_jq_installed

# --- 创建安装目录 (在下载任何文件前) ---
if [ ! -d "$INSTALL_DIR" ]; then
    _temp_log_info "创建安装目录: $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo chmod 755 "$INSTALL_DIR"
fi

# --- 下载 utils.sh (旧版通常直接下载，不依赖 config.json) ---
_temp_log_info "正在下载或更新通用工具库 utils.sh..."
if sudo curl -fsSL "${base_url}/utils.sh?_=$(date +%s)" -o "$INSTALL_DIR/utils.sh"; then
    sudo chmod +x "$INSTALL_DIR/utils.sh"
    _temp_log_success "utils.sh 下载成功。"
else
    _temp_log_err "致命错误: utils.sh 下载失败！请检查网络。"
    exit 1
fi

# --- 导入通用工具函数库 ---
source "$INSTALL_DIR/utils.sh"

# --- 确保只运行一个实例 ---
if ! flock -xn "$LOCK_FILE" -c "true"; then
    log_warn "脚本已在运行中，请勿重复启动。"
    exit 1
fi

# --- 菜单数据 (旧版硬编码) ---
MAIN_MENU_TITLE="🖥️ VPS 一 键 安 装 脚 本"
declare -A MAIN_MENU_ITEMS
MAIN_MENU_ITEMS[0]="item|Docker|🐳|docker.sh"
MAIN_MENU_ITEMS[1]="item|Nginx|🌐|nginx.sh"
MAIN_MENU_ITEMS[2]="submenu|常 用 工 具 |🛠️|TOOLS_MENU"
MAIN_MENU_ITEMS[3]="item|证 书 申 请 |📜|cert.sh"
MAIN_MENU_ITEMS[4]="func|强 制 重 置  (更 新 脚 本 )|⚙️|confirm_and_force_update"
MAIN_MENU_ITEMS[5]="func|卸 载 脚 本  (Uninstall)|🗑️|uninstall_script"

declare -A SUBMENUS
SUBMENUS["TOOLS_MENU_title"]="🛠️ 常 用 工 具"
SUBMENUS["TOOLS_MENU_item_0"]="item|Watchtower (Docker 更 新 )|🔄|tools/Watchtower.sh"
SUBMENUS["TOOLS_MENU_count"]="1"


# --- 依赖检查 (旧版可能简单，这里保留一个通用框架) ---
check_dependencies() {
    log_info "正在检查依赖项 (docker, curl, git, cron)..."
    local missing_deps=""
    for dep in docker curl git cron; do # 示例依赖
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=" $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        log_err "检测到缺失依赖：${missing_deps}。请手动安装。"
        log_warn "尝试自动安装依赖..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y $missing_deps
        elif command -v yum &>/dev/null; then
            sudo yum install -y $missing_deps
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y $missing_deps
        else
            log_err "无法自动安装依赖。请手动安装：${missing_deps}"
            # exit 1 # 旧版可能不强制退出
        fi
    fi
    log_success "依赖项检查完成。"
}

# --- 模块管理函数 ---
download_script() {
    local script_name="$1"
    local target_path="$INSTALL_DIR/$script_name"
    local script_url="${base_url}/$script_name"

    mkdir -p "$(dirname "$target_path")"

    log_info "正在下载 $script_name 到 $target_path..."
    if curl -sS -o "$target_path" "$script_url"; then
        chmod +x "$target_path"
        log_success "下载并设置执行权限完成: $script_name"
        return 0
    else
        log_err "下载失败: $script_name (URL: $script_url)"
        return 1
    fi
}

install_or_update_modules() {
    log_info "检查并安装/更新所有模块..."
    local script_files=("docker.sh" "nginx.sh" "cert.sh" "tools/Watchtower.sh") # 硬编码所有模块脚本
    for script in "${script_files[@]}"; do
        download_script "$script" || log_err "模块 $script 安装/更新失败。"
    done
    log_success "所有模块安装/更新操作完成。"
    press_enter_to_continue
}

uninstall_module() {
    log_warn "此功能尚未完全实现，目前仅为示例。"
    log_info "要卸载模块，您可能需要手动删除其文件和相关服务。"
    press_enter_to_continue
}

enter_module() {
    local -a module_list=()
    local -a module_paths=()
    local i=1

    # 遍历主菜单和子菜单中的所有 type="item"
    local all_menu_items=()
    for item_idx in "${!MAIN_MENU_ITEMS[@]}"; do
        all_menu_items+=("${MAIN_MENU_ITEMS[$item_idx]}")
    done

    # 旧版这里可能没有动态的子菜单键获取，直接遍历硬编码的 TOOLS_MENU
    local submenu_key="TOOLS_MENU"
    local count="${SUBMENUS["${submenu_key}_count"]:-0}"
    for (( j=0; j<count; j++ )); do
        all_menu_items+=("${SUBMENUS["${submenu_key}_item_$j"]}")
    done


    while true; do
        clear # 旧版通常直接清屏
        local -a display_items=()
        for item_str in "${all_menu_items[@]}"; do
            local type=$(echo "$item_str" | cut -d'|' -f1)
            local name=$(echo "$item_str" | cut -d'|' -f2)
            local icon=$(echo "$item_str" | cut -d'|' -f3)
            local action=$(echo "$item_str" | cut -d'|' -f4)

            if [ "$type" = "item" ] && [[ "$action" == *.sh ]]; then
                local full_path="$INSTALL_DIR/$action"
                if [ -f "$full_path" ]; then
                    module_list+=("$name")
                    module_paths+=("$full_path")
                fi
            fi
        done
        
        if [ ${#module_list[@]} -eq 0 ]; then
            _render_menu_old "🚀 进 入 模 块 菜 单 🚀" "  无可用模块。请先安装模块。"
            read -r -p " └──> 按 Enter 返回: "
            return
        fi

        local -a numbered_display_items=()
        for idx in "${!module_list[@]}"; do
            numbered_display_items+=("  $((idx + 1)). ${module_list[$idx]}")
        done

        _render_menu_old "🚀 进 入 模 块 菜 单 🚀" "${numbered_display_items[@]}"
        read -r -p " └──> 请选择模块编号, 或按 Enter 返回: " choice

        if [ -z "$choice" ]; then return; fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#module_paths[@]}" ]; then
            local selected_path="${module_paths[$((choice - 1))]}"
            log_info "正在进入模块: $(basename "$selected_path")..."
            "$selected_path" || true
            press_enter_to_continue
        else
            log_warn "无效选项。"
            sleep 1
        fi
    done
}

# 旧版简易渲染函数 (通常在 utils.sh 中，但为了独立性，这里也提供一个简易版)
_render_menu_old() {
    local menu_title="$1"
    shift
    local -a items=("$@")
    local total_width=$(tput cols || echo 80)
    local title_len=$(_calc_display_width_old "$menu_title")
    local padding=$(( (total_width - title_len - 2) / 2 ))

    printf "╭%s╮\n" "$(printf '─%.0s' $(seq 1 $((total_width - 2))))"
    printf "│%*s%s%*s│\n" "$padding" "" "$menu_title" "$((total_width - title_len - 2 - padding))" ""
    printf "├%s┤\n" "$(printf '─%.0s' $(seq 1 $((total_width - 2))))"
    
    for item in "${items[@]}"; do
        local item_len=$(_calc_display_width_old "$item")
        printf "│ %s%*s│\n" "$item" "$((total_width - item_len - 3))" ""
    done
    printf "╰%s╯\n" "$(printf '─%.0s' $(seq 1 $((total_width - 2))))"
}

_calc_display_width_old() {
    local text="$1"
    local clean_text=$(echo -e "$text" | sed -E 's/\x1b\[[0-9;]*m//g')
    local len=$(echo -n "$clean_text" | wc -c)
    echo "$len"
}


confirm_and_force_update() {
    if confirm_action "警告: 强制重置将重新下载所有脚本。确定继续吗?"; then
        log_info "正在强制重置..."
        rm -rf "$INSTALL_DIR" || log_warn "删除旧脚本目录失败，可能不存在或权限不足。"
        # 旧版可能不会删除 config.conf，或者 config.conf 路径不同
        rm -f "$CONFIG_FILE" || log_warn "删除用户配置文件失败，可能不存在或权限不足。"

        log_info "正在重新下载 install.sh..."
        local install_script_url="${DEFAULT_BASE_URL}/install.sh"
        if curl -fsSL -o "/tmp/install.sh" "$install_script_url"; then
            chmod +x "/tmp/install.sh"
            log_success "install.sh 下载成功。正在重新执行安装..."
            exec "/tmp/install.sh"
        else
            log_err "install.sh 下载失败。请手动检查网络或基础URL。"
            exit 1
        fi
    else
        log_info "操作已取消。"
    fi
    press_enter_to_continue
}


uninstall_script() {
    if confirm_action "警告: 这将删除所有脚本、配置文件和快捷命令。确定卸载吗?"; then
        log_info "正在卸载脚本..."
        rm -rf "$INSTALL_DIR"
        rm -f "$BIN_DIR/vps"
        rm -f "$CONFIG_FILE"
        log_success "脚本已成功卸载。"
        exit 0
    else
        log_info "操作已取消。"
    fi
    press_enter_to_continue
}


# --- 主菜单 ---
main_menu() {
    while true; do
        clear # 旧版通常直接清屏
        local -a display_items=()
        local current_item_idx=0

        for item_str in "${MAIN_MENU_ITEMS[@]}"; do
            local type=$(echo "$item_str" | cut -d'|' -f1)
            local name=$(echo "$item_str" | cut -d'|' -f2)
            local icon=$(echo "$item_str" | cut -d'|' -f3)
            local display_name="${icon} ${name}"
            display_items+=("  $((current_item_idx + 1)). ${display_name}")
            current_item_idx=$((current_item_idx + 1))
        done
        
        _render_menu_old "$MAIN_MENU_TITLE" "${display_items[@]}"
        read -r -p " └──> 请选择, 或按 Enter 退出: " choice

        if [ -z "$choice" ]; then exit 0; fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$current_item_idx" ]; then
            log_warn "无效选项。"
            sleep 1
            continue
        fi

        local selected_item_str="${MAIN_MENU_ITEMS[$((choice - 1))]}"
        local type=$(echo "$selected_item_str" | cut -d'|' -f1)
        local action=$(echo "$selected_item_str" | cut -d'|' -f4)

        case "$type" in
            item)
                local script_path="$INSTALL_DIR/$action"
                if [ -f "$script_path" ]; then
                    log_info "正在启动模块: $(basename "$script_path")..."
                    "$script_path" || true
                    press_enter_to_continue
                else
                    log_err "模块脚本 '$action' 未找到或不可执行。请尝试 '安装/更新模块'。"
                    press_enter_to_continue
                fi
                ;;
            submenu)
                local submenu_key="$action"
                handle_submenu "$submenu_key"
                ;;
            func)
                if declare -f "$action" &>/dev/null; then
                    "$action"
                else
                    log_err "函数 '$action' 未定义。"
                    press_enter_to_continue
                fi
                ;;
            *)
                log_warn "不支持的菜单项类型: $type"
                press_enter_to_continue
                ;;
        esac
    done
}

# --- 子菜单处理函数 ---
handle_submenu() {
    local submenu_key="$1"
    local submenu_title="${SUBMENUS["${submenu_key}_title"]}"
    local item_count="${SUBMENUS["${submenu_key}_count"]}"

    while true; do
        clear # 旧版通常直接清屏
        local -a display_items=()
        for (( i=0; i<item_count; i++ )); do
            local item_str="${SUBMENUS["${submenu_key}_item_$i"]}"
            local name=$(echo "$item_str" | cut -d'|' -f2)
            local icon=$(echo "$item_str" | cut -d'|' -f3)
            local display_name="${icon} ${name}"
            display_items+=("  $((i + 1)). ${display_name}")
        done

        _render_menu_old "$submenu_title" "${display_items[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice

        if [ -z "$choice" ]; then return; fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$item_count" ]; then
            log_warn "无效选项。"
            sleep 1
            continue
        fi

        local selected_item_str="${SUBMENUS["${submenu_key}_item_$((choice - 1))"]}"
        local type=$(echo "$selected_item_str" | cut -d'|' -f1)
        local action=$(echo "$selected_item_str" | cut -d'|' -f4)

        case "$type" in
            item)
                local script_path="$INSTALL_DIR/$action"
                if [ -f "$script_path" ]; then
                    log_info "正在启动模块: $(basename "$script_path")..."
                    "$script_path" || true
                    press_enter_to_continue
                else
                    log_err "模块脚本 '$action' 未找到或不可执行。请尝试 '安装/更新模块'。"
                    press_enter_to_continue
                fi
                ;;
            func)
                if declare -f "$action" &>/dev/null; then
                    "$action"
                else
                    log_err "函数 '$action' 未定义。"
                    press_enter_to_continue
                fi
                ;;
            *)
                log_warn "不支持的菜单项类型: $type"
                press_enter_to_continue
                ;;
        esac
    done
}


# --- 脚本主入口 ---
main() {
    main_menu
}

main "$@"
