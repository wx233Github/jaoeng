#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.6.15 - utils.sh)
# - [修复] 修正 _render_menu 函数，使用 _get_display_width 正确计算菜单项宽度，解决中文对齐问题。
# - [优化] _get_display_width 函数，在没有 python 时回退到 wc -m。
# - [优化] _prompt_for_interval 函数，增加更友好的提示。
# =============================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 日志函数 ---
log_info() {
    echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S') [信息] $*${NC}"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [成功] $*${NC}"
}

log_warn() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [警告] $*${NC}" >&2
}

log_err() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [错误] $*${NC}" >&2
}

# --- 辅助函数 ---

# press_enter_to_continue: 提示用户按回车键继续
press_enter_to_continue() {
    echo -e "\n按 ${GREEN}Enter${NC} 键继续..."
    read -r
}

# confirm_action: 提示用户确认操作
# 参数1: 提示信息
# 返回值: 0表示确认，1表示取消
confirm_action() {
    read -r -p "$(echo -e "${YELLOW}$1 (y/N): ${NC}")" response
    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            false
            ;;
    esac
}

# _get_display_width: 计算字符串的显示宽度，处理ANSI颜色码和多字节字符
# 参数1: 字符串
_get_display_width() {
    local str="$1"
    # 移除ANSI颜色码
    local clean_str=$(echo "$str" | sed 's/\x1b\[[0-9;]*m//g')
    # 使用Python计算显示宽度，处理多字节字符 (East Asian Width)
    # Fallback to wc -m (character count) if python is not available, which is better than wc -c
    if command -v python3 &>/dev/null; then
        python3 -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$clean_str" || echo "${#clean_str}"
    elif command -v python &>/dev/null; then
        python -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$clean_str" || echo "${#clean_str}"
    else
        # Fallback to wc -m (character count) if Python is not available
        # This is less accurate for mixed-width characters but better than wc -c (byte count)
        echo "$clean_str" | wc -m
    fi
}

# center_text: 将文本居中
# 参数1: 文本
# 参数2: 总宽度
center_text() {
    local text="$1"
    local total_width="$2"
    local text_width=$(_get_display_width "$text")
    if [ "$text_width" -ge "$total_width" ]; then
        echo "$text"
        return
    fi
    local padding_left=$(((total_width - text_width) / 2))
    local padding_right=$((total_width - text_width - padding_left))
    printf "%${padding_left}s%s%${padding_right}s" "" "$text" ""
}

# _render_menu: 渲染一个带边框的菜单
# 参数1: 菜单标题
# 参数2...N: 菜单项 (每项一行)
_render_menu() {
    local title="$1"
    shift
    local items_array=("$@")

    local max_width=0
    # 计算标题的显示宽度并初始化 max_width
    local title_display_width=$(_get_display_width "$title")
    if [ "$title_display_width" -gt "$max_width" ]; then
        max_width="$title_display_width"
    fi

    # 计算所有菜单项的显示宽度，并更新 max_width
    for item in "${items_array[@]}"; do
        local item_display_width=$(_get_display_width "$item")
        if [ "$item_display_width" -gt "$max_width" ]; then
            max_width="$item_display_width"
        fi
    done

    # 确保菜单有足够的宽度，至少比标题宽4个字符 (标题两侧各2个空格)
    # 并且确保最小宽度，防止菜单过窄
    if [ "$max_width" -lt 30 ]; then # 最小宽度可以根据需要调整
        max_width=30
    fi
    if [ "$max_width" -lt "$((title_display_width + 4))" ]; then
        max_width="$((title_display_width + 4))"
    fi

    # 绘制顶部边框
    local border_line=$(printf "%-${max_width}s" "" | sed 's/ /─/g')
    echo -e "╭─${border_line}─╮"

    # 绘制标题行
    printf "│ %s │\n" "$(center_text "$title" "$max_width")"

    # 绘制标题下分隔线
    echo -e "├─${border_line}─┤"

    # 绘制菜单项
    for item in "${items_array[@]}"; do
        # printf "%-${max_width}s" 会根据字符宽度进行填充
        printf "│ %-${max_width}s │\n" "$item"
    done

    # 绘制底部边框
    echo -e "╰─${border_line}─╯"
}


# _prompt_for_interval: 提示用户输入时间间隔，并将其转换为秒
# 参数1: 默认间隔 (秒)
# 参数2: 提示信息
# 返回值: 转换后的秒数
_prompt_for_interval() {
    local default_interval="$1"
    local prompt_message="$2"
    local unit_map=(
        ["s"]="秒" ["m"]="分" ["h"]="时" ["d"]="天"
        ["秒"]="s" ["分"]="m" ["时"]="h" ["天"]="d"
    )

    local current_value_human=$(_format_seconds_to_human "$default_interval")
    
    while true; do
        read -r -p "$(echo -e "${CYAN}${prompt_message} (例如: 300s, 5m, 2h, 1d, 当前: ${current_value_human}): ${NC}")" input

        if [ -z "$input" ]; then
            echo "$default_interval"
            return 0
        fi

        local num=$(echo "$input" | grep -Eo '^[0-9]+')
        local unit=$(echo "$input" | grep -Eo '[a-zA-Z一-龥]+$')

        if [ -z "$num" ]; then
            log_warn "无效输入。请输入数字和单位 (例如: 300s, 5m)。"
            continue
        fi

        local unit_in_seconds=1 # 默认单位为秒
        case "${unit,,}" in # 转换为小写进行匹配
            s|sec|秒) unit_in_seconds=1 ;;
            m|min|分) unit_in_seconds=60 ;;
            h|hr|时) unit_in_seconds=3600 ;;
            d|day|天) unit_in_seconds=86400 ;;
            *)
                log_warn "无效单位 '${unit}'。请使用 s (秒), m (分), h (时), d (天)。"
                continue
                ;;
        esac

        local total_seconds=$((num * unit_in_seconds))
        echo "$total_seconds"
        return 0
    done
}
