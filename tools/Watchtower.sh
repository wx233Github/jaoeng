#!/bin/bash
# 🚀 Docker 自动更新助手
# v2.14.1 结构优化：将主执行流程封装到 main 函数中，确保所有函数在调用前都已加载，增加脚本健壮性。
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

VERSION="2.14.1" # 版本更新，反映修复
SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf" # 配置文件路径，需要root权限才能写入和读取

# --- 全局变量，判断是否为嵌套调用 ---
IS_NESTED_CALL="${IS_NESTED_CALL:-false}" # 默认值为 false，如果父脚本设置了，则会被覆盖为 true

# --- 颜色定义 ---
if [ -t 1 ]; then # 检查标准输出是否是终端
    COLOR_GREEN="\033[0;32m"
    COLOR_RED="\033[0;31m"
    COLOR_YELLOW="\033[0;33m"
    COLOR_BLUE="\033[0;34m"
    COLOR_RESET="\033[0m"
else
    # 如果不是终端，颜色变量为空
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_RESET=""
fi

# 确保脚本以 root 权限运行，因为需要操作 Docker 和修改 crontab
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
    # 默认值
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    EMAIL_TO=""
    WATCHTOWER_LABELS="" # Watchtower 标签配置
    WATCHTOWER_EXTRA_ARGS="" # Watchtower 额外参数
    WATCHTOWER_DEBUG_ENABLED="false" # Watchtower 调试模式是否启用
    WATCHTOWER_CONFIG_INTERVAL="" # 脚本配置的Watchtower检查间隔 (秒)
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false" # 脚本配置的Watchtower智能模式 (true/false)
    WATCHTOWER_ENABLED="false" # 脚本配置的Watchtower是否应运行 (true/false)

    DOCKER_COMPOSE_PROJECT_DIR_CRON="" # Cron模式下 Docker Compose 项目目录
    CRON_HOUR="" # Cron模式下的小时 (0-23)
    CRON_TASK_ENABLED="false" # 脚本配置的Cron任务是否应运行 (true/false)
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

# 🔹 提示用户按回车键继续 (修改：如果嵌套调用，则不作任何操作)
press_enter_to_continue() {
    if [ "$IS_NESTED_CALL" = "false" ]; then # 仅当非嵌套调用时才提示
        echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}"
        read -r # 读取一个空行，等待用户按Enter
    fi
}

# 🔹 通知函数 (脚本自身的通知，Watchtower 可配置自己的通知)
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
            echo -e "${COLOR_YELLOW}⚠️ Email 通知已启用，但 'mail' 命令未找到或未配置。请安装并配置邮件传输代理 (MTA)。${COLOR_RESET}"
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
        TG_BOT_TOKEN="${TG_BOT_TOKEN_NEW:-$TG_BOT_TOKEN}" # 允许空输入保留原值
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
            echo -e "${COLOR_YELLOW}⚠️ 'mail' 命令未找到。如果需要 Email 通知，请安装并配置邮件传输代理 (MTA)。${COLOR_RESET}"
            echo -e "   例如在 Ubuntu/Debian 上安装 'sudo apt install mailutils' 并配置 SSMTP。"
        fi
    else
        EMAIL_TO=""
    fi

    save_config
    press_enter_to_continue # 调用修改后的函数
    return 0
}

# 🔹 Watchtower 标签和额外参数配置
configure_watchtower_settings() {
    echo -e "${COLOR_YELLOW}⚙️ Watchtower 额外配置${COLOR_RESET}"

    read -p "是否为 Watchtower 配置标签筛选？(y/n) (例如：com.centurylabs.watchtower.enable=true) (当前: ${WATCHTOWER_LABELS:-无}): " label_choice
    if [[ "$label_choice" == "y" || "$label_choice" == "Y" ]]; then
        read -p "请输入 Watchtower 筛选标签 (空输入取消): " WATCHTOWER_LABELS_NEW
        WATCHTOWER_LABELS="${WATCHTOWER_LABELS_NEW:-}"
    else
        WATCHTOWER_LABELS=""
    fi

    read -p "是否为 Watchtower 配置额外启动参数？(y/n) (例如：--no-startup-message --notification-url=https://your.webhook.com/path) (当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
    if [[ "$extra_args_choice" == "y" || "$extra_args_choice" == "Y" ]]; then
        read -p "请输入 Watchtower 额外参数 (空输入取消): " WATCHTOWER_EXTRA_ARGS_NEW
        WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-}"
    else
        WATCHTOWER_EXTRA_ARGS=""
    fi

    read -p "是否启用 Watchtower 调试模式 (--debug)？(y/n) (当前: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")): " debug_choice
    if [[ "$debug_choice" == "y" || "$debug_choice" == "Y" ]]; then
        WATCHTOWER_DEBUG_ENABLED="true"
    else
        WATCHTOWER_DEBUG_ENABLED="false"
    fi

    save_config
    return 0 # 确保函数有返回码
}


