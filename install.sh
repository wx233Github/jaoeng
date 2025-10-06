#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装与管理脚本 (v76.0-融合最终版)
# - 集成智能自引导、无头命令、自动更新与全新UI
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v76.0"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- [核心架构]: 智能自引导启动器 ---
INSTALL_DIR="/opt/vps_install_modules"
FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"
CONFIG_PATH="${INSTALL_DIR}/config.json"
UTILS_PATH="${INSTALL_DIR}/utils.sh"

if [ "$0" != "$FINAL_SCRIPT_PATH" ]; then
    # --- 启动器环境 (最小化依赖) ---
    STARTER_BLUE='\033[0;34m'; STARTER_GREEN='\033[0;32m'; STARTER_RED='\033[0;31m'; STARTER_NC='\033[0m'
    echo_info() { echo -e "${STARTER_BLUE}[启动器]${STARTER_NC} $1"; }
    echo_success() { echo -e "${STARTER_GREEN}[启动器]${STARTER_NC} $1"; }
    echo_error() { echo -e "${STARTER_RED}[启动器错误]${STARTER_NC} $1" >&2; exit 1; }

    # 检查是否首次运行或需要强制刷新
    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH}" = "true" ]; then
        echo_info "正在执行首次安装或强制刷新..."
        if ! command -v curl &> /dev/null; then echo_error "curl 命令未找到, 请先安装."; fi
        
        sudo mkdir -p "$INSTALL_DIR"
        BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        
        declare -A core_files=( ["主程序"]="install.sh" ["配置文件"]="config.json" ["工具库"]="utils.sh" )
        for name in "${!core_files[@]}"; do
            file_path="${core_files[$name]}"
            echo_info "正在下载最新的 ${name} (${file_path})..."
            temp_file="/tmp/$(basename "${file_path}").$$"
            if ! curl -fsSL "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then
                echo_error "下载 ${name} 失败。"
            fi
            sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"
        done

        sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH"
        echo_info "正在创建/更新快捷指令 'jb'..."
        BIN_DIR="/usr/local/bin"
        sudo bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"
        echo_success "安装/更新完成！"
    fi
    
    echo -e "${STARTER_BLUE}────────────────────────────────────────────────────────────${STARTER_NC}"
    echo ""
    # 使用 exec sudo -E 将控制权完全交给最终位置的脚本
    exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
fi

# --- 主程序逻辑 (已在 /opt/vps_install_modules/install.sh 中运行) ---
if [ -f "$UTILS_PATH" ]; then source "$UTILS_PATH"; else echo "致命错误: 通用工具库 $UTILS_PATH 未找到！" >&2; exit 1; fi

# --- 全局变量 ---
BASE_URL=""
INSTALL_DIR="/opt/vps_install_modules" # 此处硬编码以确保一致性
BIN_DIR=""
LOCK_FILE=""
export JB_ENABLE_AUTO_CLEAR="false"
export JB_TIMEZONE="Asia/Shanghai"

# --- 核心函数 ---

load_config() {
    local config_file="${INSTALL_DIR}/config.json"
    if [ ! -f "$config_file" ]; then
        log_warn "配置文件 $config_file 未找到，将使用默认值。"
        return
    fi
    BASE_URL=$(jq -r '.base_url // ""' "$config_file")
    BIN_DIR=$(jq -r '.bin_dir // "/usr/local/bin"' "$config_file")
    LOCK_FILE=$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$config_file")
    JB_ENABLE_AUTO_CLEAR=$(jq -r '.enable_auto_clear // false' "$config_file")
    JB_TIMEZONE=$(jq -r '.timezone // "Asia/Shanghai"' "$config_file")
}

check_and_install_dependencies() {
    local deps; deps=$(jq -r '.dependencies.common' "${INSTALL_DIR}/config.json")
    log_info "检查依赖: ${deps}..."
    local missing_deps=""
    for dep in $deps; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps="${missing_deps} ${dep}"
        fi
    done

    if [ -n "$missing_deps" ]; then
        log_warn "缺失依赖: ${missing_deps}"
        if confirm_action "是否尝试自动安装?"; then
            if command -v apt-get &>/dev/null; then
                run_with_sudo apt-get update
                run_with_sudo apt-get install -y $missing_deps
            elif command -v yum &>/dev/null; then
                run_with_sudo yum install -y $missing_deps
            else
                log_err "不支持的包管理器。请手动安装: ${missing_deps}"
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
    local temp_script="/tmp/install.sh.tmp.$$"
    if ! curl -fsSL "${BASE_URL}/install.sh?_=$(date +%s)" -o "$temp_script"; then
        log_warn "主程序 (install.sh) 更新检查失败 (无法连接)。"
        rm -f "$temp_script"
        return
    fi

    if ! cmp -s "$FINAL_SCRIPT_PATH" "$temp_script"; then
        log_success "主程序 (install.sh) 已更新。正在无缝重启..."
        sudo mv "$temp_script" "$FINAL_SCRIPT_PATH"
        sudo chmod +x "$FINAL_SCRIPT_PATH"
        # 解锁并退出，让 exec 重新执行新脚本
        flock -u 200
        trap - EXIT
        exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
    fi
    rm -f "$temp_script"
}

