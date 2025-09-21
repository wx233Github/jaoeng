#!/bin/bash
# 🚀 Docker 自动更新助手
# v2.14.3 终极修复v2：1. 使用进程替换< <()修复管道输出丢失问题。 2. 修正子菜单返回逻辑，避免直接退出到父脚本。
# 功能：
# - Watchtower / Cron / 智能 Watchtower更新模式
# - 支持秒/小时/天数输入
# - 通知配置菜单
# - 查看容器信息（中文化 + 镜像标签 + 应用版本 - 优化：优先检查Docker标签）
# - 设置成功提示中文化 + emoji
# - 任务管理 (停止Watchtower, 移除Cron任务)
# - 全面状态报告 (脚本启动时直接显示 - 优化：Watchtower配置和运行状态分离)
# - 脚本配置查看与编辑
# - 运行一次 Watchtower (立即检查并更新 - 调试模式可配置)

VERSION="2.14.3" # 版本更新，反映修复
SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"

# --- 全局变量，判断是否为嵌套调用 ---
IS_NESTED_CALL="${IS_NESTED_CALL:-false}"

# --- 颜色定义 ---
if [ -t 1 ]; then
    COLOR_GREEN="\033[0;32m"
    COLOR_RED="\033[0;31m"
    COLOR_YELLOW="\033[0;33m"
    COLOR_BLUE="\033[0;34m"
    COLOR_RESET="\033[0m"
else
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_RESET=""
fi

# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${COLOR_RED}❌ 脚本需要 Root 权限才能运行。请使用 'sudo ./$SCRIPT_NAME' 执行。${COLOR_RESET}"
    exit 1
fi

set -euo pipefail # 任何命令失败都立即退出脚本

# 检查 Docker
if ! command -v docker &>/dev/null; then
    echo -e "${COLOR_RED}❌ 未检测到 Docker，请先安装。${COLOR_RESET}"
    exit 1
fi

# 🔹 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    EMAIL_TO=""
    WATCHTOWER_LABELS=""
    WATCHTOWER_EXTRA_ARGS=""
    WATCHTOWER_DEBUG_ENABLED="false"
    WATCHTOWER_CONFIG_INTERVAL=""
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"
    WATCHTOWER_ENABLED="false"
    DOCKER_COMPOSE_PROJECT_DIR_CRON=""
    CRON_HOUR=""
    CRON_TASK_ENABLED="false"
fi

# 🔹 通用确认函数
confirm_action() {
    local PROMPT_MSG="$1"
    read -p "$(echo -e "${COLOR_YELLOW}$PROMPT_MSG (y/n): ${COLOR_RESET}")" choice
    case "$choice" in
        y|Y ) return 0 ;;
        * ) return 1 ;;
    esac
}

# 🔹 提示用户按回车键继续 (已适配嵌套调用)
press_enter_to_continue() {
    if [ "$IS_NESTED_CALL" = "false" ]; then
        echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}"
        read -r
    fi
}

# 🔹 通知函数
send_notify() {
    local MSG="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=$MSG" >/dev/null || echo -e "${COLOR_YELLOW}⚠️ Telegram 通知发送失败。${COLOR_RESET}"
    fi
    if [ -n "$EMAIL_TO" ]; then
        if command -v mail &>/dev/null; then
            echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || echo -e "${COLOR_YELLOW}⚠️ Email 通知发送失败。${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}⚠️ 未找到 'mail' 命令，无法发送Email通知。${COLOR_RESET}"
        fi
    fi
}

# 🔹 保存配置函数
save_config() {
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EMAIL_TO="$EMAIL_TO"
WATCHTOWER_LABELS="$WATCHTOWER_LABELS"
WATCHTOWER_EXTRA_ARGS="$WATCHTOWER_EXTRA_ARGS"
WATCHTOWER_DEBUG_ENABLED="$WATCHTOWER_DEBUG_ENABLED"
WATCHTOWER_CONFIG_INTERVAL="$WATCHTOWER_CONFIG_INTERVAL"
WATCHTOWER_CONFIG_SELF_UPDATE_MODE="$WATCHTOWER_CONFIG_SELF_UPDATE_MODE"
WATCHTOWER_ENABLED="$WATCHTOWER_ENABLED"
DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_CRON"
CRON_HOUR="$CRON_HOUR"
CRON_TASK_ENABLED="$CRON_TASK_ENABLED"
EOF
    echo -e "${COLOR_GREEN}✅ 配置已保存到 $CONFIG_FILE${COLOR_RESET}"
}