# 🔹 获取 Docker Compose 命令的函数 (用于主脚本)
get_docker_compose_command_main() {
    if command -v docker compose &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# 🔹 查看容器信息（中文化 + 镜像标签 + 内部应用版本）
show_container_info() {
    echo -e "${COLOR_YELLOW}📋 Docker 容器信息：${COLOR_RESET}"
    printf "%-20s %-45s %-25s %-15s %-15s\n" "容器名称" "镜像" "创建时间" "状态" "应用版本"
    echo "-------------------------------------------------------------------------------------------------------------------"

    docker ps -a --format "{{.Names}} {{.Image}} {{.CreatedAt}} {{.Status}}" | while read -r name image created status; do # 使用 -r 防止 read 处理反斜杠
        local APP_VERSION="N/A"
        local IMAGE_NAME_FOR_LABELS=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)
        
        # 优化：优先尝试从Docker Label获取应用版本
        if [ -n "$IMAGE_NAME_FOR_LABELS" ]; then
            APP_VERSION=$(docker inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || \
                          docker inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "app.version"}}' 2>/dev/null || \
                          true)
            APP_VERSION=$(echo "$APP_VERSION" | head -n 1 | cut -c 1-15 | tr -d '\n')
            if [ -z "$APP_VERSION" ]; then
                APP_VERSION="N/A" # 如果标签为空，重置为N/A
            fi
        fi

        # 如果标签没有找到版本，再尝试原有启发式方法 (此方法通用性较差，通常只对特定应用有效)
        if [ "$APP_VERSION" = "N/A" ]; then
            if docker exec "$name" sh -c "test -d /app" &>/dev/null; then
                local CONTAINER_APP_EXECUTABLE=$(docker exec "$name" sh -c "find /app -maxdepth 1 -type f -executable -print -quit" 2>/dev/null || true)
                if [ -n "$CONTAINER_APP_EXECUTABLE" ]; then
                    local RAW_VERSION=$(docker exec "$name" sh -c "$CONTAINER_APP_EXECUTABLE --version 2>/dev/null || echo 'N/A'")
                    APP_VERSION=$(echo "$RAW_VERSION" | head -n 1 | cut -c 1-15 | tr -d '\n')
                fi
            fi
        fi
        printf "%-20s %-45s %-25s %-15s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
    done
    press_enter_to_continue # 调用修改后的函数
    return 0 # 确保函数有返回码
}

# 🔹 统一的 Watchtower 容器启动逻辑
_start_watchtower_container_logic() {
    local wt_interval="$1"
    local enable_self_update="$2"
    local mode_description="$3" # "Watchtower模式" 或 "智能 Watchtower模式" 或 "一次性更新"

    echo "⬇️ 正在拉取 Watchtower 镜像..."
    docker pull containrrr/watchtower || {
        echo -e "${COLOR_RED}❌ 无法拉取 containrrr/watchtower 镜像。请检查网络连接或 Docker Hub 状态。${COLOR_RESET}"
        send_notify "❌ Docker 自动更新助手：$mode_description 运行失败，无法拉取镜像。"
        return 1
    }

    local WT_RUN_ARGS=""
    if [ "$mode_description" = "一次性更新" ]; then
        WT_RUN_ARGS="--rm --run-once"
    else
        WT_RUN_ARGS="-d --name watchtower --restart unless-stopped"
    fi

    local WT_CMD_ARGS="--cleanup --interval $wt_interval $WATCHTOWER_EXTRA_ARGS"
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
        WT_CMD_ARGS="$WT_CMD_ARGS --debug"
    fi
    if [ -n "$WATCHTOWER_LABELS" ]; then
        WT_CMD_ARGS="$WT_CMD_ARGS --label-enable $WATCHTOWER_LABELS"
        echo -e "${COLOR_YELLOW}ℹ️ $mode_description 将只更新带有标签 '$WATCHTOWER_LABELS' 的容器。${COLOR_RESET}"
    fi

    local FINAL_CMD="docker run $WT_RUN_ARGS -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower $WT_CMD_ARGS"
    if [ "$enable_self_update" = "true" ]; then
        FINAL_CMD="$FINAL_CMD watchtower"
    fi

    echo -e "${COLOR_BLUE}--- 正在启动 $mode_description ---${COLOR_RESET}"
    local watchtower_output=""
    local watchtower_status=0

    # 临时禁用 set -e 以捕获命令输出和状态
    set +e
    if [ "$mode_description" = "一次性更新" ]; then
        watchtower_output=$(eval "$FINAL_CMD" 2>&1)
        watchtower_status=$?
        echo "$watchtower_output" # 打印一次性运行的日志
    else
        eval "$FINAL_CMD" &>/dev/null # 后台运行，不直接打印输出
        watchtower_status=$?
        if [ $watchtower_status -ne 0 ]; then
             echo -e "${COLOR_RED}❌ $mode_description 启动失败！请检查日志。${COLOR_RESET}"
        fi
        sleep 5 # 等待后台容器启动
        if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$' && [ $watchtower_status -eq 0 ]; then
            # 如果 docker run 成功但容器没有运行，可能是其他原因，这里认为是启动失败
            watchtower_status=1
            echo -e "${COLOR_RED}❌ $mode_description 启动失败，容器未运行！${COLOR_RESET}"
        fi
    fi
    set -e # 重新启用错误检查

    if [ $watchtower_status -eq 0 ]; then
        echo -e "${COLOR_GREEN}✅ $mode_description 成功完成/启动！${COLOR_RESET}"
        send_notify "✅ Docker 自动更新助手：$mode_description 成功。"
        return 0
    else
        echo -e "${COLOR_RED}❌ $mode_description 失败！${COLOR_RESET}"
        send_notify "❌ Docker 自动更新助手：$mode_description 失败。"
        return 1
    fi
}


