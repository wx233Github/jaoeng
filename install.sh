#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v26.0 - 正确语法稳定版)
# =============================================================

# --- 严格模式与环境设定 ---
set -eo pipefail
export LC_ALL=C.utf8

# --- [核心改造 1/2]: 使用 flock 和 tee 实现原子锁、自引导和自动化日志 (正确语法) ---
LOCK_FILE="/tmp/vps_install_modules.lock"
# 检查一个特殊环境变量，如果未设置，则执行加锁引导
if [[ -z "$_JAE_LOCKED_AND_LOGGED" ]]; then
    
    export _JAE_LOCKED_AND_LOGGED=true
    export FORCE_COLOR=true
    
    MAIN_SCRIPT_PATH=$(mktemp)
    trap 'rm -f "$MAIN_SCRIPT_PATH"' EXIT
    cat > "$MAIN_SCRIPT_PATH"
    
    LOG_FILE="/var/log/jb_launcher.log"
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE"
    sudo chown "$(whoami)" "$LOG_FILE"

    # 定义要由 flock 在获取锁后执行的命令
    # 这是一个多行字符串，将在一个新的 shell 中执行
    FLOCK_COMMAND='
        # 从参数列表中提取 main_script_path 和 log_file
        main_script_path="$1"
        log_file="$2"
        # 使用 shift 移除前两个参数，剩下的 "$@" 就是原始参数
        shift 2
        
        # 终极执行命令:
        # sudo -E 保留环境变量, bash 执行主脚本并传递原始参数
        # 2>&1 | sudo tee -a 将所有输出追加到日志文件和屏幕
        sudo -E bash "$main_script_path" "$@" 2>&1 | sudo tee -a "$log_file"
    '
    
    # 使用 exec flock 重新执行自身:
    # 1. exec flock -n "$LOCK_FILE": 以非阻塞方式获取文件锁。
    # 2. sh -c "$FLOCK_COMMAND": flock 成功后，启动一个新 shell 来执行我们定义好的命令。
    # 3. sh "$MAIN_SCRIPT_PATH" "$LOG_FILE" "$@":
    #    - 'sh' 成为新 shell 内部的 $0
    #    - "$MAIN_SCRIPT_PATH" 成为 $1
    #    - "$LOG_FILE" 成为 $2
    #    - "$@" 成为 $3, $4, ...
    exec flock -n "$LOCK_FILE" sh -c "$FLOCK_COMMAND" sh "$MAIN_SCRIPT_PATH" "$LOG_FILE" "$@"
    
    # 如果 flock 获取锁失败，上面的命令会以非零状态退出，此处的 echo 不会执行
    echo "错误：检测到另一脚本实例正在运行。" >&2
    exit 1
fi
# --- 引导结束。从这里开始，是运行在文件锁和日志管道保护下的主脚本逻辑 ---


# --- [核心改造 2/2]: 主业务逻辑 ---

