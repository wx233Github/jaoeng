#!/usr/bin/env bash
# =============================================
# 🚀 VPS GitHub 一键脚本拉取入口 (彻底修正版)
# =============================================

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"

log_info() { printf '%s\n' "$*"; }
log_warn() { printf '%s\n' "$*" >&2; }
log_err() { printf '%s\n' "$*" >&2; }

require_sudo_or_die() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            return 0
        fi
        if [ "${JB_NONINTERACTIVE}" = "true" ]; then
            log_err "非交互模式下无法获取 sudo 权限"
            exit 1
        fi
        return 0
    fi
    log_err "未安装 sudo，无法继续"
    exit 1
}

require_sudo_or_die

# GitHub 仓库基础 URL
BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"

# 格式: "显示名:真实路径"
SCRIPTS=(
    "安装脚本:scripts/install.sh"
    "更新脚本:scripts/update.sh"
    "清理脚本:scripts/clean.sh"
    "删除证书:rm/rm_cert.sh"
)

# 下载脚本（打印信息，不返回文件名）
download() {
    local file="$1"                 # GitHub路径，例如 rm/rm_cert.sh
    local url="$BASE_URL/$file"   # 完整URL
    local save_name
    save_name=$(basename "$file")  # 本地保存名 rm_cert.sh
    if [ -z "$save_name" ]; then
        log_err "保存文件名为空，拒绝下载"
        exit 1
    fi

    # 下载
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$save_name" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$save_name" "$url"
    else
        log_err "❌ 系统缺少 wget 或 curl"
        exit 1
    fi

    chmod +x "$save_name"
    log_info "📥 已保存为 $save_name"
}

# 主菜单
main_menu() {
    while true; do
        log_info "================================"
        log_info "  🚀 VPS GitHub 一键脚本入口"
        log_info "================================"
        log_info "0. 退出"
        i=1
        for entry in "${SCRIPTS[@]}"; do
            name="${entry%%:*}"   # 显示名
            log_info "$i. $name"
            ((i++))
        done
        if [ "${JB_NONINTERACTIVE}" = "true" ]; then
            log_warn "非交互模式：已退出"
            exit 0
        fi
        read -r -p "请选择要执行的脚本 (0-${#SCRIPTS[@]}，回车退出): " choice < /dev/tty

        if [ -z "$choice" ]; then
            log_info "👋 回车退出"
            exit 10
        elif ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            log_warn "❌ 请输入数字选项"
            continue
        elif [ "$choice" -eq 0 ]; then
            log_info "👋 退出"
            exit 0
        elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCRIPTS[@]}" ]; then
            entry="${SCRIPTS[$((choice-1))]}"
            name="${entry%%:*}"   # 显示名
            file="${entry##*:}"   # GitHub路径
            script_file=$(basename "$file")   # 本地文件名

            log_info "🔽 正在拉取 [$name] ..."
            download "$file"                   # 仅打印信息
            log_info "🚀 执行 [$name]"
            ./"$script_file"
        else
            log_warn "❌ 无效选项，请重新输入"
        fi
        log_info ""  # 换行美化
    done
}

# 启动菜单
main_menu
