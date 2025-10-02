#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本
# 版本: v9.9
# 状态: 终极原子化修复版（中文注释）
# 作者: wx233Github
# 日期: 2025-10-02
# 功能概述:
#   - 自动加载配置 (config.json)
#   - 动态菜单 (config.json 中 menus)
#   - 模块化子脚本支持（按需下载到 install_dir）
#   - 并发锁，防止重复运行
#   - 自更新 + 强制更新
#   - 日志系统（写入 log_file）
#   - 非交互模式支持：设置 ONLINE_INSTALL=true 或 YES_TO_ALL=true 可跳过所有交互
# =============================================================

set -eo pipefail
export LC_ALL=C.utf8

# 颜色（输出）
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# -------------------------
# 全局默认配置（可被 config.json 覆盖）
# -------------------------
declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[log_file]="/var/log/jb_launcher.log"
# 默认依赖（空格分割字符串）
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]="/tmp/vps_install_modules.lock"
CONFIG[enable_auto_clear]="false"
CONFIG[timezone]="Asia/Shanghai"

# -------------------------
# 辅助：日志函数
# -------------------------
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info()    { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $1"; }
log_error()   { echo -e "$(log_timestamp) ${RED}[错误]${NC} $1" >&2; exit 1; }

# -------------------------
# 非交互 / 自动确认判断
# -------------------------
# 当 ONLINE_INSTALL=true 或 YES_TO_ALL=true 时自动同意所有提示
AUTO_YES="false"
if [[ "${ONLINE_INSTALL:-}" == "true" || "${YES_TO_ALL:-}" == "true" ]]; then
    AUTO_YES="true"
fi

# -------------------------
# 日志文件设置（在 load_config 后调用更合适）
# -------------------------
setup_logging() {
    # 确保 log 目录存在并可写
    sudo mkdir -p "$(dirname "${CONFIG[log_file]}")" 2>/dev/null || true
    sudo touch "${CONFIG[log_file]}" 2>/dev/null || true
    sudo chown "$(whoami)" "${CONFIG[log_file]}" 2>/dev/null || true
    # 将 stdout/stderr 都重定向到日志（同时保留终端输出）
    exec > >(tee -a "${CONFIG[log_file]}") 2> >(tee -a "${CONFIG[log_file]}" >&2)
}

# -------------------------
# 并发锁，防止重复运行
# -------------------------
acquire_lock() {
    local lock_file="${CONFIG[lock_file]}"
    if [ -e "$lock_file" ]; then
        local old_pid; old_pid=$(cat "$lock_file" 2>/dev/null || true)
        if [ -n "$old_pid" ] && ps -p "$old_pid" > /dev/null 2>&1; then
            log_warning "检测到另一实例 (PID: $old_pid) 正在运行。"
            exit 1
        else
            log_warning "检测到陈旧锁文件 (PID: ${old_pid:-N/A})，将自动清理。"
            sudo rm -f "$lock_file" 2>/dev/null || true
        fi
    fi
    echo "$$" | sudo tee "$lock_file" > /dev/null
}
release_lock() { sudo rm -f "${CONFIG[lock_file]}" 2>/dev/null || true; }

# -------------------------
# 从 config.json 加载配置（安全读取）
# -------------------------
load_config() {
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        # 读取非 menus、非 dependencies 且不是以 comment 开头的键
        while IFS='=' read -r key value; do
            value="${value#\"}"; value="${value%\"}"
            CONFIG[$key]="$value"
        done < <(jq -r 'to_entries | map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not))) | .[]? | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

        # 读取依赖数组（可能不存在）
        local deps_sh
        deps_sh=$(jq -r '.dependencies.common // [] | @sh' "$CONFIG_FILE" 2>/dev/null || echo "")
        CONFIG[dependencies]="$(echo "$deps_sh" | tr -d "'" )"

        CONFIG[lock_file]="$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[lock_file]}")"
        CONFIG[enable_auto_clear]=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[enable_auto_clear]}")
        CONFIG[timezone]=$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[timezone]}")
    else
        log_warning "未找到 config.json 或 jq 不可用，使用默认配置。"
    fi
}

