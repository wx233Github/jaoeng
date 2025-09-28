#!/bin/bash
# 🚀 Docker 自动更新助手
# v2.17.30 体验优化：修复 Bash 语法错误 (if/fi/continue 结构)；修复日志捕获问题；
#                    优化 Watchtower 日志获取和解析；增强通知重试机制；
#                    提升状态报告和日志详情的用户体验；强制移除Watchtower自更新模式。
#                    修复：'unexpected token <' 错误，通过避免进程替换 <() 语法来增强兼容性。
#                    新增：脚本启动时强制检查并使用 Bash 环境。
#                    重要修复：解决 "syntax error in conditional expression: unexpected token '('" 问题，
#                              通过更健壮的Watchtower日志数值提取方式（显式强制转换为整数）。
# 功能：
# - Watchtower / Cron 更新模式
# - 支持秒/小时/天数输入
# - 通知配置菜单
# - 查看容器信息（中文化 + 镜像标签 + 应用版本 - 优化：优先检查Docker标签）
# - 设置成功提示中文化 + emoji
# - 任务管理 (停止Watchtower, 移除Cron任务)
# - 全面状态报告 (脚本启动时直接显示，优化排版，新增Watchtower倒计时)
# - 脚本配置查看与编辑
# - 运行一次 Watchtower (立即检查并更新 - 调试模式可配置)
# - 新增: 查看 Watchtower 运行详情 (下次检查时间，24小时内更新记录 - 优化提示)

VERSION="2.17.34" # 版本更新，反映所有已知问题修复和排版优化
SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf" # 配置文件路径，需要root权限才能写入和读取

# --- 全局变量，判断是否为嵌套调用 ---
IS_NESTED_CALL="${IS_NESTED_CALL:-false}" # 默认值为 false，如果父脚本设置了，则会被覆盖为 true

# --- 颜色定义 ---
if [ -t 1 ]; then # 检查标准输出是否是终端
    COLOR_GREEN="\033[0m\033[0;32m"
    COLOR_RED="\033[0m\033[0;31m"
    COLOR_YELLOW="\033[0m\033[0;33m"
    COLOR_BLUE="\033[0m\033[0;34m"
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

# --- 强制脚本使用 Bash 执行 ---
# 如果当前 shell 不是 Bash，则用 Bash 重新执行自身。
# 这解决了用户可能使用 'sh script.sh' 运行，导致 Bash 特有语法报错的问题。
if [ -z "$BASH_VERSION" ]; then
    echo -e "${COLOR_YELLOW}ℹ️ 检测到非 Bash 环境。正在使用 Bash 重新启动脚本...${COLOR_RESET}" >&2 # 输出到 stderr
    exec bash "$0" "$@"
    # exec 成功后，当前进程会被替换为新的 bash 进程，不会执行下面的代码
    # 如果 exec 失败（例如没有找到 bash），则会继续执行并报错
    echo -e "${COLOR_RED}❌ 无法找到 Bash shell 或重新执行失败。请确保系统安装了 Bash。${COLOR_RESET}" >&2
    exit 1
fi

# 现在可以安全地使用 Bash 特有功能
set -euo pipefail # 任何命令失败都立即退出脚本

# 检查 Docker
if ! command -v docker &>/dev/null; then
    echo -e "${COLOR_RED}❌ 未检测到 Docker，请先安装。${COLOR_RESET}"
    exit 1
fi

# 检查 jq
if ! command -v jq &>/dev/null; then
    echo -e "${COLOR_RED}❌ 未检测到 'jq' 工具，它用于解析JSON数据。请先安装：sudo apt install jq 或 sudo yum install jq${COLOR_RESET}"
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
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false" # 智能模式已移除，默认强制为 false
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

# 优化的“按回车继续”提示：在读取用户输入前清空缓冲区，全局解决自动跳过问题。
press_enter_to_continue() {
    echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}"
    # --- 清空输入缓冲区，防止残留的换行符导致自动跳过 ---
    while read -r -t 0; do read -r; done
    read -r # 读取一个空行，等待用户按Enter
}

# 🔹 通知函数 (脚本自身的通知，Watchtower 可配置自己的通知)
send_notify() {
    local MSG="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        # 增加重试机制，提高通知可靠性
        curl -s --retry 3 --retry-delay 5 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
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
    # 智能模式已移除，强制为 false
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"

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

    # 调试模式配置依然保留
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

show_container_info() {
    echo -e "${COLOR_YELLOW}📋 Docker 容器信息：${COLOR_RESET}"
    printf "%-20s %-45s %-25s %-15s %-15s\n" "容器名称" "镜像" "创建时间" "状态" "应用版本"
    echo "-------------------------------------------------------------------------------------------------------------------"

    # 使用管道而不是进程替换，以提高兼容性
    docker ps -a --format "{{.Names}} {{.Image}} {{.CreatedAt}} {{.Status}}" | while read -r name image created status; do
        local APP_VERSION="N/A"
        local IMAGE_NAME_FOR_LABELS
        IMAGE_NAME_FOR_LABELS=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)

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
                local CONTAINER_APP_EXECUTABLE
                CONTAINER_APP_EXECUTABLE=$(docker exec "$name" sh -c "find /app -maxdepth 1 -type f -executable -print -quit" 2>/dev/null || true)
                if [ -n "$CONTAINER_APP_EXECUTABLE" ]; then
                    local RAW_VERSION
                    RAW_VERSION=$(docker exec "$name" sh -c "$CONTAINER_APP_EXECUTABLE --version 2>/dev/null || echo 'N/A'")
                    APP_VERSION=$(echo "$RAW_VERSION" | head -n 1 | cut -c 1-15 | tr -d '\n')
                fi
            fi
        fi
        printf "%-20s %-45s %-25s %-15s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
    done
    press_enter_to_continue
    return 0 # 确保函数有返回码
}

