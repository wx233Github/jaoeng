#!/bin/bash
# ==============================================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手（基于 acme.sh） (v1.0.6-深度重构与优化)
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
# - **优化**: `manage_configs` 子菜单提示优化，移除冗余的“或 [] 操作,”。
# - **优化**: `manage_configs` 返回逻辑与父脚本 `install.sh` 保持一致，使用 `return 10`。
# - **优化**: `log_message` 函数在交互模式下，统一输出级别前缀。
# - **优化**: `sleep` 操作已移除，由用户输入自然暂停。
# - **优化**: `IS_INTERACTIVE_MODE` 判断逻辑更明确。
# - **新增**: 实现 `check_and_auto_renew_certs` 函数，用于自动检查和续期所有证书。
# - **优化**: `check_root` 函数现在返回错误代码而不是直接退出，所有调用者都已更新以检查返回码。
# - **修复/优化**: 改进 `check_dns_env` 在非交互模式下的行为，确保失败时终止操作。
# - **修复/优化**: 改进 `acme.sh` 错误日志的打印，避免重复前缀。
# - **优化**: 将重复的 Docker 端口选择和自定义片段路径输入逻辑提取为辅助函数 `_prompt_for_docker_internal_port` 和 `_prompt_for_custom_snippet_path`。
# - **优化**: 新增辅助函数 `_build_project_json_object` 减少 JSON 构建重复代码。
# - **重构**: 引入 `_prompt_user_input_with_validation` 通用输入函数，减少重复。
# - **重构**: 封装 `_select_acme_ca_server` 和 `_ensure_zerossl_account` 提高 CA 逻辑复用。
# - **重构**: 封装 `_issue_and_install_certificate` 核心证书申请/安装逻辑。
# - **重构**: 统一 `check_domain_ip` 中的确认逻辑到 `_confirm_action_or_exit_non_interactive`。
# - **重构**: 提取 `_display_projects_table` 改进项目列表显示。
# - **修复**: `check_and_auto_renew_certs` 中 `RENEWED_COUNT` 和 `FAILED_COUNT` 在子shell中不更新的问题。
# - **重构**: 封装 `_parse_target_input` 函数，用于解析后端目标输入。
# - **重构**: 封装 `_setup_http01_challenge_nginx` 和 `_cleanup_http01_challenge_nginx` 用于 HTTP-01 验证的 Nginx 操作。
# ==============================================================================

set -euo pipefail # 启用：遇到未定义的变量即退出，遇到非零退出码即退出，管道中任何命令失败即退出

# --- 全局变量和颜色定义 ---
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
RENEW_THRESHOLD_DAYS=30 # 证书在多少天内到期时触发自动续期 (建议未来从 config.json 加载)

# Nginx 路径变量
NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_WEBROOT_DIR="/var/www/html" # acme.sh webroot 验证目录
NGINX_CUSTOM_SNIPPETS_DIR="/etc/nginx/custom_snippets"
SSL_CERTS_BASE_DIR="/etc/ssl" # 证书的基目录，acme.sh 默认安装到这里

# --- 控制日志输出到终端的模式 ---
# 默认为交互模式，只有在特定情况下（如cron任务）才设置为非交互
IS_INTERACTIVE_MODE="true"
# 如果脚本带参数 --cron 或 --non-interactive 执行，则设为非交互模式
for arg in "$@"; do
    if [[ "$arg" == "--cron" || "$arg" == "--non-interactive" ]]; then
        IS_INTERACTIVE_MODE="false"
        break
    fi
done

# 全局 IP 变量，在此处初始化以确保它们在脚本中的任何位置都可用
VPS_IP=""
VPS_IPV6=""

# --- 日志重定向函数 (替代 tee) ---
log_message() {
    local level="$1" # INFO, WARN, ERROR, DEBUG
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local color_code=""
    local level_prefix=""

    case "$level" in
        INFO) color_code="${GREEN}"; level_prefix="[INFO]";;
        WARN) color_code="${YELLOW}"; level_prefix="[WARN]";;
        ERROR) color_code="${RED}"; level_prefix="[ERROR]";;
        DEBUG) color_code="${BLUE}"; level_prefix="[DEBUG]";;
        *) color_code="${RESET}"; level_prefix="[UNKNOWN]";;
    esac

    # 输出到终端（带颜色和级别前缀）
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        echo -e "${color_code}${level_prefix} ${message}${RESET}"
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
    log_message INFO "acme.sh 已就绪 ($ACME_BIN)。"
fi
# 确保 $HOME/.acme.sh 在 PATH 中，这对 acme.sh 内部操作很重要
export PATH="$HOME/.acme.sh:$PATH"

# -----------------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_message ERROR "❌ 请使用 root 用户运行此操作。"
        return 1 # 返回失败
    fi
    return 0 # 返回成功
}

# -----------------------------
# 获取 VPS 公网 IPv4 和 IPv6 地址
get_vps_ip() {
    # VPS_IP 现在是全局变量，移除了 local
    VPS_IP=$(curl -s https://api.ipify.org)
    log_message INFO "🌐 VPS 公网 IP (IPv4): $VPS_IP"

    # VPS_IPV6 也是全局变量
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
        return 1
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

    echo -n "${CYAN}[INFO] 正在检查依赖：${RESET}" # 开始输出进度点，不使用 log_message
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
                apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "❌ 安装/更新包 '$pkg' 失败。"; return 1; }
                log_message INFO "✅ 命令 '$cmd' 已安装/更新。" # 记录日志并终端输出(INFO级别)
            fi
        else
            echo -n "${BLUE}i${RESET}" # 缺少并安装，显示一个蓝色的'i'
            log_message WARN "缺少命令 '$cmd' (由包 '$pkg' 提供)，正在安装..." # 记录日志并终端输出(WARN级别)
            # 将安装过程的输出重定向到日志文件
            apt install -y "$pkg" >/dev/null 2>&1 || { log_message ERROR "❌ 安装包 '$pkg' 失败。"; return 1; }
            log_message INFO "✅ 命令 '$cmd' 已安装。" # 记录日志并终端输出(INFO级别)
        fi
    done
    echo -e "\n${GREEN}[INFO] 所有依赖检查完毕。${RESET}" # 完成依赖检查后新起一行
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    return 0
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
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
}

# -----------------------------
# 通用用户输入函数，带默认值和可选验证
# 参数: 1: 提示信息, 2: 默认值, 3: 验证正则表达式 (可选), 4: 验证失败消息 (可选), 5: 是否允许空输入 (true/false)
# 返回: 用户输入 (echoed), 或通过返回码 1 表示失败
_prompt_user_input_with_validation() {
    local prompt_message="$1"
    local default_value="$2"
    local validation_regex="$3"
    local validation_error_message="$4"
    local allow_empty_input="${5:-false}" # 默认为不允许空输入
    local input_value=""

    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            local display_default_value="${default_value}"
            if [[ -z "$default_value" && "$allow_empty_input" = "true" ]]; then
                display_default_value="空"
            elif [[ -z "$default_value" ]]; then
                display_default_value="无"
            fi
            echo -e "${CYAN}${prompt_message} [默认: ${display_default_value}]: ${RESET}"
            read -rp "> " input_value
            input_value=${input_value:-$default_value}
        else # 非交互模式
            if [[ -n "$default_value" ]]; then
                input_value="$default_value"
                log_message DEBUG "在非交互模式下，自动使用默认值: ${input_value}"
            elif [ "$allow_empty_input" = "true" ]; then
                input_value=""
                log_message DEBUG "在非交互模式下，允许空输入，使用空值。"
            else
                log_message ERROR "❌ 在非交互模式下，无法获取输入 '$prompt_message' 且无默认值。"
                return 1
            fi
        fi

        if [[ -z "$input_value" && "$allow_empty_input" = "true" ]]; then
            echo "" # 允许空输入，直接返回空字符串
            return 0
        elif [[ -z "$input_value" && "$allow_empty_input" = "false" ]]; then
            log_message ERROR "❌ 输入不能为空。请重新输入。"
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; else return 1; fi
        elif [[ -n "$validation_regex" && ! "$input_value" =~ $validation_regex ]]; then
            log_message ERROR "❌ ${validation_error_message:-输入格式不正确。请重新输入。}"
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; else return 1; fi
        else
            echo "$input_value"
            return 0
        fi
    done
}

# -----------------------------
# 安装 acme.sh
install_acme_sh() {
    # 再次检查 ACME_BIN 是否已是有效文件路径
    if [ ! -f "$ACME_BIN" ]; then
        log_message WARN "⚠️ acme.sh 未安装，正在安装..."

        local ACME_EMAIL=""
        ACME_EMAIL=$(_prompt_user_input_with_validation \
            "请输入用于注册 Let's Encrypt/ZeroSSL 的邮箱地址 (例如: your@example.com)，回车则不指定" \
            "" \
            "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" \
            "邮箱格式不正确" \
            "true") || { # 允许空输入，但如果输入了则验证格式
                log_message ERROR "❌ 邮箱输入失败。已取消 acme.sh 安装。"
                return 1
            }
        
        if [[ -n "$ACME_EMAIL" ]]; then
            log_message INFO "➡️ 正在使用邮箱 $ACME_EMAIL 安装 acme.sh..."
            curl https://get.acme.sh | sh -s email="$ACME_EMAIL" || { log_message ERROR "❌ acme.sh 安装失败！"; return 1; }
        else
            log_message WARN "ℹ️ 未指定邮箱地址安装 acme.sh。某些证书颁发机构（如 ZeroSSL）可能需要注册邮箱。您可以在之后使用 'acme.sh --register-account -m your@example.com' 手动注册。"
            local NO_EMAIL_CONFIRM="n" # Default to 'n' for non-interactive safety
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                echo -e "${CYAN}是否确认不指定邮箱安装 acme.sh？[y/N]: ${RESET}"
                read -rp "> " NO_EMAIL_CONFIRM
                NO_EMAIL_CONFIRM=${NO_EMAIL_CONFIRM:-n} # 默认改为 n
            fi
            
            if [[ "$NO_EMAIL_CONFIRM" =~ ^[Yy]$ ]]; then
                curl https://get.acme.sh | sh || { log_message ERROR "❌ acme.sh 安装失败！"; return 1; }
            else
                log_message ERROR "❌ 已取消 acme.sh 安装。"
                return 1
            fi
        fi
        # 安装成功后，重新确定 ACME_BIN 路径并更新 PATH
        local newly_installed_acme_bin=$(find_acme_sh_path)
        if [[ -z "$newly_installed_acme_bin" ]]; then
            log_message ERROR "❌ acme.sh 安装成功，但无法找到其执行路径。请手动检查 $HOME/.acme.sh 目录。"
            return 1
        else
            ACME_BIN="$newly_installed_acme_bin" # 更新全局 ACME_BIN
            export PATH="$(dirname "$ACME_BIN"):$PATH" # 重新加载 PATH，确保 acme.sh 命令可用
            log_message INFO "✅ acme.sh 安装成功，路径设置为 $ACME_BIN。"
        fi
    else
        log_message INFO "✅ acme.sh 已安装 ($ACME_BIN)。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    return 0
}

# -----------------------------
# 辅助函数：统一确认逻辑，非交互模式下直接返回失败
# 参数: 1: 提示信息
# 返回: 0 确认，1 拒绝
_confirm_action_or_exit_non_interactive() {
    local prompt_message="$1"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        echo -e "${CYAN}${prompt_message} [y/N]: ${RESET}"
        read -rp "> " CONFIRM_INPUT
        CONFIRM_INPUT=${CONFIRM_INPUT:-n}
        if [[ "$CONFIRM_INPUT" =~ ^[Yy]$ ]]; then
            return 0 # 确认
        else
            return 1 # 拒绝
        fi
    else
        log_message ERROR "❌ 在非交互模式下，需要用户确认才能继续 '$prompt_message'。操作已取消。"
        return 1 # 非交互模式下直接拒绝
    fi
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
        log_message ERROR "❌ 域名 ${domain} 无法解析到任何 IPv4 地址，请检查 DNS 配置。"
        return 1 # 硬性失败
    elif [ "$domain_ip_v4" != "$vps_ip_v4" ]; then
        log_message ERROR "⚠️ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 与本机 IPv4 ($vps_ip_v4) 不符。"
        if ! _confirm_action_or_exit_non_interactive "这可能导致证书申请失败。是否继续？"; then
            log_message ERROR "❌ 已取消当前域名的操作。"
            return 1 # 硬性失败
        fi
        log_message WARN "⚠️ 已选择继续申请 (IPv4 解析不匹配)。请务必确认此操作的风险。"
    else
        log_message INFO "✅ 域名 ${domain} 的 IPv4 解析 ($domain_ip_v4) 正确。"
    fi

    # 2. IPv6 解析检查 (如果 VPS 有 IPv6 地址)
    if [[ -n "$VPS_IPV6" ]]; then
        local domain_ip_v6=$(dig +short "$domain" AAAA | grep -E '^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$' | head -n1 2>/dev/null || echo "")
        if [ -z "$domain_ip_v6" ]; then
            log_message WARN "⚠️ 域名 ${domain} 未配置 AAAA 记录，但您的 VPS 具有 IPv6 地址。"
            if ! _confirm_action_or_exit_non_interactive "这表示该域名可能无法通过 IPv6 访问。是否继续？"; then
                log_message ERROR "❌ 已取消当前域名的操作。"
                return 1 # 硬性失败
            fi
            log_message WARN "⚠️ 已选择继续申请 (AAAA 记录缺失)。"
        elif [ "$domain_ip_v6" != "$VPS_IPV6" ]; then
            log_message ERROR "⚠️ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 与本机 IPv6 ($VPS_IPV6) 不符。"
            if ! _confirm_action_or_exit_non_interactive "这可能导致证书申请失败或域名无法通过 IPv6 访问。是否继续？"; then
                log_message ERROR "❌ 已取消当前域名的操作。"
                return 1 # 硬性失败
            fi
            log_message WARN "⚠️ 已选择继续申请 (IPv6 解析不匹配)。请务必确认此操作的风险。"
        else
            log_message INFO "✅ 域名 ${domain} 的 IPv6 解析 ($domain_ip_v6) 正确。"
        fi
    else
        log_message INFO "ℹ️ 您的 VPS 未检测到 IPv6 地址，因此未检查域名 ${domain} 的 AAAA 记录。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    return 0
}

