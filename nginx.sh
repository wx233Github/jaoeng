#!/bin/bash
# ==============================================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手（基于 acme.sh）
# ------------------------------------------------------------------------------
# 功能概览：
# - **自动化配置**: 一键式自动配置 Nginx 反向代理和 HTTPS 证书。
# - **后端支持**: 支持代理到 Docker 容器或本地指定端口。
# - **依赖管理**: 自动检查并安装/更新必要的系统依赖（Nginx, Curl, Socat, OpenSSL, JQ）。
# - **acme.sh 集成**:
#   - 自动安装 acme.sh，并管理 Let's Encrypt 或 ZeroSSL 证书的申请、安装和自动续期。
#   - 支持选择 `http-01` 或 `dns-01` 验证方式。
#   - `dns-01` 模式下可申请泛域名证书，并提示设置 DNS API 凭证。
#   - 选择 ZeroSSL 时，检查并引导注册账户。
# - **域名解析校验**:
#   - 交互式检查域名是否正确解析到当前 VPS 的 IPv4 公网 IP。
#   - 如果 VPS 有 IPv6 地址，同时检查 AAAA 记录，并在缺失或不匹配时提供警告和交互。
# - **HTTPS 强制**: 自动配置 HTTP 到 HTTPS 的 301 重定向。
# - **SSL 安全优化**: 默认启用 HTTP/2，并配置推荐的 SSL 协议和加密套件，支持 HSTS。
# - **项目管理**:
#   - **核心改进**: 项目配置集中存储在 `/etc/nginx/ssl_manager_projects.json` 中。
#   - 提供菜单，方便查看所有已配置项目的详情（域名、类型、目标、证书状态、到期时间等）。
#   - **新增**: 提供“编辑项目”功能，可修改后端目标、验证方式等。
#   - **新增**: 提供“管理自定义 Nginx 配置片段”功能。
# - **证书续期**:
#   - 支持手动续期指定域名的 HTTPS 证书。
#   - **新增**: 提供“检查并自动续期所有证书”功能，可作为 Cron 任务运行。
# - **配置删除**: 支持删除指定域名的 Nginx 配置、证书文件和相关元数据。
# - **acme.sh 账户管理**: 新增专门的菜单，用于查看、注册和设置默认 ACME 账户。
# - **错误日志分析**: 对 `acme.sh` 错误日志的简单分析，提供更具体的排查建议。
# - **日志记录**: 所有脚本输出都会同时记录到指定日志文件，便于排查问题。
# - **IPv6 支持**: Nginx 自动监听服务器的 IPv6 地址（如果存在）。
# - **Docker 端口选择**: 在配置 Docker 项目时，智能检测宿主机映射端口，未检测到时可手动指定容器内部端口。
# - **Nginx 自定义片段**: 允许为每个域名注入自定义的 Nginx 配置片段文件，并提供智能默认路径。
# ==============================================================================

set -e
set -u # 启用：遇到未定义的变量即退出，有助于发现错误

# --- 全局变量和颜色定义 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"
export PATH="$HOME/.acme.sh:$PATH" # 确保 acme.sh 路径可用

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
MAGENTA="\033[35m"
RESET="\033[0m"

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/ssl_manager_projects.json"
RENEW_THRESHOLD_DAYS=30 # 证书在多少天内到期时触发自动续期

# --- 日志重定向 ---
# 将所有 stdout 和 stderr 同时输出到终端和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${BLUE}--- 脚本开始执行: $(date +"%Y-%m-%d %H:%M:%S") ---${RESET}"

# -----------------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ 请使用 root 用户运行${RESET}"
        exit 1
    fi
}

# -----------------------------
# 获取 VPS 公网 IPv4 和 IPv6 地址
get_vps_ip() {
    VPS_IP=$(curl -s https://api.ipify.org)
    echo -e "${GREEN}🌐 VPS 公网 IP (IPv4): $VPS_IP${RESET}"

    # 尝试获取 IPv6 地址，如果失败则为空
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "") 
    if [[ -n "$VPS_IPV6" ]]; then
        echo -e "${GREEN}🌐 VPS 公网 IP (IPv6): $VPS_IPV6${RESET}"
    else
        echo -e "${YELLOW}⚠️ 无法获取 VPS 公网 IPv6 地址，Nginx 将只监听 IPv4。${RESET}"
    fi
}

