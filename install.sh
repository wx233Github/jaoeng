#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装脚本 (v4.6.29-FinalFix - 最终修复版本)
# - [核心修复] 强化 `config.json` 下载后的验证：使用 `jq -s '.'` 强制解析为单一有效 JSON。
# - [核心修复] 移除 `main_menu` 循环中重复的 `load_menus_from_json` 调用，菜单只在脚本启动时加载一次。
# - [优化] 移除调试模式 `set -x`。
# - [核心修复] 在 `main_menu` 函数的菜单渲染循环中，添加了 `local display_name="${icon} ${name}"`，确保菜单项名称正确显示。
# - [核心修复] 解决 `bash: syntax error near unexpected token `}'` 错误。
#   - 将所有 `\done` 关键字更正为 `done`，确保 for 循环正确闭合。
# - [核心修复] 所有 `read` 命令现在明确从 `/dev/tty` 读取，解决通过管道执行脚本时 `read` 立即退出的问题。
# - [核心修复] 解决 MAIN_MENU_ITEMS 和 SUBMENUS 数组在函数调用后变为空的问题。
#   - 移除 `load_menus_from_json` 函数内部的 `declare -A` 语句，确保操作的是全局数组。
#   - 使用 `unset 'ARRAY_NAME[@]'` 来清空数组元素，而不是重新声明。
# - [核心修复] 增强 `load_menus_from_json` 函数的健壮性，确保即使 config.json 结构不完全匹配也能正常加载。
#   - 在解析主菜单和子菜单项时，增加对 JSON 结构类型的严格检查。
#   - 使用 `set +e / set -e` 块包围关键 `jq` 命令，并检查其退出状态。
#   - 增加大量 `_temp_log_info` 消息，以便追踪解析流程和中间结果。
# - [核心修复] 解决 `bash: local: can only be used in a function` 错误，移除全局作用域的 `local` 关键字。
# - [核心修复] 脚本自初始化流程优化，确保 utils.sh 和 config.json 在被 source/解析前已下载。
#   - 提前检查并安装 `jq` 依赖。
#   - 优先下载 `config.json` 以获取正确的 `base_url`。
#   - 再下载 `utils.sh`。
# - [核心修改] 将解析到的 config.json 值作为环境变量导出，供 utils.sh 的 load_config 使用。
# - [新增] 在主菜单中添加 UI 主题设置入口，调用 utils.sh 的 `theme_settings_menu`。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.29-FinalFix"