# -----------------------------
# Helper function to generate Nginx listen directives (IPv4 and optionally IPv6)
generate_nginx_listen_directives() {
    local port="$1"
    local ssl_and_http2_flags="$2" # e.g., "ssl http2" or empty
    local directives="    listen $port$ssl_and_http2_flags;"
    if [[ -n "$VPS_IPV6" ]]; then # Use global VPS_IPV6 here
        directives+="\n    listen [::]:$port$ssl_and_http2_flags;"
    fi
    echo -e "$directives"
}

# -----------------------------
# Nginx 配置模板 (HTTP 挑战)
_NGINX_HTTP_CHALLENGE_TEMPLATE() {
    local DOMAIN="$1"
    local LISTEN_80_DIRECTIVES="$(generate_nginx_listen_directives 80 "")"

    cat <<EOF_HTTP
server {
${LISTEN_80_DIRECTIVES}
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${NGINX_WEBROOT_DIR}; # acme.sh webroot 验证目录的绝对路径
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
    local CUSTOM_SNIPPET_CONTENT="$5" # 新增参数：自定义片段内容，而不是路径

    local LISTEN_80_DIRECTIVES="$(generate_nginx_listen_directives 80 "")"
    local LISTEN_443_DIRECTIVES="$(generate_nginx_listen_directives 443 " ssl http2")"

    cat <<EOF_FINAL
server {
${LISTEN_80_DIRECTIVES}
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
${LISTEN_443_DIRECTIVES}
    server_name ${DOMAIN};

    ssl_certificate ${INSTALLED_CRT_FILE};
    ssl_certificate_key ${INSTALLED_KEY_FILE};

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
${CUSTOM_SNIPPET_CONTENT}
    location / {
        proxy_pass ${PROXY_TARGET_URL};
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
EOF_FINAL
}

# -----------------------------
# Analyze acme.sh error output and provide suggestions
analyze_acme_error() {
    local error_output="$1"
    log_message ERROR "--- acme.sh 错误分析 ---"
    if echo "$error_output" | grep -q "Invalid response from"; then
        log_message ERROR "   可能原因：域名解析错误，或 80 端口未开放/被占用，或防火墙阻止了验证请求。"
        log_message WARN "   建议：1. 检查域名 A/AAAA 记录是否指向本机 IP。2. 确保 80 端口已开放且未被其他服务占用。3. 检查服务器防火墙设置。"
    elif echo "$error_output" | grep -q "Domain not owned"; then
        log_message ERROR "   可能原因：acme.sh 无法证明您拥有该域名。"
        log_message WARN "   建议：1. 确保域名解析正确。2. 如果是 dns-01 验证，检查 DNS API 密钥和权限。3. 尝试强制更新 DNS 记录。"
    elif echo "$error_output" | grep -q "Timeout"; then
        log_message ERROR "   可能原因：验证服务器连接超时。"
        log_message WARN "   建议：检查服务器网络连接，防火墙，或 DNS 解析是否稳定。"
    elif echo "$error_output" | grep -q "Rate Limit"; then
        log_message ERROR "   可能原因：已达到 Let's Encrypt 或 ZeroSSL 的请求频率限制。"
        log_message WARN "   建议：请等待一段时间（通常为一周）再尝试，或添加更多域名到单个证书（如果适用）。"
        log_message WARN "   参考: https://letsencrypt.org/docs/rate-limits/ 或 ZeroSSL 文档。"
    elif echo "$error_output" | grep -q "DNS problem"; then
        log_message ERROR "   可能原因：DNS 验证失败。"
        log_message WARN "   建议：1. 检查 DNS 记录是否正确添加 (TXT 记录)。2. 检查 DNS API 密钥是否有效且有足够权限。3. 确保 DNS 记录已完全生效。"
    elif echo "$error_output" | grep -q "No account specified for this domain"; then
        log_message ERROR "   可能原因：未为该域名指定或注册 ACME 账户。"
        log_message WARN "   建议：运行 'acme.sh --register-account -m your@example.com --server [CA_SERVER_URL]' 注册账户。"
    elif echo "$error_output" | grep -q "Domain key exists"; then
        log_message ERROR "   可能原因：上次申请失败后残留了域名私钥文件。"
        log_message WARN "   建议：脚本已在初次申请或重试时添加 --force 参数处理此问题。如果仍然失败，请尝试在管理菜单中删除该项目后重试。"
    elif echo "$error_output" | grep -q "not a cert name" || echo "$error_output" | grep -q "Cannot find path"; then
        log_message ERROR "   可能原因：acme.sh 无法识别证书名称或路径，通常是由于传递的域名格式不正确导致。"
        log_message WARN "   建议：请检查 acme.sh 命令中 -d 参数的域名是否包含多余的引号或特殊字符，或者证书目录是否存在。"
    else
        log_message ERROR "   未识别的错误类型。"
        log_message WARN "   建议：请仔细检查上述 acme.sh 完整错误日志，并查阅 acme.sh 官方文档或社区寻求帮助。"
    fi
    log_message ERROR "--------------------------"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
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
        log_message INFO "✅ Nginx 服务已成功 ${action}。"
        return 0
    fi
}

# -----------------------------
# 检查 DNS API 环境变量的函数 (修复了非交互模式下的阻塞问题)
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
        log_message WARN "请在运行脚本前设置这些环境变量，例如 'export CF_Token=\"YOUR_TOKEN\"'。"

        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then # 仅在交互模式下提示
            echo -e "${CYAN}是否已设置这些变量并确认继续？[y/N]: ${RESET}"
            read -rp "> " CONFIRM_ENV
            CONFIRM_ENV=${CONFIRM_ENV:-n}
            if [[ ! "$CONFIRM_ENV" =~ ^[Yy]$ ]]; then
                return 1 # 用户选择不继续
            fi
        else # 在非交互模式下直接返回失败
            log_message ERROR "❌ 在非交互模式下，缺少 DNS 环境变量。操作已取消。"
            return 1 # 致命错误
        fi
    else
        log_message INFO "✅ 必要的 DNS API 环境变量已设置。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    return 0
}

# -----------------------------
# 检查并清理项目元数据文件 (如果损坏则备份重建)
check_projects_metadata_file() {
    log_message INFO "🔍 检查并清理项目元数据文件 $PROJECTS_METADATA_FILE..."

    if [ ! -f "$PROJECTS_METADATA_FILE" ]; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
        log_message INFO "✅ 项目元数据文件 $PROJECTS_METADATA_FILE 已创建为空数组。"
        return 0
    fi

    # 尝试读取文件内容并验证 JSON 格式
    if ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
        log_message ERROR "❌ 警告: $PROJECTS_METADATA_FILE 不是有效的 JSON 格式。将备份并重新创建。"
        mv "$PROJECTS_METADATA_FILE" "${PROJECTS_METADATA_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        echo "[]" > "$PROJECTS_METADATA_FILE"
        log_message INFO "✅ 项目元数据文件已备份，并重新创建为空数组。"
        return 0
    fi

    # 如果是有效JSON，但可能包含非对象元素，则过滤掉
    local cleaned_json=$(jq -c '[.[] | select(type == "object" and .domain != null and .domain != "")]' "$PROJECTS_METADATA_FILE")
    if [[ "$cleaned_json" != "$(cat "$PROJECTS_METADATA_FILE")" ]]; then
        log_message WARN "⚠️ 项目元数据文件 $PROJECTS_METADATA_FILE 包含无效或空项目，正在清理。"
        echo "$cleaned_json" > "$PROJECTS_METADATA_FILE"
        log_message INFO "✅ 项目元数据文件已清理。"
    else
        log_message INFO "✅ 项目元数据文件 $PROJECTS_METADATA_FILE 格式有效且内容正常。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    return 0
}

# -----------------------------
# 辅助函数：选择 Docker 容器内部端口
# 参数: 1: 容器名称, 2: 默认端口建议 (字符串，可以是数字或空), 3: 是否允许空输入 (true/false)
# 返回: 选中的端口号 (echoed), 或通过返回码 1 表示失败
_prompt_for_docker_internal_port() {
    local target_container="$1"
    local default_port_suggestion="$2"
    local allow_empty="$3" # "true" or "false"
    local selected_port=""

    local INTERNAL_EXPOSED_PORTS_ARRAY=()
    while IFS= read -r port_entry; do
        INTERNAL_EXPOSED_PORTS_ARRAY+=("$port_entry")
    done < <(docker inspect "$target_container" --format '{{ range $p, $conf := .Config.ExposedPorts }}{{ $p }}{{ end }}' 2>/dev/null | sed 's|/tcp||g' | xargs -n1 || echo "")

    if [ ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} -gt 0 ]; then
        log_message INFO "检测到容器 '$target_container' 内部暴露的端口有："
        local port_idx=0
        for p in "${INTERNAL_EXPOSED_PORTS_ARRAY[@]}"; do
            port_idx=$((port_idx + 1))
            echo -e "   ${YELLOW}${port_idx})${RESET} ${p}"
        done

        local prompt_msg="请选择一个内部端口序号，或直接输入端口号 (例如 1 或 8080)"
        local validation_regex="^[0-9]+$"
        local error_msg="输入无效。请重新选择或输入有效的端口号 (1-65535)。"
        local input_val=""

        input_val=$(_prompt_user_input_with_validation "$prompt_msg" "$default_port_suggestion" "$validation_regex" "$error_msg" "$allow_empty") || return 1

        if [[ -z "$input_val" ]]; then
            echo ""
            return 0
        fi

        if (( input_val > 0 && input_val <= ${#INTERNAL_EXPOSED_PORTS_ARRAY[@]} )); then
            selected_port="${INTERNAL_EXPOSED_PORTS_ARRAY[input_val-1]}"
            log_message INFO "✅ 已选择容器内部端口: $selected_port。"
        elif (( input_val > 0 && input_val < 65536 )); then
            selected_port="$input_val"
            log_message INFO "✅ 已手动指定容器内部端口: $selected_port。"
        else
            log_message ERROR "$error_msg"
            return 1
        fi
    else
        log_message WARN "未检测到容器 '$target_container' 内部暴露的端口。"
        local prompt_msg="请输入要代理到的容器内部端口 (例如 8080)"
        local validation_regex="^[0-9]+$"
        local error_msg="输入的端口无效。请重新输入一个有效的端口号 (1-65535)。"
        
        selected_port=$(_prompt_user_input_with_validation "$prompt_msg" "$default_port_suggestion" "$validation_regex" "$error_msg" "$allow_empty") || return 1
        
        if [[ -n "$selected_port" ]]; then
            log_message INFO "✅ 将代理到容器 '$target_container' 的内部端口: $selected_port。请确保容器监听 0.0.0.0。"
        else
            log_message INFO "已选择空端口。"
        fi
    fi
    echo "$selected_port"
    return 0
}

# -----------------------------
# 辅助函数：提示用户输入自定义 Nginx 片段路径
# 参数: 1: 域名, 2: 项目类型, 3: 项目详情 (容器名/端口), 4: 当前片段路径 (用于默认值), 5: 是否允许空输入 (true/false)
# 返回: 选中的路径 (echoed), 或通过返回码 1 表示失败
_prompt_for_custom_snippet_path() {
    local domain="$1"
    local project_type="$2"
    local project_detail="$3"
    local current_snippet_path="$4"
    local allow_empty="$5" # "true" or "false"
    local chosen_snippet_path=""

    local DEFAULT_SNIPPET_FILENAME=""
    if [ "$project_type" = "docker" ]; then
        DEFAULT_SNIPPET_FILENAME="$project_detail.conf"
    else
        DEFAULT_SNIPPET_FILENAME="$domain.conf"
    fi
    local DEFAULT_SNIPPET_PATH="$NGINX_CUSTOM_SNIPPETS_DIR/$DEFAULT_SNIPPET_FILENAME"

    local ADD_CUSTOM_SNIPPET_CHOICE="n"
    if [[ -n "$current_snippet_path" && "$current_snippet_path" != "null" ]]; then
        # 如果已经有片段路径，默认是保留 (y)，用户可以选择不修改 (n)
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            ADD_CUSTOM_SNIPPET_CHOICE=$(_prompt_user_input_with_validation \
                "域名 $domain 已有自定义 Nginx 配置片段文件: $current_snippet_path。是否修改或清除？" \
                "y" "^[yYnN]$" "无效输入" "false") || return 1
            if [[ "$ADD_CUSTOM_SNIPPET_CHOICE" =~ ^[Yy]$ ]]; then
                ADD_CUSTOM_SNIPPET_CHOICE="y"
            else
                ADD_CUSTOM_SNIPPET_CHOICE="n" # 用户选择不修改/不清除，即保留
            fi
        else # 非交互模式下，默认保留现有路径
            ADD_CUSTOM_SNIPPET_CHOICE="y"
        fi
    else
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            ADD_CUSTOM_SNIPPET_CHOICE=$(_prompt_user_input_with_validation \
                "是否为域名 $domain 添加自定义 Nginx 配置片段文件？" \
                "n" "^[yYnN]$" "无效输入" "false") || return 1
            if [[ "$ADD_CUSTOM_SNIPPET_CHOICE" =~ ^[Yy]$ ]]; then
                ADD_CUSTOM_SNIPPET_CHOICE="y"
            fi
        fi
    fi

    if [[ "$ADD_CUSTOM_SNIPPET_CHOICE" =~ ^[Yy]$ ]]; then
        local prompt_msg="请输入自定义 Nginx 配置片段文件的完整路径"
        local input_val=""
        input_val=$(_prompt_user_input_with_validation "$prompt_msg" "$DEFAULT_SNIPPET_PATH" "" "" "$allow_empty") || return 1

        local CHOSEN_SNIPPET_PATH_TEMP="$input_val"

        if [[ -z "$CHOSEN_SNIPPET_PATH_TEMP" ]]; then
            if [ "$allow_empty" = "true" ]; then
                chosen_snippet_path=""
                log_message INFO "已选择空片段路径。"
            else
                log_message ERROR "❌ 文件路径不能为空。"
                return 1
            fi
        elif ! mkdir -p "$(dirname "$CHOSEN_SNIPPET_PATH_TEMP")"; then
            log_message ERROR "❌ 无法创建目录 $(dirname "$CHOSEN_SNIPPET_PATH_TEMP")。请检查权限或路径是否有效。"
            return 1
        else
            chosen_snippet_path="$CHOSEN_SNIPPET_PATH_TEMP"
            log_message INFO "✅ 将使用自定义 Nginx 配置片段文件: $chosen_snippet_path"
            log_message WARN "ℹ️ 请确保文件 '$chosen_snippet_path' 包含有效的 Nginx 配置片段。"
        fi
    else
        # 用户选择不添加或不修改，清除原有设置 (如果存在)
        if [[ -n "$current_snippet_path" && "$current_snippet_path" != "null" ]]; then
            log_message INFO "已选择不添加自定义 Nginx 片段，将清除原有设置。"
        else
            log_message INFO "未设置自定义 Nginx 片段。"
        fi
        chosen_snippet_path=""
    fi
    echo "$chosen_snippet_path"
    return 0
}

# -----------------------------
# 辅助函数：构建项目 JSON 对象
_build_project_json_object() {
    local domain="$1"
    local type="$2"
    local name="$3"
    local resolved_port="$4"
    local custom_snippet="$5"
    local acme_method="$6"
    local dns_provider="$7"
    local wildcard="$8"
    local ca_url="$9"
    local ca_name="${10}"
    local cert_file="${11}"
    local key_file="${12}"

    jq -n \
        --arg domain "$domain" \
        --arg type "$type" \
        --arg name "$name" \
        --arg resolved_port "$resolved_port" \
        --arg custom_snippet "$custom_snippet" \
        --arg acme_method "$acme_method" \
        --arg dns_provider "$dns_provider" \
        --arg wildcard "$wildcard" \
        --arg ca_url "$ca_url" \
        --arg ca_name "$ca_name" \
        --arg cert_file "$cert_file" \
        --arg key_file "$key_file" \
        '{domain: $domain, type: $type, name: $name, resolved_port: $resolved_port, custom_snippet: $custom_snippet, acme_validation_method: $acme_method, dns_api_provider: $dns_provider, use_wildcard: $wildcard, ca_server_url: $ca_url, ca_server_name: $ca_name, cert_file: $cert_file, key_file: $key_file}'
}

# -----------------------------
# 辅助函数：选择 ACME CA 服务器
# 返回: ACME_CA_SERVER_URL 和 ACME_CA_SERVER_NAME (通过 echo)
_select_acme_ca_server() {
    local prompt_message="$1"
    local default_ca_url="${2:-https://acme-v02.api.letsencrypt.org/directory}"
    local default_ca_name="${3:-letsencrypt}"

    log_message INFO "${prompt_message}"
    echo "${GREEN}1) Let's Encrypt (默认)${RESET}"
    echo "${GREEN}2) ZeroSSL${RESET}"
    echo "${GREEN}3) 自定义 ACME 服务器 URL${RESET}"
    
    local CA_CHOICE=""
    CA_CHOICE=$(_prompt_user_input_with_validation "请输入序号" "1" "^[1-3]$" "无效选择" "false") || return 1
    
    local ACME_CA_SERVER_URL_OUT="$default_ca_url"
    local ACME_CA_SERVER_NAME_OUT="$default_ca_name"

    case "$CA_CHOICE" in
        1) ACME_CA_SERVER_URL_OUT="https://acme-v02.api.letsencrypt.org/directory"; ACME_CA_SERVER_NAME_OUT="letsencrypt";;
        2) ACME_CA_SERVER_URL_OUT="https://acme.zerossl.com/v2/DV90"; ACME_CA_SERVER_NAME_OUT="zerossl";;
        3)
            local CUSTOM_ACME_URL=""
            CUSTOM_ACME_URL=$(_prompt_user_input_with_validation "请输入自定义 ACME 服务器 URL" "$default_ca_url" "" "URL格式不正确" "false") || return 1
            if [[ -n "$CUSTOM_ACME_URL" ]]; then
                ACME_CA_SERVER_URL_OUT="$CUSTOM_ACME_URL"
                ACME_CA_SERVER_NAME_OUT="Custom"
                log_message INFO "⚠️ 正在使用自定义 ACME 服务器 URL。请确保其有效。"
            else
                log_message WARN "未输入自定义 URL，将使用默认 Let's Encrypt。"
            fi
            ;;
        *) log_message WARN "⚠️ 无效选择，将使用默认 Let's Encrypt。";;
    esac
    log_message INFO "➡️ 选定 CA: $ACME_CA_SERVER_NAME_OUT"
    echo "$ACME_CA_SERVER_URL_OUT"
    echo "$ACME_CA_SERVER_NAME_OUT"
    return 0
}

