#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.30 - 最终UI修正版)
# - [最终修正] 增加菜单内部边距，适配移动终端UI
# - [修复] `generate_line` 函数中 `$系统信息` 拼写错误，修正为 `$char`。
# - [优化] `_get_visual_width` 函数，优先使用 Python 计算宽度，其次 `wc -m`，最后 `wc -c`。
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
    local line=""
    local i=0
    while [ $i -lt "$len" ]; do
        line="${line}$char"
        i=$((i + 1))
    done
    echo "$line"
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

# [最终UI修正] 增加内部边距，适配移动终端
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
    # 尝试匹配 time="YYYY-MM-DDTHH:MM:SS+ZZ:ZZ" 格式
    timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    # 尝试匹配 YYYY-MM-DDTHH:MM:SSZ 格式 (例如 Watchtower 1.7.1)
    timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    # 尝试匹配 "Scheduling first run: YYYY-MM-DD HH:MM:SS" 格式
    timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
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
    if ! echo "$seconds" | grep -qE '^[0-9]+$'; then
        echo "N/A"
        return 1
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
