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

# 🔹 提示用户按回车键继续
press_enter_to_continue() {
    # 当被嵌套调用时，父脚本会处理“按回车继续”的逻辑，这里就不再显示
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
            --data-urlencode "text=$MSG" >/dev/null || echo -e "${COLOR_YELLOW}⚠️ Telegram 通知发送失败，请检查 Bot Token 和 Chat ID。${COLOR_RESET}"
    fi
    if [ -n "$EMAIL_TO" ]; then
        if command -v mail &>/dev/null; then
            echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || echo -e "${COLOR_YELLOW}⚠️ Email 通知发送失败，请检查邮件配置。${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}⚠️ Email 通知已启用，但 'mail' 命令未找到或未配置。请安装并配置 MTA。${COLOR_RESET}"
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
    if confirm_action "是否启用 Telegram 通知？(当前: ${TG_BOT_TOKEN:+已设置} ${TG_BOT_TOKEN:-未设置})"; then
        read -p "请输入 Telegram Bot Token (空输入不修改): " TG_BOT_TOKEN_NEW
        TG_BOT_TOKEN="${TG_BOT_TOKEN_NEW:-$TG_BOT_TOKEN}"
        read -p "请输入 Telegram Chat ID (空输入不修改): " TG_CHAT_ID_NEW
        TG_CHAT_ID="${TG_CHAT_ID_NEW:-$TG_CHAT_ID}"
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi
    if confirm_action "是否启用 Email 通知？(当前: ${EMAIL_TO:+已设置} ${EMAIL_TO:-未设置})"; then
        read -p "请输入接收通知的邮箱地址 (空输入不修改): " EMAIL_TO_NEW
        EMAIL_TO="${EMAIL_TO_NEW:-$EMAIL_TO}"
        if [ -n "$EMAIL_TO" ] && ! command -v mail &>/dev/null; then
            echo -e "${COLOR_YELLOW}⚠️ 'mail' 命令未找到。如果需要 Email 通知，请安装并配置 MTA。${COLOR_RESET}"
        fi
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
    read -p "是否为 Watchtower 配置标签筛选？(y/n) (当前: ${WATCHTOWER_LABELS:-无}): " label_choice
    if [[ "$label_choice" =~ ^[Yy]$ ]]; then
        read -p "请输入 Watchtower 筛选标签 (空输入取消): " WATCHTOWER_LABELS_NEW
        WATCHTOWER_LABELS="${WATCHTOWER_LABELS_NEW:-}"
    else
        WATCHTOWER_LABELS=""
    fi
    read -p "是否为 Watchtower 配置额外启动参数？(y/n) (当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
    if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then
        read -p "请输入 Watchtower 额外参数 (空输入取消): " WATCHTOWER_EXTRA_ARGS_NEW
        WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-}"
    else
        WATCHTOWER_EXTRA_ARGS=""
    fi
    read -p "是否启用 Watchtower 调试模式 (--debug)？(y/n) (当前: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")): " debug_choice
    if [[ "$debug_choice" =~ ^[Yy]$ ]]; then
        WATCHTOWER_DEBUG_ENABLED="true"
    else
        WATCHTOWER_DEBUG_ENABLED="false"
    fi
    save_config
    return 0
}

# 🔹 查看容器信息
show_container_info() {
    echo -e "${COLOR_YELLOW}📋 Docker 容器信息：${COLOR_RESET}"
    printf "%-20s %-45s %-25s %-15s %-15s\n" "容器名称" "镜像" "创建时间" "状态" "应用版本"
    echo "-------------------------------------------------------------------------------------------------------------------"

    while read -r name image created status; do
        local APP_VERSION="N/A"
        local IMAGE_NAME_FOR_LABELS
        IMAGE_NAME_FOR_LABELS=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)
        
        if [ -n "$IMAGE_NAME_FOR_LABELS" ]; then
            APP_VERSION=$(docker inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || \
                          docker inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "app.version"}}' 2>/dev/null || \
                          true)
            APP_VERSION=$(echo "$APP_VERSION" | head -n 1 | cut -c 1-15 | tr -d '\n')
            [ -z "$APP_VERSION" ] && APP_VERSION="N/A"
        fi
        printf "%-20s %-45s %-25s %-15s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
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
    docker pull containrrr/watchtower || { echo -e "${COLOR_RED}❌ 无法拉取 containrrr/watchtower 镜像。${COLOR_RESET}"; return 1; }

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
    local watchtower_output
    watchtower_output=$(eval "$FINAL_CMD" 2>&1)
    local watchtower_status=$?
    set -e

    if [ $watchtower_status -eq 0 ]; then
        if [ "$mode_description" = "一次性更新" ]; then echo "$watchtower_output"; fi
        echo -e "${COLOR_GREEN}✅ $mode_description 成功完成/启动！${COLOR_RESET}"
        return 0
    else
        echo -e "${COLOR_RED}❌ $mode_description 失败！${COLOR_RESET}"
        echo "$watchtower_output"
        return 1
    fi
}

