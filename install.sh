#!/bin/bash
# 🚀 通用交互式 SSL 证书申请 + 自动续期脚本
# 基于 acme.sh
# 作者：你的好助手 😎

set -e

echo "=============================="
echo "   🌐 SSL 证书申请助手"
echo "   使用 acme.sh + Let's Encrypt"
echo "=============================="

# 输入域名
read -rp "请输入你的主域名 (例如 example.com): " DOMAIN

# 是否需要泛域名
read -rp "是否申请泛域名证书 (*.${DOMAIN})? [y/N]: " USE_WILDCARD
if [[ "$USE_WILDCARD" =~ ^[Yy]$ ]]; then
    WILDCARD="*.$DOMAIN"
else
    WILDCARD=""
fi

# 证书存放路径
read -rp "请输入证书存放路径 [/etc/ssl/${DOMAIN}]: " INSTALL_PATH
INSTALL_PATH=${INSTALL_PATH:-/etc/ssl/${DOMAIN}}

# reload 命令
read -rp "请输入证书更新后需要执行的服务重载命令 [systemctl reload nginx]: " RELOAD_CMD
RELOAD_CMD=${RELOAD_CMD:-"systemctl reload nginx"}

# 验证方式
echo "请选择验证方式："
echo "1) standalone (需要80端口)"
echo "2) dns_cf (Cloudflare DNS API)"
echo "3) dns_ali (阿里云 DNS API)"
read -rp "请输入序号 [1]: " VERIFY_METHOD
case $VERIFY_METHOD in
    2) METHOD="dns_cf" ;;
    3) METHOD="dns_ali" ;;
    *) METHOD="standalone" ;;
esac

echo "=============================="
echo "   ⚙️ 开始安装 acme.sh ..."
echo "=============================="

# 安装 acme.sh
curl https://get.acme.sh | sh
source ~/.bashrc

echo "📂 创建证书存放目录: $INSTALL_PATH"
mkdir -p "$INSTALL_PATH"

# 如果是 DNS 验证，提醒用户设置 API
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

echo "=============================="
echo "   🚀 正在申请证书 ..."
echo "=============================="

if [[ -n "$WILDCARD" ]]; then
    acme.sh --issue -d "$DOMAIN" -d "$WILDCARD" --$METHOD
else
    acme.sh --issue -d "$DOMAIN" --$METHOD
fi

echo "=============================="
echo "   📂 安装证书到: $INSTALL_PATH"
echo "=============================="

acme.sh --install-cert -d "$DOMAIN" \
--key-file "$INSTALL_PATH/$DOMAIN.key" \
--fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
--reloadcmd "$RELOAD_CMD"

echo "=============================="
echo "✅ 证书申请完成！"
echo "   私钥: $INSTALL_PATH/$DOMAIN.key"
echo "   证书: $INSTALL_PATH/$DOMAIN.crt"
echo "🔄 自动续期已加入 crontab（每日检查一次）。"
echo "=============================="