# -------------------------
# 检查并安装依赖（支持自动确认）
# -------------------------
check_and_install_dependencies() {
    local missing_deps=()
    IFS=' ' read -r -a deps_array <<< "${CONFIG[dependencies]}"
    for cmd in "${deps_array[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warning "缺少核心依赖: ${missing_deps[*]}"
        local pm="unknown"
        if command -v apt-get &>/dev/null; then pm="apt"
        elif command -v dnf &>/dev/null; then pm="dnf"
        elif command -v yum &>/dev/null; then pm="yum"
        fi

        if [ "$pm" == "unknown" ]; then
            log_error "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"
        fi

        if [ "$AUTO_YES" == "true" ]; then
            log_info "自动模式：将尝试安装依赖..."
            if [ "$pm" == "apt" ]; then sudo apt-get update -y || true; fi
            if ! sudo $pm install -y "${missing_deps[@]}"; then
                log_error "依赖安装失败。"
            else
                log_success "依赖安装完成！"
            fi
        else
            read -p "$(echo -e "${YELLOW}是否尝试自动安装依赖? (y/N): ${NC}")" choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                if [ "$pm" == "apt" ]; then sudo apt-get update -y || true; fi
                if ! sudo $pm install -y "${missing_deps[@]}"; then
                    log_error "依赖安装失败。"
                else
                    log_success "依赖安装完成！"
                fi
            else
                log_error "用户取消安装依赖。"
            fi
        fi
    fi
}