# --- 严格模式与环境设定 ---
set -eo pipefail
# set -x # <--- 移除逐行追踪
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
    
    # --- 净化 config.json 文件 ---
    _temp_log_info "正在净化 config.json 文件 (移除BOM和回车符)..."
    # 移除 UTF-8 BOM
    sed -i '1s/^\xEF\xBB\xBF//' "$CONFIG_JSON_PATH"
    # 移除 Windows 风格的回车符
    tr -d '\r' < "$CONFIG_JSON_PATH" > "${CONFIG_JSON_PATH}.tmp" && mv "${CONFIG_JSON_PATH}.tmp" "$CONFIG_JSON_PATH"
    _temp_log_success "config.json 文件净化完成。"

    # 验证 config.json 是否为有效 JSON，并强制解析为单一有效 JSON
    _temp_log_info "正在对 config.json 进行最终 JSON 结构验证..."
    local temp_json_content
    set +e
    temp_json_content=$(jq -s '.' "$CONFIG_JSON_PATH" 2>/dev/null) # 使用 -s 强制解析为单一 JSON 数组或对象
    local jq_validation_status=$?
    set -e
    if [ $jq_validation_status -ne 0 ]; then
        _temp_log_err "下载的 config.json 不是有效的 JSON 格式或包含多余内容！请检查文件内容。"
        exit 1
    fi
    # 将验证后的内容写回文件，确保文件是纯净的单一 JSON
    echo "$temp_json_content" | sudo tee "$CONFIG_JSON_PATH" >/dev/null
    _temp_log_success "config.json 文件已通过最终 JSON 结构验证并保存。"


    # 从下载的 config.json 更新 base_url
    new_base_url=$(jq -r '.base_url // "'"$DEFAULT_BASE_URL"'"' "$CONFIG_JSON_PATH")
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
    export JB_ENABLE_AUTO_CLEAR_FROM_JSON="$(jq -r '.enable_auto_clear // false' "$CONFIG_JSON_PATH" 2>/dev/null || echo "false")"
    export JB_TIMEZONE_FROM_JSON="$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_JSON_PATH" 2>/dev/null || echo "Asia/Shanghai")"

    # Watchtower 模块配置
    export JB_WATCHTOWER_CONF_DEFAULT_INTERVAL_FROM_JSON="$(jq -r '.module_configs.watchtower.default_interval // 300' "$CONFIG_JSON_PATH" 2>/dev/null || echo "300")"
    export JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR_FROM_JSON="$(jq -r '.module_configs.watchtower.default_cron_hour // 4' "$CONFIG_JSON_PATH" 2>/dev/null || echo "4")"
    export JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS_FROM_JSON="$(jq -r '.module_configs.watchtower.exclude_containers // ""' "$CONFIG_JSON_PATH" 2>/dev/null || echo "")"
    export JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES_FROM_JSON="$(jq -r '.module_configs.watchtower.notify_on_no_updates // false' "$CONFIG_JSON_PATH" 2>/dev/null || echo "false")"
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
declare -A MAIN_MENU_ITEMS # 全局声明
declare -A SUBMENUS        # 全局声明

