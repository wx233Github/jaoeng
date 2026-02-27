#!/usr/bin/env bash
# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.35.0 - Security & Performance)
# =============================================================
# 作者:Shell 脚本专家
# 描述:自动化管理 Nginx 反代配置与 SSL 证书,支持 TCP 负载均衡、泛域名无代理模式、性能优化与安全日志遮掩

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"

# --- 全局变量 ---
readonly NC="\033[0m"
readonly BLACK="\033[30m"
readonly RED="\033[31m"
readonly GREEN="\033[32m"
readonly YELLOW="\033[33m"
readonly BLUE="\033[34m"
readonly PURPLE="\033[35m"
readonly CYAN="\033[36m"
readonly WHITE="\033[37m"
readonly BRIGHT_RED="\033[91m"
readonly BRIGHT_YELLOW="\033[93m"
readonly GRAY="\033[2m"
readonly BOLD="\033[1m"

LOG_FILE_DEFAULT="/var/log/nginx_ssl_manager.log"
LOG_FILE_FALLBACK="/tmp/nginx_ssl_manager.log"
LOG_LEVEL_DEFAULT="INFO"
LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_DEFAULT}"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"
ALLOW_UNSAFE_HOOKS="${ALLOW_UNSAFE_HOOKS:-false}"
SAFE_PATH_ROOTS=("/etc/nginx" "/etc/ssl" "/var/www" "/var/log" "/var/lib/nginx_ssl_manager" "/root/nginx_ssl_backups" "/etc/nginx/projects_backups" "/etc/nginx/conf_backups")
HOOK_WHITELIST=("systemctl restart s-ui" "systemctl restart x-ui" "systemctl restart v2ray" "systemctl restart xray" "systemctl reload nginx" "systemctl restart nginx")
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
TCP_PROJECTS_METADATA_FILE="/etc/nginx/tcp_projects.json"
JSON_BACKUP_DIR="/etc/nginx/projects_backups"
BACKUP_DIR="/root/nginx_ssl_backups"
CONF_BACKUP_DIR="/etc/nginx/conf_backups"
TG_CONF_FILE="/etc/nginx/tg_notifier.conf"
GZIP_DISABLE_MARK="/etc/nginx/.gzip_optimize_disabled"
CONF_BACKUP_KEEP="${CONF_BACKUP_KEEP:-10}"
HEALTH_CHECK_ENABLED="${HEALTH_CHECK_ENABLED:-false}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-5}"
HEALTH_CHECK_SCHEME="${HEALTH_CHECK_SCHEME:-http}"
HEALTH_CHECK_EXPECT_CODES="${HEALTH_CHECK_EXPECT_CODES:-200,204,301,302,403}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-2}"
HEALTH_CHECK_RETRY_DELAY="${HEALTH_CHECK_RETRY_DELAY:-1}"
RENEW_FAIL_DB="${RENEW_FAIL_DB:-/var/lib/nginx_ssl_manager/renew_failures.json}"
RENEW_FAIL_THRESHOLD="${RENEW_FAIL_THRESHOLD:-3}"
RENEW_FAIL_TTL_DAYS="${RENEW_FAIL_TTL_DAYS:-14}"
SKIP_NGINX_TEST_IN_APPLY="${SKIP_NGINX_TEST_IN_APPLY:-false}"
NGINX_TEST_CACHE_ENABLED="${NGINX_TEST_CACHE_ENABLED:-true}"
NGINX_TEST_CACHE_MAX_AGE_SECS="${NGINX_TEST_CACHE_MAX_AGE_SECS:-60}"
NGINX_CONF_GEN=0
NGINX_TEST_CACHE_GEN=-1
NGINX_TEST_CACHE_RESULT=1
NGINX_TEST_CACHE_TS=0
ACME_SH_INSTALL_URL="${ACME_SH_INSTALL_URL:-https://get.acme.sh}"
ACME_SH_INSTALL_SHA256="${ACME_SH_INSTALL_SHA256:-}"

ERR_CFG_INVALID_ARGS=2
ERR_CFG_VALIDATE=20
ERR_CFG_WRITE=21

RENEW_THRESHOLD_DAYS=30
DEPS_MARK_FILE="$HOME/.nginx_ssl_manager_deps_v3"

NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_STREAM_AVAILABLE_DIR="/etc/nginx/stream-available"
NGINX_STREAM_ENABLED_DIR="/etc/nginx/stream-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
SSL_CERTS_BASE_DIR="/etc/ssl"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
NGINX_ERROR_LOG="/var/log/nginx/error.log"

IS_INTERACTIVE_MODE="true"
VPS_IP=""; VPS_IPV6=""; ACME_BIN=""
SCRIPT_PATH=$(realpath "$0")

# ==============================================================================
# SECTION: 核心工具函数与信号捕获
# ==============================================================================

OP_ID=""
LOCK_FILE_HTTP="/var/lock/nginx_ssl_manager_http.lock"
LOCK_FILE_TCP="/var/lock/nginx_ssl_manager_tcp.lock"
LOCK_FILE_CERT="/var/lock/nginx_ssl_manager_cert.lock"
LOCK_FD_HTTP=9
LOCK_FD_TCP=10
LOCK_FD_CERT=11
LAST_CERT_ELAPSED=""
LAST_CERT_CERT=""
LAST_CERT_KEY=""

_generate_op_id() { OP_ID="$(date +%Y%m%d_%H%M%S)_$$_$RANDOM"; }

_is_valid_var_name() {
    local name="${1:-}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

sanitize_noninteractive_flag() {
    case "${JB_NONINTERACTIVE:-false}" in
        true|false) return 0 ;;
        *)
            log_warn "JB_NONINTERACTIVE 值非法: ${JB_NONINTERACTIVE}，已回退为 false"
            JB_NONINTERACTIVE="false"
            return 0
            ;;
    esac
}

require_sudo_or_die() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            return 0
        fi
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_error "非交互模式下无法获取 sudo 权限"
            exit 1
        fi
        return 0
    fi
    log_error "未安装 sudo，无法继续"
    exit 1
}

cleanup() {
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
    rm -f /tmp/tg_payload_*.json 2>/dev/null || true
    _release_lock "$LOCK_FILE_HTTP" "${LOCK_OWNER_PID_HTTP:-}"
    _release_lock "$LOCK_FILE_TCP" "${LOCK_OWNER_PID_TCP:-}"
    _release_lock "$LOCK_FILE_CERT" "${LOCK_OWNER_PID_CERT:-}"
}

err_handler() {
    local exit_code="${1:-1}" line_no="${2:-}"
    log_error "发生错误 (exit=${exit_code}) 于行 ${line_no}。"
}

_on_int() {
    printf '%b' "\n${RED}检测到中断信号,已安全取消操作并清理残留文件。${NC}\n"
    cleanup; exit 130
}

