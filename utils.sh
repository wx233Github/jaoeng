#!/usr/bin/env bash
# =============================================================
# 🚀 通用工具函数库 (v2.44-标准版 & 性能优化)
# - 优化: generate_line 移除 sed 依赖，使用 Bash 原生字符串替换，提升性能。
# - 恢复: UI 输出回到标准流，日志保持在错误流。
# =============================================================

# --- 严格模式 ---
set -euo pipefail
IFS=$'\n\t'
export PATH='/usr/local/bin:/usr/bin:/bin'

# --- 默认配置 ---
DEFAULT_BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
DEFAULT_INSTALL_DIR="/opt/vps_install_modules"
DEFAULT_BIN_DIR="/usr/local/bin"
DEFAULT_LOCK_FILE="/tmp/vps_install_modules.lock"
DEFAULT_TIMEZONE="Asia/Shanghai"
DEFAULT_CONFIG_PATH="${DEFAULT_INSTALL_DIR}/config.json"
DEFAULT_LOG_WITH_TIMESTAMP="false"
DEFAULT_LOG_FILE="/var/log/jaoeng-utils.log"
DEFAULT_LOG_LEVEL="INFO"
DEFAULT_ENABLE_AUTO_UPDATE="true"
DEFAULT_NONINTERACTIVE="false"
# shellcheck disable=SC2034
DEFAULT_CLEAR_MODE="off"

readonly -a UTILS_PUBLIC_API=(
	"log_info"
	"log_success"
	"log_warn"
	"log_err"
	"log_debug"
	"die"
	"check_dependencies"
	"validate_args"
	"_prompt_user_input"
	"_prompt_for_menu_choice"
	"press_enter_to_continue"
	"confirm_action"
	"normalize_clear_mode"
	"should_clear_screen"
	"load_config"
	"generate_line"
	"_get_visual_width"
	"_render_menu"
	"utils_api_contract"
)

# --- 颜色定义 ---
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "true" ]; then
	# shellcheck disable=SC2034
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	# shellcheck disable=SC2034
	BLUE='\033[0;34m'
	# shellcheck disable=SC2034
	CYAN='\033[0;36m'
	NC='\033[0m'
	BOLD='\033[1m'
	ORANGE='\033[38;5;208m' # 橙色 #FA720A
else
	# shellcheck disable=SC2034
	RED=""
	GREEN=""
	YELLOW=""
	# shellcheck disable=SC2034
	BLUE=""
	# shellcheck disable=SC2034
	CYAN=""
	NC=""
	BOLD=""
	ORANGE=""
fi

# --- 日志系统 ---
_log_level_value() {
	local level="$1"
	case "$level" in
	DEBUG) printf '%s' "10" ;;
	INFO) printf '%s' "20" ;;
	WARN) printf '%s' "30" ;;
	ERROR) printf '%s' "40" ;;
	*) printf '%s' "20" ;;
	esac
}

_log_should_print() {
	local msg_level="$1"
	local current_level="${LOG_LEVEL:-${DEFAULT_LOG_LEVEL}}"
	local msg_value
	local cur_value
	msg_value="$(_log_level_value "$msg_level")"
	cur_value="$(_log_level_value "$current_level")"
	if [ "$msg_value" -ge "$cur_value" ]; then
		return 0
	fi
	return 1
}

_log_timestamp() {
	date +'%Y-%m-%d %H:%M:%S'
}

_log_write() {
	local level="$1"
	shift
	local msg="$*"
	local ts
	local log_file="${LOG_FILE:-${DEFAULT_LOG_FILE}}"
	ts="$(_log_timestamp)"
	if ! _log_should_print "$level"; then
		return 0
	fi
	if [ -n "$log_file" ]; then
		printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$log_file" 2>/dev/null || true
	fi
	printf '[%s] %b\n' "$level" "$msg"
}

log_info() { _log_write "INFO" "$*"; }
log_success() { _log_write "INFO" "$*"; }
log_warn() { _log_write "WARN" "$*" >&2; }
log_err() { _log_write "ERROR" "$*" >&2; }
log_debug() { if [ "${JB_DEBUG_MODE:-false}" = "true" ]; then _log_write "DEBUG" "$*" >&2; fi; }

