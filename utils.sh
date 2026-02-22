# =============================================================
# 🚀 通用工具函数库 (v2.6.0 - 新增网络连通性检查)
# - 新增: check_network_connectivity 函数，用于下载前预检
# - 优化: _render_menu 边框渲染逻辑
# =============================================================

# --- 严格模式 ---
set -eo pipefail

# --- 默认配置 ---
DEFAULT_BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
DEFAULT_INSTALL_DIR="/opt/vps_install_modules"
DEFAULT_BIN_DIR="/usr/local/bin"
DEFAULT_LOCK_FILE="/tmp/vps_install_modules.lock"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_CONFIG_PATH="${DEFAULT_INSTALL_DIR}/config.json"
DEFAULT_LOG_WITH_TIMESTAMP="false"

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
  ORANGE='\033[38;5;208m';
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""; BOLD=""; ORANGE="";
fi

# --- 日志系统 ---
_utils_log_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

_utils_write_log() {
    local level="$1"; local msg="$2"; local color="$3"
    # Console Output
    if [ "${JB_VERBOSE:-false}" = "true" ]; then
        printf "[%s] ${color}[%s]${NC} %s\n" "$(_utils_log_timestamp)" "$level" "$msg" >&2
    else
        printf "${color}[%s]${NC} %s\n" "$level" "$msg" >&2
    fi
    # File Output
    if [ -n "${GLOBAL_LOG_FILE:-}" ] && [ -d "${INSTALL_DIR:-}" ]; then
        printf "[%s] [%s] %s\n" "$(_utils_log_timestamp)" "$level" "$msg" >> "$GLOBAL_LOG_FILE" 2>/dev/null || true
    fi
}

log_info()    { _utils_write_log "INFO" "$*" "$CYAN"; }
log_success() { _utils_write_log "SUCCESS" "$*" "$GREEN"; }
log_warn()    { _utils_write_log "WARN" "$*" "$YELLOW"; }
log_err()     { _utils_write_log "ERROR" "$*" "$RED"; }
log_debug()   {
    if [ "${JB_VERBOSE:-false}" = "true" ] || [ "${JB_DEBUG_MODE:-false}" = "true" ]; then
        _utils_write_log "DEBUG" "$*" "\033[0;35m"
    fi
}

# --- 网络检查 (新增) ---
check_network_connectivity() {
    local target="${1:-www.github.com}"
    local timeout="${2:-5}"
    
    log_debug "正在检查网络连通性: $target (超时: ${timeout}s)"
    
    if command -v curl >/dev/null 2>&1; then
        if curl -I --connect-timeout "$timeout" -s "$target" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W "$timeout" "$target" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    log_warn "无法连接到 $target，可能存在网络问题。"
    return 1
}

# --- 交互函数 ---
_prompt_user_input() {
    local prompt_text="$1"; local default_value="$2"; local result
    printf "${YELLOW}%s${NC}" "$prompt_text" > /dev/tty
    read -r result < /dev/tty
    if [ -z "$result" ]; then echo "$default_value"; else echo "$result"; fi
}

_prompt_for_menu_choice() {
    local numeric_range="$1"; local func_options="${2:-}"
    local prompt_text="${ORANGE}>${NC} 选项 "
    if [ -n "$numeric_range" ]; then
        local start="${numeric_range%%-*}"; local end="${numeric_range##*-}"
        [ "$start" = "$end" ] && prompt_text+="[${ORANGE}${start}${NC}] " || prompt_text+="[${ORANGE}${start}${NC}-${end}] "
    fi
    if [ -n "$func_options" ]; then
        local start="${func_options%%,*}"; local rest="${func_options#*,}"
        [ "$start" = "$rest" ] && prompt_text+="[${ORANGE}${start}${NC}] " || prompt_text+="[${ORANGE}${start}${NC},${rest}] "
    fi
    prompt_text+="(↩ 返回): "
    local choice; read -r -p "$(printf "$prompt_text")" choice < /dev/tty
    echo "$choice"
}

