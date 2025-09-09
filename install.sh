#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（循环菜单版）
# =============================================
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 用户运行"
    exit 1
fi

GREEN="\033[32m"
RED="\033[31m"
NC="\033[0m" # No Color

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
        bash docker.sh
        ;;
    2)
        bash nginx.sh
        ;;
    3)
        bash tools.sh
        ;;
    4)
        bash cert.sh
        ;;
    *)
        echo -e "${RED}❌ 无效选项，请重新选择${NC}"
        ;;
    esac

    echo -e "${GREEN}==============================${NC}"
    echo ""  # 空行分隔下一次选择
done