sanitize_noninteractive_flag() {
	case "${JB_NONINTERACTIVE:-false}" in
	true | false) return 0 ;;
	*)
		log_warn "JB_NONINTERACTIVE 值非法: ${JB_NONINTERACTIVE}，已回退为 false"
		JB_NONINTERACTIVE="false"
		return 0
		;;
	esac
}

utils_public_api() {
	printf '%s\n' "${UTILS_PUBLIC_API[@]}"
}

utils_api_contract() {
	printf '%s\n' "公共 API 稳定层（向后兼容承诺）:"
	printf '%s\n' "- 日志: log_info/log_warn/log_err/log_debug"
	printf '%s\n' "- 交互: _prompt_user_input/_prompt_for_menu_choice/confirm_action"
	printf '%s\n' "- UI: _render_menu/press_enter_to_continue/should_clear_screen"
	printf '%s\n' "- 配置: load_config"
}

die() {
	local msg="$1"
	local code="${2:-1}"
	log_err "$msg"
	return "$code"
}

check_dependencies() {
	local missing=()
	local dep
	for dep in "$@"; do
		if ! command -v "$dep" >/dev/null 2>&1; then
			missing+=("$dep")
		fi
	done
	if [ "${#missing[@]}" -gt 0 ]; then
		die "缺少依赖: ${missing[*]}" 127 || return "$?"
		return 127
	fi
	return 0
}

validate_args() {
	if [ "$#" -lt 3 ]; then
		return 0
	fi
	local min_args="$1"
	local max_args="$2"
	local actual_args="$3"
	if [ "$actual_args" -lt "$min_args" ] || [ "$actual_args" -gt "$max_args" ]; then
		die "参数数量不符合要求: 需要 ${min_args}-${max_args}，实际 ${actual_args}" 64 || return "$?"
		return 64
	fi
	return 0
}

# --- 交互函数 ---
_prompt_user_input() {
	local prompt_text="$1"
	local default_value="$2"
	local result

	if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
		log_warn "非交互模式：使用默认值"
		echo "$default_value"
		return 0
	fi
	if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
		log_warn "无法访问 /dev/tty，使用默认值"
		echo "$default_value"
		return 0
	fi
	printf '%b' "${YELLOW}${prompt_text}${NC}" >/dev/tty
	read -r result </dev/tty

	if [ -z "$result" ]; then
		echo "$default_value"
	else
		echo "$result"
	fi
}

_prompt_for_menu_choice() {
	local numeric_range="$1"
	local func_options="${2:-}"
	local prompt_text="${ORANGE}>${NC} 选项 "

	if [ -n "$numeric_range" ]; then
		local start="${numeric_range%%-*}"
		local end="${numeric_range##*-}"
		if [ "$start" = "$end" ]; then
			prompt_text+="[${ORANGE}${start}${NC}] "
		else
			prompt_text+="[${ORANGE}${start}${NC}-${end}] "
		fi
	fi

	if [ -n "$func_options" ]; then
		local start="${func_options%%,*}"
		local rest="${func_options#*,}"
		if [ "$start" = "$rest" ]; then
			prompt_text+="[${ORANGE}${start}${NC}] "
		else
			prompt_text+="[${ORANGE}${start}${NC},${rest}] "
		fi
	fi

	prompt_text+="(↩ 返回): "

	local choice
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
		log_warn "非交互模式：返回空选项"
		echo ""
		return 0
	fi
	if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
		log_warn "无法访问 /dev/tty，返回空选项"
		echo ""
		return 0
	fi
	printf '%b' "$prompt_text" >/dev/tty
	read -r choice </dev/tty
	echo "$choice"
}

press_enter_to_continue() {
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
		log_warn "非交互模式：跳过等待"
		return 0
	fi
	if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
		log_warn "无法访问 /dev/tty，跳过等待"
		return 0
	fi
	printf '%b' "\n${YELLOW}按 Enter 键继续...${NC}" >/dev/tty
	read -r </dev/tty
}
confirm_action() {
	local prompt="$1"
	local choice
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
		log_warn "非交互模式：默认确认"
		return 0
	fi
	if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
		log_warn "无法访问 /dev/tty，默认确认"
		return 0
	fi
	printf '%b' "${YELLOW}${prompt} ([y]/n): ${NC}" >/dev/tty
	read -r choice </dev/tty
	case "$choice" in n | N) return 1 ;; *) return 0 ;; esac
}

