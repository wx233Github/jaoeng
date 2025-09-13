#!/bin/bash
# =============================================
# 🚀 自动配置 Nginx 反向代理 + HTTPS 脚本
# 支持 Docker 容器或本地端口
# 自动修复依赖冲突
# =============================================

set -e

# -----------------------------
# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# -----------------------------
# 安装前确认
read -p "⚠️ 脚本将自动安装依赖并配置 Nginx，回车继续（默认 Y）: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ 已取消"
    exit 1
fi

# -----------------------------
# 修复被锁住或破损的包
echo "🔧 修复 apt 依赖和锁定..."
sudo dpkg --configure -a
sudo apt-get install -f -y
sudo rm -f /var/lib/apt/lists/lock
sudo rm -f /var/cache/apt/archives/lock
sudo rm -f /var/lib/dpkg/lock*
sudo apt update

# -----------------------------
# 自动安装依赖
echo "🔍 检查并安装依赖..."
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
# 获取 VPS 公网 IP
VPS_IP=$(curl -s https://ipinfo.io/ip)
echo "🌐 VPS 公网 IP: $VPS_IP"

# -----------------------------
# 输入项目列表
echo "请输入项目列表（格式：域名:docker容器名 或 域名:本地端口），输入空行结束："
PROJECTS=()
while true; do
    read -p "> " line
    [[ -z "$line" ]] && break
    PROJECTS+=("$line")
done

NGINX_CONF="/etc/nginx/sites-available/projects.conf"
WEBROOT="/var/www/html"

# -----------------------------
# 获取 Docker 容器端口
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
# 检测域名解析
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
# 生成 Nginx 反向代理配置
echo "🔧 生成 Nginx 配置..."
> $NGINX_CONF
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"

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

ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# -----------------------------
# 申请 HTTPS
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

echo "✅ 完成！通过域名即可访问对应服务。"
