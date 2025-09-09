#!/bin/bash
# =============================================
# 🚀 VPS GitHub 一键脚本拉取入口
# =============================================

set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# GitHub 仓库基础 URL
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

# 格式: "显示名:真实文件名"
SCRIPTS=(
    "安装脚本:install.sh"
    "更新脚本:update.sh"
    "清理脚本:clean.sh"
    "卸载证书:/rm/rm_cert.sh"
)

# 下载函数（自动检测 wget 或 curl）
download() {
    local file=$1
    local url="$BASE_URL/$file"
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$file" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -sSL -o "$file" "$url"
    else
        echo "❌ 系统缺少 wget 或 curl"
        exit 1
    fi
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
            name="${entry%%:*}"   # 只显示新名字
            echo "$i. $name"
            ((i++))
        done
        read -p "请选择要执行的脚本 (0-${#SCRIPTS[@]}): " choice

        if [ "$choice" -eq 0 ]; then
            echo "👋 退出"
            exit 0
        elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCRIPTS[@]}" ]; then
            entry="${SCRIPTS[$((choice-1))]}"
            name="${entry%%:*}"
            file="${entry##*:}"

            echo "🔽 下载 $file..."
            download "$file"
            chmod +x "$file"
            echo "🚀 执行 [$name]"
            ./"$file"
        else
            echo "❌ 无效选项，请重新输入"
        fi
        echo ""  # 换行美化
    done
}

# 启动菜单
main_menu
