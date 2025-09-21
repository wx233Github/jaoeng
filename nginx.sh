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
#   - **核心改进**: 项目配置集中存储在 `/etc/nginx/projects.json` 中。
#   - 提供菜单，方便查看所有已配置项目的详情（域名、类型、目标、证书状态、到期时间等）。
#   - **新增**: 提供“编辑项目”功能，可修改后端目标、验证方式等。
#   - **新增**: 提供“管理自定义 Nginx 配置片段”功能。
#   - **新增**: 提供“导入现有 Nginx 配置到本脚本管理”功能。
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

# --- 脚本集成支持 ---
# 检查是否作为子脚本被调用
IS_NESTED_CALL="${IS_NESTED_CALL:-false}"

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
PROJECTS_METADATA_FILE="/etc/nginx/projects.json" # <-- 修改点：元数据文件路径已更改
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
        VALIDATION_CHOICE=${VALIDATION_CHOICE:-1}
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
        esac
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

        # --- 新增证书存在性检测逻辑 ---
        local INSTALLED_CRT_FILE="/etc/ssl/$MAIN_DOMAIN.cer"
        local INSTALLED_KEY_FILE="/etc/ssl/$MAIN_DOMAIN.key"
        local SHOULD_ISSUE_CERT="y" # 默认申请证书

        if [[ -f "$INSTALLED_CRT_FILE" && -f "$INSTALLED_KEY_FILE" ]]; then
            local EXISTING_END_DATE=$(openssl x509 -enddate -noout -in "$INSTALLED_CRT_FILE" 2>/dev/null | cut -d= -f2 || echo "未知日期")
            local EXISTING_END_TS=$(date -d "$EXISTING_END_DATE" +%s 2>/dev/null || echo 0)
            local NOW_TS=$(date +%s)
            local EXISTING_LEFT_DAYS=$(( (EXISTING_END_TS - NOW_TS) / 86400 ))

            echo -e "${YELLOW}⚠️ 域名 $MAIN_DOMAIN 已存在有效期至 ${EXISTING_END_DATE} 的证书 ($EXISTING_LEFT_DAYS 天剩余)。${RESET}"
            echo -e "您想："
            echo "1) 重新申请/续期证书 (推荐更新过期或即将过期的证书) [默认]"
            echo "2) 使用现有证书 (跳过证书申请步骤)"
            read -rp "请输入选项 [1]: " CERT_ACTION_CHOICE
            CERT_ACTION_CHOICE=${CERT_ACTION_CHOICE:-1}

            if [ "$CERT_ACTION_CHOICE" == "2" ]; then
                SHOULD_ISSUE_CERT="n"
                echo -e "${GREEN}✅ 已选择使用现有证书。${RESET}"
            else
                echo -e "${YELLOW}ℹ️ 将重新申请/续期证书。${RESET}"
            fi
        fi
        # --- 证书存在性检测逻辑结束 ---

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
            --arg cert_file "$INSTALLED_CRT_FILE" \
            --arg key_file "$INSTALLED_KEY_FILE" \
            '{domain: $domain, type: $type, name: $name, resolved_port: $resolved_port, custom_snippet: $custom_snippet, acme_validation_method: $acme_method, dns_api_provider: $dns_provider, use_wildcard: $wildcard, ca_server_url: $ca_url, ca_server_name: $ca_name, cert_file: $cert_file, key_file: $key_file}')
        
        # 将新项目添加到 JSON 文件
        if ! jq ". + [$NEW_PROJECT_JSON]" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            echo -e "${RED}❌ 写入项目元数据失败！请检查 $PROJECTS_METADATA_FILE 文件权限或 JSON 格式。${RESET}"
            continue
        fi
        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
        echo -e "${GREEN}✅ 项目元数据已保存到 $PROJECTS_METADATA_FILE。${RESET}"


        # 6. 生成 Nginx 临时配置（仅当使用 http-01 验证且需要申请证书时才需要）
        if [ "$SHOULD_ISSUE_CERT" = "y" ] && [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
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

        # 7. 申请证书 (如果用户选择重新申请)
        if [ "$SHOULD_ISSUE_CERT" = "y" ]; then
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
                rm -rf "/etc/ssl/$MAIN_DOMAIN" # 删除证书目录和元数据 (注意：现在cert_file和key_file在json里，这里可能要更精确删除)
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
            
            # 证书安装目标文件 (从 JSON 读取，确保与创建时一致)
            # acme.sh --install-cert 应该知道如何找到正确的 ECC 证书
            # 这里 INSTALLED_CRT_FILE 和 INSTALLED_KEY_FILE 已经预设为 /etc/ssl/$MAIN_DOMAIN.cer 和 .key
            # acme.sh 会将生成的证书复制到这些位置
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
        else
            echo -e "${YELLOW}ℹ️ 未进行证书申请或续期，将使用现有证书。${RESET}"
        fi

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
# 导入现有 Nginx 配置到本脚本管理
import_existing_project() {
    check_root
    echo "=============================================="
    echo "📥 导入现有 Nginx 配置到本脚本管理"
    echo "=============================================="

    read -rp "请输入要导入的主域名 (例如 example.com): " IMPORT_DOMAIN
    [[ -z "$IMPORT_DOMAIN" ]] && { echo -e "${RED}❌ 域名不能为空！${RESET}"; return 1; }

    local EXISTING_NGINX_CONF_PATH="/etc/nginx/sites-available/$IMPORT_DOMAIN.conf"
    if [ ! -f "$EXISTING_NGINX_CONF_PATH" ]; then
        echo -e "${RED}❌ 域名 $IMPORT_DOMAIN 的 Nginx 配置文件 $EXISTING_NGINX_CONF_PATH 不存在。请确认路径和文件名。${RESET}"
        return 1
    fi
    echo -e "${GREEN}✅ 找到域名 $IMPORT_DOMAIN 的 Nginx 配置文件: $EXISTING_NGINX_CONF_PATH${RESET}"

    # 检查是否已存在相同域名的配置，避免重复添加
    local EXISTING_JSON_ENTRY=$(jq -c ".[] | select(.domain == \"$IMPORT_DOMAIN\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
    if [[ -n "$EXISTING_JSON_ENTRY" ]]; then
        echo -e "${YELLOW}⚠️ 域名 $IMPORT_DOMAIN 已存在于本脚本的管理列表中。${RESET}"
        read -rp "是否要覆盖现有项目元数据？[y/N]: " OVERWRITE_CONFIRM
        OVERWRITE_CONFIRM=${OVERWRITE_CONFIRM:-n}
        if [[ ! "$OVERWRITE_CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "${RED}❌ 已取消导入操作。${RESET}"
            return 1
        fi
        echo -e "${YELLOW}ℹ️ 将覆盖域名 $IMPORT_DOMAIN 的现有项目元数据。${RESET}"
    fi

    local PROXY_TARGET_URL_GUESS=""
    local PROJECT_TYPE_GUESS="unknown" # 默认改为 unknown
    local PROJECT_DETAIL_GUESS="unknown"
    local PORT_TO_USE_GUESS="unknown"

    # 尝试从 Nginx 配置中解析 proxy_pass
    local PROXY_PASS_LINE=$(grep -E '^\s*proxy_pass\s+http://' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*proxy_pass\s+//;s/;//' || echo "")
    if [[ -n "$PROXY_PASS_LINE" ]]; then
        PROXY_TARGET_URL_GUESS="$PROXY_PASS_LINE"
        local TARGET_HOST_PORT=$(echo "$PROXY_PASS_LINE" | sed -E 's/http:\/\/(.*)/\1/' | sed 's|/.*||' || echo "") # Extract host:port or host
        local TARGET_HOST=$(echo "$TARGET_HOST_PORT" | cut -d: -f1 || echo "")
        local TARGET_PORT=$(echo "$TARGET_HOST_PORT" | cut -d: -f2 || echo "")

        if [[ "$TARGET_HOST" == "127.0.0.1" || "$TARGET_HOST" == "localhost" ]]; then
            PROJECT_TYPE_GUESS="local_port"
            PROJECT_DETAIL_GUESS="$TARGET_PORT"
            PORT_TO_USE_GUESS="$TARGET_PORT"
        else
            if "$DOCKER_INSTALLED" = true && [[ -n "$TARGET_HOST" ]] && docker ps --format '{{.Names}}' | grep -wq "$TARGET_HOST"; then
                 PROJECT_TYPE_GUESS="docker"
                 PROJECT_DETAIL_GUESS="$TARGET_HOST"
                 PORT_TO_USE_GUESS="$TARGET_PORT"
            else
                 PROJECT_TYPE_GUESS="custom_host" # 代理到其他主机或无法识别
                 PROJECT_DETAIL_GUESS="$TARGET_HOST_PORT"
                 PORT_TO_USE_GUESS="$TARGET_PORT"
            fi
        fi
        echo -e "${GREEN}✅ 从 Nginx 配置中解析到代理目标: ${PROXY_TARGET_URL_GUESS}${RESET}"
    else
        echo -e "${YELLOW}⚠️ 未能从 Nginx 配置中自动解析到 proxy_pass 目标。${RESET}"
    fi

    # 提示用户确认或修改解析到的目标
    echo -e "\n请确认或输入后端代理目标信息 (例如：docker容器名 或 本地端口):"
    echo -e "  [当前解析/建议值: ${PROJECT_DETAIL_GUESS} (类型: ${PROJECT_TYPE_GUESS}, 端口: ${PORT_TO_USE_GUESS})]"
    read -rp "输入目标（回车不修改）: " USER_TARGET_INPUT
    
    local FINAL_PROJECT_TYPE="$PROJECT_TYPE_GUESS"
    local FINAL_PROJECT_NAME="$PROJECT_DETAIL_GUESS"
    local FINAL_RESOLVED_PORT="$PORT_TO_USE_GUESS"
    local FINAL_PROXY_TARGET_URL="$PROXY_TARGET_URL_GUESS" # Default to parsed if no user input

    if [[ -n "$USER_TARGET_INPUT" ]]; then
        if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$USER_TARGET_INPUT"; then
            FINAL_PROJECT_NAME="$USER_TARGET_INPUT"
            FINAL_PROJECT_TYPE="docker"
            # 尝试获取宿主机映射端口
            local HOST_MAPPED_PORT=$(docker inspect "$USER_TARGET_INPUT" --format \
                '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
                sed 's|/tcp||g' | awk '{print $1}' | head -n1 || echo "")
            if [[ -n "$HOST_MAPPED_PORT" ]]; then
                FINAL_RESOLVED_PORT="$HOST_MAPPED_PORT"
                FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
            else
                 # 提示用户输入容器内部端口
                local INTERNAL_EXPOSED_PORTS=$(docker inspect "$USER_TARGET_INPUT" --format \
                    '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | \
                    sed 's|/tcp||g' | xargs || echo "")
                echo -e "${YELLOW}⚠️ 未检测到容器 $USER_TARGET_INPUT 映射到宿主机的端口。内部暴露端口: $INTERNAL_EXPOSED_PORTS。${RESET}"
                while true; do
                    read -rp "请输入要代理到的容器内部端口 (例如 8080): " USER_INTERNAL_PORT_IMPORT
                    if [[ "$USER_INTERNAL_PORT_IMPORT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT_IMPORT > 0 && USER_INTERNAL_PORT_IMPORT < 65536 )); then
                        FINAL_RESOLVED_PORT="$USER_INTERNAL_PORT_IMPORT"
                        FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
                        break
                    else
                        echo -e "${RED}❌ 输入的端口无效。请重新输入一个有效的端口号 (1-65535)。${RESET}"
                    fi
                done
            fi
        elif [[ "$USER_TARGET_INPUT" =~ ^[0-9]+$ ]]; then
            FINAL_PROJECT_NAME="$USER_TARGET_INPUT"
            FINAL_PROJECT_TYPE="local_port"
            FINAL_RESOLVED_PORT="$USER_TARGET_INPUT"
            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
        else
            echo -e "${RED}❌ 无效的后端目标输入。将使用解析到的默认值 (如果存在)。${RESET}"
        fi
    fi

    # 询问证书路径 (假设证书已存在，否则提示用户)
    local DEFAULT_CRT_PATH="/etc/ssl/$IMPORT_DOMAIN.cer"
    local DEFAULT_KEY_PATH="/etc/ssl/$IMPORT_DOMAIN.key"
    local SSL_CRT_PATH=$(grep -E '^\s*ssl_certificate\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate\s+//;s/;//' || echo "")
    local SSL_KEY_PATH=$(grep -E '^\s*ssl_certificate_key\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate_key\s+//;s/;//' || echo "")

    read -rp "请输入证书文件 (fullchain) 路径 [默认解析值: ${SSL_CRT_PATH:-$DEFAULT_CRT_PATH}，回车不修改]: " USER_CRT_PATH
    USER_CRT_PATH=${USER_CRT_PATH:-"${SSL_CRT_PATH:-$DEFAULT_CRT_PATH}"}
    if [ ! -f "$USER_CRT_PATH" ]; then
        echo -e "${YELLOW}⚠️ 证书文件 $USER_CRT_PATH 不存在。请确保路径正确，否则后续续期可能失败。${RESET}"
    fi

    read -rp "请输入证书私钥文件路径 [默认解析值: ${SSL_KEY_PATH:-$DEFAULT_KEY_PATH}，回车不修改]: " USER_KEY_PATH
    USER_KEY_PATH=${USER_KEY_PATH:-"${SSL_KEY_PATH:-$DEFAULT_KEY_PATH}"}
    if [ ! -f "$USER_KEY_PATH" ]; then
        echo -e "${YELLOW}⚠️ 证书私钥文件 $USER_KEY_PATH 不存在。请确保路径正确，否则后续续期可能失败。${RESET}"
    fi
    
    # 询问自定义 Nginx 片段路径
    local DEFAULT_SNIPPET_DIR="/etc/nginx/custom_snippets"
    local DEFAULT_SNIPPET_FILENAME=""
    if [ "$FINAL_PROJECT_TYPE" = "docker" ]; then
        DEFAULT_SNIPPET_FILENAME="$FINAL_PROJECT_NAME.conf"
    else # local_port or custom_host or unknown
        DEFAULT_SNIPPET_FILENAME="$IMPORT_DOMAIN.conf"
    fi
    local DEFAULT_SNIPPET_PATH="$DEFAULT_SNIPPET_DIR/$DEFAULT_SNIPPET_FILENAME"

    local IMPORTED_CUSTOM_SNIPPET=""
    read -rp "是否已有自定义 Nginx 配置片段文件？[y/N]: " HAS_CUSTOM_SNIPPET_IMPORT
    HAS_CUSTOM_SNIPPET_IMPORT=${HAS_CUSTOM_SNIPPET_IMPORT:-n}
    if [[ "$HAS_CUSTOM_SNIPPET_IMPORT" =~ ^[Yy]$ ]]; then
        read -rp "请输入自定义 Nginx 配置片段文件的完整路径 [默认: $DEFAULT_SNIPPET_PATH]: " SNIPPET_PATH_INPUT_IMPORT
        IMPORTED_CUSTOM_SNIPPET="${SNIPPET_PATH_INPUT_IMPORT:-$DEFAULT_SNIPPET_PATH}"
        if [ ! -f "$IMPORTED_CUSTOM_SNIPPET" ]; then
            echo -e "${YELLOW}⚠️ 自定义片段文件 $IMPORTED_CUSTOM_SNIPPET 不存在。请确保路径正确。${RESET}"
        fi
    fi

    # 证书的 CA, 验证方式等信息无法从 Nginx 配置中直接获取，将其标记为 'imported' 或 'unknown'
    local IMPORTED_ACME_METHOD="imported"
    local IMPORTED_DNS_PROVIDER="none"
    local IMPORTED_WILDCARD="n" # 无法自动判断，需要用户手动配置
    local IMPORTED_CA_URL="unknown"
    local IMPORTED_CA_NAME="imported"

    # 构建新的项目 JSON 对象
    local NEW_PROJECT_JSON=$(jq -n \
        --arg domain "$IMPORT_DOMAIN" \
        --arg type "$FINAL_PROJECT_TYPE" \
        --arg name "$FINAL_PROJECT_NAME" \
        --arg resolved_port "$FINAL_RESOLVED_PORT" \
        --arg custom_snippet "$IMPORTED_CUSTOM_SNIPPET" \
        --arg acme_method "$IMPORTED_ACME_METHOD" \
        --arg dns_provider "$IMPORTED_DNS_PROVIDER" \
        --arg wildcard "$IMPORTED_WILDCARD" \
        --arg ca_url "$IMPORTED_CA_URL" \
        --arg ca_name "$IMPORTED_CA_NAME" \
        --arg cert_file "$USER_CRT_PATH" \
        --arg key_file "$USER_KEY_PATH" \
        '{domain: $domain, type: $type, name: $name, resolved_port: $resolved_port, custom_snippet: $custom_snippet, acme_validation_method: $acme_method, dns_api_provider: $dns_provider, use_wildcard: $wildcard, ca_server_url: $ca_url, ca_server_name: $ca_name, cert_file: $cert_file, key_file: $key_file}')
    
    # 将新项目添加到 JSON 文件 (如果存在则覆盖，否则添加)
    if [[ -n "$EXISTING_JSON_ENTRY" ]]; then
        # Update existing entry
        if ! jq "(.[] | select(.domain == \"$IMPORT_DOMAIN\")) = $NEW_PROJECT_JSON" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            echo -e "${RED}❌ 更新项目元数据失败！${RESET}"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    else
        # Add new entry
        if ! jq ". + [$NEW_PROJECT_JSON]" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            echo -e "${RED}❌ 写入项目元数据失败！${RESET}"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    fi

    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
    echo -e "${GREEN}✅ 域名 $IMPORT_DOMAIN 的 Nginx 配置已成功导入到脚本管理列表。${RESET}"
    echo -e "${YELLOW}ℹ️ 注意：导入的项目，其证书签发机构和验证方式被标记为 'imported'/'unknown'。${RESET}"
    echo -e "${YELLOW}   如果您希望由本脚本的 acme.sh 自动续期，请手动选择 '编辑项目核心配置'，并设置正确的验证方式，然后重新申请证书。${RESET}"

    echo "=============================================="
    return 0
}

# -----------------------------
# 查看和管理已配置项目的函数
manage_configs() {
    check_root
    echo "=============================================="
    echo "📜 已配置项目列表及证书状态"
    echo "=============================================="

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}未找到任何已配置的项目。${RESET}"
        echo "=============================================="
        # 如果没有项目，仍然提供导入选项
        read -rp "没有找到已配置项目。是否立即导入一个现有 Nginx 配置？[y/N]: " IMPORT_NOW
        IMPORT_NOW=${IMPORT_NOW:-n}
        if [[ "$IMPORT_NOW" =~ ^[Yy]$ ]]; then
            import_existing_project
            # 导入后返回 manage_configs 顶层，重新显示列表
            return 0
        else
            return 0
        fi
    fi

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
        local CERT_FILE=$(echo "$project_json" | jq -r '.cert_file // "/etc/ssl/'"$DOMAIN"'.cer"') # Use stored cert_file, fallback for old
        local KEY_FILE=$(echo "$project_json" | jq -r '.key_file // "/etc/ssl/'"$DOMAIN"'.key"')   # Use stored key_file, fallback for old

        # Format display strings
        local PROJECT_TYPE_DISPLAY="$PROJECT_TYPE"
        local PROJECT_DETAIL_DISPLAY=""
        if [ "$PROJECT_TYPE" = "docker" ]; then
            PROJECT_DETAIL_DISPLAY="$PROJECT_NAME (端口: $RESOLVED_PORT)"
        elif [ "$PROJECT_TYPE" = "local_port" ]; then
            PROJECT_DETAIL_DISPLAY="$RESOLVED_PORT"
        elif [ "$PROJECT_TYPE" = "custom_host" ]; then 
            PROJECT_DETAIL_DISPLAY="$PROJECT_NAME (端口: $RESOLVED_PORT)"
        else
            PROJECT_DETAIL_DISPLAY="未知"
        fi
        
        local CUSTOM_SNIPPET_FILE_DISPLAY="无"
        if [[ -n "$CUSTOM_SNIPPET" && "$CUSTOM_SNIPPET" != "null" ]]; then 
            CUSTOM_SNIPPET_FILE_DISPLAY="是 ($(basename "$CUSTOM_SNIPPET"))"
        fi
        
        local ACME_METHOD_DISPLAY="$ACME_VALIDATION_METHOD"
        if [[ "$ACME_VALIDATION_METHOD" = "dns-01" && -n "$DNS_API_PROVIDER" && "$DNS_API_PROVIDER" != "null" ]]; then
            ACME_METHOD_DISPLAY+=" ($DNS_API_PROVIDER)"
        elif [[ "$ACME_VALIDATION_METHOD" = "imported" ]]; then 
            ACME_METHOD_DISPLAY="导入"
        fi
        local WILDCARD_DISPLAY="$([ "$USE_WILDCARD" = "y" ] && echo "是" || echo "否")"

        # Get certificate info
        local STATUS_COLOR="$RED"
        local STATUS_TEXT="缺失"
        local LEFT_DAYS="N/A"
        local FORMATTED_END_DATE="N/A"
            
        if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then 
            local END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
            
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

        printf "${MAGENTA}%-4s | %-25s | %-8s | %-20s | %-10s | %-15s | %-4s | ${STATUS_COLOR}%-5s${RESET} | %3s天 | %s\n" \
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
        echo "5. 导入现有 Nginx 配置到本脚本管理" # 新增选项
        echo "0. 返回主菜单"
        read -rp "请输入选项: " MANAGE_CHOICE
        case "$MANAGE_CHOICE" in
            1) # 手动续期
                read -rp "请输入要续期的域名: " DOMAIN_TO_RENEW
                if [[ -z "$DOMAIN_TO_RENEW" ]]; then
                    echo -e "${RED}❌ 域名不能为空！${RESET}"
                    continue
                fi
                local RENEW_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_RENEW\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$RENEW_PROJECT_JSON" ]; then
                    echo -e "${RED}❌ 域名 $DOMAIN_TO_RENEW 未找到在已配置列表中。${RESET}"
                    continue
                fi
                
                local RENEW_ACME_VALIDATION_METHOD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.acme_validation_method')
                local RENEW_DNS_API_PROVIDER=$(echo "$RENEW_PROJECT_JSON" | jq -r '.dns_api_provider')
                local RENEW_USE_WILDCARD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.use_wildcard')
                local RENEW_CA_SERVER_URL=$(echo "$RENEW_PROJECT_JSON" | jq -r '.ca_server_url')

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "imported" ]; then 
                    echo -e "${YELLOW}ℹ️ 域名 $DOMAIN_TO_RENEW 的证书是导入的，本脚本无法直接续期。请手动或通过 '编辑项目核心配置' 转换为 acme.sh 管理。${RESET}"
                    continue
                fi

                echo -e "${GREEN}🚀 正在为 $DOMAIN_TO_RENEW 续期证书 (验证方式: ${RENEW_ACME_VALIDATION_METHOD})...${RESET}"
                local RENEW_CMD_LOG_OUTPUT=$(mktemp)

                local RENEW_COMMAND="$ACME_BIN --renew -d \"$DOMAIN_TO_RENEW\" --force --ecc --server \"$RENEW_CA_SERVER_URL\""
                if [ "$RENEW_USE_WILDCARD" = "y" ]; then
                    RENEW_COMMAND+=" -d \"*.$DOMAIN_TO_RENEW\""
                fi

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                    RENEW_COMMAND+=" -w /var/www/html"
                elif [ "$RENEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                    RENEW_COMMAND+=" --dns $RENEW_DNS_API_PROVIDER"
                    echo -e "${YELLOW}⚠️ 续期 DNS 验证证书需要设置相应的 DNS API 环境变量。${RESET}"
                fi

                if ! eval "$RENEW_COMMAND" > "$RENEW_CMD_LOG_OUTPUT" 2>&1; then
                    echo -e "${RED}❌ 续期失败：$DOMAIN_TO_RENEW。${RESET}"
                    cat "$RENEW_CMD_LOG_OUTPUT"
                    analyze_acme_error "$(cat "$RENEW_CMD_LOG_OUTPUT")"
                    rm -f "$RENEW_CMD_LOG_OUTPUT"
                    continue
                fi
                rm -f "$RENEW_CMD_LOG_OUTPUT"

                echo -e "${GREEN}✅ 续期完成：$DOMAIN_TO_RENEW ${RESET}"
                systemctl reload nginx # 续期后重载Nginx
                ;;
            2) # 删除
                read -rp "请输入要删除的域名: " DOMAIN_TO_DELETE
                if [[ -z "$DOMAIN_TO_DELETE" ]]; then
                    echo -e "${RED}❌ 域名不能为空！${RESET}"
                    continue
                fi
                local PROJECT_TO_DELETE_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_DELETE\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$PROJECT_TO_DELETE_JSON" ]; then
                    echo -e "${RED}❌ 域名 $DOMAIN_TO_DELETE 未找到在已配置列表中。${RESET}"
                    continue
                fi
                read -rp "⚠️ 确认删除域名 ${DOMAIN_TO_DELETE} 的所有 Nginx 配置和证书？此操作不可恢复！[y/N]: " CONFIRM_DELETE
                CONFIRM_DELETE=${CONFIRM_DELETE:-n}
                if [[ "$CONFIRM_DELETE" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}正在删除 ${DOMAIN_TO_DELETE}...${RESET}"
                    
                    # 获取自定义片段路径 (如果存在)
                    local CUSTOM_SNIPPET_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.custom_snippet')
                    local CERT_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.cert_file // "/etc/ssl/'"$DOMAIN_TO_DELETE"'.cer"') 
                    local KEY_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.key_file // "/etc/ssl/'"$DOMAIN_TO_DELETE"'.key"')   

                    # 尝试从 acme.sh 移除，即使是导入的，也不影响 acme.sh 自身的管理
                    "$ACME_BIN" --remove -d "$DOMAIN_TO_DELETE" --ecc 2>/dev/null || true 
                    
                    rm -f "/etc/nginx/sites-available/$DOMAIN_TO_DELETE.conf"
                    rm -f "/etc/nginx/sites-enabled/$DOMAIN_TO_DELETE.conf"
                    
                    # 删除证书文件，只有在证书文件路径是脚本默认创建时才尝试删除
                    if [[ "$CERT_FILE_TO_DELETE" == "/etc/ssl/$DOMAIN_TO_DELETE.cer" && "$KEY_FILE_TO_DELETE" == "/etc/ssl/$DOMAIN_TO_DELETE.key" ]]; then
                        if [ -f "$CERT_FILE_TO_DELETE" ]; then rm -f "$CERT_FILE_TO_DELETE"; fi
                        if [ -f "$KEY_FILE_TO_DELETE" ]; then rm -f "$KEY_FILE_TO_DELETE"; fi
                        # 如果 /etc/ssl/$DOMAIN_TO_DELETE 目录存在且为空，则删除
                        if [ -d "/etc/ssl/$DOMAIN_TO_DELETE" ] && [ -z "$(ls -A "/etc/ssl/$DOMAIN_TO_DELETE")" ]; then
                             rmdir "/etc/ssl/$DOMAIN_TO_DELETE"
                             echo -e "${GREEN}✅ 已删除默认证书目录 /etc/ssl/$DOMAIN_TO_DELETE${RESET}"
                        fi
                    else # 如果是自定义路径的证书文件
                        if [ -f "$CERT_FILE_TO_DELETE" ]; then rm -f "$CERT_FILE_TO_DELETE"; fi
                        if [ -f "$KEY_FILE_TO_DELETE" ]; then rm -f "$KEY_FILE_TO_DELETE"; fi
                        echo -e "${GREEN}✅ 已删除证书文件: $CERT_FILE_TO_DELETE 和 $KEY_FILE_TO_DELETE${RESET}"
                    fi

                    if [[ -n "$CUSTOM_SNIPPET_FILE_TO_DELETE" && "$CUSTOM_SNIPPET_FILE_TO_DELETE" != "null" && -f "$CUSTOM_SNIPPET_FILE_TO_DELETE" ]]; then
                        read -rp "检测到自定义 Nginx 配置片段文件 '$CUSTOM_SNIPPET_FILE_TO_DELETE'，是否一并删除？[y/N]: " DELETE_SNIPPET_CONFIRM
                        DELETE_SNIPPET_CONFIRM=${DELETE_SNIPPET_CONFIRM:-y}
                        if [[ "$DELETE_SNIPPET_CONFIRM" =~ ^[Yy]$ ]]; then
                            rm -f "$CUSTOM_SNIPPET_FILE_TO_DELETE"
                            echo -e "${GREEN}✅ 已删除自定义 Nginx 片段文件: $CUSTOM_SNIPPET_FILE_TO_DELETE${RESET}"
                        else
                            echo -e "${YELLOW}ℹ️ 已保留自定义 Nginx 片段文件: $CUSTOM_SNIPPET_FILE_TO_DELETE${RESET}"
                        fi
                    fi

                    # 从 JSON 元数据中移除此项目
                    if ! jq "del(.[] | select(.domain == \"$DOMAIN_TO_DELETE\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                        echo -e "${RED}❌ 从元数据中移除项目失败！${RESET}"
                    else
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        echo -e "${GREEN}✅ 已从元数据中移除项目 $DOMAIN_TO_DELETE。${RESET}"
                    fi

                    echo -e "${GREEN}✅ 已删除域名 ${DOMAIN_TO_DELETE} 的相关配置和证书文件。${RESET}"
                    systemctl reload nginx 2>/dev/null || true
                else
                    echo -e "${YELLOW}已取消删除操作。${RESET}"
                fi
                ;;
            3) # 编辑项目核心配置 (不含片段)
                read -rp "请输入要编辑的域名: " DOMAIN_TO_EDIT
                if [[ -z "$DOMAIN_TO_EDIT" ]]; then
                    echo -e "${RED}❌ 域名不能为空！${RESET}"
                    continue
                fi
                local CURRENT_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_EDIT\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$CURRENT_PROJECT_JSON" ]; then
                    echo -e "${RED}❌ 域名 $DOMAIN_TO_EDIT 未找到在已配置列表中。${RESET}"
                    continue
                fi
                
                local EDIT_TYPE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.type')
                local EDIT_NAME=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.name')
                local EDIT_RESOLVED_PORT=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.resolved_port')
                local EDIT_ACME_VALIDATION_METHOD=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.acme_validation_method')
                local EDIT_DNS_API_PROVIDER=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.dns_api_provider')
                local EDIT_USE_WILDCARD=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.use_wildcard')
                local EDIT_CA_SERVER_URL=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.ca_server_url')
                local EDIT_CA_SERVER_NAME=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.ca_server_name')
                local EDIT_CUSTOM_SNIPPET_ORIGINAL=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.custom_snippet') # Keep original snippet for regeneration
                local EDIT_CERT_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.cert_file // "/etc/ssl/'"$DOMAIN_TO_EDIT"'.cer"') 
                local EDIT_KEY_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.key_file // "/etc/ssl/'"$DOMAIN_TO_EDIT"'.key"')     

                echo -e "\n--- 编辑域名: ${BLUE}$DOMAIN_TO_EDIT${RESET} ---"
                echo "当前配置:"
                echo "  类型: $EDIT_TYPE"
                echo "  目标: $EDIT_NAME (端口: $EDIT_RESOLVED_PORT)"
                echo "  验证方式: $EDIT_ACME_VALIDATION_METHOD $( [[ -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]] && echo "($EDIT_DNS_API_PROVIDER)" || echo "" )"
                echo "  泛域名: $( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "是" || echo "否" )"
                echo "  CA: $EDIT_CA_SERVER_NAME"
                echo "  证书文件: $EDIT_CERT_FILE"
                echo "  私钥文件: $EDIT_KEY_FILE"


                local NEW_TYPE="$EDIT_TYPE"
                local NEW_NAME="$EDIT_NAME"
                local NEW_RESOLVED_PORT="$EDIT_RESOLVED_PORT"
                local NEW_ACME_VALIDATION_METHOD="$EDIT_ACME_VALIDATION_METHOD"
                local NEW_DNS_API_PROVIDER="$EDIT_DNS_API_PROVIDER"
                local NEW_USE_WILDCARD="$EDIT_USE_WILDCARD"
                local NEW_CA_SERVER_URL="$EDIT_CA_SERVER_URL"
                local NEW_CA_SERVER_NAME="$EDIT_CA_SERVER_NAME"
                local NEW_CERT_FILE="$EDIT_CERT_FILE" 
                local NEW_KEY_FILE="$EDIT_KEY_FILE"   

                local NEED_REISSUE_OR_RELOAD_NGINX="n" # 标记是否需要重新申请证书或更新Nginx配置

                # 编辑后端目标
                read -rp "修改后端目标 (格式：docker容器名 或 本地端口) [当前: $EDIT_NAME，回车不修改]: " NEW_TARGET_INPUT
                if [[ -n "$NEW_TARGET_INPUT" ]]; then
                    if [[ "$NEW_TARGET_INPUT" != "$EDIT_NAME" ]]; then
                        NEED_REISSUE_OR_RELOAD_NGINX="y" # 后端目标改变，可能需要重新生成Nginx配置
                    fi

                    if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$NEW_TARGET_INPUT"; then
                        NEW_NAME="$NEW_TARGET_INPUT"
                        NEW_TYPE="docker"
                        HOST_MAPPED_PORT=$(docker inspect "$NEW_TARGET_INPUT" --format \
                            '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
                            sed 's|/tcp||g' | awk '{print $1}' | head -n1 || echo "")
                        if [[ -n "$HOST_MAPPED_PORT" ]]; then
                            NEW_RESOLVED_PORT="$HOST_MAPPED_PORT"
                            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                            echo -e "${GREEN}✅ 新目标是 Docker 容器 $NEW_NAME，映射端口: $NEW_RESOLVED_PORT。${RESET}"
                        else
                            INTERNAL_EXPOSED_PORTS=$(docker inspect "$NEW_TARGET_INPUT" --format \
                                '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | sed 's|/tcp||g' | xargs || echo "")
                            echo -e "${YELLOW}⚠️ 容器 $NEW_TARGET_INPUT 未映射到宿主机端口。内部暴露端口: $INTERNAL_EXPOSED_PORTS。${RESET}"
                            while true; do
                                read -rp "请输入要代理到的容器内部端口: " USER_INTERNAL_PORT_EDIT
                                if [[ "$USER_INTERNAL_PORT_EDIT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT_EDIT > 0 && USER_INTERNAL_PORT_EDIT < 65536 )); then
                                    NEW_RESOLVED_PORT="$USER_INTERNAL_PORT_EDIT"
                                    FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                                    echo -e "${GREEN}✅ 将代理到容器 $NEW_NAME 的内部端口: $NEW_RESOLVED_PORT。${RESET}"
                                    break
                                else
                                    echo -e "${RED}❌ 输入的端口无效。${RESET}"
                                fi
                            done
                        fi
                    elif [[ "$NEW_TARGET_INPUT" =~ ^[0-9]+$ ]]; then
                        NEW_NAME="$NEW_TARGET_INPUT"
                        NEW_TYPE="local_port"
                        NEW_RESOLVED_PORT="$NEW_TARGET_INPUT"
                        FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                        echo -e "${GREEN}✅ 新目标是本地端口: $NEW_RESOLVED_PORT。${RESET}"
                    else
                        echo -e "${RED}❌ 无效的后端目标输入。将保留原有目标。${RESET}"
                        NEW_TYPE="$EDIT_TYPE" # Reset to old values if invalid input
                        NEW_NAME="$EDIT_NAME"
                        NEW_RESOLVED_PORT="$EDIT_RESOLVED_PORT"
                        NEED_REISSUE_OR_RELOAD_NGINX="n"
                    fi
                fi

                # 编辑验证方式和泛域名
                read -rp "修改证书验证方式 (http-01 / dns-01) [当前: $EDIT_ACME_VALIDATION_METHOD，回车不修改]: " NEW_VALIDATION_METHOD_INPUT
                NEW_VALIDATION_METHOD_INPUT=${NEW_VALIDATION_METHOD_INPUT:-$EDIT_ACME_VALIDATION_METHOD}
                if [[ "$NEW_VALIDATION_METHOD_INPUT" != "$EDIT_ACME_VALIDATION_METHOD" ]]; then
                    if [[ "$NEW_VALIDATION_METHOD_INPUT" = "http-01" || "$NEW_VALIDATION_METHOD_INPUT" = "dns-01" ]]; then
                        NEW_ACME_VALIDATION_METHOD="$NEW_VALIDATION_METHOD_INPUT"
                        echo -e "${GREEN}✅ 验证方式已更新为: $NEW_ACME_VALIDATION_METHOD。${RESET}"
                        NEED_REISSUE_OR_RELOAD_NGINX="y" # 验证方式改变，需要重新申请证书
                        NEW_CA_SERVER_NAME="letsencrypt" # Default CA for new validation setup
                        NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                        # Reset cert file paths to default for acme.sh management
                        NEW_CERT_FILE="/etc/ssl/$DOMAIN_TO_EDIT.cer"
                        NEW_KEY_FILE="/etc/ssl/$DOMAIN_TO_EDIT.key"
                    else
                        echo -e "${RED}❌ 无效的验证方式。将保留原有设置。${RESET}"
                    fi
                fi

                if [ "$NEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                    read -rp "修改泛域名设置 (y/n) [当前: $( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "y" || echo "n" )，回车不修改]: " NEW_WILDCARD_INPUT
                    NEW_WILDCARD_INPUT=${NEW_WILDCARD_INPUT:-$EDIT_USE_WILDCARD}
                    if [[ "$NEW_WILDCARD_INPUT" =~ ^[Yy]$ ]]; then
                        if [[ "$EDIT_USE_WILDCARD" != "y" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                        NEW_USE_WILDCARD="y"
                    else
                        if [[ "$EDIT_USE_WILDCARD" = "y" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                        NEW_USE_WILDCARD="n"
                    fi
                    echo -e "${GREEN}✅ 泛域名设置已更新为: $NEW_USE_WILDCARD。${RESET}"

                    read -rp "修改 DNS API 服务商 (dns_cf / dns_ali) [当前: $EDIT_DNS_API_PROVIDER，回车不修改]: " NEW_DNS_PROVIDER_INPUT
                    NEW_DNS_PROVIDER_INPUT=${NEW_DNS_PROVIDER_INPUT:-$EDIT_DNS_API_PROVIDER}
                    if [[ "$NEW_DNS_PROVIDER_INPUT" != "$EDIT_DNS_API_PROVIDER" ]]; then
                        if [[ "$NEW_DNS_PROVIDER_INPUT" = "dns_cf" || "$NEW_DNS_PROVIDER_INPUT" = "dns_ali" ]]; then
                            NEW_DNS_API_PROVIDER="$NEW_DNS_PROVIDER_INPUT"
                            echo -e "${GREEN}✅ DNS API 服务商已更新为: $NEW_DNS_API_PROVIDER。${RESET}"
                            NEED_REISSUE_OR_RELOAD_NGINX="y"
                        else
                            echo -e "${RED}❌ 无效的 DNS 服务商。将保留原有设置。${RESET}"
                        fi
                    fi
                else # 如果是非 dns-01 验证，泛域名和 DNS API 设为空
                    if [[ "$EDIT_USE_WILDCARD" = "y" || -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                    NEW_USE_WILDCARD="n"
                    NEW_DNS_API_PROVIDER=""
                fi

                # 再次询问 CA (如果在导入后，或从 imported 切换到 acme.sh 托管)
                if [[ "$EDIT_ACME_VALIDATION_METHOD" = "imported" || "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]]; then
                    echo -e "\n请选择新的证书颁发机构 (CA):"
                    echo "1) Let's Encrypt (当前: ${NEW_CA_SERVER_NAME:-letsencrypt})"
                    echo "2) ZeroSSL"
                    read -rp "请输入序号 [1]: " NEW_CA_CHOICE
                    NEW_CA_CHOICE=${NEW_CA_CHOICE:-1}
                    case $NEW_CA_CHOICE in
                        1) NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; NEW_CA_SERVER_NAME="letsencrypt";;
                        2) NEW_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; NEW_CA_SERVER_NAME="zerossl";;
                        *) echo -e "${YELLOW}⚠️ 无效选择，将使用默认 Let's Encrypt。${RESET}";;
                    esac
                    echo -e "${BLUE}➡️ 选定新的 CA: $NEW_CA_SERVER_NAME${RESET}"
                    # 检查并注册 ZeroSSL 账户
                    if [ "$NEW_CA_SERVER_NAME" = "zerossl" ]; then
                         echo -e "${BLUE}🔍 检查 ZeroSSL 账户注册状态...${RESET}"
                         if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
                            echo -e "${YELLOW}⚠️ 未检测到 ZeroSSL 账户已注册。${RESET}"
                            read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " NEW_ZERO_SSL_ACCOUNT_EMAIL
                            while [[ ! "$NEW_ZERO_SSL_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                                echo -e "${RED}❌ 邮箱格式不正确。请重新输入。${RESET}"
                                read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " NEW_ZERO_SSL_ACCOUNT_EMAIL
                            done
                            echo -e "${BLUE}➡️ 正在注册 ZeroSSL 账户: $NEW_ZERO_SSL_ACCOUNT_EMAIL...${RESET}"
                            "$ACME_BIN" --register-account -m "$NEW_ZERO_SSL_ACCOUNT_EMAIL" --server "$NEW_CA_SERVER_URL" || {
                                echo -e "${RED}❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。${RESET}"
                                return 1
                            }
                            echo -e "${GREEN}✅ ZeroSSL 账户注册成功。${RESET}"
                         else
                            echo -e "${GREEN}✅ ZeroSSL 账户已注册。${RESET}"
                         fi
                    fi
                fi

                # 更新 JSON 数据
                local UPDATED_PROJECT_JSON=$(jq -n \
                    --arg domain "$DOMAIN_TO_EDIT" \
                    --arg type "$NEW_TYPE" \
                    --arg name "$NEW_NAME" \
                    --arg resolved_port "$NEW_RESOLVED_PORT" \
                    --arg custom_snippet "$EDIT_CUSTOM_SNIPPET_ORIGINAL" \
                    --arg acme_method "$NEW_ACME_VALIDATION_METHOD" \
                    --arg dns_provider "$NEW_DNS_API_PROVIDER" \
                    --arg wildcard "$NEW_USE_WILDCARD" \
                    --arg ca_url "$NEW_CA_SERVER_URL" \
                    --arg ca_name "$NEW_CA_SERVER_NAME" \
                    --arg cert_file "$NEW_CERT_FILE" \
                    --arg key_file "$NEW_KEY_FILE" \
                    '{domain: $domain, type: $type, name: $name, resolved_port: $resolved_port, custom_snippet: $custom_snippet, acme_validation_method: $acme_method, dns_api_provider: $dns_provider, use_wildcard: $wildcard, ca_server_url: $ca_url, ca_server_name: $ca_name, cert_file: $cert_file, key_file: $key_file}')

                if ! jq "(.[] | select(.domain == \"$DOMAIN_TO_EDIT\")) |= $UPDATED_PROJECT_JSON" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    echo -e "${RED}❌ 更新项目元数据失败！${RESET}"
                else
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    echo -e "${GREEN}✅ 项目元数据已更新。${RESET}"
                fi

                # 如果有关键修改，提示重新申请证书和更新Nginx配置
                if [ "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]; then
                    echo -e "${YELLOW}ℹ️ 检测到与证书或 Nginx 配置相关的关键修改。${RESET}"
                    read -rp "是否立即更新 Nginx 配置并尝试重新申请证书？(强烈建议) [y/N]: " UPDATE_NOW
                    UPDATE_NOW=${UPDATE_NOW:-y}
                    if [[ "$UPDATE_NOW" =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}重新生成 Nginx 配置并申请证书...${RESET}"
                        
                        # 重新生成 Nginx 临时配置（仅当使用 http-01 验证时）
                        if [ "$NEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                            echo -e "${YELLOW}生成 Nginx 临时 HTTP 配置以进行证书验证...${RESET}"
                            DOMAIN_CONF="/etc/nginx/sites-available/$DOMAIN_TO_EDIT.conf" # 确保 DOMAIN_CONF 被正确设置
                            _NGINX_HTTP_CHALLENGE_TEMPLATE "$DOMAIN_TO_EDIT" > "$DOMAIN_CONF"
                            if [ ! -L "/etc/nginx/sites-enabled/$DOMAIN_TO_EDIT.conf" ]; then
                                ln -sf "$DOMAIN_CONF" /etc/nginx/sites-enabled/
                            fi
                            nginx -t || { echo -e "${RED}❌ Nginx 配置语法错误，请检查！${RESET}"; return 1; }
                            systemctl restart nginx || { echo -e "${RED}❌ Nginx 启动失败，请检查服务状态！${RESET}"; return 1; }
                            echo -e "${GREEN}✅ Nginx 已重启，准备申请证书。${RESET}"
                        fi

                        # 申请证书
                        echo -e "${YELLOW}正在为 $DOMAIN_TO_EDIT 申请证书 (CA: $NEW_CA_SERVER_NAME, 验证方式: $NEW_ACME_VALIDATION_METHOD)...${RESET}"
                        local ACME_REISSUE_CMD_LOG_OUTPUT=$(mktemp)
                        ACME_REISSUE_COMMAND="$ACME_BIN --issue -d \"$DOMAIN_TO_EDIT\" --ecc --server \"$NEW_CA_SERVER_URL\""
                        if [ "$NEW_USE_WILDCARD" = "y" ]; then
                            ACME_REISSUE_COMMAND+=" -d \"*.$DOMAIN_TO_EDIT\""
                        fi
                        if [ "$NEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                            ACME_REISSUE_COMMAND+=" -w /var/www/html"
                        elif [ "$NEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                            ACME_REISSUE_COMMAND+=" --dns $NEW_DNS_API_PROVIDER"
                        fi

                        if ! eval "$ACME_REISSUE_COMMAND" > "$ACME_REISSUE_CMD_LOG_OUTPUT" 2>&1; then
                            echo -e "${RED}❌ 域名 $DOMAIN_TO_EDIT 的证书重新申请失败！${RESET}"
                            cat "$ACME_REISSUE_CMD_LOG_OUTPUT"
                            analyze_acme_error "$(cat "$ACME_REISSUE_CMD_LOG_OUTPUT")"
                            rm -f "$ACME_REISSUE_CMD_LOG_OUTPUT"
                            return 1 # Re-issue failed, exit edit mode
                        fi
                        rm -f "$ACME_REISSUE_CMD_LOG_OUTPUT"
                        
                        # 更新证书文件路径到元数据中
                        NEW_CERT_FILE="/etc/ssl/$DOMAIN_TO_EDIT.cer"
                        NEW_KEY_FILE="/etc/ssl/$DOMAIN_TO_EDIT.key"
                        local LATEST_ACME_CERT_JSON=$(jq -n \
                            --arg domain "$DOMAIN_TO_EDIT" \
                            --arg cert_file "$NEW_CERT_FILE" \
                            --arg key_file "$NEW_KEY_FILE" \
                            '{domain: $domain, cert_file: $cert_file, key_file: $key_file}')
                        jq "(.[] | select(.domain == \"$DOMAIN_TO_EDIT\")) |= . + $LATEST_ACME_CERT_JSON" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp" && \
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        echo -e "${GREEN}✅ 证书已成功重新签发。${RESET}"
                        
                        # 安装证书并生成最终 Nginx 配置
                        INSTALL_CERT_DOMAINS="-d \"$DOMAIN_TO_EDIT\""
                        if [ "$NEW_USE_WILDCARD" = "y" ]; then
                            INSTALL_CERT_DOMAINS+=" -d \"*.$DOMAIN_TO_EDIT\""
                        fi
                        "$ACME_BIN" --install-cert $INSTALL_CERT_DOMAINS --ecc \
                            --key-file "$NEW_KEY_FILE" \
                            --fullchain-file "$NEW_CERT_FILE" \
                            --reloadcmd "systemctl reload nginx"
                        echo -e "${YELLOW}生成 $DOMAIN_TO_EDIT 的最终 Nginx 配置...${RESET}"
                        # 使用原始的 custom_snippet_path 进行 Nginx 配置生成
                        _NGINX_FINAL_TEMPLATE "$DOMAIN_TO_EDIT" "$FINAL_PROXY_TARGET_URL" "$NEW_CERT_FILE" "$NEW_KEY_FILE" "$EDIT_CUSTOM_SNIPPET_ORIGINAL" > "$DOMAIN_CONF"
                        echo -e "${GREEN}✅ 域名 $DOMAIN_TO_EDIT 的 Nginx 配置已更新。${RESET}"
                        nginx -t || { echo -e "${RED}❌ 最终 Nginx 配置语法错误，请检查！${RESET}"; return 1; }
                        systemctl reload nginx || { echo -e "${RED}❌ 最终 Nginx 重载失败，请手动检查 Nginx 服务状态！${RESET}"; return 1; }
                        echo -e "${GREEN}🚀 域名 $DOMAIN_TO_EDIT 配置更新完成。${RESET}"
                    else
                        echo -e "${YELLOW}ℹ️ 已跳过证书重新申请和 Nginx 配置更新。请手动操作以确保生效。${RESET}"
                    fi
                else
                    echo -e "${YELLOW}ℹ️ 项目配置已修改。请手动重新加载 Nginx (systemctl reload nginx) 以确保更改生效。${RESET}"
                fi
                ;;
            4) # 管理自定义 Nginx 配置片段 (添加 / 修改 / 清除)
                read -rp "请输入要管理片段的域名: " DOMAIN_FOR_SNIPPET
                if [[ -z "$DOMAIN_FOR_SNIPPET" ]]; then
                    echo -e "${RED}❌ 域名不能为空！${RESET}"
                    continue
                fi
                local SNIPPET_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_FOR_SNIPPET\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$SNIPPET_PROJECT_JSON" ]; then
                    echo -e "${RED}❌ 域名 $DOMAIN_FOR_SNIPPET 未找到在已配置列表中。${RESET}"
                    continue
                fi

                local CURRENT_SNIPPET_PATH=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.custom_snippet')
                local PROJECT_TYPE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.type')
                local PROJECT_NAME_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.name')
                local RESOLVED_PORT_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.resolved_port')
                local CERT_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.cert_file // "/etc/ssl/'"$DOMAIN_FOR_SNIPPET"'.cer"')
                local KEY_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.key_file // "/etc/ssl/'"$DOMAIN_FOR_SNIPPET"'.key"')


                echo -e "\n--- 管理域名 ${BLUE}$DOMAIN_FOR_SNIPPET${RESET} 的 Nginx 配置片段 ---"
                if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                    echo -e "当前自定义片段文件: ${YELLOW}$CURRENT_SNIPPET_PATH${RESET}"
                else
                    echo -e "当前未设置自定义片段文件。"
                fi

                local DEFAULT_SNIPPET_DIR="/etc/nginx/custom_snippets"
                local DEFAULT_SNIPPET_FILENAME=""
                if [ "$PROJECT_TYPE_SNIPPET" = "docker" ]; then
                    DEFAULT_SNIPPET_FILENAME="$PROJECT_NAME_SNIPPET.conf"
                else
                    DEFAULT_SNIPPET_FILENAME="$DOMAIN_FOR_SNIPPET.conf"
                fi
                local DEFAULT_SNIPPET_PATH="$DEFAULT_SNIPPET_DIR/$DEFAULT_SNIPPET_FILENAME"

                read -rp "请输入新的自定义 Nginx 片段文件路径 (回车使用默认: $DEFAULT_SNIPPET_PATH，输入 'none' 清除): " NEW_SNIPPET_INPUT
                local CHOSEN_SNIPPET_PATH=""

                if [[ -z "$NEW_SNIPPET_INPUT" ]]; then # 回车，使用默认路径
                    CHOSEN_SNIPPET_PATH="$DEFAULT_SNIPPET_PATH"
                    echo -e "${GREEN}✅ 将使用默认路径: $CHOSEN_SNIPPET_PATH${RESET}"
                elif [[ "$NEW_SNIPPET_INPUT" = "none" ]]; then # 输入 'none'，清除片段
                    CHOSEN_SNIPPET_PATH=""
                    echo -e "${YELLOW}ℹ️ 已选择清除自定义 Nginx 片段。${RESET}"
                else # 用户输入了新路径
                    CHOSEN_SNIPPET_PATH="$NEW_SNIPPET_INPUT"
                    if ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH")"; then
                        echo -e "${RED}❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH")。操作取消。${RESET}"
                        continue
                    fi
                    echo -e "${GREEN}✅ 将使用新路径: $CHOSEN_SNIPPET_PATH${RESET}"
                fi

                # 更新 JSON 元数据
                local UPDATED_SNIPPET_JSON_OBJ=$(jq -n --arg custom_snippet "$CHOSEN_SNIPPET_PATH" '{custom_snippet: $custom_snippet}')
                if ! jq "(.[] | select(.domain == \"$DOMAIN_FOR_SNIPPET\")) |= . + $UPDATED_SNIPPET_JSON_OBJ" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    echo -e "${RED}❌ 更新项目元数据失败！${RESET}"
                    continue
                else
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    echo -e "${GREEN}✅ 项目元数据中的自定义片段路径已更新。${RESET}"
                fi

                # 重新生成 Nginx 配置
                local PROXY_TARGET_URL_SNIPPET="http://127.0.0.1:$RESOLVED_PORT_SNIPPET"
                local DOMAIN_CONF_SNIPPET="/etc/nginx/sites-available/$DOMAIN_FOR_SNIPPET.conf"

                echo -e "${YELLOW}正在重新生成 $DOMAIN_FOR_SNIPPET 的 Nginx 配置...${RESET}"
                _NGINX_FINAL_TEMPLATE "$DOMAIN_FOR_SNIPPET" "$PROXY_TARGET_URL_SNIPPET" "$CERT_FILE_SNIPPET" "$KEY_FILE_SNIPPET" "$CHOSEN_SNIPPET_PATH" > "$DOMAIN_CONF_SNIPPET"
                
                nginx -t || { echo -e "${RED}❌ Nginx 配置语法错误，请检查！${RESET}"; continue; }
                systemctl reload nginx || { echo -e "${RED}❌ Nginx 重载失败，请手动检查 Nginx 服务状态！${RESET}"; continue; }
                echo -e "${GREEN}🚀 域名 $DOMAIN_FOR_SNIPPET 的 Nginx 配置已更新并重载。${RESET}"

                # 如果原片段文件存在且现在已清除，询问是否删除文件
                if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" && -z "$CHOSEN_SNIPPET_PATH" && -f "$CURRENT_SNIPPET_PATH" ]]; then
                    read -rp "检测到原有自定义片段文件 '$CURRENT_SNIPPET_PATH'。是否删除此文件？[y/N]: " DELETE_OLD_SNIPPET_CONFIRM
                    DELETE_OLD_SNIPPET_CONFIRM=${DELETE_OLD_SNIPPET_CONFIRM:-y}
                    if [[ "$DELETE_OLD_SNIPPET_CONFIRM" =~ ^[Yy]$ ]]; then
                        rm -f "$CURRENT_SNIPPET_PATH"
                        echo -e "${GREEN}✅ 已删除旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH${RESET}"
                    else
                        echo -e "${YELLOW}ℹ️ 已保留旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH${RESET}"
                    fi
                fi
                ;;
            5) # 导入现有 Nginx 配置到本脚本管理
                import_existing_project
                # 导入后，返回 manage_configs 顶层，重新显示列表
                # 这里使用 'continue' 重新进入 manage_configs 的 while 循环，而不是 break
                # 这样可以再次显示更新后的列表，并允许用户继续其他管理操作
                continue 
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}❌ 无效选项，请输入 0-5 ${RESET}"
                ;;
        esac
    done
}

# -----------------------------
# 检查并自动续期所有证书的函数
check_and_auto_renew_certs() {
    check_root
    echo "=============================================="
    echo "🔄 检查并自动续期所有证书"
    echo "=============================================="

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        echo -e "${YELLOW}未找到任何已配置的项目，无需续期。${RESET}"
        return 0
    fi

    local RENEWED_COUNT=0
    local FAILED_COUNT=0

    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r project_json; do
        local DOMAIN=$(echo "$project_json" | jq -r '.domain')
        local ACME_VALIDATION_METHOD=$(echo "$project_json" | jq -r '.acme_validation_method')
        local DNS_API_PROVIDER=$(echo "$project_json" | jq -r '.dns_api_provider')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard')
        local CA_SERVER_URL=$(echo "$project_json" | jq -r '.ca_server_url')
        local CERT_FILE=$(echo "$project_json" | jq -r '.cert_file // "/etc/ssl/'"$DOMAIN"'.cer"') 
        local KEY_FILE=$(echo "$project_json" | jq -r '.key_file // "/etc/ssl/'"$DOMAIN"'.key"')   

        if [[ ! -f "$CERT_FILE" ]]; then
            echo -e "${YELLOW}⚠️ 域名 $DOMAIN 证书文件 $CERT_FILE 不存在，跳过续期。${RESET}"
            continue
        fi

        if [ "$ACME_VALIDATION_METHOD" = "imported" ]; then 
            echo -e "${YELLOW}ℹ️ 域名 $DOMAIN 证书是导入的，本脚本无法自动续期。请手动或通过 '编辑项目核心配置' 转换为 acme.sh 管理。${RESET}"
            continue
        fi

        local END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2) 
        local END_TS=0
        if date --version >/dev/null 2>&1; then # GNU date
            END_TS=$(date -d "$END_DATE" +%s 2>/dev/null)
        else # BSD date (macOS)
            END_TS=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%s" 2>/dev/null)
            if [[ -z "$END_TS" ]]; then
                END_TS=$(date -j -f "%b %e %T %Y %Z" "$END_DATE" "+%s" 2>/dev/null)
            fi
        fi
        END_TS=${END_TS:-0}

        local NOW_TS=$(date +%s)
        local LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))

        if (( LEFT_DAYS <= RENEW_THRESHOLD_DAYS )); then
            echo -e "${YELLOW}⚠️ 域名 $DOMAIN 证书即将到期 (${LEFT_DAYS}天剩余)，尝试自动续期 (验证方式: $ACME_VALIDATION_METHOD)...${RESET}"
            local RENEW_CMD_LOG_OUTPUT=$(mktemp)

            local RENEW_COMMAND="$ACME_BIN --renew -d \"$DOMAIN\" --ecc --server \"$CA_SERVER_URL\"" # 移除了 --force
            if [ "$USE_WILDCARD" = "y" ]; then
                RENEW_COMMAND+=" -d \"*.$DOMAIN\""
            fi

            if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                RENEW_COMMAND+=" -w /var/www/html"
            elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
                RENEW_COMMAND+=" --dns $DNS_API_PROVIDER"
                echo -e "${YELLOW}ℹ️ 续期 DNS 验证证书需要设置相应的 DNS API 环境变量。${RESET}"
            fi

            if eval "$RENEW_COMMAND" > "$RENEW_CMD_LOG_OUTPUT" 2>&1; then
                echo -e "${GREEN}✅ 域名 $DOMAIN 证书续期成功。${RESET}"
                RENEWED_COUNT=$((RENEWED_COUNT + 1))
            else
                echo -e "${RED}❌ 域名 $DOMAIN 证书续期失败！${RESET}"
                cat "$RENEW_CMD_LOG_OUTPUT"
                analyze_acme_error "$(cat "$RENEW_CMD_LOG_OUTPUT")"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            rm -f "$RENEW_CMD_LOG_OUTPUT"
        else
            echo -e "${GREEN}✅ 域名 $DOMAIN 证书有效 (${LEFT_DAYS}天剩余)，无需续期。${RESET}"
        fi
    done

    echo -e "\n${BLUE}--- 续期结果 ---${RESET}"
    echo -e "${GREEN}成功续期: $RENEWED_COUNT 个证书。${RESET}"
    echo -e "${RED}失败续期: $FAILED_COUNT 个证书。${RESET}"
    echo -e "${BLUE}--------------------------${RESET}"
    
    echo -e "${YELLOW}ℹ️ 建议设置一个 Cron 任务来定期自动执行此功能。${RESET}"
    echo -e "${YELLOW}   例如，每周执行一次 (请将 '/path/to/your/script.sh' 替换为脚本实际路径)：${RESET}"
    echo -e "${MAGENTA}   0 3 * * 0 /path/to/your/script.sh 3 >/dev/null 2>&1${RESET}"
    echo -e "${YELLOW}   (这里的 '3' 是主菜单中 '检查并自动续期所有证书' 的选项号)${RESET}"
    echo "=============================================="
}

# -----------------------------
# 管理 acme.sh 账户的函数
manage_acme_accounts() {
    check_root
    while true; do
        echo "=============================================="
        echo "👤 acme.sh 账户管理"
        echo "=============================================="
        echo "1. 查看已注册账户"
        echo "2. 注册新账户"
        echo "3. 设置默认账户"
        echo "0. 返回主菜单"
        echo "=============================================="
        read -rp "请输入选项: " ACCOUNT_CHOICE
        case "$ACCOUNT_CHOICE" in
            1)
                echo -e "${BLUE}🔍 已注册 acme.sh 账户列表:${RESET}"
                "$ACME_BIN" --list-account
                ;;
            2)
                echo -e "${BLUE}➡️ 注册新 acme.sh 账户:${RESET}"
                read -rp "请输入新账户的邮箱地址: " NEW_ACCOUNT_EMAIL
                while [[ ! "$NEW_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                    echo -e "${RED}❌ 邮箱格式不正确。请重新输入。${RESET}"
                    read -rp "请输入新账户的邮箱地址: " NEW_ACCOUNT_EMAIL
                done
                
                local REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                local REGISTER_CA_SERVER_NAME="letsencrypt"
                echo -e "\n请选择证书颁发机构 (CA):"
                echo "1) Let's Encrypt (默认)"
                echo "2) ZeroSSL"
                read -rp "请输入序号: " REGISTER_CA_CHOICE
                REGISTER_CA_CHOICE=${REGISTER_CA_CHOICE:-1}
                case $REGISTER_CA_CHOICE in
                    1) REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; REGISTER_CA_SERVER_NAME="letsencrypt";;
                    2) REGISTER_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; REGISTER_CA_SERVER_NAME="zerossl";;
                    *) echo -e "${YELLOW}⚠️ 无效选择，将使用默认 Let's Encrypt。${RESET}";;
                esac
                echo -e "${BLUE}➡️ 选定 CA: $REGISTER_CA_SERVER_NAME${RESET}"

                echo -e "${GREEN}🚀 正在注册账户 $NEW_ACCOUNT_EMAIL (CA: $REGISTER_CA_SERVER_NAME)...${RESET}"
                if "$ACME_BIN" --register-account -m "$NEW_ACCOUNT_EMAIL" --server "$REGISTER_CA_SERVER_URL"; then
                    echo -e "${GREEN}✅ 账户注册成功。${RESET}"
                else
                    echo -e "${RED}❌ 账户注册失败！请检查邮箱地址或网络。${RESET}"
                fi
                ;;
            3)
                echo -e "${BLUE}➡️ 设置默认 acme.sh 账户:${RESET}"
                "$ACME_BIN" --list-account # 列出账户，让用户选择
                read -rp "请输入要设置为默认的账户邮箱地址: " DEFAULT_ACCOUNT_EMAIL
                if [[ -z "$DEFAULT_ACCOUNT_EMAIL" ]]; then
                    echo -e "${RED}❌ 邮箱不能为空。${RESET}"
                    continue
                fi
                echo -e "${GREEN}🚀 正在设置 $DEFAULT_ACCOUNT_EMAIL 为默认账户...${RESET}"
                if "$ACME_BIN" --set-default-account -m "$DEFAULT_ACCOUNT_EMAIL"; then
                    echo -e "${GREEN}✅ 默认账户设置成功。${RESET}"
                else
                    echo -e "${RED}❌ 设置默认账户失败！请检查邮箱地址是否已注册。${RESET}"
                fi
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}❌ 无效选项，请输入 0-3 ${RESET}"
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
        echo "3. 检查并自动续期所有证书"
        echo "4. 管理 acme.sh 账户"
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
            3)
                check_and_auto_renew_certs
                ;;
            4)
                manage_acme_accounts
                ;;
            0)
                # <<<--- MODIFICATION START ---<<<
                if [ "$IS_NESTED_CALL" = "true" ]; then
                    # 如果是被主脚本调用的，返回退出码 10，代表“返回主菜单”
                    exit 10
                else
                    # 如果是独立运行的，正常退出
                    echo -e "${BLUE}👋 感谢使用，已退出。${RESET}"
                    echo -e "${BLUE}--- 脚本执行结束: $(date +"%Y-%m-%d %H:%M:%S") ---${RESET}"
                    exit 0
                fi
                # >>>--- MODIFICATION END ---<<<
                ;;
            *)
                echo -e "${RED}❌ 无效选项，请输入 0-4 ${RESET}"
                ;;
        esac
    done
}

# --- 脚本入口 ---
# 如果脚本作为cronjob直接运行，并且参数为续期选项，则直接执行续期功能
if [[ "${1:-}" == "3" ]]; then
    check_and_auto_renew_certs
    exit 0
fi

main_menu