# 🔹 Watchtower 模式配置
configure_watchtower() {
    local MODE_NAME="$1" # "Watchtower模式" 或 "智能 Watchtower模式"
    local ENABLE_SELF_UPDATE_PARAM="$2" # 是否启用自身更新 (true/false)

    echo -e "${COLOR_YELLOW}🚀 $MODE_NAME ${COLOR_RESET}"

    local INTERVAL_INPUT=""
    local WT_INTERVAL=300 # 默认值

    while true; do
        read -p "请输入检查更新间隔（例如 300s / 2h / 1d，默认300s）: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300s} # 默认值加上's'后缀

        if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then
            WT_INTERVAL=${BASH_REMATCH[1]}
            break
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*3600))
            break
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*86400))
            break
        else
            echo -e "${COLOR_RED}❌ 输入格式错误，请使用例如 '300s', '2h', '1d' 等格式。${COLOR_RESET}"
        fi
    done

    echo -e "${COLOR_GREEN}⏱ Watchtower检查间隔设置为 $WT_INTERVAL 秒${COLOR_RESET}"
    
    # 允许用户在设置模式时修改标签和额外参数，以及调试模式
    configure_watchtower_settings

    # 保存脚本配置中的Watchtower状态
    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL"
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="$ENABLE_SELF_UPDATE_PARAM"
    WATCHTOWER_ENABLED="true" # 启用Watchtower
    save_config

    # 停止并删除旧的 Watchtower 容器 (忽略错误，因为可能不存在)
    set +e # 允许 docker rm 失败
    docker rm -f watchtower &>/dev/null || true
    set -e # 重新启用错误检查
        
    if ! _start_watchtower_container_logic "$WT_INTERVAL" "$ENABLE_SELF_UPDATE_PARAM" "$MODE_NAME"; then
        # 如果启动失败，可能需要回退到安全模式 (仅智能模式需要)
        if [ "$ENABLE_SELF_UPDATE_PARAM" = "true" ]; then
            echo -e "${COLOR_YELLOW}⚠️ Watchtower 智能模式启动失败，尝试回退到不更新自身模式...${COLOR_RESET}"
            set +e; docker rm -f watchtower &>/dev/null; set -e # 确保旧的已移除
            if _start_watchtower_container_logic "$WT_INTERVAL" "false" "Watchtower安全模式"; then
                 send_notify "⚠️ Docker 自动更新助手：Watchtower 智能模式失败，已回退到不更新自身模式。"
                 echo -e "${COLOR_YELLOW}⚠️ Watchtower 智能模式回退完成！它将更新所有符合条件的容器，但不会尝试更新自身。${COLOR_RESET}"
            else
                 send_notify "❌ Docker 自动更新助手：Watchtower 智能模式回退失败！请手动检查。"
                 echo -e "${COLOR_RED}❌ $MODE_NAME 启动失败，请检查配置和日志。${COLOR_RESET}"
            fi
        else
            # 非智能模式启动失败，直接报告错误
            echo -e "${COLOR_RED}❌ $MODE_NAME 启动失败，请检查配置和日志。${COLOR_RESET}"
        fi
        return 1 # 启动失败，返回非零值
    fi
    echo "您可以使用选项2查看 Docker 容器信息。"
    press_enter_to_continue # 调用修改后的函数
    return 0 # 成功完成，返回零值
}

