#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.29-简化菜单渲染核心，修复语法)
# - 修复: _get_visual_width 函数中 if 语句的语法错误。
# - 优化: _render_menu 简化为纯粹的盒子渲染器，不再处理多列布局逻辑。
#         多列布局的格式化责任移交给调用方（如 install.sh）。
# =============================================================

# --- 严格模式 ---
set -eo pipefail

# --- 默认配置（集中一处） ---
DEFAULT_BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
DEFAULT_INSTALL_DIR="/opt/vps_install_modules"
DEFAULT_BIN_DIR="/usr/local/bin"
DEFAULT_LOCK_FILE="/tmp/vps_install_modules.lock"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_CONFIG_PATH="${DEFAULT_INSTALL_DIR}/config.json"

# --- 临时文件管理 ---
TEMP_FILES=()
create_temp_file() {
    local tmpfile
    tmpfile=$(mktemp "/tmp/jb_temp_XXXXXX") || {
        echo "[$(date '+%F %T')] [错误] 无法创建临时文件" >&2
        return 1
    }
    TEMP_FILES+=("$tmpfile")
    echo "$tmpfile"
}
cleanup_temp_files() {
    for f in "${TEMP_FILES[@]}"; do [ -f "$f" ] && rm -f "$f"; done
    TEMP_FILES=()
}
trap cleanup_temp_files EXIT INT TERM

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m';
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""; BOLD="";
fi

# --- 日志系统 ---
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info()    { echo -e "$(log_timestamp) ${BLUE}[信 息]${NC} $*"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成 功]${NC} $*"; }
log_warn()    { echo -e "$(log_timestamp) ${YELLOW}[警 告]${NC} $*" >&2; }
log_err()     { echo -e "$(log_timestamp) ${RED}[错 误]${NC} $*" >&2; }
log_debug()   {
    if [ "${JB_DEBUG_MODE:-false}" = "true" ]; then
        echo -e "$(log_timestamp) ${YELLOW}[DEBUG]${NC} $*" >&2
    fi
}

# --- 交互函数 ---
# 核心输入函数，确保提示符可见，并从 /dev/tty 读取以避免 stdin 重定向问题
_prompt_user_input() {
    local prompt_text="$1"
    local default_value="$2"
    local result
    
    # 确保提示符在终端上可见
    echo -ne "${YELLOW}${prompt_text}${NC}" > /dev/tty
    
    # 从 /dev/tty 读取输入，避免管道和重定向问题
    read -r result < /dev/tty
    
    # 返回结果，如果为空则返回默认值
    if [ -z "$result" ]; then
        echo "$default_value"
    else
        echo "$result"
    fi
}

press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }
confirm_action() { read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice < /dev/tty; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

# --- 配置加载（集中与容错） ---
_get_json_value_fallback() {
    local file="$1"; local key="$2"; local default_val="$3"
    local result; result=$(sed -n 's/.*"'"$key"'": *"\([^"]*\)".*/\1/p' "$file")
    echo "${result:-$default_val}"
}

load_config() {
    local config_path="${1:-${CONFIG_PATH:-${DEFAULT_CONFIG_PATH}}}"
    BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"; INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"; BIN_DIR="${BIN_DIR:-$DEFAULT_BIN_DIR}"; LOCK_FILE="${LOCK_FILE:-$DEFAULT_LOCK_FILE}"; JB_TIMEZONE="${JB_TIMEZONE:-$DEFAULT_TIMEZONE}"; CONFIG_PATH="${config_path}"
    if [ ! -f "$config_path" ]; then log_warn "配置文件 $config_path 未找到，使用默认配置。"; return 0; fi
    
    if command -v jq >/dev/null 2>&1; then
        BASE_URL=$(jq -r '.base_url // empty' "$config_path" 2>/dev/null || echo "$BASE_URL"); INSTALL_DIR=$(jq -r '.install_dir // empty' "$config_path" 2>/dev/null || echo "$INSTALL_DIR"); BIN_DIR=$(jq -r '.bin_dir // empty' "$config_path" 2>/dev/null || echo "$BIN_DIR"); LOCK_FILE=$(jq -r '.lock_file // empty' "$config_path" 2>/dev/null || echo "$LOCK_FILE"); JB_TIMEZONE=$(jq -r '.timezone // empty' "$config_path" 2>/dev/null || echo "$JB_TIMEZONE")
    else
        log_warn "未检测到 jq，使用轻量文本解析。建议安装 jq。"; 
        BASE_URL=$(_get_json_value_fallback "$config_path" "base_url" "$BASE_URL")
        INSTALL_DIR=$(_get_json_value_fallback "$config_path" "install_dir" "$INSTALL_DIR")
        BIN_DIR=$(_get_json_value_fallback "$config_path" "bin_dir" "$BIN_DIR")
        LOCK_FILE=$(_get_json_value_fallback "$config_path" "lock_file" "$LOCK_FILE")
        JB_TIMEZONE=$(_get_json_value_fallback "$config_path" "timezone" "$JB_TIMEZONE")
    fi
}

# --- UI 渲染 & 字符串处理 ---
generate_line() {
    local len=${1:-40}; local char=${2:-"─"}
    if [ "$len" -le 0 ]; then echo ""; return; fi
    printf "%${len}s" "" | sed "s/ /$char/g"
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

# 简化后的 _render_menu: 不再处理多列布局，只渲染一个左对齐的盒子。
# 多列布局的格式化责任移交给调用方。
_render_menu() {
    local title="$1"; shift; local -a lines=("$@")
    local box_inner_width=0

    # 确定盒子内部的最大内容宽度
    local current_line_visual_width
    for line in "${lines[@]}"; do
        current_line_visual_width=$(_get_visual_width "$line")
        if [ "$current_line_visual_width" -gt "$box_inner_width" ]; then
            box_inner_width="$current_line_visual_width"
        fi
    done

    local title_width=$(_get_visual_width "$title")
    if [ "$title_width" -gt "$box_inner_width" ]; then
        box_inner_width="$title_width"
    fi
    if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi # 最小宽度

    # 加上左右各一个空格的边距
    box_inner_width=$((box_inner_width + 2))

    echo ""; echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    if [ -n "$title" ]; then
        local padding_total=$((box_inner_width - title_width - 2)); # -2 for the spaces around title
        local padding_left=$((padding_total / 2));
        local padding_right=$((padding_total - padding_left));
        echo -e "${GREEN}│${NC} $(printf '%*s' "$padding_left")${GREEN}${BOLD}${title}${NC}$(printf '%*s' "$padding_right") ${GREEN}│${NC}"
    fi

    for line in "${lines[@]}"; do
        local content_width=$(_get_visual_width "$line")
        local total_padding=$((box_inner_width - content_width - 2)) # -2 for the spaces around content
        if [ $total_padding -lt 0 ]; then total_padding=0; fi
        
        echo -e "${GREEN}│${NC} ${line}$(printf '%*s' "$total_padding") ${GREEN}│${NC}"
    done
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
}
