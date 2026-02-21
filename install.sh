# =============================================================
# 🚀 VPS 一键安装与管理脚本 (v2.0-优化菜单无图标显示)
# - 修复: (关键) 将临时文件管理逻辑移至本脚本，并延迟 `trap` 设置，以解决启动器在 `exec` 过程中因过早清理临时文件而导致的 `No such file or directory` 致命错误。
# - 优化: 菜单渲染逻辑现在完美兼容无图标（icon字段为空或缺失）的情况，自动移除多余空格。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v2.0"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C_UTF_8}

# --- [核心架构]: 智能自引导启动器 ---
INSTALL_DIR="/opt/vps_install_modules"
FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"
CONFIG_PATH="${INSTALL_DIR}/config.json"
UTILS_PATH="${INSTALL_DIR}/utils.sh"

REAL_SCRIPT_PATH=""
REAL_SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")

if [ "$REAL_SCRIPT_PATH" != "$FINAL_SCRIPT_PATH" ]; then
    # --- 启动器环境 (最小化依赖) ---
    STARTER_CYAN='\033[0;36m'; STARTER_GREEN='\033[0;32m'; STARTER_RED='\033[0;31m'; STARTER_NC='\033[0m'
    
    _starter_log_prefix() {
        if [ "${JB_LOG_WITH_TIMESTAMP:-false}" = "true" ]; then
            echo -n "$(date '+%Y-%m-%d %H:%M:%S') "
        fi
    }
    echo_info() { echo -e "$(_starter_log_prefix)${STARTER_CYAN}[启动器]${STARTER_NC} $1" >&2; }
    echo_success() { echo -e "$(_starter_log_prefix)${STARTER_GREEN}[启动器]${STARTER_NC} $1" >&2; }
    echo_error() { echo -e "$(_starter_log_prefix)${STARTER_RED}[启动器错误]${STARTER_NC} $1" >&2; exit 1; }

    if [ -f "$CONFIG_PATH" ] && command -v jq &>/dev/null; then
        JB_LOG_WITH_TIMESTAMP=$(jq -r '.log_with_timestamp // false' "$CONFIG_PATH" 2>/dev/null || echo "false")
    fi

    if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
        echo_info "检测到核心依赖 curl 或 jq 未安装，正在尝试自动安装..."
        if command -v apt-get &>/dev/null; then
            sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq >&2
        elif command -v yum &>/dev/null; then
            sudo yum install -y curl jq >&2
        else
            echo_error "无法自动安装 curl 和 jq。请手动安装后再试。"
        fi
        echo_success "核心依赖安装完成。"
    fi

    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH}" = "true" ]; then
        echo_info "正在执行首次安装或强制刷新..."
        sudo mkdir -p "$INSTALL_DIR"
        BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        
        declare -A core_files=( ["主程序"]="install.sh" ["工具库"]="utils.sh" ["配置文件"]="config.json" )
        for name in "${!core_files[@]}"; do
            file_path="${core_files[$name]}"
            echo_info "正在下载最新的 ${name} (${file_path})..."
            temp_file="$(mktemp "/tmp/jb_starter_XXXXXX")" || temp_file="/tmp/$(basename "${file_path}").$$"
            if ! curl -fsSL "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then echo_error "下载 ${name} 失败。"; fi
            sed 's/\r$//' < "$temp_file" > "${temp_file}.unix" || true
            sudo mv "${temp_file}.unix" "${INSTALL_DIR}/${file_path}" 2>/dev/null || sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"
            rm -f "$temp_file" "${temp_file}.unix" 2>/dev/null || true
        done

        sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH" 2>/dev/null || true
        echo_info "正在创建/更新快捷指令 'jb'..."
        BIN_DIR="/usr/local/bin"
        sudo bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"
        echo_success "安装/更新完成。"
    fi
    
    echo -e "${STARTER_CYAN}────────────────────────────────────────────────────────────${STARTER_NC}" >&2
    exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
fi

# --- 主程序逻辑 ---
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    echo "致命错误: 通用工具库 $UTILS_PATH 未找到！" >&2; exit 1
fi