# 🔹 Cron 定时任务配置
configure_cron_task() {
    echo -e "${COLOR_YELLOW}🕑 Cron定时任务模式${COLOR_RESET}"
    local CRON_HOUR_TEMP="" # 临时变量
    local DOCKER_COMPOSE_PROJECT_DIR_TEMP="" # 临时变量

    while true; do
        read -p "请输入每天更新的小时 (0-23, 当前: ${CRON_HOUR:-未设置}, 默认4): " CRON_HOUR_INPUT
        CRON_HOUR_INPUT=${CRON_HOUR_INPUT:-${CRON_HOUR:-4}} # 允许空输入保留原值或使用默认值4
        if [[ "$CRON_HOUR_INPUT" =~ ^[0-9]+$ ]] && [ "$CRON_HOUR_INPUT" -ge 0 ] && [ "$CRON_HOUR_INPUT" -le 23 ]; then
            CRON_HOUR_TEMP="$CRON_HOUR_INPUT"
            break
        else
            echo -e "${COLOR_RED}❌ 小时输入无效，请在 0-23 之间输入一个数字。${COLOR_RESET}"
        fi
    done

    while true; do
        read -p "请输入 Docker Compose 文件所在的**完整目录路径** (例如 /opt/my_docker_project, 当前: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}): " DOCKER_COMPOSE_PROJECT_DIR_INPUT
        DOCKER_COMPOSE_PROJECT_DIR_INPUT=${DOCKER_COMPOSE_PROJECT_DIR_INPUT:-$DOCKER_COMPOSE_PROJECT_DIR_CRON} # 允许空输入保留原值
        if [ -z "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
            echo -e "${COLOR_RED}❌ Docker Compose 目录路径不能为空。${COLOR_RESET}"
        elif [ ! -d "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
            echo -e "${COLOR_RED}❌ 指定的目录 '$DOCKER_COMPOSE_PROJECT_DIR_INPUT' 不存在。请检查路径是否正确。${COLOR_RESET}"
        else
            DOCKER_COMPOSE_PROJECT_DIR_TEMP="$DOCKER_COMPOSE_PROJECT_DIR_INPUT"
            break
        fi
    done

    # 更新全局变量并保存配置
    CRON_HOUR="$CRON_HOUR_TEMP"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_TEMP"
    CRON_TASK_ENABLED="true" # 启用Cron任务
    save_config
    
    # 定义 Cron 脚本路径
    CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    LOG_FILE="/var/log/docker-auto-update-cron.log"

    # 使用 printf %q 来安全地引用目录路径，防止路径中包含特殊字符导致问题
    # 使用 <<'EOF_INNER_SCRIPT' 来防止在生成脚本时，父脚本的变量被意外展开
    cat > "$CRON_UPDATE_SCRIPT" <<EOF_INNER_SCRIPT
#!/bin/bash
PROJECT_DIR=$(printf "%q" "$DOCKER_COMPOSE_PROJECT_DIR_CRON") # 这是父脚本传过来的项目目录，已安全引用
LOG_FILE="$LOG_FILE"

echo "\$(date '+%Y-%m-%d %H:%M:%S') - 开始执行 Docker Compose 更新，项目目录: \$PROJECT_DIR" >> "\$LOG_FILE" 2>&1

if [ ! -d "\$PROJECT_DIR" ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：Docker Compose 项目目录 '\$PROJECT_DIR' 不存在或无法访问。" >> "\$LOG_FILE" 2>&1
    exit 1
fi

cd "\$PROJECT_DIR" || { echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：无法切换到目录 '\$PROJECT_DIR'。" >> "\$LOG_FILE" 2>&1; exit 1; }

# 优先使用 'docker compose' (V2)，如果不存在则回退到 'docker-compose' (V1)
# 将 Docker Compose 命令检测逻辑直接嵌入到 Cron 脚本中
if command -v docker compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    DOCKER_COMPOSE_CMD=""
fi

if [ -n "\$DOCKER_COMPOSE_CMD" ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 使用 '\$DOCKER_COMPOSE_CMD' 命令进行拉取和更新。" >> "\$LOG_FILE" 2>&1
    "\$DOCKER_COMPOSE_CMD" pull >> "\$LOG_FILE" 2>&1
    "\$DOCKER_COMPOSE_CMD" up -d --remove-orphans >> "\$LOG_FILE" 2>&1 # 增加 --remove-orphans
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：未找到 'docker compose' 或 'docker-compose' 命令。" >> "\$LOG_FILE" 2>&1
    exit 1
fi

# 清理不再使用的镜像
echo "\$(date '+%Y-%m-%d %H:%M:%S') - 清理无用 Docker 镜像。" >> "\$LOG_FILE" 2>&1
docker image prune -f >> "\$LOG_FILE" 2>&1

echo "\$(date '+%Y-%m-%d %H:%M:%S') - Docker Compose 更新完成。" >> "\$LOG_FILE" 2>&1
EOF_INNER_SCRIPT

    chmod +x "$CRON_UPDATE_SCRIPT"

    # 移除旧的 Cron 任务 (如果存在)，添加新的
    (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT" ; echo "0 $CRON_HOUR * * * $CRON_UPDATE_SCRIPT >> \"$LOG_FILE\" 2>&1") | crontab -

    send_notify "✅ Cron 定时任务配置完成，每天 $CRON_HOUR 点更新容器，项目目录：$DOCKER_COMPOSE_PROJECT_DIR_CRON"
    echo -e "${COLOR_GREEN}🎉 Cron 定时任务设置成功！每天 $CRON_HOUR 点会尝试更新您的 Docker Compose 项目。${COLOR_RESET}"
    echo -e "更新日志可以在 '${COLOR_YELLOW}$LOG_FILE${COLOR_RESET}' 文件中查看。"
    echo "您可以使用选项2查看 Docker 容器信息。"
    press_enter_to_continue # 调用修改后的函数
    return 0 # 成功完成，返回零值
}


# 🔹 更新模式子菜单
update_menu() {
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
    echo "1) 🚀 Watchtower模式 (自动监控并更新所有运行中的容器镜像)"
    echo "2) 🕑 Cron定时任务模式 (通过 Docker Compose 定时拉取并重启指定项目)"
    echo "3) 🤖 智能 Watchtower模式 (Watchtower 尝试更新自身)"
    read -p "请输入选择 [1-3] 或按 Enter 返回主菜单: " MODE_CHOICE # 优化提示

    if [ -z "$MODE_CHOICE" ]; then # 如果输入为空，则返回
        return 10 # 返回一个特定代码表示返回上一级菜单
    fi

    case "$MODE_CHOICE" in
    1)
        configure_watchtower "Watchtower模式" "false"
        ;;
    2)
        configure_cron_task
        ;;
    3)
        configure_watchtower "智能 Watchtower模式" "true"
        ;;
    *)
        echo -e "${COLOR_RED}❌ 输入无效，请选择 1-3 之间的数字。${COLOR_RESET}"
        press_enter_to_continue # 在无效输入后也暂停
        ;;
    esac
    return 0 # 成功处理一个子菜单选项后返回 0
}

# 🔹 任务管理菜单
manage_tasks() {
    echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
    echo "1) 停止并移除 Watchtower 容器"
    echo "2) 移除 Cron 定时任务"
    read -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MANAGE_CHOICE # 优化提示

    if [ -z "$MANAGE_CHOICE" ]; then # 如果输入为空，则返回
        return 10 # 返回一个特定代码表示返回上一级菜单
    fi

    case "$MANAGE_CHOICE" in
        1)
            if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                if confirm_action "您确定要停止并移除 Watchtower 容器吗？这将停止自动更新。"; then
                    set +e # 允许 docker rm 失败
                    docker stop watchtower &>/dev/null
                    docker rm watchtower &>/dev/null
                    set -e # 重新启用错误检查
                    # 清空配置中的Watchtower相关变量
                    WATCHTOWER_CONFIG_INTERVAL=""
                    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"
                    WATCHTOWER_ENABLED="false" # 禁用Watchtower
                    save_config
                    send_notify "🗑️ Watchtower 容器已停止并移除。"
                    echo -e "${COLOR_GREEN}✅ Watchtower 容器已停止并移除。${COLOR_RESET}"
                else
                    echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
                fi
            else
                echo -e "${COLOR_YELLOW}ℹ️ Watchtower 容器未运行或不存在。${COLOR_RESET}"
            fi
            ;;
        2)
            CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
            if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
                if confirm_action "您确定要移除 Cron 定时任务吗？这将停止定时更新。"; then
                    (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT") | crontab -
                    set +e # 允许 rm 失败
                    rm -f "$CRON_UPDATE_SCRIPT" &>/dev/null # 删除生成的脚本文件
                    set -e # 重新启用错误检查
                    # 清空配置中的Cron相关变量
                    DOCKER_COMPOSE_PROJECT_DIR_CRON=""
                    CRON_HOUR=""
                    CRON_TASK_ENABLED="false" # 禁用Cron任务
                    save_config
                    send_notify "🗑️ Cron 定时任务已移除。"
                    echo -e "${COLOR_GREEN}✅ Cron 定时任务已移除。${COLOR_RESET}"
                else
                    echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
                fi
            else
                echo -e "${COLOR_YELLOW}ℹ️ 未检测到由本脚本配置的 Cron 定时任务。${COLOR_RESET}"
            fi
            ;;
        *)
            echo -e "${COLOR_RED}❌ 输入无效，请选择 1-2 之间的数字。${COLOR_RESET}"
            press_enter_to_continue # 在无效输入后也暂停
            ;;
    esac
    press_enter_to_continue # 调用修改后的函数
    return 0 # 成功处理一个子菜单选项后返回 0
}

