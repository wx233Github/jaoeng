#!/bin/bash
# 🚀 SSL 证书申请助手（acme.sh）
# 功能：域名解析检测 + 80端口检查 + 自动安装 socat + ZeroSSL 自动注册邮箱

set -e

echo "=============================="
echo "   🌐 SSL 证书申请助手"
echo "=============================="

# ----------- 输入域名（必填） -----------
while true; do
    read -rp "请输入你的主域名 (例如 example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo "❌ 域名不能为空，请重新输入。"
        continue
    fi

    SERVER_IP=$(curl -s https://api.ipify.org)
    DOMAIN_IP=$(dig +short "$DOMAIN" | head -n1)

    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        echo "❌ 域名解析错误！"
        echo "   当前域名解析IP: $DOMAIN_IP"
        echo "   本服务器IP: $SERVER_IP"
        echo "请确保域名已解析到本服务器再继续。"
    else
        echo "✅ 域名解析正确，解析到本服务器。"
        break
    fi
done

# 是否申请泛域名
read -rp "是否申请泛域名证书 (*.$DOMAIN)？[y/N]: " USE_WILDCARD
if [[ "$USE_WILDCARD" =~ ^[Yy]$ ]]; then
    WILDCARD="*.$DOMAIN"
else
    WILDCARD=""
fi

# 证书存放路径（回车使用默认）
read -rp "请输入证书存放路径 [默认: /etc/ssl/$DOMAIN]: " INSTALL_PATH
INSTALL_PATH=${INSTALL_PATH:-/etc/ssl/$DOMAIN}

# 服务 reload 命令（回车使用默认）
read -rp "请输入证书更新后需要执行的服务重载命令 [默认: systemctl reload nginx]: " RELOAD_CMD
RELOAD_CMD=${RELOAD_CMD:-"systemctl reload nginx"}

# 验证方式选择
echo "请选择验证方式："
echo "1) standalone (HTTP验证，需要80端口)"
echo "2) dns_cf (Cloudflare DNS API)"
echo "3) dns_ali (阿里云 DNS API)"
while true; do
    read -rp "请输入序号 [1]: " VERIFY_METHOD
    VERIFY_METHOD=${VERIFY_METHOD:-1}
    case $VERIFY_METHOD in
        1) METHOD="standalone"; break ;;
        2) METHOD="dns_cf"; break ;;
        3) METHOD="dns_ali"; break ;;
        *) echo "❌ 输入错误，请输入 1、2 或 3。" ;;
    esac
done

# ----------- 安装 acme.sh -----------
echo "=============================="
echo "⚙️ 安装 acme.sh ..."
echo "=============================="
curl https://get.acme.sh | sh

ACME_BIN="$HOME/.acme.sh/acme.sh"
export PATH="$HOME/.acme.sh:$PATH"

echo "📂 创建证书存放目录: $INSTALL_PATH"
mkdir -p "$INSTALL_PATH"

# ----------- standalone 80端口 & socat 检查 -----------
if [[ "$METHOD" == "standalone" ]]; then
    echo "=============================="
    echo "🔍 检查 80 端口 ..."
    echo "=============================="

    if command -v ss &>/dev/null; then
        PORT_CHECK=$(ss -tuln | grep -w ":80" || true)
    else
        PORT_CHECK=$(netstat -tuln 2>/dev/null | grep -w ":80" || true)
    fi

    if [[ -n "$PORT_CHECK" ]]; then
        echo "❌ 检测到 80 端口已被占用："
        echo "$PORT_CHECK"
        echo "👉 standalone 模式需要占用 80 端口，请先关闭相关服务（如 nginx/apache），再重新运行脚本。"
        exit 1
    else
        echo "✅ 80 端口空闲，可以继续。"
    fi

    # 检查 socat
    if ! command -v socat &>/dev/null; then
        echo "⚠️ 未检测到 socat，正在安装..."
        if command -v apt &>/dev/null; then
            apt update && apt install -y socat
        elif command -v yum &>/dev/null; then
            yum install -y socat
        elif command -v dnf &>/dev/null; then
            dnf install -y socat
        else
            echo "❌ 无法自动安装 socat，请手动安装后重试。"
            exit 1
        fi
    fi

    # 检查 ZeroSSL 账号是否注册
    ACCOUNT_STATUS=$("$ACME_BIN" --accountstatus 2>/dev/null || true)
    if ! echo "$ACCOUNT_STATUS" | grep -q "Valid"; then
        read -rp "请输入用于注册 ZeroSSL 的邮箱: " ACCOUNT_EMAIL
        "$ACME_BIN" --register-account -m "$ACCOUNT_EMAIL"
    fi
fi

# ----------- DNS 验证提示 -----------
if [[ "$METHOD" == "dns_cf" ]]; then
    echo "⚠️ 你选择了 Cloudflare DNS 验证，请先设置环境变量："
    echo "   export CF_Token=\"你的API Token\""
    echo "   export CF_Account_ID=\"你的Account ID\""
    exit 1
elif [[ "$METHOD" == "dns_ali" ]]; then
    echo "⚠️ 你选择了 阿里云 DNS 验证，请先设置环境变量："
    echo "   export Ali_Key=\"你的AliKey\""
    echo "   export Ali_Secret=\"你的AliSecret\""
    exit 1
fi

# ----------- 申请证书 -----------
echo "=============================="
echo "🚀 正在申请证书 ..."
echo "=============================="
if [[ -n "$WILDCARD" ]]; then
    "$ACME_BIN" --issue -d "$DOMAIN" -d "$WILDCARD" --"$METHOD"
else
    "$ACME_BIN" --issue -d "$DOMAIN" --"$METHOD"
fi

# ----------- 安装证书 -----------
echo "=============================="
echo "📂 安装证书到: $INSTALL_PATH"
echo "=============================="
"$ACME_BIN" --install-cert -d "$DOMAIN" \
--key-file "$INSTALL_PATH/$DOMAIN.key" \
--fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
--reloadcmd "$RELOAD_CMD"

echo "=============================="
echo "✅ 证书申请完成！"
echo "   私钥: $INSTALL_PATH/$DOMAIN.key"
echo "   证书: $INSTALL_PATH/$DOMAIN.crt"
echo "🔄 自动续期已加入 crontab（每日检查一次）。"
echo "=============================="
