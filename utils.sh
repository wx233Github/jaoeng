#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.40-修复UI与默认值解析)
# =============================================================

# --- 严格模式 ---
set -eo pipefail

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""
fi

# --- 日志系统 ---
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info()    { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $*"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $*"; }
log_warn()    { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $*"; }
log_err()     { echo -e "$(log_timestamp) ${RED}[错误]${NC} $*" >&2; }
# 调试模式，可以通过 export JB_DEBUG_MODE=true 启用
log_debug()   { [ "${JB_DEBUG_MODE:-false}" = "true" ] && echo -e "$(log_timestamp) ${YELLOW}[DEBUG]${NC} $*" >&2; }


# --- 用户交互函数 ---
press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty; }
confirm_action() { read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice < /dev/tty; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

# --- UI 渲染 & 字符串处理 ---
generate_line() {
    local len=${1:-40}
    local char=${2:-"─"}
    if [ "$len" -le 0 ]; then echo ""; return; fi
    printf "%${len}s" "" | sed "s/ /$char/g"
}

_get_visual_width() {
    local text="$1"
    local plain_text
    plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    log_debug "DEBUG: _get_visual_width input: '$text', plain_text: '$plain_text'"
    if [ -z "$plain_text" ]; then
        log_debug "DEBUG: Empty plain_text, returning 0"
        echo 0
        return
    fi

    # 优先使用 Python 计算显示宽度，处理多字节字符 (East Asian Width)
    if command -v python3 &>/dev/null; then
        local width
        width=$(python3 -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$plain_text" 2>/dev/null || true)
        if [ -n "$width" ] && [ "$width" -ge 0 ]; then
            log_debug "DEBUG: Python3 calculated width for '$plain_text': $width"
            echo "$width"
            return
        else
            log_debug "DEBUG: Python3 failed or returned invalid width for '$plain_text'. Trying fallback."
        fi
    elif command -v python &>/dev/null; then
        local width
        width=$(python -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$plain_text" 2>/dev/null || true)
        if [ -n "$width" ] && [ "$width" -ge 0 ]; then
            log_debug "DEBUG: Python calculated width for '$plain_text': $width"
            echo "$width"
            return
        else
            log_debug "DEBUG: Python failed or returned invalid width for '$plain_text'. Trying fallback."
        fi
    fi

    # Fallback to wc -m (character count) if Python is not available
    if command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
        local width
        width=$(echo -n "$plain_text" | wc -m)
        if [ -n "$width" ] && [ "$width" -ge 0 ]; then
            log_debug "DEBUG: wc -m calculated width for '$plain_text': $width"
            echo "$width"
            return
        else
            log_debug "DEBUG: wc -m failed or returned invalid width for '$plain_text'. Trying fallback."
        fi
    fi

    # Final fallback to character count (least accurate for CJK)
    local width=${#plain_text} # 这会计算字符数，对于 CJK 字符可能不准确
    log_warn "⚠️ 无法准确计算字符串宽度，可能导致排版问题。请确保安装 Python3 或 wc -m。Fallback width: $width"
    echo "$width"
}

# 增加内部边距，适配移动终端
_render_menu() {
    local title="$1"; shift
    local -a lines=("$@")
    
    local max_content_width=0 # 仅计算内容宽度，不含内部空格和边框
    
    local title_content_width=$(_get_visual_width "$title")
    if (( title_content_width > max_content_width )); then max_content_width=$title_content_width; fi

    for line in "${lines[@]}"; do
        local line_content_width=$(_get_visual_width "$line")
        if (( line_content_width > max_content_width )); then max_content_width=$line_content_width; fi
    done
    
    local inner_padding_chars=2 # 左右各一个空格，用于内容与边框之间的间距
    local box_inner_width=$((max_content_width + inner_padding_chars))
    if [ "$box_inner_width" -lt 38 ]; then box_inner_width=38; fi # 最小内容区域宽度 (38 + 2边框 = 40总宽)

    log_debug "DEBUG: _render_menu - title_content_width: $title_content_width, max_content_width: $max_content_width, box_inner_width: $box_inner_width"

    # 顶部
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    
    # 标题
    if [ -n "$title" ]; then
        local current_title_line_width=$((title_content_width + inner_padding_chars)) # 标题内容宽度 + 左右各1空格
        local padding_total=$((box_inner_width - current_title_line_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        
        local left_padding_str; left_padding_str=$(printf '%*s' "$padding_left")
        local right_padding_str; right_padding_str=$(printf '%*s' "$padding_right")

        log_debug "DEBUG: Title: '$title', padding_left: $padding_left, padding_right: $padding_right"
        echo -e "${GREEN}│${left_padding_str} ${title} ${right_padding_str}│${NC}"
    fi
    
    # 选项
    for line in "${lines[@]}"; do
        local line_content_width=$(_get_visual_width "$line")
        # 计算右侧填充：总内容区域宽度 - 当前行内容宽度 - 左侧一个空格
        local padding_right_for_line=$((box_inner_width - line_content_width - 1)) 
        if [ "$padding_right_for_line" -lt 0 ]; then padding_right_for_line=0; fi
        log_debug "DEBUG: Line: '$line', line_content_width: $line_content_width, padding_right_for_line: $padding_right_for_line"
        echo -e "${GREEN}│ ${line} $(printf '%*s' "$padding_right_for_line")${GREEN}│${NC}" # 左侧固定一个空格
    done

    # 底部
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
}
_print_header() { _render_menu "$1" ""; }


# --- 时间处理函数 (Watchtower 模块现在统一使用这些函数) ---

# 解析 Watchtower 日志行中的时间戳
_parse_watchtower_timestamp_from_log_line() {
    local log_line="$1"
    local timestamp=""

    # 1. Highest priority: "Scheduling first run: YYYY-MM-DD HH:MM:SS" format
    timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi

    # 2. Next priority: time="YYYY-MM-DDTHH:MM:SS+ZZ:ZZ" format
    timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    
    # 3. Next priority: YYYY-MM-DDTHH:MM:SSZ format (e.g. Watchtower 1.7.1)
    timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi

    echo ""
    return 1
}

# 将日期时间字符串转换为 Unix 时间戳 (epoch)
_date_to_epoch() {
    local dt="$1"
    [ -z "$dt" ] && echo "" && return 1 # 如果输入为空，返回空字符串并失败
    
    # 尝试使用 GNU date
    if date -d "now" >/dev/null 2>&1; then
        date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""; return 1)
    # 尝试使用 BSD date (通过 gdate 命令)
    elif command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1; then
        gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""; return 1)
    else
        log_warn "⚠️ 'date' 或 'gdate' 不支持。无法解析时间戳。"
        echo ""
        return 1
    fi
}

# 将秒数格式化为更易读的字符串 (例如 300s, 2h)
_format_seconds_to_human() {
    local seconds="$1"
    log_debug "DEBUG: _format_seconds_to_human received: '$seconds'"
    if ! echo "$seconds" | grep -qE '^[0-9]+$'; then
        log_debug "DEBUG: '$seconds' is not numeric, returning N/A."
        echo "N/A"
        return 0 # 修复：非数字输入时返回0，避免脚本因set -e退出
    fi
    
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}秒"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))分"
    elif [ "$seconds" -lt 86400 ]; then
        echo "$((seconds / 3600))时"
    else
        echo "$((seconds / 86400))天"
    fi
    return 0
}

# 交互式获取并验证时间间隔
_prompt_for_interval() {
    local default_interval="$1"
    local prompt_msg="$2"
    local input=""
    local interval_in_seconds=""

    while true; do
        read -r -p "$(echo -e "${YELLOW}${prompt_msg} (例如: 300, 5m, 1h, 当 前 : $(_format_seconds_to_human "$default_interval")): ${NC}")" input < /dev/tty
        input="${input:-$default_interval}" # 如果用户输入为空，则使用默认值

        # 尝试将输入转换为秒
        if echo "$input" | grep -qE '^[0-9]+$'; then
            interval_in_seconds="$input"
        elif echo "$input" | grep -qE '^[0-9]+s$'; then
            interval_in_seconds=$(echo "$input" | sed 's/s$//')
        elif echo "$input" | grep -qE '^[0-9]+m$'; then
            interval_in_seconds=$(( $(echo "$input" | sed 's/m$//') * 60 ))
        elif echo "$input" | grep -qE '^[0-9]+h$'; then
            interval_in_seconds=$(( $(echo "$input" | sed 's/h$//') * 3600 ))
        elif echo "$input" | grep -qE '^[0-9]+d$'; then
            interval_in_seconds=$(( $(echo "$input" | sed 's/d$//') * 86400 ))
        else
            log_warn "无效的间隔格式。请使用秒数 (例如: 300), 或带单位 (例如: 5m, 1h, 1d)。"
            continue
        fi

        # 验证是否为正整数
        if echo "$interval_in_seconds" | grep -qE '^[0-9]+$' && [ "$interval_in_seconds" -gt 0 ]; then
            echo "$interval_in_seconds"
            return 0
        else
            log_warn "无效的间隔值。请输入一个大于零的整数。"
        fi
    done
}