# 🔹 统一的 Watchtower 容器启动逻辑
_start_watchtower_container_logic() {
    local wt_interval="$1"
    local enable_self_update="$2" # 此参数现已无实际作用，self-update 已强制为 false
    local mode_description="$3" # "Watchtower模式" 或 "一次性更新"

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

    local WT_CMD_ARGS="--cleanup --interval $wt_interval"
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then
        WT_CMD_ARGS="$WT_CMD_ARGS $WATCHTOWER_EXTRA_ARGS" # 添加额外参数
    fi
    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
        WT_CMD_ARGS="$WT_CMD_ARGS --debug" # 添加调试模式参数
    fi
    if [ -n "$WATCHTOWER_LABELS" ]; then
        WT_CMD_ARGS="$WT_CMD_ARGS --label-enable $WATCHTOWER_LABELS"
        echo -e "${COLOR_YELLOW}ℹ️ $mode_description 将只更新带有标签 '$WATCHTOWER_LABELS' 的容器。${COLOR_RESET}"
    fi

    local FINAL_CMD="docker run $WT_RUN_ARGS -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower $WT_CMD_ARGS"
    # WATCHTOWER_CONFIG_SELF_UPDATE_MODE 强制为 false，不再支持更新自身
    # if [ "$enable_self_update" = "true" ]; then
    #     FINAL_CMD="$FINAL_CMD watchtower" # Watchtower 不再推荐自更新，此处逻辑保持禁用
    # fi

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
    echo -e "${COLOR_YELLOW}🚀 Watchtower模式 ${COLOR_RESET}"

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
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false" # 智能模式已移除，强制为 false
    WATCHTOWER_ENABLED="true" # 启用Watchtower
    save_config

    # 停止并删除旧的 Watchtower 容器 (忽略错误，因为可能不存在)
    set +e # 允许 docker rm 失败
    docker rm -f watchtower &>/dev/null || true
    set -e # 重新启用错误检查

    if ! _start_watchtower_container_logic "$WT_INTERVAL" "false" "Watchtower模式"; then # 始终传递 false 给 self_update
        echo -e "${COLOR_RED}❌ Watchtower模式 启动失败，请检查配置和日志。${COLOR_RESET}"
        return 1 # 启动失败，返回非零值
    fi
    echo "您可以使用选项2查看 Docker 容器信息。"
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

    cat > "$CRON_UPDATE_SCRIPT" <<EOF_INNER_SCRIPT
#!/bin/bash
PROJECT_DIR="$DOCKER_COMPOSE_PROJECT_DIR_CRON"
LOG_FILE="$LOG_FILE"

echo "\$(date '+%Y-%m-%d %H:%M:%S') - 开始执行 Docker Compose 更新，项目目录: \$PROJECT_DIR" >> "\$LOG_FILE" 2>&1

if [ ! -d "\$PROJECT_DIR" ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：Docker Compose 项目目录 '\$PROJECT_DIR' 不存在或无法访问。" >> "\$LOG_FILE" 2>&1
    exit 1
fi

cd "\$PROJECT_DIR" || { echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：无法切换到目录 '\$PROJECT_DIR'。" >> "\$LOG_FILE" 2>&1; exit 1; }

# 优先使用 'docker compose' (V2)，如果不存在则回退到 'docker-compose' (V1)
if command -v docker compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 错误：未找到 'docker compose' 或 'docker-compose' 命令。" >> "\$LOG_FILE" 2>&1
    exit 1
fi

if [ -n "\$DOCKER_COMPOSE_CMD" ]; then
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - 使用 '\$DOCKER_COMPOSE_CMD' 命令进行拉取和更新。" >> "\$LOG_FILE" 2>&1
    "\$DOCKER_COMPOSE_CMD" pull >> "\$LOG_FILE" 2>&1
    "\$DOCKER_COMPOSE_CMD" up -d --remove-orphans >> "\$LOG_FILE" 2>&1
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
    return 0 # 成功完成，返回零值
}

update_menu() {
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
    echo "1) 🚀 Watchtower模式 (自动监控并更新所有运行中的容器镜像)"
    echo "2) 🕑 Cron定时任务模式 (通过 Docker Compose 定时拉取并重启指定项目)"
    read -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MODE_CHOICE # 选项变为 1-2

    if [ -z "$MODE_CHOICE" ]; then
        return 0
    fi

    case "$MODE_CHOICE" in
    1)
        configure_watchtower
        ;;
    2)
        configure_cron_task
        ;;
    *)
        echo -e "${COLOR_RED}❌ 输入无效，请选择 1-2 之间的数字。${COLOR_RESET}"
        ;;
    esac
    return 0
}

# 🔹 任务管理菜单
manage_tasks() {
    echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
    echo "1) 停止并移除 Watchtower 容器"
    echo "2) 移除 Cron 定时任务"
    read -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MANAGE_CHOICE

    if [ -z "$MANAGE_CHOICE" ]; then
        return 0
    fi

    case "$MANAGE_CHOICE" in
        1)
            if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                if confirm_action "您确定要停止并移除 Watchtower 容器吗？这将停止自动更新。"; then
                    set +e
                    docker stop watchtower &>/dev/null
                    docker rm watchtower &>/dev/null
                    set -e
                    WATCHTOWER_CONFIG_INTERVAL=""
                    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false" # 智能模式已移除，强制为 false
                    WATCHTOWER_ENABLED="false"
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
                    set +e
                    rm -f "$CRON_UPDATE_SCRIPT" &>/dev/null
                    set -e
                    DOCKER_COMPOSE_PROJECT_DIR_CRON=""
                    CRON_HOUR=""
                    CRON_TASK_ENABLED="false"
                    save_config
                    send_notify "🗑️ Watchtower 任务已移除。"
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
            ;;
    esac
    return 0
}

