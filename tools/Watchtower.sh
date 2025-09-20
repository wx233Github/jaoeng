#!/bin/bash
# 🚀 Docker 自动更新助手 (最终版)
# v1.5.0
# 功能：
# - 更新模式子菜单：Watchtower / Cron / 智能 Watchtower
# - Watchtower 支持秒 / 小时 / 天数输入
# - 通知功能（Telegram / Email）
# - 查看容器信息
# - 重新配置通知
# - 自定义时间/间隔

VERSION="1.5.0"
SCRIPT_NAME="docker_auto_update.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"

set -e

# 检查 Docker
if ! command -v docker &>/dev/null; then
    echo "❌ 未检测到 Docker，请先安装"
    exit 1
fi

# 🔹 配置向导
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "⚙️ 首次运行，进入配置向导..."
    read -p "是否启用 Telegram 通知？(y/n): " tg_choice
    if [[ "$tg_choice" == "y" || "$tg_choice" == "Y" ]]; then
        read -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
        read -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    fi

    read -p "是否启用 Email 通知？(y/n): " mail_choice
    if [[ "$mail_choice" == "y" || "$mail_choice" == "Y" ]]; then
        read -p "请输入接收通知的邮箱地址: " EMAIL_TO
    fi

    # 保存配置
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EMAIL_TO="$EMAIL_TO"
EOF
    echo "✅ 配置已保存到 $CONFIG_FILE"
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

# 🔹 查看容器信息
show_container_info() {
    echo "📋 Docker 容器信息："
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.CreatedAt}}\t{{.Status}}"
}

# 🔹 主菜单
echo "==========================================="
echo " Docker 自动更新助手 v$VERSION"
echo "==========================================="
echo "1) 更新模式"
echo "2) 查看容器信息"
echo "3) 重新配置通知"
echo "==========================================="
read -p "请输入选择 [1-3]: " MODE

case "$MODE" in
1)
    # 🔹 更新模式子菜单
    echo "请选择更新模式："
    echo "1) Watchtower模式"
    echo "2) Cron定时任务模式"
    echo "3) 智能 Watchtower模式"
    read -p "请输入选择 [1-3]: " UPDATE_MODE

    case "$UPDATE_MODE" in
    1)
        echo "🚀 Watchtower模式"
        echo "请输入检查更新间隔："
        echo "格式示例："
        echo "  300      → 300秒"
        echo "  2h       → 2小时"
        echo "  1d       → 1天"
        read -p "请输入更新间隔（默认300秒）: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300}

        # 转换为秒
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
        ;;
    3)
        echo "🤖 智能 Watchtower模式"
        echo "请输入检查更新间隔（可用秒/小时/天，例如 300 / 2h / 1d，默认300秒）: "
        read -p "请输入更新间隔: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-300}

        # 转换为秒
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
        else
            send_notify "✅ Watchtower 智能模式启动成功（尝试包含自身更新）"
        fi
        ;;
    *)
        echo "❌ 输入无效"
        ;;
    esac
    ;;
2)
    show_container_info
    ;;
3)
    echo "⚙️ 重新配置通知..."
    rm -f "$CONFIG_FILE"
    exec "$0"
    ;;
*)
    echo "❌ 输入无效"
    ;;
esac
