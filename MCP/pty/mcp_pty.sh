#!/usr/bin/env bash
# VERSION: 1.3.1
# DESCRIPTION: MCP PTY 本地部署脚本（可选关联 opencode 配置）
# DEPENDENCIES: bash curl cp mktemp mv chmod mkdir dirname flock date（jq: --with-opencode 时必需）

set -euo pipefail
IFS=$'\n\t'
export PATH='/usr/local/bin:/usr/bin:/bin'

readonly VERSION="1.3.1"
readonly DESCRIPTION="MCP PTY 本地部署脚本（可选关联 opencode 配置）"
readonly DEPENDENCIES="bash curl cp mktemp mv chmod mkdir dirname flock date (jq optional)"

readonly EX_USAGE=64
readonly EX_DATAERR=65
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_OSERR=71
readonly EX_CANTCREAT=73
readonly EX_IOERR=74

readonly UV_INSTALL_SCRIPT_URL="https://astral.sh/uv/install.sh"
readonly DEFAULT_REMOTE_RAW_BASE="https://raw.githubusercontent.com/wx233Github/vps-kit-mcp/main/MCP/pty"
readonly DEFAULT_LOCK_FILE="/tmp/mcp_pty_setup.lock"

WITH_OPENCODE="false"
DRY_RUN="false"
MODE=""
REMOTE_RAW_BASE="${DEFAULT_REMOTE_RAW_BASE}"
LOCAL_BASE_DIR="${HOME:-/root}/mcp/mcp-pty"
LOCK_FILE="${DEFAULT_LOCK_FILE}"
OPENCODE_CONFIG_PATH="${HOME:-/root}/.config/opencode/opencode.json"
OPENCODE_INSTRUCTIONS_PATH="${HOME:-/root}/.config/opencode/instructions/pty.md"
SERVER_LOCAL_PATH=""
UV_BIN=""
OPENCODE_BIN=""
declare -a TEMP_FILES=()

_now() {
  date '+%Y-%m-%d %H:%M:%S'
}

_log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(_now)" "$level" "$*" >&2
}

log_info() {
  _log "INFO" "$*"
}

log_warn() {
  _log "WARN" "$*"
}

log_error() {
  _log "ERROR" "$*"
}

die() {
  local msg="${1:-未知错误}"
  local code="${2:-$EX_SOFTWARE}"
  log_error "$msg"
  exit "$code"
}

usage() {
  cat <<'EOF'
用法:
  mcp_pty.sh [选项]

说明:
  单脚本支持三种用途：
  1) install  : 本地搭建（默认）
  2) opencode : 本地搭建 + 关联 opencode 配置
  3) uninstall: 卸载 mcp_pty 相关本地文件与 opencode 关联

选项:
  --mode <install|opencode|uninstall>
                                  指定运行模式
  --with-opencode                 启用 opencode 配置与 instructions 关联
  --uninstall                     卸载模式（仅清理 mcp_pty 相关内容，不卸载 uv）
  --remote-raw-base <url>         远端 raw 基地址 (默认: GitHub MCP/pty)
  --local-dir <path>              本地目录 (默认: ~/mcp/mcp-pty)
  --opencode-config <path>        opencode.json 路径 (默认: ~/.config/opencode/opencode.json)
  --opencode-instruction-path <path>
                                  pty.md 本地路径 (默认: ~/.config/opencode/instructions/pty.md)
  --dry-run                       干跑模式，仅打印将执行动作
  -h, --help                      显示帮助

示例:
  mcp_pty.sh
  mcp_pty.sh --mode opencode
  mcp_pty.sh --mode uninstall
  mcp_pty.sh --with-opencode
  mcp_pty.sh --uninstall --dry-run
EOF
}

