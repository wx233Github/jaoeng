#!/bin/bash
# ==============================================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手（基于 acme.sh）
# ------------------------------------------------------------------------------
# 功能概览：
# - **自动化配置**: 一键式自动配置 Nginx 反向代理和 HTTPS 证书。
# - **后端支持**: 支持代理到 Docker 容器或本地指定端口。
# - **依赖管理**: 自动检查并安装/更新必要的系统依赖（Nginx, Curl, Socat, OpenSSL, JQ, idn, dnsutils, nano）。
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
#   - **新增**: 提供“管理自定义 Nginx 配置片段”功能 (支持修改路径、编辑内容、清除)。
#   - **新增**: 提供“导入现有 Nginx 配置到本脚本管理”功能。
# - **证书续期**:
#   - 支持手动续期指定域名的 HTTPS 证书。
#   - **新增**: 提供“检查并自动续期所有证书”功能，可作为 Cron 任务运行。
# - **配置删除**:
#   - **核心改进**: 支持删除指定域名的 Nginx 配置、证书文件或所有相关数据。
# - **acme.sh 账户管理**: 新增专门的菜单，用于查看、注册和设置默认 ACME 账户。
# - **错误日志分析**: 对 `acme.sh` 错误日志的简单分析，提供更具体的排查建议。
# - **日志记录**: 所有脚本输出都会同时记录到指定日志文件，便于排查问题。
# - **IPv6 支持**: Nginx 自动监听服务器的 IPv6 地址（如果存在）。
# - **Docker 端口选择**: 在配置 Docker 项目时，智能检测宿主机映射端口，未检测到时可手动指定容器内部端口。
# - **Nginx 自定义片段**: 允许为每个域名注入自定义的 Nginx 配置片段文件，并提供智能默认路径。
# ==============================================================================

# --- 脚本集成支持 ---
IS_NESTED_CALL="${IS_NESTED_CALL:-false}"

set -e
set -u # 启用：遇到未定义的变量即退出，有助于发现错误

# --- 全局变量和颜色定义 ---
# 移除了 LC_ALL 等强制 locale 设置，依赖系统和终端的默认配置
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
RESET="\033[0m"

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
RENEW_THRESHOLD_DAYS=30 # 证书在多少天内到期时触发自动续期

# Nginx 路径变量
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_WEBROOT_DIR="/var/www/html" # acme.sh webroot 验证目录
NGINX_CUSTOM_SNIPPETS_DIR="/etc/nginx/custom_snippets"
SSL_CERTS_BASE_DIR="/etc/ssl" # 证书的基目录，acme.sh 默认安装到这里

# --- 控制日志输出到终端的模式 ---
# 默认为交互模式，只有在特定情况下（如cron任务）才设置为非交互
IS_INTERACTIVE_MODE="true"
# 如果脚本带参数3执行（通常用于cron任务），则设为非交互模式
if [[ "${1:-}" == "3" ]]; then
    IS_INTERACTIVE_MODE="false"
fi

# --- 日志重定向函数 (替代 tee) ---
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
        *) color_code="${RESET}";; # Fallback for unknown levels
    esac

    # 输出到终端（带颜色），非 DEBUG 级别不显示前缀，DEBUG 级别显示前缀
    # 强制 `-e` 选项，即使 `shopt -s huponexit` 或其他设置影响了默认行为
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        if [ "$level" = "DEBUG" ]; then
            echo -e "${color_code}[${level}] ${message}${RESET}"
        else
            echo -e "${color_code}${message}${RESET}" # 只显示消息，不带级别前缀
        fi
    fi
    # 写入日志文件（纯文本，保留时间戳和所有级别）
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# --- 临时文件清理 (使用 trap) ---
cleanup_temp_files() {
    log_message DEBUG "正在清理临时文件..."
    # 使用 find 安全地删除由本脚本创建的临时文件
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
    log_message DEBUG "临时文件清理完成。"
}
trap cleanup_temp_files EXIT # 脚本退出时执行清理

log_message INFO "--- 脚本开始执行: $(date +"%Y-%m-%d %H:%M:%S") ---"

# --- acme.sh 路径查找 ---
ACME_BIN="" # 先初始化为空，但实际在逻辑中会确保其值
find_acme_sh_path() {
    local potential_paths=(
        "$HOME/.acme.sh/acme.sh"
        "/root/.acme.sh/acme.sh"
    )
    for p in "${potential_paths[@]}"; do
        if [[ -f "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    if command -v acme.sh &>/dev/null; then
        local path_from_cmd=$(command -v acme.sh)
        if [[ "$path_from_cmd" == *".acme.sh/acme.sh"* ]]; then
            echo "$path_from_cmd"
            return 0
        fi
    fi
    return 1 # 未找到
}

# 脚本启动时，尝试设置 ACME_BIN
ACME_BIN_TEMP=$(find_acme_sh_path)
if [[ -z "$ACME_BIN_TEMP" ]]; then
    # 如果初始找不到，先假定它会安装到默认位置，以便 install_acme_sh 检查
    ACME_BIN="$HOME/.acme.sh/acme.sh"
    log_message WARN "无法在标准位置找到 acme.sh。脚本将尝试安装它。"
else
    ACME_BIN="$ACME_BIN_TEMP"
    log_message INFO "✅ acme.sh 已就绪 ($ACME_BIN)。"
fi
# 确保 $HOME/.acme.sh 在 PATH 中，这对 acme.sh 内部操作很重要
export PATH="$HOME/.acme.sh:$PATH"

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
    # VPS_IP 局部变量
    VPS_IP=$(curl -s https://api.ipify.org)
    log_message INFO "🌐 VPS 公网 IP (IPv4): $VPS_IP"

    # VPS_IPV6 全局变量，不使用 local
    VPS_IPV6=$(curl -s -6 https://api64.ipify.org 2>/dev/null || echo "")
    if [[ -n "$VPS_IPV6" ]]; then
        log_message INFO "🌐 VPS 公网 IP (IPv6): $VPS_IPV6"
    else
        log_message WARN "⚠️ 无法获取 VPS 公网 IPv6 地址，Nginx 将只监听 IPv4。"
    fi
}

# -----------------------------
# 自动安装依赖（跳过已是最新版的），适用于 Debian/Ubuntu
install_dependencies() {
    log_message INFO "🔍 检查并安装依赖 (适用于 Debian/Ubuntu)..."

    # 尝试更新包列表，将stdout和stderr重定向到日志文件，如果失败则输出错误到终端
    log_message DEBUG "正在执行 apt update..."
    if ! apt update -y >/dev/null 2>&1; then
        log_message ERROR "❌ apt update 失败，请检查网络或源配置。脚本将退出。"
        exit 1
    fi
    log_message INFO "📦 包列表已更新。"

    declare -A DEPS_MAP
    DEPS_MAP=(
        ["nginx"]="nginx"
        ["curl"]="curl"
        ["socat"]="socat"
        ["openssl"]="openssl"
        ["jq"]="jq"
        ["idn"]="idn"         # Add 'idn' command for IDN domains
        ["dig"]="dnsutils"
        ["nano"]="nano"       # Add nano for file editing
    )

    echo -n "${CYAN}正在检查依赖：${RESET}" # 开始输出进度点，不使用 log_message
    for cmd in "${!DEPS_MAP[@]}"; do
        local pkg="${DEPS_MAP[$cmd]}"
        if command -v "$cmd" &>/dev/null; then
            INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "not-found")
            AVAILABLE_VER=$(apt-cache policy "$pkg" | grep Candidate | awk '{print $2}' || echo "not-found")

            if [ "$INSTALLED_VER" != "not-found" ] && [ "$INSTALLED_VER" = "$AVAILABLE_VER" ]; then
                echo -n "${GREEN}.${RESET}" # 已安装且最新，显示一个绿点
                log_message DEBUG "命令 '$cmd' (由包 '$pkg') 已安装且为最新版 ($INSTALLED_VER)，跳过。" # 仅记录日志
            else
                echo -n "${YELLOW}u${RESET}" # 需要更新，显示一个黄色的'u'
                log_message WARN "命令 '$cmd' (由包 '$pkg') 正在安装或更新至最新版 ($INSTALLED_VER -> $AVAILABLE_VER)..." # 记录日志并终端输出(WARN级别)
                # 将安装过程的输出重定向到日志文件
                apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "❌ 安装/更新包 '$pkg' 失败。"; exit 1; }
                log_message INFO "✅ 命令 '$cmd' 已安装/更新。" # 记录日志并终端输出(INFO级别)
            fi
        else
            echo -n "${BLUE}i${RESET}" # 缺少并安装，显示一个蓝色的'i'
            log_message WARN "缺少命令 '$cmd' (由包 '$pkg' 提供)，正在安装..." # 记录日志并终端输出(WARN级别)
            # 将安装过程的输出重定向到日志文件
            apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "❌ 安装包 '$pkg' 失败。"; exit 1; }
            log_message INFO "✅ 命令 '$cmd' 已安装。" # 记录日志并终端输出(INFO级别)
        fi
    done
    echo -e "\n${GREEN}✅ 所有依赖检查完毕。${RESET}" # 完成依赖检查后新起一行
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
        log_message WARN "⚠️ Docker 未安装，无法检测容器端口，只能配置本地端口"
    fi
    sleep 1
}

