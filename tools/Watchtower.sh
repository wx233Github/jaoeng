#!/bin/bash
# 🚀 Docker 自动更新助手
# v1.8.0
# 功能：
# - Watchtower / Cron / 智能 Watchtower更新模式
# - 支持秒/小时/天数输入
# - 通知配置菜单
# - 查看容器信息（中文化 + 镜像标签 + 应用版本）
# - 设置成功提示中文化 + emoji
# - 重新加载脚本

VERSION="1.8.0"
SCRIPT_NAME="docker_auto_update.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"

set -e

# 检查 Docker
if ! command -v docker &>/dev/null; then
    echo "❌ 未检测到 Docker，请先安装"
    exit 1
fi

# 🔹 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    EMAIL_TO=""
fi

# 🔹 通知函数
send_notify() {
    local MSG="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}&text=$(echo -e "$MSG")" >/dev/null
    fi
    if [ -n "$EMAIL_TO" ]; then
        echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO"
    fi
}

# 🔹 通知配置菜单
configure_notify() {
    echo "⚙️ 通知配置"
    read -p "是否启用 Telegram 通知？(y/n): " tg_choice
    if [[ "$tg_choice" == "y" || "$tg_choice" == "Y" ]]; then
        read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
        read -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi

    read -p "是否启用 Email 通知？(y/n): " mail_choice
    if [[ "$mail_choice" == "y" || "$mail_choice" == "Y" ]]; then
        read -p "请输入接收通知的邮箱地址: " EMAIL_TO
    else
        EMAIL_TO=""
    fi

    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EMAIL_TO="$EMAIL_TO"
EOF

    echo "✅ 通知配置已保存"
}

# 🔹 查看容器信息（中文化 + 镜像标签 + 内部应用版本）
show_container_info() {
    echo "📋 Docker 容器信息："
    printf "%-15s %-45s %-25s %-15s %-15s\n" "容器名称" "镜像" "创建时间" "状态" "应用版本"

    docker ps -a --format "{{.Names}} {{.Image}} {{.CreatedAt}} {{.Status}}" | while read name image created status; do
        APP_VERSION="N/A"
        # 尝试获取容器内部应用版本
        CONTAINER_APP_PATH=$(docker exec "$name" sh -c "ls /app 2>/dev/null | grep -i $(basename $image)" || true)
        if [ -n "$CONTAINER_APP_PATH" ]; then
            APP_VERSION=$(docker exec "$name" sh -c "/app/$CONTAINER_APP_PATH --version 2>/dev/null || echo 'N/A'")
        fi
        printf "%-15s %-45s %-25s %-15s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
    done
}

# 🔹 更新模式子菜单
update_menu() {
    echo "请选择更新模式："
    echo "1) Watchtower模式"
    echo "2) Cron定时任务模式"
    echo "3) 智能 Watchtower模式"
    read -p "请输入选择 [1-3]: " UPDATE_MODE

    case "$UPDATE_MODE" in
    1)
        echo "🚀 Watchtower模式"
        echo "请输入检查更新间隔（可用秒/小时/天，例如 300 / 2h / 1d，默认300秒）: "
        read -p "请输入更新间隔: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300}

        if [[ "$INTERVAL_INPUT" =~ ^[0-9]+$ ]]; then
            WT_INTERVAL=$INTERVAL_INPUT
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*3600))
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*86400))
        else
            echo "❌ 输入格式错误，已使用默认300秒"
            WT_INTERVAL=300
        fi

        echo "⏱ Watchtower检查间隔设置为 $WT_INTERVAL 秒"

        docker rm -f watchtower >/dev/null 2>&1 || true
        docker pull containrrr/watchtower

        docker run -d \
          --name watchtower \
          --restart unless-stopped \
          -v /var/run/docker.sock:/var/run/docker.sock \
          containrrr/watchtower \
          --cleanup \
          --interval $WT_INTERVAL

        send_notify "✅ Watchtower 已启动，每 $WT_INTERVAL 秒检查更新"
        echo "🎉 Watchtower 设置成功！可以使用选项2查看 Docker 容器信息。"
        ;;
    2)
        echo "🕑 Cron定时任务模式"
        read -p "请输入每天更新的小时 (0-23, 默认4): " CRON_HOUR
        CRON_HOUR=${CRON_HOUR:-4}

        UPDATE_SCRIPT="/usr/local/bin/docker-auto-update.sh"
        cat > $UPDATE_SCRIPT <<'EOF'
#!/bin/bash
docker compose pull >/dev/null 2>&1 || docker-compose pull >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1 || docker-compose up -d >/dev/null 2>&1
docker image prune -f >/dev/null 2>&1
EOF
        chmod +x $UPDATE_SCRIPT
        (crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" ; echo "0 $CRON_HOUR * * * $UPDATE_SCRIPT >> /var/log/docker-auto-update.log 2>&1") | crontab -

        send_notify "✅ Cron 定时任务配置完成，每天 $CRON_HOUR 点更新容器"
        echo "🎉 Cron 定时任务设置成功！可以使用选项2查看 Docker 容器信息。"
        ;;
    3)
        echo "🤖 智能 Watchtower模式"
        read -p "请输入检查更新间隔（可用秒/小时/天，例如 300 / 2h / 1d，默认300秒）: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300}

        if [[ "$INTERVAL_INPUT" =~ ^[0-9]+$ ]]; then
            WT_INTERVAL=$INTERVAL_INPUT
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*3600))
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*86400))
        else
            echo "❌ 输入格式错误，已使用默认300秒"
            WT_INTERVAL=300
        fi

        echo "⏱ Watchtower智能模式间隔设置为 $WT_INTERVAL 秒"

        docker rm -f watchtower >/dev/null 2>&1 || true
        docker pull containrrr/watchtower

        docker run -d \
          --name watchtower \
          --restart unless-stopped \
          -v /var/run/docker.sock:/var/run/docker.sock \
          containrrr/watchtower \
          --cleanup \
          --interval $WT_INTERVAL \
          watchtower || FALLBACK=1

        sleep 5
        if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
            echo "⚠️ Watchtower 智能模式启动失败，回退到安全模式..."
            docker rm -f watchtower >/dev/null 2>&1 || true
            docker run -d \
              --name watchtower \
              --restart unless-stopped \
              -v /var/run/docker.sock:/var/run/docker.sock \
              containrrr/watchtower \
              --cleanup \
              --interval $WT_INTERVAL
            send_notify "⚠️ Watchtower 智能模式失败，已回退到不更新自身模式"
            echo "⚠️ Watchtower 智能模式回退完成！"
        else
            send_notify "✅ Watchtower 智能模式启动成功（尝试包含自身更新）"
            echo "🎉 Watchtower 智能模式设置成功！可以使用选项2查看 Docker 容器信息。"
        fi
        ;;
    *)
        echo "❌ 输入无效"
        ;;
    esac
}

# 🔹 主菜单
echo "==========================================="
echo " Docker 自动更新助手 v$VERSION"
echo "==========================================="
echo "1) 更新模式"
echo "2) 查看容器信息"
echo "3) 通知配置
