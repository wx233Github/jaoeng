#!/bin/bash
# =============================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手
# 支持 Docker 容器或本地端口
# 功能：
# 1. 自动配置 Nginx 反向代理和 HTTPS 证书 (acme.sh)
# 2. 查看和管理已配置的项目 (域名、端口、证书状态)
# =============================================

set -e

# --- 全局变量和颜色定义 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"
export PATH="$HOME/.acme.sh:$PATH" # 确保 acme.sh 路径可用

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
RESET="\033[0m"

# -----------------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 请使用 root 用户运行${RESET}"
        exit 1
    fi
}

# -----------------------------
# 获取 VPS 公网 IPv4 地址
get_vps_ip() {
    VPS_IP=$(curl -s https://api.ipify.org)
    echo -e "${GREEN}🌐 VPS 公网 IP (IPv4): $VPS_IP${RESET}"
}

# -----------------------------
# 自动安装依赖（跳过已是最新版的），适用于 Debian/Ubuntu
install_dependencies() {
    echo -e "${GREEN}🔍 检查并安装依赖 (适用于 Debian/Ubuntu)...${RESET}"
    apt update -y || { echo -e "${RED}❌ apt update 失败，请检查网络或源配置。${RESET}"; exit 1; }

    DEPS=(nginx curl socat openssl) # openssl 用于获取证书信息
    for dep in "${DEPS[@]}"; do
        if command -v "$dep" &>/dev/null; then
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
}

# -----------------------------
# 检测 Docker 是否存在
detect_docker() {
    DOCKER_INSTALLED=false
    if command -v docker &>/dev/null; then
        DOCKER_INSTALLED=true
        echo -e "${GREEN}✅ Docker 已安装，可检测容器端口${RESET}"
    else
        echo -e "${YELLOW}⚠️ Docker 未安装，无法检测容器端口，只能配置本地端口${RESET}"
    fi
}

# -----------------------------
# 安装 acme.sh
install_acme_sh() {
    if [ ! -f "$ACME_BIN" ]; then
        echo -e "${YELLOW}⚠️ acme.sh 未安装，正在安装...${RESET}"
        # 建议提供邮箱用于注册 Let's Encrypt / ZeroSSL 账户
        curl https://get.acme.sh | sh -s email=your_email@example.com 
        # 重新加载 PATH 以确保 acme.sh 命令可用
        export PATH="$HOME/.acme.sh:$PATH"
    else
        echo -e "${GREEN}✅ acme.sh 已安装${RESET}"
    fi
}

# -----------------------------
# 获取 Docker 容器端口
get_container_port() {
    local container_name="$1"
    local port_found=""

    if [ "$DOCKER_INSTALLED" = true ]; then
        # 尝试获取暴露到宿主机的端口 (e.g. 0.0.0.0:80->80/tcp)
        port_found=$(docker inspect "$container_name" --format \
            '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
            sed 's|/tcp||g' | awk '{print $1}' | head -n1)
        
        if [ -z "$port_found" ]; then
            # 如果宿主端口未映射，尝试获取容器内部暴露的第一个端口
            port_found=$(docker inspect "$container_name" --format \
                '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | \
                sed 's|/tcp||g' | awk '{print $1}' | head -n1)
            if [ -n "$port_found" ]; then
                echo -e "${YELLOW}⚠️ 容器 $container_name 未映射到宿主机端口，将尝试代理到容器内部端口 $port_found。请确保容器监听 0.0.0.0。${RESET}"
            fi
        fi

        if [ -z "$port_found" ]; then
            echo -e "${RED}❌ 无法获取容器 $container_name 的端口，默认使用 80。请手动检查！${RESET}"
            echo "80"
        else
            echo "$port_found"
        fi
    else
        echo -e "${YELLOW}⚠️ Docker 未安装，无法获取容器端口，使用默认 80。${RESET}"
        echo "80"
    fi
}

# -----------------------------
# 检测域名解析 (仅检查 IPv4)
check_domain_ip() {
    local domain="$1"
    local vps_ip="$2"
    DOMAIN_IP=$(dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1) # 仅获取 IPv4
    
    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}❌ 域名 ${domain} 无法解析到任何 IPv4 地址，请检查 DNS 配置。${RESET}"
        return 1
    elif [ "$DOMAIN_IP" != "$vps_ip" ]; then
        echo -e "${RED}⚠️ 域名 ${domain} 未解析到当前 VPS IP ($vps_ip)，当前解析为: $DOMAIN_IP${RESET}"
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
# 配置 Nginx 和申请 HTTPS 证书的主函数
configure_nginx_projects() {
    check_root
    read -rp "⚠️ 脚本将自动安装依赖并配置 Nginx，回车继续（默认 Y）: " CONFIRM
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ 已取消配置。${RESET}"
        return 1
    fi

    install_dependencies
    detect_docker
    install_acme_sh
    
    # 创建 Nginx 配置目录和 Webroot 目录
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /var/www/html # 用于 acme.sh webroot 验证
    
    local VPS_IP # 确保在函数内部声明，避免与全局冲突
    get_vps_ip # 获取 VPS_IP 变量

    echo -e "${YELLOW}请输入项目列表（格式：域名:docker容器名 或 域名:本地端口），输入空行结束：${RESET}"
    PROJECTS=()
    while true; do
        read -rp "> " line
        [[ -z "$line" ]] && break
        PROJECTS+=("$line")
    done

    echo -e "${GREEN}🔧 正在为每个项目生成 Nginx 配置并申请证书...${RESET}"
    for P in "${PROJECTS[@]}"; do
        DOMAIN="${P%%:*}"
        TARGET="${P##*:}"
        DOMAIN_CONF="/etc/nginx/sites-available/$DOMAIN.conf"
        
        echo -e "\n--- 处理域名: ${BLUE}$DOMAIN${RESET} ---"

        # 1. 检查域名解析
        if ! check_domain_ip "$DOMAIN" "$VPS_IP"; then
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
        # 确保软链接存在
        if [ ! -L "/etc/nginx/sites-enabled/$DOMAIN.conf" ]; then
            ln -sf "$DOMAIN_CONF" /etc/nginx/sites-enabled/
        fi

        # 4. 重启 Nginx 以应用临时配置
        echo "重启 Nginx 服务以应用临时配置..."
        nginx -t || { echo -e "${RED}❌ Nginx 配置语法错误，请检查！${RESET}"; continue; }
        systemctl restart nginx || { echo -e "${RED}❌ Nginx 启动失败，请检查服务状态！${RESET}"; continue; }
        echo -e "${GREEN}✅ Nginx 已重启，准备申请证书。${RESET}"

        # 5. 申请证书
        echo -e "${YELLOW}正在为 $DOMAIN 申请证书...${RESET}"
        # 使用 --debug 2 获取更详细日志，便于调试
        if ! "$ACME_BIN" --issue -d "$DOMAIN" -w /var/www/html --ecc --debug 2; then
            echo -e "${RED}❌ 域名 $DOMAIN 的证书申请失败！请检查上述日志。${RESET}"
            # 清理可能残留的临时配置
            rm -f "$DOMAIN_CONF"
            rm -f "/etc/nginx/sites-enabled/$DOMAIN.conf"
            continue # 尝试处理下一个域名
        fi
        
        # 检查证书是否成功生成
        # acme.sh 会将证书文件放置在 ~/.acme.sh/DOMAIN_ecc/ 目录下，
        # install-cert 会将其复制到指定路径 /etc/ssl/DOMAIN.key 和 /etc/ssl/DOMAIN.cer
        INSTALLED_CRT_FILE="/etc/ssl/$DOMAIN.cer"
        INSTALLED_KEY_FILE="/etc/ssl/$DOMAIN.key"

        # 确保证书目标目录存在
        mkdir -p /etc/ssl/

        echo -e "${GREEN}✅ 证书已成功签发，正在安装并更新 Nginx 配置...${RESET}"

        # 6. 安装证书并生成最终的 Nginx 配置
        # acme.sh --install-cert 会复制证书文件并设置自动续期
        "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
            --key-file       "$INSTALLED_KEY_FILE" \
            --fullchain-file "$INSTALLED_CRT_FILE" \
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

    ssl_certificate $INSTALLED_CRT_FILE;
    ssl_certificate_key $INSTALLED_KEY_FILE;
    
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
        # WebSocket proxying
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
        echo -e "${GREEN}✅ 域名 $DOMAIN 的 Nginx 配置已更新。${RESET}"

    done

    # -----------------------------
    # 最终 Nginx 配置检查和重载 (确保所有证书和配置都已到位)
    echo -e "${GREEN}✅ 所有项目处理完毕，执行最终 Nginx 配置检查和重载...${RESET}"
    nginx -t || { echo -e "${RED}❌ 最终 Nginx 配置语法错误，请检查！${RESET}"; return 1; }
    systemctl reload nginx || { echo -e "${RED}❌ 最终 Nginx 重载失败，请手动检查 Nginx 服务状态！${RESET}"; return 1; }

    echo -e "${GREEN}🚀 所有域名配置完成！现在可以通过 HTTPS 访问您的服务。${RESET}"
    return 0
}

# -----------------------------
# 查看和管理已配置项目的函数
manage_configs() {
    check_root
    echo "=============================================="
    echo "📜 已配置项目列表及证书状态"
    echo "=============================================="

    # 检查 Nginx 配置目录是否存在且非空
    if [ ! -d "/etc/nginx/sites-available" ] || [ -z "$(ls -A /etc/nginx/sites-available/*.conf 2>/dev/null)" ]; then
        echo -e "${YELLOW}未找到任何已配置的 Nginx 项目。${RESET}"
        echo "=============================================="
        return 0
    fi

    CONFIGURED_DOMAINS=()
    # 遍历 Nginx 配置目录，获取已配置的域名
    for DOMAIN_CONF_FILE in /etc/nginx/sites-available/*.conf; do
        if [ -f "$DOMAIN_CONF_FILE" ]; then
            DOMAIN=$(grep -E '^\s*server_name\s+' "$DOMAIN_CONF_FILE" | head -n1 | awk '{print $2}' | sed 's/;//')
            if [ -n "$DOMAIN" ]; then
                CONFIGURED_DOMAINS+=("$DOMAIN")

                PROXY_PASS_LINE=$(grep -E '^\s*proxy_pass\s+' "$DOMAIN_CONF_FILE" | head -n1)
                # 尝试从 proxy_pass 中提取目标（去掉 http://127.0.0.1:）
                PROXY_TARGET=$(echo "$PROXY_PASS_LINE" | awk '{print $2}' | sed 's/;//' | sed 's|^http://127.0.0.1:||')
                if [ -z "$PROXY_TARGET" ]; then
                    PROXY_TARGET="未知"
                fi
                
                # 获取证书信息
                INSTALLED_CRT_FILE="/etc/ssl/$DOMAIN.cer"
                INSTALLED_KEY_FILE="/etc/ssl/$DOMAIN.key"
                
                if [[ -f "$INSTALLED_CRT_FILE" && -f "$INSTALLED_KEY_FILE" ]]; then
                    END_DATE=$(openssl x509 -enddate -noout -in "$INSTALLED_CRT_FILE" 2>/dev/null | cut -d= -f2)
                    
                    # 兼容不同系统的date命令，并格式化到期时间为 YYYY年MM月DD日
                    if date --version >/dev/null 2>&1; then # GNU date
                        END_TS=$(date -d "$END_DATE" +%s)
                        FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y年%m月%d日")
                    else # BSD date (macOS)
                        END_TS=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%s")
                        FORMATTED_END_DATE=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null)
                        if [[ -z "$FORMATTED_END_DATE" ]]; then
                            FORMATTED_END_DATE=$(date -j -f "%b %e %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null)
                        fi
                        FORMATTED_END_DATE="${FORMATTED_END_DATE:-未知日期}"
                    fi
                    
                    NOW_TS=$(date +%s)
                    LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))

                    if (( LEFT_DAYS < 0 )); then
                        STATUS_COLOR="$RED"
                        STATUS_TEXT="已过期"
                    elif (( LEFT_DAYS <= 30 )); then
                        STATUS_COLOR="$YELLOW"
                        STATUS_TEXT="即将到期"
                    else
                        STATUS_COLOR="$GREEN"
                        STATUS_TEXT="有效"
                    fi

                    printf "${STATUS_COLOR}域名: %-25s | 目标端口: %-8s | 状态: %-5s | 剩余: %3d天 | 到期时间: %s${RESET}\n" \
                        "$DOMAIN" "$PROXY_TARGET" "$STATUS_TEXT" "$LEFT_DAYS" "$FORMATTED_END_DATE"
                else
                    echo -e "${RED}域名: $DOMAIN | 目标端口: $PROXY_TARGET | 证书状态: 缺失或无效${RESET}"
                fi
            fi
        fi
    done

    echo "=============================================="

    # 管理选项子菜单
    while true; do
        echo -e "\n${BLUE}请选择管理操作：${RESET}"
        echo "1. 手动续期指定域名证书"
        echo "2. 删除指定域名配置及证书"
        echo "0. 返回主菜单"
        read -rp "请输入选项: " MANAGE_CHOICE
        case "$MANAGE_CHOICE" in
            1)
                read -rp "请输入要续期的域名: " DOMAIN_TO_RENEW
                if [[ -z "$DOMAIN_TO_RENEW" ]]; then
                    echo -e "${RED}❌ 域名不能为空！${RESET}"
                    continue
                fi
                # 检查域名是否在已配置列表中
                if [[ ! " ${CONFIGURED_DOMAINS[@]} " =~ " ${DOMAIN_TO_RENEW} " ]]; then
                    echo -e "${RED}❌ 域名 $DOMAIN_TO_RENEW 未找到在已配置列表中。${RESET}"
                    continue
                fi
                echo -e "${GREEN}🚀 正在为 $DOMAIN_TO_RENEW 续期证书...${RESET}"
                # 强制续期时使用 --ecc 参数确保使用 ECC 证书（如果已申请）
                if "$ACME_BIN" --renew -d "$DOMAIN_TO_RENEW" --force --ecc; then
                    echo -e "${GREEN}✅ 续期完成：$DOMAIN_TO_RENEW ${RESET}"
                    systemctl reload nginx # 续期后重载Nginx
                else
                    echo -e "${RED}❌ 续期失败：$DOMAIN_TO_RENEW。请检查日志。${RESET}"
                fi
                ;;
            2)
                read -rp "请输入要删除的域名: " DOMAIN_TO_DELETE
                if [[ -z "$DOMAIN_TO_DELETE" ]]; then
                    echo -e "${RED}❌ 域名不能为空！${RESET}"
                    continue
                fi
                # 检查域名是否在已配置列表中
                if [[ ! " ${CONFIGURED_DOMAINS[@]} " =~ " ${DOMAIN_TO_DELETE} " ]]; then
                    echo -e "${RED}❌ 域名 $DOMAIN_TO_DELETE 未找到在已配置列表中。${RESET}"
                    continue
                fi
                read -rp "⚠️ 确认删除域名 ${DOMAIN_TO_DELETE} 的所有 Nginx 配置和证书？此操作不可恢复！[y/N]: " CONFIRM_DELETE
                if [[ "$CONFIRM_DELETE" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}正在删除 ${DOMAIN_TO_DELETE}...${RESET}"
                    # 从 acme.sh 中移除证书 (即使失败也不阻止后续删除)
                    "$ACME_BIN" --remove -d "$DOMAIN_TO_DELETE" --ecc || true 
                    # 删除 Nginx 配置文件和软链接
                    rm -f "/etc/nginx/sites-available/$DOMAIN_TO_DELETE.conf"
                    rm -f "/etc/nginx/sites-enabled/$DOMAIN_TO_DELETE.conf"
                    # 删除物理证书文件
                    rm -f "/etc/ssl/$DOMAIN_TO_DELETE.key"
                    rm -f "/etc/ssl/$DOMAIN_TO_DELETE.cer"
                    echo -e "${GREEN}✅ 已删除域名 ${DOMAIN_TO_DELETE} 的相关配置和证书文件。${RESET}"
                    systemctl reload nginx || true # 即使失败也不阻止脚本完成
                else
                    echo -e "${YELLOW}已取消删除操作。${RESET}"
                fi
                ;;
            0)
                break # 返回主菜单
                ;;
            *)
                echo -e "${RED}❌ 无效选项，请输入 0-2 ${RESET}"
                ;;
        esac
    done
}


# --- 主菜单 ---
main_menu() {
    while true; do
        echo "=============================================="
        echo "🔐 Nginx/HTTPS 证书管理主菜单"
        echo "=============================================="
        echo "1. 配置新的 Nginx 反向代理和 HTTPS 证书"
        echo "2. 查看与管理已配置项目 (域名、端口、证书)"
        echo "0. 退出"
        echo "=============================================="
        read -rp "请输入选项: " MAIN_CHOICE
        case "$MAIN_CHOICE" in
            1)
                configure_nginx_projects
                ;;
            2)
                manage_configs
                ;;
            0)
                echo -e "${BLUE}👋 感谢使用，已退出。${RESET}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效选项，请输入 0-2 ${RESET}"
                ;;
        esac
    done
}

# --- 脚本入口 ---
main_menu
