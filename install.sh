#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v73.8 - Final Fix)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v73.8"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
if locale -a | grep -q "C.UTF-8"; then export LC_ALL=C.UTF-8; else export LC_ALL=C; fi

# --- [核心架构]: 智能自引导启动器 ---
INSTALL_DIR="/opt/vps_install_modules"; FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"; CONFIG_PATH="${INSTALL_DIR}/config.json"; UTILS_PATH="${INSTALL_DIR}/utils.sh"
if [ "$0" != "$FINAL_SCRIPT_PATH" ]; then
    STARTER_BLUE='\033[0;34m'; STARTER_GREEN='\033[0;32m'; STARTER_RED='\033[0;31m'; STARTER_NC='\033[0m'; echo_info() { echo -e "${STARTER_BLUE}[启动器]${STARTER_NC} $1"; }; echo_success() { echo -e "${STARTER_GREEN}[启动器]${STARTER_NC} $1"; }; echo_error() { echo -e "${STARTER_RED}[启动器错误]${STARTER_NC} $1" >&2; exit 1; }
    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH}" = "true" ]; then
        echo_info "正在执行首次安装或强制刷新..."; if ! command -v curl &> /dev/null; then echo_error "curl 命令未找到, 请先安装."; fi; sudo mkdir -p "$INSTALL_DIR"; BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        declare -A core_files=( ["主程序"]="install.sh" ["配置文件"]="config.json" ["工具库"]="utils.sh" ); for name in "${!core_files[@]}"; do file_path="${core_files[$name]}"; echo_info "正在下载最新的 ${name} (${file_path})..."; temp_file="/tmp/$(basename "${file_path}").$$"; if ! curl -fsSL "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then echo_error "下载 ${name} 失败。"; fi; sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"; done
        sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH"; echo_info "正在创建/更新快捷指令 'jb'..."; BIN_DIR="/usr/local/bin"; sudo bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"; echo_success "安装/更新完成！"
    fi
    echo -e "${STARTER_BLUE}────────────────────────────────────────────────────────────${STARTER_NC}"; echo ""; exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
fi

