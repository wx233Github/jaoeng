#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.35)
# - 新增：添加了 `_prompt_for_interval` 函数，用于交互式获取并验证时间间隔输入。
# - 修复：修正了 `_parse_watchtower_timestamp_from_log_line` 函数中的语法错误。
# - 修复：修正了 `_parse_watchtower_timestamp_from_log_line` 函数，优先解析“Scheduling first run”的调度时间。
# - 优化：脚本头部注释更简洁。
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

# --- 用户交互函数 ---
press_enter_to_continue() { read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")"; }
confirm_action() { read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice; case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac; }

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
    if [ -z "$plain_text" ]; then
        echo 0
        return
    fi

    # 优先使用 Python 计算显示宽度，处理多字节字符 (East Asian Width)
    if command -v python3 &>/dev/null; then
        python3 -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$plain_text" || true
    elif command -v python &>/dev/null; then
        python -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$plain_text" || true
    else
        # Fallback to wc -m (character count) if Python is not available
        # This is less accurate for mixed-width characters but better than wc -c (byte count)
        if command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
            echo -n "$plain_text" | wc -m
        else
            # Final fallback to wc -c (byte count), least accurate for multi-byte characters
            echo -n "$plain_text" | wc -c
        fi
    fi
}

# 增加内部边距，适配移动终端
_render_menu() {
    local title="$1"; shift
    local -a lines=("$@")
    
    local max_width=0
    # 为标题也增加左右各一个空格的边距
    local title_width=$(( $(_get_visual_width "$title") + 2 ))
    if (( title_width > max_width )); then max_width=$title_width; fi

    for line in "${lines[@]}"; do
        # 为每行内容都增加左右各一个空格的边距
        local line_width=$(( $(_get_visual_width "$line") + 2 ))
        if (( line_width > max_width )); then max_width=$line_width; fi
    done
    
    local box_width=$((max_width + 2)) # 左右边框各占1
    if [ $box_width -lt 40 ]; then box_width=40; fi # 最小宽度

    # 顶部
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_width" "─")╮${NC}"
    
    # 标题
    if [ -n "$title" ]; then
        local padding_total=$((box_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        local left_padding; left_padding=$(printf '%*s' "$padding_left")
        local right_padding; right_padding=$(printf '%*s' "$padding_right")
        echo -e "${GREEN}│${left_padding} ${title} ${right_padding}│${NC}"
    fi
    
    # 选项
    for line in "${lines[@]}"; do
        local line_width=$(( $(_get_visual_width "$line") + 2 ))
        local padding_right=$((box_width - line_width))
        if [ "$padding_right" -lt 0 ]; then padding_right=0; fi
        echo -e "${GREEN}│${NC} ${line} $(printf '%*s' "$padding_right")${GREEN}│${NC}"
    done

    # 底部
    echo -e "${GREEN}╰$(generate_line "$box_width" "─")╯${NC}"
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
    timestamp=$(echo "$log_line" | sed -n 's/.*time="$[^"]*$".*/\1/p' | head -n1 || true)
