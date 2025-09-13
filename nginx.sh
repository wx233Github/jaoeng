#!/bin/bash
# =============================================
# 🚀 多项目 Nginx + acme.sh 自动反向代理脚本（自动依赖安装版）
# =============================================
# 功能说明：
# 1. 自动安装依赖：nginx、docker、curl、socat、acme.sh
# 2. 自动创建 Nginx 配置目录
# 3. 支持 Docker 容器端口自动检测
# 4. 支持本地端口
# 5. 自动生成反向代理 Nginx 配置
# 6. 自动申请 HTTPS（acme.sh）
# 7. 自动 HTTP→HTTPS 跳转
# 8. 自动检测域名是否解析到 VPS IP
# =============================================

set -e

# -----------------------------
# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# -----------------------------
# 自动安装依赖
echo "🔍 检查并安装依赖..."
apt update
DEPS=(nginx docker.io curl socat)
for dep in "${DEPS[@]}"; do
    if ! command -v $dep &>/dev/null; then
        echo "⚠️ 缺少 $dep，正在安装..."
        apt install -y $dep
    else
        echo "✅ $dep 已安装"
    fi
done

# 安装 acme.sh
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    echo "⚠️ acme.sh 未安装，正在安装..."
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "✅ acme.sh 已安装"
fi

# -----------------------------
# 确保 Nginx 配置目录存在
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled

# -----------------------------
# 配置项目列表（域名:容器名 或 域名:本地端口）
PROJECTS=(
    "a.example.com:app_a"
    "b.example.com:app_b"
    "c.example.com:8003"
)

NGINX_CONF="/etc/nginx/sites-available/projects.conf"
WEBROOT="/var/www/html"

# 获取 VPS 公网 IP
VPS_IP=$(curl -s https://ipinfo.io/ip)
echo "🌐 VPS 公网 IP: $VPS_IP"

# -----------------------------
# 函数：获取 Docker 容器端口
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

# -----------------------------
# 函数：检测域名解析
check_domain() {
    local domain="$1"
    DOMAIN_IP=$(dig +short $domain | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    if [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo "⚠️ 域名 $domain 未解析到当前 VPS IP ($VPS_IP)，当前解析为: $DOMAIN_IP"
    else
        echo "✅ 域名 $domain 已正确解析到 VPS IP"
    fi
}

# -----------------------------
# 创建 Nginx 反向代理配置
echo "🔧 生成 Nginx 配置..."
> $NGINX_CONF
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"

    # 域名解析检测
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
done

# 启用 Nginx 配置
ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# -----------------------------
# 申请证书并配置 HTTPS
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

    # HTTPS 反向代理
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
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

echo "✅ 完成！所有项目已配置 HTTPS（自动安装依赖 + 反向代理 + 域名解析检测）"
