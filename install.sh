#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装与管理脚本 (v77.6-哈希校验稳定版 - 已整合补丁)
# - 使用 sha256sum 替换 cmp 进行可靠的更新检测
# - 恢复了基于可靠检测的无缝重启 (exec)
# - 规范化 CRLF 处理以避免伪更新
# - 使用 mktemp/create_temp_file 生成临时文件，并在 utils.sh 中统一清理
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v77.6"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- [核心架构]: 智能自引导启动器 ---
# 这里保留最小启动器逻辑，用于初次下载 / 刷新到最终路径
INSTALL_DIR="/opt/vps_install_modules"
FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"
CONFIG_PATH="${INSTALL_DIR}/config.json"
UTILS_PATH="${INSTALL_DIR}/utils.sh"

REAL_SCRIPT_PATH=""
REAL_SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")

if [ "$REAL_SCRIPT_PATH" != "$FINAL_SCRIPT_PATH" ]; then
    # --- 启动器环境 (最小化依赖) ---
    STARTER_BLUE='\033[0;34m'; STARTER_GREEN='\033[0;32m'; STARTER_RED='\033[0;31m'; STARTER_NC='\033[0m'
    echo_info() { echo -e "${STARTER_BLUE}[启动器]${STARTER_NC} $1"; }
    echo_success() { echo -e "${STARTER_GREEN}[启动器]${STARTER_NC} $1"; }
    echo_error() { echo -e "${STARTER_RED}[启动器错误]${STARTER_NC} $1" >&2; exit 1; }

    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH}" = "true" ]; then
        echo_info "正在执行首次安装或强制刷新..."
        if ! command -v curl &> /dev/null; then echo_error "curl 命令未找到, 请先安装."; fi
        
        sudo mkdir -p "$INSTALL_DIR"
        BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        
        declare -A core_files=( ["主程序"]="install.sh" ["配置文件"]="config.json" ["工具库"]="utils.sh" )
        for name in "${!core_files[@]}"; do
            file_path="${core_files[$name]}"
            echo_info "正在下载最新的 ${name} (${file_path})..."
            temp_file="$(mktemp)" || temp_file="/tmp/$(basename "${file_path}").$$"
            if ! curl -fsSL "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then echo_error "下载 ${name} 失败。"; fi
            # 规范 CRLF
            tr -d '\r' < "$temp_file" > "${temp_file}.unix" || true
            sudo mv "${temp_file}.unix" "${INSTALL_DIR}/${file_path}" 2>/dev/null || sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"
            rm -f "$temp_file" "${temp_file}.unix" 2>/dev/null || true
        done

        sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH" 2>/dev/null || true
        echo_info "正在创建/更新快捷指令 'jb'..."
        BIN_DIR="/usr/local/bin"
        sudo bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"
        echo_success "安装/更新完成！"
    fi
    
    echo -e "${STARTER_BLUE}────────────────────────────────────────────────────────────${STARTER_NC}"
    exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
fi

# --- 主程序逻辑 ---
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    echo "致命错误: 通用工具库 $UTILS_PATH 未找到！" >&2
    exit 1
fi

# --- 使用 utils 中的默认值（如果外部没有覆盖） ---
BASE_URL="${BASE_URL:-${DEFAULT_BASE_URL:-https://raw.githubusercontent.com/wx233Github/jaoeng/main}}"
INSTALL_DIR="${INSTALL_DIR:-${DEFAULT_INSTALL_DIR:-/opt/vps_install_modules}}"
BIN_DIR="${BIN_DIR:-${DEFAULT_BIN_DIR:-/usr/local/bin}}"
LOCK_FILE="${LOCK_FILE:-${DEFAULT_LOCK_FILE:-/tmp/vps_install_modules.lock}}"
JB_ENABLE_AUTO_CLEAR="${JB_ENABLE_AUTO_CLEAR:-false}"
JB_TIMEZONE="${JB_TIMEZONE:-${DEFAULT_TIMEZONE:-Asia/Shanghai}}"
CURRENT_MENU_NAME="MAIN_MENU"
CONFIG_PATH="${CONFIG_PATH:-${INSTALL_DIR}/config.json}"
UTILS_PATH="${UTILS_PATH:-${INSTALL_DIR}/utils.sh}"

