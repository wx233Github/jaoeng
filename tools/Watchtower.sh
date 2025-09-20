#!/bin/bash
# 🚀 Docker 自动更新助手
# v2.5.0 增加了手动更新 Docker Compose 项目和手动更新单个 Docker 容器的选项。
# 功能：
# - Watchtower / Cron / 智能 Watchtower更新模式
# - 支持秒/小时/天数输入
# - 通知配置菜单
# - 查看容器信息（中文化 + 镜像标签 + 应用版本 - 注意：应用版本获取具有局限性）
# - 设置成功提示中文化 + emoji
# - 任务管理 (停止Watchtower, 移除Cron任务)
# - 全面状态报告 (脚本启动时直接显示)
# - 脚本配置查看与编辑
# - 手动更新 Docker 项目 (单个容器/Compose)
# - 重新加载脚本

VERSION="2.5.0"
SCRIPT_NAME="docker_auto_update.sh"
CONFIG_FILE="/etc/docker-auto-update.conf" # 配置文件路径，需要root权限才能写入和读取

# --- 颜色定义 ---
COLOR_GREEN="\033[0;32m"
COLOR_RED="\033[0;31m"
COLOR_YELLOW="\033[0;33m"
COLOR_BLUE="\033[0;34m"
COLOR_RESET="\033[0m"

# 确保脚本以 root 权限运行，因为需要操作 Docker 和修改 crontab
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${COLOR_RED}❌ 脚本需要 Root 权限才能运行。请使用 'sudo ./$SCRIPT_NAME' 执行。${COLOR_RESET}"
    exit 1
fi

set -e # 任何命令失败都立即退出脚本

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
    DOCKER_COMPOSE_PROJECT_DIR_CRON="" # Cron模式下 Docker Compose 项目目录
    CRON_HOUR="" # Cron模式下的小时
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
DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_CRON"
CRON_HOUR="$CRON_HOUR"
EOF
    echo -e "${COLOR_GREEN}✅ 配置已保存到 $CONFIG_FILE${COLOR_RESET}"
}

# 🔹 通知配置菜单
configure_notify() {
    echo -e "${COLOR_YELLOW}⚙️ 通知配置${COLOR_RESET}"

    if confirm_action "是否启用 Telegram 通知？(当前: ${TG_BOT_TOKEN:+已设置} ${TG_BOT_TOKEN:-未设置})"; then
        read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN_NEW
        read -p "请输入 Telegram Chat ID: " TG_CHAT_ID_NEW
        TG_BOT_TOKEN="${TG_BOT_TOKEN_NEW:-$TG_BOT_TOKEN}" # 允许空输入保留原值
        TG_CHAT_ID="${TG_CHAT_ID_NEW:-$TG_CHAT_ID}"
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi

    if confirm_action "是否启用 Email 通知？(当前: ${EMAIL_TO:+已设置} ${EMAIL_TO:-未设置})"; then
        read -p "请输入接收通知的邮箱地址: " EMAIL_TO_NEW
        EMAIL_TO="${EMAIL_TO_NEW:-$EMAIL_TO}"
        if [ -n "$EMAIL_TO" ] && ! command -v mail &>/dev/null; then
            echo -e "${COLOR_YELLOW}⚠️ 'mail' 命令未找到。如果需要 Email 通知，请安装并配置邮件传输代理 (MTA)。${COLOR_RESET}"
            echo -e "   例如在 Ubuntu/Debian 上安装 'sudo apt install mailutils' 并配置 SSMTP。"
        fi
    else
        EMAIL_TO=""
    fi

    save_config
}

