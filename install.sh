#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（完全静默后台缓存 + 菜单 + jb 快捷指令提示）
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

# 自动创建快捷指令 jb 并显示提示
if [ ! -L /usr/local/bin/jb ]; then
    ln -sf "$0" /usr/local/bin/jb
    echo -e "${GREEN}✅ 快捷指令 jb 已创建${NC}"
    echo -e "${GREEN}   以后可直接输入 ${RED}jb${GREEN} 调用入口脚本${NC}"
fi

# 下载并缓存模块（完全静默）
cache_script() {
    local script_name="$1"
    local local_file="$CACHE_DIR/$script_name"
    local url="$BASE_URL/$script_name"

    curl -fsSL "$url" -o "$local_file" || return 1
}

# 执行模块（如果不存在就先下载）
run_script() {
    local script_name="$1"
    local local_file="$CACHE_DIR/$script_name"

    if [ ! -f "$local_file" ]; then
        cache_script "$script_name"
    fi

    bash "$local_file"
}

# 并行缓存所有模块（静默）
update_all_modules_parallel() {
    for module in "${MODULES[@]}"; do
        cache_script "$module" &
    done
    wait
}

# 启动时后台缓存（完全静默）
background_cache_update() {
    (
        for module in "${MODULES[@]}"; do
            cache_script "$module" &
        done
        wait
    ) &
}

# 启动时后台更新缓存
background_cache_update

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
    1) run_script "docker.sh" ;;
    2) run_script "nginx.sh" ;;
    3) run_script "tools.sh" ;;
    4) run_script "cert.sh" ;;
    5) update_all_modules_parallel ;;
    *) echo -e "${RED}❌ 无效选项，请重新选择${NC}" ;;
    esac

    echo -e "${GREEN}==============================${NC}\n"
done