_sanitize_log_file() {
    local candidate="${1:-}"
    if [ -z "$candidate" ]; then return 1; fi
    if [[ "$candidate" != /* ]]; then return 1; fi
    if ! _is_path_in_allowed_roots "$candidate"; then return 1; fi
    printf '%s\n' "$candidate"
}

_resolve_log_file() {
    local target=""
    if [ -n "${LOG_FILE:-}" ]; then
        local sanitized
        sanitized=$(_sanitize_log_file "$LOG_FILE" 2>/dev/null || true)
        if [ -n "$sanitized" ]; then
            target="$sanitized"
        fi
    fi
    if [ -z "$target" ]; then
        target="$LOG_FILE_DEFAULT"
    fi

    local dir
    dir=$(dirname "$target")
    if mkdir -p "$dir" 2>/dev/null && touch "$target" 2>/dev/null; then
        LOG_FILE="$target"; return 0
    fi
    LOG_FILE="$LOG_FILE_FALLBACK"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
}

_acquire_lock() {
    local lock_file="${1:-}"
    local lock_fd_var="${2:-}"
    if [ -z "$lock_file" ] || [ -z "$lock_fd_var" ]; then return 1; fi
    if ! _is_valid_var_name "$lock_fd_var"; then
        log_error "锁 FD 变量名非法: $lock_fd_var"
        return 1
    fi
    local lock_dir
    lock_dir=$(dirname "$lock_file")
    if ! mkdir -p "$lock_dir" 2>/dev/null; then
        lock_file="$LOG_FILE_FALLBACK.lock"
    fi
    local lock_fd
    exec {lock_fd}>"$lock_file" || return 1
    if ! flock -n "$lock_fd"; then
        log_error "已有实例在运行,退出。"
        return 1
    fi
    printf -v "$lock_fd_var" '%s' "$lock_fd"
    printf '%s\n' "$$" > "$lock_file"
    return 0
}

_release_lock() {
    local lock_file="${1:-}"
    local lock_pid="${2:-}"
    if [ -z "$lock_file" ] || [ -z "$lock_pid" ]; then return 0; fi
    if [ -f "$lock_file" ] && [ "$(<"$lock_file" 2>/dev/null || true)" = "$lock_pid" ]; then
        rm -f "$lock_file" 2>/dev/null || true
    fi
}

_mark_nginx_conf_changed() {
    NGINX_CONF_GEN=$((NGINX_CONF_GEN + 1))
}

_nginx_test_cached() {
    local now
    now=$(date +%s)
    local max_age
    max_age="$NGINX_TEST_CACHE_MAX_AGE_SECS"
    if ! [[ "$max_age" =~ ^[0-9]+$ ]]; then max_age=60; fi
    if [ "${NGINX_TEST_CACHE_ENABLED}" != "true" ]; then
        nginx -t >/dev/null 2>&1
        return $?
    fi
    if [ "$NGINX_TEST_CACHE_GEN" -eq "$NGINX_CONF_GEN" ] && [ $((now - NGINX_TEST_CACHE_TS)) -le "$max_age" ]; then
        return "$NGINX_TEST_CACHE_RESULT"
    fi
    nginx -t >/dev/null 2>&1
    NGINX_TEST_CACHE_RESULT=$?
    NGINX_TEST_CACHE_GEN=$NGINX_CONF_GEN
    NGINX_TEST_CACHE_TS=$now
    return "$NGINX_TEST_CACHE_RESULT"
}

acquire_http_lock() {
    if _acquire_lock "$LOCK_FILE_HTTP" "LOCK_FD_HTTP"; then
        LOCK_OWNER_PID_HTTP="$$"
        return 0
    fi
    return 1
}

acquire_tcp_lock() {
    if _acquire_lock "$LOCK_FILE_TCP" "LOCK_FD_TCP"; then
        LOCK_OWNER_PID_TCP="$$"
        return 0
    fi
    return 1
}

acquire_cert_lock() {
    if _acquire_lock "$LOCK_FILE_CERT" "LOCK_FD_CERT"; then
        LOCK_OWNER_PID_CERT="$$"
        return 0
    fi
    return 1
}

run_cmd() {
    local timeout_secs="${1:-15}"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_secs" "$@"
    else
        "$@"
    fi
}

trap cleanup EXIT
trap 'err_handler $? $LINENO' ERR
trap '_on_int' INT TERM

_log_level_to_num() {
    case "${1:-INFO}" in
        ERROR) printf '%s\n' "0" ;;
        WARN) printf '%s\n' "1" ;;
        INFO) printf '%s\n' "2" ;;
        SUCCESS) printf '%s\n' "3" ;;
        DEBUG) printf '%s\n' "4" ;;
        *) printf '%s\n' "2" ;;
    esac
}

_log_should_emit() {
    local msg_level="${1:-INFO}"
    local current_level="${LOG_LEVEL:-$LOG_LEVEL_DEFAULT}"
    local msg_num
    local cur_num
    msg_num=$(_log_level_to_num "$msg_level")
    cur_num=$(_log_level_to_num "$current_level")
    [ "$msg_num" -le "$cur_num" ]
}

_log_emit() {
    local level="${1:-INFO}" message="${2:-}"
    local ts op_tag
    ts="$(date +"%Y-%m-%d %H:%M:%S")"
    op_tag="${OP_ID:-NA}"
    local plain_line="[${ts}] [${level}] [op:${op_tag}] ${message}"
    if ! _log_should_emit "$level"; then return 0; fi
    _resolve_log_file
    printf '%s\n' "$plain_line" >> "$LOG_FILE"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        case "$level" in
            ERROR|WARN) printf '%s\n' "$plain_line" >&2 ;;
            *) printf '%s\n' "$plain_line" ;;
        esac
    fi
}

log_info() { _log_emit "INFO" "${1:-}" "stdout"; }
log_warn() { _log_emit "WARN" "${1:-}" "stderr"; }
log_error() { _log_emit "ERROR" "${1:-}" "stderr"; }
log_success() { _log_emit "SUCCESS" "${1:-}" "stdout"; }

log_message() {
    local level="${1:-INFO}" message="${2:-}"
    case "$level" in
        INFO) log_info "$message";;
        SUCCESS) log_success "$message";;
        WARN) log_warn "$message";;
        ERROR) log_error "$message";;
        *) log_info "$message";;
    esac
}

press_enter_to_continue() {
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
        log_warn "非交互模式：跳过等待"
        return 0
    fi
    read -r -p "$(printf '%b' "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty || true
}

prompt_menu_choice() {
    local range="${1:-}"; local allow_empty="${2:-false}"; local prompt_text="${BRIGHT_YELLOW}选项 [${range}]${NC} (Enter 返回): "
    local choice
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
        if [ "$allow_empty" = "true" ]; then printf '%b' "\n"; return 0; fi
        log_message ERROR "非交互模式无法选择菜单"
        return 1
    fi
    while true; do
        read -r -p "$(printf '%b' "$prompt_text")" choice < /dev/tty || return 1
        if [ -z "$choice" ]; then
            if [ "$allow_empty" = "true" ]; then printf '%b' "\n"; return 0; fi
            printf '%b' "${YELLOW}请选择一个选项。${NC}\n" >&2; continue
        fi
        if [[ "$choice" =~ ^[0-9A-Za-z]+$ ]]; then printf '%s\n' "$choice"; return 0; fi
    done
}

prompt_input() {
    local prompt="${1:-}" default="${2:-}" regex="${3:-}" error_msg="${4:-}" allow_empty="${5:-false}" visual_default="${6:-}"
    while true; do
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
            val="$default"
            if [[ -z "$val" && "$allow_empty" = "false" ]]; then log_message ERROR "非交互缺失: $prompt"; return 1; fi
        else
            local disp=""
            if [ -n "$visual_default" ]; then
                disp=" [默认: ${visual_default}]"
            elif [ -n "$default" ]; then
                disp=" [默认: ${default}]"
            fi
            printf '%b' "${BRIGHT_YELLOW}${prompt}${NC}${disp}: " >&2
            read -r val < /dev/tty || return 1
            val=${val:-$default}
        fi
        if [[ -z "$val" && "$allow_empty" = "true" ]]; then printf '%b' "\n"; return 0; fi
        if [[ -z "$val" ]]; then log_message ERROR "输入不能为空"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        if [[ -n "$regex" && ! "$val" =~ $regex ]]; then log_message ERROR "${error_msg:-格式错误}"; [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1; continue; fi
        printf '%s\n' "$val"; return 0
    done
}

_prompt_secret() {
    local prompt="${1:-}" val=""
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
        log_message ERROR "非交互模式禁止读取密文输入"
        return 1
    fi
    printf '%b' "${BRIGHT_YELLOW}${prompt} (无屏幕回显): ${NC}" >&2
    read -rs val < /dev/tty || return 1
    printf '%b' "\n" >&2; printf '%s\n' "$val"
}


_is_hook_whitelisted() {
    local cmd="${1:-}"
    local item
    for item in "${HOOK_WHITELIST[@]}"; do
        if [ "$cmd" = "$item" ]; then return 0; fi
    done
    return 1
}

_validate_hook_command() {
    local cmd="${1:-}"
    if [ -z "$cmd" ]; then return 0; fi
    if _is_hook_whitelisted "$cmd"; then return 0; fi
    if [ "$ALLOW_UNSAFE_HOOKS" = "true" ]; then
        if [ "$IS_INTERACTIVE_MODE" != "true" ]; then
            log_message ERROR "非交互模式禁止不安全 Hook: $cmd"
            return 1
        fi
        if confirm_or_cancel "检测到不安全 Hook: '$cmd'，是否继续执行?" "n"; then
            return 0
        fi
        log_message ERROR "已取消不安全 Hook 执行。"
        return 1
    fi
    log_message ERROR "拒绝执行自定义 Hook 命令(未允许不安全 Hook): $cmd"
    log_message INFO "如确需执行,请设置环境变量 ALLOW_UNSAFE_HOOKS=true"
    return 1
}

_mask_string() {
    local str="${1:-}"; local len=${#str}
    if [ "$len" -le 6 ]; then printf '%s\n' "***"; else printf '%s\n' "${str:0:2}***${str: -3}"; fi
}

_load_tg_conf() {
    local f="$TG_CONF_FILE"
    if [ ! -f "$f" ]; then return 1; fi
    local mode
    mode=$(stat -c '%a' "$f" 2>/dev/null || printf '%s' "")
    local owner
    owner=$(stat -c '%U:%G' "$f" 2>/dev/null || printf '%s' "")
    if [ "$owner" != "root:root" ]; then
        log_message ERROR "TG 配置属主/属组不安全: $owner"
        return 1
    fi
    if [ -n "$mode" ] && [ "$mode" -gt 600 ]; then
        log_message ERROR "TG 配置权限过宽: $mode"
        return 1
    fi
    local token chat server
    token=$(grep -E '^TG_BOT_TOKEN=' "$f" | head -n1 | cut -d= -f2- | tr -d '"' || true)
    chat=$(grep -E '^TG_CHAT_ID=' "$f" | head -n1 | cut -d= -f2- | tr -d '"' || true)
    server=$(grep -E '^SERVER_NAME=' "$f" | head -n1 | cut -d= -f2- | tr -d '"' || true)
    if [ -z "$token" ] || [ -z "$chat" ]; then
        log_message ERROR "TG 配置内容不完整"
        return 1
    fi
    TG_BOT_TOKEN="$token"
    TG_CHAT_ID="$chat"
    SERVER_NAME="$server"
    return 0
}

_mask_ip() {
    local ip="${1:-}"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        IFS='.' read -r a b _c _d <<< "$ip"
        printf '%s\n' "${a}.${b}.*.*"
    elif [[ "$ip" =~ .*:.* ]]; then
        IFS=':' read -r a b _rest <<< "$ip"
        printf '%s\n' "${a}:${b}::***"
    else
        printf '%s\n' "***"
    fi
}

confirm_or_cancel() {
    local prompt_text="${1:-}" default_yesno="${2:-y}"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local hint="([y]/n)"; [ "$default_yesno" = "n" ] && hint="(y/[N])"
        local c
        read -r -p "$(printf '%b' "${BRIGHT_YELLOW}${prompt_text} ${hint}: ${NC}")" c < /dev/tty || return 1
        if [ -z "$c" ]; then
            [ "$default_yesno" = "y" ] && return 0 || return 1
        fi
        case "$c" in
            y|Y) return 0;;
            n|N) return 1;;
            *) return 1;;
        esac
    fi
    log_message ERROR "非交互需确认: '$prompt_text',已取消。"; return 1
}

_get_cf_allow_file() {
    local f="/etc/nginx/snippets/cf_allow.conf"
    if [ -f "$f" ] && [ -s "$f" ]; then printf '%s\n' "$f"; return 0; fi
    printf '%s\n' ""; return 1
}

_is_cloudflare_ip() {
    local ip="${1:-}" cf_file
    cf_file=$(_get_cf_allow_file) || return 1
    if [ -z "$ip" ]; then return 1; fi
    grep -q "^allow ${ip}/" "$cf_file"
}

_domain_uses_cloudflare() {
    local domain="${1:-}" ip
    if [ -z "$domain" ]; then return 1; fi
    while read -r ip; do
        [ -z "$ip" ] && continue
        if _is_cloudflare_ip "$ip"; then return 0; fi
    done < <(getent ahosts "$domain" | awk '{print $1}' | sort -u)
    return 1
}

_prompt_update_cf_ips_if_missing() {
    if _get_cf_allow_file >/dev/null; then return 0; fi
    if confirm_or_cancel "未检测到 Cloudflare IP 库，是否现在更新?" "n"; then
        _update_cloudflare_ips || return 1
    fi
    return 0
}


_detect_web_service() {
    if ! command -v systemctl &>/dev/null; then return; fi
    local svc; for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then printf '%s\n' "$svc"; return; fi
    done
}

_is_safe_path() {
    local p="${1:-}"
    if [ -z "$p" ]; then return 1; fi
    if [[ "$p" =~ (^|/)\.\.(\/|$) ]]; then return 1; fi
    if [[ "$p" =~ [[:space:]] ]]; then return 1; fi
    return 0
}

_is_path_in_allowed_roots() {
    local p="${1:-}"
    if ! _is_safe_path "$p"; then return 1; fi
    local real_p
    real_p=$(realpath -m "$p" 2>/dev/null || true)
    if [ -z "$real_p" ]; then return 1; fi
    local root
    for root in "${SAFE_PATH_ROOTS[@]}"; do
        if [[ "$real_p" == "$root" || "$real_p" == "$root"/* ]]; then
            return 0
        fi
    done
    return 1
}

_require_safe_path() {
    local p="${1:-}"
    local purpose="${2:-操作}"
    if ! _is_path_in_allowed_roots "$p"; then
        log_message ERROR "不安全路径(${purpose}): $p"
        return 1
    fi
    return 0
}

_is_valid_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

_require_valid_domain() {
    local d="${1:-}"
    if ! _is_valid_domain "$d"; then
        log_message ERROR "域名格式无效: $d"
        return 1
    fi
    return 0
}

_is_valid_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

_require_valid_port() {
    local p="${1:-}"
    if ! _is_valid_port "$p"; then
        log_message ERROR "端口无效: $p"
        return 1
    fi
    return 0
}

_is_valid_target() {
    local t="${1:-}"
    [[ "$t" =~ ^[A-Za-z0-9.-]+:[0-9]+(,[A-Za-z0-9.-]+:[0-9]+)*$ ]]
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_message ERROR "请使用 root 用户运行此操作。"
        return 1
    fi
    return 0
}

check_os_compatibility() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
            printf '%b' "${RED}⚠️ 警告: 检测到非 Debian/Ubuntu 系统 ($NAME)。${NC}\n"
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                if ! confirm_or_cancel "是否尝试继续?"; then return 1; fi
            else
                log_message WARN "非 Debian 系统,尝试强制运行..."
            fi
        fi
    fi
    return 0
}

# ==============================================================================
# SECTION: UI 渲染函数 (兼容中文宽度)
# ==============================================================================

generate_line() {
    local len=${1:-40}; local char=${2:-"─"}
    if [ "$len" -le 0 ]; then printf '%b' "\n"; return; fi
    printf "%${len}s" "" | sed "s/ /$char/g"
}

_get_visual_width() {
    local text="$1"
    local plain_text
    plain_text=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    if [ -z "$plain_text" ]; then printf '%s\n' "0"; return; fi
    if command -v python3 &>/dev/null; then
        python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<< "$plain_text" 2>/dev/null || printf '%s\n' "${#plain_text}"
    elif command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
        printf '%s' "$plain_text" | wc -m
    else
        printf '%s' "$plain_text" | awk '{print length}'
    fi
}

_render_menu() {
    local title="$1"; shift; local -a lines=("$@")
    local max_content_width=0
    local title_width=$(_get_visual_width "$title")
    max_content_width=$title_width
    for line in "${lines[@]}"; do
        local current_line_visual_width=$(_get_visual_width "$line")
        if [ "$current_line_visual_width" -gt "$max_content_width" ]; then
            max_content_width="$current_line_visual_width"
        fi
    done
    local box_inner_width=$max_content_width
    if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi
    
    printf '%b' "\n"
    printf '%b' "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}\n"
    if [ -n "$title" ]; then
        local padding_total=$((box_inner_width - title_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        printf '%b' "${GREEN}│${NC}$(printf '%*s' "$padding_left")${BOLD}${title}${NC}$(printf '%*s' "$padding_right")${GREEN}│${NC}\n"
    fi
    printf '%b' "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}\n"
    
    for line in "${lines[@]}"; do printf '%b' "${line}\n"; done
    
    local box_total_physical_width=$(( box_inner_width + 2 ))
    printf '%b' "${GREEN}$(generate_line "$box_total_physical_width" "─")${NC}\n"
}

_center_text() {
    local text="$1"
    local width="${2:-10}"
    local len=${#text}
    if [ -z "$text" ]; then printf "%${width}s" ""; return; fi
    if (( len >= width )); then printf "%-${width}.${width}s" "$text"; else
        local pad=$(( width - len ))
        local left=$(( pad / 2 ))
        local right=$(( pad - left ))
        printf "%${left}s%s%${right}s" "" "$text" ""
    fi
}

_draw_dashboard() {
    _generate_op_id
    local nginx_v=$(nginx -v 2>&1 | awk -F/ '{print $2}' | cut -d' ' -f1)
    local uptime_raw=$(uptime -p | sed 's/up //')
    local count=$(jq '. | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "0")
    local tcp_count=$(jq '. | length' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "0")
    local warn_count=0
    if [ -f "$PROJECTS_METADATA_FILE" ]; then warn_count=$(jq '[.[] | select(.cert_file)] | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "0"); fi
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs | cut -d, -f1-3 2>/dev/null || printf '%s' "unknown")
    
    local title="Nginx 管理面板"
    local line1="Nginx: ${nginx_v} | 运行: ${uptime_raw} | 负载: ${load}"
    local line2="HTTP : ${count} 个 | TCP : ${tcp_count} 个 | 告警 : ${warn_count}"
    
    local max_width=$(_get_visual_width "$title"); local w1=$(_get_visual_width "$line1"); local w2=$(_get_visual_width "$line2")
    [ "$w1" -gt "$max_width" ] && max_width=$w1; [ "$w2" -gt "$max_width" ] && max_width=$w2; [ "$max_width" -lt 50 ] && max_width=50
    
    printf '%b' "\n"
    printf '%b' "${GREEN}╭$(generate_line "$max_width" "─")╮${NC}\n"
    local title_pad_total=$((max_width - $(_get_visual_width "$title"))); local title_pad_left=$((title_pad_total / 2)); local title_pad_right=$((title_pad_total - title_pad_left))
    printf '%b' "${GREEN}│${NC}$(printf '%*s' "$title_pad_left")${BOLD}${title}${NC}$(printf '%*s' "$title_pad_right")${GREEN}│${NC}\n"
    printf '%b' "${GREEN}╰$(generate_line "$max_width" "─")╯${NC}\n"
    local pad1=$((max_width - w1)); local pad2=$((max_width - w2))
    printf '%b' " ${line1}$(printf '%*s' "$pad1")\n"
    printf '%b' " ${line2}$(printf '%*s' "$pad2")\n"
    printf '%b' "${GREEN}$(generate_line $((max_width + 2)) "─")${NC}\n"
}

get_vps_ip() {
    if [ -z "$VPS_IP" ]; then
    VPS_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || printf '%s' "")
    VPS_IPV6=$(curl -s -6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || printf '%s' "")
    fi
}

# ==============================================================================
# SECTION: DNS 预检模块
# ==============================================================================

_check_dns_resolution() {
    local domain="${1:-}"
    log_message INFO "正在预检域名解析: $domain ..."
    get_vps_ip
    local resolved_ips=""
    if command -v dig >/dev/null 2>&1; then
        resolved_ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ' | xargs)
    elif command -v host >/dev/null 2>&1; then
        resolved_ips=$(host -t A "$domain" 2>/dev/null | grep "has address" | awk '{print $NF}' | tr '\n' ' ' | xargs)
    else log_message WARN "未安装 dig/host 工具,跳过 DNS 预检。"; return 0; fi

    if [ -z "$resolved_ips" ]; then
        log_message ERROR "❌ DNS 解析失败: 域名 $domain 当前未解析到任何 IP 地址。"
        printf '%b' "${RED}请先前往您的 DNS 服务商添加一条 A 记录,指向本机 IP: ${VPS_IP}${NC}\n"
        if ! confirm_or_cancel "DNS 未生效,是否强制继续申请?"; then return 1; fi; return 0
    fi
    if [[ " $resolved_ips " == *" $VPS_IP "* ]]; then log_message SUCCESS "✅ DNS 校验通过: $domain --> $VPS_IP"
    else
        log_message WARN "⚠️  DNS 解析异常!"
        printf '%b' "${YELLOW}本机 IP : ${VPS_IP}${NC}\n"
        printf '%b' "${YELLOW}解析 IP : ${resolved_ips}${NC}\n"
        printf '%b' "${RED}解析结果不包含本机 IP。如果您开启了 Cloudflare CDN (橙色云),这是正常的,请选择 'y' 继续。${NC}\n"
        if ! confirm_or_cancel "解析结果不匹配,是否强制继续?"; then return 1; fi
    fi

    if [ -n "$resolved_ips" ]; then
        if _prompt_update_cf_ips_if_missing; then
            if ! _domain_uses_cloudflare "$domain"; then
                if [ "${CF_STRICT_MODE_CURRENT:-n}" = "y" ]; then
                    printf '%b' "${YELLOW}检测为灰云/非 CDN，严格防御可能导致 403/521。${NC}\n"
                    if confirm_or_cancel "是否立即关闭严格防御?" "n"; then
                        CF_STRICT_MODE_CURRENT="n"
                    fi
                fi
            fi
        fi
    fi
    return 0
}

# ==============================================================================
# SECTION: TG 机器人通知模块
# ==============================================================================

setup_tg_notifier() {
    _generate_op_id
    local -a menu_lines=(); local curr_token="" curr_chat="" curr_name=""
    if [ -f "$TG_CONF_FILE" ]; then
        _load_tg_conf || { log_message ERROR "TG 配置读取失败"; return; }
        curr_token="${TG_BOT_TOKEN:-}"; curr_chat="${TG_CHAT_ID:-}"; curr_name="${SERVER_NAME:-}"
        menu_lines+=("${GREEN}当前已配置:${NC}"); menu_lines+=(" 机器人 Token : $(_mask_string "$curr_token")"); menu_lines+=(" 会话 ID      : $(_mask_string "$curr_chat")"); menu_lines+=(" 服务器备注   : $curr_name")
    fi
    _render_menu "Telegram 机器人通知设置" "${menu_lines[@]}"
    if [ -f "$TG_CONF_FILE" ]; then if ! confirm_or_cancel "是否要重新配置或关闭通知?"; then return; fi; fi
    local action; printf '%b' "1. 开启/修改通知配置\n"; printf '%b' "2. 清除配置 (关闭通知)\n"; printf '%b' "\n"
    if ! action=$(prompt_menu_choice "1-2" "true"); then return; fi
    if [ "$action" = "2" ]; then rm -f "$TG_CONF_FILE"; log_message SUCCESS "Telegram 通知已关闭。"; return; fi
    [ "$action" != "1" ] && return
    local real_tk_default="${curr_token:-}"; local vis_tk_default=""; [ -n "$curr_token" ] && vis_tk_default="$(_mask_string "$curr_token")" || vis_tk_default="***"
    local tk; if ! tk=$(prompt_input "请输入 Bot Token (如 1234:ABC...)" "$real_tk_default" "" "" "false" "$vis_tk_default"); then return; fi
    local real_cid_default="${curr_chat:-}"; local vis_cid_default=""; [ -n "$curr_chat" ] && vis_cid_default="$(_mask_string "$curr_chat")" || vis_cid_default="无"
    local cid; if ! cid=$(prompt_input "请输入 Chat ID (如 123456789 或 -100123...)" "$real_cid_default" "^-?[0-9]+$" "格式错误,只能包含数字或负号" "false" "$vis_cid_default"); then return; fi
    local sname; if ! sname=$(prompt_input "请输入这台服务器的备注 (如 日本主机)" "$curr_name" "" "" "false"); then return; fi
    cat > "$TG_CONF_FILE" << EOF
TG_BOT_TOKEN="${tk}"
TG_CHAT_ID="${cid}"
SERVER_NAME="${sname}"
EOF
    chmod 600 "$TG_CONF_FILE"
    log_message INFO "正在发送测试消息 (同步模式)..."
    if _send_tg_notify "success" "测试域名" "恭喜!您的 Telegram 通知系统已成功挂载。" "$sname" "true"; then log_message SUCCESS "测试消息发送成功!请检查 Telegram 客户端。"
    else log_message ERROR "测试消息发送失败!请检查上方的错误提示。"; if ! confirm_or_cancel "是否保留此配置?"; then rm -f "$TG_CONF_FILE"; fi; fi
}

_send_tg_notify() {
    local status_type="${1:-}" domain="${2:-}" detail_msg="${3:-}" sname="${4:-}" debug="${5:-false}"
    _generate_op_id
    if [ ! -f "$TG_CONF_FILE" ]; then return 0; fi
    if ! _load_tg_conf; then
        log_message WARN "TG 配置读取失败,已跳过通知。"
        return 0
    fi
    if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then return 0; fi
    get_vps_ip; local display_ip=$(_mask_ip "$VPS_IP"); local display_ipv6=$(_mask_ip "$VPS_IPV6")
    local title="" status_text="" emoji=""
    if [ "$status_type" == "success" ]; then title="证书续期成功"; status_text="✅ 续订完成"; emoji="✅"
    else title="异常警报"; status_text="⚠️ 续订失败"; emoji="⚠️"
    fi
    local ipv6_line=""; [ -n "$VPS_IPV6" ] && ipv6_line=$'\n'"🌐<b>IPv6:</b> <code>${display_ipv6}</code>"
    local current_time
    current_time=$(date "+%Y-%m-%d %H:%M:%S (%Z)")
    local text_body
    text_body=$(cat <<EOF
<b>${emoji} ${title}</b>

🖥<b>服务器:</b> ${sname:-未知主机}
🌐<b>IPv4:</b> <code>${display_ip:-未知}</code>${ipv6_line}

📄<b>状态:</b> ${status_text}
🎯<b>域名:</b> <code>${domain}</code>
⌚<b>时间:</b> ${current_time}

📃<b>详细描述:</b>
<i>${detail_msg}</i>
EOF
)
    local button_url="http://${domain}/"; [ "$debug" == "true" ] && button_url="https://core.telegram.org/bots/api"
    local kb_json='{"inline_keyboard":[[{"text":"📊 访问实例","url":"'"$button_url"'"}]]}'
    local payload_file
    payload_file=$(mktemp /tmp/tg_payload_XXXXXX.json)
    chmod 600 "$payload_file"
    if ! jq -n --arg cid "$TG_CHAT_ID" --arg txt "$text_body" --argjson kb "$kb_json" '{chat_id: $cid, text: $txt, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: $kb}' > "$payload_file"; then log_message ERROR "构造 TG JSON 失败。"; rm -f "$payload_file"; return 1; fi
    local curl_cmd=(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" -H "Content-Type: application/json" -d @"$payload_file" --connect-timeout 10 --max-time 15)
    local ret_code=0
    local resp=""
    if [ "$debug" == "true" ]; then
        printf '%b' "${CYAN}>>> 发送请求到 Telegram API...${NC}\n"
        resp=$("${curl_cmd[@]}" 2>&1) || ret_code=$?
        printf '%b' "${CYAN}<<< Telegram 响应:${NC}\n${resp}\n"
        if [ $ret_code -ne 0 ] || ! jq -e '.ok' >/dev/null 2>&1 <<< "$resp"; then ret_code=1; fi
    else
        resp=$(run_cmd 20 "${curl_cmd[@]}" 2>&1) || ret_code=$?
        if [ $ret_code -ne 0 ] || ! jq -e '.ok' >/dev/null 2>&1 <<< "$resp"; then ret_code=1; fi
    fi
    if [ $ret_code -ne 0 ]; then log_message WARN "Telegram 通知发送失败 (已脱敏)。"; _mask_sensitive_data <<< "$resp" >&2; fi
    rm -f "$payload_file"; return $ret_code
}

# ==============================================================================
# SECTION: 环境初始化与依赖 (优化版)
# ==============================================================================

check_dependencies() {
    local -a missing=()
    local cmd

    for cmd in nginx curl socat openssl jq idn nano flock timeout awk sed grep sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1; then
        missing+=("dnsutils")
    fi

    if ! command -v ls >/dev/null 2>&1 || ! command -v date >/dev/null 2>&1 || ! command -v cp >/dev/null 2>&1 || ! command -v realpath >/dev/null 2>&1; then
        missing+=("coreutils")
    fi

    if (( ${#missing[@]} > 0 )); then
        log_message WARN "缺失依赖: ${missing[*]}"
        return 1
    fi
    return 0
}

install_dependencies() {
    if [ -f "$DEPS_MARK_FILE" ]; then return 0; fi
    local -a deps=(nginx curl socat openssl jq idn dnsutils nano coreutils util-linux)
    local -a missing_deps=()
    local pkg
    for pkg in "${deps[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then missing_deps+=("$pkg"); fi
    done
    if (( ${#missing_deps[@]} > 0 )); then
        log_message WARN "检测到缺失依赖: ${missing_deps[*]}，正在批量安装..."
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_message ERROR "非交互模式禁止自动安装依赖"
            return 1
        fi
        if run_cmd 60 sudo -n apt-get update >/dev/null 2>&1 || run_cmd 60 apt-get update >/dev/null 2>&1; then
            if run_cmd 120 sudo -n apt-get install -y "${missing_deps[@]}" >/dev/null 2>&1 || run_cmd 120 apt-get install -y "${missing_deps[@]}" >/dev/null 2>&1; then log_message SUCCESS "依赖安装成功。"
            else log_message ERROR "依赖安装失败"; return 1; fi
        else log_message ERROR "apt-get update 失败"; return 1; fi
    fi
    touch "$DEPS_MARK_FILE"; return 0
}

_setup_logrotate() {
    if [ ! -d /etc/logrotate.d ]; then return 0; fi
    local log_path
    log_path=$(_sanitize_log_file "$LOG_FILE" 2>/dev/null || true)
    if [ -z "$log_path" ]; then log_path="$LOG_FILE_DEFAULT"; fi
    if [ ! -f /etc/logrotate.d/nginx ]; then
        log_message INFO "自动补全 Nginx 缺失的日志切割配置..."
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_message ERROR "非交互模式禁止写入 logrotate 配置"
            return 1
        fi
        cat > /etc/logrotate.d/nginx << 'EOF'
/var/log/nginx/*.log {
    daily missingok rotate 14 compress delaycompress notifempty create 0640 root root sharedscripts postrotate if [ -f /var/run/nginx.pid ]; then kill -USR1 `cat /var/run/nginx.pid`; fi endscript
}
EOF
    fi
    if [ ! -f /etc/logrotate.d/nginx_ssl_manager ]; then
        log_message INFO "注入本面板运行日志 切割规则..."
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_message ERROR "非交互模式禁止写入 logrotate 配置"
            return 1
        fi
        cat > /etc/logrotate.d/nginx_ssl_manager << EOF
${log_path} { weekly missingok rotate 12 compress delaycompress notifempty create 0644 root root }
EOF
    fi
}

_parse_args() {
    IS_INTERACTIVE_MODE="true"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --cron|--non-interactive)
                IS_INTERACTIVE_MODE="false"
                ;;
        esac
    done
}

validate_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --cron|--non-interactive|--check)
                ;;
            *)
                log_message ERROR "未知参数: $arg"
                return 1
                ;;
        esac
    done
    return 0
}

initialize_environment() {
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
    if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
    export PATH="$(dirname "$ACME_BIN"):$PATH"
    
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR" "$BACKUP_DIR" "$CONF_BACKUP_DIR"
    mkdir -p "$JSON_BACKUP_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$NGINX_STREAM_ENABLED_DIR"
    _renew_fail_db_init
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
        if ! _require_safe_path "$PROJECTS_METADATA_FILE" "初始化项目配置"; then return 1; fi
        printf '%s\n' "[]" > "$PROJECTS_METADATA_FILE"
    fi
    if [ ! -f "$TCP_PROJECTS_METADATA_FILE" ] || ! jq -e . "$TCP_PROJECTS_METADATA_FILE" > /dev/null 2>&1; then
        if ! _require_safe_path "$TCP_PROJECTS_METADATA_FILE" "初始化 TCP 配置"; then return 1; fi
        printf '%s\n' "[]" > "$TCP_PROJECTS_METADATA_FILE"
    fi
    if [ -f "$GZIP_DISABLE_MARK" ] && [ -f "/etc/nginx/conf.d/gzip_optimize.conf" ]; then
        if _require_safe_path "/etc/nginx/conf.d/gzip_optimize.conf" "删除 gzip 配置"; then
            rm -f "/etc/nginx/conf.d/gzip_optimize.conf"
        fi
    fi
    if [ -f "/etc/nginx/conf.d/gzip_optimize.conf" ]; then
        if ! _nginx_test_cached; then
            if nginx -t 2>&1 | grep -q "gzip"; then
                if _require_safe_path "/etc/nginx/conf.d/gzip_optimize.conf" "删除 gzip 配置"; then
                    rm -f "/etc/nginx/conf.d/gzip_optimize.conf"
                fi
                touch "$GZIP_DISABLE_MARK"
                log_message WARN "清理与主配置冲突的 Gzip 文件，并禁用自动恢复。"
            fi
        fi
    fi
    if [ -f /etc/nginx/nginx.conf ] && ! grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_message ERROR "非交互模式禁止修改 /etc/nginx/nginx.conf"
            return 1
        fi
        cat >> /etc/nginx/nginx.conf << EOF

# TCP/UDP Stream Proxy Auto-injected
stream { include ${NGINX_STREAM_ENABLED_DIR}/*.conf; }
EOF
        systemctl reload nginx || true
    fi
    _setup_logrotate
}

install_acme_sh() {
    _generate_op_id
    if [ -f "$ACME_BIN" ]; then return 0; fi
    log_message WARN "acme.sh 未安装,开始安装..."
    local email; if ! email=$(prompt_input "注册邮箱" "" "" "" "true"); then return 1; fi
    local email_arg=""
    if [ -n "$email" ]; then email_arg="email=$email"; fi
    if [[ "$ACME_SH_INSTALL_URL" != https://* ]]; then
        log_message ERROR "acme.sh 安装地址必须为 https://"
        return 1
    fi
    if [ -n "$ACME_SH_INSTALL_SHA256" ] && ! [[ "$ACME_SH_INSTALL_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        log_message ERROR "acme.sh 安装脚本 SHA256 格式无效"
        return 1
    fi
    if [ -n "$ACME_SH_INSTALL_SHA256" ] && ! command -v sha256sum >/dev/null 2>&1; then
        log_message ERROR "缺少 sha256sum,无法校验安装脚本"
        return 1
    fi
    local install_script
    install_script=$(mktemp /tmp/acme_install.XXXXXX)
    chmod 600 "$install_script"
    if ! run_cmd 30 curl -fsSL "$ACME_SH_INSTALL_URL" -o "$install_script"; then
        rm -f "$install_script"
        log_message ERROR "acme.sh 安装脚本下载失败"
        return 1
    fi
    if [ -n "$ACME_SH_INSTALL_SHA256" ]; then
        local got_sha
        got_sha=$(sha256sum "$install_script" | awk '{print $1}')
        if [ "$got_sha" != "$ACME_SH_INSTALL_SHA256" ]; then
            rm -f "$install_script"
            log_message ERROR "acme.sh 安装脚本校验失败"
            return 1
        fi
    fi
    if [ -n "$email_arg" ]; then
        sh "$install_script" "$email_arg" || { rm -f "$install_script"; log_message ERROR "acme.sh 安装失败"; return 1; }
    else
        sh "$install_script" || { rm -f "$install_script"; log_message ERROR "acme.sh 安装失败"; return 1; }
    fi
    rm -f "$install_script"
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1)
    if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
    "$ACME_BIN" --upgrade --auto-upgrade >/dev/null 2>&1 || true
    local cron_tmp
    cron_tmp=$(mktemp /tmp/cron.bak.XXXXXX)
    chmod 600 "$cron_tmp"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > "$cron_tmp" || true
    local cron_log
    cron_log=$(_sanitize_log_file "$LOG_FILE" 2>/dev/null || true)
    if [ -z "$cron_log" ]; then cron_log="$LOG_FILE_DEFAULT"; fi
    printf '%s\n' "0 3 * * * $SCRIPT_PATH --cron >> $cron_log 2>&1" >> "$cron_tmp"
    crontab "$cron_tmp"; rm -f "$cron_tmp"
    log_message SUCCESS "acme.sh 安装成功。"; return 0
}

control_nginx() {
    local action="${1:-reload}"
    if [ "${SKIP_NGINX_TEST_IN_APPLY:-false}" != "true" ] && ! _nginx_test_cached; then
        log_message ERROR "Nginx 配置错误"
        nginx -t || true
        return 1
    fi
    systemctl "$action" nginx || { log_message ERROR "Nginx $action 失败"; return 1; }
    return 0
}

control_nginx_reload_if_needed() {
    if [ "${NGINX_RELOAD_NEEDED:-false}" = "true" ]; then
        control_nginx reload
        return $?
    fi
    return 0
}

# ==============================================================================
# SECTION: 安全与高级特性
# ==============================================================================

_update_cloudflare_ips() {
    _generate_op_id
    log_message INFO "正在拉取最新的 Cloudflare IP 列表..."
    local temp_allow
    temp_allow=$(mktemp)
    chmod 600 "$temp_allow"
    if run_cmd 20 curl -fsS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 > "$temp_allow" && printf "\n" >> "$temp_allow" && run_cmd 20 curl -fsS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 >> "$temp_allow"; then
        mkdir -p /etc/nginx/snippets /etc/nginx/conf.d
        local temp_cf_allow temp_cf_real temp_cf_geo
        temp_cf_allow=$(mktemp); temp_cf_real=$(mktemp); temp_cf_geo=$(mktemp)
        chmod 600 "$temp_cf_allow" "$temp_cf_real" "$temp_cf_geo"
        printf '%s\n' "# Cloudflare Allow List" > "$temp_cf_allow"
        printf '%s\n' "# Cloudflare Real IP" > "$temp_cf_real"
        printf '%s\n' "geo \$cf_ip {" > "$temp_cf_geo"
        printf '%s\n' "    default 0;" >> "$temp_cf_geo"
        while read -r ip; do
            [ -z "$ip" ] && continue
            printf '%s\n' "allow $ip;" >> "$temp_cf_allow"
            printf '%s\n' "set_real_ip_from $ip;" >> "$temp_cf_real"
            printf '%s\n' "    $ip 1;" >> "$temp_cf_geo"
        done < <(grep -E '^[0-9a-fA-F.:]+(/[0-9]+)?$' "$temp_allow")
        local allow_count
        allow_count=$(grep -c '^allow ' "$temp_cf_allow" || printf '%s' "0")
        if [ "$allow_count" -lt 5 ]; then
            log_message ERROR "Cloudflare IP 列表异常 (${allow_count})，已放弃更新。"
            rm -f "$temp_allow" "$temp_cf_allow" "$temp_cf_real" "$temp_cf_geo" 2>/dev/null || true
            return 1
        fi
        printf '%s\n' "deny all;" >> "$temp_cf_allow"
        printf '%s\n' "real_ip_header CF-Connecting-IP;" >> "$temp_cf_real"
        printf '%s\n' "}" >> "$temp_cf_geo"
        if ! _require_safe_path "/etc/nginx/conf.d/cf_real_ip.conf" "写入 CF Real IP"; then return 1; fi
        if ! _require_safe_path "/etc/nginx/conf.d/cf_geo.conf" "写入 CF Geo"; then return 1; fi
        if ! _require_safe_path "/etc/nginx/snippets/cf_allow.conf" "写入 CF Allow"; then return 1; fi
        mv "$temp_cf_real" /etc/nginx/conf.d/cf_real_ip.conf
        mv "$temp_cf_geo" /etc/nginx/conf.d/cf_geo.conf
        mv "$temp_cf_allow" /etc/nginx/snippets/cf_allow.conf
    log_message SUCCESS "Cloudflare IP 列表更新完成。"
    printf '%b' "${GREEN}Cloudflare IP 列表已更新。${NC}\n"
    else
        log_message ERROR "获取 Cloudflare IP 列表失败,请检查 VPS 的国际网络连通性。"
        printf '%b' "${RED}Cloudflare IP 列表更新失败。${NC}\n"
    fi
    rm -f "$temp_allow" "$temp_cf_allow" "$temp_cf_real" "$temp_cf_geo" 2>/dev/null || true
}


_handle_backup_restore() {
    _generate_op_id
    _render_menu "维护选项与灾备工具" "1. 备份与恢复面板 (数据层)" "2. 重建所有 HTTP 配置 (应用层)" "3. 修复定时任务 (系统层)"
    local c; if ! c=$(prompt_menu_choice "1-3" "true"); then return; fi
    case "$c" in
        1)
            _render_menu "备份与恢复系统" "1. 创建新备份 (打包所有配置与证书)" "2. 从完整备份包还原" "3. 从 本地快照 回滚元数据"
            local bc; if ! bc=$(prompt_menu_choice "1-3" "true"); then return; fi
            case "$bc" in
                1)
                    local ts=$(date +%Y%m%d_%H%M%S); local backup_file="$BACKUP_DIR/nginx_manager_backup_$ts.tar.gz"
                    log_message INFO "正在打包备份..."
                    if tar -czf "$backup_file" -C / "$PROJECTS_METADATA_FILE" "$TCP_PROJECTS_METADATA_FILE" "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$SSL_CERTS_BASE_DIR" 2>/dev/null; then log_message SUCCESS "备份成功: $backup_file"; else log_message ERROR "备份失败。"; fi ;;
                2)
                    printf '%b' "\n${CYAN}可用备份列表:${NC}\n"; ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || { log_message WARN "无可用备份。"; return; }
                    local file_path; if ! file_path=$(prompt_input "请输入完整备份文件路径" "" "" "" "true"); then return; fi
                    if [ -n "$file_path" ] && ! _require_safe_path "$file_path" "还原"; then return; fi
                    [ -z "$file_path" ] && return; [ ! -f "$file_path" ] && log_message ERROR "文件不存在" && return
                    if confirm_or_cancel "警告:还原将覆盖当前配置,是否继续?"; then
                        systemctl stop nginx || true; log_message INFO "正在解压还原..."
                        if tar -xzf "$file_path" -C /; then log_message SUCCESS "还原完成。"; control_nginx restart; else log_message ERROR "解压失败。"; fi
                    fi ;;
                3)
                    _render_menu "选择要回滚的数据类型" "1. 恢复 HTTP 项目" "2. 恢复 TCP 项目"
                    local snap_type; if ! snap_type=$(prompt_menu_choice "1-2" "true"); then return; fi
                    local target_file=""; local filter_str=""
                    [ "$snap_type" = "1" ] && target_file="$PROJECTS_METADATA_FILE" && filter_str="projects_"
                    [ "$snap_type" = "2" ] && target_file="$TCP_PROJECTS_METADATA_FILE" && filter_str="tcp_projects_"
                    [ -z "$target_file" ] && return
                    printf '%b' "\n${CYAN}可用快照 (${filter_str}):${NC}\n"; ls -lh "$JSON_BACKUP_DIR"/${filter_str}*.bak 2>/dev/null || { log_message WARN "无快照。"; return; }
                    local snap_path; if ! snap_path=$(prompt_input "请输入要恢复的快照路径" "" "" "" "true"); then return; fi
                    if [ -n "$snap_path" ] && ! _require_safe_path "$snap_path" "快照恢复"; then return; fi
                    if [ -n "$snap_path" ] && [ -f "$snap_path" ]; then
                        if confirm_or_cancel "这将会回滚记录,确认执行?"; then
                            snapshot_json "$target_file"; cp "$snap_path" "$target_file"
                            log_message SUCCESS "数据回滚完毕!(建议返回上级菜单执行 '重建所有 HTTP 配置' 同步 Nginx)"
                        fi
                    fi ;;
            esac ;;
        2) _rebuild_all_nginx_configs ;;
        3) _manage_cron_jobs ;;
    esac
}

# ==============================================================================
# SECTION: 日志与运维
# ==============================================================================

_view_file_with_tail() {
    local file="${1:-}"; if [ ! -f "$file" ]; then log_message ERROR "文件不存在: $file"; return; fi
    printf '%b' "${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}\n"; tail -f -n 50 "$file" || true; printf '%b' "\n${CYAN}--- 日志查看结束 ---${NC}\n"
}
_view_acme_log() { local f="$HOME/.acme.sh/acme.sh.log"; [ ! -f "$f" ] && f="/root/.acme.sh/acme.sh.log"; _view_file_with_tail "$f"; }
_view_nginx_global_log() {
    _render_menu "Nginx 全局日志" "1. 访问日志" "2. 错误日志"
    local c; if ! c=$(prompt_menu_choice "1-2" "true"); then return; fi
    case "$c" in 1) _view_file_with_tail "$NGINX_ACCESS_LOG" ;; 2) _view_file_with_tail "$NGINX_ERROR_LOG" ;; esac
}

_manage_cron_jobs() {
    local has_acme=0 has_manager=0
    if crontab -l 2>/dev/null | grep -q "\.acme\.sh/acme\.sh"; then has_acme=1; fi
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --cron"; then has_manager=1; fi
    local -a lines=()
    lines+=(" 1. acme.sh 原生续期进程 : $( [ $has_acme -eq 1 ] && printf '%b' "${GREEN}正常运行${NC}" || printf '%b' "${RED}缺失${NC}" )")
    lines+=(" 2. 本面板接管守护进程   : $( [ $has_manager -eq 1 ] && printf '%b' "${GREEN}正常运行${NC}" || printf '%b' "${RED}缺失${NC}" )")
    if [ $has_acme -eq 1 ] && [ $has_manager -eq 1 ]; then lines+=("${GREEN}系统定时任务状态完全健康,无需干预。${NC}")
    else lines+=("${YELLOW}检测到必需的定时任务不完整,正在自动执行修复...${NC}"); fi
    _render_menu "系统定时任务 (Cron) 诊断与修复" "${lines[@]}"
    if [ $has_acme -eq 0 ] || [ $has_manager -eq 0 ]; then
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_message ERROR "非交互模式禁止修复定时任务"
            return 1
        fi
        "$ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
        local cron_tmp
        cron_tmp=$(mktemp /tmp/cron.bak.XXXXXX)
        chmod 600 "$cron_tmp"
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > "$cron_tmp" || true
        local cron_log
        cron_log=$(_sanitize_log_file "$LOG_FILE" 2>/dev/null || true)
        if [ -z "$cron_log" ]; then cron_log="$LOG_FILE_DEFAULT"; fi
        printf '%s\n' "0 3 * * * $SCRIPT_PATH --cron >> $cron_log 2>&1" >> "$cron_tmp"
        crontab "$cron_tmp"; rm -f "$cron_tmp"
        log_message SUCCESS "定时任务修复完毕,系统级容灾续期已挂载。"
    fi
    press_enter_to_continue
}

# ==============================================================================
# SECTION: 数据与 HTTP 代理配置
# ==============================================================================

_get_project_json() { jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' ""; }

_project_snapshot_file() {
    local domain="${1:-}"
    if [ -z "$domain" ]; then return 1; fi
    printf '%s\n' "${JSON_BACKUP_DIR}/project_${domain}_$(date +%Y%m%d_%H%M%S).json.bak"
}

_nginx_conf_snapshot_file() {
    local name="${1:-}"; local type="${2:-http}"
    if [ -z "$name" ]; then return 1; fi
    printf '%s\n' "${CONF_BACKUP_DIR}/${type}_${name}_$(date +%Y%m%d_%H%M%S).conf.bak"
}

snapshot_nginx_conf() {
    local src_conf="${1:-}"; local name="${2:-}"; local type="${3:-http}"
    if [ -z "$src_conf" ] || [ -z "$name" ]; then return $ERR_CFG_INVALID_ARGS; fi
    if ! _require_safe_path "$src_conf" "配置快照"; then return 1; fi
    if [ ! -f "$src_conf" ]; then return 0; fi
    local snap
    snap=$(_nginx_conf_snapshot_file "$name" "$type") || return 1
    mkdir -p "$CONF_BACKUP_DIR"
    cp "$src_conf" "$snap"
    _cleanup_conf_backups "$name" "$type"
}

_cleanup_conf_backups() {
    local name="${1:-}"
    local type="${2:-http}"
    if [ -z "$name" ]; then return 0; fi
    local keep="$CONF_BACKUP_KEEP"
    if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then keep=10; fi
    ls -tp "$CONF_BACKUP_DIR/${type}_${name}_"*.conf.bak 2>/dev/null | grep -v '/$' | tail -n +$((keep + 1)) | xargs -I {} rm -- "{}" 2>/dev/null || true
}

_apply_nginx_conf_with_validation() {
    local temp_conf="${1:-}"; local target_conf="${2:-}"; local name="${3:-}"; local type="${4:-http}"; local skip_test="${5:-false}"
    if [ -z "$temp_conf" ] || [ -z "$target_conf" ] || [ -z "$name" ]; then return $ERR_CFG_INVALID_ARGS; fi
    if ! _require_safe_path "$target_conf" "配置写入"; then return $ERR_CFG_INVALID_ARGS; fi
    if [ -f "$target_conf" ] && cmp -s "$temp_conf" "$target_conf"; then
        log_message INFO "配置未变化，跳过写入与重载: $target_conf"
        rm -f "$temp_conf"
        return 0
    fi
    snapshot_nginx_conf "$target_conf" "$name" "$type" || true
    mv "$temp_conf" "$target_conf"
    _mark_nginx_conf_changed
    if [ "$skip_test" != "true" ] && ! _nginx_test_cached; then
        local rollback_conf
        rollback_conf=$(ls -t "$CONF_BACKUP_DIR/${type}_${name}_"*.conf.bak 2>/dev/null | head -n 1 || true)
        if [ -n "$rollback_conf" ] && [ -f "$rollback_conf" ]; then
            cp "$rollback_conf" "$target_conf"
        else
            rm -f "$target_conf"
        fi
        log_message ERROR "Nginx 配置检查失败,已回滚 (snapshot: ${rollback_conf:-none})"
        return $ERR_CFG_VALIDATE
    fi
    chmod 640 "$target_conf" || true
    return 0
}

_health_check_nginx_config() {
    local domain="${1:-}"
    if [ "$HEALTH_CHECK_ENABLED" != "true" ]; then return 0; fi
    if [ -z "$domain" ]; then return 0; fi
    local url="${HEALTH_CHECK_SCHEME}://127.0.0.1${HEALTH_CHECK_PATH}"
    local host_header="$domain"
    if ! command -v curl >/dev/null 2>&1; then return 0; fi
    local expect_list=()
    IFS=',' read -r -a expect_list <<< "$HEALTH_CHECK_EXPECT_CODES"
    local retries="$HEALTH_CHECK_RETRIES"
    if ! [[ "$retries" =~ ^[0-9]+$ ]] || [ "$retries" -lt 1 ]; then retries=1; fi
    local attempt=1
    while [ $attempt -le "$retries" ]; do
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout "$HEALTH_CHECK_TIMEOUT" --max-time "$HEALTH_CHECK_TIMEOUT" -H "Host: ${host_header}" "$url" 2>/dev/null || printf '%s' "000")
        local ok="false"
        local c
        for c in "${expect_list[@]}"; do
            if [ "$code" = "$c" ]; then ok="true"; break; fi
        done
        if [ "$ok" = "true" ]; then return 0; fi
        attempt=$((attempt + 1))
        sleep "$HEALTH_CHECK_RETRY_DELAY"
    done
    log_message ERROR "健康检查失败: ${domain}${HEALTH_CHECK_PATH} (code=${code})"
    return 1
}

snapshot_project_json() {
    local domain="${1:-}" json="${2:-}"
    if [ -z "$domain" ] || [ -z "$json" ]; then return 1; fi
    local snap
    snap=$(_project_snapshot_file "$domain") || return 1
    printf '%s\n' "$json" > "$snap"
}

snapshot_json() {
    local target_file="${1:-$PROJECTS_METADATA_FILE}"
    if [ -f "$target_file" ]; then
        local base_name snap_name
        base_name=$(basename "$target_file" .json)
        snap_name="${JSON_BACKUP_DIR}/${base_name}_$(date +%Y%m%d_%H%M%S).json.bak"
        cp "$target_file" "$snap_name"
        ls -tp "${JSON_BACKUP_DIR}/${base_name}_*.bak" 2>/dev/null | grep -v '/$' | tail -n +11 | xargs -I {} rm -- "{}" 2>/dev/null || true
    fi
}

json_upsert_by_key() {
    local target_file="${1:-}" key_name="${2:-}" key_value="${3:-}" json="${4:-}"
    if [ -z "$target_file" ] || [ -z "$key_name" ] || [ -z "$key_value" ] || [ -z "$json" ]; then
        return 1
    fi
    local temp
    temp=$(mktemp)
    chmod 600 "$temp"
    if jq -e --arg k "$key_name" --arg v "$key_value" '.[] | select(.[$k] == $v)' "$target_file" >/dev/null 2>&1; then
        jq --argjson new_val "$json" --arg k "$key_name" --arg v "$key_value" 'map(if .[$k] == $v then $new_val else . end)' "$target_file" > "$temp"
    else
        jq --argjson new_val "$json" '. + [$new_val]' "$target_file" > "$temp"
    fi
    if [ -s "$temp" ]; then
        mv "$temp" "$target_file"; return 0
    fi
    rm -f "$temp"; return 1
}

_save_project_json() {
    local json="${1:-}"
    if [ -z "$json" ]; then return 1; fi
    snapshot_json "$PROJECTS_METADATA_FILE"
    local domain
    domain=$(jq -r .domain <<< "$json")
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then return 1; fi
    json_upsert_by_key "$PROJECTS_METADATA_FILE" "domain" "$domain" "$json"
}


# 已废弃: 统一使用 check_dependencies()

_check_nginx_config() {
    if ! _nginx_test_cached; then
        log_error "Nginx 配置检查失败。"
        nginx -t || true
        return 1
    fi
    return 0
}

_check_dns_tools() {
    if command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1; then
        return 0
    fi
    log_warn "未找到 dig/host, DNS 诊断将跳过。"
    return 1
}

run_diagnostics() {
    _generate_op_id
    log_info "开始执行自检 (--check)"
    if [ "$(id -u)" -ne 0 ]; then log_warn "当前非 root, 部分检查可能失败。"; fi
    check_dependencies || true
    _check_dns_tools || true
    _check_nginx_config || true
    if [ -f "$PROJECTS_METADATA_FILE" ]; then jq -e . "$PROJECTS_METADATA_FILE" >/dev/null 2>&1 || log_error "projects.json 格式异常"; fi
    if [ -f "$TCP_PROJECTS_METADATA_FILE" ]; then jq -e . "$TCP_PROJECTS_METADATA_FILE" >/dev/null 2>&1 || log_error "tcp_projects.json 格式异常"; fi
    log_info "自检完成"
}

_delete_project_json() {
    snapshot_json "$PROJECTS_METADATA_FILE"
    local temp
    temp=$(mktemp)
    chmod 600 "$temp"
    jq --arg d "${1:-}" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$PROJECTS_METADATA_FILE"
}

_write_and_enable_nginx_config() {
    local domain="${1:-}"; local json="${2:-}"; local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if ! _require_valid_domain "$domain"; then return 1; fi
    if ! _require_safe_path "$conf" "配置写入"; then return 1; fi
    if [ -z "$json" ]; then log_message ERROR "配置生成失败: 传入 JSON 为空。"; return 1; fi
    local port cert key max_body custom_cfg cf_strict
    IFS=$'\t' read -r port cert key max_body custom_cfg cf_strict < <(jq -r '[.resolved_port, .cert_file, .key_file, (.client_max_body_size // empty), (.custom_config // empty), (.cf_strict_mode // "n")] | @tsv' <<< "$json")
    if [ "$port" == "cert_only" ]; then return 0; fi
    if ! _require_valid_port "$port"; then return 1; fi
    
    if ! _require_safe_path "$cert" "证书文件"; then return 1; fi
    if ! _require_safe_path "$key" "密钥文件"; then return 1; fi
    local body_cfg=""
    [[ -n "$max_body" && "$max_body" != "null" ]] && body_cfg="client_max_body_size ${max_body};"
    local extra_cfg=""; [[ -n "$custom_cfg" && "$custom_cfg" != "null" ]] && extra_cfg="$custom_cfg"; local cf_strict_cfg=""
    if [ "$cf_strict" == "y" ]; then
        [ ! -f "/etc/nginx/conf.d/cf_geo.conf" ] && _update_cloudflare_ips
        cf_strict_cfg="\n    if (\$cf_ip = 0) { return 444; }"
    fi
    
    if [[ -z "$port" || "$port" == "null" ]]; then log_message ERROR "端口为空,请检查项目配置。"; return 1; fi; get_vps_ip

    local temp_conf
    temp_conf=$(mktemp "${conf}.tmp.XXXXXX")
    cat > "$temp_conf" << EOF
server {
    listen 80; $( [[ -n "$VPS_IPV6" ]] && printf '%s' "listen [::]:80;" )
    server_name ${domain};
    location /.well-known/acme-challenge/ { root ${NGINX_WEBROOT_DIR}; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2; $( [[ -n "$VPS_IPV6" ]] && printf '%s' "listen [::]:443 ssl http2;" )
    server_name ${domain};
    ssl_certificate ${cert}; ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    add_header Strict-Transport-Security "max-age=31536000;" always;
    ${body_cfg}${cf_strict_cfg}
    ${extra_cfg}
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s; proxy_send_timeout 300s;
    }
}
EOF
    local skip_test="false"
    if [ "${SKIP_NGINX_TEST_IN_APPLY:-false}" = "true" ]; then skip_test="true"; fi
    _apply_nginx_conf_with_validation "$temp_conf" "$conf" "$domain" "http" "$skip_test"
    local apply_ret=$?
    if [ $apply_ret -ne 0 ]; then
        return $apply_ret
    fi
    ln -sf "$conf" "$NGINX_SITES_ENABLED_DIR/"
    chmod 640 "$conf" 2>/dev/null || true
    if ! _health_check_nginx_config "$domain"; then
        local rollback_conf
        rollback_conf=$(ls -t "$CONF_BACKUP_DIR/http_${domain}_"*.conf.bak 2>/dev/null | head -n 1 || true)
        if [ -n "$rollback_conf" ] && [ -f "$rollback_conf" ]; then
            cp "$rollback_conf" "$conf"
            NGINX_RELOAD_NEEDED="true"
            control_nginx_reload_if_needed || true
            log_message ERROR "健康检查失败,已回滚配置 (snapshot: ${rollback_conf:-none})"
        else
            log_message ERROR "健康检查失败且无可用快照: $domain"
        fi
        return $ERR_CFG_VALIDATE
    fi
}

_remove_and_disable_nginx_config() {
    local domain="${1:-}"
    if ! _require_valid_domain "$domain"; then return 1; fi
    if ! _require_safe_path "$NGINX_SITES_AVAILABLE_DIR/${domain}.conf" "删除"; then return 1; fi
    if ! _require_safe_path "$NGINX_SITES_ENABLED_DIR/${domain}.conf" "删除"; then return 1; fi
    rm -f "$NGINX_SITES_AVAILABLE_DIR/${domain}.conf" "$NGINX_SITES_ENABLED_DIR/${domain}.conf"
}

_view_nginx_config() {
    local domain="${1:-}"; local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if [ ! -f "$conf" ]; then log_message WARN "此项目未生成配置文件。"; return; fi
    local -a lines=(); while IFS= read -r line; do lines+=("$line"); done < "$conf"
    _render_menu "配置文件: $domain" "${lines[@]}"
}

_rebuild_all_nginx_configs() {
    log_message INFO "准备基于现有记录从零重建所有 Nginx HTTP 代理文件..."
    if ! confirm_or_cancel "这将会覆盖当前所有 Nginx HTTP 代理配置文件,是否继续?"; then return; fi
    local all_projects
    all_projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
    if [ -z "$all_projects" ]; then log_message WARN "没有任何项目记录可供重建。"; return; fi
    local success=0 fail=0
    while read -r p; do
        [ -z "$p" ] && continue
        local d port
        d=$(jq -r .domain <<< "$p")
        port=$(jq -r .resolved_port <<< "$p")
        if ! _require_valid_domain "$d"; then log_message ERROR "域名无效，跳过: $d"; fail=$((fail+1)); continue; fi
        if [ "$port" == "cert_only" ]; then continue; fi
        if ! _require_valid_port "$port"; then log_message ERROR "端口无效，跳过: $d"; fail=$((fail+1)); continue; fi
        log_message INFO "重建配置文件: $d ..."
        if _write_and_enable_nginx_config "$d" "$p"; then
            success=$((success+1))
        else
            fail=$((fail+1))
            log_message ERROR "重建失败: $d"
        fi
    done <<< "$all_projects"
    rm -f /etc/nginx/snippets/cf_allow.conf
    log_message INFO "正在重载 Nginx..."
    NGINX_RELOAD_NEEDED="true"
    if control_nginx_reload_if_needed; then log_message SUCCESS "重建完成。成功: $success, 失败: $fail"; else log_message ERROR "Nginx 重载失败!"; fi
}

# ==============================================================================
# SECTION: 数据与 TCP 代理配置
# ==============================================================================

_save_tcp_project_json() {
    local json="${1:-}"
    if [ -z "$json" ]; then return 1; fi
    snapshot_json "$TCP_PROJECTS_METADATA_FILE"
    local port
    port=$(jq -r .listen_port <<< "$json")
    if [ -z "$port" ] || [ "$port" = "null" ]; then return 1; fi
    json_upsert_by_key "$TCP_PROJECTS_METADATA_FILE" "listen_port" "$port" "$json"
}

_write_and_enable_tcp_config() {
    local port="${1:-}"; local json="${2:-}"; local conf="$NGINX_STREAM_AVAILABLE_DIR/tcp_${port}.conf"
    if ! _require_valid_port "$port"; then return 1; fi
    if ! _require_safe_path "$conf" "配置写入"; then return 1; fi
    local target tls_enabled ssl_cert ssl_key
    IFS=$'\t' read -r target tls_enabled ssl_cert ssl_key < <(jq -r '[.target, (.tls_enabled // "n"), (.ssl_cert // ""), (.ssl_key // "")] | @tsv' <<< "$json")
    local listen_flag=""; local ssl_block=""
    if [ "$tls_enabled" == "y" ]; then
        : "ssl_cert/ssl_key already set"
        listen_flag="ssl"
        ssl_block="\n    ssl_certificate ${ssl_cert};\n    ssl_certificate_key ${ssl_key};\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';"
    fi
    local upstream_block=""; local proxy_pass_target="${target}"
    if [[ "$target" == *","* ]]; then
        proxy_pass_target="tcp_backend_${port}"; upstream_block="upstream ${proxy_pass_target} {"
        IFS=',' read -ra ADDR <<< "$target"; for i in "${ADDR[@]}"; do upstream_block+=$'\n    server '"${i};"; done; upstream_block+=$'\n}\n'
    fi
    local temp_conf
    temp_conf=$(mktemp "${conf}.tmp.XXXXXX")
    cat > "$temp_conf" << EOF
${upstream_block}server {
    listen ${port} ${listen_flag};
    proxy_pass ${proxy_pass_target};${ssl_block}
}
EOF
    local skip_test="false"
    if [ "${SKIP_NGINX_TEST_IN_APPLY:-false}" = "true" ]; then skip_test="true"; fi
    _apply_nginx_conf_with_validation "$temp_conf" "$conf" "$port" "tcp" "$skip_test"
    local apply_ret=$?
    if [ $apply_ret -ne 0 ]; then
        return $apply_ret
    fi
    ln -sf "$conf" "$NGINX_STREAM_ENABLED_DIR/"
    chmod 640 "$conf" 2>/dev/null || true
}

configure_tcp_proxy() {
    _generate_op_id
    if ! acquire_tcp_lock; then return 1; fi
    _render_menu "配置 TCP 代理与负载均衡"
    local name; if ! name=$(prompt_input "项目备注名称" "MyTCP" "" "" "false"); then return; fi
    local l_port; if ! l_port=$(prompt_input "本机监听端口" "" "^[0-9]+$" "无效端口" "false"); then return; fi
    if ! _is_valid_port "$l_port"; then log_message ERROR "端口范围无效 (1-65535)。"; return; fi
    local target; if ! target=$(prompt_input "目标地址" "" "^[a-zA-Z0-9.-]+:[0-9]+(,[a-zA-Z0-9.-]+:[0-9]+)*$" "格式错误" "false"); then return; fi
    if ! _is_valid_target "$target"; then log_message ERROR "目标地址格式无效。"; return; fi
    local tls_enabled="n"; local ssl_cert=""; local ssl_key=""
    if confirm_or_cancel "是否开启 TLS/SSL 加密卸载?"; then
        tls_enabled="y"
        local http_projects=$(jq -c '.[] | select(.cert_file != null and .cert_file != "")' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
        if [ -z "$http_projects" ]; then log_message ERROR "未发现可用证书。"; return 1; fi
        printf '%b' "\n${CYAN}请选择要用于加密流量的证书:${NC}\n"; local idx=0; declare -A domain_map cert_map key_map
        while read -r p; do [ -z "$p" ] && continue; idx=$((idx+1)); domain_map[$idx]=$(jq -r .domain <<< "$p"); cert_map[$idx]=$(jq -r .cert_file <<< "$p"); key_map[$idx]=$(jq -r .key_file <<< "$p"); printf '%b' " ${GREEN}${idx}.${NC} ${domain_map[$idx]}\n"; done <<< "$http_projects"
        local c_idx; while true; do
            if ! c_idx=$(prompt_input "请输入序号" "" "^[0-9]+$" "无效序号" "false"); then return; fi
            if [ "$c_idx" -ge 1 ] && [ "$c_idx" -le "$idx" ]; then ssl_cert="${cert_map[$c_idx]}"; ssl_key="${key_map[$c_idx]}"; break; else log_message ERROR "序号越界"; fi
        done
    fi
    local json=$(jq -n --arg n "$name" --arg lp "$l_port" --arg t "$target" --arg te "$tls_enabled" --arg sc "$ssl_cert" --arg sk "$ssl_key" '{name:$n, listen_port:$lp, target:$t, tls_enabled:$te, ssl_cert:$sc, ssl_key:$sk}')
    if _write_and_enable_tcp_config "$l_port" "$json"; then
        NGINX_RELOAD_NEEDED="true"
        if control_nginx_reload_if_needed; then _save_tcp_project_json "$json"; log_message SUCCESS "TCP 代理已成功配置 ($l_port) [TLS: $tls_enabled]。"
        else log_message ERROR "Nginx 重载失败"; rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${l_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${l_port}.conf"; NGINX_RELOAD_NEEDED="true"; control_nginx_reload_if_needed || true; fi
    fi
}

manage_tcp_configs() {
    _generate_op_id
    if ! acquire_tcp_lock; then return 1; fi
    while true; do
    local all count
    all=$(jq . "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "[]")
    count=$(jq 'length' <<< "$all")
        if [ "$count" -eq 0 ]; then log_message WARN "暂无 TCP 项目。"; break; fi
        printf '%b' "\n"; printf "${BOLD}%-4s %-10s %-5s %-12s %-22s${NC}\n" "ID" "端口" "TLS" "备注" "目标地址"; printf '%b' "──────────────────────────────────────────────────────────\n"
        local idx=0
        jq -r '.[] | [(.listen_port // ""), (.name // "-"), (.target // ""), (.tls_enabled // "n")] | @tsv' <<< "$all" | while IFS=$'\t' read -r port name target tls; do
            idx=$((idx + 1))
            local short_target="${target:0:22}"
            [ ${#target} -gt 22 ] && short_target="${target:0:19}..."
            local tls_str="${RED}否${NC}"
            [ "$tls" == "y" ] && tls_str="${GREEN}是${NC}"
            printf "%-4d ${GREEN}%-10s${NC} %-14s %-12s %-22s\n" "$idx" "$port" "$tls_str" "${name:0:10}" "$short_target"
        done; printf '%b' "\n"
        if ! select_item_and_act "$all" "$count" "请输入序号选择 TCP 项目 (回车返回)" "listen_port" _manage_tcp_actions; then break; fi
    done
}

# ==============================================================================
# SECTION: 业务逻辑 (证书申请与主流程) - 优化与安全增强版
# ==============================================================================

# 敏感信息遮掩过滤器
# 用法: _mask_sensitive_data < log.txt
_mask_sensitive_data() {
    # 使用 sed 正则替换常见的敏感 Key 和 Token
    # 匹配模式: Key='value', Key="value", Key=value, Key: 'value'
    sed -E \
        -e "s/(CF_Token(=|':\s*'|=\s*'))([^ '\"]+)/\1***MASKED***/g" \
        -e "s/(CF_Account_ID(=|':\s*'|=\s*'))([^ '\"]+)/\1***MASKED***/g" \
        -e "s/(CF_Zone_ID(=|':\s*'|=\s*'))([^ '\"]+)/\1***MASKED***/g" \
        -e "s/(Ali_Key(=|':\s*'|=\s*'))([^ '\"]+)/\1***MASKED***/g" \
        -e "s/(Ali_Secret(=|':\s*'|=\s*'))([^ '\"]+)/\1***MASKED***/g" \
        -e "s/(SAVED_[^ ]+)(=)([^ ]+)/\1\2***MASKED***/g"
}

_renew_fail_db_init() {
    local db_dir
    db_dir=$(dirname "$RENEW_FAIL_DB")
    mkdir -p "$db_dir"
    if [ ! -f "$RENEW_FAIL_DB" ]; then
        printf '%s\n' "{}" > "$RENEW_FAIL_DB"
    fi
}

_renew_fail_incr() {
    local domain="${1:-}"
    if [ -z "$domain" ]; then printf '%s\n' "0"; return 0; fi
    _renew_fail_db_init
    local temp
    temp=$(mktemp)
    chmod 600 "$temp"
    local now_ts
    now_ts=$(date +%s)
    local count
    count=$(jq -r --arg d "$domain" '(.[$d].count // 0) + 1' "$RENEW_FAIL_DB" 2>/dev/null || printf '%s\n' "1")
    jq --arg d "$domain" --argjson c "$count" --argjson ts "$now_ts" '. + {($d): {count: $c, ts: $ts}}' "$RENEW_FAIL_DB" > "$temp" && mv "$temp" "$RENEW_FAIL_DB"
    printf '%s\n' "$count"
}

_renew_fail_reset() {
    local domain="${1:-}"
    if [ -z "$domain" ]; then return 0; fi
    _renew_fail_db_init
    local temp
    temp=$(mktemp)
    chmod 600 "$temp"
    jq --arg d "$domain" 'del(.[$d])' "$RENEW_FAIL_DB" > "$temp" && mv "$temp" "$RENEW_FAIL_DB"
}

_renew_fail_cleanup() {
    _renew_fail_db_init
    local ttl_days="$RENEW_FAIL_TTL_DAYS"
    if ! [[ "$ttl_days" =~ ^[0-9]+$ ]] || [ "$ttl_days" -lt 1 ]; then ttl_days=14; fi
    local now_ts
    now_ts=$(date +%s)
    local cutoff=$((now_ts - ttl_days * 86400))
    local temp
    temp=$(mktemp)
    chmod 600 "$temp"
    jq --argjson cutoff "$cutoff" 'with_entries(select((.value.ts // 0) >= $cutoff))' "$RENEW_FAIL_DB" > "$temp" && mv "$temp" "$RENEW_FAIL_DB"
}

_handle_dns_provider_credentials() {
    local provider="${1:-}"
    if [ "$provider" != "dns_cf" ]; then return 0; fi
    if [ "$IS_INTERACTIVE_MODE" != "true" ]; then return 0; fi
    local saved_t="" saved_a="" use_saved="false"
    saved_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
    saved_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
    if [[ -n "$saved_t" && -n "$saved_a" ]]; then
        printf '%b' "${CYAN}检测到已保存的 Cloudflare 凭证:${NC}\n"
        printf '%b' "  Token : $(_mask_string "$saved_t")\n"
        printf '%b' "  AccID : $(_mask_string "$saved_a")\n"
        if confirm_or_cancel "是否复用该凭证?"; then use_saved="true"; fi
    fi
    if [ "$use_saved" = "false" ]; then
        local t
        local a
        if ! t=$(_prompt_secret "请输入新的 CF_Token"); then return 1; fi
        if ! a=$(_prompt_secret "请输入新的 Account_ID"); then return 1; fi
        [ -n "$t" ] && export CF_Token="$t"
        [ -n "$a" ] && export CF_Account_ID="$a"
    fi
    return 0
}

_prepare_http01_challenge() {
    local domain="${1:-}"
    local -n cmd_ref="$2"
    local -n temp_conf_created_ref="$3"
    local -n temp_conf_ref="$4"
    local -n stopped_svc_ref="$5"

    if ss -tuln 2>/dev/null | grep -qE ':(80|443)\s'; then
        local temp_svc
        temp_svc=$(_detect_web_service)
        if [ "$temp_svc" = "nginx" ]; then
            if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
                if ! _require_safe_path "$temp_conf_ref" "临时配置"; then return 1; fi
                cat > "$temp_conf_ref" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }
EOF
                ln -sf "$temp_conf_ref" "$NGINX_SITES_ENABLED_DIR/"
                systemctl reload nginx || true
                temp_conf_created_ref="true"
            fi
            mkdir -p "$NGINX_WEBROOT_DIR"
            cmd_ref+=("--webroot" "$NGINX_WEBROOT_DIR")
        else
            if confirm_or_cancel "是否临时停止 $temp_svc 以释放 80 端口?"; then
                systemctl stop "$temp_svc"
                stopped_svc_ref="$temp_svc"
                trap "systemctl start \"$stopped_svc_ref\"; cleanup; exit 130" INT TERM
            fi
            cmd_ref+=("--standalone")
        fi
    else
        cmd_ref+=("--standalone")
    fi
}

_run_acme_issue_command() {
    local -n cmd_ref="$1"
    local -n log_temp_ref="$2"
    local -n ret_ref="$3"
    local log_temp
    log_temp=$(mktemp /tmp/acme_cmd_log.XXXXXX)
    chmod 600 "$log_temp"
    printf '%b' "${YELLOW}正在通信 (约 30-60 秒,请勿中断)... ${NC}"
    run_cmd 90 "${cmd_ref[@]}" > "$log_temp" 2>&1 &
    local pid=$!
    local spinstr='|/-\'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.2
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    wait $pid
    ret_ref=$?
    log_temp_ref="$log_temp"
}

_cleanup_http01_challenge() {
    local temp_conf_created="${1:-false}"
    local temp_conf="${2:-}"
    local stopped_svc="${3:-}"

    if [ "$temp_conf_created" = "true" ]; then
        if _require_safe_path "$temp_conf" "清理临时配置"; then rm -f "$temp_conf"; fi
        local enabled_conf
        enabled_conf="$NGINX_SITES_ENABLED_DIR/temp_acme_$(basename "$temp_conf" | sed 's/^temp_acme_//;s/\.conf$//').conf"
        if _require_safe_path "$enabled_conf" "清理临时配置"; then rm -f "$enabled_conf"; fi
        systemctl reload nginx || true
    fi
    if [ -n "$stopped_svc" ]; then
        systemctl start "$stopped_svc"
        trap '_on_int' INT TERM
    fi
}

_install_certificate_files() {
    local domain="${1:-}"
    local key="${2:-}"
    local cert="${3:-}"
    local install_reload_cmd="${4:-}"
    local wildcard="${5:-n}"
    local -a inst
    inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
    [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    "${inst[@]}" >/dev/null 2>&1
    return $?
}

_issue_and_install_certificate() {
    _generate_op_id
    local json="${1:-}"
    local domain
    local method
    local domain method
    IFS=$'\t' read -r domain method < <(jq -r '[.domain, .acme_validation_method] | @tsv' <<< "$json")
    LAST_CERT_ELAPSED=""; LAST_CERT_CERT=""; LAST_CERT_KEY=""
    if [ "$method" == "reuse" ]; then
        local cert_info
        IFS=$'\t' read -r LAST_CERT_CERT LAST_CERT_KEY < <(jq -r '[.cert_file, .key_file] | @tsv' <<< "$json")
    fi
    if [ "$method" == "http-01" ]; then
        if ! _check_dns_resolution "$domain"; then return 1; fi
    fi
    if [ "$method" == "reuse" ]; then
        if ! _require_safe_path "$LAST_CERT_CERT" "证书文件" || ! _require_safe_path "$LAST_CERT_KEY" "密钥文件"; then return 1; fi
        if [ ! -f "$LAST_CERT_CERT" ] || [ ! -f "$LAST_CERT_KEY" ]; then
            log_message ERROR "复用证书文件不存在"
            return 1
        fi
        return 0
    fi
    local provider
    local wildcard
    local ca
    IFS=$'\t' read -r provider wildcard ca < <(jq -r '[.dns_api_provider, .use_wildcard, .ca_server_url] | @tsv' <<< "$json")
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key="$SSL_CERTS_BASE_DIR/$domain.key"
    local start_ts
    start_ts=$(date +%s)
    
    log_message INFO "正在为 $domain 申请证书 ($method)..."
    local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca" --log)
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")
    
    local temp_conf_created="false"; local temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"; local stopped_svc=""
    if ! _require_valid_domain "$domain"; then return 1; fi
    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ]; then
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                local saved_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local saved_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
                local use_saved="false"
                if [[ -n "$saved_t" && -n "$saved_a" ]]; then
                    printf '%b' "${CYAN}检测到已保存的 Cloudflare 凭证:${NC}\n"
                    printf '%b' "  Token : $(_mask_string "$saved_t")\n"
                    printf '%b' "  AccID : $(_mask_string "$saved_a")\n"
                    if confirm_or_cancel "是否复用该凭证?"; then use_saved="true"; fi
                fi
                if [ "$use_saved" = "false" ]; then
                    local t; if ! t=$(_prompt_secret "请输入新的 CF_Token"); then return 1; fi
                    local a; if ! a=$(_prompt_secret "请输入新的 Account_ID"); then return 1; fi
                    [ -n "$t" ] && export CF_Token="$t"; [ -n "$a" ] && export CF_Account_ID="$a"
                fi
            fi
        fi; cmd+=("--dns" "$provider")
    elif [ "$method" = "http-01" ]; then
        if ! _prepare_http01_challenge "$domain" cmd temp_conf_created temp_conf stopped_svc; then return 1; fi
    fi

    local log_temp
    log_temp=$(mktemp /tmp/acme_cmd_log.XXXXXX)
    chmod 600 "$log_temp"
    printf '%b' "${YELLOW}正在通信 (约 30-60 秒,请勿中断)... ${NC}"
    run_cmd 90 "${cmd[@]}" > "$log_temp" 2>&1 &
    local pid=$!
    local spinstr='|/-\'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}; printf " [%c]  " "$spinstr"; local spinstr=$temp${spinstr%"$temp"}; sleep 0.2; printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"; wait $pid; local ret=$?
    _cleanup_http01_challenge "$temp_conf_created" "$temp_conf" "$stopped_svc"

    if [ $ret -ne 0 ]; then printf '%b' "\n"; log_message ERROR "申请失败: $domain"
        printf '%b' "${CYAN}--- 错误详情 (已脱敏) ---${NC}\n"
        _mask_sensitive_data < "$log_temp"
        printf '%b' "${CYAN}------------------------${NC}\n"
        rm -f "$log_temp"; _send_tg_notify "fail" "$domain" "acme.sh 申请证书失败。" ""; unset CF_Token CF_Account_ID Ali_Key Ali_Secret; return 1; fi
    rm -f "$log_temp"
    local rcmd
    local resolved_port
    local install_reload_cmd=""
    IFS=$'\t' read -r rcmd resolved_port < <(jq -r '[.reload_cmd // empty, .resolved_port // empty] | @tsv' <<< "$json")
    if [ -n "$rcmd" ] && [ "$resolved_port" != "cert_only" ]; then
        log_message WARN "当前为 HTTP 代理项目,将强制使用 nginx reload,忽略自定义 Hook"
        rcmd=""
    fi
    if ! _validate_hook_command "$rcmd"; then
        log_message ERROR "不安全的 Hook 命令,已拒绝。"
        return 1
    fi
    if [ "$resolved_port" == "cert_only" ]; then install_reload_cmd="$rcmd"; else install_reload_cmd="systemctl reload nginx"; fi
    local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
    [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
    "${inst[@]}" >/dev/null 2>&1; local acme_ret=$?
    if [ -f "$cert" ] && [ -f "$key" ]; then
        chmod 600 "$key" 2>/dev/null || true
        chmod 644 "$cert" 2>/dev/null || true
        local elapsed=$(( $(date +%s) - start_ts ))
        LAST_CERT_ELAPSED="${elapsed}s"; LAST_CERT_CERT="$cert"; LAST_CERT_KEY="$key"
        log_message SUCCESS "证书文件已成功生成于 /etc/ssl/ 目录。"
        if [ $acme_ret -ne 0 ]; then printf '%b' "\n${RED}⚠️  [警告] 自动重启命令执行失败: $install_reload_cmd${NC}\n"; printf '%b' "${YELLOW}证书已安装,但服务未能自动加载新证书。${NC}\n"; fi
        _send_tg_notify "success" "$domain" "证书已成功安装。"; unset CF_Token CF_Account_ID Ali_Key Ali_Secret; return 0
    else log_message ERROR "证书文件安装后丢失。"; return 1; fi
}

_gather_project_details() {
    exec 3>&1; exec 1>&2
    local cur="${1:-{\}}"; local skip_cert="${2:-false}"; local is_cert_only="false"
    if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

    local domain
    domain=$(jq -r '.domain // ""' <<< "$cur")
    if [ -z "$domain" ]; then if ! domain=$(prompt_input "主域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式无效" "false"); then exec 1>&3; return 1; fi; fi
    if ! _is_valid_domain "$domain"; then log_message ERROR "域名格式无效。"; exec 1>&3; return 1; fi
    
    if [ "$skip_cert" == "false" ]; then
        if ! _check_dns_resolution "$domain"; then
            printf '%b' "${RED}域名配置已取消。${NC}\n"
            exec 1>&3
            return 1
        fi
    fi

    local wc_match=""
    if [ "$skip_cert" == "false" ]; then
        local all_wcs=$(jq -c '.[] | select(.use_wildcard == "y" and .cert_file != null)' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
        while read -r wp; do [ -z "$wp" ] && continue
            local wd
            wd=$(jq -r .domain <<< "$wp")
            if [[ "$domain" == *".$wd" || "$domain" == "$wd" ]]; then wc_match="$wd"; break; fi
        done <<< "$all_wcs"
    fi
    local reuse_wc="false"; local wc_cert=""; local wc_key=""
    if [ -n "$wc_match" ]; then
        printf '%b' "\n${GREEN}🎯 智能提示: 检测到系统中已存在匹配的泛域名证书 (*.${wc_match})${NC}\n" >&2
        if confirm_or_cancel "是否直接绑定复用该证书,实现免验证零延迟上线?"; then
            reuse_wc="true"
            local wp
            wp=$(_get_project_json "$wc_match")
            wc_cert=$(jq -r .cert_file <<< "$wp")
            wc_key=$(jq -r .key_file <<< "$wp")
        fi
    fi

    local type="cert_only"; local name="证书"; local port="cert_only"
    local max_body
    local custom_cfg
    max_body=$(jq -r '.client_max_body_size // empty' <<< "$cur")
    custom_cfg=$(jq -r '.custom_config // empty' <<< "$cur")
    local cf_strict
    local reload_cmd
    cf_strict=$(jq -r '.cf_strict_mode // "n"' <<< "$cur")
    reload_cmd=$(jq -r '.reload_cmd // empty' <<< "$cur")
    CF_STRICT_MODE_CURRENT="$cf_strict"

    if [ "$is_cert_only" == "false" ]; then
        name=$(jq -r '.name // ""' <<< "$cur")
        [ "$name" == "证书" ] && name=""
        while true; do
            local target; if ! target=$(prompt_input "后端目标 (容器名/端口)" "$name" "" "" "false"); then exec 1>&3; return 1; fi
            type="local_port"; port="$target"
            if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
                type="docker"; exec 1>&3
                port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true); exec 1>&2
                if [ -z "$port" ]; then
                    if ! port=$(prompt_input "未检测到端口,手动输入" "80" "^[0-9]+$" "无效端口" "false"); then exec 1>&3; return 1; fi
                fi
                if ! _is_valid_port "$port"; then log_message ERROR "端口范围无效 (1-65535)。"; exec 1>&3; return 1; fi
                break
            fi
            if [[ "$port" =~ ^[0-9]+$ ]] && _is_valid_port "$port"; then break; fi
            log_message ERROR "错误: '$target' 既不是容器也不是端口。" >&2
        done
    fi

    local method="http-01"; local provider=""; local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"; local ca_name="letsencrypt"
    if [ "$reuse_wc" == "true" ]; then method="reuse"; skip_cert="true"; fi

    if [ "$skip_cert" == "true" ]; then
        if [ "$reuse_wc" == "false" ]; then
            method=$(jq -r '.acme_validation_method // "http-01"' <<< "$cur")
            provider=$(jq -r '.dns_api_provider // ""' <<< "$cur")
            wildcard=$(jq -r '.use_wildcard // "n"' <<< "$cur")
            ca_server=$(jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"' <<< "$cur")
        fi
    else
        local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
        _render_menu "选择 CA 机构" "${ca_list[@]}"; local ca_choice; while true; do ca_choice=$(prompt_menu_choice "1-3"); [ -n "$ca_choice" ] && break; done
        case "$ca_choice" in 1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;; 2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;; 3) ca_server="google"; ca_name="google" ;; esac
        
        local -a method_display=("1. http-01 (智能无中断 Webroot / Standalone)" "2. dns_cf  (Cloudflare API)" "3. dns_ali (阿里云 API)")
        _render_menu "验证方式" "${method_display[@]}" >&2; local v_choice; while true; do v_choice=$(prompt_menu_choice "1-3"); [ -n "$v_choice" ] && break; done
        case "$v_choice" in 1) method="http-01" ;; 2|3)
            method="dns-01"; [ "$v_choice" = "2" ] && provider="dns_cf" || provider="dns_ali"
            if ! wildcard=$(prompt_input "是否申请泛域名? (y/[n])" "n" "^[yYnN]$" "" "false"); then exec 1>&3; return 1; fi
            
            # *** 优化核心：泛域名主域不配置端口 ***
            if [ "$wildcard" = "y" ] && [ "$is_cert_only" == "false" ]; then
                printf '%b' "\n${BRIGHT_YELLOW}┌──────────────────────────────────────────────┐${NC}\n"
                local box_msg="⚠️  检测到泛域名申请模式"; local box_line
                printf -v box_line "%-44s" "$box_msg"
                printf '%b' "${BRIGHT_YELLOW}│ ${box_line} │${NC}\n"
                printf '%b' "${BRIGHT_YELLOW}└──────────────────────────────────────────────┘${NC}\n"
                printf '%b' "您的配置将同时覆盖 ${GREEN}${domain}${NC} 和 ${GREEN}*.${domain}${NC}。\n"
                if ! confirm_or_cancel "是否为主域名 ${domain} 配置 Nginx HTTP 代理端口? (选 No 则仅管理证书)" "n"; then
                    # 用户选择不配置代理，强制切换为 cert_only 模式
                    is_cert_only="true"
                    type="cert_only"; port="cert_only"
                    printf '%b' "${CYAN}已切换为证书管理模式，后续将跳过端口与防御设置。${NC}\n"
                fi
            fi ;;
        esac
    fi

    if [ "$is_cert_only" == "false" ]; then
        local cf_strict_default="n"; [ "$cf_strict" == "y" ] && cf_strict_default="y"
    if confirm_or_cancel "是否开启 Cloudflare 严格安全防御?" "$cf_strict_default"; then cf_strict="y"; else cf_strict="n"; fi
    CF_STRICT_MODE_CURRENT="$cf_strict"
    else
        if [ "$skip_cert" == "false" ]; then
            local -a hook_lines=(); local auto_sui_cmd=""
            if systemctl list-units --type=service | grep -q "s-ui.service"; then auto_sui_cmd="systemctl restart s-ui"
            elif systemctl list-units --type=service | grep -q "x-ui.service"; then auto_sui_cmd="systemctl restart x-ui"; fi
            local opt1_text="S-UI / 3x-ui / x-ui"; [ -n "$auto_sui_cmd" ] && opt1_text="${opt1_text} (自动: ${auto_sui_cmd##* })"
            hook_lines+=("${CYAN}自动重启预设方案:${NC}"); hook_lines+=("1. ${opt1_text}")
            hook_lines+=("2. V2Ray 原生服务 (systemctl restart v2ray)")
            hook_lines+=("3. Xray 原生服务 (systemctl restart xray)")
            hook_lines+=("4. Nginx 服务 (systemctl reload nginx)")
            hook_lines+=("5. 手动输入自定义 Shell 命令"); hook_lines+=("6. 跳过")
_render_menu "配置外部重载组件 (Reload Hook)" "${hook_lines[@]}" >&2
            local hk; while true; do hk=$(prompt_menu_choice "1-6"); [ -n "$hk" ] && break; done
            case "$hk" in 1) reload_cmd="$auto_sui_cmd" ;; 2) reload_cmd="systemctl restart v2ray" ;; 3) reload_cmd="systemctl restart xray" ;; 4) reload_cmd="systemctl reload nginx" ;; 5) if ! reload_cmd=$(prompt_input "请输入完整 Shell 命令" "" "" "" "true"); then exec 1>&3; return 1; fi ;; 6) reload_cmd="" ;; esac
             if [ -n "$reload_cmd" ]; then
                 if ! _validate_hook_command "$reload_cmd"; then
                     exec 1>&3
                     return 1
                 fi
             fi
        fi
    fi

    local cf="$SSL_CERTS_BASE_DIR/$domain.cer"; local kf="$SSL_CERTS_BASE_DIR/$domain.key"
    if [ "$reuse_wc" == "true" ]; then cf="$wc_cert"; kf="$wc_key"; fi

    jq -n --arg d "${domain:-}" --arg t "${type:-local_port}" --arg n "${name:-}" --arg p "${port:-}" \
        --arg m "${method:-http-01}" --arg dp "${provider:-}" --arg w "${wildcard:-n}" \
        --arg cu "${ca_server:-}" --arg cn "${ca_name:-}" --arg cf "${cf:-}" --arg kf "${kf:-}" \
        --arg mb "${max_body:-}" --arg cc "${custom_cfg:-}" --arg cs "${CF_STRICT_MODE_CURRENT:-$cf_strict}" --arg rc "${reload_cmd:-}" \
        '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf, client_max_body_size:$mb, custom_config:$cc, cf_strict_mode:$cs, reload_cmd:$rc}' >&3
    exec 1>&3
}