# -----------------------------
# 辅助函数：确保 ZeroSSL 账户已注册
# 参数: 1: ACME_CA_SERVER_URL
_ensure_zerossl_account() {
    local ACME_CA_SERVER_URL="$1"
    log_message INFO "🔍 检查 ZeroSSL 账户注册状态..."
    if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
        log_message WARN "⚠️ 未检测到 ZeroSSL 账户已注册。"
        local ZERO_SSL_ACCOUNT_EMAIL=""
        ZERO_SSL_ACCOUNT_EMAIL=$(_prompt_user_input_with_validation \
            "请输入用于注册 ZeroSSL 的邮箱地址" \
            "" \
            "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" \
            "邮箱格式不正确" \
            "false") || {
                log_message ERROR "❌ 邮箱输入失败或格式不正确。无法注册 ZeroSSL 账户。"
                return 1
            }
        
        log_message INFO "➡️ 正在注册 ZeroSSL 账户: $ZERO_SSL_ACCOUNT_EMAIL..."
        local register_cmd=("$ACME_BIN" --register-account -m "$ZERO_SSL_ACCOUNT_EMAIL" --server "$ACME_CA_SERVER_URL")
        "${register_cmd[@]}" || {
            log_message ERROR "❌ ZeroSSL 账户注册失败！请检查邮箱地址或稍后重试。"
            return 1
        }
        log_message INFO "✅ ZeroSSL 账户注册成功。"
    else
        log_message INFO "✅ ZeroSSL 账户已注册。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    return 0
}

# -----------------------------
# 辅助函数：设置 HTTP-01 验证的 Nginx 临时配置
# 参数: 1: 域名, 2: Nginx 配置文件路径
# 返回: 0 成功, 1 失败
_setup_http01_challenge_nginx() {
    local DOMAIN="$1"
    local NGINX_CONF_PATH="$2"

    log_message WARN "生成 Nginx 临时 HTTP 配置以进行证书验证..."
    _NGINX_HTTP_CHALLENGE_TEMPLATE "$DOMAIN" > "$NGINX_CONF_PATH"
    if [ ! -L "$NGINX_SITES_ENABLED_DIR/$DOMAIN.conf" ]; then
        ln -sf "$NGINX_CONF_PATH" "$NGINX_SITES_ENABLED_DIR/"
    fi
    if ! control_nginx restart; then
        log_message ERROR "❌ Nginx 重启失败，HTTP-01 验证将无法进行。"
        return 1
    fi
    return 0
}

# -----------------------------
# 辅助函数：清理 HTTP-01 验证的 Nginx 临时配置
# 参数: 1: 域名, 2: Nginx 配置文件路径
# 返回: 0 成功, 1 失败 (Nginx 重载失败)
_cleanup_http01_challenge_nginx() {
    local DOMAIN="$1"
    local NGINX_CONF_PATH="$2"

    log_message INFO "清理 HTTP-01 验证的 Nginx 临时配置..."
    rm -f "$NGINX_CONF_PATH"
    rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN.conf"
    if ! control_nginx reload; then
        log_message WARN "Nginx 重载失败，请手动检查。这可能不影响服务，但建议检查。"
        return 1
    fi
    return 0
}

