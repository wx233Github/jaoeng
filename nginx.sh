#!/usr/bin/env bash
# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.33.1 - Stable Simplified)
# =============================================================

set -eEuo pipefail
IFS=$'\n\t'

readonly ERR_GENERAL=1
readonly ERR_INVALID_ARGS=2
readonly ERR_MISSING_DEPS=3
readonly ERR_RUNTIME=4

readonly NC="\033[0m"
readonly RED="\033[31m"
readonly GREEN="\033[32m"
readonly YELLOW="\033[33m"
readonly PURPLE="\033[35m"
readonly CYAN="\033[36m"
readonly BRIGHT_RED="\033[91m"
readonly BRIGHT_YELLOW="\033[93m"
readonly GRAY="\033[2m"
readonly BOLD="\033[1m"

readonly SCRIPT_PATH="$(realpath "$0")"
readonly OP_ID="$(date +%Y%m%d%H%M%S)-$$"

LOG_FILE="/var/log/nginx_ssl_manager.log"
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
TCP_PROJECTS_METADATA_FILE="/etc/nginx/tcp_projects.json"
JSON_BACKUP_DIR="/etc/nginx/projects_backups"
BACKUP_DIR="/root/nginx_ssl_backups"
TG_CONF_FILE="/etc/nginx/tg_notifier.conf"

RENEW_THRESHOLD_DAYS=30
DEPS_MARK_FILE="$HOME/.nginx_ssl_manager_deps_v2"

NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
NGINX_STREAM_AVAILABLE_DIR="/etc/nginx/stream-available"
NGINX_STREAM_ENABLED_DIR="/etc/nginx/stream-enabled"
NGINX_WEBROOT_DIR="/var/www/html"
SSL_CERTS_BASE_DIR="/etc/ssl"
NGINX_ACCESS_LOG="/var/log/nginx/access.log"
NGINX_ERROR_LOG="/var/log/nginx/error.log"

LOCK_FILE="/var/lock/nginx_ssl_manager.lock"

IS_INTERACTIVE_MODE="true"
VPS_IP=""
VPS_IPV6=""
ACME_BIN=""
STOPPED_SERVICE=""
LOCK_FD=""

# ========================= 通用工具 =========================

_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_write() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local line="[$(_timestamp)] [${level}] [op:${OP_ID}] ${message}"

    if [ "$level" = "ERROR" ]; then
        printf '%s\n' "$line" >&2
    else
        printf '%s\n' "$line"
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s\n' "$line" >> "$LOG_FILE"
}

log_info() { _log_write "INFO" "$*"; }
log_warn() { _log_write "WARN" "$*"; }
log_error() { _log_write "ERROR" "$*"; }
log_success() { _log_write "INFO" "$*"; }

cleanup() {
    local exit_code=$?
    find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
    rm -f /tmp/tg_payload_*.json 2>/dev/null || true

    if [ -n "${STOPPED_SERVICE:-}" ]; then
        systemctl start "$STOPPED_SERVICE" >/dev/null 2>&1 || true
        STOPPED_SERVICE=""
    fi

    if [ "$exit_code" -ne 0 ]; then
        log_error "Script aborted with error code ${exit_code}"
    fi
}

report_err() {
    local code="${1:-$ERR_RUNTIME}"
    local line_no="${2:-0}"
    log_error "Error at line ${line_no}, exit code ${code}"
}

trap cleanup EXIT
trap 'report_err $? $LINENO' ERR
trap 'log_warn "收到中断信号，退出"; exit '"$ERR_RUNTIME" INT TERM

press_enter_to_continue() {
    read -r -p "$(echo -e "\n${YELLOW}按 Enter 键继续...${NC}")" < /dev/tty || true
}

render_menu() {
    local title="${1:-}"
    shift
    local -a lines=("$@")
    echo ""
    echo -e "${GREEN}========== ${title} ==========${NC}"
    local line=""
    for line in "${lines[@]}"; do
        echo -e "$line"
    done
    echo -e "${GREEN}================================${NC}"
}

prompt_menu_choice() {
    local range="${1:-}"
    local allow_empty="${2:-false}"
    local c=""
    while true; do
        read -r -p "$(echo -e "${BRIGHT_YELLOW}选项 [${range}]${NC} (Enter 返回): ")" c < /dev/tty || return 1
        if [ -z "$c" ] && [ "$allow_empty" = "true" ]; then
            echo ""
            return        fi if"[-z]+ then echo "$"
            return 0
        fi
    done
}

prompt_input() {
    local prompt="${1:-}"
    local default="${2:-}"
    local regex="${3:-}"
    local err_msg="${4:-格式错误}"
    local allow_empty="${5:-false}"
    local val=""

    while true; do
        if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            if [ -n "$default" ]; then
                echo -ne "${BRIGHT_YELLOW}${prompt}${NC} [默认: ${default}]: " >&2
            else
                echo -ne "${BRIGHT_YELLOW}${prompt}${NC}: " >&2
            fi
            read -r val < /dev/tty || return 1
            val="${val:-$default}"
        else
            val="$default"
        fi

        if [ -z "$val" ] && [ "$allow_empty" = "true" ]; then
            echo ""
            return 0
        fi
        if [ -z "$val" ]; then
            log_error "输入不能为空"
            [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1
            continue
        fi
        if [ -n "$regex" ] && [[ ! "$val" =~ $regex ]]; then
            log_error "$err_msg"
            [ "$IS_INTERACTIVE_MODE" = "false" ] && return 1
            continue
        fi

        echo "$val"
        return 0
    done
}

prompt_secret() {
    local prompt="${1:-}"
    local val=""
    echo -ne "${BRIGHT_YELLOW}${prompt} (无屏幕回显): ${NC}" >&2
    read -rs val < /dev/tty || return 1
    echo "" >&2
    echo "$val"
}

confirm_or_cancel() {
    local msg="${1:-确认继续?}"
    if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local c=""
        read -r -p "$(echo -e "${BRIGHT_YELLOW}${msg} ([y]/n): ${NC}")" c < /dev/tty || return 1
        case "$c" in
            n|N) return 1 ;;
            *) return 0 ;;
        esac
    fi
    log_error "非交互模式无法确认: ${msg}"
    return 1
}

# ========================= 参数/依赖/启动 =========================

validate_args() {
    local arg=""
    for arg in "$@"; do
        case "$arg" in
            --cron|--non-interactive) ;;
            *)
                log_error "未知参数: ${arg}"
                return "$ERR_INVALID_ARGS"
                ;;
        esac
    done
    return 0
}

parse_args() {
    local arg=""
    IS_INTERACTIVE_MODE="true"
    for arg in "$@"; do
        if [ "$arg" = "--cron" ] || [ "$arg" = "--non-interactive" ]; then
            IS_INTERACTIVE_MODE="false"
        fi
    done
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 用户运行"
        return 1
    fi
    return 0
}

check_os_compatibility() {
    if [ -f "/etc/os-release" ]; then
        # shellcheck disable=SC1091
        . "/etc/os-release"
        if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
            log_warn "检测到非 Debian/Ubuntu 系统: ${NAME:-unknown}"
            if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
                confirm_or_cancel "是否继续?" || return "$ERR_GENERAL"
            fi
        fi
    fi
    return 0
}

install_dependencies() {
    if [ -f "$DEPS_MARK_FILE" ]; then
        return 0
    fi

    local -a pkgs=(nginx curl socat openssl jq idn dnsutils nano)
    local -a missing=()
    local pkg=""
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1 && ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        log_info "安装依赖: ${missing[*]}"
        apt update -y >/dev/null 2>&1 || true
        if ! apt install -y "${missing[@]}" >/dev/null 2>&1; then
            log_error "依赖安装失败: ${missing[*]}"
            return 1
        fi
    fi

    touch "$DEPS_MARK_FILE"
    return 0
}

check_dependencies() {
    local -a required=(nginx curl socat openssl jq idn sed awk grep date uptime find mktemp tar systemctl realpath flock crontab ss)
    local -a missing=()
    local cmd=""
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log_error "缺失必要命令: ${missing[*]}"
        return "$ERR_MISSING_DEPS"
    fi
    return 0
}

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        log_error "另一个实例正在运行"
        return "$ERR_RUNTIME"
    fi
    return 0
}

# ========================= 校验/安全 =========================