# --- 临时文件管理 (移至主脚本) ---
TEMP_FILES=()
create_temp_file() {
    local tmpfile
    tmpfile=$(mktemp "/tmp/jb_temp_XXXXXX") || {
        log_err "无法创建临时文件"
        return 1
    }
    TEMP_FILES+=("$tmpfile")
    echo "$tmpfile"
}
cleanup_temp_files() {
    log_debug "正在清理临时文件: ${TEMP_FILES[*]}"
    for f in "${TEMP_FILES[@]}"; do [ -f "$f" ] && rm -f "$f"; done
    TEMP_FILES=()
}

# --- 变量与函数定义 ---
CURRENT_MENU_NAME="MAIN_MENU"

check_sudo_privileges() {
    if [ "$(id -u)" -eq 0 ]; then 
        JB_HAS_PASSWORDLESS_SUDO=true; 
        log_info "以 root 用户运行（拥有完整权限）。" >&2;
        return 0; 
    fi
    
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then 
        JB_HAS_PASSWORDLESS_SUDO=true; 
        log_info "检测到免密 sudo 权限。" >&2;
    else 
        JB_HAS_PASSWORDLESS_SUDO=false; 
        log_warn "未检测到免密 sudo 权限。部分操作可能需要您输入密码。" >&2;
    fi
}
run_with_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else
        if [ "${JB_SUDO_LOG_QUIET:-}" != "true" ]; then log_debug "Executing with sudo: sudo $*" >&2; fi
        sudo "$@"
    fi
}
export -f run_with_sudo

check_and_install_dependencies() {
    local default_deps="curl ln dirname flock jq sha256sum mktemp sed"
    local deps; deps=$(jq -r '.dependencies.common' "$CONFIG_PATH" 2>/dev/null || echo "$default_deps")
    if [ -z "$deps" ]; then deps="$default_deps"; fi

    local missing_pkgs=""
    declare -A pkg_apt_map=( [curl]=curl [ln]=coreutils [dirname]=coreutils [flock]=util-linux [jq]=jq [sha256sum]=coreutils [mktemp]=coreutils [sed]=sed )
    for dep in $deps; do if ! command -v "$dep" &>/dev/null; then local pkg="${pkg_apt_map[$dep]:-$dep}"; missing_pkgs="${missing_pkgs} ${pkg}"; fi; done
    
    if [ -n "$missing_pkgs" ]; then
        missing_pkgs=$(echo "$missing_pkgs" | xargs)
        log_info "检查附加依赖..." >&2
        log_warn "缺失依赖: ${missing_pkgs}" >&2
        if confirm_action "是否尝试自动安装?"; then
            if command -v apt-get &>/dev/null; then run_with_sudo env DEBIAN_FRONTEND=noninteractive apt-get update >&2; run_with_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $missing_pkgs >&2
            elif command -v yum &>/dev/null; then run_with_sudo yum install -y $missing_pkgs >&2
            else log_err "不支持的包管理器。请手动安装: ${missing_pkgs}" >&2; exit 1; fi
        else log_err "用户取消安装，脚本无法继续。" >&2; exit 1; fi
    else
        log_debug "所有依赖均已满足。" >&2
    fi
}

run_comprehensive_auto_update() {
    local updated_files=()
    declare -A core_files=( ["install.sh"]="$FINAL_SCRIPT_PATH" ["utils.sh"]="$UTILS_PATH" ["config.json"]="$CONFIG_PATH" )
    for file in "${!core_files[@]}"; do
        local local_path="${core_files[$file]}"; local temp_file; temp_file=$(create_temp_file)
        if ! curl -fsSL "${BASE_URL}/${file}?_=$(date +%s)" -o "$temp_file"; then log_err "下载 ${file} 失败。" >&2; continue; fi
        local remote_hash; remote_hash=$(sed 's/\r$//' < "$temp_file" | sha256sum | awk '{print $1}')
        local local_hash="no_local_file"; [ -f "$local_path" ] && local_hash=$(sed 's/\r$//' < "$local_path" | sha256sum | awk '{print $1}')
        if [ "$local_hash" != "$remote_hash" ]; then
            updated_files+=("$file"); sudo mv "$temp_file" "$local_path"
            if [[ "$file" == *".sh" ]]; then sudo chmod +x "$local_path"; fi
        else rm -f "$temp_file"; fi
    done
    local scripts_to_update; scripts_to_update=$(jq -r '.menus[] | .items[]? | select(.type == "item").action' "$CONFIG_PATH" 2>/dev/null || true)
    for script_name in $scripts_to_update; do if download_module_to_cache "$script_name" "auto"; then updated_files+=("$script_name"); fi; done
    echo "${updated_files[@]}"
}

