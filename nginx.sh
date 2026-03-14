#!/usr/bin/env bash
# =============================================================
# 🚀 Nginx 反向代理 + HTTPS 证书管理助手 (v4.35.0 - Security & Performance)
# =============================================================
# 作者:Shell 脚本专家
# 描述:自动化管理 Nginx 反代配置与 SSL 证书,支持 TCP 负载均衡、泛域名无代理模式、性能优化与安全日志遮掩

set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export PATH='/usr/local/bin:/usr/bin:/bin'

VERSION="4.35.0"
DESCRIPTION="Nginx 反向代理与证书管理助手"
DEPENDENCIES="nginx curl socat openssl jq idn dnsutils nano coreutils util-linux flock timeout awk sed grep sha256sum"
NGINX_BIN_CANDIDATES=(
  "/usr/sbin/nginx"
  "/usr/local/sbin/nginx"
  "/sbin/nginx"
  "/usr/bin/nginx"
  "/usr/local/bin/nginx"
  "/opt/nginx/sbin/nginx"
)
NGINX_PATH_FIXED="false"

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"

# --- 全局变量 ---
if [ -t 1 ] || [ -t 2 ]; then
  NC="\033[0m"
  # shellcheck disable=SC2034
  BLACK="\033[30m"
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  # shellcheck disable=SC2034
  BLUE="\033[34m"
  PURPLE="\033[35m"
  CYAN="\033[36m"
  # shellcheck disable=SC2034
  WHITE="\033[37m"
  BRIGHT_RED="\033[91m"
  BRIGHT_YELLOW="\033[93m"
  GRAY="\033[2m"
  BOLD="\033[1m"
else
  NC=""
  # shellcheck disable=SC2034
  BLACK=""
  RED=""
  GREEN=""
  YELLOW=""
  # shellcheck disable=SC2034
  BLUE=""
  PURPLE=""
  CYAN=""
  # shellcheck disable=SC2034
  WHITE=""
  BRIGHT_RED=""
  BRIGHT_YELLOW=""
  GRAY=""
  BOLD=""
fi
readonly NC BLACK RED GREEN YELLOW BLUE PURPLE CYAN WHITE BRIGHT_RED BRIGHT_YELLOW GRAY BOLD

LOG_FILE_DEFAULT="/var/log/nginx_ssl_manager.log"
LOG_FILE_FALLBACK="/tmp/nginx_ssl_manager.log"
LOG_LEVEL_DEFAULT="INFO"
LOG_LEVEL="${LOG_LEVEL:-$LOG_LEVEL_DEFAULT}"
LOG_FILE="${LOG_FILE:-$LOG_FILE_DEFAULT}"
LOG_WITH_TIMESTAMP="false"
LOG_WITH_OP_TAG="${LOG_WITH_OP_TAG:-false}"
LOG_FORMAT="${LOG_FORMAT:-plain}"
ALLOW_UNSAFE_HOOKS="${ALLOW_UNSAFE_HOOKS:-false}"
SAFE_PATH_ROOTS=("/etc/nginx" "/etc/ssl" "/var/www" "/var/log" "/var/lib/nginx_ssl_manager" "/root/nginx_ssl_backups" "/etc/nginx/projects_backups" "/etc/nginx/conf_backups" "/etc/logrotate.d" "/etc/cron.d")
HOOK_WHITELIST=("systemctl restart s-ui" "systemctl restart x-ui" "systemctl restart v2ray" "systemctl restart xray" "systemctl reload nginx" "systemctl restart nginx")
PROJECTS_METADATA_FILE="/etc/nginx/projects.json"
TCP_PROJECTS_METADATA_FILE="/etc/nginx/tcp_projects.json"
MCP_TOKEN_DIR="/etc/nginx/mcp_tokens"
JSON_BACKUP_DIR="/etc/nginx/projects_backups"
BACKUP_DIR="/root/nginx_ssl_backups"
CONF_BACKUP_DIR="/etc/nginx/conf_backups"
TX_WAL_FILE="/var/lib/nginx_ssl_manager/tx_wal.log"
TG_CONF_FILE="/etc/nginx/tg_notifier.conf"
GZIP_DISABLE_MARK="/etc/nginx/.gzip_optimize_disabled"
SAFE_PATH_ROOTS+=("$MCP_TOKEN_DIR")
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
NGINX_RELOAD_STRATEGY_CACHE=""
NGINX_RELOAD_STRATEGY_CACHE_TS=0
NGINX_RELOAD_STRATEGY_CACHE_TTL_SECS="${NGINX_RELOAD_STRATEGY_CACHE_TTL_SECS:-30}"
ACME_SH_INSTALL_URL="${ACME_SH_INSTALL_URL:-https://get.acme.sh}"
ACME_SH_INSTALL_SHA256="${ACME_SH_INSTALL_SHA256:-}"
declare -a TMP_PAYLOAD_FILES=()
CF_AUTO_UPDATE_ENABLED_FILE="/etc/nginx/.cf_ip_auto_update.enabled"
CRON_MANAGER_FILE="/etc/cron.d/nginx_ssl_manager"