# 辅助函数：以最健壮的方式获取 Watchtower 的所有原始日志
_get_watchtower_all_raw_logs() {
    local temp_log_file="/tmp/watchtower_raw_logs_$$.log"
    # 确保临时文件在函数退出时无论成功失败都会被清理
    trap "rm -f \"$temp_log_file\"" RETURN

    local container_id
    set +e
    container_id=$(docker inspect watchtower --format '{{.Id}}' 2>/dev/null)
    set -e

    if [ -z "$container_id" ]; then
        echo ""
        return
    fi

    # 优先使用 docker logs 命令，它更通用且不依赖日志驱动配置
    # 限制 --tail 数量，避免日志量过大，但足够覆盖近期历史
    set +e
    # 使用 timeout 防止 docker logs 卡住，并将 stderr 重定向到 /dev/null 防止命令本身失败输出大量错误
    timeout 30s docker logs watchtower --tail 5000 --since 0s > "$temp_log_file" 2>/dev/null || true
    set -e
    
    # 返回所有日志内容
    cat "$temp_log_file"
}

# 辅助函数：获取 Watchtower 的下次检查倒计时
_get_watchtower_remaining_time() {
    local wt_interval_running="$1"
    local raw_logs="$2" # 传入已获取的日志内容
    local remaining_time_str="N/A"

    # 1. 检查是否存在扫描完成日志
    if ! echo "$raw_logs" | grep -q "Session done"; then
        echo "${COLOR_YELLOW}⚠️ 等待首次扫描完成${COLOR_RESET}" # 统一首次扫描等待提示
        return
    fi

    # 2. 查找最新的 Session done 日志
    local last_check_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
    local last_check_timestamp_str=""

    if [ -n "$last_check_log" ]; then
        # 从日志行中精确提取 time="XXX" 的值
        last_check_timestamp_str=$(echo "$last_check_log" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1)
    fi

    if [ -n "$last_check_timestamp_str" ]; then
        # 尝试将时间字符串转换为 Epoch 时间。Watchtower日志自带Z表示UTC
        local last_check_epoch
        last_check_epoch=$(date -d "$last_check_timestamp_str" +%s 2>/dev/null || true)

        if [ -n "$last_check_epoch" ]; then
            local current_epoch=$(date +%s)
            local time_since_last_check=$((current_epoch - last_check_epoch))
            local remaining_time=$((wt_interval_running - time_since_last_check))

            if [ "$remaining_time" -gt 0 ]; then
                # 计算时分秒
                local hours=$((remaining_time / 3600))
                local minutes=$(( (remaining_time % 3600) / 60 ))
                local seconds=$(( remaining_time % 60 ))
                remaining_time_str="${COLOR_GREEN}${hours}时 ${minutes}分 ${seconds}秒${COLOR_RESET}"
            else
                remaining_time_str="${COLOR_GREEN}即将进行或已超时 (${COLOR_YELLOW}${remaining_time}s)${COLOR_RESET}"
            fi
        else
            remaining_time_str="${COLOR_RED}❌ 日志时间解析失败 (检查系统date命令)${COLOR_RESET}"
        fi
    else
        remaining_time_str="${COLOR_YELLOW}⚠️ 未找到最近扫描日志${COLOR_RESET}"
    fi
    echo "$remaining_time_str"
}


