#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装脚本 (v4.6.17-SelfInit - 自初始化和健壮菜单解析)
# - [核心修复] 脚本自初始化流程优化，确保 utils.sh 和 config.json 在被 source/解析前已下载。
#   - 提前检查并安装 `jq` 依赖。
#   - 优先下载 `config.json` 以获取正确的 `base_url`。
#   - 再下载 `utils.sh`。
# - [核心修复] 增强 `load_menus_from_json` 函数的健壮性，解决 `jq: Cannot index string with string "title"` 错误。
#   - 在解析子菜单标题和项目时，增加对 JSON 结构类型的检查和错误处理。
# - [核心修改] 将解析到的 config.json 值作为环境变量导出，供 utils.sh 的 load_config 使用。
# - [新增] 在主菜单中添加 UI 主题设置入口，调用 utils.sh 的 `theme_settings_menu`。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.17-SelfInit"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 基础路径和文件 ---
INSTALL_DIR="/opt/vps_install_modules"
BIN_DIR="/usr/local/bin"
CONFIG_JSON_PATH="$INSTALL_DIR/config.json"
UTILS_PATH="$INSTALL_DIR/utils.sh"
LOCK_FILE="/tmp/vps_install_modules.lock"
# 默认的脚本下载基础URL (如果 config.json 未下载或解析失败，将使用此默认值)
DEFAULT_BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
base_url="$DEFAULT_BASE_URL" # 初始化 base_url

# --- 临时日志函数 (在 utils.sh 加载前使用) ---
# 这些函数会在 utils.sh 加载后被其同名函数覆盖
_temp_log_err() { echo -e "\033[0;31m[错误]\033[0m $*" >&2; }
_temp_log_info() { echo -e "\033[0;34m[信息]\033[0m $*"; }
_temp_log_success() { echo -e "\033[0;32m[成功]\033[0m $*"; }
_temp_log_warn() { echo -e "\033[0;33m[警告]\033[0m $*" >&2; }

# --- 确保 jq 已安装 (在任何 JSON 解析前) ---
ensure_jq_installed() {
    if ! command -v jq &>/dev/null; then
        _temp_log_err "jq 命令未找到。请手动安装 jq (例如: sudo apt-get install jq 或 sudo yum install jq)。"
        _temp_log_info "尝试自动安装 jq..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y jq
        elif command -v yum &>/dev/null; then
            sudo yum install -y jq
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y jq
        else
            _temp_log_err "无法自动安装 jq。请手动安装。"
            exit 1
        fi
        if ! command -v jq &>/dev/null; then # 再次检查以确认安装成功
            _temp_log_err "jq 自动安装失败。请手动安装 jq。"
            exit 1
        else
            _temp_log_success "jq 安装成功。"
        fi
    fi
}
ensure_jq_installed # 脚本启动时立即检查并安装 jq

# --- 创建安装目录 (在下载任何文件前) ---
if [ ! -d "$INSTALL_DIR" ]; then
    _temp_log_info "创建安装目录: $INSTALL_DIR..."
    sudo mkdir -p "$INSTALL_DIR"
    sudo chmod 755 "$INSTALL_DIR" # 确保权限
fi

# --- 下载 config.json (获取真实的 base_url) ---
_temp_log_info "正在下载配置文件 config.json..."
if sudo curl -fsSL "${DEFAULT_BASE_URL}/config.json?_=$(date +%s)" -o "$CONFIG_JSON_PATH"; then
    _temp_log_success "config.json 下载成功。"
    # 从下载的 config.json 更新 base_url
    local new_base_url=$(jq -r '.base_url // "'"$DEFAULT_BASE_URL"'"' "$CONFIG_JSON_PATH")
    if [ "$new_base_url" != "$base_url" ]; then
        base_url="$new_base_url"
        _temp_log_info "已从 config.json 更新脚本基础URL为: $base_url"
    fi
else
    _temp_log_warn "config.json 下载失败！将使用默认基础URL: $base_url"
    # 如果 config.json 下载失败，不退出，而是使用默认 base_url
fi

# --- 下载 utils.sh (使用可能已更新的 base_url) ---
_temp_log_info "正在下载或更新通用工具库 utils.sh..."
if sudo curl -fsSL "${base_url}/utils.sh?_=$(date +%s)" -o "$UTILS_PATH"; then
    sudo chmod +x "$UTILS_PATH"
    _temp_log_success "utils.sh 下载成功。"
else
    _temp_log_err "致命错误: utils.sh 下载失败！请检查网络或基础URL。"
    exit 1
fi