export JB_ENABLE_AUTO_CLEAR JB_TIMEZONE

# --- 权限处理函数 ---
check_sudo_privileges() {
    if [ "$(id -u)" -eq 0 ]; then
        JB_HAS_PASSWORDLESS_SUDO=true
        log_info "以 root 用户运行（拥有完整权限）。"
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        JB_HAS_PASSWORDLESS_SUDO=true
        log_info "检测到免密 sudo 权限。"
    else
        JB_HAS_PASSWORDLESS_SUDO=false
        log_warn "未检测到免密 sudo 权限。部分操作可能需要您输入密码。"
    fi
}
run_with_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else
        if [ "${JB_SUDO_LOG_QUIET:-}" != "true" ]; then log_debug "Executing with sudo: sudo $*"; fi
        sudo "$@"
    fi
}

# --- 核心函数 ---
# load_config 已在 utils.sh 中实现（集中默认与容错）
# load_config "$CONFIG_PATH"  # will be called in main()

check_and_install_dependencies() {
    # 支持 config.json 不存在或 jq 不可用的情况
    local deps
    if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
        deps=$(jq -r '.dependencies.common' "$CONFIG_PATH" 2>/dev/null || echo "")
    fi
    deps="${deps:-curl cmp ln dirname flock jq sha256sum mktemp}"

    log_info "检查依赖: ${deps}..."
    local missing_pkgs=""

    # 映射命令 -> apt 包（Debian/Ubuntu 的常见映射）
    declare -A pkg_apt_map=(
        [cmp]=diffutils
        [curl]=curl
        [ln]=coreutils
        [dirname]=coreutils
        [flock]=util-linux
        [jq]=jq
        [sha256sum]=coreutils
        [mktemp]=coreutils
        [tr]=coreutils
    )

    for dep in $deps; do
        if ! command -v "$dep" &>/dev/null; then
            local pkg="${pkg_apt_map[$dep]:-$dep}"
            missing_pkgs="${missing_pkgs} ${pkg}"
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        missing_pkgs=$(echo "$missing_pkgs" | xargs) # trim
        log_warn "缺失依赖: ${missing_pkgs}"
        if confirm_action "是否尝试自动安装?"; then
            if command -v apt-get &>/dev/null; then
                run_with_sudo env DEBIAN_FRONTEND=noninteractive apt-get update
                run_with_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $missing_pkgs
            elif command -v yum &>/dev/null; then
                run_with_sudo yum install -y $missing_pkgs
            else
                log_err "不支持的包管理器。请手动安装: ${missing_pkgs}"
                exit 1
            fi
        else
            log_err "用户取消安装，脚本无法继续。"
            exit 1
        fi
    else
        log_success "所有依赖均已安装。"
    fi
}

self_update() {
    log_info "正在检查主程序更新..."
    # 使用 utils 的 create_temp_file（如果可用），否则回退 mktemp
    local temp_script
    if command -v create_temp_file >/dev/null 2>&1; then
        temp_script=$(create_temp_file)
    else
        temp_script=$(mktemp) || temp_script="/tmp/install.sh.tmp.$$"
    fi

    if ! curl -fsSL "${BASE_URL}/install.sh?_=$(date +%s)" -o "$temp_script"; then
        log_warn "主程序更新检查失败 (无法连接)。"
        rm -f "$temp_script" 2>/dev/null || true
        return
    fi

    # 规范化 CRLF 再计算哈希，避免 CRLF 导致伪变更
    local remote_hash; remote_hash=$(tr -d '\r' < "$temp_script" | sha256sum | awk '{print $1}')
    local local_hash; local_hash=""
    if [ -f "$FINAL_SCRIPT_PATH" ]; then
        local_hash=$(tr -d '\r' < "$FINAL_SCRIPT_PATH" | sha256sum | awk '{print $1}')
    fi

    if [ "$local_hash" != "$remote_hash" ]; then
        log_success "主程序 (install.sh) 已更新。正在无缝重启..."
        run_with_sudo mv "$temp_script" "$FINAL_SCRIPT_PATH"
        run_with_sudo chmod +x "$FINAL_SCRIPT_PATH"
        # 释放锁并 exec 新脚本
        flock -u 200 2>/dev/null || true; trap - EXIT || true; exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
    fi
    rm -f "$temp_script" 2>/dev/null || true
}