# --- 颜色定义 ---
if [ -t 1 ] || [[ "$FORCE_COLOR" == "true" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# --- 默认配置 ---
declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[log_file]="/var/log/jb_launcher.log"
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]=$LOCK_FILE 
CONFIG[enable_auto_clear]="false"
CONFIG[timezone]="Asia/Shanghai"

# --- 控制变量定义 ---
AUTO_YES="false"
if [[ "${NON_INTERACTIVE:-}" == "true" || "${YES_TO_ALL:-}" == "true" ]]; then
    AUTO_YES="true"
fi

# --- 辅助函数 & 日志系统 ---
sudo_preserve_env() { sudo -E "$@"; }
setup_logging() { :; }

log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info() { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "$(log_timestamp) ${RED}[错误]${NC} $1" >&2; exit 1; }

# --- 并发锁机制 (已由 flock 取代) ---
acquire_lock() { :; }
release_lock() { :; }

# --- 配置加载 ---
load_config() {
    export LC_ALL=C.utf8
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"; if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        while IFS='=' read -r key value; do value="${value#\"}"; value="${value%\"}"; CONFIG[$key]="$value"; done < <(jq -r 'to_entries|map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not)))|map("\(.key)=\(.value)")|.[]' "$CONFIG_FILE")
        CONFIG[dependencies]="$(jq -r '.dependencies.common | @sh' "$CONFIG_FILE" | tr -d "'")"
        CONFIG[enable_auto_clear]=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE")
        CONFIG[timezone]=$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE")
    fi
}

# --- 智能依赖处理 ---
check_and_install_dependencies() {
    export LC_ALL=C.utf8
    local missing_deps=(); local deps=(${CONFIG[dependencies]}); for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done; if [ ${#missing_deps[@]} -gt 0 ]; then log_warning "缺少核心依赖: ${missing_deps[*]}"; local pm; pm=$(command -v apt-get &>/dev/null && echo "apt" || (command -v dnf &>/dev/null && echo "dnf" || (command -v yum &>/dev/null && echo "yum" || echo "unknown"))); if [ "$pm" == "unknown" ]; then log_error "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"; fi; if [[ "$AUTO_YES" == "true" ]]; then choice="y"; else read -p "$(echo -e "${YELLOW}是否尝试自动安装? (y/N): ${NC}")" choice < /dev/tty; fi; if [[ "$choice" =~ ^[Yy]$ ]]; then log_info "正在使用 $pm 安装..."; local update_cmd=""; if [ "$pm" == "apt" ]; then update_cmd="sudo apt-get update"; fi; if ! ($update_cmd && sudo "$pm" install -y "${missing_deps[@]}"); then log_error "依赖安装失败。"; fi; log_success "依赖安装完成！"; else log_error "用户取消安装。"; fi; fi
}

# --- 核心功能 ---
_download_self() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/install.sh?_=$(date +%s)" -o "$1"; }
save_entry_script() { 
    export LC_ALL=C.utf8; sudo mkdir -p "${CONFIG[install_dir]}"; local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; log_info "正在保存入口脚本..."; 
    local temp_path="/tmp/install.sh.self"; if ! _download_self "$temp_path"; then 
        log_error "无法从 GitHub 下载脚本以保存。";
    else 
        sudo mv "$temp_path" "$SCRIPT_PATH"; 
    fi; 
    sudo chmod +x "$SCRIPT_PATH"; 
}
setup_shortcut() { 
    export LC_ALL=C.utf8; local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; local BIN_DIR="${CONFIG[bin_dir]}"; 
    if [ ! -L "$BIN_DIR/jb" ] || [ "$(readlink "$BIN_DIR/jb")" != "$SCRIPT_PATH" ]; then 
        sudo ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"; log_success "快捷指令 'jb' 已创建。"; 
    fi; 
}
self_update() { 
    export LC_ALL=C.utf8; local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; if [[ "$0" != "$SCRIPT_PATH" ]]; then return; fi; log_info "检查主脚本更新..."; 
    local temp_script="/tmp/install.sh.tmp"; if _download_self "$temp_script"; then 
        if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then 
            log_info "检测到新版本..."; sudo mv "$temp_script" "$SCRIPT_PATH"; sudo chmod +x "$SCRIPT_PATH"; 
            log_success "主脚本更新成功！正在重启..."; exec sudo -E bash "$SCRIPT_PATH" "$@" 
        fi; rm -f "$temp_script"; 
    else log_warning "无法连接 GitHub 检查更新。"; fi; 
}
download_module_to_cache() { 
    export LC_ALL=C.utf8; sudo mkdir -p "$(dirname "${CONFIG[install_dir]}/$1")"; 
    local script_name="$1"; local force_update="${2:-false}"; local local_file="${CONFIG[install_dir]}/$script_name"; 
    local url="${CONFIG[base_url]}/$script_name"; if [ "$force_update" = "true" ]; then url="${url}?_=$(date +%s)"; log_info "  ↳ 强制刷新: $script_name"; fi
    local http_code; http_code=$(curl -sL --connect-timeout 5 --max-time 60 "$url" -o "$local_file" -w "%{http_code}"); 
    if [ "$http_code" -eq 200 ] && [ -s "$local_file" ]; then return 0; else sudo rm -f "$local_file"; log_warning "下载 [$script_name] 失败 (HTTP: $http_code)。"; return 1; fi; 
}

_update_all_modules() {
    export LC_ALL=C.utf8; local force_update="${1:-false}"; log_info "正在并行更新所有模块..."; 
    local scripts_to_update
    scripts_to_update=$(jq -r '.menus[] | select(type=="array") | .[] | select(.type=="item") | .action' "${CONFIG[install_dir]}/config.json")
    for script_name in $scripts_to_update; do ( if download_module_to_cache "$script_name" "$force_update"; then echo -e "  ${GREEN}✔ ${script_name}${NC}"; else echo -e "  ${RED}✖ ${script_name}${NC}"; fi ) & done
    wait; log_success "所有模块更新完成！"
}

force_update_all() {
    export LC_ALL=C.utf8; log_info "开始强制更新流程..."; self_update; log_info "步骤 2: 强制更新所有子模块..."; _update_all_modules "true";
}
confirm_and_force_update() {
    export LC_ALL=C.utf8; if [[ "$AUTO_YES" == "true" ]]; then choice="y"; else read -p "$(echo -e "${YELLOW}这将强制拉取最新版本，继续吗？(Y/回车 确认, N 取消): ${NC}")" choice < /dev/tty; fi
    if [[ "$choice" =~ ^[Yy]$ || -z "$choice" ]]; then force_update_all; else log_info "强制更新已取消。"; fi
}

execute_module() {
    export LC_ALL=C.utf8; local script_name="$1"; local display_name="$2"; local local_path="${CONFIG[install_dir]}/$script_name"; local config_path="${CONFIG[install_dir]}/config.json";
    log_info "您选择了 [$display_name]"; if [ ! -f "$local_path" ]; then log_info "正在下载模块..."; if ! download_module_to_cache "$script_name"; then log_error "下载失败。"; return 1; fi; fi
    sudo chmod +x "$local_path"
    
    local env_exports="export IS_NESTED_CALL=true; export JB_ENABLE_AUTO_CLEAR='${CONFIG[enable_auto_clear]}'; export JB_TIMEZONE='${CONFIG[timezone]}';"
    local module_key; module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')
    
    if jq -e --arg key "$module_key" 'has("module_configs") and .module_configs | has($key)' "$config_path" > /dev/null; then
        local exports
        exports=$(jq -r --arg key "$module_key" '
            .module_configs[$key] | to_entries | .[] | 
            select(
                (.key | startswith("comment") | not) and 
                (.value | type | IN("string", "number", "boolean"))
            ) | 
            "export WT_CONF_\(.key | ascii_upcase)=\(.value|@sh);"
        ' "$config_path")
        env_exports+="$exports"
    fi
    
    if [[ "$script_name" == "tools/Watchtower.sh" ]] && command -v docker &>/dev/null && docker ps -q &>/dev/null; then
        local all_labels; all_labels=$(docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | jq -s 'add | keys_unsorted | unique | .[]' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$all_labels" ]; then env_exports+="export WT_AVAILABLE_LABELS='$all_labels';"; fi
        
        local exclude_list; exclude_list=$(jq -r '.module_configs.watchtower.exclude_containers // [] | .[]' "$config_path" | tr '\n' ',' | sed 's/,$//')
        if [ -n "$exclude_list" ]; then env_exports+="export WT_EXCLUDE_CONTAINERS='$exclude_list';"; fi
    fi
    
    local exit_code=0
    sudo bash -c "$env_exports bash $local_path" < /dev/tty || exit_code=$?
    
    if [ "$exit_code" -eq 0 ]; then log_success "模块 [$display_name] 执行完毕。"; elif [ "$exit_code" -eq 10 ]; then log_info "已从 [$display_name] 返回。"; else log_warning "模块 [$display_name] 执行出错 (码: $exit_code)。"; fi
    return $exit_code
}

display_menu() {
    export LC_ALL=C.utf8; if [[ "${CONFIG[enable_auto_clear]}" == "true" ]]; then clear 2>/dev/null || true; fi
    local config_path="${CONFIG[install_dir]}/config.json"; local header_text="🚀 VPS 一键安装入口 (v26.0)"; if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then header_text="🛠️ ${CURRENT_MENU_NAME//_/ }"; fi
    local menu_items_json; menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_items_json" | jq 'length')
    local max_width=${#header_text}; local names; names=$(echo "$menu_items_json" | jq -r '.[].name');
    while IFS= read -r name; do local line_width=$(( ${#name} + 4 )); if [ $line_width -gt $max_width ]; then max_width=$line_width; fi; done <<< "$names"
    local border; border=$(printf '%*s' "$((max_width + 4))" | tr ' ' '=')
    echo ""; echo -e "${BLUE}${border}${NC}"; echo -e "  ${header_text}"; echo -e "${BLUE}${border}${NC}";
    for i in $(seq 0 $((menu_len - 1))); do local name; name=$(echo "$menu_items_json" | jq -r ".[$i].name"); echo -e " ${YELLOW}$((i+1)).${NC} $name"; done; echo ""
    local prompt_text; if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 退出:"; else prompt_text="请选择操作 (1-${menu_len}) 或按 Enter 返回:"; fi
    
    if [ "$AUTO_YES" == "true" ]; then
        choice=""
        echo -e "${BLUE}${prompt_text}${NC} [非交互模式，自动选择默认选项]"
    else
        read -p "$(echo -e "${BLUE}${prompt_text}${NC} ")" choice < /dev/tty
    fi
}
process_menu_selection() {
    export LC_ALL=C.utf8; local config_path="${CONFIG[install_dir]}/config.json"
    local menu_items_json; menu_items_json=$(jq --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_items_json" | jq 'length')
    if [ -z "$choice" ]; then if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then log_info "已退出脚本。"; exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; return 10; fi; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then log_warning "无效选项。"; return 0; fi
    local item_json; item_json=$(echo "$menu_items_json" | jq ".[$((choice-1))]")
    local type; type=$(echo "$item_json" | jq -r ".type"); local name; name=$(echo "$item_json" | jq -r ".name"); local action; action=$(echo "$item_json" | jq -r ".action")
    case "$type" in item) execute_module "$action" "$name"; return $?;; submenu | back) CURRENT_MENU_NAME=$action; return 10;; func) "$action"; return 0;; esac
}

main() {
    export LC_ALL=C.utf8
    local CACHE_BUSTER=""
    
    if [[ "${FORCE_REFRESH}" == "true" ]]; then
        CACHE_BUSTER="?_=$(date +%s)"
        log_info "强制刷新模式：将强制拉取所有最新文件。"
        sudo rm -f "${CONFIG[install_dir]}/config.json" 2>/dev/null || true
    fi
    
    setup_logging
    
    # 锁机制已由顶层 flock 处理，不再需要 acquire_lock 和 trap
    
    sudo mkdir -p "${CONFIG[install_dir]}"
    local config_path="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$config_path" ]; then
        log_info "未找到配置，正在下载..."
        if ! curl -fsSL "${CONFIG[base_url]}/config.json${CACHE_BUSTER}" -o "$config_path"; then
            log_error "下载 config.json 失败！"
        fi
        log_success "已下载 config.json。"
    fi
    
    if ! command -v jq &>/dev/null; then
        check_and_install_dependencies
    fi
    
    load_config
    
    log_info "脚本启动 (v26.0 - 正确语法稳定版)"
    
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
        if [ "$exit_code" -ne 10 ] && [ "$AUTO_YES" != "true" ]; then
            while read -r -t 0; do :; done
            read -p "$(echo -e "${BLUE}按回车键继续...${NC}")" < /dev/tty
        fi
    done
}

main "$@"
