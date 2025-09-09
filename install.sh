#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（无需 Last-Modified，智能 + 并行 + 后台更新）
# =============================================
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 用户运行"
    exit 1
fi

BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

GREEN="\033[32m"
RED="\033[31m"
NC="\033[0m"

CACHE_DIR="/opt/vps_install_modules"
mkdir -p "$CACHE_DIR"

MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

# 下载并缓存模块（不依赖 Last-Modified）
fetch_script() {
    local script_name="$1"
    local local_file="$CACHE_DIR/$script_name"
    local url="$BASE_URL/$script_name"

    echo -e "${GREEN}下载模块 $script_name${NC}"
    curl -fsSL "$url" -o "$local_file" || {
        echo -e "${RED}❌ 下载失败: $script_name${NC}"
        return 1
    }

    bash "$local_file"
}

# 并行更新所有模块
update_all_modules_parallel() {
    echo -e "${GREEN}🔄 并行更新所有模块缓存...${NC}"
    for module in "${MODULES[@]}"; do
        fetch_script "$module" &
    done
    wait
    echo -e "${GREEN}✅ 所有模块更新完成${NC}"
}

# 后台自动更新模块
background_update() {
    (
        for module in "${MODULES[@]}"; do
            fetch_script "$module" &
        done
        wait
        echo -e "${GREEN}✅ 背景模块更新完成${NC}"
    ) &
}

# 启动时后台更新
background_update

# 菜单循环
while true; do
    echo -e "${GREEN}==============================${NC}"
    echo -e "${GREEN}   VPS 一键安装入口脚本       ${NC}"
    echo -e "${GREEN}==============================${NC}"
    echo "请选择操作："
    echo "0. 退出"
    echo "1. Docker"
    echo "2. Nginx"
    echo "3. 常用工具"
    echo "4. 证书申请"
    echo "5. 更新所有模块缓存（并行）"

    read -p "输入数字: " choice

    case $choice in
    0) exit 0 ;;
    1) fetch_script "docker.sh" ;;
    2) fetch_script "nginx.sh" ;;
    3) fetch_script "tools.sh" ;;
    4) fetch_script "cert.sh" ;;
    5) update_all_modules_parallel ;;
    *) echo -e "${RED}❌ 无效选项，请重新选择${NC}" ;;
    esac

    echo -e "${GREEN}==============================${NC}\n"
done