ERR_CFG_INVALID_ARGS=2
ERR_CFG_VALIDATE=20
# shellcheck disable=SC2034
ERR_CFG_WRITE=21
ERR_TX_CONTRACT=31
EX_USAGE=64
EX_DATAERR=65
EX_SOFTWARE=70
EX_CONFIG=78

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
DRY_RUN="false"
VPS_IP=""
VPS_IPV6=""
ACME_BIN=""
SCRIPT_PATH=$(realpath "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
NGINX_TEMPLATE_DIR="${NGINX_TEMPLATE_DIR:-${SCRIPT_DIR}/templates/nginx}"
NGINX_TEMPLATE_MANIFEST="${NGINX_TEMPLATE_MANIFEST:-${NGINX_TEMPLATE_DIR}/manifest.json}"
NGINX_TEMPLATE_SNIPPETS_DIR="${NGINX_TEMPLATE_SNIPPETS_DIR:-${NGINX_TEMPLATE_DIR}/snippets}"
NGINX_TEMPLATE_AUDIT_LOG="${NGINX_TEMPLATE_AUDIT_LOG:-/var/log/nginx_template_audit.log}"

TEMPLATE_MODE=""
TEMPLATE_IDS=""
TEMPLATE_DOMAIN=""
TEMPLATE_VARS_RAW=""
TEMPLATE_APPLY_MODE="append"
TEMPLATE_CLEANUP_MODE=""
TEMPLATE_PARALLELISM=1
TEMPLATE_DRY_RUN="false"
TEMPLATE_BATCH_AUTO_CONFIRM="false"
TEMPLATE_MANIFEST_CACHE=""
TEMPLATE_PRECHECK="false"
TEMPLATE_FAIL_FAST="false"
TEMPLATE_CONTINUE_ON_ERROR="false"
TEMPLATE_OUTPUT_JSON="false"
TEMPLATE_DEFER_RELOAD="false"
TEMPLATE_IMPACT_REPORT="false"
TEMPLATE_ROLLBACK_OP=""
TEMPLATE_ROLLBACK_DOMAIN=""
TEMPLATE_ROLLBACK_BEFORE=""
TEMPLATE_AUDIT_REPORT="false"
TEMPLATE_APPROVAL_HOOK=""
QUIET_MODE="false"
PRECHECK_ONLY="false"
PREFLIGHT_HARD_GATE="true"
PREFLIGHT_GATE_CACHE_TS=0
PREFLIGHT_GATE_CACHE_RESULT=1
PREFLIGHT_GATE_CACHE_MAX_AGE_SECS="${PREFLIGHT_GATE_CACHE_MAX_AGE_SECS:-20}"
SHOW_HELP="false"
declare -A TEMPLATE_VARS=()

SAFE_PATH_ROOTS+=("${SCRIPT_DIR}" "${SCRIPT_DIR}/templates" "/opt/vps_install_modules" "/opt/vps_install_modules/templates")

_unused_globals_noop() {
  : "$VERSION" "$DESCRIPTION" "$DEPENDENCIES" "$PURPLE" "$LOG_WITH_TIMESTAMP" "$EX_USAGE" "$EX_CONFIG" "$RENEW_THRESHOLD_DAYS" "$ERR_CFG_INVALID_ARGS"
  : "$TEMPLATE_IDS" "$TEMPLATE_DOMAIN" "$TEMPLATE_VARS_RAW" "$TEMPLATE_APPLY_MODE" "$TEMPLATE_CLEANUP_MODE" "$TEMPLATE_PARALLELISM"
  : "$TEMPLATE_DRY_RUN" "$TEMPLATE_PRECHECK" "$TEMPLATE_FAIL_FAST" "$TEMPLATE_CONTINUE_ON_ERROR" "$TEMPLATE_DEFER_RELOAD"
  : "$TEMPLATE_IMPACT_REPORT" "$TEMPLATE_ROLLBACK_DOMAIN" "$TEMPLATE_ROLLBACK_BEFORE" "$LOG_FORMAT" "$TX_WAL_FILE" "$AUDIT_REPORT" "$AUDIT_OUTPUT_JSON" "$PLAN_MODE" "$TX_RECOVER"
}

# shellcheck disable=SC1091
# shellcheck source=lib/template_manifest.sh
source "${SCRIPT_DIR}/lib/template_manifest.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/template_audit.sh
source "${SCRIPT_DIR}/lib/template_audit.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/template_ops.sh
source "${SCRIPT_DIR}/lib/template_ops.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/template_cli.sh
source "${SCRIPT_DIR}/lib/template_cli.sh"
# shellcheck disable=SC1091
# shellcheck source=lib/template_render.sh
source "${SCRIPT_DIR}/lib/template_render.sh"

# ==============================================================================
# SECTION: 核心工具函数与信号捕获
# ==============================================================================

OP_ID=""
LOCK_FILE_HTTP="/var/lock/nginx_ssl_manager_http.lock"
LOCK_FILE_TCP="/var/lock/nginx_ssl_manager_tcp.lock"
LOCK_FILE_CERT="/var/lock/nginx_ssl_manager_cert.lock"
LOCK_FILE_PROJECT="/var/lock/nginx_ssl_manager_project.lock"
LOCK_FILE_LOGROTATE="/var/lock/nginx_ssl_manager_logrotate.lock"
LOCK_FILE_CRON="/var/lock/nginx_ssl_manager_cron.lock"
LOCK_FILE_CF="/var/lock/nginx_ssl_manager_cf.lock"
LOCK_FILE_WAL="/var/lock/nginx_ssl_manager_wal.lock"
# shellcheck disable=SC2034
LOCK_FD_HTTP=9
# shellcheck disable=SC2034
LOCK_FD_TCP=10
# shellcheck disable=SC2034
LOCK_FD_CERT=11
# shellcheck disable=SC2034
LOCK_FD_PROJECT=12
LAST_CERT_ELAPSED=""
LAST_CERT_CERT=""
LAST_CERT_KEY=""
INTERRUPT_RESUME_SERVICE=""
LOCK_OWNER_PID_PROJECT=""

# shellcheck disable=SC1091
# shellcheck source=lib/nginx_core.sh
source "${SCRIPT_DIR}/lib/nginx_core.sh"

# shellcheck disable=SC1091
# shellcheck source=lib/nginx_store.sh
source "${SCRIPT_DIR}/lib/nginx_store.sh"

# shellcheck disable=SC1091
# shellcheck source=lib/nginx_env.sh
source "${SCRIPT_DIR}/lib/nginx_env.sh"

# shellcheck disable=SC1091
# shellcheck source=lib/nginx_render.sh
source "${SCRIPT_DIR}/lib/nginx_render.sh"

# shellcheck disable=SC1091
# shellcheck source=lib/nginx_flow.sh
source "${SCRIPT_DIR}/lib/nginx_flow.sh"

# ==============================================================================
# SECTION: UI 渲染函数 (兼容中文宽度)
# ==============================================================================

generate_line() {
  local len=${1:-40}
  local char=${2:-"─"}
  if [ "$len" -le 0 ]; then
    printf '%b' "\n"
    return
  fi
  printf "%${len}s" "" | sed "s/ /$char/g"
}

_get_visual_width() {
  local text="$1"
  local plain_text
  plain_text=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g')
  if [ -z "$plain_text" ]; then
    printf '%s\n' "0"
    return
  fi
  if command -v python3 &>/dev/null; then
    python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<<"$plain_text" 2>/dev/null || printf '%s\n' "${#plain_text}"
  elif command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
    printf '%s' "$plain_text" | wc -m
  else
    printf '%s' "$plain_text" | awk '{print length}'
  fi
}

_render_menu() {
  local out="/dev/tty"
  if [ -t 1 ]; then
    out="/dev/stdout"
  elif [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    out="/dev/stdout"
  fi
  local title="$1"
  shift
  local -a lines=("$@")
  local max_content_width=0
  local title_width
  title_width=$(_get_visual_width "$title")
  max_content_width=$title_width
  for line in "${lines[@]}"; do
    local current_line_visual_width
    current_line_visual_width=$(_get_visual_width "$line")
    if [ "$current_line_visual_width" -gt "$max_content_width" ]; then
      max_content_width="$current_line_visual_width"
    fi
  done
  local box_inner_width=$max_content_width
  if [ "$box_inner_width" -lt 40 ]; then box_inner_width=40; fi

  printf '%b' "\n" >"$out"
  printf '%b' "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}\n" >"$out"
  if [ -n "$title" ]; then
    local padding_total=$((box_inner_width - title_width))
    local padding_left=$((padding_total / 2))
    local padding_right=$((padding_total - padding_left))
    printf '%b' "${GREEN}│${NC}$(printf '%*s' "$padding_left" "")${BOLD}${title}${NC}$(printf '%*s' "$padding_right" "")${GREEN}│${NC}\n" >"$out"
  fi
  printf '%b' "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}\n" >"$out"

  for line in "${lines[@]}"; do printf '%b' "${line}\n" >"$out"; done

  local box_total_physical_width=$((box_inner_width + 2))
  printf '%b' "${GREEN}$(generate_line "$box_total_physical_width" "─")${NC}\n" >"$out"
}

safe_rm() {
  # DRY-RUN 安全删除封装
  local target="${1:-}"
  local purpose="${2:-删除文件}"
  if [ -z "$target" ]; then return 1; fi
  if ! _require_safe_path "$target" "$purpose"; then return 1; fi
  if [ "$DRY_RUN" = "true" ]; then
    log_message INFO "[DRY-RUN] rm -f ${target}"
    return 0
  fi
  rm -f "$target"
}

_center_text() {
  local text="$1"
  local width="${2:-10}"
  local len=${#text}
  if [ -z "$text" ]; then
    printf "%${width}s" ""
    return
  fi
  if ((len >= width)); then printf "%-${width}.${width}s" "$text"; else
    local pad=$((width - len))
    local left=$((pad / 2))
    local right=$((pad - left))
    printf "%${left}s%s%${right}s" "" "$text" ""
  fi
}

_draw_dashboard() {
  _generate_op_id
  local nginx_v="unknown"
  if _ensure_nginx_in_path; then
    nginx_v=$(nginx -v 2>&1 | sed -n 's#^.*/\([^[:space:]]\+\).*$#\1#p' | head -n1)
    [ -z "$nginx_v" ] && nginx_v="unknown"
  fi
  local uptime_raw
  uptime_raw=$(uptime -p | sed 's/up //')
  local count
  count=$(jq '. | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "0")
  local tcp_count
  tcp_count=$(jq '. | length' "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "0")
  local warn_count=0
  if [ -f "$PROJECTS_METADATA_FILE" ]; then warn_count=$(jq '[.[] | select(.cert_file)] | length' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "0"); fi
  local load
  load=$(uptime | awk -F'load average:' '{print $2}' | xargs | cut -d, -f1-3 2>/dev/null || printf '%s' "unknown")

  local title="Nginx 管理面板"
  local line1="Nginx: ${nginx_v} | 运行: ${uptime_raw} | 负载: ${load}"
  local line2="HTTP : ${count} 个 | TCP : ${tcp_count} 个 | 告警 : ${warn_count}"

  local max_width
  max_width=$(_get_visual_width "$title")
  local w1
  w1=$(_get_visual_width "$line1")
  local w2
  w2=$(_get_visual_width "$line2")
  [ "$w1" -gt "$max_width" ] && max_width=$w1
  [ "$w2" -gt "$max_width" ] && max_width=$w2
  [ "$max_width" -lt 50 ] && max_width=50

  printf '%b' "\n"
  printf '%b' "${GREEN}╭$(generate_line "$max_width" "─")╮${NC}\n"
  local title_pad_total=$((max_width - $(_get_visual_width "$title")))
  local title_pad_left=$((title_pad_total / 2))
  local title_pad_right=$((title_pad_total - title_pad_left))
  printf '%b' "${GREEN}│${NC}$(printf '%*s' "$title_pad_left" "")${BOLD}${title}${NC}$(printf '%*s' "$title_pad_right" "")${GREEN}│${NC}\n"
  printf '%b' "${GREEN}╰$(generate_line "$max_width" "─")╯${NC}\n"
  local pad1=$((max_width - w1))
  local pad2=$((max_width - w2))
  printf '%b' " ${line1}$(printf '%*s' "$pad1" "")\n"
  printf '%b' " ${line2}$(printf '%*s' "$pad2" "")\n"
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
  else
    log_message WARN "未安装 dig/host 工具,跳过 DNS 预检。"
    return 0
  fi

  if [ -z "$resolved_ips" ]; then
    log_message ERROR "❌ DNS 解析失败: 域名 $domain 当前未解析到任何 IP 地址。"
    printf '%b' "${RED}请先前往您的 DNS 服务商添加一条 A 记录,指向本机 IP: ${VPS_IP}${NC}\n"
    if ! confirm_or_cancel "DNS 未生效,是否强制继续申请?"; then return 1; fi
    return 0
  fi
  if [[ " $resolved_ips " == *" $VPS_IP "* ]]; then
    log_message SUCCESS "✅ DNS 校验通过: $domain --> $VPS_IP"
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
  local -a menu_lines=()
  local curr_token="" curr_chat="" curr_name=""
  if [ -f "$TG_CONF_FILE" ]; then
    _load_tg_conf || {
      log_message ERROR "TG 配置读取失败"
      return
    }
    curr_token="${TG_BOT_TOKEN:-}"
    curr_chat="${TG_CHAT_ID:-}"
    curr_name="${SERVER_NAME:-}"
    menu_lines+=("${GREEN}当前已配置:${NC}")
    menu_lines+=(" 机器人 Token : $(_mask_string "$curr_token")")
    menu_lines+=(" 会话 ID      : $(_mask_string "$curr_chat")")
    menu_lines+=(" 服务器备注   : $curr_name")
  fi
  _render_menu "Telegram 机器人通知设置" "${menu_lines[@]}"
  if [ -f "$TG_CONF_FILE" ]; then if ! confirm_or_cancel "是否要重新配置或关闭通知?"; then return; fi; fi
  local action
  printf '%b' "1. 开启/修改通知配置\n"
  printf '%b' "2. 清除配置 (关闭通知)\n"
  printf '%b' "\n"
  if ! action=$(prompt_menu_choice "1-2" "true"); then return; fi
  if [ "$action" = "2" ]; then
    rm -f "$TG_CONF_FILE"
    log_message SUCCESS "Telegram 通知已关闭。"
    return
  fi
  [ "$action" != "1" ] && return
  local real_tk_default="${curr_token:-}"
  local vis_tk_default=""
  [ -n "$curr_token" ] && vis_tk_default="$(_mask_string "$curr_token")" || vis_tk_default="***"
  local tk
  if ! tk=$(prompt_input "请输入 Bot Token (如 1234:ABC...)" "$real_tk_default" "" "" "false" "$vis_tk_default"); then return; fi
  local real_cid_default="${curr_chat:-}"
  local vis_cid_default=""
  [ -n "$curr_chat" ] && vis_cid_default="$(_mask_string "$curr_chat")" || vis_cid_default="无"
  local cid
  if ! cid=$(prompt_input "请输入 Chat ID (如 123456789 或 -100123...)" "$real_cid_default" "^-?[0-9]+$" "格式错误,只能包含数字或负号" "false" "$vis_cid_default"); then return; fi
  local sname
  if ! sname=$(prompt_input "请输入这台服务器的备注 (如 日本主机)" "$curr_name" "" "" "false"); then return; fi
  if ! _require_safe_path "$TG_CONF_FILE" "写入 TG 配置"; then return; fi
  cat <<EOF | _atomic_write_file "$TG_CONF_FILE" "0600"
TG_BOT_TOKEN="${tk}"
TG_CHAT_ID="${cid}"
SERVER_NAME="${sname}"
EOF
  log_message INFO "正在发送测试消息 (同步模式)..."
  if _send_tg_notify "success" "测试域名" "恭喜!您的 Telegram 通知系统已成功挂载。" "$sname" "true"; then
    log_message SUCCESS "测试消息发送成功!请检查 Telegram 客户端。"
  else
    log_message ERROR "测试消息发送失败!请检查上方的错误提示。"
    if ! confirm_or_cancel "是否保留此配置?"; then rm -f "$TG_CONF_FILE"; fi
  fi
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
  get_vps_ip
  local display_ip
  display_ip=$(_mask_ip "$VPS_IP")
  local display_ipv6
  display_ipv6=$(_mask_ip "$VPS_IPV6")
  local title="" status_text="" emoji=""
  if [ "$status_type" == "success" ]; then
    title="证书续期成功"
    status_text="✅ 续订完成"
    emoji="✅"
  else
    title="异常警报"
    status_text="⚠️ 续订失败"
    emoji="⚠️"
  fi
  local ipv6_line=""
  [ -n "$VPS_IPV6" ] && ipv6_line=$'\n'"🌐<b>IPv6:</b> <code>${display_ipv6}</code>"
  local current_time
  current_time=$(date "+%Y-%m-%d %H:%M:%S (%Z)")
  local text_body
  text_body=$(
    cat <<EOF
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
  local button_url="http://${domain}/"
  [ "$debug" == "true" ] && button_url="https://core.telegram.org/bots/api"
  local kb_json='{"inline_keyboard":[[{"text":"📊 访问实例","url":"'"$button_url"'"}]]}'
  local payload_file
  payload_file=$(mktemp /tmp/tg_payload_XXXXXX.json)
  TMP_PAYLOAD_FILES+=("$payload_file")
  chmod 600 "$payload_file"
  if ! jq -n --arg cid "$TG_CHAT_ID" --arg txt "$text_body" --argjson kb "$kb_json" '{chat_id: $cid, text: $txt, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: $kb}' >"$payload_file"; then
    log_message ERROR "构造 TG JSON 失败。"
    rm -f "$payload_file"
    return 1
  fi
  local curl_cmd=(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" -H "Content-Type: application/json" -d @"$payload_file" --connect-timeout 10 --max-time 15)
  local ret_code=0
  local resp=""
  if [ "$debug" == "true" ]; then
    printf '%b' "${CYAN}>>> 发送请求到 Telegram API...${NC}\n"
    resp=$("${curl_cmd[@]}" 2>&1) || ret_code=$?
    printf '%b' "${CYAN}<<< Telegram 响应:${NC}\n${resp}\n"
    if [ $ret_code -ne 0 ] || ! jq -e '.ok' >/dev/null 2>&1 <<<"$resp"; then ret_code=1; fi
  else
    resp=$(run_cmd 20 "${curl_cmd[@]}" 2>&1) || ret_code=$?
    if [ $ret_code -ne 0 ] || ! jq -e '.ok' >/dev/null 2>&1 <<<"$resp"; then ret_code=1; fi
  fi
  if [ $ret_code -ne 0 ]; then
    log_message WARN "Telegram 通知发送失败 (已脱敏)。"
    _mask_sensitive_data <<<"$resp" >&2
  fi
  rm -f "$payload_file"
  return $ret_code
}

# ==============================================================================
# SECTION: 环境初始化与依赖 (优化版)
# ==============================================================================

_get_nginx_bin_from_proc() {
  local pid=""
  pid=$(pgrep -o nginx 2>/dev/null || true)
  if [ -n "$pid" ] && [ -e "/proc/${pid}/exe" ]; then
    readlink -f "/proc/${pid}/exe" 2>/dev/null || true
  fi
}

_find_nginx_bin() {
  if command -v nginx >/dev/null 2>&1; then
    command -v nginx
    return 0
  fi
  local candidate
  for candidate in "${NGINX_BIN_CANDIDATES[@]}"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  local proc_bin
  proc_bin=$(_get_nginx_bin_from_proc)
  if [ -n "$proc_bin" ] && [ -x "$proc_bin" ]; then
    printf '%s\n' "$proc_bin"
    return 0
  fi
  return 1
}

_ensure_system_path_sbin() {
  local profile="${NGINX_PROFILE_PATH:-/etc/profile}"
  local marker="# Added by nginx.sh to ensure /usr/sbin in PATH"
  if [ ! -f "$profile" ]; then
    return 0
  fi
  if grep -q "${marker}" "$profile" 2>/dev/null; then
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  cp -p "$profile" "$tmp"
  {
    printf '\n%s\n' "$marker"
    printf "%s\n" "case \":\$PATH:\" in"
    printf '%s\n' '  *:/usr/sbin:*) ;;'
    printf "%s\n" "  *) export PATH=\"\$PATH:/usr/sbin\" ;;"
    printf '%s\n' 'esac'
  } >>"$tmp"
  if ! grep -q "$marker" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log_message INFO "[DRY-RUN] 将写入 ${profile} 以补齐 /usr/sbin"
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$profile"
}

_ensure_nginx_in_path() {
  local bin=""
  bin=$(_find_nginx_bin) || return 1
  local dir
  dir=$(dirname "$bin")
  case ":$PATH:" in
  *":$dir:"*) return 0 ;;
  esac
  export PATH="${dir}:$PATH"
  _ensure_system_path_sbin
  if [ "${NGINX_PATH_FIXED:-false}" != "true" ]; then
    log_debug "已自动补齐 PATH，检测到 nginx: ${bin}"
    NGINX_PATH_FIXED="true"
  fi
  return 0
}

check_dependencies() {
  local -a missing=()
  local cmd

  for cmd in nginx curl socat openssl jq idn nano flock timeout awk sed grep sha256sum; do
    if [ "$cmd" = "nginx" ]; then
      if ! _ensure_nginx_in_path; then
        missing+=("$cmd")
      fi
    else
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    fi
  done

  if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1; then
    missing+=("dnsutils")
  fi

  if ! command -v ls >/dev/null 2>&1 || ! command -v date >/dev/null 2>&1 || ! command -v cp >/dev/null 2>&1 || ! command -v realpath >/dev/null 2>&1; then
    missing+=("coreutils")
  fi

  if ((${#missing[@]} > 0)); then
    log_message WARN "缺失依赖: ${missing[*]}"
    return 1
  fi
  return 0
}

install_dependencies() {
  if [ -f "$DEPS_MARK_FILE" ]; then return 0; fi
  local -a deps=(nginx curl socat openssl jq idn dnsutils nano coreutils util-linux)
  local -a missing_deps=()
  local missing_display=""
  local -a apt_env=(env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a)
  local -a apt_opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  local pkg
  for pkg in "${deps[@]}"; do
    if [ "$pkg" = "nginx" ]; then
      if _ensure_nginx_in_path; then
        continue
      fi
    fi
    if ! dpkg -s "$pkg" &>/dev/null; then missing_deps+=("$pkg"); fi
  done
  if ((${#missing_deps[@]} > 0)); then
    missing_display=$(printf '%s ' "${missing_deps[@]}")
    missing_display="${missing_display% }"
    log_message WARN "检测到缺失依赖: ${missing_display}"
    log_message INFO "正在安装依赖（步骤1/2）：刷新软件源..."
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
      log_message ERROR "非交互模式禁止自动安装依赖"
      return 1
    fi
    if run_cmd 300 sudo -n "${apt_env[@]}" apt-get update || run_cmd 300 "${apt_env[@]}" apt-get update; then
      log_message INFO "正在安装依赖（步骤2/2）：批量安装 ${missing_display} ..."
      if run_cmd 900 sudo -n "${apt_env[@]}" apt-get install "${apt_opts[@]}" "${missing_deps[@]}" || run_cmd 900 "${apt_env[@]}" apt-get install "${apt_opts[@]}" "${missing_deps[@]}"; then
        log_message SUCCESS "依赖安装成功。"
      else
        log_message ERROR "依赖安装失败"
        return 1
      fi
    else
      log_message ERROR "apt-get update 失败（请检查网络/源可用性/apt锁）"
      return 1
    fi
  fi
  touch "$DEPS_MARK_FILE"
  return 0
}

_setup_logrotate() {
  if ! acquire_logrotate_lock; then
    log_message ERROR "无法获取全局锁，已取消写入 logrotate"
    return 1
  fi
  trap 'release_logrotate_lock' RETURN
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
    if ! _require_safe_path "/etc/logrotate.d/nginx" "写入 logrotate"; then return 1; fi
    cat <<'EOF' | _atomic_write_file "/etc/logrotate.d/nginx" "0644"
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
    if ! _require_safe_path "/etc/logrotate.d/nginx_ssl_manager" "写入 logrotate"; then return 1; fi
    cat <<EOF | _atomic_write_file "/etc/logrotate.d/nginx_ssl_manager" "0644"
${log_path} { weekly missingok rotate 12 compress delaycompress notifempty create 0644 root root }
EOF
  fi
}

_parse_args() {
  tm_parse_args "$@"
}

_get_active_nginx_main_conf() {
  local master_cmd=""
  local conf=""
  master_cmd=$(pgrep -af 'nginx: master process' | head -n1 || true)
  conf=$(_extract_nginx_conf_from_master_cmd "$master_cmd" 2>/dev/null || true)
  if [ -z "$conf" ]; then
    conf="/etc/nginx/nginx.conf"
  fi
  printf '%s\n' "$conf"
}

_ensure_active_nginx_http_include_sites_enabled() {
  local active_conf=""
  active_conf=$(_get_active_nginx_main_conf)
  if [ -z "$active_conf" ] || [ ! -f "$active_conf" ]; then
    return 0
  fi
  if [ "$active_conf" = "/etc/nginx/nginx.conf" ]; then
    return 0
  fi
  if grep -Eq 'include[[:space:]]+/etc/nginx/sites-enabled/\*\.conf;' "$active_conf" 2>/dev/null; then
    return 0
  fi
  log_message WARN "检测到 Nginx 使用自定义主配置: ${active_conf}，正在自动接入 /etc/nginx/sites-enabled/*.conf"
  local backup tmp_file
  backup="${active_conf}.bak.$(date +%Y%m%d_%H%M%S)"
  tmp_file=$(mktemp /tmp/nginx.main.include.XXXXXX)
  chmod 600 "$tmp_file"
  cp "$active_conf" "$backup" || true
  awk '
		BEGIN{in_http=0; depth=0; inserted=0}
		{
			line=$0
			if (line ~ /^[ \t]*http[ \t]*\{[ \t]*$/) { in_http=1; depth=1; print line; next }
			if (in_http==1) {
				opens=gsub(/\{/, "{", line)
				closes=gsub(/\}/, "}", line)
				if (depth==1 && closes>0 && inserted==0) {
					print "    # Auto-injected: make /etc/nginx/sites-enabled configs effective"
					print "    include /etc/nginx/sites-enabled/*.conf;"
					inserted=1
				}
				depth += opens - closes
				if (depth<=0) { in_http=0; depth=0 }
			}
			print line
		}
	' "$active_conf" >"$tmp_file"
  if ! _require_safe_path "$active_conf" "更新自定义 nginx 主配置"; then
    rm -f "$tmp_file"
    return 1
  fi
  local precheck_output=""
  local precheck_rc=0
  precheck_output=$(nginx -t -c "$tmp_file" 2>&1) || precheck_rc=$?
  if [ "$precheck_rc" -ne 0 ]; then
    log_message ERROR "接入 sites-enabled 的预检失败，已取消写入: ${active_conf}"
    printf '%b' "${YELLOW}失败原因: ${precheck_output}${NC}\n"
    rm -f "$tmp_file"
    return 1
  fi
  mv "$tmp_file" "$active_conf"
  log_message SUCCESS "已将 /etc/nginx/sites-enabled/*.conf 接入 ${active_conf}"
  return 0
}

_stream_module_available() {
  if nginx -V 2>&1 | grep -Eq -- '--with-stream($|[[:space:]])'; then
    return 0
  fi
  if nginx -V 2>&1 | grep -q -- '--with-stream=dynamic'; then
    if [ -f /usr/lib/nginx/modules/ngx_stream_module.so ] && grep -Rqs 'ngx_stream_module\.so' /etc/nginx/modules-enabled 2>/dev/null; then
      return 0
    fi
  fi
  if [ -f /etc/nginx/modules-enabled/50-mod-stream.conf ] || [ -f /etc/nginx/modules-enabled/mod-stream.conf ]; then
    return 0
  fi
  if [ -f /usr/lib/nginx/modules/ngx_stream_module.so ]; then
    return 0
  fi
  return 1
}

_ensure_stream_module_available() {
  if _stream_module_available; then
    return 0
  fi
  log_message WARN "检测到当前 Nginx 缺少 stream 模块，正在尝试自动安装..."
  if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
    log_message ERROR "非交互模式下无法自动安装 stream 模块"
    return 1
  fi
  local -a apt_env=(env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a)
  local -a apt_opts=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  if ! run_cmd 300 sudo -n "${apt_env[@]}" apt-get update || ! run_cmd 300 sudo -n "${apt_env[@]}" apt-get install "${apt_opts[@]}" libnginx-mod-stream; then
    if ! run_cmd 300 "${apt_env[@]}" apt-get update || ! run_cmd 300 "${apt_env[@]}" apt-get install "${apt_opts[@]}" libnginx-mod-stream; then
      log_message ERROR "安装 stream 模块失败（libnginx-mod-stream）"
      return 1
    fi
  fi
  if _stream_module_available; then
    log_message SUCCESS "stream 模块已就绪。"
    return 0
  fi
  log_message ERROR "stream 模块仍不可用，请检查 Nginx 安装来源与模块路径。"
  return 1
}

validate_args() {
  tm_validate_args "$@"
}

print_usage() {
  tm_print_usage
}

run_audit_report() {
  tx_wal_summary
}

initialize_environment() {
  if [ -d "$HOME/.acme.sh" ]; then
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" -print -quit 2>/dev/null || true)
  else
    ACME_BIN=""
  fi
  if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
  local acme_bin_dir
  acme_bin_dir=$(dirname "$ACME_BIN")
  export PATH="${acme_bin_dir}:$PATH"

  mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$SSL_CERTS_BASE_DIR" "$BACKUP_DIR" "$CONF_BACKUP_DIR"
  mkdir -p "$JSON_BACKUP_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$NGINX_STREAM_ENABLED_DIR" "$MCP_TOKEN_DIR"
  if [ -n "$TX_WAL_FILE" ] && _require_safe_path "$TX_WAL_FILE" "WAL"; then
    mkdir -p "$(dirname "$TX_WAL_FILE")"
    touch "$TX_WAL_FILE" 2>/dev/null || true
  fi
  chmod 700 "$MCP_TOKEN_DIR" 2>/dev/null || true
  _ensure_active_nginx_http_include_sites_enabled || true
  _renew_fail_db_init
  if [ ! -f "$PROJECTS_METADATA_FILE" ] || ! jq -e . "$PROJECTS_METADATA_FILE" >/dev/null 2>&1; then
    if ! _require_safe_path "$PROJECTS_METADATA_FILE" "初始化项目配置"; then return 1; fi
    printf '%s\n' "[]" | _atomic_write_file "$PROJECTS_METADATA_FILE" "0644"
  fi
  if [ ! -f "$TCP_PROJECTS_METADATA_FILE" ] || ! jq -e . "$TCP_PROJECTS_METADATA_FILE" >/dev/null 2>&1; then
    if ! _require_safe_path "$TCP_PROJECTS_METADATA_FILE" "初始化 TCP 配置"; then return 1; fi
    printf '%s\n' "[]" | _atomic_write_file "$TCP_PROJECTS_METADATA_FILE" "0644"
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
  if [ -f /etc/nginx/nginx.conf ] && grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
    if ! _stream_module_available; then
      if ! _ensure_stream_module_available; then
        log_message WARN "检测到 stream 指令但模块不可用，尝试禁用自动注入的 stream 块。"
        if grep -q '^# TCP/UDP Stream Proxy Auto-injected$' /etc/nginx/nginx.conf; then
          local tmp_ng
          tmp_ng=$(mktemp /tmp/nginx.conf.fixstream.XXXXXX)
          chmod 600 "$tmp_ng"
          awk 'BEGIN{skip=0} /^# TCP\/UDP Stream Proxy Auto-injected$/{skip=1; next} {if(skip==1 && $0 ~ /^[[:space:]]*stream[[:space:]]*\{/) {skip=0; next} print $0}' /etc/nginx/nginx.conf >"$tmp_ng"
          if _require_safe_path "/etc/nginx/nginx.conf" "更新 nginx 主配置"; then
            mv "$tmp_ng" /etc/nginx/nginx.conf
          else
            rm -f "$tmp_ng" 2>/dev/null || true
            return 1
          fi
          log_message WARN "已自动禁用 nginx.conf 中的 stream 注入块。"
        fi
      fi
    fi
  fi
  if [ -f /etc/nginx/nginx.conf ] && ! grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
    if ! _ensure_stream_module_available; then
      log_message WARN "stream 模块不可用，已跳过 stream 块自动注入。"
      _setup_logrotate
      return 0
    fi
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
      log_message ERROR "非交互模式禁止修改 /etc/nginx/nginx.conf"
      return 1
    fi
    if ! _require_safe_path "/etc/nginx/nginx.conf" "更新 nginx 主配置"; then return 1; fi
    _atomic_append_file "/etc/nginx/nginx.conf" "
# TCP/UDP Stream Proxy Auto-injected
stream { include ${NGINX_STREAM_ENABLED_DIR}/*.conf; }"
    control_nginx reload || true
  fi
  _setup_logrotate
}

install_acme_sh() {
  _generate_op_id
  if [ -f "$ACME_BIN" ]; then return 0; fi
  log_message WARN "acme.sh 未安装,开始安装..."
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
  local install_log
  install_script=$(mktemp /tmp/acme_install.XXXXXX)
  install_log=$(mktemp /tmp/acme_install_log.XXXXXX)
  chmod 600 "$install_script"
  chmod 600 "$install_log"
  if ! run_cmd 30 curl -fsSL "$ACME_SH_INSTALL_URL" -o "$install_script"; then
    rm -f "$install_script"
    rm -f "$install_log"
    log_message ERROR "acme.sh 安装脚本下载失败"
    return 1
  fi
  if [ -n "$ACME_SH_INSTALL_SHA256" ]; then
    local got_sha
    got_sha=$(sha256sum "$install_script" | awk '{print $1}')
    if [ "$got_sha" != "$ACME_SH_INSTALL_SHA256" ]; then
      rm -f "$install_script"
      rm -f "$install_log"
      log_message ERROR "acme.sh 安装脚本校验失败"
      return 1
    fi
  fi
  sh "$install_script" >"$install_log" 2>&1 || {
    rm -f "$install_script"
    printf '%b' "${CYAN}--- 安装错误详情 (已脱敏) ---${NC}\n"
    _mask_sensitive_data <"$install_log"
    printf '%b' "${CYAN}------------------------------${NC}\n"
    rm -f "$install_log"
    log_message ERROR "acme.sh 安装失败"
    return 1
  }
  rm -f "$install_script"
  rm -f "$install_log"
  if [ -d "$HOME/.acme.sh" ]; then
    ACME_BIN=$(find "$HOME/.acme.sh" -name "acme.sh" -print -quit 2>/dev/null || true)
  else
    ACME_BIN=""
  fi
  if [[ -z "$ACME_BIN" ]]; then ACME_BIN="$HOME/.acme.sh/acme.sh"; fi
  "$ACME_BIN" --upgrade --auto-upgrade >/dev/null 2>&1 || true
  _write_manager_cron_file
  log_message SUCCESS "acme.sh 安装成功。"
  return 0
}

_zerossl_account_has_email() {
  local f1="$HOME/.acme.sh/account.conf"
  local f2="$HOME/.acme.sh/ca/acme.zerossl.com/v2/DV90/account.conf"
  if [ -f "$f1" ] && grep -Eq '^ACCOUNT_EMAIL=.+' "$f1" 2>/dev/null; then
    return 0
  fi
  if [ -f "$f2" ] && grep -Eq '^ACCOUNT_EMAIL=.+' "$f2" 2>/dev/null; then
    return 0
  fi
  return 1
}

_get_zerossl_account_email() {
  local f1="$HOME/.acme.sh/account.conf"
  local f2="$HOME/.acme.sh/ca/acme.zerossl.com/v2/DV90/account.conf"
  local email=""
  if [ -f "$f2" ]; then
    email=$(grep -E '^ACCOUNT_EMAIL=' "$f2" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"" || true)
  fi
  if [ -z "$email" ] && [ -f "$f1" ]; then
    email=$(grep -E '^ACCOUNT_EMAIL=' "$f1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"" || true)
  fi
  printf '%s\n' "$email"
}

_ensure_zerossl_account_email() {
  local ca_url="${1:-}"
  local email="${ZEROSSL_EMAIL:-}"
  local saved_email=""
  local log_temp=""
  if [ "$ca_url" != "https://acme.zerossl.com/v2/DV90" ]; then
    return 0
  fi
  saved_email=$(_get_zerossl_account_email)
  saved_email=$(printf '%s' "$saved_email" | tr -d '\r' | xargs)
  if [ "$saved_email" = "my@example.com" ]; then
    saved_email=""
  fi
  if [ -z "$email" ]; then
    email="$saved_email"
  fi
  if [ "$IS_INTERACTIVE_MODE" = "true" ] && [ "${JB_NONINTERACTIVE:-false}" != "true" ]; then
    log_message INFO "ZeroSSL 需要邮箱进行账号注册。"
    if ! email=$(prompt_input "ZeroSSL 注册邮箱" "$email" "^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$" "邮箱格式无效" "false"); then
      return 1
    fi
  fi
  if [ -z "$email" ]; then
    log_message ERROR "ZeroSSL 需要邮箱注册账号。"
    return 1
  fi
  log_temp=$(mktemp /tmp/acme_register_log.XXXXXX)
  chmod 600 "$log_temp"
  if ! run_cmd 90 "$ACME_BIN" --register-account -m "$email" --server "$ca_url" --log >"$log_temp" 2>&1; then
    log_message ERROR "ZeroSSL 账号邮箱注册失败。"
    printf '%b' "${CYAN}--- 注册错误详情 (已脱敏) ---${NC}\n"
    _mask_sensitive_data <"$log_temp"
    printf '%b' "${CYAN}------------------------------${NC}\n"
    rm -f "$log_temp"
    return 1
  fi
  rm -f "$log_temp"
  log_message SUCCESS "ZeroSSL 账号邮箱注册成功。"
  return 0
}

_extract_nginx_conf_from_master_cmd() {
  local master_cmd="${1:-}"
  if [[ "$master_cmd" =~ (^|[[:space:]])-c[[:space:]]([^[:space:]]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

_select_reload_strategy() {
  local now_ts=0
  now_ts=$(date +%s)
  if [ -n "${NGINX_RELOAD_STRATEGY_CACHE:-}" ] && [ "${NGINX_RELOAD_STRATEGY_CACHE_TS:-0}" -gt 0 ] && [ $((now_ts - NGINX_RELOAD_STRATEGY_CACHE_TS)) -le "${NGINX_RELOAD_STRATEGY_CACHE_TTL_SECS:-30}" ]; then
    printf '%s\n' "$NGINX_RELOAD_STRATEGY_CACHE"
    return 0
  fi
  local master_cmd=""
  local conf_path=""
  if systemctl status nginx >/dev/null 2>&1; then
    NGINX_RELOAD_STRATEGY_CACHE="systemctl"
    NGINX_RELOAD_STRATEGY_CACHE_TS="$now_ts"
    printf '%s\n' "systemctl"
    return 0
  fi
  master_cmd=$(pgrep -af 'nginx: master process' | head -n1 || true)
  conf_path=$(_extract_nginx_conf_from_master_cmd "$master_cmd" 2>/dev/null || true)
  if [ -n "$conf_path" ]; then
    NGINX_RELOAD_STRATEGY_CACHE="nginx_conf:${conf_path}"
    NGINX_RELOAD_STRATEGY_CACHE_TS="$now_ts"
    printf '%s\n' "nginx_conf:${conf_path}"
    return 0
  fi
  NGINX_RELOAD_STRATEGY_CACHE="nginx_plain"
  NGINX_RELOAD_STRATEGY_CACHE_TS="$now_ts"
  printf '%s\n' "nginx_plain"
}

control_nginx() {
  local action="${1:-reload}"
  if [ "${SKIP_NGINX_TEST_IN_APPLY:-false}" != "true" ] && ! _nginx_test_cached; then
    log_message ERROR "Nginx 配置错误"
    nginx -t || true
    return 1
  fi

  if [ "$action" != "reload" ]; then
    if systemctl "$action" nginx >/dev/null 2>&1; then
      if [ "$action" = "reload" ]; then NGINX_RELOAD_NEEDED="false"; fi
      return 0
    fi
    log_message ERROR "Nginx $action 失败"
    _tx_emit_marker "RELOAD_FAILED" "action=${action}, strategy=systemctl" "ERROR"
    return 1
  fi

  local strategy=""
  strategy=$(_select_reload_strategy)
  case "$strategy" in
  systemctl)
    if systemctl reload nginx >/dev/null 2>&1; then
      NGINX_RELOAD_NEEDED="false"
      _tx_emit_marker "RELOAD_OK" "strategy=systemctl"
      return 0
    fi
    ;;
  nginx_conf:*)
    local conf_path="${strategy#nginx_conf:}"
    if run_cmd 20 nginx -c "$conf_path" -s reload >/dev/null 2>&1; then
      log_message INFO "已使用 nginx -c ${conf_path} -s reload。"
      NGINX_RELOAD_NEEDED="false"
      _tx_emit_marker "RELOAD_OK" "strategy=nginx_conf:${conf_path}"
      return 0
    fi
    ;;
  nginx_plain)
    if run_cmd 20 nginx -s reload >/dev/null 2>&1; then
      log_message INFO "已使用 nginx -s reload。"
      NGINX_RELOAD_NEEDED="false"
      _tx_emit_marker "RELOAD_OK" "strategy=nginx_plain"
      return 0
    fi
    ;;
  esac

  NGINX_RELOAD_STRATEGY_CACHE=""
  NGINX_RELOAD_STRATEGY_CACHE_TS=0

  local master_cmd=""
  local conf_path=""
  master_cmd=$(pgrep -af 'nginx: master process' | head -n1 || true)
  conf_path=$(_extract_nginx_conf_from_master_cmd "$master_cmd" 2>/dev/null || true)
  if [ -n "$conf_path" ] && run_cmd 20 nginx -c "$conf_path" -s reload >/dev/null 2>&1; then
    log_message WARN "已回退为 nginx -c ${conf_path} -s reload。"
    NGINX_RELOAD_NEEDED="false"
    _tx_emit_marker "RELOAD_OK" "strategy=fallback_nginx_conf:${conf_path}"
    return 0
  fi
  if run_cmd 20 nginx -s reload >/dev/null 2>&1; then
    log_message WARN "已回退为 nginx -s reload。"
    NGINX_RELOAD_NEEDED="false"
    _tx_emit_marker "RELOAD_OK" "strategy=fallback_nginx_plain"
    return 0
  fi
  log_message ERROR "Nginx $action 失败"
  _tx_emit_marker "RELOAD_FAILED" "action=${action}, strategy=all_failed" "ERROR"
  return 1
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
  if ! acquire_cf_lock; then
    log_message ERROR "无法获取全局锁，已取消 Cloudflare IP 更新"
    return 1
  fi
  trap 'release_cf_lock' RETURN
  log_message INFO "正在拉取最新的 Cloudflare IP 列表..."
  printf '%b' "${CYAN}开始更新 Cloudflare 防御 IP 库...${NC}\n"
  local temp_allow
  temp_allow=$(mktemp)
  chmod 600 "$temp_allow"
  local temp_v4 temp_v6
  temp_v4=$(mktemp)
  temp_v6=$(mktemp)
  chmod 600 "$temp_v4" "$temp_v6"
  if run_cmd 20 curl -fsS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4 >"$temp_v4" && run_cmd 20 curl -fsS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v6 >"$temp_v6"; then
    local count_v4 count_v6
    count_v4=$(grep -Ec '^[0-9.]+/[0-9]+$' "$temp_v4" || printf '%s' "0")
    count_v6=$(grep -Ec '^[0-9a-fA-F:]+/[0-9]+$' "$temp_v6" || printf '%s' "0")
    printf '%b' "${GREEN}已获取 Cloudflare IPv4 网段: ${count_v4}${NC}\n"
    printf '%b' "${GREEN}已获取 Cloudflare IPv6 网段: ${count_v6}${NC}\n"

    cat "$temp_v4" "$temp_v6" >"$temp_allow"
    mkdir -p /etc/nginx/snippets /etc/nginx/conf.d
    local temp_cf_allow temp_cf_real temp_cf_geo
    temp_cf_allow=$(mktemp)
    temp_cf_real=$(mktemp)
    temp_cf_geo=$(mktemp)
    chmod 600 "$temp_cf_allow" "$temp_cf_real" "$temp_cf_geo"
    printf '%s\n' "# Cloudflare Allow List" >"$temp_cf_allow"
    printf '%s\n' "# Cloudflare Real IP" >"$temp_cf_real"
    {
      printf '%s\n' "geo \$realip_remote_addr \$cf_ip {"
      printf '%s\n' "    default 0;"
      printf '%s\n' "    127.0.0.1/32 1;"
      printf '%s\n' "    ::1/128 1;"
    } >"$temp_cf_geo"
    printf '%s\n' "allow 127.0.0.1;" >>"$temp_cf_allow"
    printf '%s\n' "allow ::1;" >>"$temp_cf_allow"
    while read -r ip; do
      [ -z "$ip" ] && continue
      printf '%s\n' "allow $ip;" >>"$temp_cf_allow"
      printf '%s\n' "set_real_ip_from $ip;" >>"$temp_cf_real"
      printf '%s\n' "    $ip 1;" >>"$temp_cf_geo"
    done < <(grep -E '^[0-9a-fA-F.:]+(/[0-9]+)?$' "$temp_allow")
    local allow_count
    allow_count=$(grep -c '^allow ' "$temp_cf_allow" || printf '%s' "0")
    if [ "$allow_count" -lt 5 ]; then
      log_message ERROR "Cloudflare IP 列表异常 (${allow_count})，已放弃更新。"
      rm -f "$temp_allow" "$temp_v4" "$temp_v6" "$temp_cf_allow" "$temp_cf_real" "$temp_cf_geo" 2>/dev/null || true
      return 1
    fi
    printf '%s\n' "deny all;" >>"$temp_cf_allow"
    printf '%s\n' "real_ip_header CF-Connecting-IP;" >>"$temp_cf_real"
    printf '%s\n' "real_ip_recursive on;" >>"$temp_cf_real"
    printf '%s\n' "}" >>"$temp_cf_geo"
    if ! _require_safe_path "/etc/nginx/conf.d/cf_real_ip.conf" "写入 CF Real IP"; then return 1; fi
    if ! _require_safe_path "/etc/nginx/conf.d/cf_geo.conf" "写入 CF Geo"; then return 1; fi
    if ! _require_safe_path "/etc/nginx/snippets/cf_allow.conf" "写入 CF Allow"; then return 1; fi
    mv "$temp_cf_real" /etc/nginx/conf.d/cf_real_ip.conf
    mv "$temp_cf_geo" /etc/nginx/conf.d/cf_geo.conf
    mv "$temp_cf_allow" /etc/nginx/snippets/cf_allow.conf
    printf '%b' "${CYAN}写入文件: /etc/nginx/snippets/cf_allow.conf${NC}\n"
    printf '%b' "${CYAN}写入文件: /etc/nginx/conf.d/cf_real_ip.conf${NC}\n"
    printf '%b' "${CYAN}写入文件: /etc/nginx/conf.d/cf_geo.conf${NC}\n"
    printf '%b' "${GREEN}本次生效网段(含本地环回): ${allow_count}${NC}\n"
    log_message SUCCESS "Cloudflare IP 列表更新完成。"
    printf '%b' "${GREEN}Cloudflare IP 列表已更新。${NC}\n"
    local test_output=""
    local test_rc=0
    test_output=$(nginx -t 2>&1) || test_rc=$?
    if [ "$test_rc" -eq 0 ]; then
      if control_nginx reload; then
        printf '%b' "${GREEN}Nginx 配置检测通过并已重载。${NC}\n"
      else
        printf '%b' "${YELLOW}Nginx 配置检测通过，但自动重载失败，请手动执行 nginx reload。${NC}\n"
      fi
    else
      printf '%b' "${YELLOW}Nginx 配置检测失败，已写入文件但未自动重载。${NC}\n"
      printf '%b' "${YELLOW}失败原因: ${test_output}${NC}\n"
    fi
  else
    log_message ERROR "获取 Cloudflare IP 列表失败,请检查 VPS 的国际网络连通性。"
    printf '%b' "${RED}Cloudflare IP 列表更新失败。${NC}\n"
  fi
  rm -f "$temp_allow" "$temp_v4" "$temp_v6" "$temp_cf_allow" "$temp_cf_real" "$temp_cf_geo" 2>/dev/null || true
}

_handle_backup_restore() {
  _generate_op_id
  _render_menu "维护选项与灾备工具" "1. 备份与恢复面板 (数据层)" "2. 重建所有 HTTP 配置 (应用层)" "3. 修复定时任务 (系统层)"
  local c
  if ! c=$(prompt_menu_choice "1-3" "true"); then return; fi
  case "$c" in
  1)
    _render_menu "备份与恢复系统" "1. 创建新备份 (打包所有配置与证书)" "2. 从完整备份包还原" "3. 从 本地快照 回滚元数据"
    local bc
    if ! bc=$(prompt_menu_choice "1-3" "true"); then return; fi
    case "$bc" in
    1)
      local ts
      ts=$(date +%Y%m%d_%H%M%S)
      local backup_file="$BACKUP_DIR/nginx_manager_backup_$ts.tar.gz"
      log_message INFO "正在打包备份..."
      if tar -czf "$backup_file" -C / "$PROJECTS_METADATA_FILE" "$TCP_PROJECTS_METADATA_FILE" "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_STREAM_AVAILABLE_DIR" "$SSL_CERTS_BASE_DIR" 2>/dev/null; then log_message SUCCESS "备份成功: $backup_file"; else log_message ERROR "备份失败。"; fi
      ;;
    2)
      printf '%b' "\n${CYAN}可用备份列表:${NC}\n"
      ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || {
        log_message WARN "无可用备份。"
        return
      }
      local file_path
      if ! file_path=$(prompt_input "请输入完整备份文件路径" "" "" "" "true"); then return; fi
      if [ -n "$file_path" ] && ! _require_safe_path "$file_path" "还原"; then return; fi
      [ -z "$file_path" ] && return
      [ ! -f "$file_path" ] && log_message ERROR "文件不存在" && return
      if confirm_or_cancel "警告:还原将覆盖当前配置,是否继续?"; then
        if [ "$DRY_RUN" = "true" ]; then
          log_message INFO "[DRY-RUN] systemctl stop nginx"
        else
          systemctl stop nginx || true
        fi
        log_message INFO "正在解压还原..."
        if tar -xzf "$file_path" -C /; then
          log_message SUCCESS "还原完成。"
          control_nginx restart
        else log_message ERROR "解压失败。"; fi
      fi
      ;;
    3)
      _render_menu "选择要回滚的数据类型" "1. 恢复 HTTP 项目" "2. 恢复 TCP 项目"
      local snap_type
      if ! snap_type=$(prompt_menu_choice "1-2" "true"); then return; fi
      local target_file=""
      local filter_str=""
      [ "$snap_type" = "1" ] && target_file="$PROJECTS_METADATA_FILE" && filter_str="projects_"
      [ "$snap_type" = "2" ] && target_file="$TCP_PROJECTS_METADATA_FILE" && filter_str="tcp_projects_"
      [ -z "$target_file" ] && return
      printf '%b' "\n${CYAN}可用快照 (${filter_str}):${NC}\n"
      ls -lh "$JSON_BACKUP_DIR"/${filter_str}*.bak 2>/dev/null || {
        log_message WARN "无快照。"
        return
      }
      local snap_path
      if ! snap_path=$(prompt_input "请输入要恢复的快照路径" "" "" "" "true"); then return; fi
      if [ -n "$snap_path" ] && ! _require_safe_path "$snap_path" "快照恢复"; then return; fi
      if [ -n "$snap_path" ] && [ -f "$snap_path" ]; then
        if confirm_or_cancel "这将会回滚记录,确认执行?"; then
          snapshot_json "$target_file"
          cp "$snap_path" "$target_file"
          log_message SUCCESS "数据回滚完毕!(建议返回上级菜单执行 '重建所有 HTTP 配置' 同步 Nginx)"
        fi
      fi
      ;;
    esac
    ;;
  2) _rebuild_all_nginx_configs ;;
  3) _manage_cron_jobs ;;
  esac
}

# ==============================================================================
# SECTION: 日志与运维
# ==============================================================================

_view_file_with_tail() {
  local file="${1:-}"
  if [ ! -f "$file" ]; then
    log_message ERROR "文件不存在: $file"
    return
  fi
  printf '%b' "${CYAN}--- 实时日志 (Ctrl+C 退出) ---${NC}\n"
  tail -f -n 50 "$file" || true
  printf '%b' "\n${CYAN}--- 日志查看结束 ---${NC}\n"
}
_view_acme_log() {
  local f="$HOME/.acme.sh/acme.sh.log"
  [ ! -f "$f" ] && f="/root/.acme.sh/acme.sh.log"
  _view_file_with_tail "$f"
}
_view_nginx_global_log() {
  _render_menu "Nginx 全局日志" "1. 访问日志" "2. 错误日志"
  local c
  if ! c=$(prompt_menu_choice "1-2" "true"); then return; fi
  case "$c" in 1) _view_file_with_tail "$NGINX_ACCESS_LOG" ;; 2) _view_file_with_tail "$NGINX_ERROR_LOG" ;; esac
}

_manager_cron_log_path() {
  local cron_log
  cron_log=$(_sanitize_log_file "$LOG_FILE" 2>/dev/null || true)
  if [ -z "$cron_log" ]; then cron_log="$LOG_FILE_DEFAULT"; fi
  printf '%s\n' "$cron_log"
}

_cleanup_legacy_manager_crontab() {
  local cron_tmp
  cron_tmp=$(mktemp /tmp/cron.legacy.clean.XXXXXX)
  chmod 600 "$cron_tmp"
  crontab -l 2>/dev/null | grep -v -- "$SCRIPT_PATH --cron" | grep -v -- "$SCRIPT_PATH --cf-ip-update" >"$cron_tmp" || true
  crontab "$cron_tmp" >/dev/null 2>&1 || true
  rm -f "$cron_tmp"
}

_write_manager_cron_file() {
  if ! acquire_cron_lock; then
    log_message ERROR "无法获取全局锁，已取消写入 cron"
    return 1
  fi
  trap 'release_cron_lock' RETURN
  if ! _require_safe_path "$CRON_MANAGER_FILE" "写入 cron.d"; then return 1; fi
  local cron_log
  cron_log=$(_manager_cron_log_path)
  {
    printf '%s\n' "SHELL=/bin/sh"
    printf '%s\n' "PATH=/usr/local/bin:/usr/bin:/bin"
    printf '%s\n' "0 3 * * * root ${SCRIPT_PATH} --cron >> ${cron_log} 2>&1"
    if [ -f "$CF_AUTO_UPDATE_ENABLED_FILE" ]; then
      printf '%s\n' "15 3 * * 0 root ${SCRIPT_PATH} --cf-ip-update >> ${cron_log} 2>&1"
    fi
  } | _atomic_write_file "$CRON_MANAGER_FILE" "0644"
  _cleanup_legacy_manager_crontab
  return 0
}

_manager_cron_has_job() {
  local pattern="${1:-}"
  if [ -f "$CRON_MANAGER_FILE" ] && grep -q -- "$pattern" "$CRON_MANAGER_FILE"; then
    return 0
  fi
  return 1
}

_manage_cron_jobs() {
  local has_acme=0 has_manager=0
  if crontab -l 2>/dev/null | grep -q "\.acme\.sh/acme\.sh"; then has_acme=1; fi
  if _manager_cron_has_job "$SCRIPT_PATH --cron"; then has_manager=1; fi
  local has_cf_auto=0
  if [ -f "$CF_AUTO_UPDATE_ENABLED_FILE" ] && _manager_cron_has_job "$SCRIPT_PATH --cf-ip-update"; then has_cf_auto=1; fi
  local -a lines=()
  lines+=(" 1. acme.sh 原生续期进程 : $([ $has_acme -eq 1 ] && printf '%b' "${GREEN}正常运行${NC}" || printf '%b' "${RED}缺失${NC}")")
  lines+=(" 2. 本面板接管守护进程   : $([ $has_manager -eq 1 ] && printf '%b' "${GREEN}正常运行${NC}" || printf '%b' "${RED}缺失${NC}")")
  lines+=(" 3. Cloudflare IP 自动更新 : $([ $has_cf_auto -eq 1 ] && printf '%b' "${GREEN}正常运行${NC}" || printf '%b' "${YELLOW}未启用${NC}")")
  if [ $has_acme -eq 1 ] && [ $has_manager -eq 1 ]; then
    lines+=("${GREEN}系统定时任务状态完全健康,无需干预。${NC}")
  else lines+=("${YELLOW}检测到必需的定时任务不完整,正在自动执行修复...${NC}"); fi
  _render_menu "系统定时任务 (Cron) 诊断与修复" "${lines[@]}"
  if [ $has_acme -eq 0 ] || [ $has_manager -eq 0 ]; then
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
      log_message ERROR "非交互模式禁止修复定时任务"
      return 1
    fi
    "$ACME_BIN" --install-cronjob >/dev/null 2>&1 || true
    _write_manager_cron_file
    log_message SUCCESS "定时任务修复完毕,系统级容灾续期已挂载。"
  fi
  press_enter_to_continue
}

# ==============================================================================
# SECTION: 数据与 HTTP 代理配置
# ==============================================================================

_normalize_custom_config_text() {
  local content="${1:-}"
  if [ -z "$content" ]; then
    printf '%s\n' ""
    return 0
  fi
  awk '
    {
      gsub(/[ \t]+$/, "", $0)
      lines[++n]=$0
    }
    END {
      start=1
      while (start<=n && lines[start] ~ /^[ \t]*$/) start++
      end=n
      while (end>=start && lines[end] ~ /^[ \t]*$/) end--
      blank=0
      for (i=start; i<=end; i++) {
        if (lines[i] ~ /^[ \t]*$/) {
          blank++
          if (blank > 1) continue
          print ""
        } else {
          blank=0
          print lines[i]
        }
      }
    }
  ' <<<"$content"
}

_version_ge() {
  local a="${1:-0}"
  local b="${2:-0}"
  local first
  first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)
  [ "$first" = "$b" ]
}

_detect_nginx_version() {
  local raw=""
  raw=$(nginx -v 2>&1 || true)
  if [[ "$raw" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$raw" =~ ([0-9]+\.[0-9]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}.0"
    return 0
  fi
  return 1
}

_check_template_compatibility() {
  local id=""
  local nginx_ver=""
  local min_ver=""
  nginx_ver=$(_detect_nginx_version 2>/dev/null || true)
  [ -z "$nginx_ver" ] && return 0
  for id in "$@"; do
    [ -z "$id" ] && continue
    # shellcheck disable=SC2016
    min_ver=$(_manifest_query --arg id "$id" '.templates[] | select(.id == $id) | (.min_nginx_version // "")' 2>/dev/null || true)
    if [ -n "$min_ver" ] && ! _version_ge "$nginx_ver" "$min_ver"; then
      log_message ERROR "模板 ${id} 要求 Nginx >= ${min_ver}，当前版本 ${nginx_ver}"
      return 1
    fi
  done
  return 0
}

_template_approval_gate() {
  local action="${1:-apply}"
  local domain="${2:-}"
  local ids_text="${3:-}"
  local mode="${4:-}"
  if [ -z "${TEMPLATE_APPROVAL_HOOK:-}" ]; then
    return 0
  fi
  if [ ! -x "$TEMPLATE_APPROVAL_HOOK" ]; then
    log_message ERROR "审批钩子不可执行: ${TEMPLATE_APPROVAL_HOOK}"
    return 1
  fi
  if ! TEMPLATE_ACTION="$action" TEMPLATE_DOMAIN="$domain" TEMPLATE_IDS="$ids_text" TEMPLATE_MODE="$mode" OP_ID="${OP_ID:-NA}" "$TEMPLATE_APPROVAL_HOOK" >/dev/null 2>&1; then
    log_message ERROR "审批钩子拒绝本次操作: action=${action}, domain=${domain}"
    return 1
  fi
  return 0
}

_normalize_max_body_size() {
  local raw="${1:-}"
  local trimmed="${raw//$'\r'/}"
  local normalized
  local body_re='^client_max_body_size[[:space:]]+([^[:space:];]+)[[:space:]]*;?[[:space:]]*$'

  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  if [ -z "$trimmed" ] || [ "$trimmed" = "null" ]; then
    printf '%s\n' ""
    return 0
  fi

  if [[ "$trimmed" == *$'\n'* ]]; then
    return 1
  fi

  if [[ "$trimmed" =~ $body_re ]]; then
    normalized="${BASH_REMATCH[1]}"
  else
    normalized="${trimmed%;}"
  fi

  normalized="${normalized,,}"
  if [[ "$normalized" =~ ^0[kmg]?$ ]]; then
    printf '%s\n' "0"
    return 0
  fi

  if [[ "$normalized" =~ ^[1-9][0-9]*[kKmMgG]?$ ]] || [[ "$normalized" =~ ^0$ ]]; then
    printf '%s\n' "$normalized"
    return 0
  fi
  return 1
}

_health_check_nginx_config() {
  local domain="${1:-}"
  if [ "$HEALTH_CHECK_ENABLED" != "true" ]; then return 0; fi
  if [ -z "$domain" ]; then return 0; fi
  local url="${HEALTH_CHECK_SCHEME}://127.0.0.1${HEALTH_CHECK_PATH}"
  local host_header="$domain"
  if ! command -v curl >/dev/null 2>&1; then return 0; fi
  local expect_list=()
  IFS=',' read -r -a expect_list <<<"$HEALTH_CHECK_EXPECT_CODES"
  local retries="$HEALTH_CHECK_RETRIES"
  if ! [[ "$retries" =~ ^[0-9]+$ ]] || [ "$retries" -lt 1 ]; then retries=1; fi
  local attempt=1
  while [ $attempt -le "$retries" ]; do
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout "$HEALTH_CHECK_TIMEOUT" --max-time "$HEALTH_CHECK_TIMEOUT" -H "Host: ${host_header}" "$url" 2>/dev/null || printf '%s' "000")
    local ok="false"
    local c
    for c in "${expect_list[@]}"; do
      if [ "$code" = "$c" ]; then
        ok="true"
        break
      fi
    done
    if [ "$ok" = "true" ]; then return 0; fi
    attempt=$((attempt + 1))
    sleep "$HEALTH_CHECK_RETRY_DELAY"
  done
  log_message ERROR "健康检查失败: ${domain}${HEALTH_CHECK_PATH} (code=${code})"
  return 1
}

_view_nginx_config() {
  local domain="${1:-}"
  local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
  if [ ! -f "$conf" ]; then
    log_message WARN "此项目未生成配置文件。"
    return
  fi
  local -a lines=()
  while IFS= read -r line; do lines+=("$line"); done <"$conf"
  _render_menu "配置文件: $domain" "${lines[@]}"
}

_rebuild_all_nginx_configs() {
  log_message INFO "准备基于现有记录从零重建所有 Nginx HTTP 代理文件..."
  if ! confirm_or_cancel "这将会覆盖当前所有 Nginx HTTP 代理配置文件,是否继续?"; then return; fi
  local all_projects
  all_projects=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
  if [ -z "$all_projects" ]; then
    log_message WARN "没有任何项目记录可供重建。"
    return
  fi
  local success=0 fail=0
  while read -r p; do
    [ -z "$p" ] && continue
    local d port
    local old_json=""
    local tx_json=""
    d=$(jq -r .domain <<<"$p")
    port=$(jq -r .resolved_port <<<"$p")
    if ! _require_valid_domain "$d"; then
      log_message ERROR "域名无效，跳过: $d"
      fail=$((fail + 1))
      continue
    fi
    if [ "$port" == "cert_only" ]; then continue; fi
    if ! _require_valid_port "$port"; then
      log_message ERROR "端口无效，跳过: $d"
      fail=$((fail + 1))
      continue
    fi
    log_message INFO "重建配置文件: $d ..."
    old_json=$(_get_project_json "$d")
    tx_json=$(jq --arg tok "rebuild:${OP_ID:-manual}:${d}:$(date +%s)" '.idempotency_token = $tok' <<<"$p")
    if _apply_project_transaction "$d" "$tx_json" "$old_json" "standard"; then
      success=$((success + 1))
    else
      fail=$((fail + 1))
      log_message ERROR "重建失败: $d"
    fi
  done <<<"$all_projects"
  safe_rm "/etc/nginx/snippets/cf_allow.conf" "删除 CF Allow"
  log_message SUCCESS "重建完成。成功: $success, 失败: $fail"
}

# ==============================================================================
# SECTION: 数据与 TCP 代理配置
# ==============================================================================

_save_tcp_project_json() {
  local json="${1:-}"
  if [ -z "$json" ]; then return 1; fi
  snapshot_json "$TCP_PROJECTS_METADATA_FILE"
  local port
  port=$(jq -r .listen_port <<<"$json")
  if [ -z "$port" ] || [ "$port" = "null" ]; then return 1; fi
  json_upsert_by_key "$TCP_PROJECTS_METADATA_FILE" "listen_port" "$port" "$json"
}

_write_and_enable_tcp_config() {
  local port="${1:-}"
  local json="${2:-}"
  local conf="$NGINX_STREAM_AVAILABLE_DIR/tcp_${port}.conf"
  if ! _require_valid_port "$port"; then return 1; fi
  if ! _require_safe_path "$conf" "配置写入"; then return 1; fi
  local target tls_enabled ssl_cert ssl_key
  IFS=$'\t' read -r target tls_enabled ssl_cert ssl_key < <(jq -r '[.target, (.tls_enabled // "n"), (.ssl_cert // ""), (.ssl_key // "")] | @tsv' <<<"$json")
  local listen_flag=""
  local ssl_block=""
  if [ "$tls_enabled" == "y" ]; then
    : "ssl_cert/ssl_key already set"
    listen_flag="ssl"
    ssl_block="\n    ssl_certificate ${ssl_cert};\n    ssl_certificate_key ${ssl_key};\n    ssl_protocols TLSv1.2 TLSv1.3;\n    ssl_ecdh_curve X25519:prime256v1:secp384r1;\n    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';"
  fi
  local upstream_block=""
  local proxy_pass_target="${target}"
  if [[ "$target" == *","* ]]; then
    proxy_pass_target="tcp_backend_${port}"
    upstream_block="upstream ${proxy_pass_target} {"
    IFS=',' read -ra ADDR <<<"$target"
    for i in "${ADDR[@]}"; do upstream_block+=$'\n    server '"${i};"; done
    upstream_block+=$'\n}\n'
  fi
  local temp_conf
  temp_conf=$(mktemp "${conf}.tmp.XXXXXX")
  cat >"$temp_conf" <<EOF
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
  local name
  if ! name=$(prompt_input "项目备注名称" "MyTCP" "" "" "false"); then return; fi
  local l_port
  if ! l_port=$(prompt_input "本机监听端口" "" "^[0-9]+$" "无效端口" "false"); then return; fi
  if ! _is_valid_port "$l_port"; then
    log_message ERROR "端口范围无效 (1-65535)。"
    return
  fi
  local target
  if ! target=$(prompt_input "目标地址" "" "^[a-zA-Z0-9.-]+:[0-9]+(,[a-zA-Z0-9.-]+:[0-9]+)*$" "格式错误" "false"); then return; fi
  if ! _is_valid_target "$target"; then
    log_message ERROR "目标地址格式无效。"
    return
  fi
  local tls_enabled="n"
  local ssl_cert=""
  local ssl_key=""
  if confirm_or_cancel "是否开启 TLS/SSL 加密卸载?"; then
    tls_enabled="y"
    local http_projects
    http_projects=$(jq -c '.[] | select(.cert_file != null and .cert_file != "")' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
    if [ -z "$http_projects" ]; then
      log_message ERROR "未发现可用证书。"
      return 1
    fi
    printf '%b' "\n${CYAN}请选择要用于加密流量的证书:${NC}\n"
    local idx=0
    declare -A domain_map cert_map key_map
    while read -r p; do
      [ -z "$p" ] && continue
      idx=$((idx + 1))
      domain_map[$idx]=$(jq -r .domain <<<"$p")
      cert_map[$idx]=$(jq -r .cert_file <<<"$p")
      key_map[$idx]=$(jq -r .key_file <<<"$p")
      printf '%b' " ${GREEN}${idx}.${NC} ${domain_map[$idx]}\n"
    done <<<"$http_projects"
    local c_idx
    while true; do
      if ! c_idx=$(prompt_input "请输入序号" "" "^[0-9]+$" "无效序号" "false"); then return; fi
      if [ "$c_idx" -ge 1 ] && [ "$c_idx" -le "$idx" ]; then
        ssl_cert="${cert_map[$c_idx]}"
        ssl_key="${key_map[$c_idx]}"
        break
      else log_message ERROR "序号越界"; fi
    done
  fi
  local json
  json=$(jq -n --arg n "$name" --arg lp "$l_port" --arg t "$target" --arg te "$tls_enabled" --arg sc "$ssl_cert" --arg sk "$ssl_key" '{name:$n, listen_port:$lp, target:$t, tls_enabled:$te, ssl_cert:$sc, ssl_key:$sk}')
  if _write_and_enable_tcp_config "$l_port" "$json"; then
    NGINX_RELOAD_NEEDED="true"
    if control_nginx_reload_if_needed; then
      _save_tcp_project_json "$json"
      log_message SUCCESS "TCP 代理已成功配置 ($l_port) [TLS: $tls_enabled]。"
    else
      log_message ERROR "Nginx 重载失败"
      rm -f "$NGINX_STREAM_AVAILABLE_DIR/tcp_${l_port}.conf" "$NGINX_STREAM_ENABLED_DIR/tcp_${l_port}.conf"
      NGINX_RELOAD_NEEDED="true"
      control_nginx_reload_if_needed || true
    fi
  fi
}

_display_tcp_projects_list() {
  local json="${1:-}"
  printf '%b' "\n"
  printf "${BOLD}%-4s %-10s %-5s %-12s %-22s${NC}\n" "ID" "端口" "TLS" "备注" "目标地址"
  printf '%b' "──────────────────────────────────────────────────────────\n"
  local idx=0
  jq -r '.[] | [(.listen_port // ""), (.name // "-"), (.target // ""), (.tls_enabled // "n")] | @tsv' <<<"$json" | while IFS=$'\t' read -r port name target tls; do
    idx=$((idx + 1))
    local short_target="${target:0:22}"
    [ ${#target} -gt 22 ] && short_target="${target:0:19}..."
    local tls_str="${RED}否${NC}"
    [ "$tls" == "y" ] && tls_str="${GREEN}是${NC}"
    printf "%-4d ${GREEN}%-10s${NC} %-14s %-12s %-22s\n" "$idx" "$port" "$tls_str" "${name:0:10}" "$short_target"
  done
  printf '%b' "\n"
}

manage_tcp_configs() {
  _generate_op_id
  if ! acquire_tcp_lock; then return 1; fi
  while true; do
    local all count
    all=$(jq . "$TCP_PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "[]")
    count=$(jq 'length' <<<"$all")
    if [ "$count" -eq 0 ]; then
      log_message WARN "暂无 TCP 项目。"
      break
    fi
    if ! select_item_and_act "$all" "$count" "请输入序号选择 TCP 项目 (回车返回)" "listen_port" _manage_tcp_actions _display_tcp_projects_list; then break; fi
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
    -e 's/^\[[A-Za-z]{3} [A-Za-z]{3}[[:space:]]+[0-9]{1,2}[[:space:]][0-9:]{8}[[:space:]][A-Z]{2,5}[[:space:]][0-9]{4}\][[:space:]]*//' \
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
    printf '%s\n' "{}" >"$RENEW_FAIL_DB"
  fi
}

_renew_fail_incr() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    printf '%s\n' "0"
    return 0
  fi
  _renew_fail_db_init
  local temp
  temp=$(mktemp)
  chmod 600 "$temp"
  local now_ts
  now_ts=$(date +%s)
  local count
  count=$(jq -r --arg d "$domain" '(.[$d].count // 0) + 1' "$RENEW_FAIL_DB" 2>/dev/null || printf '%s\n' "1")
  jq --arg d "$domain" --argjson c "$count" --argjson ts "$now_ts" '. + {($d): {count: $c, ts: $ts}}' "$RENEW_FAIL_DB" >"$temp" && mv "$temp" "$RENEW_FAIL_DB"
  printf '%s\n' "$count"
}

_renew_fail_reset() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then return 0; fi
  _renew_fail_db_init
  local temp
  temp=$(mktemp)
  chmod 600 "$temp"
  jq --arg d "$domain" 'del(.[$d])' "$RENEW_FAIL_DB" >"$temp" && mv "$temp" "$RENEW_FAIL_DB"
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
  jq --argjson cutoff "$cutoff" 'with_entries(select((.value.ts // 0) >= $cutoff))' "$RENEW_FAIL_DB" >"$temp" && mv "$temp" "$RENEW_FAIL_DB"
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
    if [ -z "$temp_svc" ] && pgrep -x nginx >/dev/null 2>&1; then
      temp_svc="nginx"
    fi
    if [ -z "$temp_svc" ]; then
      log_message ERROR "检测到 80/443 端口被占用，但无法识别占用服务。请手动释放端口或停用相关服务后重试。"
      return 1
    fi
    if [ "$temp_svc" = "nginx" ]; then
      if [ ! -f "$NGINX_SITES_AVAILABLE_DIR/$domain.conf" ]; then
        if ! _require_safe_path "$temp_conf_ref" "临时配置"; then return 1; fi
        cat >"$temp_conf_ref" <<EOF
server { listen 80; server_name ${domain}; location /.well-known/acme-challenge/ { root $NGINX_WEBROOT_DIR; } }
EOF
        ln -sf "$temp_conf_ref" "$NGINX_SITES_ENABLED_DIR/"
        control_nginx reload || true
        # shellcheck disable=SC2034
        temp_conf_created_ref="true"
      fi
      mkdir -p "$NGINX_WEBROOT_DIR"
      cmd_ref+=("--webroot" "$NGINX_WEBROOT_DIR")
    else
      if confirm_or_cancel "是否临时停止 $temp_svc 以释放 80 端口?"; then
        if [ "$DRY_RUN" = "true" ]; then
          log_message INFO "[DRY-RUN] systemctl stop $temp_svc"
        else
          systemctl stop "$temp_svc"
          stopped_svc_ref="$temp_svc"
          INTERRUPT_RESUME_SERVICE="$stopped_svc_ref"
          trap '_on_int_resume_service' INT TERM
        fi
      fi
      cmd_ref+=("--standalone")
    fi
  else
    cmd_ref+=("--standalone")
  fi
}

_run_acme_issue_command() {
  # shellcheck disable=SC2178
  local -n cmd_ref="$1"
  local -n log_temp_ref="$2"
  local -n ret_ref="$3"
  local log_temp
  log_temp=$(mktemp /tmp/acme_cmd_log.XXXXXX)
  chmod 600 "$log_temp"
  printf '%b' "${YELLOW}正在通信 (约 30-60 秒,请勿中断)... ${NC}"
  run_cmd 90 "${cmd_ref[@]}" >"$log_temp" 2>&1 &
  local pid=$!
  local spinstr="|/-\\"
  while kill -0 $pid 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep 0.2
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
  wait $pid
  # shellcheck disable=SC2034
  ret_ref=$?
  # shellcheck disable=SC2034
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
    control_nginx reload || true
  fi
  if [ -n "$stopped_svc" ]; then
    systemctl start "$stopped_svc"
    INTERRUPT_RESUME_SERVICE=""
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
  IFS=$'\t' read -r domain method < <(jq -r '[.domain, .acme_validation_method] | @tsv' <<<"$json")
  LAST_CERT_ELAPSED=""
  LAST_CERT_CERT=""
  LAST_CERT_KEY=""
  if [ "$method" == "reuse" ]; then
    IFS=$'\t' read -r LAST_CERT_CERT LAST_CERT_KEY < <(jq -r '[.cert_file, .key_file] | @tsv' <<<"$json")
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
  IFS=$'\t' read -r provider wildcard ca < <(jq -r '[.dns_api_provider, .use_wildcard, .ca_server_url] | @tsv' <<<"$json")
  ca=$(printf '%s' "$ca" | tr -d '\r' | xargs)
  if [ -z "$ca" ] || [ "$ca" = "null" ]; then
    ca="https://acme-v02.api.letsencrypt.org/directory"
  fi
  local ca_selector="$ca"
  case "$ca" in
  https://acme-v02.api.letsencrypt.org/directory) ca_selector="letsencrypt" ;;
  https://acme.zerossl.com/v2/DV90) ca_selector="zerossl" ;;
  google) ca_selector="google" ;;
  esac
  run_cmd 20 "$ACME_BIN" --set-default-ca --server "$ca_selector" >/dev/null 2>&1 || true
  if [ "$ca" = "https://acme.zerossl.com/v2/DV90" ] && ! _ensure_zerossl_account_email "$ca"; then
    if [ "$IS_INTERACTIVE_MODE" = "true" ] && [ "${JB_NONINTERACTIVE:-false}" != "true" ]; then
      if confirm_or_cancel "ZeroSSL 邮箱注册失败，是否自动切换 Let's Encrypt?" "y"; then
        log_message INFO "ZeroSSL 注册失败，自动切换到 Let's Encrypt。"
        ca="https://acme-v02.api.letsencrypt.org/directory"
        run_cmd 20 "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
      else
        return 1
      fi
    else
      log_message INFO "ZeroSSL 注册失败（非交互），自动切换到 Let's Encrypt。"
      ca="https://acme-v02.api.letsencrypt.org/directory"
      run_cmd 20 "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    fi
  fi
  local cert="$SSL_CERTS_BASE_DIR/$domain.cer"
  local key="$SSL_CERTS_BASE_DIR/$domain.key"
  local start_ts
  start_ts=$(date +%s)

  log_message INFO "正在为 $domain 申请证书 ($method, CA: ${ca})..."
  local cmd=("$ACME_BIN" --issue --force --ecc -d "$domain" --server "$ca" --log)
  [ "$wildcard" = "y" ] && cmd+=("-d" "*.$domain")

  local temp_conf_created="false"
  local temp_conf="$NGINX_SITES_AVAILABLE_DIR/temp_acme_${domain}.conf"
  local stopped_svc=""
  if ! _require_valid_domain "$domain"; then return 1; fi
  if [ "$method" = "dns-01" ]; then
    if [ "$provider" = "dns_cf" ]; then
      if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
        local saved_t
        saved_t=$(grep "^SAVED_CF_Token=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
        local saved_a
        saved_a=$(grep "^SAVED_CF_Account_ID=" "$HOME/.acme.sh/account.conf" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)
        local use_saved="false"
        if [[ -n "$saved_t" && -n "$saved_a" ]]; then
          printf '%b' "${CYAN}检测到已保存的 Cloudflare 凭证:${NC}\n"
          printf '%b' "  Token : $(_mask_string "$saved_t")\n"
          printf '%b' "  AccID : $(_mask_string "$saved_a")\n"
          if confirm_or_cancel "是否复用该凭证?"; then use_saved="true"; fi
        fi
        if [ "$use_saved" = "false" ]; then
          local t
          if ! t=$(_prompt_secret "请输入新的 CF_Token"); then return 1; fi
          local a
          if ! a=$(_prompt_secret "请输入新的 Account_ID"); then return 1; fi
          [ -n "$t" ] && export CF_Token="$t"
          [ -n "$a" ] && export CF_Account_ID="$a"
        fi
      fi
    fi
    cmd+=("--dns" "$provider")
  elif [ "$method" = "http-01" ]; then
    if ! _prepare_http01_challenge "$domain" cmd temp_conf_created temp_conf stopped_svc; then return 1; fi
  fi

  local log_temp
  log_temp=$(mktemp /tmp/acme_cmd_log.XXXXXX)
  chmod 600 "$log_temp"
  printf '%b' "${YELLOW}正在通信 (约 30-60 秒,请勿中断)... ${NC}"
  run_cmd 90 "${cmd[@]}" >"$log_temp" 2>&1 &
  local pid=$!
  local spinstr="|/-\\"
  while kill -0 $pid 2>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    local spinstr=$temp${spinstr%"$temp"}
    sleep 0.2
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
  wait $pid
  local ret=$?
  _cleanup_http01_challenge "$temp_conf_created" "$temp_conf" "$stopped_svc"

  if [ $ret -ne 0 ]; then
    printf '%b' "\n"
    log_message ERROR "申请失败: $domain"
    printf '%b' "${CYAN}--- 错误详情 (已脱敏) ---${NC}\n"
    _mask_sensitive_data <"$log_temp"
    printf '%b' "${CYAN}------------------------${NC}\n"
    rm -f "$log_temp"
    _send_tg_notify "fail" "$domain" "acme.sh 申请证书失败。" ""
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret
    return 1
  fi
  rm -f "$log_temp"
  local rcmd
  local resolved_port
  local install_reload_cmd=""
  IFS=$'\t' read -r rcmd resolved_port < <(jq -r '[.reload_cmd // empty, .resolved_port // empty] | @tsv' <<<"$json")
  if [ -n "$rcmd" ] && [ "$resolved_port" != "cert_only" ]; then
    log_message WARN "当前为 HTTP 代理项目，证书安装阶段将忽略自定义 Hook，统一由事务重载接管。"
    rcmd=""
  fi
  if ! _validate_hook_command "$rcmd"; then
    log_message ERROR "不安全的 Hook 命令,已拒绝。"
    return 1
  fi
  if [ "$resolved_port" == "cert_only" ]; then
    install_reload_cmd="$rcmd"
  else
    install_reload_cmd=""
  fi
  local inst=("$ACME_BIN" --install-cert --ecc -d "$domain" --key-file "$key" --fullchain-file "$cert" --log)
  [ -n "$install_reload_cmd" ] && inst+=("--reloadcmd" "$install_reload_cmd")
  [ "$wildcard" = "y" ] && inst+=("-d" "*.$domain")
  "${inst[@]}" >/dev/null 2>&1
  local acme_ret=$?
  if [ -f "$cert" ] && [ -f "$key" ]; then
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$cert" 2>/dev/null || true
    local elapsed=$(($(date +%s) - start_ts))
    LAST_CERT_ELAPSED="${elapsed}s"
    LAST_CERT_CERT="$cert"
    LAST_CERT_KEY="$key"
    log_message SUCCESS "证书文件已成功生成于 /etc/ssl/ 目录。"
    if [ $acme_ret -ne 0 ]; then
      printf '%b' "\n${RED}⚠️  [警告] 自动重启命令执行失败: $install_reload_cmd${NC}\n"
      printf '%b' "${YELLOW}证书已安装,但服务未能自动加载新证书。${NC}\n"
    fi
    _send_tg_notify "success" "$domain" "证书已成功安装。"
    unset CF_Token CF_Account_ID Ali_Key Ali_Secret
    return 0
  else
    log_message ERROR "证书文件安装后丢失。"
    return 1
  fi
}

_prompt_mcp_protection_settings() {
  local cur_path="${1:-}"
  local cur_token="${2:-}"
  local mcp_path="$cur_path"
  local mcp_token="$cur_token"
  local mcp_default="n"

  if [ -n "$mcp_path" ] && [ -n "$mcp_token" ]; then
    mcp_default="y"
  fi
  if confirm_or_cancel "是否启用 MCP 接口路径 Token 防护? (仅保护接口路径)" "$mcp_default"; then
    while true; do
      if ! mcp_path=$(prompt_input "请输入 MCP 接口路径 (示例: /mcp)" "${mcp_path:-}" "" "" "false"); then
        return 1
      fi
      if _is_valid_location_path "$mcp_path"; then
        break
      fi
      log_message ERROR "路径无效: 必须以 / 开头，不能为 /，仅支持字母数字和 /._~%%:+-"
    done

    if [ -n "$mcp_token" ]; then
      local masked_mcp_token=""
      masked_mcp_token=$(_mask_string "$mcp_token")
      if ! confirm_or_cancel "检测到已保存 MCP Token(${masked_mcp_token})，是否复用?" "y"; then
        mcp_token=""
      fi
    fi
    while true; do
      if [ -n "$mcp_token" ] && _is_valid_mcp_token "$mcp_token"; then
        break
      fi
      if ! mcp_token=$(_prompt_secret "请输入 MCP Token (最少16位,无回显)"); then
        return 1
      fi
      if _is_valid_mcp_token "$mcp_token"; then
        break
      fi
      log_message ERROR "Token 无效: 仅允许安全字符，长度需在 16-128。"
    done
  else
    mcp_path=""
    mcp_token=""
  fi

  printf '%s\t%s\n' "$mcp_path" "$mcp_token"
}

_prompt_reload_hook_for_cert_only() {
  local auto_sui_cmd=""
  local reload_cmd=""
  local -a hook_lines=()

  if systemctl list-units --type=service | grep -q "s-ui.service"; then
    auto_sui_cmd="systemctl restart s-ui"
  elif systemctl list-units --type=service | grep -q "x-ui.service"; then
    auto_sui_cmd="systemctl restart x-ui"
  fi
  local opt1_text="S-UI / 3x-ui / x-ui"
  [ -n "$auto_sui_cmd" ] && opt1_text="${opt1_text} (自动: ${auto_sui_cmd##* })"
  hook_lines+=("${CYAN}自动重启预设方案:${NC}")
  hook_lines+=("1. ${opt1_text}")
  hook_lines+=("2. V2Ray 原生服务 (systemctl restart v2ray)")
  hook_lines+=("3. Xray 原生服务 (systemctl restart xray)")
  hook_lines+=("4. Nginx 服务 (systemctl reload nginx)")
  hook_lines+=("5. 手动输入自定义 Shell 命令")
  hook_lines+=("6. 跳过")
  _render_menu "配置外部重载组件 (Reload Hook)" "${hook_lines[@]}" >&2

  local hk
  while true; do
    hk=$(prompt_menu_choice "1-6")
    [ -n "$hk" ] && break
  done
  case "$hk" in
  1) reload_cmd="$auto_sui_cmd" ;;
  2) reload_cmd="systemctl restart v2ray" ;;
  3) reload_cmd="systemctl restart xray" ;;
  4) reload_cmd="systemctl reload nginx" ;;
  5)
    if ! reload_cmd=$(prompt_input "请输入完整 Shell 命令" "" "" "" "true"); then
      return 1
    fi
    ;;
  6) reload_cmd="" ;;
  esac

  if [ -n "$reload_cmd" ] && ! _validate_hook_command "$reload_cmd"; then
    return 1
  fi
  printf '%s\n' "$reload_cmd"
}

_prompt_ca_selection() {
  local ca_server="https://acme-v02.api.letsencrypt.org/directory"
  local ca_name="letsencrypt"
  local -a ca_list=("1. Let's Encrypt (默认推荐)" "2. ZeroSSL" "3. Google Public CA")
  _render_menu "选择 CA 机构" "${ca_list[@]}" >&2
  local ca_choice
  while true; do
    ca_choice=$(prompt_menu_choice "1-3")
    [ -n "$ca_choice" ] && break
  done
  case "$ca_choice" in
  1)
    ca_server="https://acme-v02.api.letsencrypt.org/directory"
    ca_name="letsencrypt"
    ;;
  2)
    ca_server="https://acme.zerossl.com/v2/DV90"
    ca_name="zerossl"
    ;;
  3)
    ca_server="google"
    ca_name="google"
    ;;
  esac
  printf '%s\t%s\n' "$ca_server" "$ca_name"
}

_prompt_validation_method_selection() {
  local domain="${1:-}"
  local is_cert_only="${2:-false}"
  local type="${3:-cert_only}"
  local port="${4:-cert_only}"
  local method="http-01"
  local provider=""
  local wildcard="n"
  local method_delim=$'\x01'

  local -a method_display=("1. http-01 (智能无中断 Webroot / Standalone)" "2. dns_cf  (Cloudflare API)" "3. dns_ali (阿里云 API)")
  _render_menu "验证方式" "${method_display[@]}" >&2
  local v_choice
  while true; do
    v_choice=$(prompt_menu_choice "1-3")
    [ -n "$v_choice" ] && break
  done
  case "$v_choice" in
  1) method="http-01" ;;
  2 | 3)
    method="dns-01"
    [ "$v_choice" = "2" ] && provider="dns_cf" || provider="dns_ali"
    if ! wildcard=$(prompt_input "是否申请泛域名? (y/[n])" "n" "^[yYnN]$" "" "false"); then
      return 1
    fi

    if [ "$wildcard" = "y" ] && [ "$is_cert_only" = "false" ]; then
      printf '%b' "\n${BRIGHT_YELLOW}┌──────────────────────────────────────────────┐${NC}\n"
      local box_msg="⚠️  检测到泛域名申请模式"
      local box_line
      printf -v box_line "%-44s" "$box_msg"
      printf '%b' "${BRIGHT_YELLOW}│ ${box_line} │${NC}\n"
      printf '%b' "${BRIGHT_YELLOW}└──────────────────────────────────────────────┘${NC}\n"
      printf '%b' "您的配置将同时覆盖 ${GREEN}${domain}${NC} 和 ${GREEN}*.${domain}${NC}。\n"
      if ! confirm_or_cancel "是否为主域名 ${domain} 配置 Nginx HTTP 代理端口? (选 No 则仅管理证书)" "n"; then
        is_cert_only="true"
        type="cert_only"
        port="cert_only"
        printf '%b' "${CYAN}已切换为证书管理模式，后续将跳过端口与防御设置。${NC}\n"
      fi
    fi
    ;;
  esac

  printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$method" "$method_delim" "$provider" "$method_delim" "$wildcard" "$method_delim" "$is_cert_only" "$method_delim" "$type" "$method_delim" "$port"
}

_build_project_payload_json() {
  local domain="${1:-}"
  local type="${2:-local_port}"
  local name="${3:-}"
  local port="${4:-}"
  local method="${5:-http-01}"
  local provider="${6:-}"
  local wildcard="${7:-n}"
  local ca_server="${8:-https://acme-v02.api.letsencrypt.org/directory}"
  local ca_name="${9:-letsencrypt}"
  local cert_file="${10:-}"
  local key_file="${11:-}"
  local max_body="${12:-}"
  local custom_cfg="${13:-}"
  local cf_strict="${14:-n}"
  local reload_cmd="${15:-}"
  local mcp_path="${16:-}"
  local mcp_token="${17:-}"

  jq -n \
    --arg d "${domain}" --arg t "${type}" --arg n "${name}" --arg p "${port}" \
    --arg m "${method}" --arg dp "${provider}" --arg w "${wildcard}" \
    --arg cu "${ca_server}" --arg cn "${ca_name}" --arg cf "${cert_file}" --arg kf "${key_file}" \
    --arg mb "${max_body}" --arg cc "${custom_cfg}" --arg cs "${cf_strict}" --arg rc "${reload_cmd}" \
    --arg mp "${mcp_path}" --arg mt "${mcp_token}" \
    '{domain:$d, type:$t, name:$n, resolved_port:$p, acme_validation_method:$m, dns_api_provider:$dp, use_wildcard:$w, ca_server_url:$cu, ca_server_name:$cn, cert_file:$cf, key_file:$kf, client_max_body_size:$mb, custom_config:$cc, cf_strict_mode:$cs, reload_cmd:$rc, mcp_protect_path:$mp, mcp_token:$mt}'
}

_detect_reusable_wildcard_cert() {
  local domain="${1:-}"
  local skip_cert="${2:-false}"
  local wc_match=""
  local reuse_wc="false"
  local wc_cert=""
  local wc_key=""

  if [ "$skip_cert" != "false" ]; then
    printf '%s\t%s\t%s\n' "$reuse_wc" "$wc_cert" "$wc_key"
    return 0
  fi

  local all_wcs
  all_wcs=$(jq -c '.[] | select(.use_wildcard == "y" and .cert_file != null)' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
  while read -r wp; do
    [ -z "$wp" ] && continue
    local wd
    wd=$(jq -r .domain <<<"$wp")
    if [[ "$domain" == *".$wd" || "$domain" == "$wd" ]]; then
      wc_match="$wd"
      break
    fi
  done <<<"$all_wcs"

  if [ -n "$wc_match" ]; then
    printf '%b' "\n${GREEN}🎯 智能提示: 检测到系统中已存在匹配的泛域名证书 (*.${wc_match})${NC}\n" >&2
    if confirm_or_cancel "是否直接绑定复用该证书,实现免验证零延迟上线?"; then
      reuse_wc="true"
      local wp
      wp=$(_get_project_json "$wc_match")
      if jq -e . >/dev/null 2>&1 <<<"$wp"; then
        wc_cert=$(jq -r '.cert_file // empty' <<<"$wp" 2>/dev/null || true)
        wc_key=$(jq -r '.key_file // empty' <<<"$wp" 2>/dev/null || true)
      else
        log_message WARN "复用证书配置读取异常，已回退为常规申请流程。"
        reuse_wc="false"
      fi
    fi
  fi

  printf '%s\t%s\t%s\n' "$reuse_wc" "$wc_cert" "$wc_key"
}

_prompt_backend_target_for_project() {
  local cur="${1:-{}}"
  local name="${2:-}"
  local type="local_port"
  local port=""

  local old_type old_port target_default
  old_type=$(jq -r '.type // "local_port"' <<<"$cur" 2>/dev/null || printf '%s' "local_port")
  old_port=$(jq -r '.resolved_port // ""' <<<"$cur" 2>/dev/null || printf '%s' "")
  target_default="$name"
  if [ "$old_type" = "local_port" ] && [ -n "$old_port" ] && [ "$old_port" != "null" ] && [ "$old_port" != "cert_only" ]; then
    target_default="$old_port"
  fi
  [ "$target_default" == "证书" ] && target_default=""

  while true; do
    local target
    if ! target=$(prompt_input "后端目标 (容器名/端口)" "$target_default" "" "" "false"); then
      return 1
    fi
    type="local_port"
    port="$target"
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -wq "$target"; then
      type="docker"
      port=$(docker inspect "$target" --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' 2>/dev/null | head -n1 || true)
      if [ -z "$port" ]; then
        if ! port=$(prompt_input "未检测到端口,手动输入" "80" "^[0-9]+$" "无效端口" "false"); then
          return 1
        fi
      fi
      if ! _is_valid_port "$port"; then
        log_message ERROR "端口范围无效 (1-65535)。"
        return 1
      fi
      break
    fi
    if [[ "$port" =~ ^[0-9]+$ ]] && _is_valid_port "$port"; then break; fi
    log_message ERROR "错误: '$target' 既不是容器也不是端口。" >&2
  done

  printf '%s\t%s\n' "$type" "$port"
}

_gather_project_details() {
  exec 3>&1
  local cur="${1:-{}}"
  local cur_compact="$cur"
  cur_compact="${cur_compact//$'\r'/}"
  cur_compact="${cur_compact//$'\n'/}"
  cur_compact="${cur_compact//$'\t'/}"
  cur_compact="${cur_compact// /}"
  if [ -n "$cur_compact" ] && [ "$cur_compact" != "{}" ] && ! jq -e . >/dev/null 2>&1 <<<"$cur"; then
    log_message WARN "检测到损坏的项目配置 JSON，已回退为默认空配置。"
    cur="{}"
  fi
  local skip_cert="${2:-false}"
  local is_cert_only="false"
  if [ "${3:-}" == "cert_only" ]; then is_cert_only="true"; fi

  local domain
  domain=$(jq -r '.domain // ""' <<<"$cur")
  if [ -z "$domain" ]; then if ! domain=$(prompt_input "主域名" "" "^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "格式无效" "false"); then
    exec 3>&-
    return 1
  fi; fi
  if ! _is_valid_domain "$domain"; then
    log_message ERROR "域名格式无效。"
    exec 3>&-
    return 1
  fi

  local type="cert_only"
  local name="证书"
  local port="cert_only"
  if [ "$is_cert_only" == "false" ]; then
    name=$(jq -r '.name // ""' <<<"$cur")
    local target_pair=""
    if ! target_pair=$(_prompt_backend_target_for_project "$cur" "$name"); then
      exec 3>&-
      return 1
    fi
    local old_ifs="$IFS"
    IFS=$'\t' read -r type port <<<"$target_pair"
    IFS="$old_ifs"
  fi

  if [ "$skip_cert" == "false" ]; then
    if ! _check_dns_resolution "$domain"; then
      printf '%b' "${RED}域名配置已取消。${NC}\n" >&2
      exec 3>&-
      return 1
    fi
  fi

  local wc_pair=""
  local reuse_wc="false"
  local wc_cert=""
  local wc_key=""
  if ! wc_pair=$(_detect_reusable_wildcard_cert "$domain" "$skip_cert"); then
    exec 3>&-
    return 1
  fi
  local old_ifs="$IFS"
  IFS=$'\t' read -r reuse_wc wc_cert wc_key <<<"$wc_pair"
  IFS="$old_ifs"

  local max_body
  local custom_cfg
  max_body=$(jq -r '.client_max_body_size // empty' <<<"$cur")
  custom_cfg=$(jq -r '.custom_config // empty' <<<"$cur")
  local cf_strict
  local reload_cmd
  local mcp_protect_path
  local mcp_token
  cf_strict=$(jq -r '.cf_strict_mode // "n"' <<<"$cur")
  reload_cmd=$(jq -r '.reload_cmd // empty' <<<"$cur")
  mcp_protect_path=$(jq -r '.mcp_protect_path // empty' <<<"$cur")
  mcp_token=$(_resolve_mcp_token_from_json "$cur" "$domain" 2>/dev/null || true)
  CF_STRICT_MODE_CURRENT="$cf_strict"

  local method="http-01"
  local provider=""
  local wildcard="n"
  local ca_server="https://acme-v02.api.letsencrypt.org/directory"
  local ca_name="letsencrypt"
  if [ "$reuse_wc" == "true" ]; then
    method="reuse"
    skip_cert="true"
  fi

  if [ "$skip_cert" == "true" ]; then
    if [ "$reuse_wc" == "false" ]; then
      method=$(jq -r '.acme_validation_method // "http-01"' <<<"$cur")
      provider=$(jq -r '.dns_api_provider // ""' <<<"$cur")
      wildcard=$(jq -r '.use_wildcard // "n"' <<<"$cur")
      ca_server=$(jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"' <<<"$cur")
    fi
  else
    local ca_pair=""
    if ! ca_pair=$(_prompt_ca_selection); then
      exec 3>&-
      return 1
    fi
    local old_ifs="$IFS"
    IFS=$'\t' read -r ca_server ca_name <<<"$ca_pair"
    IFS="$old_ifs"

    local method_pair=""
    if ! method_pair=$(_prompt_validation_method_selection "$domain" "$is_cert_only" "$type" "$port"); then
      exec 3>&-
      return 1
    fi
    local method_delim=$'\x01'
    old_ifs="$IFS"
    IFS="$method_delim" read -r method provider wildcard is_cert_only type port <<<"$method_pair"
    IFS="$old_ifs"
  fi

  if [ "$is_cert_only" == "false" ]; then
    local cf_strict_default="y"
    [ "$cf_strict" == "n" ] && cf_strict_default="n"
    if confirm_or_cancel "是否开启 Cloudflare 严格安全防御?" "$cf_strict_default"; then cf_strict="y"; else cf_strict="n"; fi
    CF_STRICT_MODE_CURRENT="$cf_strict"

    local mcp_pair=""
    if ! mcp_pair=$(_prompt_mcp_protection_settings "$mcp_protect_path" "$mcp_token"); then
      exec 3>&-
      return 1
    fi
    local old_ifs="$IFS"
    IFS=$'\t' read -r mcp_protect_path mcp_token <<<"$mcp_pair"
    IFS="$old_ifs"
  else
    if [ "$skip_cert" == "false" ]; then
      if ! reload_cmd=$(_prompt_reload_hook_for_cert_only); then
        exec 3>&-
        return 1
      fi
    fi
  fi

  local cf="$SSL_CERTS_BASE_DIR/$domain.cer"
  local kf="$SSL_CERTS_BASE_DIR/$domain.key"
  if [ "$reuse_wc" == "true" ]; then
    cf="$wc_cert"
    kf="$wc_key"
  fi

  if ! _build_project_payload_json \
    "${domain:-}" "${type:-local_port}" "${name:-}" "${port:-}" \
    "${method:-http-01}" "${provider:-}" "${wildcard:-n}" \
    "${ca_server:-}" "${ca_name:-}" "${cf:-}" "${kf:-}" \
    "${max_body:-}" "${custom_cfg:-}" "${CF_STRICT_MODE_CURRENT:-$cf_strict}" "${reload_cmd:-}" \
    "${mcp_protect_path:-}" "${mcp_token:-}"; then
    exec 3>&-
    return 1
  fi
  exec 3>&-
}

_display_projects_list() {
  local json="${1:-}"
  if [ -z "$json" ] || [ "$json" == "[]" ]; then
    printf '%b' "暂无数据\n"
    return
  fi
  local w_id=4 w_domain=24 w_target=18 w_status=14 w_renew=12
  local header=""
  header+="$(_center_text "ID" $w_id) "
  header+="$(_center_text "域名" $w_domain) "
  header+="$(_center_text "目标" $w_target) "
  header+="$(_center_text "状态" $w_status) "
  header+="$(_center_text "续期" $w_renew)"
  printf "${BOLD}${CYAN}%s${NC}\n" "$header"
  printf "%${w_id}s " | sed "s/ /─/g"
  printf "%${w_domain}s " | sed "s/ /─/g"
  printf "%${w_target}s " | sed "s/ /─/g"
  printf "%${w_status}s " | sed "s/ /─/g"
  printf "%${w_renew}s\n" | sed "s/ /─/g"

  local idx=0
  jq -r '.[] | [(.domain // "未知"), (.type // ""), (.resolved_port // ""), (.cert_file // ""), (.acme_validation_method // "")] | @tsv' <<<"$json" | while IFS=$'\t' read -r domain type port cert method; do
    idx=$((idx + 1))
    local target_str="Port:$port"
    [ "$type" = "docker" ] && target_str="Docker:$port"
    [ "$port" == "cert_only" ] && target_str="CertOnly"
    local display_target
    display_target=$(printf "%-${w_target}s" "$target_str")
    local renew_date="-"
    if [ "$method" == "reuse" ]; then
      renew_date="跟随主域"
    else
      local conf_file="$HOME/.acme.sh/${domain}_ecc/${domain}.conf"
      [ ! -f "$conf_file" ] && conf_file="$HOME/.acme.sh/${domain}/${domain}.conf"
      if [ -f "$conf_file" ]; then
        local next_ts
        next_ts=$(grep "^Le_NextRenewTime=" "$conf_file" | cut -d= -f2- | tr -d "'\"" || true)
        [ -n "$next_ts" ] && renew_date=$(date -d "@$next_ts" +%F 2>/dev/null || printf '%s' "Err")
      fi
    fi
    local status_text=""
    local color_code="${NC}"
    if [[ ! -f "$cert" ]]; then
      status_text="未安装"
      color_code="${GRAY}"
    else
      local end
      end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
      local end_ts
      end_ts=$(date -d "$end" +%s 2>/dev/null || printf '%s' "0")
      local now_ts
      now_ts=$(date +%s)
      local days=$(((end_ts - now_ts) / 86400))
      if ((days < 0)); then
        status_text="过期 ${days#-}天"
        color_code="${BRIGHT_RED}"
      elif ((days <= 30)); then
        status_text="${days}天续期"
        color_code="${BRIGHT_RED}"
      else
        status_text="正常 ${days}天"
        color_code="${GREEN}"
      fi
    fi
    local line=""
    line+="$(_center_text "$idx" "$w_id") "
    line+="$(_center_text "$domain" "$w_domain") "
    line+="$(_center_text "$display_target" "$w_target") "
    local status_len=${#status_text}
    local s_pad=$((w_status - status_len))
    local s_left=$((s_pad / 2))
    local s_right=$((s_pad - s_left))
    line+="$(printf '%*s' "$s_left" "")${color_code}${status_text}${NC}$(printf '%*s' "$s_right" "") "
    line+="$(_center_text "$renew_date" "$w_renew")"
    printf '%b\n' "$line"
  done
  printf '%b' "\n"
}

select_item_and_act() {
  local list_json="${1:-}" count="${2:-0}" prompt_text="${3:-}" id_field="${4:-}" action_fn="${5:-}" list_render_fn="${6:-}"
  while true; do
    if [ -n "$list_render_fn" ] && declare -f "$list_render_fn" >/dev/null 2>&1; then
      "$list_render_fn" "$list_json"
    fi
    local choice_idx
    if ! choice_idx=$(prompt_input "$prompt_text" "" "^[0-9]*$" "无效序号" "true"); then return 0; fi
    if [ -z "$choice_idx" ] || [ "$choice_idx" == "0" ]; then return 1; fi
    if [ "$choice_idx" -gt "$count" ]; then
      log_message ERROR "序号越界"
      continue
    fi
    local selected_id
    selected_id=$(jq -r ".[$((choice_idx - 1))].${id_field}" <<<"$list_json")
    "$action_fn" "$selected_id"
    local action_ret=$?
    if [ "$action_ret" -eq 2 ]; then return 1; fi
  done
}

_manage_http_actions() {
  local selected_domain="${1:-}"
  _render_menu "管理: $selected_domain" "1. 查看证书详情 (中文诊断)" "2. 手动续期" "3. 删除项目" "4. 查看 Nginx 配置" "5. 重新配置 (目标/防御/Hook等)" "6. 修改证书申请与续期设置" "7. 添加自定义指令" "8. 配置模板中心 (Block追加/Site替换)"
  local cc
  if ! cc=$(prompt_menu_choice "1-8" "true"); then return 0; fi
  case "$cc" in
  1) _handle_cert_details "$selected_domain" ;;
  2) _handle_renew_cert "$selected_domain" ;;
  3)
    _handle_delete_project "$selected_domain"
    return 2
    ;;
  4) _handle_view_config "$selected_domain" ;;
  5) _handle_reconfigure_project "$selected_domain" ;;
  6) _handle_modify_renew_settings "$selected_domain" ;;
  7) _handle_set_custom_config "$selected_domain" ;;
  8) _handle_nginx_template_center_for_domain "$selected_domain" ;;
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
      snapshot_json "$TCP_PROJECTS_METADATA_FILE"
      local temp
      temp=$(mktemp)
      chmod 600 "$temp"
      jq --arg p "$selected_port" 'del(.[] | select(.listen_port == $p))' "$TCP_PROJECTS_METADATA_FILE" >"$temp" && mv "$temp" "$TCP_PROJECTS_METADATA_FILE"
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
    count=$(jq 'length' <<<"$all")
    if [ "$count" -eq 0 ]; then
      log_message WARN "暂无项目。"
      break
    fi
    if ! select_item_and_act "$all" "$count" "请输入序号选择项目 (回车返回)" "domain" _manage_http_actions _display_projects_list; then break; fi
  done
}

