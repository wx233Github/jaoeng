# =============================================================
# 🚀 通用工具函数库 (v3.1.0-交互优化)
# - 新增: 添加了 `_render_menu_prompt` 函数，用于生成全新的、
#         带有颜色和符号的标准化菜单输入提示符，以增强用户体验。
# - 更新: 脚本版本号。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v3.1.0"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C_UTF_8}

# --- 全局变量与颜色定义 ---
GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; BLUE="\033[0;34m";
MAGENTA="\033[0;35m"; CYAN="\033[0;36m"; WHITE="\033[0;37m"; BOLD="\033[1m"; NC="\033[0m";

# --- 基础函数 ---
log_timestamp() {
    echo -n "$(date +"%Y-%m-%d %H:%M:%S")"
}

log_err() {
    echo -e "$(log_timestamp) ${RED}[错 误]${NC} $*" >&2
}

log_info() {
    echo -e "$(log_timestamp) ${BLUE}[信 息]${NC} $*" >&2
}

log_warn() {
    echo -e "$(log_timestamp) ${YELLOW}[警 告]${NC} $*" >&2
}

log_success() {
    echo -e "$(log_timestamp) ${GREEN}[成 功]${NC} $*" >&2
}

log_debug() {
    if [ "${JB_ENABLE_DEBUG:-false}" = "true" ]; then
        echo -e "$(log_timestamp) ${MAGENTA}[调 试]${NC} $*" >&2
    fi
}

_get_visual_width() {
    local text="$1"
    local visual_len
    visual_len=$(echo -n "$text" | sed 's/\x1b\[[0-9;]*m//g' | wc -m)
    echo "$visual_len"
}

_render_menu() {
    local title="$1"; shift
    local max_width=40
    local title_visual_len=$(_get_visual_width "$title")
    local title_padding=$(( (max_width - title_visual_len) / 2 ))

    echo -e "╭$(printf '─%.0s' $(seq 1 "$max_width"))╮"
    echo -e "│$(printf ' %.0s' $(seq 1 "$title_padding"))${BOLD}${title}${NC}$(printf ' %.0s' $(seq 1 "$((max_width - title_padding - title_visual_len))"))│"
    echo -e "╰$(printf '─%.0s' $(seq 1 "$max_width"))╯"
    
    for item in "$@"; do
        echo -e "$item"
    done
    echo -e "──────────────────────────────────────────"
}

_render_menu_prompt() {
    local num_choices="$1"
    local func_choices_str="$2"

    local prompt="${BLUE}>${NC} "
    prompt+="选项 [1-${num_choices}]"

    if [ -n "$func_choices_str" ]; then
        prompt+=" (${func_choices_str} 操作)"
    fi

    prompt+=" (↩ 返回): "
    echo -e "$prompt"
}

_prompt_user_input() {
    local prompt_message="$1"
    local default_value="${2:-}"
    local user_input
    read -r -p "$(echo -e "${CYAN}${prompt_message}${NC} [默认: ${GREEN}${default_value:-无}${NC}]: ")" user_input < /dev/tty
    echo "${user_input:-$default_value}"
}

press_enter_to_continue() {
    read -r -p "$(echo -e "按 Enter 键继续...")" < /dev/tty
}

confirm_action() {
    local prompt_message="$1"
    local choice
    read -r -p "$(echo -e "${YELLOW}${prompt_message}${NC} ([y]/n): ")" choice < /dev/tty
    case "$choice" in
        [nN]) return 1 ;;
        *) return 0 ;;
    esac
}

load_config() {
    local config_file="$1"
    if [ ! -f "$config_file" ]; then
        log_err "配置文件 '$config_file' 未找到。"
        return 1
    fi
    
    export BASE_URL; BASE_URL=$(jq -r '.repository.base_url' "$config_file")
    export LOCK_FILE; LOCK_FILE=$(jq -r '.system.lock_file' "$config_file")
    export JB_TIMEZONE; JB_TIMEZONE=$(jq -r '.system.timezone' "$config_file")
    export JB_ENABLE_DEBUG; JB_ENABLE_DEBUG=$(jq -r '.system.enable_debug' "$config_file")
    export JB_ENABLE_AUTO_CLEAR; JB_ENABLE_AUTO_CLEAR=$(jq -r '.system.enable_auto_clear' "$config_file")
    
    log_debug "配置已加载: BASE_URL=${BASE_URL}, LOCK_FILE=${LOCK_FILE}, TIMEZONE=${JB_TIMEZONE}"
}

create_temp_file() {
    mktemp 2>/dev/null || mktemp -t jb_temp.XXXXXX
}