# 🔹 Watchtower 模式配置
configure_watchtower() {
    local MODE_NAME="$1"
    local ENABLE_SELF_UPDATE_PARAM="$2"
    echo -e "${COLOR_YELLOW}🚀 $MODE_NAME ${COLOR_RESET}"
    local INTERVAL_INPUT
    local WT_INTERVAL
    while true; do
        read -p "请输入检查更新间隔（例如 300s / 2h / 1d，默认300s）: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300s}
        if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then WT_INTERVAL=${BASH_REMATCH[1]}; break;
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then WT_INTERVAL=$((BASH_REMATCH[1]*3600)); break;
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then WT_INTERVAL=$((BASH_REMATCH[1]*86400)); break;
        else echo -e "${COLOR_RED}❌ 输入格式错误。${COLOR_RESET}"; fi
    done
    echo -e "${COLOR_GREEN}⏱ Watchtower检查间隔设置为 $WT_INTERVAL 秒${COLOR_RESET}"
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
    local CRON_HOUR_TEMP
    while true; do
        read -p "请输入每天更新的小时 (0-23, 当前: ${CRON_HOUR:-未设置}, 默认4): " CRON_HOUR_INPUT
        CRON_HOUR_INPUT=${CRON_HOUR_INPUT:-${CRON_HOUR:-4}}
        if [[ "$CRON_HOUR_INPUT" =~ ^[0-9]+$ ]] && [ "$CRON_HOUR_INPUT" -ge 0 ] && [ "$CRON_HOUR_INPUT" -le 23 ]; then
            CRON_HOUR_TEMP="$CRON_HOUR_INPUT"; break
        else echo -e "${COLOR_RED}❌ 小时输入无效。${COLOR_RESET}"; fi
    done
    local DOCKER_COMPOSE_PROJECT_DIR_TEMP
    while true; do
        read -p "请输入 Docker Compose 项目的**完整目录路径** (当前: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}): " DOCKER_COMPOSE_PROJECT_DIR_INPUT
        DOCKER_COMPOSE_PROJECT_DIR_INPUT=${DOCKER_COMPOSE_PROJECT_DIR_INPUT:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}
        if [ -z "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then echo -e "${COLOR_RED}❌ 目录路径不能为空。${COLOR_RESET}";
        elif [ ! -d "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then echo -e "${COLOR_RED}❌ 目录不存在。${COLOR_RESET}";
        else DOCKER_COMPOSE_PROJECT_DIR_TEMP="$DOCKER_COMPOSE_PROJECT_DIR_INPUT"; break; fi
    done
    CRON_HOUR="$CRON_HOUR_TEMP"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_TEMP"
    CRON_TASK_ENABLED="true"
    save_config
    local CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    local LOG_FILE="/var/log/docker-auto-update-cron.log"
    cat > "$CRON_UPDATE_SCRIPT" <<EOF_INNER_SCRIPT
#!/bin/bash
PROJECT_DIR=$(printf "%q" "$DOCKER_COMPOSE_PROJECT_DIR_CRON")
LOG_FILE="$LOG_FILE"
echo "\$(date '+%Y-%m-%d %H:%M:%S') - 开始执行 Docker Compose 更新" >> "\$LOG_FILE" 2>&1
cd "\$PROJECT_DIR" || exit 1
DOCKER_COMPOSE_CMD=\$(command -v docker-compose || command -v docker compose)
if [ -n "\$DOCKER_COMPOSE_CMD" ]; then
    "\$DOCKER_COMPOSE_CMD" pull >> "\$LOG_FILE" 2>&1
    "\$DOCKER_COMPOSE_CMD" up -d --remove-orphans >> "\$LOG_FILE" 2>&1
fi
docker image prune -f >> "\$LOG_FILE" 2>&1
echo "\$(date '+%Y-%m-%d %H:%M:%S') - 更新完成" >> "\$LOG_FILE" 2>&1
EOF_INNER_SCRIPT
    chmod +x "$CRON_UPDATE_SCRIPT"
    (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT" ; echo "0 $CRON_HOUR * * * $CRON_UPDATE_SCRIPT") | crontab -
    echo -e "${COLOR_GREEN}🎉 Cron 定时任务设置成功！每天 $CRON_HOUR 点更新。日志: ${COLOR_YELLOW}$LOG_FILE${COLOR_RESET}"
    press_enter_to_continue
    return 0
}

# 🔹 更新模式子菜单
update_menu() {
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
    echo "1) 🚀 Watchtower模式"
    echo "2) 🕑 Cron定时任务模式"
    echo "3) 🤖 智能 Watchtower模式"
    read -p "请输入选择 [1-3] 或按 Enter 返回主菜单: " MODE_CHOICE
    if [ -z "$MODE_CHOICE" ]; then return 0; fi
    case "$MODE_CHOICE" in
        1) configure_watchtower "Watchtower模式" "false" ;;
        2) configure_cron_task ;;
        3) configure_watchtower "智能 Watchtower模式" "true" ;;
        *) echo -e "${COLOR_RED}❌ 输入无效。${COLOR_RESET}"; press_enter_to_continue ;;
    esac
    return 0
}

