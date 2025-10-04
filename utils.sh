#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.5 - UI Theming Engine)
# 供所有 vps-install 模块共享使用
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
    local len=${1:-62}
    local char_type=${2:-"─"} # 第二个参数可以是 "─" 或 "═"
    local line=""
    local i=0
    while [ $i -lt $len ]; do line="${line}${char_type}"; i=$((i + 1)); done
    echo "$line"
}
_get_visual_width() {
    local text="$1"; local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g'); local width=0; local i=1
    while [ $i -le ${#plain_text} ]; do char=$(echo "$plain_text" | cut -c $i); if [ "$(echo -n "$char" | wc -c)" -gt 1 ]; then width=$((width + 2)); else width=$((width + 1)); fi; i=$((i + 1)); done; echo $width
}

# =============================================================
# 关键修复: 实现UI主题引擎
# =============================================================
_render_menu() {
    # 如果是 watchtower 风格，则不执行任何操作，由模块自己渲染
    if [ "${UI_STYLE}" = "watchtower" ]; then
        return 0
    fi

    # 默认使用 install 风格
    local title="$1"; shift
    local max_width=0; local line_width

    line_width=$(_get_visual_width "  $title  "); if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi
    for line in "$@"; do line_width=$(_get_visual_width "$line"); if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi; done
    
    local box_width; box_width=$((max_width + 4)); if [ $box_width -lt 40 ]; then box_width=40; fi
    local title_width; title_width=$(_get_visual_width "$title")
    
    local padding_total=$((box_width - title_width - 2)) # -2 for " ║ "
    local padding_left=$((padding_total / 2))
    local padding_right=$((padding_total - padding_left))
    
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$padding_right")
    
    echo ""; echo -e "${GREEN}╔$(generate_line "$box_width" "═")╗${NC}"
    echo -e "${GREEN}║${left_padding} ${title} ${right_padding}║${NC}"
    echo -e "${GREEN}╚$(generate_line "$box_width" "═")╝${NC}"
    
    for line in "$@"; do echo -e "$line"; done

    # install 风格不需要底部的分隔线
}

_print_header() { _render_menu "$1" ""; }
