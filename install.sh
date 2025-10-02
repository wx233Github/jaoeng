#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v9.3 - exec 终极修复版)
# =============================================================

# --- 严格模式与环境设定 ---
set -eo pipefail
export LC_ALL=C.utf8

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 默认配置 ---
declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[log_file]="/var/log/jb_launcher.log"
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]="/tmp/vps_install_modules.lock"
CONFIG[enable_auto_clear]="false"

# --- 辅助函数 & 日志系统 ---
sudo_preserve_env() { sudo -E "$@"; }
setup_logging() {
    sudo_preserve_env mkdir -p "$(dirname "${CONFIG[log_file]}")"; sudo_preserve_env touch "${CONFIG[log_file]}"; sudo_preserve_env chown "$(whoami)" "${CONFIG[log_file]}"
    exec > >(tee -a "${CONFIG[log_file]}") 2> >(tee -a "${CONFIG[log_file]}" >&2)
}
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info() { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "$(log_timestamp) ${RED}[错误]${NC} $1" >&2; exit 1; }

# --- 并发锁机制 ---
acquire_lock() {
    local lock_file="${CONFIG[lock_file]}"; if [ -e "$lock_file" ]; then
        local old_pid; old_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$old_pid" ] && ps -p "$old_pid" > /dev/null 2>&1; then log_warning "检测到另一实例 (PID: $old_pid) 正在运行。"; exit 1; else
            log_warning "检测到陈旧锁文件 (PID: ${old_pid:-"N/A"})，将自动清理。"; sudo_preserve_env rm -f "$lock_file"
        fi
    fi; echo "$$" | sudo_preserve_env tee "$lock_file" > /dev/null
}
release_lock() { sudo_preserve_env rm -f "${CONFIG[lock_file]}"; }