# -----------------------------
# 辅助函数：执行证书申请和安装流程
# 参数: 1: 域名, 2: ACME验证方法, 3: DNS提供商, 4: 是否泛域名, 5: CA URL, 6: 证书文件, 7: 私钥文件, 8: Nginx 配置文件路径
# 返回: 0 成功, 1 失败
_issue_and_install_certificate() {
    local DOMAIN="$1"
    local ACME_VALIDATION_METHOD="$2"
    local DNS_API_PROVIDER="$3"
    local USE_WILDCARD="$4"
    local ACME_CA_SERVER_URL="$5"
    local INSTALLED_CRT_FILE="$6"
    local INSTALLED_KEY_FILE="$7"
    local NGINX_CONF_PATH="$8" # Nginx 配置文件路径

    log_message WARN "正在为 $DOMAIN 申请证书 (验证方式: $ACME_VALIDATION_METHOD)..."
    local ACME_ISSUE_CMD_LOG_OUTPUT=$(mktemp acme_cmd_log.XXXXXX)

    local issue_command_array=("$ACME_BIN" --issue --force -d "$DOMAIN" --ecc --server "$ACME_CA_SERVER_URL")
    if [ "$USE_WILDCARD" = "y" ]; then
        issue_command_array+=("-d" "*.$DOMAIN")
    fi

    if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
        issue_command_array+=("-w" "$NGINX_WEBROOT_DIR")
        if ! _setup_http01_challenge_nginx "$DOMAIN" "$NGINX_CONF_PATH"; then
            rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"
            return 1
        fi
    elif [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
        issue_command_array+=("--dns" "$DNS_API_PROVIDER")
        if ! check_dns_env "$DNS_API_PROVIDER"; then
            log_message ERROR "DNS 环境变量检查失败，跳过域名 $DOMAIN 的证书申请。"
            rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"
            return 1
        fi
    fi

    if ! "${issue_command_array[@]}" > "$ACME_ISSUE_CMD_LOG_OUTPUT" 2>&1; then
        log_message ERROR "❌ 域名 $DOMAIN 的证书申请失败！"
        cat "$ACME_ISSUE_CMD_LOG_OUTPUT" >&2 # 直接打印原始错误
        analyze_acme_error "$(cat "$ACME_ISSUE_CMD_LOG_OUTPUT")"
        rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"
        
        # 清理临时 Nginx 配置
        if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
            _cleanup_http01_challenge_nginx "$DOMAIN" "$NGINX_CONF_PATH" || true
        fi
        return 1
    fi
    rm -f "$ACME_ISSUE_CMD_LOG_OUTPUT"

    log_message INFO "✅ 证书已成功签发，正在安装并更新 Nginx 配置..."

    local install_cert_domains_array=("-d" "$DOMAIN")
    if [ "$USE_WILDCARD" = "y" ]; then
        install_cert_domains_array+=("-d" "*.$DOMAIN")
    fi

    local install_command_array=("$ACME_BIN" "--install-cert" "${install_cert_domains_array[@]}" "--ecc" \
        "--key-file" "$INSTALLED_KEY_FILE" \
        "--fullchain-file" "$INSTALLED_CRT_FILE" \
        "--reloadcmd" "systemctl reload nginx")

    if ! "${install_command_array[@]}"; then
        log_message ERROR "❌ acme.sh 证书安装或Nginx重载失败。"
        return 1
    fi

    # 清理临时 Nginx 配置 (如果 http-01 成功)
    if [ "$ACME_VALIDATION_METHOD" = "http-01" ]; then
        _cleanup_http01_challenge_nginx "$DOMAIN" "$NGINX_CONF_PATH" || true
    fi

    return 0
}

# -----------------------------
# 辅助函数：解析后端目标输入
# 参数: 1: 原始目标字符串, 2: 默认端口建议 (字符串，可以是数字或空), 3: 是否允许空输入 (true/false)
# 输出: PROJECT_TYPE, PROJECT_DETAIL, PORT_TO_USE, PROXY_TARGET_URL (通过 echo)
# 返回: 0 成功, 1 失败
_parse_target_input() {
    local raw_target_input="$1"
    local default_port_suggestion="$2"
    local allow_empty_input="$3"

    local PROJECT_TYPE=""
    local PROJECT_DETAIL=""
    local PORT_TO_USE=""
    local PROXY_TARGET_URL=""

    if [ "$DOCKER_INSTALLED" = true ] && docker ps --format '{{.Names}}' | grep -wq "$raw_target_input"; then
        log_message INFO "🔍 识别到 Docker 容器: $raw_target_input"
        PROJECT_TYPE="docker"
        PROJECT_DETAIL="$raw_target_input"

        local HOST_MAPPED_PORT=$(docker inspect "$raw_target_input" --format \
            '{{ with (index .NetworkSettings.Ports) }}{{ range $p, $conf := . }}{{ (index $conf 0).HostPort }}{{ end }}{{ end }}' 2>/dev/null | \
            head -n1 || echo "")

        if [[ -n "$HOST_MAPPED_PORT" ]]; then
            log_message INFO "✅ 检测到容器 $raw_target_input 已映射到宿主机端口: $HOST_MAPPED_PORT。将自动使用此端口。"
            PORT_TO_USE="$HOST_MAPPED_PORT"
        else
            log_message WARN "⚠️ 未检测到容器 $raw_target_input 映射到宿主机的端口。"
            PORT_TO_USE=$(_prompt_for_docker_internal_port "$raw_target_input" "$default_port_suggestion" "$allow_empty_input")
            if [ $? -ne 0 ]; then return 1; fi
        fi
        PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
    elif [[ "$raw_target_input" =~ ^[0-9]+$ ]]; then
        log_message INFO "🔍 识别到本地端口: $raw_target_input"
        PROJECT_TYPE="local_port"
        PROJECT_DETAIL="$raw_target_input"
        PORT_TO_USE="$raw_target_input"
        PROXY_TARGET_URL="http://127.0.0.1:$PORT_TO_USE"
    elif [[ -z "$raw_target_input" && "$allow_empty_input" = "true" ]]; then
        PROJECT_TYPE=""
        PROJECT_DETAIL=""
        PORT_TO_USE=""
        PROXY_TARGET_URL=""
        log_message INFO "后端目标为空。"
    else
        log_message ERROR "❌ 无效的目标格式 '$raw_target_input' (既不是Docker容器名也不是端口号)。"
        return 1
    fi

    echo "$PROJECT_TYPE"
    echo "$PROJECT_DETAIL"
    echo "$PORT_TO_USE"
    echo "$PROXY_TARGET_URL"
    return 0
}


# -----------------------------
# 配置 Nginx 和申请 HTTPS 证书的主函数
configure_nginx_projects() {
    if ! check_root; then return 10; fi # 非root则返回主菜单

    if ! _confirm_action_or_exit_non_interactive "脚本将自动安装依赖并配置 Nginx，是否继续？"; then
        log_message RED "❌ 已取消配置。"
        return 10 # 返回到主菜单
    fi

    if ! install_dependencies; then return 1; fi
    detect_docker
    if ! install_acme_sh; then return 1; fi # 确保 acme.sh 已安装并 ACME_BIN 正确设置

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

    check_projects_metadata_file # 确保元数据文件是健康的

    log_message INFO "请输入项目列表（格式：主域名:docker容器名 或 主域名:本地端口），输入空行结束："
    PROJECTS=()
    while true; do
        local line=""
        line=$(_prompt_user_input_with_validation "" "" "" "" "true") || { log_message ERROR "输入错误，操作取消。"; return 1; }
        [[ -z "$line" ]] && break
        PROJECTS+=("$line")
    done

    if [ ${#PROJECTS[@]} -eq 0 ]; then
        log_message WARN "⚠️ 您没有输入任何项目，操作已取消。"
        return 10
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local ACME_CA_SERVER_URL=""
    local ACME_CA_SERVER_NAME=""
    local CA_SELECTION_OUTPUT
    CA_SELECTION_OUTPUT=$(_select_acme_ca_server "请选择证书颁发机构 (CA):" "https://acme-v02.api.letsencrypt.org/directory" "letsencrypt") || return 1
    ACME_CA_SERVER_URL=$(echo "$CA_SELECTION_OUTPUT" | head -n1)
    ACME_CA_SERVER_NAME=$(echo "$CA_SELECTION_OUTPUT" | tail -n1)

    # ZeroSSL 账户注册检查
    if [ "$ACME_CA_SERVER_NAME" = "zerossl" ]; then
        if ! _ensure_zerossl_account "$ACME_CA_SERVER_URL"; then return 1; fi
    fi

    log_message INFO "🔧 正在为每个项目生成 Nginx 配置并申请证书..."
    for P in "${PROJECTS[@]}"; do
        local MAIN_DOMAIN="${P%%:*}"
        local TARGET_INPUT="${P##*:}"
        local DOMAIN_CONF="$NGINX_SITES_AVAILABLE_DIR/$MAIN_DOMAIN.conf"

        log_message INFO "\n--- 处理域名: $MAIN_DOMAIN ---"

        if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
            log_message WARN "⚠️ 域名 $MAIN_DOMAIN 已存在配置。"
            if ! _confirm_action_or_exit_non_interactive "是否要覆盖现有配置并重新申请/安装证书？"; then
                log_message ERROR "❌ 已选择不覆盖，跳过域名 $MAIN_DOMAIN。"
                continue
            else
                log_message WARN "ℹ️ 确认覆盖。正在删除旧配置以便重新创建..."
                rm -f "$NGINX_SITES_AVAILABLE_DIR/$MAIN_DOMAIN.conf"
                rm -f "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf"
                if jq "del(.[] | select(.domain == \"$MAIN_DOMAIN\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    log_message INFO "✅ 旧配置及元数据已移除。"
                else
                    log_message ERROR "❌ 移除旧元数据失败，请检查 $PROJECTS_METADATA_FILE 文件权限。跳过 $MAIN_DOMAIN。"
                    continue
                fi
            fi
        fi

        if ! check_domain_ip "$MAIN_DOMAIN" "$VPS_IP"; then
            log_message ERROR "❌ 跳过域名 $MAIN_DOMAIN 的配置和证书申请。"
            continue
        fi

        local ACME_VALIDATION_METHOD="http-01"
        local DNS_API_PROVIDER=""
        local USE_WILDCARD="n"

        log_message INFO "请选择验证方式:"
        echo "${GREEN}1) http-01 (通过 80 端口，推荐用于单域名) [默认: 1]${RESET}"
        echo "${GREEN}2) dns-01 (通过 DNS API，推荐用于泛域名或 80 端口不可用时)${RESET}"
        
        local VALIDATION_CHOICE=""
        VALIDATION_CHOICE=$(_prompt_user_input_with_validation "请输入序号" "1" "^[1-2]$" "无效选择" "false") || continue

        case "$VALIDATION_CHOICE" in
            1) ACME_VALIDATION_METHOD="http-01";;
            2)
                ACME_VALIDATION_METHOD="dns-01"
                local WILDCARD_INPUT=""
                WILDCARD_INPUT=$(_prompt_user_input_with_validation "是否申请泛域名证书 (*.$MAIN_DOMAIN)？" "n" "^[yYnN]$" "无效输入" "false") || continue
                if [[ "$WILDCARD_INPUT" =~ ^[Yy]$ ]]; then
                    USE_WILDCARD="y"
                    log_message WARN "⚠️ 泛域名证书必须使用 dns-01 验证方式。"
                fi

                log_message INFO "请选择您的 DNS 服务商 (用于 dns-01 验证):"
                echo "${GREEN}1) Cloudflare (dns_cf)${RESET}"
                echo "${GREEN}2) Aliyun DNS (dns_ali)${RESET}"
                
                local DNS_PROVIDER_CHOICE=""
                DNS_PROVIDER_CHOICE=$(_prompt_user_input_with_validation "请输入序号" "1" "^[1-2]$" "无效选择" "false") || continue

                case "$DNS_PROVIDER_CHOICE" in
                    1) DNS_API_PROVIDER="dns_cf";;
                    2) DNS_API_PROVIDER="dns_ali";;
                    *)
                        log_message ERROR "❌ 无效的 DNS 服务商选择，将尝试使用 dns_cf。"
                        DNS_API_PROVIDER="dns_cf"
                        ;;
                esac
                ;;
            *) log_message WARN "⚠️ 无效选择，将使用默认 http-01 验证方式。";;
        esac
        log_message INFO "➡️ 选定验证方式: $ACME_VALIDATION_METHOD"
        if [ "$ACME_VALIDATION_METHOD" = "dns-01" ]; then
            log_message INFO "➡️ 选定 DNS API 服务商: $DNS_API_PROVIDER"
            if [ "$USE_WILDCARD" = "y" ]; then
                log_message INFO "➡️ 申请泛域名证书: *.$MAIN_DOMAIN"
            fi
        fi
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

        local PROJECT_TYPE=""
        local PROJECT_DETAIL=""
        local PORT_TO_USE=""
        local PROXY_TARGET_URL=""
        local PARSED_TARGET_OUTPUT
        
        PARSED_TARGET_OUTPUT=$(_parse_target_input "$TARGET_INPUT" "8080" "false") || { log_message ERROR "❌ 解析后端目标失败，跳过域名 $MAIN_DOMAIN。"; continue; }
        PROJECT_TYPE=$(echo "$PARSED_TARGET_OUTPUT" | head -n1)
        PROJECT_DETAIL=$(echo "$PARSED_TARGET_OUTPUT" | sed -n '2p')
        PORT_TO_USE=$(echo "$PARSED_TARGET_OUTPUT" | sed -n '3p')
        PROXY_TARGET_URL=$(echo "$PARSED_TARGET_OUTPUT" | tail -n1)

        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

        mkdir -p "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN"

        local CUSTOM_NGINX_SNIPPET_PATH=""
        local CUSTOM_SNIPPET_CONTENT=""
        
        CUSTOM_NGINX_SNIPPET_PATH=$(_prompt_for_custom_snippet_path "$MAIN_DOMAIN" "$PROJECT_TYPE" "$PROJECT_DETAIL" "" "true")
        if [ $? -ne 0 ]; then
            log_message ERROR "❌ 自定义 Nginx 片段路径配置失败，跳过域名 $MAIN_DOMAIN。"
            continue
        fi
        if [[ -n "$CUSTOM_NGINX_SNIPPET_PATH" ]]; then
            CUSTOM_SNIPPET_CONTENT="\n    # BEGIN Custom Nginx Snippet for $MAIN_DOMAIN\n    include $CUSTOM_NGINX_SNIPPET_PATH;\n    # END Custom Nginx Snippet for $MAIN_DOMAIN"
        fi
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

        local INSTALLED_CRT_FILE="$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN.cer"
        local INSTALLED_KEY_FILE="$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN.key"
        local SHOULD_ISSUE_CERT="y"

        if [[ -f "$INSTALLED_CRT_FILE" && -f "$INSTALLED_KEY_FILE" ]]; then
            local EXISTING_END_DATE=$(openssl x509 -enddate -noout -in "$INSTALLED_CRT_FILE" 2>/dev/null | cut -d= -f2 || echo "未知日期")
            local END_TS_TEMP=0
            if command -v date >/dev/null 2>&1; then # Check if date command is available
                # Try GNU date -d first
                END_TS_TEMP=$(date -d "$EXISTING_END_DATE" +%s 2>/dev/null || echo 0)
                if [ "$END_TS_TEMP" -eq 0 ]; then # If GNU date -d failed, try BSD date -j
                    END_TS_TEMP=$(date -j -f "%b %d %T %Y %Z" "$EXISTING_END_DATE" "+%s" 2>/dev/null || echo 0)
                fi
            fi
            local NOW_TS=$(date +%s)
            local EXISTING_LEFT_DAYS=$(( (END_TS_TEMP - NOW_TS) / 86400 ))

            log_message WARN "⚠️ 域名 $MAIN_DOMAIN 已存在有效期至 ${EXISTING_END_DATE} 的证书 ($EXISTING_LEFT_DAYS 天剩余)。"
            log_message INFO "您想："
            echo "${GREEN}1) 重新申请/续期证书 (推荐更新过期或即将过期的证书) [默认]${RESET}"
            echo "${GREEN}2) 使用现有证书 (跳过证书申请步骤)${RESET}"
            
            local CERT_ACTION_CHOICE=""
            CERT_ACTION_CHOICE=$(_prompt_user_input_with_validation "请输入选项" "1" "^[1-2]$" "无效选择" "false") || continue

            if [ "$CERT_ACTION_CHOICE" == "2" ]; then
                SHOULD_ISSUE_CERT="n"
                log_message INFO "✅ 已选择使用现有证书。"
            else
                log_message WARN "ℹ️ 将重新申请/续期证书。"
            fi
        fi
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

        local NEW_PROJECT_JSON_TMP=$(_build_project_json_object \
            "$MAIN_DOMAIN" "$PROJECT_TYPE" "$PROJECT_DETAIL" "$PORT_TO_USE" "$CUSTOM_NGINX_SNIPPET_PATH" \
            "$ACME_VALIDATION_METHOD" "$DNS_API_PROVIDER" "$USE_WILDCARD" "$ACME_CA_SERVER_URL" \
            "$ACME_CA_SERVER_NAME" "$INSTALLED_CRT_FILE" "$INSTALLED_KEY_FILE")

        if ! jq ". + [$NEW_PROJECT_JSON_TMP]" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message ERROR "❌ 写入项目元数据失败！请检查 $PROJECTS_METADATA_FILE 文件权限或 JSON 格式。跳过域名 $MAIN_DOMAIN。"
            continue
        fi
        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
        log_message INFO "✅ 项目元数据已保存到 $PROJECTS_METADATA_FILE。"
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

        if [ "$SHOULD_ISSUE_CERT" = "y" ]; then
            if ! _issue_and_install_certificate \
                "$MAIN_DOMAIN" "$ACME_VALIDATION_METHOD" "$DNS_API_PROVIDER" "$USE_WILDCARD" \
                "$ACME_CA_SERVER_URL" "$INSTALLED_CRT_FILE" "$INSTALLED_KEY_FILE" "$DOMAIN_CONF"; then
                
                log_message ERROR "❌ 域名 $MAIN_DOMAIN 的证书申请/安装失败。清理相关文件..."
                rm -f "$DOMAIN_CONF"
                rm -f "$NGINX_SITES_ENABLED_DIR/$MAIN_DOMAIN.conf"
                if [ -d "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN" ]; then rm -rf "$SSL_CERTS_BASE_DIR/$MAIN_DOMAIN"; fi
                if [[ -n "$CUSTOM_NGINX_SNIPPET_PATH" && "$CUSTOM_NGINX_SNIPPET_PATH" != "null" && -f "$CUSTOM_NGINX_SNIPPET_PATH" ]]; then
                    log_message WARN "⚠️ 证书申请失败，删除自定义 Nginx 片段文件: $CUSTOM_NGINX_SNIPPET_PATH"
                    rm -f "$CUSTOM_NGINX_SNIPPET_PATH"
                fi
                if jq -e ".[] | select(.domain == \"$MAIN_DOMAIN\")" "$PROJECTS_METADATA_FILE" > /dev/null; then
                    log_message WARN "⚠️ 从元数据中移除失败的项目 $MAIN_DOMAIN。"
                    jq "del(.[] | select(.domain == \"$MAIN_DOMAIN\"))" "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp" && \
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                fi
                continue
            fi
        else
            log_message WARN "ℹ️ 未进行证书申请或续期，将使用现有证书。"
        fi
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

        log_message WARN "生成 $MAIN_DOMAIN 的最终 Nginx 配置..."
        _NGINX_FINAL_TEMPLATE "$MAIN_DOMAIN" "$PROXY_TARGET_URL" "$INSTALLED_CRT_FILE" "$INSTALLED_KEY_FILE" "$CUSTOM_SNIPPET_CONTENT" > "$DOMAIN_CONF"

        log_message INFO "✅ 域名 $MAIN_DOMAIN 的 Nginx 配置已更新。"
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
    done

    log_message INFO "✅ 所有项目处理完毕，执行最终 Nginx 配置检查和重载..."
    if ! control_nginx reload; then
        log_message ERROR "❌ 最终 Nginx 配置未能成功重载。请手动检查并处理。"
        return 1
    fi

    log_message INFO "🚀 所有域名配置完成！现在可以通过 HTTPS 访问您的服务。"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
    return 0
}

