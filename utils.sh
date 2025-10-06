#!/bin/bash

# =============================================================
# 🚀 通用工具函数库 (v2.41-回归稳定版并集成修复)
# - 集中默认路径与配置加载（容错）
# - 临时文件管理（create_temp_file / cleanup_temp_files + trap）
# - 字符宽度计算改进（优先 python）
# - UI 渲染与交互函数
# =============================================================

set -eo pipefail

# --- 默认配置 ---
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
    for f in "${TEMP_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f"
    done
    TEMP_FILES=()
    log_debug "清理临时文件完成。"
}

trap cleanup_temp_files EXIT INT TERM

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
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
log_debug()   { [ "${JB_DEBUG_MODE:-false}" = "true" ] && echo -e "$(log_timestamp) ${YELLOW}[DEBUG]${NC} $*" >&2; }

# --- 交互函数 ---
press_enter_to_continue() {
    read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty
}
confirm_action() {
    read -r -p "$(echo -e "${YELLOW}$1 ([y]/n): ${NC}")" choice < /dev/tty
    case "$choice" in n|N ) return 1 ;; * ) return 0 ;; esac
}

# --- 配置加载 ---
load_config() {
    local config_path="${1:-${CONFIG_PATH:-${DEFAULT_CONFIG_PATH}}}"
    log_debug "尝试加载配置文件: $config_path"

    # 初始化默认值
    BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"
    INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    BIN_DIR="${BIN_DIR:-$DEFAULT_BIN_DIR}"
    LOCK_FILE="${LOCK_FILE:-$DEFAULT_LOCK_FILE}"
    JB_TIMEZONE="${JB_TIMEZONE:-$DEFAULT_TIMEZONE}"
    CONFIG_PATH="${config_path:-${DEFAULT_CONFIG_PATH}}"

    if [ ! -f "$config_path" ]; then
        log_warn "配置文件 $config_path 未找到，使用默认配置。"
        export BASE_URL INSTALL_DIR BIN_DIR LOCK_FILE JB_TIMEZONE CONFIG_PATH
        log_debug "配置（回退默认）: base_url=$BASE_URL install_dir=$INSTALL_DIR bin_dir=$BIN_DIR lock_file=$LOCK_FILE timezone=$JB_TIMEZONE"
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        BASE_URL=$(jq -r '.base_url // empty' "$config_path" 2>/dev/null || echo "$BASE_URL")
        INSTALL_DIR=$(jq -r '.install_dir // empty' "$config_path" 2>/dev/null || echo "$INSTALL_DIR")
        BIN_DIR=$(jq -r '.bin_dir // empty' "$config_path" 2>/dev/null || echo "$BIN_DIR")
        LOCK_FILE=$(jq -r '.lock_file // empty' "$config_path" 2>/dev/null || echo "$LOCK_FILE")
        JB_TIMEZONE=$(jq -r '.timezone // empty' "$config_path" 2>/dev/null || echo "$JB_TIMEZONE")
    else
        log_warn "未检测到 jq，使用轻量文本解析（可能不完整）。建议安装 jq。"
        BASE_URL=$(grep -Po '"base_url"\s*:\s*"\K[^"]+' "$config_path" 2>/dev/null || echo "$BASE_URL")
        INSTALL_DIR=$(grep -Po '"install_dir"\s*:\s*"\K[^"]+' "$config_path" 2>/dev/null || echo "$INSTALL_DIR")
        BIN_DIR=$(grep -Po '"bin_dir"\s*:\s*"\K[^"]+' "$config_path" 2>/dev/null || echo "$BIN_DIR")
        LOCK_FILE=$(grep -Po '"lock_file"\s*:\s*"\K[^"]+' "$config_path" 2>/dev/null || echo "$LOCK_FILE")
        JB_TIMEZONE=$(grep -Po '"timezone"\s*:\s*"\K[^"]+' "$config_path" 2>/dev/null || echo "$JB_TIMEZONE")
    fi

    export BASE_URL INSTALL_DIR BIN_DIR LOCK_FILE JB_TIMEZONE CONFIG_PATH
    log_debug "配置已加载: base_url=$BASE_URL install_dir=$INSTALL_DIR bin_dir=$BIN_DIR lock_file=$LOCK_FILE timezone=$JB_TIMEZONE"
}

# --- UI 渲染 & 字符串处理 ---
generate_line() {
    local len=${1:-40} char=${2:-"─"}
    [ "$len" -le 0 ] && echo "" && return
    printf "%${len}s" "" | sed "s/ /$char/g"
}

_get_visual_width() {
    local text="$1"
    local plain_text
    plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    [ -z "$plain_text" ] && echo 0 && return

    local width
    if command -v python3 &>/dev/null; then
        width=$(python3 - <<'PY' 2>/dev/null
import unicodedata,sys
s=sys.stdin.read()
print(sum(2 if unicodedata.east_asian_width(c) in ("W","F","A") else 1 for c in s.strip()))
PY
<<< "$plain_text" || echo "")
    elif command -v python &>/dev/null; then
        width=$(python - <<'PY' 2>/dev/null
import unicodedata,sys
s=sys.stdin.read()
print(sum(2 if unicodedata.east_asian_width(c) in ("W","F","A") else 1 for c in s.strip()))
PY
<<< "$plain_text" || echo "")
    fi

    if [ -z "$width" ]; then
        if command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
            width=$(echo -n "$plain_text" | wc -m)
        else
            width=${#plain_text}
        fi
    fi
    echo "$width"
}

_render_menu() {
    local title="$1"; shift
    local -a lines=("$@")
    local max_content_width=0
    local title_width=$(_get_visual_width "$title")
    (( title_width > max_content_width )) && max_content_width=$title_width
    for line in "${lines[@]}"; do
        local w=$(_get_visual_width "$line")
        (( w > max_content_width )) && max_content_width=$w
    done

    local inner_padding=2
    local box_width=$((max_content_width + inner_padding))
    [ "$box_width" -lt 38 ] && box_width=38

    echo ""; echo -e "${GREEN}╭$(generate_line "$box_width" "─")╮${NC}"
    [ -n "$title" ] && {
        local padding_total=$((box_width - title_width - 2))
        local pad_left=$((padding_total/2))
        local pad_right=$((padding_total - pad_left))
        printf "${GREEN}│%*s %s %*s│${NC}\n" "$pad_left" "" "$title" "$pad_right" ""
    }
    for line in "${lines[@]}"; do
        local w=$(_get_visual_width "$line")
        local pad_right=$((box_width - w - 1))
        [ "$pad_right" -lt 0 ] && pad_right=0
        printf "${GREEN}│ %s%*s${GREEN}│${NC}\n" "$line" "$pad_right" ""
    done
    echo -e "${GREEN}╰$(generate_line "$box_width" "─")╯${NC}"
}

_print_header() { _render_menu "$1"; }
