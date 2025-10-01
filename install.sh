#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v8.3 - 健壮配置解析版)
# =============================================================

# --- 严格模式与环境设定 ---
set -eo pipefail
export LC_ALL=C.utf8

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 默认配置 (当config.json加载失败时的后备) ---
declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[log_file]="/var/log/jb_launcher.log"
CONFIG[dependencies]='curl cmp ln dirname flock jq'

# --- 辅助函数 & 日志系统 ---
setup_logging() {
    mkdir -p "$(dirname "${CONFIG[log_file]}")"
    touch "${CONFIG[log_file]}" || { echo "无法创建日志文件 ${CONFIG[log_file]}，请检查权限。"; exit 1; }
    exec > >(tee -a "${CONFIG[log_file]}") 2> >(tee -a "${CONFIG[log_file]}" >&2)
}
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info() { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "$(log_timestamp) ${RED}[错误]${NC} $1" >&2; exit 1; }

# --- 配置加载 ---
load_config() {
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        # 【增强】更健壮的解析：明确排除所有 comment* 键
        while IFS='=' read -r key value; do value="${value#\"}"; value="${value%\"}"; CONFIG[$key]="$value"; done < <(jq -r 'to_entries|map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not)))|map("\(.key)=\(.value)")|.[]' "$CONFIG_FILE")
        CONFIG[dependencies]="$(jq -r '.dependencies.common | @sh' "$CONFIG_FILE" | tr -d "'")"
    fi
    CONFIG[lock_file]="${CONFIG[lock_file]:-/tmp/vps_install_modules.lock}"
}

# --- 智能依赖处理 ---
detect_package_manager() { if command -v apt-get &>/dev/null; then echo "apt"; elif command -v dnf &>/dev/null; then echo "dnf"; elif command -v yum &>/dev/null; then echo "yum"; else echo "unknown"; fi; }
check_and_install_dependencies() {
    # shellcheck disable=SC2206
    local missing_deps=(); local deps=(${CONFIG[dependencies]}); for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warning "系统缺少以下核心依赖: ${missing_deps[*]}"; local pm; pm=$(detect_package_manager)
        if [ "$pm" == "unknown" ]; then log_error "无法检测到系统的包管理器, 请手动安装依赖: ${missing_deps[*]}"; fi
        read -p "$(echo -e "${YELLOW}是否尝试自动为您安装? (y/N): ${NC}")" choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log_info "正在使用 $pm 安装依赖..."; local update_cmd=""; if [ "$pm" == "apt" ]; then update_cmd="sudo apt-get update"; fi
            # shellcheck disable=SC2086
            if ! $update_cmd && sudo $pm install -y ${missing_deps[@]}; then log_error "依赖安装失败, 请检查系统或手动安装。"; fi
            log_success "依赖安装完成！"
        else
            log_error "用户取消安装。请在手动安装依赖后重试。"
        fi
    fi
}

