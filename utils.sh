#!/bin/bash
# =============================================================
# 🚀 脚本工具库 (v2.0-移除tr依赖)
# - 重写 load_config 函数，彻底移除 tr 依赖
# =============================================================

# --- [颜色与日志] ---
# shellcheck disable=SC2034
{
    BLACK='\033[0;30m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m';
    BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; WHITE='\033[0;37m';
    NC='\033[0m'; BOLD='\033[1m'; UNDERLINE='\033[4m';
}

log_info() { echo -e "$(date +"%Y-%m-%d %H:%M:%S") [${BLUE}信 息${NC}] $*"; }
log_success() { echo -e "$(date +"%Y-%m-%d %H:%M:%S") [${GREEN}成 功${NC}] $*"; }
log_warn() { echo -e "$(date +"%Y-%m-%d %H:%M:%S") [${YELLOW}警 告${NC}] $*" >&2; }
log_err() { echo -e "$(date +"%Y-%m-%d %H:%M:%S") [${RED}错 误${NC}] $*" >&2; }
log_debug() { if [ "${JB_DEBUG_MODE:-false}" = "true" ]; then echo -e "[${PURPLE}调试${NC}] (L${BASH_LINENO[0]}) ${FUNCNAME[1]}: $*" >&2; fi; }

# --- [用户交互] ---
confirm_action() {
    local prompt="${1:-确定要执行此操作吗?}"
    while true; do
        read -r -p "$(log_info "${prompt} [y/N]: ")" response < /dev/tty
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) log_warn "无效输入，请输入 'y' 或 'n'。" ;;
        esac
    done
}

press_enter_to_continue() {
    echo -e "${CYAN}------------------------------------${NC}"
    read -r -p "请按 Enter 键返回菜单..." < /dev/tty
}

# --- [文件与系统] ---
create_temp_file() {
    mktemp "/tmp/jb_temp.XXXXXX"
}

# --- [核心功能] ---
load_config() {
    local config_file="$1"
    if [ ! -f "$config_file" ]; then
        log_warn "配置文件 $config_file 不存在，将使用默认值。"
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq 命令未找到，无法加载配置文件，将使用默认值。"
        return
    fi

    local config_content
    config_content=$(jq '.' "$config_file" 2>/dev/null)
    if [ -z "$config_content" ]; then
        log_warn "无法解析配置文件 $config_file，将使用默认值。"
        return
    fi

    _assign_from_json() {
        local var_name="$1"
        local json_key="$2"
        local value
        value=$(jq -r ".$json_key // \"\"" <<< "$config_content")
        if [ -n "$value" ]; then
            printf -v "$var_name" '%s' "$value"
        fi
    }

    _assign_from_json "BASE_URL" "base_url"
    _assign_from_json "INSTALL_DIR" "install_dir"
    _assign_from_json "BIN_DIR" "bin_dir"
    _assign_from_json "LOCK_FILE" "lock_file"
    _assign_from_json "JB_ENABLE_AUTO_CLEAR" "enable_auto_clear"
    _assign_from_json "JB_TIMEZONE" "timezone"
}

# --- [UI 渲染] ---
_render_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local terminal_width; terminal_width=$(tput cols 2>/dev/null || echo 80)
    
    # 打印标题
    local title_len=${#title}
    local padding=$(( (terminal_width - title_len) / 2 ))
    printf "\n%*s%s\n" "$padding" "" "${BOLD}${CYAN}${title}${NC}"
    
    # 打印分隔线
    printf "%s\n" "${BLUE}$(printf '─%.0s' $(seq 1 "$terminal_width"))${NC}"
    
    # 打印菜单项
    for item in "${items[@]}"; do
        echo -e "  $item"
    done
    
    # 打印底部线
    printf "%s\n" "${BLUE}$(printf '─%.0s' $(seq 1 "$terminal_width"))${NC}"
}
