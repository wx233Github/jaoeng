#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（安全稳定版）
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

# 固定安装路径
INSTALL_DIR="/opt/vps_install_modules"
mkdir -p "$INSTALL_DIR"

# 当前脚本路径
# 如果 $0 是 /dev/fd/*（bash <(curl …)），则保存自己到固定路径
if [[ "$0" == /dev/fd/* ]]; then
    SCRIPT_PATH="$INSTALL_DIR/install.sh"
    echo -e "${GREEN}⚡ 保存入口脚本到 $SCRIPT_PATH${NC}"
    # 保存标准输入内容到文件
    # 注意：bash <(curl …) 时 stdin 已经是进程替代，cat 可能会卡
    # 这里直接使用 curl 再下载一次入口脚本更安全
    curl -fsSL "$BASE_URL/install.sh" -o "$SCRIPT_PATH" || {
        echo -e "${RED}⚠ 无法从 GitHub 下载入口脚本，尝试使用当前输入保存${NC}"
        cat > "$SCRIPT_PATH"
    }
    chmod +x "$SCRIPT_PATH"
else
    SCRIPT_PATH="$0"
fi

MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

# 自动创建 jb 快捷指令
BIN_DIR="/usr/local/bin"
mkdir -p "$BIN_DIR"

if [ ! -L "$BIN_DIR/jb" ]; then
    ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"
    chmod +x "$SCRIPT_PATH"

    if echo "$PATH" | grep -q "$BIN_DIR"; then
        echo -e "${GREEN}✅ 快捷指令 jb 已创建，可直接输入 jb 调用入口脚本${NC}"
    else
        echo -e "${RED}⚠ PATH 未包含 $BIN_DIR，jb 可能无法立即使用${NC}"
        echo -e "${GREEN}   请运行: export PATH=\$PATH:$BIN_DIR 或重新打开终端${NC}"
    fi
fi

# 下载并缓存模块（静默）
cache_script() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    local url="$BASE_URL/$script_name"
    curl -fsSL "$url" -o "$local_file" || true
}

# 执行模块（不存在就先下载）
run_script() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    [ ! -f "$local_file" ] && cache_script "$script_name"
    bash "$local_file"
}

# 并行缓存所有模块（静默）
update_all_modules_parallel() {
    for module in "${MODULES[@]}"; do
        cache_script "$module" &
    done
    wait
}

# 启动时后台缓存（静默）
(
    for module in "${MODULES[@]}"; do
        cache_script "$module" &
    done
    wait
) &

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