# 🔹 任务管理菜单
manage_tasks() {
    echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
    echo "1) 停止并移除 Watchtower 容器"
    echo "2) 移除 Cron 定时任务"
    read -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MANAGE_CHOICE
    if [ -z "$MANAGE_CHOICE" ]; then return 0; fi
    case "$MANAGE_CHOICE" in
        1)
            if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                if confirm_action "您确定要停止并移除 Watchtower 容器吗？"; then
                    set +e; docker stop watchtower &>/dev/null; docker rm watchtower &>/dev/null; set -e
                    WATCHTOWER_ENABLED="false"; save_config
                    echo -e "${COLOR_GREEN}✅ Watchtower 容器已停止并移除。${COLOR_RESET}"
                else echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"; fi
            else echo -e "${COLOR_YELLOW}ℹ️ Watchtower 容器未运行或不存在。${COLOR_RESET}"; fi
            ;;
        2)
            local CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
            if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
                if confirm_action "您确定要移除 Cron 定时任务吗？"; then
                    (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT") | crontab -
                    rm -f "$CRON_UPDATE_SCRIPT"
                    CRON_TASK_ENABLED="false"; save_config
                    echo -e "${COLOR_GREEN}✅ Cron 定时任务已移除。${COLOR_RESET}"
                else echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"; fi
            else echo -e "${COLOR_YELLOW}ℹ️ 未检测到由本脚本配置的 Cron 任务。${COLOR_RESET}"; fi
            ;;
        *) echo -e "${COLOR_RED}❌ 输入无效。${COLOR_RESET}" ;;
    esac
    press_enter_to_continue
    return 0
}

# 🔹 状态报告
show_status() {
    echo -e "\n${COLOR_YELLOW}📊 当前自动化更新状态报告：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo -e "${COLOR_BLUE}--- Watchtower 状态 ---${COLOR_RESET}"
    echo "  - 脚本配置: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "${COLOR_GREEN}已启用${COLOR_RESET}" || echo "${COLOR_RED}已禁用${COLOR_RESET}")"
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "  - 容器状态: ${COLOR_GREEN}正在运行${COLOR_RESET}"
    elif docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "  - 容器状态: ${COLOR_YELLOW}已存在但未运行${COLOR_RESET}"
    else
        echo -e "  - 容器状态: ${COLOR_RED}不存在${COLOR_RESET}"
    fi
    echo -e "${COLOR_BLUE}--- Cron 定时任务状态 ---${COLOR_RESET}"
    echo "  - 脚本配置: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "${COLOR_GREEN}已启用${COLOR_RESET}" || echo "${COLOR_RED}已禁用${COLOR_RESET}")"
    if crontab -l 2>/dev/null | grep -q "/usr/local/bin/docker-auto-update-cron.sh"; then
        echo -e "  - 系统任务: ${COLOR_GREEN}已激活${COLOR_RESET}"
    else
        echo -e "  - 系统任务: ${COLOR_RED}未激活${COLOR_RESET}"
    fi
    echo "-------------------------------------------------------------------------------------------------------------------"
    return 0
}

# 🔹 配置查看与编辑
view_and_edit_config() {
    echo -e "${COLOR_YELLOW}🔍 脚本配置查看与编辑：${COLOR_RESET}"
    read -p "此功能正在开发中，按 Enter 返回。"
    return 0
}

# 🔹 运行一次 Watchtower
run_watchtower_once() {
    echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower (立即检查并更新)${COLOR_RESET}"
    if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_YELLOW}⚠️ 注意：后台已有 Watchtower 容器，本次为独立一次性运行。${COLOR_RESET}"
    fi
    if confirm_action "是否继续运行一次性 Watchtower 更新？"; then
        _start_watchtower_container_logic "" "false" "一次性更新"
    else
        echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
    fi
    press_enter_to_continue
    return 0
}

# 🔹 主菜单
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