# -----------------------------
# 自动安装依赖（跳过已是最新版的），适用于 Debian/Ubuntu
install_dependencies() {
    echo -e "${GREEN}🔍 检查并安装依赖 (适用于 Debian/Ubuntu)...${RESET}"
    apt update -y || { echo -e "${RED}❌ apt update 失败，请检查网络或源配置。${RESET}"; exit 1; }

    DEPS=(nginx curl socat openssl jq) # JQ for JSON parsing
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
        
        read -rp "请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址 (例如: your@example.com)，回车则不指定: " ACME_EMAIL_INPUT
        
        ACME_EMAIL=""
        if [[ -n "$ACME_EMAIL_INPUT" ]]; then
            while [[ ! "$ACME_EMAIL_INPUT" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                echo -e "${RED}❌ 邮箱格式不正确。请重新输入，或回车不指定。${RESET}"
                read -rp "请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址: " ACME_EMAIL_INPUT
                [[ -z "$ACME_EMAIL_INPUT" ]] && break
            done
            ACME_EMAIL="$ACME_EMAIL_INPUT"
        fi

        if [[ -n "$ACME_EMAIL" ]]; then
            echo -e "${BLUE}➡️ 正在使用邮箱 $ACME_EMAIL 安装 acme.sh...${RESET}"
            curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
        else
            echo -e "${YELLOW}ℹ️ 未指定邮箱地址安装 acme.sh。某些证书颁发机构（如 ZeroSSL）可能需要注册邮箱。您可以在之后使用 'acme.sh --register-account -m your@example.com' 手动注册。${RESET}"
            read -rp "是否确认不指定邮箱安装 acme.sh？[y/N]: " NO_EMAIL_CONFIRM
            NO_EMAIL_CONFIRM=${NO_EMAIL_CONFIRM:-y} # 默认确认
            if [[ "$NO_EMAIL_CONFIRM" =~ ^[Yy]$ ]]; then
                curl https://get.acme.sh | sh
            else
                echo -e "${RED}❌ 已取消 acme.sh 安装。${RESET}"
                exit 1
            fi
        fi
        export PATH="$HOME/.acme.sh:$PATH" # 重新加载 PATH，确保 acme.sh 命令可用
    else
        echo -e "${GREEN}✅ acme.sh 已安装${RESET}"
    fi
}

# -----------------------------
# 检测域名解析 (同时检查 IPv4 和 IPv6)
check_domain_ip() {
    local domain="$1"
    local vps_ip_v4="$2" # VPS_IP
    local vps_ip_v6="$3" # VPS_IPV6 (global variable)

    # 1. IPv4 解析检查
    local domain_ip_v4=$(dig +short "$domain" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 2>/dev/null || echo "")
    if [ -z "$domain_ip_v4" ]; then
        echo -e "${RED}❌ 域名 ${domain} 无法解析到任何 IPv4 地址，请检查 DNS 配置。${RESET}"
        return 1 # 硬性失败
    elif [ "$domain_ip_v4" != "$vps_ip_v4" ]; then
        echo -e "${RED}⚠️ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 与本机 IPv4 ($vps_ip_v4) 不符。${RESET}"
        read -rp "这可能导致证书申请失败。是否继续？[y/N]: " PROCEED_ANYWAY_V4
        PROCEED_ANYWAY_V4=${PROCEED_ANYWAY_V4:-y}
        if [[ ! "$PROCEED_ANYWAY_V4" =~ ^[Yy]$ ]]; then
            echo -e "${RED}❌ 已取消当前域名的操作。${RESET}"
            return 1 # 硬性失败
        fi
        echo -e "${YELLOW}⚠️ 已选择继续申请 (IPv4 解析不匹配)。请务必确认此操作的风险。${RESET}"
    else
        echo -e "${GREEN}✅ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 正确。${RESET}"
    fi

    # 2. IPv6 解析检查 (如果 VPS 有 IPv6 地址)
    if [[ -n "$vps_ip_v6" ]]; then
        local domain_ip_v6=$(dig +short "$domain" AAAA | grep -E '^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$' | head -n1 2>/dev/null || echo "")
        if [ -z "$domain_ip_v6" ]; then
            echo -e "${YELLOW}⚠️ 域名 ${domain} 未配置 AAAA 记录，但您的 VPS 具有 IPv6 地址。${RESET}"
            read -rp "这表示该域名可能无法通过 IPv6 访问。是否继续？[y/N]: " PROCEED_ANYWAY_AAAA_MISSING
            PROCEED_ANYWAY_AAAA_MISSING=${PROCEED_ANYWAY_AAAA_MISSING:-y}
            if [[ ! "$PROCEED_ANYWAY_AAAA_MISSING" =~ ^[Yy]$ ]]; then
                echo -e "${RED}❌ 已取消当前域名的操作。${RESET}"
                return 1 # 硬性失败
            fi
            echo -e "${YELLOW}⚠️ 已选择继续申请 (AAAA 记录缺失)。${RESET}"
        elif [ "$domain_ip_v6" != "$vps_ip_v6" ]; then
            echo -e "${RED}⚠️ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 与本机 IPv6 ($vps_ip_v6) 不符。${RESET}"
            read -rp "这可能导致证书申请失败或域名无法通过 IPv6 访问。是否继续？[y/N]: " PROCEED_ANYWAY_AAAA_MISMATCH
            PROCEED_ANYWAY_AAAA_MISMATCH=${PROCEED_ANYWAY_AAAA_MISMATCH:-y}
            if [[ ! "$PROCEED_ANYWAY_AAAA_MISMATCH" =~ ^[Yy]$ ]]; then
                echo -e "${RED}❌ 已取消当前域名的操作。${RESET}"
                return 1 # 硬性失败
            fi
            echo -e "${YELLOW}⚠️ 已选择继续申请 (IPv6 解析不匹配)。请务必确认此操作的风险。${RESET}"
        else
            echo -e "${GREEN}✅ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 正确。${RESET}"
        fi
    else
        echo -e "${YELLOW}ℹ️ 您的 VPS 未检测到 IPv6 地址，因此未检查域名 ${domain} 的 AAAA 记录。${RESET}"
    fi

    return 0 # 只要没有硬性失败，就返回 0
}

# -----------------------------
# Helper function to generate Nginx listen directives (IPv4 and optionally IPv6)
generate_nginx_listen_directives() {
    local port="$1"
    local ssl_http2_flags="$2" # e.g., "ssl http2" or empty
    local directives="    listen $port $ssl_http2_flags;"
    if [[ -n "$VPS_IPV6" ]]; then # Use global VPS_IPV6 here
        directives+="\n    listen [::]:$port $ssl_http2_flags;"
    fi
    echo -e "$directives"
}

# -----------------------------
# Nginx 配置模板 (HTTP 挑战)
_NGINX_HTTP_CHALLENGE_TEMPLATE() {
    local DOMAIN="$1"
    
    cat <<EOF
server {
$(generate_nginx_listen_directives 80 "")
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 200 'ACME Challenge Ready';
    }
}
EOF
}

# -----------------------------
# Nginx 配置模板 (最终 HTTPS 代理)
_NGINX_FINAL_TEMPLATE() {
    local DOMAIN="$1"
    local PROXY_TARGET_URL="$2"
    local INSTALLED_CRT_FILE="$3"
    local INSTALLED_KEY_FILE="$4"
    local CUSTOM_SNIPPET_PATH="$5" # 新增参数：自定义片段文件路径

    cat <<EOF
server {
$(generate_nginx_listen_directives 80 "")
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
$(generate_nginx_listen_directives 443 "ssl http2")
    server_name $DOMAIN;

    ssl_certificate $INSTALLED_CRT_FILE;
    ssl_certificate_key $INSTALLED_KEY_FILE;
    
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
    # 注入自定义 Nginx 配置片段
    if [[ -n "$CUSTOM_SNIPPET_PATH" && "$CUSTOM_SNIPPET_PATH" != "null" && -f "$CUSTOM_SNIPPET_PATH" ]]; then
        cat <<INNER_EOF
    # BEGIN Custom Nginx Snippet for $DOMAIN
    include $CUSTOM_SNIPPET_PATH;
    # END Custom Nginx Snippet for $DOMAIN
INNER_EOF
    fi

    cat <<EOF
    location / {
        proxy_pass $PROXY_TARGET_URL;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
}

# -----------------------------
# Analyze acme.sh error output and provide suggestions
analyze_acme_error() {
    local error_output="$1"
    echo -e "${RED}--- acme.sh 错误分析 ---${RESET}"
    if echo "$error_output" | grep -q "Invalid response from"; then
        echo -e "${RED}   可能原因：域名解析错误，或 80 端口未开放/被占用，或防火墙阻止了验证请求。${RESET}"
        echo -e "${YELLOW}   建议：1. 检查域名 A/AAAA 记录是否指向本机 IP。2. 确保 80 端口已开放且未被其他服务占用。3. 检查服务器防火墙设置。${RESET}"
    elif echo "$error_output" | grep -q "Domain not owned"; then
        echo -e "${RED}   可能原因：acme.sh 无法证明您拥有该域名。${RESET}"
        echo -e "${YELLOW}   建议：1. 确保域名解析正确。2. 如果是 dns-01 验证，检查 DNS API 密钥和权限。3. 尝试强制更新 DNS 记录。${RESET}"
    elif echo "$error_output" | grep -q "Timeout"; then
        echo -e "${RED}   可能原因：验证服务器连接超时。${RESET}"
        echo -e "${YELLOW}   建议：检查服务器网络连接，防火墙，或 DNS 解析是否稳定。${RESET}"
    elif echo "$error_output" | grep -q "Rate Limit"; then
        echo -e "${RED}   可能原因：已达到 Let's Encrypt 或 ZeroSSL 的请求频率限制。${RESET}"
        echo -e "${YELLOW}   建议：请等待一段时间（通常为一周）再尝试，或添加更多域名到单个证书（如果适用）。${RESET}"
        echo -e "${YELLOW}   参考: https://letsencrypt.org/docs/rate-limits/ 或 ZeroSSL 文档。${RESET}"
    elif echo "$error_output" | grep -q "DNS problem"; then
        echo -e "${RED}   可能原因：DNS 验证失败。${RESET}"
        echo -e "${YELLOW}   建议：1. 检查 DNS 记录是否正确添加 (TXT 记录)。2. 检查 DNS API 密钥是否有效且有足够权限。3. 确保 DNS 记录已完全生效。${RESET}"
    elif echo "$error_output" | grep -q "No account specified for this domain"; then
        echo -e "${RED}   可能原因：未为该域名指定或注册 ACME 账户。${RESET}"
        echo -e "${YELLOW}   建议：运行 'acme.sh --register-account -m your@example.com --server [CA_SERVER_URL]' 注册账户。${RESET}"
    else
        echo -e "${RED}   未识别的错误类型。${RESET}"
        echo -e "${YELLOW}   建议：请仔细检查上述 acme.sh 完整错误日志，并查阅 acme.sh 官方文档或社区寻求帮助。${RESET}"
    fi
    echo -e "${RED}--------------------------${RESET}"
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
    
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /var/www/html # 用于 acme.sh webroot 验证
    mkdir -p /etc/nginx/custom_snippets # 创建自定义片段的默认父目录
    
    local VPS_IP # VPS_IPV6 是全局的，无需在此处声明 local
    get_vps_ip # 获取 VPS_IP 和 VPS_IPV6 变量 (VPS_IPV6 是全局变量)

    # 检查并移除旧版 projects.conf 以避免冲突
    if [ -f "/etc/nginx/sites-available/projects.conf" ]; then
        echo -e "${YELLOW}⚠️ 检测到旧版 Nginx 配置文件 /etc/nginx/sites-available/projects.conf，正在删除以避免冲突。${RESET}"
        rm -f "/etc/nginx/sites-available/projects.conf"
        rm -f "/etc/nginx/sites-enabled/projects.conf"
        systemctl reload nginx 2>/dev/null || true # 尝试重载 Nginx
    fi

    # Ensure metadata file exists and is a valid JSON array
    if [ ! -f "$PROJECTS_METADATA_FILE" ]; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
    else
        # Validate if it's a valid JSON array
        if ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
            echo -e "${RED}❌ 警告: $PROJECTS_METADATA_FILE 不是有效的 JSON 格式。将备份并重新创建。${RESET}"
            mv "$PROJECTS_METADATA_FILE" "${PROJECTS_METADATA_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            echo "[]" > "$PROJECTS_METADATA_FILE"
        fi
    fi

    echo -e "${YELLOW}请输入项目列表（格式：主域名:docker容器名 或 主域名:本地端口），输入空行结束：${RESET}"
    PROJECTS=()
    while true; do
        read -rp "> " line
        [[ -z "$line" ]] && break
        PROJECTS+=("$line")
    done

    # CA 选择
    ACME_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory" # Let's Encrypt v2 API URL
    ACME_CA_SERVER_NAME="letsencrypt"
    echo -e "\n请选择证书颁发机构 (CA):"
    echo "1) Let's Encrypt (默认)"
    echo "2) ZeroSSL"
    read -rp "请输入序号: " CA_CHOICE
    CA_CHOICE=${CA_CHOICE:-1}
    case $CA_CHOICE in
        1) ACME_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; ACME_CA_SERVER_NAME="letsencrypt";;
        2) ACME_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; ACME_CA_SERVER_NAME="zerossl";;
        *) echo -e "${YELLOW}⚠️ 无效选择，将使用默认 Let's Encrypt。${RESET}";;
    esac
    echo -e "${BLUE}➡️ 选定 CA: $ACME_CA_SERVER_NAME${RESET}"

    # ZeroSSL 账户注册检查
    if [ "$ACME_CA_SERVER_NAME" = "zerossl" ]; then
        echo -e "${BLUE}🔍 检查 ZeroSSL 账户注册状态...${RESET}"
        # acme.sh --list 默认显示所有账户，ZeroSSL 账户通常会显示 "ZeroSSL.com" 或其 URL
        if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
             echo -e "${YELLOW}⚠️ 未检测到 ZeroSSL 账户已注册。${RESET}"
             read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " ZERO_SSL_ACCOUNT_EMAIL
             while [[ ! "$ZERO_SSL_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                 echo -e "${RED}❌ 邮箱格式不正确。请重新输入。${RESET}"
                 read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " ZERO_SSL_ACCOUNT_EMAIL
             done
             echo -e "${BLUE}➡️ 正在注册 ZeroSSL 账户: $ZERO_SSL_ACCOUNT_EMAIL...${RESET}"
             "$ACME_BIN" --register-account -m "$ZERO_SSL_ACCOUNT_EMAIL" --server "$ACME_CA_SERVER_URL" || {
                 echo -e "${RED}❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。${RESET}"
                 return 1
             }
             echo -e "${GREEN}✅ ZeroSSL 账户注册成功。${RESET}"
        else
            echo -e "${GREEN}✅ ZeroSSL 账户已注册。${RESET}"
        fi
    fi

    echo -e "${GREEN}🔧 正在为每个项目生成 Nginx 配置并申请证书...${RESET}"
    for P in "${PROJECTS[@]}"; do
        MAIN_DOMAIN="${P%%:*}" # 原始输入的主域名
        TARGET_INPUT="${P##*:}" # 原始输入的目标，可能是容器名或端口
        DOMAIN_CONF="/etc/nginx/sites-available/$MAIN_DOMAIN.conf"
        
        echo -e "\n--- 处理域名: ${BLUE}$MAIN_DOMAIN${RESET} ---"

        # 检查是否已存在相同域名的配置，避免重复添加
        if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
            echo -e "${YELLOW}⚠️ 域名 $MAIN_DOMAIN 已存在配置。请在 '查看与管理' 菜单中编辑或删除。${RESET}"
            continue
        fi

        # 1. 检查域名解析 (同时检查 IPv4 和 IPv6)
        if ! check_domain_ip "$MAIN_DOMAIN" "$VPS_IP" "$VPS_IPV6"; then
            echo -e "${RED}❌ 跳过域名 $MAIN_DOMAIN 的配置和证书申请。${RESET}"
            continue
        fi

        # 2. 验证方式选择
        ACME_VALIDATION_METHOD="http-01"
        DNS_API_PROVIDER=""
        USE_WILDCARD="n"
        
        echo -e "\n请选择验证方式:"
        echo "1) http-01 (通过 80 端口，推荐用于单域名)"
        echo "2) dns-01 (通过 DNS API，推荐用于泛域名或 80 端口不可用时)"
        read -rp "请输入序号: " VALIDATION_CHOICE
        VALIDATION_CHOENCE=${VALIDATION_CHOICE:-1}
        case $VALIDATION_CHOICE in
            1) ACME_VALIDATION_METHOD="http-01";;
            2) 
                ACME_VALIDATION_METHOD="dns-01"
                read -rp "是否申请泛域名证书 (*.$MAIN_DOMAIN)？[y/N]: " WILDCARD_INPUT
                WILDCARD_INPUT=${WILDCARD_INPUT:-n}
                if [[ "$WILDCARD_INPUT" =~ ^[Yy]$ ]]; then
                    USE_WILDCARD="y"
                    echo -e "${YELLOW}⚠️ 泛域名证书必须使用 dns-01 验证方式。${RESET}"
                fi

                echo -e "\n请选择您的 DNS 服务商 (用于 dns-01 验证):"
                echo "1) Cloudflare (dns_cf)"
                echo "2) Aliyun DNS (dns_ali)"
                read -rp "请输入序号: " DNS_PROVIDER_CHOICE
                DNS_PROVIDER_CHOICE=${DNS_PROVIDER_CHOICE:-1}
                case $DNS_PROVIDER_CHOICE in
                    1) 
                        DNS_API_PROVIDER="dns_cf"
                        echo -e "${YELLOW}⚠️ 您选择了 Cloudflare DNS API。请确保在运行脚本前，已设置以下环境变量：${RESET}"
                        echo -e "   export CF_Token=\"YOUR_CLOUDFLARE_API_TOKEN\""
                        echo -e "   export CF_Account_ID=\"YOUR_CLOUDFLARE_ACCOUNT_ID\""
                        echo -e "   参考文档: https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Cloudflare-API"
                        ;;
                    2) 
                        DNS_API_PROVIDER="dns_ali"
                        echo -e "${YELLOW}⚠️ 您选择了 Aliyun DNS API。请确保在运行脚本前，已设置以下环境变量：${RESET}"
                        echo -e "   export Ali_Key=\"YOUR_ALIYUN_ACCESS_KEY_ID\""
                        echo -e "   export Ali_Secret=\"YOUR_ALIYUN_ACCESS_KEY_SECRET\""
                        echo -e "   参考文档: https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Aliyun-Domain-API"
                        ;;
                    *) 
                        echo -e "${RED}❌ 无效的 DNS 服务商选择，将尝试使用 dns_cf。请确保环境变量已设置。${RESET}"
                        DNS_API_PROVIDER="dns_cf"
                        ;;
                esac
                ;;
            *) echo -e "${YELLOW}⚠️ 无效选择，将使用默认 http-01 验证方式。${RESET}";;
        esac # 修正了上一次的esmeac拼写错误
        echo -e "${BLUE}➡️ 选定验证方式: $ACME_VALIDATION_METHOD${RESET}"
        if [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
            echo -e "${BLUE}➡️ 选定 DNS API 服务商: $DNS_API_PROVIDER${RESET}"
            if [ "$USE_WILDCARD" = "y" ]; then
                echo -e "${BLUE}➡️ 申请泛域名证书: *.$MAIN_DOMAIN${RESET}"
            fi
        fi

        # 3. 确定后端代理目标 (优化 Docker 端口选择逻辑)
        PROXY_TARGET_URL=""
        PROJECT_TYPE=""
        PROJECT_DETAIL="" # 存储容器名称或本地端口号
        PORT_TO_USE="" # 实际代理的端口号

        if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$TARGET_INPUT"; then
            echo -e "${GREEN}🔍 识别到 Docker 容器: $TARGET_INPUT${RESET}"
            
            # 尝试获取宿主机映射端口
            HOST_MAPPED_PORT=$(docker inspect "$TARGET_INPUT" --format \
                '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
                sed 's|/tcp||g' | awk '{print $1}' | head -n1)

            if [[ -n "$HOST_MAPPED_PORT" ]]; then
                # 自动使用宿主机映射端口
                echo -e "${GREEN}✅ 检测到容器 $TARGET_INPUT 已映射到宿主机端口: $HOST_MAPPED_PORT。将自动使用此端口。${RESET}"
                PORT_TO_USE="$HOST_MAPPED_PORT"
                PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
                PROJECT_TYPE="docker"
                PROJECT_DETAIL="$TARGET_INPUT" # 存储容器名称
            else
                echo -e "${YELLOW}⚠️ 未检测到容器 $TARGET_INPUT 映射到宿主机的端口。${RESET}"
                
                # 尝试列出容器内部暴露的端口作为建议
                INTERNAL_EXPOSED_PORTS=$(docker inspect "$TARGET_INPUT" --format \
                    '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | \
                    sed 's|/tcp||g' | xargs) # xargs 将端口列表连接成一行

                if [[ -n "$INTERNAL_EXPOSED_PORTS" ]]; then
                    echo -e "${YELLOW}   检测到容器内部暴露的端口有: $INTERNAL_EXPOSED_PORTS。${RESET}"
                else
                    echo -e "${YELLOW}   未检测到容器 $TARGET_INPUT 内部暴露的端口。${RESET}"
                fi

                # 提示用户手动输入内部端口
                while true; do
                    read -rp "请输入要代理到的容器内部端口 (例如 8080): " USER_INTERNAL_PORT
                    if [[ "$USER_INTERNAL_PORT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT > 0 && USER_INTERNAL_PORT < 65536 )); then
                        PORT_TO_USE="$USER_INTERNAL_PORT"
                        PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
                        PROJECT_TYPE="docker"
                        PROJECT_DETAIL="$TARGET_INPUT" # 存储容器名称
                        echo -e "${GREEN}✅ 将代理到容器 $TARGET_INPUT 的内部端口: $PORT_TO_USE。请确保容器监听 0.0.0.0。${RESET}"
                        break
                    else
                        echo -e "${RED}❌ 输入的端口无效。请重新输入一个有效的端口号 (1-65535)。${RESET}"
                    fi
                done
            fi
        elif [[ "$TARGET_INPUT" =~ ^[0-9]+$ ]]; then
            echo -e "${GREEN}🔍 识别到本地端口: $TARGET_INPUT${RESET}"
            PORT_TO_USE="$TARGET_INPUT"
            PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
            PROJECT_TYPE="local_port"
            PROJECT_DETAIL="$TARGET_INPUT" # 存储本地端口号
        else
            echo -e "${RED}❌ 无效的目标格式 '$TARGET_INPUT' (既不是Docker容器名也不是端口号)，跳过域名 $MAIN_DOMAIN。${RESET}"
            continue
        fi

        # 确保证书存储目录存在
        mkdir -p "/etc/ssl/$MAIN_DOMAIN"

        # 4. 自定义 Nginx 配置片段 (带默认路径)
        local CUSTOM_NGINX_SNIPPET_FILE=""
        local DEFAULT_SNIPPET_DIR="/etc/nginx/custom_snippets"
        local DEFAULT_SNIPPET_FILENAME=""

        if [ "$PROJECT_TYPE" = "docker" ]; then
            DEFAULT_SNIPPET_FILENAME="$PROJECT_DETAIL.conf" # 使用容器名作为默认文件名
        else # local_port 或未知类型
            DEFAULT_SNIPPET_FILENAME="$MAIN_DOMAIN.conf" # 使用域名作为默认文件名
        fi
        local DEFAULT_SNIPPET_PATH="$DEFAULT_SNIPPET_DIR/$DEFAULT_SNIPPET_FILENAME"
        
        read -rp "是否为域名 $MAIN_DOMAIN 添加自定义 Nginx 配置片段文件？[y/N]: " ADD_CUSTOM_SNIPPET
        ADD_CUSTOM_SNIPPET=${ADD_CUSTOM_SNIPPET:-n}
        if [[ "$ADD_CUSTOM_SNIPPET" =~ ^[Yy]$ ]]; then
            while true; do
                read -rp "请输入自定义 Nginx 配置片段文件的完整路径 [默认: $DEFAULT_SNIPPET_PATH]: " SNIPPET_PATH_INPUT
                local CHOSEN_SNIPPET_PATH="${SNIPPET_PATH_INPUT:-$DEFAULT_SNIPPET_PATH}" # 如果回车，使用默认路径

                if [[ -z "$CHOSEN_SNIPPET_PATH" ]]; then
                    echo -e "${RED}❌ 文件路径不能为空。${RESET}"
                elif ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH")"; then # 尝试创建父目录
                    echo -e "${RED}❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH")。请检查权限或路径是否有效。${RESET}"
                else
                    CUSTOM_NGINX_SNIPPET_FILE="$CHOSEN_SNIPPET_PATH"
                    echo -e "${YELLOW}ℹ️ 请确保文件 '$CUSTOM_NGINX_SNIPPET_FILE' 包含有效的 Nginx 配置片段。${RESET}"
                    echo -e "${GREEN}✅ 将使用自定义 Nginx 配置片段文件: $CUSTOM_NGINX_SNIPPET_FILE${RESET}"
                    break
                fi
            done
        fi

        # 5. 构建新的项目 JSON 对象并添加到元数据文件
        local NEW_PROJECT_JSON=$(jq -n \
            --arg domain "$MAIN_DOMAIN" \
            --arg type "$PROJECT_TYPE" \
            --arg name "$PROJECT_DETAIL" \
            --arg resolved_port "$PORT_TO_USE" \
            --arg custom_snippet "$CUSTOM_NGINX_SNIPPET_FILE" \
            --arg acme_method "$ACME_VALIDATION_METHOD" \
            --arg dns_provider "$DNS_API_PROVIDER" \
            --arg wildcard "$USE_WILDCARD" \
            --arg ca_url "$ACME_CA_SERVER_URL" \
            --arg ca_name "$ACME_CA_SERVER_NAME" \
            '{domain: $domain, type: $type, name: $name, resolved_port: $resolved_port, custom_snippet: $custom_snippet, acme_validation_method: $acme_method, dns_api_provider: $dns_provider, use_wildcard: $wildcard, ca_server_url: $ca_url, ca_server_name: $ca_name}')
        
        # 将新项目添加到 JSON 文件
        if ! jq ". + [$NEW_PROJECT_JSON]" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            echo -e "${RED}❌ 写入项目元数据失败！请检查 $PROJECTS_METADATA_FILE 文件权限或 JSON 格式。${RESET}"
            continue
        fi
        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
        echo -e "${GREEN}✅ 项目元数据已保存到 $PROJECTS_METADATA_FILE。${RESET}"


        # 6. 生成 Nginx 临时配置（仅当使用 http-01 验证时才需要）
        if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
            echo -e "${YELLOW}生成 Nginx 临时 HTTP 配置以进行证书验证...${RESET}"
            _NGINX_HTTP_CHALLENGE_TEMPLATE "$MAIN_DOMAIN" > "$DOMAIN_CONF"
            
            # 确保软链接存在
            if [ ! -L "/etc/nginx/sites-enabled/$MAIN_DOMAIN.conf" ]; then
                ln -sf "$DOMAIN_CONF" /etc/nginx/sites-enabled/
            fi

            # 重启 Nginx 以应用临时配置
            echo "重启 Nginx 服务以应用临时配置..."
            nginx -t || { echo -e "${RED}❌ Nginx 配置语法错误，请检查！${RESET}"; continue; }
            systemctl restart nginx || { echo -e "${RED}❌ Nginx 启动失败，请检查服务状态！${RESET}"; continue; }
            echo -e "${GREEN}✅ Nginx 已重启，准备申请证书。${RESET}"
        fi

        # 7. 申请证书
        echo -e "${YELLOW}正在为 $MAIN_DOMAIN 申请证书 (CA: $ACME_CA_SERVER_NAME, 验证方式: $ACME_VALIDATION_METHOD)...${RESET}"
        local ACME_ISSUE_CMD_LOG_OUTPUT=$(mktemp) # Capture acme.sh output for error analysis

        ACME_ISSUE_COMMAND="$ACME_BIN --issue -d \"$MAIN_DOMAIN\" --ecc --server \"$ACME_CA_SERVER_URL\" --debug 2"
        if [ "$USE_WILDCARD" = "y" ]; then
            ACME_ISSUE_COMMAND+=" -d \"*.$MAIN_DOMAIN\"" # 如果是泛域名，添加泛域名到 issue 命令
        fi

        if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
            ACME_ISSUE_COMMAND+=" -w /var/www/html"
        elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
            ACME_ISSUE_COMMAND+=" --dns $DNS_API_PROVIDER"
        fi

        # Execute acme.sh command and capture output
        if ! eval "$ACME_ISSUE_COMMAND" > "$ACME_ISSUE_CMD_LOG_OUTPUT" 2>&1; then
            echo -e "${RED}❌ 域名 $MAIN_DOMAIN 的证书申请失败！${RESET}"
            cat "$ACME_ISSUE_CMD_LOG_OUTPUT"
            analyze_acme_error "$(cat "$ACME_ISSUE_CMD_LOG_OUTPUT")" # Analyze error
            rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"

            # 清理可能残留的临时配置和元数据
            rm -f "$DOMAIN_CONF"
            rm -f "/etc/nginx/sites-enabled/$MAIN_DOMAIN.conf"
            rm -rf "/etc/ssl/$MAIN_DOMAIN" # 删除证书目录和元数据
            # 如果指定了自定义片段文件，也尝试删除
            if [[ -n "$CUSTOM_NGINX_SNIPPET_FILE" ]]; then
                echo -e "${YELLOW}⚠️ 证书申请失败，删除自定义 Nginx 片段文件: $CUSTOM_NGINX_SNIPPET_FILE${RESET}"
                rm -f "$CUSTOM_NGINX_SNIPPET_FILE"
            fi
            # 从 JSON 元数据中移除此项目
            if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
                echo -e "${YELLOW}⚠️ 从元数据中移除失败的项目 $MAIN_DOMAIN。${RESET}"
                jq "del(.[] | select(.domain == \"$MAIN_DOMAIN\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp" && \
                mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
            fi
            continue # 尝试处理下一个域名
        fi
        rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"
        
        # 证书安装目标文件
        INSTALLED_CRT_FILE="/etc/ssl/$MAIN_DOMAIN.cer"
        INSTALLED_KEY_FILE="/etc/ssl/$MAIN_DOMAIN.key"

        echo -e "${GREEN}✅ 证书已成功签发，正在安装并更新 Nginx 配置...${RESET}"

        # 8. 安装证书并生成最终的 Nginx 配置
        # acme.sh --install-cert 命令在安装泛域名时也需要 -d "wildcard.domain"
        INSTALL_CERT_DOMAINS="-d \"$MAIN_DOMAIN\""
        if [ "$USE_WILDCARD" = "y" ]; then
            INSTALL_CERT_DOMAINS+=" -d \"*.$MAIN_DOMAIN\""
        fi

        "$ACME_BIN" --install-cert $INSTALL_CERT_DOMAINS --ecc \
            --key-file       "$INSTALLED_KEY_FILE" \
            --fullchain-file "$INSTALLED_CRT_FILE" \
            --reloadcmd      "systemctl reload nginx" # acme.sh 会在证书安装后自动执行 reload

        # 生成最终的 Nginx 配置 (HTTP redirect + HTTPS proxy)
        echo -e "${YELLOW}生成 $MAIN_DOMAIN 的最终 Nginx 配置...${RESET}"
        _NGINX_FINAL_TEMPLATE "$MAIN_DOMAIN" "$PROXY_TARGET_URL" "$INSTALLED_CRT_FILE" "$INSTALLED_KEY_FILE" "$CUSTOM_NGINX_SNIPPET_FILE" > "$DOMAIN_CONF"
        
        echo -e "${GREEN}✅ 域名 $MAIN_DOMAIN 的 Nginx 配置已更新。${RESET}"

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

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE")" -eq 0 ]; then
        echo -e "${YELLOW}未找到任何已配置的项目。${RESET}"
        echo "=============================================="
        return 0
    fi

    CONFIGURED_DOMAINS=() # Initialize in main shell context
    # Populate CONFIGURED_DOMAINS in the main shell context
    while IFS= read -r domain_name; do
        CONFIGURED_DOMAINS+=("$domain_name")
    done < <(jq -r '.[] | .domain' "$PROJECTS_METADATA_FILE")


    local PROJECTS_ARRAY_RAW=$(jq -c . "$PROJECTS_METADATA_FILE")
    local INDEX=0
    
    # Header for the table
    printf "${BLUE}%-4s | %-25s | %-8s | %-20s | %-10s | %-15s | %-4s | %-5s | %3s天 | %s${RESET}\n" \
        "ID" "域名" "类型" "目标" "片段" "验证" "泛域" "状态" "剩余" "到期时间"
    echo -e "${BLUE}------------------------------------------------------------------------------------------------------------------------------------${RESET}"

    # Use jq to iterate over the array
    echo "$PROJECTS_ARRAY_RAW" | jq -c '.[]' | while read -r project_json; do
        INDEX=$((INDEX + 1))
        local DOMAIN=$(echo "$project_json" | jq -r '.domain')
        local PROJECT_TYPE=$(echo "$project_json" | jq -r '.type')
        local PROJECT_NAME=$(echo "$project_json" | jq -r '.name')
        local RESOLVED_PORT=$(echo "$project_json" | jq -r '.resolved_port')
        local CUSTOM_SNIPPET=$(echo "$project_json" | jq -r '.custom_snippet')
        local ACME_VALIDATION_METHOD=$(echo "$project_json" | jq -r '.acme_validation_method')
        local DNS_API_PROVIDER=$(echo "$project_json" | jq -r '.dns_api_provider')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard')

        # Format display strings
        local PROJECT_TYPE_DISPLAY="$PROJECT_TYPE"
        local PROJECT_DETAIL_DISPLAY=""
        if [ "$PROJECT_TYPE" = "docker" ]; then
            PROJECT_DETAIL_DISPLAY="$PROJECT_NAME (端口: $RESOLVED_PORT)"
        elif [ "$PROJECT_TYPE" = "local_port" ]; then
            PROJECT_DETAIL_DISPLAY="$RESOLVED_PORT"
        else
            PROJECT_DETAIL_DISPLAY="未知"
        fi
        
        local CUSTOM_SNIPPET_FILE_DISPLAY="无"
        if [[ -n "$CUSTOM_SNIPPET" && "$CUSTOM_SNIPPET" != "null" ]]; then # Check for "null" if jq outputs it
            CUSTOM_SNIPPET_FILE_DISPLAY="是 ($(basename "$CUSTOM_SNIPPET"))"
        fi
        
        local ACME_METHOD_DISPLAY="$ACME_VALIDATION_METHOD"
        if [[ "$ACME_VALIDATION_METHOD" = "dns-01" && -n "$DNS_API_PROVIDER" && "$DNS_API_PROVIDER" != "null" ]]; then
            ACME_METHOD_DISPLAY+=" ($DNS_API_PROVIDER)"
        fi
        local WILDCARD_DISPLAY="$([ "$USE_WILDCARD" = "y" ] && echo "是" || echo "否")"

        # Get certificate info
        local INSTALLED_CRT_FILE="/etc/ssl/$DOMAIN.cer"
        local INSTALLED_KEY_FILE="/etc/ssl/$DOMAIN.key"
        local STATUS_COLOR="$RED"
        local STATUS_TEXT="缺失"
        local LEFT_DAYS="N/A"
        local FORMATTED_END_DATE="N/A"
            
        if [[ -f "$INSTALLED_CRT_FILE" && -f "$INSTALLED_KEY_FILE" ]]; then
            local END_DATE=$(openssl x509 -enddate -noout -in "$INSTALLED_CRT_FILE" 2>/dev/null | cut -d= -f2)
            
            local END_TS=0
            if date --version >/dev/null 2>&1; then # GNU date
                END_TS=$(date -d "$END_DATE" +%s 2>/dev/null)
                FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y年%m月%d日" 2>/dev/null)
            else # BSD date (macOS)
                END_TS=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%s" 2>/dev/null)
                FORMATTED_END_DATE=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null)
                if [[ -z "$FORMATTED_END_DATE" ]]; then
                    END_TS=$(date -j -f "%b %e %T %Y %Z" "$END_DATE" "+%s" 2>/dev/null)
                    FORMATTED_END_DATE=$(date -j -f "%b %e %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null)
                fi
            fi
            FORMATTED_END_DATE="${FORMATTED_END_DATE:-未知日期}"
            END_TS=${END_TS:-0}

            local NOW_TS=$(date +%s)
            LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))

            if (( LEFT_DAYS < 0 )); then
                STATUS_COLOR="$RED"
                STATUS_TEXT="已过期"
            elif (( LEFT_DAYS <= RENEW_THRESHOLD_DAYS )); then
                STATUS_COLOR="$YELLOW"
                STATUS_TEXT="即将到期"
            else
                STATUS_COLOR="$GREEN"
                STATUS_TEXT="有效"
            fi
        fi

        printf "${MAGENTA}%-4s${RESET} | %-25s | %-8s | %-20s | %-10s | %-15s | %-4s | ${STATUS_COLOR}%-5s${RESET} | %3s天 | %s\n" \
            "$INDEX" "$DOMAIN" "$PROJECT_TYPE_DISPLAY" "$PROJECT_DETAIL_DISPLAY" "$CUSTOM_SNIPPET_FILE_DISPLAY" "$ACME_METHOD_DISPLAY" "$WILDCARD_DISPLAY" "$STATUS_TEXT" "$LEFT_DAYS" "$FORMATTED_END_DATE"
    done

    echo "=============================================="

    # 管理选项子菜单
    while true; do
        echo -e "\n${BLUE}请选择管理操作：${RESET}"
        echo "1. 手动续期指定域名证书"
        echo "2. 删除指定域名配置及证书"
        echo "3. 编辑项目核心配置 (后端目标 / 验证方式等)"
        echo "4. 管理自定义 Nginx 配置片段 (添加 / 修改 / 清除)"
        echo "0. 返回主菜单"
        read -rp "请输入选项: " MANAGE_