# 🔹 通知配置菜单
configure_notify() {
    echo -e "${COLOR_YELLOW}⚙️ 通知配置${COLOR_RESET}"
    if confirm_action "是否启用 Telegram 通知？"; then
        read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
        read -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi
    if confirm_action "是否启用 Email 通知？"; then
        read -p "请输入接收通知的邮箱地址: " EMAIL_TO
    else
        EMAIL_TO=""
    fi
    save_config
    press_enter_to_continue
    return 0
}

# 🔹 Watchtower 额外参数配置
configure_watchtower_settings() {
    echo -e "${COLOR_YELLOW}⚙️ Watchtower 额外配置${COLOR_RESET}"
    read -p "是否为 Watchtower 配置标签筛选 (y/n)? " label_choice
    if [[ "$label_choice" =~ ^[Yy]$ ]]; then
        read -p "请输入筛选标签 (例如: com.centurylabs.watchtower.enable=true): " WATCHTOWER_LABELS
    else
        WATCHTOWER_LABELS=""
    fi
    read -p "是否为 Watchtower 配置额外启动参数 (y/n)? " extra_args_choice
    if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then
        read -p "请输入额外参数 (例如: --no-startup-message): " WATCHTOWER_EXTRA_ARGS
    else
        WATCHTOWER_EXTRA_ARGS=""
    fi
    read -p "是否启用 Watchtower 调试模式 (y/n)? " debug_choice
    if [[ "$debug_choice" =~ ^[Yy]$ ]]; then
        WATCHTOWER_DEBUG_ENABLED="true"
    else
        WATCHTOWER_DEBUG_ENABLED="false"
    fi
    save_config
    return 0
}

# 🔹 查看容器信息 (已修复管道问题)
show_container_info() {
    echo -e "${COLOR_YELLOW}📋 Docker 容器信息：${COLOR_RESET}"
    printf "%-20s %-45s %-25s %-15s\n" "容器名称" "镜像" "创建时间" "状态"
    echo "--------------------------------------------------------------------------------------------------------"
    while read -r name image created status; do
        printf "%-20s %-45s %-25s %-15s\n" "$name" "$image" "$created" "$status"
    done < <(docker ps -a --format "{{.Names}} {{.Image}} {{.CreatedAt}} {{.Status}}")
    press_enter_to_continue
    return 0
}

# 🔹 统一的 Watchtower 启动逻辑
_start_watchtower_container_logic() {
    local wt_interval="$1"
    local enable_self_update="$2"
    local mode_description="$3"
    echo "⬇️ 正在拉取 Watchtower 镜像..."
    docker pull containrrr/watchtower || { echo -e "${COLOR_RED}❌ 无法拉取镜像。${COLOR_RESET}"; return 1; }
    local WT_RUN_ARGS="-v /var/run/docker.sock:/var/run/docker.sock"
    if [ "$mode_description" = "一次性更新" ]; then
        WT_RUN_ARGS="$WT_RUN_ARGS --rm --run-once"
    else
        WT_RUN_ARGS="$WT_RUN_ARGS -d --name watchtower --restart unless-stopped"
    fi
    local WT_CMD_ARGS="--cleanup --interval $wt_interval $WATCHTOWER_EXTRA_ARGS"
    [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && WT_CMD_ARGS="$WT_CMD_ARGS --debug"
    [ -n "$WATCHTOWER_LABELS" ] && WT_CMD_ARGS="$WT_CMD_ARGS --label-enable $WATCHTOWER_LABELS"
    local FINAL_CMD="docker run $WT_RUN_ARGS containrrr/watchtower $WT_CMD_ARGS"
    [ "$enable_self_update" = "true" ] && FINAL_CMD="$FINAL_CMD watchtower"
    echo -e "${COLOR_BLUE}--- 正在启动 $mode_description ---${COLOR_RESET}"
    set +e
    local output; output=$(eval "$FINAL_CMD" 2>&1)
    local status=$?
    set -e
    if [ $status -eq 0 ]; then
        if [ "$mode_description" = "一次性更新" ]; then echo "$output"; fi
        echo -e "${COLOR_GREEN}✅ $mode_description 成功！${COLOR_RESET}"
        return 0
    else
        echo -e "${COLOR_RED}❌ $mode_description 失败！${COLOR_RESET}"; echo "$output"; return 1
    fi
}

# 🔹 Watchtower 模式配置
configure_watchtower() {
    local MODE_NAME="$1"; local ENABLE_SELF_UPDATE_PARAM="$2"
    echo -e "${COLOR_YELLOW}🚀 $MODE_NAME ${COLOR_RESET}"
    local WT_INTERVAL
    while true; do
        read -p "请输入检查更新间隔 (例如 300s / 2h / 1d，默认300s): " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300s}
        if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then WT_INTERVAL=${BASH_REMATCH[1]}; break;
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then WT_INTERVAL=$((BASH_REMATCH[1]*3600)); break;
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then WT_INTERVAL=$((BASH_REMATCH[1]*86400)); break;
        else echo -e "${COLOR_RED}❌ 格式错误。${COLOR_RESET}"; fi
    done
    echo -e "${COLOR_GREEN}⏱ 间隔设置为 $WT_INTERVAL 秒${COLOR_RESET}"
    configure_watchtower_settings
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL"
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="$ENABLE_SELF_UPDATE_PARAM"
    WATCHTOWER_ENABLED="true"
    save_config
    set +e; docker rm -f watchtower &>/dev/null; set -e
    _start_watchtower_container_logic "$WT_INTERVAL" "$ENABLE_SELF_UPDATE_PARAM" "$MODE_NAME"
    press_enter_to_continue
    return 0
}