press_enter_to_continue() { read -r -p "$(printf "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }
confirm_action() { local choice; read -r -p "$(printf "${YELLOW}$1 ([y]/n): ${NC}")" choice < /dev/tty; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

# --- 配置加载 ---
_get_json_value_fallback() {
    local file="$1"; local key="$2"; local default_val="$3"
    local result; result=$(sed -n 's/.*"'"$key"'": *"\([^"]*\)".*/\1/p' "$file")
    echo "${result:-$default_val}"
}

load_config() {
    local config_path="${1:-${CONFIG_PATH:-${DEFAULT_CONFIG_PATH}}}"
    BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"; INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"; BIN_DIR="${BIN_DIR:-$DEFAULT_BIN_DIR}"; LOCK_FILE="${LOCK_FILE:-$DEFAULT_LOCK_FILE}"; JB_TIMEZONE="${JB_TIMEZONE:-$DEFAULT_TIMEZONE}"; CONFIG_PATH="${config_path}"; JB_LOG_WITH_TIMESTAMP="${JB_LOG_WITH_TIMESTAMP:-$DEFAULT_LOG_WITH_TIMESTAMP}"
    
    if [ ! -f "$config_path" ]; then log_warn "配置文件未找到，使用默认。"; return 0; fi
    
    if command -v jq >/dev/null 2>&1; then
        BASE_URL=$(jq -r '.base_url // empty' "$config_path" 2>/dev/null || echo "$BASE_URL")
        INSTALL_DIR=$(jq -r '.install_dir // empty' "$config_path" 2>/dev/null || echo "$INSTALL_DIR")
        BIN_DIR=$(jq -r '.bin_dir // empty' "$config_path" 2>/dev/null || echo "$BIN_DIR")
        LOCK_FILE=$(jq -r '.lock_file // empty' "$config_path" 2>/dev/null || echo "$LOCK_FILE")
        JB_TIMEZONE=$(jq -r '.timezone // empty' "$config_path" 2>/dev/null || echo "$JB_TIMEZONE")
    else
        BASE_URL=$(_get_json_value_fallback "$config_path" "base_url" "$BASE_URL")
        INSTALL_DIR=$(_get_json_value_fallback "$config_path" "install_dir" "$INSTALL_DIR")
        BIN_DIR=$(_get_json_value_fallback "$config_path" "bin_dir" "$BIN_DIR")
        LOCK_FILE=$(_get_json_value_fallback "$config_path" "lock_file" "$LOCK_FILE")
    fi
}

# --- UI 渲染 ---
generate_line() {
    local len=${1:-40}; local char=${2:-"─"}
    if [ "$len" -le 0 ]; then echo ""; return; fi
    printf "%${len}s" "" | sed "s/ /$char/g"
}

_get_visual_width() {
    local text="$1"; local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    if [ -z "$plain_text" ]; then echo 0; return; fi
    # 优先使用 wc -m (字符计数)，因为 ${#var} 在某些 shell 对多字节字符支持不一致
    if command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
        printf "%s" "$plain_text" | wc -m
    elif command -v python3 &>/dev/null; then
        python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<< "$plain_text" 2>/dev/null || echo "${#plain_text}"
    else
        echo "${#plain_text}"
    fi
}

_render_menu() {
    local title="$1"; shift; local -a lines=("$@")
    local max_content_width=0
    local title_width; title_width=$(_get_visual_width "$title")
    max_content_width=$title_width
    for line in "${lines[@]}"; do
        local w; w=$(_get_visual_width "$line")
        if [ "$w" -gt "$max_content_width" ]; then max_content_width="$w"; fi
    done
    local box_inner_width=$max_content_width
    if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi
    
    printf "\n"
    printf "${GREEN}╭%s╮${NC}\n" "$(generate_line "$box_inner_width" "─")"
    if [ -n "$title" ]; then
        local padding_total=$((box_inner_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        printf "${GREEN}│${NC}%*s${BOLD}%s${NC}%*s${GREEN}│${NC}\n" "$padding_left" "" "$title" "$padding_right" ""
    fi
    printf "${GREEN}╰%s╯${NC}\n" "$(generate_line "$box_inner_width" "─")"
    for line in "${lines[@]}"; do
        printf "%s\n" "$line"
    done
    printf "${GREEN}%s${NC}\n" "$(generate_line "$((box_inner_width + 2))" "─")"
}