_validate_domain() {
    local d="${1:-}"
    [[ "$d" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

_validate_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

_validate_ip_or_hostname_port() {
    local val="${1:-}"
    [[ "$val" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]] || return 1
    _validate_port "${val##*:}"
}

_validate_target_list() {
    local target="${1:-}"
    [[ "$target" =~ ^[a-zA-Z0-9.-]+:[0-9]+(,[a-zA-Z0-9.-]+:[0-9]+)*$ ]] || return 1
    local -a arr=()
    local item=""
    IFS=',' read -r -a arr <<< "$target"
    for item in "${arr[@]}"; do
        _validate_ip_or_hostname_port "$item" || return 1
    done
    return 0
}

_validate_email() {
    local email="${1:-}"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

_validate_reload_cmd() {
    local cmd="${1:-}"
    [ -z "$cmd" ] && return 0
    if [[ "$cmd" =~ ^systemctl[[:space:]]+restart[[:space:]]+[a-zA-Z0-9@_.-]+$ ]]; then
        return 0
    fi
    [ "$cmd" = "systemctl reload nginx" ]
}

_validate_nginx_directive() {
    local line="${1:-}"
    [ -z "$line" ] && return 0
    case "$line" in
        *"`"*|*"$("*|*"{"*|*"}"*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    [[ "$line" =~ ;$ ]]
}

_is_allowed_custom_directive() {
    local line="${1:-}"
    local key=""
    key="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([a-zA-Z0-9_]+).*/\1/')"
    case "$key" in
        client_max_body_size|add_header|set|more_set_headers|proxy_*|gzip_*) return 0 ;;
    esac
    return 1
}

_validate_custom_config_block() {
    local block="${1:-}"
    [ -z "$block" ] && return 0
    local line=""
    while IFS= read -r line; do
        _validate_nginx_directive "$line" || return 1
        _is_allowed_custom_directive "$line" || return 1
    done <<< "$block"
    return 0
}

# ========================= 环境初始化 =========================

get_vps_ip() {
    if [ -z "$VPS_IP" ]; then
        VPS_IP="$(curl -s --connect-timeout 3 https://api.ipify.org || echo "")"
        VPS_IPV6="$(curl -s -6 --connect-timeout 3 https://api64.ipify.org 2>/dev/null || echo "")"
    fi
}

init_json_files() {
    mkdir -p "$JSON_BACKUP_DIR"
    if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" >/dev/null 2>&1; then
        echo "[]" > "$PROJECTS_METADATA_FILE"
    fi
    if [ ! -f "$TCP_PROJECTS_METADATA_FILE" ] || ! jq -e . "$TCP_PROJECTS_METADATA_FILE" >/dev/null 2>&1; then
        echo "[]" > "$TCP_PROJECTS_METADATA_FILE"
    fi
}

setup_logrotate() {
    [ -d /etc/logrotate.d ] || return 0

    if [ ! -f /etc/logrotate.d/nginx ]; then
        cat > /etc/logrotate.d/nginx <<'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        if [ -f /var/run/nginx.pid ]; then kill -USR1 "$(cat /var/run/nginx.pid)"; fi
    endscript
}
EOF
    fi

    if [ ! -f /etc/logrotate.d/nginx_ssl_manager ]; then
        cat > /etc/logrotate.d/nginx_ssl_manager <<EOF
${LOG_FILE} {
    weekly
    missingok
    rotate 12
    compress
    delaycompress
    notifempty
    create 0644 root root
}
EOF
    fi
}

initialize_environment() {
    ACME_BIN="$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1 || true)"
    [ -z "$ACME_BIN" ] && ACME_BIN="$HOME/.acme.sh/acme.sh"

    mkdir -p \
        "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" \
        "$NGINX_STREAM_AVAILABLE_DIR" "$NGINX_STREAM_ENABLED_DIR" \
        "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR" \
        "$BACKUP_DIR" "$JSON_BACKUP_DIR"

    init_json_files
    setup_logrotate

    if [ -f /etc/nginx/nginx.conf ] && ! grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
        cat >> /etc/nginx/nginx.conf <<EOF

# TCP/UDP Stream Proxy Auto-injected
stream {
    include ${NGINX_STREAM_ENABLED_DIR}/*.conf;
}
EOF
        systemctl reload nginx || true
    fi
}

install_acme_sh() {
    if [ -f "$ACME_BIN" ]; then
        return 0
    fi

    log_warn "acme.sh 未安装，开始安装..."
    local email=""
    email="$(prompt_input "注册邮箱(可留空)" "" "" "" "true")" || return 1

    if [ -n "$email" ] && ! _validate_email "$email"; then
        log_error "邮箱格式错误"
        return 1
    fi

    if [ -n "$email" ]; then
        curl -fsSL https://get.acme.sh | /bin/sh -s -- --email "$email" || return 1
    else
        curl -fsSL https://get.acme.sh | /bin/sh || return 1
    fi

    ACME_BIN="$(find "$HOME/.acme.sh" -name "acme.sh" 2>/dev/null | head -n 1 || true)"
    [ -n "$ACME_BIN" ] || { log_error "acme.sh 安装后未找到"; return 1; }

    "$ACME_BIN" --upgrade --auto-upgrade >/dev/null 2>&1 || true
    manage_cron_jobs
    log_success "acme.sh 安装完成"
    return 0
}

# ========================= JSON 数据层 =========================

snapshot_json() {
    local target="${1:-$PROJECTS_METADATA_FILE}"
    [ -f "$target" ] || return 0
    local base=""
    base="$(basename "$target" .json)"
    local snap="${JSON_BACKUP_DIR}/${base}_$(date +%Y%m%d_%H%M%S).json.bak"
    cp -f "$target" "$snap"
    ls -tp "${JSON_BACKUP_DIR}/${base}_"*.bak 2>/dev/null | tail -n +11 | xargs -r rm -f --
}

json_upsert_by_key() {
    local file="${1:-}"
    local key_name="${2:-}"
    local key_val="${3:-}"
    local obj_json="${4:-}"
    local tmp=""
    tmp="$(mktemp "$(dirname "$file")/.json.XXXXXX")"

    if jq -e --arg k "$key_val" --arg n "$key_name" '.[] | select(.[$n] == $k)' "$file" >/dev/null 2>&1; then
        if jq --argjson new_val "$obj_json" --arg k "$key_val" --arg n "$key_name" \
            'map(if .[$n] == $k then $new_val else . end)' "$file" > "$tmp"; then
            mv -f "$tmp" "$file"
            return 0
        fi
    else
        if jq --argjson new_val "$obj_json" '. + [$new_val]' "$file" > "$tmp"; then
            mv -f "$tmp" "$file"
            return 0
        fi
    fi

    rm -f "$tmp"
    return 1
}

project_get_by_domain() {
    local domain="${1:-}"
    jq -c --arg d "$domain" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo ""
}

project_save() {
    local json="${1:-}"
    [ -n "$json" ] || return 1
    local domain=""
    domain="$(echo "$json" | jq -r '.domain')"
    _validate_domain "$domain" || return 1
    snapshot_json "$PROJECTS_METADATA_FILE"
    json_upsert_by_key "$PROJECTS_METADATA_FILE" "domain" "$domain" "$json"
}

project_delete() {
    local domain="${1:-}"
    snapshot_json "$PROJECTS_METADATA_FILE"
    local tmp=""
    tmp="$(mktemp)"
    if jq --arg d "$domain" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" > "$tmp"; then
        mv -f "$tmp" "$PROJECTS_METADATA_FILE"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

tcp_project_save() {
    local json="${1:-}"
    [ -n "$json" ] || return 1
    local listen_port=""
    listen_port="$(echo "$json" | jq -r '.listen_port')"
    _validate_port "$listen_port" || return 1
    snapshot_json "$TCP_PROJECTS_METADATA_FILE"
    json_upsert_by_key "$TCP_PROJECTS_METADATA_FILE" "listen_port" "$listen_port" "$json"
}

# ========================= Nginx 配置层 =========================

control_nginx() {
    local action="${1:-reload}"
    if ! nginx -t >/dev/null 2>&1; then
        log_error "Nginx 配置错误"
        nginx -t || true
        return 1
    fi
    systemctl "$action" nginx || return 1
    return 0
}

write_http_conf() {
    local domain="${1:-}"
    local json="${2:-}"
    local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    local enabled="$NGINX_SITES_ENABLED_DIR/$domain.conf"

    [ -n "$json" ] || return 1
    _validate_domain "$domain" || return 1

    local port=""
    local cert=""
    local key=""
    local max_body=""
    local custom_cfg=""
    local cf_mode=""
    port="$(echo "$json" | jq -r '.resolved_port')"
    [ "$port" = "cert_only" ] && return 0
    _validate_port "$port" || return 1

    cert="$(echo "$json" | jq -r '.cert_file')"
    key="$(echo "$json" | jq -r '.key_file')"
    max_body="$(echo "$json" | jq -r '.client_max_body_size // empty')"
    custom_cfg="$(echo "$json" | jq -r '.custom_config // empty')"
    cf_mode="$(echo "$json" | jq -r '.cf_strict_mode // "n"')"

    local body_cfg=""
    local cf_cfg=""
    [ -n "$max_body" ] && body_cfg="client_max_body_size ${max_body};"
    if [ "$cf_mode" = "y" ]; then
        [ -f "/etc/nginx/snippets/cf_allow.conf" ] || update_cloudflare_ips
        cf_cfg="include /etc/nginx/snippets/cf_allow.conf;"
    fi

    get_vps_ip

    local tmp_conf=""
    local old_target=""
    tmp_conf="$(mktemp "${NGINX_SITES_AVAILABLE_DIR}/${domain}.conf.new.XXXXXX")"
    [ -L "$enabled" ] && old_target="$(readlink "$enabled" || true)"

    cat > "$tmp_conf" <<EOF
server {
    listen 80;
    $( [[ -n "$VPS_IPV6" ]] && echo "listen [::]:80;" )
    server_name ${domain};

    location /.well-known/acme-challenge/ { root ${NGINX_WEBROOT_DIR}; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    $( [[ -n "$VPS_IPV6" ]] && echo "listen [::]:443 ssl http2;" )
    server_name ${domain};

    ssl_certificate ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    add_header Strict-Transport-Security "max-age=31536000;" always;

    ${body_cfg}
    ${cf_cfg}
    ${custom_cfg}

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

    ln -sfn "$tmp_conf" "$enabled"
    if nginx -t >/dev/null 2>&1; then
        mv -f "$tmp_conf" "$conf"
        ln -sfn "$conf" "$enabled"
        return 0
    fi

    rm -f "$tmp_conf"
    if [ -n "$old_target" ]; then
        ln -sfn "$old_target" "$enabled"
    else
        rm -f "$enabled"
    fi
    log_error "Nginx HTTP 配置检测失败: ${domain}"
    return 1
}

remove_http_conf() {
    local domain="${1:-}"
    _validate_domain "$domain" || return 1
    rm -f "$NGINX_SITES_AVAILABLE_DIR/${domain}.conf" "$NGINX_SITES_ENABLED_DIR/${domain}.conf"
}

write_tcp_conf() {
    local port="${1:-}"
    local json="${2:-}"
    local conf="$NGINX_STREAM_AVAILABLE_DIR/tcp_${port}.conf"
    local enabled="$NGINX_STREAM_ENABLED_DIR/tcp_${port}.conf"

    _validate_port "$port" || return 1

    local target=""
    local tls=""
    target="$(echo "$json" | jq -r '.target')"
    tls="$(echo "$json" | jq -r '.tls_enabled // "n"')"
    _validate_target_list "$target" || return 1

    local listen_flag=""
    local ssl_block=""
    if [ "$tls" = "y" ]; then
        local ssl_cert=""
        local ssl_key=""
        ssl_cert="$(echo "$json" | jq -r '.ssl_cert')"
        ssl_key="$(echo "$json" | jq -r '.ssl_key')"
        listen_flag="ssl"
        ssl_block=$'\n'"    ssl_certificate ${ssl_cert};"$'\n'"    ssl_certificate_key ${ssl_key};"$'\n'"    ssl_protocols TLSv1.2 TLSv1.3;"
    fi

    local upstream_block=""
    local proxy_target="$target"
    if [[ "$target" == *","* ]]; then
        proxy_target="tcp_backend_${port}"
        upstream_block="upstream ${proxy_target} {"
        local -a arr=()
        local item=""
        IFS=',' read -r -a arr <<< "$target"
        for item in "${arr[@]}"; do
            upstream_block+=$'\n'"    server ${item};"
        done
        upstream_block+=$'\n''}'
    fi

    local tmp_conf=""
    local old_target=""
    tmp_conf="$(mktemp "${NGINX_STREAM_AVAILABLE_DIR}/tcp_${port}.conf.new.XXXXXX")"
    [ -L "$enabled" ] && old_target="$(readlink "$enabled" || true)"

    cat > "$tmp_conf" <<EOF
${upstream_block}
server {
    listen ${port} ${listen_flag};
    proxy_pass ${proxy_target};${ssl_block}
}
EOF

    ln -sfn "$tmp_conf" "$enabled"
    if nginx -t >/dev/null 2>&1; then
        mv -f "$tmp_conf" "$conf"
        ln -sfn "$conf" "$enabled"
        return 0
    fi

    rm -f "$tmp_conf"
    if [ -n "$old_target" ]; then
        ln -sfn "$old_target" "$enabled"
    else
        rm -f "$enabled"
    fi
    log_error "Nginx TCP 配置检测失败: ${port}"
    return 1
}

# ========================= DNS / CF =========================

check_dns_resolution() {
    local domain="${1:-}"
    log_info "DNS 预检: ${domain}"
    get_vps_ip

    local resolved=""
    if command -v dig >/dev/null 2>&1; then
        resolved="$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | xargs)"
    elif command -v host >/dev/null 2>&1; then
        resolved="$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $NF}' | xargs)"
    else
        log_warn "无 dig/host，跳过 DNS 预检"
        return 0
    fi

    if [ -z "$resolved" ]; then
        log_warn "域名未解析到 A 记录: ${domain}"
        confirm_or_cancel "是否继续申请?" || return 1
        return 0
    fi

    if [[ " $resolved " == *" $VPS_IP "* ]]; then
        log_success "DNS 校验通过: ${domain} -> ${VPS_IP}"
        return 0
    fi

    log_warn "DNS 与本机IP不匹配: ${resolved} / ${VPS_IP}"
    confirm_or_cancel "是否继续?" || return 1
    return 0
}

update_cloudflare_ips() {
    log_info "正在更新 Cloudflare IP 列表..."
    local tmp_allow=""
    local tmp_cf_allow=""
    local tmp_cf_real=""
    tmp_allow="$(mktemp)"
    tmp_cf_allow="$(mktemp)"
    tmp_cf_real="$(mktemp)"

    if curl -sS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 > "$tmp_allow" && \
       echo "" >> "$tmp_allow" && \
       curl -sS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 >> "$tmp_allow"; then

        mkdir -p /etc/nginx/snippets /etc/nginx/conf.d
        echo "# Cloudflare Allow List" > "$tmp_cf_allow"
        echo "# Cloudflare Real IP" > "$tmp_cf_real"

        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "allow $ip;" >> "$tmp_cf_allow"
            echo "set_real_ip_from $ip;" >> "$tmp_cf_real"
        done < <(grep -E '^[0-9a-fA-F.:]+(/[0-9]+)?$' "$tmp_allow")

        echo "deny all;" >> "$tmp_cf_allow"
        echo "real_ip_header CF-Connecting-IP;" >> "$tmp_cf_real"

        mv -f "$tmp_cf_allow" /etc/nginx/snippets/cf_allow.conf
        mv -f "$tmp_cf_real" /etc/nginx/conf.d/cf_real_ip.conf
        log_success "Cloudflare IP 库已更新"

    else
        log_error "Cloudflare IP 拉取失败"
    fi

    rm -f "$tmp_allow" "$tmp_cf_allow" "$tmp_cf_real" 2>/dev/null || true
}

# ========================= TG 通知 =========================

mask_string() {
    local s="${1:-}"
    local len=${#s}
    if [ "$len" -le 6 ]; then echo "***"; else echo "${s:0:2}***${s: -3}"; fi
}

mask_ip() {
    local ip="${1:-}"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip" | awk -F. '{print $1"."$2".*.*"}'
    elif [[ "$ip" =~ : ]]; then
        echo "$ip" | awk -F: '{print $1":"$2"::***"}'
    else
        echo "***"
    fi
}

load_tg_config() {
    [ -f "$TG_CONF_FILE" ] || return 1
    TG_BOT_TOKEN="$(grep '^TG_BOT_TOKEN=' "$TG_CONF_FILE" | cut -d= -f2- | sed 's/^"//;s/"$//')"
    TG_CHAT_ID="$(grep '^TG_CHAT_ID=' "$TG_CONF_FILE" | cut -d= -f2- | sed 's/^"//;s/"$//')"
    SERVER_NAME="$(grep '^SERVER_NAME=' "$TG_CONF_FILE" | cut -d= -f2- | sed 's/^"//;s/"$//')"
    return 0
}

send_tg_notify() {
    local status="${1:-}"
    local domain="${2:-}"
    local detail="${3:-}"
    local sname="${4:-}"
    local debug="${5:-false}"

    [ -f "$TG_CONF_FILE" ] || return 0
    load_tg_config || return 0
    [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || return 0

    get_vps_ip
    local title=""
    local status_text=""
    if [ "$status" = "success" ]; then
        title="证书续期成功"
        status_text="✅ 续订完成"
    else
        title="异常警报"
        status_text="⚠️ 续订失败"
    fi

    local payload=""
    payload="$(mktemp /tmp/tg_payload_XXXXXX.json)"
    jq -n \
        --arg cid "$TG_CHAT_ID" \
        --arg txt "<b>${title}</b>
🖥<b>服务器:</b> ${sname:-未知}
🌐<b>IPv4:</b> <code>$(mask_ip "$VPS_IP")</code>
📄<b>状态:</b> ${status_text}
🎯<b>域名:</b> <code>${domain}</code>
📃<b>描述:</b> <i>${detail}</i>" \
        '{chat_id:$cid,text:$txt,parse_mode:"HTML",disable_web_page_preview:true}' > "$payload"

    local resp=""
    local rc=0
    resp="$(curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d @"$payload" \
        --connect-timeout 10 --max-time 15 2>&1)" || rc=$?
    rm -f "$payload"

    [ "$debug" = "true" ] && echo -e "${CYAN}${resp}${NC}"

    if [ "$rc" -ne 0 ] || ! echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

setup_tg_notifier() {
    local curr_token=""
    local curr_chat=""
    local curr_name=""

    if [ -f "$TG_CONF_FILE" ]; then
        load_tg_config || true
        curr_token="${TG_BOT_TOKEN:-}"
        curr_chat="${TG_CHAT_ID:-}"
        curr_name="${SERVER_NAME:-}"
        render_menu "Telegram 当前配置" \
            "Token: $(mask_string "$curr_token")" \
            "Chat : $(mask_string "$curr_chat")" \
            "Name : ${curr_name}"
        confirm_or_cancel "是否重新配置/关闭?" || return
    fi

    echo "1. 开启/修改"
    echo "2. 关闭"
    local c=""
    c="$(prompt_menu_choice "1-2" "true")" || return
    if [ "$c" = "2" ]; then
        rm -f "$TG_CONF_FILE"
        log_success "TG 通知已关闭"
        return
    fi
    [ "$c" = "1" ] || return

    local tk=""
    local cid=""
    local sname=""
    tk="$(prompt_input "请输入 Bot Token" "$curr_token" "^[0-9]+:[A-Za-z0-9_-]+$" "格式错误" "false")" || return
    cid="$(prompt_input "请输入 Chat ID" "$curr_chat" "^-?[0-9]+$" "格式错误" "false")" || return
    sname="$(prompt_input "请输入服务器备注" "$curr_name" "" "" "false")" || return

    cat > "$TG_CONF_FILE" <<EOF
TG_BOT_TOKEN="${tk}"
TG_CHAT_ID="${cid}"
SERVER_NAME="${sname}"
EOF
    chmod 600 "$TG_CONF_FILE"

    if send_tg_notify "success" "test.example.com" "测试消息" "$sname" "true"; then
        log_success "TG 测试消息发送成功"
    else
        log_error "TG 测试消息发送失败"
    fi
}

# ========================= 证书逻辑 =========================

detect_web_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    local svc=""
    for svc in nginx apache2 httpd caddy; do
        if systemctl is-active --quiet "$svc"; then
            echo "$svc"
            return 0
        fi
    done
    return 0
}

issue_and_install_certificate() {
    local json="${1:-}"
    local domain=""
    local method=""
    local provider=""
    local wildcard=""
    local ca_server=""
    local cert=""
    local key=""
    local resolved_port=""
    local reload_cmd=""

    domain="$(echo "$json" | jq -r '.domain')"
    method="$(echo "$json" | jq -r '.acme_validation_method // "http-01"')"
    provider="$(echo "$json" | jq -r '.dns_api_provider // empty')"
    wildcard="$(echo "$json" | jq -r '.use_wildcard // "n"')"
    ca_server="$(echo "$json" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')"
    resolved_port="$(echo "$json" | jq -r '.resolved_port // empty')"
    reload_cmd="$(echo "$json" | jq -r '.reload_cmd // empty')"
    cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    key="$SSL_CERTS_BASE_DIR/$domain.key"

    if [ "$method" = "reuse" ]; then
        return 0
    fi

    if [ "$method" = "http-01" ]; then
        check_dns_resolution "$domain" || return 1
    fi

    local -a cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca_server" --log)
    [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

    local temp_conf=""
    local temp_conf_created="false"
    local stopped_svc=""

    if [ "$method" = "dns-01" ]; then
        if [ "$provider" = "dns_cf" ] && [ "$IS_INTERACTIVE_MODE" = "true" ]; then
            if confirm_or_cancel "是否输入新的 Cloudflare 凭证?"; then
                local t=""
                local a=""
                t="$(prompt_secret "CF_Token")" || return 1
                a="$(prompt_secret "CF_Account_ID")" || return 1
                [ -n "$t" ] && export CF_Token="$t"
                [ -n "$a" ] && export CF_Account_ID="$a"
            fi
        fi
        cmd+=("--dns" "$provider")
    else
        if ss -tuln 2>/dev/null | grep -qE ':(80|443)\s'; then
            local svc=""
            svc="$(detect_web_service)"
            if [ "$svc" = "nginx" ]; then
                temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"
                if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
                    cat > "$temp_conf" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }
EOF
                    ln -sf "$temp_conf" "$NGINX_SITES_ENABLED_DIR/"
                    systemctl reload nginx || true
                    temp_conf_created="true"
                fi
                mkdir -p "$NGINX_WEBROOT_DIR"
                cmd+=("--webroot" "$NGINX_WEBROOT_DIR")
            else
                if [ -n "$svc" ] && confirm_or_cancel "是否临时停止 ${svc} 释放 80 端口?"; then
                    systemctl stop "$svc" || true
                    stopped_svc="$svc"
                    STOPPED_SERVICE="$svc"
                fi
                cmd+=("--standalone")
            fi
        else
            cmd+=("--standalone")
        fi
    fi

    log_info "申请证书: ${domain} (${method})"
    local acme_log=""
    acme_log="$(mktemp /tmp/acme_cmd_log.XXXXXX)"
    if ! "${cmd[@]}" > "$acme_log" 2>&1; then
        log_error "证书申请失败: ${domain}"
        cat "$acme_log" >&2 || true
        rm -f "$acme_log"
        if [ -n "$stopped_svc" ]; then
            systemctl start "$stopped_svc" >/dev/null 2>&1 || true
            STOPPED_SERVICE=""
        fi
        send_tg_notify "fail" "$domain" "acme.sh 申请失败" ""
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret || true
        return 1
    fi
    rm -f "$acme_log"

    if [ "$temp_conf_created" = "true" ]; then
        rm -f "$temp_conf" "$NGINX_SITES_ENABLED_DIR/temp_acme_${domain}.conf"
        systemctl reload nginx || true
    fi
    if [ -n "$stopped_svc" ]; then
        systemctl start "$stopped_svc" >/dev/null 2>&1 || true
        STOPPED_SERVICE=""
    fi

    local install_reload_cmd=""
    if [ "$resolved_port" = "cert_only" ]; then
        install_reload_cmd="$reload_cmd"
    else
        install_reload_cmd="systemctl reload nginx"
    fi

    local -a inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
    [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
    [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")

    local inst_rc=0
    "${inst[@]}" >/dev/null 2>&1 || inst_rc=$?

    if [ -f "$cert" ] && [ -f "$key" ]; then
        [ "$inst_rc" -ne 0 ] && log_warn "证书安装成功，但 hook 执行失败: ${install_reload_cmd}"
        send_tg_notify "success" "$domain" "证书安装成功" ""
        unset CF_Token CF_Account_ID Ali_Key Ali_Secret || true
        return 0
    fi

    log_error "证书文件缺失: ${domain}"
    return 1
}

# ========================= 收集项目信息 =========================

gather_project_details() {
    exec 3>&1
    exec 1>&2

    local cur="${1:-{}}"
    local skip_cert="${2:-false}"
    local mode="${3:-standard}" # standard / cert_only

    local domain=""
    domain="$(echo "$cur" | jq -r '.domain // ""')"
    if [ -z "$domain" ]; then
        domain="$(prompt_input "主域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式无效" "false")" || { exec 1>&3; return 1; }
    fi
    _validate_domain "$domain" || { log_error "域名格式无效"; exec 1>&3; return 1; }

    if [ "$skip_cert" = "false" ]; then
        check_dns_resolution "$domain" || { exec 1>&3; return 1; }
    fi

    local type="cert_only"
    local name="证书"
    local resolved_port="cert_only"
    local max_body=""
    local custom_cfg=""
    local cf_strict="n"
    local reload_cmd=""
    max_body="$(echo "$cur" | jq -r '.client_max_body_size // empty')"
    custom_cfg="$(echo "$cur" | jq -r '.custom_config // empty')"
    cf_strict="$(echo "$cur" | jq -r '.cf_strict_mode // "n"')"
    reload_cmd="$(echo "$cur" | jq -r '.reload_cmd // empty')"

    if [ "$mode" != "cert_only" ]; then
        name="$(echo "$cur" | jq -r '.name // ""')"
        local target=""
        target="$(prompt_input "后端目标(容器名/端口/host:port)" "$name" "" "" "false")" || { exec 1>&3; return 1; }

        type="local_port"
        resolved_port="$target"

        if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
            type="docker"
            resolved_port="$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)"
            if [ -z "$resolved_port" ]; then
                resolved_port="$(prompt_input "未探测到容器映射端口，手动输入" "80" "^[0-9]+$" "端口错误" "false")" || { exec 1>&3; return 1; }
            fi
        elif _validate_ip_or_hostname_port "$target"; then
            type="remote_port"
            resolved_port="${target##*:}"
        else
            _validate_port "$target" || { log_error "后端目标无效"; exec 1>&3; return 1; }
        fi

        if confirm_or_cancel "是否启用 Cloudflare 严格防护?"; then
            cf_strict="y"
        else
            cf_strict="n"
        fi

        local mb=""
        mb="$(prompt_input "可选 client_max_body_size (回车保持)" "$max_body" "" "" "true")" || true
        [ -n "$mb" ] && max_body="$mb"

        local cc=""
        cc="$(prompt_input "可选自定义 Nginx 指令(回车保持)" "$custom_cfg" "" "" "true")" || true
        if [ -n "$cc" ]; then
            _validate_custom_config_block "$cc" || { log_error "自定义指令不安全"; exec 1>&3; return 1; }
            custom_cfg="$cc"
        fi
    else
        if [ "$skip_cert" = "false" ]; then
            render_menu "证书续期后重载 Hook" \
                "1. systemctl restart s-ui/x-ui(自动)" \
                "2. systemctl restart v2ray" \
                "3. systemctl restart xray" \
                "4. systemctl reload nginx" \
                "5. 自定义命令" \
                "6. 跳过"
            local hk=""
            hk="$(prompt_menu_choice "1-6" "false")" || { exec 1>&3; return 1; }
            case "$hk" in
                1)
                    if systemctl list-units --type=service | grep -q "s-ui.service"; then
                        reload_cmd="systemctl restart s-ui"
                    elif systemctl list-units --type=service | grep -q "x-ui.service"; then
                        reload_cmd="systemctl restart x-ui"
                    else
                        reload_cmd=""
                    fi
                    ;;
                2) reload_cmd="systemctl restart v2ray" ;;
                3) reload_cmd="systemctl restart xray" ;;
                4) reload_cmd="systemctl reload nginx" ;;
                5)
                    reload_cmd="$(prompt_input "请输入完整命令" "" "" "" "true")" || { exec 1>&3; return 1; }
                    _validate_reload_cmd "$reload_cmd" || { log_error "命令不安全"; exec 1>&3; return 1; }
                    ;;
                6) reload_cmd="" ;;
            esac
        fi
    fi

    # 证书策略
    local method="http-01"
    local provider=""
    local wildcard="n"
    local ca_server="https://acme-v02.api.letsencrypt.org/directory"
    local ca_name="letsencrypt"

    # 泛域名复用
    local reuse_wc="false"
    local wc_match=""
    local wc_cert=""
    local wc_key=""
    if [ "$skip_cert" = "false" ]; then
        local wd=""
        while IFS= read -r wd; do
            [ -z "$wd" ] && continue
            if [[ "$domain" == "$wd" || "$domain" == *".${wd}" ]]; then
                wc_match="$wd"
                break
            fi
        done < <(jq -r '.[] | select(.use_wildcard=="y" and .cert_file!=null and .key_file!=null) | .domain' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)

        if [ -n "$wc_match" ]; then
            echo -e "${GREEN}检测到可复用泛域名证书: *.${wc_match}${NC}" >&2
            if confirm_or_cancel "是否复用该证书?"; then
                reuse_wc="true"
                local wp=""
                wp="$(project_get_by_domain "$wc_match")"
                wc_cert="$(echo "$wp" | jq -r '.cert_file')"
                wc_key="$(echo "$wp" | jq -r '.key_file')"
            fi
        fi
    fi

    if [ "$reuse_wc" = "true" ]; then
        method="reuse"
        skip_cert="true"
    fi

    if [ "$skip_cert" = "false" ]; then
        render_menu "选择 CA" "1. Let's Encrypt" "2. ZeroSSL" "3. Google Public CA"
        local ca_choice=""
        ca_choice="$(prompt_menu_choice "1-3" "false")" || { exec 1>&3; return 1; }
        case "$ca_choice" in
            1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
            2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;;
            3) ca_server="google"; ca_name="google" ;;
        esac

        render_menu "验证方式" "1. http-01" "2. dns_cf" "3. dns_ali"
        local v=""
        v="$(prompt_menu_choice "1-3" "false")" || { exec 1>&3; return 1; }
        case "$v" in
            1) method="http-01"; provider="" ;;
            2) method="dns-01"; provider="dns_cf" ;;
            3) method="dns-01"; provider="dns_ali" ;;
        esac
        if [ "$method" = "dns-01" ]; then
            wildcard="$(prompt_input "是否申请泛域名? (y/n)" "n" "^[yYnN]$" "请输入 y 或 n" "false")" || { exec 1>&3; return 1; }
            wildcard="$(echo "$wildcard" | tr '[:upper:]' '[:lower:]')"
        fi
    else
        if [ "$reuse_wc" = "false" ]; then
            method="$(echo "$cur" | jq -r '.acme_validation_method // "http-01"')"
            provider="$(echo "$cur" | jq -r '.dns_api_provider // ""')"
            wildcard="$(echo "$cur" | jq -r '.use_wildcard // "n"')"
            ca_server="$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')"
            ca_name="$(echo "$cur" | jq -r '.ca_server_name // "letsencrypt"')"
        fi
    fi

    local cert_file="$SSL_CERTS_BASE_DIR/$domain.cer"
    local key_file="$SSL_CERTS_BASE_DIR/$domain.key"
    if [ "$reuse_wc" = "true" ]; then
        cert_file="$wc_cert"
        key_file="$wc_key"
    fi

    jq -n \
        --arg d "$domain" \
        --arg t "$type" \
        --arg n "$name" \
        --arg p "$resolved_port" \
        --arg m "$method" \
        --arg dp "$provider" \
        --arg w "$wildcard" \
        --arg cu "$ca_server" \
        --arg cn "$ca_name" \
        --arg cf "$cert_file" \
        --arg kf "$key_file" \
        --arg mb "$max_body" \
        --arg cc "$custom_cfg" \
        --arg cs "$cf_strict" \
        --arg rc "$reload_cmd" \
        '{domain:$d,type:$t,name:$n,resolved_port:$p,acme_validation_method:$m,dns_api_provider:$dp,use_wildcard:$w,ca_server_url:$cu,ca_server_name:$cn,cert_file:$cf,key_file:$kf,client_max_body_size:$mb,custom_config:$cc,cf_strict_mode:$cs,reload_cmd:$rc}' >&3

    exec 1>&3
}

# ========================= 业务动作：HTTP/TCP =========================

configure_nginx_projects() {
    local mode="${1:-standard}" # standard / cert_only

    echo -e "\n${CYAN}开始配置新项目...${NC}"
    local json=""
    json="$(gather_project_details "{}" "false" "$mode")" || { log_warn "用户取消"; return; }

    local issue_rc=0
    issue_and_install_certificate "$json" || issue_rc=$?

    local domain=""
    domain="$(echo "$json" | jq -r '.domain')"
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    if [ ! -f "$cert" ]; then
        log_error "证书申请失败，未保存"
        return 1
    fi

    project_save "$json" || { log_error "保存项目失败"; return 1; }

    if [ "$mode" != "cert_only" ]; then
        write_http_conf "$domain" "$json" || return 1
        control_nginx reload || return 1
        echo -e "${GREEN}网站已上线: https://${domain}${NC}"
    else
        echo -e "${GREEN}证书已就绪: ${cert}${NC}"
    fi

    [ "$issue_rc" -ne 0 ] && log_warn "证书安装阶段存在告警(如 hook 失败)"
    log_success "配置完成"
    return 0
}

configure_tcp_proxy() {
    render_menu "配置 TCP 代理"

    local name=""
    local listen_port=""
    local target=""
    local tls_enabled="n"
    local ssl_cert=""
    local ssl_key=""

    name="$(prompt_input "项目备注名称" "MyTCP" "" "" "false")" || return
    listen_port="$(prompt_input "本机监听端口" "" "^[0-9]+$" "端口错误" "false")" || return
    _validate_port "$listen_port" || { log_error "无效端口"; return; }

    target="$(prompt_input "目标地址(单节点或逗号负载)" "" "^[a-zA-Z0-9.-]+:[0-9]+(,[a-zA-Z0-9.-]+:[0-9]+)*$" "格式错误" "false")" || return
    _validate_target_list "$target" || { log_error "目标地址无效"; return; }

    if confirm_or_cancel "是否开启 TLS 卸载?"; then
        tls_enabled="y"
        local projects=""
        projects="$(jq -c '.[] | select(.cert_file!=null and .cert_file!="")' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)"
        [ -n "$projects" ] || { log_error "未发现可用证书"; return; }

        echo -e "\n${CYAN}请选择证书:${NC}"
        local idx=0
        local p=""
        local -a domains certs keys
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            idx=$((idx + 1))
            domains[$idx]="$(echo "$p" | jq -r '.domain')"
            certs[$idx]="$(echo "$p" | jq -r '.cert_file')"
            keys[$idx]="$(echo "$p" | jq -r '.key_file')"
            echo " ${idx}. ${domains[$idx]}"
        done <<< "$projects"

        local pick=""
        while true; do
            pick="$(prompt_input "输入序号" "" "^[0-9]+$" "无效序号" "false")" || return
            if [ "$pick" -ge 1 ] && [ "$pick" -le "$idx" ]; then
                ssl_cert="${certs[$pick]}"
                ssl_key="${keys[$pick]}"
                break
            fi
            log_error "序号越界"
        done
    fi

    local json=""
    json="$(jq -n \
        --arg n "$name" \
        --arg lp "$listen_port" \
        --arg t "$target" \
        --arg te "$tls_enabled" \
        --arg sc "$ssl_cert" \
        --arg sk "$ssl_key" \
        '{name:$n,listen_port:$lp,target:$t,tls_enabled:$te,ssl_cert:$sc,ssl_key:$sk}'
    )"

    write_tcp_conf "$listen_port" "$json" || return
    control_nginx reload || return
    tcp_project_save "$json" || return
    log_success "TCP 代理创建成功: ${listen_port}"
}

# ========================= 管理：HTTP =========================

display_projects_table() {
    local all="${1:-[]}"
    printf "${BOLD}%-4s %-28s %-16s %-16s${NC}\n" "ID" "域名" "目标" "证书状态"
    echo "----------------------------------------------------------------------------"

    local idx=0
    local p=""
    while IFS= read -r p; do
        idx=$((idx + 1))
        local d=""
        local rp=""
        local cert=""
        d="$(echo "$p" | jq -r '.domain')"
        rp="$(echo "$p" | jq -r '.resolved_port')"
        cert="$(echo "$p" | jq -r '.cert_file // ""')"

        local status="未安装"
        local color="$GRAY"
        if [ -f "$cert" ]; then
            local end=""
            local end_ts=0
            local now_ts=0
            local days=0
            end="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
            end_ts="$(date -d "$end" +%s 2>/dev/null || echo 0)"
            now_ts="$(date +%s)"
            days=$(( (end_ts - now_ts) / 86400 ))
            if (( days < 0 )); then
                status="过期${days#-}天"; color="$BRIGHT_RED"
            elif (( days <= 30 )); then
                status="${days}天续期"; color="$BRIGHT_YELLOW"
            else
                status="正常${days}天"; color="$GREEN"
            fi
        fi

        printf "%-4s %-28s %-16s %b\n" "$idx" "${d:0:28}" "${rp:0:16}" "${color}${status}${NC}"
    done < <(echo "$all" | jq -c '.[]')
    echo ""
}

view_http_config() {
    local domain="${1:-}"
    local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
    if [ ! -f "$conf" ]; then
        log_warn "配置文件不存在: $conf"
        return
    fi
    render_menu "配置文件: ${domain}"
    cat "$conf"
    press_enter_to_continue
}

handle_cert_details() {
    local domain="${1:-}"
    local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
    local cur=""
    cur="$(project_get_by_domain "$domain")"

    if [ ! -f "$cert" ]; then
        log_error "证书文件不存在: $cert"
        press_enter_to_continue
        return
    fi

    local issuer=""
    local subject=""
    local end=""
    local days=0
    local method=""
    issuer="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null || echo "issuer=未知")"
    subject="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || echo "subject=未知")"
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    method="$(echo "$cur" | jq -r '.acme_validation_method // "未知"')"

    echo -e "${CYAN}域名: ${domain}${NC}"
    echo "颁发者: $issuer"
    echo "主题:   $subject"
    echo "到期:   $end (剩余 ${days} 天)"
    echo "方式:   $method"
    press_enter_to_continue
}

handle_renew_cert() {
    local domain="${1:-}"
    local p=""
    p="$(project_get_by_domain "$domain")"
    [ -n "$p" ] || return
    issue_and_install_certificate "$p" && control_nginx reload || true
    press_enter_to_continue
}

handle_delete_project() {
    local domain="${1:-}"
    if confirm_or_cancel "确认删除项目 ${domain} 及其证书?"; then
        remove_http_conf "$domain" || true
        "$ACME_BIN" --remove -d "$domain" --ecc >/dev/null 2>&1 || true
        rm -f "$SSL_CERTS_BASE_DIR/$domain.cer" "$SSL_CERTS_BASE_DIR/$domain.key"
        project_delete "$domain" || true
        control_nginx reload || true
        log_success "项目已删除: ${domain}"
    fi
    press_enter_to_continue
}

handle_reconfigure_project() {
    local domain="${1:-}"
    local cur=""
    cur="$(project_get_by_domain "$domain")"
    [ -n "$cur" ] || return

    local mode="standard"
    if [ "$(echo "$cur" | jq -r '.resolved_port')" = "cert_only" ]; then
        mode="cert_only"
    fi

    local skip_cert="true"
    confirm_or_cancel "是否重新申请证书?" && skip_cert="false"

    local new_json=""
    new_json="$(gather_project_details "$cur" "$skip_cert" "$mode")" || { log_warn "已取消"; return; }

    if [ "$skip_cert" = "false" ]; then
        issue_and_install_certificate "$new_json" || { log_error "证书申请失败"; return; }
    fi

    if [ "$mode" != "cert_only" ]; then
        write_http_conf "$domain" "$new_json" || return
        control_nginx reload || return
    fi

    project_save "$new_json" || return
    log_success "重配完成"
    press_enter_to_continue
}

handle_modify_renew_settings() {
    local domain="${1:-}"
    local cur=""
    cur="$(project_get_by_domain "$domain")"
    [ -n "$cur" ] || return

    local current_method=""
    current_method="$(echo "$cur" | jq -r '.acme_validation_method')"
    if [ "$current_method" = "reuse" ]; then
        log_warn "该项目为复用证书，请在主域配置中修改"
        press_enter_to_continue
        return
    fi

    render_menu "修改续期设置" \
        "1. CA: Let's Encrypt" \
        "2. CA: ZeroSSL" \
        "3. CA: Google" \
        "4. CA: 保持"

    local ca_choice=""
    ca_choice="$(prompt_menu_choice "1-4" "false")" || return

    local ca_server=""
    local ca_name=""
    ca_server="$(echo "$cur" | jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"')"
    ca_name="$(echo "$cur" | jq -r '.ca_server_name // "letsencrypt"')"

    case "$ca_choice" in
        1) ca_server="https://acme-v02.api.letsencrypt.org/directory"; ca_name="letsencrypt" ;;
        2) ca_server="https://acme.zerossl.com/v2/DV90"; ca_name="zerossl" ;;
        3) ca_server="google"; ca_name="google" ;;
    esac

    render_menu "修改验证方式" \
        "1. http-01" \
        "2. dns_cf" \
        "3. dns_ali" \
        "4. 保持"

    local v_choice=""
    v_choice="$(prompt_menu_choice "1-4" "false")" || return

    local method=""
    local provider=""
    method="$(echo "$cur" | jq -r '.acme_validation_method // "http-01"')"
    provider="$(echo "$cur" | jq -r '.dns_api_provider // ""')"

    case "$v_choice" in
        1) method="http-01"; provider="" ;;
        2) method="dns-01"; provider="dns_cf" ;;
        3) method="dns-01"; provider="dns_ali" ;;
    esac

    local new_json=""
    new_json="$(echo "$cur" | jq --arg cu "$ca_server" --arg cn "$ca_name" --arg m "$method" --arg dp "$provider" \
        '.ca_server_url=$cu | .ca_server_name=$cn | .acme_validation_method=$m | .dns_api_provider=$dp')"

    if project_save "$new_json"; then
        log_success "续期设置已更新"
    else
        log_error "保存失败"
    fi
    press_enter_to_continue
}

handle_set_custom_config() {
    local domain="${1:-}"
    local cur=""
    cur="$(project_get_by_domain "$domain")"
    [ -n "$cur" ] || return

    local current_cfg=""
    current_cfg="$(echo "$cur" | jq -r '.custom_config // "无"')"
    echo -e "${CYAN}当前自定义配置:${NC}\n${current_cfg}"
    echo -e "${YELLOW}输入新指令(回车不修改，clear 清空)${NC}"

    local input_cfg=""
    input_cfg="$(prompt_input "指令内容" "" "" "" "true")" || return
    [ -z "$input_cfg" ] && return

    local final_cfg="$input_cfg"
    if [ "$input_cfg" = "clear" ]; then
        final_cfg=""
    else
        _validate_custom_config_block "$input_cfg" || { log_error "自定义指令不安全"; press_enter_to_continue; return; }
    fi

    local new_json=""
    new_json="$(echo "$cur" | jq --arg v "$final_cfg" '.custom_config=$v')"

    if project_save "$new_json"; then
        if write_http_conf "$domain" "$new_json" && control_nginx reload; then
            log_success "已应用自定义配置"
        else
            log_error "应用失败，尝试回滚..."
            write_http_conf "$domain" "$cur" || true
            control_nginx reload || true
        fi
    fi
    press_enter_to_continue
}

manage_configs() {
    while true; do
        local all=""
        all="$(jq . "$PROJECTS_METADATA_FILE" 2>/dev/null || echo "[]")"
        local count=0
        count="$(echo "$all" | jq 'length')"

        if [ "$count" -eq 0 ]; then
            log_warn "暂无 HTTP 项目"
            break
        fi

        display_projects_table "$all"
        local idx=""
        idx="$(prompt_input "请输入序号选择项目(回车返回)" "" "^[0-9]*$" "无效序号" "true")" || return
        [ -z "$idx" ] && break
        [ "$idx" -ge 1 ] && [ "$idx" -le "$count" ] || { log_error "序号越界"; continue; }

        local domain=""
        domain="$(echo "$all" | jq -r ".[$((idx-1))].domain")"

        render_menu "管理: ${domain}" \
            "1. 查看证书详情" \
            "2. 手动续期" \
            "3. 删除项目" \
            "4. 查看 Nginx 配置" \
            "5. 重新配置(目标/防护/Hook等)" \
            "6. 修改证书续期设置" \
            "7. 添加自定义指令"

        local c=""
        c="$(prompt_menu_choice "1-7" "true")" || continue
        case "$c" in
            1) handle_cert_details "$domain" ;;
            2) handle_renew_cert "$domain" ;;
            3) handle_delete_project "$domain"; break ;;
            4) view_http_config "$domain" ;;
            5) handle_reconfigure_project "$domain" ;;
            6) handle_modify_renew_settings "$domain" ;;
            7) handle_set_custom_config "$domain" ;;
            "") continue ;;
        esac
    done
}

# ========================= 管理：TCP =========================

manage_tcp_configs() {
    while true; do
        local all=""
        all="$(jq . "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo "[]")"
        local count=0
        count="$(echo "$all" | jq 'length')"

        if [ "$count" -eq 0 ]; then
            log_warn "暂无 TCP 项目"
            break
        fi

        printf "${BOLD}%-4s %-8s %-6s %-14s %-28s${NC}\n" "ID" "端口" "TLS" "备注" "目标"
        echo "--------------------------------------------------------------------------"

        local idx=0
        local p=""
        while IFS= read -r p; do
            idx=$((idx + 1))
            local port=""
            local tls=""
            local name=""
            local target=""
            port="$(echo "$p" | jq -r '.listen_port')"
            tls="$(echo "$p" | jq -r '.tls_enabled // "n"')"
            name="$(echo "$p" | jq -r '.name // "-"')"
            target="$(echo "$p" | jq -r '.target')"
            printf "%-4s %-8s %-6s %-14s %-28s\n" "$idx" "$port" "$tls" "${name:0:14}" "${target:0:28}"
        done < <(echo "$all" | jq -c '.[]')
        echo ""

        local pick=""
        pick="$(prompt_input "请输入序号选择 TCP 项目(回车返回)" "" "^[0-9]*$" "无效序号" "true")" || return
        [ -z "$pick" ] && break
        [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ] || { log_error "序号越界"; continue; }

        local selected_port=""
        selected_port="$(echo "$all" | jq -r ".[$((pick-1))].listen_port")"

        render_menu "管理 TCP: 端口 ${selected_port}" "1. 删除项目" "2. 查看配置"
        local c=""
        c="$(prompt_menu_choice "1-2" "true")" || continue
        case "$c" in
            1)
                if confirm_or_cancel "确认删除 TCP 代理 ${selected_port}?"; then
                    rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${selected_port}.conf"
                    snapshot_json "$TCP_PROJECTS_METADATA_FILE"
                    local tmp=""
                    tmp="$(mktemp)"
                    if jq --arg p "$selected_port" 'del(.[] | select(.listen_port == $p))' "$TCP_PROJECTS_METADATA_FILE" > "$tmp"; then
                        mv -f "$tmp" "$TCP_PROJECTS_METADATA_FILE"
                        control_nginx reload || true
                        log_success "TCP 项目删除成功: ${selected_port}"
                    else
                        rm -f "$tmp"
                        log_error "删除 TCP 元数据失败"
                    fi
                fi
                ;;
            2)
                cat "$NGINX_STREAM_AVAILABLE_DIR/tcp_${selected_port}.conf" 2>/dev/null || echo "配置文件不存在"
                press_enter_to_continue
                ;;
        esac
    done
}

# ========================= 续期/日志/备份 =========================

check_and_auto_renew_certs() {
    log_info "开始批量续期检测..."
    local success=0
    local fail=0
    local p=""

    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local d=""
        local cert_file=""
        local method=""
        d="$(echo "$p" | jq -r '.domain')"
        cert_file="$(echo "$p" | jq -r '.cert_file')"
        method="$(echo "$p" | jq -r '.acme_validation_method')"

        echo -ne "检查: ${d} ... "
        if [ "$method" = "reuse" ]; then
            echo "跳过(复用)"
            continue
        fi

        if [ ! -f "$cert_file" ] || ! openssl x509 -checkend $((RENEW_THRESHOLD_DAYS * 86400)) -noout -in "$cert_file" >/dev/null 2>&1; then
            echo -e "${YELLOW}触发续期${NC}"
            if issue_and_install_certificate "$p"; then
                success=$((success + 1))
            else
                fail=$((fail + 1))
            fi
        else
            echo -e "${GREEN}有效期充足${NC}"
        fi
    done < <(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)

    control_nginx reload || true
    log_info "批量续期完成: 成功=${success}, 失败=${fail}"
}

view_file_with_tail() {
    local file="${1:-}"
    [ -f "$file" ] || { log_error "文件不存在: $file"; return; }
    echo -e "${CYAN}--- tail -f ${file} (Ctrl+C 退出) ---${NC}"
    tail -f -n 50 "$file" || true
    echo -e "${CYAN}--- 日志查看结束 ---${NC}"
}

view_nginx_global_log() {
    render_menu "Nginx 全局日志" "1. 访问日志" "2. 错误日志"
    local c=""
    c="$(prompt_menu_choice "1-2" "true")" || return
    case "$c" in
        1) view_file_with_tail "$NGINX_ACCESS_LOG" ;;
        2) view_file_with_tail "$NGINX_ERROR_LOG" ;;
    esac
}

view_acme_log() {
    local f="$HOME/.acme.sh/acme.sh.log"
    [ -f "$f" ] || f="/root/.acme.sh/acme.sh.log"
    view_file_with_tail "$f"
}

manage_cron_jobs() {
    local has_acme=0
    local has_manager=0

    crontab -l 2>/dev/null | grep -q "\.acme\.sh/acme\.sh" && has_acme=1
    crontab -l 2>/dev/null | grep -F -q -- "$SCRIPT_PATH --cron" && has_manager=1

    render_menu "Cron 诊断" \
        "acme.sh 原生任务: $([ "$has_acme" -eq 1 ] && echo "正常" || echo "缺失")" \
        "本脚本守护任务 : $([ "$has_manager" -eq 1 ] && echo "正常" || echo "缺失")"

    if [ "$has_acme" -eq 0 ] || [ "$has_manager" -eq 0 ]; then
        "$ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
        local tmp=""
        tmp="$(mktemp /tmp/nginx_ssl_manager_cron.XXXXXX)"
        crontab -l 2>/dev/null | grep -F -v -- "$SCRIPT_PATH --cron" > "$tmp" || true
        printf '0 3 * * * "%s" --cron >> "%s" 2>&1\n' "$SCRIPT_PATH" "$LOG_FILE" >> "$tmp"
        crontab "$tmp"
        rm -f "$tmp"
        log_success "Cron 已修复"
    else
        log_info "Cron 状态健康，无需修复"
    fi

    press_enter_to_continue
}

rebuild_all_nginx_configs() {
    confirm_or_cancel "确认重建所有 HTTP 配置?" || return
    local all=""
    all="$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)"
    [ -n "$all" ] || { log_warn "无 HTTP 项目"; return; }

    local ok=0
    local bad=0
    local p=""
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local d=""
        local rp=""
        d="$(echo "$p" | jq -r '.domain')"
        rp="$(echo "$p" | jq -r '.resolved_port')"
        [ "$rp" = "cert_only" ] && continue
        if write_http_conf "$d" "$p"; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1))
        fi
    done <<< "$all"

    if control_nginx reload; then
        log_success "重建完成: 成功=${ok}, 失败=${bad}"
    else
        log_error "Nginx 重载失败"
    fi
}

handle_backup_restore() {
    render_menu "维护与灾备" \
        "1. 创建完整备份包" \
        "2. 从备份包还原" \
        "3. 从快照回滚元数据" \
        "4. 重建所有 HTTP 配置" \
        "5. 修复 Cron 任务"

    local c=""
    c="$(prompt_menu_choice "1-5" "true")" || return
    case "$c" in
        1)
            local ts=""
            ts="$(date +%Y%m%d_%H%M%S)"
            local backup_file="$BACKUP_DIR/nginx_manager_backup_${ts}.tar.gz"
            if tar -czf "$backup_file" -C / "$PROJECTS_METADATA_FILE" "$TCP_PROJECTS_METADATA_FILE" "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$SSL_CERTS_BASE_DIR" 2>/dev/null; then
                log_success "备份完成: ${backup_file}"
            else
                log_error "备份失败"
            fi
            ;;
        2)
            ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || { log_warn "无可用备份"; return; }
            local f=""
            f="$(prompt_input "输入备份文件完整路径" "" "" "" "false")" || return
            [ -f "$f" ] || { log_error "文件不存在"; return; }
            if confirm_or_cancel "恢复将覆盖当前配置，继续?"; then
                systemctl stop nginx || true
                if tar -xzf "$f" -C /; then
                    control_nginx restart || true
                    log_success "恢复完成"
                else
                    log_error "恢复失败"
                fi
            fi
            ;;
        3)
            render_menu "选择回滚类型" "1. HTTP 项目" "2. TCP 项目"
            local t=""
            t="$(prompt_menu_choice "1-2" "true")" || return
            local target_file=""
            local prefix=""
            if [ "$t" = "1" ]; then
                target_file="$PROJECTS_METADATA_FILE"
                prefix="projects_"
            elif [ "$t" = "2" ]; then
                target_file="$TCP_PROJECTS_METADATA_FILE"
                prefix="tcp_projects_"
            else
                return
            fi
            ls -lh "$JSON_BACKUP_DIR"/${prefix}*.bak 2>/dev/null || { log_warn "无快照"; return; }
            local s=""
            s="$(prompt_input "输入快照完整路径" "" "" "" "false")" || return
            [ -f "$s" ] || { log_error "快照不存在"; return; }
            if confirm_or_cancel "确认执行回滚?"; then
                snapshot_json "$target_file"
                cp -f "$s" "$target_file"
                log_success "回滚完成"
            fi
            ;;
        4) rebuild_all_nginx_configs ;;
        5) manage_cron_jobs ;;
    esac
}

# ========================= 主菜单 =========================

draw_dashboard() {
    local nginx_v=""
    local up=""
    local http_count=0
    local tcp_count=0
    local load="unknown"

    nginx_v="$(nginx -v 2>&1 | awk -F/ '{print $2}' | awk '{print $1}')"
    up="$(uptime -p 2>/dev/null | sed 's/up //')"
    http_count="$(jq 'length' "$PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)"
    tcp_count="$(jq 'length' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || echo 0)"
    load="$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs || echo unknown)"

    echo ""
    echo -e "${GREEN}================ Nginx 管理面板 v4.33.1 Stable ================${NC}"
    echo "Nginx: ${nginx_v} | 运行: ${up:-unknown} | 负载: ${load}"
    echo "HTTP: ${http_count} 个 | TCP: ${tcp_count} 个"
    echo -e "${GREEN}===============================================================${NC}"
}

main_menu() {
    while true; do
        draw_dashboard
        echo -e "${PURPLE}【HTTP(S) 业务】${NC}"
        echo " 1. 配置新域名反代 (New HTTP Proxy)"
        echo " 2. HTTP 项目管理 (Manage HTTP)"
        echo " 3. 仅申请证书 (Cert Only + Hook)"
        echo ""
        echo -e "${PURPLE}【TCP 负载均衡】${NC}"
        echo " 4. 配置 TCP 反代/负载均衡"
        echo " 5. 管理 TCP 反向代理"
        echo ""
        echo -e "${PURPLE}【运维监控与系统维护】${NC}"
        echo " 6. 批量续期"
        echo " 7. 查看日志"
        echo " 8. 更新 Cloudflare 防御 IP 库"
        echo " 9. 备份/还原与配置重建"
        echo "10. 设置 Telegram 通知"
        echo ""

        local c=""
        c="$(prompt_menu_choice "1-10" "true")" || break
        case "$c" in
            1) configure_nginx_projects "standard"; press_enter_to_continue ;;
            2) manage_configs ;;
            3) configure_nginx_projects "cert_only"; press_enter_to_continue ;;
            4) configure_tcp_proxy; press_enter_to_continue ;;
            5) manage_tcp_configs ;;
            6)
                if confirm_or_cancel "确认检查所有项目?"; then
                    check_and_auto_renew_certs
                fi
                press_enter_to_continue
                ;;
            7)
                render_menu "查看日志" "1. Nginx 全局日志" "2. acme.sh 日志"
                local lc=""
                lc="$(prompt_menu_choice "1-2" "true")" || continue
                case "$lc" in
                    1) view_nginx_global_log ;;
                    2) view_acme_log ;;
                esac
                press_enter_to_continue
                ;;
            8) update_cloudflare_ips; press_enter_to_continue ;;
            9) handle_backup_restore; press_enter_to_continue ;;
            10) setup_tg_notifier; press_enter_to_continue ;;
            "") return 0 ;;
            *) log_error "无效选择" ;;
        esac
    done
}

# ========================= 入口 =========================

pre_check() {
    validate_args "$@" || return "$ERR_INVALID_ARGS"
    parse_args "$@"
    check_root || return "$ERR_GENERAL"
    install_dependencies || return "$ERR_MISSING_DEPS"
    check_dependencies || return "$ERR_MISSING_DEPS"
    acquire_lock || return "$ERR_RUNTIME"
    return 0
}

_main_inner() {
    if [[ " $* " =~ " --cron " ]]; then
        check_and_auto_renew_certs
        return $?
    fi
    install_acme_sh
    main_menu
    return 0
}

main() {
    pre_check "$@" || exit $?
    check_os_compatibility || exit $?
    initialize_environment
    _main_inner "$@"
}

main "$@"
