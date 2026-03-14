#!/usr/bin/env bash

_generate_op_id() { OP_ID="$(date +%Y%m%d_%H%M%S)_$$_$RANDOM"; }

_is_valid_var_name() {
	local name="${1:-}"
	[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

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

TTY_FALLBACK_WARNED="false"

# é»è®¤æ¥å¿è·¯å¾ï¼nginx.sh æªé¢è®¾æ¶ååºï¼
LOG_FILE_DEFAULT="${LOG_FILE_DEFAULT:-/var/log/nginx_ssl_manager.log}"
LOG_FILE_FALLBACK="${LOG_FILE_FALLBACK:-/tmp/nginx_ssl_manager.log}"

_tty_available() {
	if [ ! -t 0 ] && [ ! -t 1 ]; then
		return 1
	fi
	[ -r /dev/tty ] && [ -w /dev/tty ]
}

_read_input() {
	if [ -t 0 ]; then
		read -r
		return $?
	fi
	if _tty_available; then
		_log_tty_fallback_once
		read -r </dev/tty
		return $?
	fi
	return 1
}

_read_input_prompt() {
	local prompt_text="${1:-}"
	if [ -t 0 ]; then
		if [ -t 1 ]; then
			printf '%b' "$prompt_text"
		elif _tty_available; then
			printf '%b' "$prompt_text" >/dev/tty
		else
			printf '%b' "$prompt_text" >&2
		fi
		read -r
		return $?
	fi
	if _tty_available; then
		_log_tty_fallback_once
		printf '%b' "$prompt_text" >/dev/tty
		read -r </dev/tty
		return $?
	fi
	return 1
}

_read_secret_input_prompt() {
	local prompt_text="${1:-}"
	if [ -t 0 ]; then
		if [ -t 1 ]; then
			printf '%b' "$prompt_text"
		elif _tty_available; then
			printf '%b' "$prompt_text" >/dev/tty
		else
			printf '%b' "$prompt_text" >&2
		fi
		read -rs
		return $?
	fi
	if _tty_available; then
		_log_tty_fallback_once
		printf '%b' "$prompt_text" >/dev/tty
		read -rs </dev/tty
		return $?
	fi
	return 1
}

_log_tty_fallback_once() {
	if [ "${TTY_FALLBACK_WARNED:-false}" = "true" ]; then
		return 0
	fi
	log_message WARN "标准输入不可用，已切换为 /dev/tty"
	TTY_FALLBACK_WARNED="true"
}

self_elevate_or_die() {
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi

	if ! command -v sudo >/dev/null 2>&1; then
		log_error "未安装 sudo，无法自动提权。"
		exit "${EX_SOFTWARE:-70}"
	fi

	case "$0" in
	/dev/fd/* | /proc/self/fd/*)
		local tmp_script
		tmp_script=$(mktemp /tmp/nginx_module.XXXXXX.sh)
		cat <"$0" >"$tmp_script"
		chmod 700 "$tmp_script" || true
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
			if sudo -n true 2>/dev/null; then
				exec sudo -n -E bash "$tmp_script" "$@"
			fi
			log_error "非交互模式下无法自动提权（需要免密 sudo）。"
			exit "${EX_SOFTWARE:-70}"
		fi
		exec sudo -E bash "$tmp_script" "$@"
		;;
	*)
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
			if sudo -n true 2>/dev/null; then
				exec sudo -n -E bash "$0" "$@"
			fi
			log_error "非交互模式下无法自动提权（需要免密 sudo）。"
			exit "${EX_SOFTWARE:-70}"
		fi
		exec sudo -E bash "$0" "$@"
		;;
	esac
}

cleanup() {
	find /tmp -maxdepth 1 -name "acme_cmd_log.*" -user "$(id -un)" -delete 2>/dev/null || true
	if [ "${#TMP_PAYLOAD_FILES[@]}" -gt 0 ]; then
		rm -f "${TMP_PAYLOAD_FILES[@]}" 2>/dev/null || true
	fi
	_release_lock "$LOCK_FILE_HTTP" "${LOCK_OWNER_PID_HTTP:-}"
	_release_lock "$LOCK_FILE_TCP" "${LOCK_OWNER_PID_TCP:-}"
	_release_lock "$LOCK_FILE_CERT" "${LOCK_OWNER_PID_CERT:-}"
	_release_lock "$LOCK_FILE_PROJECT" "${LOCK_OWNER_PID_PROJECT:-}"
	_release_lock "$LOCK_FILE_LOGROTATE" "${LOCK_OWNER_PID_LOGROTATE:-}"
	_release_lock "$LOCK_FILE_CRON" "${LOCK_OWNER_PID_CRON:-}"
	_release_lock "$LOCK_FILE_CF" "${LOCK_OWNER_PID_CF:-}"
	_release_lock "$LOCK_FILE_WAL" "${LOCK_OWNER_PID_WAL:-}"
}

err_handler() {
	local exit_code="${1:-1}" line_no="${2:-}"
	log_error "发生错误 (exit=${exit_code}) 于行 ${line_no}。"
}

_on_int() {
	printf '%b' "\n${RED}检测到中断信号,已安全取消操作并清理残留文件。${NC}\n"
	cleanup
	exit 130
}

_on_int_resume_service() {
	if [ -n "${INTERRUPT_RESUME_SERVICE:-}" ]; then
		systemctl start "$INTERRUPT_RESUME_SERVICE" 2>/dev/null || true
		INTERRUPT_RESUME_SERVICE=""
	fi
	_on_int
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
	if command mkdir -p "$dir" 2>/dev/null && command touch "$target" 2>/dev/null; then
		LOG_FILE="$target"
		return 0
	fi
	LOG_FILE="$LOG_FILE_FALLBACK"
	command mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
	command touch "$LOG_FILE" 2>/dev/null || true
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
	printf '%s\n' "$$" >"$lock_file"
	return 0
}

_release_lock() {
	local lock_file="${1:-}"
	local lock_pid="${2:-}"
	local lock_file_pid=""
	if [ -z "$lock_file" ] || [ -z "$lock_pid" ]; then return 0; fi
	lock_file_pid=$(cat "$lock_file" 2>/dev/null || true)
	if [ -f "$lock_file" ] && [ "$lock_file_pid" = "$lock_pid" ]; then
		rm -f "$lock_file" 2>/dev/null || true
	fi
}

release_project_lock() {
	local fd="${LOCK_FD_PROJECT:-}"
	_release_lock "$LOCK_FILE_PROJECT" "${LOCK_OWNER_PID_PROJECT:-}"
	if [[ "$fd" =~ ^[0-9]+$ ]]; then
		eval "exec ${fd}>&-" 2>/dev/null || true
	fi
	LOCK_OWNER_PID_PROJECT=""
	return 0
}

release_logrotate_lock() {
	local fd="${LOCK_FD_LOGROTATE:-}"
	_release_lock "$LOCK_FILE_LOGROTATE" "${LOCK_OWNER_PID_LOGROTATE:-}"
	if [[ "$fd" =~ ^[0-9]+$ ]]; then
		eval "exec ${fd}>&-" 2>/dev/null || true
	fi
	LOCK_OWNER_PID_LOGROTATE=""
	return 0
}

release_cron_lock() {
	local fd="${LOCK_FD_CRON:-}"
	_release_lock "$LOCK_FILE_CRON" "${LOCK_OWNER_PID_CRON:-}"
	if [[ "$fd" =~ ^[0-9]+$ ]]; then
		eval "exec ${fd}>&-" 2>/dev/null || true
	fi
	LOCK_OWNER_PID_CRON=""
	return 0
}

release_cf_lock() {
	local fd="${LOCK_FD_CF:-}"
	_release_lock "$LOCK_FILE_CF" "${LOCK_OWNER_PID_CF:-}"
	if [[ "$fd" =~ ^[0-9]+$ ]]; then
		eval "exec ${fd}>&-" 2>/dev/null || true
	fi
	LOCK_OWNER_PID_CF=""
	return 0
}

release_wal_lock() {
	local fd="${LOCK_FD_WAL:-}"
	_release_lock "$LOCK_FILE_WAL" "${LOCK_OWNER_PID_WAL:-}"
	if [[ "$fd" =~ ^[0-9]+$ ]]; then
		eval "exec ${fd}>&-" 2>/dev/null || true
	fi
	LOCK_OWNER_PID_WAL=""
	return 0
}

_mark_nginx_conf_changed() {
	NGINX_CONF_GEN=$((NGINX_CONF_GEN + 1))
	# shellcheck disable=SC2034
	NGINX_RELOAD_STRATEGY_CACHE=""
	# shellcheck disable=SC2034
	NGINX_RELOAD_STRATEGY_CACHE_TS=0
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

acquire_project_lock() {
	if _acquire_lock "$LOCK_FILE_PROJECT" "LOCK_FD_PROJECT"; then
		LOCK_OWNER_PID_PROJECT="$$"
		return 0
	fi
	return 1
}

acquire_logrotate_lock() {
	if _acquire_lock "$LOCK_FILE_LOGROTATE" "LOCK_FD_LOGROTATE"; then
		LOCK_OWNER_PID_LOGROTATE="$$"
		return 0
	fi
	return 1
}

acquire_cron_lock() {
	if _acquire_lock "$LOCK_FILE_CRON" "LOCK_FD_CRON"; then
		LOCK_OWNER_PID_CRON="$$"
		return 0
	fi
	return 1
}

acquire_cf_lock() {
	if _acquire_lock "$LOCK_FILE_CF" "LOCK_FD_CF"; then
		LOCK_OWNER_PID_CF="$$"
		return 0
	fi
	return 1
}

acquire_wal_lock() {
	if _acquire_lock "$LOCK_FILE_WAL" "LOCK_FD_WAL"; then
		LOCK_OWNER_PID_WAL="$$"
		return 0
	fi
	return 1
}

TX_STATE=""
TX_DOMAIN=""
TX_LAST_ERROR_CODE=0
TX_LAST_ERROR_MESSAGE=""
TX_SNAPSHOT_FILE=""
TX_MODE=""

_tx_emit_marker() {
	local marker="${1:-UNKNOWN}"
	local msg="${2:-}"
	local level="${3:-INFO}"
	local ctx_prefix
	ctx_prefix=$(_log_prefix)
	_log_emit "$level" "[TX:${marker}] ${msg}" "$ctx_prefix" "true"
}

_tx_can_transition() {
	local from="${1:-}"
	local to="${2:-}"
	case "$from:$to" in
	":created" | \
		"created:preflight_ok" | \
		"created:applied" | \
		"created:failed" | \
		"preflight_ok:applied" | \
		"preflight_ok:failed" | \
		"applied:reload_ok" | \
		"applied:committed" | \
		"applied:failed" | \
		"reload_ok:committed" | \
		"reload_ok:failed" | \
		"failed:rolled_back")
		return 0
		;;
	esac
	return 1
}

tx_begin() {
	local domain="${1:-}"
	TX_STATE=""
	# shellcheck disable=SC2034
	TX_DOMAIN="$domain"
	# shellcheck disable=SC2034
	TX_LAST_ERROR_CODE=0
	# shellcheck disable=SC2034
	TX_LAST_ERROR_MESSAGE=""
	_tx_wal_append "BEGIN" "domain=${domain}"
	tx_transition "created" "transaction created"
}

tx_transition() {
	local to="${1:-}"
	local msg="${2:-}"
	local from="${TX_STATE:-}"
	if ! _tx_can_transition "$from" "$to"; then
		TX_LAST_ERROR_CODE="${ERR_TX_CONTRACT:-31}"
		TX_LAST_ERROR_MESSAGE="invalid transition ${from:-<none>} -> ${to}"
		_tx_emit_marker "CONTRACT_INVALID" "${TX_LAST_ERROR_MESSAGE}" "ERROR"
		return "${ERR_TX_CONTRACT:-31}"
	fi
	TX_STATE="$to"
	_tx_emit_marker "STATE_${to^^}" "${msg}"
	return 0
}

tx_fail() {
	local marker="${1:-FAILED}"
	local msg="${2:-transaction failed}"
	local code="${3:-1}"
	# shellcheck disable=SC2034
	TX_LAST_ERROR_CODE="$code"
	# shellcheck disable=SC2034
	TX_LAST_ERROR_MESSAGE="$msg"
	_tx_wal_append "FAIL" "marker=${marker};msg=${msg}"
	if [ "${TX_STATE:-}" != "failed" ]; then
		tx_transition "failed" "$msg" || true
	fi
	_tx_emit_marker "$marker" "$msg" "ERROR"
	return "$code"
}

tx_mark_commit() {
	_tx_wal_append "COMMIT" "transaction committed"
	_tx_emit_marker "APPLY_COMMIT" "transaction committed"
}

_tx_wal_append() {
	local state="${1:-UNKNOWN}"
	local msg="${2:-}"
	if [ "${DRY_RUN:-false}" = "true" ]; then return 0; fi
	if [ -z "${TX_WAL_FILE:-}" ]; then return 0; fi
	if ! _require_safe_path "$TX_WAL_FILE" "WAL"; then return 1; fi
	local ts
	ts=$(date +%s)
	if ! acquire_wal_lock; then return 1; fi
	trap 'release_wal_lock' RETURN
	printf '%s\n' "${ts}|${OP_ID:-NA}|${TX_DOMAIN:-}|${state}|${TX_MODE:-}|${TX_SNAPSHOT_FILE:-}|${msg}" >>"$TX_WAL_FILE"
	return 0
}

tx_wal_summary() {
	local file="${TX_WAL_FILE:-}"
	if [ -z "$file" ] || [ ! -f "$file" ]; then
		log_message ERROR "WAL 不存在: ${file}"
		return "${EX_DATAERR:-65}"
	fi
	local total=0
	local begin=0 commit=0 fail=0
	local -a last=()
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		total=$((total + 1))
		case "$line" in
		*"|BEGIN|"*) begin=$((begin + 1)) ;;
		*"|COMMIT|"*) commit=$((commit + 1)) ;;
		*"|FAIL|"*) fail=$((fail + 1)) ;;
		esac
		last+=("$line")
		if [ "${#last[@]}" -gt 10 ]; then
			last=("${last[@]:1}")
		fi
	done <"$file"
	if [ "${AUDIT_OUTPUT_JSON:-false}" = "true" ]; then
		printf '{"total":%s,"begin":%s,"commit":%s,"fail":%s,"last":%s}\n' \
			"$total" "$begin" "$commit" "$fail" "$(printf '%s\n' "${last[@]}" | jq -Rsc .)"
		return 0
	fi
	log_message INFO "WAL: total=${total}, begin=${begin}, commit=${commit}, fail=${fail}"
	if [ "${#last[@]}" -gt 0 ]; then
		printf '%s\n' "最近记录:"
		printf '%s\n' "${last[@]}"
	fi
	return 0
}

tx_wal_recover() {
	local file="${TX_WAL_FILE:-}"
	if [ -z "$file" ] || [ ! -f "$file" ]; then
		log_message ERROR "WAL 不存在: ${file}"
		return "${EX_DATAERR:-65}"
	fi
	local -A last_state=()
	local -A snap=()
	local -A mode=()
	local -A domain_map=()
	while IFS='|' read -r ts op state dom m s _msg; do
		[ -z "$op" ] && continue
		last_state["$op"]="$state"
		snap["$op"]="$s"
		mode["$op"]="$m"
		domain_map["$op"]="$dom"
	done <"$file"
	local ok=0 fail=0
	local op
	for op in "${!last_state[@]}"; do
		case "${last_state[$op]}" in
		COMMIT | FAIL) continue ;;
		esac
		if [ -n "${snap[$op]}" ] && [ -f "${snap[$op]}" ]; then
			local old_json
			old_json=$(cat "${snap[$op]}" 2>/dev/null || true)
			if [ -n "$old_json" ]; then
				if _rollback_project_transaction "${domain_map[$op]}" "$old_json" "${mode[$op]:-standard}"; then
					ok=$((ok + 1))
				else
					fail=$((fail + 1))
				fi
			else
				fail=$((fail + 1))
			fi
		else
			fail=$((fail + 1))
		fi
	done
	if [ "$fail" -gt 0 ]; then
		log_message ERROR "WAL 恢复完成: 成功=${ok}, 失败=${fail}"
		return "${EX_SOFTWARE:-70}"
	fi
	log_message INFO "WAL 恢复完成: 成功=${ok}, 失败=${fail}"
	return 0
}

preflight_hard_gate() {
	local context="${1:-unknown}"
	local now=0
	local max_age="${PREFLIGHT_GATE_CACHE_MAX_AGE_SECS:-20}"
	if [ "${PREFLIGHT_HARD_GATE:-true}" != "true" ]; then
		_tx_emit_marker "PRECHECK_BYPASS_DENIED" "hard gate disabled flag detected but blocked by policy" "ERROR"
		return "${ERR_CFG_VALIDATE:-20}"
	fi
	if ! [[ "$max_age" =~ ^[0-9]+$ ]]; then max_age=20; fi
	now=$(date +%s)
	if [ "${PREFLIGHT_GATE_CACHE_TS:-0}" -gt 0 ] && [ $((now - PREFLIGHT_GATE_CACHE_TS)) -le "$max_age" ]; then
		if [ "${PREFLIGHT_GATE_CACHE_RESULT:-1}" -eq 0 ]; then
			_tx_emit_marker "PRECHECK_OK" "context=${context}, source=cache"
			return 0
		fi
		_tx_emit_marker "PRECHECK_BLOCK" "context=${context}, source=cache" "ERROR"
		return "${ERR_CFG_VALIDATE:-20}"
	fi
	if run_preflight >/dev/null 2>&1; then
		PREFLIGHT_GATE_CACHE_TS="$now"
		PREFLIGHT_GATE_CACHE_RESULT=0
		_tx_emit_marker "PRECHECK_OK" "context=${context}, source=fresh"
		return 0
	fi
	PREFLIGHT_GATE_CACHE_TS="$now"
	PREFLIGHT_GATE_CACHE_RESULT=1
	_tx_emit_marker "PRECHECK_BLOCK" "context=${context}, source=fresh" "ERROR"
	return "${ERR_CFG_VALIDATE:-20}"
}

_json_sha256() {
	local payload="${1:-}"
	if [ -z "$payload" ]; then return 1; fi
	printf '%s' "$payload" | sha256sum | awk '{print $1}'
}

_validate_custom_directive_common() {
	local val="${1:-}"
	local silent="${2:-false}"
	local semicolon_re=';[[:space:]]*$'
	local full_re='^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]].*;[[:space:]]*$'
	local line=""
	local directive=""
	if [ -z "$val" ]; then
		[ "$silent" != "true" ] && log_message ERROR "自定义指令不能为空。"
		return 1
	fi
	if [[ "$val" == *$'\r'* ]]; then
		[ "$silent" != "true" ] && log_message ERROR "自定义指令不允许 CR 字符。"
		return 1
	fi
	if [[ "$val" == *"{"* ]] || [[ "$val" == *"}"* ]]; then
		[ "$silent" != "true" ] && log_message ERROR "禁止输入块级配置(包含 { 或 })。"
		return 1
	fi
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[ -z "$line" ] && continue
		[[ "$line" == \#* ]] && continue

		if [[ ! "$line" =~ $semicolon_re ]]; then
			[ "$silent" != "true" ] && log_message ERROR "指令必须以分号结尾: ${line}"
			return 1
		fi
		if [[ ! "$line" =~ $full_re ]]; then
			[ "$silent" != "true" ] && log_message ERROR "指令格式无效: ${line}"
			return 1
		fi

		directive="${line%%[[:space:]]*}"
		case "$directive" in
		client_max_body_size | proxy_read_timeout | proxy_send_timeout | proxy_connect_timeout | send_timeout | keepalive_timeout | add_header | proxy_set_header) ;;
		*)
			[ "$silent" != "true" ] && log_message ERROR "当前仅允许常用安全指令，拒绝未知指令: ${directive}"
			return 1
			;;
		esac
	done <<<"$val"
	return 0
}

_validate_custom_directive() {
	_validate_custom_directive_common "${1:-}" "false"
}

_is_valid_custom_directive_silent() {
	_validate_custom_directive_common "${1:-}" "true"
}

run_cmd() {
	local timeout_secs="${1:-15}"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$timeout_secs" "$@"
	else
		"$@"
	fi
}

_dry_run_exec() {
	if [ "${DRY_RUN:-false}" = "true" ]; then
		log_message INFO "[DRY-RUN] $*"
		if [ "${PLAN_MODE:-false}" = "true" ]; then
			_plan_add "$*"
		fi
		return 0
	fi
	"$@"
}

PLAN_ACTIONS=()

_plan_add() {
	PLAN_ACTIONS+=("$*")
}

_plan_flush() {
	if [ "${PLAN_MODE:-false}" != "true" ]; then return 0; fi
	if [ "${#PLAN_ACTIONS[@]}" -eq 0 ]; then
		log_message INFO "计划: 无变更"
		return 0
	fi
	log_message INFO "计划: ${#PLAN_ACTIONS[@]} 项"
	local item
	for item in "${PLAN_ACTIONS[@]}"; do
		printf '%s\n' "- ${item}"
	done
}

rm() { _dry_run_exec command rm "$@"; }
mv() { _dry_run_exec command mv "$@"; }
cp() { _dry_run_exec command cp "$@"; }
ln() { _dry_run_exec command ln "$@"; }
mkdir() { _dry_run_exec command mkdir "$@"; }
touch() { _dry_run_exec command touch "$@"; }
chmod() { _dry_run_exec command chmod "$@"; }
chown() { _dry_run_exec command chown "$@"; }
systemctl() { _dry_run_exec command systemctl "$@"; }
apt-get() { _dry_run_exec command apt-get "$@"; }
tar() { _dry_run_exec command tar "$@"; }
crontab() { _dry_run_exec command crontab "$@"; }

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

_log_context() {
	local func="" line="" i=2
	for ((i = 2; i < ${#FUNCNAME[@]}; i++)); do
		func="${FUNCNAME[$i]}"
		case "$func" in
		_log_emit | log_info | log_warn | log_error | log_success | log_message) continue ;;
		esac
		line="${BASH_LINENO[$((i - 1))]:-0}"
		printf '%s:%s\n' "${func:-main}" "${line:-0}"
		return 0
	done
	printf '%s:%s\n' "main" "0"
}

_log_prefix() {
	local func="${FUNCNAME[2]:-main}"
	local line="${BASH_LINENO[1]:-0}"
	printf '[%s:%s] ' "$func" "$line"
}

_log_emit() {
	local level="${1:-INFO}" message="${2:-}"
	local ctx_prefix="${3:-}"
	local force_stdout="${4:-false}"
	local op_tag
	op_tag="${OP_ID:-NA}"
	local log_line=""
	local output_line=""
	if [ "${LOG_FORMAT:-plain}" = "kv" ]; then
		local safe_msg
		safe_msg=${message//$'\n'/ }
		safe_msg=${safe_msg//"/\\"/}
		log_line="level=${level} op=${op_tag} msg=\"${safe_msg}\""
		output_line="$log_line"
	else
		log_line="[${level}] ${message}"
		output_line="[${level}] ${ctx_prefix}${message}"
		if [ "${LOG_WITH_OP_TAG:-false}" = "true" ]; then
			log_line="[${level}] [op:${op_tag}] ${message}"
			output_line="[${level}] [op:${op_tag}] ${ctx_prefix}${message}"
		fi
	fi
	if ! _log_should_emit "$level"; then return 0; fi
	_resolve_log_file
	printf '%s\n' "$log_line" >>"$LOG_FILE"
	if [ "${QUIET_MODE:-false}" = "true" ] && [ "$level" != "ERROR" ]; then
		return 0
	fi
	if [ "$IS_INTERACTIVE_MODE" = "true" ] || [ "$force_stdout" = "true" ]; then
		case "$level" in
		ERROR | WARN)
			if [ "$force_stdout" = "true" ]; then
				printf '%s\n' "$output_line"
			else
				printf '%s\n' "$output_line" >&2
			fi
			;;
		*) printf '%s\n' "$output_line" ;;
		esac
	fi
}

log_info() { _log_emit "INFO" "${1:-}" "stdout"; }
log_debug() { _log_emit "DEBUG" "${1:-}" "stdout"; }
log_warn() { _log_emit "WARN" "${1:-}" "stderr"; }
log_error() { _log_emit "ERROR" "${1:-}" "stderr"; }
log_success() { _log_emit "SUCCESS" "${1:-}" "stdout"; }

log_message() {
	local level="${1:-INFO}" message="${2:-}"
	local ctx_prefix
	ctx_prefix=$(_log_prefix)
	_log_emit "$level" "$message" "$ctx_prefix"
}

press_enter_to_continue() {
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
		log_warn "非交互模式：跳过等待"
		return 0
	fi
	if _read_input_prompt "\n${YELLOW}按 Enter 键继续...${NC}"; then
		return 0
	fi
	log_warn "无可用交互输入，已跳过等待"
	return 0
}

press_enter_to_exit() {
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
		log_warn "非交互模式：直接退出"
		exit 10
	fi
	if _read_input_prompt "\n${YELLOW}按 Enter 键退出...${NC}"; then
		exit 10
	fi
	log_warn "无可用交互输入，已直接退出"
	exit 10
}

prompt_menu_choice() {
	local range="${1:-}"
	local allow_empty="${2:-false}"
	local prompt_text="${BRIGHT_YELLOW}选项 [${range}]${NC} (Enter 返回): "
	local choice
	local range_start="" range_end="" range_is_numeric="false"
	if [[ "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
		range_start="${range%%-*}"
		range_end="${range##*-}"
		range_is_numeric="true"
	fi
	if [ "${JB_NONINTERACTIVE:-false}" != "true" ] && [ "$IS_INTERACTIVE_MODE" != "true" ]; then
		if [ -t 0 ] || _tty_available; then
			IS_INTERACTIVE_MODE="true"
			log_message WARN "检测到交互终端，已恢复交互模式"
		fi
	fi
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
		log_message ERROR "非交互模式无法选择菜单"
		return 1
	fi
	while true; do
		if _read_input_prompt "$prompt_text"; then
			choice="$REPLY"
		else
			if [ "$allow_empty" = "true" ]; then
				printf '%b' "\n"
				return 0
			fi
			log_message ERROR "无可用交互输入(缺少TTY)"
			return 1
		fi
		if [ -z "$choice" ]; then
			if [ "$allow_empty" = "true" ]; then
				printf '%b' "\n"
				return 0
			fi
			printf '%b' "${YELLOW}请选择一个选项。${NC}\n" >&2
			continue
		fi
		if [ "$range_is_numeric" = "true" ]; then
			if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
				log_message ERROR "无效选择"
				continue
			fi
			if [ "$choice" -lt "$range_start" ] || [ "$choice" -gt "$range_end" ]; then
				log_message ERROR "无效选择"
				continue
			fi
			printf '%s\n' "$choice"
			return 0
		fi
		if [[ "$choice" =~ ^[0-9A-Za-z]+$ ]]; then
			printf '%s\n' "$choice"
			return 0
		fi
		log_message ERROR "无效选择"
	done
}

prompt_input() {
	local prompt="${1:-}" default="${2:-}" regex="${3:-}" error_msg="${4:-}" allow_empty="${5:-false}" visual_default="${6:-}"
	while true; do
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
			val="$default"
			if [[ -z "$val" && "$allow_empty" = "false" ]]; then
				log_message ERROR "非交互缺失: $prompt"
				return 1
			fi
		else
			local disp=""
			if [ -n "$visual_default" ]; then
				disp=" [默认: ${visual_default}]"
			elif [ -n "$default" ]; then
				disp=" [默认: ${default}]"
			fi
			if _read_input_prompt "${BRIGHT_YELLOW}${prompt}${NC}${disp}: "; then
				val="$REPLY"
			else
				log_message ERROR "无可用交互输入(缺少TTY)"
				return 1
			fi
			val=${val:-$default}
		fi
		if [[ -z "$val" && "$allow_empty" = "true" ]]; then
			printf '%b' "\n"
			return 0
		fi
		if [[ -z "$val" ]]; then
			log_message ERROR "输入不能为空"
			[ "$IS_INTERACTIVE_MODE" = "false" ] && return 1
			continue
		fi
		if [[ -n "$regex" && ! "$val" =~ $regex ]]; then
			log_message ERROR "${error_msg:-格式错误}"
			[ "$IS_INTERACTIVE_MODE" = "false" ] && return 1
			continue
		fi
		printf '%s\n' "$val"
		return 0
	done
}

_prompt_secret() {
	local prompt="${1:-}" val=""
	if [ "${JB_NONINTERACTIVE:-false}" = "true" ] || [ "$IS_INTERACTIVE_MODE" != "true" ]; then
		log_message ERROR "非交互模式禁止读取密文输入"
		return 1
	fi
	printf '%b' "${BRIGHT_YELLOW}${prompt} (无屏幕回显): ${NC}" >&2
	if _read_secret_input_prompt ""; then
		val="$REPLY"
	else
		log_message ERROR "无可用交互输入(缺少TTY)"
		return 1
	fi
	printf '%b' "\n" >&2
	printf '%s\n' "$val"
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
	local str="${1:-}"
	local len=${#str}
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
	# shellcheck disable=SC2034
	TG_BOT_TOKEN="$token"
	# shellcheck disable=SC2034
	TG_CHAT_ID="$chat"
	# shellcheck disable=SC2034
	SERVER_NAME="$server"
	return 0
}

_mask_ip() {
	local ip="${1:-}"
	if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		IFS='.' read -r a b _c _d <<<"$ip"
		printf '%s\n' "${a}.${b}.*.*"
	elif [[ "$ip" =~ .*:.* ]]; then
		IFS=':' read -r a b _rest <<<"$ip"
		printf '%s\n' "${a}:${b}::***"
	else
		printf '%s\n' "***"
	fi
}

confirm_or_cancel() {
	local prompt_text="${1:-}" default_yesno="${2:-y}"
	if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
		local hint="([y]/n)"
		[ "$default_yesno" = "n" ] && hint="(y/[N])"
		local c
		while true; do
			if _read_input_prompt "${BRIGHT_YELLOW}${prompt_text} ${hint}: ${NC}"; then
				c="$REPLY"
			else
				log_message ERROR "无可用交互输入(缺少TTY)"
				return 1
			fi
			if [ -z "$c" ]; then
				[ "$default_yesno" = "y" ] && return 0 || return 1
			fi
			case "$c" in
			y | Y | yes | YES | Yes) return 0 ;;
			n | N | no | NO | No) return 1 ;;
			*)
				log_message WARN "无效输入: '${c}'，请输入 y 或 n。"
				continue
				;;
			esac
		done
	fi
	log_message ERROR "非交互需确认: '$prompt_text',已取消。"
	return 1
}

_get_cf_allow_file() {
	local f="/etc/nginx/snippets/cf_allow.conf"
	if [ -f "$f" ] && [ -s "$f" ]; then
		printf '%s\n' "$f"
		return 0
	fi
	printf '%s\n' ""
	return 1
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
	log_message INFO "未检测到 Cloudflare IP 库，自动执行更新。"
	_update_cloudflare_ips || return 1
	return 0
}

_detect_web_service() {
	if ! command -v systemctl &>/dev/null; then return; fi
	local svc
	for svc in nginx apache2 httpd caddy; do
		if systemctl is-active --quiet "$svc"; then
			printf '%s\n' "$svc"
			return
		fi
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

_atomic_write_file() {
	local target="${1:-}"
	local mode="${2:-}"
	local dir="" tmp="" base=""
	if [ -z "$target" ]; then return 1; fi
	if [ "${DRY_RUN:-false}" = "true" ]; then
		log_message INFO "[DRY-RUN] write ${target}"
		if [ "${PLAN_MODE:-false}" = "true" ]; then
			_plan_add "write ${target}"
		fi
		return 0
	fi
	dir=$(dirname "$target")
	base=$(basename "$target")
	mkdir -p "$dir"
	tmp=$(mktemp "${dir}/.${base}.tmp.XXXXXX")
	chmod 600 "$tmp" 2>/dev/null || true
	cat >"$tmp"
	if [ -n "$mode" ]; then
		chmod "$mode" "$tmp" 2>/dev/null || true
	fi
	mv "$tmp" "$target"
}

_atomic_append_file() {
	local target="${1:-}"
	local append_content="${2:-}"
	local current=""
	if [ -z "$target" ]; then return 1; fi
	if [ "${DRY_RUN:-false}" = "true" ]; then
		log_message INFO "[DRY-RUN] append ${target}"
		if [ "${PLAN_MODE:-false}" = "true" ]; then
			_plan_add "append ${target}"
		fi
		return 0
	fi
	if [ -f "$target" ]; then
		current=$(cat "$target" 2>/dev/null || true)
	fi
	if [ -n "$current" ]; then
		printf '%s\n%s' "$current" "$append_content" | _atomic_write_file "$target"
	else
		printf '%s\n' "$append_content" | _atomic_write_file "$target"
	fi
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

_is_glob_domain_expr() {
	local expr="${1:-}"
	[[ "$expr" == *"*"* || "$expr" == *"?"* || "$expr" == *","* || "$expr" == *"!"* ]]
}

_glob_to_regex() {
	local glob_pat="${1:-}"
	printf '%s' "$glob_pat" | sed -e 's/[.[\^$+(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g' -e '1s/^/^/' -e '$s/$/$/'
}

_domain_matches_glob() {
	local domain="${1:-}"
	local pattern="${2:-}"
	local re=""
	[ -z "$domain" ] || [ -z "$pattern" ] && return 1
	re=$(_glob_to_regex "$pattern")
	[[ "$domain" =~ $re ]]
}

_list_http_project_domains() {
	jq -r '.[].domain // empty' "$PROJECTS_METADATA_FILE" 2>/dev/null | sed '/^$/d' | sort -u
}

_match_domains_by_glob_expr() {
	local expr="${1:-}"
	local token=""
	local domain=""
	local -a positives=()
	local -a negatives=()
	local include="false"
	local matched="false"

	expr="${expr// /}"
	[ -z "$expr" ] && return 1

	IFS=',' read -r -a tokens <<<"$expr"
	for token in "${tokens[@]}"; do
		[ -z "$token" ] && continue
		if [[ "$token" == !* ]]; then
			negatives+=("${token#!}")
		else
			positives+=("$token")
		fi
	done

	while IFS= read -r domain; do
		[ -z "$domain" ] && continue
		include="false"
		if [ "${#positives[@]}" -eq 0 ]; then
			include="true"
		else
			for token in "${positives[@]}"; do
				if _domain_matches_glob "$domain" "$token"; then
					include="true"
					break
				fi
			done
		fi
		if [ "$include" != "true" ]; then
			continue
		fi
		for token in "${negatives[@]}"; do
			if _domain_matches_glob "$domain" "$token"; then
				include="false"
				break
			fi
		done
		if [ "$include" = "true" ]; then
			matched="true"
			printf '%s\n' "$domain"
		fi
	done < <(_list_http_project_domains)

	[ "$matched" = "true" ]
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

_is_valid_location_path() {
	local p="${1:-}"
	if [ -z "$p" ] || [ "$p" = "/" ]; then return 1; fi
	[[ "$p" =~ ^/[A-Za-z0-9._~/%:+-]*$ ]]
}

_is_valid_mcp_token() {
	local token="${1:-}"
	if [ -z "$token" ]; then return 1; fi
	if [ "${#token}" -lt 16 ] || [ "${#token}" -gt 128 ]; then return 1; fi
	[[ "$token" =~ ^[A-Za-z0-9._~!@#%^*+=:-]+$ ]]
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
		# shellcheck disable=SC1091
		. /etc/os-release
		if [[ "${ID:-}" != "debian" && "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
			printf '%b' "${RED}⚠️ 警告: 检测到非 Debian/Ubuntu 系统 (${NAME:-unknown}).${NC}\n"
			if [ "$IS_INTERACTIVE_MODE" = "true" ]; then
				if ! confirm_or_cancel "是否尝试继续?"; then return 1; fi
			else
				log_message WARN "非 Debian 系统,尝试强制运行..."
			fi
		fi
	fi
	return 0
}