# -----------------------------
# 安装 acme.sh
install_acme_sh() {
    # 再次检查 ACME_BIN 是否已是有效文件路径
    if [ ! -f "$ACME_BIN" ]; then
        log_message WARN "⚠️ acme.sh 未安装，正在安装..."

        read -rp "$(echo -e "${CYAN}请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址 (例如: your@example.com)，回车则不指定: ${RESET}")" ACME_EMAIL_INPUT

        local ACME_EMAIL=""
        if [[ -n "$ACME_EMAIL_INPUT" ]]; then
            while [[ ! "$ACME_EMAIL_INPUT" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                log_message RED "❌ 邮箱格式不正确。请重新输入，或回车不指定。"
                read -rp "$(echo -e "${CYAN}请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址: ${RESET}")" ACME_EMAIL_INPUT
                [[ -z "$ACME_EMAIL_INPUT" ]] && break
            done
            ACME_EMAIL="$ACME_EMAIL_INPUT"
        fi

        if [[ -n "$ACME_EMAIL" ]]; then
            log_message BLUE "➡️ 正在使用邮箱 $ACME_EMAIL 安装 acme.sh..."
            curl https://get.acme.sh | sh -s email="$ACME_EMAIL" || { log_message ERROR "❌ acme.sh 安装失败！"; exit 1; }
        else
            log_message YELLOW "ℹ️ 未指定邮箱地址安装 acme.sh。某些证书颁发机构（如 ZeroSSL）可能需要注册邮箱。您可以在之后使用 'acme.sh --register-account -m your@example.com' 手动注册。"
            read -rp "$(echo -e "${CYAN}是否确认不指定邮箱安装 acme.sh？[y/N]: ${RESET}")" NO_EMAIL_CONFIRM
            NO_EMAIL_CONFIRM=${NO_EMAIL_CONFIRM:-n} # 默认改为 n
            if [[ "$NO_EMAIL_CONFIRM" =~ ^[Yy]$ ]]; then
                curl https://get.acme.sh | sh || { log_message ERROR "❌ acme.sh 安装失败！"; exit 1; }
            else
                log_message RED "❌ 已取消 acme.sh 安装。"
                exit 1
            fi
        fi
        # 安装成功后，重新确定 ACME_BIN 路径并更新 PATH
        local newly_installed_acme_bin=$(find_acme_sh_path)
        if [[ -z "$newly_installed_acme_bin" ]]; then
            log_message ERROR "❌ acme.sh 安装成功，但无法找到其执行路径。请手动检查 $HOME/.acme.sh 目录。"
            exit 1
        else
            ACME_BIN="$newly_installed_acme_bin" # 更新全局 ACME_BIN
            export PATH="$(dirname "$ACME_BIN"):$PATH" # 重新加载 PATH，确保 acme.sh 命令可用
            log_message GREEN "✅ acme.sh 安装成功，路径设置为 $ACME_BIN。"
        fi
    else
        log_message INFO "✅ acme.sh 已安装 ($ACME_BIN)。"
    fi
    sleep 1
}

# -----------------------------
# 检测域名解析 (同时检查 IPv4 和 IPv6)
check_domain_ip() {
    local domain="$1"
    local vps_ip_v4="$2"
    # VPS_IPV6 是全局变量

    log_message INFO "🔍 检查域名 ${domain} 的 DNS 解析..."

    # 1. IPv4 解析检查
    local domain_ip_v4=$(dig +short "$domain" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 2>/dev/null || echo "")
    if [ -z "$domain_ip_v4" ]; then
        log_message RED "❌ 域名 ${domain} 无法解析到任何 IPv4 地址，请检查 DNS 配置。"
        return 1 # 硬性失败
    elif [ "$domain_ip_v4" != "$vps_ip_v4" ]; then
        log_message RED "⚠️ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 与本机 IPv4 ($vps_ip_v4) 不符。"
        read -rp "$(echo -e "${CYAN}这可能导致证书申请失败。是否继续？[y/N]: ${RESET}")" PROCEED_ANYWAY_V4
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
    if [[ -n "$VPS_IPV6" ]]; then
        local domain_ip_v6=$(dig +short "$domain" AAAA | grep -E '^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$' | head -n1 2>/dev/null || echo "")
        if [ -z "$domain_ip_v6" ]; then
            log_message YELLOW "⚠️ 域名 ${domain} 未配置 AAAA 记录，但您的 VPS 具有 IPv6 地址。"
            read -rp "$(echo -e "${CYAN}这表示该域名可能无法通过 IPv6 访问。是否继续？[Y/n]: ${RESET}")" PROCEED_ANYWAY_AAAA_MISSING
            PROCEED_ANYWAY_AAAA_MISSING=${PROCEED_ANYWAY_AAAA_MISSING:-y} # 默认改为 y (继续)
            if [[ ! "$PROCEED_ANYWAY_AAAA_MISSING" =~ ^[Yy]$ ]]; then
                log_message RED "❌ 已取消当前域名的操作。"
                return 1 # 硬性失败
            fi
            log_message YELLOW "⚠️ 已选择继续申请 (AAAA 记录缺失)。"
        elif [ "$domain_ip_v6" != "$VPS_IPV6" ]; then
            log_message RED "⚠️ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 与本机 IPv6 ($VPS_IPV6) 不符。"
            read -rp "$(echo -e "${CYAN}这可能导致证书申请失败或域名无法通过 IPv6 访问。是否继续？[y/N]: ${RESET}")" PROCEED_ANYWAY_AAAA_MISMATCH
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
    return 0
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
    local LISTEN_80_DIRECTIVES=$(generate_nginx_listen_directives 80 "") # Pre-calculate directives

    cat <<EOF_HTTP
server {
${LISTEN_80_DIRECTIVES}
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html; # acme.sh webroot 验证目录的绝对路径，这里使用硬编码
    }

    location / {
        return 200 'ACME Challenge Ready';
    }
}
EOF_HTTP
}

# -----------------------------
# Nginx 配置模板 (最终 HTTPS 代理)
_NGINX_FINAL_TEMPLATE() {
    local DOMAIN="$1"
    local PROXY_TARGET_URL="$2"
    local INSTALLED_CRT_FILE="$3"
    local INSTALLED_KEY_FILE="$4"
    local CUSTOM_SNIPPET_PATH="$5" # 新增参数：自定义片段文件路径
    local LISTEN_443_DIRECTIVES=$(generate_nginx_listen_directives 443 "ssl http2") # Pre-calculate directives
    local LISTEN_80_DIRECTIVES=$(generate_nginx_listen_directives 80 "") # Pre-calculate directives

    cat <<EOF_FINAL
server {
${LISTEN_80_DIRECTIVES}
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
${LISTEN_443_DIRECTIVES}
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
EOF_FINAL
    # 注入自定义 Nginx 配置片段
    if [[ -n "$CUSTOM_SNIPPET_PATH" && "$CUSTOM_SNIPPET_PATH" != "null" && -f "$CUSTOM_SNIPPET_PATH" ]]; then
        cat <<INNER_SNIPPET_EOF
    # BEGIN Custom Nginx Snippet for $DOMAIN
    include $CUSTOM_SNIPPET_PATH;
    # END Custom Nginx Snippet for $DOMAIN
INNER_SNIPPET_EOF
    fi

    cat <<'EOF_FINAL_PART2'
    location / {
        proxy_pass $PROXY_TARGET_URL;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF_FINAL_PART2
}

# -----------------------------
# Analyze acme.sh error output and provide suggestions
analyze_acme_error() {
    local error_output="$1"
    log_message ERROR "${RED}--- acme.sh 错误分析 ---${RESET}"
    if echo "$error_output" | grep -q "Invalid response from"; then
        log_message ERROR "   ${RED}可能原因：域名解析错误，或 80 端口未开放/被占用，或防火墙阻止了验证请求。${RESET}"
        log_message YELLOW "   建议：1. 检查域名 A/AAAA 记录是否指向本机 IP。2. 确保 80 端口已开放且未被其他服务占用。3. 检查服务器防火墙设置。"
    elif echo "$error_output" | grep -q "Domain not owned"; then
        log_message ERROR "   ${RED}可能原因：acme.sh 无法证明您拥有该域名。${RESET}"
        log_message YELLOW "   建议：1. 确保域名解析正确。2. 如果是 dns-01 验证，检查 DNS API 密钥和权限。3. 尝试强制更新 DNS 记录。"
    elif echo "$error_output" | grep -q "Timeout"; then
        log_message ERROR "   ${RED}可能原因：验证服务器连接超时。${RESET}"
        log_message YELLOW "   建议：检查服务器网络连接，防火墙，或 DNS 解析是否稳定。"
    elif echo "$error_output" | grep -q "Rate Limit"; then
        log_message ERROR "   ${RED}可能原因：已达到 Let's Encrypt 或 ZeroSSL 的请求频率限制。${RESET}"
        log_message YELLOW "   建议：请等待一段时间（通常为一周）再尝试，或添加更多域名到单个证书（如果适用）。"
        log_message YELLOW "   参考: https://letsencrypt.org/docs/rate-limits/ 或 ZeroSSL 文档。"
    elif echo "$error_output" | grep -q "DNS problem"; then
        log_message ERROR "   ${RED}可能原因：DNS 验证失败。${RESET}"
        log_message YELLOW "   建议：1. 检查 DNS 记录是否正确添加 (TXT 记录)。2. 检查 DNS API 密钥是否有效且有足够权限。3. 确保 DNS 记录已完全生效。"
    elif echo "$error_output" | grep -q "No account specified for this domain"; then
        log_message ERROR "   ${RED}可能原因：未为该域名指定或注册 ACME 账户。${RESET}"
        log_message YELLOW "   建议：运行 'acme.sh --register-account -m your@example.com --server [CA_SERVER_URL]' 注册账户。"
    elif echo "$error_output" | grep -q "Domain key exists"; then
        log_message ERROR "   ${RED}可能原因：上次申请失败后残留了域名私钥文件。${RESET}"
        log_message YELLOW "   建议：脚本已在初次申请或重试时添加 --force 参数处理此问题。如果仍然失败，请尝试在管理菜单中删除该项目后重试。"
    elif echo "$error_output" | grep -q "not a cert name" || echo "$error_output" | grep -q "Cannot find path"; then
        log_message ERROR "   ${RED}可能原因：acme.sh 无法识别证书名称或路径，通常是由于传递的域名格式不正确导致。${RESET}"
        log_message YELLOW "   建议：请检查 acme.sh 命令中 -d 参数的域名是否包含多余的引号或特殊字符，或者证书目录是否存在。"
    elif echo "$error_output" | grep -q "Unknown parameter"; then
        log_message ERROR "   ${RED}可能原因：acme.sh 命令中存在未知参数。${RESET}"
        log_message YELLOW "   建议：这通常是由于脚本内部构建 acme.sh 命令时，参数或引号处理不当造成的。请向开发者反馈此问题，并提供完整的错误日志。"
    else
        log_message ERROR "   ${RED}未识别的错误类型。${RESET}"
        log_message YELLOW "   建议：请仔细检查上述 acme.sh 完整错误日志，并查阅 acme.sh 官方文档或社区寻求帮助。"
    fi
    log_message ERROR "${RED}--------------------------${RESET}"
    sleep 2
}

# -----------------------------
# 健壮的 Nginx 控制函数
control_nginx() {
    local action="$1" # restart, reload, start, stop
    log_message INFO "尝试 ${action} Nginx 服务..."

    # 检查配置语法
    # Nginx -t 的输出直接到 stderr，不重定向，让用户看到具体错误
    if ! nginx -t; then
        log_message ERROR "❌ Nginx 配置语法错误！请检查 '$NGINX_SITES_AVAILABLE_DIR/' 下的配置文件。"
        return 1
    fi

    systemctl "$action" nginx
    if [ $? -ne 0 ]; then
        log_message ERROR "❌ Nginx ${action} 失败！请手动检查 Nginx 服务状态：'systemctl status nginx'，并查看错误日志：'journalctl -xeu nginx'。"
        return 1
    else
        log_message GREEN "✅ Nginx 服务已成功 ${action}。"
        return 0
    fi
}

# -----------------------------
# 检查 DNS API 环境变量的函数
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
        read -rp "$(echo -e "${CYAN}是否已设置这些变量并确认继续？[y/N]: ${RESET}")" CONFIRM_ENV
        CONFIRM_ENV=${CONFIRM_ENV:-n}
        if [[ ! "$CONFIRM_ENV" =~ ^[Yy]$ ]]; then
            return 1 # 用户选择不继续
        fi
    else
        log_message INFO "✅ 必要的 DNS API 环境变量已设置。"
    fi
    sleep 1
    return 0
}

# -----------------------------
# 配置 Nginx 和申请 HTTPS 证书的主函数
configure_nginx_projects() {
    check_root
    read -rp "$(echo -e "${CYAN}⚠️ 脚本将自动安装依赖并配置 Nginx，回车继续（默认 Y）: ${RESET}")" CONFIRM
    CONFIRM=${CONFIRM:-y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_message RED "❌ 已取消配置。"
        return 1
    fi

    install_dependencies
    detect_docker
    install_acme_sh # 确保 acme.sh 已安装并 ACME_BIN 正确设置

    mkdir -p "$NGINX_SITES_AVAILABLE_DIR"
    mkdir -p "$NGINX_SITES_ENABLED_DIR"
    mkdir -p "$NGINX_WEBROOT_DIR" # 用于 acme.sh webroot 验证
    mkdir -p "$NGINX_CUSTOM_SNIPPETS_DIR" # 创建自定义片段的默认父目录
    mkdir -p "$SSL_CERTS_BASE_DIR" # 确保证书基目录存在

    get_vps_ip

    # 检查并移除旧版 projects.conf 以避免冲突
    if [ -f "$NGINX_SITES_AVAILABLE_DIR/projects.conf" ]; then
        log_message WARN "⚠️ 检测到旧版 Nginx 配置文件 $NGINX_SITES_AVAILABLE_DIR/projects.conf，正在删除以避免冲突。"
        rm -f "$NGINX_SITES_AVAILABLE_DIR/projects.conf"
        rm -f "$NGINX_SITES_ENABLED_DIR/projects.conf"
        if ! control_nginx reload; then # 即使失败也继续，因为可能是旧文件导致无法重载
            log_message WARN "Nginx 服务重载失败，可能影响后续配置，但脚本将尝试继续。"
        fi
    fi

    # Ensure metadata file exists and is a valid JSON array
    if [ ! -f "$PROJECTS_METADATA_FILE" ]; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
        log_message INFO "✅ 项目元数据文件 $PROJECTS_METADATA_FILE 已创建。"
    else
        # Validate if it's a valid JSON array
        if ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
            log_message ERROR "❌ 警告: $PROJECTS_METADATA_FILE 不是有效的 JSON 格式。将备份并重新创建。"
            mv "$PROJECTS_METADATA_FILE" "${PROJECTS_METADATA_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            echo "[]" > "$PROJECTS_METADATA_FILE"
            log_message INFO "✅ 项目元数据文件 $PROJECTS_METADATA_FILE 已重新创建。"
        fi
    fi
    sleep 1

    log_message YELLOW "请输入项目列表（格式：主域名:docker容器名 或 主域名:本地端口），输入空行结束：${RESET}"
    PROJECTS=()
    while true; do
        read -rp "$(echo -e "${CYAN}> ${RESET}")" line
        [[ -z "$line" ]] && break
        PROJECTS+=("$line")
    done

    if [ ${#PROJECTS[@]} -eq 0 ]; then
        log_message YELLOW "⚠️ 您没有输入任何项目，操作已取消。"
        return 1
    fi
    sleep 1

    # CA 选择
    local ACME_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
    local ACME_CA_SERVER_NAME="letsencrypt"
    log_message INFO "${BLUE}请选择证书颁发机构 (CA):${RESET}"
    echo "${GREEN}1) Let's Encrypt (默认)${RESET}"
    echo "${GREEN}2) ZeroSSL${RESET}"
    read -rp "$(echo -e "${CYAN}请输入序号: ${RESET}")" CA_CHOICE
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
             read -rp "$(echo -e "${CYAN}请输入用于注册 ZeroSSL 的邮箱地址: ${RESET}")" ZERO_SSL_ACCOUNT_EMAIL
             while [[ ! "$ZERO_SSL_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                 log_message RED "❌ 邮箱格式不正确。请重新输入。"
                 read -rp "$(echo -e "${CYAN}请输入用于注册 ZeroSSL 的邮箱地址: ${RESET}")" ZERO_SSL_ACCOUNT_EMAIL
                 [[ -z "$ZERO_SSL_ACCOUNT_EMAIL" ]] && break
             done
             if [[ -z "$ZERO_SSL_ACCOUNT_EMAIL" ]]; then
                 log_message RED "❌ 未提供邮箱，无法注册 ZeroSSL 账户。操作已取消。"
                 return 1
             fi
             log_message BLUE "➡️ 正在注册 ZeroSSL 账户: $ZERO_SSL_ACCOUNT_EMAIL..."
             # Use command array for robustness
             local acme_reg_cmd_array=("$ACME_BIN" --register-account -m "$ZERO_SSL_ACCOUNT_EMAIL" --server "$ACME_CA_SERVER_URL")
             if ! "${acme_reg_cmd_array[@]}"; then
                 log_message ERROR "❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。"
                 return 1
             fi
             log_message GREEN "✅ ZeroSSL 账户注册成功。"
        else
            log_message GREEN "✅ ZeroSSL 账户已注册。"
        fi
        sleep 1
    fi

    log_message GREEN "🔧 正在为每个项目生成 Nginx 配置并申请证书..."
    for P in "${PROJECTS[@]}"; do
        local MAIN_DOMAIN="${P%%:*}"
        local TARGET_INPUT="${P##*:}"
        local DOMAIN_CONF="$NGINX_SITES_AVAILABLE_DIR/$MAIN_DOMAIN.conf"

        log_message BLUE "\n--- 处理域名: $MAIN_DOMAIN ---"

        if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
            log_message YELLOW "⚠️ 域名 $MAIN_DOMAIN 已存在配置。"
            read -rp "$(echo -e "${CYAN}是否要覆盖现有配置并重新申请/安装证书？[y/N]: ${RESET}")" OVERWRITE_CONFIRM
            OVERWRITE_CONFIRM=${OVERWRITE_CONFIRM:-n}
            if [[ ! "$OVERWRITE_CONFIRM" =~ ^[Yy]$ ]]; then
                log_message RED "❌ 已选择不覆盖，跳过域名 $MAIN_DOMAIN。"
                continue
            else
                log_message YELLOW "ℹ️ 确认覆盖。正在删除旧配置以便重新创建..."
                rm -f "$NGINX_SITES_AVAILABLE_DIR/$MAIN_DOMAIN.conf"
                rm -f "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf"
                if jq "del(.[] | select(.domain == \"$MAIN_DOMAIN\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    log_message GREEN "✅ 旧配置及元数据已移除。"
                else
                    log_message ERROR "❌ 移除旧元数据失败，请检查 $PROJECTS_METADATA_FILE 文件权限。跳过 $MAIN_DOMAIN。"
                    continue
                fi
            fi
        fi

        if ! check_domain_ip "$MAIN_DOMAIN" "$VPS_IP"; then
            log_message RED "❌ 跳过域名 $MAIN_DOMAIN 的配置和证书申请。"
            continue
        fi

        local ACME_VALIDATION_METHOD="http-01"
        local DNS_API_PROVIDER=""
        local USE_WILDCARD="n"

        log_message INFO "${BLUE}请选择验证方式:${RESET}"
        echo "${GREEN}1) http-01 (通过 80 端口，推荐用于单域名) [默认: 1]${RESET}"
        echo "${GREEN}2) dns-01 (通过 DNS API，推荐用于泛域名或 80 端口不可用时)${RESET}"
        read -rp "$(echo -e "${CYAN}请输入序号: ${RESET}")" VALIDATION_CHOICE
        VALIDATION_CHOICE=${VALIDATION_CHOICE:-1}
        case $VALIDATION_CHOICE in
            1) ACME_VALIDATION_METHOD="http-01";;
            2)
                ACME_VALIDATION_METHOD="dns-01"
                read -rp "$(echo -e "${CYAN}是否申请泛域名证书 (*.$MAIN_DOMAIN)？[y/N]: ${RESET}")" WILDCARD_INPUT
                WILDCARD_INPUT=${WILDCARD_INPUT:-n}
                if [[ "$WILDCARD_INPUT" =~ ^[Yy]$ ]]; then
                    USE_WILDCARD="y"
                    log_message YELLOW "⚠️ 泛域名证书必须使用 dns-01 验证方式。"
                fi

                log_message INFO "${BLUE}请选择您的 DNS 服务商 (用于 dns-01 验证):${RESET}"
                echo "${GREEN}1) Cloudflare (dns_cf)${RESET}"
                echo "${GREEN}2) Aliyun DNS (dns_ali)${RESET}"
                read -rp "$(echo -e "${CYAN}请输入序号: ${RESET}")" DNS_PROVIDER_CHOICE
                DNS_PROVIDER_CHOICE=${DNS_PROVIDER_CHOICE:-1}
                case $DNS_PROVIDER_CHOICE in
                    1) DNS_API_PROVIDER="dns_cf";;
                    2) DNS_API_PROVIDER="dns_ali";;
                    *)
                        log_message RED "❌ 无效的 DNS 服务商选择，将尝试使用 dns_cf。"
                        DNS_API_PROVIDER="dns_cf"
                        ;;
                esac
                if ! check_dns_env "$DNS_API_PROVIDER"; then
                    log_message ERROR "DNS 环境变量检查失败，跳过域名 $MAIN_DOMAIN 的证书申请。"
                    continue
                fi
                ;;
            *) log_message YELLOW "⚠️ 无效选择，将使用默认 http-01 验证方式。";;
        esac
        log_message BLUE "➡️ 选定验证方式: $ACME_VALIDATION_METHOD"
        if [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
            log_message BLUE "➡️ 选定 DNS API 服务商: $DNS_API_PROVIDER"
            if [ "$USE_WILDCARD" = "y" ]; then
                log_message BLUE "➡️ 申请泛域名证书: *.$MAIN_DOMAIN"
            fi
        fi
        sleep 1

        local PROXY_TARGET_URL=""
        local PROJECT_TYPE=""
        local PROJECT_DETAIL=""
        local PORT_TO_USE=""

        # Detect docker containers and their mapped ports
        if [ "$DOCKER_INSTALLED" = true ]; then
            local container_id=$(docker ps -aq --filter "name=$TARGET_INPUT" | head -n1 || echo "")
            if [[ -n "$container_id" ]]; then
                log_message GREEN "🔍 识别到 Docker 容器: $TARGET_INPUT (ID: $container_id)"

                # Try to get host mapped port first
                local HOST_MAPPED_PORT=$(docker inspect "$container_id" --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{ (index $conf 0).HostPort }}{{end}}{{end}}' 2>/dev/null | sed 's|/tcp||g' | awk '{print $1}' | head -n1 || echo "")

                if [[ -n "$HOST_MAPPED_PORT" ]]; then
                    log_message GREEN "✅ 检测到容器 $TARGET_INPUT 已映射到宿主机端口: $HOST_MAPPED_PORT。将自动使用此端口。"
                    PORT_TO_USE="$HOST_MAPPED_PORT"
                    PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
                    PROJECT_TYPE="docker"
                    PROJECT_DETAIL="$TARGET_INPUT"
                else
                    log_message YELLOW "⚠️ 未检测到容器 $TARGET_INPUT 映射到宿主机的端口。"

                    local INTERNAL_EXPOSED_PORTS_ARRAY=()
                    # Use jq to robustly extract exposed ports from JSON output
                    while IFS= read -r port_entry; do
                        INTERNAL_EXPOSED_PORTS_ARRAY+=("$port_entry")
                    done < <(docker inspect "$container_id" | jq -r '.[].Config.ExposedPorts | keys[]' 2>/dev/null | sed 's|/tcp||g' | sort -n)

                    if [ ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} -gt 0 ]; then
                        log_message YELLOW "检测到容器内部暴露的端口有："
                        local port_idx=0
                        for p in "${INTERNAL_EXPOSED_PORTS_ARRAY[@]}"; do
                            port_idx=$((port_idx + 1))
                            echo -e "   ${YELLOW}${port_idx})${RESET} ${p}"
                        done

                        while true; do
                            read -rp "$(echo -e "${CYAN}请选择一个内部端口序号，或直接输入端口号 (例如 1 或 8080): ${RESET}")" PORT_SELECTION
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
                            read -rp "$(echo -e "${CYAN}请输入要代理到的容器内部端口 (例如 8080): ${RESET}")" USER_INTERNAL_PORT
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
        elif [[ "$TARGET_INPUT" =~ ^[0-9]+$ ]]; then
            log_message GREEN "🔍 识别到本地端口: $TARGET_INPUT"
            PORT_TO_USE="$TARGET_INPUT"
            PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
            PROJECT_TYPE="local_port"
            PROJECT_DETAIL="$TARGET_INPUT"
        else
            log_message RED "❌ 无效的目标格式 '$TARGET_INPUT' (Docker未安装或不是端口号)，跳过域名 $MAIN_DOMAIN。"
            continue
        fi
        sleep 1

        mkdir -p "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN"

        local CUSTOM_NGINX_SNIPPET_FILE=""
        local DEFAULT_SNIPPET_FILENAME=""

        if [ "$PROJECT_TYPE" = "docker" ]; then
            DEFAULT_SNIPPET_FILENAME="$PROJECT_DETAIL.conf"
        else
            DEFAULT_SNIPPET_FILENAME="$MAIN_DOMAIN.conf"
        fi
        local DEFAULT_SNIPPET_PATH="$NGINX_CUSTOM_SNIPPETS_DIR/$DEFAULT_SNIPPET_FILENAME"

        read -rp "$(echo -e "${CYAN}是否为域名 $MAIN_DOMAIN 添加自定义 Nginx 配置片段文件？[y/N]: ${RESET}")" ADD_CUSTOM_SNIPPET
        ADD_CUSTOM_SNIPPET=${ADD_CUSTOM_SNIPPET:-n}
        if [[ "$ADD_CUSTOM_SNIPPET" =~ ^[Yy]$ ]]; then
            while true; do
                read -rp "$(echo -e "${CYAN}请输入自定义 Nginx 配置片段文件的完整路径 [默认: $DEFAULT_SNIPPET_PATH]: ${RESET}")" SNIPPET_PATH_INPUT
                local CHOSEN_SNIPPET_PATH="${SNIPPET_PATH_INPUT:-$DEFAULT_SNIPPET_PATH}"

                if [[ -z "$CHOSEN_SNIPPET_PATH" ]]; then
                    log_message RED "❌ 文件路径不能为空。"
                elif ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH")"; then
                    log_message RED "❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH")。请检查权限或路径是否有效。"
                else
                    CUSTOM_NGINX_SNIPPET_FILE="$CHOSEN_SNIPPET_PATH"
                    log_message GREEN "✅ 将使用自定义 Nginx 配置片段文件: $CUSTOM_NGINX_SNIPPET_FILE"
                    log_message YELLOW "ℹ️ 请确保文件 '$CUSTOM_NGINX_SNIPPET_FILE' 包含有效的 Nginx 配置片段。"
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
            log_message INFO "${BLUE}您想：${RESET}"
            echo "${GREEN}1) 重新申请/续期证书 (推荐更新过期或即将过期的证书) [默认]${RESET}"
            echo "${GREEN}2) 使用现有证书 (跳过证书申请步骤)${RESET}"
            read -rp "$(echo -e "${CYAN}请输入选项 [1]: ${RESET}")" CERT_ACTION_CHOICE
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
            log_message ERROR "❌ 写入项目元数据失败！请检查 $PROJECTS_METADATA_FILE 文件权限或 JSON 格式。跳过域名 $MAIN_DOMAIN。"
            continue
        fi
        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
        log_message GREEN "✅ 项目元数据已保存到 $PROJECTS_METADATA_FILE。"
        sleep 1

        if [ "$SHOULD_ISSUE_CERT" = "y" ] && [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
            log_message YELLOW "生成 Nginx 临时 HTTP 配置以进行证书验证..."
            local DOMAIN_CONF="$NGINX_SITES_AVAILABLE_DIR/$MAIN_DOMAIN.conf"
            _NGINX_HTTP_CHALLENGE_TEMPLATE "$MAIN_DOMAIN" > "$DOMAIN_CONF"

            if [ ! -L "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf" ]; then
                ln -sf "$DOMAIN_CONF" "$NGINX_SITES_ENABLED_DIR/"
            fi

            if ! control_nginx restart; then
                log_message ERROR "❌ Nginx 重启失败，证书申请将无法进行。清理临时配置并跳过域名 $MAIN_DOMAIN。"
                rm -f "$DOMAIN_CONF"
                rm -f "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf"
                if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
                    log_message YELLOW "Nginx 重启失败，从元数据中移除项目 $MAIN_DOMAIN。"
                    jq "del(.[] | select(.domain == \"$MAIN_DOMAIN\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp" && \
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                fi
                continue
            fi
        fi

        if [ "$SHOULD_ISSUE_CERT" = "y" ]; then
            log_message YELLOW "正在为 $MAIN_DOMAIN 申请证书 (CA: $ACME_CA_SERVER_NAME, 验证方式: $ACME_VALIDATION_METHOD)..."
            local ACME_ISSUE_CMD_LOG_OUTPUT=$(mktemp acme_cmd_log.XXXXXX)

            local acme_issue_cmd_array=("$ACME_BIN" --issue --force -d "$MAIN_DOMAIN" --ecc --server "$ACME_CA_SERVER_URL" --debug 2)
            if [ "$USE_WILDCARD" = "y" ]; then
                acme_issue_cmd_array+=("-d" "*.$MAIN_DOMAIN")
            fi

            if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                acme_issue_cmd_array+=("-w" "$NGINX_WEBROOT_DIR")
            elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
                acme_issue_cmd_array+=("--dns" "$DNS_API_PROVIDER")
            fi

            if ! "${acme_issue_cmd_array[@]}" > "$ACME_ISSUE_CMD_LOG_OUTPUT" 2>&1; then
                log_message ERROR "❌ 域名 $MAIN_DOMAIN 的证书申请失败！"
                cat "$ACME_ISSUE_CMD_LOG_OUTPUT"
                analyze_acme_error "$(cat "$ACME_ISSUE_CMD_LOG_OUTPUT")"
                rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"

                rm -f "$DOMAIN_CONF"
                rm -f "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf"
                if [ -d "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN" ]; then rm -rf "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN"; fi # 删除创建的证书目录

                if [[ -n "$CUSTOM_NGINX_SNIPPET_FILE" && "$CUSTOM_NGINX_SNIPPET_FILE" != "null" && -f "$CUSTOM_NGINX_SNIPPET_FILE" ]]; then
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

            # Construct INSTALL_CERT_DOMAINS_ARRAY for --install-cert
            local INSTALL_CERT_DOMAINS_ARRAY=()
            INSTALL_CERT_DOMAINS_ARRAY+=("-d" "$MAIN_DOMAIN")
            if [ "$USE_WILDCARD" = "y" ]; then
                INSTALL_CERT_DOMAINS_ARRAY+=("-d" "*.$MAIN_DOMAIN")
            fi

            local acme_install_cmd_array=(
                "$ACME_BIN" --install-cert "${INSTALL_CERT_DOMAINS_ARRAY[@]}" --ecc
                --key-file "$INSTALLED_KEY_FILE"
                --fullchain-file "$INSTALLED_CRT_FILE"
                --reloadcmd "systemctl reload nginx"
            )

            # Use command array for robustness
            if ! "${acme_install_cmd_array[@]}"; then
                log_message ERROR "❌ acme.sh 证书安装或Nginx重载失败。"
                continue
            fi
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
        log_message ERROR "❌ 最终 Nginx 配置未能成功重载。请手动检查并处理。"
        return 1
    fi

    log_message GREEN "🚀 所有域名配置完成！现在可以通过 HTTPS 访问您的服务。"
    sleep 2
    return 0
}

# -----------------------------
# 导入现有 Nginx 配置到本脚本管理
import_existing_project() {
    check_root
    log_message INFO "--- 📥 导入现有 Nginx 配置到本脚本管理 ---"

    read -rp "$(echo -e "${CYAN}请输入要导入的主域名 (例如 example.com): ${RESET}")" IMPORT_DOMAIN
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
        read -rp "$(echo -e "${CYAN}是否要覆盖现有项目元数据？[y/N]: ${RESET}")" OVERWRITE_CONFIRM
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
            if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$TARGET_HOST"; then
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

    log_message INFO "${BLUE}\n请确认或输入后端代理目标信息 (例如：docker容器名 或 本地端口):${RESET}"
    log_message INFO "  [当前解析/建议值: ${PROJECT_DETAIL_GUESS} (类型: ${PROJECT_TYPE_GUESS}, 端口: ${PORT_TO_USE_GUESS})]"
    read -rp "$(echo -e "${CYAN}输入目标（回车不修改）: ${RESET}")" USER_TARGET_INPUT

    local FINAL_PROJECT_TYPE="$PROJECT_TYPE_GUESS"
    local FINAL_PROJECT_NAME="$PROJECT_DETAIL_GUESS"
    local FINAL_RESOLVED_PORT="$PORT_TO_USE_GUESS"
    local FINAL_PROXY_TARGET_URL="$PROXY_TARGET_URL_GUESS"

    if [[ -n "$USER_TARGET_INPUT" ]]; then
        if [ "$DOCKER_INSTALLED" = true ] && docker ps -aq --filter "name=$USER_TARGET_INPUT" | head -n1 >/dev/null; then
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
                done < <(docker inspect "$USER_TARGET_INPUT" | jq -r '.[].Config.ExposedPorts | keys[]' 2>/dev/null | sed 's|/tcp||g' | sort -n)

                log_message YELLOW "⚠️ 未检测到容器 $USER_TARGET_INPUT 映射到宿主机的端口。"
                if [ ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} -gt 0 ]; then
                    log_message YELLOW "   检测到容器内部暴露的端口有："
                    local port_idx=0
                    for p in "${INTERNAL_EXPOSED_PORTS_ARRAY[@]}"; do
                        port_idx=$((port_idx + 1))
                        echo -e "   ${YELLOW}${port_idx})${RESET} ${p}"
                    end
                    while true; do
                        read -rp "$(echo -e "${CYAN}请选择一个内部端口序号，或直接输入端口号 (例如 1 或 8080): ${RESET}")" PORT_SELECTION
                        if [[ "$PORT_SELECTION" =~ ^[0-9]+$ ]]; then
                            if (( PORT_SELECTION > 0 && PORT_SELECTION <= ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} )); then
                                FINAL_RESOLVED_PORT="${INTERNAL_EXPOSED_PORTS_ARRAY[PORT_SELECTION-1]}"
                                FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
                                log_message GREEN "✅ 已选择容器内部端口: $FINAL_RESOLVED_PORT。"
                                break
                            elif (( PORT_SELECTION > 0 && PORT_SELECTION < 65536 )); then
                                FINAL_RESOLVED_PORT="$PORT_SELECTION"
                                FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
                                log_message GREEN "✅ 已手动指定容器内部端口: $FINAL_RESOLVED_PORT。"
                                break
                            fi
                        fi
                        log_message RED "❌ 输入无效。请重新选择或输入有效的端口号 (1-65535)。"
                    done
                else
                    log_message YELLOW "   未检测到容器 $USER_TARGET_INPUT 内部暴露的端口。"
                    while true; do
                        read -rp "$(echo -e "${CYAN}请输入要代理到的容器内部端口 (例如 8080): ${RESET}")" USER_INTERNAL_PORT_IMPORT
                        if [[ "$USER_INTERNAL_PORT_IMPORT" =~ ^[0-9]+$ ]] && (( USER_INTERNAL_PORT_IMPORT > 0 && USER_INTERNAL_PORT_IMPORT < 65536 )); then
                            FINAL_RESOLVED_PORT="$USER_INTERNAL_PORT_IMPORT"
                            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$FINAL_RESOLVED_PORT"
                            log_message GREEN "✅ 将代理到容器 $FINAL_PROJECT_NAME 的内部端口: $FINAL_RESOLVED_PORT。${RESET}"
                            break
                        else
                            log_message RED "❌ 输入的端口无效。请重新输入一个有效的端口号 (1-65535)。${RESET}"
                        fi
                    done
                fi
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

    local SSL_CRT_PATH=$(grep -E '^\s*ssl_certificate\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate\s+//;s/;//' || echo "")
    local SSL_KEY_PATH=$(grep -E '^\s*ssl_certificate_key\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate_key\s+//;s/;//' || echo "")

    read -rp "$(echo -e "${CYAN}请输入证书文件 (fullchain) 路径 [默认解析值: ${SSL_CRT_PATH:-$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.cer}，回车不修改]: ${RESET}")" USER_CRT_PATH
    USER_CRT_PATH=${USER_CRT_PATH:-"${SSL_CRT_PATH:-$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.cer}"}
    if [ ! -f "$USER_CRT_PATH" ]; then
        log_message YELLOW "⚠️ 证书文件 $USER_CRT_PATH 不存在。请确保路径正确，否则后续续期可能失败。"
    fi
    sleep 1

    read -rp "$(echo -e "${CYAN}请输入证书私钥文件路径 [默认解析值: ${SSL_KEY_PATH:-$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.key}，回车不修改]: ${RESET}")" USER_KEY_PATH
    USER_KEY_PATH=${USER_KEY_PATH:-"${SSL_KEY_PATH:-$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.key}"}
    if [ ! -f "$USER_KEY_PATH" ]; then
        log_message YELLOW "⚠️ 证书私钥文件 $USER_KEY_PATH 不存在。请确保路径正确，否则后续续期可能失败。"
    fi
    sleep 1

    local DEFAULT_SNIPPET_FILENAME=""
    if [ "$FINAL_PROJECT_TYPE" = "docker" ]; then
        DEFAULT_SNIPPET_FILENAME="$FINAL_PROJECT_NAME.conf"
    else
        DEFAULT_SNIPPET_FILENAME="$IMPORT_DOMAIN.conf"
    fi
    local DEFAULT_SNIPPET_PATH="$NGINX_CUSTOM_SNIPPETS_DIR/$DEFAULT_SNIPPET_FILENAME"

    local IMPORTED_CUSTOM_SNIPPET=""
    read -rp "$(echo -e "${CYAN}是否已有自定义 Nginx 配置片段文件？[y/N]: ${RESET}")" HAS_CUSTOM_SNIPPET_IMPORT
    HAS_CUSTOM_SNIPPET_IMPORT=${HAS_CUSTOM_SNIPPET_IMPORT:-n}
    if [[ "$HAS_CUSTOM_SNIPPET_IMPORT" =~ ^[Yy]$ ]]; then
        read -rp "$(echo -e "${CYAN}请输入自定义 Nginx 配置片段文件的完整路径 [默认: $DEFAULT_SNIPPET_PATH]: ${RESET}")" SNIPPET_PATH_INPUT_IMPORT
        IMPORTED_CUSTOM_SNIPPET="${SNIPPET_PATH_INPUT_IMPORT:-$DEFAULT_SNIPPET_PATH}"
        if [ ! -f "$IMPORTED_CUSTOM_SNIPPET" ]; then
            log_message YELLOW "⚠️ 自定义片段文件 $IMPORTED_CUSTOM_SNIPPET 不存在。请确保路径正确。"
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
        if ! jq "(.[] | select(.domain == \$domain)) = \$new_project_json" \
            --arg domain "$IMPORT_DOMAIN" \
            --argjson new_project_json "$NEW_PROJECT_JSON" \
            "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message ERROR "❌ 更新项目元数据失败！"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    else
        if ! jq ". + [\$new_project_json]" \
            --argjson new_project_json "$NEW_PROJECT_JSON" \
            "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message ERROR "❌ 写入项目元数据失败！"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    fi

    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
    log_message GREEN "✅ 域名 $IMPORT_DOMAIN 的 Nginx 配置已成功导入到脚本管理列表。"
    log_message YELLOW "ℹ️ 注意：导入的项目，其证书签发机构和验证方式被标记为 'imported'/'unknown'。"
    log_message YELLOW "   如果您希望由本脚本的 acme.sh 自动续期，请手动选择 '编辑项目核心配置'，并设置正确的验证方式，然后重新申请证书。"

    log_message INFO "--- 导入完成 ---"
    sleep 2
    return 0
}

