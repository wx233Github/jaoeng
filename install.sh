#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（终极版 - 彻底排版修正版）
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
YELLOW="\033[33m" # 添加黄色用于警告或提示
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
            echo -e "${RED}❌ 无法保存入口脚本。请检查网络连接或 GitHub 访问情况。${NC}" # 更具体的错误提示
            exit 1
        fi
    }
    chmod +x "$SCRIPT_PATH"
fi

# ====================== 快捷指令 jb ======================
BIN_DIR="/usr/local/bin"
mkdir -p "$BIN_DIR"

# 检查软链接是否存在，如果不存在则创建
if command -v ln >/dev/null 2>&1 && [ ! -L "$BIN_DIR/jb" ]; then
    ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"
    chmod +x "$SCRIPT_PATH" # 确保源脚本可执行
    echo -e "${GREEN}✅ 快捷指令 jb 已创建。您现在可以直接输入 'jb' 运行此脚本。${NC}"
elif command -v jb >/dev/null 2>&1; then
    # 如果 jb 命令已经存在（可能是软链接已存在），则不重复提示
    echo -e "${GREEN}✅ 快捷指令 jb 已存在。${NC}"
else
    # 如果软链接失败且 jb 命令不存在，使用 alias 临时模式
    alias jb="bash $SCRIPT_PATH"
    echo -e "${YELLOW}⚠ 快捷指令 jb 设置为临时 alias，仅当前终端会话有效。建议手动创建软链接：${NC}"
    echo -e "  ${YELLOW}sudo ln -sf $SCRIPT_PATH $BIN_DIR/jb${NC}"
fi

# ====================== 模块设置 ======================
MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

# 优化函数：用于下载模块到缓存目录
# 增加了 silent_mode 参数，控制是否打印进度信息
download_module_to_cache() {
    local script_name="$1"
    local silent_mode="${2:-false}" # 第二个参数，如果为 'true' 则静默，默认为 'false' (非静默)
    local local_file="$INSTALL_DIR/$script_name"
    local url="$BASE_URL/$script_name"

    if [ "$silent_mode" = "false" ]; then
        echo -e "${YELLOW}  - 正在缓存 $script_name ...${NC}"
    fi

    curl -fsSL "$url" -o "$local_file" || {
        if [ "$silent_mode" = "false" ]; then
            echo -e "${RED}  ❌ 缓存 $script_name 失败。${NC}"
        fi
        return 1 # 返回非零值表示失败
    }
    if [ "$silent_mode" = "false" ]; then
        echo -e "${GREEN}  ✅ $script_name 缓存成功。${NC}"
    fi
    return 0
}

# 优化函数：运行模块脚本，增加了下载失败的错误检查
run_script() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    echo -e "${GREEN}🚀 正在准备运行模块: ${script_name}${NC}"

    # 在运行前，确保模块文件存在并尝试下载 (这里是非静默下载，会显示进度)
    if [ ! -f "$local_file" ]; then
        echo -e "${YELLOW}模块 $script_name 未找到，尝试下载...${NC}"
        # 直接调用 download_module_to_cache，并确保其显示输出 (silent_mode='false')
        download_module_to_cache "$script_name" "false" || {
            echo -e "${RED}❌ 无法下载模块 $script_name。请检查网络连接或 GitHub 访问情况。${NC}"
            exit 1 # 如果下载失败，直接退出
        }
    fi

    # 确保下载的脚本可执行（尽管 bash 运行不需要，但这是一个好习惯）
    chmod +x "$local_file"

    echo -e "${GREEN}==== 运行 ${script_name} ====${NC}"
    bash "$local_file"
    echo -e "${GREEN}==== ${script_name} 运行完毕 ====${NC}"
}

# 优化函数：并行更新所有模块缓存
update_all_modules_parallel() {
    echo -e "${GREEN}⚡ 正在并行更新所有模块缓存，请稍候...${NC}"
    for module in "${MODULES[@]}"; do
        # 这里的调用是非静默的，会显示 download_module_to_cache 内部的进度信息
        download_module_to_cache "$module" "false" &
    done
    wait
    echo -e "${GREEN}✅ 所有模块缓存更新完成！${NC}"
}

# ====================== 后台静默缓存 ======================
# 增加用户反馈，告知后台正在进行缓存
echo -e "${YELLOW}💡 脚本正在后台静默缓存模块，不影响您的操作...${NC}"
(
    for module in "${MODULES[@]}"; do
        # 【关键修正】将 download_module_to_cache 以静默模式运行
        # 这样在后台运行时，它内部的进度消息将不会被打印。
        download_module_to_cache "$module" "true" & # 传入 'true' 启用静默模式
    done
    wait
    # 后台缓存完成后，打印最终的完成消息
    echo -e "${GREEN}✅ 初始模块后台缓存完成。${NC}"
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
    echo -e "${YELLOW}（注意：初次运行或模块缺失时，相关模块会自动下载）${NC}" # 提示自动下载

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