# 🔹 Watchtower 标签和额外参数配置
configure_watchtower_settings() {
    echo -e "${COLOR_YELLOW}⚙️ Watchtower 额外配置${COLOR_RESET}"
    read -p "是否为 Watchtower 配置标签筛选？(y/n) (例如：要更新带有 'com.centurylabs.watchtower.enable=true' 标签的容器，请输入 'com.centurylabs.watchtower.enable=true') (当前: ${WATCHTOWER_LABELS:-无}): " label_choice
    if [[ "$label_choice" == "y" || "$label_choice" == "Y" ]]; then
        read -p "请输入 Watchtower 筛选标签: " WATCHTOWER_LABELS_NEW
        WATCHTOWER_LABELS="${WATCHTOWER_LABELS_NEW:-$WATCHTOWER_LABELS}"
    else
        WATCHTOWER_LABELS=""
    fi

    read -p "是否为 Watchtower 配置额外启动参数？(y/n) (例如：--no-startup-message --notification-url=https://your.webhook.com/path) (当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
    if [[ "$extra_args_choice" == "y" || "$extra_args_choice" == "Y" ]]; then
        read -p "请输入 Watchtower 额外参数: " WATCHTOWER_EXTRA_ARGS_NEW
        WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-$WATCHTOWER_EXTRA_ARGS}"
    else
        WATCHTOWER_EXTRA_ARGS=""
    fi
    save_config
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
        # 尝试获取容器内部应用版本 (具有局限性，见前述说明)
        if docker exec "$name" sh -c "test -d /app" &>/dev/null; then
            local CONTAINER_APP_EXECUTABLE=$(docker exec "$name" sh -c "find /app -maxdepth 1 -type f -executable -print -quit" 2>/dev/null || true)
            if [ -n "$CONTAINER_APP_EXECUTABLE" ]; then
                local RAW_VERSION=$(docker exec "$name" sh -c "$CONTAINER_APP_EXECUTABLE --version 2>/dev/null || echo 'N/A'")
                APP_VERSION=$(echo "$RAW_VERSION" | head -n 1 | cut -c 1-15 | tr -d '\n')
            fi
        fi
        printf "%-20s %-45s %-25s %-15s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
    done
}

# 🔹 Watchtower 模式配置
configure_watchtower() {
    local MODE_NAME="$1" # "Watchtower模式" 或 "智能 Watchtower模式"
    local ENABLE_SELF_UPDATE="$2" # 是否启用自身更新 (true/false)

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
    
    # 允许用户在设置模式时修改标签和额外参数
    configure_watchtower_settings

    # 停止并删除旧的 Watchtower 容器 (忽略错误，因为可能不存在)
    set +e # 允许 docker rm 失败
    docker rm -f watchtower &>/dev/null || true
    set -e # 重新启用错误检查
        
    echo "⬇️ 正在拉取 Watchtower 镜像..."
    docker pull containrrr/watchtower || {
        echo -e "${COLOR_RED}❌ 无法拉取 containrrr/watchtower 镜像。请检查网络连接或 Docker Hub 状态。${COLOR_RESET}"
        send_notify "❌ Docker 自动更新助手：无法拉取 Watchtower 镜像。"
        exit 1
    }

    local WT_ARGS="--cleanup --interval $WT_INTERVAL --debug $WATCHTOWER_EXTRA_ARGS"
    if [ -n "$WATCHTOWER_LABELS" ]; then
        WT_ARGS="$WT_ARGS --label-enable $WATCHTOWER_LABELS"
        echo -e "${COLOR_YELLOW}ℹ️ Watchtower 将只更新带有标签 '$WATCHTOWER_LABELS' 的容器。${COLOR_RESET}"
    fi

    if [ "$ENABLE_SELF_UPDATE" = "true" ]; then
        echo "尝试启动 Watchtower 智能模式 (Watchtower 尝试更新自身)..."
        docker run -d \
          --name watchtower \
          --restart unless-stopped \
          -v /var/run/docker.sock:/var/run/docker.sock \
          containrrr/watchtower \
          $WT_ARGS \
          watchtower || local FALLBACK=1 # 如果失败，设置FALLBACK标记
        
        sleep 5 # 等待 Watchtower 容器启动
        if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$' || [ "$FALLBACK" = "1" ]; then
            echo -e "${COLOR_YELLOW}⚠️ Watchtower 智能模式启动失败或不稳定，回退到安全模式...${COLOR_RESET}"
            set +e # 允许 docker rm 失败
            docker rm -f watchtower &>/dev/null || true
            set -e # 重新启用错误检查

            docker run -d \
              --name watchtower \
              --restart unless-stopped \
              -v /var/run/docker.sock:/var/run/docker.sock \
              containrrr/watchtower \
              $WT_ARGS
            send_notify "⚠️ Docker 自动更新助手：Watchtower 智能模式失败，已回退到不更新自身模式。"
            echo -e "${COLOR_YELLOW}⚠️ Watchtower 智能模式回退完成！它将更新所有符合条件的容器，但不会尝试更新自身。${COLOR_RESET}"
        else
            send_notify "✅ Watchtower 智能模式启动成功（Watchtower 将尝试更新自身）"
            echo -e "${COLOR_GREEN}🎉 Watchtower 智能模式设置成功！它将自动监控并更新所有符合条件的容器，包括自身。${COLOR_RESET}"
        fi
    else
        echo "启动 Watchtower 模式..."
        docker run -d \
          --name watchtower \
          --restart unless-stopped \
          -v /var/run/docker.sock:/var/run/docker.sock \
          containrrr/watchtower \
          $WT_ARGS

        send_notify "✅ Watchtower 已启动，每 $WT_INTERVAL 秒检查更新。"
        echo -e "${COLOR_GREEN}🎉 Watchtower 设置成功！它将自动监控并更新除自身外的所有符合条件的容器。${COLOR_RESET}"
    fi
    echo "您可以使用选项2查看 Docker 容器信息。"
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
}