_display_projects_list() {
    local json="${1:-}"; if [ -z "$json" ] || [ "$json" == "[]" ]; then printf '%b' "暂无数据\n"; return; fi
    local w_id=4 w_domain=24 w_target=18 w_status=14 w_renew=12
    local header=""; header+="$(_center_text "ID" $w_id) "; header+="$(_center_text "域名" $w_domain) "
    header+="$(_center_text "目标" $w_target) "; header+="$(_center_text "状态" $w_status) "; header+="$(_center_text "续期" $w_renew)"
    printf "${BOLD}${CYAN}%s${NC}\n" "$header"
    printf "%${w_id}s " | sed "s/ /─/g"; printf "%${w_domain}s " | sed "s/ /─/g"
    printf "%${w_target}s " | sed "s/ /─/g"; printf "%${w_status}s " | sed "s/ /─/g"; printf "%${w_renew}s\n" | sed "s/ /─/g"
    
    local idx=0
    jq -r '.[] | [(.domain // "未知"), (.type // ""), (.resolved_port // ""), (.cert_file // ""), (.acme_validation_method // "")] | @tsv' <<< "$json" | while IFS=$'\t' read -r domain type port cert method; do
        idx=$((idx + 1))
        local target_str="Port:$port"; [ "$type" = "docker" ] && target_str="Docker:$port"; [ "$port" == "cert_only" ] && target_str="CertOnly"
        local display_target=$(printf "%-${w_target}s" "$target_str"); local renew_date="-"
        if [ "$method" == "reuse" ]; then renew_date="跟随主域"
        else
            local conf_file="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"; [ ! -f "$conf_file" ] && conf_file="$HOME/.acme.sh/${domain}/${domain}.conf"
            if [ -f "$conf_file" ]; then local next_ts=$(grep "^Le_NextRenewTime=" "$conf_file" | cut -d= -f2- | tr -d "'\"" || true); [ -n "$next_ts" ] && renew_date=$(date -d "@$next_ts" +%F 2>/dev/null || printf '%s' "Err"); fi
        fi
        local status_text=""; local color_code="${NC}"
        if [[ ! -f "$cert" ]]; then status_text="未安装"; color_code="${GRAY}"
        else
            local end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2); local end_ts=$(date -d "$end" +%s 2>/dev/null || printf '%s' "0")
            local now_ts=$(date +%s); local days=$(( (end_ts - now_ts) / 86400 ))
            if (( days < 0 )); then status_text="过期 ${days#-}天"; color_code="${BRIGHT_RED}"
            elif (( days <= 30 )); then status_text="${days}天续期"; color_code="${BRIGHT_RED}"
            else status_text="正常 ${days}天"; color_code="${GREEN}"; fi
        fi
        local line=""; line+="$(_center_text "$idx" "$w_id") "; line+="$(_center_text "$domain" "$w_domain") "; line+="$(_center_text "$display_target" "$w_target") "
        local status_len=${#status_text}; local s_pad=$(( w_status - status_len ))
        local s_left=$(( s_pad / 2 )); local s_right=$(( s_pad - s_left ))
        line+="%${s_left}s${color_code}${status_text}${NC}%${s_right}s "; line+="$(_center_text "$renew_date" "$w_renew")"
        printf "$line\n" "" ""
    done; printf '%b' "\n"
}