download_module_to_cache() {
    local script_name="$1"; local mode="${2:-}"; local local_file="${INSTALL_DIR}/$script_name"; local tmp_file; tmp_file=$(create_temp_file)
    if [ "$mode" != "auto" ]; then log_info "  -> 检查/下载模块: ${script_name}" >&2; fi
    sudo mkdir -p "$(dirname "$local_file")"
    if ! curl -fsSL "${BASE_URL}/${script_name}?_=$(date +%s)" -o "$tmp_file"; then
        if [ "$mode" != "auto" ]; then log_err "     模块 (${script_name}) 下载失败。" >&2; fi
        return 1
    fi
    local remote_hash; remote_hash=$(sed 's/\r$//' < "$tmp_file" | sha256sum | awk '{print $1}')
    local local_hash="no_local_file"; [ -f "$local_file" ] && local_hash=$(sed 's/\r$//' < "$local_file" | sha256sum | awk '{print $1}')
    if [ "$local_hash" != "$remote_hash" ]; then
        if [ "$mode" != "auto" ]; then log_success "     模块 (${script_name}) 已更新。" >&2; fi
        sudo mv "$tmp_file" "$local_file"; sudo chmod +x "$local_file"; return 0
    else rm -f "$tmp_file"; return 1; fi
}

uninstall_script() {
    log_warn "警告: 这将从您的系统中彻底移除本脚本及其所有组件！" >&2; log_warn "  - 安装目录: ${INSTALL_DIR}" >&2; log_warn "  - 快捷方式: ${BIN_DIR}/jb" >&2
    local choice; read -r -p "$(echo -e "${RED}这是一个不可逆的操作, 您确定要继续吗? (请输入 'yes' 确认): ${NC}")" choice < /dev/tty
    if [ "$choice" = "yes" ]; then log_info "开始卸载..." >&2; run_with_sudo rm -f "${BIN_DIR}/jb" || true; run_with_sudo rm -rf "$INSTALL_DIR" || true; log_success "脚本已成功卸载。再见！" >&2; exit 0; else log_info "卸载操作已取消。" >&2; fi
}

confirm_and_force_update() {
    log_warn "警告: 这将从 GitHub 强制拉取所有最新脚本和【主配置文件 config.json】。" >&2; log_warn "您对 config.json 的【所有本地修改都将丢失】！这是一个恢复出厂设置的操作。" >&2
    local choice; read -r -p "$(echo -e "${RED}此操作不可逆，请输入 'yes' 确认继续: ${NC}")" choice < /dev/tty
    if [ "$choice" = "yes" ]; then
        log_info "用户确认：开始强制更新所有组件..." >&2; 
        flock -u 200 2>/dev/null || true; trap - EXIT
        FORCE_REFRESH=true bash -c "$(curl -fsSL ${BASE_URL}/install.sh?_=$(date +%s))"
        log_success "强制更新完成！脚本将自动重启以应用所有更新..." >&2; sleep 2
        exec sudo -E bash "$FINAL_SCRIPT_PATH" "$@"
    else log_info "用户取消了强制更新。" >&2; fi
}