# -----------------------------
# 导入现有 Nginx 配置到本脚本管理
import_existing_project() {
    if ! check_root; then return 1; fi
    log_message INFO "--- 📥 导入现有 Nginx 配置到本脚本管理 ---"

    local IMPORT_DOMAIN=""
    IMPORT_DOMAIN=$(_prompt_user_input_with_validation "请输入要导入的主域名 (例如 example.com)" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" "域名格式不正确" "false") || { log_message ERROR "❌ 域名输入失败或格式不正确。"; return 1; }

    local EXISTING_NGINX_CONF_PATH="$NGINX_SITES_AVAILABLE_DIR/$IMPORT_DOMAIN.conf"
    if [ ! -f "$EXISTING_NGINX_CONF_PATH" ]; then
        log_message ERROR "❌ 域名 $IMPORT_DOMAIN 的 Nginx 配置文件 $EXISTING_NGINX_CONF_PATH 不存在。请确认路径和文件名。"
        return 1
    fi
    log_message INFO "✅ 找到域名 $IMPORT_DOMAIN 的 Nginx 配置文件: $EXISTING_NGINX_CONF_PATH"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local EXISTING_JSON_ENTRY=$(jq -c ".[] | select(.domain == \"$IMPORT_DOMAIN\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "") # 定义 EXISTING_JSON_ENTRY

    if [[ -n "$EXISTING_JSON_ENTRY" ]]; then # 使用定义的变量
        log_message WARN "⚠️ 域名 $IMPORT_DOMAIN 已存在于本脚本的管理列表中。"
        if ! _confirm_action_or_exit_non_interactive "是否要覆盖现有项目元数据？"; then
            log_message ERROR "❌ 已取消导入操作。"
            return 1
        fi
        log_message WARN "ℹ️ 将覆盖域名 $IMPORT_DOMAIN 的现有项目元数据。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local PROJECT_TYPE=""
    local PROJECT_DETAIL=""
    local PORT_TO_USE=""
    local PROXY_TARGET_URL=""

    local PROXY_PASS_LINE=$(grep -E '^\s*proxy_pass\s+http://' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*proxy_pass\s+//;s/;//' || echo "")
    local GUESS_TARGET_INPUT=""
    if [[ -n "$PROXY_PASS_LINE" ]]; then
        local TARGET_HOST_PORT=$(echo "$PROXY_PASS_LINE" | sed -E 's/http:\/\/(.*)/\1/' | sed 's|/.*||' || echo "")
        local TARGET_HOST=$(echo "$TARGET_HOST_PORT" | cut -d: -f1 || echo "")
        local TARGET_PORT=$(echo "$TARGET_HOST_PORT" | cut -d: -f2 || echo "")
        if [[ "$TARGET_HOST" == "127.0.0.1" || "$TARGET_HOST" == "localhost" ]]; then
            GUESS_TARGET_INPUT="$TARGET_PORT"
        else
            GUESS_TARGET_INPUT="$TARGET_HOST" # 尝试用容器名猜测
        fi
        log_message INFO "✅ 从 Nginx 配置中解析到代理目标猜测: ${GUESS_TARGET_INPUT}"
    else
        log_message WARN "⚠️ 未能从 Nginx 配置中自动解析到 proxy_pass 目标。"
    fi

    log_message INFO "\n请确认或输入后端代理目标信息 (例如：docker容器名 或 本地端口):"
    log_message INFO "  [当前解析/建议值: ${GUESS_TARGET_INPUT:-无}]"
    
    local USER_TARGET_INPUT=""
    USER_TARGET_INPUT=$(_prompt_user_input_with_validation "输入目标（回车不修改）" "$GUESS_TARGET_INPUT" "" "" "true") || { log_message ERROR "后端目标输入失败。"; return 1; }
    
    local PARSED_TARGET_OUTPUT
    PARSED_TARGET_OUTPUT=$(_parse_target_input "$USER_TARGET_INPUT" "8080" "true") || { log_message ERROR "❌ 解析后端目标失败，导入操作取消。"; return 1; }
    PROJECT_TYPE=$(echo "$PARSED_TARGET_OUTPUT" | head -n1)
    PROJECT_DETAIL=$(echo "$PARSED_TARGET_OUTPUT" | sed -n '2p')
    PORT_TO_USE=$(echo "$PARSED_TARGET_OUTPUT" | sed -n '3p')
    PROXY_TARGET_URL=$(echo "$PARSED_TARGET_OUTPUT" | tail -n1)

    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local SSL_CRT_PATH=$(grep -E '^\s*ssl_certificate\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate\s+//;s/;//' || echo "")
    local SSL_KEY_PATH=$(grep -E '^\s*ssl_certificate_key\s+' "$EXISTING_NGINX_CONF_PATH" | head -n1 | sed -E 's/^\s*ssl_certificate_key\s+//;s/;//' || echo "")

    local USER_CRT_PATH=""
    USER_CRT_PATH=$(_prompt_user_input_with_validation \
        "请输入证书文件 (fullchain) 路径" \
        "${SSL_CRT_PATH:-$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.cer}" \
        "" "" "false") || { log_message ERROR "证书文件路径输入失败。"; return 1; }

    if [ ! -f "$USER_CRT_PATH" ]; then
        log_message WARN "⚠️ 证书文件 $USER_CRT_PATH 不存在。请确保路径正确，否则后续续期可能失败。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local USER_KEY_PATH=""
    USER_KEY_PATH=$(_prompt_user_input_with_validation \
        "请输入证书私钥文件路径" \
        "${SSL_KEY_PATH:-$SSL_CERTS_BASE_DIR/$IMPORT_DOMAIN.key}" \
        "" "" "false") || { log_message ERROR "私钥文件路径输入失败。"; return 1; }

    if [ ! -f "$USER_KEY_PATH" ]; then
        log_message WARN "⚠️ 证书私钥文件 $USER_KEY_PATH 不存在。请确保路径正确，否则后续续期可能失败。"
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local IMPORTED_CUSTOM_SNIPPET=""
    IMPORTED_CUSTOM_SNIPPET=$(_prompt_for_custom_snippet_path "$IMPORT_DOMAIN" "$PROJECT_TYPE" "$PROJECT_DETAIL" "" "true")
    if [ $? -ne 0 ]; then
        log_message ERROR "❌ 自定义 Nginx 片段路径配置失败，导入操作取消。"
        return 1
    fi
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

    local IMPORTED_ACME_METHOD="imported"
    local IMPORTED_DNS_PROVIDER=""
    local IMPORTED_WILDCARD="n"
    local IMPORTED_CA_URL="unknown"
    local IMPORTED_CA_NAME="imported"

    local NEW_PROJECT_JSON_TMP=$(_build_project_json_object \
        "$IMPORT_DOMAIN" "$PROJECT_TYPE" "$PROJECT_DETAIL" "$PORT_TO_USE" "$IMPORTED_CUSTOM_SNIPPET" \
        "$IMPORTED_ACME_METHOD" "$IMPORTED_DNS_PROVIDER" "$IMPORTED_WILDCARD" "$IMPORTED_CA_URL" \
        "$IMPORTED_CA_NAME" "$USER_CRT_PATH" "$USER_KEY_PATH")

    if [[ -n "$EXISTING_JSON_ENTRY" ]]; then
        if ! jq "(.[] | select(.domain == \$domain)) = \$new_project_json" \
            --arg domain "$IMPORT_DOMAIN" \
            --argjson new_project_json "$NEW_PROJECT_JSON_TMP" \
            "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message ERROR "❌ 更新项目元数据失败！"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    else
        if ! jq ". + [\$new_project_json]" \
            --argjson new_project_json "$NEW_PROJECT_JSON_TMP" \
            "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
            log_message ERROR "❌ 写入项目元数据失败！"
            rm -f "${PROJECTS_METADATA_FILE}.tmp"
            return 1
        fi
    fi

    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
    log_message INFO "✅ 域名 $IMPORT_DOMAIN 的 Nginx 配置已成功导入到脚本管理列表。"
    log_message WARN "ℹ️ 注意：导入的项目，其证书签发机构和验证方式被标记为 'imported'/'unknown'。"
    log_message WARN "   如果您希望由本脚本的 acme.sh 自动续期，请手动选择 '编辑项目核心配置'，并设置正确的验证方式，然后重新申请证书。"

    log_message INFO "--- 导入完成 ---"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
    return 0
}

# -----------------------------
# 辅助函数：显示项目列表表格
_display_projects_table() {
    local PROJECTS_ARRAY_RAW="$1"
    local INDEX=0

    printf "${BLUE}%-4s │ %-25s │ %-8s │ %-25s │ %-10s │ %-18s │ %-4s │ %-5s │ %3s天 │ %s${RESET}\n" \
        "ID" "域名" "类型" "目标" "片段" "验证" "泛域" "状态" "剩余" "到期时间"
    printf "${BLUE}─────┼─────────────────────────┼──────────┼─────────────────────────┼────────────┼────────────────────┼──────┼───────┼───────┼────────────────────${RESET}\n"

    echo "$PROJECTS_ARRAY_RAW" | jq -c '.[]' | while read -r project_json; do
        INDEX=$((INDEX + 1))
        local DOMAIN=$(echo "$project_json" | jq -r '.domain // "未知域名"')

        local default_cert_file_display="$SSL_CERTS_BASE_DIR/$DOMAIN.cer"
        local default_key_file_display="$SSL_CERTS_BASE_DIR/$DOMAIN.key"
        local CERT_FILE=$(echo "$project_json" | jq -r --arg default_cert "$default_cert_file_display" '.cert_file // $default_cert')
        local KEY_FILE=$(echo "$project_json" | jq -r --arg default_key "$default_key_file_display" '.key_file // $default_key')

        local PROJECT_TYPE=$(echo "$project_json" | jq -r '.type // "未知"')
        local PROJECT_NAME=$(echo "$project_json" | jq -r '.name // "未知"')
        local RESOLVED_PORT=$(echo "$project_json" | jq -r '.resolved_port // "未知"')
        local CUSTOM_SNIPPET=$(echo "$project_json" | jq -r '.custom_snippet // "null"')
        local ACME_VALIDATION_METHOD=$(echo "$project_json" | jq -r '.acme_validation_method // "未知"')
        local DNS_API_PROVIDER=$(echo "$project_json" | jq -r '.dns_api_provider // "null"')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard // "n"')


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
            local END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || echo "未知日期")

            local END_TS_TEMP=0
            if command -v date >/dev/null 2>&1; then # Check if date command is available
                # Try GNU date -d first
                END_TS_TEMP=$(date -d "$END_DATE" +%s 2>/dev/null || echo 0)
                if [ "$END_TS_TEMP" -eq 0 ]; then # If GNU date -d failed, try BSD date -j
                    END_TS_TEMP=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%s" 2>/dev/null || echo 0)
                fi
            fi
            local NOW_TS=$(date +%s)
            local LEFT_DAYS=$(( (END_TS_TEMP - NOW_TS) / 86400 ))

            if (( END_TS_TEMP == 0 )); then # Date parsing failed completely
                STATUS_COLOR="$YELLOW"
                STATUS_TEXT="日期未知"
                LEFT_DAYS="N/A"
                FORMATTED_END_DATE="解析失败"
            elif (( LEFT_DAYS < 0 )); then
                STATUS_COLOR="$RED"
                STATUS_TEXT="已过期"
                FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y年%m月%d日" 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null || echo "未知日期")
            elif (( LEFT_DAYS <= RENEW_THRESHOLD_DAYS )); then
                STATUS_COLOR="$YELLOW"
                STATUS_TEXT="即将到期"
                FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y年%m月%d日" 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null || echo "未知日期")
            else
                STATUS_COLOR="$GREEN"
                STATUS_TEXT="有效"
                FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y年%m月%d日" 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null || echo "未知日期")
            fi
        fi

        printf "${MAGENTA}%-4s │ %-25s │ %-8s │ %-25s │ %-10s │ %-18s │ %-4s │ ${STATUS_COLOR}%-5s${RESET} │ %3s天 │ %s\n" "$INDEX" "$DOMAIN" "$PROJECT_TYPE_DISPLAY" "$PROJECT_DETAIL_DISPLAY" "$CUSTOM_SNIPPET_FILE_DISPLAY" "$ACME_METHOD_DISPLAY" "$WILDCARD_DISPLAY" "$STATUS_TEXT" "$LEFT_DAYS" "$FORMATTED_END_DATE"
    done <<< "$PROJECTS_ARRAY_RAW"
}


# -----------------------------
# 查看和管理已配置项目的函数
manage_configs() {
    if ! check_root; then return 10; fi # 非root则返回主菜单
    log_message INFO "--- 📜 已配置项目列表及证书状态 ---"

    check_projects_metadata_file # 每次进入管理界面都检查文件健康

    local PROJECTS_ARRAY_RAW=$(jq -c '[.[] | select(type == "object" and .domain != null and .domain != "")]' "$PROJECTS_METADATA_FILE")

    if [ "$(echo "$PROJECTS_ARRAY_RAW" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
        log_message WARN "未找到任何已配置的项目。"
        log_message INFO "------------------------------------"
        if _confirm_action_or_exit_non_interactive "没有找到已配置项目。是否立即导入一个现有 Nginx 配置？"; then
            # 导入后再次调用 manage_configs 显示列表
            import_existing_project && manage_configs
            return 0
        else
            return 10 # 返回到主菜单
        fi
    fi

    _display_projects_table "$PROJECTS_ARRAY_RAW"

    log_message INFO "--- 列 表 结 束 ---"

    while true; do
        log_message INFO "\n请选择管理操作："
        echo -e "${GREEN}1) 手动续期指定域名证书${RESET}"
        echo -e "${GREEN}2) 删除指定域名配置及证书${RESET}"
        echo -e "${GREEN}3) 编辑项目核心配置 (后端目标 / 验证方式等)${RESET}"
        echo -e "${GREEN}4) 管理自定义 Nginx 配置片段 (添加 / 修改 / 清除)${RESET}"
        echo -e "${GREEN}5) 导入现有 Nginx 配置到本脚本管理${RESET}"
        log_message INFO "----------------------------------------"
        echo -e "${CYAN}请输入选项 [回车返回]: ${RESET}"
        read -rp "> " MANAGE_CHOICE
        
        # 处理回车键返回
        if [ -z "$MANAGE_CHOICE" ]; then
            log_message INFO "返回主菜单。"
            return 10 # 返回到主菜单
        fi

        case "$MANAGE_CHOICE" in
            1) # 手动续期
                local DOMAIN_TO_RENEW=""
                DOMAIN_TO_RENEW=$(_prompt_user_input_with_validation "请输入要续期的域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" "域名格式不正确" "false") || { log_message ERROR "域名输入失败。"; continue; }

                local RENEW_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_RENEW\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
                if [ -z "$RENEW_PROJECT_JSON" ]; then log_message ERROR "❌ 域名 $DOMAIN_TO_RENEW 未找到在已配置列表中。"; continue; fi

                local RENEW_ACME_VALIDATION_METHOD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.acme_validation_method // "unknown"')
                local RENEW_DNS_API_PROVIDER=$(echo "$RENEW_PROJECT_JSON" | jq -r '.dns_api_provider // ""')
                local RENEW_USE_WILDCARD=$(echo "$RENEW_PROJECT_JSON" | jq -r '.use_wildcard // "n"')
                local RENEW_CA_SERVER_URL=$(echo "$RENEW_PROJECT_JSON" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')

                local default_cert_file_renew="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_RENEW.cer"
                local default_key_file_renew="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_RENEW.key"
                local RENEW_CERT_FILE=$(echo "$RENEW_PROJECT_JSON" | jq -r --arg default_cert "$default_cert_file_renew" '.cert_file // $default_cert')
                local RENEW_KEY_FILE=$(echo "$RENEW_PROJECT_JSON" | jq -r --arg default_key "$default_key_file_renew" '.key_file // $default_key')

                if [ "$RENEW_ACME_VALIDATION_METHOD" = "imported" ]; then
                    log_message WARN "ℹ️ 域名 $DOMAIN_TO_RENEW 的证书是导入的，本脚本无法直接续期。请手动或通过 '编辑项目核心配置' 转换为 acme.sh 管理。"
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                    continue
                fi

                local DOMAIN_CONF_RENEW="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_RENEW.conf"
                if ! _issue_and_install_certificate \
                    "$DOMAIN_TO_RENEW" "$RENEW_ACME_VALIDATION_METHOD" "$RENEW_DNS_API_PROVIDER" "$RENEW_USE_WILDCARD" \
                    "$RENEW_CA_SERVER_URL" "$RENEW_CERT_FILE" "$RENEW_KEY_FILE" "$DOMAIN_CONF_RENEW"; then
                    log_message ERROR "❌ 域名 $DOMAIN_TO_RENEW 证书续期失败。"
                else
                    log_message INFO "✅ 域名 $DOMAIN_TO_RENEW 证书续期成功。"
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            2) # 删除
                local DOMAIN_TO_DELETE=""
                DOMAIN_TO_DELETE=$(_prompt_user_input_with_validation "请输入要删除的域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" "域名格式不正确" "false") || { log_message ERROR "域名输入失败。"; continue; }

                local PROJECT_TO_DELETE_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_DELETE\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
                if [ -z "$PROJECT_TO_DELETE_JSON" ]; then
                    log_message ERROR "❌ 域名 $DOMAIN_TO_DELETE 未找到在已配置列表中。"
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                    continue
                fi

                log_message INFO "\n--- 请选择删除级别 for $DOMAIN_TO_DELETE ---"
                echo "${GREEN}1) 仅删除 Nginx 配置文件 (保留证书和元数据，用于临时禁用)${RESET}"
                echo "${GREEN}2) 删除 Nginx 配置文件和证书 (保留元数据，用于重新申请证书)${RESET}"
                echo "${RED}3) 全部删除 (Nginx 配置、证书、acme.sh 记录和元数据，彻底移除)${RESET}"
                
                local DELETE_LEVEL_CHOICE=""
                DELETE_LEVEL_CHOICE=$(_prompt_user_input_with_validation "请输入选项" "" "^[1-3]$" "无效选项" "false") || { log_message WARN "已取消删除操作。"; continue; }

                local CONFIRM_TEXT=""
                case "$DELETE_LEVEL_CHOICE" in
                    1) CONFIRM_TEXT="仅删除 Nginx 配置";;
                    2) CONFIRM_TEXT="删除 Nginx 配置和证书";;
                    3) CONFIRM_TEXT="全部删除";;
                esac

                if ! _confirm_action_or_exit_non_interactive "确认对 ${DOMAIN_TO_DELETE} 执行 '${CONFIRM_TEXT}' 操作？此操作可能不可恢复！"; then
                    log_message WARN "已取消删除操作。"
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                    continue
                fi

                log_message WARN "正在执行删除操作 for ${DOMAIN_TO_DELETE}..."

                local delete_config=false
                local delete_certs=false
                local delete_metadata=false

                case "$DELETE_LEVEL_CHOICE" in
                    1) delete_config=true ;;
                    2) delete_config=true; delete_certs=true ;;
                    3) delete_config=true; delete_certs=true; delete_metadata=true ;;
                esac

                # 获取相关文件路径
                local CUSTOM_SNIPPET_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r '.custom_snippet // "null"')
                local default_cert_file_delete="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE.cer"
                local default_key_file_delete="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE.key"
                local CERT_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r --arg default_cert "$default_cert_file_delete" '.cert_file // $default_cert')
                local KEY_FILE_TO_DELETE=$(echo "$PROJECT_TO_DELETE_JSON" | jq -r --arg default_key "$default_key_file_delete" '.key_file // $default_key')

                if [ "$delete_config" = "true" ]; then
                    rm -f "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_DELETE.conf"
                    rm -f "$NGINX_SITES_ENABLED_DIR/$DOMAIN_TO_DELETE.conf"
                    log_message INFO "✅ 已删除 Nginx 配置文件。"
                fi

                if [ "$delete_certs" = "true" ]; then
                    # acme.sh --remove 不会删除实际文件，只会删除它的内部记录
                    local remove_cmd=("$ACME_BIN" --remove -d "$DOMAIN_TO_DELETE" --ecc)
                    "${remove_cmd[@]}" 2>/dev/null || true
                    log_message INFO "✅ 已从 acme.sh 移除证书记录。"

                    # 删除实际的证书文件
                    if [ -f "$CERT_FILE_TO_DELETE" ]; then rm -f "$CERT_FILE_TO_DELETE"; log_message INFO "✅ 已删除证书文件: $CERT_FILE_TO_DELETE"; fi
                    if [ -f "$KEY_FILE_TO_DELETE" ]; then rm -f "$KEY_FILE_TO_DELETE"; log_message INFO "✅ 已删除私钥文件: $KEY_FILE_TO_DELETE"; fi

                    # 尝试删除 acme.sh 默认的证书目录，如果为空
                    if [ -d "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE" ] && [ -z "$(ls -A "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE" 2>/dev/null)" ]; then
                        rmdir "$SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE" 2>/dev/null || true # rmdir 只能删除空目录
                        log_message INFO "✅ 已删除空的默认证书目录 $SSL_CERTS_BASE_DIR/$DOMAIN_TO_DELETE (如果为空)。"
                    fi

                    if [[ -n "$CUSTOM_SNIPPET_FILE_TO_DELETE" && "$CUSTOM_SNIPPET_FILE_TO_DELETE" != "null" && -f "$CUSTOM_SNIPPET_FILE_TO_DELETE" ]]; then
                        if _confirm_action_or_exit_non_interactive "检测到自定义 Nginx 配置片段文件 '$CUSTOM_SNIPPET_FILE_TO_DELETE'，是否一并删除？"; then
                            rm -f "$CUSTOM_SNIPPET_FILE_TO_DELETE"
                            log_message INFO "✅ 已删除自定义 Nginx 片段文件。"
                        else
                            log_message WARN "ℹ️ 已保留自定义 Nginx 片段文件。"
                        fi
                    fi
                fi

                if [ "$delete_metadata" = "true" ]; then
                    if ! jq "del(.[] | select(.domain == \$domain_to_delete))" \
                        --arg domain_to_delete "$DOMAIN_TO_DELETE" \
                        "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                        log_message ERROR "❌ 从元数据中移除项目失败！"
                    else
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        log_message INFO "✅ 已从元数据中移除项目。"
                    fi
                fi

                log_message INFO "✅ 删除操作完成。"

                if [ "$delete_config" = "true" ]; then
                    if ! control_nginx reload; then
                        log_message WARN "Nginx 重载失败。如果已无任何站点，此为正常现象。请手动检查Nginx状态。"
                    fi
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            3) # 编辑项目核心配置 (不含片段)
                local DOMAIN_TO_EDIT=""
                DOMAIN_TO_EDIT=$(_prompt_user_input_with_validation "请输入要编辑的域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" "域名格式不正确" "false") || { log_message ERROR "域名输入失败。"; continue; }

                local CURRENT_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_TO_EDIT\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
                if [ -z "$CURRENT_PROJECT_JSON" ]; then log_message ERROR "❌ 域名 $DOMAIN_TO_EDIT 未找到在已配置列表中。"; continue; fi

                local EDIT_TYPE=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.type // "unknown"')
                local EDIT_NAME=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.name // "unknown"')
                local EDIT_RESOLVED_PORT=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.resolved_port // "unknown"')
                local EDIT_ACME_VALIDATION_METHOD=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.acme_validation_method // "unknown"')
                local EDIT_DNS_API_PROVIDER=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.dns_api_provider // ""')
                local EDIT_USE_WILDCARD=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.use_wildcard // "n"')
                local EDIT_CA_SERVER_URL=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')
                local EDIT_CA_SERVER_NAME=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.ca_server_name // "letsencrypt"')
                local EDIT_CUSTOM_SNIPPET_ORIGINAL=$(echo "$CURRENT_PROJECT_JSON" | jq -r '.custom_snippet // "null"')

                local default_cert_file_edit="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer"
                local default_key_file_edit="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                local EDIT_CERT_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r --arg default_cert "$default_cert_file_edit" '.cert_file // $default_cert')
                local EDIT_KEY_FILE=$(echo "$CURRENT_PROJECT_JSON" | jq -r --arg default_key "$default_key_file_edit" '.key_file // $default_key')

                log_message INFO "\n--- 编辑域名: $DOMAIN_TO_EDIT ---"
                log_message INFO "当前配置:"
                log_message INFO "  类型: ${YELLOW}$EDIT_TYPE${RESET}"
                log_message INFO "  目标: ${YELLOW}$EDIT_NAME (端口: $EDIT_RESOLVED_PORT)${RESET}"
                log_message INFO "  验证方式: ${YELLOW}$EDIT_ACME_VALIDATION_METHOD $( [[ -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]] && echo "($EDIT_DNS_API_PROVIDER)" || echo "" )${RESET}"
                log_message INFO "  泛域名: ${YELLOW}$( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "是" || echo "否" )${RESET}"
                log_message INFO "  CA: ${YELLOW}$EDIT_CA_SERVER_NAME${RESET}"
                log_message INFO "  证书文件: ${YELLOW}$EDIT_CERT_FILE${RESET}"
                log_message INFO "  私钥文件: ${YELLOW}$EDIT_KEY_FILE${RESET}"
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

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

                local NEW_TARGET_INPUT=""
                NEW_TARGET_INPUT=$(_prompt_user_input_with_validation "修改后端目标 (格式：docker容器名 或 本地端口)" "$EDIT_NAME" "" "" "true") || { log_message ERROR "后端目标输入失败。"; continue; }
                
                if [[ -n "$NEW_TARGET_INPUT" ]]; then
                    if [[ "$NEW_TARGET_INPUT" != "$EDIT_NAME" ]]; then
                        NEED_REISSUE_OR_RELOAD_NGINX="y"
                    fi

                    local PARSED_TARGET_OUTPUT_EDIT
                    PARSED_TARGET_OUTPUT_EDIT=$(_parse_target_input "$NEW_TARGET_INPUT" "$EDIT_RESOLVED_PORT" "false") || { log_message ERROR "❌ 解析后端目标失败，编辑操作取消。"; continue; }
                    NEW_TYPE=$(echo "$PARSED_TARGET_OUTPUT_EDIT" | head -n1)
                    NEW_NAME=$(echo "$PARSED_TARGET_OUTPUT_EDIT" | sed -n '2p')
                    NEW_RESOLVED_PORT=$(echo "$PARSED_TARGET_OUTPUT_EDIT" | sed -n '3p')
                    FINAL_PROXY_TARGET_URL=$(echo "$PARSED_TARGET_OUTPUT_EDIT" | tail -n1)
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                local NEW_VALIDATION_METHOD_INPUT=""
                NEW_VALIDATION_METHOD_INPUT=$(_prompt_user_input_with_validation \
                    "修改证书验证方式 (http-01 / dns-01)" \
                    "$EDIT_ACME_VALIDATION_METHOD" \
                    "^(http-01|dns-01)$" \
                    "无效的验证方式" \
                    "false") || { log_message ERROR "验证方式输入失败。"; continue; }

                if [[ "$NEW_VALIDATION_METHOD_INPUT" != "$EDIT_ACME_VALIDATION_METHOD" ]]; then
                    NEW_ACME_VALIDATION_METHOD="$NEW_VALIDATION_METHOD_INPUT"
                    log_message INFO "✅ 验证方式已更新为: $NEW_ACME_VALIDATION_METHOD。"
                    NEED_REISSUE_OR_RELOAD_NGINX="y"
                    NEW_CA_SERVER_NAME="letsencrypt" # Default CA for new validation setup
                    NEW_CA_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
                    NEW_CERT_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer" # Reset cert file paths to default for acme.sh management
                    NEW_KEY_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                if [ "$NEW_ACME_VALIDATION_METHOD" = "dns-01" ]; then
                     local NEW_WILDCARD_INPUT=""
                     NEW_WILDCARD_INPUT=$(_prompt_user_input_with_validation \
                        "修改泛域名设置 (y/n)" \
                        "$( [[ "$EDIT_USE_WILDCARD" = "y" ]] && echo "y" || echo "n" )" \
                        "^[yYnN]$" \
                        "无效输入" \
                        "false") || { log_message ERROR "泛域名设置输入失败。"; continue; }

                     if [[ "$NEW_WILDCARD_INPUT" =~ ^[Yy]$ ]]; then
                         if [[ "$EDIT_USE_WILDCARD" != "y" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                         NEW_USE_WILDCARD="y"
                     else
                         if [[ "$EDIT_USE_WILDCARD" = "y" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                         NEW_USE_WILDCARD="n"
                     fi
                     log_message INFO "✅ 泛域名设置已更新为: $NEW_USE_WILDCARD。"
                     if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                     local NEW_DNS_PROVIDER_INPUT=""
                     NEW_DNS_PROVIDER_INPUT=$(_prompt_user_input_with_validation \
                        "修改 DNS API 服务商 (dns_cf / dns_ali)" \
                        "$EDIT_DNS_API_PROVIDER" \
                        "^(dns_cf|dns_ali)$" \
                        "无效的 DNS 服务商" \
                        "false") || { log_message ERROR "DNS 服务商输入失败。"; continue; }

                     if [[ "$NEW_DNS_PROVIDER_INPUT" != "$EDIT_DNS_API_PROVIDER" ]]; then
                         NEW_DNS_API_PROVIDER="$NEW_DNS_PROVIDER_INPUT"
                         log_message INFO "✅ DNS API 服务商已更新为: $NEW_DNS_API_PROVIDER。"
                         NEED_REISSUE_OR_RELOAD_NGINX="y"
                         if ! check_dns_env "$NEW_DNS_API_PROVIDER"; then
                            log_message ERROR "DNS 环境变量检查失败，请设置后重试。"
                            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                            continue # 跳过当前编辑，用户需重新设置
                         fi
                     fi
                     if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                else # 如果是非 dns-01 验证，泛域名和 DNS API 设为空
                    if [[ "$EDIT_USE_WILDCARD" = "y" || -n "$EDIT_DNS_API_PROVIDER" && "$EDIT_DNS_API_PROVIDER" != "null" ]]; then NEED_REISSUE_OR_RELOAD_NGINX="y"; fi
                    NEW_USE_WILDCARD="n"
                    NEW_DNS_API_PROVIDER=""
                fi

                if [[ "$EDIT_ACME_VALIDATION_METHOD" = "imported" || "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]]; then
                    local CA_SELECTION_OUTPUT_EDIT
                    CA_SELECTION_OUTPUT_EDIT=$(_select_acme_ca_server \
                        "请选择新的证书颁发机构 (CA):" \
                        "$NEW_CA_SERVER_URL" \
                        "$NEW_CA_SERVER_NAME") || continue
                    NEW_CA_SERVER_URL=$(echo "$CA_SELECTION_OUTPUT_EDIT" | head -n1)
                    NEW_CA_SERVER_NAME=$(echo "$CA_SELECTION_OUTPUT_EDIT" | tail -n1)

                    if [ "$NEW_CA_SERVER_NAME" = "zerossl" ]; then
                         if ! _ensure_zerossl_account "$NEW_CA_SERVER_URL"; then continue; fi
                    fi
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                local UPDATED_PROJECT_JSON_TMP=$(_build_project_json_object \
                    "$DOMAIN_TO_EDIT" "$NEW_TYPE" "$NEW_NAME" "$NEW_RESOLVED_PORT" "$EDIT_CUSTOM_SNIPPET_ORIGINAL" \
                    "$NEW_ACME_VALIDATION_METHOD" "$NEW_DNS_API_PROVIDER" "$NEW_USE_WILDCARD" "$NEW_CA_SERVER_URL" \
                    "$NEW_CA_SERVER_NAME" "$NEW_CERT_FILE" "$NEW_KEY_FILE")

                if ! jq "(.[] | select(.domain == \$domain_to_edit)) = \$updated_project_json" \
                    --arg domain_to_edit "$DOMAIN_TO_EDIT" \
                    --argjson updated_project_json "$UPDATED_PROJECT_JSON_TMP" \
                    "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                    log_message ERROR "❌ 更新项目元数据失败！"
                else
                    mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                    log_message INFO "✅ 项目元数据已更新。"
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                if [ "$NEED_REISSUE_OR_RELOAD_NGINX" = "y" ]; then
                    log_message WARN "ℹ️ 检测到与证书或 Nginx 配置相关的关键修改。"
                    if ! _confirm_action_or_exit_non_interactive "是否立即更新 Nginx 配置并尝试重新申请证书？(强烈建议)"; then
                        log_message WARN "ℹ️ 已跳过证书重新申请和 Nginx 配置更新。请手动操作以确保生效。"
                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                        continue
                    fi

                    log_message WARN "重新生成 Nginx 配置并申请证书..."

                    local DOMAIN_CONF_EDIT="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_EDIT.conf"
                    if ! _issue_and_install_certificate \
                        "$DOMAIN_TO_EDIT" "$NEW_ACME_VALIDATION_METHOD" "$NEW_DNS_API_PROVIDER" "$NEW_USE_WILDCARD" \
                        "$NEW_CA_SERVER_URL" "$NEW_CERT_FILE" "$NEW_KEY_FILE" "$DOMAIN_CONF_EDIT"; then
                        log_message ERROR "❌ 域名 $DOMAIN_TO_EDIT 的证书重新申请/安装失败。"
                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                        continue # Re-issue failed, back to manage menu
                    fi

                    # 更新证书文件路径到元数据中
                    NEW_CERT_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.cer"
                    NEW_KEY_FILE="$SSL_CERTS_BASE_DIR/$DOMAIN_TO_EDIT.key"
                    local LATEST_ACME_CERT_JSON=$(_build_project_json_object \
                        "$DOMAIN_TO_EDIT" "" "" "" "" "" "" "" "" "" \
                        "$NEW_CERT_FILE" "$NEW_KEY_FILE") # 只更新证书路径相关字段

                    if ! jq "(.[] | select(.domain == \$domain_to_edit)) |= . + \$latest_acme_cert_json" \
                        --arg domain_to_edit "$DOMAIN_TO_EDIT" \
                        --argjson latest_acme_cert_json "$LATEST_ACME_CERT_JSON" \
                        "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                        log_message ERROR "❌ 更新证书文件路径到元数据失败！"
                    else
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        log_message INFO "✅ 证书已成功重新签发，路径已更新至脚本默认管理路径。"
                    fi
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                    log_message WARN "生成 $DOMAIN_TO_EDIT 的最终 Nginx 配置..."
                    local CUSTOM_SNIPPET_CONTENT_EDIT=""
                    if [[ -n "$EDIT_CUSTOM_SNIPPET_ORIGINAL" && "$EDIT_CUSTOM_SNIPPET_ORIGINAL" != "null" ]]; then
                        CUSTOM_SNIPPET_CONTENT_EDIT="\n    # BEGIN Custom Nginx Snippet for $DOMAIN_TO_EDIT\n    include $EDIT_CUSTOM_SNIPPET_ORIGINAL;\n    # END Custom Nginx Snippet for $DOMAIN_TO_EDIT"
                    fi
                    _NGINX_FINAL_TEMPLATE "$DOMAIN_TO_EDIT" "$FINAL_PROXY_TARGET_URL" "$NEW_CERT_FILE" "$NEW_KEY_FILE" "$CUSTOM_SNIPPET_CONTENT_EDIT" > "$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_TO_EDIT.conf"
                    log_message INFO "✅ 域名 $DOMAIN_TO_EDIT 的 Nginx 配置已更新。"
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                    if ! control_nginx reload; then
                        log_message ERROR "❌ 最终 Nginx 配置重载失败，请手动检查 Nginx 服务状态！"
                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                        continue
                    fi
                    log_message INFO "🚀 域名 $DOMAIN_TO_EDIT 配置更新完成。"
                } else {
                    log_message WARN "ℹ️ 项目配置已修改。请手动重新加载 Nginx (systemctl reload nginx) 以确保更改生效。"
                }
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            4) # 管理自定义 Nginx 配置片段
                local DOMAIN_FOR_SNIPPET=""
                DOMAIN_FOR_SNIPPET=$(_prompt_user_input_with_validation "请输入要管理片段的域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" "域名格式不正确" "false") || { log_message ERROR "域名输入失败。"; continue; }
                
                local SNIPPET_PROJECT_JSON=$(jq -c ".[] | select(.domain == \"$DOMAIN_FOR_SNIPPET\")" "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "")
                if [ -z "$SNIPPET_PROJECT_JSON" ]; then log_message ERROR "❌ 域名 $DOMAIN_FOR_SNIPPET 未找到在已配置列表中。"; continue; fi

                local CURRENT_SNIPPET_PATH=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.custom_snippet // "null"')
                local PROJECT_TYPE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.type // "unknown"')
                local PROJECT_NAME_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.name // "unknown"')
                local RESOLVED_PORT_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.resolved_port // "unknown"')
                local CERT_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.cert_file // ""')
                local KEY_FILE_SNIPPET=$(echo "$SNIPPET_PROJECT_JSON" | jq -r '.key_file // ""')

                if [[ -z "$CERT_FILE_SNIPPET" || "$CERT_FILE_SNIPPET" == "null" ]]; then CERT_FILE_SNIPPET="$SSL_CERTS_BASE_DIR/$DOMAIN_FOR_SNIPPET.cer"; fi
                if [[ -z "$KEY_FILE_SNIPPET" || "$KEY_FILE_SNIPPET" == "null" ]]; then KEY_FILE_SNIPPET="$SSL_CERTS_BASE_DIR/$DOMAIN_FOR_SNIPPET.key"; fi

                log_message INFO "\n--- 管理域名 $DOMAIN_FOR_SNIPPET 的 Nginx 配置片段 ---"
                if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then log_message WARN "当前自定义片段文件: $CURRENT_SNIPPET_PATH"; else log_message INFO "当前未设置自定义片段文件。"; fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                local DEFAULT_SNIPPET_FILENAME=""
                if [ "$PROJECT_TYPE_SNIPPET" = "docker" ]; then DEFAULT_SNIPPET_FILENAME="$PROJECT_NAME_SNIPPET.conf"; else DEFAULT_SNIPPET_FILENAME="$DOMAIN_FOR_SNIPPET.conf"; fi
                local DEFAULT_SNIPPET_PATH="$NGINX_CUSTOM_SNIPPETS_DIR/$DEFAULT_SNIPPET_FILENAME"

                local SNIPPET_MANAGEMENT_ACTION=""
                while true; do
                    log_message INFO "\n请选择片段管理操作 for $DOMAIN_FOR_SNIPPET:"
                    if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                        echo "${GREEN}1) 修改片段文件路径 (当前: $(basename "$CURRENT_SNIPPET_PATH"))${RESET}"
                        echo "${GREEN}2) 编辑当前片段文件内容 (用 nano)${RESET}"
                        echo "${RED}3) 清除自定义片段设置并删除文件${RESET}"
                    else
                        echo "${GREEN}1) 设置新的片段文件路径${RESET}"
                    fi
                    echo "${YELLOW}0) 返回上级菜单${RESET}"
                    SNIPPET_MANAGEMENT_ACTION=$(_prompt_user_input_with_validation "请输入选项" "" "^[0-3]$" "无效选项" "false") || { log_message ERROR "输入错误，操作取消。"; continue; }
                    
                    local CHOSEN_SNIPPET_PATH="$CURRENT_SNIPPET_PATH" # 默认保持不变
                    local RELOAD_NGINX_AFTER_UPDATE="n"

                    case "$SNIPPET_MANAGEMENT_ACTION" in
                        1) # 修改片段文件路径
                            CHOSEN_SNIPPET_PATH=$(_prompt_for_custom_snippet_path "$DOMAIN_FOR_SNIPPET" "$PROJECT_TYPE_SNIPPET" "$PROJECT_NAME_SNIPPET" "$CURRENT_SNIPPET_PATH" "false")
                            if [ $? -ne 0 ]; then
                                log_message ERROR "❌ 自定义 Nginx 片段路径配置失败，操作取消。"
                                continue
                            fi
                            RELOAD_NGINX_AFTER_UPDATE="y"
                            break # 跳出当前内部循环，执行更新元数据和Nginx配置的逻辑
                            ;;
                        2) # 编辑当前片段文件内容
                            if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                                if [ -f "$CURRENT_SNIPPET_PATH" ]; then
                                    log_message INFO "正在使用 nano 编辑文件: $CURRENT_SNIPPET_PATH"
                                    if ! command -v nano &>/dev/null; then
                                        log_message ERROR "❌ nano 编辑器未安装。请手动安装 'nano' 或编辑文件。"
                                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                                        continue
                                    fi
                                    nano "$CURRENT_SNIPPET_PATH"
                                    log_message WARN "ℹ️ 文件已保存。正在检查 Nginx 配置并尝试重载..."
                                    if ! control_nginx reload; then
                                        log_message ERROR "❌ Nginx 重载失败！请检查片段文件 '$CURRENT_SNIPPET_PATH' 的语法错误！"
                                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 3; fi
                                    else
                                        log_message INFO "✅ Nginx 配置已重载，更改已应用。"
                                    fi
                                else
                                    log_message ERROR "❌ 片段文件 '$CURRENT_SNIPPET_PATH' 不存在，无法编辑。请先设置或创建它。"
                                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                                fi
                            else
                                log_message WARN "⚠️ 未设置自定义片段文件，请先选择 '1. 设置新的片段文件路径'。"
                                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                            fi
                            ;;
                        3) # 清除自定义片段设置并删除文件
                            if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" ]]; then
                                if ! _confirm_action_or_exit_non_interactive "确认清除自定义片段设置并删除文件 '$CURRENT_SNIPPET_PATH'？此操作不可逆！"; then
                                    log_message WARN "ℹ️ 已取消删除片段文件。"
                                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                                    continue
                                fi
                                rm -f "$CURRENT_SNIPPET_PATH"
                                log_message INFO "✅ 已删除片段文件: $CURRENT_SNIPPET_PATH。"
                                CHOSEN_SNIPPET_PATH="" # 将路径设置为空以清除元数据记录
                                RELOAD_NGINX_AFTER_UPDATE="y"
                                break # 跳出当前内部循环，执行更新元数据和Nginx配置的逻辑
                            else
                                log_message WARN "⚠️ 当前未设置自定义片段文件，无需清除。"
                                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                            fi
                            ;;
                        0) # 返回上级菜单
                            break 2 # 跳出两层循环，返回到 manage_configs 主循环
                            ;;
                        *)
                            log_message ERROR "❌ 无效选项，请重新输入。"
                            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                            ;;
                    esac
                }

                # 如果 CHOSEN_SNIPPET_PATH 与 CURRENT_SNIPPET_PATH 不同，或者需要重新加载 Nginx
                if [[ "$CHOSEN_SNIPPET_PATH" != "$CURRENT_SNIPPET_PATH" || "$RELOAD_NGINX_AFTER_UPDATE" = "y" ]]; then
                    local UPDATED_SNIPPET_JSON_OBJ=$(jq -n --arg custom_snippet "$CHOSEN_SNIPPET_PATH" '{custom_snippet: $custom_snippet}')
                    if ! jq "(.[] | select(.domain == \$domain_for_snippet)) |= . + \$updated_snippet_json_obj" \
                        --arg domain_for_snippet "$DOMAIN_FOR_SNIPPET" \
                        --argjson updated_snippet_json_obj "$UPDATED_SNIPPET_JSON_OBJ" \
                        "$PROJECTS_METADATA_FILE" > "${PROJECTS_METADATA_FILE}.tmp"; then
                        log_message ERROR "❌ 更新项目元数据失败！"
                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                        continue
                    else
                        mv "${PROJECTS_METADATA_FILE}.tmp" "$PROJECTS_METADATA_FILE"
                        log_message INFO "✅ 项目元数据中的自定义片段路径已更新。"
                    fi
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                    local PROXY_TARGET_URL_SNIPPET="http://127.0.0.1:$RESOLVED_PORT_SNIPPET"
                    local DOMAIN_CONF_SNIPPET="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN_FOR_SNIPPET.conf"

                    log_message WARN "正在重新生成 $DOMAIN_FOR_SNIPPET 的 Nginx 配置..."
                    local CUSTOM_SNIPPET_CONTENT_FOR_RENDER=""
                    if [[ -n "$CHOSEN_SNIPPET_PATH" && "$CHOSEN_SNIPPET_PATH" != "null" ]]; then
                        CUSTOM_SNIPPET_CONTENT_FOR_RENDER="\n    # BEGIN Custom Nginx Snippet for $DOMAIN_FOR_SNIPPET\n    include $CHOSEN_SNIPPET_PATH;\n    # END Custom Nginx Snippet for $DOMAIN_FOR_SNIPPET"
                    fi
                    _NGINX_FINAL_TEMPLATE "$DOMAIN_FOR_SNIPPET" "$PROXY_TARGET_URL_SNIPPET" "$CERT_FILE_SNIPPET" "$KEY_FILE_SNIPPET" "$CUSTOM_SNIPPET_CONTENT_FOR_RENDER" > "$DOMAIN_CONF_SNIPPET"

                    if ! control_nginx reload; then
                        log_message ERROR "❌ Nginx 重载失败，请手动检查 Nginx 服务状态！"
                        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                        continue
                    fi
                    log_message INFO "🚀 域名 $DOMAIN_FOR_SNIPPET 的 Nginx 配置已更新并重载。"
                    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi

                    if [[ -n "$CURRENT_SNIPPET_PATH" && "$CURRENT_SNIPPET_PATH" != "null" && "$CHOSEN_SNIPPET_PATH" != "$CURRENT_SNIPPET_PATH" && -f "$CURRENT_SNIPPET_PATH" ]]; then
                        if _confirm_action_or_exit_non_interactive "检测到原有自定义片段文件 '$CURRENT_SNIPPET_PATH'。是否删除此文件？"; then
                            rm -f "$CURRENT_SNIPPET_PATH"
                            log_message INFO "✅ 已删除旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH"
                        else
                            log_message WARN "ℹ️ 已保留旧的自定义 Nginx 片段文件: $CURRENT_SNIPPET_PATH"
                        fi
                    fi
                }
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            5) # 导入现有 Nginx 配置到本脚本管理
                import_existing_project
                # 导入后继续显示管理菜单
                continue
                ;;
            *)
                log_message ERROR "❌ 无效选项，请输入 1-5"
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                ;;
        esac
    done
}

