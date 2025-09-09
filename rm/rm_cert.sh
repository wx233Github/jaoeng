#!/bin/bash
# 🚀 安全版交互式卸载 SSL 脚本（可备份证书）

set -e

echo "=============================="
echo "⚠️  开始卸载 SSL 脚本相关内容"
echo "=============================="

# 1️⃣ 删除 acme.sh
if [ -d "$HOME/.acme.sh" ]; then
    echo "🔹 删除 acme.sh 目录..."
    rm -rf "$HOME/.acme.sh"
else
    echo "ℹ️ acme.sh 目录不存在，跳过"
fi

# 2️⃣ 删除脚本文件
SCRIPT_PATH="/opt/vps_install_modules/cert.sh"
if [ -f "$SCRIPT_PATH" ]; then
    echo "🔹 删除脚本文件 $SCRIPT_PATH ..."
    rm -f "$SCRIPT_PATH"
else
    echo "ℹ️ 脚本文件不存在，跳过"
fi

# 3️⃣ 交互式输入要删除的域名证书目录
DOMAINS=()
while true; do
    read -rp "请输入要卸载证书的域名（回车结束输入）: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        break
    fi
    DOMAINS+=("$DOMAIN")
done

if [ ${#DOMAINS[@]} -eq 0 ]; then
    echo "ℹ️ 未输入任何域名，跳过证书删除步骤。"
else
    BACKUP_ROOT="/root/ssl_backup"
    mkdir -p "$BACKUP_ROOT"

    for DOMAIN in "${DOMAINS[@]}"; do
        CERT_DIR="/etc/ssl/$DOMAIN"
        if [ -d "$CERT_DIR" ]; then
            read -rp "是否备份 $DOMAIN 证书到 $BACKUP_ROOT/$DOMAIN ? [y/N]: " BACKUP
            if [[ "$BACKUP" =~ ^[Yy]$ ]]; then
                DEST="$BACKUP_ROOT/$DOMAIN"
                mkdir -p "$DEST"
                cp -r "$CERT_DIR"/* "$DEST"/
                echo "✅ 已备份 $DOMAIN 证书到 $DEST"
            fi

            echo "🔹 删除证书目录 $CERT_DIR ..."
            rm -rf "$CERT_DIR"
        else
            echo "ℹ️ 证书目录 $CERT_DIR 不存在，跳过"
        fi
    done
fi

# 4️⃣ 清理 crontab 自动续期任务
echo "🔹 清理 acme.sh 自动续期 crontab..."
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
        echo "⚠️ 未知包管理器，无法自动卸载 socat"
    fi
else
    echo "ℹ️ socat 未安装，跳过"
fi

echo "=============================="
echo "✅ 卸载完成！"
echo "📂 备份目录（如有备份）：$BACKUP_ROOT"
echo "=============================="