_handle_renew_cert() {
  local d="${1:-}"
  local p
  p=$(_get_project_json "$d")
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
  local d="${1:-}"
  local cur
  cur=$(_get_project_json "$d")
  log_message INFO "正在重配 $d ..."
  _generate_op_id
  local port
  local mode=""
  port=$(jq -r .resolved_port <<<"$cur")
  [ "$port" == "cert_only" ] && mode="cert_only"
  local skip_cert="true"
  if confirm_or_cancel "是否连同证书也重新申请/重载?" "n"; then skip_cert="false"; fi
  local new
  if ! new=$(_gather_project_details "$cur" "$skip_cert" "$mode"); then
    log_message WARN "取消。"
    return
  fi
  local old_json="$cur"
  snapshot_project_json "$d" "$old_json"
  if [ "$skip_cert" == "false" ]; then if ! _issue_and_install_certificate "$new"; then
    log_message ERROR "证书申请失败。"
    return 1
  fi; fi
  if _apply_project_transaction "$d" "$new" "$old_json" "$mode"; then
    printf '%b' "重配完成: ${d}\n"
    if [ -n "$LAST_CERT_ELAPSED" ]; then printf '%b' "申请耗时: ${LAST_CERT_ELAPSED}\n"; fi
    if [ -n "$LAST_CERT_CERT" ] && [ -n "$LAST_CERT_KEY" ]; then
      printf '%b' "证书路径: ${LAST_CERT_CERT}\n"
      printf '%b' "私钥路径: ${LAST_CERT_KEY}\n"
    fi
    if [ "$mode" != "cert_only" ]; then
      printf '%b' "网站已上线: https://$(jq -r .domain <<<"$new")\n"
    fi
    printf '%b' "已重载 Nginx。\n"
  else
    printf '%b' "重配失败: ${d}\n"
    printf '%b' "已自动回滚到原配置。\n"
  fi
  press_enter_to_continue
}
_handle_modify_renew_settings() {
  local d="${1:-}"
  local cur
  local current_method
  cur=$(_get_project_json "$d")
  current_method=$(jq -r '.acme_validation_method' <<<"$cur")
  _generate_op_id
  if [ "$current_method" == "reuse" ]; then
    log_message WARN "此项目正在复用泛域名证书,请前往主域名修改续期设置。"
    press_enter_to_continue
    return
  fi
  local -a lines=()
  lines+=("${CYAN}选择新的 CA 机构:${NC}")
  lines+=("1. Let's Encrypt")
  lines+=("2. ZeroSSL")
  lines+=("3. Google Public CA")
  lines+=("4. 保持不变")
  _render_menu "修改证书续期设置: $d" "${lines[@]}"
  local ca_choice
  if ! ca_choice=$(prompt_menu_choice "1-4" "false"); then return; fi
  local ca_server
  local ca_name
  ca_server=$(jq -r '.ca_server_url // "https://acme-v02.api.letsencrypt.org/directory"' <<<"$cur")
  ca_name=$(jq -r '.ca_server_name // "letsencrypt"' <<<"$cur")
  case "$ca_choice" in 1)
    ca_server="https://acme-v02.api.letsencrypt.org/directory"
    ca_name="letsencrypt"
    ;;
  2)
    ca_server="https://acme.zerossl.com/v2/DV90"
    ca_name="zerossl"
    ;;
  3)
    ca_server="google"
    ca_name="google"
    ;;
  esac
  printf '%b' "\n"
  printf '%b' "${CYAN}选择新的验证方式:${NC}\n"
  printf '%b' " 1. http-01 (智能 Webroot)\n"
  printf '%b' " 2. dns_cf (Cloudflare API)\n"
  printf '%b' " 3. dns_ali (阿里云 API)\n"
  printf '%b' " 4. 保持不变\n"
  local v_choice
  if ! v_choice=$(prompt_menu_choice "1-4" "false"); then return; fi
  local method
  local provider
  method=$(jq -r '.acme_validation_method // "http-01"' <<<"$cur")
  provider=$(jq -r '.dns_api_provider // ""' <<<"$cur")
  case "$v_choice" in 1)
    method="http-01"
    provider=""
    ;;
  2)
    method="dns-01"
    provider="dns_cf"
    ;;
  3)
    method="dns-01"
    provider="dns_ali"
    ;;
  esac
  local new_json
  new_json=$(jq --arg cu "$ca_server" --arg cn "$ca_name" --arg m "$method" --arg dp "$provider" '.ca_server_url=$cu | .ca_server_name=$cn | .acme_validation_method=$m | .dns_api_provider=$dp' <<<"$cur")
  if _apply_project_transaction "$d" "$new_json" "$cur" "standard"; then
    printf '%b' "已更新: 证书续期设置 (CA/验证方式)\n"
    printf '%b' "下次续期将自动应用。\n"
  else
    printf '%b' "保存失败: 证书续期设置\n"
    printf '%b' "已回滚到原配置。\n"
  fi
  press_enter_to_continue
}
_handle_set_custom_config() {
  local d="${1:-}"
  local cur
  local current_val
  local mode_choice
  local update_max_body="false"
  cur=$(_get_project_json "$d")
  current_val=$(jq -r '.custom_config // "无"' <<<"$cur")
  _generate_op_id
  printf '%b' "\n${CYAN}当前自定义配置:${NC}\n${current_val}\n"
  _render_menu "常用自定义指令（仅 server 级）" \
    "1. client_max_body_size 10m;       # 调整请求体大小上限（常用于解决 413）" \
    "2. proxy_read_timeout 600s;        # 上游读取超时（长响应场景）" \
    "3. proxy_send_timeout 600s;        # 向上游发送超时" \
    "4. proxy_connect_timeout 60s;      # 连接上游超时" \
    "5. send_timeout 120s;              # 向客户端发送超时" \
    "6. add_header X-Frame-Options \"SAMEORIGIN\" always;  # 基础安全响应头" \
    "7. clear                            # 清空自定义指令" \
    "8. 手动输入"
  if ! mode_choice=$(prompt_menu_choice "1-8" "true"); then return; fi
  if [ -z "$mode_choice" ]; then return; fi
  local new_val=""
  case "$mode_choice" in
  1)
    new_val='10m'
    update_max_body="true"
    ;;
  2) new_val='proxy_read_timeout 600s;' ;;
  3) new_val='proxy_send_timeout 600s;' ;;
  4) new_val='proxy_connect_timeout 60s;' ;;
  5) new_val='send_timeout 120s;' ;;
  6) new_val='add_header X-Frame-Options "SAMEORIGIN" always;' ;;
  7) new_val='clear' ;;
  8)
    printf '%b' "${YELLOW}请输入完整的 Nginx 指令 (需以分号结尾)。回车不修改; 输入 'clear' 清空${NC}\n"
    if ! new_val=$(prompt_input "指令内容" "" "" "" "true"); then return; fi
    ;;
  *)
    log_message ERROR "无效选项"
    return
    ;;
  esac
  if [ -z "$new_val" ]; then return; fi
  local json_val="$new_val"
  local new_json

  if [ "$update_max_body" = "false" ] && [ "$new_val" != "clear" ]; then
    local manual_max_body
    manual_max_body=$(_normalize_max_body_size "$new_val" 2>/dev/null || true)
    if [ -n "$manual_max_body" ]; then
      new_val="$manual_max_body"
      update_max_body="true"
      log_message INFO "检测到 client_max_body_size 指令，已自动改为请求体大小专用字段保存。"
    fi
  fi

  if [ "$update_max_body" = "true" ]; then
    local custom_body_re='^[[:space:]]*client_max_body_size[[:space:]]+.*;[[:space:]]*$'
    local old_custom_cfg
    old_custom_cfg=$(jq -r '.custom_config // empty' <<<"$cur")
    if [ -n "$old_custom_cfg" ]; then
      if ! _is_valid_custom_directive_silent "$old_custom_cfg"; then
        cur=$(jq '.custom_config = ""' <<<"$cur")
        log_message WARN "检测到历史无效 custom_config，已自动清空后继续应用。"
      elif [[ "$old_custom_cfg" =~ $custom_body_re ]]; then
        cur=$(jq '.custom_config = ""' <<<"$cur")
        log_message INFO "已清理 custom_config 中重复的 client_max_body_size 指令。"
      fi
    fi
    cur=$(jq '.custom_config = ""' <<<"$cur")
    new_json=$(jq --arg mb "$new_val" '.client_max_body_size = $mb' <<<"$cur")
  else
    [ "$new_val" == "clear" ] && json_val=""
    if [ "$new_val" != "clear" ] && ! _validate_custom_directive "$new_val"; then
      press_enter_to_continue
      return
    fi
    new_json=$(jq --arg v "$json_val" '.custom_config = $v' <<<"$cur")
  fi
  if _apply_project_transaction "$d" "$new_json" "$cur" "standard"; then
    if [ "$update_max_body" = "true" ]; then
      printf '%b' "已应用: 请求体大小上限 (client_max_body_size ${new_val})\n"
    else
      printf '%b' "已应用: 自定义指令\n"
    fi
    printf '%b' "Nginx 已重载。\n"
  else
    if [ "$update_max_body" = "true" ]; then
      printf '%b' "应用失败: 请求体大小上限设置\n"
    else
      printf '%b' "应用失败: 自定义指令\n"
    fi
    printf '%b' "已回滚配置。\n"
  fi
  press_enter_to_continue
}