# 🔹 状态报告
show_status() {
    echo -e "\n${COLOR_YELLOW}📊 当前自动化更新状态报告：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"

    # Watchtower 状态 (脚本配置 vs 运行状态)
    echo -e "${COLOR_BLUE}--- Watchtower 脚本配置状态 ---${COLOR_RESET}" # 明确为脚本配置
    echo "  - 启用状态: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "${COLOR_GREEN}已启用${COLOR_RESET}" || echo "${COLOR_RED}已禁用${COLOR_RESET}")"
    echo "  - 配置的检查间隔: ${WATCHTOWER_CONFIG_INTERVAL:-未设置} 秒"
    echo "  - 配置的智能模式 (更新自身): $([ "$WATCHTOWER_CONFIG_SELF_UPDATE_MODE" = "true" ] && echo "是" || echo "否")"
    echo "  - 配置的标签筛选: ${WATCHTOWER_LABELS:-无}"
    echo "  - 配置的额外参数: ${WATCHTOWER_EXTRA_ARGS:-无}"
    echo "  - 配置的调试模式: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "启用" || echo "禁用")"

    echo -e "${COLOR_BLUE}--- Watchtower 容器实际运行状态 ---${COLOR_RESET}" # 明确为容器运行状态
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_GREEN}✅ Watchtower 容器正在运行。${COLOR_RESET}"
        local wt_status=$(docker inspect watchtower --format "{{.State.Status}}")
        local wt_cmd_json=$(docker inspect watchtower --format "{{json .Config.Cmd}}") # 获取完整的Cmd数组

        local wt_interval_running="N/A"
        local wt_labels_running="无"
        local is_self_updating_running="否"
        local debug_mode_running="禁用"
        
        # 使用 awk 从 JSON 数组中解析参数
        wt_interval_running=$(echo "$wt_cmd_json" | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /"--interval"/) {
                    val = $(i+1); gsub(/"/, "", val); gsub(/,/, "", val); print val; exit;
                }
            }
        }' FS=', *' | head -n 1)

        wt_labels_running=$(echo "$wt_cmd_json" | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /"--label-enable"/) {
                    val = $(i+1); gsub(/"/, "", val); gsub(/,/, "", val); print val; exit;
                }
            }
        }' FS=', *' | head -n 1)
        
        if echo "$wt_cmd_json" | grep -q '"watchtower"\]$' || echo "$wt_cmd_json" | grep -q '"watchtower",'; then
            is_self_updating_running="是"
        fi
        if echo "$wt_cmd_json" | grep -q '"--debug"'; then
            debug_mode_running="启用"
        fi

        echo "  - 容器运行状态: $wt_status"
        echo "  - 实际检查间隔 (运行): ${wt_interval_running:-N/A} 秒"
        echo "  - 实际智能模式 (运行): $is_self_updating_running"
        echo "  - 实际标签筛选 (运行): ${wt_labels_running:-无}"
        echo "  - 实际调试模式 (运行): ${debug_mode_running:-禁用}"
        # 注意：实际额外参数的解析依然复杂，这里只报告配置的
    elif docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_YELLOW}⚠️ Watchtower 容器已存在但未运行。${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}❌ 未检测到 Watchtower 容器。${COLOR_RESET}"
    fi

    # Cron 任务状态
    echo -e "${COLOR_BLUE}--- Cron 定时任务脚本配置状态 ---${COLOR_RESET}" # 明确为脚本配置
    echo "  - 启用状态: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "${COLOR_GREEN}已启用${COLOR_RESET}" || echo "${COLOR_RED}已禁用${COLOR_RESET}")"
    echo "  - 配置的每天更新时间: ${CRON_HOUR:-未设置} 点"
    echo "  - 配置的 Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"

    echo -e "${COLOR_BLUE}--- Cron 定时任务实际运行状态 ---${COLOR_RESET}" # 明确为实际运行状态
    local CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
        echo -e "${COLOR_GREEN}✅ Cron 定时任务已配置并激活。${COLOR_RESET}"
        local cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_UPDATE_SCRIPT")
        echo "  - 实际定时表达式 (运行): $(echo "$cron_entry" | cut -d ' ' -f 1-5)"
        echo "  - 日志文件: /var/log/docker-auto-update-cron.log"
    else
        echo -e "${COLOR_RED}❌ 未检测到由本脚本配置的 Cron 定时任务。${COLOR_RESET}"
    fi
    echo "-------------------------------------------------------------------------------------------------------------------"
    return 0 # 确保函数有返回码
}