# --- 从 config.json 加载默认配置并导出为环境变量 ---
# 此函数在 utils.sh 被 source 之前调用，以便 utils.sh 的 load_config 能读取这些值
load_json_defaults() {
    if [ ! -f "$CONFIG_JSON_PATH" ]; then
        _temp_log_warn "配置文件 $CONFIG_JSON_PATH 未找到，无法加载 JSON 默认配置。将使用硬编码默认值。"
        return 1
    fi

    # 全局配置
    export JB_ENABLE_AUTO_CLEAR_FROM_JSON="$(jq -r '.enable_auto_clear // false' "$CONFIG_JSON_PATH" || echo "false")"
    export JB_TIMEZONE_FROM_JSON="$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_JSON_PATH" || echo "Asia/Shanghai")"

    # Watchtower 模块配置
    export JB_WATCHTOWER_CONF_DEFAULT_INTERVAL_FROM_JSON="$(jq -r '.module_configs.watchtower.default_interval // 300' "$CONFIG_JSON_PATH" || echo "300")"
    export JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR_FROM_JSON="$(jq -r '.module_configs.watchtower.default_cron_hour // 4' "$CONFIG_JSON_PATH" || echo "4")"
    export JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS_FROM_JSON="$(jq -r '.module_configs.watchtower.exclude_containers // ""' "$CONFIG_JSON_PATH" || echo "")"
    export JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES_FROM_JSON="$(jq -r '.module_configs.watchtower.notify_on_no_updates // false' "$CONFIG_JSON_PATH" || echo "false")"
    # 其他 Watchtower 变量 (如 TG_BOT_TOKEN, EXTRA_ARGS 等) 默认在 config.json 中未定义，
    # 它们将通过 utils.sh 中的硬编码默认值或用户在 config.conf 中的设置来管理。
    # 如果未来 config.json 增加了这些字段，也需要在这里导出。
}
load_json_defaults # 调用此函数以设置环境变量

# --- 导入通用工具函数库 (现在 utils.sh 应该已存在并包含所有配置和通用函数) ---
# utils.sh 内部会在被 source 时自动调用 load_config，从而加载 config.conf 和这些导出的 JSON 默认值。
source "$UTILS_PATH"

# --- 确保只运行一个实例 (现在使用 utils.sh 的日志函数) ---
if ! flock -xn "$LOCK_FILE" -c "true"; then
    log_warn "脚本已在运行中，请勿重复启动。"
    exit 1
fi

# --- 菜单数据 (从 config.json 加载) ---
MAIN_MENU_TITLE=""
declare -A MAIN_MENU_ITEMS
declare -A SUBMENUS

load_menus_from_json() {
    if [ ! -f "$CONFIG_JSON_PATH" ]; then
        log_err "配置文件 $CONFIG_JSON_PATH 未找到，无法加载菜单。请尝试强制重置。"
        exit 1
    fi

    MAIN_MENU_TITLE=$(jq -r '.menus.MAIN_MENU.title // "主菜单"' "$CONFIG_JSON_PATH")
    
    # 清空现有菜单项
    unset MAIN_MENU_ITEMS
    declare -A MAIN_MENU_ITEMS

    local i=0
    # 健壮地解析主菜单项
    while IFS= read -r item_json; do
        local type=$(echo "$item_json" | jq -r '.type // "unknown"')
        local name=$(echo "$item_json" | jq -r '.name // "未知菜单项"')
        local icon=$(echo "$item_json" | jq -r '.icon // ""')
        local action=$(echo "$item_json" | jq -r '.action // ""')
        MAIN_MENU_ITEMS["$i"]="${type}|${name}|${icon}|${action}"
        i=$((i + 1))
    done < <(jq -c '.menus.MAIN_MENU.items[] // empty' "$CONFIG_JSON_PATH" || true)

    # 加载所有子菜单
    while IFS= read -r submenu_key; do
        # 健壮地提取子菜单对象
        local submenu_obj_str=$(jq -c ".menus.\"$submenu_key\" // {}" "$CONFIG_JSON_PATH" || echo "{}")
        
        local submenu_title=""
        local items_array_str="[]" # 默认空数组字符串

        # 检查提取出的 submenu_obj 是否是一个对象并且包含 title 字段
        if echo "$submenu_obj_str" | jq -e 'type == "object"' >/dev/null 2>&1; then
            submenu_title=$(echo "$submenu_obj_str" | jq -r '.title // "'"$submenu_key"'"') # Default title to key if not present
            items_array_str=$(echo "$submenu_obj_str" | jq -c '.items // []') # Get items, default to empty array
        else
            submenu_title="$submenu_key" # Not an object, use key as title
            log_warn "子菜单 '$submenu_key' 在 config.json 中结构异常或不存在。使用键名作为标题。"
        fi
        SUBMENUS["${submenu_key}_title"]="$submenu_title"
        
        local j=0
        # 从提取出的 submenu_obj 中解析 items，并处理 items 不存在或不是数组的情况
        while IFS= read -r item_json; do
            local type=$(echo "$item_json" | jq -r '.type // "unknown"')
            local name=$(echo "$item_json" | jq -r '.name // "未知子菜单项"')
            local icon=$(echo "$item_json" | jq -r '.icon // ""')
            local action=$(echo "$item_json" | jq -r '.action // ""')
            SUBMENUS["${submenu_key}_item_$j"]="${type}|${name}|${icon}|${action}"
            j=$((j + 1))
        done < <(echo "$items_array_str" | jq -c '.[] // empty' || true)
        SUBMENUS["${submenu_key}_count"]="$j"
    done < <(jq -r '.menus | keys[] | select(. != "MAIN_MENU")' "$CONFIG_JSON_PATH" || true)
}