select_item_and_act() {
    local list_json="${1:-}" count="${2:-0}" prompt_text="${3:-}" id_field="${4:-}" action_fn="${5:-}"
    while true; do
        local choice_idx
        if ! choice_idx=$(prompt_input "$prompt_text" "" "^[0-9]*$" "无效序号" "true"); then return 0; fi
        if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then return 1; fi
        if [ "$choice_idx" -gt "$count" ]; then log_message ERROR "序号越界"; continue; fi
        local selected_id
        selected_id=$(jq -r ".[$((choice_idx-1))].${id_field}" <<< "$list_json")
        "$action_fn" "$selected_id"
        local action_ret=$?
        if [ "$action_ret" -eq 2 ]; then return 1; fi
    done
}

_manage_http_actions() {
    local selected_domain="${1:-}"
    _render_menu "管理: $selected_domain" "1. 查看证书详情 (中文诊断)" "2. 手动续期" "3. 删除项目" "4. 查看 Nginx 配置" "5. 重新配置 (目标/防御/Hook等)" "6. 修改证书申请与续期设置" "7. 添加自定义指令" "8. 切换 Cloudflare 严格防御"
    local cc
    if ! cc=$(prompt_menu_choice "1-8" "true"); then return 0; fi
    case "$cc" in
        1) _handle_cert_details "$selected_domain" ;;
        2) _handle_renew_cert "$selected_domain" ;;
        3) _handle_delete_project "$selected_domain"; return 2 ;;
        4) _handle_view_config "$selected_domain" ;;
        5) _handle_reconfigure_project "$selected_domain" ;;
        6) _handle_modify_renew_settings "$selected_domain" ;;
        7) _handle_set_custom_config "$selected_domain" ;;
        8) _handle_toggle_cf_strict "$selected_domain" ;;
        "") return 0 ;;
    esac
    return 0
}