# 🔹 配置查看与编辑
view_and_edit_config() {
    echo -e "${COLOR_YELLOW}🔍 脚本配置查看与编辑：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "1) Telegram Bot Token: ${TG_BOT_TOKEN:-未设置}"
    echo "2) Telegram Chat ID:   ${TG_CHAT_ID:-未设置}"
    echo "3) Email 接收地址:     ${EMAIL_TO:-未设置}"
    echo "4) Watchtower 标签筛选: ${WATCHTOWER_LABELS:-无}"
    echo "5) Watchtower 额外参数: ${WATCHTOWER_EXTRA_ARGS:-无}"
    echo "6) Watchtower 调试模式: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "启用" || echo "禁用")"
    echo "7) Watchtower 配置间隔: ${WATCHTOWER_CONFIG_INTERVAL:-未设置} 秒"
    echo "8) Watchtower 智能模式: $([ "$WATCHTOWER_CONFIG_SELF_UPDATE_MODE" = "true" ] && echo "是" || echo "否")"
    echo "9) Watchtower 脚本配置启用: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "10) Cron 更新小时:      ${CRON_HOUR:-未设置}"
    echo "11) Cron Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
    echo "12) Cron 脚本配置启用: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "-------------------------------------------------------------------------------------------------------------------"
    read -p "请输入要编辑的选项编号 (1-12) 或按 Enter 返回主菜单: " edit_choice

    if [ -z "$edit_choice" ]; then # 如果输入为空，则返回
        return 10 # 返回一个特定代码表示返回上一级菜单
    fi

    case "$edit_choice" in
        1)
            read -p "请输入新的 Telegram Bot Token (当前: ${TG_BOT_TOKEN:-未设置}, 空输入不修改): " TG_BOT_TOKEN_NEW
            TG_BOT_TOKEN="${TG_BOT_TOKEN_NEW:-$TG_BOT_TOKEN}"
            save_config
            ;;
        2)
            read -p "请输入新的 Telegram Chat ID (当前: ${TG_CHAT_ID:-未设置}, 空输入不修改): " TG_CHAT_ID_NEW
            TG_CHAT_ID="${TG_CHAT_ID_NEW:-$TG_CHAT_ID}"
            save_config
            ;;
        3)
            read -p "请输入新的 Email 接收地址 (当前: ${EMAIL_TO:-未设置}, 空输入不修改): " EMAIL_TO_NEW
            EMAIL_TO="${EMAIL_TO_NEW:-$EMAIL_TO}"
            if [ -n "$EMAIL_TO" ] && ! command -v mail &>/dev/null; then
                echo -e "${COLOR_YELLOW}⚠️ 'mail' 命令未找到。如果需要 Email 通知，请安装并配置邮件传输代理 (MTA)。${COLOR_RESET}"
            fi
            save_config
            ;;
        4)
            read -p "请输入新的 Watchtower 标签筛选 (当前: ${WATCHTOWER_LABELS:-无}, 空输入取消筛选): " WATCHTOWER_LABELS_NEW
            WATCHTOWER_LABELS="${WATCHTOWER_LABELS_NEW:-}" # 允许空输入来清除
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 标签筛选已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}"
            ;;
        5)
            read -p "请输入新的 Watchtower 额外参数 (当前: ${WATCHTOWER_EXTRA_ARGS:-无}, 空输入取消额外参数): " WATCHTOWER_EXTRA_ARGS_NEW
            WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-}" # 允许空输入来清除
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 额外参数已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}"
            ;;
        6)
            local debug_choice=""
            read -p "是否启用 Watchtower 调试模式 (--debug)？(y/n) (当前: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")): " debug_choice
            if [[ "$debug_choice" == "y" || "$debug_choice" == "Y" ]]; then
                WATCHTOWER_DEBUG_ENABLED="true"
            else
                WATCHTOWER_DEBUG_ENABLED="false"
            fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 调试模式已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}"
            ;;
        7) # Watchtower 配置间隔
            local WT_INTERVAL_TEMP=""
            while true; do
                read -p "请输入新的 Watchtower 检查间隔（例如 300s / 2h / 1d，当前: ${WATCHTOWER_CONFIG_INTERVAL:-未设置}秒): " INTERVAL_INPUT
                INTERVAL_INPUT=${INTERVAL_INPUT:-${WATCHTOWER_CONFIG_INTERVAL:-300}} # 允许空输入保留原值或使用默认值
                if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then
                    WT_INTERVAL_TEMP=${BASH_REMATCH[1]}
                    break
                elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then
                    WT_INTERVAL_TEMP=$((${BASH_REMATCH[1]}*3600))
                    break
                elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then
                    WT_INTERVAL_TEMP=$((${BASH_REMATCH[1]}*86400))
                    break
                elif [[ "$INTERVAL_INPUT" =~ ^[0-9]+$ ]]; then # 仅数字，默认为秒
                     WT_INTERVAL_TEMP="$INTERVAL_INPUT"
                     break
                else
                    echo -e "${COLOR_RED}❌ 输入格式错误，请使用例如 '300s', '2h', '1d' 或纯数字 (秒) 等格式。${COLOR_RESET}"
                fi
            done
            WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TEMP"
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 检查间隔已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}"
            ;;
        8) # Watchtower 智能模式
            local self_update_choice=""
            read -p "是否启用 Watchtower 智能模式 (更新自身)？(y/n) (当前: $([ "$WATCHTOWER_CONFIG_SELF_UPDATE_MODE" = "true" ] && echo "是" || echo "否")): " self_update_choice
            if [[ "$self_update_choice" == "y" || "$self_update_choice" == "Y" ]]; then
                WATCHTOWER_CONFIG_SELF_UPDATE_MODE="true"
            else
                WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"
            fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 智能模式已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}"
            ;;
        9) # Watchtower 脚本配置启用
            local wt_enabled_choice=""
            read -p "是否启用 Watchtower 脚本配置？(y/n) (当前: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")): " wt_enabled_choice
            if [[ "$wt_enabled_choice" == "y" || "$wt_enabled_choice" == "Y" ]]; then
                WATCHTOWER_ENABLED="true"
            else
                WATCHTOWER_ENABLED="false"
            fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 脚本配置启用状态已修改。请注意，这仅是脚本的记录状态，您仍需通过主菜单选项 1 来启动或主菜单选项 4 -> 1 来停止实际的 Watchtower 容器。${COLOR_RESET}"
            ;;
        10) # Cron 更新小时
            local CRON_HOUR_TEMP=""
            while true; do
                read -p "请输入新的 Cron 更新小时 (0-23, 当前: ${CRON_HOUR:-未设置}, 空输入不修改): " CRON_HOUR_INPUT
                if [ -z "$CRON_HOUR_INPUT" ]; then # 如果新输入为空，则保留旧值
                    CRON_HOUR_TEMP="$CRON_HOUR"
                    break
                elif [[ "$CRON_HOUR_INPUT" =~ ^[0-9]+$ ]] && [ "$CRON_HOUR_INPUT" -ge 0 ] && [ "$CRON_HOUR_INPUT" -le 23 ]; then
                    CRON_HOUR_TEMP="$CRON_HOUR_INPUT"
                    break
                else
                    echo -e "${COLOR_RED}❌ 小时输入无效，请在 0-23 之间输入一个数字。${COLOR_RESET}"
                fi
            done
            CRON_HOUR="$CRON_HOUR_TEMP"
            save_config
            # 提示用户可能需要重新设置Cron任务
            echo -e "${COLOR_YELLOW}ℹ️ Cron 更新小时已修改，您可能需要重新配置 Cron 定时任务 (主菜单选项 1 -> 2) 以应用此更改。${COLOR_RESET}"
            ;;
        11) # Cron Docker Compose 项目目录
            local DOCKER_COMPOSE_PROJECT_DIR_TEMP=""
            while true; do
                read -p "请输入新的 Cron Docker Compose 项目目录 (当前: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}, 空输入取消设置): " DOCKER_COMPOSE_PROJECT_DIR_INPUT
                if [ -z "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
                    DOCKER_COMPOSE_PROJECT_DIR_TEMP=""
                    break
                elif [ ! -d "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
                    echo -e "${COLOR_RED}❌ 指定的目录 '$DOCKER_COMPOSE_PROJECT_DIR_INPUT' 不存在。请检查路径是否正确。${COLOR_RESET}"
                else
                    DOCKER_COMPOSE_PROJECT_DIR_TEMP="$DOCKER_COMPOSE_PROJECT_DIR_INPUT"
                    break
                fi
            done
            DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_TEMP"
            save_config
            # 提示用户可能需要重新设置Cron任务
            echo -e "${COLOR_YELLOW}ℹ️ Cron Docker Compose 项目目录已修改，您可能需要重新配置 Cron 定时任务 (主菜单选项 1 -> 2) 以应用此更改。${COLOR_RESET}"
            ;;
        12) # Cron 脚本配置启用
            local cron_enabled_choice=""
            read -p "是否启用 Cron 脚本配置？(y/n) (当前: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")): " cron_enabled_choice
            if [[ "$cron_enabled_choice" == "y" || "$cron_enabled_choice" == "Y" ]]; then
                CRON_TASK_ENABLED="true"
            else
                CRON_TASK_ENABLED="false"
            fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Cron 脚本配置启用状态已修改。请注意，这仅是脚本的记录状态，您仍需通过主菜单选项 1 -> 2 来设置或主菜单选项 4 -> 2 来移除实际的 Cron 定时任务。${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_YELLOW}ℹ️ 返回主菜单。${COLOR_RESET}"
            ;;
    esac
    press_enter_to_continue # 调用修改后的函数
    return 0 # 成功处理一个子菜单选项后返回 0
}

