#!/bin/bash
# =========================================
# 🚀 Docker 自动更新助手 (含 Watchtower 详情页)
# =========================================

set -euo pipefail

# -----------------------------
# 彩色
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_RESET="\033[0m"

# -----------------------------
# 全局变量
WATCHTOWER_CONTAINER="watchtower"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_INTERVAL:-86400}"  # 默认 24h

# -----------------------------
# 工具函数
press_enter_to_continue() {
    echo
    read -rp "👉 按回车返回主菜单..." _
}

_get_watchtower_all_raw_logs() {
    docker logs "$WATCHTOWER_CONTAINER" 2>&1 || true
}

_get_watchtower_remaining_time() {
    local interval="$1"
    local raw_logs="$2"

    local last_done_log last_done_time last_done_ts now_ts remain
    last_done_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
    if [ -z "$last_done_log" ]; then
        echo -e "${COLOR_YELLOW}未知（尚未完成过扫描）${COLOR_RESET}"
        return
    fi
    last_done_time=$(echo "$last_done_log" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$last_done_time" ]; then
        echo -e "${COLOR_YELLOW}未知${COLOR_RESET}"
        return
    fi

    last_done_ts=$(date -d "$last_done_time" +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    remain=$(( interval - (now_ts - last_done_ts) ))
    if [ "$remain" -le 0 ]; then
        echo -e "${COLOR_GREEN}即将开始${COLOR_RESET}"
    else
        local h=$((remain/3600))
        local m=$(( (remain%3600)/60 ))
        local s=$((remain%60))
        echo -e "${COLOR_GREEN}${h}h ${m}m ${s}s${COLOR_RESET}"
    fi
}

# -----------------------------
# Watchtower 详情页
show_watchtower_details() {
    echo -e "${COLOR_BLUE}--- 📊 Watchtower 详情 ---${COLOR_RESET}"

    if ! docker ps --format '{{.Names}}' | grep -q "^${WATCHTOWER_CONTAINER}$"; then
        echo -e "${COLOR_RED}❌ Watchtower 未在运行${COLOR_RESET}"
        press_enter_to_continue
        return
    fi

    local wt_interval_running="$WATCHTOWER_CONFIG_INTERVAL"
    echo -e "  - 配置的更新间隔: ${COLOR_GREEN}${wt_interval_running}s${COLOR_RESET}"

    local raw_logs=$(_get_watchtower_all_raw_logs)

    local last_done_log last_done_time
    last_done_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
    if [ -n "$last_done_log" ]; then
        last_done_time=$(echo "$last_done_log" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1)
        echo -e "  - 最近完成扫描时间: ${COLOR_GREEN}${last_done_time:-N/A}${COLOR_RESET}"
    else
        echo -e "  - 最近完成扫描时间: ${COLOR_YELLOW}尚未完成过扫描${COLOR_RESET}"
    fi

    echo -n "  - 下次扫描倒计时: "
    _get_watchtower_remaining_time "$wt_interval_running" "$raw_logs"

    echo -e "\n${COLOR_YELLOW}📋 最近 10 条日志:${COLOR_RESET}"
    echo "$raw_logs" | tail -n 10 | sed "s/^/    /"

    press_enter_to_continue
}

# -----------------------------
# 容器状态展示
show_status() {
    echo -e "${COLOR_BLUE}--- 📦 Docker 容器状态 ---${COLOR_RESET}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" || true
    echo
    echo -e "${COLOR_BLUE}--- 🛠 Watchtower 状态 ---${COLOR_RESET}"

    if docker ps --format '{{.Names}}' | grep -q "^${WATCHTOWER_CONTAINER}$"; then
        echo -e "  - Watchtower 服务: ${COLOR_GREEN}运行中${COLOR_RESET}"
    else
        echo -e "  - Watchtower 服务: ${COLOR_RED}未运行${COLOR_RESET}"
    fi
    press_enter_to_continue
}

# -----------------------------
# 主菜单
main_menu() {
    clear
    echo -e "${COLOR_BLUE}=== 🚀 Docker 自动更新助手 ===${COLOR_RESET}"
    echo "1) 查看容器状态"
    echo "2) 手动触发 Watchtower 更新"
    echo "3) 启动 Watchtower"
    echo "4) 停止 Watchtower"
    echo "5) 重启 Watchtower"
    echo "6) 查看 Watchtower 日志"
    echo "7) Watchtower 详情页"
    echo "0) 退出"
    echo
    read -rp "请选择操作: " choice
    case "$choice" in
        1) show_status ;;
        2) docker exec "$WATCHTOWER_CONTAINER" watchtower --run-once; press_enter_to_continue ;;
        3) docker start "$WATCHTOWER_CONTAINER"; press_enter_to_continue ;;
        4) docker stop "$WATCHTOWER_CONTAINER"; press_enter_to_continue ;;
        5) docker restart "$WATCHTOWER_CONTAINER"; press_enter_to_continue ;;
        6) docker logs --tail 50 -f "$WATCHTOWER_CONTAINER" ;;
        7) show_watchtower_details ;;
        0) exit 0 ;;
        *) echo -e "${COLOR_RED}无效选项${COLOR_RESET}"; sleep 1 ;;
    esac
}

# -----------------------------
# 循环
while true; do
    main_menu
done
