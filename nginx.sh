```bash
#!/bin/bash
# ==============================================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手（基于 acme.sh）
# ------------------------------------------------------------------------------
# 功能概览：
# - **自动化配置**: 一键式自动配置 Nginx 反向代理和 HTTPS 证书。
# - **后端支持**: 支持代理到 Docker 容器或本地指定端口。
# - **依赖管理**: 自动检查并安装/更新必要的系统依赖（Nginx, Curl, Socat, OpenSSL, JQ, idn2, dnsutils）。
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
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
MAGENTA="\033[35m"
RESET="\033[0m"

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
RENEW_THRESHOLD_DAYS=30 # 证书在多少天内到期时触发自动续期

# Nginx 路径变量化
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_WEBROOT_DIR="/var/www/html" # acme.sh webroot 验证目录
NGINX_CUSTOM_SNIPPETS_DIR="/etc/nginx/custom_snippets"
SSL_CERTS_BASE_DIR="/etc/ssl" # 证书的基目录

# --- 日志重定向 ---
# 将所有 stdout 和 stderr 同时输出到终端和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

# --- 日志函数 ---
log_message() {
    local level="$1" # INFO, WARN, ERROR, DEBUG
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color_code=""

    case "$level" in
        INFO) color_code="${GREEN}";;
        WARN) color_code="${YELLOW}";;
        ERROR) color_code="${RED}";;
        DEBUG) color_code="${BLUE}";;
        *) color_code="${RESET}";;
    esac

    # 同时输出到终端和日志文件
    echo -e "${color_code}[${timestamp}] [${level}] ${message}${RESET}" | tee -a "$LOG_FILE" >/dev/null
    # 使用 >/dev/null 避免 tee 重复输出到 stdout，因为 exec > >(tee ...) 已经处理了
}

log_message INFO "--- 脚本开始执行: $(date +"%Y-%m-%d %H:%M:%S") ---"

# --- acme.sh 路径查找 ---
ACME_BIN=""
find_acme_sh_path() {
    local potential_paths=(
        "$HOME/.acme.sh/acme.sh"
        "/root/.acme.sh/acme.sh"
        "$(command -v acme.sh 2>/dev/null)" # 尝试从PATH中查找
    )
    for p in "${potential_paths[@]}"; do
        if [[ -f "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    echo "" # 未找到
    return 1
}

ACME_BIN=$(find_acme_sh_path)
if [[ -z "$ACME_BIN" ]]; then
    log_message WARN "无法立即找到 acme.sh 脚本，将在安装时处理。"
    # 如果此时未找到，install_acme_sh 会尝试安装，并重新设置 ACME_BIN
else
    export PATH="$(dirname "$ACME_BIN"):$PATH" # 确保 PATH 包含 acme.sh 的目录
    log_message INFO "✅ acme.sh 路径已识别: $ACME_BIN"
fi

# -----------------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_message ERROR "请使用 root 用户运行"
        exit 1
    fi
}

# -----------------------------
# 获取 VPS 公网 IPv4 和 IPv6 地址
get_vps_ip() {
    VPS_IP=$(curl -s https://api.ipify.org)
    log_message INFO "🌐 VPS 公网 IP (IPv4): $VPS_IP"

    # 尝试获取 IPv6 地址，如果失败则为空
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "") 
    if [[ -n "$VPS_IPV6" ]]; then
        log_message INFO "🌐 VPS 公网 IP (IPv6): $VPS_IPV6"
    else
        log_message WARN "无法获取 VPS 公网 IPv6 地址，Nginx 将只监听 IPv4。"
    fi
}

# -----------------------------
# 自动安装依赖（跳过已是最新版的），适用于 Debian/Ubuntu
install_dependencies() {
    log_message INFO "🔍 检查并安装依赖 (适用于 Debian/Ubuntu)..."
    apt update -y || { log_message ERROR "apt update 失败，请检查网络或源配置。"; exit 1; }

    # 使用关联数组映射命令到包名
    declare -A DEPS_MAP
    DEPS_MAP=(
        ["nginx"]="nginx"
        ["curl"]="curl"
        ["socat"]="socat"
        ["openssl"]="openssl"
        ["jq"]="jq"
        ["idn2"]="idn2"
        ["dig"]="dnsutils" # 检查 'dig' 命令，如果缺少则安装 'dnsutils' 包
    )

    for cmd in "${!DEPS_MAP[@]}"; do
        local pkg="${DEPS_MAP[$cmd]}"
        if command -v "$cmd" &>/dev/null; then
            # 检查版本是否最新
            INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "not-found")
            AVAILABLE_VER=$(apt-cache policy "$pkg" | grep Candidate | awk '{print $2}' || echo "not-found")
            
            if [ "$INSTALLED_VER" != "not-found" ] && [ "$INSTALLED_VER" = "$AVAILABLE_VER" ]; then
                log_message INFO "✅ 命令 '$cmd' (由包 '$pkg') 已安装且为最新版 ($INSTALLED_VER)，跳过"
            else
                log_message YELLOW "⚠️ 命令 '$cmd' (由包 '$pkg') 正在安装或更新至最新版 ($INSTALLED_VER → $AVAILABLE_VER)..."
                apt install -y "$pkg"
            fi
        else
            log_message YELLOW "⚠️ 缺少命令 '$cmd' (由包 '$pkg' 提供)，正在安装..."
            apt install -y "$pkg"
        fi
    done
    sleep 1
}

# -----------------------------
# 检测 Docker 是否存在
detect_docker() {
    DOCKER_INSTALLED=false
    if command -v docker &>/dev/null; then
        DOCKER_INSTALLED=true
        log_message INFO "✅ Docker 已安装，可检测容器端口"
    else
        log_message WARN "Docker 未安装，无法检测容器端口，只能配置本地端口"
    fi
    sleep 1
}

# -----------------------------
# 安装 acme.sh
install_acme_sh() {
    if [ ! -f "$ACME_BIN" ]; then
        log_message YELLOW "⚠️ acme.sh 未安装，正在安装..."
        
        read -rp "请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址 (例如: your@example.com)，回车则不指定: " ACME_EMAIL_INPUT
        
        ACME_EMAIL=""
        if [[ -n "$ACME_EMAIL_INPUT" ]]; then
            while [[ ! "$ACME_EMAIL_INPUT" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                log_message RED "❌ 邮箱格式不正确。请重新输入，或回车不指定。"
                read -rp "请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址: " ACME_EMAIL_INPUT
                [[ -z "$ACME_EMAIL_INPUT" ]] && break
            done
            ACME_EMAIL="$ACME_EMAIL_INPUT"
        fi

        if [[ -n "$ACME_EMAIL" ]]; then
            log_message BLUE "➡️ 正在使用邮箱 $ACME_EMAIL 安装 acme.sh..."
            curl https://get.acme.sh | sh -s email="$ACME_EMAIL"
        else
            log_message YELLOW "ℹ️ 未指定邮箱地址安装 acme.sh。某些证书颁发机构（如 ZeroSSL）可能需要注册邮箱。您可以在之后使用 'acme.sh --register-account -m your@example.com' 手动注册。"
            read -rp "是否确认不指定邮箱安装 acme.sh？[y/N]: " NO_EMAIL_CONFIRM
            NO_EMAIL_CONFIRM=${NO_EMAIL_CONFIRM:-n} # 默认改为 n，更安全
            if [[ "$NO_EMAIL_CONFIRM" =~ ^[Yy]$ ]]; then
                curl https://get.acme.sh | sh
            else
                log_message RED "❌ 已取消 acme.sh 安装。"
                exit 1
            fi
        fi
        
        ACME_BIN=$(find_acme_sh_path) # 重新查找 acme.sh 路径
        if [[ -z "$ACME_BIN" ]]; then
             log_message ERROR "acme.sh 安装成功，但无法找到其执行路径。请手动检查并确保安装正确。"
             exit 1
        fi
        export PATH="$(dirname "$ACME_BIN"):$PATH" # 重新加载 PATH，确保 acme.sh 命令可用
        log_message INFO "✅ acme.sh 已安装或路径已更新。"
    else
        log_message INFO "✅ acme.sh 已安装"
    fi
    sleep 1
}

# -----------------------------
# 检测域名解析 (同时检查 IPv4 和 IPv6)
check_domain_ip() {
    local domain="$1"
    local vps_ip_v4="$2" # VPS_IP
    local vps_ip_v6="$3" # VPS_IPV6 (global variable)

    log_message INFO "🔍 正在检查域名 ${domain} 的 DNS 解析..."

    # 1. IPv4 解析检查
    local domain_ip_v4=$(dig +short "$domain" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 2>/dev/null || echo "")
    if [ -z "$domain_ip_v4" ]; then
        log_message RED "❌ 域名 ${domain} 无法解析到任何 IPv4 地址，请检查 DNS 配置。"
        return 1 # 硬性失败
    elif [ "$domain_ip_v4" != "$vps_ip_v4" ]; then
        log_message RED "⚠️ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 与本机 IPv4 ($vps_ip_v4) 不符。"
        read -rp "这可能导致证书申请失败。是否继续？[y/N]: " PROCEED_ANYWAY_V4
        PROCEED_ANYWAY_V4=${PROCEED_ANYWAY_V4:-n} # 默认改为 n
        if [[ ! "$PROCEED_ANYWAY_V4" =~ ^[Yy]$ ]]; then
            log_message RED "❌ 已取消当前域名的操作。"
            return 1 # 硬性失败
        fi
        log_message YELLOW "⚠️ 已选择继续申请 (IPv4 解析不匹配)。请务必确认此操作的风险。"
    else
        log_message GREEN "✅ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 正确。"
    fi

    # 2. IPv6 解析检查 (如果 VPS 有 IPv6 地址)
    if [[ -n "$vps_ip_v6" ]]; then
        local domain_ip_v6=$(dig +short "$domain" AAAA | grep -E '^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$' | head -n1 2>/dev/null || echo "")
        if [ -z "$domain_ip_v6" ]; then
            log_message YELLOW "⚠️ 域名 ${domain} 未配置 AAAA 记录，但您的 VPS 具有 IPv6 地址。"
            read -rp "这表示该域名可能无法通过 IPv6 访问。是否继续？[y/N]: " PROCEED_ANYWAY_AAAA_MISSING
            PROCEED_ANYWAY_AAAA_MISSING=${PROCEED_ANYWAY_AAAA_MISSING:-n} # 默认改为 n
            if [[ ! "$PROCEED_ANYWAY_AAAA_MISSING" =~ ^[Yy]$ ]]; then
                log_message RED "❌ 已取消当前域名的操作。"
                return 1 # 硬性失败
            fi
            log_message YELLOW "⚠️ 已选择继续申请 (AAAA 记录缺失)。"
        elif [ "$domain_ip_v6" != "$vps_ip_v6" ]; then
            log_message RED "⚠️ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 与本机 IPv6 ($vps_ip_v6) 不符。"
            read -rp "这可能导致证书申请失败或域名无法通过 IPv6 访问。是否继续？[y/N]: " PROCEED_ANYWAY_AAAA_MISMATCH
            PROCEED_ANYWAY_AAAA_MISMATCH=${PROCEED_ANYWAY_AAAA_MISMATCH:-n} # 默认改为 n
            if [[ ! "$PROCEED_ANYWAY_AAAA_MISMATCH" =~ ^[Yy]$ ]]; then
                log_message RED "❌ 已取消当前域名的操作。"
                return 1 # 硬性失败
            fi
            log_message YELLOW "⚠️ 已选择继续申请 (IPv6 解析不匹配)。请务必确认此操作的风险。"
        else
            log_message GREEN "✅ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 正确。"
        fi
    else
        log_message YELLOW "ℹ️ 您的 VPS 未检测到 IPv6 地址，因此未检查域名 ${domain} 的 AAAA 记录。"
    fi

    sleep 1
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
        root "$NGINX_WEBROOT_DIR";
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
    log_message ERROR "--- acme.sh 错误分析 ---"
    if echo "$error_output" | grep -q "Invalid response from"; then
        log_message ERROR "   可能原因：域名解析错误，或 80 端口未开放/被占用，或防火墙阻止了验证请求。"
        log_message YELLOW "   建议：1. 检查域名 A/AAAA 记录是否指向本机 IP。2. 确保 80 端口已开放且未被其他服务占用。3. 检查服务器防火墙设置。"
    elif echo "$error_output" | grep -q "Domain not owned"; then
        log_message ERROR "   可能原因：acme.sh 无法证明您拥有该域名。"
        log_message YELLOW "   建议：1. 确保域名解析正确。2. 如果是 dns-01 验证，检查 DNS API 密钥和权限。3. 尝试强制更新 DNS 记录。"
    elif echo "$error_output" | grep -q "Timeout"; then
        log_message ERROR "   可能原因：验证服务器连接超时。"
        log_message YELLOW "   建议：检查服务器网络连接，防火墙，或 DNS 解析是否稳定。"
    elif echo "$error_output" | grep -q "Rate Limit"; then
        log_message ERROR "   可能原因：已达到 Let's Encrypt 或 ZeroSSL 的请求频率限制。"
        log_message YELLOW "   建议：请等待一段时间（通常为一周）再尝试，或添加更多域名到单个证书（如果适用）。"
        log_message YELLOW "   参考: https://letsencrypt.org/docs/rate-limits/ 或 ZeroSSL 文档。"
    elif echo "$error_output" | grep -q "DNS problem"; then
        log_message ERROR "   可能原因：DNS 验证失败。"
        log_message YELLOW "   建议：1. 检查 DNS 记录是否正确添加 (TXT 记录)。2. 检查 DNS API 密钥是否有效且有足够权限。3. 确保 DNS 记录已完全生效。"
    elif echo "$error_output" | grep -q "No account specified for this domain"; then
        log_message ERROR "   可能原因：未为该域名指定或注册 ACME 账户。"
        log_message YELLOW "   建议：运行 'acme.sh --register-account -m your@example.com --server [CA_SERVER_URL]' 注册账户。"
    elif echo "$error_output" | grep -q "Domain key exists"; then # 新增错误分析
        log_message ERROR "   可能原因：上次申请失败后残留了域名私钥文件。"
        log_message YELLOW "   建议：此错误通常在使用 '--force' 时被忽略。如果不是手动强制申请，请尝试在管理菜单中删除该项目后重试。"
    else
        log_message ERROR "   未识别的错误类型。"
        log_message YELLOW "   建议：请仔细检查上述 acme.sh 完整错误日志，并查阅 acme.sh 官方文档或社区寻求帮助。"
    fi
    log_message ERROR "--------------------------"
}

# -----------------------------
# 健壮的 Nginx 控制函数
control_nginx() {
    local action="$1" # restart, reload, start, stop
    log_message INFO "尝试 ${action} Nginx 服务..."
    
    # 检查配置语法
    nginx -t &>/dev/null
    if [ $? -ne 0 ]; then
        log_message ERROR "Nginx 配置语法错误！请检查 '$NGINX_SITES_AVAILABLE_DIR/' 下的配置文件。"
        nginx -t # 再次运行以便用户看到详细错误
        sleep 2
        return 1
    fi

    systemctl "$action" nginx
    if [ $? -ne 0 ]; then
        log_message ERROR "Nginx ${action} 失败！请手动检查 Nginx 服务状态：'systemctl status nginx'，并查看错误日志：'journalctl -xeu nginx'。"
        sleep 2
        return 1
    else
        log_message INFO "Nginx 服务已成功 ${action}。"
        sleep 1
        return 0
    fi
}

# -----------------------------
# 检查 DNS API 环境变量是否设置
check_dns_env() {
    local provider="$1"
    local missing_vars=()
    case "$provider" in
        dns_cf)
            if [[ -z "${CF_Token:-}" ]]; then missing_vars+=("CF_Token"); fi
            if [[ -z "${CF_Account_ID:-}" ]]; then missing_vars+=("CF_Account_ID"); fi
            ;;
        dns_ali)
            if [[ -z "${Ali_Key:-}" ]]; then missing_vars+=("Ali_Key"); fi
            if [[ -z "${Ali_Secret:-}" ]]; then missing_vars+=("Ali_Secret"); fi
            ;;
        *)
            log_message WARN "未知的 DNS API 提供商 '$provider'，无法检查环境变量。"
            return 0 # 不影响继续
            ;;
    esac

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_message ERROR "⚠️ 进行 DNS-01 验证时，缺少以下必要的环境变量："
        for var in "${missing_vars[@]}"; do
            log_message ERROR "   - $var"
        done
        log_message YELLOW "请在运行脚本前设置这些环境变量，例如 'export CF_Token=\"YOUR_TOKEN\"'。"
        read -rp "是否已设置这些变量并确认继续？[y/N]: " CONFIRM_ENV
        CONFIRM_ENV=${CONFIRM_ENV:-n}
        if [[ ! "$CONFIRM_ENV" =~ ^[Yy]$ ]]; then
            return 1 # 用户选择不继续
        fi
    else
        log_message INFO "✅ 必要的 DNS API 环境变量已设置。"
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
        log_message RED "❌ 已取消配置。"
        return 1
    fi

    install_dependencies
    detect_docker
    install_acme_sh
    
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR"
    mkdir -p "$NGINX_SITES_ENABLED_DIR"
    mkdir -p "$NGINX_WEBROOT_DIR" # 用于 acme.sh webroot 验证
    mkdir -p "$NGINX_CUSTOM_SNIPPETS_DIR" # 创建自定义片段的默认父目录
    
    local VPS_IP
    get_vps_ip

    # 检查并移除旧版 projects.conf 以避免冲突
    if [ -f "$NGINX_SITES_AVAILABLE_DIR/projects.conf" ]; then
        log_message YELLOW "⚠️ 检测到旧版 Nginx 配置文件 $NGINX_SITES_AVAILABLE_DIR/projects.conf，正在删除以避免冲突。"
        rm -f "$NGINX_SITES_AVAILABLE_DIR/projects.conf"
        rm -f "$NGINX_SITES_ENABLED_DIR/projects.conf"
        control_nginx reload 2>/dev/null || true # 尝试重载 Nginx
    fi

    # Ensure metadata file exists and is a valid JSON array
    if [ ! -f "$PROJECTS_METADATA_FILE" ]; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
    else
        # Validate if it's a valid JSON array
        if ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
            log_message RED "❌ 警告: $PROJECTS_METADATA_FILE 不是有效的 JSON 格式。将备份并重新创建。"
            mv "$PROJECTS_METADATA_FILE" "${PROJECTS_METADATA_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            echo "[]" > "$PROJECTS_METADATA_FILE"
        fi
    fi

    log_message YELLOW "请输入项目列表（格式：主域名:docker容器名 或 主域名:本地端口），输入空行结束："
    PROJECTS=()
    while true; do
        read -rp "> " line
        [[ -z "$line" ]] && break
        PROJECTS+=("$line")
    done

    # 【修复 2】检查用户是否输入了任何项目 (移动到此处)
    if [ ${#PROJECTS[@]} -eq 0 ]; then
        log_message YELLOW "⚠️ 您没有输入任何项目，操作已取消。"
        return 1
    fi
    sleep 1

    # CA 选择
    ACME_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
    ACME_CA_SERVER_NAME="letsencrypt"
    log_message INFO "请选择证书颁发机构 (CA):"
    echo "1) Let's Encrypt (默认)"
    echo "2) ZeroSSL"
    read -rp "请输入序号: " CA_CHOICE
    CA_CHOICE=${CA_CHOICE:-1}
    case $CA_CHOICE in
        1) ACME_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; ACME_CA_SERVER_NAME="letsencrypt";;
        2) ACME_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; ACME_CA_SERVER_NAME="zerossl";;
        *) log_message YELLOW "⚠️ 无效选择，将使用默认 Let's Encrypt。";;
    esac
    log_message BLUE "➡️ 选定 CA: $ACME_CA_SERVER_NAME"
    sleep 1

    # ZeroSSL 账户注册检查
    if [ "$ACME_CA_SERVER_NAME" = "zerossl" ]; then
        log_message BLUE "🔍 检查 ZeroSSL 账户注册状态..."
        if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
             log_message YELLOW "⚠️ 未检测到 ZeroSSL 账户已注册。"
             read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " ZERO_SSL_ACCOUNT_EMAIL
             while [[ ! "$ZERO_SSL_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                 log_message RED "❌ 邮箱格式不正确。请重新输入。"
                 read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " ZERO_SSL_ACCOUNT_EMAIL
             done
             log_message BLUE "➡️ 正在注册 ZeroSSL 账户: $ZERO_SSL_ACCOUNT_EMAIL..."
             "$ACME_BIN" --register-account -m "$ZERO_SSL_ACCOUNT_EMAIL" --server "$ACME_CA_SERVER_URL" || {
                 log_message RED "❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。"
                 return 1
             }
             log_message GREEN "✅ ZeroSSL 账户注册成功。"
        else
            log_message GREEN "✅ ZeroSSL 账户已注册。"
        fi
        sleep 1
    fi

    log_message GREEN "🔧 正在为每个项目生成 Nginx 配置并申请证书..."
    for P in "${PROJECTS[@]}"; do
        MAIN_DOMAIN="${P%%:*}"
        TARGET_INPUT="${P##*:}"
        DOMAIN_CONF="$NGINX_SITES_AVAILABLE_DIR/$MAIN_DOMAIN.conf"
        
        log_message INFO "\n--- 处理域名: ${BLUE}$MAIN_DOMAIN${RESET} ---"

        if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
            log_message YELLOW "⚠️ 域名 $MAIN_DOMAIN 已存在配置。请在 '查看与管理' 菜单中编辑或删除。"
            continue
        fi

        if ! check_domain_ip "$MAIN_DOMAIN" "$VPS_IP" "$VPS_IPV6"; then
            log_message RED "❌ 跳过域名 $MAIN_DOMAIN 的配置和证书申请。"
            continue
        fi

        ACME_VALIDATION_METHOD="http-01"
        DNS_API_PROVIDER=""
        USE_WILDCARD="n"
        
        log_message INFO "\n请选择验证方式:"
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
                    log_message YELLOW "⚠️ 泛域名证书必须使用 dns-01 验证方式。"
                fi

                log_message INFO "\n请选择您的 DNS 服务商 (用于 dns-01 验证):"
                echo "1) Cloudflare (dns_cf)"
                echo "2) Aliyun DNS (dns_ali)"
                read -rp "请输入序号: " DNS_PROVIDER_CHOICE
                DNS_PROVIDER_CHOICE=${DNS_PROVIDER_CHOICE:-1}
                case $DNS_PROVIDER_CHOICE in
                    1) 
                        DNS_API_PROVIDER="dns_cf"
                        log_message YELLOW "⚠️ 您选择了 Cloudflare DNS API。请确保在运行脚本前，已设置以下环境变量：${RESET}"
                        log_message YELLOW "   export CF_Token=\"YOUR_CLOUDFLARE_API_TOKEN\""
                        log_message YELLOW "   export CF_Account_ID=\"YOUR_CLOUDFLARE_ACCOUNT_ID\""
                        log_message YELLOW "   参考文档: https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Cloudflare-API"
                        ;;
                    2) 
                        DNS_API_PROVIDER="dns_ali"
                        log_message YELLOW "⚠️ 您选择了 Aliyun DNS API。请确保在运行脚本前，已设置以下环境变量：${RESET}"
                        log_message YELLOW "   export Ali_Key=\"YOUR_ALIYUN_ACCESS_KEY_ID\""
                        log_message YELLOW "   export Ali_Secret=\"YOUR_ALIYUN_ACCESS_KEY_SECRET\""
                        log_message YELLOW "   参考文档: https://github.com/acmesh-official/acme.sh/wiki/How-to-use-Aliyun-Domain-API"
                        ;;
                    *) 
                        log_message RED "❌ 无效的 DNS 服务商选择，将尝试使用 dns_cf。请确保环境变量已设置。"
                        DNS_API_PROVIDER="dns_cf"
                        ;;
                esac
                if ! check_dns_env "$DNS_API_PROVIDER"; then
                    log_message ERROR "DNS 环境变量检查失败，跳过域名 $MAIN_DOMAIN 的证书申请。"
                    continue
                fi
                ;;
            *) log_message YELLOW "⚠️ 无效选择，将使用默认 http-01 验证方式。";;
        esme
        log_message BLUE "➡️ 选定验证方式: $ACME_VALIDATION_METHOD"
        if [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
            log_message BLUE "➡️ 选定 DNS API 服务商: $DNS_API_PROVIDER"
            if [ "$USE_WILDCARD" = "y" ]; then
                log_message BLUE "➡️ 申请泛域名证书: *.$MAIN_DOMAIN"
            fi
        fi
        sleep 1

        PROXY_TARGET_URL=""
        PROJECT_TYPE=""
        PROJECT_DETAIL=""
        PORT_TO_USE=""

        if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$TARGET_INPUT"; then
            log_message GREEN "🔍 识别到 Docker 容器: $TARGET_INPUT"
            
            HOST_MAPPED_PORT=$(docker inspect "$TARGET_INPUT" --format \
                '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
                sed 's|/tcp||g' | awk '{print $1}' | head -n1)

            if [[ -n "$HOST_MAPPED_PORT" ]]; then
                log_message GREEN "✅ 检测到容器 $TARGET_INPUT 已映射到宿主机端口: $HOST_MAPPED_PORT。将自动使用此端口。"
                PORT_TO_USE="$HOST_MAPPED_PORT"
                PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
                PROJECT_TYPE="docker"
                PROJECT_DETAIL="$TARGET_INPUT"
            else
                log_message YELLOW "⚠️ 未检测到容器 $TARGET_INPUT 映射到宿主机的端口。"
                
                INTERNAL_EXPOSED_PORTS_ARRAY=()
                while IFS= read -r port_entry; do
                    INTERNAL_EXPOSED_PORTS_ARRAY+=("$port_entry")
                done < <(docker inspect "$TARGET_INPUT" --format '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | sed 's|/tcp||g' | xargs -n1)

                if [ ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} -gt 0 ]; then
                    log_message YELLOW "检测到容器内部暴露的端口有："
                    local port_idx=0
                    for p in "${INTERNAL_EXPOSED_PORTS_ARRAY[@]}"; do
                        port_idx=$((port_idx + 1))
                        echo -e "   ${YELLOW}${port_idx})${RESET} ${p}"
                    done
                    
                    while true; do
                        read -rp "请选择一个内部端口序号，或直接输入端口号 (例如 1 或 8080): " PORT_SELECTION
                        if [[ "$PORT_SELECTION" =~ ^[0-9]+$ ]]; then
                            if (( PORT_SELECTION > 0 && PORT_SELECTION <= ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} )); then
                                PORT_TO_USE="${INTERNAL_EXPOSED_PORTS_ARRAY[PORT_SELECTION-1]}"
                                log_message GREEN "✅ 已选择容器内部端口: $PORT_TO_USE。"
                                break
                            elif (( PORT_SELECTION > 0 && PORT_SELECTION < 65536 )); then
                                PORT_TO_USE="$PORT_SELECTION"
                                log_message GREEN "✅ 已手动指定容器内部端口: $PORT_TO_USE。"
                                break
                            fi
                        fi
                        log_message RED "❌ 输入无效。请重新选择或输入有效的端口号 (1-65535)。"
                    done
                else
                    log_message YELLOW "未检测到容器 $TARGET_INPUT 内部暴露的端口。"
                    while true; do
                        read -rp "请输入要代理到的容器内部端口 (例如 8080): " USER_INTERNAL_PORT
                        if [[ "$USER_INTERNAL_PORT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT > 0 && USER_INTERNAL_PORT < 65536 )); then
                            PORT_TO_USE="$USER_INTERNAL_PORT"
                            PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
                            PROJECT_TYPE="docker"
                            PROJECT_DETAIL="$TARGET_INPUT"
                            log_message GREEN "✅ 将代理到容器 $TARGET_INPUT 的内部端口: $PORT_TO_USE。请确保容器监听 0.0.0.0。"
                            break
                        else
                            log_message RED "❌ 输入的端口无效。请重新输入一个有效的端口号 (1-65535)。"
                        fi
                    done
                fi
            fi
        elif [[ "$TARGET_INPUT" =~ ^[0-9]+$ ]]; then
            log_message GREEN "🔍 识别到本地端口: $TARGET_INPUT"
            PORT_TO_USE="$TARGET_INPUT"
            PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
            PROJECT_TYPE="local_port"
            PROJECT_DETAIL="$TARGET_INPUT"
        else
            log_message RED "❌ 无效的目标格式 '$TARGET_INPUT' (既不是Docker容器名也不是端口号)，跳过域名 $MAIN_DOMAIN。"
            continue
        fi
        sleep 1

        mkdir -p "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN"

        local CUSTOM_NGINX_SNIPPET_FILE=""
        local DEFAULT_SNIPPET_DIR="$NGINX_CUSTOM_SNIPPETS_DIR"
        local DEFAULT_SNIPPET_FILENAME=""

        if [ "$PROJECT_TYPE" = "docker" ]; then
            DEFAULT_SNIPPET_FILENAME="$PROJECT_DETAIL.conf"
        else
            DEFAULT_SNIPPET_FILENAME="$MAIN_DOMAIN.conf"
        fi
        local DEFAULT_SNIPPET_PATH="$DEFAULT_SNIPPET_DIR/$DEFAULT_SNIPPET_FILENAME"
        
        read -rp "是否为域名 $MAIN_DOMAIN 添加自定义 Nginx 配置片段文件？[y/N]: " ADD_CUSTOM_SNIPPET
        ADD_CUSTOM_SNIPPET=${ADD_CUSTOM_SNIPPET:-n}
        if [[ "$ADD_CUSTOM_SNIPPET" =~ ^[Yy]$ ]]; then
            while true; do
                read -rp "请输入自定义 Nginx 配置片段文件的完整路径 [默认: $DEFAULT_SNIPPET_PATH]: " SNIPPET_PATH_INPUT
                local CHOSEN_SNIPPET_PATH="${SNIPPET_PATH_INPUT:-$DEFAULT_SNIPPET_PATH}"

                if [[ -z "$CHOSEN_SNIPPET_PATH" ]]; then
                    log_message RED "❌ 文件路径不能为空。"
                elif ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH")"; then
                    log_message RED "❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH")。请检查权限或路径是否有效。"
                else
                    CUSTOM_NGINX_SNIPPET_FILE="$CHOSEN_SNIPPET_PATH"
                    log_message YELLOW "ℹ️ 请确保文件 '$CUSTOM_NGINX_SNIPPET_FILE' 包含有效的 Nginx 配置片段。"
                    log_message GREEN "✅ 将使用自定义 Nginx 配置片段文件: $CUSTOM_NGINX_SNIPPET_FILE"
                    break
                fi
            done
        fi
        sleep 1

        local INSTALLED_CRT_FILE="$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN.cer"
        local INSTALLED_KEY_FILE="$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN.key"
        local SHOULD_ISSUE_CERT="y"

        if [[ -f "$INSTALLED_CRT_FILE" && -f "$INSTALLED_KEY_FILE" ]]; then
            local EXISTING_END_DATE=$(openssl x509 -enddate -noout -in "$INSTALLED_CRT_FILE" 2>/dev/null | cut -d= -f2 || echo "未知日期")
            local EXISTING_END_TS=$(date -d "$EXISTING_END_DATE" +%s 2>/dev/null || echo 0)
            local NOW_TS=$(date +%s)
            local EXISTING_LEFT_DAYS=$(( (EXISTING_END_TS - NOW_TS) / 86400 ))

            log_message YELLOW "⚠️ 域名 $MAIN_DOMAIN 已存在有效期至 ${EXISTING_END_DATE} 的证书 ($EXISTING_LEFT_DAYS 天剩余)。"
            log_message INFO "您想："
            echo "1) 重新申请/续期证书 (推荐更新过期或即将过期的证书) [默认]"
            echo "2) 使用现有证书 (跳过证书申请步骤)"
            read -rp "请输入选项 [1]: " CERT_ACTION_CHOICE
            CERT_ACTION_CHOICE=${CERT_ACTION_CHOICE:-1}

            if [ "$CERT_ACTION_CHOICE" == "2" ]; then
                SHOULD_ISSUE_CERT="n"
                log_message GREEN "✅ 已选择使用现有证书。"
            else
                log_message YELLOW "ℹ️ 将重新申请/续期证书。"
            fi
        fi
        sleep 1

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
        
        if ! jq ". + [$NEW_PROJECT_JSON]" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message RED "❌ 写入项目元数据失败！请检查 $PROJECTS_METADATA_FILE 文件权限或 JSON 格式。"
            continue
        fi
        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
        log_message GREEN "✅ 项目元数据已保存到 $PROJECTS_METADATA_FILE。"
        sleep 1

        if [ "$SHOULD_ISSUE_CERT" = "y" ] && [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
            log_message YELLOW "生成 Nginx 临时 HTTP 配置以进行证书验证..."
            _NGINX_HTTP_CHALLENGE_TEMPLATE "$MAIN_DOMAIN" > "$DOMAIN_CONF"
            
            if [ ! -L "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf" ]; then
                ln -sf "$DOMAIN_CONF" "$NGINX_SITES_ENABLED_DIR/"
            fi

            log_message INFO "重启 Nginx 服务以应用临时配置..."
            if ! control_nginx restart; then
                log_message ERROR "Nginx 启动失败，跳过域名 $MAIN_DOMAIN 的证书申请。"
                continue
            fi
            log_message GREEN "✅ Nginx 已重启，准备申请证书。"
            sleep 1
        fi

        if [ "$SHOULD_ISSUE_CERT" = "y" ]; then
            log_message YELLOW "正在为 $MAIN_DOMAIN 申请证书 (CA: $ACME_CA_SERVER_NAME, 验证方式: $ACME_VALIDATION_METHOD)..."
            local ACME_ISSUE_CMD_LOG_OUTPUT=$(mktemp)

            ACME_ISSUE_COMMAND="$ACME_BIN --issue --force -d \"$MAIN_DOMAIN\" --ecc --server \"$ACME_CA_SERVER_URL\" --debug 2" # 重新添加 --force
            if [ "$USE_WILDCARD" = "y" ]; then
                ACME_ISSUE_COMMAND+=" -d \"*.$MAIN_DOMAIN\""
            fi

            if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                ACME_ISSUE_COMMAND+=" -w \"$NGINX_WEBROOT_DIR\""
            elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
                ACME_ISSUE_COMMAND+=" --dns $DNS_API_PROVIDER"
            fi

            if ! eval "$ACME_ISSUE_COMMAND" > "$ACME_ISSUE_CMD_LOG_OUTPUT" 2>&1; then
                log_message RED "❌ 域名 $MAIN_DOMAIN 的证书申请失败！"
                cat "$ACME_ISSUE_CMD_LOG_OUTPUT"
                analyze_acme_error "$(cat "$ACME_ISSUE_CMD_LOG_OUTPUT")"
                rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"

                rm -f "$DOMAIN_CONF"
                rm -f "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf"
                rm -rf "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN" # 删除证书目录
                
                if [[ -n "$CUSTOM_NGINX_SNIPPET_FILE" && "$CUSTOM_NGINX_SNIPPET_FILE" != "null" ]]; then
                    log_message YELLOW "⚠️ 证书申请失败，删除自定义 Nginx 片段文件: $CUSTOM_NGINX_SNIPPET_FILE"
                    rm -f "$CUSTOM_NGINX_SNIPPET_FILE"
                fi
                if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
                    log_message YELLOW "⚠️ 从元数据中移除失败的项目 $MAIN_DOMAIN。"
                    jq "del(.[] | select(.domain == \"$MAIN_DOMAIN\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp" && \
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                fi
                continue
            fi
            rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"
            
            log_message GREEN "✅ 证书已成功签发，正在安装并更新 Nginx 配置..."
            sleep 1

            INSTALL_CERT_DOMAINS="-d \"$MAIN_DOMAIN\""
            if [ "$USE_WILDCARD" = "y" ]; then
                INSTALL_CERT_DOMAINS+=" -d \"*.$MAIN_DOMAIN\""
            fi

            "$ACME_BIN" --install-cert $INSTALL_CERT_DOMAINS --ecc \
                --key-file       "$INSTALLED_KEY_FILE" \
                --fullchain-file "$INSTALLED_CRT_FILE" \
                --reloadcmd      "systemctl reload nginx"
        else
            log_message YELLOW "ℹ️ 未进行证书申请或续期，将使用现有证书。"
        fi
        sleep 1

        log_message YELLOW "生成 $MAIN_DOMAIN 的最终 Nginx 配置..."
        _NGINX_FINAL_TEMPLATE "$MAIN_DOMAIN" "$PROXY_TARGET_URL" "$INSTALLED_CRT_FILE" "$INSTALLED_KEY_FILE" "$CUSTOM_NGINX_SNIPPET_FILE" > "$DOMAIN_CONF"
        
        log_message GREEN "✅ 域名 $MAIN_DOMAIN 的 Nginx 配置已更新。"
        sleep 1
    done

    log_message GREEN "✅ 所有项目处理完毕，执行最终 Nginx 配置检查和重载..."
    if ! control_nginx reload; then
        log_message ERROR "最终 Nginx 重载失败，请手动检查 Nginx 服务状态！"
        return 1
    fi

    log_message GREEN "🚀 所有域名配置完成！现在可以通过 HTTPS 访问您的服务。"
    return 0
}

# -----------------------------
# 导入现有 Nginx 配置到本脚本管理 (这部分代码是完整的)
import_existing_project() {
    check_root
    log_message INFO "=============================================="
    log_message INFO "📥 导入现有 Nginx 配置到本脚本管理"
    log_message INFO "=============================================="
    sleep 1

    read -rp "请输入要导入的主域名 (例如 example.com): " IMPORT_DOMAIN
    [[ -z "$IMPORT_DOMAIN" ]] && { log_message RED "❌ 域名不能为空！"; return 1; }

    local EXISTING_NGINX_CONF_PATH="$NGINX_SITES_AVAILABLE_DIR/$IMPORT_DOMAIN.conf"
    if [ ! -f "$EXISTING_NGINX_CONF_PATH" ]; then
        log_message RED "❌ 域名 $IMPORT_DOMAIN 的 Nginx 配置文件 $EXISTING_NGINX_CONF_PATH 不存在。请确认路径和文件名。"
        return 1
    fi
    log_message GREEN "✅ 找到域名 $IMPORT_DOMAIN 的 Nginx 配置文件: $EXISTING_NGINX_CONF_PATH"
    sleep 1

    local EXISTING_JSON_ENTRY=$(jq -c ".[] | select(.domain == \"$IMPORT_DOMAIN\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
    if [[ -n "$EXISTING_JSON_ENTRY" ]]; then
        log_message YELLOW "⚠️ 域名 $IMPORT_DOMAIN 已存在于本脚本的管理列表中。"
        read -rp "是否要覆盖现有项目元数据？[y/N]: " OVERWRITE_CONFIRM
        OVERWRITE_CONFIRM=${OVERWRITE_CONFIRM:-n}
        if [[ ! "$OVERWRITE_CONFIRM" =~ ^[Yy]$ ]]; then
            log_message RED "❌ 已取消导入操作。"
            return 1
        fi
        log_message YELLOW "ℹ️ 将覆盖域名 $IMPORT_DOMAIN 的现有项目元数据。"
    fi
    sleep 1

    local PROXY_TARGET_URL_GUESS=""
    local PROJECT_TYPE_GUESS="unknown"
    local PROJECT_DETAIL_GUESS="unknown"
    local PORT_TO_USE_GUESS="unknown"

    local PROXY_PASS_LINE=$(grep -E '^\s*proxy_pass\s+http://' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*proxy_pass\s+//;s/;//' || echo "")
    if [[ -n "$PROXY_PASS_LINE" ]]; then
        PROXY_TARGET_URL_GUESS="$PROXY_PASS_LINE"
        local TARGET_HOST_PORT=$(echo "$PROXY_PASS_LINE" | sed -E 's/http:\/\/(.*)/\1/' | sed 's|/.*||' || echo "")
        local TARGET_HOST=$(echo "$TARGET_HOST_PORT" | cut -d: -f1 || echo "")
        local TARGET_PORT=$(echo "$TARGET_HOST_PORT" | cut -d: -f2 || echo "")

        if [[ "$TARGET_HOST" == "127.0.0.1" || "$TARGET_HOST" == "localhost" ]]; then
            PROJECT_TYPE_GUESS="local_port"
            PROJECT_DETAIL_GUESS="$TARGET_PORT"
            PORT_TO_USE_GUESS="$TARGET_PORT"
        else
            if [ "$DOCKER_INSTALLED" = true ] && [[ -n "$TARGET_HOST" ]] && docker ps --format '{{.Names}}' | grep -wq "$TARGET_HOST"; then
                 PROJECT_TYPE_GUESS="docker"
                 PROJECT_DETAIL_GUESS="$TARGET_HOST"
                 PORT_TO_USE_GUESS="$TARGET_PORT"
            else
                 PROJECT_TYPE_GUESS="custom_host"
                 PROJECT_DETAIL_GUESS="$TARGET_HOST_PORT"
                 PORT_TO_USE_GUESS="$TARGET_PORT"
            fi
        fi
        log_message GREEN "✅ 从 Nginx 配置中解析到代理目标: ${PROXY_TARGET_URL_GUESS}"
    else
        log_message YELLOW "⚠️ 未能从 Nginx 配置中自动解析到 proxy_pass 目标。"
    fi

    log_message INFO "\n请确认或输入后端代理目标信息 (例如：docker容器名 或 本地端口):"
    log_message INFO "  [当前解析/建议值: ${PROJECT_DETAIL_GUESS} (类型: ${PROJECT_TYPE_GUESS}, 端口: ${PORT_TO_USE_GUESS})]"
    read -rp "输入目标（回车不修改）: " USER_TARGET_INPUT
    
    local FINAL_PROJECT_TYPE="$PROJECT_TYPE_GUESS"
    local FINAL_PROJECT_NAME="$PROJECT_DETAIL_GUESS"
    local FINAL_RESOLVED_PORT="$PORT_TO_USE_GUESS"
    local FINAL_PROXY_TARGET_URL="$PROXY_TARGET_URL_GUESS"

    if [[ -n "$USER_TARGET_INPUT" ]]; then
        if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$USER_TARGET_INPUT"; then
            FINAL_PROJECT_NAME="$USER_TARGET_INPUT"
            FINAL_PROJECT_TYPE="docker"
            local HOST_MAPPED_PORT=$(docker inspect "$USER_TARGET_INPUT" --format \
                '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
                sed 's|/tcp||g' | awk '{print $1}' | head -n1 || echo "")
            if [[ -n "$HOST_MAPPED_PORT" ]]; then
                FINAL_RESOLVED_PORT="$HOST_MAPPED_PORT"
                FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
                log_message GREEN "✅ 新目标是 Docker 容器 $FINAL_PROJECT_NAME，映射端口: $FINAL_RESOLVED_PORT。"
            else
                local INTERNAL_EXPOSED_PORTS_ARRAY=()
                while IFS= read -r port_entry; do
                    INTERNAL_EXPOSED_PORTS_ARRAY+=("$port_entry")
                done < <(docker inspect "$USER_TARGET_INPUT" --format '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | sed 's|/tcp||g' | xargs -n1)

                log_message YELLOW "⚠️ 未检测到容器 $USER_TARGET_INPUT 映射到宿主机的端口。内部暴露端口: ${INTERNAL_EXPOSED_PORTS_ARRAY[*]}。"
                while true; do
                    read -rp "请输入要代理到的容器内部端口 (例如 8080): " USER_INTERNAL_PORT_IMPORT
                    if [[ "$USER_INTERNAL_PORT_IMPORT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT_IMPORT > 0 && USER_INTERNAL_PORT_IMPORT < 65536 )); then
                        FINAL_RESOLVED_PORT="$USER_INTERNAL_PORT_IMPORT"
                        FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
                        log_message GREEN "✅ 将代理到容器 $FINAL_PROJECT_NAME 的内部端口: $FINAL_RESOLVED_PORT。"
                        break
                    else
                        log_message RED "❌ 输入的端口无效。请重新输入一个有效的端口号 (1-65535)。"
                    fi
                done
            fi
        elif [[ "$USER_TARGET_INPUT" =~ ^[0-9]+$ ]]; then
            FINAL_PROJECT_NAME="$USER_TARGET_INPUT"
            FINAL_PROJECT_TYPE="local_port"
            FINAL_RESOLVED_PORT="$USER_TARGET_INPUT"
            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
            log_message GREEN "✅ 新目标是本地端口: $FINAL_RESOLVED_PORT。"
        else
            log_message RED "❌ 无效的后端目标输入。将使用解析到的默认值 (如果存在)。"
        fi
    fi
    sleep 1

    local DEFAULT_CRT_PATH="$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.cer"
    local DEFAULT_KEY_PATH="$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.key"
    local SSL_CRT_PATH=$(grep -E '^\s*ssl_certificate\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate\s+//;s/;//' || echo "")
    local SSL_KEY_PATH=$(grep -E '^\s*ssl_certificate_key\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate_key\s+//;s/;//' || echo "")

    read -rp "请输入证书文件 (fullchain) 路径 [默认解析值: ${SSL_CRT_PATH:-$DEFAULT_CRT_PATH}，回车不修改]: " USER_CRT_PATH
    USER_CRT_PATH=${USER_CRT_PATH:-"${SSL_CRT_PATH:-$DEFAULT_CRT_PATH}"}
    if [ ! -f "$USER_CRT_PATH" ]; then
        log_message YELLOW "⚠️ 证书文件 $USER_CRT_PATH 不存在。请确保路径正确，否则后续续期可能失败。"
    else
        log_message GREEN "✅ 证书文件路径: $USER_CRT_PATH"
    fi

    read -rp "请输入证书私钥文件路径 [默认解析值: ${SSL_KEY_PATH:-$DEFAULT_KEY_PATH}，回车不修改]: " USER_KEY_PATH
    USER_KEY_PATH=${USER_KEY_PATH:-"${SSL_KEY_PATH:-$DEFAULT_KEY_PATH}"}
    if [ ! -f "$USER_KEY_PATH" ]; then
        log_message YELLOW "⚠️ 证书私钥文件 $USER_KEY_PATH 不存在。请确保路径正确，否则后续续期可能失败。"
    else
        log_message GREEN "✅ 私钥文件路径: $USER_KEY_PATH"
    fi
    sleep 1
    
    local DEFAULT_SNIPPET_DIR="$NGINX_CUSTOM_SNIPPETS_DIR"
    local DEFAULT_SNIPPET_FILENAME=""
    if [ "$FINAL_PROJECT_TYPE" = "docker" ]; then
        DEFAULT_SNIPPET_FILENAME="$FINAL_PROJECT_NAME.conf"
    else
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
            log_message YELLOW "⚠️ 自定义片段文件 $IMPORTED_CUSTOM_SNIPPET 不存在。请确保路径正确。"
        else
            log_message GREEN "✅ 自定义片段文件路径: $IMPORTED_CUSTOM_SNIPPET"
        fi
    fi
    sleep 1

    local IMPORTED_ACME_METHOD="imported"
    local IMPORTED_DNS_PROVIDER="none"
    local IMPORTED_WILDCARD="n"
    local IMPORTED_CA_URL="unknown"
    local IMPORTED_CA_NAME="imported"

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
    
    if [[ -n "$EXISTING_JSON_ENTRY" ]]; then
        if ! jq "(.[] | select(.domain == \"$IMPORT_DOMAIN\")) = $NEW_PROJECT_JSON" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message RED "❌ 更新项目元数据失败！"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    else
        if ! jq ". + [$NEW_PROJECT_JSON]" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message RED "❌ 写入项目元数据失败！"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    fi

    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
    log_message GREEN "✅ 域名 $IMPORT_DOMAIN 的 Nginx 配置已成功导入到脚本管理列表。"
    log_message YELLOW "ℹ️ 注意：导入的项目，其证书签发机构和验证方式被标记为 'imported'/'unknown'。"
    log_message YELLOW "   如果您希望由本脚本的 acme.sh 自动续期，请手动选择 '编辑项目核心配置'，并设置正确的验证方式，然后重新申请证书。"

    log_message INFO "=============================================="
    sleep 1
    return 0
}

# -----------------------------
# 查看和管理已配置项目的函数
manage_configs() {
    check_root
    log_message INFO "=============================================="
    log_message INFO "📜 已配置项目列表及证书状态"
    log_message INFO "=============================================="

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        log_message YELLOW "未找到任何已配置的项目。"
        log_message INFO "=============================================="
        read -rp "没有找到已配置项目。是否立即导入一个现有 Nginx 配置？[y/N]: " IMPORT_NOW
        IMPORT_NOW=${IMPORT_NOW:-n}
        if [[ "$IMPORT_NOW" =~ ^[Yy]$ ]]; then
            import_existing_project
            return 0 # 导入后返回顶层菜单，再次显示列表
        else
            return 0
        fi
    fi

    local PROJECTS_ARRAY_RAW=$(jq -c . "$PROJECTS_METADATA_FILE")
    local INDEX=0
    
    # Header for the table (调整列宽)
    printf "${BLUE}%-4s | %-25s | %-8s | %-25s | %-10s | %-18s | %-4s | %-5s | %4s天 | %s${RESET}\n" \
        "ID" "域名" "类型" "目标" "片段" "验证" "泛域" "状态" "剩余" "到期时间"
    log_message BLUE "----------------------------------------------------------------------------------------------------------------------------------------"

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
        local CERT_FILE=$(echo "$project_json" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN"'.cer"') # Use stored cert_file, fallback for old
        local KEY_FILE=$(echo "$project_json" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN"'.key"')   # Use stored key_file, fallback for old

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

        printf "${MAGENTA}%-4s | %-25s | %-8s | %-25s | %-10s | %-18s | %-4s | ${STATUS_COLOR}%-5s${RESET} | %4s天 | %s\n" \
            "$INDEX" "$DOMAIN" "$PROJECT_TYPE_DISPLAY" "$PROJECT_DETAIL_DISPLAY" "$CUSTOM_SNIPPET_FILE_DISPLAY" "$ACME_METHOD_DISPLAY" "$WILDCARD_DISPLAY" "$STATUS_TEXT" "$LEFT_DAYS" "$FORMATTED_END_DATE"
    done

    log_message INFO "=============================================="

    while true; do
        log_message BLUE "\n请选择管理操作："
        echo "1. 手动续期指定域名证书"
        echo "2. 删除指定域名配置及证书"
        echo "3. 编辑项目核心配置 (后端目标 / 验证方式等)"
        echo "4. 管理自定义 Nginx 配置片段 (添加 / 修改 / 清除)"
        echo "5. 导入现有 Nginx 配置到本脚本管理"
        echo "0. 返回主菜单"
        read -rp "请输入选项 [回车返回]: " MANAGE_CHOICE
        MANAGE_CHOICE=${MANAGE_CHOICE:-0}
        case "$MANAGE_CHOICE" in
            1) # 手动续期
                read -rp "请输入要续期的域名: " DOMAIN_TO_RENEW
                if [[ -z "$DOMAIN_TO_RENEW" ]]; then
                    log_message RED "❌ 域名不能为空！"
                    continue
                fi
                local RENEW_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_RENEW\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$RENEW_PROJECT_JSON" ]; then
                    log_message RED "❌ 域名 $DOMAIN_TO_RENEW 未找到在已配置列表中。"
                    continue
                fi
                
                local RENEW_ACME_VALIDATION_METHOD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.acme_validation_method')
                local RENEW_DNS_API_PROVIDER=$(echo "$RENEW_PROJECT_JSON" | jq -r '.dns_api_provider')
                local RENEW_USE_WILDCARD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.use_wildcard')
                local RENEW_CA_SERVER_URL=$(echo "$RENEW_PROJECT_JSON" | jq -r '.ca_server_url')

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "imported" ]; then 
                    log_message YELLOW "ℹ️ 域名 $DOMAIN_TO_RENEW 的证书是导入的，本脚本无法直接续期。请手动或通过 '编辑项目核心配置' 转换为 acme.sh 管理。"
                    continue
                fi

                log_message GREEN "🚀 正在为 $DOMAIN_TO_RENEW 续期证书 (验证方式: ${RENEW_ACME_VALIDATION_METHOD})..."
                sleep 1
                local RENEW_CMD_LOG_OUTPUT=$(mktemp)

                # 自动续期不强制使用 --force
                local RENEW_COMMAND="$ACME_BIN --renew -d \"$DOMAIN_TO_RENEW\" --ecc --server \"$RENEW_CA_SERVER_URL\""
                if [ "$RENEW_USE_WILDCARD" = "y" ]; then
                    RENEW_COMMAND+=" -d \"*.$DOMAIN_TO_RENEW\""
                fi

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                    # 临时 Nginx 配置
                    log_message YELLOW "生成 Nginx 临时 HTTP 配置以进行证书验证..."
                    _NGINX_HTTP_CHALLENGE_TEMPLATE "$DOMAIN_TO_RENEW" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_RENEW.conf"
                    if [ ! -L "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_RENEW.conf" ]; then
                        ln -sf "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_RENEW.conf" "$NGINX_SITES_ENABLED_DIR/"
                    fi
                    if ! control_nginx restart; then
                         log_message ERROR "Nginx 重启失败，无法进行 HTTP-01 验证，续期失败。"
                         rm -f "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_RENEW.conf"
                         rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_RENEW.conf"
                         continue
                    fi

                    RENEW_COMMAND+=" -w \"$NGINX_WEBROOT_DIR\""
                elif [ "$RENEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                    RENEW_COMMAND+=" --dns $RENEW_DNS_API_PROVIDER"
                    log_message YELLOW "⚠️ 续期 DNS 验证证书需要设置相应的 DNS API 环境变量。"
                    if ! check_dns_env "$RENEW_DNS_API_PROVIDER"; then
                        log_message ERROR "DNS 环境变量检查失败，跳过域名 $DOMAIN_TO_RENEW 的证书续期。"
                        continue
                    fi
                fi

                if ! eval "$RENEW_COMMAND" > "$RENEW_CMD_LOG_OUTPUT" 2>&1; then
                    log_message RED "❌ 续期失败：$DOMAIN_TO_RENEW。"
                    cat "$RENEW_CMD_LOG_OUTPUT"
                    analyze_acme_error "$(cat "$RENEW_CMD_LOG_OUTPUT")"
                    rm -f "$RENEW_CMD_LOG_OUTPUT"
                    # 如果是 http-01 失败，尝试恢复 Nginx 配置
                    if [ "$RENEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                        local PROXY_TARGET_URL_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.name' | awk '{print "http://127.0.0.1:" $1}') # 简化获取目标
                        local CERT_FILE_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_RENEW"'.cer"')
                        local KEY_FILE_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_RENEW"'.key"')
                        local CUSTOM_SNIPPET_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.custom_snippet')
                        _NGINX_FINAL_TEMPLATE "$DOMAIN_TO_RENEW" "$PROXY_TARGET_URL_RENEW" "$CERT_FILE_RENEW" "$KEY_FILE_RENEW" "$CUSTOM_SNIPPET_RENEW" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_RENEW.conf"
                        control_nginx reload
                    fi
                    continue
                fi
                rm -f "$RENEW_CMD_LOG_OUTPUT"

                log_message GREEN "✅ 续期完成：$DOMAIN_TO_RENEW"
                sleep 1
                # 重新安装证书 (acme.sh 的 reloadcmd 可能会处理，但在此确保一下)
                local INSTALLED_CRT_FILE_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_RENEW"'.cer"')
                local INSTALLED_KEY_FILE_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_RENEW"'.key"')
                local RELOAD_DOMAINS="-d \"$DOMAIN_TO_RENEW\""
                if [ "$RENEW_USE_WILDCARD" = "y" ]; then RELOAD_DOMAINS+=" -d \"*.$DOMAIN_TO_RENEW\""; fi
                "$ACME_BIN" --install-cert $RELOAD_DOMAINS --ecc \
                    --key-file "$INSTALLED_KEY_FILE_RENEW" \
                    --fullchain-file "$INSTALLED_CRT_FILE_RENEW" \
                    --reloadcmd "systemctl reload nginx"
                
                # 如果是 http-01 验证，需要重新生成最终 Nginx 配置
                if [ "$RENEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                    local PROXY_TARGET_URL_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.name' | awk '{print "http://127.0.0.1:" $1}') # 简化获取目标
                    local CERT_FILE_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_RENEW"'.cer"')
                    local KEY_FILE_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_RENEW"'.key"')
                    local CUSTOM_SNIPPET_RENEW=$(echo "$RENEW_PROJECT_JSON" | jq -r '.custom_snippet')
                    _NGINX_FINAL_TEMPLATE "$DOMAIN_TO_RENEW" "$PROXY_TARGET_URL_RENEW" "$CERT_FILE_RENEW" "$KEY_FILE_RENEW" "$CUSTOM_SNIPPET_RENEW" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_RENEW.conf"
                    control_nginx reload
                fi
                ;;
            2) # 删除
                read -rp "请输入要删除的域名: " DOMAIN_TO_DELETE
                if [[ -z "$DOMAIN_TO_DELETE" ]]; then
                    log_message RED "❌ 域名不能为空！"
                    continue
                fi
                local PROJECT_TO_DELETE_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_DELETE\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$PROJECT_TO_DELETE_JSON" ]; then
                    log_message RED "❌ 域名 $DOMAIN_TO_DELETE 未找到在已配置列表中。"
                    continue
                fi
                read -rp "⚠️ 确认删除域名 ${DOMAIN_TO_DELETE} 的所有 Nginx 配置和证书？此操作不可恢复！[y/N]: " CONFIRM_DELETE
                CONFIRM_DELETE=${CONFIRM_DELETE:-n}
                if [[ "$CONFIRM_DELETE" =~ ^[Yy]$ ]]; then
                    log_message YELLOW "正在删除 ${DOMAIN_TO_DELETE}..."
                    sleep 1
                    
                    local CUSTOM_SNIPPET_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.custom_snippet')
                    local CERT_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_DELETE"'.cer"') 
                    local KEY_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_DELETE"'.key"')   

                    "$ACME_BIN" --remove -d "$DOMAIN_TO_DELETE" --ecc 2>/dev/null || true 
                    
                    rm -f "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_DELETE.conf"
                    rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_DELETE.conf"
                    
                    if [[ "$CERT_FILE_TO_DELETE" == "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE.cer" && "$KEY_FILE_TO_DELETE" == "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE.key" ]]; then
                        if [ -f "$CERT_FILE_TO_DELETE" ]; then rm -f "$CERT_FILE_TO_DELETE"; fi
                        if [ -f "$KEY_FILE_TO_DELETE" ]; then rm -f "$KEY_FILE_TO_DELETE"; fi
                        if [ -d "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE" ] && [ -z "$(ls -A "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE")" ]; then
                             rmdir "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE"
                             log_message GREEN "✅ 已删除默认证书目录 $SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE"
                        fi
                    else
                        if [ -f "$CERT_FILE_TO_DELETE" ]; then rm -f "$CERT_FILE_TO_DELETE"; fi
                        if [ -f "$KEY_FILE_TO_DELETE" ]; then rm -f "$KEY_FILE_TO_DELETE"; fi
                        log_message GREEN "✅ 已删除证书文件: $CERT_FILE_TO_DELETE 和 $KEY_FILE_TO_DELETE"
                    fi

                    if [[ -n "$CUSTOM_SNIPPET_FILE_TO_DELETE" && "$CUSTOM_SNIPPET_FILE_TO_DELETE" != "null" && -f "$CUSTOM_SNIPPET_FILE_TO_DELETE" ]]; then
                        read -rp "检测到自定义 Nginx 配置片段文件 '$CUSTOM_SNIPPET_FILE_TO_DELETE'，是否一并删除？[y/N]: " DELETE_SNIPPET_CONFIRM
                        DELETE_SNIPPET_CONFIRM=${DELETE_SNIPPET_CONFIRM:-y}
                        if [[ "$DELETE_SNIPPET_CONFIRM" =~ ^[Yy]$ ]]; then
                            rm -f "$CUSTOM_SNIPPET_FILE_TO_DELETE"
                            log_message GREEN "✅ 已删除自定义 Nginx 片段文件: $CUSTOM_SNIPPET_FILE_TO_DELETE"
                        else
                            log_message YELLOW "ℹ️ 已保留自定义 Nginx 片段文件: $CUSTOM_SNIPPET_FILE_TO_DELETE"
                        fi
                    fi

                    if ! jq "del(.[] | select(.domain == \"$DOMAIN_TO_DELETE\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                        log_message RED "❌ 从元数据中移除项目失败！"
                    else
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        log_message GREEN "✅ 已从元数据中移除项目 $DOMAIN_TO_DELETE。"
                    fi

                    log_message GREEN "✅ 已删除域名 ${DOMAIN_TO_DELETE} 的相关配置和证书文件。"
                    control_nginx reload 2>/dev/null || true # 静默重载，如果 Nginx 已经没有配置，会报错但不需要影响主流程
                else
                    log_message YELLOW "已取消删除操作。"
                fi
                sleep 1
                ;;
            3) # 编辑项目核心配置 (不含片段)
                read -rp "请输入要编辑的域名: " DOMAIN_TO_EDIT
                if [[ -z "$DOMAIN_TO_EDIT" ]]; then
                    log_message RED "❌ 域名不能为空！"
                    continue
                fi
                local CURRENT_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_EDIT\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$CURRENT_PROJECT_JSON" ]; then
                    log_message RED "❌ 域名 $DOMAIN_TO_EDIT 未找到在已配置列表中。"
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
                local EDIT_CERT_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_EDIT"'.cer"') 
                local EDIT_KEY_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_TO_EDIT"'.key"')     

                log_message INFO "\n--- 编辑域名: ${BLUE}$DOMAIN_TO_EDIT${RESET} ---"
                log_message INFO "当前配置:"
                log_message INFO "  类型: $EDIT_TYPE"
                log_message INFO "  目标: $EDIT_NAME (端口: $EDIT_RESOLVED_PORT)"
                log_message INFO "  验证方式: $EDIT_ACME_VALIDATION_METHOD $( [[ -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]] && echo "($EDIT_DNS_API_PROVIDER)" || echo "" )"
                log_message INFO "  泛域名: $( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "是" || echo "否" )"
                log_message INFO "  CA: $EDIT_CA_SERVER_NAME"
                log_message INFO "  证书文件: $EDIT_CERT_FILE"
                log_message INFO "  私钥文件: $EDIT_KEY_FILE"
                sleep 1

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
                local FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT" # Initial value, will update
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
                            log_message GREEN "✅ 新目标是 Docker 容器 $NEW_NAME，映射端口: $NEW_RESOLVED_PORT。"
                        else
                            INTERNAL_EXPOSED_PORTS_ARRAY=()
                            while IFS= read -r port_entry; do
                                INTERNAL_EXPOSED_PORTS_ARRAY+=("$port_entry")
                            done < <(docker inspect "$NEW_TARGET_INPUT" --format '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | sed 's|/tcp||g' | xargs -n1)

                            log_message YELLOW "⚠️ 容器 $NEW_TARGET_INPUT 未映射到宿主机端口。内部暴露端口: ${INTERNAL_EXPOSED_PORTS_ARRAY[*]}。"
                            while true; do
                                read -rp "请输入要代理到的容器内部端口: " USER_INTERNAL_PORT_EDIT
                                if [[ "$USER_INTERNAL_PORT_EDIT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT_EDIT > 0 && USER_INTERNAL_PORT_EDIT < 65536 )); then
                                    NEW_RESOLVED_PORT="$USER_INTERNAL_PORT_EDIT"
                                    FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                                    log_message GREEN "✅ 将代理到容器 $NEW_NAME 的内部端口: $NEW_RESOLVED_PORT。"
                                    break
                                else
                                    log_message RED "❌ 输入的端口无效。"
                                fi
                            done
                        fi
                    elif [[ "$NEW_TARGET_INPUT" =~ ^[0-9]+$ ]]; then
                        NEW_NAME="$NEW_TARGET_INPUT"
                        NEW_TYPE="local_port"
                        NEW_RESOLVED_PORT="$NEW_TARGET_INPUT"
                        FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                        log_message GREEN "✅ 新目标是本地端口: $NEW_RESOLVED_PORT。"
                    else
                        log_message RED "❌ 无效的后端目标输入。将保留原有目标。"
                        NEW_TYPE="$EDIT_TYPE" # Reset to old values if invalid input
                        NEW_NAME="$EDIT_NAME"
                        NEW_RESOLVED_PORT="$EDIT_RESOLVED_PORT"
                        NEED_REISSUE_OR_RELOAD_NGINX="n"
                    fi
                fi
                sleep 1

                # 编辑验证方式和泛域名
                read -rp "修改证书验证方式 (http-01 / dns-01) [当前: $EDIT_ACME_VALIDATION_METHOD，回车不修改]: " NEW_VALIDATION_METHOD_INPUT
                NEW_VALIDATION_METHOD_INPUT=${NEW_VALIDATION_METHOD_INPUT:-$EDIT_ACME_VALIDATION_METHOD}
                if [[ "$NEW_VALIDATION_METHOD_INPUT" != "$EDIT_ACME_VALIDATION_METHOD" ]]; then
                    if [[ "$NEW_VALIDATION_METHOD_INPUT" = "http-01" || "$NEW_VALIDATION_METHOD_INPUT" = "dns-01" ]]; then
                        NEW_ACME_VALIDATION_METHOD="$NEW_VALIDATION_METHOD_INPUT"
                        log_message GREEN "✅ 验证方式已更新为: $NEW_ACME_VALIDATION_METHOD。"
                        NEED_REISSUE_OR_RELOAD_NGINX="y" # 验证方式改变，需要重新申请证书
                        NEW_CA_SERVER_NAME="letsencrypt" # Default CA for new validation setup
                        NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                        # Reset cert file paths to default for acme.sh management
                        NEW_CERT_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer"
                        NEW_KEY_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                    else
                        log_message RED "❌ 无效的验证方式。将保留原有设置。"
                    fi
                fi
                sleep 1

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
                    log_message GREEN "✅ 泛域名设置已更新为: $NEW_USE_WILDCARD。"
                    sleep 1

                    read -rp "修改 DNS API 服务商 (dns_cf / dns_ali) [当前: $EDIT_DNS_API_PROVIDER，回车不修改]: " NEW_DNS_PROVIDER_INPUT
                    NEW_DNS_PROVIDER_INPUT=${NEW_DNS_PROVIDER_INPUT:-$EDIT_DNS_API_PROVIDER}
                    if [[ "$NEW_DNS_PROVIDER_INPUT" != "$EDIT_DNS_API_PROVIDER" ]]; then
                        if [[ "$NEW_DNS_PROVIDER_INPUT" = "dns_cf" || "$NEW_DNS_PROVIDER_INPUT" = "dns_ali" ]]; then
                            NEW_DNS_API_PROVIDER="$NEW_DNS_PROVIDER_INPUT"
                            log_message GREEN "✅ DNS API 服务商已更新为: $NEW_DNS_API_PROVIDER。"
                            NEED_REISSUE_OR_RELOAD_NGINX="y"
                        else
                            log_message RED "❌ 无效的 DNS 服务商。将保留原有设置。"
                        fi
                    fi
                    if [ "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]; then
                        if ! check_dns_env "$NEW_DNS_API_PROVIDER"; then
                            log_message ERROR "DNS 环境变量检查失败，请重新设置。"
                            continue
                        fi
                    fi
                else # 如果是非 dns-01 验证，泛域名和 DNS API 设为空
                    if [[ "$EDIT_USE_WILDCARD" = "y" || -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                    NEW_USE_WILDCARD="n"
                    NEW_DNS_API_PROVIDER=""
                fi
                sleep 1

                # 再次询问 CA (如果在导入后，或从 imported 切换到 acme.sh 托管)
                if [[ "$EDIT_ACME_VALIDATION_METHOD" = "imported" || "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]]; then
                    log_message INFO "\n请选择新的证书颁发机构 (CA):"
                    echo "1) Let's Encrypt (当前: ${NEW_CA_SERVER_NAME:-letsencrypt})"
                    echo "2) ZeroSSL"
                    echo "3) 自定义 ACME 服务器 URL" # 新增
                    read -rp "请输入序号 [1]: " NEW_CA_CHOICE
                    NEW_CA_CHOICE=${NEW_CA_CHOICE:-1}
                    case $NEW_CA_CHOICE in
                        1) NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; NEW_CA_SERVER_NAME="letsencrypt";;
                        2) NEW_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; NEW_CA_SERVER_NAME="zerossl";;
                        3) # 新增自定义逻辑
                            read -rp "请输入自定义 ACME 服务器 URL: " CUSTOM_ACME_URL
                            if [[ -n "$CUSTOM_ACME_URL" ]]; then
                                NEW_CA_SERVER_URL="$CUSTOM_ACME_URL"
                                NEW_CA_SERVER_NAME="Custom"
                                log_message INFO "⚠️ 正在使用自定义 ACME 服务器 URL。请确保其有效。"
                            else
                                log_message YELLOW "未输入自定义 URL，将使用默认 Let's Encrypt。"
                                NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; NEW_CA_SERVER_NAME="letsencrypt";
                            fi
                            ;;
                        *) log_message YELLOW "⚠️ 无效选择，将使用默认 Let's Encrypt。";;
                    esac
                    log_message BLUE "➡️ 选定新的 CA: $NEW_CA_SERVER_NAME"
                    # 检查并注册 ZeroSSL 账户
                    if [ "$NEW_CA_SERVER_NAME" = "zerossl" ]; then
                         log_message BLUE "🔍 检查 ZeroSSL 账户注册状态..."
                         if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
                            log_message YELLOW "⚠️ 未检测到 ZeroSSL 账户已注册。"
                            read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " NEW_ZERO_SSL_ACCOUNT_EMAIL
                            while [[ ! "$NEW_ZERO_SSL_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                                log_message RED "❌ 邮箱格式不正确。请重新输入。"
                                read -rp "请输入用于注册 ZeroSSL 的邮箱地址: " NEW_ZERO_SSL_ACCOUNT_EMAIL
                            done
                            log_message BLUE "➡️ 正在注册 ZeroSSL 账户: $NEW_ZERO_SSL_ACCOUNT_EMAIL..."
                            "$ACME_BIN" --register-account -m "$NEW_ZERO_SSL_ACCOUNT_EMAIL" --server "$NEW_CA_SERVER_URL" || {
                                log_message RED "❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。"
                                return 1
                            }
                            log_message GREEN "✅ ZeroSSL 账户注册成功。"
                         else
                            log_message GREEN "✅ ZeroSSL 账户已注册。"
                         fi
                    fi
                fi
                sleep 1

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
                    log_message RED "❌ 更新项目元数据失败！"
                else
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    log_message GREEN "✅ 项目元数据已更新。"
                fi
                sleep 1

                # 如果有关键修改，提示重新申请证书和更新Nginx配置
                if [ "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]; then
                    log_message YELLOW "ℹ️ 检测到与证书或 Nginx 配置相关的关键修改。"
                    read -rp "是否立即更新 Nginx 配置并尝试重新申请证书？(强烈建议) [y/N]: " UPDATE_NOW
                    UPDATE_NOW=${UPDATE_NOW:-y}
                    if [[ "$UPDATE_NOW" =~ ^[Yy]$ ]]; then
                        log_message YELLOW "重新生成 Nginx 配置并申请证书..."
                        
                        # 重新生成 Nginx 临时配置（仅当使用 http-01 验证时）
                        if [ "$NEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                            log_message YELLOW "生成 Nginx 临时 HTTP 配置以进行证书验证..."
                            DOMAIN_CONF="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_EDIT.conf" # 确保 DOMAIN_CONF 被正确设置
                            _NGINX_HTTP_CHALLENGE_TEMPLATE "$DOMAIN_TO_EDIT" > "$DOMAIN_CONF"
                            if [ ! -L "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_EDIT.conf" ]; then
                                ln -sf "$DOMAIN_CONF" "$NGINX_SITES_ENABLED_DIR/"
                            fi
                            if ! control_nginx restart; then
                                log_message ERROR "Nginx 启动失败，无法进行 HTTP-01 验证，证书申请失败。"
                                return 1 # Re-issue failed, exit edit mode
                            fi
                            log_message GREEN "✅ Nginx 已重启，准备申请证书。"
                            sleep 1
                        fi

                        # 申请证书
                        log_message YELLOW "正在为 $DOMAIN_TO_EDIT 申请证书 (CA: $NEW_CA_SERVER_NAME, 验证方式: $NEW_ACME_VALIDATION_METHOD)..."
                        local ACME_REISSUE_CMD_LOG_OUTPUT=$(mktemp)
                        ACME_REISSUE_COMMAND="$ACME_BIN --issue --force -d \"$DOMAIN_TO_EDIT\" --ecc --server \"$NEW_CA_SERVER_URL\"" # 重新添加 --force
                        if [ "$NEW_USE_WILDCARD" = "y" ]; then
                            ACME_REISSUE_COMMAND+=" -d \"*.$DOMAIN_TO_EDIT\""
                        fi
                        if [ "$NEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                            ACME_REISSUE_COMMAND+=" -w \"$NGINX_WEBROOT_DIR\""
                        elif [ "$NEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                            ACME_REISSUE_COMMAND+=" --dns $NEW_DNS_API_PROVIDER"
                        fi

                        if ! eval "$ACME_REISSUE_COMMAND" > "$ACME_REISSUE_CMD_LOG_OUTPUT" 2>&1; then
                            log_message RED "❌ 域名 $DOMAIN_TO_EDIT 的证书重新申请失败！"
                            cat "$ACME_REISSUE_CMD_LOG_OUTPUT"
                            analyze_acme_error "$(cat "$ACME_REISSUE_CMD_LOG_OUTPUT")"
                            rm -f "$ACME_REISSUE_CMD_LOG_OUTPUT"
                            return 1 # Re-issue failed, exit edit mode
                        fi
                        rm -f "$ACME_REISSUE_CMD_LOG_OUTPUT"
                        
                        # 更新证书文件路径到元数据中
                        NEW_CERT_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer"
                        NEW_KEY_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                        local LATEST_ACME_CERT_JSON=$(jq -n \
                            --arg domain "$DOMAIN_TO_EDIT" \
                            --arg cert_file "$NEW_CERT_FILE" \
                            --arg key_file "$NEW_KEY_FILE" \
                            '{domain: $domain, cert_file: $cert_file, key_file: $key_file}')
                        jq "(.[] | select(.domain == \"$DOMAIN_TO_EDIT\")) |= . + $LATEST_ACME_CERT_JSON" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp" && \
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        log_message GREEN "✅ 证书已成功重新签发。"
                        sleep 1
                        
                        # 安装证书并生成最终 Nginx 配置
                        INSTALL_CERT_DOMAINS="-d \"$DOMAIN_TO_EDIT\""
                        if [ "$NEW_USE_WILDCARD" = "y" ]; then
                            INSTALL_CERT_DOMAINS+=" -d \"*.$DOMAIN_TO_EDIT\""
                        fi
                        "$ACME_BIN" --install-cert $INSTALL_CERT_DOMAINS --ecc \
                            --key-file "$NEW_KEY_FILE" \
                            --fullchain-file "$NEW_CERT_FILE" \
                            --fullchain-file "$NEW_CERT_FILE" \
                            --reloadcmd "systemctl reload nginx"
                        log_message YELLOW "生成 $DOMAIN_TO_EDIT 的最终 Nginx 配置..."
                        # 使用原始的 custom_snippet_path 进行 Nginx 配置生成
                        _NGINX_FINAL_TEMPLATE "$DOMAIN_TO_EDIT" "$FINAL_PROXY_TARGET_URL" "$NEW_CERT_FILE" "$NEW_KEY_FILE" "$EDIT_CUSTOM_SNIPPET_ORIGINAL" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_EDIT.conf"
                        log_message GREEN "✅ 域名 $DOMAIN_TO_EDIT 的 Nginx 配置已更新。"
                        if ! control_nginx reload; then
                            log_message ERROR "最终 Nginx 重载失败，请手动检查 Nginx 服务状态！"
                            return 1
                        fi
                        log_message GREEN "🚀 域名 $DOMAIN_TO_EDIT 配置更新完成。"
                    else
                        log_message YELLOW "ℹ️ 已跳过证书重新申请和 Nginx 配置更新。请手动操作以确保生效。"
                    fi
                else
                    log_message YELLOW "ℹ️ 项目配置已修改。请手动重新加载 Nginx (systemctl reload nginx) 以确保更改生效。"
                fi
                sleep 1
                ;;
            4) # 管理自定义 Nginx 配置片段 (添加 / 修改 / 清除)
                read -rp "请输入要管理片段的域名: " DOMAIN_FOR_SNIPPET
                if [[ -z "$DOMAIN_FOR_SNIPPET" ]]; then
                    log_message RED "❌ 域名不能为空！"
                    continue
                fi
                local SNIPPET_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_FOR_SNIPPET\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$SNIPPET_PROJECT_JSON" ]; then
                    log_message RED "❌ 域名 $DOMAIN_FOR_SNIPPET 未找到在已配置列表中。"
                    continue
                fi

                local CURRENT_SNIPPET_PATH=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.custom_snippet')
                local PROJECT_TYPE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.type')
                local PROJECT_NAME_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.name')
                local RESOLVED_PORT_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.resolved_port')
                local CERT_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_FOR_SNIPPET"'.cer"')
                local KEY_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN_FOR_SNIPPET"'.key"')


                log_message INFO "\n--- 管理域名 ${BLUE}$DOMAIN_FOR_SNIPPET${RESET} 的 Nginx 配置片段 ---"
                if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                    log_message YELLOW "当前自定义片段文件: ${YELLOW}$CURRENT_SNIPPET_PATH${RESET}"
                else
                    log_message INFO "当前未设置自定义片段文件。"
                fi
                sleep 1

                local DEFAULT_SNIPPET_DIR="$NGINX_CUSTOM_SNIPPETS_DIR"
                local DEFAULT_SNIPPET_FILENAME=""
                if [ "$PROJECT_TYPE_SNIPPET" = "docker" ]; then DEFAULT_SNIPPET_FILENAME="$PROJECT_NAME_SNIPPET.conf"; else DEFAULT_SNIPPET_FILENAME="$DOMAIN_FOR_SNIPPET.conf"; fi
                local DEFAULT_SNIPPET_PATH="$DEFAULT_SNIPPET_DIR/$DEFAULT_SNIPPET_FILENAME"

                read -rp "请输入新的片段文件路径 (回车用默认: $DEFAULT_SNIPPET_PATH, 输入 'none' 清除): " NEW_SNIPPET_INPUT
                local CHOSEN_SNIPPET_PATH=""

                if [[ -z "$NEW_SNIPPET_INPUT" ]]; then # 回车，使用默认路径
                    CHOSEN_SNIPPET_PATH="$DEFAULT_SNIPPET_PATH"
                    log_message GREEN "✅ 将使用默认路径: $CHOSEN_SNIPPET_PATH"
                elif [[ "$NEW_SNIPPET_INPUT" = "none" ]]; then # 输入 'none'，清除片段
                    CHOSEN_SNIPPET_PATH=""
                    log_message YELLOW "ℹ️ 已选择清除自定义 Nginx 片段。"
                else # 用户输入了新路径
                    CHOSEN_SNIPPET_PATH="$NEW_SNIPPET_INPUT"
                    if ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH")"; then
                        log_message RED "❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH")。操作取消。"
                        continue
                    fi
                    log_message GREEN "✅ 将使用新路径: $CHOSEN_SNIPPET_PATH"
                fi
                sleep 1

                # 更新 JSON 元数据
                local UPDATED_SNIPPET_JSON_OBJ=$(jq -n --arg custom_snippet "$CHOSEN_SNIPPET_PATH" '{custom_snippet: $custom_snippet}')
                if ! jq "(.[] | select(.domain == \"$DOMAIN_FOR_SNIPPET\")) |= . + $UPDATED_SNIPPET_JSON_OBJ" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    log_message RED "❌ 更新项目元数据失败！"
                    continue
                else
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    log_message GREEN "✅ 项目元数据中的自定义片段路径已更新。"
                fi
                sleep 1

                # 重新生成 Nginx 配置
                local PROXY_TARGET_URL_SNIPPET="http://127.0.0.1:$RESOLVED_PORT_SNIPPET"
                local DOMAIN_CONF_SNIPPET="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_FOR_SNIPPET.conf"

                log_message YELLOW "正在重新生成 $DOMAIN_FOR_SNIPPET 的 Nginx 配置..."
                _NGINX_FINAL_TEMPLATE "$DOMAIN_FOR_SNIPPET" "$PROXY_TARGET_URL_SNIPPET" "$CERT_FILE_SNIPPET" "$KEY_FILE_SNIPPET" "$CHOSEN_SNIPPET_PATH" > "$DOMAIN_CONF_SNIPPET"
                
                if ! control_nginx reload; then
                    log_message ERROR "Nginx 重载失败，请手动检查 Nginx 服务状态！"
                    continue
                fi
                log_message GREEN "🚀 域名 $DOMAIN_FOR_SNIPPET 的 Nginx 配置已更新并重载。"
                sleep 1

                # 如果原片段文件存在且现在已清除，询问是否删除文件
                if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" && -z "$CHOSEN_SNIPPET_PATH" && -f "$CURRENT_SNIPPET_PATH" ]]; then
                    read -rp "检测到原有自定义片段文件 '$CURRENT_SNIPPET_PATH'。是否删除此文件？[y/N]: " DELETE_OLD_SNIPPET_CONFIRM
                    DELETE_OLD_SNIPPET_CONFIRM=${DELETE_OLD_SNIPPET_CONFIRM:-y}
                    if [[ "$DELETE_OLD_SNIPPET_CONFIRM" =~ ^[Yy]$ ]]; then
                        rm -f "$CURRENT_SNIPPET_PATH"
                        log_message GREEN "✅ 已删除旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH"
                    else
                        log_message YELLOW "ℹ️ 已保留旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH"
                    fi
                fi
                sleep 1
                ;;
            5) # 导入现有 Nginx 配置到本脚本管理
                import_existing_project
                continue 
                ;;
            0)
                break
                ;;
            *)
                log_message RED "❌ 无效选项，请输入 0-5"
                ;;
        esac
    done
}

# -----------------------------
# 检查并自动续期所有证书的函数
check_and_auto_renew_certs() {
    check_root
    log_message INFO "=============================================="
    log_message INFO "🔄 检查并自动续期所有证书"
    log_message INFO "=============================================="
    sleep 1

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        log_message YELLOW "未找到任何已配置的项目，无需续期。"
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
        local CERT_FILE=$(echo "$project_json" | jq -r '.cert_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN"'.cer"') 
        local KEY_FILE=$(echo "$project_json" | jq -r '.key_file // "'"$SSL_CERTS_BASE_DIR"'/'"$DOMAIN"'.key"')   

        if [[ ! -f "$CERT_FILE" ]]; then
            log_message YELLOW "⚠️ 域名 $DOMAIN 证书文件 $CERT_FILE 不存在，跳过续期。"
            continue
        fi

        if [ "$ACME_VALIDATION_METHOD" = "imported" ]; then 
            log_message YELLOW "ℹ️ 域名 $DOMAIN 证书是导入的，本脚本无法自动续期。请手动或通过 '编辑项目核心配置' 转换为 acme.sh 管理。"
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
            log_message YELLOW "⚠️ 域名 $DOMAIN 证书即将到期 (${LEFT_DAYS}天剩余)，尝试自动续期 (验证方式: $ACME_VALIDATION_METHOD)..."
            local RENEW_CMD_LOG_OUTPUT=$(mktemp)

            # 自动续期不使用 --force
            local RENEW_COMMAND="$ACME_BIN --renew -d \"$DOMAIN\" --ecc --server \"$CA_SERVER_URL\""
            if [ "$USE_WILDCARD" = "y" ]; then
                RENEW_COMMAND+=" -d \"*.$DOMAIN\""
            fi

            if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                # 临时 Nginx 配置
                log_message YELLOW "生成 Nginx 临时 HTTP 配置以进行证书验证..."
                _NGINX_HTTP_CHALLENGE_TEMPLATE "$DOMAIN" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN.conf"
                if [ ! -L "$NGINX_SITES_ENABLED_DIR/$DOMAIN.conf" ]; then
                    ln -sf "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN.conf" "$NGINX_SITES_ENABLED_DIR/"
                fi
                if ! control_nginx restart; then
                     log_message ERROR "Nginx 重启失败，无法进行 HTTP-01 验证，续期失败。"
                     rm -f "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN.conf"
                     rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN.conf"
                     continue
                fi
                RENEW_COMMAND+=" -w \"$NGINX_WEBROOT_DIR\""
            elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
                RENEW_COMMAND+=" --dns $DNS_API_PROVIDER"
                log_message YELLOW "ℹ️ 续期 DNS 验证证书需要设置相应的 DNS API 环境变量。"
                if ! check_dns_env "$DNS_API_PROVIDER"; then
                    log_message ERROR "DNS 环境变量检查失败，跳过域名 $DOMAIN 的证书续期。"
                    continue
                fi
            fi

            if eval "$RENEW_COMMAND" > "$RENEW_CMD_LOG_OUTPUT" 2>&1; then
                log_message GREEN "✅ 域名 $DOMAIN 证书续期成功。"
                RENEWED_COUNT=$((RENEWED_COUNT + 1))
                # 如果是 http-01 验证，需要重新生成最终 Nginx 配置
                if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                    local PROJECT_TYPE_RENEW=$(echo "$project_json" | jq -r '.type')
                    local PROJECT_NAME_RENEW=$(echo "$project_json" | jq -r '.name')
                    local RESOLVED_PORT_RENEW=$(echo "$project_json" | jq -r '.resolved_port')
                    local PROXY_TARGET_URL_RENEW="http://127.0.0.1:$RESOLVED_PORT_RENEW"
                    local CUSTOM_SNIPPET_RENEW=$(echo "$project_json" | jq -r '.custom_snippet')
                    _NGINX_FINAL_TEMPLATE "$DOMAIN" "$PROXY_TARGET_URL_RENEW" "$CERT_FILE" "$KEY_FILE" "$CUSTOM_SNIPPET_RENEW" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN.conf"
                    control_nginx reload # 确保Nginx配置更新
                fi
            else
                log_message RED "❌ 域名 $DOMAIN 证书续期失败！"
                cat "$RENEW_CMD_LOG_OUTPUT"
                analyze_acme_error "$(cat "$RENEW_CMD_LOG_OUTPUT")"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                # 如果是 http-01 失败，尝试恢复 Nginx 配置
                if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                    local PROJECT_TYPE_RENEW=$(echo "$project_json" | jq -r '.type')
                    local PROJECT_NAME_RENEW=$(echo "$project_json" | jq -r '.name')
                    local RESOLVED_PORT_RENEW=$(echo "$project_json" | jq -r '.resolved_port')
                    local PROXY_TARGET_URL_RENEW="http://127.0.0.1:$RESOLVED_PORT_RENEW"
                    local CUSTOM_SNIPPET_RENEW=$(echo "$project_json" | jq -r '.custom_snippet')
                    _NGINX_FINAL_TEMPLATE "$DOMAIN" "$PROXY_TARGET_URL_RENEW" "$CERT_FILE" "$KEY_FILE" "$CUSTOM_SNIPPET_RENEW" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN.conf"
                    control_nginx reload
                fi
            fi
            rm -f "$RENEW_CMD_LOG_OUTPUT"
        else
            log_message INFO "✅ 域名 $DOMAIN 证书有效 (${LEFT_DAYS}天剩余)，无需续期。"
        fi
        sleep 1
    done

    log_message BLUE "\n--- 续期结果 ---"
    log_message GREEN "成功续期: $RENEWED_COUNT 个证书。"
    log_message RED "失败续期: $FAILED_COUNT 个证书。"
    log_message BLUE "--------------------------"
    
    log_message YELLOW "ℹ️ 建议设置一个 Cron 任务来定期自动执行此功能。"
    log_message YELLOW "   例如，每周执行一次（请将 '/path/to/your/script.sh' 替换为脚本的${RED}绝对路径${RESET}${YELLOW}）："
    log_message MAGENTA "   0 3 * * 0 /path/to/your/script.sh 3 >/dev/null 2>&1"
    log_message YELLOW "   (这里的 '${MAGENTA}3${RESET}${YELLOW}' 是主菜单中 '检查并自动续期所有证书' 的${MAGENTA}选项号${RESET}${YELLOW})${RESET}"
    log_message INFO "=============================================="
}

# -----------------------------
# 管理 acme.sh 账户的函数
manage_acme_accounts() {
    check_root
    while true; do
        log_message INFO "=============================================="
        log_message INFO "👤 acme.sh 账户管理"
        log_message INFO "=============================================="
        echo "1. 查看已注册账户"
        echo "2. 注册新账户"
        echo "3. 设置默认账户"
        echo "0. 返回主菜单"
        log_message INFO "=============================================="
        read -rp "请输入选项 [回车返回]: " ACCOUNT_CHOICE
        ACCOUNT_CHOICE=${ACCOUNT_CHOICE:-0}
        case "$ACCOUNT_CHOICE" in
            1)
                log_message BLUE "🔍 已注册 acme.sh 账户列表:"
                "$ACME_BIN" --list-account
                sleep 2
                ;;
            2)
                log_message BLUE "➡️ 注册新 acme.sh 账户:"
                read -rp "请输入新账户的邮箱地址: " NEW_ACCOUNT_EMAIL
                while [[ ! "$NEW_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                    log_message RED "邮箱格式不正确，请重新输入:"
                    read -rp "请输入新账户的邮箱地址: " NEW_ACCOUNT_EMAIL
                done
                
                local REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                local REGISTER_CA_SERVER_NAME="letsencrypt"
                log_message INFO "\n请选择证书颁发机构 (CA):"
                echo "1) Let's Encrypt (默认)"
                echo "2) ZeroSSL"
                echo "3) 自定义 ACME 服务器 URL" # 新增
                read -rp "请输入序号: " REGISTER_CA_CHOICE
                REGISTER_CA_CHOICE=${REGISTER_CA_CHOICE:-1}
                case $REGISTER_CA_CHOICE in
                    1) REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; REGISTER_CA_SERVER_NAME="letsencrypt";;
                    2) REGISTER_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; REGISTER_CA_SERVER_NAME="zerossl";;
                    3) # 新增自定义逻辑
                        read -rp "请输入自定义 ACME 服务器 URL: " CUSTOM_ACME_URL
                        if [[ -n "$CUSTOM_ACME_URL" ]]; then
                            REGISTER_CA_SERVER_URL="$CUSTOM_ACME_URL"
                            REGISTER_CA_SERVER_NAME="Custom"
                            log_message INFO "⚠️ 正在使用自定义 ACME 服务器 URL。请确保其有效。"
                        else
                            log_message YELLOW "未输入自定义 URL，将使用默认 Let's Encrypt。"
                            REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; REGISTER_CA_SERVER_NAME="letsencrypt";
                        fi
                        ;;
                    *) log_message YELLOW "⚠️ 无效选择，将使用默认 Let's Encrypt。";;
                esac
                log_message BLUE "➡️ 选定 CA: $REGISTER_CA_SERVER_NAME"

                log_message GREEN "🚀 正在注册账户 $NEW_ACCOUNT_EMAIL (CA: $REGISTER_CA_SERVER_NAME)..."
                if "$ACME_BIN" --register-account -m "$NEW_ACCOUNT_EMAIL" --server "$REGISTER_CA_SERVER_URL"; then
                    log_message GREEN "✅ 账户注册成功。"
                else
                    log_message RED "❌ 账户注册失败！请检查邮箱地址或网络。"
                fi
                sleep 2
                ;;
            3)
                log_message BLUE "➡️ 设置默认 acme.sh 账户:"
                "$ACME_BIN" --list-account # 列出账户，让用户选择
                read -rp "请输入要设置为默认的账户邮箱地址: " DEFAULT_ACCOUNT_EMAIL
                if [[ -z "$DEFAULT_ACCOUNT_EMAIL" ]]; then
                    log_message RED "❌ 邮箱不能为空。"
                    continue
                fi
                log_message GREEN "🚀 正在设置 $DEFAULT_ACCOUNT_EMAIL 为默认账户..."
                if "$ACME_BIN" --set-default-account -m "$DEFAULT_ACCOUNT_EMAIL"; then
                    log_message GREEN "✅ 默认账户设置成功。"
                else
                    log_message RED "❌ 设置默认账户失败！请检查邮箱地址是否已注册。"
                fi
                sleep 2
                ;;
            0)
                break
                ;;
            *)
                log_message RED "❌ 无效选项，请输入 0-3"
                ;;
        esac 
    done
}


# --- 主菜单 ---
main_menu() {
    while true; do
        log_message INFO "=============================================="
        log_message INFO "🔐 Nginx/HTTPS 证书管理主菜单"
        log_message INFO "=============================================="
        echo "1. 配置新的 Nginx 反向代理和 HTTPS 证书"
        echo "2. 查看与管理已配置项目 (域名、端口、证书)"
        echo "3. 检查并自动续期所有证书"
        echo "4. 管理 acme.sh 账户"
        echo "0. 退出"
        log_message INFO "=============================================="
        read -rp "请输入选项 [回车退出]: " MAIN_CHOICE
        MAIN_CHOICE=${MAIN_CHOICE:-0}
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
                if [ "$IS_NESTED_CALL" = "true" ]; then
                    log_message INFO "返回主菜单。"
                    exit 10 # 如果是被主脚本调用的，返回退出码 10，代表“返回主菜单”
                else
                    log_message BLUE "👋 感谢使用，已退出。"
                    log_message INFO "--- 脚本执行结束: $(date +"%Y-%m-%d %H:%M:%S") ---"
                    exit 0 # 如果是独立运行的，正常退出
                fi
                ;;
            *)
                log_message RED "❌ 无效选项，请输入 0-4"
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
```