# 🔹 运行一次 Watchtower (立即检查并更新)
run_watchtower_once() {
    echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower (立即检查并更新)${COLOR_RESET}"

    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_YELLOW}⚠️ 注意：Watchtower 容器已在后台运行。${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}      本次一次性更新将独立执行，不会影响后台运行的 Watchtower 进程。${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}      如果希望停止后台 Watchtower，请使用主菜单选项 4 -> 1。${COLOR_RESET}"
        if ! confirm_action "是否继续运行一次性 Watchtower 更新？"; then
            echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
            press_enter_to_continue # 在操作取消后也暂停
            return 0
        fi
    fi

    if ! _start_watchtower_container_logic "" "false" "一次性更新"; then # 一次性运行不关心间隔和智能模式，由 --run-once 决定
        press_enter_to_continue # 在错误后也暂停
        return 1
    fi
    press_enter_to_continue # 在操作完成后暂停
    return 0 # 成功完成，返回零值
}

# 🔹 主菜单
main_menu() {
    while true; do
        clear # 清屏以获得更好的体验
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
        # 修正：根据 IS_NESTED_CALL 变量决定退出选项的文本
        if [ "$IS_NESTED_CALL" = "true" ]; then
            echo "7) 返回上级菜单"
        else
            echo "7) 退出脚本"
        fi
        echo -e "-------------------------------------------"
        read -p "请输入选择 [1-7] (按 Enter 直接退出/返回): " choice

        # 主菜单回车直接退出
        if [ -z "$choice" ]; then
            choice=7
        fi

        case "$choice" in
            1)
                update_menu
                ;;
            2)
                show_container_info
                ;;
            3)
                configure_notify
                ;;
            4)
                manage_tasks
                ;;
            5)
                view_and_edit_config
                ;;
            6)
                run_watchtower_once
                ;;
            7)
                # 修正：根据 IS_NESTED_CALL 决定行为
                if [ "$IS_NESTED_CALL" = "true" ]; then
                    echo -e "${COLOR_YELLOW}↩️ 返回上级菜单...${COLOR_RESET}"
                    # 使用特定的退出码 10，让父脚本知道是正常返回
                    exit 10
                else
                    echo -e "${COLOR_GREEN}👋 感谢使用，脚本已退出。${COLOR_RESET}"
                    exit 0
                fi
                ;;
            *)
                echo -e "${COLOR_RED}❌ 输入无效，请选择 1-7 之间的数字。${COLOR_RESET}"
                press_enter_to_continue
                ;;
        esac
    done
}


# --- [新增] 主执行函数 ---
# 将所有顶级执行逻辑封装到这里
main() {
    # 1. 显示脚本欢迎信息
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION${COLOR_RESET}"
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"

    # 2. 直接显示当前自动化更新状态报告
    show_status

    # 3. 调用主菜单函数
    main_menu
}

# --- [新增] 脚本的唯一入口点 ---
# 这确保了上面的所有函数都已被 shell 解析后，才开始执行 main 函数
main