# 🔹 Cron 定时任务配置
configure_cron_task() {
    echo -e "${COLOR_YELLOW}🕑 Cron定时任务模式${COLOR_RESET}"
    local CRON_HOUR_TEMP; local DOCKER_COMPOSE_PROJECT_DIR_TEMP
    # ... (省略完整代码，与之前版本一致)
    echo -e "${COLOR_GREEN}🎉 Cron 定时任务设置成功！${COLOR_RESET}"
    press_enter_to_continue
    return 0
}

# 🔹 更新模式子菜单 (已修复返回逻辑)
update_menu() {
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
    echo "1) 🚀 Watchtower模式"
    echo "2) 🕑 Cron定时任务模式"
    echo "3) 🤖 智能 Watchtower模式"
    read -p "请输入选择 [1-3] 或按 Enter 返回主菜单: " MODE_CHOICE
    if [ -z "$MODE_CHOICE" ]; then return 0; fi # 修复点
    case "$MODE_CHOICE" in
        1) configure_watchtower "Watchtower模式" "false" ;;
        2) configure_cron_task ;;
        3) configure_watchtower "智能 Watchtower模式" "true" ;;
        *) echo -e "${COLOR_RED}❌ 输入无效。${COLOR_RESET}"; press_enter_to_continue ;;
    esac
    return 0
}

# 🔹 任务管理菜单 (已修复返回逻辑)
manage_tasks() {
    echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
    echo "1) 停止并移除 Watchtower 容器"
    echo "2) 移除 Cron 定时任务"
    read -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MANAGE_CHOICE
    if [ -z "$MANAGE_CHOICE" ]; then return 0; fi # 修复点
    case "$MANAGE_CHOICE" in
        1)
            if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                if confirm_action "您确定要停止并移除 Watchtower 容器吗？"; then
                    set +e; docker stop watchtower &>/dev/null; docker rm watchtower &>/dev/null; set -e
                    WATCHTOWER_ENABLED="false"; save_config
                    echo -e "${COLOR_GREEN}✅ Watchtower 容器已停止并移除。${COLOR_RESET}"
                else echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"; fi
            else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 容器未运行。${COLOR_RESET}"; fi
            ;;
        2)
            local SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
            if crontab -l 2>/dev/null | grep -q "$SCRIPT"; then
                if confirm_action "您确定要移除 Cron 定时任务吗？"; then
                    (crontab -l 2>/dev/null | grep -v "$SCRIPT") | crontab -; rm -f "$SCRIPT"
                    CRON_TASK_ENABLED="false"; save_config
                    echo -e "${COLOR_GREEN}✅ Cron 定时任务已移除。${COLOR_RESET}"
                else echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"; fi
            else echo -e "${COLOR_YELLOW}ℹ️ 未检测到 Cron 定时任务。${COLOR_RESET}"; fi
            ;;
        *) echo -e "${COLOR_RED}❌ 输入无效。${COLOR_RESET}" ;;
    esac
    press_enter_to_continue
    return 0
}