_nginx_template_snippet_by_id() {
  tm_nginx_template_snippet_by_id "$@"
}

_template_block_wrap() {
  local template_id="${1:-}"
  local payload="${2:-}"
  local payload_hash=""
  payload_hash=$(_template_payload_hash "$payload")
  cat <<EOF
# NGINX_TEMPLATE_START:${template_id}
# Template: $(_template_id_to_name "$template_id")
# Hash: ${payload_hash}
${payload}
# NGINX_TEMPLATE_END:${template_id}
EOF
}

_extract_template_blocks_by_ids() {
  local content="${1:-}"
  shift || true
  local ids=("$@")
  if [ "${#ids[@]}" -eq 0 ]; then
    printf '%s\n' "$content"
    return 0
  fi

  local patterns_json
  patterns_json=$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)

  jq -r --arg text "$content" --argjson ids "$patterns_json" '
    def remove_block($id):
      ($id | gsub("[][(){}.*+?|^$\\\\-]"; "\\\\\\\\&")) as $esc
      | $text
      | gsub("(?ms)^# NGINX_TEMPLATE_START:" + $esc + "\\n.*?^# NGINX_TEMPLATE_END:" + $esc + "\\n?"; "");
    reduce $ids[] as $id ($text; ($id | gsub("[][(){}.*+?|^$\\\\-]"; "\\\\\\\\&")) as $esc | gsub("(?ms)^# NGINX_TEMPLATE_START:" + $esc + "\\n.*?^# NGINX_TEMPLATE_END:" + $esc + "\\n?"; ""))
  '
}

