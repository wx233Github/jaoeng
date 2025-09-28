#!/bin/bash
# =============================================
# 🚀 Docker 容器增强管理脚本（配置化 + 日志 + Watchtower）
# 功能：
# - 配置化参数支持
# - 自动检测 Docker 容器状态
# - 容器日志管理（归档、查看）
# - Watchtower 自动更新
# - 可扩展通知功能（控制台/邮件/Slack/Telegram）
# =============================================

set -e

# -----------------------------
# 读取配置文件（可自定义路径）
CONFIG_FILE="./docker_manager.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# -----------------------------
# 默认配置
LOG_DIR=${LOG_DIR:-"./logs"}
WATCHTOWER_INTERVAL=${WATCHTOWER_INTERVAL:-3600}
NOTIFY_ENABLED=${NOTIFY_ENABLED:-false}
TAIL_COUNT_DEFAULT=${TAIL_COUNT_DEFAULT:-100}

# 创建日志目录
mkdir -p "$LOG_DIR"

# -----------------------------
# 日志函数
log() {
    local msg="$1"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$ts] $msg"
}

# -----------------------------
# 通知函数（可扩展）
notify() {
    local msg="$1"
    if [ "$NOTIFY_ENABLED" = "true" ]; then
        # 目前仅控制台输出
        log "🔔 NOTIFY: $msg"
        # 可扩展：邮件/Slack/Telegram
        # send_mail "$ALERT_EMAIL" "$msg"
        # send_slack "$SLACK_WEBHOOK" "$msg"
    fi
}

# -----------------------------
# 容器状态检测
check_containers() {
    local containers
    containers=$(docker ps --format "{{.Names}}")
    if [ -z "$containers" ]; then
        log "❌ 没有运行中的容器"
        return
    fi
    for container in $containers; do
        local status
        status=$(docker inspect -f '{{.State.Status}}' "$container")
        log "容器: $container 状态: $status"
        if [ "$status" != "running" ]; then
            notify "容器 $container 停止运行！"
        fi
    done
}

# -----------------------------
# 容器日志查看/归档
manage_logs() {
    local container=$1
    local tail_count=${2:-$TAIL_COUNT_DEFAULT}
    local log_file="$LOG_DIR/${container}_$(date +%Y%m%d%H%M%S).log"

    # 导出日志
    docker logs --tail "$tail_count" "$container" &> "$log_file"
    log "📄 容器 $container 日志已保存到 $log_file"

    # 可选归档旧日志（保留最近 7 天）
    find "$LOG_DIR" -name "${container}_*.log" -mtime +7 -exec rm -f {} \;
}

# -----------------------------
# Watchtower 自动更新
start_watchtower() {
    if ! docker ps --format '{{.Names}}' | grep -q "watchtower"; then
        log "🚀 启动 Watchtower..."
        docker run -d \
            --name watchtower \
            -v /var/run/docker.sock:/var/run/docker.sock \
            containrrr/watchtower \
            --interval "$WATCHTOWER_INTERVAL" \
            --cleanup
        log "Watchtower 已启动，检查间隔 ${WATCHTOWER_INTERVAL}s"
    else
        log "Watchtower 已运行"
    fi
}

# -----------------------------
# 主菜单
show_menu() {
    echo "=================================="
    echo "🚀 Docker 管理菜单"
    echo "1. 查看容器状态"
    echo "2. 查看/导出容器日志"
    echo "3. 启动 Watchtower 自动更新"
    echo "4. 退出"
    echo "=================================="
    read -rp "请选择操作 (1-4): " choice
    case $choice in
        1)
            check_containers
            ;;
        2)
            read -rp "请输入容器名: " cname
            read -rp "请输入日志行数（默认 $TAIL_COUNT_DEFAULT）: " tcount
            manage_logs "$cname" "$tcount"
            ;;
        3)
            start_watchtower
            ;;
        4)
            exit 0
            ;;
        *)
            log "❌ 选项无效"
            ;;
    esac
}

# -----------------------------
# 循环显示菜单
while true; do
    show_menu
done
