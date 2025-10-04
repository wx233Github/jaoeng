#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v1.3 - Universal Argument Handling Fix)
# 供所有 vps-install 模块共享使用
# =============================================================

# --- 严格模式 ---
set -eo pipefail

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m' # No Color
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
press_enter_to_continue() { 
    read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")"
}

confirm_action() {
    read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice
    case "$choice" in
        n|N ) return 1 ;;
        * ) return 0 ;;
    esac
}

# --- UI 渲染 & 字符串处理 ---

generate_line() {
    local len=${1:-62}
    local char="─"
    printf "%*s" "$len" | tr ' ' "$char"
}

_get_visual_width() {
    local text="$1"
    local plain_text
    plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    echo "$plain_text" | awk '{
        split($0, chars, "");
        width = 0;
        for (i in chars) {
            if (length(chars[i]) > 1) {
                width += 2;
            } else {
                width += 1;
            }
        }
        print width;
    }'
}

# ==============================================================================
# 关键修复: 重写 _render_menu，使其能同时处理多参数和单一多行字符串参数
# ==============================================================================
_render_menu() {
    local title="$1"; shift
    local max_width=0
    
    # 步骤 1: 规范化输入。无论输入是 ("line1" "line2") 还是 ("line1\nline2")
    # 都将其转换为一个干净的 BASH 数组 `lines_array`
    local -a lines_array
    # 'readarray -t' 从标准输入读取行到数组，-t 移除每行的换行符
    # 'printf "%s\n"' 会正确处理所有传入的参数，将它们逐行打印出来
    printf '%s\n' "$@" | readarray -t lines_array

    # 步骤 2: 使用规范化后的数组来计算最大宽度
    local line_width
    line_width=$(_get_visual_width "$title")
    if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi
    
    for line in "${lines_array[@]}"; do
        line_width=$(_get_visual_width "$line")
        if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi
    done
    
    # 步骤 3: 正常渲染UI
    local box_width; box_width=$(expr $max_width + 6)
    if [ $box_width -lt 40 ]; then box_width=40; fi
    
    local title_width; title_width=$(_get_visual_width "$title")
    local padding_total; padding_total=$(expr $box_width - $title_width)
    local padding_left; padding_left=$(expr $padding_total / 2)
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    
    echo ""
    echo -e "${GREEN}╭$(generate_line "$box_width")╮${NC}"
    echo -e "${GREEN}│${left_padding}${title}${right_padding}${GREEN}│${NC}"
    echo -e "${GREEN}╰$(generate_line "$box_width")╯${NC}"
    
    # 步骤 4: 使用规范化后的数组来打印菜单项
    for line in "${lines_array[@]}"; do
        echo -e "$line"
    done
    
    echo -e "${BLUE}$(generate_line $(expr $box_width + 2))${NC}"
}

_render_dynamic_box() {
    local title="$1"; local box_width="$2"; shift 2
    local content_str="$@"
    
    local title_width; title_width=$(_get_visual_width "$title")
    local top_bottom_border; top_bottom_border=$(generate_line "$box_width")
    local padding_total; padding_total=$(expr $box_width - $title_width)
    local padding_left; padding_left=$(expr $padding_total / 2)
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    
    echo ""
    echo -e "${GREEN}╭${top_bottom_border}╮${NC}"
    echo -e "${GREEN}│${left_padding}${title}${right_padding}${GREEN}│${NC}"
    echo -e "${GREEN}╰$(generate_line "$box_width")╯${NC}"
    
    local old_ifs=$IFS; IFS=$'\n'
    for line in $content_str; do
        echo -e "$line"
    done
    IFS=$old_ifs
}

_print_header() {
    _render_menu "$1" ""
}