# --- 清屏策略 ---
# shellcheck disable=SC2034
declare -A JB_SMART_CLEAR_SEEN=()

normalize_clear_mode() {
	local mode="${JB_CLEAR_MODE:-}"
	if [ -z "$mode" ]; then
		if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then
			mode="full"
		else
			mode="off"
		fi
	fi
	case "${mode,,}" in
	off | false | 0) printf '%s' "off" ;;
	full | true | 1) printf '%s' "full" ;;
	smart) printf '%s' "smart" ;;
	*) printf '%s' "off" ;;
	esac
	return 0
}

should_clear_screen() {
	local menu_key="${1:-__default_menu__}"
	local clear_mode
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
		return 1
	fi
	clear_mode="$(normalize_clear_mode)"
	case "$clear_mode" in
	off) return 1 ;;
	full) return 0 ;;
	smart)
		if [ -n "${JB_SMART_CLEAR_SEEN[$menu_key]+x}" ]; then
			return 1
		fi
		JB_SMART_CLEAR_SEEN["$menu_key"]=1
		return 0
		;;
	*) return 1 ;;
	esac
}

# --- 配置加载 (优化版) ---
_get_json_value_fallback() {
	local file="$1"
	local key="$2"
	local default_val="$3"
	local result
	result=$(sed -n 's/.*"'"$key"'": *"\([^"]*\)".*/\1/p' "$file")
	echo "${result:-$default_val}"
}

load_config() {
	local config_path="${1:-${CONFIG_PATH:-${DEFAULT_CONFIG_PATH}}}"
	BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"
	INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
	BIN_DIR="${BIN_DIR:-$DEFAULT_BIN_DIR}"
	LOCK_FILE="${LOCK_FILE:-$DEFAULT_LOCK_FILE}"
	JB_TIMEZONE="${JB_TIMEZONE:-$DEFAULT_TIMEZONE}"
	CONFIG_PATH="$config_path"
	JB_LOG_WITH_TIMESTAMP="${JB_LOG_WITH_TIMESTAMP:-$DEFAULT_LOG_WITH_TIMESTAMP}"
	if [ -n "${JB_LOG_LEVEL_OVERRIDE:-}" ]; then
		case "${JB_LOG_LEVEL_OVERRIDE}" in
		ERROR | WARN | INFO | DEBUG)
			LOG_LEVEL="${JB_LOG_LEVEL_OVERRIDE}"
			log_info "应用临时日志级别覆盖: ${LOG_LEVEL}"
			;;
		esac
	fi
	JB_ENABLE_AUTO_UPDATE="${JB_ENABLE_AUTO_UPDATE:-$DEFAULT_ENABLE_AUTO_UPDATE}"
	JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-$DEFAULT_NONINTERACTIVE}"
	# shellcheck disable=SC2034
	JB_CLEAR_MODE="off"
	LOG_FILE="${LOG_FILE:-${DEFAULT_LOG_FILE}}"
	LOG_LEVEL="${LOG_LEVEL:-${DEFAULT_LOG_LEVEL}}"

	sanitize_noninteractive_flag

	if [ ! -f "$config_path" ]; then
		log_warn "配置文件 $config_path 未找到，使用默认配置。"
		return 0
	fi

	if command -v jq >/dev/null 2>&1; then
		BASE_URL=$(jq -r '.base_url // empty' "$config_path" 2>/dev/null || echo "$BASE_URL")
		INSTALL_DIR=$(jq -r '.install_dir // empty' "$config_path" 2>/dev/null || echo "$INSTALL_DIR")
		BIN_DIR=$(jq -r '.bin_dir // empty' "$config_path" 2>/dev/null || echo "$BIN_DIR")
		LOCK_FILE=$(jq -r '.lock_file // empty' "$config_path" 2>/dev/null || echo "$LOCK_FILE")
		JB_TIMEZONE=$(jq -r '.timezone // empty' "$config_path" 2>/dev/null || echo "$JB_TIMEZONE")
		JB_LOG_WITH_TIMESTAMP=$(jq -r '.log_with_timestamp // false' "$config_path" 2>/dev/null || echo "$JB_LOG_WITH_TIMESTAMP")
		JB_ENABLE_AUTO_UPDATE=$(jq -r '.enable_auto_update // "true"' "$config_path" 2>/dev/null || echo "$JB_ENABLE_AUTO_UPDATE")
		JB_NONINTERACTIVE=$(jq -r '.noninteractive // "false"' "$config_path" 2>/dev/null || echo "$JB_NONINTERACTIVE")
	else
		log_warn "未检测到 jq，使用轻量文本解析。"
		BASE_URL=$(_get_json_value_fallback "$config_path" "base_url" "$BASE_URL")
		INSTALL_DIR=$(_get_json_value_fallback "$config_path" "install_dir" "$INSTALL_DIR")
		BIN_DIR=$(_get_json_value_fallback "$config_path" "bin_dir" "$BIN_DIR")
		LOCK_FILE=$(_get_json_value_fallback "$config_path" "lock_file" "$LOCK_FILE")
		JB_TIMEZONE=$(_get_json_value_fallback "$config_path" "timezone" "$JB_TIMEZONE")
		JB_LOG_WITH_TIMESTAMP=$(_get_json_value_fallback "$config_path" "log_with_timestamp" "$JB_LOG_WITH_TIMESTAMP")
		JB_ENABLE_AUTO_UPDATE=$(_get_json_value_fallback "$config_path" "enable_auto_update" "$JB_ENABLE_AUTO_UPDATE")
		JB_NONINTERACTIVE=$(_get_json_value_fallback "$config_path" "noninteractive" "$JB_NONINTERACTIVE")
	fi

	# shellcheck disable=SC2034
	JB_CLEAR_MODE="$(normalize_clear_mode)"
}

