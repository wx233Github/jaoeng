#!/bin/bash
# =============================================
# 🚀 VPS 一键安装入口脚本（终极版 - 纯静默后台缓存版）
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

# ====================== 保存入口脚本 (确保本地有脚本可供更新或首次运行) ======================
# 如果脚本文件不存在，或者指定了 --save-self 参数，则保存脚本
if [ ! -f "$SCRIPT_PATH" ] || [ "$SAVE_SELF" = true ]; then
    echo -e "${GREEN}⚡ 保存入口脚本到 $SCRIPT_PATH${NC}"
    # 先尝试从 GitHub 下载
    curl -fsSL "$BASE_URL/install.sh" -o "$SCRIPT_PATH" || {
        # 下载失败则尝试复制当前运行的脚本内容
        if [[ "$0" == /dev/fd/* ]]; then
            # 如果是进程替换方式运行 (e.g., bash <(curl ...))，直接复制 $0
            cp "$0" "$SCRIPT_PATH"
        elif [ -f "$0" ]; then
            # 如果是本地文件方式运行 (e.g., bash ./install.sh)，复制 $0
            cp "$0" "$SCRIPT_PATH"
        else
            # 无法识别运行方式或获取脚本内容
            echo -e "${RED}❌ 无法保存入口脚本。请检查网络连接或 GitHub 访问情况，或尝试直接下载。${NC}"
            exit 1
        fi
    }
    chmod +x "$SCRIPT_PATH"
fi

# ====================== 快捷指令 jb ======================
BIN_DIR="/usr/local/bin"
mkdir -p "$BIN_DIR"

JB_LINK_STATUS=""
if command -v ln >/dev/null 2>&1 && [ ! -L "$BIN_DIR/jb" ]; then
    ln -sf "$SCRIPT_PATH" "$BIN_DIR/jb"
    chmod +x "$SCRIPT_PATH" # 确保源脚本可执行
    JB_LINK_STATUS="${YELLOW}✅ 快捷指令：jb 已创建。您现在可以直接输入 'jb' 运行此脚本。${NC}"
elif command -v jb >/dev/null 2>&1; then
    # 如果 jb 命令已经存在（可能是软链接已存在），则不重复创建
    JB_LINK_STATUS="${YELLOW}✅ 快捷指令：jb${NC}" # <-- 修改点 1
else
    # 如果软链接失败且 jb 命令不存在，使用 alias 临时模式
    alias jb="bash $SCRIPT_PATH"
    JB_LINK_STATUS="${YELLOW}⚠ 快捷指令 jb 设置为临时 alias，仅当前终端会话有效。建议手动创建软链接：sudo ln -sf $SCRIPT_PATH $BIN_DIR/jb${NC}"
fi
# 在这里打印快捷指令状态，确保在菜单之前显示
echo -e "$JB_LINK_STATUS"

# ====================== 自动更新脚本自身 ======================
# 如果是 --save-self 模式，我们已经处理了更新，不需要再自动检查
if [ "$SAVE_SELF" = true ]; then
    echo -e "${GREEN}跳过自动更新检查 (已手动更新脚本)。${NC}"
else
    # echo -e "${YELLOW}🔍 检查脚本更新...${NC}" # <-- 修改点 2 (已注释或移除)
    TEMP_REMOTE_SCRIPT="/tmp/$(basename "$SCRIPT_PATH").tmp" # 使用 SCRIPT_PATH 的文件名作为临时文件

    # 尝试静默下载远程脚本
    if curl -fsSL "$BASE_URL/install.sh" -o "$TEMP_REMOTE_SCRIPT" &>/dev/null; then
        # 比较本地脚本内容与下载的远程脚本内容
        # cmp -s 命令用于比较两个文件，如果相同则返回0，不同则返回非0
        if ! cmp -s "$SCRIPT_PATH" "$TEMP_REMOTE_SCRIPT"; then
            echo -e "${GREEN}✨ 检测到新版本，正在自动更新脚本...${NC}"
            # 覆盖本地脚本 (需要 sudo 权限，因为路径在 /opt 下)
            if sudo mv "$TEMP_REMOTE_SCRIPT" "$SCRIPT_PATH" && sudo chmod +x "$SCRIPT_PATH"; then
                echo -e "${GREEN}✅ 脚本已更新。正在重新启动以应用更新...${NC}"
                # 重新执行更新后的脚本。这非常关键，确保当前会话运行的是最新版本。
                # `exec` 命令会用新进程替换当前 shell 进程，并传递所有原始参数。
                exec bash "$SCRIPT_PATH" "$@"
                # 脚本会在这里退出，新版本将接管执行。
            else
                echo -e "${RED}❌ 自动更新脚本失败！请检查权限或网络连接。${NC}"
            fi
        else
            echo -e "${GREEN}✅ 脚本已经是最新版本${NC}" # <-- 修改点 3
        fi
        rm -f "$TEMP_REMOTE_SCRIPT" # 清理临时文件
    else
        echo -e "${YELLOW}⚠️ 无法连接到 GitHub 检查脚本更新（网络问题或防火墙），将使用当前版本运行。${NC}"
        rm -f "$TEMP_REMOTE_SCRIPT" # 如果下载失败，也尝试清理临时文件
    fi
fi
# ==========================================================

# ====================== 模块设置 ======================
MODULES=("docker.sh" "nginx.sh" "tools.sh" "cert.sh")

# 优化函数：用于下载模块到缓存目录 (完全静默，不输出任何进度信息)
download_module_to_cache() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    local url="$BASE_URL/$script_name"

    # curl 失败则返回非零值
    curl -fsSL "$url" -o "$local_file" &>/dev/null # 使用 &>/dev/null 确保所有输出都被重定向，完全静默
}

# 优化函数：运行模块脚本 (移除了下载成功的提示，保留了下载失败的致命错误提示)
run_script() {
    local script_name="$1"
    local local_file="$INSTALL_DIR/$script_name"
    echo -e "${GREEN}🚀 正在准备运行模块: ${script_name}${NC}"

    if [ ! -f "$local_file" ]; then
        # 尝试静默下载模块
        # 注意：此处如果 download_module_to_cache 失败，会返回非零值，触发 if 语句的错误处理
        if ! download_module_to_cache "$script_name"; then
            echo -e "${RED}❌ 无法下载模块 $script_name。请检查网络连接或 GitHub 访问情况。${NC}"
            exit 1 # 如果下载失败，直接退出
        fi
    fi

    chmod +x "$local_file"

    echo -e "${GREEN}==== 运行 ${script_name} ====${NC}"
    bash "$local_file"
    echo -e "${GREEN}==== ${script_name} 运行完毕 ====${NC}"
}

# 优化函数：并行更新所有模块缓存 (只保留整体的开始和结束提示)
update_all_modules_parallel() {
    echo -e "${GREEN}⚡ 正在并行更新所有模块缓存，请稍候...${NC}"
    for module in "${MODULES[@]}"; do
        download_module_to_cache "$module" & # 完全静默下载
    done
    wait
    echo -e "${GREEN}✅ 所有模块缓存更新完成！${NC}"
}

# ====================== 后台静默缓存 ======================
# 后台静默缓存。完全不产生任何输出。
# 将整个后台缓存操作的输出重定向到 /dev/null，并再次放入后台
(
    for module in "${MODULES[@]}"; do
        download_module_to_cache "$module" &
    done
    wait
) &>/dev/null &

# ====================== 菜单循环 ======================
while true; do
    echo -e "${GREEN}==============================${NC}"
    echo -e "${GREEN}   VPS 一键安装入口脚本       ${NC}"
    echo -e "${GREEN}==============================${NC}"
    echo "请选择操作："
    echo "0. 退出"
    echo "1. Docker"
    echo "2. Nginx"
    echo "3. 常 用 工 具"
    echo "4. 证 书 申 请"
    echo "5. 更 新 所 有 模 块 缓 存 （ 并 行 ）"

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