_extract_all_template_blocks() {
  local content="${1:-}"
  jq -r --arg text "$content" '
    $text
    | gsub("(?ms)^# NGINX_TEMPLATE_START:[^\\n]+\\n.*?^# NGINX_TEMPLATE_END:[^\\n]+\\n?"; "")
  '
}

_template_block_marker_balance_ok() {
  local content="${1:-}"
  local starts=0
  local ends=0
  local line=""
  while IFS= read -r line; do
    case "$line" in
    '# NGINX_TEMPLATE_START:'*) starts=$((starts + 1)) ;;
    '# NGINX_TEMPLATE_END:'*) ends=$((ends + 1)) ;;
    esac
  done <<<"$content"
  [ "$starts" -eq "$ends" ]
}

_count_template_blocks() {
  local content="${1:-}"
  local count=0
  local line=""
  while IFS= read -r line; do
    case "$line" in
    '# NGINX_TEMPLATE_START:'*) count=$((count + 1)) ;;
    esac
  done <<<"$content"
  printf '%s\n' "$count"
}

_count_lines() {
  local content="${1:-}"
  if [ -z "$content" ]; then
    printf '%s\n' "0"
    return 0
  fi
  awk 'END{print NR}' <<<"$content"
}

_print_template_diff_summary() {
  local before="${1:-}"
  local after="${2:-}"
  local before_blocks after_blocks before_lines after_lines
  before_blocks=$(_count_template_blocks "$before")
  after_blocks=$(_count_template_blocks "$after")
  before_lines=$(_count_lines "$before")
  after_lines=$(_count_lines "$after")
  printf '%b' "${CYAN}变更摘要:${NC} 模板块 ${before_blocks} -> ${after_blocks}，行数 ${before_lines} -> ${after_lines}\n"
}