# -----------------------------
# 查看和管理已配置项目的函数
manage_configs() {
    check_root
    log_message INFO "${CYAN}--- 📜 已配置项目列表及证书状态 ---${RESET}"

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        log_message YELLOW "未找到任何已配置的项目。"
        log_message INFO "${BLUE}------------------------------------${RESET}"
        read -rp "$(echo -e "${CYAN}没有找到已配置项目。是否立即导入一个现有 Nginx 配置？[y/N]: ${RESET}")" IMPORT_NOW
        IMPORT_NOW=${IMPORT_NOW:-n}
        if [[ "$IMPORT_NOW" =~ ^[Yy]$ ]]; then
            import_existing_project
            # 导入后再次调用 manage_configs 显示列表
            manage_configs
            return 0
        else
            return 0
        fi
    fi

    local PROJECTS_ARRAY_RAW=$(jq -c . "$PROJECTS_METADATA_FILE")
    local INDEX=0

    # 表头部分已修正为单行，并使用 UTF-8 的横线字符美化
    printf "${BLUE}%-4s │ %-25s │ %-8s │ %-25s │ %-10s │ %-18s │ %-4s │ %-5s │ %3s天 │ %s${RESET}\n" \
        "ID" "域名" "类型" "目标" "片段" "验证" "泛域" "状态" "剩余" "到期时间"
    printf "${BLUE}─────┼─────────────────────────┼──────────┼─────────────────────────┼────────────┼────────────────────┼──────┼───────┼───────┼────────────────────${RESET}\n"

    echo "$PROJECTS_ARRAY_RAW" | jq -c '.[]' | while read -r project_json; do
        INDEX=$((INDEX + 1))
        local DOMAIN=$(echo "$project_json" | jq -r '.domain')

        # 修复：使用 --arg 参数将 shell 变量安全地传递给 jq
        local default_cert_file_display="$SSL_CERTS_BASE_DIR/$DOMAIN.cer"
        local default_key_file_display="$SSL_CERTS_BASE_DIR/$DOMAIN.key"
        local CERT_FILE=$(echo "$project_json" | jq -r --arg default_cert "$default_cert_file_display" '.cert_file // $default_cert')
        local KEY_FILE=$(echo "$project_json" | jq -r --arg default_key "$default_key_file_display" '.key_file // $default_key')

        # 额外检查，防止 jq 失败或输出 "null"
        if [[ -z "$CERT_FILE" || "$CERT_FILE" == "null" ]]; then CERT_FILE="$default_cert_file_display"; fi
        if [[ -z "$KEY_FILE" || "$KEY_FILE" == "null" ]]; then KEY_FILE="$default_key_file_display"; fi

        local PROJECT_TYPE=$(echo "$project_json" | jq -r '.type')
        local PROJECT_NAME=$(echo "$project_json" | jq -r '.name')
        local RESOLVED_PORT=$(echo "$project_json" | jq -r '.resolved_port')
        local CUSTOM_SNIPPET=$(echo "$project_json" | jq -r '.custom_snippet')
        local ACME_VALIDATION_METHOD=$(echo "$project_json" | jq -r '.acme_validation_method')
        local DNS_API_PROVIDER=$(echo "$project_json" | jq -r '.dns_api_provider')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard')


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

        # 修正了这一行的 printf，改为单行，避免行尾 \ 问题
        printf "${MAGENTA}%-4s │ %-25s │ %-8s │ %-25s │ %-10s │ %-18s │ %-4s │ ${STATUS_COLOR}%-5s${RESET} │ %3s天 │ %s\n" "$INDEX" "$DOMAIN" "$PROJECT_TYPE_DISPLAY" "$PROJECT_DETAIL_DISPLAY" "$CUSTOM_SNIPPET_FILE_DISPLAY" "$ACME_METHOD_DISPLAY" "$WILDCARD_DISPLAY" "$STATUS_TEXT" "$LEFT_DAYS" "$FORMATTED_END_DATE"
    done

    log_message INFO "${CYAN}--- 列表结束 ---${RESET}"

    while true; do
        log_message BLUE "\n${CYAN}请选择管理操作：${RESET}"
        echo "${GREEN}1) 手动续期指定域名证书${RESET}"
        echo "${GREEN}2) 删除指定域名配置及证书${RESET}"
        echo "${GREEN}3) 编辑项目核心配置 (后端目标 / 验证方式等)${RESET}"
        echo "${GREEN}4) 管理自定义 Nginx 配置片段 (添加 / 修改 / 清除)${RESET}"
        echo "${GREEN}5) 导入现有 Nginx 配置到本脚本管理${RESET}"
        echo "${YELLOW}0) 返回主菜单${RESET}"
        log_message INFO "${BLUE}------------------------------------${RESET}"
        read -rp "$(echo -e "${CYAN}请输入选项 [回车返回]: ${RESET}")" MANAGE_CHOICE
        MANAGE_CHOICE=${MANAGE_CHOICE:-0} # 默认改为 0
        case "$MANAGE_CHOICE" in
            1) # 手动续期
                read -rp "$(echo -e "${CYAN}请输入要续期的域名: ${RESET}")" DOMAIN_TO_RENEW
                if [[ -z "$DOMAIN_TO_RENEW" ]]; then log_message RED "❌ 域名不能为空！"; sleep 1; continue; fi
                local RENEW_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_RENEW\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$RENEW_PROJECT_JSON" ]; then log_message RED "❌ 域名 $DOMAIN_TO_RENEW 未找到在已配置列表中。"; sleep 1; continue; fi

                local RENEW_ACME_VALIDATION_METHOD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.acme_validation_method')
                local RENEW_DNS_API_PROVIDER=$(echo "$RENEW_PROJECT_JSON" | jq -r '.dns_api_provider')
                local RENEW_USE_WILDCARD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.use_wildcard')
                local RENEW_CA_SERVER_URL=$(echo "$RENEW_PROJECT_JSON" | jq -r '.ca_server_url')

                # 修复：使用 --arg 参数将 shell 变量安全地传递给 jq
                local default_cert_file_renew="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_RENEW.cer"
                local default_key_file_renew="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_RENEW.key"
                local RENEW_CERT_FILE=$(echo "$RENEW_PROJECT_JSON" | jq -r --arg default_cert "$default_cert_file_renew" '.cert_file // $default_cert')
                local RENEW_KEY_FILE=$(echo "$RENEW_PROJECT_JSON" | jq -r --arg default_key "$default_key_file_renew" '.key_file // $default_key')

                if [[ -z "$RENEW_CERT_FILE" || "$RENEW_CERT_FILE" == "null" ]]; then RENEW_CERT_FILE="$default_cert_file_renew"; fi
                if [[ -z "$RENEW_KEY_FILE" || "$RENEW_KEY_FILE" == "null" ]]; then RENEW_KEY_FILE="$default_key_file_renew"; fi

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "imported" ]; then
                    log_message YELLOW "ℹ️ 域名 $DOMAIN_TO_RENEW 的证书是导入的，本脚本无法直接续期。请手动或通过 '编辑项目核心配置' 转换为 acme.sh 管理。"
                    sleep 2
                    continue
                fi

                log_message GREEN "🚀 正在为 $DOMAIN_TO_RENEW 续期证书 (验证方式: ${RENEW_ACME_VALIDATION_METHOD})..."
                local RENEW_CMD_LOG_OUTPUT=$(mktemp acme_cmd_log.XXXXXX)

                # Construct acme renew command array
                local acme_renew_cmd_array=("$ACME_BIN" --renew -d "$DOMAIN_TO_RENEW" --ecc --server "$RENEW_CA_SERVER_URL")
                if [ "$RENEW_USE_WILDCARD" = "y" ]; then
                    acme_renew_cmd_array+=("-d" "*.$DOMAIN_TO_RENEW")
                fi

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                    acme_renew_cmd_array+=("-w" "$NGINX_WEBROOT_DIR")
                elif [ "$RENEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                    acme_renew_cmd_array+=("--dns" "$RENEW_DNS_API_PROVIDER")
                    log_message YELLOW "⚠️ 续期 DNS 验证证书需要设置相应的 DNS API 环境变量。"
                    if ! check_dns_env "$RENEW_DNS_API_PROVIDER"; then
                        log_message ERROR "DNS 环境变量检查失败，跳过域名 $DOMAIN_TO_RENEW 的续期。"
                        rm -f "$RENEW_CMD_LOG_OUTPUT"
                        sleep 2
                        continue
                    fi
                fi

                if ! "${acme_renew_cmd_array[@]}" > "$RENEW_CMD_LOG_OUTPUT" 2>&1; then
                    log_message ERROR "❌ 续期失败：$DOMAIN_TO_RENEW。"
                    cat "$RENEW_CMD_LOG_OUTPUT"
                    analyze_acme_error "$(cat "$RENEW_CMD_LOG_OUTPUT")"
                    rm -f "$RENEW_CMD_LOG_OUTPUT"
                    sleep 2
                    continue
                fi
                rm -f "$RENEW_CMD_LOG_OUTPUT"

                log_message GREEN "✅ 续期完成：$DOMAIN_TO_RENEW"
                control_nginx reload || log_message ERROR "Nginx 重载失败，请手动检查。"
                sleep 2
                ;;
            2) # 删除
                read -rp "$(echo -e "${CYAN}请输入要删除的域名: ${RESET}")" DOMAIN_TO_DELETE
                if [[ -z "$DOMAIN_TO_DELETE" ]]; then log_message RED "❌ 域名不能为空！"; sleep 1; continue; fi
                local PROJECT_TO_DELETE_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_DELETE\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$PROJECT_TO_DELETE_JSON" ]; then log_message RED "❌ 域名 $DOMAIN_TO_DELETE 未找到在已配置列表中。"; sleep 1; continue; fi

                log_message YELLOW "\n${CYAN}--- 请选择删除级别 for $DOMAIN_TO_DELETE ---${RESET}"
                echo "${GREEN}1) 仅删除 Nginx 配置文件 (保留证书和元数据，用于临时禁用)${RESET}"
                echo "${GREEN}2) 删除 Nginx 配置文件和证书 (保留元数据，用于重新申请证书)${RESET}"
                echo "${RED}3) 全部删除 (Nginx 配置、证书、acme.sh 记录和元数据，彻底移除)${RESET}"
                echo "${YELLOW}0) 取消${RESET}"
                log_message YELLOW "${BLUE}----------------------------------------${RESET}"
                read -rp "$(echo -e "${CYAN}请输入选项 [0]: ${RESET}")" DELETE_LEVEL_CHOICE
                DELETE_LEVEL_CHOICE=${DELETE_LEVEL_CHOICE:-0}

                if [ "$DELETE_LEVEL_CHOICE" -eq 0 ]; then
                    log_message YELLOW "已取消删除操作。"
                    sleep 1
                    continue
                fi

                local CONFIRM_TEXT=""
                case "$DELETE_LEVEL_CHOICE" in
                    1) CONFIRM_TEXT="仅删除 Nginx 配置";;
                    2) CONFIRM_TEXT="删除 Nginx 配置和证书";;
                    3) CONFIRM_TEXT="全部删除";;
                    *) log_message RED "❌ 无效选项。"; sleep 1; continue;;
                esac

                read -rp "$(echo -e "${CYAN}⚠️ 确认对 ${DOMAIN_TO_DELETE} 执行 '${CONFIRM_TEXT}' 操作？此操作可能不可恢复！[y/N]: ${RESET}")" CONFIRM_DELETE
                CONFIRM_DELETE=${CONFIRM_DELETE:-n}
                if [[ "$CONFIRM_DELETE" =~ ^[Yy]$ ]]; then
                    log_message YELLOW "正在执行删除操作 for ${DOMAIN_TO_DELETE}..."

                    local delete_config=false
                    local delete_certs=false
                    local delete_metadata=false

                    case "$DELETE_LEVEL_CHOICE" in
                        1) delete_config=true ;;
                        2) delete_config=true; delete_certs=true ;;
                        3) delete_config=true; delete_certs=true; delete_metadata=true ;;
                    esac

                    # 获取相关文件路径
                    local CUSTOM_SNIPPET_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.custom_snippet')
                    local default_cert_file_delete="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE.cer"
                    local default_key_file_delete="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE.key"
                    local CERT_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r --arg default_cert "$default_cert_file_delete" '.cert_file // $default_cert')
                    local KEY_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r --arg default_key "$default_key_file_delete" '.key_file // $default_key')
                    if [[ -z "$CERT_FILE_TO_DELETE" || "$CERT_FILE_TO_DELETE" == "null" ]]; then CERT_FILE_TO_DELETE="$default_cert_file_delete"; fi
                    if [[ -z "$KEY_FILE_TO_DELETE" || "$KEY_FILE_TO_DELETE" == "null" ]]; then KEY_FILE_TO_DELETE="$default_key_file_delete"; fi

                    if [ "$delete_config" = true ]; then
                        rm -f "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_DELETE.conf"
                        rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_DELETE.conf"
                        log_message GREEN "✅ 已删除 Nginx 配置文件。"
                    fi

                    if [ "$delete_certs" = true ]; then
                        # acme.sh --remove 不会删除实际文件，只会删除它的内部记录
                        # Use command array for robustness
                        local acme_remove_cmd_array=("$ACME_BIN" --remove -d "$DOMAIN_TO_DELETE" --ecc)
                        "${acme_remove_cmd_array[@]}" 2>/dev/null || true
                        log_message GREEN "✅ 已从 acme.sh 移除证书记录。"

                        # 删除实际的证书文件
                        if [ -f "$CERT_FILE_TO_DELETE" ]; then rm -f "$CERT_FILE_TO_DELETE"; log_message GREEN "✅ 已删除证书文件: $CERT_FILE_TO_DELETE"; fi
                        if [ -f "$KEY_FILE_TO_DELETE" ]; then rm -f "$KEY_FILE_TO_DELETE"; log_message GREEN "✅ 已删除私钥文件: $KEY_FILE_TO_DELETE"; fi

                        # 尝试删除 acme.sh 默认的证书目录，如果为空
                        if [ -d "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE" ] && [ -z "$(ls -A "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE" 2>/dev/null)" ]; then
                            rmdir "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE"
                            log_message GREEN "✅ 已删除空的默认证书目录 $SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE。"
                        fi

                        if [[ -n "$CUSTOM_SNIPPET_FILE_TO_DELETE" && "$CUSTOM_SNIPPET_FILE_TO_DELETE" != "null" && -f "$CUSTOM_SNIPPET_FILE_TO_DELETE" ]]; then
                            read -rp "$(echo -e "${CYAN}检测到自定义 Nginx 配置片段文件 '$CUSTOM_SNIPPET_FILE_TO_DELETE'，是否一并删除？[y/N]: ${RESET}")" DELETE_SNIPPET_CONFIRM
                            DELETE_SNIPPET_CONFIRM=${DELETE_SNIPPET_CONFIRM:-y}
                            if [[ "$DELETE_SNIPPET_CONFIRM" =~ ^[Yy]$ ]]; then
                                rm -f "$CUSTOM_SNIPPET_FILE_TO_DELETE"
                                log_message GREEN "✅ 已删除自定义 Nginx 片段文件。"
                            else
                                log_message YELLOW "ℹ️ 已保留自定义 Nginx 片段文件。"
                            fi
                        fi
                    fi

                    if [ "$delete_metadata" = true ]; then
                        if ! jq "del(.[] | select(.domain == \$domain_to_delete))" \
                            --arg domain_to_delete "$DOMAIN_TO_DELETE" \
                            "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                            log_message ERROR "❌ 从元数据中移除项目失败！"
                        else
                            mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                            log_message GREEN "✅ 已从元数据中移除项目。"
                        fi
                    fi

                    log_message GREEN "✅ 删除操作完成。"

                    if [ "$delete_config" = true ]; then
                        if ! control_nginx reload; then
                            log_message WARN "Nginx 重载失败。如果已无任何站点，此为正常现象。请手动检查Nginx状态。"
                        fi
                    fi
                else
                    log_message YELLOW "已取消删除操作。"
                fi
                sleep 2
                ;;
            3) # 编辑项目核心配置 (不含片段)
                read -rp "$(echo -e "${CYAN}请输入要编辑的域名: ${RESET}")" DOMAIN_TO_EDIT
                if [[ -z "$DOMAIN_TO_EDIT" ]]; then log_message RED "❌ 域名不能为空！"; sleep 1; continue; fi
                local CURRENT_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_EDIT\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$CURRENT_PROJECT_JSON" ]; then log_message RED "❌ 域名 $DOMAIN_TO_EDIT 未找到在已配置列表中。"; sleep 1; continue; fi

                local EDIT_TYPE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.type')
                local EDIT_NAME=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.name')
                local EDIT_RESOLVED_PORT=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.resolved_port')
                local EDIT_ACME_VALIDATION_METHOD=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.acme_validation_method')
                local EDIT_DNS_API_PROVIDER=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.dns_api_provider')
                local EDIT_USE_WILDCARD=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.use_wildcard')
                local EDIT_CA_SERVER_URL=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.ca_server_url')
                local EDIT_CA_SERVER_NAME=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.ca_server_name')
                local EDIT_CUSTOM_SNIPPET_ORIGINAL=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.custom_snippet')

                # 修复：使用 --arg 参数将 shell 变量安全地传递给 jq
                local default_cert_file_edit="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer"
                local default_key_file_edit="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                local EDIT_CERT_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r --arg default_cert "$default_cert_file_edit" '.cert_file // $default_cert')
                local KEY_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r --arg default_key "$default_key_file_edit" '.key_file // $default_key')

                if [[ -z "$EDIT_CERT_FILE" || "$EDIT_CERT_FILE" == "null" ]]; then EDIT_CERT_FILE="$default_cert_file_edit"; fi
                if [[ -z "$KEY_FILE" || "$KEY_FILE" == "null" ]]; then EDIT_KEY_FILE="$default_key_file_edit"; fi

                log_message BLUE "\n${CYAN}--- 编辑域名: $DOMAIN_TO_EDIT ---${RESET}"
                log_message INFO "${WHITE}当前配置:${RESET}"
                log_message INFO "  ${WHITE}类型: ${RESET}${YELLOW}$EDIT_TYPE${RESET}"
                log_message INFO "  ${WHITE}目标: ${RESET}${YELLOW}$EDIT_NAME (端口: $EDIT_RESOLVED_PORT)${RESET}"
                log_message INFO "  ${WHITE}验证方式: ${RESET}${YELLOW}$EDIT_ACME_VALIDATION_METHOD $( [[ -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]] && echo "($EDIT_DNS_API_PROVIDER)" || echo "" )${RESET}"
                log_message INFO "  ${WHITE}泛域名: ${RESET}${YELLOW}$( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "是" || echo "否" )${RESET}"
                log_message INFO "  ${WHITE}CA: ${RESET}${YELLOW}$EDIT_CA_SERVER_NAME${RESET}"
                log_message INFO "  ${WHITE}证书文件: ${RESET}${YELLOW}$EDIT_CERT_FILE${RESET}"
                log_message INFO "  ${WHITE}私钥文件: ${RESET}${YELLOW}$EDIT_KEY_FILE${RESET}"
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

                local FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                local NEED_REISSUE_OR_RELOAD_NGINX="n"

                read -rp "$(echo -e "${CYAN}修改后端目标 (格式：docker容器名 或 本地端口) [当前: $EDIT_NAME，回车不修改]: ${RESET}")" NEW_TARGET_INPUT
                if [[ -n "$NEW_TARGET_INPUT" ]]; then
                    if [[ "$NEW_TARGET_INPUT" != "$EDIT_NAME" ]]; then
                        NEED_REISSUE_OR_RELOAD_NGINX="y"
                    fi

                    if [ "$DOCKER_INSTALLED" = true ] && docker ps -aq --filter "name=$NEW_TARGET_INPUT" | head -n1 >/dev/null; then
                        NEW_NAME="$NEW_TARGET_INPUT"
                        NEW_TYPE="docker"
                        local HOST_MAPPED_PORT=$(docker inspect "$NEW_TARGET_INPUT" --format \
                            '{{ range $p, $conf := .NetworkSettings.Ports }}{{ if $conf }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
                            sed 's|/tcp||g' | awk '{print $1}' | head -n1)
                        if [[ -n "$HOST_MAPPED_PORT" ]]; then
                            NEW_RESOLVED_PORT="$HOST_MAPPED_PORT"
                            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                            log_message GREEN "✅ 新目标是 Docker 容器 $NEW_NAME，映射端口: $NEW_RESOLVED_PORT。"
                        else
                            local INTERNAL_EXPOSED_PORTS_ARRAY=()
                            while IFS= read -r port_entry; do
                                INTERNAL_EXPOSED_PORTS_ARRAY+=("$port_entry")
                            done < <(docker inspect "$NEW_TARGET_INPUT" | jq -r '.[].Config.ExposedPorts | keys[]' 2>/dev/null | sed 's|/tcp||g' | sort -n)

                            log_message YELLOW "⚠️ 容器 $NEW_TARGET_INPUT 未映射到宿主机端口。内部暴露端口："
                            if [ ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} -gt 0 ]; then
                                local port_idx=0
                                for p in "${INTERNAL_EXPOSED_PORTS_ARRAY[@]}"; do
                                    port_idx=$((port_idx + 1))
                                    echo -e "   ${YELLOW}${port_idx})${RESET} ${p}"
                                done
                                while true; do
                                    read -rp "$(echo -e "${CYAN}请选择一个内部端口序号，或直接输入端口号: ${RESET}")" PORT_SELECTION
                                    if [[ "$PORT_SELECTION" =~ ^[0-9]+$ ]]; then
                                        if (( PORT_SELECTION > 0 && PORT_SELECTION <= ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} )); then
                                            NEW_RESOLVED_PORT="${INTERNAL_EXPOSED_PORTS_ARRAY[PORT_SELECTION-1]}"
                                            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                                            log_message GREEN "✅ 已选择容器内部端口: $NEW_RESOLVED_PORT。"
                                            break
                                        elif (( PORT_SELECTION > 0 && PORT_SELECTION < 65536 )); then
                                            NEW_RESOLVED_PORT="$PORT_SELECTION"
                                            FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                                            log_message GREEN "✅ 已手动指定容器内部端口: $NEW_RESOLVED_PORT。"
                                            break
                                        fi
                                    fi
                                    log_message RED "❌ 输入无效。请重新选择或输入有效的端口号 (1-65536)。"
                                done
                            else
                                log_message YELLOW "   未检测到容器 $NEW_TARGET_INPUT 内部暴露的端口。"
                                while true; do read -rp "$(echo -e "${CYAN}请输入容器 $NEW_NAME 的内部端口: ${RESET}")" USER_INTERNAL_PORT_EDIT; if [[ "$USER_INTERNAL_PORT_EDIT" =~ ^[0-9]+$ && "$USER_INTERNAL_PORT_EDIT" -gt 0 && "$USER_INTERNAL_PORT_EDIT" -lt 65536 ]]; then NEW_RESOLVED_PORT="$USER_INTERNAL_PORT_EDIT"; FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"; log_message GREEN "✅ 已指定容器内部端口: $NEW_RESOLVED_PORT。"; break; else log_message RED "端口无效"; fi; done
                            fi
                        fi
                    elif [[ "$NEW_TARGET_INPUT" =~ ^[0-9]+$ ]]; then
                        NEW_NAME="$NEW_TARGET_INPUT"; NEW_TYPE="local_port"; NEW_RESOLVED_PORT="$NEW_TARGET_INPUT"
                        FINAL_PROXY_TARGET_URL="http://127.0.0.1:$NEW_RESOLVED_PORT"
                        log_message GREEN "✅ 新目标是本地端口: $NEW_RESOLVED_PORT。"
                    else
                        log_message RED "❌ 无效目标，保留原设置。"
                        NEW_TYPE="$EDIT_TYPE" # Reset to old values if invalid input
                        NEW_NAME="$EDIT_NAME"
                        NEW_RESOLVED_PORT="$EDIT_RESOLVED_PORT"
                        NEED_REISSUE_OR_RELOAD_NGINX="n"
                    fi
                fi
                sleep 1

                read -rp "$(echo -e "${CYAN}修改证书验证方式 (http-01 / dns-01) [当前: $EDIT_ACME_VALIDATION_METHOD，回车不修改]: ${RESET}")" NEW_VALIDATION_METHOD_INPUT
                NEW_VALIDATION_METHOD_INPUT=${NEW_VALIDATION_METHOD_INPUT:-$EDIT_ACME_VALIDATION_METHOD}
                if [[ "$NEW_VALIDATION_METHOD_INPUT" != "$EDIT_ACME_VALIDATION_METHOD" ]]; then
                    if [[ "$NEW_VALIDATION_METHOD_INPUT" = "http-01" || "$NEW_VALIDATION_METHOD_INPUT" = "dns-01" ]]; then
                         NEW_ACME_VALIDATION_METHOD="$NEW_VALIDATION_METHOD_INPUT"
                         log_message GREEN "✅ 验证方式已更新为: $NEW_ACME_VALIDATION_METHOD。"
                         NEED_REISSUE_OR_RELOAD_NGINX="y"
                         NEW_CA_SERVER_NAME="letsencrypt" # Default CA for new validation setup
                         NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                         NEW_CERT_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer" # Reset cert file paths to default for acme.sh management
                         NEW_KEY_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                    else
                        log_message RED "❌ 无效的验证方式，保留原设置。"
                    fi
                fi
                sleep 1

                if [ "$NEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                     read -rp "$(echo -e "${CYAN}修改泛域名设置 (y/n) [当前: $( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "y" || echo "n" )，回车不修改]: ${RESET}")" NEW_WILDCARD_INPUT
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

                     read -rp "$(echo -e "${CYAN}修改 DNS API 服务商 (dns_cf / dns_ali) [当前: $EDIT_DNS_API_PROVIDER，回车不修改]: ${RESET}")" NEW_DNS_PROVIDER_INPUT
                     NEW_DNS_PROVIDER_INPUT=${NEW_DNS_PROVIDER_INPUT:-$EDIT_DNS_API_PROVIDER}
                     if [[ "$NEW_DNS_PROVIDER_INPUT" != "$EDIT_DNS_API_PROVIDER" ]]; then
                         if [[ "$NEW_DNS_PROVIDER_INPUT" = "dns_cf" || "$NEW_DNS_PROVIDER_INPUT" = "dns_ali" ]]; then
                             NEW_DNS_API_PROVIDER="$NEW_DNS_PROVIDER_INPUT"
                             log_message GREEN "✅ DNS API 服务商已更新为: $NEW_DNS_API_PROVIDER。"
                             NEED_REISSUE_OR_RELOAD_NGINX="y"
                             if ! check_dns_env "$NEW_DNS_API_PROVIDER"; then
                                log_message ERROR "DNS 环境变量检查失败，请设置后重试。"
                                sleep 2
                                continue # 跳过当前编辑，用户需重新设置
                             fi
                         else
                             log_message RED "❌ 无效的 DNS 服务商。将保留原有设置。"
                         fi
                     fi
                     sleep 1
                else # 如果是非 dns-01 验证，泛域名和 DNS API 设为空
                    if [[ "$EDIT_USE_WILDCARD" = "y" || -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                    NEW_USE_WILDCARD="n"
                    NEW_DNS_API_PROVIDER=""
                fi

                if [[ "$EDIT_ACME_VALIDATION_METHOD" = "imported" || "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]]; then
                    log_message INFO "${BLUE}\n请选择新的证书颁发机构 (CA):${RESET}"
                    echo "${GREEN}1) Let's Encrypt (当前: ${NEW_CA_SERVER_NAME:-letsencrypt})${RESET}"
                    echo "${GREEN}2) ZeroSSL${RESET}"
                    echo "${GREEN}3) 自定义 ACME 服务器 URL${RESET}"
                    read -rp "$(echo -e "${CYAN}请输入序号 [1]: ${RESET}")" NEW_CA_CHOICE
                    NEW_CA_CHOICE=${NEW_CA_CHOICE:-1}
                    case $NEW_CA_CHOICE in
                        1) NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; NEW_CA_SERVER_NAME="letsencrypt";;
                        2) NEW_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; NEW_CA_SERVER_NAME="zerossl";;
                        3)
                            read -rp "$(echo -e "${CYAN}请输入自定义 ACME 服务器 URL: ${RESET}")" CUSTOM_ACME_URL
                            if [[ -n "$CUSTOM_ACME_URL" ]]; then
                                NEW_CA_SERVER_URL="$CUSTOM_ACME_URL"
                                NEW_CA_SERVER_NAME="Custom"
                                log_message INFO "⚠️ 正在使用自定义 ACME 服务器 URL。请确保其有效。"
                            else
                                log_message YELLOW "未输入自定义 URL，将使用默认 Let's Encrypt。"
                            fi
                            ;;
                        *) log_message YELLOW "⚠️ 无效选择，将使用默认 Let's Encrypt。";;
                    esac
                    log_message BLUE "➡️ 选定新的 CA: $NEW_CA_SERVER_NAME"

                    if [ "$NEW_CA_SERVER_NAME" = "zerossl" ]; then
                         log_message BLUE "🔍 检查 ZeroSSL 账户注册状态..."
                         if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
                            log_message YELLOW "⚠️ 未检测到 ZeroSSL 账户已注册。"
                            read -rp "$(echo -e "${CYAN}请输入用于注册 ZeroSSL 的邮箱地址: ${RESET}")" NEW_ZERO_SSL_ACCOUNT_EMAIL
                            while [[ ! "$NEW_ZERO_SSL_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                                log_message RED "❌ 邮箱格式不正确。请重新输入。"
                                read -rp "$(echo -e "${CYAN}请输入用于注册 ZeroSSL 的邮箱地址: ${RESET}")" NEW_ZERO_SSL_ACCOUNT_EMAIL
                                [[ -z "$NEW_ZERO_SSL_ACCOUNT_EMAIL" ]] && break
                            done
                            if [[ -z "$NEW_ZERO_SSL_ACCOUNT_EMAIL" ]]; then
                                log_message RED "❌ 未提供邮箱，无法注册 ZeroSSL 账户。操作已取消。"
                                sleep 2
                                continue # 返回编辑菜单
                            fi
                            log_message BLUE "➡️ 正在注册 ZeroSSL 账户: $NEW_ZERO_SSL_ACCOUNT_EMAIL..."
                            local acme_reg_cmd_array=("$ACME_BIN" --register-account -m "$NEW_ZERO_SSL_ACCOUNT_EMAIL" --server "$NEW_CA_SERVER_URL")
                            if ! "${acme_reg_cmd_array[@]}"; then
                                log_message ERROR "❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。"
                                sleep 2
                                continue # 返回编辑菜单
                            fi
                            log_message GREEN "✅ ZeroSSL 账户注册成功。"
                         else
                            log_message GREEN "✅ ZeroSSL 账户已注册。"
                         fi
                    fi
                fi
                sleep 1

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

                if ! jq "(.[] | select(.domain == \$domain_to_edit)) = \$updated_project_json" \
                    --arg domain_to_edit "$DOMAIN_TO_EDIT" \
                    --argjson updated_project_json "$UPDATED_PROJECT_JSON" \
                    "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    log_message ERROR "❌ 更新项目元数据失败！"
                else
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    log_message GREEN "✅ 项目元数据已更新。"
                fi
                sleep 1

                if [ "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]; then
                    log_message YELLOW "ℹ️ 检测到与证书或 Nginx 配置相关的关键修改。"
                    read -rp "$(echo -e "${CYAN}是否立即更新 Nginx 配置并尝试重新申请证书？(强烈建议) [y/N]: ${RESET}")" UPDATE_NOW
                    UPDATE_NOW=${UPDATE_NOW:-y}
                    if [[ "$UPDATE_NOW" =~ ^[Yy]$ ]]; then
                        log_message YELLOW "重新生成 Nginx 配置并申请证书..."

                        if [ "$NEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                            log_message YELLOW "生成 Nginx 临时 HTTP 配置以进行证书验证..."
                            local DOMAIN_CONF_EDIT="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_EDIT.conf"
                            _NGINX_HTTP_CHALLENGE_TEMPLATE "$DOMAIN_TO_EDIT" > "$DOMAIN_CONF_EDIT"
                            if [ ! -L "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_EDIT.conf" ]; then
                                ln -sf "$DOMAIN_CONF_EDIT" "$NGINX_SITES_ENABLED_DIR/"
                            fi
                            if ! control_nginx restart; then
                                log_message ERROR "❌ Nginx 重启失败，证书申请将无法进行。清理临时配置并退出编辑模式。"
                                rm -f "$DOMAIN_CONF_EDIT"
                                rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_EDIT.conf"
                                sleep 2
                                continue # 回到管理菜单
                            fi
                        fi

                        log_message YELLOW "正在为 $DOMAIN_TO_EDIT 申请证书 (CA: $NEW_CA_SERVER_NAME, 验证方式: $NEW_ACME_VALIDATION_METHOD)..."
                        local ACME_REISSUE_CMD_LOG_OUTPUT=$(mktemp acme_cmd_log.XXXXXX)
                        # Construct acme reissue command array
                        local acme_reissue_cmd_array=("$ACME_BIN" --issue --force -d "$DOMAIN_TO_EDIT" --ecc --server "$NEW_CA_SERVER_URL")
                        if [ "$NEW_USE_WILDCARD" = "y" ]; then
                            acme_reissue_cmd_array+=("-d" "*.$DOMAIN_TO_EDIT")
                        fi
                        if [ "$NEW_ACME_VALIDATION_METHOD" = "http-01" ]; then
                            acme_reissue_cmd_array+=("-w" "$NGINX_WEBROOT_DIR")
                        elif [ "$NEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                            acme_reissue_cmd_array+=("--dns" "$NEW_DNS_API_PROVIDER")
                        fi

                        if ! "${acme_reissue_cmd_array[@]}" > "$ACME_REISSUE_CMD_LOG_OUTPUT" 2>&1; then
                            log_message ERROR "❌ 域名 $DOMAIN_TO_EDIT 的证书重新申请失败！"
                            cat "$ACME_REISSUE_CMD_LOG_OUTPUT"
                            analyze_acme_error "$(cat "$ACME_REISSUE_CMD_LOG_OUTPUT")"
                            rm -f "$ACME_REISSUE_CMD_LOG_OUTPUT"
                            sleep 2
                            continue # Re-issue failed, back to manage menu
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

                        if ! jq "(.[] | select(.domain == \$domain_to_edit)) |= . + \$latest_acme_cert_json" \
                            --arg domain_to_edit "$DOMAIN_TO_EDIT" \
                            --argjson latest_acme_cert_json "$LATEST_ACME_CERT_JSON" \
                            "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                            log_message ERROR "❌ 更新证书文件路径到元数据失败！"
                        else
                            mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                            log_message GREEN "✅ 证书已成功重新签发，路径已更新至脚本默认管理路径。"
                        fi
                        sleep 1

                        # Construct INSTALL_CERT_DOMAINS_ARRAY for --install-cert
                        local INSTALL_CERT_DOMAINS_ARRAY=()
                        INSTALL_CERT_DOMAINS_ARRAY+=("-d" "$DOMAIN_TO_EDIT")
                        if [ "$NEW_USE_WILDCARD" = "y" ]; then
                            INSTALL_CERT_DOMAINS_ARRAY+=("-d" "*.$DOMAIN_TO_EDIT")
                        fi
                        # acme.sh 会自动执行 --reloadcmd
                        local acme_install_cmd_array=(
                            "$ACME_BIN" --install-cert "${INSTALL_CERT_DOMAINS_ARRAY[@]}" --ecc
                            --key-file "$NEW_KEY_FILE"
                            --fullchain-file "$NEW_CERT_FILE"
                            --reloadcmd "systemctl reload nginx"
                        )
                        if ! "${acme_install_cmd_array[@]}"; then
                            log_message ERROR "❌ acme.sh 证书安装或Nginx重载失败。"; sleep 2; continue;
                        fi

                        log_message YELLOW "生成 $DOMAIN_TO_EDIT 的最终 Nginx 配置..."
                        _NGINX_FINAL_TEMPLATE "$DOMAIN_TO_EDIT" "$FINAL_PROXY_TARGET_URL" "$NEW_CERT_FILE" "$NEW_KEY_FILE" "$EDIT_CUSTOM_SNIPPET_ORIGINAL" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_EDIT.conf"
                        log_message GREEN "✅ 域名 $DOMAIN_TO_EDIT 的 Nginx 配置已更新。"
                        sleep 1
                        if ! control_nginx reload; then
                            log_message ERROR "❌ 最终 Nginx 配置重载失败，请手动检查 Nginx 服务状态！"
                            sleep 2
                            continue
                        fi
                        log_message GREEN "🚀 域名 $DOMAIN_TO_EDIT 配置更新完成。"
                    else
                        log_message YELLOW "ℹ️ 已跳过证书重新申请和 Nginx 配置更新。请手动操作以确保生效。"
                    fi
                else
                    log_message YELLOW "ℹ️ 项目配置已修改。请手动重新加载 Nginx (systemctl reload nginx) 以确保更改生效。"
                fi
                sleep 2
                ;;
            4) # 管理自定义 Nginx 配置片段
                read -rp "$(echo -e "${CYAN}请输入要管理片段的域名: ${RESET}")" DOMAIN_FOR_SNIPPET
                if [[ -z "$DOMAIN_FOR_SNIPPET" ]]; then log_message RED "❌ 域名不能为空！"; sleep 1; continue; fi
                local SNIPPET_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_FOR_SNIPPET\")" "$PROJECTS_METADATA_FILE")
                if [ -z "$SNIPPET_PROJECT_JSON" ]; then log_message RED "❌ 域名 $DOMAIN_FOR_SNIPPET 未找到在已配置列表中。"; sleep 1; continue; fi

                local CURRENT_SNIPPET_PATH=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.custom_snippet')
                local PROJECT_TYPE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.type')
                local PROJECT_NAME_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.name')
                local RESOLVED_PORT_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.resolved_port')
                local ACME_VALIDATION_METHOD_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.acme_validation_method')
                local DNS_API_PROVIDER_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.dns_api_provider')
                local USE_WILDCARD_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.use_wildcard')

                # 修复：使用 --arg 参数将 shell 变量安全地传递给 jq
                local default_cert_file_snippet="$SSL_CERTS_BASE_DIR/$DOMAIN_FOR_SNIPPET.cer"
                local default_key_file_snippet="$SSL_CERTS_BASE_DIR/$DOMAIN_FOR_SNIPPET.key"
                local CERT_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r --arg default_cert "$default_cert_file_snippet" '.cert_file // $default_cert')
                local KEY_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r --arg default_key "$default_key_file_snippet" '.key_file // $default_key')

                if [[ -z "$CERT_FILE_SNIPPET" || "$CERT_FILE_SNIPPET" == "null" ]]; then CERT_FILE_SNIPPET="$default_cert_file_snippet"; fi
                if [[ -z "$KEY_FILE_SNIPPET" || "$KEY_FILE_SNIPPET" == "null" ]]; then KEY_FILE_SNIPPET="$default_key_file_snippet"; fi

                log_message BLUE "\n${CYAN}--- 管理域名 $DOMAIN_FOR_SNIPPET 的 Nginx 配置片段 ---${RESET}"
                if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then log_message YELLOW "当前自定义片段文件: $CURRENT_SNIPPET_PATH"; else log_message INFO "当前未设置自定义片段文件。"; fi
                sleep 1

                local DEFAULT_SNIPPET_FILENAME=""
                if [ "$PROJECT_TYPE_SNIPPET" = "docker" ]; then DEFAULT_SNIPPET_FILENAME="$PROJECT_NAME_SNIPPET.conf"; else DEFAULT_SNIPPET_FILENAME="$DOMAIN_FOR_SNIPPET.conf"; fi
                local DEFAULT_SNIPPET_PATH="$NGINX_CUSTOM_SNIPPETS_DIR/$DEFAULT_SNIPPET_FILENAME"

                local SNIPPET_MANAGEMENT_ACTION=""
                while true; do
                    log_message BLUE "\n${CYAN}请选择片段管理操作 for $DOMAIN_FOR_SNIPPET:${RESET}"
                    if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                        echo "${GREEN}1) 修改片段文件路径 (当前: $(basename "$CURRENT_SNIPPET_PATH"))${RESET}"
                        echo "${GREEN}2) 编辑当前片段文件内容 (用 nano)${RESET}"
                        echo "${RED}3) 清除自定义片段设置并删除文件${RESET}"
                    else
                        echo "${GREEN}1) 设置新的片段文件路径${RESET}"
                    fi
                    echo "${YELLOW}0) 返回上级菜单${RESET}"
                    read -rp "$(echo -e "${CYAN}请输入选项: ${RESET}")" SNIPPET_MANAGEMENT_ACTION

                    local CHOSEN_SNIPPET_PATH="$CURRENT_SNIPPET_PATH" # 默认保持不变
                    local RELOAD_NGINX_AFTER_UPDATE="n"

                    case "$SNIPPET_MANAGEMENT_ACTION" in
                        1) # 修改片段文件路径
                            read -rp "$(echo -e "${CYAN}请输入新的片段文件完整路径 (回车用默认: $DEFAULT_SNIPPET_PATH): ${RESET}")" NEW_SNIPPET_INPUT
                            if [[ -z "$NEW_SNIPPET_INPUT" ]]; then CHOSEN_SNIPPET_PATH="$DEFAULT_SNIPPET_PATH";
                            else CHOSEN_SNIPPET_PATH="$NEW_SNIPPET_INPUT"; fi

                            if ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH")"; then
                                log_message RED "❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH")。操作取消。"
                                sleep 2
                                continue
                            fi
                            log_message GREEN "✅ 将使用新路径: $CHOSEN_SNIPPET_PATH";
                            RELOAD_NGINX_AFTER_UPDATE="y"
                            break # 跳出当前内部循环，执行更新元数据和Nginx配置的逻辑
                            ;;
                        2) # 编辑当前片段文件内容
                            if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                                if [ -f "$CURRENT_SNIPPET_PATH" ]; then
                                    log_message INFO "正在使用 nano 编辑文件: $CURRENT_SNIPPET_PATH"
                                    # 确保 nano 命令存在
                                    if ! command -v nano &>/dev/null; then
                                        log_message ERROR "❌ nano 编辑器未安装。请手动安装 'nano' 或编辑文件。"
                                        sleep 2
                                        continue
                                    fi
                                    nano "$CURRENT_SNIPPET_PATH"
                                    log_message YELLOW "ℹ️ 文件已保存。正在检查 Nginx 配置并尝试重载..."
                                    if ! control_nginx reload; then
                                        log_message ERROR "❌ Nginx 重载失败！请检查片段文件 '$CURRENT_SNIPPET_PATH' 的语法错误！"
                                        sleep 3
                                    else
                                        log_message GREEN "✅ Nginx 配置已重载，更改已应用。"
                                    fi
                                else
                                    log_message RED "❌ 片段文件 '$CURRENT_SNIPPET_PATH' 不存在，无法编辑。请先设置或创建它。"
                                    sleep 2
                                fi
                            else
                                log_message YELLOW "⚠️ 未设置自定义片段文件，请先选择 '1. 设置新的片段文件路径'。"
                                sleep 2
                            fi
                            ;;
                        3) # 清除自定义片段设置并删除文件
                            if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                                read -rp "$(echo -e "${CYAN}⚠️ 确认清除自定义片段设置并删除文件 '$CURRENT_SNIPPET_PATH'？此操作不可逆！[y/N]: ${RESET}")" CONFIRM_CLEAR_SNIPPET
                                CONFIRM_CLEAR_SNIPPET=${CONFIRM_CLEAR_SNIPPET:-n}
                                if [[ "$CONFIRM_CLEAR_SNIPPET" =~ ^[Yy]$ ]]; then
                                    rm -f "$CURRENT_SNIPPET_PATH"
                                    log_message GREEN "✅ 已删除片段文件: $CURRENT_SNIPPET_PATH。"
                                    CHOSEN_SNIPPET_PATH="" # 将路径设置为空以清除元数据记录
                                    RELOAD_NGINX_AFTER_UPDATE="y"
                                    break # 跳出当前内部循环，执行更新元数据和Nginx配置的逻辑
                                else
                                    log_message YELLOW "ℹ️ 已取消删除片段文件。"
                                fi
                            else
                                log_message YELLOW "⚠️ 当前未设置自定义片段文件，无需清除。"
                            fi
                            sleep 1
                            ;;
                        0) # 返回上级菜单
                            break 2 # 跳出两层循环，返回到 manage_configs 主循环
                            ;;
                        *)
                            log_message RED "❌ 无效选项，请重新输入。"
                            sleep 1
                            ;;
                    esac
                done

                # 如果 CHOSEN_SNIPPET_PATH 与 CURRENT_SNIPPET_PATH 不同，或者需要重新加载 Nginx
                if [[ "$CHOSEN_SNIPPET_PATH" != "$CURRENT_SNIPPET_PATH" || "$RELOAD_NGINX_AFTER_UPDATE" = "y" ]]; then
                    local UPDATED_SNIPPET_JSON_OBJ=$(jq -n --arg custom_snippet "$CHOSEN_SNIPPET_PATH" '{custom_snippet: $custom_snippet}')
                    if ! jq "(.[] | select(.domain == \$domain_for_snippet)) |= . + \$updated_snippet_json_obj" \
                        --arg domain_for_snippet "$DOMAIN_FOR_SNIPPET" \
                        --argjson updated_snippet_json_obj "$UPDATED_SNIPPET_JSON_OBJ" \
                        "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                        log_message ERROR "❌ 更新项目元数据失败！"
                        sleep 2
                        continue
                    else
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        log_message GREEN "✅ 项目元数据中的自定义片段路径已更新。"
                    fi
                    sleep 1

                    local PROXY_TARGET_URL_SNIPPET="http://127.0.0.1:$RESOLVED_PORT_SNIPPET"
                    local DOMAIN_CONF_SNIPPET="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_FOR_SNIPPET.conf"

                    log_message YELLOW "正在重新生成 $DOMAIN_FOR_SNIPPET 的 Nginx 配置..."
                    _NGINX_FINAL_TEMPLATE "$DOMAIN_FOR_SNIPPET" "$PROXY_TARGET_URL_SNIPPET" "$CERT_FILE_SNIPPET" "$KEY_FILE_SNIPPET" "$CHOSEN_SNIPPET_PATH" > "$DOMAIN_CONF_SNIPPET"

                    if ! control_nginx reload; then
                        log_message ERROR "❌ Nginx 重载失败，请手动检查 Nginx 服务状态！"
                        sleep 2
                        continue
                    fi
                    log_message GREEN "🚀 域名 $DOMAIN_FOR_SNIPPET 的 Nginx 配置已更新并重载。"
                    sleep 1

                    # 只有在路径改变且旧路径非空时才提示删除旧文件
                    if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" && "$CHOSEN_SNIPPET_PATH" != "$CURRENT_SNIPPET_PATH" && -f "$CURRENT_SNIPPET_PATH" ]]; then
                        read -rp "$(echo -e "${CYAN}检测到原有自定义片段文件 '$CURRENT_SNIPPET_PATH'。是否删除此文件？[y/N]: ${RESET}")" DELETE_OLD_SNIPPET_CONFIRM
                        DELETE_OLD_SNIPPET_CONFIRM=${DELETE_OLD_SNIPPET_CONFIRM:-y}
                        if [[ "$DELETE_OLD_SNIPPET_CONFIRM" =~ ^[Yy]$ ]]; then
                            rm -f "$CURRENT_SNIPPET_PATH"
                            log_message GREEN "✅ 已删除旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH"
                        else
                            log_message YELLOW "ℹ️ 已保留旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH"
                        fi
                    fi
                fi
                sleep 2
                ;;
            5) # 导入现有 Nginx 配置到本脚本管理
                import_existing_project
                # 导入后继续显示管理菜单
                continue
                ;;
            0)
                break
                ;;
            *)
                log_message RED "❌ 无效选项，请输入 0-5"
                sleep 1
                ;;
        esac
    done
}

