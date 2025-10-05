#!/bin/bash
# =============================================================
# 🚀 通用工具函数库 (v4.6.15-GlobalUI - 全局UI主题支持及统一配置管理)
# - [核心修改] `JB_UI_THEME` 变量移至此处，作为全局配置。
# - [核心修改] `load_config` 和 `save_config` 移至此处，统一管理所有全局配置。
# - [核心修改] `utils.sh` 在被 `source` 时会自动调用 `load_config`。
# - [新增] `set_ui_theme` 函数用于设置主题。
# - [新增] `theme_settings_menu` 函数用于主题选择界面。
# - [修改] `_print_header_title_only` 和 `_render_menu` 以支持主题切换。
# - [修复] 修正了 `_calc_display_width` 函数，使其能正确处理包含ANSI颜色码的字符串长度。
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

# 默认值 (如果配置文件中未指定，则使用这些值)
JB_UI_THEME="${JB_UI_THEME:-default}" # UI 主题 (default, modern)
JB_ENABLE_AUTO_CLEAR="${JB_ENABLE_AUTO_CLEAR:-true}" # 默认启用自动清屏

# Watchtower 模块的默认配置 (从 config.json 传递，或硬编码默认值)
# 这些变量现在也由 utils.sh 的 load_config/save_config 管理
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-300}" # 默认 300 秒
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-4}" # 默认凌晨 4 点
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-false}"

# --- 配置加载与保存函数 (现在位于 utils.sh 中) ---
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # 注意: source 命令会直接执行文件内容，覆盖同名变量
        source "$CONFIG_FILE" &>/dev/null || true
    fi
    # 确保所有变量都有最终值，配置文件值优先，若配置文件为空则回退到脚本默认值
    JB_UI_THEME="${JB_UI_THEME:-default}"
    JB_ENABLE_AUTO_CLEAR="${JB_ENABLE_AUTO_CLEAR:-true}"

    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
    EMAIL_TO="${EMAIL_TO:-}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-300}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
    CRON_HOUR="${CRON_HOUR:-4}"
    CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-false}"
}

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
# =============================================================
# Docker 自动更新助手全局配置文件
# =============================================================

# --- UI 主题设置 ---
JB_UI_THEME="${JB_UI_THEME}"
JB_ENABLE_AUTO_CLEAR="${JB_ENABLE_AUTO_CLEAR}"

# --- Watchtower 模块配置 ---
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
    read -r
}

# 确认操作
confirm_action() {
    local prompt_message="$1"
    read -r -p "${YELLOW}${prompt_message} (y/N)? ${NC}" response
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
        read -r -p "${CYAN}${prompt_message} (当前: ${default_display}, 支持 s/m/h/d, 如 30m): ${NC}" new_interval_input_raw
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
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) set_ui_theme "default"; press_enter_to_continue ;;
            2) set_ui_theme "modern"; press_enter_to_continue ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

# --- 脚本启动时自动加载配置 ---
load_config
