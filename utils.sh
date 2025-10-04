#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.28 - 最终对齐修正版)
# - [最终修正] 采用真正计算视觉宽度（中文=2）的 _get_visual_width 函数
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

# [最终修正] 采用真正计算视觉宽度的函数
_get_visual_width() {
    local text="$1"
    local plain_text
    plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    if [ -z "$plain_text" ]; then
        echo 0
        return
    fi
    local bytes chars
    bytes=$(echo -n "$plain_text" | wc -c)
    chars=$(echo -n "$plain_text" | wc -m)
    echo $(( (bytes + chars) / 2 ))
}

_render_menu() {
    local title="$1"; shift
    local -a lines=("$@")
    
    local max_width=0
    local title_width=$(_get_visual_width "$title")
    if (( title_width > max_width )); then max_width=$title_width; fi

    for line in "${lines[@]}"; do
        local line_width=$(_get_visual_width "$line")
        if (( line_width > max_width )); then max_width=$line_width; fi
    done
    
    local box_width=$((max_width + 4))
    if [ $box_width -lt 40 ]; then box_width=40; fi

    # 顶部
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_width" "─")╮${NC}"
    
    # 标题
    if [ -n "$title" ]; then
        local padding_total=$((box_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        local left_padding; left_padding=$(printf '%*s' "$padding_left")
        local right_padding; right_padding=$(printf '%*s' "$padding_right")
        echo -e "${GREEN}│${left_padding}${title}${right_padding}│${NC}"
    fi
    
    # 选项
    for line in "${lines[@]}"; do
        local line_width=$(_get_visual_width "$line")
        local padding_right=$((box_width - line_width - 1))
        if [ "$padding_right" -lt 0 ]; then padding_right=0; fi
        echo -e "${GREEN}│${NC}${line}$(printf '%*s' "$padding_right")${GREEN}│${NC}"
    done

    # 底部
    echo -e "${GREEN}╰$(generate_line "$box_width" "─")╯${NC}"
}
_print_header() { _render_menu "$1" ""; }