run_module(){
    local module_script="$1"; local module_name="$2"; local module_path="${INSTALL_DIR}/${module_script}";
    if [ ! -f "$module_path" ]; then log_info "模块首次运行，正在下载..." >&2; download_module_to_cache "$module_script"; fi
    
    local filename_only="${module_script##*/}"; local key_base="${filename_only%.sh}"; local module_key="${key_base,,}"
    
    if command -v jq >/dev/null 2>&1 && jq -e --arg key "$module_key" '.module_configs | has($key)' "$CONFIG_PATH" >/dev/null 2>&1; then
        local module_config_json; module_config_json=$(jq -r --arg key "$module_key" '.module_configs[$key]' "$CONFIG_PATH")
        local prefix_base="${module_key^^}"

        echo "$module_config_json" | jq -r 'keys[]' | while IFS= read -r key; do
            if [[ "$key" == "comment_"* ]]; then continue; fi
            local value; value=$(echo "$module_config_json" | jq -r --arg subkey "$key" '.[$subkey]')
            local upper_key="${key^^}"
            export "${prefix_base}_CONF_${upper_key}"="$value"
        done
    fi
    
    set +e; bash "$module_path"; local exit_code=$?; set -e
    
    if [ "$exit_code" -eq 0 ]; then 
        log_success "模块 [${module_name}] 执行完毕。" >&2;
    elif [ "$exit_code" -eq 10 ]; then 
        log_info "已从 [${module_name}] 返回。" >&2;
    else 
        log_warn "模块 [${module_name}] 执行出错 (代码: ${exit_code})。" >&2;
    fi
    return $exit_code
}

_get_docker_status() {
    local docker_ok=false compose_ok=false status_str=""; if systemctl is-active --quiet docker 2>/dev/null; then docker_ok=true; fi; if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>&1; then compose_ok=true; fi
    if $docker_ok && $compose_ok; then echo -e "${GREEN}已运行${NC}"; else if ! $docker_ok; then status_str+="Docker${RED}未运行${NC} "; fi; if ! $compose_ok; then status_str+="Compose${RED}未找到${NC}"; fi; echo -e "$status_str"; fi
}
_get_nginx_status() { if systemctl is-active --quiet nginx 2>/dev/null; then echo -e "${GREEN}已运行${NC}"; else echo -e "${RED}未运行${NC}"; fi; }
_get_watchtower_status() {
    if systemctl is-active --quiet docker 2>/dev/null; then if run_with_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qFx 'watchtower'; then echo -e "${GREEN}已运行${NC}"; else echo -e "${YELLOW}未运行${NC}"; fi; else echo -e "${RED}Docker未运行${NC}"; fi
}