# --- 依赖检查 ---
check_dependencies() {
    local common_deps=$(jq -r '.dependencies.common // ""' "$CONFIG_JSON_PATH" || echo "")
    local missing_deps=""
    for dep in $common_deps; do
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
            exit 1
        fi
        if [ $? -eq 0 ]; then
            log_success "依赖安装成功。"
        else
            log_err "依赖安装失败，请手动检查并安装。"
            exit 1
        fi
    fi
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

    for submenu_key in $(jq -r '.menus | keys[] | select(. != "MAIN_MENU")' "$CONFIG_JSON_PATH" || true); do
        local count_key="${submenu_key}_count"
        local count="${SUBMENUS[$count_key]:-0}" # Default to 0 if not set
        for (( j=0; j<count; j++ )); do
            all_menu_items+=("${SUBMENUS["${submenu_key}_item_$j"]}")
        done
    done

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
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
        
        # If no modules found, display a message
        if [ ${#module_list[@]} -eq 0 ]; then
            _render_menu "🚀 进 入 模 块 菜 单 🚀" "  无可用模块。请先安装模块。"
            read -r -p " └──> 按 Enter 返回: "
            return
        fi

        local -a numbered_display_items=()
        for idx in "${!module_list[@]}"; do
            numbered_display_items+=("  $((idx + 1)). ${module_list[$idx]}")
        done

        _render_menu "🚀 进 入 模 块 菜 单 🚀" "${numbered_display_items[@]}"
        read -r -p " └──> 请选择模块编号, 或按 Enter 返回: " choice

        if [ -z "$choice" ]; then return; fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#module_paths[@]}" ]; then
            local selected_path="${module_paths[$((choice - 1))]}"
            log_info "正在进入模块: $(basename "$selected_path")..."
            "$selected_path" || true # 允许模块退出时不中断主脚本
            press_enter_to_continue
        else
            log_warn "无效选项。"
            sleep 1
        fi
    done
}


confirm_and_force_update() {
    if confirm_action "警告: 强制重置将重新下载所有脚本并恢复配置到默认值。确定继续吗?"; then
        log_info "正在强制重置..."
        # 1. 删除所有已安装的脚本模块
        log_info "正在删除旧脚本模块..."
        rm -rf "$INSTALL_DIR" || log_warn "删除旧脚本目录失败，可能不存在或权限不足。"
        
        # 2. 删除配置文件
        log_info "正在删除用户配置文件..."
        rm -f "$CONFIG_FILE" || log_warn "删除用户配置文件失败，可能不存在或权限不足。"

        # 3. 重新下载 install.sh 自身并执行安装
        log_info "正在重新下载 install.sh..."
        local install_script_url="${DEFAULT_BASE_URL}/install.sh" # 使用默认的 base_url 来获取 install.sh 自身
        if curl -fsSL -o "/tmp/install.sh" "$install_script_url"; then
            chmod +x "/tmp/install.sh"
            log_success "install.sh 下载成功。正在重新执行安装..."
            # 使用 exec 替换当前进程，执行新的安装脚本
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
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        load_menus_from_json # 每次进入主菜单都重新加载菜单配置
        local -a display_items=()
        local current_item_idx=0

        # 从 MAIN_MENU_ITEMS 数组中构建显示项
        for item_str in "${MAIN_MENU_ITEMS[@]}"; do
            local type=$(echo "$item_str" | cut -d'|' -f1)
            local name=$(echo "$item_str" | cut -d'|' -f2)
            local icon=$(echo "$item_str" | cut -d'|' -f3)
            local display_name="${icon} ${name}"
            display_items+=("  $((current_item_idx + 1)). ${display_name}")
            current_item_idx=$((current_item_idx + 1))
        done
        
        # 添加 UI 主题设置到主菜单
        display_items+=("")
        display_items+=("  $((current_item_idx + 1)). 🎨 UI 主 题 设 置")

        _render_menu "$MAIN_MENU_TITLE" "${display_items[@]}"
        read -r -p " └──> 请选择, 或按 Enter 退出: " choice

        if [ -z "$choice" ]; then exit 0; fi

        # 处理 UI 主题设置选项
        if [ "$choice" -eq "$((current_item_idx + 1))" ]; then
            theme_settings_menu
            continue
        fi

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
                    "$script_path" || true # 允许子脚本退出时不中断主脚本
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
                # 直接执行函数
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
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a display_items=()
        for (( i=0; i<item_count; i++ )); do
            local item_str="${SUBMENUS["${submenu_key}_item_$i"]}"
            local name=$(echo "$item_str" | cut -d'|' -f2)
            local icon=$(echo "$item_str" | cut -d'|' -f3)
            local display_name="${icon} ${name}"
            display_items+=("  $((i + 1)). ${display_name}")
        done

        _render_menu "$submenu_title" "${display_items[@]}"
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