_template_operation_confirm_or_auto() {
  local prompt_text="${1:-确认继续?}"
  local default_yesno="${2:-y}"
  if [ "$TEMPLATE_BATCH_AUTO_CONFIRM" = "true" ]; then
    return 0
  fi
  if [ "$IS_INTERACTIVE_MODE" != "true" ] && [ -n "$TEMPLATE_MODE" ]; then
    log_message INFO "非交互模板模式：自动确认执行。"
    return 0
  fi
  confirm_or_cancel "$prompt_text" "$default_yesno"
}

_template_contains_id() {
  local target="${1:-}"
  shift || true
  local id=""
  for id in "$@"; do
    if [ "$id" = "$target" ]; then
      return 0
    fi
  done
  return 1
}

_dedupe_template_ids() {
  local id=""
  local -a uniq=()
  for id in "$@"; do
    [ -z "$id" ] && continue
    if ! _template_contains_id "$id" "${uniq[@]}"; then
      uniq+=("$id")
    fi
  done
  printf '%s\n' "${uniq[*]}"
}

_parse_template_vars_raw() {
  local raw="${1:-}"
  local token=""
  local key=""
  local val=""
  TEMPLATE_VARS=()
  raw="${raw// /}"
  [ -z "$raw" ] && return 0
  IFS=',' read -r -a parts <<<"$raw"
  for token in "${parts[@]}"; do
    [ -z "$token" ] && continue
    if [[ "$token" != *=* ]]; then
      return 1
    fi
    key="${token%%=*}"
    val="${token#*=}"
    if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      return 1
    fi
    if ! [[ "$val" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      return 1
    fi
    TEMPLATE_VARS["$key"]="$val"
  done
  return 0
}

_validate_template_vars_for_selection() {
  local -a selected=("$@")
  local id=""
  local key=""
  local allowed=""
  local vkey=""
  if [ "${#TEMPLATE_VARS[@]}" -eq 0 ]; then
    return 0
  fi
  for id in "${selected[@]}"; do
    [ -z "$id" ] && continue
    # shellcheck disable=SC2016
    allowed+=" $(_manifest_query --arg id "$id" '.templates[] | select(.id == $id) | (.vars // {} | keys | join(" "))' 2>/dev/null || true)"
  done
  for vkey in "${!TEMPLATE_VARS[@]}"; do
    if [[ " $allowed " != *" $vkey "* ]]; then
      log_message ERROR "模板变量未被当前模板集合声明: ${vkey}"
      return 1
    fi
  done
  for id in "${selected[@]}"; do
    [ -z "$id" ] && continue
    # shellcheck disable=SC2016
    while IFS=$'\t' read -r key pattern; do
      [ -z "$key" ] && continue
      if [ -n "${TEMPLATE_VARS[$key]+x}" ] && [ -n "$pattern" ] && ! [[ "${TEMPLATE_VARS[$key]}" =~ $pattern ]]; then
        log_message ERROR "模板变量校验失败: ${key}=${TEMPLATE_VARS[$key]} 不匹配 ${pattern}"
        return 1
      fi
    done < <(_manifest_query --arg id "$id" '.templates[] | select(.id == $id) | (.vars // {}) | to_entries[]? | [.key, (.value.pattern // "")] | @tsv' 2>/dev/null)
  done
  return 0
}

_json_escape() {
  tm_json_escape "$@"
}

_emit_template_cli_summary() {
  local mode="${1:-}"
  local domain_expr="${2:-}"
  local matched="${3:-0}"
  local ok="${4:-0}"
  local fail="${5:-0}"
  local code="${6:-0}"
  local precheck="${7:-false}"
  if [ "${TEMPLATE_OUTPUT_JSON:-false}" != "true" ]; then
    return 0
  fi
  printf '{"mode":%s,"domain_expr":%s,"matched":%s,"ok":%s,"fail":%s,"precheck":%s,"exit_code":%s}\n' \
    "$(_json_escape "$mode")" \
    "$(_json_escape "$domain_expr")" \
    "$matched" \
    "$ok" \
    "$fail" \
    "$precheck" \
    "$code"
}

_rotate_template_audit_log_if_needed() {
  tm_rotate_template_audit_log_if_needed "$@"
}

_append_template_audit_log() {
  tm_append_template_audit_log "$@"
}

_snapshot_epoch_from_file() {
  local file_name="${1:-}"
  local base=""
  local stamp=""
  base=$(basename "$file_name" .json.bak)
  stamp="${base##*_}"
  if [[ ! "$stamp" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
    return 1
  fi
  date -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null
}

_find_best_snapshot_for_domain() {
  local domain="${1:-}"
  local target_epoch="${2:-0}"
  local file=""
  local best_file=""
  local best_epoch=0
  local ts=0
  local newest_file=""
  local newest_epoch=0
  shopt -s nullglob
  for file in "$JSON_BACKUP_DIR"/project_"$domain"_*.json.bak; do
    ts=$(_snapshot_epoch_from_file "$file" 2>/dev/null || printf '%s' "0")
    if [ "$ts" -gt "$newest_epoch" ]; then
      newest_epoch="$ts"
      newest_file="$file"
    fi
    if [ "$target_epoch" -gt 0 ] && [ "$ts" -le "$target_epoch" ] && [ "$ts" -ge "$best_epoch" ]; then
      best_epoch="$ts"
      best_file="$file"
    fi
  done
  shopt -u nullglob
  if [ -n "$best_file" ]; then
    printf '%s\n' "$best_file"
    return 0
  fi
  if [ -n "$newest_file" ]; then
    printf '%s\n' "$newest_file"
    return 0
  fi
  return 1
}

_template_impact_report() {
  tm_template_impact_report "$@"
}

_rollback_templates_by_op() {
  tm_rollback_templates_by_op "$@"
}

_template_audit_report() {
  tm_template_audit_report
}

_validate_template_selection() {
  local id=""
  local requires=""
  local conflict=""
  local -a selected=("$@")
  local -a missing=()
  local -a conflict_hits=()
  for id in "${selected[@]}"; do
    if [ -z "$id" ]; then
      continue
    fi
    # shellcheck disable=SC2016
    if [ "$(_manifest_query --arg id "$id" '.templates[] | select(.id == $id) | .id // ""' 2>/dev/null || true)" = "" ]; then
      log_message ERROR "模板不存在: ${id}"
      return 1
    fi
    # shellcheck disable=SC2016
    requires=$(_manifest_query --arg id "$id" '.templates[] | select(.id == $id) | (.requires // []) | join(" ")' 2>/dev/null || true)
    for conflict in $requires; do
      if ! _template_contains_id "$conflict" "${selected[@]}"; then
        missing+=("${id}->${conflict}")
      fi
    done
    # shellcheck disable=SC2016
    conflict=$(_manifest_query --arg id "$id" '.templates[] | select(.id == $id) | (.conflicts // []) | join(" ")' 2>/dev/null || true)
    for requires in $conflict; do
      if _template_contains_id "$requires" "${selected[@]}"; then
        conflict_hits+=("${id}<->${requires}")
      fi
    done
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log_message ERROR "模板依赖缺失: ${missing[*]}"
    return 1
  fi
  if [ "${#conflict_hits[@]}" -gt 0 ]; then
    log_message ERROR "模板冲突: ${conflict_hits[*]}"
    return 1
  fi
  if ! _validate_template_vars_for_selection "${selected[@]}"; then
    return 1
  fi
  if ! _check_template_compatibility "${selected[@]}"; then
    return 1
  fi
  return 0
}

_template_payload_hash() {
  local payload="${1:-}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum | awk '{print $1}'
    return 0
  fi
  printf '%s' "$payload" | cksum | awk '{print $1}'
}

_extract_directive_names() {
  local content="${1:-}"
  awk '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "" || line ~ /^#/) next
      sub(/;.*/, "", line)
      split(line, a, /[ \t]+/)
      if (a[1] != "") print a[1]
    }
  ' <<<"$content" | sort -u
}

_count_unique_directives() {
  local content="${1:-}"
  local count=0
  count=$(_extract_directive_names "$content" | awk 'END{print NR+0}')
  printf '%s\n' "$count"
}

_count_changed_directives() {
  local before="${1:-}"
  local after="${2:-}"
  local tmp_before=""
  local tmp_after=""
  local delta=0
  tmp_before=$(mktemp /tmp/tmpl.before.XXXXXX)
  tmp_after=$(mktemp /tmp/tmpl.after.XXXXXX)
  printf '%s\n' "$(_extract_directive_names "$before")" >"$tmp_before"
  printf '%s\n' "$(_extract_directive_names "$after")" >"$tmp_after"
  delta=$(cat "$tmp_before" "$tmp_after" | sed '/^$/d' | sort | uniq -u | awk 'END{print NR+0}')
  rm -f -- "$tmp_before" "$tmp_after" 2>/dev/null || true
  printf '%s\n' "$delta"
}

_emit_template_impact_domain_json() {
  local domain="${1:-}"
  local before_blocks="${2:-0}"
  local after_blocks="${3:-0}"
  local before_dirs="${4:-0}"
  local after_dirs="${5:-0}"
  local changed_dirs="${6:-0}"
  if [ "${TEMPLATE_OUTPUT_JSON:-false}" != "true" ]; then
    return 0
  fi
  printf '{"domain":%s,"before_blocks":%s,"after_blocks":%s,"before_directives":%s,"after_directives":%s,"changed_directives":%s}\n' \
    "$(_json_escape "$domain")" "$before_blocks" "$after_blocks" "$before_dirs" "$after_dirs" "$changed_dirs"
}

_template_id_to_name() {
  tm_template_id_to_name "$@"
}

_ensure_template_manifest_available() {
  local manifest_json=""
  local snippet_rel=""
  local snippet_abs=""
  local schema_file="${NGINX_TEMPLATE_DIR%/}/manifest.schema.json"
  if [ -n "$TEMPLATE_MANIFEST_CACHE" ]; then
    return 0
  fi
  if ! _require_safe_path "$NGINX_TEMPLATE_MANIFEST" "读取模板清单"; then
    return 1
  fi
  if [ ! -f "$NGINX_TEMPLATE_MANIFEST" ]; then
    log_message ERROR "模板清单不存在: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if ! manifest_json=$(cat "$NGINX_TEMPLATE_MANIFEST" 2>/dev/null); then
    log_message ERROR "读取模板清单失败: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if ! jq -e . <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板清单 JSON 非法: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if [ -f "$schema_file" ]; then
    if ! _require_safe_path "$schema_file" "读取模板 Schema"; then
      return 1
    fi
    if ! jq -e . "$schema_file" >/dev/null 2>&1; then
      log_message ERROR "模板 Schema JSON 非法: ${schema_file}"
      return 1
    fi
  fi
  if ! jq -e '
    (.version | type == "number") and
    (.templates | type == "array" and length > 0) and
    (.default_combos | type == "array" and length > 0) and
    (all(.templates[]; has("id") and has("name") and has("snippet_file") and (.id | type == "string") and (.id | test("^[a-z0-9_]+$")))) and
    (all(.templates[]; ((.min_nginx_version // "") | type == "string") and (((.min_nginx_version // "") == "") or ((.min_nginx_version // "") | test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))))) and
    (all(.templates[]; ((.vars // {}) | type == "object"))) and
    (all(.templates[]; ((.vars // {}) | to_entries | all(.[]; (.key | test("^[A-Z][A-Z0-9_]*$")) and (((.value.default // "") | type) == "string") and (((.value.pattern // "") | type) == "string")))) ) and
    (all(.default_combos[]; has("id") and has("name") and (.templates | type == "array" and length > 0)))
  ' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板清单结构校验失败: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  if ! jq -e '([.templates[].id] | length) == ([.templates[].id] | unique | length)' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板清单中存在重复模板 ID"
    return 1
  fi
  if ! jq -e '
    ([.templates[].id] | unique) as $ids
    | all(.default_combos[].templates[]; ($ids | index(.) != null))
  ' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "默认模板组合引用了不存在的模板 ID"
    return 1
  fi
  if ! jq -e '
    ([.templates[].id] | unique) as $ids
    | all(.templates[]; ((.requires // []) + (.conflicts // [])) | all(.[]; ($ids | index(.) != null)))
  ' <<<"$manifest_json" >/dev/null 2>&1; then
    log_message ERROR "模板 requires/conflicts 引用了不存在的模板 ID"
    return 1
  fi
  while IFS= read -r snippet_rel; do
    [ -z "$snippet_rel" ] && continue
    snippet_abs="${NGINX_TEMPLATE_DIR%/}/${snippet_rel}"
    if ! _require_safe_path "$snippet_abs" "读取模板片段"; then
      return 1
    fi
    if [ ! -f "$snippet_abs" ]; then
      log_message ERROR "模板片段不存在: ${snippet_abs}"
      return 1
    fi
  done < <(jq -r '.templates[].snippet_file' <<<"$manifest_json")

  TEMPLATE_MANIFEST_CACHE="$manifest_json"
  return 0
}

_manifest_query() {
  tm_manifest_query "$@"
}

_render_nginx_template_root_menu() {
  local c1 c2 c3 c4 d1 d2 d3 d4
  local -a lines=()
  c1=$(_manifest_query '.default_combos[0].name // "通用反代"' 2>/dev/null || printf '%s' "通用反代")
  c2=$(_manifest_query '.default_combos[1].name // "HTTPS生产"' 2>/dev/null || printf '%s' "HTTPS生产")
  c3=$(_manifest_query '.default_combos[2].name // "WordPress常用"' 2>/dev/null || printf '%s' "WordPress常用")
  c4=$(_manifest_query '.default_combos[3].name // "长连接服务"' 2>/dev/null || printf '%s' "长连接服务")
  d1=$(_manifest_query '.default_combos[0].desc // empty' 2>/dev/null || printf '%s' "")
  d2=$(_manifest_query '.default_combos[1].desc // empty' 2>/dev/null || printf '%s' "")
  d3=$(_manifest_query '.default_combos[2].desc // empty' 2>/dev/null || printf '%s' "")
  d4=$(_manifest_query '.default_combos[3].desc // empty' 2>/dev/null || printf '%s' "")
  lines+=("1. ${c1}")
  [ -n "$d1" ] && lines+=("   ${d1}")
  lines+=("2. ${c2}")
  [ -n "$d2" ] && lines+=("   ${d2}")
  lines+=("3. ${c3}")
  [ -n "$d3" ] && lines+=("   ${d3}")
  lines+=("4. ${c4}")
  [ -n "$d4" ] && lines+=("   ${d4}")
  lines+=("5. 自定义模板（单项，可多选）")
  lines+=("6. 清理模板配置")
  lines+=("7. 批量应用模板（glob域名匹配）")
  lines+=("8. 查看模板状态")
  lines+=("9. 查看模板审计日志")
  lines+=("10. 按模板反查域名")
  lines+=("11. 按操作ID回滚模板变更")
  lines+=("12. 返回")
  _render_menu "配置模板中心" "${lines[@]}"
}

_render_nginx_template_custom_menu() {
  local -a lines=()
  local idx=0
  while IFS=$'\t' read -r id name; do
    [ -z "$id" ] && continue
    idx=$((idx + 1))
    lines+=("${idx}. ${name} (${id})")
  done < <(_manifest_query '.templates[] | select(.single == true) | [.id, .name] | @tsv' 2>/dev/null)
  lines+=("$((idx + 1)). 返回")
  _render_menu "自定义模板（单项，可多选）" "${lines[@]}"
}

_render_nginx_template_cleanup_menu() {
  _render_menu "清理模板配置" \
    "1. 清理指定模板块（可多选）" \
    "2. 清理全部模板块" \
    "3. 返回"
}

_template_combo_by_choice() {
  local choice="${1:-}"
  local idx=$((choice - 1))
  local combo_ids=""
  _ensure_template_manifest_available || return 1
  # shellcheck disable=SC2016
  combo_ids=$(_manifest_query --argjson i "$idx" '.default_combos[$i].templates // [] | join(" ")' 2>/dev/null || true)
  if [ -z "$combo_ids" ] || [ "$combo_ids" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$combo_ids"
}

_parse_custom_template_multi_select() {
  local raw="${1:-}"
  local token=""
  local id=""
  local single_count=0
  local out=()
  raw="${raw// /}"
  [ -z "$raw" ] && return 1
  single_count=$(_manifest_query '[.templates[] | select(.single == true)] | length' 2>/dev/null || printf '%s' "0")
  if [ "$single_count" -le 0 ]; then
    log_message ERROR "模板清单中未定义可用自定义模板。"
    return 1
  fi
  IFS=',' read -r -a parts <<<"$raw"
  for token in "${parts[@]}"; do
    if ! [[ "$token" =~ ^[0-9]+$ ]]; then
      log_message ERROR "自定义模板多选包含无效项: ${token}"
      return 1
    fi
    if [ "$token" -eq $((single_count + 1)) ]; then
      continue
    fi
    if [ "$token" -lt 1 ] || [ "$token" -gt "$single_count" ]; then
      log_message ERROR "自定义模板多选包含越界项: ${token}"
      return 1
    fi
    # shellcheck disable=SC2016
    id=$(_manifest_query --argjson i "$((token - 1))" '[.templates[] | select(.single == true)] | .[$i].id // ""' 2>/dev/null || true)
    [ -z "$id" ] && continue
    if [ -n "$id" ]; then out+=("$id"); fi
  done
  if [ "${#out[@]}" -eq 0 ]; then return 1; fi
  printf '%s\n' "${out[*]}"
}

_ask_template_apply_mode() {
  local mode_choice=""
  _render_menu "模板应用模式" \
    "1. Block追加（推荐，保留已有自定义配置）" \
    "2. Site替换（覆盖 custom_config）" \
    "3. 返回"
  if ! mode_choice=$(prompt_menu_choice "1-3" "true"); then return 1; fi
  case "$mode_choice" in
  1) printf '%s\n' "append" ;;
  2)
    printf '%b' "${YELLOW}警告: Site替换会覆盖当前项目的 custom_config 字段。${NC}\n"
    if ! confirm_or_cancel "确认继续 Site替换?" "n"; then return 1; fi
    printf '%s\n' "replace"
    ;;
  *) return 1 ;;
  esac
}

_apply_templates_to_domain() {
  tm_apply_templates_to_domain "$@"
}

_cleanup_template_blocks_for_domain() {
  tm_cleanup_template_blocks_for_domain "$@"
}

_handle_nginx_template_cleanup_for_domain() {
  local d="${1:-}"
  local clean_choice=""
  local clean_input=""
  local selected_ids=""
  local -a ids=()

  while true; do
    _render_nginx_template_cleanup_menu
    if ! clean_choice=$(prompt_menu_choice "1-3" "true"); then return 0; fi
    case "$clean_choice" in
    1)
      _render_nginx_template_custom_menu
      if ! clean_input=$(prompt_input "请输入要清理的模板序号(可多选,逗号分隔,如 1,3)" "" "^[0-9, ]*$" "输入格式错误" "true"); then
        continue
      fi
      [ -z "${clean_input// /}" ] && continue
      selected_ids=$(_parse_custom_template_multi_select "$clean_input") || {
        log_message ERROR "未选择有效模板。"
        continue
      }
      IFS=' ' read -r -a ids <<<"$selected_ids"
      _cleanup_template_blocks_for_domain "$d" "ids" "${ids[@]}"
      press_enter_to_exit
      ;;
    2)
      _cleanup_template_blocks_for_domain "$d" "all"
      press_enter_to_exit
      ;;
    3 | "") return 0 ;;
    *) log_message ERROR "无效选择" ;;
    esac
  done
}

_extract_template_ids_from_content() {
  local content="${1:-}"
  local line=""
  local id=""
  local -a ids=()
  while IFS= read -r line; do
    case "$line" in
    '# NGINX_TEMPLATE_START:'*)
      id="${line#\# NGINX_TEMPLATE_START:}"
      if [ -n "$id" ] && ! _template_contains_id "$id" "${ids[@]}"; then
        ids+=("$id")
      fi
      ;;
    esac
  done <<<"$content"
  printf '%s\n' "${ids[*]}"
}

_view_template_status_for_all_domains() {
  local all=""
  local domain=""
  local cfg=""
  local ids_text=""
  local -a lines=()
  all=$(jq -r '.[].domain // empty' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)
  if [ -z "$all" ]; then
    log_message WARN "暂无 HTTP 项目。"
    press_enter_to_exit
  fi
  while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    cfg=$(jq -r --arg d "$domain" '.[] | select(.domain == $d) | .custom_config // empty' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)
    ids_text=$(_extract_template_ids_from_content "$cfg")
    [ -z "$ids_text" ] && ids_text="-"
    lines+=("${domain} -> ${ids_text}")
  done <<<"$all"
  _render_menu "模板状态总览" "${lines[@]}"
  press_enter_to_exit
}

_view_template_audit_history() {
  local log_path=""
  local -a lines=()
  log_path=$(_sanitize_log_file "$NGINX_TEMPLATE_AUDIT_LOG" 2>/dev/null || true)
  [ -z "$log_path" ] && log_path="/tmp/nginx_template_audit.log"
  if [ ! -f "$log_path" ]; then
    log_message WARN "模板审计日志不存在: ${log_path}"
    press_enter_to_exit
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lines+=("$line")
  done < <(tail -n 20 "$log_path" 2>/dev/null || true)
  [ "${#lines[@]}" -eq 0 ] && lines+=("日志为空")
  _render_menu "模板审计日志(最近20条)" "${lines[@]}"
  press_enter_to_exit
}

_view_template_domains_by_template() {
  local all=""
  local domain=""
  local cfg=""
  local id=""
  local ids_text=""
  local -a lines=()
  _ensure_template_manifest_available || return 1
  all=$(jq -r '.[].domain // empty' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)
  if [ -z "$all" ]; then
    log_message WARN "暂无 HTTP 项目。"
    press_enter_to_exit
  fi
  while IFS=$'\t' read -r id name; do
    [ -z "$id" ] && continue
    local matched=0
    local -a ds=()
    while IFS= read -r domain; do
      [ -z "$domain" ] && continue
      cfg=$(jq -r --arg d "$domain" '.[] | select(.domain == $d) | .custom_config // empty' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)
      ids_text=$(_extract_template_ids_from_content "$cfg")
      if [[ " $ids_text " == *" $id "* ]]; then
        ds+=("$domain")
        matched=$((matched + 1))
      fi
    done <<<"$all"
    if [ "$matched" -eq 0 ]; then
      lines+=("${name} (${id}) -> -")
    else
      lines+=("${name} (${id}) -> ${ds[*]}")
    fi
  done < <(_manifest_query '.templates[] | [.id, .name] | @tsv' 2>/dev/null)
  _render_menu "按模板反查域名" "${lines[@]}"
  press_enter_to_exit
}

_handle_template_rollback_by_op_interactive() {
  local op_id=""
  if ! op_id=$(prompt_input "请输入要回滚的操作ID(op_id)" "" "^[A-Za-z0-9._:-]+$" "操作ID格式错误" "false"); then
    return 0
  fi
  if ! confirm_or_cancel "确认按操作ID回滚模板变更? (op=${op_id})" "n"; then
    return 0
  fi
  if _rollback_templates_by_op "$op_id"; then
    log_message SUCCESS "按操作ID回滚完成: ${op_id}"
  else
    log_message ERROR "按操作ID回滚失败: ${op_id}"
  fi
  press_enter_to_exit
}

_handle_nginx_template_batch_apply_for_domain_glob() {
  local domain_expr=""
  local source_choice=""
  local combo_choice=""
  local combo_ids=""
  local mode=""
  local custom_input=""
  local domain=""
  local ok=0
  local fail=0
  local -a ids=()
  local -a domains=()

  if ! domain_expr=$(prompt_input "请输入域名匹配表达式(支持 glob, 如 *.api.example.com,!admin.api.example.com)" "" "^[A-Za-z0-9*?.!,-]+$" "表达式格式错误" "false"); then
    return 0
  fi

  _render_menu "批量模板来源" \
    "1. 默认组合模板" \
    "2. 自定义模板(单项多选)" \
    "3. 返回"
  if ! source_choice=$(prompt_menu_choice "1-3" "true"); then return 0; fi
  case "$source_choice" in
  1)
    _render_menu "默认模板组合" \
      "1. $(_manifest_query '.default_combos[0].name // "通用反代"')" \
      "2. $(_manifest_query '.default_combos[1].name // "HTTPS生产"')" \
      "3. $(_manifest_query '.default_combos[2].name // "WordPress常用"')" \
      "4. $(_manifest_query '.default_combos[3].name // "长连接服务"')" \
      "5. 返回"
    if ! combo_choice=$(prompt_menu_choice "1-5" "true"); then return 0; fi
    case "$combo_choice" in
    1 | 2 | 3 | 4)
      combo_ids=$(_template_combo_by_choice "$combo_choice") || return 0
      IFS=' ' read -r -a ids <<<"$combo_ids"
      ;;
    *) return 0 ;;
    esac
    ;;
  2)
    _render_nginx_template_custom_menu
    if ! custom_input=$(prompt_input "请输入模板序号(可多选,逗号分隔,如 1,3)" "" "^[0-9, ]*$" "输入格式错误" "true"); then
      return 0
    fi
    [ -z "${custom_input// /}" ] && return 0
    combo_ids=$(_parse_custom_template_multi_select "$custom_input") || return 0
    IFS=' ' read -r -a ids <<<"$combo_ids"
    ;;
  *) return 0 ;;
  esac

  mode=$(_ask_template_apply_mode) || return 0

  while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    domains+=("$domain")
  done < <(_match_domains_by_glob_expr "$domain_expr" || true)

  if [ "${#domains[@]}" -eq 0 ]; then
    log_message WARN "未匹配到任何域名: ${domain_expr}"
    press_enter_to_exit
  fi

  printf '%b' "匹配到域名(${#domains[@]}): ${domains[*]}\n"
  if ! confirm_or_cancel "确认批量应用模板到以上域名?" "n"; then
    return 0
  fi

  TEMPLATE_BATCH_AUTO_CONFIRM="true"
  for domain in "${domains[@]}"; do
    if _apply_templates_to_domain "$domain" "$mode" "${ids[@]}"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done
  TEMPLATE_BATCH_AUTO_CONFIRM="false"

  log_message INFO "批量模板应用完成: 成功=${ok}, 失败=${fail}"
  press_enter_to_exit
}

_handle_nginx_template_center_for_domain() {
  local d="${1:-}"
  local root_choice=""
  local custom_input=""
  local mode=""
  local combo_ids=""
  local -a ids=()

  if ! _ensure_template_manifest_available; then
    press_enter_to_exit
  fi

  while true; do
    _render_nginx_template_root_menu
    if ! root_choice=$(prompt_menu_choice "1-12" "true"); then return 0; fi
    case "$root_choice" in
    1 | 2 | 3 | 4)
      combo_ids=$(_template_combo_by_choice "$root_choice") || {
        log_message ERROR "默认模板映射失败。"
        continue
      }
      IFS=' ' read -r -a ids <<<"$combo_ids"
      mode=$(_ask_template_apply_mode) || continue
      _apply_templates_to_domain "$d" "$mode" "${ids[@]}"
      press_enter_to_exit
      ;;
    5)
      _render_nginx_template_custom_menu
      if ! custom_input=$(prompt_input "请输入模板序号(可多选,逗号分隔,如 1,3)" "" "^[0-9, ]*$" "输入格式错误" "true"); then
        continue
      fi
      [ -z "${custom_input// /}" ] && continue
      combo_ids=$(_parse_custom_template_multi_select "$custom_input") || {
        log_message ERROR "未选择有效模板。"
        continue
      }
      IFS=' ' read -r -a ids <<<"$combo_ids"
      mode=$(_ask_template_apply_mode) || continue
      _apply_templates_to_domain "$d" "$mode" "${ids[@]}"
      press_enter_to_exit
      ;;
    6)
      _handle_nginx_template_cleanup_for_domain "$d"
      ;;
    7)
      _handle_nginx_template_batch_apply_for_domain_glob
      ;;
    8)
      _view_template_status_for_all_domains
      ;;
    9)
      _view_template_audit_history
      ;;
    10)
      _view_template_domains_by_template
      ;;
    11)
      _handle_template_rollback_by_op_interactive
      ;;
    12 | "") return 0 ;;
    *)
      log_message ERROR "无效模板中心选项"
      continue
      ;;
    esac
  done
}