# --- UI 渲染 & 字符串处理 (性能优化版) ---
generate_line() {
	local len=${1:-40}
	local char=${2:-"─"}
	if [ "$len" -le 0 ]; then
		echo ""
		return
	fi

	# [优化点] 使用 Bash 原生 printf 和字符串替换，避免 fork sed 子进程
	# 旧方法: printf "%${len}s" "" | sed "s/ /$char/g"  (生成速度快，但多一个进程)
	# 新方法: Bash 参数扩展替换 (纯内存操作)
	local spaces
	printf -v spaces "%${len}s" ""
	echo "${spaces// /$char}"
}

_get_visual_width() {
	local text="$1"
	local plain_text
	plain_text=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g')
	if [ -z "$plain_text" ]; then
		echo 0
		return
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<<"$plain_text" 2>/dev/null || echo "${#plain_text}"
	elif command -v wc >/dev/null 2>&1 && wc --help 2>&1 | grep -q -- "-m"; then
		printf '%s' "$plain_text" | wc -m
	else
		echo "${#plain_text}"
	fi
}

_render_menu() {
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

	echo ""
	printf '%b\n' "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
	if [ -n "$title" ]; then
		local padding_total=$((box_inner_width - title_width))
		local padding_left=$((padding_total / 2))
		local padding_right=$((padding_total - padding_left))
		printf '%b\n' "${GREEN}│${NC}$(printf '%*s' "$padding_left" "")${BOLD}${title}${NC}$(printf '%*s' "$padding_right" "")${GREEN}│${NC}"
	fi
	printf '%b\n' "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
	for line in "${lines[@]}"; do
		printf '%b\n' "${line}"
	done
	local box_total_physical_width=$((box_inner_width + 2))
	printf '%b\n' "${GREEN}$(generate_line "$box_total_physical_width" "─")${NC}"
}

_on_error() {
	local exit_code="$1"
	local line_no="$2"
	log_err "运行出错: exit_code=${exit_code}, line=${line_no}"
	return "$exit_code"
}

_cleanup() {
	:
}

main() {
	trap '_on_error "$?" "$LINENO"' ERR
	trap _cleanup EXIT

	log_info "启动: utils.sh"
	log_info "环境: LOG_LEVEL=${LOG_LEVEL:-${DEFAULT_LOG_LEVEL}}, LOG_FILE=${LOG_FILE:-${DEFAULT_LOG_FILE}}"
	return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