# 🔹 状态报告 (移除顶部标题，改为左对齐)
show_status() {
    echo -e "${COLOR_BLUE}--- Watchtower 状态 ---${COLOR_RESET}"
    local wt_configured_mode_desc="Watchtower模式 (更新所有容器)" # 智能模式已移除

    local wt_overall_status_line
    if [ "$WATCHTOWER_ENABLED" = "true" ]; then
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
            wt_overall_status_line="${COLOR_GREEN}运行中 (${wt_configured_mode_desc})${COLOR_RESET}"
        else
            wt_overall_status_line="${COLOR_YELLOW}配置已启用，但容器未运行！(${wt_configured_mode_desc})${COLOR_RESET}"
            echo -e "  ${COLOR_YELLOW}提示: 如果Watchtower应运行，请尝试在主菜单选项1中重新设置Watchtower模式。${COLOR_RESET}"
        fi
    else
        wt_overall_status_line="${COLOR_RED}已禁用 (未配置或已停止)${COLOR_RESET}"
    fi
    printf "  - Watchtower 服务状态: %b\n" "$wt_overall_status_line"

    local script_config_interval="${WATCHTOWER_CONFIG_INTERVAL:-未设置}"
    local script_config_labels="${WATCHTOWER_LABELS:-无}"
    local script_config_extra_args="${WATCHTOWER_EXTRA_ARGS:-无}"
    local script_config_debug=$( [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "启用" || echo "禁用" )

    local container_actual_interval="N/A"
    local container_actual_labels="无"
    local container_actual_extra_args="无"
    local container_actual_debug="禁用"
    local container_actual_self_update="否 (已禁用)" # 明确指出已禁用

    local wt_remaining_time_display="${COLOR_YELLOW}N/A${COLOR_RESET}" # 初始化倒计时显示，带颜色
    local raw_logs_content_for_status="" # 用于存储 Watchtower 原始日志

    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        raw_logs_content_for_status=$(_get_watchtower_all_raw_logs) # 获取所有原始日志
        local wt_cmd_json=$(docker inspect watchtower --format "{{json .Config.Cmd}}" 2>/dev/null || echo "[]") # 确保jq有有效输入

        # 1. 解析容器实际运行参数
        # 查找 --interval 参数的值
        container_actual_interval=$(echo "$wt_cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
        container_actual_interval="${container_actual_interval:-N/A}"
        # 查找 --label-enable 参数的值
        container_actual_labels=$(echo "$wt_cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--label-enable") | .[$i+1] // empty)' 2>/dev/null || true)
        container_actual_labels="${container_actual_labels:-无}"

        # 检查 --debug 标志
        if echo "$wt_cmd_json" | jq -e 'any(. == "--debug")' >/dev/null; then
            container_actual_debug="启用"
        fi

        # 提取其他额外参数
        # 过滤掉已知参数 (--cleanup, --interval, --label-enable, --debug, watchtower)
        # Watchtower 自更新模式已在脚本层面强制禁用，这里只为显示兼容旧配置，实际不应该出现 'watchtower' 参数
        local filtered_args_array=()
        if [ -n "$wt_cmd_json" ] && [ "$wt_cmd_json" != "[]" ]; then
            # 使用管道而不是进程替换，以提高兼容性
            echo "$wt_cmd_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r arg_item; do
                case "$arg_item" in
                    --cleanup|--interval|--label-enable|--debug)
                        # 这些是 Watchtower 的标准参数，我们已经在其他地方显示
                        ;;
                    --*)
                        # 收集其他自定义的额外参数
                        if ! echo "$arg_item" | grep -qE "^--interval|^--label-enable|^--debug|^--cleanup$"; then # 再次确认排除
                            # 如果下一个参数是其值，则跳过
                            local next_arg=$(echo "$wt_cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "'"$arg_item"'") | .[$i+1] // empty)' 2>/dev/null || true)
                            if [ -z "$next_arg" ] || [[ "$next_arg" =~ ^-- ]]; then # 如果下一个是空或者又是另一个参数，说明当前参数是独立flag
                                filtered_args_array+=("$arg_item")
                            fi
                        fi
                        ;;
                    *)
                        # 排除掉 --interval 或 --label-enable 对应的值
                        if ! echo "$arg_item" | grep -qE "^[0-9]+$" && ! echo "$arg_item" | grep -qE "^com\.centurylabs\.watchtower\.enable"; then
                            # 如果是 watchtower 容器本身，并且不是之前已经识别的参数值
                            if [ "$arg_item" = "watchtower" ]; then
                                # 尽管脚本层面已禁用，但如果容器实际运行带了，还是显示
                                container_actual_self_update="${COLOR_YELLOW}是 (不推荐)${COLOR_RESET}"
                            fi
                        fi
                        ;;
                esac
            done
        fi
        container_actual_extra_args=$(IFS=' '; echo "${filtered_args_array[*]:-}")
        if [ -z "$container_actual_extra_args" ]; then container_actual_extra_args="无"; fi


        # 2. 倒计时计算 (依赖于日志)
        if echo "$raw_logs_content_for_status" | grep -q "Session done"; then
            if [[ "$container_actual_interval" =~ ^[0-9]+$ ]]; then
                wt_remaining_time_display=$(_get_watchtower_remaining_time "$container_actual_interval" "$raw_logs_content_for_status")
            else
                wt_remaining_time_display="${COLOR_YELLOW}⚠️ 无法计算倒计时 (间隔无效)${COLOR_RESET}"
            fi
        else
             # 修复：当Session done日志缺失时，根据日志内容判断是否为首次等待
             if [ -n "$raw_logs_content_for_status" ] && echo "$raw_logs_content_for_status" | grep -q "Scheduling first run"; then
                wt_remaining_time_display="${COLOR_YELLOW}⚠️ 等待首次扫描完成${COLOR_RESET}"
             else
                wt_remaining_time_display="${COLOR_YELLOW}⚠️ 无法获取日志，请检查权限/状态${COLOR_RESET}"
             fi
        fi
    fi

    # 横向对比 Watchtower 配置 (列宽压缩至 15, 12, 12 以适应 43 字符宽度)
    printf "  %-15s %-12s %-12s\n" "参数" "脚本配置" "容器运行"
    printf "  %-15s %-12s %-12s\n" "---------------" "------------" "------------"

    printf "  %-15s %-12s %-12s\n" "检查间隔 (秒)" "$script_config_interval" "$container_actual_interval"
    printf "  %-15s %-12s %-12s\n" "标签筛选" "$script_config_labels" "$container_actual_labels"
    printf "  %-15s %-12s %-12s\n" "额外参数" "$script_config_extra_args" "$container_actual_extra_args"
    printf "  %-15s %-12s %-12s\n" "调试模式" "$script_config_debug" "$container_actual_debug"
    printf "  %-15s %-12s %b\n" "更新自身" "$( [ "$WATCHTOWER_CONFIG_SELF_UPDATE_MODE" = "true" ] && echo "是" || echo "否" )" "$container_actual_self_update"
    printf "  %-15s %b\n" "下次检查倒计时:" "$wt_remaining_time_display"

    if docker ps --format '{{.Names}}' | grep -q '^watchtower$' && echo "$raw_logs_content_for_status" | grep -q "unauthorized: authentication required"; then
        echo -e "  ${COLOR_RED}🚨 警告: Watchtower 日志中发现认证失败 ('unauthorized') 错误！${COLOR_RESET}"
        echo -e "         这通常意味着 Watchtower 无法拉取镜像，包括其自身。请检查 Docker Hub 认证或私有仓库配置。"
        echo -e "         如果你遇到频繁的 Docker Hub 镜像拉取失败，可能是达到了免费用户的限速，请考虑付费套餐或使用其他镜像源。"
    fi

    echo -e "${COLOR_BLUE}--- Cron 定时任务状态 ---${COLOR_RESET}"
    local cron_enabled_status
    if [ "$CRON_TASK_ENABLED" = "true" ]; then
        cron_enabled_status="${COLOR_GREEN}✅ 已启用${COLOR_RESET}"
    else
        cron_enabled_status="${COLOR_RED}❌ 已禁用${COLOR_RESET}"
    fi
    printf "  - 启用状态: %b\n" "$cron_enabled_status"
    echo "  - 配置的每天更新时间: ${CRON_HOUR:-未设置} 点"
    echo "  - 配置的 Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"

    local CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_UPDATE_SCRIPT")
        echo "  - 实际定时表达式 (运行): $(echo "$cron_entry" | cut -d ' ' -f 1-5)"
        echo "  - 日志文件: /var/log/docker-auto-update-cron.log"
    else
        echo -e "${COLOR_RED}❌ 未检测到由本脚本配置的 Cron 定时任务。${COLOR_RESET}"
    fi
    echo "" # 增加空行
    return 0
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
    echo "6) Watchtower 调试模式: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "7) Watchtower 配置间隔: ${WATCHTOWER_CONFIG_INTERVAL:-未设置} 秒"
    echo "8) Watchtower 脚本配置启用: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "9) Cron 更新小时:      ${CRON_HOUR:-未设置}"
    echo "10) Cron Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
    echo "11) Cron 脚本配置启用: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "-------------------------------------------------------------------------------------------------------------------"
    read -p "请输入要编辑的选项编号 (1-11) 或按 Enter 返回主菜单: " edit_choice

    if [ -z "$edit_choice" ]; then
        return 0
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
            WATCHTOWER_LABELS="${WATCHTOWER_LABELS_NEW:-}"
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 标签筛选已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}"
            ;;
        5)
            read -p "请输入新的 Watchtower 额外参数 (当前: ${WATCHTOWER_EXTRA_ARGS:-无}, 空输入取消额外参数): " WATCHTOWER_EXTRA_ARGS_NEW
            WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-}"
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
        7)
            local WT_INTERVAL_TEMP=""
            while true; do
                read -p "请输入新的 Watchtower 检查间隔（例如 300s / 2h / 1d，当前: ${WATCHTOWER_CONFIG_INTERVAL:-未设置}秒): " INTERVAL_INPUT
                INTERVAL_INPUT=${INTERVAL_INPUT:-${WATCHTOWER_CONFIG_INTERVAL:-300}}
                if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then
                    WT_INTERVAL_TEMP=${BASH_REMATCH[1]}
                    break
                elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then
                    WT_INTERVAL_TEMP=$((${BASH_REMATCH[1]}*3600))
                    break
                elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then
                    WT_INTERVAL_TEMP=$((${BASH_REMATCH[1]}*86400))
                    break
                elif [[ "$INTERVAL_INPUT" =~ ^[0-9]+$ ]]; then
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
        8)
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
        9)
            local CRON_HOUR_TEMP=""
            while true; do
                read -p "请输入新的 Cron 更新小时 (0-23, 当前: ${CRON_HOUR:-未设置}, 空输入不修改): " CRON_HOUR_INPUT
                if [ -z "$CRON_HOUR_INPUT" ]; then
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
            echo -e "${COLOR_YELLOW}ℹ️ Cron 更新小时已修改，您可能需要重新配置 Cron 定时任务 (主菜单选项 1 -> 2) 以应用此更改。${COLOR_RESET}"
            ;;
        10)
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
            echo -e "${COLOR_YELLOW}ℹ️ Cron Docker Compose 项目目录已修改，您可能需要重新配置 Cron 定时任务 (主菜单选项 1 -> 2) 以应用此更改。${COLOR_RESET}"
            ;;
        11)
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
    return 0
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
            press_enter_to_continue
            return 0
        fi
    fi

    # 智能模式已移除，一次性运行也应默认为更新所有容器
    if ! _start_watchtower_container_logic "" "false" "一次性更新"; then
        press_enter_to_continue
        return 1
    fi
    press_enter_to_continue
    return 0
}

