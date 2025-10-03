#!/bin/bash
# =============================================================
# 🚀 Jaoeng Script Launcher (v1.0)
# =============================================================
set -eo pipefail
export LC_ALL=C.utf8

# --- 配置 (硬编码在启动器中，以实现独立) ---
INSTALL_DIR="/opt/vps_install_modules"
BIN_DIR="/usr/local/bin"
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
MAIN_SCRIPT_NAME="jb-main.sh" # 主程序的脚本名

# 简单的颜色定义
BLUE='\033[0;34m'; NC='\033[0m'; GREEN='\033[0;32m';
echo_info() { echo -e "${BLUE}[启动器]${NC} $1"; }
echo_success() { echo -e "${GREEN}[启动器]${NC} $1"; }
echo_error() { echo -e "\033[0;31m[启动器错误]\033[0m $1" >&2; exit 1; }

# --- 启动器主逻辑 ---
main() {
    local main_script_path="${INSTALL_DIR}/${MAIN_SCRIPT_NAME}"
    
    # --- 首次安装或 jb 命令执行 ---
    # 检查主程序是否存在，如果不存在或被强制刷新，则执行完整的安装/更新流程
    if [ ! -f "$main_script_path" ] || [[ "${FORCE_REFRESH}" == "true" ]]; then
        echo_info "正在执行首次安装或强制刷新..."
        
        # 确保 curl 存在
        if ! command -v curl &> /dev/null; then
            echo_error "curl 命令未找到，无法继续。请先安装 curl。"
        fi
        
        sudo mkdir -p "$INSTALL_DIR"
        
        # 1. 下载/更新启动器自身
        echo_info "正在安装/更新启动器..."
        local launcher_path="${INSTALL_DIR}/install.sh"
        if ! sudo curl -fsSL "${BASE_URL}/install.sh?_=$(date +%s)" -o "$launcher_path"; then
            echo_error "下载启动器失败，请检查网络连接。"
        fi
        sudo chmod +x "$launcher_path"
        
        # 2. 下载/更新主程序
        echo_info "正在下载/更新主程序..."
        if ! sudo curl -fsSL "${BASE_URL}/${MAIN_SCRIPT_NAME}?_=$(date +%s)" -o "$main_script_path"; then
            echo_error "下载主程序失败。"
        fi
        sudo chmod +x "$main_script_path"
        
        # 3. 下载/更新配置文件
        echo_info "正在下载/更新配置文件..."
        local config_path="${INSTALL_DIR}/config.json"
        if ! sudo curl -fsSL "${BASE_URL}/config.json?_=$(date +%s)" -o "$config_path"; then
            echo_error "下载配置文件失败。"
        fi
        
        # 4. 创建/更新快捷方式
        echo_info "正在创建/更新快捷指令 'jb'..."
        sudo ln -sf "$launcher_path" "${BIN_DIR}/jb"
        
        echo_success "安装/更新完成！"
    fi
    
    # --- 启动主程序 ---
    echo_info "正在启动主程序..."
    echo "--------------------------------------------------"
    
    # 使用 exec sudo -E 将控制权完全交接给磁盘上的主程序
    exec sudo -E bash "$main_script_path" "$@"
}

main "$@"