force_update_all() {
    log_info "开始强制更新所有组件..."
    self_update "$@"
    _update_core_files
    # 更新 menus 指定的脚本
    local scripts_to_update=""
    if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
        scripts_to_update=$(jq -r '.menus[] | .items[]? | select(.type == "item").action' "$CONFIG_PATH" 2>/dev/null || true)
    fi
    for script_name in $scripts_to_update; do download_module_to_cache "$script_name"; done
    log_success "所有组件更新检查完成！"
}

_update_core_files() {
    log_info "检查并更新核心工具库..."
    local temp_utils
    if command -v create_temp_file >/dev/null 2>&1; then
        temp_utils=$(create_temp_file)
    else
        temp_utils=$(mktemp) || temp_utils="/tmp/utils.sh.tmp.$$"
    fi

    if curl -fsSL "${BASE_URL}/utils.sh?_=$(date +%s)" -o "$temp_utils"; then
        local remote_hash; remote_hash=$(tr -d '\r' < "$temp_utils" | sha256sum | awk '{print $1}')
        local local_hash="no_local_file"
        [ -f "$UTILS_PATH" ] && local_hash=$(tr -d '\r' < "$UTILS_PATH" | sha256sum | awk '{print $1}')
        
        if [ "$local_hash" != "$remote_hash" ]; then
            log_success "核心工具库 (utils.sh) 已更新。"
            sudo mv "$temp_utils" "$UTILS_PATH"
            sudo chmod +x "$UTILS_PATH"
        else
            rm -f "$temp_utils"
        fi
    else
        log_warn "核心工具库 (utils.sh) 更新检查失败。"
        rm -f "$temp_utils" 2>/dev/null || true
    fi
}

download_module_to_cache() {
    local script_name="$1"; local local_file="${INSTALL_DIR}/$script_name"; local tmp_file=""
    log_info "  -> 检查/下载模块: ${script_name}"
    if command -v create_temp_file >/dev/null 2>&1; then
        tmp_file=$(create_temp_file)
    else
        tmp_file=$(mktemp) || tmp_file="/tmp/$(basename "$script_name").$$"
    fi

    if ! curl -fsSL "${BASE_URL}/${script_name}?_=$(date +%s)" -o "$tmp_file"; then
        log_err "     模块 (${script_name}) 下载失败。"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    
    local remote_hash; remote_hash=$(tr -d '\r' < "$tmp_file" | sha256sum | awk '{print $1}')
    local local_hash="no_local_file"
    [ -f "$local_file" ] && local_hash=$(tr -d '\r' < "$local_file" | sha256sum | awk '{print $1}')

    if [ "$local_hash" != "$remote_hash" ]; then
        log_success "     模块 (${script_name}) 已更新。"
        sudo mkdir -p "$(dirname "$local_file")"
        sudo mv "$tmp_file" "$local_file"
        sudo chmod +x "$local_file"
    else
        rm -f "$tmp_file" 2>/dev/null || true
    fi
}

uninstall_script() {
    if confirm_action "警告：这将移除脚本、模块和快捷命令，确定吗？"; then
        log_info "正在卸载..."
        run_with_sudo rm -f "${BIN_DIR}/jb" || true
        run_with_sudo rm -rf "$INSTALL_DIR" || true
        log_success "卸载完成。"
        exit 0
    else
        log_info "操作已取消。"
    fi
}

