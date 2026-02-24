#!/bin/bash
# 🚀 Nginx + Cloudflare 一键排查脚本
# 功能：检测监听端口、防火墙、证书、Cloudflare IP 放行

echo "🔍 检测 Nginx 状态..."
if ! command -v nginx >/dev/null 2>&1; then
    echo "❌ 未检测到 Nginx，请确认是否安装"
    exit 1
else
    nginx -t 2>/dev/null
    systemctl status nginx | grep Active
fi

echo
echo "🔍 检测监听端口..."
ss -tulnp | grep -E ':80|:443' || echo "❌ 未监听 80/443 端口"

echo
echo "🔍 检测防火墙规则 (UFW/iptables)"
if command -v ufw >/dev/null 2>&1; then
    ufw status
else
    iptables -L -n | grep -E '80|443' || echo "⚠️ iptables 未放行 80/443"
fi

echo
echo "🔍 检测 Cloudflare IP 段是否放行..."
CF_IPS=$(curl -s https://www.cloudflare.com/ips-v4; curl -s https://www.cloudflare.com/ips-v6)
for ip in $CF_IPS; do
    if ! iptables -L -n | grep -q "$ip"; then
        echo "⚠️ 未检测到放行 CF IP: $ip"
    fi
done

echo
echo "🔍 检测 SSL 证书 (443)"
if ss -tulnp | grep -q ':443'; then
    if command -v openssl >/dev/null 2>&1; then
        DOMAIN=$(grep server_name /etc/nginx/sites-enabled/* 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/;//')
        if [ -n "$DOMAIN" ]; then
            echo "🌐 检测域名证书: $DOMAIN"
            echo | openssl s_client -servername $DOMAIN -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -dates
        else
            echo "⚠️ 未找到 server_name，请检查 nginx 配置"
        fi
    fi
else
    echo "⚠️ 未开启 443 端口，可能只支持 HTTP"
fi

echo
echo "✅ 检测完成，请根据上面提示修复问题"
