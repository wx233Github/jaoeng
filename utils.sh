#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v4.6.29-FinalFix - 最终修复版本)
# - [优化] 移除 `_render_menu` 函数内部的调试日志。
# - [核心修复] 所有 `read` 命令现在明确从 `/dev/tty` 读取，解决通过管道执行脚本时 `read` 立即退出的问题。
# - [核心修改] `CONFIG_FILE` 定义移至此处。
# - [核心修改] 所有全局配置变量（包括UI主题、自动清屏、Watchtower配置）的默认值在此定义。
# - [核心修改] `load_config` 和 `save_config` 函数在此实现，统一管理所有全局配置。
#   - `load_config` 优先从 `config.conf` 加载，其次从 `install.sh` 传递的 JSON 默认值获取，最后是硬编码默认值。
# - [核心修改] `utils.sh` 在被 `source` 时会自动调用 `load_config`。
# - [新增] `set_ui_theme` 函数用于设置主题。
# - [新增] `theme_settings_menu` 函数用于主题选择界面。
# - [修改] `_print_header_title_only` 和 `_render_menu` 以支持主题切换。
# - [修复] 修正了 `_calc_display_width` 函数，使其能正确处理包含ANSI颜色码的字符串长度。
# - [新增] `_parse_watchtower_timestamp_from_log_line`, `_date_to_epoch`, `_format_seconds_to_human` 移至此处。
# =============================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'
UNDERLINE='\033[4m'

# --- 全局变量和配置文件路径 ---
# 所有模块共享的配置都将在此定义默认值，并通过 CONFIG_FILE 持久化
CONFIG_FILE="/etc/docker-auto-update.conf"
if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# --- 从 config.json 传递的环境变量 (由 install.sh 导出) ---
# 这些变量用于在 config.conf 不存在或为空时，提供 config.json 的默认值
JB_UI_THEME_FROM_JSON="${JB_UI_THEME_FROM_JSON:-}"
JB_ENABLE_AUTO_CLEAR_FROM_JSON="${JB_ENABLE_AUTO_CLEAR_FROM_JSON:-}"
JB_TIMEZONE_FROM_JSON="${JB_TIMEZONE_FROM_JSON:-}"

# Watchtower 模块的配置 (从 config.json 传递)
JB_WATCHTOWER_CONF_DEFAULT_INTERVAL_FROM_JSON="${JB_WATCHTOWER_CONF_DEFAULT_INTERVAL_FROM_JSON:-}"
JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR_FROM_JSON="${JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR_FROM_JSON:-}"
JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS_FROM_JSON="${JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS_FROM_JSON:-}"
JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES_FROM_JSON="${JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES_FROM_JSON:-}"
JB_WATCHTOWER_CONF_EXTRA_ARGS_FROM_JSON="${JB_WATCHTOWER_CONF_EXTRA_ARGS_FROM_JSON:-}"
JB_WATCHTOWER_CONF_DEBUG_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_DEBUG_ENABLED_FROM_JSON:-}"
JB_WATCHTOWER_CONF_CONFIG_INTERVAL_FROM_JSON="${JB_WATCHTOWER_CONF_CONFIG_INTERVAL_FROM_JSON:-}"
JB_WATCHTOWER_CONF_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_ENABLED_FROM_JSON:-}"
JB_WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON_FROM_JSON="${JB_WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON_FROM_JSON:-}"
JB_WATCHTOWER_CONF_CRON_HOUR_FROM_JSON="${JB_WATCHTOWER_CONF_CRON_HOUR_FROM_JSON:-}"
JB_WATCHTOWER_CONF_TASK_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_TASK_ENABLED_FROM_JSON:-}"
JB_WATCHTOWER_CONF_BOT_TOKEN_FROM_JSON="${JB_WATCHTOWER_CONF_BOT_TOKEN_FROM_JSON:-}"
JB_WATCHTOWER_CONF_CHAT_ID_FROM_JSON="${JB_WATCHTOWER_CONF_CHAT_ID_FROM_JSON:-}"
JB_WATCHTOWER_CONF_EMAIL_TO_FROM_JSON="${JB_WATCHTOWER_CONF_EMAIL_TO_FROM_JSON:-}"
JB_WATCHTOWER_CONF_EXCLUDE_LIST_FROM_JSON="${JB_WATCHTOWER_CONF_EXCLUDE_LIST_FROM_JSON:-}"


# --- 最终生效的配置变量 (将从 config.conf 或 JSON 默认值加载) ---
# UI/Global settings
JB_UI_THEME="default"
JB_ENABLE_AUTO_CLEAR="true"
JB_TIMEZONE="Asia/Shanghai"

# Watchtower module settings
TG_BOT_TOKEN=""
TG_CHAT_ID=""
EMAIL_TO=""
WATCHTOWER_EXCLUDE_LIST=""
WATCHTOWER_EXTRA_ARGS=""
WATCHTOWER_DEBUG_ENABLED="false"
WATCHTOWER_CONFIG_INTERVAL="300"
WATCHTOWER_ENABLED="false"
DOCKER_COMPOSE_PROJECT_DIR_CRON=""
CRON_HOUR="4"
CRON_TASK_ENABLED="false"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"