confirm_and_force_update() {
    if confirm_action "⚠️ 确认要强制更新所有组件并重启脚本吗？"; then
        log_info "用户确认：开始强制更新所有组件..."
        force_update_all "$@"
    else
        log_info "用户取消了强制更新。"
    fi
}

run_module(){
    local module_script="$1"; local module_name="$2"; local module_path="${INSTALL_DIR}/${module_script}"
    log_info "您选择了 [${module_name}]"
    if [ ! -f "$module_path" ]; then
        log_info "模块首次运行，正在下载..."
        download_module_to_cache "$module_script"
    fi
    
    local module_key; module_key=$(basename "$module_script" .sh | tr '[:upper:]' '[:lower:]')
    if command -v jq >/dev/null 2>&1 && jq -e ".module_configs.$module_key" "$CONFIG_PATH" >/dev/null 2>&1; then
        local keys; keys=$(jq -r ".module_configs.$module_key | keys[]" "$CONFIG_PATH")
        for key in $keys; do
            if [[ "$key" == "comment_"* ]]; then continue; fi
            local value; value=$(jq -r ".module_configs.$module_key.$key" "$CONFIG_PATH")
            export "WATCHTOWER_CONF_$(echo "$key" | tr '[:lower:]' '[:upper:]')"="$value"
        done
    fi
    
    set +e; bash "$module_path"; local exit_code=$?; set -e
    if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 10 ]; then
        log_warn "模块 [${module_name}] 执行出错 (码: ${exit_code})."
        press_enter_to_continue
    fi
}

# --- 状态检查函数 ---
_get_docker_status() {
    local docker_ok=false compose_ok=false status_str=""
    if systemctl is-active --quiet docker 2>/dev/null; then docker_ok=true; fi
    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>&1; then compose_ok=true; fi
    if $docker_ok && $compose_ok; then echo -e "${GREEN}已运行${NC}"; else
        if ! $docker_ok; then status_str+="Docker${RED}未运行${NC} "; fi
        if ! $compose_ok; then status_str+="Compose${RED}未找到${NC}"; fi
        echo -e "$status_str"
    fi
}
_get_nginx_status() { if systemctl is-active --quiet nginx 2>/dev/null; then echo -e "${GREEN}已运行${NC}"; else echo -e "${RED}未运行${NC}"; fi; }
_get_watchtower_status() {
    if systemctl is-active --quiet docker 2>/dev/null; then
        if run_with_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^watchtower$'; then echo -e "${GREEN}已运行${NC}";
        else echo -e "${YELLOW}未运行${NC}"; fi
    else echo -e "${RED}Docker未运行${NC}"; fi
}