# --- 主程序逻辑 ---
if [ -f "$UTILS_PATH" ]; then source "$UTILS_PATH"; else echo "致命错误: 通用工具库 $UTILS_PATH 未找到！" >&2; exit 1; fi
declare -A CONFIG; CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"; CONFIG[install_dir]="/opt/vps_install_modules"; CONFIG[bin_dir]="/usr/local/bin"; CONFIG[dependencies]='curl cmp ln dirname flock jq'; CONFIG[lock_file]="/tmp/vps_install_modules.lock"; CONFIG[enable_auto_clear]="false"; CONFIG[timezone]="Asia/Shanghai"; AUTO_YES="false"; if [ "${NON_INTERACTIVE:-}" = "true" ] || [ "${YES_TO_ALL:-}" = "true" ]; then AUTO_YES="true"; fi
load_config() { CONFIG_FILE="${CONFIG[install_dir]}/config.json"; if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then while IFS='=' read -r key value; do value="${value#\"}"; value="${value%\"}"; CONFIG[$key]="$value"; done < <(jq -r 'to_entries | map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not))) | map("\(.key)=\(.value)") | .[]' "$CONFIG_FILE"); CONFIG[dependencies]="$(jq -r '.dependencies.common // "curl cmp ln dirname flock jq"' "$CONFIG_FILE")"; CONFIG[lock_file]="$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$CONFIG_FILE")"; CONFIG[enable_auto_clear]=$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE")"; CONFIG[timezone]=$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE")"; fi; }
check_and_install_dependencies() { local missing_deps=(); local deps=(${CONFIG[dependencies]}); for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done; if [ ${#missing_deps[@]} -gt 0 ]; then log_warn "缺少核心依赖: ${missing_deps[*]}"; local pm; pm=$(command -v apt-get &>/dev/null && echo "apt" || (command -v dnf &>/dev/null && echo "dnf" || (command -v yum &>/dev/null && echo "yum" || echo "unknown"))); if [ "$pm" = "unknown" ]; then log_err "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"; exit 1; fi; if [ "$AUTO_YES" = "true" ]; then choice="y"; else read -p "$(echo -e "${YELLOW}是否尝试自动安装? (y/N): ${NC}")" choice < /dev/tty; fi; if echo "$choice" | grep -qE '^[Yy]$'; then log_info "正在使用 $pm 安装..."; local update_cmd=""; if [ "$pm" = "apt" ]; then update_cmd="sudo apt-get update"; fi; if ! ($update_cmd && sudo "$pm" install -y "${missing_deps[@]}"); then log_err "依赖安装失败."; exit 1; fi; log_success "依赖安装完成！"; else log_err "用户取消安装."; exit 1; fi; fi; }
_download_file() { curl -fsSL --connect-timeout 5 --max-time 30 "${CONFIG[base_url]}/$1?_=$(date +%s)" -o "$2"; }
self_update() { local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"; if [ "$0" != "$SCRIPT_PATH" ]; then return; fi; local temp_script="/tmp/install.sh.tmp.$$"; if ! _download_file "install.sh" "$temp_script"; then log_warn "主程序 (install.sh) 更新检查失败 (无法连接)。"; rm -f "$temp_script"; return; fi; if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then log_success "主程序 (install.sh) 已更新。正在无缝重启..."; sudo mv "$temp_script" "$SCRIPT_PATH"; sudo chmod +x "$SCRIPT_PATH"; flock -u 200; rm -f "${CONFIG[lock_file]}"; trap - EXIT; exec sudo -E bash "$SCRIPT_PATH" "$@"; fi; rm -f "$temp_script"; }
download_module_to_cache() { local script_name="$1"; local local_file="${CONFIG[install_dir]}/$script_name"; local tmp_file="/tmp/$(basename "$script_name").$$"; local url="${CONFIG[base_url]}/${script_name}?_=$(date +%s)"; local http_code; http_code=$(curl -fsSL --connect-timeout 5 --max-time 60 -w "%{http_code}" -o "$tmp_file" "$url"); local curl_exit_code=$?; if [ "$curl_exit_code" -ne 0 ] || [ "$http_code" -ne 200 ] || [ ! -s "$tmp_file" ]; then log_err "模块 (${script_name}) 下载失败 (HTTP: $http_code, Curl: $curl_exit_code)"; rm -f "$tmp_file"; return 1; fi; if [ -f "$local_file" ] && cmp -s "$local_file" "$tmp_file"; then rm -f "$tmp_file"; else log_success "模块 (${script_name}) 已更新。"; sudo mkdir -p "$(dirname "$local_file")"; sudo mv "$tmp_file" "$local_file"; fi; }
_update_core_files() { local temp_utils="/tmp/utils.sh.tmp.$$"; if _download_file "utils.sh" "$temp_utils"; then if [ ! -f "$UTILS_PATH" ] || ! cmp -s "$UTILS_PATH" "$temp_utils"; then log_success "核心工具库 (utils.sh) 已更新。"; sudo mv "$temp_utils" "$UTILS_PATH"; sudo chmod +x "$UTILS_PATH"; else rm -f "$temp_utils"; fi; else log_warn "核心工具库 (utils.sh) 更新检查失败。"; fi; }
_update_all_modules() { local scripts_to_update; scripts_to_update=$(jq -r '.menus[] | select(type == "object") | .items[]? | select(.type == "item").action' "${CONFIG[install_dir]}/config.json"); if [ -z "$scripts_to_update" ]; then return; fi; local pids=(); for script_name in $scripts_to_update; do download_module_to_cache "$script_name" & pids+=($!); done; for pid in "${pids[@]}"; do wait "$pid" || true; done; }
force_update_all() { self_update; _update_core_files; _update_all_modules; log_success "所有组件更新检查完成！"; }
confirm_and_force_update() { log_warn "警告: 这将从 GitHub 强制拉取所有最新脚本和【主配置文件 config.json】。"; log_warn "您对 config.json 的【所有本地修改都将丢失】！这是一个恢复出厂设置的操作。"; read -p "$(echo -e "${RED}此操作不可逆，请输入 'yes' 确认继续: ${NC}")" choice < /dev/tty; if [ "$choice" = "yes" ]; then log_info "开始强制完全重置..."; declare -A core_files_to_reset=( ["主程序"]="install.sh" ["工具库"]="utils.sh" ["配置文件"]="config.json" ); for name in "${!core_files_to_reset[@]}"; do local file_path="${core_files_to_reset[$name]}"; log_info "正在强制更新 ${name}..."; local temp_file="/tmp/$(basename "$file_path").tmp.$$"; if ! _download_file "$file_path" "$temp_file"; then log_err "下载最新的 ${name} 失败。"; continue; fi; sudo mv "$temp_file" "${CONFIG[install_dir]}/${file_path}"; log_success "${name} 已重置为最新版本。"; done; log_info "正在恢复核心脚本执行权限..."; sudo chmod +x "${CONFIG[install_dir]}/install.sh" "${CONFIG[install_dir]}/utils.sh"; log_success "权限已恢复。"; _update_all_modules; log_success "强制重置完成！"; log_info "脚本将在2秒后自动重启以应用所有更新..."; sleep 2; flock -u 200; rm -f "${CONFIG[lock_file]}"; exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"; else log_info "操作已取消."; fi; return 10; }
uninstall_script() { log_warn "警告: 这将从您的系统中彻底移除本脚本及其所有组件！"; log_warn "  - 安装目录: ${CONFIG[install_dir]}"; log_warn "  - 快捷方式: ${CONFIG[bin_dir]}/jb"; read -p "$(echo -e "${RED}这是一个不可逆的操作, 您确定要继续吗? (请输入 'yes' 确认): ${NC}")" choice < /dev/tty; if [ "$choice" = "yes" ]; then log_info "开始卸载..."; sudo rm -rf "${CONFIG[install_dir]}"; log_success "安装目录已移除."; sudo rm -f "${CONFIG[bin_dir]}/jb"; log_success "快捷方式已移除."; log_success "脚本已成功卸载."; log_info "再见！"; exit 0; else log_info "卸载操作已取消."; return 10; fi; }
_quote_args() { for arg in "$@"; do printf "%q " "$arg"; done; }
execute_module() { local script_name="$1"; local display_name="$2"; shift 2; local local_path="${CONFIG[install_dir]}/$script_name"; log_info "您选择了 [$display_name]"; if [ ! -f "$local_path" ]; then log_info "正在下载模块..."; if ! download_module_to_cache "$script_name"; then log_err "下载失败."; return 1; fi; fi; local env_exports="export IS_NESTED_CALL=true; export FORCE_COLOR=true; export JB_ENABLE_AUTO_CLEAR='${CONFIG[enable_auto_clear]}'; export JB_TIMEZONE='${CONFIG[timezone]}'; export LC_ALL=${LC_ALL};"; local module_key; module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]'); local config_path="${CONFIG[install_dir]}/config.json"; local module_config_json; module_config_json=$(jq -r --arg key "$module_key" '.module_configs[$key] // null' "$config_path"); if [ "$module_config_json" != "null" ]; then local prefix; prefix=$(basename "$script_name" .sh | tr '[:lower:]' '[:upper:]'); local jq_script='to_entries | .[] | select((.key | startswith("comment") | not) and .value != null) | .key as $k | .value as $v | if ($v|type) == "array" then [$k, ($v|join(","))] elif ($v|type) | IN("string", "number", "boolean") then [$k, $v] else empty end | @tsv'; while IFS=$'\t' read -r key value; do if [ -n "$key" ]; then local key_upper; key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]'); env_exports+=$(printf "export %s_CONF_%s=%q;" "$prefix" "$key_upper" "$value"); fi; done < <(echo "$module_config_json" | jq -r "$jq_script"); fi; local exit_code=0; local extra_args_str; extra_args_str=$(_quote_args "$@"); sudo bash -c "$env_exports bash '$local_path' $extra_args_str" < /dev/tty || exit_code=$?; if [ "$exit_code" -eq 0 ]; then log_success "模块 [$display_name] 执行完毕."; elif [ "$exit_code" -eq 10 ]; then log_info "已从 [$display_name] 返回."; else log_warn "模块 [$display_name] 执行出错 (码: $exit_code)."; fi; return $exit_code; }
display_menu() {
    if [ "${CONFIG[enable_auto_clear]}" = "true" ]; then clear 2>/dev/null || true; fi;
    local config_path="${CONFIG[install_dir]}/config.json"; local menu_json; menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path"); local main_title_text; main_title_text=$(jq -r '.title // "VPS 安装脚本"' <<< "$menu_json")
    local -a menu_items_array=()
    local i=1
    while IFS=$'\t' read -r icon name; do
        menu_items_array+=("$(printf "  ${YELLOW}%2d.${NC} %s %s" "$i" "$icon" "$name")")
        i=$((i + 1))
    done < <(jq -r '.items[] | ((.icon // "›") + "\t" + .name)' <<< "$menu_json")
    _render_menu "$main_title_text" "${menu_items_array[@]}"
    local menu_len; menu_len=$(jq -r '.items | length' <<< "$menu_json"); local exit_hint="退出"; if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then exit_hint="返回"; fi; local prompt_text=" └──> 请选择 [1-${menu_len}], 或 [Enter] ${exit_hint}: ";
    if [ "$AUTO_YES" = "true" ]; then choice=""; echo -e "${BLUE}${prompt_text}${NC} [非交互模式]"; else read -p "$(echo -e "${BLUE}${prompt_text}${NC}")" choice < /dev/tty; fi
}
process_menu_selection() { local config_path="${CONFIG[install_dir]}/config.json"; local menu_json; menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path"); local menu_len; menu_len=$(jq -r '.items | length' <<< "$menu_json"); if [ -z "$choice" ]; then if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; return 10; fi; fi; if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then log_warn "无效选项."; return 10; fi; local item_json; item_json=$(echo "$menu_json" | jq -r --argjson idx "$(expr $choice - 1)" '.items[$idx]'); if [ -z "$item_json" ] || [ "$item_json" = "null" ]; then log_warn "菜单项配置无效或不完整。"; return 10; fi; local type; type=$(echo "$item_json" | jq -r ".type"); local name; name=$(echo "$item_json" | jq -r ".name"); local action; action=$(echo "$item_json" | jq -r ".action"); case "$type" in item) execute_module "$action" "$name"; return $?;; submenu) CURRENT_MENU_NAME=$action; return 10;; func) "$action"; return $?;; esac; }
main() {
    exec 200>"${CONFIG[lock_file]}"; if ! flock -n 200; then echo -e "\033[0;33m[警告] 检测到另一实例正在运行."; exit 1; fi
    trap 'flock -u 200; rm -f "${CONFIG[lock_file]}"; log_info "脚本已退出."' EXIT
    if ! command -v flock >/dev/null || ! command -v jq >/dev/null; then check_and_install_dependencies; fi; load_config
    if [ $# -gt 0 ]; then
        local command="$1"; shift; case "$command" in
            update) log_info "正在以 Headless 模式安全更新所有脚本..."; force_update_all; exit 0 ;;
            uninstall) log_info "正在以 Headless 模式执行卸载..."; uninstall_script; exit 0 ;;
            *) local item_json; item_json=$(jq -r --arg cmd "$command" '.menus[] | .items[]? | select(.type != "submenu") | select(.action == $cmd or (.name | ascii_downcase | startswith($cmd)))' "${CONFIG[install_dir]}/config.json" | head -n 1)
                if [ -n "$item_json" ]; then local action_to_run; action_to_run=$(echo "$item_json" | jq -r '.action'); local display_name; display_name=$(echo "$item_json" | jq -r '.name'); local type; type=$(echo "$item_json" | jq -r '.type'); log_info "正在以 Headless 模式执行: ${display_name}"; if [ "$type" = "func" ]; then "$action_to_run" "$@"; else execute_module "$action_to_run" "$display_name" "$@"; fi; exit $?; else log_err "未知命令: $command"; exit 1; fi ;;
        esac
    fi
    log_info "脚本启动 (${SCRIPT_VERSION})"; echo -ne "$(log_timestamp) ${BLUE}[信息]${NC} 正在智能更新... 🕛"; sleep 0.5; echo -ne "\r$(log_timestamp) ${BLUE}[信息]${NC} 正在智能更新... 🔄\n"; force_update_all
    CURRENT_MENU_NAME="MAIN_MENU"; while true; do display_menu; local exit_code=0; process_menu_selection || exit_code=$?; if [ "$exit_code" -ne 10 ]; then while read -r -t 0; do :; done; press_enter_to_continue < /dev/tty; fi; done
}

main "$@"
