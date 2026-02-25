# =============================================================
# 🚀 通用工具函数库 (v2.44-标准版 & 性能优化)
# - 优化: generate_line 移除 sed 依赖，使用 Bash 原生字符串替换，提升性能。
# - 恢复: UI 输出回到标准流，日志保持在错误流。
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
  ORANGE='\033[38;5;208m'; # 橙色 #FA720A
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""; BOLD=""; ORANGE="";
fi

# --- 日志系统 ---
_log_prefix() {
    if [ "${JB_LOG_WITH_TIMESTAMP:-${DEFAULT_LOG_WITH_TIMESTAMP}}" = "true" ]; then
        echo -n "$(date '+%Y-%m-%d %H:%M:%S') "
    fi
}
log_info()    { echo -e "$(_log_prefix)${CYAN}[信 息]${NC} $*"; }
log_success() { echo -e "$(_log_prefix)${GREEN}[成 功]${NC} $*"; }
log_warn()    { echo -e "$(_log_prefix)${YELLOW}[警 告]${NC} $*" >&2; }
log_err()     { echo -e "$(_log_prefix)${RED}[错 误]${NC} $*" >&2; }
log_debug()   {
    if [ "${JB_DEBUG_MODE:-false}" = "true" ]; then
        echo -e "$(_log_prefix)${YELLOW}[DEBUG]${NC} $*" >&2
    fi
}

# --- 交互函数 ---
_prompt_user_input() {
    local prompt_text="$1"
    local default_value="$2"
    local result
    
    echo -ne "${YELLOW}${prompt_text}${NC}" > /dev/tty
    read -r result < /dev/tty
    
    if [ -z "$result" ]; then
        echo "$default_value"
    else
        echo "$result"
    fi
}

_prompt_for_menu_choice() {
    local numeric_range="$1"
    local func_options="${2:-}"
    local prompt_text="${ORANGE}>${NC} 选项 "

    if [ -n "$numeric_range" ]; then
        local start="${numeric_range%%-*}"
        local end="${numeric_range##*-}"
        if [ "$start" = "$end" ]; then
            prompt_text+="[${ORANGE}${start}${NC}] "
        else
            prompt_text+="[${ORANGE}${start}${NC}-${end}] "
        fi
    fi

    if [ -n "$func_options" ]; then
        local start="${func_options%%,*}"
        local rest="${func_options#*,}"
        if [ "$start" = "$rest" ]; then
             prompt_text+="[${ORANGE}${start}${NC}] "
        else
             prompt_text+="[${ORANGE}${start}${NC},${rest}] "
        fi
    fi
    
    prompt_text+="(↩ 返回): "
    
    local choice
    read -r -p "$(echo -e "$prompt_text")" choice < /dev/tty
    echo "$choice"
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }
confirm_action() { read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice < /dev/tty; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

# --- 配置加载 (优化版) ---
_get_json_value_fallback() {
    local file="$1"; local key="$2"; local default_val="$3"
    local result; result=$(sed -n 's/.*"'"$key"'": *"\([^"]*\)".*/\1/p' "$file")
    echo "${result:-$default_val}"
}

load_config() {
    local config_path="${1:-${CONFIG_PATH:-${DEFAULT_CONFIG_PATH}}}"
    BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"; INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"; BIN_DIR="${BIN_DIR:-$DEFAULT_BIN_DIR}"; LOCK_FILE="${LOCK_FILE:-$DEFAULT_LOCK_FILE}"; JB_TIMEZONE="${JB_TIMEZONE:-$DEFAULT_TIMEZONE}"; CONFIG_PATH="$config_path"; JB_LOG_WITH_TIMESTAMP="${JB_LOG_WITH_TIMESTAMP:-$DEFAULT_LOG_WITH_TIMESTAMP}"
    
    if [ ! -f "$config_path" ]; then log_warn "配置文件 $config_path 未找到，使用默认配置。"; return 0; fi
    
    if command -v jq >/dev/null 2>&1; then
        BASE_URL=$(jq -r '.base_url // empty' "$config_path" 2>/dev/null || echo "$BASE_URL")
        INSTALL_DIR=$(jq -r '.install_dir // empty' "$config_path" 2>/dev/null || echo "$INSTALL_DIR")
        BIN_DIR=$(jq -r '.bin_dir // empty' "$config_path" 2>/dev/null || echo "$BIN_DIR")
        LOCK_FILE=$(jq -r '.lock_file // empty' "$config_path" 2>/dev/null || echo "$LOCK_FILE")
        JB_TIMEZONE=$(jq -r '.timezone // empty' "$config_path" 2>/dev/null || echo "$JB_TIMEZONE")
        JB_LOG_WITH_TIMESTAMP=$(jq -r '.log_with_timestamp // false' "$config_path" 2>/dev/null || echo "$JB_LOG_WITH_TIMESTAMP")
    else
        log_warn "未检测到 jq，使用轻量文本解析。"; 
        BASE_URL=$(_get_json_value_fallback "$config_path" "base_url" "$BASE_URL")
        INSTALL_DIR=$(_get_json_value_fallback "$config_path" "install_dir" "$INSTALL_DIR")
        BIN_DIR=$(_get_json_value_fallback "$config_path" "bin_dir" "$BIN_DIR")
        LOCK_FILE=$(_get_json_value_fallback "$config_path" "lock_file" "$LOCK_FILE")
        JB_TIMEZONE=$(_get_json_value_fallback "$config_path" "timezone" "$JB_TIMEZONE")
        JB_LOG_WITH_TIMESTAMP=$(_get_json_value_fallback "$config_path" "log_with_timestamp" "$JB_LOG_WITH_TIMESTAMP")
    fi
}

# --- UI 渲染 & 字符串处理 (性能优化版) ---
generate_line() {
    local len=${1:-40}; local char=${2:-"─"}
    if [ "$len" -le 0 ]; then echo ""; return; fi
    
    # [优化点] 使用 Bash 原生 printf 和字符串替换，避免 fork sed 子进程
    # 旧方法: printf "%${len}s" "" | sed "s/ /$char/g"  (生成速度快，但多一个进程)
    # 新方法: Bash 参数扩展替换 (纯内存操作)
    local spaces
    printf -v spaces "%${len}s" ""
    echo "${spaces// /$char}"
}

_get_visual_width() {
    local text="$1"; local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    if [ -z "$plain_text" ]; then echo 0; return; fi
    if command -v python3 &>/dev/null; then
        python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<< "$plain_text" 2>/dev/null || echo "${#plain_text}"
    elif command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
        echo -n "$plain_text" | wc -m
    else
        echo "${#plain_text}"
    fi
}

_render_menu() {
    local title="$1"; shift; local -a lines=("$@")
    local max_content_width=0
    local title_width=$(_get_visual_width "$title")
    max_content_width=$title_width
    for line in "${lines[@]}"; do
        local current_line_visual_width=$(_get_visual_width "$line")
        if [ "$current_line_visual_width" -gt "$max_content_width" ]; then
            max_content_width="$current_line_visual_width"
        fi
    done
    local box_inner_width=$max_content_width
    if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi
    
    echo ""
    echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    if [ -n "$title" ]; then
        local padding_total=$((box_inner_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        echo -e "${GREEN}│${NC}$(printf '%*s' "$padding_left")${BOLD}${title}${NC}$(printf '%*s' "$padding_right")${GREEN}│${NC}"
    fi
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
    for line in "${lines[@]}"; do
        echo -e "${line}"
    done
    local box_total_physical_width=$(( box_inner_width + 2 ))
    echo -e "${GREEN}$(generate_line "$box_total_physical_width" "─")${NC}"
}
