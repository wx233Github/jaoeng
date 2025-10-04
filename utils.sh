#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v2.6 - Theming Engine)
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
generate_line() { local len=${1:-40}; local char=${2:-"─"}; local line=""; local i=0; while [ $i -lt $len ]; do line="${line}${char}"; i=$((i + 1)); done; echo "$line"; }
_get_visual_width() {
    local text="$1"; local plain_text; plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g'); local width=0; local i=1
    while [ $i -le ${#plain_text} ]; do char=$(echo "$plain_text" | cut -c $i); if [ "$(echo -n "$char" | wc -c)" -gt 1 ]; then width=$((width + 2)); else width=$((width + 1)); fi; i=$((i + 1)); done; echo $width
}

# =============================================================
# 关键修复: 实现UI主题引擎，还原经典盒子布局
# =============================================================
_render_menu() {
    local title="$1"; shift
    local theme="${UI_THEME:-default}" # 默认为 default 主题

    # 定义主题字符集
    local top_left top_right bottom_left bottom_right horiz vert;
    case "$theme" in
        install)
            top_left="≈"; top_right="≈"; bottom_left="≈"; bottom_right="≈"; horiz="≈"; vert=" "
            title="★ $title · 状态：${GREEN}已更新 ✓${NC}"
            ;;
        watchtower)
            top_left="~"; top_right="~"; bottom_left="~"; bottom_right="~"; horiz="~"; vert=" "
            title="★ $title · 状态：[${GREEN}绿${NC}]${GREEN}已更新 ✓${NC}[无]"
            ;;
        *) # default theme
            top_left="╭"; top_right="╮"; bottom_left="╰"; bottom_right="╯"; horiz="─"; vert="│"
            ;;
    esac
    
    local max_width=0; local line_width
    line_width=$(_get_visual_width "$title"); if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi
    for line in "$@"; do line_width=$(_get_visual_width "$line"); if [ "$line_width" -gt "$max_width" ]; then max_width=$line_width; fi; done
    
    local box_width; box_width=$((max_width + 4)); if [ $box_width -lt 40 ]; then box_width=40; fi
    
    # 渲染顶部
    echo ""; echo -e "${CYAN}${top_left}$(generate_line "$box_width" "$horiz")${top_right}${NC}"
    
    # 渲染标题
    if [ -n "$title" ]; then
        local title_width; title_width=$(_get_visual_width "$title")
        local padding_total=$((box_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        local left_padding; left_padding=$(printf '%*s' "$padding_left")
        local right_padding; right_padding=$(printf '%*s' "$padding_right")
        echo -e "${CYAN}${vert}${left_padding}${title}${right_padding}${vert}${NC}"
    fi

    # 渲染状态面板 (如果存在)
    if [[ "$theme" == "install" ]] || [[ "$theme" == "watchtower" ]]; then
        echo -e "${CYAN}${vert}$(generate_line "$box_width" "-") ${vert}${NC}"
        local docker_status="→ Docker：$(command -v docker &>/dev/null && echo -e "${GREEN}🟢 正常${NC}" || echo -e "${RED}🔴 未安装${NC}")"
        local nginx_status="→ Nginx ：$(command -v nginx &>/dev/null && echo -e "${GREEN}🟢 正常${NC}" || echo -e "${YELLOW}🟡 未安装${NC}")"
        local wt_status="→ Watchtower：$(docker ps -q --filter "name=watchtower" | grep -q . && echo -e "${CYAN}🔄 运行中${NC}" || echo -e "${BLUE}⚪ 未运行${NC}")"
        local cert_status="→ Certbot：$(command -v ~/.acme.sh/acme.sh &>/dev/null && echo -e "${GREEN}🟢 已安装${NC}" || echo -e "${RED}🔴 未申请${NC}")"
        local -a status_lines=("$docker_status" "$nginx_status" "$wt_status" "$cert_status")
        for line in "${status_lines[@]}"; do
            local line_width=$(_get_visual_width "$line")
            local padding_right=$((box_width - line_width))
            echo -e "${CYAN}${vert} ${line}$(printf '%*s' "$padding_right")${vert}${NC}"
        done
        echo -e "${CYAN}${vert}$(generate_line "$box_width" "-") ${vert}${NC}"
        local footer="⏳ 正在监控更新，请稍候..."
        local footer_width=$(_get_visual_width "$footer")
        local padding_right_footer=$((box_width - footer_width))
        echo -e "${CYAN}${vert} ${footer}$(printf '%*s' "$padding_right_footer")${vert}${NC}"
    fi
    
    # 渲染菜单项
    for line in "$@"; do
        local line_width=$(_get_visual_width "$line")
        local padding_right=$((box_width - line_width))
        echo -e "${CYAN}${vert} ${line}$(printf '%*s' "$padding_right")${vert}${NC}"
    done

    # 渲染底部
    echo -e "${CYAN}${bottom_left}$(generate_line "$box_width" "$horiz")${bottom_right}${NC}"
}

_print_header() { _render_menu "$1" ""; }