# --- 配置加载与保存函数 (现在统一位于 utils.sh 中) ---
load_config(){
    # 1. 加载 config.conf 中的用户配置 (最高优先级)
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE" &>/dev/null || true
    fi

    # 2. 应用优先级: config.conf (已加载) > JSON_FROM_INSTALL (环境变量) > 硬编码默认值
    # UI/Global settings
    JB_UI_THEME="${JB_UI_THEME:-${JB_UI_THEME_FROM_JSON:-default}}"
    JB_ENABLE_AUTO_CLEAR="${JB_ENABLE_AUTO_CLEAR:-${JB_ENABLE_AUTO_CLEAR_FROM_JSON:-true}}"
    JB_TIMEZONE="${JB_TIMEZONE:-${JB_TIMEZONE_FROM_JSON:-Asia/Shanghai}}"

    # Watchtower module settings
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${JB_WATCHTOWER_CONF_BOT_TOKEN_FROM_JSON:-}}"
    TG_CHAT_ID="${TG_CHAT_ID:-${JB_WATCHTOWER_CONF_CHAT_ID_FROM_JSON:-}}"
    EMAIL_TO="${EMAIL_TO:-${JB_WATCHTOWER_CONF_EMAIL_TO_FROM_JSON:-}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-${JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS_FROM_JSON:-}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-${JB_WATCHTOWER_CONF_EXTRA_ARGS_FROM_JSON:-}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${JB_WATCHTOWER_CONF_DEBUG_ENABLED_FROM_JSON:-false}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${JB_WATCHTOWER_CONF_DEFAULT_INTERVAL_FROM_JSON:-300}}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${JB_WATCHTOWER_CONF_ENABLED_FROM_JSON:-false}}"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-${JB_WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON_FROM_JSON:-}}"
    CRON_HOUR="${CRON_HOUR:-${JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR_FROM_JSON:-4}}" # 注意这里是 default_cron_hour
    CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-${JB_WATCHTOWER_CONF_TASK_ENABLED_FROM_JSON:-false}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES_FROM_JSON:-false}}"
}

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
# =============================================================
# Docker 自动更新助手全局配置文件 (由脚本管理，请勿手动修改)
# =============================================================

# --- UI/Global Settings ---
JB_UI_THEME="${JB_UI_THEME}"
JB_ENABLE_AUTO_CLEAR="${JB_ENABLE_AUTO_CLEAR}"
JB_TIMEZONE="${JB_TIMEZONE}"

# --- Watchtower Module Settings ---
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}

# --- 通用工具函数 ---

# 计算字符串在终端中显示的宽度，忽略ANSI颜色码
_calc_display_width() {
    local text="$1"
    # 使用sed去除ANSI颜色码，然后用wc -c计算字符数，并减去1（因为wc -c会计算末尾的换行符）
    local clean_text=$(echo -e "$text" | sed -E 's/\x1b\[[0-9;]*m//g')
    local len=$(echo -n "$clean_text" | wc -c)
    echo "$len"
}

# 打印菜单头部（仅标题部分，不含边框）
_print_header_title_only() {
    local title="$1"
    local total_width=$(tput cols || echo 80)
    local title_len=$(_calc_display_width "$title")

    case "$JB_UI_THEME" in
        modern)
            # 现代主题：标题左对齐，高亮
            echo -e "${GREEN}${BOLD}${title}${NC}"
            ;;
        default)
            # 默认主题：标题居中，带左右边框
            local padding=$(( (total_width - title_len - 2) / 2 )) # -2 for "  "
            printf "│%*s%s%*s│\n" "$padding" "" "$title" "$((total_width - title_len - 2 - padding))" ""
            ;;
    esac
}

# 渲染菜单
_render_menu() {
    local menu_title="$1"
    shift
    local -a items=("$@")
    local total_width=$(tput cols || echo 80)

    # log_info "DEBUG: Inside _render_menu. Received title: '$menu_title'" # <-- Removed debug
    # log_info "DEBUG: Inside _render_menu. Received ${#items[@]} items." # <-- Removed debug
    # if [ "${#items[@]}" -gt 0 ]; then
    #     log_info "DEBUG: Inside _render_menu. First item: '${items[0]}'" # <-- Removed debug
    # fi

    case "$JB_UI_THEME" in
        modern)
            local sep_char_top="━━━━━━" # 顶部分隔符
            local sep_char_bottom="======" # 底部分隔符
            local sep_len_top_block=$(( (total_width / $(_calc_display_width "$sep_char_top")) + 1 )) # 计算重复次数
            local sep_len_bottom_block=$(( (total_width / $(_calc_display_width "$sep_char_bottom")) + 1 )) # 计算重复次数

            # 打印顶部分隔符
            echo -e "${CYAN}$(printf "%s%.0s" "$sep_char_top" $(seq 1 $sep_len_top_block))${NC}"
            
            _print_header_title_only "$menu_title" # 打印标题

            # 打印标题下方的分隔符 (与顶部相同)
            echo -e "${CYAN}$(printf "%s%.0s" "$sep_char_top" $(seq 1 $sep_len_top_block))${NC}"

            # 打印菜单项
            for item in "${items[@]}"; do
                echo -e "$item"
            done
            
            # 打印底部分隔符
            echo -e "${CYAN}$(printf "%s%.0s" "$sep_char_bottom" $(seq 1 $sep_len_bottom_block))${NC}"
            ;;
        default)
            # 默认主题的边框和布局
            printf "╭%s╮\n" "$(printf '─%.0s' $(seq 1 $((total_width - 2))))"
            _print_header_title_only "$menu_title" # 打印标题
            printf "├%s┤\n" "$(printf '─%.0s' $(seq 1 $((total_width - 2))))" # 标题下方的分隔线
            
            # 打印菜单项
            for item in "${items[@]}"; do
                local item_len=$(_calc_display_width "$item")
                printf "│ %s%*s│\n" "$item" "$((total_width - item_len - 3))" ""
            done
            
            # 打印底部边框
            printf "╰%s╯\n" "$(printf '─%.0s' $(seq 1 $((total_width - 2))))"
            ;;
    esac
}