_manage_tcp_actions() {
    local selected_port="${1:-}"
    _render_menu "管理 TCP: 端口 $selected_port" "1. 删除项目" "2. 查看配置"
    local cc
    if ! cc=$(prompt_menu_choice "1-2" "true"); then return 0; fi
    case "$cc" in
        1)
            if confirm_or_cancel "确认删除 TCP 代理 $selected_port?"; then
                if _require_safe_path "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" "删除配置"; then
                    rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf"
                fi
                if _require_safe_path "$NGINX_STREAM_ENABLED_DIR/tcp_${selected_port}.conf" "删除配置"; then
                    rm -f "$NGINX_STREAM_ENABLED_DIR/tcp_${selected_port}.conf"
                fi
                snapshot_json "$TCP_PROJECTS_METADATA_FILE"; local temp=$(mktemp)
                chmod 600 "$temp"
                jq --arg p "$selected_port" 'del(.[] | select(.listen_port == $p))' "$TCP_PROJECTS_METADATA_FILE" > "$temp" && mv "$temp" "$TCP_PROJECTS_METADATA_FILE"
                NGINX_RELOAD_NEEDED="true"
                control_nginx_reload_if_needed
                log_message SUCCESS "TCP 项目 $selected_port 删除成功。"
            fi
            ;;
        2)
            local conf_file="$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf"
            if _require_safe_path "$conf_file" "查看配置" && [ -f "$conf_file" ]; then
                cat "$conf_file"
            else
        printf '%b' "配置文件不存在\n"
            fi
            ;;
        "") return 0 ;;
    esac
    return 0
}

