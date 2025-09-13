#!/bin/bash
# =============================================
# 🚀 自动配置 Nginx 反向代理 + HTTPS
# 支持 Docker 容器或本地端口
# 检测 Docker 是否存在，不安装
# 自动跳过已是最新版的依赖
# =============================================

set -e

# --- 全局变量和颜色定义 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"
export PATH="$HOME/.acme.sh:$PATH" # 确保 acme.sh 路径可用

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# -----------------------------
# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ 请使用 root 用户运行${RESET}"
    exit 1
fi

# -----------------------------
# 安装前确认
read -rp "⚠️ 脚本将自动安装依赖并配置 Nginx，回车继续（默认 Y）: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}❌ 已取消${RESET}"
    exit 1
fi

# -----------------------------
# 自动安装依赖（跳过已是最新版的）
echo -e "${GREEN}🔍 检查并安装依赖 (适用于 Debian/Ubuntu)...${RESET}"
# 尝试更新包列表，避免安装失败
apt update -y || { echo -e "${RED}❌ apt update 失败，请检查网络或源配置。${RESET}"; exit 1; }

DEPS=(nginx curl socat) # socat 即使不明确使用，acme.sh 可能会依赖
for dep in "${DEPS[@]}"; do
    if command -v "$dep" &>/dev/null; then
        # 检查是否为最新版 (仅适用于 apt)
        INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$dep" 2>/dev/null || echo "not-found")
        AVAILABLE_VER=$(apt-cache policy "$dep" | grep Candidate | awk '{print $2}' || echo "not-found")
        if [ "$INSTALLED_VER" != "not-found" ] && [ "$INSTALLED_VER" = "$AVAILABLE_VER" ]; then
            echo -e "${GREEN}✅ $dep 已安装且为最新版 ($INSTALLED_VER)，跳过${RESET}"
            continue
        else
            echo -e "${YELLOW}⚠️ $dep 版本过旧或可升级 ($INSTALLED_VER → $AVAILABLE_VER)，正在安装/更新...${RESET}"
        fi
    else
        echo -e "${YELLOW}⚠️ 缺少 $dep，正在安装...${RESET}"
    fi
    apt install -y "$dep"
done

# -----------------------------
# 检测 Docker 是否存在
DOCKER_INSTALLED=false
if command -v docker &>/dev/null; then
    DOCKER_INSTALLED=true
    echo -e "${GREEN}✅ Docker 已安装，可检测容器端口${RESET}"
else
    echo -e "${YELLOW}⚠️ Docker 未安装，无法检测容器端口，只能配置本地端口${RESET}"
fi

# -----------------------------
# 安装 acme.sh
if [ ! -f "$ACME_BIN" ]; then
    echo -e "${YELLOW}⚠️ acme.sh 未安装，正在安装...${RESET}"
    curl https://get.acme.sh | sh -s email=your_email@example.com # 建议提供邮箱
    # acme.sh 安装后会修改 ~/.bashrc, ~/.zshrc 等，为了当前脚本环境生效，可以 source 一下
    # 或者直接使用 ACME_BIN 完整路径调用，已在脚本顶部设置 PATH
else
    echo -e "${GREEN}✅ acme.sh 已安装${RESET}"
fi

# -----------------------------
# 创建 Nginx 配置目录和 Webroot 目录
mkdir -p /etc/nginx/sites-available
mkdir -p /etc/nginx/sites-enabled
mkdir -p /var/www/html # 用于 acme.sh webroot 验证