# 🔹 更新模式子菜单
update_menu() {
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
    echo "1) 🚀 Watchtower模式 (自动监控并更新所有运行中的容器镜像)"
    echo "2) 🕑 Cron定时任务模式 (通过 Docker Compose 定时拉取并重启指定项目)"
    echo "3) 🤖 智能 Watchtower模式 (Watchtower 尝试更新自身)"
    read -p "请输入选择 [1-3]: " MODE_CHOICE

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
        ;;
    esac
}

# 🔹 任务管理菜单
manage_tasks() {
    echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
    echo "1) 停止并移除 Watchtower 容器"
    echo "2) 移除 Cron 定时任务"
    read -p "请输入选择 [1-2]: " MANAGE_CHOICE

    case "$MANAGE_CHOICE" in
        1)
            if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                if confirm_action "您确定要停止并移除 Watchtower 容器吗？这将停止自动更新。"; then
                    set +e # 允许 docker rm 失败
                    docker stop watchtower &>/dev/null
                    docker rm watchtower &>/dev/null
                    set -e # 重新启用错误检查
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
            ;;
    esac
}

# 🔹 状态报告
show_status() {
    echo -e "\n${COLOR_YELLOW}📊 当前自动化更新状态报告：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"

    # Watchtower 状态
    echo -e "${COLOR_BLUE}--- Watchtower 状态 ---${COLOR_RESET}"
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_GREEN}✅ Watchtower 容器正在运行。${COLOR_RESET}"
        local wt_status=$(docker inspect watchtower --format "{{.State.Status}}")
        local wt_cmd_json=$(docker inspect watchtower --format "{{json .Config.Cmd}}") # 获取完整的Cmd数组

        local wt_interval="N/A"
        local wt_labels_from_cmd="无"
        local is_self_updating="否"
        
        # 使用 awk 从 JSON 数组中解析参数
        wt_interval=$(echo "$wt_cmd_json" | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /"--interval"/) {
                    val = $(i+1); gsub(/"/, "", val); gsub(/,/, "", val); print val; exit;
                }
            }
        }' FS=', *' | head -n 1)

        wt_labels_from_cmd=$(echo "$wt_cmd_json" | awk '{
            for (i=1; i<=NF; i++) {
                if ($i ~ /"--label-enable"/) {
                    val = $(i+1); gsub(/"/, "", val); gsub(/,/, "", val); print val; exit;
                }
            }
        }' FS=', *' | head -n 1)
        
        # 检查 "watchtower" 是否是最后一个参数，或者在参数中显式出现
        if echo "$wt_cmd_json" | grep -q '"watchtower"\]$' || echo "$wt_cmd_json" | grep -q '"watchtower",'; then
            is_self_updating="是"
        fi
        
        echo "  - 运行状态: $wt_status"
        echo "  - 检查间隔: ${wt_interval:-N/A} 秒"
        echo "  - 智能模式 (更新自身): $is_self_updating"
        echo "  - 标签筛选 (配置): ${WATCHTOWER_LABELS:-无}" # 从配置文件获取
        echo "  - 标签筛选 (运行): ${wt_labels_from_cmd:-无}" # 从运行参数解析
        echo "  - 额外参数 (配置): ${WATCHTOWER_EXTRA_ARGS:-无}" # 从配置文件获取
    elif docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_YELLOW}⚠️ Watchtower 容器已存在但未运行。${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}❌ 未检测到 Watchtower 容器。${COLOR_RESET}"
    fi

    # Cron 任务状态
    echo -e "${COLOR_BLUE}--- Cron 定时任务状态 ---${COLOR_RESET}"
    local CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
        echo -e "${COLOR_GREEN}✅ Cron 定时任务已配置。${COLOR_RESET}"
        local cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_UPDATE_SCRIPT")
        echo "  - 定时表达式: $(echo "$cron_entry" | cut -d ' ' -f 1-5)"
        echo "  - 每天更新时间 (配置): ${CRON_HOUR:-未设置} 点"
        echo "  - Docker Compose 项目目录 (配置): ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
        echo "  - 日志文件: /var/log/docker-auto-update-cron.log"
    else
        echo -e "${COLOR_RED}❌ 未检测到由本脚本配置的 Cron 定时任务。${COLOR_RESET}"
    fi
    echo "-------------------------------------------------------------------------------------------------------------------"
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
    echo "6) Cron 更新小时:      ${CRON_HOUR:-未设置}"
    echo "7) Cron Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    read -p "请输入要编辑的选项编号 (1-7) 或按 Enter 返回主菜单: " edit_choice

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
            ;;
        5)
            read -p "请输入新的 Watchtower 额外参数 (当前: ${WATCHTOWER_EXTRA_ARGS:-无}, 空输入取消额外参数): " WATCHTOWER_EXTRA_ARGS_NEW
            WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-}" # 允许空输入来清除
            save_config
            ;;
        6)
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
            echo -e "${COLOR_YELLOW}ℹ️ Cron 更新小时已修改，您可能需要重新配置 Cron 定时任务 (选项 1 -> 2) 以应用此更改。${COLOR_RESET}"
            ;;
        7)
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
            echo -e "${COLOR_YELLOW}ℹ️ Cron Docker Compose 项目目录已修改，您可能需要重新配置 Cron 定时任务 (选项 1 -> 2) 以应用此更改。${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_YELLOW}ℹ️ 返回主菜单。${COLOR_RESET}"
            ;;
    esac
}