# --- 检查并自动续期所有证书的函数
check_and_auto_renew_certs() {
    check_root
    log_message INFO "${CYAN}--- 🔄 检查并自动续期所有证书 ---${RESET}"

    if [ ! -f "$PROJECTS_METADATA_FILE" ] || [ "$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
        log_message YELLOW "未找到任何已配置的项目，无需续期。"
        return 0
    fi

    local temp_renew_count_file=$(mktemp acme_cmd_log.XXXXXX)
    local temp_fail_count_file=$(mktemp acme_cmd_log.XXXXXX)
    echo "0" > "$temp_renew_count_file"
    echo "0" > "$temp_fail_count_file"

    jq -c '.[]' "$PROJECTS_METADATA_FILE" | while read -r project_json; do
        local DOMAIN=$(echo "$project_json" | jq -r '.domain')
        local ACME_VALIDATION_METHOD=$(echo "$project_json" | jq -r '.acme_validation_method')
        local DNS_API_PROVIDER=$(echo "$project_json" | jq -r '.dns_api_provider')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard')
        local CA_SERVER_URL=$(echo "$project_json" | jq -r '.ca_server_url')

        # 修复：使用 --arg 参数将 shell 变量安全地传递给 jq
        local default_cert_file_auto="$SSL_CERTS_BASE_DIR/$DOMAIN.cer"
        local default_key_file_auto="$SSL_CERTS_BASE_DIR/$DOMAIN.key"
        local CERT_FILE=$(echo "$project_json" | jq -r --arg default_cert "$default_cert_file_auto" '.cert_file // $default_cert')
        local KEY_FILE=$(echo "$project_json" | jq -r --arg default_key "$default_key_file_auto" '.key_file // $default_key')

        if [[ -z "$CERT_FILE" || "$CERT_FILE" == "null" ]]; then CERT_FILE="$default_cert_file_auto"; fi
        if [[ -z "$KEY_FILE" || "$KEY_FILE" == "null" ]]; then KEY_FILE="$default_key_file_auto"; fi

        if [[ ! -f "$CERT_FILE" ]]; then
            log_message YELLOW "⚠️ 域名 $DOMAIN 证书文件 $CERT_FILE 不存在，跳过续期。"
            echo $(( $(cat "$temp_fail_count_file") + 1 )) > "$temp_fail_count_file" # 计入失败
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
            local RENEW_CMD_LOG_OUTPUT=$(mktemp acme_cmd_log.XXXXXX)

            # Construct acme renew command array
            local acme_renew_cmd_array=("$ACME_BIN" --renew -d "$DOMAIN" --ecc --server "$CA_SERVER_URL") # 自动续期不强制 --force
            if [ "$USE_WILDCARD" = "y" ]; then
                acme_renew_cmd_array+=("-d" "*.$DOMAIN")
            fi

            if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
                acme_renew_cmd_array+=("-w" "$NGINX_WEBROOT_DIR")
            elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
                acme_renew_cmd_array+=("--dns" "$DNS_API_PROVIDER")
                log_message YELLOW "ℹ️ 续期 DNS 验证证书需要设置相应的 DNS API 环境变量。"
                if ! check_dns_env "$DNS_API_PROVIDER"; then
                    log_message ERROR "DNS 环境变量检查失败，跳过域名 $DOMAIN 的续期。"
                    rm -f "$RENEW_CMD_LOG_OUTPUT"
                    echo $(( $(cat "$temp_fail_count_file") + 1 )) > "$temp_fail_count_file" # 更新失败计数
                    continue
                fi
            fi

            if "${acme_renew_cmd_array[@]}" > "$RENEW_CMD_LOG_OUTPUT" 2>&1; then
                log_message GREEN "✅ 域名 $DOMAIN 证书续期成功。"
                echo $(( $(cat "$temp_renew_count_file") + 1 )) > "$temp_renew_count_file" # 更新成功计数
            else
                log_message ERROR "❌ 域名 $DOMAIN 证书续期失败！"
                cat "$RENEW_CMD_LOG_OUTPUT"
                analyze_acme_error "$(cat "$RENEW_CMD_LOG_OUTPUT")"
                echo $(( $(cat "$temp_fail_count_file") + 1 )) > "$temp_fail_count_file" # 更新失败计数
            fi
            rm -f "$RENEW_CMD_LOG_OUTPUT"
            sleep 1
        else
            log_message INFO "✅ 域名 $DOMAIN 证书有效 (${LEFT_DAYS}天剩余)，无需续期。"
        fi
    done

    local RENEWED_COUNT=$(cat "$temp_renew_count_file")
    local FAILED_COUNT=$(cat "$temp_fail_count_file")
    rm -f "$temp_renew_count_file" "$temp_fail_count_file"

    log_message BLUE "\n${CYAN}--- 续期结果 ---${RESET}"
    log_message GREEN "成功续期: $RENEWED_COUNT 个证书。"
    log_message RED "失败续期: $FAILED_COUNT 个证书。"
    log_message BLUE "${CYAN}--------------------------${RESET}"

    log_message YELLOW "ℹ️ 建议设置一个 Cron 任务来定期自动执行此功能。"
    log_message YELLOW "   例如，每周执行一次（请将 '${MAGENTA}/path/to/your/script.sh${RESET}' 替换为脚本的${RED}绝对路径${RESET}${YELLOW}）："
    log_message MAGENTA "   0 3 * * 0 /path/to/your/script.sh 3 >/dev/null 2>&1"
    log_message YELLOW "   (这里的 '${MAGENTA}3${RESET}${YELLOW}' 是主菜单中 '检查并自动续期所有证书' 的${MAGENTA}选项号${RESET}${YELLOW})${RESET}"
    log_message INFO "${CYAN}--- 自动续期完成 ---${RESET}"
    sleep 2
}

# -----------------------------
# 管理 acme.sh 账户的函数
manage_acme_accounts() {
    check_root
    while true; do
        log_message INFO "${CYAN}--- 👤 acme.sh 账户管理 ---${RESET}"
        echo "${GREEN}1) 查看已注册账户${RESET}"
        echo "${GREEN}2) 注册新账户${RESET}"
        echo "${GREEN}3) 设置默认账户${RESET}"
        echo "${YELLOW}0) 返回主菜单${RESET}"
        log_message INFO "${BLUE}---------------------------${RESET}"
        read -rp "$(echo -e "${CYAN}请输入选项 [回车返回]: ${RESET}")" ACCOUNT_CHOICE
        ACCOUNT_CHOICE=${ACCOUNT_CHOICE:-0}
        case "$ACCOUNT_CHOICE" in
            1)
                log_message BLUE "🔍 已注册 acme.sh 账户列表:"
                "$ACME_BIN" --list-account
                sleep 2
                ;;
            2)
                log_message BLUE "➡️ 注册新 acme.sh 账户:"
                read -rp "$(echo -e "${CYAN}请输入新账户的邮箱地址: ${RESET}")" NEW_ACCOUNT_EMAIL
                while [[ ! "$NEW_ACCOUNT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; do
                    log_message RED "❌ 邮箱格式不正确。请重新输入。"
                    read -rp "$(echo -e "${CYAN}请输入新账户的邮箱地址: ${RESET}")" NEW_ACCOUNT_EMAIL
                    [[ -z "$NEW_ACCOUNT_EMAIL" ]] && break
                done
                if [[ -z "$NEW_ACCOUNT_EMAIL" ]]; then
                    log_message RED "❌ 未提供邮箱，注册账户操作已取消。"
                    sleep 1
                    continue
                fi

                local REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                local REGISTER_CA_SERVER_NAME="letsencrypt"
                log_message INFO "${BLUE}\n请选择证书颁发机构 (CA):${RESET}"
                echo "${GREEN}1) Let's Encrypt (默认)${RESET}"
                echo "${GREEN}2) ZeroSSL${RESET}"
                echo "${GREEN}3) 自定义 ACME 服务器 URL${RESET}"
                read -rp "$(echo -e "${CYAN}请输入序号: ${RESET}")" REGISTER_CA_CHOICE
                REGISTER_CA_CHOICE=${REGISTER_CA_CHOICE:-1}
                case $REGISTER_CA_CHOICE in
                    1) REGISTER_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"; REGISTER_CA_SERVER_NAME="letsencrypt";;
                    2) REGISTER_CA_SERVER_URL="https://acme.zerossl.com/v2/DV90"; REGISTER_CA_SERVER_NAME="zerossl";;
                    3)
                        read -rp "$(echo -e "${CYAN}请输入自定义 ACME 服务器 URL: ${RESET}")" CUSTOM_ACME_URL
                        if [[ -n "$CUSTOM_ACME_URL" ]]; then
                            REGISTER_CA_SERVER_URL="$CUSTOM_ACME_URL"
                            REGISTER_CA_SERVER_NAME="Custom"
                            log_message INFO "⚠️ 正在使用自定义 ACME 服务器 URL。请确保其有效。"
                        else
                            log_message YELLOW "未输入自定义 URL，将使用默认 Let's Encrypt。"
                        fi
                        ;;
                    *) log_message YELLOW "⚠️ 无效选择，将使用默认 Let's Encrypt。";;
                esac
                log_message BLUE "➡️ 选定 CA: $REGISTER_CA_SERVER_NAME"

                log_message GREEN "🚀 正在注册账户 $NEW_ACCOUNT_EMAIL (CA: $REGISTER_CA_SERVER_NAME)..."
                local acme_reg_cmd_array=("$ACME_BIN" --register-account -m "$NEW_ACCOUNT_EMAIL" --server "$REGISTER_CA_SERVER_URL")
                if "${acme_reg_cmd_array[@]}"; then
                    log_message GREEN "✅ 账户注册成功。"
                else
                    log_message RED "❌ 账户注册失败！请检查邮箱地址或网络。"
                fi
                sleep 2
                ;;
            3)
                log_message BLUE "➡️ 设置默认 acme.sh 账户:"
                "$ACME_BIN" --list-account # 列出账户，让用户选择
                read -rp "$(echo -e "${CYAN}请输入要设置为默认的账户邮箱地址: ${RESET}")" DEFAULT_ACCOUNT_EMAIL
                if [[ -z "$DEFAULT_ACCOUNT_EMAIL" ]]; then
                    log_message RED "❌ 邮箱不能为空。"
                    sleep 1
                    continue
                fi
                log_message GREEN "🚀 正在设置 $DEFAULT_ACCOUNT_EMAIL 为默认账户..."
                local acme_set_default_cmd_array=("$ACME_BIN" --set-default-account -m "$DEFAULT_ACCOUNT_EMAIL")
                if "${acme_set_default_cmd_array[@]}"; then
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
                sleep 1
                ;;
        esac
    done
}