# --- 动态菜单引擎 ---
display_and_process_menu() {
    while true; do
        if [ "$JB_ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
        
        local menu_json; menu_json=""
        if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
            menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$CONFIG_PATH" 2>/dev/null || "")
        fi
        if [ -z "$menu_json" ]; then
            log_warn "菜单配置读取失败或为空，回退到默认 MAIN_MENU."
            CURRENT_MENU_NAME="MAIN_MENU"
            menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$CONFIG_PATH" 2>/dev/null || "")
        fi

        local menu_title; menu_title=$(jq -r '.title' <<< "$menu_json")
        
        local -a primary_items=() func_items=()
        while IFS=$'\t' read -r icon name type action; do
            local item_data="$icon|$name|$type|$action"
            if [[ "$type" == "item" || "$type" == "submenu" ]]; then primary_items+=("$item_data");
            elif [[ "$type" == "func" ]]; then func_items+=("$item_data"); fi
        done < <(jq -r '.items[] | [.icon, .name, .type, .action] | @tsv' <<< "$menu_json" 2>/dev/null || true)
        
        local -a items_array=()
        local -A status_map=( ["docker.sh"]="$(_get_docker_status)" ["nginx.sh"]="$(_get_nginx_status)" ["TOOLS_MENU"]="$(_get_watchtower_status)" )
        local -A status_prefix_map=( ["docker.sh"]="docker: " ["nginx.sh"]="Nginx: " ["TOOLS_MENU"]="Watchtower: " )
        local num_primary=${#primary_items[@]}; local num_func=${#func_items[@]}

        # 生成 func_letters 动态字母表
        local func_letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)

        for (( i=0; i<num_primary; i++ )); do
            IFS='|' read -r icon name type action <<< "${primary_items[i]}"
            items_array+=("$(printf "%-22s │ %s" "$(printf "%d. %s %s" "$((i+1))" "$icon" "$name")" "${status_prefix_map[$action]}${status_map[$action]}")")
        done
        for (( i=0; i<num_func; i++ )); do
            IFS='|' read -r icon name type action <<< "${func_items[i]}"
            items_array+=("$(printf "%-22s │ %s" "" "$(printf "%s. %s %s" "${func_letters[i]}" "$icon" "$name")")")
        done
        _render_menu "$menu_title" "${items_array[@]}"
        
        local num_choices=${#primary_items[@]}; local func_choices_str=""
        for ((i=0; i<num_func; i++)); do func_choices_str+="${func_letters[i]},"; done
        read -r -p " └──> 请选择 [1-$num_choices], 或 [${func_choices_str%,}] 操作, [Enter] 返回: " choice < /dev/tty

        if [ -z "$choice" ]; then if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; continue; fi; fi
        local item_json=""
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$num_choices" ]; then
            item_json=$(jq -r --argjson idx "$((choice-1))" '.items | map(select(.type == "item" or .type == "submenu")) | .[$idx]' <<< "$menu_json")
        else
            for ((i=0; i<num_func; i++)); do if [ "$choice" = "${func_letters[i]}" ]; then item_json=$(jq -r --argjson idx "$i" '.items | map(select(.type == "func")) | .[$idx]' <<< "$menu_json"); break; fi; done
        fi
        if [ -z "$item_json" ]; then log_warn "无效选项。"; sleep 1; continue; fi
        
        local type name action; type=$(jq -r .type <<< "$item_json"); name=$(jq -r .name <<< "$item_json"); action=$(jq -r .action <<< "$item_json")
        case "$type" in
            item) run_module "$action" "$name"; press_enter_to_continue ;;
            submenu) CURRENT_MENU_NAME="$action" ;;
            func) "$action" "$@"; press_enter_to_continue ;;
        esac
    done
}

# --- 主程序入口 ---
main() {
    # 先确保默认值与加载配置（load_config 在 utils.sh 中）
    load_config "$CONFIG_PATH"
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then log_err "脚本已在运行。"; exit 1; fi
    trap 'flock -u 200; rm -f "$LOCK_FILE" 2>/dev/null || true' EXIT
    
    check_and_install_dependencies

    if [ $# -gt 0 ]; then
        local command="$1"; shift
        case "$command" in
            update) log_info "正在以无头模式更新所有脚本..."; force_update_all "$@"; exit 0 ;;
            uninstall) log_info "正在以无头模式执行卸载..."; uninstall_script; exit 0 ;;
            *)
                local action_to_run=""
                if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
                    action_to_run=$(jq -r --arg cmd "$command" '.menus[] | .items[]? | select(.action and (.action | contains($cmd)) or (.name | ascii_downcase | contains($cmd))) | .action' "$CONFIG_PATH" 2>/dev/null | head -n 1)
                fi
                if [ -n "$action_to_run" ]; then
                    local display_name
                    display_name=$(jq -r --arg act "$action_to_run" '.menus[] | .items[]? | select(.action == $act) | .name' "$CONFIG_PATH" 2>/dev/null | head -n 1)
                    log_info "正在以无头模式执行: ${display_name}"
                    run_module "$action_to_run" "$display_name" "$@"
                    exit $?
                else
                    log_err "未知命令: $command"
                    exit 1
                fi
                ;;
        esac
    fi

    self_update
    check_sudo_privileges
    display_and_process_menu "$@"
}

main "$@"
