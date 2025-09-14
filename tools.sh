#!/bin/bash
# =============================================
# 🚀 VPS GitHub 一键脚本拉取入口 (彻底修正版)
# =============================================

set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# GitHub 仓库基础 URL
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

# 格式: "显示名:真实路径"
SCRIPTS=(
    "nginx_cf:tools/nginx_ch.sh"
    "安装脚本:scripts/install.sh"
    
)

# 下载脚本（打印信息，不返回文件名）
download() {
    local file=$1                 # GitHub路径，例如 rm/rm_cert.sh
    local url="$BASE_URL/$file"   # 完整URL
    local save_name=$(basename "$file")  # 本地保存名 rm_cert.sh

    # 下载
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$save_name" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -sSL -o "$save_name" "$url"
    else
        echo "❌ 系统缺少 wget 或 curl"
        exit 1
    fi

    chmod +x "$save_name"
    echo "📥 已保存为 $save_name"
}

# 主菜单
main_menu() {
    while true; do
        echo "================================"
        echo "  🚀 VPS GitHub 一键脚本入口"
        echo "================================"
        echo "0. 退出"
        i=1
        for entry in "${SCRIPTS[@]}"; do
            name="${entry%%:*}"   # 显示名
            echo "$i. $name"
            ((i++))
        done
        read -p "请选择要执行的脚本 (0-${#SCRIPTS[@]}): " choice

        if [ "$choice" -eq 0 ]; then
            echo "👋 退出"
            exit 0
        elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCRIPTS[@]}" ]; then
            entry="${SCRIPTS[$((choice-1))]}"
            name="${entry%%:*}"   # 显示名
            file="${entry##*:}"   # GitHub路径
            script_file=$(basename "$file")   # 本地文件名

            echo "🔽 正在拉取 [$name] ..."
            download "$file"                   # 仅打印信息
            echo "🚀 执行 [$name]"
            ./"$script_file"
        else
            echo "❌ 无效选项，请重新输入"
        fi
        echo ""  # 换行美化
    done
}

# 启动菜单
main_menu