# --- 核心功能 (并发锁、下载、执行等) ---
with_lock() { ( flock -n 200 || { log_warning "其他更新任务正在运行，请稍后重试。"; exit 1; }; "$@"; ) 200>"${CONFIG[lock_file]}"; }
_download_self() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/install.sh" -o "$1"; }
save_entry_script() { local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; log_info "正在检查并保存入口脚本..."; local temp_path="/tmp/install.sh.self"; if ! with_lock _download_self "$temp_path"; then if [[ "$0" == /dev/fd/* || "$0" == "bash" ]]; then log_error "无法自动保存入口脚本。"; else cp "$0" "$SCRIPT_PATH"; fi; else mv "$temp_path" "$SCRIPT_PATH"; fi; chmod +x "$SCRIPT_PATH"; }
setup_shortcut() { local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; local BIN_DIR="${CONFIG[bin_dir]}"; if [ ! -L "$BIN_DIR/jb" ] || [ "$(readlink "$BIN_DIR/jb")" != "$SCRIPT_PATH" ]; then ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"; log_success "快捷指令 'jb' 已创建。"; fi; }
self_update() { local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; if [[ "$0" != "$SCRIPT_PATH" ]]; then return; fi; log_info "正在检查入口脚本更新..."; local temp_script="/tmp/install.sh.tmp"; if with_lock _download_self "$temp_script"; then if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then log_info "检测到新版本，正在自动更新..."; mv "$temp_script" "$SCRIPT_PATH"; chmod +x "$SCRIPT_PATH"; log_success "脚本已更新！正在重新启动..."; exec bash "$SCRIPT_PATH" "$@"; fi; rm -f "$temp_script"; else log_warning "无法连接 GitHub 检查更新。"; fi; }
download_module_to_cache() { local script_name="$1"; local local_file="${CONFIG[install_dir]}/$script_name"; local url="${CONFIG[base_url]}/$script_name"; mkdir -p "$(dirname "$local_file")"; local http_code; http_code=$(curl -sL --connect-timeout 5 --max-time 60 "$url" -o "$local_file" -w "%{http_code}"); if [ "$http_code" -eq 200 ] && [ -s "$local_file" ]; then return 0; else rm -f "$local_file"; log_warning "下载 [$script_name] 失败 (HTTP: $http_code)。"; return 1; fi; }
_update_all_modules() {
    log_info "正在并行更新所有模块缓存..."
    local scripts_to_update; scripts_to_update=$(jq -r '.menus[][] | select(.type=="item") | .action' "${CONFIG[install_dir]}/config.json")
    for script_name in $scripts_to_update; do
        ( if download_module_to_cache "$script_name"; then echo -e "  ${GREEN}✔ ${script_name}${NC}"; else echo -e "  ${RED}✖ ${script_name}${NC}"; fi ) &
    done
    wait
    log_success "所有模块缓存更新完成！"
}
update_all_modules_parallel() { with_lock _update_all_modules; }
execute_module() {
    local script_name="$1"; local display_name="$2"; local local_path="${CONFIG[install_dir]}/$script_name"
    local config_path="${CONFIG[install_dir]}/config.json"
    log_info "您选择了 [$display_name]"; if [ ! -f "$local_path" ]; then log_info "本地未找到模块，正在下载..."; if ! with_lock download_module_to_cache "$script_name"; then log_error "下载模块失败，无法执行。"; return 1; fi; fi
    chmod +x "$local_path"; local env_vars=("IS_NESTED_CALL=true")
    
    local module_key; module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')
    local has_config; has_config=$(jq --arg key "$module_key" 'has("module_configs") and .module_configs | has($key)' "$config_path")
    if [[ "$has_config" == "true" ]]; then
        # 【增强】更健壮的解析：明确排除所有 comment* 键
        while IFS='=' read -r key value; do
            env_vars+=("$(echo "WT_CONF_$key" | tr '[:lower:]' '[:upper:]')=$value")
        done < <(jq -r --arg key "$module_key" '.module_configs[$key] | to_entries | .[] | select(.key | startswith("comment") | not) | "\(.key)=\(.value)"' "$config_path")
    fi

    if [[ "$script_name" == "tools/Watchtower.sh" ]]; then
        if command -v docker &>/dev/null && docker ps -q &>/dev/null; then
            local all_labels; all_labels=$(docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | jq -s 'add | keys_unsorted | unique | .[]' | tr '\n' ',' | sed 's/,$//')
            if [ -n "$all_labels" ]; then
                env_vars+=("WT_AVAILABLE_LABELS=$all_labels")
            fi
            # 【增强】这里的解析已经是正确的，因为它直接读取数组
            local exclude_list; exclude_list=$(jq -r '.module_configs.watchtower.exclude_containers // [] | .[]' "$config_path" | tr '\n' ',' | sed 's/,$//')
            if [ -n "$exclude_list" ]; then
                env_vars+=("WT_EXCLUDE_CONTAINERS=$exclude_list")
            fi
        fi
    fi

    local exit_code=0; env "${env_vars[@]}" bash "$local_path" || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then log_success "模块 [$display_name] 执行完毕。"; elif [ "$exit_code" -eq 10 ]; then log_info "已从 [$display_name] 返回。"; else log_warning "模块 [$display_name] 执行时发生错误 (退出码: $exit_code)。"; fi
    return $exit_code
}

# --- 动态菜单核心 ---
CURRENT_MENU_NAME="MAIN_MENU"
display_menu() {
    local config_path="${CONFIG[install_dir]}/config.json"
    local header_text="🚀 VPS 一键安装入口 (v8.3)"; if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then header_text="🛠️ ${CURRENT_MENU_NAME//_/ }"; fi
    local menu_items_json; menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_items_json" | jq 'length')
    
    local max_width=${#header_text}; local names; names=$(echo "$menu_items_json" | jq -r '.[].name');
    while IFS= read -r name; do local line_width=$(( ${#name} + 4 )); if [ $line_width -gt $max_width ]; then max_width=$line_width; fi; done <<< "$names"
    local border; border=$(printf '%*s' "$((max_width + 4))" | tr ' ' '=')
    
    echo ""; echo -e "${BLUE}${border}${NC}"; echo -e "  ${header_text}"; echo -e "${BLUE}${border}${NC}";
    for i in $(seq 0 $((menu_len - 1))); do
        local name; name=$(echo "$menu_items_json" | jq -r ".[$i].name")
        echo -e " ${YELLOW}$((i+1)).${NC} $name"
    done; echo ""
    
    local prompt_text; if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 退出:"; else prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 返回:"; fi
    read -p "$(echo -e "${BLUE}${prompt_text}${NC} ")" choice
}
process_menu_selection() {
    local config_path="${CONFIG[install_dir]}/config.json"
    local menu_items_json; menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_items_json" | jq 'length')

    if [ -z "$choice" ]; then if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then log_info "已退出脚本。"; exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; return 10; fi; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then log_warning "无效选项，请重新输入。"; return 0; fi
    
    local item_json; item_json=$(echo "$menu_items_json" | jq ".[$((choice-1))]")
    local type; type=$(echo "$item_json" | jq -r ".type"); local name; name=$(echo "$item_json" | jq -r ".name"); local action; action=$(echo "$item_json" | jq -r ".action")
    
    case "$type" in
        item) execute_module "$action" "$name"; return $?;;
        submenu | back) CURRENT_MENU_NAME=$action; return 10;;
        func) "$action"; return 0;;
    esac
}

# ====================== 主程序入口 ======================
main() {
    mkdir -p "${CONFIG[install_dir]}"
    local config_path="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$config_path" ]; then
        echo -e "${BLUE}[信息]${NC} 未找到配置文件，正在从 GitHub 下载默认配置..."
        if ! curl -fsSL "${CONFIG[base_url]}/config.json" -o "$config_path"; then
            echo -e "${RED}[错误]${NC} 下载默认配置文件失败！请检查网络或仓库地址。"
            exit 1
        fi
        echo -e "${GREEN}[成功]${NC} 默认配置文件已下载至 $config_path"
    fi

    if ! command -v jq &>/dev/null; then check_and_install_dependencies; fi
    load_config
    setup_logging
    log_info "脚本启动 (v8.3)"
    check_and_install_dependencies
    
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    if [ ! -f "$SCRIPT_PATH" ]; then with_lock save_entry_script; fi
    with_lock setup_shortcut; self_update

    while true; do
        clear 2>/dev/null || true; display_menu; local exit_code=0
        process_menu_selection || exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            while read -r -t 0; do :; done; read -p "$(echo -e "${BLUE}按回车键继续...${NC}")"
        fi
    done
}

main "$@"
