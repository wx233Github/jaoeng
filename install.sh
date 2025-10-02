#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本
# 版本: v9.9
# 状态: 终极原子化修复版
# 作者: wx233Github
# 日期: 2025-10-02
# 描述:
#   - 自动加载配置 (config.json)
#   - 动态菜单管理
#   - 模块化子脚本支持
#   - 并发锁机制防止重复执行
#   - 自更新 + 强制更新模式
#   - 日志系统 (输出到 /var/log/jb_launcher.log)
# =============================================================

set -eo pipefail
export LC_ALL=C.utf8

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Default config (global)
declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[log_file]="/var/log/jb_launcher.log"
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]="/tmp/vps_install_modules.lock"
CONFIG[enable_auto_clear]="false"
CONFIG[timezone]="Asia/Shanghai"

# Logging helpers
sudo_preserve_env() { sudo -E "$@"; }
setup_logging() {
    export LC_ALL=C.utf8
    sudo mkdir -p "$(dirname "${CONFIG[log_file]}")" || true
    sudo touch "${CONFIG[log_file]}" 2>/dev/null || true
    sudo chown "$(whoami)" "${CONFIG[log_file]}" 2>/dev/null || true
    exec > >(tee -a "${CONFIG[log_file]}") 2> >(tee -a "${CONFIG[log_file]}" >&2)
}
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info() { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "$(log_timestamp) ${RED}[错误]${NC} $1" >&2; exit 1; }

# Locking
acquire_lock() {
    export LC_ALL=C.utf8
    local lock_file="${CONFIG[lock_file]}"
    if [ -e "$lock_file" ]; then
        local old_pid; old_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$old_pid" ] && ps -p "$old_pid" > /dev/null 2>&1; then
            log_warning "检测到另一实例 (PID: $old_pid) 正在运行。"
            exit 1
        else
            log_warning "检测到陈旧锁文件 (PID: ${old_pid:-"N/A"})，将自动清理。"
            sudo rm -f "$lock_file" || true
        fi
    fi
    echo "$$" | sudo tee "$lock_file" > /dev/null
}
release_lock() { sudo rm -f "${CONFIG[lock_file]}" || true; }

# Load config.json safely
load_config() {
    export LC_ALL=C.utf8
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        # read top-level non-menu, non-dependencies, non-comment keys
        while IFS='=' read -r key value; do
            value="${value#\"}"; value="${value%\"}"
            CONFIG[$key]="$value"
        done < <(jq -r 'to_entries | map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not))) | .[]? | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

        # dependencies.common might be missing
        local deps; deps=$(jq -r '.dependencies.common // [] | @sh' "$CONFIG_FILE" 2>/dev/null || echo "")
        CONFIG[dependencies]="$(echo "$deps" | tr -d "'")"
        CONFIG[lock_file]="$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[lock_file]}")"
        CONFIG[enable_auto_clear]=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[enable_auto_clear]}")
        CONFIG[timezone]=$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[timezone]}")
    else
        log_warning "未找到 config.json 或 jq 不可用，使用默认配置。"
    fi
}

# Install dependencies if missing (robust if/fi)
check_and_install_dependencies() {
    export LC_ALL=C.utf8
    local missing_deps=()
    local deps=(${CONFIG[dependencies]})
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warning "缺少核心依赖: ${missing_deps[*]}"
        local pm
        if command -v apt-get &>/dev/null; then pm="apt"
        elif command -v dnf &>/dev/null; then pm="dnf"
        elif command -v yum &>/dev/null; then pm="yum"
        else pm="unknown"
        fi
        if [ "$pm" == "unknown" ]; then log_error "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"; fi
        read -p "$(echo -e "${YELLOW}是否尝试自动安装? (y/N): ${NC}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在使用 $pm 安装..."
            local update_cmd=""
            if [ "$pm" == "apt" ]; then update_cmd="sudo apt-get update"; fi
            if ! { $update_cmd && sudo $pm install -y "${missing_deps[@]}"; }; then
                log_error "依赖安装失败。"
            else
                log_success "依赖安装完成！"
            fi
        else
            log_error "用户取消安装。"
        fi
    fi
}