# --- 配置加载 ---
load_config() {
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"; if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        while IFS='=' read -r key value; do value="${value#\"}"; value="${value%\"}"; CONFIG[$key]="$value"; done < <(jq -r 'to_entries|map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not)))|map("\(.key)=\(.value)")|.[]' "$CONFIG_FILE")
        CONFIG[dependencies]="$(jq -r '.dependencies.common | @sh' "$CONFIG_FILE" | tr -d "'")"
        CONFIG[lock_file]="${CONFIG[lock_file]:-/tmp/vps_install_modules.lock}"
        CONFIG[enable_auto_clear]=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE")
    fi
}

# --- 智能依赖处理 ---
detect_package_manager() { if command -v apt-get &>/dev/null; then echo "apt"; elif command -v dnf &>/dev/null; then echo "dnf"; elif command -v yum &>/dev/null; then echo "yum"; else echo "unknown"; fi; }
check_and_install_dependencies() {
    local missing_deps=(); local deps=(${CONFIG[dependencies]}); for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warning "缺少核心依赖: ${missing_deps[*]}"; local pm; pm=$(detect_package_manager)
        if [ "$pm" == "unknown" ]; then log_error "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"; fi
        read -p "$(echo -e "${YELLOW}是否尝试自动安装? (y/N): ${NC}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在使用 $pm 安装..."; local update_cmd=""; if [ "$pm" == "apt" ]; then update_cmd="sudo_preserve_env apt-get update"; fi
            if ! $update_cmd && sudo_preserve_env $pm install -y ${missing_deps[@]}; then log_error "依赖安装失败。"; fi; log_success "依赖安装完成！"
        else log_error "用户取消安装。"; fi
    fi
}

# --- 核心功能 ---
_download_self() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/install.sh" -o "$1"; }
save_entry_script() { 
    sudo_preserve_env mkdir -p "${CONFIG[install_dir]}"; local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; log_info "正在保存入口脚本..."; 
    local temp_path="/tmp/install.sh.self"; if ! _download_self "$temp_path"; then 
        if [[ "$0" == /dev/fd/* || "$0" == "bash" ]]; then log_error "无法自动保存。"; else sudo_preserve_env cp "$0" "$SCRIPT_PATH"; fi; 
    else sudo_preserve_env mv "$temp_path" "$SCRIPT_PATH"; fi; sudo_preserve_env chmod +x "$SCRIPT_PATH"; 
}
setup_shortcut() { 
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; local BIN_DIR="${CONFIG[bin_dir]}"; 
    if [ ! -L "$BIN_DIR/jb" ] || [ "$(readlink "$BIN_DIR/jb")" != "$SCRIPT_PATH" ]; then 
        sudo_preserve_env ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"; log_success "快捷指令 'jb' 已创建。"; 
    fi; 
}
self_update() { 
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; if [[ "$0" != "$SCRIPT_PATH" ]]; then return; fi; log_info "检查主脚本更新..."; 
    local temp_script="/tmp/install.sh.tmp"; if _download_self "$temp_script"; then 
        if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then 
            log_info "检测到新版本，正在更新并重启..."; sudo_preserve_env mv "$temp_script" "$SCRIPT_PATH"; sudo_preserve_env chmod +x "$SCRIPT_PATH"; 
            log_success "主脚本更新成功！正在重新启动..."; 
            # 【修复】直接使用 sudo -E 调用，不再使用封装函数
            exec sudo -E bash "$SCRIPT_PATH" "$@" 
        fi; rm -f "$temp_script"; 
    else log_warning "无法连接 GitHub 检查更新。"; fi; 
}
download_module_to_cache() { 
    sudo_preserve_env mkdir -p "$(dirname "${CONFIG[install_dir]}/$1")"; 
    local script_name="$1"; local force_update="${2:-false}"; local local_file="${CONFIG[install_dir]}/$script_name"; 
    local url="${CONFIG[base_url]}/$script_name"; if [ "$force_update" = "true" ]; then url="${url}?_=$(date +%s)"; log_info "  ↳ 强制刷新: $script_name"; fi
    local http_code; http_code=$(curl -sL --connect-timeout 5 --max-time 60 "$url" -o "$local_file" -w "%{http_code}"); 
    if [ "$http_code" -eq 200 ] && [ -s "$local_file" ]; then return 0; else sudo_preserve_env rm -f "$local_file"; log_warning "下载 [$script_name] 失败 (HTTP: $http_code)。"; return 1; fi; 
}
_update_all_modules() {
    local force_update="${1:-false}"; log_info "正在并行更新所有模块缓存..."
    local scripts_to_update; scripts_to_update=$(jq -r '.menus[][] | select(.type=="item") | .action' "${CONFIG[install_dir]}/config.json")
    for script_name in $scripts_to_update; do ( if download_module_to_cache "$script_name" "$force_update"; then echo -e "  ${GREEN}✔ ${script_name}${NC}"; else echo -e "  ${RED}✖ ${script_name}${NC}"; fi ) & done
    wait; log_success "所有模块缓存更新完成！"
}
force_update_all() {
    log_info "开始强制更新流程..."; local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; log_info "步骤 1: 检查主脚本更新..."
    local temp_script="/tmp/install.sh.force.tmp"; local force_url="${CONFIG[base_url]}/install.sh?_=$(date +%s)"
    if curl -fsSL "$force_url" -o "$temp_script"; then
        if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then
            log_info "检测到主脚本新版本，正在应用并重启..."; sudo_preserve_env mv "$temp_script" "$SCRIPT_PATH"; sudo_preserve_env chmod +x "$SCRIPT_PATH";
            log_success "主脚本更新成功！正在重新启动...";
            # 【修复】直接使用 sudo -E 调用，不再使用封装函数
            exec sudo -E bash "$SCRIPT_PATH" "$@" 
        else
            log_success "主脚本已是最新版本。"; rm -f "$temp_script";
        fi
    else log_warning "无法获取主脚本，跳过更新。"; fi
    log_info "步骤 2: 强制更新所有子模块..."; _update_all_modules "true"
}
confirm_and_force_update() {
    read -p "$(echo -e "${YELLOW}这将从GitHub强制拉取最新版本，确定要继续吗？(Y/回车 确认, N 取消): ${NC}")" choice
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then force_update_all; else log_info "强制更新已取消。"; fi
}
execute_module() {
    local script_name="$1"; local display_name="$2"; local local_path="${CONFIG[install_dir]}/$script_name"; local config_path="${CONFIG[install_dir]}/config.json";
    log_info "您选择了 [$display_name]"; if [ ! -f "$local_path" ]; then log_info "正在下载模块..."; if ! download_module_to_cache "$script_name"; then log_error "下载失败。"; return 1; fi; fi
    sudo_preserve_env chmod +x "$local_path"; local env_vars=("IS_NESTED_CALL=true" "JB_ENABLE_AUTO_CLEAR=${CONFIG[enable_auto_clear]}")
    local module_key; module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')
    if jq -e --arg key "$module_key" 'has("module_configs") and .module_configs | has($key)' "$config_path" > /dev/null; then
        while IFS='=' read -r key value; do env_vars+=("$(echo "WT_CONF_$key" | tr '[:lower:]' '[:upper:]')=$value"); done < <(jq -r --arg key "$module_key" '.module_configs[$key] | to_entries | .[] | select(.key | startswith("comment") | not) | "\(.key)=\(.value)"' "$config_path")
    fi
    if [[ "$script_name" == "tools/Watchtower.sh" ]] && command -v docker &>/dev/null && docker ps -q &>/dev/null; then
        local all_labels; all_labels=$(docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | jq -s 'add | keys_unsorted | unique | .[]' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$all_labels" ]; then env_vars+=("WT_AVAILABLE_LABELS=$all_labels"); fi
        local exclude_list; exclude_list=$(jq -r '.module_configs.watchtower.exclude_containers // [] | .[]' "$config_path" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$exclude_list" ]; then env_vars+=("WT_EXCLUDE_CONTAINERS=$exclude_list"); fi
    fi
    local exit_code=0; sudo_preserve_env env "${env_vars[@]}" bash "$local_path" || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then log_success "模块 [$display_name] 执行完毕。"; elif [ "$exit_code" -eq 10 ]; then log_info "已从 [$display_name] 返回。"; else log_warning "模块 [$display_name] 执行出错 (码: $exit_code)。"; fi
    return $exit_code
}

# --- 动态菜单核心 ---
CURRENT_MENU_NAME="MAIN_MENU"
display_menu() {
    if [[ "${CONFIG[enable_auto_clear]}" == "true" ]]; then clear 2>/dev/null || true; fi
    local config_path="${CONFIG[install_dir]}/config.json"; local header_text="🚀 VPS 一键安装入口 (v9.3)"; if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then header_text="🛠️ ${CURRENT_MENU_NAME//_/ }"; fi
    local menu_items_json; menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_items_json" | jq 'length')
    local max_width=${#header_text}; local names; names=$(echo "$menu_items_json" | jq -r '.[].name');
    while IFS= read -r name; do local line_width=$(( ${#name} + 4 )); if [ $line_width -gt $max_width ]; then max_width=$line_width; fi; done <<< "$names"
    local border; border=$(printf '%*s' "$((max_width + 4))" | tr ' ' '=')
    echo ""; echo -e "${BLUE}${border}${NC}"; echo -e "  ${header_text}"; echo -e "${BLUE}${border}${NC}";
    for i in $(seq 0 $((menu_len - 1))); do local name; name=$(echo "$menu_items_json" | jq -r ".[$i].name"); echo -e " ${YELLOW}$((i+1)).${NC} $name"; done; echo ""
    local prompt_text; if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 退出:"; else prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 返回:"; fi
    read -p "$(echo -e "${BLUE}${prompt_text}${NC} ")" choice
}
process_menu_selection() {
    local config_path="${CONFIG[install_dir]}/config.json"
    local menu_items_json; menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_items_json" | jq 'length')
    if [ -z "$choice" ]; then if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then log_info "已退出脚本。"; exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; return 10; fi; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then log_warning "无效选项。"; return 0; fi
    local item_json; item_json=$(echo "$menu_items_json" | jq ".[$((choice-1))]")
    local type; type=$(echo "$item_json" | jq -r ".type"); local name; name=$(echo "$item_json" | jq -r ".name"); local action; action=$(echo "$item_json" | jq -r ".action")
    case "$type" in item) execute_module "$action" "$name"; return $?;; submenu | back) CURRENT_MENU_NAME=$action; return 10;; func) "$action"; return 0;; esac
}

# ====================== 主程序入口 ======================
main() {
    acquire_lock
    trap 'release_lock; log_info "脚本已退出，锁已释放。"' EXIT HUP INT QUIT TERM
    sudo_preserve_env mkdir -p "${CONFIG[install_dir]}"
    local config_path="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$config_path" ]; then
        echo -e "${BLUE}[信息]${NC} 未找到配置文件，正在下载...";
        if ! curl -fsSL "${CONFIG[base_url]}/config.json" -o "$config_path"; then echo -e "${RED}[错误]${NC} 下载失败！"; exit 1; fi
        echo -e "${GREEN}[成功]${NC} 默认配置已下载。"
    fi
    if ! command -v jq &>/dev/null; then check_and_install_dependencies; fi
    load_config; setup_logging; log_info "脚本启动 (v9.3)"; check_and_install_dependencies
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    if [ ! -f "$SCRIPT_PATH" ]; then save_entry_script; fi
    setup_shortcut; self_update
    while true; do 
        display_menu
        local exit_code=0; process_menu_selection || exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            while read -r -t 0; do :; done; read -p "$(echo -e "${BLUE}按回车键继续...${NC}")"
        fi
    done
}
main "$@"