cleanup() {
  local tmp_file=""
  for tmp_file in "${TEMP_FILES[@]:-}"; do
    if [ -n "$tmp_file" ] && [ -f "$tmp_file" ]; then
      rm -f -- "$tmp_file" 2>/dev/null || true
    fi
  done
  flock -u 200 2>/dev/null || true
}

on_interrupt() {
  die "收到中断信号，操作已停止" 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

register_tmp_file() {
  TEMP_FILES+=("$1")
}

expand_home_path() {
  local raw_path="$1"
  if [[ "$raw_path" == ~/* ]]; then
    printf '%s\n' "${HOME:-/root}/${raw_path#~/}"
    return 0
  fi
  printf '%s\n' "$raw_path"
}

validate_lock_file() {
  if [[ "$LOCK_FILE" != /tmp/*.lock ]]; then
    die "锁文件路径非法，必须是 /tmp/*.lock: ${LOCK_FILE}" "$EX_DATAERR"
  fi
}

validate_remote_raw_base() {
  if [ -z "$REMOTE_RAW_BASE" ]; then
    die "--remote-raw-base 不能为空" "$EX_USAGE"
  fi
  if [[ "$REMOTE_RAW_BASE" != https://* ]]; then
    die "--remote-raw-base 必须为 https URL" "$EX_DATAERR"
  fi
  if [[ "$REMOTE_RAW_BASE" =~ [[:space:]] ]]; then
    die "--remote-raw-base 不允许包含空白字符" "$EX_DATAERR"
  fi
}

check_core_dependencies() {
  local missing=()
  local cmd=""
  local -a required=(bash curl cp mktemp mv chmod mkdir dirname flock date)
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "缺少核心依赖: ${missing[*]}" "$EX_UNAVAILABLE"
  fi
}

check_optional_dependencies() {
  if [ "$MODE" != "install" ] && ! command -v jq >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "true" ]; then
      log_warn "dry-run 模式：未检测到 jq，跳过 opencode JSON 写入校验。"
      return 0
    fi
    die "模式 ${MODE} 需要 jq 支持" "$EX_UNAVAILABLE"
  fi

  if [ "$MODE" = "opencode" ]; then
    if ! resolve_opencode_bin; then
      log_warn "未检测到 opencode 命令（已检查 PATH、~/.opencode-i18n/bin、~/.local/bin），可在安装后手动执行 opencode mcp list 验证。"
    else
      log_info "已检测到 opencode: ${OPENCODE_BIN}"
    fi
  fi
}

is_mode_valid() {
  case "$1" in
  install | opencode | uninstall)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

format_command_for_log() {
  local arg=""
  local output=""
  for arg in "$@"; do
    output+="$(printf '%q ' "$arg")"
  done
  printf '%s\n' "${output% }"
}

to_opencode_home_var_path() {
  local raw_path="$1"
  local home_dir="${HOME:-}"

  if [ -n "$home_dir" ] && [[ "$raw_path" == "$home_dir"/* ]]; then
    printf '{env:HOME}/%s\n' "${raw_path#"$home_dir"/}"
    return 0
  fi

  printf '%s\n' "$raw_path"
}

to_shell_home_expr_path() {
  local raw_path="$1"
  local home_dir="${HOME:-}"

  if [ -n "$home_dir" ] && [[ "$raw_path" == "$home_dir"/* ]]; then
    printf '%s\n' "\${HOME}/${raw_path#"$home_dir"/}"
    return 0
  fi

  printf '%s\n' "$raw_path"
}

run_mutating() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] $(format_command_for_log "$@")"
    return 0
  fi
  "$@"
}

ensure_parent_dir() {
  local file_path="$1"
  local parent_dir=""
  parent_dir="$(dirname "$file_path")"
  if [ -z "$parent_dir" ]; then
    die "无法解析父目录: ${file_path}" "$EX_DATAERR"
  fi
  run_mutating mkdir -p "$parent_dir"
}

build_raw_url() {
  local file_name="$1"
  if [ -z "$file_name" ]; then
    die "build_raw_url: file_name 不能为空" "$EX_USAGE"
  fi
  printf '%s/%s?_=%s\n' "${REMOTE_RAW_BASE%/}" "$file_name" "$(date +%s)"
}

download_to_file() {
  local url="$1"
  local target_path="$2"
  local chmod_mode="${3:-}"
  local tmp_file=""

  ensure_parent_dir "$target_path"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 下载: ${url} -> ${target_path}"
    if [ -n "$chmod_mode" ]; then
      log_info "[DRY-RUN] chmod ${chmod_mode} ${target_path}"
    fi
    return 0
  fi

  tmp_file="$(mktemp /tmp/mcp_pty_download.XXXXXX)" || die "无法创建下载临时文件" "$EX_CANTCREAT"
  register_tmp_file "$tmp_file"

  if ! curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$tmp_file"; then
    die "下载失败: ${url}" "$EX_IOERR"
  fi

  if [ ! -s "$tmp_file" ]; then
    die "下载结果为空: ${url}" "$EX_DATAERR"
  fi

  if ! mv -f -- "$tmp_file" "$target_path"; then
    die "原子替换失败: ${target_path}" "$EX_IOERR"
  fi

  if [ -n "$chmod_mode" ]; then
    run_mutating chmod "$chmod_mode" "$target_path"
  fi

  log_info "已更新: ${target_path}"
}

acquire_lock() {
  validate_lock_file
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 跳过锁文件获取: ${LOCK_FILE}"
    return 0
  fi
  exec 200>"$LOCK_FILE" || die "无法打开锁文件: ${LOCK_FILE}" "$EX_CANTCREAT"
  if ! flock -n 200; then
    die "已有同类任务在运行，请稍后重试。" "$EX_UNAVAILABLE"
  fi
}

resolve_uv_bin() {
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
    return 0
  fi
  if [ -x "${HOME:-/root}/.local/bin/uv" ]; then
    UV_BIN="${HOME:-/root}/.local/bin/uv"
    return 0
  fi
  if [ -x "${HOME:-/root}/.cargo/bin/uv" ]; then
    UV_BIN="${HOME:-/root}/.cargo/bin/uv"
    return 0
  fi
  return 1
}

resolve_opencode_bin() {
  if command -v opencode >/dev/null 2>&1; then
    OPENCODE_BIN="$(command -v opencode)"
    return 0
  fi
  if [ -x "${HOME:-/root}/.opencode-i18n/bin/opencode" ]; then
    OPENCODE_BIN="${HOME:-/root}/.opencode-i18n/bin/opencode"
    return 0
  fi
  if [ -x "${HOME:-/root}/.local/bin/opencode" ]; then
    OPENCODE_BIN="${HOME:-/root}/.local/bin/opencode"
    return 0
  fi
  return 1
}

load_uv_env_if_present() {
  local local_env="${HOME:-/root}/.local/bin/env"
  local cargo_env="${HOME:-/root}/.cargo/env"

  if [ "$DRY_RUN" = "true" ]; then
    if [ -f "$local_env" ]; then
      log_info "[DRY-RUN] source ${local_env}"
    fi
    if [ -f "$cargo_env" ]; then
      log_info "[DRY-RUN] source ${cargo_env}"
    fi
    return 0
  fi

  if [ -f "$local_env" ]; then
    # shellcheck disable=SC1090
    . "$local_env"
  fi
  if [ -f "$cargo_env" ]; then
    # shellcheck disable=SC1090
    . "$cargo_env"
  fi
}

install_uv_if_needed() {
  if resolve_uv_bin; then
    log_info "已检测到 uv: $(${UV_BIN} --version 2>/dev/null || printf '%s' "${UV_BIN}")"
    return 0
  fi

  log_info "未检测到 uv，开始安装。"
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] curl -LsSf ${UV_INSTALL_SCRIPT_URL} | sh"
    return 0
  fi

  if ! curl -LsSf "$UV_INSTALL_SCRIPT_URL" | sh; then
    die "uv 安装失败" "$EX_SOFTWARE"
  fi

  load_uv_env_if_present
}

verify_uv_or_die() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 跳过 uv 版本校验"
    return 0
  fi

  if ! resolve_uv_bin; then
    die "未找到 uv，请检查安装或 ~/.local/bin/env ~/.cargo/env" "$EX_UNAVAILABLE"
  fi

  if ! "$UV_BIN" --version >/dev/null 2>&1; then
    die "uv 版本校验失败" "$EX_SOFTWARE"
  fi

  log_info "uv 校验通过: $(${UV_BIN} --version)"
}

prepare_local_workspace() {
  local server_url=""
  LOCAL_BASE_DIR="$(expand_home_path "$LOCAL_BASE_DIR")"
  SERVER_LOCAL_PATH="${LOCAL_BASE_DIR%/}/server.py"

  run_mutating mkdir -p "$LOCAL_BASE_DIR"
  server_url="$(build_raw_url "pty-runner.py")"
  download_to_file "$server_url" "$SERVER_LOCAL_PATH" "755"
}

update_opencode_config() {
  local config_path="$1"
  local server_path="$2"
  local instruction_path="$3"
  local env_path="{env:HOME}/.local/bin:{env:HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  local server_path_cfg=""
  local instruction_path_cfg=""
  local instruction_path_shell_expr=""
  local base_tmp=""
  local out_tmp=""

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 更新 opencode 配置: ${config_path}"
    return 0
  fi

  ensure_parent_dir "$config_path"

  server_path_cfg="$(to_opencode_home_var_path "$server_path")"
  instruction_path_cfg="$(to_opencode_home_var_path "$instruction_path")"
  instruction_path_shell_expr="$(to_shell_home_expr_path "$instruction_path")"

  base_tmp="$(mktemp /tmp/mcp_pty_opencode_base.XXXXXX)" || die "创建 opencode 临时文件失败" "$EX_CANTCREAT"
  out_tmp="$(mktemp /tmp/mcp_pty_opencode_out.XXXXXX)" || die "创建 opencode 输出临时文件失败" "$EX_CANTCREAT"
  register_tmp_file "$base_tmp"
  register_tmp_file "$out_tmp"

  if [ -f "$config_path" ]; then
    cp -f -- "$config_path" "$base_tmp" || die "复制 opencode 配置失败" "$EX_IOERR"
    if ! jq -e . "$base_tmp" >/dev/null 2>&1; then
      die "opencode 配置不是合法 JSON: ${config_path}" "$EX_DATAERR"
    fi
  else
    printf '{}\n' >"$base_tmp" || die "初始化 opencode 配置失败" "$EX_CANTCREAT"
  fi

  if ! jq --arg server_path "$server_path_cfg" --arg env_path "$env_path" --arg instruction_path "$instruction_path_cfg" --arg instruction_path_abs "$instruction_path" --arg instruction_path_shell_expr "$instruction_path_shell_expr" '
    .mcp = (.mcp // {})
    | .mcp["pty-runner"] = {
        type: "local",
        command: ["uv", "run", "--script", $server_path],
        environment: {
          PATH: $env_path,
          LANG: "C.UTF-8",
          LC_ALL: "C.UTF-8",
          PYTHONUNBUFFERED: "1",
          TERM: "xterm-256color"
        },
        enabled: true,
        timeout: 60000
      }
    | .instructions = (
        ((.instructions // [])
        | map(select(. != $instruction_path_abs and . != $instruction_path and . != $instruction_path_shell_expr)))
        + [$instruction_path]
        | unique
      )
  ' "$base_tmp" >"$out_tmp"; then
    die "生成 opencode 配置失败" "$EX_SOFTWARE"
  fi

  if ! jq -e . "$out_tmp" >/dev/null 2>&1; then
    die "生成的 opencode 配置非法" "$EX_SOFTWARE"
  fi

  if ! mv -f -- "$out_tmp" "$config_path"; then
    die "写入 opencode 配置失败: ${config_path}" "$EX_IOERR"
  fi

  chmod 600 "$config_path" 2>/dev/null || log_warn "无法设置 opencode 配置权限为 600"
  log_info "已更新 opencode 配置: ${config_path}"
}

configure_opencode_optional() {
  local pty_md_url=""

  OPENCODE_CONFIG_PATH="$(expand_home_path "$OPENCODE_CONFIG_PATH")"
  OPENCODE_INSTRUCTIONS_PATH="$(expand_home_path "$OPENCODE_INSTRUCTIONS_PATH")"

  pty_md_url="$(build_raw_url "pty.md")"
  download_to_file "$pty_md_url" "$OPENCODE_INSTRUCTIONS_PATH" "644"
  update_opencode_config "$OPENCODE_CONFIG_PATH" "$SERVER_LOCAL_PATH" "$OPENCODE_INSTRUCTIONS_PATH"
}

print_next_steps() {
  printf '\n'
  printf '%s\n' "=== MCP PTY 部署完成 ==="
  printf '%s\n' "版本: ${VERSION}"
  printf '%s\n' "描述: ${DESCRIPTION}"
  printf '%s\n' "依赖: ${DEPENDENCIES}"
  printf '%s\n' "本地目录: ${LOCAL_BASE_DIR}"
  printf '%s\n' "入口脚本: ${SERVER_LOCAL_PATH}"
  printf '%s\n' "远端基址: ${REMOTE_RAW_BASE}"
  if [ "$WITH_OPENCODE" = "true" ]; then
    printf '%s\n' "opencode 配置: ${OPENCODE_CONFIG_PATH}"
    printf '%s\n' "instructions: ${OPENCODE_INSTRUCTIONS_PATH}"
  else
    printf '%s\n' "opencode 关联: 未启用（如需启用，增加 --with-opencode）"
  fi

  printf '\n'
  printf '%s\n' "建议验证："
  printf '%s\n' "1) uv --version"
  printf '%s\n' "2) opencode mcp list"
  printf '%s\n' "3) 对话测试：使用 pty-runner 运行 echo 'Hello from uv' 并读取输出"
}

print_uninstall_next_steps() {
  printf '\n'
  printf '%s\n' "=== MCP PTY 卸载完成 ==="
  printf '%s\n' "版本: ${VERSION}"
  printf '%s\n' "本地目录: ${LOCAL_BASE_DIR}"
  printf '%s\n' "入口脚本: ${SERVER_LOCAL_PATH}"
  printf '%s\n' "opencode 配置: ${OPENCODE_CONFIG_PATH}"
  printf '%s\n' "instructions: ${OPENCODE_INSTRUCTIONS_PATH}"
  printf '%s\n' "说明: 仅清理 mcp_pty 相关内容，不会卸载 uv。"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --mode)
      [ "$#" -ge 2 ] || die "参数 --mode 缺少值" "$EX_USAGE"
      is_mode_valid "$2" || die "不支持的模式: $2" "$EX_USAGE"
      MODE="$2"
      shift 2
      ;;
    --with-opencode)
      MODE="opencode"
      shift
      ;;
    --uninstall)
      MODE="uninstall"
      shift
      ;;
    --remote-raw-base)
      [ "$#" -ge 2 ] || die "参数 --remote-raw-base 缺少值" "$EX_USAGE"
      REMOTE_RAW_BASE="$2"
      shift 2
      ;;
    --local-dir)
      [ "$#" -ge 2 ] || die "参数 --local-dir 缺少值" "$EX_USAGE"
      LOCAL_BASE_DIR="$2"
      shift 2
      ;;
    --opencode-config)
      [ "$#" -ge 2 ] || die "参数 --opencode-config 缺少值" "$EX_USAGE"
      OPENCODE_CONFIG_PATH="$2"
      shift 2
      ;;
    --opencode-instruction-path)
      [ "$#" -ge 2 ] || die "参数 --opencode-instruction-path 缺少值" "$EX_USAGE"
      OPENCODE_INSTRUCTIONS_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1" "$EX_USAGE"
      ;;
    esac
  done
}

validate_inputs() {
  if [ -z "${HOME:-}" ]; then
    die "HOME 未设置，无法计算默认路径" "$EX_OSERR"
  fi

  REMOTE_RAW_BASE="${REMOTE_RAW_BASE%/}"
  validate_remote_raw_base

  if [ -z "$LOCAL_BASE_DIR" ]; then
    die "--local-dir 不能为空" "$EX_USAGE"
  fi
  if [ -z "$OPENCODE_CONFIG_PATH" ]; then
    die "--opencode-config 不能为空" "$EX_USAGE"
  fi
  if [ -z "$OPENCODE_INSTRUCTIONS_PATH" ]; then
    die "--opencode-instruction-path 不能为空" "$EX_USAGE"
  fi
}

should_skip_confirmation() {
  if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
    return 0
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    return 0
  fi
  return 1
}

select_mode_if_needed() {
  local choice=""

  if [ -n "$MODE" ]; then
    return 0
  fi

  if should_skip_confirmation; then
    MODE="install"
    return 0
  fi

  printf '%s\n' "请选择 mcp_pty 运行模式:" >/dev/tty
  printf '%s\n' "  1) install   - 本地搭建" >/dev/tty
  printf '%s\n' "  2) opencode  - 本地搭建并关联 opencode" >/dev/tty
  printf '%s\n' "  3) uninstall - 卸载 mcp_pty 相关内容" >/dev/tty
  printf '%s' "选项 [1-3] (默认 1): " >/dev/tty
  read -r choice </dev/tty || choice=""

  case "${choice:-1}" in
  1)
    MODE="install"
    ;;
  2)
    MODE="opencode"
    ;;
  3)
    MODE="uninstall"
    ;;
  *)
    die "无效选项: ${choice}" "$EX_USAGE"
    ;;
  esac
}

confirm_run_if_needed() {
  local answer=""
  if should_skip_confirmation; then
    log_info "检测到 headless/JB_NONINTERACTIVE，跳过交互确认并继续执行。"
    return 0
  fi

  case "$MODE" in
  install)
    printf '%s' "确认执行 mcp_pty 本地搭建? [Y/n]: " >/dev/tty
    ;;
  opencode)
    printf '%s' "确认执行 mcp_pty 搭建并关联 opencode? [Y/n]: " >/dev/tty
    ;;
  uninstall)
    printf '%s' "确认执行 mcp_pty 卸载（不卸载 uv）? [Y/n]: " >/dev/tty
    ;;
  *)
    die "未知运行模式: ${MODE}" "$EX_SOFTWARE"
    ;;
  esac
  read -r answer </dev/tty || answer=""
  case "${answer:-Y}" in
  [nN] | [nN][oO])
    log_warn "用户取消执行 mcp 流程。"
    return 10
    ;;
  *)
    return 0
    ;;
  esac
}

initialize_runtime_paths() {
  LOCAL_BASE_DIR="$(expand_home_path "$LOCAL_BASE_DIR")"
  SERVER_LOCAL_PATH="${LOCAL_BASE_DIR%/}/server.py"
  OPENCODE_CONFIG_PATH="$(expand_home_path "$OPENCODE_CONFIG_PATH")"
  OPENCODE_INSTRUCTIONS_PATH="$(expand_home_path "$OPENCODE_INSTRUCTIONS_PATH")"
}

uninstall_file_if_exists() {
  local target="$1"
  if [ -f "$target" ]; then
    run_mutating rm -f -- "$target"
    log_info "已删除文件: ${target}"
    return 0
  fi
  log_info "文件不存在，跳过: ${target}"
}

uninstall_empty_dir_if_exists() {
  local target="$1"
  if [ ! -d "$target" ]; then
    return 0
  fi
  if [ -n "$(ls -A "$target" 2>/dev/null || true)" ]; then
    log_info "目录非空，保留: ${target}"
    return 0
  fi
  run_mutating rmdir "$target" || true
}

cleanup_opencode_config() {
  local config_path="$1"
  local instruction_path_abs="$2"
  local instruction_path_env=""
  local instruction_path_shell=""
  local base_tmp=""
  local out_tmp=""

  if [ ! -f "$config_path" ]; then
    log_info "opencode 配置不存在，跳过: ${config_path}"
    return 0
  fi

  instruction_path_env="$(to_opencode_home_var_path "$instruction_path_abs")"
  instruction_path_shell="$(to_shell_home_expr_path "$instruction_path_abs")"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] 清理 opencode 配置关联: ${config_path}"
    return 0
  fi

  base_tmp="$(mktemp /tmp/mcp_pty_opencode_uninstall_base.XXXXXX)" || die "创建 opencode 卸载临时文件失败" "$EX_CANTCREAT"
  out_tmp="$(mktemp /tmp/mcp_pty_opencode_uninstall_out.XXXXXX)" || die "创建 opencode 卸载输出文件失败" "$EX_CANTCREAT"
  register_tmp_file "$base_tmp"
  register_tmp_file "$out_tmp"

  cp -f -- "$config_path" "$base_tmp" || die "复制 opencode 配置失败" "$EX_IOERR"
  jq -e . "$base_tmp" >/dev/null 2>&1 || die "opencode 配置不是合法 JSON: ${config_path}" "$EX_DATAERR"

  if ! jq --arg ins_abs "$instruction_path_abs" --arg ins_env "$instruction_path_env" --arg ins_shell "$instruction_path_shell" '
    del(.mcp["pty-runner"])
    | .instructions = ((.instructions // []) | map(select(. != $ins_abs and . != $ins_env and . != $ins_shell)))
  ' "$base_tmp" >"$out_tmp"; then
    die "生成卸载后的 opencode 配置失败" "$EX_SOFTWARE"
  fi

  jq -e . "$out_tmp" >/dev/null 2>&1 || die "卸载后 opencode 配置非法" "$EX_SOFTWARE"
  mv -f -- "$out_tmp" "$config_path" || die "写入 opencode 配置失败: ${config_path}" "$EX_IOERR"
  chmod 600 "$config_path" 2>/dev/null || log_warn "无法设置 opencode 配置权限为 600"
}

uninstall_flow() {
  initialize_runtime_paths

  uninstall_file_if_exists "$SERVER_LOCAL_PATH"
  uninstall_empty_dir_if_exists "$LOCAL_BASE_DIR"
  uninstall_file_if_exists "$OPENCODE_INSTRUCTIONS_PATH"
  cleanup_opencode_config "$OPENCODE_CONFIG_PATH" "$OPENCODE_INSTRUCTIONS_PATH"
}

main() {
  parse_args "$@"
  validate_inputs
  select_mode_if_needed
  if [ "$MODE" = "opencode" ]; then
    WITH_OPENCODE="true"
  fi
  confirm_run_if_needed || return $?

  check_core_dependencies
  check_optional_dependencies
  acquire_lock

  initialize_runtime_paths

  if [ "$MODE" = "uninstall" ]; then
    uninstall_flow
    print_uninstall_next_steps
    return 0
  fi

  install_uv_if_needed
  load_uv_env_if_present
  verify_uv_or_die

  prepare_local_workspace

  if [ "$WITH_OPENCODE" = "true" ]; then
    configure_opencode_optional
  fi

  print_next_steps
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
