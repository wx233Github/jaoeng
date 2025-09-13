#!/bin/bash
# =============================================
# 🚀 多项目 Nginx + acme.sh 自动配置脚本（带域名解析检测）
# =============================================
# 功能说明：
# 1. 支持 Docker 容器端口自动检测
# 2. 支持本地端口直接反向代理
# 3. 自动生成 Nginx 配置
# 4. 自动申请 HTTPS 证书（acme.sh）
# 5. 自动配置 HTTP → HTTPS 跳转
# 6. 无需 yq
# 7. 安装依赖前提示用户手动确认（回车默认 Y）
# 8. 自动检测域名是否解析到当前 VPS IP
# =============================================

set -e

# -----------------------------
# 安装依赖确认提示（回车默认 Y）
echo "⚠️ 请确保以下依赖已安装，否则脚本无法正常运行："
echo " - nginx"
echo " - docker (或 docker-compose)"
echo " - curl"
echo " - socat"
echo " - acme.sh"
read -p "确认依赖已安装且可用？(回车默认 Y): " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ 请先手动安装依赖，然后重新运行脚本"
    exit 1
fi

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# -----------------------------
# 配置区：在这里填写你的项目
# 格式：域名:docker容器名 或 本地端口
PROJECTS=(
    "a.example.com:app_a"
    "b.example.com:app_b"
    "c.example.com:8003"
)

NGINX_CONF="/etc/nginx/sites-available/projects.conf"
WEBROOT="/var/www/html"

# 获取 VPS 公网 IP
VPS_IP=$(curl -s https://ipinfo.io/ip)
echo "🌐 检测到 VPS 公网 IP: $VPS_IP"

# 函数：获取容器映射端口
get_container_port() {
    local container="$1"
    PORT=$(docker inspect $container \
        --format '{{ range $p,$conf := .NetworkSettings.Ports }}{{ if $conf }}{{$p}} {{end}}{{end}}' 2>/dev/null \
        | sed 's|/tcp||' | awk '{print $1}' | head -n1)
    if [ -z "$PORT" ]; then
        echo "⚠️ 无法获取容器 $container 端口，默认使用 80"
        PORT=80
    fi
    echo "$PORT"
}

# 函数：检测域名解析是否正确
check_domain() {
    local domain="$1"
    DOMAIN_IP=$(dig +short $domain | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    if [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo "⚠️ 域名 $domain 未解析到当前 VPS IP ($VPS_IP)，当前解析为: $DOMAIN_IP"
    else
        echo "✅ 域名 $domain 已正确解析到 VPS IP"
    fi
}

# 创建 Nginx 配置文件
echo "🔧 生成 Nginx 配置..."
> $NGINX_CONF
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"

    # 检测域名解析
    check_domain $DOMAIN

    if docker ps --format '{{.Names}}' | grep -wq "$TARGET"; then
        PORT=$(get_container_port $TARGET)
        PROXY="http://127.0.0.1:$PORT"
    else
        PROXY="http://127.0.0.1:$TARGET"
    fi

    cat >> $NGINX_CONF <<EOF
# -----------------------------
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass $PROXY;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
done

# 启用 Nginx 配置
ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# 申请证书并安装 HTTPS
echo "🔐 申请证书并安装..."
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"

    if docker ps --format '{{.Names}}' | grep -wq "$TARGET"; then
        PORT=$(get_container_port $TARGET)
        PROXY="http://127.0.0.1:$PORT"
    else
        PROXY="http://127.0.0.1:$TARGET"
    fi

    ~/.acme.sh/acme.sh --issue -d $DOMAIN -w $WEBROOT
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file       /etc/ssl/$DOMAIN.key \
        --fullchain-file /etc/ssl/$DOMAIN.cer \
        --reloadcmd      "systemctl reload nginx"

    # HTTPS 配置
    cat >> $NGINX_CONF <<EOF

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/ssl/$DOMAIN.key;

    location / {
        proxy_pass $PROXY;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF
done

nginx -t
systemctl reload nginx

echo "✅ 完成！所有项目已配置 HTTPS（含域名解析检测、Docker端口自动检测）。"