# 🔹 手动更新 Docker Compose 项目
manual_update_compose_project() {
    echo -e "${COLOR_YELLOW}📱 手动更新 Docker Compose 项目${COLOR_RESET}"
    local project_dir_to_update=""

    while true; do
        read -p "请输入 Docker Compose 项目的完整目录路径 (例如 /opt/my_docker_project, 默认使用 Cron 配置的目录 ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}): " input_dir
        input_dir=${input_dir:-$DOCKER_COMPOSE_PROJECT_DIR_CRON} # 允许空输入使用默认值

        if [ -z "$input_dir" ]; then
            echo -e "${COLOR_RED}❌ Docker Compose 目录路径不能为空。${COLOR_RESET}"
        elif [ ! -d "$input_dir" ]; then
            echo -e "${COLOR_RED}❌ 指定的目录 '$input_dir' 不存在。请检查路径是否正确。${COLOR_RESET}"
        elif [ ! -f "$input_dir/docker-compose.yml" ] && [ ! -f "$input_dir/compose.yml" ]; then
            echo -e "${COLOR_RED}❌ 在目录 '$input_dir' 中未找到 docker-compose.yml 或 compose.yml 文件。${COLOR_RESET}"
        else
            project_dir_to_update="$input_dir"
            break
        fi
    done

    echo -e "${COLOR_BLUE}--- 正在更新项目: $project_dir_to_update ---${COLOR_RESET}"
    local DOCKER_COMPOSE_CMD=$(get_docker_compose_command_main)
    if [ -z "$DOCKER_COMPOSE_CMD" ]; then
        echo -e "${COLOR_RED}❌ 错误：未找到 'docker compose' 或 'docker-compose' 命令。${COLOR_RESET}"
        send_notify "❌ Docker 手动更新失败：未找到 Docker Compose 命令。"
        return 1
    fi

    if cd "$project_dir_to_update"; then
        echo "⬇️ 正在拉取最新镜像..."
        if "$DOCKER_COMPOSE_CMD" pull; then
            echo "🔄 正在重启容器..."
            if "$DOCKER_COMPOSE_CMD" up -d --remove-orphans; then
                echo -e "${COLOR_GREEN}✅ 项目 '$project_dir_to_update' 更新成功！${COLOR_RESET}"
                send_notify "✅ Docker 手动更新成功：项目 '$project_dir_to_update' 已更新。"
            else
                echo -e "${COLOR_RED}❌ 错误：启动容器失败。${COLOR_RESET}"
                send_notify "❌ Docker 手动更新失败：项目 '$project_dir_to_update' 启动容器失败。"
            fi
        else
            echo -e "${COLOR_RED}❌ 错误：拉取镜像失败。${COLOR_RESET}"
            send_notify "❌ Docker 手动更新失败：项目 '$project_dir_to_update' 拉取镜像失败。"
        fi
        cd - &>/dev/null # 返回到之前的目录
    else
        echo -e "${COLOR_RED}❌ 错误：无法切换到目录 '$project_dir_to_update'。${COLOR_RESET}"
        send_notify "❌ Docker 手动更新失败：无法访问目录 '$project_dir_to_update'。"
    fi
}