# 🆕 新增：查看 Watchtower 运行详情和更新记录
show_watchtower_details() {
    echo -e "${COLOR_YELLOW}🔍 Watchtower 运行详情和更新记录：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "" # 增加空行

    if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_RED}❌ Watchtower 容器未运行。${COLOR_RESET}"
        press_enter_to_continue
        return 1
    fi

    echo -e "${COLOR_BLUE}--- Watchtower 运行详情 ---${COLOR_RESET}"
    local wt_cmd_json=$(docker inspect watchtower --format "{{json .Config.Cmd}}" 2>/dev/null || echo "[]")
    local wt_interval_running="N/A"

    # --- 确保解析到运行参数 ---
    if [ -n "$wt_cmd_json" ] && [ "$wt_cmd_json" != "[]" ]; then
        local interval_value=$(echo "$wt_cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
        wt_interval_running="${interval_value:-N/A}"
    fi

    if [ -z "$wt_interval_running" ] || ! [[ "$wt_interval_running" =~ ^[0-9]+$ ]]; then # 检查是否为有效数字
        wt_interval_running="300" # 如果解析失败或不是数字，使用默认值 300 秒进行倒计时估算
        echo -e "  ${COLOR_YELLOW}⚠️ 无法从 Watchtower 容器命令中解析出检查间隔或其为非数字，使用默认值 300 秒进行倒计时估算。${COLOR_RESET}"
    fi

    local only_self_update="否" # Watchtower 的自更新模式已在脚本层面强制禁用，此变量仅用于兼容显示
    if echo "$wt_cmd_json" | jq -e 'any(. == "watchtower")' >/dev/null; then
        only_self_update="${COLOR_YELLOW}是 (不推荐)${COLOR_RESET}"
        echo -e "  - ${COLOR_YELLOW}提示: Watchtower 容器当前配置为只监控并更新自身容器 (watchtower)。${COLOR_RESET}"
        echo -e "          如果需要更新其他容器，请在主菜单选项 1 中选择 'Watchtower模式'。${COLOR_RESET}"
    fi

    # --- 获取所有原始日志，并根据实际扫描日志进行过滤 ---
    local raw_logs=$(_get_watchtower_all_raw_logs)

    # 检查获取到的 raw_logs 是否包含有效的 Watchtower 扫描日志（Session done）
    if ! echo "$raw_logs" | grep -q "Session done"; then

        # 打印错误标题
        echo -e "${COLOR_RED}❌ 无法获取 Watchtower 容器的任何扫描完成日志 (Session done)。请检查容器状态和日志配置。${COLOR_RED}"

        # 致命错误提示
        if [ -z "$raw_logs" ]; then
             echo -e "${COLOR_RED}    致命错误：无法从 Docker 获取到任何日志。请检查 Docker 日志驱动和权限。${COLOR_RED}"
        fi

        # 优化长提示，消除多余空格
        printf "    ${COLOR_YELLOW}请确认以下几点：${COLOR_RESET}\n"
        printf "    1. 您的系统时间是否与Watchtower日志时间同步？请执行'date'命令检查，\n"
        printf "       并运行'sudo docker exec watchtower date'对比。\n"
        printf "       (如果看到'exec: date: executable file not found'错误，表明容器内无date命令，\n"
        printf "        这不影响功能，但需确认宿主机时间正确。)\n"

        printf "    2. Watchtower容器是否已运行足够长的时间以完成一次扫描？\n"

        # 增加首次扫描计划时间，如果能解析到的话
        local first_run_scheduled=$(echo "$raw_logs" | grep -E "Scheduling first run" | sed -n 's/.*Scheduling first run: \([^ ]* [^ ]*\).*/\1/p' | head -n 1 || true)
        if [ -n "$first_run_scheduled" ]; then
            echo -e "       首次扫描计划在: ${COLOR_YELLOW}$first_run_scheduled UTC${COLOR_RESET}"
            local first_run_epoch=$(date -d "$first_run_scheduled Z" +%s 2>/dev/null || true)
            if [ -n "$first_run_epoch" ]; then
                local current_epoch=$(date +%s)
                local time_to_first_run=$((first_run_epoch - current_epoch))
                if [ "$time_to_first_run" -gt 0 ]; then
                    local hours=$((time_to_first_run / 3600))
                    local minutes=$(( (time_to_first_run % 3600) / 60 ))
                    local seconds=$(( time_to_first_run % 60 ))
                    echo -e "       预计距离首次扫描还有: ${COLOR_GREEN}${hours}小时 ${minutes}分钟 ${seconds}秒${COLOR_RESET}"
                else
                    echo -e "       首次扫描应已完成或即将进行。${COLOR_RESET}"
                fi
            fi
        else
            echo -e "       未找到首次扫描计划时间。${COLOR_RESET}"
        fi

        printf "    3. 如果时间不同步，请尝试校准宿主机时间，并重启Watchtower容器。\n"
        echo -e "    ${COLOR_YELLOW}原始日志输出 (前5行):${COLOR_RESET}"
        echo "$raw_logs" | head -n 5
        press_enter_to_continue
        return 1
    fi

    # 查找最近一次检查更新的日志 (确保是 Session done)
    local last_check_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
    local last_check_timestamp_str=""

    if [ -n "$last_check_log" ]; then
        last_check_timestamp_str=$(echo "$last_check_log" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1)
    fi

    if [ -n "$last_check_timestamp_str" ]; then
        local last_check_epoch=$(date -d "$last_check_timestamp_str" +%s 2>/dev/null || true)

        if [ -n "$last_check_epoch" ]; then
            local current_epoch=$(date +%s)
            local time_since_last_check=$((current_epoch - last_check_epoch))
            local remaining_time=$((wt_interval_running - time_since_last_check))

            echo "  - 上次检查时间 (UTC): $(date -d "$last_check_timestamp_str" '+%Y-%m-%d %H:%M:%S')"

            if [ "$remaining_time" -gt 0 ]; then
                local hours=$((remaining_time / 3600))
                local minutes=$(( (remaining_time % 3600) / 60 ))
                local seconds=$(( remaining_time % 60 ))
                echo -e "  - 距离下次检查还有: ${COLOR_GREEN}${hours}时 ${minutes}分 ${seconds}秒${COLOR_RESET}"
            else
                echo -e "  - ${COLOR_GREEN}下次检查即将进行或已经超时。${COLOR_RESET}"
            fi
        else
            echo -e "  - ${COLOR_YELLOW}⚠️ 无法解析 Watchtower 上次检查的日志时间。请检查系统日期和 Watchtower 日志日期是否一致。${COLOR_RESET}"
            echo -e "    当前系统日期: $(date '+%Y-%m-%d %H:%M:%S')"
            echo -e "    Watchtower日志示例日期: $(echo "$last_check_timestamp_str" | cut -d'T' -f1)"
        fi
    else
        echo -e "  - ${COLOR_YELLOW}⚠️ 未找到 Watchtower 的最近扫描完成日志。${COLOR_RESET}"
    fi

    echo -e "\n${COLOR_BLUE}--- 24 小时内容器更新状况 ---${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    local update_logs_filtered_content=""

    local current_epoch=$(date +%s)
    local log_time_warning_issued="false"

    local temp_filtered_log="/tmp/watchtower_filtered_24h_$$"
    trap "rm -f \"$temp_filtered_log\"" RETURN # 确保函数退出时清理

    echo "$raw_logs" | while IFS= read -r line; do
        local log_time_raw=$(echo "$line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1)
        if [ -n "$log_time_raw" ]; then
            local log_epoch=$(date -d "$log_time_raw" +%s 2>/dev/null || true)
            if [ -n "$log_epoch" ]; then
                local time_diff_seconds=$((current_epoch - log_epoch))
                # 筛选出日志时间在过去 24 小时内（0到 86400秒前）
                if [ "$time_diff_seconds" -le 86400 ] && [ "$time_diff_seconds" -ge 0 ]; then
                    echo "$line" >> "$temp_filtered_log"
                elif [ "$time_diff_seconds" -lt 0 ] && [ "$log_time_warning_issued" = "false" ]; then
                    echo -e "${COLOR_YELLOW}    注意: Watchtower 日志时间显著超前当前系统时间。以下显示的日志可能并非实际过去24小时内发生。${COLOR_RESET}"
                    log_time_warning_issued="true"
                    echo "$line" >> "$temp_filtered_log" # 包含超前日志，但有警告
                fi
            else
                # 无法解析日志时间，为了不丢失信息，也加入
                echo "$line" >> "$temp_filtered_log"
            fi
        else
            # 没有时间戳的行也加入
            echo "$line" >> "$temp_filtered_log"
        fi
    done

    # 从过滤后的内容中提取关键事件
    update_logs_filtered_content=$(grep -E "Session done|Found new image for container|will pull|Updating container|container was updated|skipped because of an error|No new images found for container|Stopping container|Starting container|Pulling image|Removing old container|Creating new container|Unable to update container|Could not do a head request" "$temp_filtered_log" || true)

    if [ -z "$update_logs_filtered_content" ]; then
        echo -e "${COLOR_YELLOW}ℹ️ 过去 24 小时内未检测到容器更新或相关操作。${COLOR_RESET}"
    else
        echo "最近24小时的 Watchtower 日志摘要 (按时间顺序):"
        echo "$update_logs_filtered_content" | while IFS= read -r line; do # 使用IFS= read -r 防止空格截断
            local log_time_raw=$(echo "$line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1)
            local log_time_formatted=""
            if [ -n "$log_time_raw" ]; then
                # 尝试解析时间并格式化，如果失败则保持空
                log_time_formatted=$(date -d "$log_time_raw" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$log_time_raw")
            fi

            local container_name="N/A"
            # 优先从 container="xxx" 或 container='xxx' 提取
            if [[ "$line" =~ container=\"?/?([^\"]+)\"?[[:space:]] ]]; then
                container_name="${BASH_REMATCH[1]}"
                container_name="${container_name#/}"
            elif [[ "$line" =~ container\ \'([^\']+)\' ]]; then
                container_name="${BASH_REMATCH[1]}"
            # 如果没有，尝试从 Found new image for container XXX 或 No new images found for container XXX 提取
            elif echo "$line" | grep -qE "Found new image for container|No new images found for container"; then
                if [[ "$line" =~ (Found new image for container|No new images found for container) ([^ ]+) ]]; then
                    container_name="${BASH_REMATCH[2]}"
                fi
            fi


            local action_desc="未知操作"

            # 使用 case 结构解决条件表达式兼容性问题
            case "$line" in
                *Session\ done*)
                    # 强化：分步提取并强制清理非数字字符
                    local failed_str=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p')
                    local scanned_str=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p')
                    local updated_str=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p')

                    # 强制移除所有非数字字符
                    local cleaned_failed="${failed_str//[^0-9]/}"
                    local cleaned_scanned="${scanned_str//[^0-9]/}"
                    local cleaned_updated="${updated_str//[^0-9]/}"

                    # 显式转换为整数，如果为空或非数字则默认为0
                    local failed_val=0
                    local scanned_val=0
                    local updated_val=0

                    # 使用 printf -v 进行安全转换
                    printf -v failed_val %d "${cleaned_failed:-0}" 2>/dev/null || failed_val=0
                    printf -v scanned_val %d "${cleaned_scanned:-0}" 2>/dev/null || scanned_val=0
                    printf -v updated_val %d "${cleaned_updated:-0}" 2>/dev/null || updated_val=0
                    
                    if (( failed_val > 0 )); then
                        action_desc="${COLOR_RED}扫描完成 (扫描: ${scanned_val}, 更新: ${updated_val}, 失败: ${failed_val})${COLOR_RESET}"
                    elif (( updated_val > 0 )); then
                        action_desc="${COLOR_YELLOW}扫描完成 (扫描: ${scanned_val}, 更新: ${updated_val}, 失败: ${failed_val})${COLOR_RESET}"
                    else
                        action_desc="${COLOR_GREEN}扫描完成 (扫描: ${scanned_val}, 更新: ${updated_val}, 失败: ${failed_val})${COLOR_RESET}"
                    fi
                    ;;
                *Found\ new\ image\ for\ container*)
                    local image_info=$(echo "$line" | sed -n 's/.*image="\([^"]*\)".*/\1/p' | head -n 1)
                    action_desc="${COLOR_YELLOW}发现新版本: ${image_info:-N/A}${COLOR_RESET}"
                    ;;
                *Pulling\ image*|*will\ pull*)
                    action_desc="${COLOR_BLUE}正在拉取镜像...${COLOR_RESET}"
                    ;;
                *Stopping\ container*)
                    action_desc="${COLOR_BLUE}正在停止容器...${COLOR_RESET}"
                    ;;
                *Updating\ container*)
                    action_desc="${COLOR_BLUE}正在更新容器...${COLOR_RESET}"
                    ;;
                *container\ was\ updated*)
                    action_desc="${COLOR_GREEN}容器已更新${COLOR_RESET}"
                    ;;
                *skipped\ because\ of\ an\ error*)
                    action_desc="${COLOR_RED}更新失败 (错误)${COLOR_RESET}"
                    ;;
                *Unable\ to\ update\ container*)
                    local error_msg=$(echo "$line" | sed -n 's/.*msg="Unable to update container \/[^:]*: \(.*\)"/\1/p') # 更通用的匹配
                    action_desc="${COLOR_RED}更新失败 (无法更新): ${error_msg:-未知错误}${COLOR_RESET}"
                    ;;
                *Could\ not\ do\ a\ head\ request*)
                    local image_info=$(echo "$line" | sed -n 's/.*image="\([^"]*\)".*/\1/p' | head -n 1)
                    action_desc="${COLOR_RED}拉取失败 (head请求): 镜像 ${image_info:-N/A}${COLOR_RESET}"
                    ;;
                *No\ new\ images\ found\ for\ container*)
                    action_desc="${COLOR_GREEN}未找到新镜像${COLOR_RESET}"
                    ;;
                *Scheduling\ first\ run*)
                    action_desc="${COLOR_YELLOW}首次扫描已安排${COLOR_RESET}"
                    ;;
                *)
                    # 默认情况，如果以上规则不匹配，则尝试更宽泛的匹配
                    if echo "$line" | grep -qE "info='Updating|debug='Updating|Updating container"; then
                        action_desc="${COLOR_BLUE}正在更新容器...${COLOR_RESET}"
                    elif echo "$line" | grep -qE "info='Pulling|debug='Pulling|Pulling image"; then
                         action_desc="${COLOR_BLUE}正在拉取镜像...${COLOR_RESET}"
                    elif echo "$line" | grep -qE "info='Starting|debug='Starting|Starting container"; then
                         action_desc="${COLOR_BLUE}正在启动容器...${COLOR_RESET}"
                    elif echo "$line" | grep -qE "info='Stopping|debug='Stopping|Stopping container"; then
                         action_desc="${COLOR_BLUE}正在停止容器...${COLOR_RESET}"
                    else
                        action_desc="${COLOR_YELLOW}其他 Watchtower 日志${COLOR_RESET}"
                    fi
                    ;;
            esac

            # 仅在能提取到有效信息时才格式化输出，否则打印原始行作为调试
            if [ -n "$log_time_formatted" ] && [ "$action_desc" != "未知操作" ]; then
                printf "  %-20s %-25s %s\n" "$log_time_formatted" "$(printf "%.23s" "$container_name")" "$action_desc" # 限制容器名长度
            else
                echo "  ${COLOR_YELLOW}原始日志 (部分解析或无法解析):${COLOR_RESET} $line"
            fi
        done
    fi
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "" # 增加空行
    press_enter_to_continue
    return 0
}


