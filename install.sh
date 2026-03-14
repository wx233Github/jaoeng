#!/usr/bin/env bash
# =============================================================
# 🚀 VPS 一键安装与管理脚本 (v2.2.1 - 优化终端日志体验)
# =============================================================
# 作者：
# 描述：自引导智能化 VPS 环境一键部署与管理菜单系统
# 版本历史：
#   v2.2.1 - 移除终端输出的时间戳（仅保留在日志文件中），提升视觉整洁度
#   v2.2.0 - 恢复日志持久化与轮转，全面审查防御网络假死及兼容性问题
#   v2.1.1 - 修复空参数导致的 Headless 误触发漏洞
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v2.2.1"
AUTO_UPDATE_STATUS_FILE="/tmp/jb_auto_update.status"
AUTO_UPDATE_PID_FILE="/tmp/jb_auto_update.pid"
AUTO_UPDATE_STATE=""
AUTO_UPDATE_UPDATED_CORE="false"
AUTO_UPDATE_UPDATED_COUNT="0"
AUTO_UPDATE_NOTE=""
AUTO_UPDATE_PID=""
AUTO_UPDATE_STARTED_AT=""
AUTO_UPDATE_LAST_HINT=""
AUTO_UPDATE_LAST_HINT_TS=0
AUTO_UPDATE_NOTIFIER_PID=""
JB_FORCE_REFRESH=0

# --- 严格模式与环境设定 ---
set -euo pipefail
IFS=$'\n\t'
export PATH='/usr/local/bin:/usr/bin:/bin'
export LANG="${LANG:-en_US.UTF_8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# --- 颜色与样式定义 ---
if [ -t 1 ] || [ -t 2 ]; then
  CYAN='\033[0;36m'
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  CYAN=''
  GREEN=''
  RED=''
  YELLOW=''
  NC=''
fi

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"
JB_CLEAR_MODE="off"
EXIT_MESSAGE=""
DRY_RUN="false"
declare -a RUN_ARGS=()

: "${SCRIPT_VERSION}" "${AUTO_UPDATE_UPDATED_CORE}" "${AUTO_UPDATE_NOTE}"

# --- [核心架构]: 智能自引导启动器 ---
INSTALL_DIR="/opt/vps_install_modules"
FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"
CONFIG_PATH="${INSTALL_DIR}/config.json"
UTILS_PATH="${INSTALL_DIR}/utils.sh"
GLOBAL_LOG_FILE="${INSTALL_DIR}/vps_install.log"

REAL_SCRIPT_PATH=""
REAL_SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")

_log_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

_log_prefix() {
  local func="${FUNCNAME[1]:-main}"
  local line="${BASH_LINENO[0]:-0}"
  printf '[%s:%s] ' "$func" "$line"
}

# 启动器专用精简日志 (移除终端时间戳)
echo_info() {
  printf "${CYAN}[启动器]${NC} %s\n" "$1" >&2
}
echo_success() {
  printf "${GREEN}[启动器]${NC} %s\n" "$1" >&2
}
echo_error() {
  printf "${RED}[启动器错误]${NC} %s\n" "$1" >&2
  exit 1
}

