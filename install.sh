#!/bin/bash
# =============================================================
# 🚀 Jaoeng Script Launcher (v1.0)
# This script creates a perfect environment and launches the main program.
# =============================================================

set -eo pipefail
export LC_ALL=C.utf8

# --- 配置 ---
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
MAIN_SCRIPT_NAME="main.sh" # 主程序的脚本名
LOG_FILE="/var/log/jb_launcher.log"

# --- 辅助函数 ---
log_info() { echo -e "\033[0;34m[启动器]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[启动器错误]\033[0m $1" >&2; exit 1; }

# --- 引导程序主逻辑 ---
main() {
    log_info "正在初始化环境..."

    # 准备日志文件
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    sudo touch "$LOG_FILE"
    sudo chown "$(whoami)" "$LOG_FILE"

    # 创建一个安全的临时文件来存放主脚本
    local main_script_path
    main_script_path=$(mktemp)
    
    # 设置陷阱，确保在任何情况下退出时，临时文件都会被删除
    trap 'rm -f "$main_script_path"' EXIT

    # 下载主程序脚本，并强制绕过CDN缓存
    local main_script_url="${BASE_URL}/${MAIN_SCRIPT_NAME}?_=$(date +%s)"
    log_info "正在从 GitHub 下载主程序..."
    if ! curl -fsSL "$main_script_url" -o "$main_script_path"; then
        log_error "下载主程序失败，请检查网络连接。"
    fi
    
    # 传递所有接收到的参数 (例如，来自 jb 命令的参数)
    local all_args=("$@")

    # 魔法执行命令：
    # 1. script -q -c "..." /dev/null: 创建一个伪终端(pty)，完美保留颜色和格式。
    # 2. bash "$main_script_path" "${all_args[@]}": 在 pty 中，执行下载好的主脚本，并传递所有参数。
    # 3. | tee -a "$LOG_FILE": 将 pty 的所有输出同时打印到屏幕并追加到日志文件。
    log_info "启动主程序..."
    script -q -c "bash \"$main_script_path\" \"${all_args[@]}\"" /dev/null | tee -a "$LOG_FILE"
    
    # 获取 script 命令中 bash 进程的真实退出码，并以此作为启动器的退出码
    local exit_code="${PIPESTATUS[0]}"
    exit "$exit_code"
}

main "$@"
