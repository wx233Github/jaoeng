#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（智能更新 + 并行 + 自动后台更新）
# =============================================
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 用户运行"
    exit 1
fi

# GitHub 仓库 raw 地址
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

GREEN="\033[32m"
RED="\033[31m"
NC="\033[0m" # No Color

# 模块缓存目录
CACHE_DIR="/opt/vps_install_modules"
mkdir -p "$CACHE_DIR"

# 模块列表
MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

# 下载并缓存脚本函数，智能更新
fetch_script() {
    local script_name="$1"
    local local_file="$CACHE_DIR/$script_name"
    local meta_file="$CACHE_DIR/$script_name.meta"
    local url="$BASE_URL/$script_name"

    # 获取远程 Last-Modified 时间
    remote_time=$(curl -sI "$url" | grep -i '^Last-Modified:' | sed 's/Last-Modified: //I' | tr -d '\r')
    if [ -z "$remote_time" ]; then
        echo -e "${RED}❌ 无法获取远程更新时间: $url${NC}"
        return 1
    fi

    # 获取本地缓存的更新时间
    if [ -f "$meta_file" ]; then
        local_time=$(cat "$meta_file")
    else
        local_time=""
    fi

    # 判断是否需要更新
    if [ "$remote_time" != "$local_time" ] || [ ! -f "$local_file" ]; then
        echo -e "${GREEN}更新模块 $script_name${NC}"
        curl -fsSL "$url" -o "$local_file" || {
            echo -e "${RED}❌ 下载失败: $script_name${NC}"
            return 1
        }
        echo "$remote_time" > "$meta_file"
    else
        echo -e "${GREEN}使用缓存模块 $script_name${NC}"
    fi

    # 执行模块脚本
    bash "$local_file"
}

# 并行更新所有模块缓存
update_all_modules_parallel() {
    echo -e "${GREEN}🔄 并行更新所有模块缓存...${NC}"
    for module in "${MODULES[@]}"; do
        fetch_script "$module" &
    done
    wait
    echo -e "${GREEN}✅ 所有模块更新完成${NC}"
}

# 后台自动更新模块（启动时执行）
background_update() {
    (
        for module in "${MODULES[@]}"; do
            fetch_script "$module" &
        done
        wait
        echo -e "${GREEN}✅ 背景模块更新完成${NC}"
    ) &
}

# 启动时后台检查更新
background_update

# 菜单循环
while true; do
    echo -e "${GREEN}==============================${NC}"
    echo -e "${GREEN}   VPS 一键安装入口脚本       ${NC}"
    echo -e "${GREEN}==============================${NC}"
    echo "请选择要操作："
    echo "0. 退出"
    echo "1. Docker"
    echo "2. Nginx"
    echo "3. 常用工具"
    echo "4. 证书申请"
    echo "5. 更新所有模块缓存（并行）"

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
    5)
        update_all_modules_parallel
        ;;
    *)
        echo -e "${RED}❌ 无效选项，请重新选择${NC}"
        ;;
    esac

    echo -e "${GREEN}==============================${NC}"
    echo ""  # 空行分隔下一次选择
done