manage_configs() {
    _generate_op_id
    while true; do
    local all count
    all=$(jq . "$PROJECTS_METADATA_FILE")
    count=$(jq 'length' <<< "$all")
        if [ "$count" -eq 0 ]; then log_message WARN "暂无项目。"; break; fi
    printf '%b' "\n"; _display_projects_list "$all"
        if ! select_item_and_act "$all" "$count" "请输入序号选择项目 (回车返回)" "domain" _manage_http_actions; then break; fi
    done
}

_handle_renew_cert() {
    local d="${1:-}"; local p=$(_get_project_json "$d")
    [ -z "$p" ] && return
    _generate_op_id
    NGINX_RELOAD_NEEDED="true"
    if _issue_and_install_certificate "$p" && control_nginx_reload_if_needed; then
        printf '%b' "已续期: ${d}\n"
        printf '%b' "请返回项目列表继续操作。\n"
    else
        printf '%b' "续期失败: ${d}\n"
        printf '%b' "请查看日志后重试。\n"
    fi
    press_enter_to_continue
}
_handle_delete_project() {
    local d="${1:-}"
    _generate_op_id
    if confirm_or_cancel "确认彻底删除 $d 及其证书?"; then
        _remove_and_disable_nginx_config "$d"
        "$ACME_BIN" --remove -d "$d" --ecc >/dev/null 2>&1 || true
        if _require_safe_path "$SSL_CERTS_BASE_DIR/$d.cer" "删除证书"; then rm -f "$SSL_CERTS_BASE_DIR/$d.cer"; fi
        if _require_safe_path "$SSL_CERTS_BASE_DIR/$d.key" "删除证书"; then rm -f "$SSL_CERTS_BASE_DIR/$d.key"; fi
        _delete_project_json "$d"
        NGINX_RELOAD_NEEDED="true"
        if control_nginx_reload_if_needed; then
            printf '%b' "已删除: ${d}\n"
            printf '%b' "配置已重载。\n"
        else
            printf '%b' "已删除: ${d}\n"
            printf '%b' "Nginx 重载失败,请手动处理。\n"
        fi
    else
        printf '%b' "已取消删除。\n"
    fi
    press_enter_to_continue
}
_handle_view_config() { _view_nginx_config "${1:-}"; }
_handle_reconfigure_project() {
    local d="${1:-}"; local cur=$(_get_project_json "$d"); log_message INFO "正在重配 $d ..."
    _generate_op_id
    local port
    local mode=""
    port=$(jq -r .resolved_port <<< "$cur")
    [ "$port" == "cert_only" ] && mode="cert_only"
    local skip_cert="true"; if confirm_or_cancel "是否连同证书也重新申请/重载?"; then skip_cert="false"; fi
    local new; if ! new=$(_gather_project_details "$cur" "$skip_cert" "$mode"); then log_message WARN "取消。"; return; fi
    snapshot_project_json "$d" "$cur"
    if [ "$skip_cert" == "false" ]; then if ! _issue_and_install_certificate "$new"; then log_message ERROR "证书申请失败。"; return 1; fi; fi
    if [ "$mode" != "cert_only" ]; then _write_and_enable_nginx_config "$d" "$new"; fi
    NGINX_RELOAD_NEEDED="true"
    if _save_project_json "$new" && control_nginx_reload_if_needed; then
        printf '%b' "重配完成: ${d}\n"
        if [ -n "$LAST_CERT_ELAPSED" ]; then printf '%b' "申请耗时: ${LAST_CERT_ELAPSED}\n"; fi
        if [ -n "$LAST_CERT_CERT" ] && [ -n "$LAST_CERT_KEY" ]; then
            printf '%b' "证书路径: ${LAST_CERT_CERT}\n"
            printf '%b' "私钥路径: ${LAST_CERT_KEY}\n"
        fi
        if [ "$mode" != "cert_only" ]; then
            printf '%b' "网站已上线: https://$(jq -r .domain <<< "$new")\n"
        fi
        printf '%b' "已重载 Nginx。\n"
    else
        printf '%b' "重配失败: ${d}\n"
        printf '%b' "已回滚到原配置。\n"
        _save_project_json "$cur"
        if [ "$mode" != "cert_only" ]; then _write_and_enable_nginx_config "$d" "$cur"; fi
        NGINX_RELOAD_NEEDED="true"
        control_nginx_reload_if_needed || true
    fi
    press_enter_to_continue
}
_handle_modify_renew_settings() {
    local d="${1:-}"
    local cur
    local current_method
    cur=$(_get_project_json "$d")
    current_method=$(jq -r '.acme_validation_method' <<< "$cur")
    _generate_op_id
    if [ "$current_method" == "reuse" ]; then log_message WARN "此项目正在复用泛域名证书,请前往主域名修改续期设置。"; press_enter_to_continue; return; fi
    local -a lines=(); lines+=("${CYAN}选择新的 CA 机构:${NC}"); lines+=("1. Let's Encrypt"); lines+=("2. ZeroSSL"); lines+=("3. Google Public CA"); lines+=("4. 保持不变")
    _render_menu "修改证书续期设置: $d" "${lines[@]}"
    local ca_choice; if ! ca_choice=$(prompt_menu_choice "1-4" "false"); then return; fi
    local ca_server
    local ca_name
    ca_server=$(jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"' <<< "$cur")
    ca_name=$(jq -r '.ca_server_name // "letsencrypt"' <<< "$cur")
    case "$ca_choice" in 1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;; 2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;; 3) ca_server="google"; ca_name="google" ;; esac
    printf '%b' "\n"; printf '%b' "${CYAN}选择新的验证方式:${NC}\n"; printf '%b' " 1. http-01 (智能 Webroot)\n"; printf '%b' " 2. dns_cf (Cloudflare API)\n"; printf '%b' " 3. dns_ali (阿里云 API)\n"; printf '%b' " 4. 保持不变\n"
    local v_choice; if ! v_choice=$(prompt_menu_choice "1-4" "false"); then return; fi
    local method
    local provider
    method=$(jq -r '.acme_validation_method // "http-01"' <<< "$cur")
    provider=$(jq -r '.dns_api_provider // ""' <<< "$cur")
    case "$v_choice" in 1) method="http-01"; provider="" ;; 2) method="dns-01"; provider="dns_cf" ;; 3) method="dns-01"; provider="dns_ali" ;; esac
    local new_json
    new_json=$(jq --arg cu "$ca_server" --arg cn "$ca_name" --arg m "$method" --arg dp "$provider" '.ca_server_url=$cu | .ca_server_name=$cn | .acme_validation_method=$m | .dns_api_provider=$dp' <<< "$cur")
    snapshot_project_json "$d" "$cur"
    if _save_project_json "$new_json"; then
        printf '%b' "已更新: 证书续期设置 (CA/验证方式)\n"
        printf '%b' "下次续期将自动应用。\n"
    else
        printf '%b' "保存失败: 证书续期设置\n"
        printf '%b' "已回滚到原配置。\n"
        _save_project_json "$cur"
    fi
    press_enter_to_continue
}
_handle_set_custom_config() {
    local d="${1:-}"
    local cur
    local current_val
    cur=$(_get_project_json "$d")
    current_val=$(jq -r '.custom_config // "无"' <<< "$cur")
    _generate_op_id
    printf '%b' "\n${CYAN}当前自定义配置:${NC}\n${current_val}\n${YELLOW}请输入完整的 Nginx 指令 (需以分号结尾)。回车不修改; 输入 'clear' 清空${NC}\n"
    local new_val; if ! new_val=$(prompt_input "指令内容" "" "" "" "true"); then return; fi
    if [ -z "$new_val" ]; then return; fi
    local json_val="$new_val"
    local new_json
    [ "$new_val" == "clear" ] && json_val=""
    new_json=$(jq --arg v "$json_val" '.custom_config = $v' <<< "$cur")
    snapshot_project_json "$d" "$cur"
    if _save_project_json "$new_json"; then
        NGINX_RELOAD_NEEDED="true"
        if _write_and_enable_nginx_config "$d" "$new_json" && control_nginx_reload_if_needed; then
            printf '%b' "已应用: 自定义指令\n"
            printf '%b' "Nginx 已重载。\n"
        else
            printf '%b' "应用失败: 自定义指令\n"
            printf '%b' "已回滚配置。\n"
            _save_project_json "$cur"
            _write_and_enable_nginx_config "$d" "$cur"
            NGINX_RELOAD_NEEDED="true"
            control_nginx_reload_if_needed || true
        fi
    fi
    press_enter_to_continue
}