# 🔹 手动更新单个 Docker 容器
manual_update_single_container() {
    echo -e "${COLOR_YELLOW}📱 手动更新单个 Docker 容器${COLOR_RESET}"
    local container_name=""
    local image_name=""

    while true; do
        read -p "请输入要更新的容器名称: " container_name_input
        if [ -z "$container_name_input" ]; then
            echo -e "${COLOR_RED}❌ 容器名称不能为空。${COLOR_RESET}"
            return 1 # 返回上一级菜单
        fi
        if ! docker ps -a --format '{{.Names}}' | grep -q "^${container_name_input}$"; then
            echo -e "${COLOR_RED}❌ 容器 '$container_name_input' 不存在。请检查名称是否正确。${COLOR_RESET}"
        else
            container_name="$container_name_input"
            break
        fi
    done

    image_name=$(docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null)
    if [ -z "$image_name" ]; then
        echo -e "${COLOR_RED}❌ 无法获取容器 '$container_name' 的镜像名称。${COLOR_RESET}"
        send_notify "❌ Docker 单个容器更新失败：无法获取镜像名称。"
        return 1
    fi

    echo -e "${COLOR_BLUE}--- 正在更新容器 '$container_name' 使用的镜像 '$image_name' ---${COLOR_RESET}"
    echo "⬇️ 正在拉取最新镜像 '$image_name'..."
    if docker pull "$image_name"; then
        echo -e "${COLOR_GREEN}✅ 镜像 '$image_name' 已成功拉取最新版本。${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}⚠️ 注意：为使容器生效，您需要手动停止旧容器，删除，然后使用其原始的 'docker run' 命令重新启动新容器。${COLOR_RESET}"
        echo "   停止旧容器: docker stop $container_name"
        echo "   删除旧容器: docker rm $container_name"
        echo "   (然后使用您创建容器时的 'docker run ...' 命令重新启动)"
        send_notify "✅ Docker 单个容器镜像更新成功：镜像 '$image_name' 已更新。请手动重启容器 '$container_name'。"
    else
        echo -e "${COLOR_RED}❌ 错误：拉取镜像 '$image_name' 失败。${COLOR_RESET}"
        send_notify "❌ Docker 单个容器镜像更新失败：拉取镜像 '$image_name' 失败。"
    fi
}


# 🔹 手动更新主菜单
manual_update_menu() {
    echo -e "${COLOR_YELLOW}📱 请选择手动更新类型：${COLOR_RESET}"
    echo "1) 更新 Docker Compose 项目"
    echo "2) 更新单个 Docker 容器"
    read -p "请输入选择 [1-2]: " MANUAL_CHOICE

    case "$MANUAL_CHOICE" in
        1)
            manual_update_compose_project
            ;;
        2)
            manual_update_single_container
            ;;
        *)
            echo -e "${COLOR_RED}❌ 输入无效，请选择 1-2 之间的数字。${COLOR_RESET}"
            ;;
    esac
}


# --- 脚本主执行流程 ---

# 1. 显示脚本欢迎信息
echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION${COLOR_RESET}"
echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"

# 2. 直接显示当前自动化更新状态报告
show_status

# 3. 显示主菜单
echo -e "\n${COLOR_GREEN}===========================================${COLOR_RESET}"
echo "1) 🚀 设置/管理 Docker 更新模式"
echo "2) 📋 查看 Docker 容器信息"
echo "3) ⚙️ 配置通知方式 (Telegram/Email)"
echo "4) 🧹 管理更新任务 (停止Watchtower/移除Cron)"
echo "5) 📊 刷新并查看当前自动化更新状态"
echo "6) 📝 查看/编辑脚本配置"
echo "7) 📱 手动更新 Docker 项目 (单个容器/Compose)"
echo "8) 🔄 重新加载脚本 (当脚本自身更新时使用)"
echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
read -p "请输入选择 [1-8]: " MODE

case "$MODE" in
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
    # 选项5现在只是再次调用show_status，因为它已在启动时显示
    show_status
    ;;
6)
    view_and_edit_config
    ;;
7)
    manual_update_menu # 调用新的手动更新子菜单
    ;;
8)
    echo -e "${COLOR_YELLOW}🔄 正在重新加载脚本...${COLOR_RESET}"
    exec "$0" # 重新执行当前脚本，用于脚本自身更新后
    ;;
*)
    echo -e "${COLOR_RED}❌ 输入无效，请选择 1-8 之间的数字。${COLOR_RESET}"
    ;;
esac

echo -e "${COLOR_GREEN}✅ 操作完成。${COLOR_RESET}"