# 打印信息日志
log_info() {
    echo -e "${BLUE}[信息]${NC} $*"
}

# 打印成功日志
log_success() {
    echo -e "${GREEN}[成功]${NC} $*"
}

# 打印警告日志
log_warn() {
    echo -e "${YELLOW}[警告]${NC} $*" >&2
}

# 打印错误日志
log_err() {
    echo -e "${RED}[错误]${NC} $*" >&2
}

# 暂停并等待用户按Enter键
press_enter_to_continue() {
    echo -e "\n${CYAN}按 Enter 键继续...${NC}"
    read -r </dev/tty
}

# 确认操作
confirm_action() {
    local prompt_message="$1"
    read -r -p "${YELLOW}${prompt_message} (y/N)? ${NC}" response </dev/tty
    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            false
            ;;
    esac
}

# 提示用户输入一个时间间隔 (秒)，支持 s, m, h, d 单位
_prompt_for_interval() {
    local current_interval_seconds="$1"
    local prompt_message="$2"
    local default_display="$(_format_seconds_to_human "$current_interval_seconds")"
    local new_interval_input=""
    local new_interval_seconds=""

    while true; do
        read -r -p "${CYAN}${prompt_message} (当前: ${default_display}, 支持 s/m/h/d, 如 30m): ${NC}" new_interval_input_raw </dev/tty
        new_interval_input="${new_interval_input_raw:-$current_interval_seconds}" # 如果用户输入为空，则使用当前值

        if echo "$new_interval_input" | grep -qE '^[0-9]+(s|m|h|d)?$'; then
            local value=$(echo "$new_interval_input" | sed -E 's/[smhd]$//')
            local unit=$(echo "$new_interval_input" | sed -E 's/^[0-9]+//')

            case "$unit" in
                s|"") new_interval_seconds="$value" ;;
                m) new_interval_seconds=$((value * 60)) ;;
                h) new_interval_seconds=$((value * 3600)) ;;
                d) new_interval_seconds=$((value * 86400)) ;;
            esac
            echo "$new_interval_seconds"
            return 0
        else
            log_warn "无效的间隔格式。请使用数字加单位 (s/m/h/d) 或仅数字 (秒)。"
        fi
    done
}

# 设置 UI 主题
set_ui_theme() {
    local theme_name="$1"
    case "$theme_name" in
        default|modern)
            JB_UI_THEME="$theme_name"
            save_config # 保存主题设置到配置文件
            log_info "UI 主题已设置为: ${GREEN}${theme_name}${NC}"
            ;;
        *)
            log_warn "无效主题名称: ${RED}${theme_name}${NC}"
            ;;
    esac
}

# UI 主题设置菜单
theme_settings_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a items_array=(
            "  1. › 默认主题 (Default Theme)"
            "  2. › 现代主题 (Modern Theme)"
        )
        # 动态更新当前主题的显示状态
        if [ "$JB_UI_THEME" = "default" ]; then
            items_array[0]="  1. › 默认主题 (Default Theme) ${GREEN}(当前)${NC}"
        else
            items_array[1]="  2. › 现代主题 (Modern Theme) ${GREEN}(当前)${NC}"
        fi

        _render_menu "🎨 UI 主题设置 🎨" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice </dev/tty
        case "$choice" in
            1) set_ui_theme "default"; press_enter_to_continue ;;
            2) set_ui_theme "modern"; press_enter_to_continue ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

# --- Watchtower 模块所需的通用时间处理函数 (现在统一位于 utils.sh 中) ---

# 解析 Watchtower 日志行中的时间戳
_parse_watchtower_timestamp_from_log_line() {
    local log_line="$1"
    local timestamp=""
    # 尝试匹配 time="YYYY-MM-DDTHH:MM:SS+ZZ:ZZ" 格式
    timestamp=$(echo "$log_line" | sed -n 's/.*time="$[^"]*$".*/\1/p' | head -n1 || true)
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

# --- 脚本启动时自动加载配置 ---
load_config
