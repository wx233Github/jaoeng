#!/usr/bin/env bash
# 🚀 安全版交互式卸载 SSL 脚本（可备份证书）

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"

log_info() { printf '%s\n' "$*"; }
log_warn() { printf '%s\n' "$*" >&2; }
log_err() { printf '%s\n' "$*" >&2; }

ensure_safe_path() {
    local target="$1"
    if [ -z "${target}" ] || [ "${target}" = "/" ]; then
        log_err "拒绝对危险路径执行破坏性操作: '${target}'"
        exit 1
    fi
}

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

log_info "=============================="
log_info "⚠️  开始卸载 SSL 脚本相关内容"
log_info "=============================="

# 1️⃣ 删除 acme.sh
if [ -d "$HOME/.acme.sh" ]; then
    log_info "🔹 删除 acme.sh 目录..."
    ensure_safe_path "$HOME/.acme.sh"
    rm -rf "$HOME/.acme.sh"
else
    log_info "ℹ️ acme.sh 目录不存在，跳过"
fi

# 2️⃣ 删除脚本文件
SCRIPT_PATH="/opt/vps_install_modules/cert.sh"
if [ -f "$SCRIPT_PATH" ]; then
    log_info "🔹 删除脚本文件 $SCRIPT_PATH ..."
    ensure_safe_path "$SCRIPT_PATH"
    rm -f "$SCRIPT_PATH"
else
    log_info "ℹ️ 脚本文件不存在，跳过"
fi

# 3️⃣ 交互式输入要删除的域名证书目录
DOMAINS=()
if [ "${JB_NONINTERACTIVE}" = "true" ]; then
    log_warn "非交互模式：跳过证书删除步骤"
    DOMAINS=()
else
    while true; do
        read -r -p "请输入要卸载证书的域名（回车结束输入）: " DOMAIN < /dev/tty
        if [[ -z "$DOMAIN" ]]; then
            break
        fi
        DOMAINS+=("$DOMAIN")
    done
fi

if [ ${#DOMAINS[@]} -eq 0 ]; then
    log_info "ℹ️ 未输入任何域名，跳过证书删除步骤。"
else
    BACKUP_ROOT="/root/ssl_backup"
    mkdir -p "$BACKUP_ROOT"

    for DOMAIN in "${DOMAINS[@]}"; do
        CERT_DIR="/etc/ssl/$DOMAIN"
        if [ -d "$CERT_DIR" ]; then
            if [ "${JB_NONINTERACTIVE}" = "true" ]; then
                BACKUP=""
            else
                read -r -p "是否备份 $DOMAIN 证书到 $BACKUP_ROOT/$DOMAIN ? [y/N]: " BACKUP < /dev/tty
            fi
            if [[ "$BACKUP" =~ ^[Yy]$ ]]; then
                DEST="$BACKUP_ROOT/$DOMAIN"
                mkdir -p "$DEST"
                cp -r "$CERT_DIR"/* "$DEST"/
                log_info "✅ 已备份 $DOMAIN 证书到 $DEST"
            fi

            log_info "🔹 删除证书目录 $CERT_DIR ..."
            ensure_safe_path "$CERT_DIR"
            rm -rf "$CERT_DIR"
        else
            log_info "ℹ️ 证书目录 $CERT_DIR 不存在，跳过"
        fi
    done
fi

# 4️⃣ 清理 crontab 自动续期任务
log_info "🔹 清理 acme.sh 自动续期 crontab..."
crontab -l | grep -v 'acme.sh' | crontab -

# 5️⃣ 卸载 socat（可选）
if command -v socat &>/dev/null; then
    if command -v apt &>/dev/null; then
        apt remove -y socat
    elif command -v yum &>/dev/null; then
        yum remove -y socat
    elif command -v dnf &>/dev/null; then
        dnf remove -y socat
    else
        log_warn "⚠️ 未知包管理器，无法自动卸载 socat"
    fi
else
    log_info "ℹ️ socat 未安装，跳过"
fi

log_info "=============================="
log_info "✅ 卸载完成！"
log_info "📂 备份目录（如有备份）：$BACKUP_ROOT"
log_info "=============================="
