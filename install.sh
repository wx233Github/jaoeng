#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 用户运行"
    exit 1
fi

echo "请选择要安装的内容："
echo "1) Docker"
echo "2) Nginx"
echo "3) 常用工具"
echo "4) 证书申请"
read -p "输入数字: " choice

case $choice in
1)
    bash install_docker.sh
    ;;
2)
    bash install_nginx.sh
    ;;
3)
    bash install_tools.sh
    ;;
4）
    bash install_cert.sh
    ;;
*)
    echo "❌ 无效选项"
    ;;
esac