# -------------------------
# 下载并保存入口脚本
# -------------------------
_download_self() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/install.sh" -o "$1"; }
save_entry_script() {
    sudo mkdir -p "${CONFIG[install_dir]}" 2>/dev/null || true
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    log_info "正在保存入口脚本到 ${SCRIPT_PATH} ..."
    local temp_path="/tmp/install.sh.self"
    if ! _download_self "$temp_path"; then
        if [[ "$0" == /dev/fd/* || "$0" == "bash" ]]; then
            log_error "无法自动保存入口脚本（当前为管道/进程替代执行）。"
        else
            sudo cp "$0" "$SCRIPT_PATH" || true
        fi
    else
        sudo mv "$temp_path" "$SCRIPT_PATH" || true
    fi
    sudo chmod +x "$SCRIPT_PATH" || true
}

# -------------------------
# 创建快捷指令 jb
# -------------------------
setup_shortcut() {
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    local BIN="${CONFIG[bin_dir]}"
    sudo mkdir -p "$BIN" 2>/dev/null || true
    if [ ! -L "${BIN}/jb" ] || [ "$(readlink "${BIN}/jb" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
        sudo ln -sf "$SCRIPT_PATH" "${BIN}/jb" || true
        log_success "快捷指令 'jb' 已创建 -> ${BIN}/jb"
    fi
}

# -------------------------
# 自更新逻辑（检查 Github 上的 install.sh）
# -------------------------
self_update() {
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    # 只有当当前脚本就是保存在 install_dir 时才自动 self-update
    if [[ "$0" != "$SCRIPT_PATH" ]]; then return; fi
    log_info "检查主脚本更新..."
    local tmp="/tmp/install.sh.tmp"
    if _download_self "$tmp"; then
        if ! cmp -s "$SCRIPT_PATH" "$tmp"; then
            log_info "发现新版本，替换本脚本并重启..."
            sudo mv "$tmp" "$SCRIPT_PATH" || true
            sudo chmod +x "$SCRIPT_PATH" || true
            exec sudo -E bash "$SCRIPT_PATH" "$@"
        fi
        rm -f "$tmp" || true
    else
        log_warning "无法从 ${CONFIG[base_url]} 获取最新脚本。"
    fi
}

# -------------------------
# 下载模块脚本到缓存
# -------------------------
download_module_to_cache() {
    local script_name="$1"
    local force_update="${2:-false}"
    local local_file="${CONFIG[install_dir]}/$script_name"
    sudo mkdir -p "$(dirname "$local_file")" 2>/dev/null || true
    local url="${CONFIG[base_url]}/$script_name"
    if [ "$force_update" = "true" ]; then url="${url}?_=$(date +%s)"; fi
    local http_code
    http_code=$(curl -sL --connect-timeout 5 --max-time 60 "$url" -o "$local_file" -w "%{http_code}")
    if [ "$http_code" -eq 200 ] && [ -s "$local_file" ]; then
        return 0
    else
        sudo rm -f "$local_file" 2>/dev/null || true
        log_warning "下载模块 [$script_name] 失败 (HTTP: $http_code)。"
        return 1
    fi
}

# -------------------------
# 并行更新所有子模块（安全的 jq 读取）
# -------------------------
_update_all_modules() {
    local force_update="${1:-false}"
    log_info "并行更新所有模块..."
    local cfg="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$cfg" ]; then
        log_warning "配置文件不存在 (${cfg})，跳过模块更新。"
        return
    fi
    # 安全读取：避免在 menus 为空时报错
    local scripts
    scripts=$(jq -r '.menus[]?[]? | select(.type=="item") | .action' "$cfg" 2>/dev/null || true)
    if [ -z "$scripts" ]; then
        log_info "未找到可更新的模块列表。"
        return
    fi
    for s in $scripts; do
        (
            if download_module_to_cache "$s" "$force_update"; then
                echo -e "  ${GREEN}✔ ${s}${NC}"
            else
                echo -e "  ${RED}✖ ${s}${NC}"
            fi
        ) &
    done
    wait
    log_success "所有模块更新完成。"
}

# -------------------------
# 强制更新入口（主脚本 + 子模块）
# -------------------------
force_update_all() {
    log_info "开始强制更新流程..."
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    log_info "步骤1：检查主脚本..."
    local tmp="/tmp/install.sh.force.tmp"
    local force_url="${CONFIG[base_url]}/install.sh?_=$(date +%s)"
    if curl -fsSL "$force_url" -o "$tmp"; then
        if ! cmp -s "$SCRIPT_PATH" "$tmp"; then
            log_info "检测到主脚本新版本，替换并重启..."
            sudo mv "$tmp" "$SCRIPT_PATH" || true
            sudo chmod +x "$SCRIPT_PATH" || true
            exec sudo -E bash "$SCRIPT_PATH" "$@"
        else
            log_success "主脚本已是最新。"
            rm -f "$tmp" || true
        fi
    else
        log_warning "无法获取主脚本更新。"
    fi
    log_info "步骤2：强制更新所有子模块..."
    _update_all_modules "true"
}

confirm_and_force_update() {
    if [ "$AUTO_YES" == "true" ]; then
        force_update_all
        return
    fi
    read -p "$(echo -e "${YELLOW}这将强制拉取最新版本，继续吗？(Y/回车 确认, N 取消): ${NC}")" choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then
        force_update_all
    else
        log_info "强制更新已取消。"
    fi
}

# -------------------------
# 执行模块（稳健注入环境变量）
# -------------------------
execute_module() {
    local script_name="$1"
    local display_name="$2"
    local local_path="${CONFIG[install_dir]}/$script_name"
    local config_path="${CONFIG[install_dir]}/config.json"

    log_info "您选择了 [$display_name]"

    if [ ! -f "$local_path" ]; then
        log_info "模块不存在，正在下载 $script_name ..."
        if ! download_module_to_cache "$script_name"; then
            log_error "下载模块失败：$script_name"
            return 1
        fi
    fi
    sudo chmod +x "$local_path" 2>/dev/null || true

    # 构造环境变量数组（每项形如 VAR=val）
    env_args=()
    env_args+=( "IS_NESTED_CALL=true" )
    env_args+=( "JB_ENABLE_AUTO_CLEAR=${CONFIG[enable_auto_clear]}" )
    env_args+=( "JB_TIMEZONE=${CONFIG[timezone]}" )

    # 从 config.json 中注入 module 专属配置（WT_CONF_ 前缀）
    if [ -f "$config_path" ] && command -v jq &>/dev/null; then
        local module_key
        module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')
        if jq -e --arg key "$module_key" '.module_configs[$key] != null' "$config_path" >/dev/null 2>&1; then
            # 逐条读取键值对，值使用 tostring，避免 json 结构带来的问题
            while IFS="=" read -r k v; do
                k_u=$(echo "$k" | tr '[:lower:]' '[:upper:]')
                # 直接作为 VAR=value 添加（env 会正确处理包含空格的单个参数）
                env_args+=( "WT_CONF_${k_u}=${v}" )
            done < <(jq -r --arg key "$module_key" '.module_configs[$key] | to_entries[]? | select(.key | startswith("comment") | not) | "\(.key)=\(.value|tostring)"' "$config_path" 2>/dev/null || true)
        fi
    fi

    # watchtower 特殊处理：收集 labels 与排除容器列表
    if [[ "$script_name" == "tools/Watchtower.sh" ]]; then
        if command -v docker &>/dev/null && docker ps -q &>/dev/null; then
            all_labels=$(docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | jq -s 'add | keys_unsorted | unique | .[]?' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            if [ -n "$all_labels" ]; then env_args+=( "WT_AVAILABLE_LABELS=${all_labels}" ); fi
            if [ -f "$config_path" ] && command -v jq &>/dev/null; then
                exclude_list=$(jq -r '.module_configs.watchtower.exclude_containers // [] | .[]' "$config_path" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                if [ -n "$exclude_list" ]; then env_args+=( "WT_EXCLUDE_CONTAINERS=${exclude_list}" ); fi
            fi
        fi
    fi

    # 使用 sudo env 安全传递环境变量并执行模块脚本（避免 eval/拼接问题）
    local exit_code=0
    sudo env "${env_args[@]}" bash "$local_path" || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
        log_success "模块 [$display_name] 执行完毕。"
    elif [ "$exit_code" -eq 10 ]; then
        log_info "模块 [$display_name] 返回上级菜单。"
    else
        log_warning "模块 [$display_name] 执行出错 (退出码: $exit_code)。"
    fi
    return $exit_code
}

# -------------------------
# 菜单渲染 / 交互（从 config.json 的 menus 读取）
# -------------------------
display_menu() {
    if [[ "${CONFIG[enable_auto_clear]}" == "true" ]]; then clear 2>/dev/null || true; fi
    local config_path="${CONFIG[install_dir]}/config.json"
    local header_text="🚀 VPS 一键安装入口 (v9.9)"

    if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then
        header_text="🛠️ ${CURRENT_MENU_NAME//_/ }"
    fi

    if [ ! -f "$config_path" ]; then
        echo ""
        log_warning "配置文件缺失：${config_path}"
        echo ""
        if [ "$AUTO_YES" == "true" ]; then return; fi
        read -p "$(echo -e "${BLUE}按回车继续...${NC}")"
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
        local w=$(( ${#name} + 4 ))
        if [ $w -gt $max_width ]; then max_width=$w; fi
    done <<< "$names"

    local border; border=$(printf '%*s' "$((max_width + 4))" | tr ' ' '=')
    echo ""; echo -e "${BLUE}${border}${NC}"; echo -e "  ${header_text}"; echo -e "${BLUE}${border}${NC}";
    for i in $(seq 0 $((menu_len - 1))); do
        local name; name=$(echo "$menu_items_json" | jq -r ".[$i].name" 2>/dev/null || echo "")
        echo -e " ${YELLOW}$((i+1)).${NC} $name"
    done
    echo ""

    local prompt_text
    if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then
        prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 退出:"
    else
        prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 返回:"
    fi

    if [ "$AUTO_YES" == "true" ]; then
        # 自动模式下直接返回（或可定制默认行为）
        choice=""
    else
        read -p "$(echo -e "${BLUE}${prompt_text}${NC} ")" choice
    fi
}

process_menu_selection() {
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
        log_warning "无效选择。"
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
            # action 必须是脚本内已定义的函数名
            if declare -F "$action" > /dev/null; then
                "$action"
            else
                log_warning "找不到函数: $action"
            fi
            return 0
            ;;
        *)
            log_warning "未知菜单项类型: $type"
            return 0
            ;;
    esac
}

# ======================
# 主程序入口
# ======================
main() {
    local CACHE_BUSTER=""
    if [[ "${ONLINE_INSTALL:-}" == "true" ]]; then
        CACHE_BUSTER="?_=$(date +%s)"
        echo -e "${YELLOW}[警告]${NC} 在线安装模式：将强制拉取所有最新文件。"
        sudo rm -f "${CONFIG[install_dir]}/config.json" 2>/dev/null || true
    fi

    acquire_lock
    trap 'release_lock; log_info "脚本已退出。"' EXIT HUP INT QUIT TERM

    sudo mkdir -p "${CONFIG[install_dir]}" 2>/dev/null || true
    local config_path="${CONFIG[install_dir]}/config.json"

    if [ ! -f "$config_path" ]; then
        echo -e "${BLUE}[信息]${NC} 未找到配置，正在下载..."
        if ! curl -fsSL "${CONFIG[base_url]}/config.json${CACHE_BUSTER}" -o "$config_path"; then
            echo -e "${RED}[错误]${NC} 下载 config.json 失败！"
            exit 1
        fi
        echo -e "${GREEN}[成功]${NC} 已下载 config.json。"
    fi

    # 确保 jq 存在（否则无法解析 config.json）
    if ! command -v jq &>/dev/null; then
        check_and_install_dependencies
    fi

    load_config
    setup_logging
    log_info "脚本启动 (v9.9)"
    check_and_install_dependencies

    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    if [ ! -f "$SCRIPT_PATH" ]; then
        save_entry_script
    fi

    setup_shortcut
    self_update

    CURRENT_MENU_NAME="MAIN_MENU"

    while true; do
        display_menu
        local exit_code=0
        process_menu_selection || exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            # 清空任何 pending 输入，然后等待回车（除非自动模式）
            while read -r -t 0; do :; done
            if [ "$AUTO_YES" == "true" ]; then
                # 自动模式不阻塞，继续循环
                :
            else
                read -p "$(echo -e "${BLUE}按回车键继续...${NC}")"
            fi
        fi
    done
}

# 调用主程序
main "$@"
