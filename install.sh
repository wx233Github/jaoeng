#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（缓存+智能版本检测）
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

# 模块列表
MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

# 下载并缓存脚本函数，智能版本检测
fetch_script() {
    local script_name="$1"
    local script_base="${script_name%.sh}" # docker, nginx 等
    local local_file="$CACHE_DIR/$script_name"
    local version_file="$CACHE_DIR/$script_base.version"
    local remote_version_url="$BASE_URL/$script_base.version"

    # 获取远程版本号
    remote_version=$(curl -fsSL "$remote_version_url" || echo "")
    if [ -z "$remote_version" ]; then
        echo -e "${RED}❌ 无法获取远程版本: $remote_version_url${NC}"
        return 1
    fi

    # 获取本地版本号
    if [ -f "$version_file" ]; then
        local_version=$(cat "$version_file")
    else
        local_version=""
    fi

    # 判断是否需要更新
    if [ "$remote_version" != "$local_version" ]; then
        echo -e "${GREEN}更新模块 $script_name (版本 $local_version → $remote_version)${NC}"
        curl -fsSL "$BASE_URL/$script_name" -o "$local_file" || {
            echo -e "${RED}❌ 下载失败: $script_name${NC}"
            return 1
        }
        echo "$remote_version" > "$version_file"
    else
        echo -e "${GREEN}使用缓存模块 $script_name (版本 $local_version)${NC}"
    fi

    # 执行模块脚本
    bash "$local_file"
}

# 更新所有模块缓存
update_all_modules() {
    echo -e "${GREEN}🔄 正在更新所有模块缓存...${NC}"
    for module in "${MODULES[@]}"; do
        fetch_script "$module"
    done
    echo -e "${GREEN}✅ 模块更新完成${NC}"
}

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
    echo "5. 更新所有模块缓存"

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
        update_all_modules
        ;;
    *)
        echo -e "${RED}❌ 无效选项，请重新选择${NC}"
        ;;
    esac

    echo -e "${GREEN}==============================${NC}"
    echo ""  # 空行分隔下一次选择
done
