#!/bin/bash
# =============================================
# 🚀 VPS GitHub 一键脚本拉取入口 (最终修正版 v4)
# =============================================

# --- 严格模式 ---
set -euo pipefail # -e: 任何命令失败立即退出, -u: 引用未设置变量时出错, -o pipefail: 管道中任何命令失败都将导致整个管道失败

# --- 终极环境修复 ---
# 在父脚本的最高层级设置正确的区域环境，确保所有子进程都能继承。
# 这将从根本上解决所有中文显示和交互（如 read 回车）的问题。
export LC_ALL=C.utf8

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 辅助函数 ---
log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1" >&2; exit 1; }

# --- 临时目录设置与清理 ---
TEMP_DIR="" # 声明全局变量

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_info "清理临时目录: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# 在脚本退出时执行 cleanup 函数
trap cleanup EXIT INT TERM HUP

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
    if ! curl -Is --connect-timeout 5 https://raw.githubusercontent.com >/dev/null 2>&1; then
        log_error "网络不通或无法访问 GitHub (curl raw.githubusercontent.com 失败)。请检查您的网络设置。"
    fi
    log_success "网络连通性正常。"
}

# 下载脚本
download() {
    local file=$1                 # GitHub路径
    local url="$BASE_URL/$file"   # 完整URL
    local save_name=$(basename "$file")  # 本地保存名
    local download_path="${TEMP_DIR}/${save_name}" # 下载到临时目录

    log_info "正在从 ${url} 下载..."
    if curl -sSL -o "$download_path" "$url"; then
        chmod +x "$download_path"
        log_success "下载成功并设置为可执行: $download_path"
    else
        log_error "下载 $save_name 失败。"
    fi
}

# 主菜单
main_menu() {
    TEMP_DIR=$(mktemp -d -t vps_script_XXXXXX)
    log_info "脚本将在临时目录 $TEMP_DIR 中运行"
    check_network

    while true; do
        echo ""
        echo -e "${BLUE}================================${NC}"
        echo -e "${BLUE}  🚀 VPS GitHub 一键脚本入口   ${NC}"
        echo -e "${BLUE}================================${NC}"
        echo -e " ${GREEN}0. 退出 ${NC}"
        i=1
        for entry in "${SCRIPTS[@]}"; do
            name="${entry%%:*}"
            echo -e " ${YELLOW}$i.${NC} $name"
            ((i++))
        done
        echo ""
        
        # 使用 printf 来避免 echo 的潜在问题，并确保提示符颜色正确
        printf "%b" "${BLUE}请选择要执行的脚本 (0-${#SCRIPTS[@]}) 或直接回车退出:${NC} "
        read -r choice

        if [ -z "$choice" ]; then
            log_info "退出脚本"
            exit 0
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log_warning "无效选项：请输入数字"
            sleep 1
            continue
        fi

        if [ "$choice" -eq 0 ]; then
            log_info "退出脚本"
            exit 0
        elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCRIPTS[@]}" ]; then
            entry="${SCRIPTS[$((choice-1))]}"
            name="${entry%%:*}"
            file="${entry##*:}"
            script_file=$(basename "$file")
            local_script_path="${TEMP_DIR}/${script_file}"

            log_info "您选择了 [$name]"
            download "$file"
            
            # --- 执行下载的子脚本 ---
            # 修改了调用方式，避免 subshell 导致的 read 问题
            local child_script_exit_code=0
            if ! bash -c "cd '$TEMP_DIR' && IS_NESTED_CALL=true bash './$script_file'"; then
                child_script_exit_code=$?
            fi

            # --- 处理子脚本的退出状态 ---
            if [ "$child_script_exit_code" -eq 10 ]; then
                log_info "脚本 [$name] 已返回主菜单。"
            elif [ "$child_script_exit_code" -eq 0 ]; then
                log_success "脚本 [$name] 执行完毕。"
                read -r -p "$(echo -e "${BLUE}按回车键返回主菜单...${NC}")"
            else
                log_warning "脚本 [$name] 执行失败 (退出码: $child_script_exit_code)，请检查输出。"
                read -r -p "$(echo -e "${YELLOW}按回车键返回主菜单...${NC}")"
            fi
        else
            log_warning "无效选项，请重新输入 (0-${#SCRIPTS[@]})"
            sleep 1
        fi
        echo ""
    done
}

# 启动菜单
main_menu