force_update_all() {
    log_info "开始强制更新所有组件..."
    self_update "$@" # 确保主程序自身最新
    
    # 更新核心文件
    _update_core_files

    # 更新所有模块
    local scripts_to_update; scripts_to_update=$(jq -r '.menus[] | select(type == "object") | .items[]? | select(.type == "item").action' "${INSTALL_DIR}/config.json")
    for script_name in $scripts_to_update; do
        download_module_to_cache "$script_name"
    done
    log_success "所有组件更新检查完成！"
}

_update_core_files() {
    local temp_utils="/tmp/utils.sh.tmp.$$"
    if curl -fsSL "${BASE_URL}/utils.sh?_=$(date +%s)" -o "$temp_utils"; then
        if [ ! -f "$UTILS_PATH" ] || ! cmp -s "$UTILS_PATH" "$temp_utils"; then
            log_success "核心工具库 (utils.sh) 已更新。"
            sudo mv "$temp_utils" "$UTILS_PATH"
            sudo chmod +x "$UTILS_PATH"
        else
            rm -f "$temp_utils"
        fi
    else
        log_warn "核心工具库 (utils.sh) 更新检查失败。"
    fi
}

download_module_to_cache() {
    local script_name="$1"
    local local_file="${INSTALL_DIR}/$script_name"
    local tmp_file="/tmp/$(basename "$script_name").$$"
    
    log_info "  -> 检查/下载模块: ${script_name}"
    if ! curl -fsSL "${BASE_URL}/${script_name}?_=$(date +%s)" -o "$tmp_file"; then
        log_err "     模块 (${script_name}) 下载失败。"
        rm -f "$tmp_file"
        return 1
    fi

    if [ -f "$local_file" ] && cmp -s "$local_file" "$tmp_file"; then
        rm -f "$tmp_file"
    else
        log_success "     模块 (${script_name}) 已更新。"
        sudo mkdir -p "$(dirname "$local_file")"
        sudo mv "$tmp_file" "$local_file"
        sudo chmod +x "$local_file"
    fi
}

confirm_and_force_update() {
    if confirm_action "确定要强制更新所有脚本文件吗？"; then
        force_update_all "$@"
        log_info "脚本已更新，请重新运行以使更改生效。"
        exit 0
    else
        log_info "操作已取消。"
    fi
}

uninstall_script() {
    if confirm_action "警告：这将移除脚本、模块和快捷命令，确定吗？"; then
        log_info "正在卸载..."
        sudo rm -f "${BIN_DIR}/jb"
        sudo rm -rf "$INSTALL_DIR"
        log_success "卸载完成。"
        exit 0
    else
        log_info "操作已取消。"
    fi
}

run_module(){
    local module_script="$1"
    local module_name="$2"
    local module_path="${INSTALL_DIR}/${module_script}"

    log_info "您选择了 [${module_name}]"
    
    if [ ! -f "$module_path" ]; then
        log_info "模块首次运行，正在下载..."
        download_module_to_cache "$module_script"
    fi
    
    local module_key; module_key=$(basename "$module_script" .sh | tr '[:upper:]' '[:lower:]')
    if jq -e ".module_configs.$module_key" "$CONFIG_PATH" >/dev/null; then
        local keys; keys=$(jq -r ".module_configs.$module_key | keys[]" "$CONFIG_PATH")
        for key in $keys; do
            if [[ "$key" == "comment_"* ]]; then continue; fi
            local value; value=$(jq -r ".module_configs.$module_key.$key" "$CONFIG_PATH")
            local var_name="WATCHTOWER_CONF_$(echo "$key" | tr '[:lower:]' '[:upper:]')"
            export "$var_name"="$value"
        done
    fi
    
    set +e
    bash "$module_path"
    local exit_code=$?
    set -e

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

    if $docker_ok && $compose_ok; then echo -e "${GREEN}已运行${NC}";
    else
        if ! $docker_ok; then status_str+="Docker${RED}未运行${NC} "; fi
        if ! $compose_ok; then status_str+="Compose${RED}未找到${NC}"; fi
        echo -e "$status_str"
    fi
}
_get_nginx_status() { if systemctl is-active --quiet nginx 2>/dev/null; then echo -e "${GREEN}已运行${NC}"; else echo -e "${RED}未运行${NC}"; fi; }
_get_watchtower_status() {
    if systemctl is-active --quiet docker 2>/dev/null; then
        if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^watchtower$'; then echo -e "${GREEN}已运行${NC}";
        else echo -e "${YELLOW}未运行${NC}"; fi
    else echo -e "${RED}Docker未运行${NC}"; fi
}