# --- 检查并自动续期所有证书的函数
check_and_auto_renew_certs() {
    if ! check_root; then return 1; fi # 非root则返回失败

    log_message INFO "--- 🔄 检查并自动续期所有证书 ---"

    if ! check_projects_metadata_file; then
        log_message ERROR "❌ 项目元数据文件检查失败，无法进行证书续期。"
        return 1
    fi

    local PROJECTS_ARRAY_RAW=$(jq -c '[.[] | select(type == "object" and .domain != null and .domain != "")]' "$PROJECTS_METADATA_FILE")

    if [ "$(echo "$PROJECTS_ARRAY_RAW" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
        log_message INFO "未找到任何由本脚本管理的已配置项目，无需续期。"
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
        return 0
    fi

    local RENEWED_COUNT=0
    local FAILED_COUNT=0
    local TOTAL_PROCESSED=0

    # 使用进程替换来确保变量在父shell中更新
    while IFS= read -r project_json; do
        local DOMAIN=$(echo "$project_json" | jq -r '.domain // "未知域名"')
        local ACME_VALIDATION_METHOD=$(echo "$project_json" | jq -r '.acme_validation_method // "unknown"')
        local DNS_API_PROVIDER=$(echo "$project_json" | jq -r '.dns_api_provider // ""')
        local USE_WILDCARD=$(echo "$project_json" | jq -r '.use_wildcard // "n"')
        local ACME_CA_SERVER_URL=$(echo "$project_json" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')

        local default_cert_file="$SSL_CERTS_BASE_DIR/$DOMAIN.cer"
        local CERT_FILE=$(echo "$project_json" | jq -r --arg default_cert "$default_cert_file" '.cert_file // $default_cert')
        local KEY_FILE=$(echo "$project_json" | jq -r --arg default_cert "$default_cert_file" '.key_file // $default_cert') # Key file path is often same as cert file path in acme.sh fullchain

        log_message INFO "➡️ 检查域名 $DOMAIN 的证书..."
        TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))

        if [ "$ACME_VALIDATION_METHOD" = "imported" ]; then
            log_message WARN "ℹ️ 域名 $DOMAIN 的证书是导入的，本脚本无法自动续期。请手动管理。"
            continue
        fi

        if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
            log_message ERROR "❌ 域名 $DOMAIN 的证书文件或私钥文件缺失 ($CERT_FILE, $KEY_FILE)，无法续期。"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi

        local END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || echo "未知日期")
        local END_TS_TEMP=0
        if command -v date >/dev/null 2>&1; then
            END_TS_TEMP=$(date -d "$END_DATE" +%s 2>/dev/null || echo 0)
            if [ "$END_TS_TEMP" -eq 0 ]; then
                END_TS_TEMP=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%s" 2>/dev/null || echo 0)
            fi
        fi
        
        if (( END_TS_TEMP == 0 )); then
            log_message ERROR "❌ 无法解析域名 $DOMAIN 证书的到期日期，无法续期。"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi

        local NOW_TS=$(date +%s)
        local LEFT_DAYS=$(( (END_TS_TEMP - NOW_TS) / 86400 ))

        if (( LEFT_DAYS <= RENEW_THRESHOLD_DAYS )); then
            log_message WARN "⚠️ 域名 $DOMAIN 的证书将在 $LEFT_DAYS 天内到期（或已过期），正在尝试续期..."

            local DOMAIN_CONF_AUTO_RENEW="$NGINX_SITES_AVAILABLE_DIR/$DOMAIN.conf"
            if ! _issue_and_install_certificate \
                "$DOMAIN" "$ACME_VALIDATION_METHOD" "$DNS_API_PROVIDER" "$USE_WILDCARD" \
                "$ACME_CA_SERVER_URL" "$CERT_FILE" "$KEY_FILE" "$DOMAIN_CONF_AUTO_RENEW"; then
                
                log_message ERROR "❌ 域名 $DOMAIN 证书续期失败！"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                # 续期失败时，不删除 Nginx 配置，保留旧证书
            else
                log_message INFO "✅ 域名 $DOMAIN 证书续期成功。"
                RENEWED_COUNT=$((RENEWED_COUNT + 1))
            fi
        else
            log_message INFO "✅ 域名 $DOMAIN 的证书在 $LEFT_DAYS 天后到期，无需续期。"
        fi
        echo "$RENEWED_COUNT $FAILED_COUNT" # 每次循环输出计数，供父shell读取
    done <<< "$PROJECTS_ARRAY_RAW" | { # 进程替换
        local last_line
        while IFS= read -r last_line; do
            # Read the last line to get the final counts
            RENEWED_COUNT=$(echo "$last_line" | awk '{print $1}')
            FAILED_COUNT=$(echo "$last_line" | awk '{print $2}')
        done
        
        log_message INFO "--- 证书续期概览 ---"
        log_message INFO "成功续期: $RENEWED_COUNT 个"
        log_message INFO "失败续期: $FAILED_COUNT 个"
        log_message INFO "--------------------"
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
        
        if [ "$FAILED_COUNT" -gt 0 ]; then
            return 1 # 有失败项则返回失败
        else
            return 0 # 全部成功或无操作则返回成功
        fi
    }
}