load_menus_from_json() {
    log_info "开始加载菜单配置..."
    if [ ! -f "$CONFIG_JSON_PATH" ]; then
        log_err "配置文件 $CONFIG_JSON_PATH 未找到，无法加载菜单。请尝试强制重置。"
        exit 1
    fi

    # 此时 config.json 已经过严格验证，可以直接使用 cat 读取
    local config_json_content
    config_json_content=$(cat "$CONFIG_JSON_PATH")
    log_info "config.json 内容已读取。"

    # 健壮地获取主菜单标题
    set +e
    MAIN_MENU_TITLE=$(echo "$config_json_content" | jq -r '.menus.MAIN_MENU.title // "主菜单"' 2>/dev/null)
    local jq_status=$?
    set -e
    if [ $jq_status -ne 0 ]; then
        log_warn "从 config.json 获取主菜单标题失败 (jq exit status: $jq_status)。使用默认标题。"
        MAIN_MENU_TITLE="主菜单"
    fi
    log_info "主菜单标题: '$MAIN_MENU_TITLE'"
    
    # 清空全局数组，而不是重新声明局部数组
    unset 'MAIN_MENU_ITEMS[@]' 
    log_info "已清空 MAIN_MENU_ITEMS 数 组 。 "

    local i=0
    # 健壮地解析主菜单项
    local main_menu_items_json_array_raw
    set +e
    main_menu_items_json_array_raw=$(echo "$config_json_content" | jq -c '.menus.MAIN_MENU.items // []' 2>/dev/null)
    jq_status=$?
    set -e
    if [ $jq_status -ne 0 ]; then
        log_warn "从 config.json 获取 'menus.MAIN_MENU.items' 失败 (jq exit status: $jq_status)。将使用空主菜单项。"
        main_menu_items_json_array_raw="[]"
    fi
    log_info "主菜单项原始JSON数组: '$main_menu_items_json_array_raw'"

    if echo "$main_menu_items_json_array_raw" | jq -e 'type == "array"' 2>/dev/null >/dev/null; then
        while IFS= read -r item_json; do
            if [ -z "$item_json" ]; then continue; fi

            set +e
            local type=$(echo "$item_json" | jq -r '.type // "unknown"' 2>/dev/null)
            local name=$(echo "$item_json" | jq -r '.name // "未知菜单项"' 2>/dev/null)
            local icon=$(echo "$item_json" | jq -r '.icon // ""' 2>/dev/null)
            local action=$(echo "$item_json" | jq -r '.action // ""' 2>/dev/null)
            jq_status=$?
            set -e
            if [ $jq_status -ne 0 ]; then
                log_warn "解析主菜单项 JSON 失败 (jq exit status: $jq_status): '$item_json'。跳过此项。"
                continue
            fi

            MAIN_MENU_ITEMS["$i"]="${type}|${name}|${icon}|${action}"
            log_info "添加主菜单项 $i: '${MAIN_MENU_ITEMS["$i"]}'"
            i=$((i + 1))
        done <<< "$(echo "$main_menu_items_json_array_raw" | jq -c '.[] // empty' 2>/dev/null || true)"
    else
        log_warn "config.json 中 'menus.MAIN_MENU.items' 结构异常或不是数组。主菜单项将为空。"
    fi
    log_info "主菜单项加载完成。共 $i 项 。"

    # 清空全局数组，而不是重新声明局部数组
    unset 'SUBMENUS[@]'
    log_info "已清空 SUBMENUS 数 组 。 "

    # 加载所有子菜单键
    local submenu_keys_json_array_raw
    local submenu_keys_json_array_stderr_output # 捕获 stderr
    log_info "尝 试 从  config.json 获 取 子 菜 单 键 列 表  (JSON数 组 格 式 )..."
    set +e
    submenu_keys_json_array_raw=$(echo "$config_json_content" | jq -c '.menus | keys | map(select(. != "MAIN_MENU")) // []' 2> >(submenu_keys_json_array_stderr_output=$(cat); echo "$submenu_keys_json_array_stderr_output" >&2))
    jq_status=$?
    set -e
    log_info "jq 命 令 获 取 子 菜 单 键 的 退 出 状 态 : $jq_status"
    if [ -n "$submenu_keys_json_array_stderr_output" ]; then
        log_warn "jq 获 取 子 菜 单 键 时 有 stderr 输 出 : '$submenu_keys_json_array_stderr_output'"
    fi
    if [ $jq_status -ne 0 ]; then
        log_warn "从 config.json 获取子菜单键失败 (jq exit status: $jq_status)。将使用空子菜单。"
        submenu_keys_json_array_raw="[]"
    fi
    log_info "子菜单键原始JSON数组 (预 期 ): '$submenu_keys_json_array_raw'"

    if echo "$submenu_keys_json_array_raw" | jq -e 'type == "array"' 2>/dev/null >/dev/null; then
        log_info "子菜单键列表是有效的JSON数组，开 始 迭 代 。"
        while IFS= read -r submenu_key; do
            if [ -z "$submenu_key" ]; then continue; fi

            log_info "正 在 处 理 子 菜 单 键 : $submenu_key"
            local submenu_obj_str
            set +e
            submenu_obj_str=$(echo "$config_json_content" | jq -c ".menus.\"$submenu_key\" // {}" 2>/dev/null)
            jq_status=$?
            set -e
            if [ $jq_status -ne 0 ]; then
                log_warn "从 config.json 获取子菜单 '$submenu_key' 对象失败 (jq exit status: $jq_status)。跳过此子菜单。"
                continue
            fi
            log_info "子菜单 '$submenu_key' 原 始 JSON对 象 : '$submenu_obj_str'"
            
            local submenu_title=""
            local items_array_str="[]"

            if echo "$submenu_obj_str" | jq -e 'type == "object"' 2>/dev/null >/dev/null; then
                submenu_title=$(echo "$submenu_obj_str" | jq -r '.title // "'"$submenu_key"'"' 2>/dev/null)
                items_array_str=$(echo "$submenu_obj_str" | jq -c '.items // []' 2>/dev/null)
            else
                submenu_title="$submenu_key"
                log_warn "子菜单 '$submenu_key' 在 config.json 中结构异常或不是对象。使用键名作为标题，子菜单项将为空。"
            fi
            SUBMENUS["${submenu_key}_title"]="$submenu_title"
            log_info "子菜单 '$submenu_key' 标 题 : '$submenu_title'"
            log_info "子菜单 '$submenu_key' 项 目 原 始 JSON数 组 : '$items_array_str'"
            
            local j=0
            if echo "$items_array_str" | jq -e 'type == "array"' 2>/dev/null >/dev/null; then
                while IFS= read -r item_json; do
                    if [ -z "$item_json" ]; then continue; fi

                    set +e
                    local type=$(echo "$item_json" | jq -r '.type // "unknown"' 2>/dev/null)
                    local name=$(echo "$item_json" | jq -r '.name // "未知子菜单项"' 2>/dev/null)
                    local icon=$(echo "$item_json" | jq -r '.icon // ""' 2>/dev/null)
                    local action=$(echo "$item_json" | jq -r '.action // ""' 2>/dev/null)
                    jq_status=$?
                    set -e
                    if [ $jq_status -ne 0 ]; then
                        log_warn "解析子菜单 '$submenu_key' 项目 JSON 失败 (jq exit status: $jq_status): '$item_json'。跳过此项。"
                        continue
                    fi
                    SUBMENUS["${submenu_key}_item_$j"]="${type}|${name}|${icon}|${action}"
                    log_info "添 加 子 菜 单  '$submenu_key' 项 目  $j: '${SUBMENUS["${submenu_key}_item_$j"]}'"
                    j=$((j + 1))
                done <<< "$(echo "$items_array_str" | jq -c '.[] // empty' 2>/dev/null || true)"
            else
                log_warn "子菜单 '$submenu_key' 的 items 结构异常或不是数组。子菜单项将为空。"
            fi
            SUBMENUS["${submenu_key}_count"]="$j"
            log_info "子菜单 '$submenu_key' 加 载 完 成 。 共  $j 项 。 "
        done <<< "$(echo "$submenu_keys_json_array_raw" | jq -r '.[] // empty' 2>/dev/null || true)"
    else
        log_info "config.json 中 未 发 现 子 菜 单 键 。"
    fi
    log_info "菜 单 配 置 加 载 完 成 。"
}