# Download helpers
_download_self() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/install.sh" -o "$1"; }
save_entry_script() {
    export LC_ALL=C.utf8
    sudo mkdir -p "${CONFIG[install_dir]}" || true
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    log_info "正在保存入口脚本..."
    local temp_path="/tmp/install.sh.self"
    if ! _download_self "$temp_path"; then
        if [[ "$0" == /dev/fd/* || "$0" == "bash" ]]; then
            log_error "无法自动保存。"
        else
            sudo cp "$0" "$SCRIPT_PATH" || true
        fi
    else
        sudo mv "$temp_path" "$SCRIPT_PATH" || true
    fi
    sudo chmod +x "$SCRIPT_PATH" || true
}
setup_shortcut() {
    export LC_ALL=C.utf8
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    local BIN_DIR="${CONFIG[bin_dir]}"
    if [ ! -L "$BIN_DIR/jb" ] || [ "$(readlink "$BIN_DIR/jb" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
        sudo ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb" || true
        log_success "快捷指令 'jb' 已创建。"
    fi
}
self_update() {
    export LC_ALL=C.utf8
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    if [[ "$0" != "$SCRIPT_PATH" ]]; then return; fi
    log_info "检查主脚本更新..."
    local temp_script="/tmp/install.sh.tmp"
    if _download_self "$temp_script"; then
        if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then
            log_info "检测到新版本..."
            sudo mv "$temp_script" "$SCRIPT_PATH" || true
            sudo chmod +x "$SCRIPT_PATH" || true
            log_success "主脚本更新成功！正在重启..."
            exec sudo -E bash "$SCRIPT_PATH" "$@"
        fi
        rm -f "$temp_script" || true
    else
        log_warning "无法连接 GitHub 检查更新。"
    fi
}

download_module_to_cache() {
    export LC_ALL=C.utf8
    sudo mkdir -p "$(dirname "${CONFIG[install_dir]}/$1")" || true
    local script_name="$1"
    local force_update="${2:-false}"
    local local_file="${CONFIG[install_dir]}/$script_name"
    local url="${CONFIG[base_url]}/$script_name"
    if [ "$force_update" = "true" ]; then url="${url}?_=$(date +%s)"; log_info "  ↳ 强制刷新: $script_name"; fi
    local http_code
    http_code=$(curl -sL --connect-timeout 5 --max-time 60 "$url" -o "$local_file" -w "%{http_code}")
    if [ "$http_code" -eq 200 ] && [ -s "$local_file" ]; then
        return 0
    else
        sudo rm -f "$local_file" || true
        log_warning "下载 [$script_name] 失败 (HTTP: $http_code)。"
        return 1
    fi
}

_update_all_modules() {
    export LC_ALL=C.utf8
    local force_update="${1:-false}"
    log_info "正在并行更新所有模块..."
    local cfg="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$cfg" ]; then
        log_warning "配置文件不存在，跳过模块更新。"
        return
    fi
    # safe jq: avoid iterating null
    local scripts_to_update
    scripts_to_update=$(jq -r '.menus[]?[]? | select(.type=="item") | .action' "$cfg" 2>/dev/null || true)
    if [ -z "$scripts_to_update" ]; then
        log_info "未找到可更新的模块列表。"
        return
    fi
    for script_name in $scripts_to_update; do
        (
            if download_module_to_cache "$script_name" "$force_update"; then
                echo -e "  ${GREEN}✔ ${script_name}${NC}"
            else
                echo -e "  ${RED}✖ ${script_name}${NC}"
            fi
        ) &
    done
    wait
    log_success "所有模块更新完成！"
}

force_update_all() {
    export LC_ALL=C.utf8
    log_info "开始强制更新流程..."
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    log_info "步骤 1: 检查主脚本更新..."
    local temp_script="/tmp/install.sh.force.tmp"
    local force_url="${CONFIG[base_url]}/install.sh?_=$(date +%s)"
    if curl -fsSL "$force_url" -o "$temp_script"; then
        if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then
            log_info "检测到主脚本新版本..."
            sudo mv "$temp_script" "$SCRIPT_PATH" || true
            sudo chmod +x "$SCRIPT_PATH" || true
            log_success "主脚本更新成功！正在重启..."
            exec sudo -E bash "$SCRIPT_PATH" "$@"
        else
            log_success "主脚本已是最新版本。"
            rm -f "$temp_script" || true
        fi
    else
        log_warning "无法获取主脚本。"
    fi
    log_info "步骤 2: 强制更新所有子模块..."
    _update_all_modules "true"
}

confirm_and_force_update() {
    export LC_ALL=C.utf8
    read -p "$(echo -e "${YELLOW}这将强制拉取最新版本，继续吗？(Y/回车 确认, N 取消): ${NC}")" choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
        force_update_all
    else
        log_info "强制更新已取消。"
    fi
}

execute_module() {
    export LC_ALL=C.utf8
    local script_name="$1"
    local display_name="$2"
    local local_path="${CONFIG[install_dir]}/$script_name"
    local config_path="${CONFIG[install_dir]}/config.json"

    log_info "您选择了 [$display_name]"

    if [ ! -f "$local_path" ]; then
        log_info "正在下载模块..."
        if ! download_module_to_cache "$script_name"; then
            log_error "下载失败。"
            return 1
        fi
    fi
    sudo chmod +x "$local_path" || true

    local env_exports="export IS_NESTED_CALL=true; export JB_ENABLE_AUTO_CLEAR='${CONFIG[enable_auto_clear]}'; export JB_TIMEZONE='${CONFIG[timezone]}';"
    local module_key
    module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')

    if [ -f "$config_path" ] && command -v jq &>/dev/null; then
        if jq -e --arg key "$module_key" '.module_configs[$key] != null' "$config_path" >/dev/null 2>&1; then
            local exports
            exports=$(jq -r --arg key "$module_key" '.module_configs[$key] | to_entries[]? | select(.key | startswith("comment") | not) | "export WT_CONF_\(.key | ascii_upcase)=\(.value|@sh)"' "$config_path" 2>/dev/null || true)
            if [ -n "$exports" ]; then
                exports="$(echo "$exports" | tr '\n' ';')"
                env_exports+="$exports;"
            fi
        fi
    fi

    if [[ "$script_name" == "tools/Watchtower.sh" ]]; then
        if command -v docker &>/dev/null && docker ps -q &>/dev/null; then
            local all_labels
            all_labels=$(docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | jq -s 'add | keys_unsorted | unique | .[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            if [ -n "$all_labels" ]; then env_exports+="export WT_AVAILABLE_LABELS='$all_labels';"; fi

            local exclude_list
            if [ -f "$config_path" ] && command -v jq &>/dev/null; then
                exclude_list=$(jq -r '.module_configs.watchtower.exclude_containers // [] | .[]' "$config_path" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                if [ -n "$exclude_list" ]; then env_exports+="export WT_EXCLUDE_CONTAINERS='$exclude_list';"; fi
            fi
        fi
    fi

    local exit_code=0
    # run module with environment exports under sudo bash -c
    sudo bash -c "export IS_NESTED_CALL=true; $env_exports bash '$local_path'" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        log_success "模块 [$display_name] 执行完毕。"
    elif [ "$exit_code" -eq 10 ]; then
        log_info "已从 [$display_name] 返回。"
    else
        log_warning "模块 [$display_name] 执行出错 (码: $exit_code)。"
    fi
    return $exit_code
}

display_menu() {
    export LC_ALL=C.utf8
    if [[ "${CONFIG[enable_auto_clear]}" == "true" ]]; then clear 2>/dev/null || true; fi
    local config_path="${CONFIG[install_dir]}/config.json"
    local header_text="🚀 VPS 一键安装入口 (v9.9)"
    if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then header_text="🛠️ ${CURRENT_MENU_NAME//_/ }"; fi

    if [ ! -f "$config_path" ]; then
        echo ""
        log_warning "配置文件缺失：${config_path}。"
        echo ""
        read -p "$(echo -e "${BLUE}按回车键继续...${NC}")"
        return
    fi

    local menu_items_json
    menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu] // []' "$config_path" 2>/dev/null || echo "[]")
    local menu_len
    menu_len=$(echo "$menu_items_json" | jq 'length' 2>/dev/null || echo 0)

    local max_width=${#header_text}
    local names
    names=$(echo "$menu_items_json" | jq -r '.[].name' 2>/dev/null || echo "")
    while IFS= read -r name; do
        local line_width=$(( ${#name} + 4 ))
        if [ $line_width -gt $max_width ]; then max_width=$line_width; fi
    done <<< "$names"

    local border; border=$(printf '%*s' "$((max_width + 4))" | tr ' ' '=')
    echo ""; echo -e "${BLUE}${border}${NC}"; echo -e "  ${header_text}"; echo -e "${BLUE}${border}${NC}";
    for i in $(seq 0 $((menu_len - 1))); do
        local name; name=$(echo "$menu_items_json" | jq -r ".[$i].name")
        echo -e " ${YELLOW}$((i+1)).${NC} $name"
    done
    echo ""
    local prompt_text
    if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then
        prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 退出:"
    else
        prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 返回:"
    fi
    read -p "$(echo -e "${BLUE}${prompt_text}${NC} ")" choice
}

process_menu_selection() {
    export LC_ALL=C.utf8
    local config_path="${CONFIG[install_dir]}/config.json"
    local menu_items_json
    menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu] // []' "$config_path" 2>/dev/null || echo "[]")
    local menu_len
    menu_len=$(echo "$menu_items_json" | jq 'length' 2>/dev/null || echo 0)

    if [ -z "$choice" ]; then
        if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then
            log_info "已退出脚本。"
            exit 0
        else
            CURRENT_MENU_NAME="MAIN_MENU"
            return 10
        fi
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then
        log_warning "无效选项。"
        return 0
    fi

    local item_json
    item_json=$(echo "$menu_items_json" | jq ".[$((choice-1))]" 2>/dev/null || echo "{}")
    local type name action
    type=$(echo "$item_json" | jq -r ".type" 2>/dev/null || echo "")
    name=$(echo "$item_json" | jq -r ".name" 2>/dev/null || echo "")
    action=$(echo "$item_json" | jq -r ".action" 2>/dev/null || echo "")

    case "$type" in
        item)
            execute_module "$action" "$name"
            return $?
            ;;
        submenu|back)
            CURRENT_MENU_NAME=$action
            return 10
            ;;
        func)
            "$action"
            return 0
            ;;
        *)
            log_warning "未知类型: $type"
            return 0
            ;;
    esac
}

# ====================== 主程序入口 ======================
main() {
    export LC_ALL=C.utf8
    local CACHE_BUSTER=""
    if [[ "${ONLINE_INSTALL}" == "true" ]]; then
        CACHE_BUSTER="?_=$(date +%s)"
        echo -e "${YELLOW}[警告]${NC} 在线安装模式：将强制拉取所有最新文件。"
        sudo rm -f "${CONFIG[install_dir]}/config.json" 2>/dev/null || true
    fi

    acquire_lock
    trap 'release_lock; log_info "脚本已退出。"' EXIT HUP INT QUIT TERM

    sudo mkdir -p "${CONFIG[install_dir]}" || true

    local config_path="${CONFIG[install_dir]}/config.json"

    if [ ! -f "$config_path" ]; then
        echo -e "${BLUE}[信息]${NC} 未找到配置，正在下载..."
        if ! curl -fsSL "${CONFIG[base_url]}/config.json${CACHE_BUSTER}" -o "$config_path"; then
            echo -e "${RED}[错误]${NC} 下载失败！"
            exit 1
        fi
        echo -e "${GREEN}[成功]${NC} 已下载。"
    fi

    if ! command -v jq &>/dev/null; then check_and_install_dependencies; fi

    load_config
    setup_logging
    log_info "脚本启动 (v9.9)"
    check_and_install_dependencies

    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    if [ ! -f "$SCRIPT_PATH" ]; then save_entry_script; fi
    setup_shortcut
    self_update

    CURRENT_MENU_NAME="MAIN_MENU"

    while true; do
        display_menu
        local exit_code=0
        process_menu_selection || exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            # consume any pending input, then pause for Enter
            while read -r -t 0; do :; done
            read -p "$(echo -e "${BLUE}按回车键继续...${NC}")"
        fi
    done
}

# call main
main "$@"