starter_ensure_safe_path() {
  local target="$1"
  if [ -z "${target:-}" ] || [ "$target" = "/" ]; then
    return 1
  fi
  if [[ "$target" != /* ]] || [[ "$target" == *".."* ]]; then
    return 1
  fi
  return 0
}

starter_require_safe_path_or_die() {
  local target="$1"
  local reason="${2:-路径校验}"
  if ! starter_ensure_safe_path "$target"; then
    echo_error "路径不安全 (${reason}): ${target}"
  fi
}

starter_validate_noninteractive_flag() {
  case "${JB_NONINTERACTIVE:-false}" in
  true | false) return 0 ;;
  *)
    echo_error "JB_NONINTERACTIVE 值非法: ${JB_NONINTERACTIVE}"
    ;;
  esac
}

starter_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  if sudo -n true 2>/dev/null; then
    sudo -n "$@"
    return $?
  fi
  if [ "${JB_NONINTERACTIVE}" = "true" ]; then
    echo_error "非交互模式下无法获取 sudo 权限"
  fi
  echo_info "需要 sudo 权限，可能会提示输入密码。"
  sudo "$@"
}

parse_dry_run_args() {
  RUN_ARGS=()
  local arg
  for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
      DRY_RUN="true"
      continue
    fi
    RUN_ARGS+=("$arg")
  done
  if [ "$DRY_RUN" = "true" ]; then
    log_warn "已启用 dry-run：破坏性操作仅记录，不实际执行。"
  fi
}

run_destructive_with_sudo() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] sudo $*"
    return 0
  fi
  run_with_sudo "$@"
}

build_exec_env() {
  local safe_path
  local -a envs
  safe_path="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
  envs=(
    "PATH=${safe_path}"
    "HOME=${HOME:-/root}"
    "LANG=${LANG:-C.UTF-8}"
    "LC_ALL=${LC_ALL:-C.UTF-8}"
  )
  if [ -n "${TERM:-}" ]; then envs+=("TERM=${TERM}"); fi
  if [ -n "${FORCE_REFRESH:-}" ]; then envs+=("FORCE_REFRESH=${FORCE_REFRESH}"); fi
  if [ -n "${JB_RESTARTED:-}" ]; then envs+=("JB_RESTARTED=${JB_RESTARTED}"); fi
  envs+=("JB_ENABLE_AUTO_CLEAR=false")
  envs+=("JB_CLEAR_MODE=off")
  if [ -n "${JB_DEBUG:-}" ]; then envs+=("JB_DEBUG=${JB_DEBUG}"); fi
  if [ -n "${JB_DEBUG_MODE:-}" ]; then envs+=("JB_DEBUG_MODE=${JB_DEBUG_MODE}"); fi
  if [ -n "${JB_SUDO_LOG_QUIET:-}" ]; then envs+=("JB_SUDO_LOG_QUIET=${JB_SUDO_LOG_QUIET}"); fi
  if [ -n "${LOG_LEVEL:-}" ]; then envs+=("LOG_LEVEL=${LOG_LEVEL}"); fi
  if [ -n "${LOG_FILE:-}" ]; then envs+=("LOG_FILE=${LOG_FILE}"); fi
  printf '%s\n' "${envs[@]}"
}

exec_script_with_sudo() {
  local script_path="$1"
  shift
  local -a envs
  mapfile -t envs < <(build_exec_env)

  if [ "$(id -u)" -eq 0 ]; then
    exec env -i "${envs[@]}" bash "$script_path" "${@:-}"
  fi
  if sudo -n true 2>/dev/null; then
    exec sudo -n env -i "${envs[@]}" bash "$script_path" "${@:-}"
  fi
  if [ "${JB_NONINTERACTIVE}" = "true" ]; then
    echo_error "非交互模式下无法获取 sudo 权限"
  fi
  echo_info "需要 sudo 权限以继续。"
  exec sudo env -i "${envs[@]}" bash "$script_path" "${@:-}"
}

# 环境预检 (Pre-flight Check)
preflight_check() {
  local arch
  arch=$(uname -m)
  case "$arch" in
  x86_64 | aarch64 | arm64)
    # 支持的架构
    ;;
  *)
    echo_error "不支持的系统架构: ${arch}。本脚本仅支持 x86_64 和 arm64 (aarch64) 系统。"
    ;;
  esac

  if [ ! -f "/etc/os-release" ]; then
    echo_error "无法识别操作系统：缺失 /etc/os-release 文件。"
  fi

  # shellcheck disable=SC1091
  local os_id os_like
  os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
  os_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")

  if [[ "$os_id" =~ ^(debian|ubuntu|centos|almalinux|rocky|fedora)$ ]] || [[ "$os_like" =~ (debian|ubuntu|centos|rhel|fedora) ]]; then
    : # Valid OS
  else
    echo_error "不支持的操作系统: ${os_id} (${os_like})。本脚本仅支持 Debian, Ubuntu, CentOS 及其衍生版本。"
  fi
}

# Fail-Fast: 前置依赖硬检查
check_dependencies() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo_error "缺少核心依赖: ${missing[*]}. 请手动安装后重试。"
  fi
}

if [ "$REAL_SCRIPT_PATH" != "$FINAL_SCRIPT_PATH" ]; then
  starter_validate_noninteractive_flag

  preflight_check

  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    if [ "${JB_NONINTERACTIVE}" = "true" ]; then
      echo_error "非交互模式下禁止自动安装依赖"
    fi
    echo_info "检测到核心依赖缺失，正在尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
      starter_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2 || true
      starter_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq >&2 || true
    elif command -v yum >/dev/null 2>&1; then
      starter_sudo yum install -y curl jq >&2 || true
    fi
    check_dependencies curl jq
    echo_success "核心依赖验证通过。"
  fi

  if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH:-false}" = "true" ]; then
    if [ "${JB_NONINTERACTIVE}" = "true" ]; then
      echo_error "非交互模式下禁止下载/覆盖核心文件"
    fi
    starter_require_safe_path_or_die "$INSTALL_DIR" "安装目录"
    starter_require_safe_path_or_die "$FINAL_SCRIPT_PATH" "主脚本"
    starter_require_safe_path_or_die "$UTILS_PATH" "工具库"
    starter_require_safe_path_or_die "$CONFIG_PATH" "配置文件"
    echo_info "正在执行首次安装或强制刷新..."
    starter_sudo mkdir -p "$INSTALL_DIR"
    BASE_URL="https://raw.githubusercontent.com/wx233Github/vps-kit-mcp/main"

    declare -A core_files=(["主程序"]="install.sh" ["工具库"]="utils.sh" ["配置文件"]="config.json")
    for name in "${!core_files[@]}"; do
      file_path="${core_files[$name]}"
      echo_info "正在下载最新的 ${name} (${file_path})..."
      temp_file="$(mktemp "/tmp/jb_starter_XXXXXX")" || temp_file="/tmp/$(basename "${file_path}").$$"
      # 强化网络请求鲁棒性
      if ! curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then
        echo_error "下载 ${name} 失败，可能是网络问题或被阻断。"
      fi
      sed 's/\r$//' <"$temp_file" >"${temp_file}.unix" || true
      starter_sudo mv "${temp_file}.unix" "${INSTALL_DIR}/${file_path}" 2>/dev/null || starter_sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"
      rm -f "$temp_file" "${temp_file}.unix" 2>/dev/null || true
    done

    starter_require_safe_path_or_die "$FINAL_SCRIPT_PATH" "主脚本权限"
    starter_require_safe_path_or_die "$UTILS_PATH" "工具库权限"
    starter_sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH" 2>/dev/null || true
    echo_info "正在创建/更新快捷指令 'cc'..."
    BIN_DIR="/usr/local/bin"
    starter_require_safe_path_or_die "$BIN_DIR/cc" "快捷指令"
    starter_sudo ln -sfn -- "$FINAL_SCRIPT_PATH" "$BIN_DIR/cc"
    echo_success "安装/更新完成。"
  fi

  printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${NC}" >&2
  if [ "$(id -u)" -eq 0 ]; then
    exec bash "$FINAL_SCRIPT_PATH" "${@:-}"
  fi
  if sudo -n true 2>/dev/null; then
    exec sudo -n -E bash "$FINAL_SCRIPT_PATH" "${@:-}"
  fi
  echo_info "需要 sudo 权限以继续。"
  exec_script_with_sudo "$FINAL_SCRIPT_PATH" "${@:-}"
fi

# --- 主程序依赖加载 ---
if [ -f "$UTILS_PATH" ]; then
  # shellcheck source=/dev/null
  source "$UTILS_PATH"
else
  echo_error "通用工具库 $UTILS_PATH 未找到！系统不完整。"
fi

# --- 日志配置 ---
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE="${LOG_FILE:-$GLOBAL_LOG_FILE}"
JB_DEBUG_MODE="${JB_DEBUG_MODE:-${JB_DEBUG:-false}}"

# --- 临时文件管理与资源清理 ---
TEMP_FILES=()
create_temp_file() {
  local tmpfile
  tmpfile=$(mktemp "/tmp/jb_temp_XXXXXX") || {
    log_err "无法创建临时文件"
    return 1
  }
  TEMP_FILES+=("$tmpfile")
  echo "$tmpfile"
}
cleanup_temp_files() {
  log_debug "正在清理临时文件: ${TEMP_FILES[*]:-none}"
  if [ ${#TEMP_FILES[@]} -gt 0 ]; then
    for f in "${TEMP_FILES[@]:-}"; do [ -f "$f" ] && rm -f "$f"; done
  fi
  TEMP_FILES=()
}

# --- Usage与CLI用法 ---
usage() {
  cat <<EOF >&2
用法: $(basename "$0") [选项] [命令]

选项:
  -h, --help    显示本帮助信息并退出
  -u, --uninstall  一键清理所有脚本（含 Y/n 确认）
  --json        与 status/doctor 搭配输出 JSON

命令:
	status        仅显示当前运行状态与环境摘要（不修改系统）
	doctor        执行环境自检（不修改系统）
  update        强制全面更新所有模块和配置
  uninstall     完全卸载本脚本及其相关组件
  [其他命令]    执行配置在菜单中的快捷操作（忽略大小写匹配）

示例:
	$(basename "$0") update
	$(basename "$0") status --json
	$(basename "$0") doctor
	$(basename "$0") docker
EOF
}

run_doctor_status() {
  local mode="${1:-status}"
  local output_format="${2:-text}"
  local os_id="unknown"
  local os_like="unknown"
  local arch
  local docker_state="missing"
  local nginx_state="missing"
  local jq_state="missing"
  local env_state="n/a"
  local deps_state="n/a"
  local config_state="n/a"
  local utils_state="n/a"
  local doctor_exit=0
  arch="$(uname -m 2>/dev/null || echo unknown)"

  if [ -f /etc/os-release ]; then
    os_id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
    os_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "unknown")
  fi

  if command -v docker >/dev/null 2>&1; then docker_state="present"; fi
  if command -v nginx >/dev/null 2>&1; then nginx_state="present"; fi
  if command -v jq >/dev/null 2>&1; then jq_state="present"; fi

  if [ "$mode" = "doctor" ]; then
    if validate_env >/dev/null 2>&1; then
      env_state="ok"
    else
      env_state="fail"
      doctor_exit=70
    fi
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      deps_state="ok"
    else
      deps_state="fail"
      if [ "$doctor_exit" -eq 0 ]; then doctor_exit=69; fi
    fi
    if [ -f "$CONFIG_PATH" ] && jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
      config_state="ok"
    else
      config_state="fail"
      if [ "$doctor_exit" -eq 0 ]; then doctor_exit=65; fi
    fi
    if [ -f "$UTILS_PATH" ]; then
      utils_state="ok"
    else
      utils_state="fail"
      if [ "$doctor_exit" -eq 0 ]; then doctor_exit=66; fi
    fi
  fi

  if [ "$output_format" = "json" ]; then
    printf '{"mode":"%s","script_version":"%s","install_dir":"%s","config_path":"%s","utils_path":"%s","log_file":"%s","os_id":"%s","os_like":"%s","arch":"%s","user":"%s","uid":%s,"docker":"%s","nginx":"%s","jq":"%s","checks":{"env":"%s","core_dependencies":"%s","config_json":"%s","utils_file":"%s"}}\n' \
      "$mode" "${SCRIPT_VERSION}" "${INSTALL_DIR}" "${CONFIG_PATH}" "${UTILS_PATH}" "${LOG_FILE:-$GLOBAL_LOG_FILE}" "$os_id" "$os_like" "$arch" "$(id -un 2>/dev/null || echo unknown)" "$(id -u 2>/dev/null || echo 0)" "$docker_state" "$nginx_state" "$jq_state" "$env_state" "$deps_state" "$config_state" "$utils_state"
  else
    printf '%s\n' "=== jb ${mode} ==="
    printf 'script_version=%s\n' "${SCRIPT_VERSION}"
    printf 'install_dir=%s\n' "${INSTALL_DIR}"
    printf 'config_path=%s\n' "${CONFIG_PATH}"
    printf 'utils_path=%s\n' "${UTILS_PATH}"
    printf 'log_file=%s\n' "${LOG_FILE:-$GLOBAL_LOG_FILE}"
    printf 'os_id=%s\n' "$os_id"
    printf 'os_like=%s\n' "$os_like"
    printf 'arch=%s\n' "$arch"
    printf 'user=%s\n' "$(id -un 2>/dev/null || echo unknown)"
    printf 'uid=%s\n' "$(id -u 2>/dev/null || echo unknown)"
    printf 'docker=%s\n' "$docker_state"
    printf 'nginx=%s\n' "$nginx_state"
    printf 'jq=%s\n' "$jq_state"
    if [ "$mode" = "doctor" ]; then
      printf '%s\n' "--- checks ---"
      printf 'env=%s\n' "$env_state"
      printf 'core_dependencies=%s\n' "$deps_state"
      printf 'config_json=%s\n' "$config_state"
      printf 'utils_file=%s\n' "$utils_state"
    fi
  fi

  return "$doctor_exit"
}

# --- Logrotate 自动配置 ---
setup_logrotate() {
  local logrotate_conf="/etc/logrotate.d/vps_install_modules"
  local tmp_conf=""
  if [ -d "/etc/logrotate.d" ] && [ ! -f "$logrotate_conf" ]; then
    if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
      log_err "非交互模式下禁止写入 logrotate 配置"
      return 1
    fi
    log_info "首次运行: 正在为脚本日志配置 Logrotate 自动轮转..."
    tmp_conf=$(create_temp_file) || return 1
    cat >"$tmp_conf" <<EOF
${INSTALL_DIR%/}/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF
    run_with_sudo mv -f "$tmp_conf" "$logrotate_conf"
    run_with_sudo chmod 644 "$logrotate_conf"
    log_success "Logrotate 日志轮转配置已生成。"
  fi
}

# --- 变量与核心函数定义 ---
CURRENT_MENU_NAME="MAIN_MENU"

check_sudo_privileges() {
  if [ "$(id -u)" -eq 0 ]; then
    JB_HAS_PASSWORDLESS_SUDO=true
    export JB_HAS_PASSWORDLESS_SUDO
    :
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    JB_HAS_PASSWORDLESS_SUDO=true
    export JB_HAS_PASSWORDLESS_SUDO
    log_info "检测到免密 sudo 权限。"
  else
    JB_HAS_PASSWORDLESS_SUDO=false
    export JB_HAS_PASSWORDLESS_SUDO
    log_warn "未检测到免密 sudo 权限。部分操作可能需要您输入密码。"
  fi
}
run_with_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else
    if [ "${JB_SUDO_LOG_QUIET:-false}" != "true" ]; then log_debug "Executing with sudo: sudo $*"; fi
    if sudo -n true 2>/dev/null; then
      sudo -n "$@"
      return $?
    fi
    log_warn "需要 sudo 权限，可能会提示输入密码。"
    sudo "$@"
  fi
}
export -f run_with_sudo

check_and_install_extra_dependencies() {
  local default_deps="curl ln dirname flock jq sha256sum mktemp sed"
  local deps_raw
  local -a deps
  local -a missing_pkgs
  local -A pkg_apt_map

  deps_raw=$(jq -r '.dependencies.common // empty' "$CONFIG_PATH" 2>/dev/null || true)
  if [ -z "$deps_raw" ] || [ "$deps_raw" = "null" ]; then deps_raw="$default_deps"; fi

  local IFS=$' \t\n'
  read -r -a deps <<<"$deps_raw"

  pkg_apt_map=([curl]=curl [ln]=coreutils [dirname]=coreutils [flock]=util-linux [jq]=jq [sha256sum]=coreutils [mktemp]=coreutils [sed]=sed)
  missing_pkgs=()
  for dep in "${deps[@]:-}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      local pkg="${pkg_apt_map[$dep]:-$dep}"
      missing_pkgs+=("$pkg")
    fi
  done

  if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    local missing_display
    missing_display=$(printf '%s ' "${missing_pkgs[@]}")
    missing_display="${missing_display% }"
    log_warn "缺失附加依赖: ${missing_display}"
    if confirm_action "是否尝试自动安装?"; then
      if command -v apt-get >/dev/null 2>&1; then
        run_with_sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2
        run_with_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_pkgs[@]}" >&2
      elif command -v yum >/dev/null 2>&1; then
        run_with_sudo yum install -y "${missing_pkgs[@]}" >&2
      else
        log_err "不支持的包管理器。请手动安装: ${missing_display}"
        exit 1
      fi
    else
      log_err "用户取消安装，脚本无法继续。"
      exit 1
    fi
  fi
}

run_comprehensive_auto_update() {
  local updated_files=()
  local -A core_files
  core_files=(["install.sh"]="$FINAL_SCRIPT_PATH" ["utils.sh"]="$UTILS_PATH" ["config.json"]="$CONFIG_PATH")
  for file in "${!core_files[@]}"; do
    local local_path="${core_files[$file]}"
    local temp_file
    temp_file=$(create_temp_file)
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${file}?_=$(date +%s)" -o "$temp_file"; then
      log_err "下载 ${file} 失败，跳过。"
      continue
    fi
    if [ "$file" = "config.json" ] && [ -f "$local_path" ]; then
      local merged_file
      merged_file=$(create_temp_file) || return 1
      if merge_config_json "$temp_file" "$local_path" "$merged_file"; then
        temp_file="$merged_file"
      else
        log_warn "配置文件合并失败，已保留本地配置"
        rm -f "$temp_file" "$merged_file" 2>/dev/null || true
        continue
      fi
    fi
    local remote_hash
    remote_hash=$(sed 's/\r$//' <"$temp_file" | sha256sum | awk '{print $1}')
    local local_hash="no_local_file"
    [ -f "$local_path" ] && local_hash=$(sed 's/\r$//' <"$local_path" | sha256sum | awk '{print $1}' || echo "no_local_file")
    if [ "$local_hash" != "$remote_hash" ]; then
      updated_files+=("$file")
      run_with_sudo mv "$temp_file" "$local_path"
      if [[ "$file" == *".sh" ]]; then run_with_sudo chmod +x "$local_path"; fi
    else
      rm -f "$temp_file"
    fi
  done

  local scripts_to_update
  scripts_to_update=$(jq -r '.menus[] | .items[]? | select(.type == "item").action' "$CONFIG_PATH" 2>/dev/null || true)
  if [ -n "${scripts_to_update:-}" ] && [ "$scripts_to_update" != "null" ]; then
    local download_rc=0
    for script_name in $scripts_to_update; do
      if download_module_to_cache "$script_name" "auto"; then
        download_rc=0
      else
        download_rc=$?
      fi
      if [ "$download_rc" -eq 0 ]; then
        updated_files+=("$script_name")
      fi
    done
  fi
  if ! _sync_module_sidecars "nginx.sh"; then
    printf '\n' >&2
    log_warn "Nginx 模块依赖同步失败（不影响使用）"
  fi
  if [ "${#updated_files[@]}" -gt 0 ]; then
    printf '%s\n' "${updated_files[@]}"
  fi
}

_sync_module_sidecars() {
  local module="${1:-}"
  [ -z "$module" ] && return 1
  if ! command -v jq >/dev/null 2>&1; then
    log_warn "缺少 jq，跳过模块依赖同步"
    return 1
  fi
  local download_rc=0
  if download_module_to_cache "$module" "auto"; then
    download_rc=0
  else
    download_rc=$?
  fi
  if [ "$download_rc" -eq 0 ] || [ "$download_rc" -eq 2 ]; then
    return 0
  fi
  return 1
}

merge_config_json() {
  local remote_file="$1"
  local local_file="$2"
  local out_file="$3"
  if ! command -v jq >/dev/null 2>&1; then
    return 1
  fi
  if ! jq -e . "$remote_file" >/dev/null 2>&1; then
    return 1
  fi
  if ! jq -e . "$local_file" >/dev/null 2>&1; then
    return 1
  fi
  jq -s '.[0] * .[1]' "$remote_file" "$local_file" >"$out_file"
}

download_module_to_cache() {
  local script_name="$1"
  local mode="${2:-}"
  local local_file="${INSTALL_DIR}/$script_name"
  local tmp_file
  tmp_file=$(create_temp_file)
  if ! sanitize_module_script "$script_name"; then
    log_err "模块路径非法，拒绝下载: ${script_name}"
    return 1
  fi
  if [ "$mode" != "auto" ]; then log_info "  -> 检查/下载模块: ${script_name}"; fi
  run_with_sudo mkdir -p "$(dirname "$local_file")"
  if ! curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${script_name}?_=$(date +%s)" -o "$tmp_file"; then
    if [ "$mode" != "auto" ]; then log_err "     模块 (${script_name}) 下载失败。"; fi
    return 1
  fi
  local remote_hash
  remote_hash=$(sed 's/\r$//' <"$tmp_file" | sha256sum | awk '{print $1}')
  local local_hash="no_local_file"
  [ -f "$local_file" ] && local_hash=$(sed 's/\r$//' <"$local_file" | sha256sum | awk '{print $1}' || echo "no_local_file")

  if [ "$local_hash" != "$remote_hash" ]; then
    if [ "$mode" != "auto" ]; then log_success "     模块 (${script_name}) 已更新。"; fi
    run_with_sudo mv "$tmp_file" "$local_file"
    run_with_sudo chmod +x "$local_file"
    if ! ensure_module_sidecar_libs "$script_name" "$mode"; then
      return 1
    fi
    return 0
  else
    rm -f "$tmp_file"
    if ! ensure_module_sidecar_libs "$script_name" "$mode"; then
      return 1
    fi
    return 2
  fi
}

ensure_module_sidecar_libs() {
  local script_name="$1"
  local mode="${2:-}"
  local rel=""
  local tmp_file=""
  local local_path=""
  local remote_hash=""
  local local_hash=""
  local -a required=()

  case "$script_name" in
  nginx.sh)
    required=(
      "lib/nginx_core.sh"
      "lib/nginx_env.sh"
      "lib/nginx_store.sh"
      "lib/nginx_render.sh"
      "lib/nginx_flow.sh"
      "lib/template_render.sh"
      "lib/template_manifest.sh"
      "lib/template_audit.sh"
      "lib/template_ops.sh"
      "lib/template_cli.sh"
      "templates/nginx/manifest.json"
      "templates/nginx/manifest.schema.json"
    )
    ;;
  *)
    return 0
    ;;
  esac

  for rel in "${required[@]}"; do
    if ! sanitize_module_script "$rel"; then
      log_err "模块依赖路径非法，拒绝下载: ${rel}"
      return 1
    fi
    local_path="${INSTALL_DIR}/${rel}"
    run_with_sudo mkdir -p "$(dirname "$local_path")"
    tmp_file=$(create_temp_file)
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${rel}?_=$(date +%s)" -o "$tmp_file"; then
      log_err "下载模块依赖失败: ${rel}"
      return 1
    fi
    remote_hash=$(sed 's/\r$//' <"$tmp_file" | sha256sum | awk '{print $1}')
    local_hash="no_local_file"
    [ -f "$local_path" ] && local_hash=$(sed 's/\r$//' <"$local_path" | sha256sum | awk '{print $1}' || echo "no_local_file")
    if [ "$local_hash" != "$remote_hash" ]; then
      run_with_sudo mv "$tmp_file" "$local_path"
      run_with_sudo chmod +x "$local_path"
      if [ "$mode" != "auto" ]; then
        log_info "     已同步模块依赖: ${rel}"
      fi
    else
      rm -f "$tmp_file"
    fi
  done

  if [ "$script_name" = "nginx.sh" ]; then
    local manifest_local="${INSTALL_DIR}/templates/nginx/manifest.json"
    local snippet_rel=""
    if [ -f "$manifest_local" ]; then
      while IFS= read -r snippet_rel; do
        [ -z "$snippet_rel" ] && continue
        rel="templates/nginx/${snippet_rel}"
        if ! sanitize_module_script "$rel"; then
          log_err "模板路径非法，拒绝下载: ${rel}"
          return 1
        fi
        local_path="${INSTALL_DIR}/${rel}"
        run_with_sudo mkdir -p "$(dirname "$local_path")"
        tmp_file=$(create_temp_file)
        if ! curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/${rel}?_=$(date +%s)" -o "$tmp_file"; then
          log_err "下载模板片段失败: ${rel}"
          return 1
        fi
        remote_hash=$(sed 's/\r$//' <"$tmp_file" | sha256sum | awk '{print $1}')
        local_hash="no_local_file"
        [ -f "$local_path" ] && local_hash=$(sed 's/\r$//' <"$local_path" | sha256sum | awk '{print $1}' || echo "no_local_file")
        if [ "$local_hash" != "$remote_hash" ]; then
          run_with_sudo mv "$tmp_file" "$local_path"
          run_with_sudo chmod 644 "$local_path"
          if [ "$mode" != "auto" ]; then
            log_info "     已同步模板片段: ${rel}"
          fi
        else
          rm -f "$tmp_file"
        fi
      done < <(jq -r '.templates[]?.snippet_file // empty' "$manifest_local" 2>/dev/null || true)
    fi
  fi
  return 0
}

uninstall_script() {
  log_warn "警告: 这将从您的系统中彻底移除本脚本及其所有组件！"
  log_warn "  - 安装目录: ${INSTALL_DIR}"
  log_warn "  - 日志文件: ${GLOBAL_LOG_FILE}"
  log_warn "  - 快捷方式: ${BIN_DIR:-/usr/local/bin}/jb, ${BIN_DIR:-/usr/local/bin}/sb"
  local choice
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    log_err "无法访问 /dev/tty，无法执行交互式卸载。"
    exit 1
  fi
  printf "%b" "${RED}确认执行一键清理所有脚本? [Y/n]: ${NC}" >/dev/tty
  read -r choice </dev/tty
  case "${choice:-Y}" in
  Y | y | "")
    log_info "开始卸载..."
    LOG_FILE="/tmp/vps_install_modules_uninstall.log"
    export LOG_FILE
    run_destructive_with_sudo rm -f "${BIN_DIR:-/usr/local/bin}/jb" || true
    run_destructive_with_sudo rm -f "${BIN_DIR:-/usr/local/bin}/sb" || true
    run_destructive_with_sudo rm -f "/etc/logrotate.d/vps_install_modules" || true
    ensure_safe_install_dir "$INSTALL_DIR"
    run_destructive_with_sudo rm -rf "$INSTALL_DIR" || true
    run_destructive_with_sudo rm -f "/tmp/jb.lock" "/tmp/jb_auto_update.status" "/tmp/jb_auto_update.pid" || true
    run_destructive_with_sudo rm -f /tmp/jb_temp_* || true
    log_success "脚本已成功卸载。再见！"
    exit 0
    ;;
  *)
    log_info "卸载操作已取消。"
    ;;
  esac
}

confirm_and_force_update() {
  log_warn "警告: 这将从 GitHub 强制拉取所有最新脚本和配置 config.json。"
  log_warn "您对 config.json 的【所有本地修改都将丢失】！这是一个恢复出厂设置的操作。"
  local choice
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    log_err "无法访问 /dev/tty，无法执行交互式更新。"
    exit 1
  fi
  printf "%b" "${RED}此操作不可逆，请输入 'yes' 确认继续: ${NC}" >/dev/tty
  read -r choice </dev/tty
  if [ "${choice:-}" = "yes" ]; then
    log_info "用户确认：开始强制更新所有组件..."
    flock -u 200 2>/dev/null || true
    trap - EXIT
    local install_script_path
    install_script_path=$(create_temp_file)
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL}/install.sh?_=$(date +%s)" -o "$install_script_path"; then
      log_err "拉取核心脚本失败"
      exit 1
    fi
    FORCE_REFRESH=true JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}" bash "$install_script_path"
    log_success "强制更新完成！脚本将自动重启以应用所有更新..."
    sleep 2
    if [ "$(id -u)" -eq 0 ]; then
      exec bash "$FINAL_SCRIPT_PATH" "${@:-}"
    fi
    if sudo -n true 2>/dev/null; then
      exec sudo -n -E bash "$FINAL_SCRIPT_PATH" "${@:-}"
    fi
    exec_script_with_sudo "$FINAL_SCRIPT_PATH" "${@:-}"
  else
    log_info "用户取消了强制更新。"
  fi
}

run_module() {
  local module_script="$1"
  local module_name="$2"
  local module_path="${INSTALL_DIR}/${module_script}"
  shift 2
  if ! sanitize_module_script "$module_script"; then
    log_err "模块路径非法，已拒绝执行。"
    return 1
  fi
  if [ ! -f "$module_path" ]; then
    log_info "模块首次运行，正在下载..."
    download_module_to_cache "$module_script"
  fi

  local filename_only="${module_script##*/}"
  local key_base="${filename_only%.sh}"
  local module_key="${key_base,,}"

  if command -v jq >/dev/null 2>&1 && jq -e --arg key "$module_key" '.module_configs | has($key)' "$CONFIG_PATH" >/dev/null 2>&1; then
    local module_config_json
    module_config_json=$(jq -r --arg key "$module_key" '.module_configs[$key]' "$CONFIG_PATH")
    local prefix_base="${module_key^^}"

    while IFS= read -r key; do
      if [[ "$key" == "comment_"* ]]; then continue; fi
      local value
      value=$(echo "$module_config_json" | jq -r --arg subkey "$key" '.[$subkey]')
      local upper_key="${key^^}"
      export "${prefix_base}_CONF_${upper_key}"="$value"
    done < <(echo "$module_config_json" | jq -r 'keys[]')
  fi

  set +e
  bash "$module_path" "$@"
  local exit_code=$?
  set -e

  if [ "$exit_code" -eq 0 ]; then
    :
  elif [ "$exit_code" -eq 10 ]; then
    :
  elif [ "$exit_code" -eq 130 ]; then
    :
  else
    log_warn "模块 [${module_name}] 执行出错 (代码: ${exit_code})。"
  fi
  return $exit_code
}

self_elevate_or_die() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    log_err "未安装 sudo，无法自动提权。"
    return 1
  fi

  if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
    if sudo -n true 2>/dev/null; then
      exec sudo -n -E bash "$0" "$@"
    fi
    log_err "非交互模式下无法自动提权（需要免密 sudo）。"
    return 1
  fi

  exec sudo -E bash "$0" "$@"
}

