#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（终极版）
# =============================================
set -e

# ====================== 检查 root ======================
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 用户运行"
    exit 1
fi

BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
GREEN="\033[32m"
RED="\033[31m"
NC="\033[0m"

# ====================== 安装路径 ======================
INSTALL_DIR="/opt/vps_install_modules"
mkdir -p "$INSTALL_DIR"

SCRIPT_PATH="$INSTALL_DIR/install.sh"

# ====================== 参数解析 ======================
SAVE_SELF=false
for arg in "$@"; do
    [[ "$arg" == "--save-self" ]] && SAVE_SELF=true
done

# ====================== 保存入口脚本 ======================
if [ ! -f "$SCRIPT_PATH" ] || [ "$SAVE_SELF" = true ]; then
    echo -e "${GREEN}⚡ 保存入口脚本到 $SCRIPT_PATH${NC}"
    # 先尝试从 GitHub 下载
    curl -fsSL "$BASE_URL/install.sh" -o "$SCRIPT_PATH" || {
        # 下载失败则尝试复制 stdin
        if [[ "$0" == /dev/fd/* ]]; then
            cp /proc/$$/fd/0 "$SCRIPT_PATH"
        else
            echo -e "${RED}❌ 无法保存入口脚本${NC}"
            exit 1
        fi
    }
    chmod +x "$SCRIPT_PATH"
fi

# ====================== 快捷指令 jb ======================
BIN_DIR="/usr/local/bin"
mkdir -p "$BIN_DIR"

if command -v ln >/dev/null 2>&1 && [ ! -L "$BIN_DIR/jb" ]; then
    ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"
    chmod +x "$SCRIPT_PATH"
    echo -e "${GREEN}✅ 快捷指令 jb 已创建${NC}"
elif ! command -v jb >/dev/null 2>&1; then
    # 如果软链接失败，使用 alias 临时模式
    alias jb="bash $SCRIPT_PATH"
    echo -e "${GREEN}⚠ 快捷指令 jb 设置为临时 alias，仅当前终端有效${NC}"
fi

# ====================== 模块设置 ======================
MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

cache_script() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    local url="$BASE_URL/$script_name"
    curl -fsSL "$url" -o "$local_file" || true
}

run_script() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    [ ! -f "$local_file" ] && cache_script "$script_name"
    bash "$local_file"
}

update_all_modules_parallel() {
    for module in "${MODULES[@]}"; do
        cache_script "$module" &
    done
    wait
}

# ====================== 后台静默缓存 ======================
(
    for module in "${MODULES[@]}"; do
        cache_script "$module" &
    done
    wait
) &

# ====================== 菜单循环 ======================
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