_handle_toggle_cf_strict() {
    local d="${1:-}"
    local cur
    local current
    cur=$(_get_project_json "$d")
    current=$(jq -r '.cf_strict_mode // "n"' <<< "$cur")
    local target="y"; [ "$current" = "y" ] && target="n"
    local label="开启"; [ "$target" = "n" ] && label="关闭"
    if ! confirm_or_cancel "是否${label} Cloudflare 严格防御? (仅适用于开启 CDN)" "n"; then return; fi
    local new_json
    new_json=$(jq --arg v "$target" '.cf_strict_mode = $v' <<< "$cur")
    snapshot_project_json "$d" "$cur"
    if _save_project_json "$new_json"; then
        _write_and_enable_nginx_config "$d" "$new_json"
        NGINX_RELOAD_NEEDED="true"
        if control_nginx_reload_if_needed; then
            printf '%b' "已${label} Cloudflare 严格防御。\n"
            printf '%b' "配置已重载。\n"
        else
            printf '%b' "操作失败: Nginx 重载失败\n"
            printf '%b' "已回滚配置。\n"
            _save_project_json "$cur"
            _write_and_enable_nginx_config "$d" "$cur"
            NGINX_RELOAD_NEEDED="true"
            control_nginx_reload_if_needed || true
        fi
    else
        printf '%b' "保存失败: 严格防御设置\n"
    fi
    press_enter_to_continue
}
_handle_cert_details() {
    local d="${1:-}"; local cur=$(_get_project_json "$d"); local cert="$SSL_CERTS_BASE_DIR/$d.cer"
    _generate_op_id
    local key_path="${SSL_CERTS_BASE_DIR}/${d}.key"
    local method
    method=$(jq -r '.acme_validation_method // ""' <<< "$cur")
    if [ "$method" = "reuse" ]; then
        local primary_domain
        primary_domain=$(jq -r '.domain // ""' <<< "$cur")
        if [ -z "$primary_domain" ] || [ "$primary_domain" = "null" ]; then primary_domain="$d"; fi
        cert=$(jq -r '.cert_file // empty' <<< "$cur")
        key_path=$(jq -r '.key_file // empty' <<< "$cur")
        if [ -z "$cert" ] || [ "$cert" = "null" ]; then cert="$SSL_CERTS_BASE_DIR/$primary_domain.cer"; fi
        if [ -z "$key_path" ] || [ "$key_path" = "null" ]; then key_path="$SSL_CERTS_BASE_DIR/$primary_domain.key"; fi
    fi
    if [ -f "$cert" ]; then
        local -a lines=()
        local issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed -n 's/.*O = \([^,]*\).*/\1/p' || printf '%s' "未知")
        local subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed -n 's/.*CN = \([^,]*\).*/\1/p' || printf '%s' "未知")
        local end_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2); local end_ts=$(date -d "$end_date" +%s 2>/dev/null || printf '%s' "0")
        local days=$(( (end_ts - $(date +%s)) / 86400 ))
        local dns_names=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:\K[^,]+' | xargs | sed 's/ /, /g' || printf '%s' "无")
        local provider
        local method_zh="未知"
        provider=$(jq -r '.dns_api_provider // ""' <<< "$cur")
        case "$method" in "http-01") method_zh="HTTP 网站根目录验证" ;; "dns-01") method_zh="DNS API 验证 (${provider:-未知})" ;; "reuse") method_zh="泛域名智能复用" ;; esac
        lines+=("${BOLD}颁发机构 (CA) :${NC} $issuer"); lines+=("${BOLD}证书主域名     :${NC} $subject"); lines+=("${BOLD}包含子域名     :${NC} $dns_names")
        lines+=("${BOLD}证书路径       :${NC} ${cert}")
        lines+=("${BOLD}私钥路径       :${NC} ${key_path}")
        if (( days < 0 )); then lines+=("${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${RED}(已过期 ${days#-} 天)${NC}")
        elif (( days <= 30 )); then lines+=("${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${BRIGHT_RED}(剩余 $days 天 - 急需续期)${NC}")
        else lines+=("${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${GREEN}(剩余 $days 天)${NC}"); fi
        lines+=("${BOLD}配置的验证方式 :${NC} $method_zh")
        _render_menu "证书详细诊断信息: $d" "${lines[@]}"
    else log_message ERROR "证书文件不存在: $cert"; fi
}

