#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v69.2 - UI Unification)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v69.2"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LC_ALL=C.utf8

# --- [核心架构]: 智能自引导启动器 ---
INSTALL_DIR="/opt/vps_install_modules"
FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"
CONFIG_PATH="${INSTALL_DIR}/config.json"

if [[ "$0" != "$FINAL_SCRIPT_PATH" ]]; then
    
    BLUE='\033[0;34m'; NC='\033[0m'; GREEN='\033[0;32m';
    echo_info() { echo -e "${BLUE}[启动器]${NC} $1"; }
    echo_success() { echo -e "${GREEN}[启动器]${NC} $1"; }
    echo_error() { echo -e "\033[0;31m[启动器错误]\033[0m $1" >&2; exit 1; }

    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [[ "${FORCE_REFRESH}" == "true" ]]; then
        echo_info "正在执行首次安装或强制刷新..."
        if ! command -v curl &> /dev/null; then echo_error "curl 命令未找到, 请先安装."; fi
        
        sudo mkdir -p "$INSTALL_DIR"
        BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        
        temp_install="/tmp/install.sh.$$"
        temp_config="/tmp/config.json.$$"
        
        echo_info "正在下载最新的主程序..."
        if ! curl -fsSL "${BASE_URL}/install.sh?_=$(date +%s)" -o "$temp_install"; then echo_error "下载主程序失败."; fi
        
        echo_info "正在下载最新的配置文件..."
        if ! curl -fsSL "${BASE_URL}/config.json?_=$(date +%s)" -o "$temp_config"; then echo_error "下载配置文件失败."; fi
        
        sudo mv "$temp_install" "$FINAL_SCRIPT_PATH"
        sudo chmod +x "$FINAL_SCRIPT_PATH"
        sudo mv "$temp_config" "$CONFIG_PATH"
        
        echo_info "正在创建/更新快捷指令 'jb'..."
        BIN_DIR="/usr/local/bin"
        sudo bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"
        
        echo_success "安装/更新完成！"
    fi
    
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
fi

# --- 主程序逻辑 ---

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
# --- 默认配置 ---
declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]="/tmp/vps_install_modules.lock"
CONFIG[enable_auto_clear]="false"
CONFIG[timezone]="Asia/Shanghai"
# --- 控制变量定义 ---
AUTO_YES="false"
if [[ "${NON_INTERACTIVE:-}" == "true" || "${YES_TO_ALL:-}" == "true" ]]; then AUTO_YES="true"; fi
# --- 辅助函数 & 日志系统 ---
sudo_preserve_env() { sudo -E "$@"; }
setup_logging() { :; }
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info() { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "$(log_timestamp) ${RED}[错误]${NC} $1" >&2; exit 1; }