display_and_process_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        local menu_json; menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$CONFIG_PATH" 2>/dev/null || "")
        if [ -z "$menu_json" ]; then log_warn "菜单配置 '$CURRENT_MENU_NAME' 读取失败，回退到主菜单." >&2; CURRENT_MENU_NAME="MAIN_MENU"; menu_json=$(jq -r --arg menu "MAIN_MENU" '.menus[$menu]' "$CONFIG_PATH" 2>/dev/null || ""); fi
        if [ -z "$menu_json" ]; then log_err "致命错误：无法加载任何菜单。" >&2; exit 1; fi

        local menu_title; menu_title=$(jq -r '.title' <<< "$menu_json"); local -a primary_items=() func_items=()
        
        # 优化: 使用 // "" 确保 jq 输出空字符串而非 null，避免解析错误
        while IFS=$'\t' read -r icon name type action; do
            local item_data="$icon|$name|$type|$action"
            if [[ "$type" == "item" || "$type" == "submenu" ]]; then primary_items+=("$item_data"); elif [[ "$type" == "func" ]]; then func_items+=("$item_data"); fi
        done < <(jq -r '.items[] | [.icon // "", .name // "", .type // "", .action // ""] | @tsv' <<< "$menu_json" 2>/dev/null || true)
        
        local -a formatted_items_for_render=() first_cols_content=() second_cols_content=()
        local max_first_col_width=0
        local -A status_map=( ["docker"]="$(_get_docker_status)" ["nginx"]="$(_get_nginx_status)" ["watchtower"]="$(_get_watchtower_status)" )
        local -A status_label_map=( ["docker"]="Docker:" ["nginx"]="Nginx:" ["watchtower"]="Watchtower:" )

        for item_data in "${primary_items[@]}"; do
            IFS='|' read -r icon name type action <<< "$item_data"; local status_text="" status_key=""
            if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then
                case "$action" in "docker.sh") status_key="docker" ;; "nginx.sh") status_key="nginx" ;; "TOOLS_MENU") status_key="watchtower" ;; esac
            fi
            if [ -n "$status_key" ] && [ -n "${status_map[$status_key]}" ]; then status_text="${status_label_map[$status_key]} ${status_map[$status_key]}"; fi
            
            # 优化: 兼容无图标显示，移除多余空格
            local idx="$(( ${#first_cols_content[@]} + 1 ))"
            local first_col_display_content
            if [ -n "$icon" ]; then
                first_col_display_content="$(printf "%d. %s %s" "$idx" "$icon" "$name")"
            else
                first_col_display_content="$(printf "%d. %s" "$idx" "$name")"
            fi

            first_cols_content+=("$first_col_display_content"); second_cols_content+=("$status_text")
            if [ -n "$status_text" ]; then
                local current_visual_width=$(_get_visual_width "$first_col_display_content")
                if [ "$current_visual_width" -gt "$max_first_col_width" ]; then max_first_col_width="$current_visual_width"; fi
            fi
        done

        for i in "${!first_cols_content[@]}"; do
            local first_col="${first_cols_content[i]}"; local second_col="${second_cols_content[i]}"
            if [ -n "$second_col" ]; then
                local padding=$((max_first_col_width - $(_get_visual_width "$first_col")))
                formatted_items_for_render+=("${first_col}$(printf '%*s' "$padding") ${CYAN}- ${NC}${second_col}")
            else formatted_items_for_render+=("${first_col}"); fi
        done

        local func_letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
        for i in "${!func_items[@]}"; do 
            IFS='|' read -r icon name type action <<< "${func_items[i]}"; 
            # 优化: 功能键菜单项兼容无图标
            if [ -n "$icon" ]; then
                formatted_items_for_render+=("$(printf "%s. %s %s" "${func_letters[i]}" "$icon" "$name")")
            else
                formatted_items_for_render+=("$(printf "%s. %s" "${func_letters[i]}" "$name")")
            fi
        done
        
        _render_menu "$menu_title" "${formatted_items_for_render[@]}"
        
        local num_choices=${#primary_items[@]}
        local numeric_range_str=""
        if [ "$num_choices" -gt 0 ]; then
            numeric_range_str="1-$num_choices"
        fi
        
        local func_choices_str=""
        if [ ${#func_items[@]} -gt 0 ]; then
            local temp_func_str=""
            for ((i=0; i<${#func_items[@]}; i++)); do temp_func_str+="${func_letters[i]},"; done
            func_choices_str="${temp_func_str%,}"
        fi
        
        local choice
        choice=$(_prompt_for_menu_choice "$numeric_range_str" "$func_choices_str")

        if [ -z "$choice" ]; then 
            if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then log_info "用户选择退出，脚本正常终止。" >&2; exit 0; else CURRENT_MENU_NAME="MAIN_MENU"; continue; fi
        fi
        
        local item_json=""
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$num_choices" ]; then item_json=$(jq -r --argjson idx "$((choice-1))" '.items | map(select(.type == "item" or .type == "submenu")) | .[$idx]' <<< "$menu_json")
        else for ((i=0; i<${#func_items[@]}; i++)); do if [ "$choice" = "${func_letters[i]}" ]; then item_json=$(jq -r --argjson idx "$i" '.items | map(select(.type == "func")) | .[$idx]' <<< "$menu_json"); break; fi; done; fi
        if [ -z "$item_json" ]; then log_warn "无效选项。" >&2; sleep 1; continue; fi
        
        local type name action exit_code=0
        type=$(jq -r .type <<< "$item_json"); name=$(jq -r .name <<< "$item_json"); action=$(jq -r .action <<< "$item_json")
        
        case "$type" in 
            item) 
                run_module "$action" "$name" || exit_code=$? 
                ;; 
            submenu) CURRENT_MENU_NAME="$action" ;; 
            func) "$action" "$@"; exit_code=$? ;; 
        esac
        
        if [ "$type" != "submenu" ] && [ "$exit_code" -ne 10 ]; then press_enter_to_continue; fi
    done
}

main() {
    load_config "$CONFIG_PATH"; check_and_install_dependencies
    
    # 显式设置 trap，在主程序逻辑开始时
    trap 'exit_code=$?; cleanup_temp_files; flock -u 200; rm -f "$LOCK_FILE" 2>/dev/null || true; log_info "脚本已退出 (代码: ${exit_code})" >&2' EXIT INT TERM
    
    exec 200>"$LOCK_FILE"; if ! flock -n 200; then log_err "脚本已在运行。" >&2; exit 1; fi
    
    if [ $# -gt 0 ]; then
        local command="$1"; shift
        case "$command" in
            update) log_info "正在以 Headless 模式更新所有脚本..." >&2; run_comprehensive_auto_update "$@"; exit 0 ;;
            uninstall) log_info "正在以 Headless 模式执行卸载..." >&2; uninstall_script; exit 0 ;;
            *) local action_to_run; action_to_run=$(jq -r --arg cmd "$command" '.menus[] | .items[]? | select(.action and (.action | contains($cmd)) or (.name | ascii_downcase | contains($cmd))) | .action' "$CONFIG_PATH" 2>/dev/null | head -n 1)
                if [ -n "$action_to_run" ]; then local display_name; display_name=$(jq -r --arg act "$action_to_run" '.menus[] | .items[]? | select(.action == $act) | .name' "$CONFIG_PATH" 2>/dev/null | head -n 1); log_info "正在以 Headless 模式执行: ${display_name}" >&2; run_module "$action_to_run" "$display_name" "$@"; exit $?; else log_err "未知命令: $command" >&2; exit 1; fi ;;
        esac
    fi
    
    log_info "脚本启动 (${SCRIPT_VERSION})" >&2

    if [ "${JB_RESTARTED:-false}" != "true" ]; then
        printf "$(_log_prefix)${CYAN}[信 息]${NC} 正 在 全 面 智 能 更 新 🕛 " >&2
        local updated_files_list; updated_files_list=$(run_comprehensive_auto_update "$@")
        printf "\r$(_log_prefix)${GREEN}[成 功]${NC} 全 面 智 能 更 新 检 查 完 成 🔄          \n" >&2

        local restart_needed=false
        local update_messages=""

        if [ -n "$updated_files_list" ]; then
            for file in $updated_files_list; do
                local filename; filename=$(basename "$file")
                if [[ "$filename" == "install.sh" ]]; then
                    restart_needed=true
                    update_messages+="主程序 (install.sh) 已更新\n"
                else
                    update_messages+="${GREEN}${filename}${NC} 已更新\n"
                fi
            done
            if [[ " ${updated_files_list} " == *"config.json"* ]]; then
                update_messages+="  > 配置文件 config.json 已更新，部分默认设置可能已改变。\n"
            fi

            if [ -n "$update_messages" ]; then
                log_info "发现以下更新:" >&2
                echo -e "$update_messages" | while IFS= read -r line; do
                    if [ -n "$line" ]; then
                        log_success "$line" >&2
                    fi
                done
            fi

            if [ "$restart_needed" = true ]; then
                log_success "正在无缝重启主程序 (install.sh) 以应用更新... 🚀" >&2
                flock -u 200 2>/dev/null || true; trap - EXIT
                exec sudo -E JB_RESTARTED="true" bash "$FINAL_SCRIPT_PATH" "$@"
            fi
        fi
    else
        log_info "脚本已由自身重启，跳过初始更新检查。" >&2
    fi
    
    check_sudo_privileges; display_and_process_menu "$@"
}

main "$@"