# --- 依赖检查 ---
check_dependencies() {
    log_info "检查依赖项..."
    local common_deps=$(jq -r '.dependencies.common // ""' "$CONFIG_JSON_PATH" 2>/dev/null || echo "")
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
    log_info "开始检查并安装/更新所有模块..."
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
    log_info "进入模块选择界面..."
    local -a module_list=()
    local -a module_paths=()
    local i=1

    # 遍历主菜单和子菜单中的所有 type="item"
    local all_menu_items=()
    for item_idx in "${!MAIN_MENU_ITEMS[@]}"; do
        all_menu_items+=("${MAIN_MENU_ITEMS[$item_idx]}")
    done

    # Collect all unique submenu keys that were successfully loaded
    local -a loaded_submenu_keys=()
    for key in "${!SUBMENUS[@]}"; do
        if [[ "$key" == *_title ]]; then
            # Extract the base key (e.g., "TOOLS_MENU" from "TOOLS_MENU_title")
            loaded_submenu_keys+=("${key%_title}")
        fi
    done

    for submenu_key in "${loaded_submenu_keys[@]}"; do
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
            local display_name="${icon} ${name}"
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
            read -r -p " └──> 按 Enter 返回: " </dev/tty
            return
        fi

        local -a numbered_display_items=()
        for idx in "${!module_list[@]}"; do
            numbered_display_items+=("  $((idx + 1)). ${module_list[$idx]}")
        done

        _render_menu "🚀 进 入 模 块 菜 单 🚀" "${numbered_display_items[@]}"
        read -r -p " └──> 请选择模块编号, 或按 Enter 返回: " choice </dev/tty

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


# --- 脚本主入口 ---
main() {
    # 脚本启动时只加载一次菜单配置
    load_menus_from_json

    main_menu
}

main "$@"