_manage_nginx_template_center() {
  _generate_op_id
  local all count
  if ! _ensure_template_manifest_available; then
    press_enter_to_exit
  fi
  all=$(jq . "$PROJECTS_METADATA_FILE")
  count=$(jq 'length' <<<"$all")
  if [ "$count" -eq 0 ]; then
    log_message WARN "暂无 HTTP 项目，无法应用模板。"
    press_enter_to_exit
  fi
  select_item_and_act "$all" "$count" "请输入序号选择项目进入模板中心 (回车返回)" "domain" _handle_nginx_template_center_for_domain _display_projects_list || true
}

_template_parallel_execute() {
  tm_template_parallel_execute "$@"
}

_run_template_cli_mode() {
  tm_run_template_cli_mode
}

_set_cf_strict_mode_for_domain() {
  local d="${1:-}"
  local target="${2:-}"
  if [ -z "$d" ] || { [ "$target" != "y" ] && [ "$target" != "n" ]; }; then
    return 1
  fi

  local cur
  cur=$(_get_project_json "$d")
  if [ -z "$cur" ]; then
    log_message ERROR "项目不存在: ${d}"
    return 1
  fi

  local port
  port=$(jq -r '.resolved_port // ""' <<<"$cur")
  if [ "$port" = "cert_only" ]; then
    log_message WARN "项目 ${d} 为 cert_only，已跳过严格防御切换。"
    return 2
  fi

  local current
  current=$(jq -r '.cf_strict_mode // "n"' <<<"$cur")
  if [ "$current" = "$target" ]; then
    return 0
  fi

  local new_json
  new_json=$(jq --arg v "$target" '.cf_strict_mode = $v' <<<"$cur")
  if _apply_project_transaction "$d" "$new_json" "$cur" "standard"; then
    return 0
  fi
  log_message ERROR "保存严格防御状态失败: ${d}"
  return 1
}