# --- 主菜单 ---
main_menu() {
    while true; do
        log_message INFO "${CYAN}╔═══════════════════════════════════════╗${RESET}"
        log_message INFO "${CYAN}║     🚀 Nginx/HTTPS 证书管理主菜单     ║${RESET}"
        log_message INFO "${CYAN}╚═══════════════════════════════════════╝${RESET}"
        log_message INFO "" # 添加空行美化
        echo -e "${GREEN}  1) 配置新的 Nginx 反向代理和 HTTPS 证书${RESET}"
        echo -e "${GREEN}  2) 查看与管理已配置项目 (域名、端口、证书)${RESET}"
        echo -e "${GREEN}  3) 检查并自动续期所有证书${RESET}"
        echo -e "${GREEN}  4) 管理 acme.sh 账户${RESET}"
        echo -e "${YELLOW}  0) 退出${RESET}"
        log_message INFO "${CYAN}───────────────────────────────────────${RESET}"
        # 修改 read -rp 提示，将颜色部分移到 echo -e 之外，或者确保整个字符串被 `echo -e` 预处理
        # 这里使用 `echo -e` + `read -r` 来避免 `read -rp` 对转义序列的潜在不处理
        echo -e "${CYAN}➜ 请输入选项 [回车退出]: ${RESET}\c" # `\c` 避免换行
        read -r MAIN_CHOICE
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
                    exit 10
                else
                    log_message BLUE "👋 感谢使用，已退出。"
                    log_message INFO "--- 脚本执行结束: $(date +"%Y-%m-%d %H:%M:%S") ---"
                    exit 0
                fi
                ;;
            *)
                log_message RED "❌ 无效选项，请输入 0-4"
                sleep 1
                ;;
        esac
    done
}

# --- 脚本入口 ---
# 根据入口参数，如果是用于Cron的自动续期，则直接执行，并设置非交互模式
if [[ "${1:-}" == "3" ]]; then
    # IS_INTERACTIVE_MODE="false" 已经在脚本开头根据 $1 的值设置了
    check_and_auto_renew_certs
    exit 0
fi

main_menu
