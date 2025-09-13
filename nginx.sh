#!/bin/bash
# =============================================
# 🚀 多项目 Nginx + acme.sh 自动配置脚本（Docker端口自动检测版）
# =============================================
# 功能说明：
# 1. 支持 Docker 容器任意端口自动检测
# 2. 支持本地端口直接反向代理
# 3. 自动生成 Nginx 配置
# 4. 自动申请 HTTPS 证书（acme.sh）
# 5. 自动配置 HTTP → HTTPS 跳转
# 6. 无需额外依赖 yq
# 7. 安装依赖前会提示确认
# =============================================

set -e

# -----------------------------
# 安装确认提示
read -p "⚠️ 脚本将安装 Nginx、acme.sh 和 Docker（如未安装），确认继续？(y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "❌ 已取消安装"
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

# 安装依赖
echo "🔍 安装依赖..."
apt update
apt install -y nginx curl socat docker.io

# 安装 acme.sh
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    echo "🔍 安装 acme.sh..."
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

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

# 创建 Nginx 配置文件
echo "🔧 生成 Nginx 配置..."
> $NGINX_CONF
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"

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

echo "✅ 完成！所有项目已配置 HTTPS（无需 yq，Docker端口自动检测）。"