_show_cf_strict_status_list() {
  local all
  all=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
  local -a lines=()
  lines+=("${CYAN}项目 Cloudflare 严格防御状态列表:${NC}")
  if [ -z "$all" ]; then
    lines+=("暂无项目")
    _render_menu "Cloudflare 防御项目状态" "${lines[@]}"
    return 0
  fi

  local idx=0
  while read -r p; do
    [ -z "$p" ] && continue
    idx=$((idx + 1))
    local d mode strict strict_zh
    d=$(jq -r '.domain // "-"' <<<"$p")
    mode=$(jq -r '.resolved_port // "-"' <<<"$p")
    strict=$(jq -r '.cf_strict_mode // "n"' <<<"$p")
    strict_zh="关闭"
    [ "$strict" = "y" ] && strict_zh="开启"
    if [ "$mode" = "cert_only" ]; then
      lines+=("${idx}. ${d} | 严格防御: ${strict_zh}(${strict}) | 模式: cert_only(跳过)")
    else
      lines+=("${idx}. ${d} | 严格防御: ${strict_zh}(${strict}) | 目标: ${mode}")
    fi
  done <<<"$all"

  _render_menu "Cloudflare 防御项目状态" "${lines[@]}"
}

_batch_set_cf_strict_mode() {
  local target="${1:-}"
  if [ "$target" != "y" ] && [ "$target" != "n" ]; then
    return 1
  fi
  local action_zh="开启"
  [ "$target" = "n" ] && action_zh="关闭"

  if ! confirm_or_cancel "确认批量${action_zh} Cloudflare 严格防御? (默认跳过 cert_only 项目)" "n"; then
    return 0
  fi

  local all
  all=$(jq -c '.[]' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "")
  if [ -z "$all" ]; then
    log_message WARN "暂无项目可执行批量操作。"
    return 0
  fi

  local success=0 fail=0 skipped=0
  local -a fail_list=()
  local -a skipped_list=()

  while read -r p; do
    [ -z "$p" ] && continue
    local d mode
    d=$(jq -r '.domain // ""' <<<"$p")
    mode=$(jq -r '.resolved_port // ""' <<<"$p")
    [ -z "$d" ] && continue

    if [ "$mode" = "cert_only" ]; then
      skipped=$((skipped + 1))
      skipped_list+=("$d")
      continue
    fi

    if _set_cf_strict_mode_for_domain "$d" "$target"; then
      success=$((success + 1))
    else
      local rc=$?
      if [ "$rc" -eq 2 ]; then
        skipped=$((skipped + 1))
        skipped_list+=("$d")
      else
        fail=$((fail + 1))
        fail_list+=("$d")
      fi
    fi
  done <<<"$all"

  log_message INFO "批量${action_zh}严格防御完成: 成功=${success}, 跳过=${skipped}, 失败=${fail}"
  if [ "${#skipped_list[@]}" -gt 0 ]; then
    log_message WARN "已跳过(cert_only): ${skipped_list[*]}"
  fi
  if [ "${#fail_list[@]}" -gt 0 ]; then
    log_message ERROR "失败项目: ${fail_list[*]}"
  fi
}

_toggle_cf_strict_single() {
  local all count
  all=$(jq . "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' "[]")
  count=$(jq 'length' <<<"$all")
  if [ "$count" -eq 0 ]; then
    log_message WARN "暂无项目。"
    return 0
  fi

  printf '%b' "\n"
  _display_projects_list "$all"

  local choice_idx
  if ! choice_idx=$(prompt_input "请输入序号选择项目 (回车返回)" "" "^[0-9]*$" "无效序号" "true"); then return 0; fi
  if [ -z "$choice_idx" ] || [ "$choice_idx" = "0" ]; then return 0; fi
  if [ "$choice_idx" -gt "$count" ]; then
    log_message ERROR "序号越界"
    return 0
  fi

  local selected_domain
  selected_domain=$(jq -r ".[$((choice_idx - 1))].domain" <<<"$all")
  _handle_toggle_cf_strict "$selected_domain"
}

_manage_cloudflare_defense() {
  _generate_op_id
  while true; do
    _show_cf_strict_status_list
    printf '%b' "\n"
    printf '%b' "1. 更新 Cloudflare 防御 IP 库\n"
    printf '%b' "2. 逐项目切换 Cloudflare 严格防御\n"
    printf '%b' "3. 批量开启 Cloudflare 严格防御 (跳过 cert_only)\n"
    printf '%b' "4. 批量关闭 Cloudflare 严格防御 (跳过 cert_only)\n"
    local auto_status="${RED}关闭${NC}"
    if [ -f "$CF_AUTO_UPDATE_ENABLED_FILE" ]; then auto_status="${GREEN}开启${NC}"; fi
    printf '%b' "5. 自动更新 Cloudflare 防御 IP 库 (每周日 03:15) [当前: ${auto_status}]\n"
    printf '%b' "6. 返回\n"
    local c
    if ! c=$(prompt_menu_choice "1-6" "true"); then return; fi
    case "$c" in
    1)
      _update_cloudflare_ips
      press_enter_to_continue
      ;;
    2) _toggle_cf_strict_single ;;
    3)
      _batch_set_cf_strict_mode "y"
      press_enter_to_continue
      ;;
    4)
      _batch_set_cf_strict_mode "n"
      press_enter_to_continue
      ;;
    5)
      if [ -f "$CF_AUTO_UPDATE_ENABLED_FILE" ]; then
        if confirm_or_cancel "当前已开启自动更新，是否关闭?" "y"; then
          rm -f "$CF_AUTO_UPDATE_ENABLED_FILE" 2>/dev/null || true
          local cron_tmp_off
          cron_tmp_off=$(mktemp /tmp/cron.bak.XXXXXX)
          chmod 600 "$cron_tmp_off"
          crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --cf-ip-update" >"$cron_tmp_off" || true
          crontab "$cron_tmp_off"
          rm -f "$cron_tmp_off"
          log_message INFO "已关闭 Cloudflare IP 库自动更新。"
        fi
      else
        if confirm_or_cancel "是否开启自动更新 Cloudflare 防御 IP 库? (每周日 03:15)" "y"; then
          touch "$CF_AUTO_UPDATE_ENABLED_FILE"
          chmod 600 "$CF_AUTO_UPDATE_ENABLED_FILE" 2>/dev/null || true
          local cron_tmp_on
          cron_tmp_on=$(mktemp /tmp/cron.bak.XXXXXX)
          chmod 600 "$cron_tmp_on"
          crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH --cf-ip-update" >"$cron_tmp_on" || true
          local cron_log_on
          cron_log_on=$(_sanitize_log_file "$LOG_FILE" 2>/dev/null || true)
          if [ -z "$cron_log_on" ]; then cron_log_on="$LOG_FILE_DEFAULT"; fi
          printf '%s\n' "15 3 * * 0 $SCRIPT_PATH --cf-ip-update >> $cron_log_on 2>&1" >>"$cron_tmp_on"
          crontab "$cron_tmp_on"
          rm -f "$cron_tmp_on"
          log_message INFO "已开启 Cloudflare IP 库自动更新。"
        fi
      fi
      press_enter_to_continue
      ;;
    6 | "") return ;;
    *) log_message ERROR "无效选择" ;;
    esac
  done
}

_handle_toggle_cf_strict() {
  local d="${1:-}"
  local cur
  local current
  cur=$(_get_project_json "$d")
  if [ -z "$cur" ]; then
    log_message ERROR "项目不存在: ${d}"
    return
  fi
  local mode
  mode=$(jq -r '.resolved_port // ""' <<<"$cur")
  if [ "$mode" = "cert_only" ]; then
    log_message WARN "该项目为 cert_only，仅证书模式，不适用 Cloudflare 严格防御。"
    press_enter_to_continue
    return
  fi
  current=$(jq -r '.cf_strict_mode // "n"' <<<"$cur")
  local current_label="关闭"
  [ "$current" = "y" ] && current_label="开启"
  printf '%b' "当前 Cloudflare 严格防御状态: ${current_label} (${current})\n"
  local target="y"
  [ "$current" = "y" ] && target="n"
  local label="开启"
  [ "$target" = "n" ] && label="关闭"
  if ! confirm_or_cancel "是否${label} Cloudflare 严格防御? (仅适用于开启 CDN)" "n"; then return; fi
  if _set_cf_strict_mode_for_domain "$d" "$target"; then
    printf '%b' "已${label} Cloudflare 严格防御。\n"
    printf '%b' "配置已重载。\n"
  else
    printf '%b' "操作失败: 严格防御切换失败\n"
    printf '%b' "已尝试自动回滚。\n"
  fi
  press_enter_to_continue
}
_handle_cert_details() {
  local d="${1:-}"
  local cur
  cur=$(_get_project_json "$d")
  local cert="$SSL_CERTS_BASE_DIR/$d.cer"
  _generate_op_id
  local key_path="${SSL_CERTS_BASE_DIR}/${d}.key"
  local method
  method=$(jq -r '.acme_validation_method // ""' <<<"$cur")
  if [ "$method" = "reuse" ]; then
    local primary_domain
    primary_domain=$(jq -r '.domain // ""' <<<"$cur")
    if [ -z "$primary_domain" ] || [ "$primary_domain" = "null" ]; then primary_domain="$d"; fi
    cert=$(jq -r '.cert_file // empty' <<<"$cur")
    key_path=$(jq -r '.key_file // empty' <<<"$cur")
    if [ -z "$cert" ] || [ "$cert" = "null" ]; then cert="$SSL_CERTS_BASE_DIR/$primary_domain.cer"; fi
    if [ -z "$key_path" ] || [ "$key_path" = "null" ]; then key_path="$SSL_CERTS_BASE_DIR/$primary_domain.key"; fi
  fi
  if [ -f "$cert" ]; then
    local -a lines=()
    local issuer
    issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null | sed -n 's/.*O = \([^,]*\).*/\1/p' || printf '%s' "未知")
    local subject
    subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed -n 's/.*CN = \([^,]*\).*/\1/p' || printf '%s' "未知")
    local end_date
    end_date=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    local end_ts
    end_ts=$(date -d "$end_date" +%s 2>/dev/null || printf '%s' "0")
    local days=$(((end_ts - $(date +%s)) / 86400))
    local dns_names
    dns_names=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:\K[^,]+' | xargs | sed 's/ /, /g' || printf '%s' "无")
    local provider
    local method_zh="未知"
    provider=$(jq -r '.dns_api_provider // ""' <<<"$cur")
    case "$method" in "http-01") method_zh="HTTP 网站根目录验证" ;; "dns-01") method_zh="DNS API 验证 (${provider:-未知})" ;; "reuse") method_zh="泛域名智能复用" ;; esac
    lines+=("${BOLD}颁发机构 (CA) :${NC} $issuer")
    lines+=("${BOLD}证书主域名     :${NC} $subject")
    lines+=("${BOLD}包含子域名     :${NC} $dns_names")
    lines+=("${BOLD}证书路径       :${NC} ${cert}")
    lines+=("${BOLD}私钥路径       :${NC} ${key_path}")
    if ((days < 0)); then
      lines+=("${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${RED}(已过期 ${days#-} 天)${NC}")
    elif ((days <= 30)); then
      lines+=("${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${BRIGHT_RED}(剩余 $days 天 - 急需续期)${NC}")
    else lines+=("${BOLD}到期时间       :${NC} $(date -d "$end_date" "+%Y-%m-%d %H:%M:%S") ${GREEN}(剩余 $days 天)${NC}"); fi
    lines+=("${BOLD}配置的验证方式 :${NC} $method_zh")
    _render_menu "证书详细诊断信息: $d" "${lines[@]}"
  else log_message ERROR "证书文件不存在: $cert"; fi
}

# ==============================================================================
# SECTION: 主流程 UI
# ==============================================================================

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    -h | --help)
      print_usage
      return 0
      ;;
    esac
  done

  self_elevate_or_die "$@"
  _generate_op_id
  _resolve_log_file
  _parse_args "$@"
  sanitize_noninteractive_flag
  if [ "${PLAN_MODE:-false}" = "true" ]; then
    trap _plan_flush EXIT
  fi
  if ! validate_args "$@"; then return 1; fi
  if [ "$SHOW_HELP" = "true" ]; then
    print_usage
    return 0
  fi
  if ! acquire_http_lock; then return 1; fi
  if ! check_root; then return 1; fi
  if ! check_os_compatibility; then return 1; fi
  if ! check_dependencies; then
    install_dependencies
  fi

  if [ "${CHECK_ONLY:-false}" = "true" ]; then
    run_diagnostics
    return $?
  fi
  if [ "${PRECHECK_ONLY:-false}" = "true" ]; then
    run_preflight
    return $?
  fi
  if [ "${AUDIT_REPORT:-false}" = "true" ]; then
    run_audit_report
    return $?
  fi
  initialize_environment
  if [ "${TX_RECOVER:-false}" = "true" ]; then
    tx_wal_recover
    return $?
  fi

  if [ "${CF_IP_UPDATE_MODE:-false}" = "true" ]; then
    _update_cloudflare_ips
    return $?
  fi
  if [ "${CRON_MODE:-false}" = "true" ]; then
    check_and_auto_renew_certs
    return $?
  fi
  if [ -n "$TEMPLATE_MODE" ] || [ -n "${TEMPLATE_ROLLBACK_OP:-}" ] || [ "${TEMPLATE_AUDIT_REPORT:-false}" = "true" ]; then
    _run_template_cli_mode
    return $?
  fi
  if [ "${PLAN_MODE:-false}" = "true" ]; then
    log_message ERROR "plan 模式仅支持非交互操作（请结合 --check/--preflight/--cron/--cf-ip-update/模板 CLI）"
    return "${EX_USAGE:-64}"
  fi

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
