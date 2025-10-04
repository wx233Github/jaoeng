#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v1.0)
# 供所有 vps-install 模块共享使用
# =============================================================

# --- 严格模式 ---
set -eo pipefail

# --- 颜色定义 ---
# 仅当在终端中运行时才启用颜色
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; 
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m' # No Color
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""
fi

# --- 日志系统 ---
# 提供了带时间戳和颜色分类的日志输出
log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info()    { echo -e "$(log_timestamp) ${BLUE}[信息]${NC} $*"; }
log_success() { echo -e "$(log_timestamp) ${GREEN}[成功]${NC} $*"; }
log_warn()    { echo -e "$(log_timestamp) ${YELLOW}[警告]${NC} $*"; }
log_err()     { echo -e "$(log_timestamp) ${RED}[错误]${NC} $*" >&2; }

# --- 用户交互函数 ---
# 等待用户按 Enter 继续
press_enter_to_continue() { 
    read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")"
}

# 询问用户确认操作
confirm_action() {
    read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice
    case "$choice" in
        n|N ) return 1 ;;
        * ) return 0 ;;
    esac
}


# --- UI 渲染 & 字符串处理 ---

# 生成指定长度的横线
generate_line() {
    local len=${1:-62}
    local char="─"
    local line=""
    local i=0
    while [ $i -lt $len ]; do
        line="$line$char"
        i=$(expr $i + 1)
    done
    echo "$line"
}

# 计算字符串的可视宽度（处理中文字符和颜色代码）
_get_visual_width() {
    local text="$1"
    local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local processed_text; processed_text=$(echo "$plain_text" | sed $'s/\uFE0F//g')
    
    local width=0
    local i=0
    while [ $i -lt ${#processed_text} ]; do
        char=${processed_text:$i:1}
        if [[ "$char" == "›" ]]; then
            width=$((width + 1))
        elif [ "$(echo -n "$char" | wc -c)" -gt 1 ]; then
            width=$((width + 2))
        else
            width=$((width + 1))
        fi
        i=$((i + 1))
    done
    echo $width
}

# 渲染一个带标题和内容的静态菜单
_render_menu() {
    local title="$1"; shift
    local lines_str="$@"
    local max_width=0
    local line_width
    
    line_width=$(_get_visual_width "$title")
    if [ $line_width -gt $max_width ]; then max_width=$line_width; fi
    
    local old_ifs=$IFS; IFS=$'\n'
    for line in $lines_str; do
        line_width=$(_get_visual_width "$line")
        if [ $line_width -gt $max_width ]; then max_width=$line_width; fi
    done
    IFS=$old_ifs
    
    local box_width; box_width=$(expr $max_width + 6)
    if [ $box_width -lt 40 ]; then box_width=40; fi
    
    local title_width; title_width=$(_get_visual_width "$title")
    local padding_total; padding_total=$(expr $box_width - $title_width)
    local padding_left; padding_left=$(expr $padding_total / 2)
    local left_padding; left_padding=$(printf '%*s' "$padding_left")
    local right_padding; right_padding=$(printf '%*s' "$(expr $padding_total - $padding_left)")
    
    echo ""
    echo -e "${YELLOW}╭$(generate_line "$box_width")╮${NC}"
    echo -e "${YELLOW}│${left_padding}${title}${right_padding}${YELLOW}│${NC}"
    echo -e "${YELLOW}╰$(generate_line "$box_width")╯${NC}"
    
    IFS=$'\n'
    for line in $lines_str; do
        echo -e "$line"
    done
    IFS=$old_ifs
    echo -e "${BLUE}$(generate_line $(expr $box_width + 2))${NC}"
}

# 渲染一个根据内容自动调整宽度的动态盒子
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
    echo -e "${YELLOW}╭${top_bottom_border}╮${NC}"
    echo -e "${YELLOW}│${left_padding}${title}${right_padding}${YELLOW}│${NC}"
    echo -e "${YELLOW}╰$(generate_line "$box_width")╯${NC}"
    
    local old_ifs=$IFS; IFS=$'\n'
    for line in $content_str; do
        echo -e "$line"
    done
    IFS=$old_ifs
}

_print_header() {
    _render_menu "$1" ""
}