sanitize_module_script() {
  local script_name="$1"
  if [ -z "$script_name" ]; then
    log_err "模块名称为空"
    return 1
  fi
  if [[ "$script_name" == /* ]]; then
    log_err "禁止使用绝对路径模块: ${script_name}"
    return 1
  fi
  if [[ "$script_name" == *".."* ]]; then
    log_err "禁止使用包含 .. 的模块路径: ${script_name}"
    return 1
  fi
  if ! [[ "$script_name" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    log_err "模块路径包含非法字符: ${script_name}"
    return 1
  fi
  return 0
}

validate_autoupdate_flag() {
  case "${JB_ENABLE_AUTO_UPDATE:-true}" in
  true | false) return 0 ;;
  *)
    log_warn "enable_auto_update 值非法: ${JB_ENABLE_AUTO_UPDATE}，已回退为 true"
    JB_ENABLE_AUTO_UPDATE="true"
    return 0
    ;;
  esac
}

validate_noninteractive_flag() {
  case "${JB_NONINTERACTIVE:-false}" in
  true | false) return 0 ;;
  *)
    log_warn "JB_NONINTERACTIVE 值非法: ${JB_NONINTERACTIVE}，已回退为 false"
    JB_NONINTERACTIVE="false"
    return 0
    ;;
  esac
}

get_startup_update_mode() {
  local mode="background"
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_PATH" ]; then
    mode=$(jq -r '.startup_update_mode // empty' "$CONFIG_PATH" 2>/dev/null || true)
  fi
  case "${mode:-}" in
  legacy | background)
    printf '%s' "$mode"
    ;;
  *)
    printf '%s' "background"
    ;;
  esac
}

startup_update_mode_label() {
  local mode="${1:-}"
  case "$mode" in
  background) printf '%s' "后台" ;;
  legacy) printf '%s' "前台" ;;
  *) printf '%s' "未知" ;;
  esac
}

set_startup_update_mode() {
  local mode="${1:-}"
  case "$mode" in
  legacy | background)
    :
    ;;
  *)
    log_warn "startup_update_mode 值非法: ${mode}"
    return 1
    ;;
  esac

  if ! command -v jq >/dev/null 2>&1; then
    log_warn "未安装 jq，无法写入 startup_update_mode"
    return 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    log_warn "配置文件不存在，无法写入 startup_update_mode"
    return 1
  fi
  if ! jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
    log_warn "配置文件格式异常，无法写入 startup_update_mode"
    return 1
  fi

  local tmp_file
  tmp_file=$(create_temp_file) || return 1
  if ! jq --arg mode "$mode" '.startup_update_mode=$mode' "$CONFIG_PATH" >"$tmp_file"; then
    log_warn "写入 startup_update_mode 失败"
    return 1
  fi
  run_with_sudo mv "$tmp_file" "$CONFIG_PATH"
  log_success "启动更新模式已设置为: $(startup_update_mode_label "$mode")"
  return 0
}

toggle_startup_update_mode() {
  local current_mode next_mode
  current_mode=$(get_startup_update_mode)
  if [ "$current_mode" = "legacy" ]; then
    next_mode="background"
  else
    next_mode="legacy"
  fi
  local next_label
  next_label=$(startup_update_mode_label "$next_mode")
  if ! confirm_action "确定切换启动更新模式为 ${next_label} 吗?"; then
    log_info "已取消切换"
    return 1
  fi
  log_info "正在切换启动更新模式: $(startup_update_mode_label "$current_mode") -> ${next_label}"
  set_startup_update_mode "$next_mode"
}

restart_main_script() {
  local -a args=("${@:-}")
  flock -u 200 2>/dev/null || true
  trap - EXIT
  JB_RESTARTED="true"
  export JB_RESTARTED
  if [ "$(id -u)" -eq 0 ]; then
    exec bash "$FINAL_SCRIPT_PATH" "${args[@]:-}"
  fi
  if sudo -n true 2>/dev/null; then
    exec sudo -n -E bash "$FINAL_SCRIPT_PATH" "${args[@]:-}"
  fi
  exec_script_with_sudo "$FINAL_SCRIPT_PATH" "${args[@]:-}"
}

run_startup_update_legacy() {
  log_debug "脚本启动 (${SCRIPT_VERSION})" >&2
  if [ "${JB_RESTARTED:-false}" = "true" ]; then
    log_debug "脚本已由自身重启，跳过初始更新检查。" >&2
    return 0
  fi

  local update_tmp
  update_tmp=$(create_temp_file) || return 1
  run_comprehensive_auto_update "${@:-}" >"$update_tmp" &
  local update_pid=$!
  startup_update_spinner "$update_pid"
  local update_rc=0
  if ! wait "$update_pid"; then
    update_rc=$?
  fi
  local -a updated_files_list=()
  mapfile -t updated_files_list <"$update_tmp"
  if [ ${#updated_files_list[@]} -gt 0 ]; then
    startup_update_done_line
  else
    startup_update_clear_line
  fi
  if [ "$update_rc" -ne 0 ]; then
    log_warn "智能更新检查异常（不影响使用）" >&2
  fi

  local restart_needed=false
  local update_messages=""

  if [ ${#updated_files_list[@]} -gt 0 ]; then
    local file=""
    for file in "${updated_files_list[@]}"; do
      [ -z "$file" ] && continue
      local filename
      filename=$(basename "$file")
      if [ "$filename" = "install.sh" ]; then
        restart_needed=true
        update_messages+="主程序 (install.sh) 已更新\n"
      elif [ "$filename" = "config.json" ]; then
        continue
      else
        update_messages+="${GREEN}${filename}${NC} 已更新\n"
      fi
    done

    if [ -n "$update_messages" ]; then
      log_info "发现以下更新:" >&2
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        log_success "$line" >&2
      done <<<"$(printf '%b' "$update_messages")"
    fi

    if [ "$restart_needed" = true ]; then
      log_success "主程序更新，重启中" >&2
      restart_main_script "${@:-}"
    fi
  fi
}

startup_update_spinner() {
  if [ "${STARTUP_UPDATE_SPINNER:-true}" != "true" ]; then
    printf '\r检查更新 ⠙' >&2
    return 0
  fi
  local pid="${1:-}"
  local -a frames=("⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local idx=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s 检查更新 %s ' "$(_log_prefix)" "${CYAN}[信 息]${NC}" "${frames[$idx]}" >&2
    idx=$(((idx + 1) % ${#frames[@]}))
    sleep 0.08
  done
}

startup_update_done_line() {
  if [ -t 2 ]; then
    printf '\r\033[2K%s%s 更新完成\n' "$(_log_prefix)" "${GREEN}[成 功]${NC}" >&2
  else
    printf '\r%s%s 更新完成\n' "$(_log_prefix)" "${GREEN}[成 功]${NC}" >&2
  fi
}

startup_update_clear_line() {
  if [ -t 2 ]; then
    printf '\r\033[2K' >&2
  else
    printf '\r' >&2
  fi
}

run_startup_update_background() {
  start_auto_update_background "${@:-}"
}

handle_auto_update_core_restart() {
  if [ "${JB_RESTARTED:-false}" = "true" ]; then
    return 0
  fi
  if [ "${AUTO_UPDATE_STATE:-}" = "updated_core" ] || [ "${AUTO_UPDATE_UPDATED_CORE:-false}" = "true" ]; then
    local count="${AUTO_UPDATE_UPDATED_COUNT:-0}"
    clear_auto_update_worker_state
    write_auto_update_status "updated" "$count" "false" "core_restarted"
    AUTO_UPDATE_STATE="updated"
    AUTO_UPDATE_UPDATED_CORE="false"
    log_success "主程序更新，重启中"
    restart_main_script "${@:-}"
  fi
}

clear_auto_update_worker_state() {
  # 清理后台更新进程与状态，避免重复触发重启
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 清理后台更新状态"
    return 0
  fi
  local pid=""
  if [ -f "$AUTO_UPDATE_PID_FILE" ]; then
    pid="$(cat "$AUTO_UPDATE_PID_FILE" 2>/dev/null || true)"
  fi
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  run_destructive_with_sudo rm -f "$AUTO_UPDATE_PID_FILE" "$AUTO_UPDATE_STATUS_FILE" || true
}

run_startup_update_flow() {
  local mode
  mode=$(get_startup_update_mode)
  case "$mode" in
  legacy)
    run_startup_update_legacy "${@:-}"
    ;;
  background | *)
    run_startup_update_background "${@:-}"
    ;;
  esac
}

_get_docker_status() {
  local docker_ok=false compose_ok=false status_str=""
  if systemctl is-active --quiet docker 2>/dev/null; then docker_ok=true; fi
  if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then compose_ok=true; fi
  if $docker_ok && $compose_ok; then printf '%b' "${GREEN}已运行${NC}"; else
    if ! $docker_ok; then status_str+="Docker${RED}未运行${NC} "; fi
    if ! $compose_ok; then status_str+="Compose${RED}未找到${NC}"; fi
    printf '%b' "$status_str"
  fi
}
_get_nginx_status() {
  if systemctl is-active --quiet nginx 2>/dev/null; then
    printf '%b' "${GREEN}已运行${NC}"
  elif pgrep -x nginx >/dev/null 2>&1; then
    printf '%b' "${YELLOW}已运行(非systemd)${NC}"
  else
    printf '%b' "${RED}未运行${NC}"
  fi
}
_get_watchtower_status() {
  if systemctl is-active --quiet docker 2>/dev/null; then
    if run_with_sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qFx 'watchtower' >/dev/null 2>&1; then printf '%b' "${GREEN}已运行${NC}"; else printf '%b' "${YELLOW}未运行${NC}"; fi
  else
    printf '%b' "${RED}Docker未运行${NC}"
  fi
}

ensure_safe_path() {
  local target="$1"
  if [ -z "${target}" ] || [ "${target}" = "/" ]; then
    log_err "拒绝对危险路径执行破坏性操作: '${target}'"
    return 1
  fi
  if [[ "$target" != /* ]] || [[ "$target" == *".."* ]]; then
    log_err "路径必须为绝对路径且不可包含 '..': '${target}'"
    return 1
  fi
  return 0
}

ensure_safe_install_dir() {
  local target="$1"
  ensure_safe_path "$target" || return 1
  case "$target" in
  /opt/vps_install_modules | /opt/vps_install_modules/*)
    return 0
    ;;
  *)
    log_err "INSTALL_DIR 超出允许范围: ${target}"
    return 1
    ;;
  esac
}

ensure_safe_lock_file() {
  local target="$1"
  ensure_safe_path "$target" || return 1
  case "$target" in
  /tmp/*.lock)
    return 0
    ;;
  *)
    log_err "LOCK_FILE 必须位于 /tmp 且以 .lock 结尾: ${target}"
    return 1
    ;;
  esac
}

cleanup_lock_file() {
  local lock_file="${LOCK_FILE:-}"
  if [ -z "$lock_file" ]; then
    return 0
  fi
  if ensure_safe_lock_file "$lock_file" >/dev/null 2>&1; then
    rm -f -- "$lock_file" 2>/dev/null || true
  fi
}

require_safe_path_or_die() {
  local target="$1"
  local reason="$2"
  if ! ensure_safe_path "$target"; then
    log_err "路径不安全 (${reason}): ${target}"
    return 1
  fi
  return 0
}

validate_env() {
  local base_url="${BASE_URL:-}"
  if [ -z "$base_url" ]; then
    log_err "BASE_URL 为空，无法继续"
    return 1
  fi
  case "$base_url" in
  https://raw.githubusercontent.com/wx233Github/vps-kit-mcp/*) ;;
  *)
    log_err "BASE_URL 不在允许白名单: ${base_url}"
    return 1
    ;;
  esac

  if [ -z "${INSTALL_DIR:-}" ]; then
    log_err "INSTALL_DIR 未设置"
    return 1
  fi
  ensure_safe_install_dir "$INSTALL_DIR" || return 1

  if [ -z "${LOCK_FILE:-}" ]; then
    log_warn "LOCK_FILE 未设置，使用默认 /tmp/jb.lock"
    LOCK_FILE="/tmp/jb.lock"
  fi
  ensure_safe_lock_file "$LOCK_FILE" || return 1

  local lock_dir
  lock_dir=$(dirname "$LOCK_FILE")
  if [ ! -d "$lock_dir" ]; then
    run_with_sudo mkdir -p "$lock_dir" 2>/dev/null || true
  fi
  return 0
}

ensure_cli_symlinks() {
  local bin_dir="${BIN_DIR:-/usr/local/bin}"
  require_safe_path_or_die "${bin_dir}/cc" "快捷命令 cc" || return 1
  run_with_sudo mkdir -p "$bin_dir"
  run_with_sudo ln -sfn -- "$FINAL_SCRIPT_PATH" "${bin_dir}/cc"
  return 0
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  log_err "运行出错: exit_code=${exit_code}, line=${line_no}"
  return "$exit_code"
}

write_auto_update_status() {
  local state="${1:-idle}"
  local updated_count="${2:-0}"
  local updated_core="${3:-false}"
  local note="${4:-}"
  local pid="${5:-}"
  local started_at="${6:-}"
  local tmp_file=""

  note="${note//$'\n'/ }"
  tmp_file="$(mktemp /tmp/jb_auto_update.status.XXXXXX)" || return 1
  {
    printf 'state=%s\n' "$state"
    printf 'updated_count=%s\n' "$updated_count"
    printf 'updated_core=%s\n' "$updated_core"
    printf 'note=%s\n' "$note"
    printf 'pid=%s\n' "$pid"
    printf 'started_at=%s\n' "$started_at"
  } >"$tmp_file"
  mv -f "$tmp_file" "$AUTO_UPDATE_STATUS_FILE"
}

refresh_auto_update_state() {
  local prev_state="${AUTO_UPDATE_STATE}"
  local prev_count="${AUTO_UPDATE_UPDATED_COUNT}"
  AUTO_UPDATE_STATE=""
  AUTO_UPDATE_UPDATED_CORE="false"
  AUTO_UPDATE_UPDATED_COUNT="0"
  AUTO_UPDATE_NOTE=""
  AUTO_UPDATE_PID=""
  AUTO_UPDATE_STARTED_AT=""

  if [ ! -f "$AUTO_UPDATE_STATUS_FILE" ]; then
    return 0
  fi

  while IFS='=' read -r key value; do
    case "$key" in
    state) AUTO_UPDATE_STATE="$value" ;;
    updated_count) AUTO_UPDATE_UPDATED_COUNT="$value" ;;
    updated_core) AUTO_UPDATE_UPDATED_CORE="$value" ;;
    note) AUTO_UPDATE_NOTE="$value" ;;
    pid) AUTO_UPDATE_PID="$value" ;;
    started_at) AUTO_UPDATE_STARTED_AT="$value" ;;
    esac
  done <"$AUTO_UPDATE_STATUS_FILE"

  if [ "$AUTO_UPDATE_STATE" = "running" ]; then
    local now elapsed
    now=$(date +%s)
    elapsed=0
    if [[ "$AUTO_UPDATE_STARTED_AT" =~ ^[0-9]+$ ]] && [ "$now" -ge "$AUTO_UPDATE_STARTED_AT" ]; then
      elapsed=$((now - AUTO_UPDATE_STARTED_AT))
    fi

    if [[ "$AUTO_UPDATE_PID" =~ ^[0-9]+$ ]]; then
      if ! kill -0 "$AUTO_UPDATE_PID" 2>/dev/null; then
        write_auto_update_status "error_stale" "0" "false" "worker_gone"
        AUTO_UPDATE_STATE="error_stale"
        AUTO_UPDATE_NOTE="worker_gone"
      elif [ "$elapsed" -gt 300 ]; then
        write_auto_update_status "error_stale" "0" "false" "timeout"
        AUTO_UPDATE_STATE="error_stale"
        AUTO_UPDATE_NOTE="timeout"
        rm -f "$AUTO_UPDATE_PID_FILE" 2>/dev/null || true
      fi
    elif [ "$elapsed" -gt 30 ]; then
      write_auto_update_status "error_stale" "0" "false" "missing_pid"
      AUTO_UPDATE_STATE="error_stale"
      AUTO_UPDATE_NOTE="missing_pid"
    fi
  fi

  if [ "$AUTO_UPDATE_STATE" != "$prev_state" ] || [ "$AUTO_UPDATE_UPDATED_COUNT" != "$prev_count" ]; then
    auto_update_capture_transient_hint "$AUTO_UPDATE_STATE" "$AUTO_UPDATE_UPDATED_COUNT"
  fi
}

auto_update_capture_transient_hint() {
  local state="${1:-}"
  local count="${2:-0}"
  local now
  now=$(date +%s)

  case "$state" in
  updated)
    if [ "$count" -gt 0 ] 2>/dev/null; then
      AUTO_UPDATE_LAST_HINT="${GREEN}✅ 后台已更新 ${count} 项${NC}"
      AUTO_UPDATE_LAST_HINT_TS="$now"
    fi
    ;;
  latest)
    AUTO_UPDATE_LAST_HINT="${GREEN}✅ 后台已最新${NC}"
    AUTO_UPDATE_LAST_HINT_TS="$now"
    ;;
  error_stale | error)
    AUTO_UPDATE_LAST_HINT="${YELLOW}⚠ 后台检查异常${NC}"
    AUTO_UPDATE_LAST_HINT_TS="$now"
    ;;
  esac
}

auto_update_pop_transient_hint() {
  local now
  now=$(date +%s)
  if [ -z "$AUTO_UPDATE_LAST_HINT" ]; then
    return 1
  fi
  if [ "$AUTO_UPDATE_LAST_HINT_TS" -gt 0 ] 2>/dev/null && [ $((now - AUTO_UPDATE_LAST_HINT_TS)) -le 6 ]; then
    printf '%s' "$AUTO_UPDATE_LAST_HINT"
    return 0
  fi
  AUTO_UPDATE_LAST_HINT=""
  AUTO_UPDATE_LAST_HINT_TS=0
  return 1
}

auto_update_status_text_for_state() {
  local state="${1:-unknown}"
  local count="${2:-0}"
  case "$state" in
  latest)
    printf '%b' "${GREEN}✅ 后台：最新${NC}"
    ;;
  updated)
    if [ "$count" -gt 0 ] 2>/dev/null; then
      printf '%b' "${GREEN}✅ 后台：已更新${count}${NC}"
    else
      printf '%b' "${GREEN}✅ 后台：已更新${NC}"
    fi
    ;;
  updated_core)
    printf '%b' "${YELLOW}⚠ 主程序待更新${NC}"
    ;;
  running)
    printf '%b' "${CYAN}⠙ 后台检查中${NC}"
    ;;
  error | error_stale)
    printf '%b' "${YELLOW}⚠ 后台检查异常${NC}"
    ;;
  disabled)
    printf '%b' "${YELLOW}ℹ 后台已关闭${NC}"
    ;;
  *)
    printf '%b' "${CYAN}⠙ 后台检查中${NC}"
    ;;
  esac
}

auto_update_status_line() {
  auto_update_status_text_for_state "${AUTO_UPDATE_STATE:-unknown}" "${AUTO_UPDATE_UPDATED_COUNT:-0}"
}

auto_update_version_line() {
  printf '版本: %b %b' "${SCRIPT_VERSION}" "$(auto_update_status_line)"
}

auto_update_version_line_for_state() {
  local state="${1:-unknown}"
  local count="${2:-0}"
  printf '版本: %b %b' "${SCRIPT_VERSION}" "$(auto_update_status_text_for_state "$state" "$count")"
}

show_log_info() {
  if should_clear_screen "install:log_info"; then clear; fi
  refresh_auto_update_state
  local update_text=""
  update_text="$(auto_update_status_text_for_state "${AUTO_UPDATE_STATE:-unknown}" "${AUTO_UPDATE_UPDATED_COUNT:-0}")"
  log_info "📄 日志信息"
  log_info "- 脚本版本: ${SCRIPT_VERSION}"
  log_info "- 日志文件: ${LOG_FILE:-$GLOBAL_LOG_FILE}"
  if [ -f "${LOG_FILE:-$GLOBAL_LOG_FILE}" ]; then
    log_info "- 日志状态: 存在"
  else
    log_warn "- 日志状态: 不存在"
  fi
  log_info "- 后台更新状态: ${AUTO_UPDATE_STATE:-unknown} (${update_text})"
  if [[ "${AUTO_UPDATE_UPDATED_COUNT:-0}" =~ ^[0-9]+$ ]]; then
    log_info "- 后台更新数量: ${AUTO_UPDATE_UPDATED_COUNT}"
  fi
  return 0
}

start_auto_update_notifier() {
  if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
    return 0
  fi
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    return 0
  fi
  if [ -n "${AUTO_UPDATE_NOTIFIER_PID:-}" ] && kill -0 "$AUTO_UPDATE_NOTIFIER_PID" 2>/dev/null; then
    return 0
  fi

  local main_pid="$$"
  (
    local last_key=""
    while kill -0 "$main_pid" 2>/dev/null; do
      local state=""
      local count="0"
      if [ -f "$AUTO_UPDATE_STATUS_FILE" ]; then
        while IFS='=' read -r key value; do
          case "$key" in
          state) state="$value" ;;
          updated_count) count="$value" ;;
          esac
        done <"$AUTO_UPDATE_STATUS_FILE"
      fi

      local current_key="${state}:${count}"
      if [ "$current_key" != "$last_key" ]; then
        kill -USR1 "$main_pid" 2>/dev/null || true
        last_key="$current_key"
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  AUTO_UPDATE_NOTIFIER_PID="$!"
}

stop_auto_update_notifier() {
  if [[ "${AUTO_UPDATE_NOTIFIER_PID:-}" =~ ^[0-9]+$ ]]; then
    kill "$AUTO_UPDATE_NOTIFIER_PID" 2>/dev/null || true
    wait "$AUTO_UPDATE_NOTIFIER_PID" 2>/dev/null || true
    AUTO_UPDATE_NOTIFIER_PID=""
  fi
}

_can_run_background_update() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  sudo -n true >/dev/null 2>&1
}

start_auto_update_background() {
  if [ "${JB_RESTARTED:-false}" = "true" ] || [ "${JB_ENABLE_AUTO_UPDATE}" != "true" ]; then
    write_auto_update_status "disabled" "0" "false" ""
    return 0
  fi

  if ! _can_run_background_update; then
    write_auto_update_status "disabled" "0" "false" "no_privilege"
    return 0
  fi

  if [ -f "$AUTO_UPDATE_PID_FILE" ]; then
    local old_pid=""
    old_pid="$(cat "$AUTO_UPDATE_PID_FILE" 2>/dev/null || true)"
    if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
      write_auto_update_status "running" "0" "false" ""
      return 0
    fi
  fi

  local started_at
  started_at=$(date +%s)
  write_auto_update_status "running" "0" "false" "" "" "$started_at"

  (
    set +e
    trap 'write_auto_update_status "error" "0" "false" "worker_interrupted" "" ""; rm -f "$AUTO_UPDATE_PID_FILE" 2>/dev/null || true' INT TERM
    local -a updated_files_list=()
    local count=0
    local updated_core=false
    local file=""
    mapfile -t updated_files_list < <(run_comprehensive_auto_update "${@:-}")
    count="${#updated_files_list[@]}"
    if [ "$count" -gt 0 ]; then
      for file in "${updated_files_list[@]}"; do
        if [ "$(basename "$file")" = "install.sh" ]; then
          updated_core=true
          break
        fi
      done
    fi

    if [ "$count" -eq 0 ]; then
      write_auto_update_status "latest" "0" "false" ""
    elif [ "$updated_core" = "true" ]; then
      write_auto_update_status "updated_core" "$count" "true" ""
    else
      write_auto_update_status "updated" "$count" "false" ""
    fi

    rm -f "$AUTO_UPDATE_PID_FILE" 2>/dev/null || true
  ) >/dev/null 2>&1 &

  local bg_pid="$!"
  printf '%s\n' "$bg_pid" >"$AUTO_UPDATE_PID_FILE"
  write_auto_update_status "running" "0" "false" "" "$bg_pid" "$started_at"
}

display_and_process_menu() {
  while true; do
    refresh_auto_update_state
    handle_auto_update_core_restart "${@:-}"
    if should_clear_screen "install:${CURRENT_MENU_NAME}"; then clear; fi
    local menu_json
    menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$CONFIG_PATH" 2>/dev/null || true)
    if [ -z "$menu_json" ] || [ "$menu_json" = "null" ]; then
      log_warn "菜单配置 '$CURRENT_MENU_NAME' 读取失败，回退到主菜单."
      CURRENT_MENU_NAME="MAIN_MENU"
      menu_json=$(jq -r --arg menu "MAIN_MENU" '.menus[$menu]' "$CONFIG_PATH" 2>/dev/null || true)
    fi
    if [ -z "$menu_json" ] || [ "$menu_json" = "null" ]; then
      log_err "致命错误：无法加载任何菜单。"
      exit 1
    fi

    local menu_title
    menu_title=$(jq -r '.title' <<<"$menu_json")
    local -a primary_items=() func_items=()

    while IFS=$'\t' read -r icon name type action; do
      if [[ "$icon" == "NO_ICON" ]]; then icon=""; fi
      if [[ "$icon" =~ ^[[:space:]]*$ ]]; then icon=""; fi
      local item_data="${icon:-}|${name:-}|${type:-}|${action:-}"
      if [[ "$type" == "item" || "$type" == "submenu" ]]; then primary_items+=("$item_data"); elif [[ "$type" == "func" ]]; then func_items+=("$item_data"); fi
    done < <(jq -r '.items[] | [(if (.icon == null or .icon == "") then "NO_ICON" else .icon end), .name // "", .type // "", .action // ""] | @tsv' <<<"$menu_json" 2>/dev/null || true)

    local -a formatted_items_for_render=() first_cols_content=() second_cols_content=()
    local max_first_col_width=0
    local -A status_map=(["docker"]="$(_get_docker_status)" ["nginx"]="$(_get_nginx_status)" ["watchtower"]="$(_get_watchtower_status)")
    local -A status_label_map=(["docker"]="Docker:" ["nginx"]="Nginx:" ["watchtower"]="Watchtower:")

    for item_data in "${primary_items[@]:-}"; do
      IFS='|' read -r icon name type action <<<"$item_data"
      local status_text="" status_key=""
      if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then
        case "${action:-}" in "docker.sh") status_key="docker" ;; "nginx.sh") status_key="nginx" ;; "TOOLS_MENU") status_key="watchtower" ;; esac
      fi
      if [ -n "$status_key" ] && [ -n "${status_map[$status_key]:-}" ]; then status_text="${status_label_map[$status_key]:-} ${status_map[$status_key]:-}"; fi

      local idx="$((${#first_cols_content[@]} + 1))"
      local first_col_display_content
      if [ -n "$icon" ]; then
        first_col_display_content="$(printf "%d. %s %s" "$idx" "$icon" "$name")"
      else
        first_col_display_content="$(printf "%d. %s" "$idx" "$name")"
      fi

      first_cols_content+=("$first_col_display_content")
      second_cols_content+=("$status_text")
      if [ -n "$status_text" ]; then
        local current_visual_width
        current_visual_width=$(_get_visual_width "$first_col_display_content")
        if [ "$current_visual_width" -gt "$max_first_col_width" ]; then max_first_col_width="$current_visual_width"; fi
      fi
    done

    for ((i = 0; i < ${#first_cols_content[@]}; i++)); do
      local first_col="${first_cols_content[i]}"
      local second_col="${second_cols_content[i]:-}"
      if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ] && [ "$i" -eq 3 ] && [ "${#first_cols_content[@]}" -ge 5 ]; then
        local left_item right_item left_width merge_padding
        left_item="$first_col"
        right_item="${first_cols_content[4]}"
        left_width=$(_get_visual_width "$left_item")
        if [ "$max_first_col_width" -gt "$left_width" ]; then
          merge_padding=$((max_first_col_width - left_width + 2))
        else
          merge_padding=2
        fi
        formatted_items_for_render+=("${left_item}$(printf '%*s' "$merge_padding" "")${right_item}")
        i=4
        continue
      fi
      if [ -n "$second_col" ]; then
        local first_col_visual_width
        local padding
        first_col_visual_width=$(_get_visual_width "$first_col")
        padding=$((max_first_col_width - first_col_visual_width))
        formatted_items_for_render+=("${first_col}$(printf '%*s' "$padding" "") ${CYAN}- ${NC}${second_col}")
      else
        formatted_items_for_render+=("${first_col}")
      fi
    done

    local func_letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
    for i in "${!func_items[@]}"; do
      IFS='|' read -r icon name type action <<<"${func_items[i]}"
      if [ -n "$icon" ]; then
        formatted_items_for_render+=("$(printf "%s. %s %s" "${func_letters[i]}" "$icon" "$name")")
      else
        formatted_items_for_render+=("$(printf "%s. %s" "${func_letters[i]}" "$name")")
      fi
    done

    _render_menu "$menu_title" "${formatted_items_for_render[@]:-}"

    local num_choices=${#primary_items[@]}
    local numeric_range_str=""
    if [ "$num_choices" -gt 0 ]; then numeric_range_str="1-$num_choices"; fi

    local func_choices_str=""
    if [ ${#func_items[@]} -gt 0 ]; then
      local temp_func_str=""
      for ((i = 0; i < ${#func_items[@]}; i++)); do temp_func_str+="${func_letters[i]},"; done
      func_choices_str="${temp_func_str%,}"
    fi
    local choice
    choice=$(_prompt_for_menu_choice "$numeric_range_str" "$func_choices_str")
    if [ "${JB_FORCE_REFRESH:-0}" = "1" ]; then
      JB_FORCE_REFRESH=0
      continue
    fi

    if [ "$choice" = "__JB_REFRESH__" ]; then
      continue
    fi

    if [ -z "${choice:-}" ]; then
      if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then
        EXIT_MESSAGE="已退出"
        exit 10
      else
        CURRENT_MENU_NAME="MAIN_MENU"
        continue
      fi
    fi

    local item_json=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$num_choices" ]; then
      item_json=$(jq -r --argjson idx "$((choice - 1))" '.items | map(select(.type == "item" or .type == "submenu")) | .[$idx]' <<<"$menu_json")
    else
      for ((i = 0; i < ${#func_items[@]}; i++)); do
        if [ "$choice" = "${func_letters[i]}" ]; then
          item_json=$(jq -r --argjson idx "$i" '.items | map(select(.type == "func")) | .[$idx]' <<<"$menu_json")
          break
        fi
      done
    fi

    if [ -z "${item_json:-}" ] || [ "$item_json" = "null" ]; then
      log_warn "无效选项。"
      sleep 1
      continue
    fi

    local type name action exit_code=0
    type=$(jq -r .type <<<"$item_json")
    name=$(jq -r .name <<<"$item_json")
    action=$(jq -r .action <<<"$item_json")

    case "$type" in
    item) run_module "$action" "$name" || exit_code=$? ;;
    submenu) CURRENT_MENU_NAME="$action" ;;
    func)
      "$action" "${@:-}"
      exit_code=$?
      ;;
    esac

    if [ "$type" = "item" ] && { [ "$exit_code" -eq 10 ] || [ "$exit_code" -eq 130 ]; }; then
      EXIT_MESSAGE="已退出"
      exit 0
    fi

    if [ "$type" != "submenu" ] && [ "$exit_code" -ne 10 ] && [ "$exit_code" -ne 130 ]; then press_enter_to_continue; fi
  done
}

main() {
  self_elevate_or_die "$@"
  parse_dry_run_args "$@"
  set -- "${RUN_ARGS[@]}"
  load_config "$CONFIG_PATH"
  export JB_CLEAR_MODE="off"
  export JB_ENABLE_AUTO_CLEAR=false
  LOG_FILE="${LOG_FILE:-$GLOBAL_LOG_FILE}"
  LOG_LEVEL="${LOG_LEVEL:-INFO}"
  JB_DEBUG_MODE="${JB_DEBUG_MODE:-${JB_DEBUG:-false}}"
  validate_env
  ensure_cli_symlinks
  validate_autoupdate_flag
  validate_noninteractive_flag
  setup_logrotate
  check_and_install_extra_dependencies

  # 显式设置 trap，强化对中止信号和退出的兜底
  trap 'on_error "$?" "$LINENO"' ERR
  trap 'JB_FORCE_REFRESH=1' USR1
  trap 'exit_code=$?; stop_auto_update_notifier; cleanup_temp_files; flock -u 200 2>/dev/null || true; cleanup_lock_file; if [ -n "${EXIT_MESSAGE:-}" ]; then log_info "${EXIT_MESSAGE}"; elif [ "$exit_code" -ne 0 ]; then log_info "脚本已退出 (代码: ${exit_code})"; fi' EXIT INT TERM

  exec 200>"${LOCK_FILE}"
  if ! flock -n 200; then
    log_err "脚本已在运行。"
    exit 1
  fi

  # 防护级别的 Headless 命令读取，规避空值引发全量匹配
  if [ $# -gt 0 ]; then
    local command="${1:-}"
    if [ -n "$command" ]; then
      shift
      case "$command" in
      -h | --help)
        usage
        exit 0
        ;;
      -u | --uninstall)
        log_info "正在以 Headless 模式执行卸载..."
        uninstall_script
        exit 0
        ;;
      status)
        if [ "${1:-}" = "--json" ]; then
          shift
          run_doctor_status "status" "json"
        else run_doctor_status "status" "text"; fi
        exit 0
        ;;
      doctor)
        if [ "${1:-}" = "--json" ]; then
          shift
          run_doctor_status "doctor" "json"
        else run_doctor_status "doctor" "text"; fi
        exit $?
        ;;
      update)
        log_info "正在以 Headless 模式更新所有脚本..."
        run_comprehensive_auto_update "${@:-}"
        exit 0
        ;;
      uninstall)
        log_info "正在以 Headless 模式执行卸载..."
        uninstall_script
        exit 0
        ;;
      *)
        local cmd_lower
        local cmd_with_sh
        local action_to_run
        cmd_lower=$(printf '%s' "$command" | tr '[:upper:]' '[:lower:]')
        cmd_with_sh="${cmd_lower}.sh"
        action_to_run=$(jq -r --arg cmd "$cmd_lower" --arg cmdsh "$cmd_with_sh" '.menus[] | .items[]? | select((.action // "" | ascii_downcase) == $cmd or (.action // "" | ascii_downcase) == $cmdsh or (.name // "" | ascii_downcase) == $cmd) | .action' "$CONFIG_PATH" 2>/dev/null | head -n 1 || true)
        if [ -n "${action_to_run:-}" ] && [ "$action_to_run" != "null" ]; then
          local display_name
          display_name=$(jq -r --arg act "$action_to_run" '.menus[] | .items[]? | select(.action == $act) | .name' "$CONFIG_PATH" 2>/dev/null | head -n 1 || echo "Unknown")
          log_info "正在以 Headless 模式执行: ${display_name}"
          run_module "$action_to_run" "$display_name" "${@:-}"
          exit $?
        else
          log_err "未知命令: $command"
          usage
          exit 1
        fi
        ;;
      esac
    else
      shift
    fi
  fi

  :

  run_startup_update_flow "${@:-}"

  check_sudo_privileges
  display_and_process_menu "${@:-}"
}

main "${@:-}"