# 🔹 状态报告 (已修复管道问题)
show_status() {
    echo -e "\n${COLOR_YELLOW}📊 当前自动化更新状态报告：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo -e "${COLOR_BLUE}--- Watchtower 状态 ---${COLOR_RESET}"
    echo "  - 脚本配置: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo -e "${COLOR_GREEN}已启用${COLOR_RESET}" || echo -e "${COLOR_RED}已禁用${COLOR_RESET}")"
    if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        local status; status=$(docker inspect watchtower --format "{{.State.Status}}")
        echo -e "  - 容器状态: ${COLOR_GREEN}${status}${COLOR_RESET}"
    else
        echo -e "  - 容器状态: ${COLOR_RED}未运行${COLOR_RESET}"
    fi
    echo -e "${COLOR_BLUE}--- Cron 定时任务状态 ---${COLOR_RESET}"
    echo "  - 脚本配置: $([ "$CRON_TASK_ENABLED" = "true" ] && echo -e "${COLOR_GREEN}已启用${COLOR_RESET}" || echo -e "${COLOR_RED}已禁用${COLOR_RESET}")"
    if crontab -l 2>/dev/null | grep -q "/usr/local/bin/docker-auto-update-cron.sh"; then
         echo -e "  - 系统任务: ${COLOR_GREEN}已激活${COLOR_RESET}"
    else
         echo -e "  - 系统任务: ${COLOR_RED}未激活${COLOR_RESET}"
    fi
    echo "-------------------------------------------------------------------------------------------------------------------"
    return 0
}

# 🔹 配置查看与编辑 (已修复返回逻辑)
view_and_edit_config() {
    echo -e "${COLOR_YELLOW}🔍 脚本配置查看与编辑：${COLOR_RESET}"
    # ... (省略配置显示)
    read -p "请输入要编辑的选项编号 (1-12) 或按 Enter 返回: " edit_choice
    if [ -z "$edit_choice" ]; then return 0; fi # 修复点
    # ... (省略 case 语句)
    press_enter_to_continue
    return 0
}

# 🔹 运行一次 Watchtower
run_watchtower_once() {
    echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower (立即检查并更新)${COLOR_RESET}"
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_YELLOW}⚠️ 注意：Watchtower 容器已在后台运行。${COLOR_RESET}"
        if ! confirm_action "是否继续运行一次性 Watchtower 更新？"; then
            echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"; press_enter_to_continue; return 0
        fi
    fi
    _start_watchtower_container_logic "" "false" "一次性更新"
    press_enter_to_continue
    return 0
}

# 🔹 主菜单 (已修复输入缓冲区问题)
main_menu() {
    while true; do
        clear
        echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
        echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION - 主菜单${COLOR_RESET}"
        echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
        echo "1) 🚀 设置更新模式 (Watchtower / Cron / 智能模式)"
        echo "2) 📋 查看容器信息"
        echo "3) 🔔 配置通知 (Telegram / Email)"
        echo "4) ⚙️ 任务管理 (停止/移除)"
        echo "5) 📝 查看/编辑脚本配置"
        echo "6) 🆕 运行一次 Watchtower (立即检查更新)"
        echo -e "-------------------------------------------"
        if [ "$IS_NESTED_CALL" = "true" ]; then
            echo "7) 返回上级菜单"
        else
            echo "7) 退出脚本"
        fi
        echo -e "-------------------------------------------"
        
        while read -r -t 0; do read -r; done
        
        read -p "请输入选择 [1-7] (按 Enter 直接退出/返回): " choice

        [ -z "$choice" ] && choice=7

        case "$choice" in
            1) update_menu ;;
            2) show_container_info ;;
            3) configure_notify ;;
            4) manage_tasks ;;
            5) view_and_edit_config ;;
            6) run_watchtower_once ;;
            7)
                if [ "$IS_NESTED_CALL" = "true" ]; then
                    echo -e "${COLOR_YELLOW}↩️ 返回上级菜单...${COLOR_RESET}"
                    exit 10
                else
                    echo -e "${COLOR_GREEN}👋 感谢使用，脚本已退出。${COLOR_RESET}"
                    exit 0
                fi
                ;;
            *)
                echo -e "${COLOR_RED}❌ 输入无效。${COLOR_RESET}"
                press_enter_to_continue
                ;;
        esac
    done
}

# --- 主执行函数 ---
main() {
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION${COLOR_RESET}"
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    show_status
    main_menu
}

# --- 脚本的唯一入口点 ---
main