# --- 菜单渲染 ---
main_menu() {
    while true; do
        if [ "$JB_ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
        local docker_status=$(_get_docker_status); local nginx_status=$(_get_nginx_status); local watchtower_status=$(_get_watchtower_status)
        local -a items_array=(
            "$(printf "%-22s │ %s" "1. 🐳 Docker" "docker: $docker_status")"
            "$(printf "%-22s │ %s" "2. 🌐 Nginx" "Nginx: $nginx_status")"
            "$(printf "%-22s │ %s" "3. 🛠️ 常用工具" "Watchtower: $watchtower_status")"
            "$(printf "%-22s │ %s" "4. 📜 证书申请" "a.⚙️ 强制重置")"
            "$(printf "%-22s │ %s" "" "c.🗑️ 卸载脚本")"
        )
        _render_menu "🖥️ VPS 一键安装脚本" "${items_array[@]}"
        read -r -p " └──> 请选择 [1-4], 或 [a,c] 操作: " choice < /dev/tty
        case "$choice" in
            1) run_module "$(jq -r '.menus.MAIN_MENU.items[0].action' "$CONFIG_PATH")" "Docker" ;;
            2) run_module "$(jq -r '.menus.MAIN_MENU.items[1].action' "$CONFIG_PATH")" "Nginx" ;;
            3) tools_menu ;;
            4) run_module "$(jq -r '.menus.MAIN_MENU.items[3].action' "$CONFIG_PATH")" "证书申请" ;;
            a|A) confirm_and_force_update "$@"; press_enter_to_continue ;;
            c|C) uninstall_script ;;
            "") exit 0 ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}
tools_menu() {
    while true; do
        if [ "$JB_ENABLE_AUTO_CLEAR" = "true" ]; then clear; fi
        local -a items_array=("  1. › Watchtower (Docker 更新)")
        _render_menu "🛠️ 常用工具" "${items_array[@]}"
        read -r -p " └──> 请选择 [1-1], 或 [Enter] 返回: " choice < /dev/tty
        case "$choice" in
            1) run_module "$(jq -r '.menus.TOOLS_MENU.items[0].action' "$CONFIG_PATH")" "Watchtower (Docker 更新)" ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

# --- 主程序入口 ---
main() {
    load_config
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then log_err "脚本已在运行。"; exit 1; fi
    trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT
    
    check_and_install_dependencies

    # --- 无头命令解析器 ---
    if [ $# -gt 0 ]; then
        local command="$1"; shift
        case "$command" in
            update) log_info "正在以无头模式更新所有脚本..."; force_update_all "$@"; exit 0 ;;
            uninstall) log_info "正在以无头模式执行卸载..."; uninstall_script; exit 0 ;;
            *)  # 模块直达
                local action_to_run; action_to_run=$(jq -r --arg cmd "$command" '.menus[] | .items[]? | select(.action and (.action | contains($cmd)) or (.name | ascii_downcase | contains($cmd))) | .action' "$CONFIG_PATH" | head -n 1)
                local display_name; display_name=$(jq -r --arg act "$action_to_run" '.menus[] | .items[]? | select(.action == $act) | .name' "$CONFIG_PATH" | head -n 1)
                if [ -n "$action_to_run" ]; then
                    log_info "正在以无头模式执行: ${display_name}"
                    run_module "$action_to_run" "$display_name" "$@"
                    exit $?
                else
                    log_err "未知命令: $command"; exit 1
                fi
                ;;
        esac
    fi

    # --- 交互模式 ---
    self_update "$@" # 自动更新检查
    source "${INSTALL_DIR}/sudo_check.sh"
    check_sudo_privileges
    main_menu
}

main "$@"