# --- 配置加载 ---
load_config() {
    export LC_ALL=C.utf8
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"; if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
        while IFS='=' read -r key value; do value="${value#\"}"; value="${value%\"}"; CONFIG[$key]="$value"; done < <(jq -r 'to_entries|map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not)))|map("\(.key)=\(.value)")|.[]' "$CONFIG_FILE")
        CONFIG[dependencies]="$(jq -r '.dependencies.common // ""' "$CONFIG_FILE")"
        CONFIG[lock_file]="$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$CONFIG_FILE")"
        CONFIG[enable_auto_clear]=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE")
        CONFIG[timezone]=$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE")
    fi
}
# --- 智能依赖处理 ---
check_and_install_dependencies() {
    export LC_ALL=C.utf8
    local missing_deps=(); local deps=(${CONFIG[dependencies]}); for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done; if [ ${#missing_deps[@]} -gt 0 ]; then log_warning "缺少核心依赖: ${missing_deps[*]}"; local pm; pm=$(command -v apt-get &>/dev/null && echo "apt" || (command -v dnf &>/dev/null && echo "dnf" || (command -v yum &>/dev/null && echo "yum" || echo "unknown"))); if [ "$pm" == "unknown" ]; then log_error "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"; fi; if [[ "$AUTO_YES" == "true" ]]; then choice="y"; else read -p "$(echo -e "${YELLOW}是否尝试自动安装? (y/N): ${NC}")" choice < /dev/tty; fi; if [[ "$choice" =~ ^[Yy]$ ]]; then log_info "正在使用 $pm 安装..."; local update_cmd=""; if [ "$pm" == "apt" ]; then update_cmd="sudo apt-get update"; fi; if ! ($update_cmd && sudo "$pm" install -y "${missing_deps[@]}"); then log_error "依赖安装失败."; fi; log_success "依赖安装完成！"; else log_error "用户取消安装."; fi; fi
}
# --- 核心功能 ---
_download_self() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/install.sh?_=$(date +%s)" -o "$1"; }
self_update() { 
    export LC_ALL=C.utf8; local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; 
    if [[ "$0" != "$SCRIPT_PATH" ]]; then return; fi; 
    
    local temp_script="/tmp/install.sh.tmp.$$"; if ! _download_self "$temp_script"; then 
        log_warning "主程序 (install.sh) 更新检查失败 (无法连接)。"; rm -f "$temp_script"; return;
    fi
    if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then 
        log_success "主程序 (install.sh) 已更新。正在无缝重启..."
        sudo mv "$temp_script" "$SCRIPT_PATH"; sudo chmod +x "$SCRIPT_PATH"; 
        flock -u 200; rm -f "${CONFIG[lock_file]}"; trap - EXIT
        exec sudo -E bash "$SCRIPT_PATH" "$@"
    fi; rm -f "$temp_script"; 
}
download_module_to_cache() { 
    export LC_ALL=C.utf8
    local script_name="$1"
    
    local local_file="${CONFIG[install_dir]}/$script_name"
    local tmp_file="/tmp/$(basename "$script_name").$$"
    local url="${CONFIG[base_url]}/${script_name}?_=$(date +%s)"

    local http_code; http_code=$(curl -fsSL --connect-timeout 5 --max-time 60 -w "%{http_code}" -o "$tmp_file" "$url")
    local curl_exit_code=$?

    if [ "$curl_exit_code" -ne 0 ] || [ "$http_code" -ne 200 ] || [ ! -s "$tmp_file" ]; then
        log_error "模块 (${script_name}) 下载失败 (HTTP: $http_code, Curl: $curl_exit_code)"
        rm -f "$tmp_file"; return 1
    fi

    if [ -f "$local_file" ] && cmp -s "$local_file" "$tmp_file"; then
        rm -f "$tmp_file"; return 0
    else
        log_success "模块 (${script_name}) 已更新。"
        sudo mkdir -p "$(dirname "$local_file")"
        sudo mv "$tmp_file" "$local_file"
        return 0
    fi
}
_update_all_modules() {
    export LC_ALL=C.utf8
    local scripts_to_update
    scripts_to_update=$(jq -r '.menus[] | select(type == "object") | (if .items then .items[] else .[] end) | select(.type == "item").action' "${CONFIG[install_dir]}/config.json")
    if [[ -z "$scripts_to_update" ]]; then return; fi

    local pids=()
    for script_name in $scripts_to_update; do
        download_module_to_cache "$script_name" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
}
force_update_all() {
    export LC_ALL=C.utf8
    self_update
    _update_all_modules
    log_success "检查完成！"
}
confirm_and_force_update() {
    export LC_ALL=C.utf8
    log_warning "警告: 这将从 GitHub 强制拉取所有最新脚本和【主配置文件 config.json】。"
    log_warning "您对 config.json 的【所有本地修改都将丢失】！这是一个恢复出厂设置的操作。"
    read -p "$(echo -e "${RED}此操作不可逆，请输入 'yes' 确认继续: ${NC}")" choice < /dev/tty
    if [[ "$choice" == "yes" ]]; then
        log_info "开始强制完全重置..."
        local temp_config="/tmp/config.json.$$"
        log_info "正在强制更新 config.json..."
        local config_url="${CONFIG[base_url]}/config.json?_=$(date +%s)"
        if ! curl -fsSL "$config_url" -o "$temp_config"; then log_error "下载最新的 config.json 失败。"; fi
        sudo mv "$temp_config" "${CONFIG[install_dir]}/config.json"
        log_success "config.json 已重置为最新版本。"
        log_info "正在重新加载配置..."; load_config
        force_update_all
    else 
        log_info "操作已取消."; fi
    return 10 
}
uninstall_script() {
    log_warning "警告: 这将从您的系统中彻底移除本脚本及其所有组件！"
    log_warning "将要删除的包括:"; log_warning "  - 安装目录: ${CONFIG[install_dir]}"; log_warning "  - 快捷方式: ${CONFIG[bin_dir]}/jb"
    read -p "$(echo -e "${RED}这是一个不可逆的操作, 您确定要继续吗? (请输入 'yes' 确认): ${NC}")" choice < /dev/tty
    if [[ "$choice" == "yes" ]]; then
        log_info "开始卸载...";
        sudo rm -rf "${CONFIG[install_dir]}"; log_success "安装目录已移除."
        sudo rm -f "${CONFIG[bin_dir]}/jb"; log_success "快捷方式已移除."
        log_success "脚本已成功卸载."; log_info "再见！";
        exit 0
    else log_info "卸载操作已取消."; return 10; fi
}
### [ADDED] ###
# 安全地引用参数以传递给子 shell 的辅助函数
_quote_args() {
    for arg in "$@"; do
        printf "%q " "$arg"
    done
}
execute_module() {
    export LC_ALL=C.utf8; local script_name="$1"; local display_name="$2"
    shift 2 ### [ADDED] ### 移除 script_name 和 display_name，剩下的 $@ 是要传递给模块的额外参数
    
    local local_path="${CONFIG[install_dir]}/$script_name"
    log_info "您选择了 [$display_name]"; if [ ! -f "$local_path" ]; then log_info "正在下载模块..."; if ! download_module_to_cache "$script_name"; then log_error "下载失败."; return 1; fi; fi
    local env_exports="export IS_NESTED_CALL=true; export FORCE_COLOR=true; export JB_ENABLE_AUTO_CLEAR='${CONFIG[enable_auto_clear]}'; export JB_TIMEZONE='${CONFIG[timezone]}';"
    local module_key; module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')
    local config_path="${CONFIG[install_dir]}/config.json"
    local module_config_json; module_config_json=$(jq -r --arg key "$module_key" 'if has("module_configs") and (.module_configs | has($key)) and (.module_configs[$key] | type == "object") then .module_configs[$key] | tojson else "null" end' "$config_path")

    if [[ "$module_config_json" != "null" ]]; then
        local prefix; prefix=$(basename "$script_name" .sh | tr '[:lower:]' '[:upper:]')
        local jq_script='to_entries | .[] | select((.key | startswith("comment") | not) and .value != null) | .key as $k | .value as $v | if ($v|type) == "array" then [$k, ($v|join(","))] elif ($v|type) | IN("string", "number", "boolean") then [$k, $v] else empty end | @tsv'
        while IFS=$'\t' read -r key value; do
            if [[ -n "$key" ]]; then
                local key_upper; key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
                env_exports+=$(printf "export %s_CONF_%s=%q;" "$prefix" "$key_upper" "$value")
            fi
        done < <(echo "$module_config_json" | jq -r "$jq_script")
    elif jq -e --arg key "$module_key" 'has("module_configs") and .module_configs | has($key)' "$config_path" > /dev/null; then
        log_warning "在 config.json 中找到模块 '${module_key}' 的配置, 但其格式不正确(不是一个对象), 已跳过加载."
    fi
    
    if command -v docker &>/dev/null && docker ps -q &>/dev/null; then
        local all_labels; all_labels=$(docker inspect $(docker ps -q) --format '{{json .Config.Labels}}' 2>/dev/null | jq -s 'add | keys_unsorted | unique | .[]' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$all_labels" ]; then env_exports+="export JB_DOCKER_LABELS='$all_labels';"; fi
    fi

    local exit_code=0
    ### [MODIFIED] ### 将额外参数安全地传递给子脚本
    local extra_args_str=$(_quote_args "$@")
    sudo bash -c "$env_exports bash '$local_path' $extra_args_str" < /dev/tty || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then log_success "模块 [$display_name] 执行完毕."; elif [ "$exit_code" -eq 10 ]; then log_info "已从 [$display_name] 返回."; else log_warning "模块 [$display_name] 执行出错 (码: $exit_code)."; fi
    return $exit_code
}
generate_line() { local len=$1; local char="─"; local line=""; for ((i=0; i<len; i++)); do line+="$char"; done; echo "$line"; }
display_menu() {
    export LC_ALL=C.utf8; if [[ "${CONFIG[enable_auto_clear]}" == "true" ]]; then clear 2>/dev/null || true; fi;
    local config_path="${CONFIG[install_dir]}/config.json"
    local menu_json; menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local main_title_text; main_title_text=$(echo "$menu_json" | jq -r '.title // "🚀 VPS 一键安装脚本"')
    local plain_title; plain_title=$(echo -e "$main_title_text" | sed 's/\x1b\[[0-9;]*m//g'); local total_chars=${#plain_title}; local ascii_chars_only; ascii_chars_only=$(echo "$main_title_text" | tr -dc '[ -~]'); local ascii_count=${#ascii_chars_only}; local non_ascii_count=$((total_chars - ascii_count)); local title_width=$((ascii_count + non_ascii_count * 2)); local box_width=$((title_width + 10)); local top_bottom_border; top_bottom_border=$(generate_line "$box_width"); local padding_total=$((box_width - title_width)); local padding_left=$((padding_total / 2));
    echo ""; echo -e "${CYAN}╭${top_bottom_border}╮${NC}"; local left_padding; left_padding=$(printf '%*s' "$padding_left"); local right_padding; right_padding=$(printf '%*s' "$((padding_total - padding_left))"); echo -e "${CYAN}│${left_padding}${main_title_text}${right_padding}${CYAN}│${NC}"; echo -e "${CYAN}╰${top_bottom_border}╯${NC}";
    local i=1
    echo "$menu_json" | jq -r '.items[] | [.name, (.icon // "›")] | @tsv' | while IFS=$'\t' read -r name icon; do
        printf "  ${YELLOW}%2d.${NC} %s %s\n" "$i" "$icon" "$name"; i=$((i+1));
    done
    local menu_len; menu_len=$(echo "$menu_json" | jq -r '.items | length')
    local line_separator; line_separator=$(generate_line "$((box_width + 2))"); echo -e "${BLUE}${line_separator}${NC}";
    local exit_hint="退出"; if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then exit_hint="返回"; fi;
    local prompt_text=" └──> 请选择 [1-${menu_len}], 或 [Enter] ${exit_hint}: ";
    if [ "$AUTO_YES" == "true" ]; then choice=""; echo -e "${BLUE}${prompt_text}${NC} [非交互模式]"; else read -p "$(echo -e "${BLUE}${prompt_text}${NC}")" choice < /dev/tty; fi
}
process_menu_selection() {
    export LC_ALL=C.utf8; local config_path="${CONFIG[install_dir]}/config.json"
    local menu_json; menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path")
    local menu_len; menu_len=$(echo "$menu_json" | jq -r '.items | length')
    if [ -z "$choice" ]; then if [ "$CURRENT_MENU_NAME" == "MAIN_MENU" ]; then exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; return 10; fi; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then log_warning "无效选项."; return 10; fi
    local item_json; item_json=$(echo "$menu_json" | jq -r --argjson idx "$((choice - 1))" '.items[$idx]')
    if [[ -z "$item_json" || "$item_json" == "null" ]]; then log_warning "菜单项配置无效或不完整。"; return 10; fi
    local type; type=$(echo "$item_json" | jq -r ".type"); local name; name=$(echo "$item_json" | jq -r ".name"); local action; action=$(echo "$item_json" | jq -r ".action")
    case "$type" in item) execute_module "$action" "$name"; return $?;; submenu) CURRENT_MENU_NAME=$action; return 10;; func) "$action"; return $?;; esac
}

main() {
    exec 200>"${CONFIG[lock_file]}"
    if ! flock -n 200; then echo -e "\033[0;33m[警告] 检测到另一实例正在运行."; exit 1; fi
    trap 'flock -u 200; rm -f "${CONFIG[lock_file]}"; log_info "脚本已退出."' EXIT
    
    if ! command -v flock >/dev/null || ! command -v jq >/dev/null; then check_and_install_dependencies; fi
    load_config
    
    if [[ $# -gt 0 ]]; then
        local command="$1"; shift
        case "$command" in
            ### [MODIFIED] ### 使 update 命令更安全，只更新脚本，不覆盖 config.json
            update)
                log_info "正在以 Headless 模式安全更新所有脚本 (config.json 不会被覆盖)..."
                force_update_all
                log_success "所有脚本更新检查完成。"
                exit 0
                ;;
            uninstall)
                log_info "正在以 Headless 模式执行卸载..."; uninstall_script; exit 0
                ;;
            *)
                local item_json; item_json=$(jq -r --arg cmd "$command" '.menus[] | select(type == "object") | (if .items then .items[] else .[] end) | select(.type != "submenu") | select(.action == $cmd or (.name | ascii_downcase | startswith($cmd)))' "${CONFIG[install_dir]}/config.json" | head -n 1)
                if [[ -n "$item_json" ]]; then
                    local action_to_run; action_to_run=$(echo "$item_json" | jq -r '.action'); local display_name; display_name=$(echo "$item_json" | jq -r '.name'); local type; type=$(echo "$item_json" | jq -r '.type')
                    log_info "正在以 Headless 模式执行: ${display_name}"
                    if [[ "$type" == "func" ]]; then "$action_to_run" "$@"; else execute_module "$action_to_run" "$display_name" "$@"; fi
                    exit $?
                else
                    log_error "未知命令: $command"; fi
                ;;
        esac
    fi

    log_info "脚本启动 (${SCRIPT_VERSION})"
    echo -ne "$(log_timestamp) ${BLUE}[信息]${NC} 正在智能更新... 🕛"; sleep 0.5; echo -ne "\r$(log_timestamp) ${BLUE}[信息]${NC} 正在智能更新... 🔄\n"
    force_update_all
    
    CURRENT_MENU_NAME="MAIN_MENU"
    while true; do
        display_menu
        local exit_code=0
        process_menu_selection || exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            while read -r -t 0; do :; done
            read -p "$(echo -e "${BLUE}按回车键继续...${NC}")" < /dev/tty
        fi
    done
}

main "$@"