# -----------------------------
# 获取 VPS 公网 IP (IPv4)
VPS_IP=$(curl -s https://api.ipify.org) # 使用更简单的 ipify
echo -e "${GREEN}🌐 VPS 公网 IP (IPv4): $VPS_IP${RESET}"

# -----------------------------
# 输入项目列表
echo -e "${YELLOW}请输入项目列表（格式：域名:docker容器名 或 域名:本地端口），输入空行结束：${RESET}"
PROJECTS=()
while true; do
    read -rp "> " line
    [[ -z "$line" ]] && break
    PROJECTS+=("$line")
done

# -----------------------------
# 获取 Docker 容器端口
get_container_port() {
    local container_name="$1"
    if [ "$DOCKER_INSTALLED" = true ]; then
        # 尝试获取暴露到宿主机的端口，或者容器内部第一个暴露的端口
        PORT=$(docker inspect "$container_name" --format \
            '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ else }}{{ $p }}{{ end }}{{ end }}' 2>/dev/null | \
            sed 's|/tcp||g' | awk '{print $1}' | head -n1)
        
        if [ -z "$PORT" ]; then
            echo -e "${YELLOW}⚠️ 无法获取容器 $container_name 暴露到宿主机的端口，尝试获取容器内部端口...${RESET}"
            PORT=$(docker inspect "$container_name" --format \
                '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | \
                sed 's|/tcp||g' | awk '{print $1}' | head -n1)
        fi

        if [ -z "$PORT" ]; then
            echo -e "${RED}❌ 无法获取容器 $container_name 的端口，默认使用 80。请手动检查！${RESET}"
            PORT=80
        fi
        echo "$PORT"
    else
        echo -e "${YELLOW}⚠️ Docker 未安装，无法获取容器端口，使用默认 80。${RESET}"
        echo "80"
    fi
}

# -----------------------------
# 检测域名解析 (仅检查 IPv4)
check_domain() {
    local domain="$1"
    DOMAIN_IP=$(dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1) # 仅获取 IPv4
    
    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}❌ 域名 ${domain} 无法解析到任何 IPv4 地址，请检查 DNS 配置。${RESET}"
        return 1
    elif [ "$DOMAIN_IP" != "$VPS_IP" ]; then
        echo -e "${RED}⚠️ 域名 ${domain} 未解析到当前 VPS IP ($VPS_IP)，当前解析为: $DOMAIN_IP${RESET}"
        read -rp "域名解析与本机IP不符，可能导致证书申请失败。是否继续？[y/N]: " PROCEED_ANYWAY
        if [[ ! "$PROCEED_ANYWAY" =~ ^[Yy]$ ]]; then
            echo -e "${RED}❌ 已取消当前域名的操作。${RESET}"
            return 1
        fi
        echo -e "${YELLOW}⚠️ 已选择继续申请。请务必确认此操作的风险。${RESET}"
    else
        echo -e "${GREEN}✅ 域名 ${domain} 已正确解析到 VPS IP${RESET}"
    fi
    return 0
}

# -----------------------------
# 主要配置和证书申请循环
echo -e "${GREEN}🔧 正在为每个项目生成 Nginx 配置并申请证书...${RESET}"
for P in "${PROJECTS[@]}"; do
    DOMAIN="${P%%:*}"
    TARGET="${P##*:}"
    DOMAIN_CONF="/etc/nginx/sites-available/$DOMAIN.conf"
    
    echo -e "\n--- 处理域名: ${YELLOW}$DOMAIN${RESET} ---"

    # 1. 检查域名解析
    if ! check_domain "$DOMAIN"; then
        echo -e "${RED}❌ 跳过域名 $DOMAIN 的配置和证书申请。${RESET}"
        continue
    fi

    # 2. 确定后端代理目标
    PROXY_TARGET=""
    if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$TARGET"; then
        echo -e "${GREEN}🔍 识别到 Docker 容器: $TARGET${RESET}"
        PORT=$(get_container_port "$TARGET")
        PROXY_TARGET="http://127.0.0.1:$PORT"
        echo -e "${GREEN}   容器 $TARGET 端口: $PORT, 代理目标: $PROXY_TARGET${RESET}"
    elif [[ "$TARGET" =~ ^[0-9]+$ ]]; then
        echo -e "${GREEN}🔍 识别到本地端口: $TARGET${RESET}"
        PROXY_TARGET="http://127.0.0.1:$TARGET"
    else
        echo -e "${RED}❌ 无效的目标格式 '$TARGET' (既不是Docker容器名也不是端口号)，跳过域名 $DOMAIN。${RESET}"
        continue
    fi

    # 3. 生成 Nginx 临时配置（仅 HTTP + ACME 验证）
    echo -e "${YELLOW}生成 Nginx 临时 HTTP 配置以进行证书验证...${RESET}"
    > "$DOMAIN_CONF" # 清空或创建文件
    cat >> "$DOMAIN_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html; # 必须指向 acme.sh 的 webroot
    }

    location / {
        return 200 'ACME Challenge Ready'; # 临时返回，确保 80 端口可用
    }
}
EOF
    ln -sf "$DOMAIN_CONF" /etc/nginx/sites-enabled/

    # 4. 重启 Nginx 以应用临时配置
    echo "重启 Nginx 服务以应用临时配置..."
    nginx -t || { echo -e "${RED}❌ Nginx 配置语法错误，请检查！${RESET}"; exit 1; }
    systemctl restart nginx || { echo -e "${RED}❌ Nginx 启动失败，请检查服务状态！${RESET}"; exit 1; }
    echo -e "${GREEN}✅ Nginx 已重启，准备申请证书。${RESET}"

    # 5. 申请证书
    echo -e "${YELLOW}正在为 $DOMAIN 申请证书...${RESET}"
    # 使用 --debug 2 获取更详细日志，便于调试
    "$ACME_BIN" --issue -d "$DOMAIN" -w /var/www/html --ecc --debug 2
    
    # 检查证书是否成功生成
    CRT_FILE="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    KEY_FILE="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"

    if [[ -f "$CRT_FILE" && -f "$KEY_FILE" ]]; then
        echo -e "${GREEN}✅ 证书已成功签发，正在安装并更新 Nginx 配置...${RESET}"

        # 6. 安装证书并生成最终的 Nginx 配置
        # acme.sh --install-cert 会复制证书文件并设置自动续期
        # 我们将手动处理 Nginx 配置的重新生成和 reload
        "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
            --key-file       "/etc/ssl/$DOMAIN.key" \
            --fullchain-file "/etc/ssl/$DOMAIN.cer" \
            --reloadcmd      "systemctl reload nginx" # acme.sh 会在证书安装后自动执行 reload

        # 生成最终的 Nginx 配置 (HTTP redirect + HTTPS proxy)
        echo -e "${YELLOW}生成 $DOMAIN 的最终 Nginx 配置...${RESET}"
        > "$DOMAIN_CONF" # 清空并重写为最终配置
        cat >> "$DOMAIN_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2; # 启用 HTTP/2
    server_name $DOMAIN;

    ssl_certificate /etc/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/ssl/$DOMAIN.key;
    
    # 推荐的 SSL 安全配置
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    ssl_prefer_server_ciphers off;

    # HSTS (HTTP Strict Transport Security)
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass $PROXY_TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off; # 避免重定向问题
    }
}
EOF
    else
        echo -e "${RED}❌ 域名 $DOMAIN 的证书申请失败！请检查上述日志或添加 --debug 2 重新运行。${RESET}"
        # 清理可能残留的临时配置
        rm -f "$DOMAIN_CONF"
        rm -f "/etc/nginx/sites-enabled/$DOMAIN.conf"
    fi
done

# -----------------------------
# 最终 Nginx 配置检查和重载 (确保所有证书和配置都已到位)
echo -e "${GREEN}✅ 所有项目处理完毕，执行最终 Nginx 配置检查和重载...${RESET}"
nginx -t || { echo -e "${RED}❌ 最终 Nginx 配置语法错误，请检查！${RESET}"; exit 1; }
systemctl reload nginx || { echo -e "${RED}❌ 最终 Nginx 重载失败，请手动检查 Nginx 服务状态！${RESET}"; exit 1; }

echo -e "${GREEN}🚀 所有域名配置完成！现在可以通过 HTTPS 访问您的服务。${RESET}"
