#!/bin/bash
# =============================================
# 🚀 多项目 Nginx + acme.sh 自动配置（docker-compose 自动端口版）
# =============================================
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# -----------------------------
# 配置区：在这里填写你的项目
# 格式：域名:docker-compose服务名 或 本地端口
PROJECTS=(
    "a.example.com:app_a"
    "b.example.com:app_b"
    "c.example.com:8003"
)

NGINX_CONF="/etc/nginx/sites-available/projects.conf"
WEBROOT="/var/www/html"
DOCKER_COMPOSE_FILE="docker-compose.yml"  # 如果不在当前目录请填写完整路径

# 安装依赖
echo "🔍 安装依赖..."
apt update
apt install -y nginx curl socat docker.io yq

# 安装 acme.sh
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    echo "🔍 安装 acme.sh..."
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

# 函数：获取 Docker 服务端口
get_service_port() {
    local service="$1"
    # 从 docker-compose.yml 中读取映射的端口
    PORT=$(yq e ".services.$service.ports[0]" $DOCKER_COMPOSE_FILE 2>/dev/null | sed 's/:.*//')
    if [ -z "$PORT" ]; then
        # 如果没有映射，尝试获取运行容器的映射端口
        CONTAINER=$(docker ps --format '{{.Names}} {{.Image}}' | grep "$service" | awk '{print $1}' | head -n1)
        if [ -n "$CONTAINER" ]; then
            PORT=$(docker inspect $CONTAINER \
                --format '{{ (index (index .NetworkSettings.Ports "80/tcp") 0).HostPort }}' 2>/dev/null || echo "80")
        else
            echo "⚠️ 无法获取服务 $service 的端口，默认使用 80"
            PORT=80
        fi
    fi
    echo "$PORT"
}

# 创建 Nginx 配置文件
echo "🔧 生成 Nginx 配置..."
> $NGINX_CONF
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"

    # 判断 TARGET 是本地端口还是 docker 服务
    if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
        PROXY="http://127.0.0.1:$TARGET"
    else
        PORT=$(get_service_port $TARGET)
        PROXY="http://127.0.0.1:$PORT"
    fi

    # HTTP 配置
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

    # 获取 PROXY
    if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
        PROXY="http://127.0.0.1:$TARGET"
    else
        PORT=$(get_service_port $TARGET)
        PROXY="http://127.0.0.1:$PORT"
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

echo "✅ 完成！所有项目已配置 HTTPS（自动读取 docker-compose 端口）。"