# --- 检查并自动续期所有证书的函数
manage_acme_accounts() {
    if ! check_root; then return 10; fi # 非root则返回主菜单
    while true; do
        log_message INFO "--- 👤 acme.sh 账户管理 ---"
        echo "${GREEN}1) 查看已注册账户${RESET}"
        echo "${GREEN}2) 注册新账户${RESET}"
        echo "${GREEN}3) 设置默认账户${RESET}"
        log_message INFO "---------------------------"
        echo -e "${CYAN}请输入选项 [回车返回]: ${RESET}"
        read -rp "> " ACCOUNT_CHOICE
        
        if [ -z "$ACCOUNT_CHOICE" ]; then
            log_message INFO "返回主菜单。"
            return 10
        fi

        case "$ACCOUNT_CHOICE" in
            1)
                log_message INFO "🔍 已注册 acme.sh 账户列表:"
                local list_account_cmd=("$ACME_BIN" --list-account)
                "${list_account_cmd[@]}"
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            2)
                log_message INFO "➡️ 注册新 acme.sh 账户:"
                local NEW_ACCOUNT_EMAIL=""
                NEW_ACCOUNT_EMAIL=$(_prompt_user_input_with_validation \
                    "请输入新账户的邮箱地址" \
                    "" \
                    "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" \
                    "邮箱格式不正确" \
                    "false") || { log_message ERROR "邮箱输入失败。"; continue; }
                
                local REGISTER_CA_SERVER_URL=""
                local REGISTER_CA_SERVER_NAME=""
                local CA_REGISTER_OUTPUT
                CA_REGISTER_OUTPUT=$(_select_acme_ca_server "请选择证书颁发机构 (CA):" "https://acme-v02.api.letsencrypt.org/directory" "letsencrypt") || continue
                REGISTER_CA_SERVER_URL=$(echo "$CA_REGISTER_OUTPUT" | head -n1)
                REGISTER_CA_SERVER_NAME=$(echo "$CA_REGISTER_OUTPUT" | tail -n1)

                log_message INFO "🚀 正在注册账户 $NEW_ACCOUNT_EMAIL (CA: $REGISTER_CA_SERVER_NAME)..."
                local register_cmd_accounts=("$ACME_BIN" --register-account -m "$NEW_ACCOUNT_EMAIL" --server "$REGISTER_CA_SERVER_URL")
                if "${register_cmd_accounts[@]}"; then
                    log_message INFO "✅ 账户注册成功。"
                else
                    log_message ERROR "❌ 账户注册失败！请检查邮箱地址或网络。"
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            3)
                log_message INFO "➡️ 设置默认 acme.sh 账户:"
                local list_account_cmd_set_default=("$ACME_BIN" --list-account)
                "${list_account_cmd_set_default[@]}" # 列出账户，让用户选择
                
                local DEFAULT_ACCOUNT_EMAIL=""
                DEFAULT_ACCOUNT_EMAIL=$(_prompt_user_input_with_validation \
                    "请输入要设置为默认的账户邮箱地址" \
                    "" \
                    "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$" \
                    "邮箱格式不正确" \
                    "false") || { log_message ERROR "邮箱输入失败。"; continue; }
                
                log_message INFO "🚀 正在设置 $DEFAULT_ACCOUNT_EMAIL 为默认账户..."
                local set_default_cmd=("$ACME_BIN" --set-default-account -m "$DEFAULT_ACCOUNT_EMAIL")
                if "${set_default_cmd[@]}"; then
                    log_message INFO "✅ 默认账户设置成功。"
                else
                    log_message ERROR "❌ 设置默认账户失败！请检查邮箱地址是否已注册。"
                fi
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 2; fi
                ;;
            *)
                log_message ERROR "❌ 无效选项，请输入 1-3"
                if [ "$IS_INTERACTIVE_MODE" = "true" ]; then sleep 1; fi
                ;;
        esac
    done
}