check_and_auto_renew_certs() {
    _generate_op_id
    if ! acquire_cert_lock; then return 1; fi
    log_message INFO "正在执行 Cron 守护检测并批量续期..."
    local success=0 fail=0
    local reload_needed="false"
    _renew_fail_cleanup
    local IFS=$'\1'
    while IFS=$'\1' read -r domain cert_file method; do
        [[ -z "$domain" ]] && continue; printf '%b' "检查: $domain ... "
        if [ "$method" == "reuse" ]; then printf '%b' "跳过(跟随主域)\n"; continue; fi
        local should_reload="false"
        if [ ! -f "$cert_file" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$cert_file"; then
            printf '%b' "${BRIGHT_RED}触发续期...${NC}\n"
            local project_json; project_json=$(_get_project_json "$domain")
            if [[ -n "$project_json" ]]; then
                if _issue_and_install_certificate "$project_json"; then
                    success=$((success+1))
                    _renew_fail_reset "$domain"
                    _send_tg_notify "success" "$domain" "证书已成功安装。" ""
                    should_reload="true"
                else
                    fail=$((fail+1))
                    local fcount
                    fcount=$(_renew_fail_incr "$domain")
                    if [ "$fcount" -ge "$RENEW_FAIL_THRESHOLD" ]; then
                        _send_tg_notify "fail" "$domain" "自动续签失败(${fcount}次)。" ""
                    else
                        log_message WARN "续签失败次数未达阈值(${fcount}/${RENEW_FAIL_THRESHOLD})，暂不通知。"
                    fi
                fi
            else log_message ERROR "无法读取 $domain 的配置元数据"; fail=$((fail+1)); fi
        else printf '%b' "${GREEN}有效期充足${NC}\n"; fi
        if [ "$should_reload" = "true" ]; then reload_needed="true"; fi
    done < <(jq -r '.[] | "\(.domain)\1\(.cert_file)\1\(.acme_validation_method)' "$PROJECTS_METADATA_FILE" 2>/dev/null)
    unset IFS
    NGINX_RELOAD_NEEDED="${reload_needed}"
    control_nginx_reload_if_needed || true
    log_message INFO "批量任务结束: $success 成功, $fail 失败。"
}

configure_nginx_projects() {
    _generate_op_id
    local mode="${1:-standard}"; local json
    printf '%b' "\n${CYAN}开始配置新项目...${NC}\n"
    if ! json=$(_gather_project_details "{}" "false" "$mode"); then log_message WARN "用户取消配置。"; return; fi
    
    _issue_and_install_certificate "$json"
    local ret=$?
    local domain method
    IFS=$'\t' read -r domain method < <(jq -r '[.domain, (.acme_validation_method // "")] | @tsv' <<< "$json")
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    if [ -f "$cert" ] || [ "$method" = "reuse" ]; then
        snapshot_project_json "$domain" "$json"
        _save_project_json "$json"
        if [ "$mode" != "cert_only" ]; then _write_and_enable_nginx_config "$domain" "$json"; fi
        NGINX_RELOAD_NEEDED="true"
        if control_nginx_reload_if_needed; then
            log_message SUCCESS "配置已保存。"
            if [ -n "$LAST_CERT_ELAPSED" ]; then printf '%b' "\n申请耗时: ${LAST_CERT_ELAPSED}\n"; fi
            if [ -n "$LAST_CERT_CERT" ] && [ -n "$LAST_CERT_KEY" ]; then
                printf '%b' "证书路径: ${LAST_CERT_CERT}\n"
                printf '%b' "私钥路径: ${LAST_CERT_KEY}\n"
            fi
            if [ "$mode" != "cert_only" ]; then
                printf '%b' "\n网站已上线: https://${domain}\n"
            fi
        else
            log_message WARN "配置已保存,但 Nginx 重载失败,请手动处理。"
        fi
    else log_message ERROR "证书申请失败,未保存。"; fi
}

# ==============================================================================
# SECTION: 主流程 UI
# ==============================================================================

main_menu() {
    _generate_op_id
    while true; do
        _draw_dashboard
        printf '%b' "${PURPLE}【HTTP(S) 业务】${NC}\n"
        printf '%b' " 1. 配置新域名反代 (支持泛域名免代理)\n"
        printf '%b' " 2. HTTP 项目管理\n"
        printf '%b' " 3. 仅申请证书 (S-UI/V2Ray 专用)\n"
        printf '%b' "\n"
        printf '%b' "${PURPLE}【TCP 负载均衡】${NC}\n"
        printf '%b' " 4. 配置 TCP 反代/负载均衡\n"
        printf '%b' " 5. 管理 TCP 反向代理\n"
        printf '%b' "\n"
        printf '%b' "${PURPLE}【运维监控与系统维护】${NC}\n"
        printf '%b' " 6. 批量续期\n"
        printf '%b' " 7. 查看日志 (Logs - Nginx/acme)\n"
        printf '%b' " 8. ${BRIGHT_RED}${BOLD}更新 Cloudflare 防御 IP 库${NC}\n"
        printf '%b' " 9. 备份/还原与配置重建\n"
        printf '%b' "10. 设置 Telegram 机器人通知\n"
        printf '%b' "\n"
        local c; if ! c=$(prompt_menu_choice "1-10" "true"); then break; fi
        case "$c" in
            1) configure_nginx_projects; press_enter_to_continue ;;
            2) manage_configs ;;
            3) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            4) configure_tcp_proxy; press_enter_to_continue ;;
            5) manage_tcp_configs ;;
            6) if confirm_or_cancel "确认检查所有项目?"; then check_and_auto_renew_certs; press_enter_to_continue; fi ;;
            7) _render_menu "查看日志" "1. Nginx 全局访问/错误日志" "2. acme.sh 证书运行日志"
               local log_c; if log_c=$(prompt_menu_choice "1-2" "true"); then [ "$log_c" = "1" ] && _view_nginx_global_log || _view_acme_log; press_enter_to_continue; fi ;;
            8) _update_cloudflare_ips; press_enter_to_continue ;;
            9) _handle_backup_restore ;;
            10) setup_tg_notifier; press_enter_to_continue ;;
            "") return 10 ;;
            *) log_message ERROR "无效选择" ;;
        esac
    done
}

main() {
    _generate_op_id
    _resolve_log_file
    _parse_args "$@"
    sanitize_noninteractive_flag
    require_sudo_or_die
    if ! validate_args "$@"; then return 1; fi
    if ! acquire_http_lock; then return 1; fi
    if ! check_root; then return 1; fi
    if ! check_os_compatibility; then return 1; fi
    if ! check_dependencies; then
        install_dependencies
    fi
    initialize_environment

    if [[ " $* " =~ " --check " ]]; then run_diagnostics; return $?; fi
    if [[ " $* " =~ " --cron " ]]; then check_and_auto_renew_certs; return $?; fi

    if ! install_acme_sh; then
        return 1
    fi

    local menu_rc=0
    if main_menu; then
        return 0
    fi
    menu_rc=$?
    if [ "$menu_rc" -eq 10 ]; then
        return 10
    fi
    return "$menu_rc"
}

main "$@"
