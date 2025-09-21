#!/bin/bash
# =============================================
# 🚀 VPS GitHub 一键脚本拉取入口 (彻底修正版)
# =============================================

# --- 严格模式 ---
set -euo pipefail # -e: 任何命令失败立即退出, -u: 引用未设置变量时出错, -o pipefail: 管道中任何命令失败都将导致整个管道失败

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
log_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1" >&2
    exit 1
}

# --- 临时目录设置与清理 ---
TEMP_DIR="" # 声明全局变量

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_info "清理临时目录: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# 在脚本退出时执行 cleanup 函数
trap cleanup EXIT INT TERM

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 用户运行"
fi

# GitHub 仓库基础 URL
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

# 格式: "显示名:真实路径"
SCRIPTS=(
    "nginx_cf:tools/nginx_ch.sh"
    "Watchtower(docker 更新):tools/Watchtower.sh"
    "安装脚本:scripts/install.sh"
)

# 检查网络连通性
check_network() {
    log_info "正在检查网络连通性..."
    if command -v ping >/dev/null 2>&1; then
        if ! ping -c 1 -W 3 github.com >/dev/null 2>&1; then
            log_error "网络不通或无法访问 GitHub (ping github.com 失败)。请检查您的网络设置。"
        fi
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -Is --connect-timeout 5 https://github.com >/dev/null 2>&1; then
            log_error "网络不通或无法访问 GitHub (curl github.com 失败)。请检查您的网络设置。"
        fi
    else
        log_warning "无法找到 ping 或 curl 命令来检查网络，跳过网络连通性检查。"
    fi
    log_success "网络连通性正常。"
}

# 下载脚本
download() {
    local file=$1                 # GitHub路径，例如 rm/rm_cert.sh
    local url="$BASE_URL/$file"   # 完整URL
    local save_name=$(basename "$file")  # 本地保存名 rm_cert.sh
    local download_path="${TEMP_DIR}/${save_name}" # 下载到临时目录

    log_info "正在从 ${url} 下载到 ${download_path} ..."

    # 尝试下载，并捕获 stderr
    local download_output
    if command -v wget >/dev/null 2>&1; then
        download_output=$(wget -qO "$download_path" "$url" --show-progress 2>&1)
    elif command -v curl >/dev/null 2>&1; then
        download_output=$(curl -sSL -o "$download_path" "$url" --progress-bar 2>&1)
    else
        log_error "系统缺少 wget 或 curl"
    fi

    if [ $? -eq 0 ]; then
        chmod +x "$download_path"
        log_success "已保存为 $download_path 并设置为可执行"
    else
        log_error "下载 $save_name 失败。错误信息: ${download_output:-'未知错误'}"
    fi
}

# 主菜单
main_menu() {
    # 创建临时目录
    TEMP_DIR=$(mktemp -d -t vps_script_XXXXXX)
    if [ -z "$TEMP_DIR" ] || [ ! -d "$TEMP_DIR" ]; then
        log_error "创建临时目录失败"
    fi
    log_info "脚本将在临时目录 $TEMP_DIR 中运行"

    # 执行网络检查
    check_network

    while true; do
        echo ""
        echo -e "${BLUE}================================${NC}"
        echo -e "${BLUE}  🚀 VPS GitHub 一键脚本入口   ${NC}"
        echo -e "${BLUE}================================${NC}"
        echo -e " ${GREEN}0. 退出 ${NC}" # 退出选项也加绿
        i=1
        for entry in "${SCRIPTS[@]}"; do
            name="${entry%%:*}"   # 显示名
            echo -e " ${YELLOW}$i.${NC} $name"
            ((i++))
        done
        echo ""
        read -p "$(echo -e "${BLUE}请选择要执行的脚本 (0-${#SCRIPTS[@]}) 或直接回车退出:${NC} ")" choice

        # 判断是否为空 (直接回车)
        if [ -z "$choice" ]; then
            log_info "退出脚本"
            exit 0
        fi

        # 验证输入是否为数字
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log_warning "无效选项：请输入数字"
            continue
        fi

        # 处理选择
        if [ "$choice" -eq 0 ]; then
            log_info "退出脚本"
            exit 0
        elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCRIPTS[@]}" ]; then
            entry="${SCRIPTS[$((choice-1))]}"
            name="${entry%%:*}"   # 显示名
            file="${entry##*:}"   # GitHub路径
            script_file=$(basename "$file")   # 本地保存名
            local_script_path="${TEMP_DIR}/${script_file}" # 脚本在临时目录中的完整路径

            log_info "您选择了 [$name]"
            
            # 直接下载脚本到临时目录
            download "$file"
            
            log_success "执行 [$name]"
            
            # 切换到临时目录执行，确保脚本在预期环境中运行
            ( cd "$TEMP_DIR" && ./"$script_file" )
            
            # 检查子脚本的退出状态码
            if [ $? -ne 0 ]; then
                log_warning "脚本 [$name] 执行失败，请检查输出。"
                read -p "$(echo -e "${YELLOW}按回车键返回主菜单...${NC}")" # 暂停一下，让用户看错误
            else
                log_success "脚本 [$name] 执行完毕。"
                read -p "$(echo -e "${BLUE}按回车键返回主菜单...${NC}")"
            fi

        else
            log_warning "无效选项，请重新输入 (0-${#SCRIPTS[@]})"
        fi
        echo ""  # 换行美化
    done
}

# 启动菜单
main_menu