# 🔹 主菜单
main_menu() {
    while true; do
        # 每次循环开始时，显示状态报告
        show_status
        echo -e "${COLOR_BLUE}==================== 主菜单 ====================${COLOR_RESET}"
        echo "1) 🚀 设置更新模式 (Watchtower / Cron)"
        echo "2) 📋 查看容器信息"
        echo "3) 🔔 配置通知 (Telegram / Email)"
        echo "4) ⚙️ 任务管理 (停止/移除)"
        echo "5) 📝 查看/编辑脚本配置"
        echo "6) 🆕 运行一次 Watchtower (立即检查更新)"

        # 统一将选项 7 用于查看详情，并处理退出逻辑
        if [ "$IS_NESTED_CALL" = "true" ]; then
            echo "7) 🔍 查看 Watchtower 运行详情和更新记录 / 返回上级菜单"
        else
            echo "7) 🔍 查看 Watchtower 运行详情和更新记录 / 退出脚本"
        fi
        echo -e "-------------------------------------------"

        while read -r -t 0; do read -r; done # 清空输入缓冲区，防止自动跳过
        read -p "请输入选择 [1-7] (按 Enter 直接退出/返回): " choice

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
                # 选项 7 的退出/返回逻辑
                if [ "$IS_NESTED_CALL" = "true" ]; then
                    # 总是显示详情，并检查其退出状态
                    if ! show_watchtower_details; then
                         echo -e "${COLOR_YELLOW}↩️ 返回上级菜单...${COLOR_RESET}"
                         return 0 # 如果 show_watchtower_details 失败，则返回上级菜单
                    fi
                    continue # 详情查看成功，继续循环
                else
                    # 主脚本直接调用，行为是显示详情，然后退出
                    show_watchtower_details
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


# --- 主执行函数 ---
main() {
    echo "" # 脚本启动最顶部加一个空行
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION${COLOR_RESET}"
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    echo "" # 脚本启动标题下方加一个空行

    main_menu
}

# --- 脚本的唯一入口点 ---
main