# --- 主菜单 ---
main_menu() {
    while true; do
        log_message INFO "╔═══════════════════════════════════════╗"
        log_message INFO "║     🚀 Nginx/HTTPS 证书管理主菜单     ║"
        log_message INFO "╚═══════════════════════════════════════╝"
        log_message INFO "" # 添加空行美化
        echo -e "${GREEN}1) 配置新的 Nginx 反向代理和 HTTPS 证书${RESET}"
        echo -e "${GREEN}2) 查看与管理已配置项目 (域名、端口、证书)${RESET}"
        echo -e "${GREEN}3) 检查并自动续期所有证书${RESET}"
        echo -e "${GREEN}4) 管理 acme.sh 账户${RESET}"
        log_message INFO "---------------------------------------"
        echo -e "${CYAN}请输入选项 [回车退出]: ${RESET}"
        read -rp "> " MAIN_CHOICE
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
                log_message INFO "👋 感谢使用，已退出。"
                log_message INFO "--- 脚本执行结束: $(date +"%Y-%m-%d %H:%M:%S") ---"
                return 0 # 返回 0 给父脚本，表示正常退出模块
                ;;
            *)
        esac
    done
}

# --- 脚本入口 ---
# 检查是否以 `--cron` 或 `--non-interactive` 参数启动
if [[ " $* " =~ " --cron " || " $* " =~ " --non-interactive " ]]; then
    # IS_INTERACTIVE_MODE="false" 已经在脚本开头根据参数设置了
    if ! check_root; then exit 1; fi # 非 root 用户在非交互模式下直接退出
    check_and_auto_renew_certs
    exit $? # 确保 cron 任务能正确反映续期结果
fi

# 正常交互模式启动主菜单
if ! check_root; then exit 1; fi # 非 root 用户在交互模式下也直接退出
main_menu
