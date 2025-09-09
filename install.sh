#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（在线模块缓存版）
# =============================================
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 用户运行"
    exit 1
fi

# GitHub 仓库地址（替换成你自己的）
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

GREEN="\033[32m"
RED="\033[31m"
NC="\033[0m" # No Color

# 模块缓存目录
CACHE_DIR="/opt/vps_install_modules"
mkdir -p "$CACHE_DIR"

# 下载并缓存脚本函数
fetch_script() {
    local script_name="$1"
    local script_url="$BASE_URL/$script_name"
    local local_file="$CACHE_DIR/$script_name"

    # 检查是否已缓存
    if [ ! -f "$local_file" ]; then
        echo -e "${GREEN}首次下载模块: $script_name${NC}"
        curl -fsSL "$script_url" -o "$local_file" || {
            echo -e "${RED}❌ 下载失败: $script_url${NC}"
            return 1
        }
    else
        echo -e "${GREEN}使用缓存模块: $script_name${NC}"
    fi

    # 执行模块脚本
    bash "$local_file"
}

while true; do
    echo -e "${GREEN}==============================${NC}"
    echo -e "${GREEN}   VPS 一键安装入口脚本       ${NC}"
    echo -e "${GREEN}==============================${NC}"
    echo "请选择要安装的内容："
    echo "0. 退出"
    echo "1. Docker"
    echo "2. Nginx"
    echo "3. 常用工具"
    echo "4. 证书申请"

    read -p "输入数字: " choice

    case $choice in
    0)
        echo -e "${GREEN}退出脚本${NC}"
        exit 0
        ;;
    1)
        fetch_script "docker.sh"
        ;;
    2)
        fetch_script "nginx.sh"
        ;;
    3)
        fetch_script "tools.sh"
        ;;
    4)
        fetch_script "cert.sh"
        ;;
    *)
        echo -e "${RED}❌ 无效选项，请重新选择${NC}"
        ;;
    esac

    echo -e "${GREEN}==============================${NC}"
    echo ""  # 空行分隔下一次选择
done
