#!/usr/bin/env bash
# 🚀 安全版交互式卸载 SSL 脚本（可备份证书）

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"
BACKUP_ROOT="/root/ssl_backup"
DRY_RUN="false"
declare -a RUN_ARGS=()

log_info() { printf '%s\n' "$*"; }
log_warn() { printf '%s\n' "$*" >&2; }
log_err() { printf '%s\n' "$*" >&2; }

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

run_destructive_cmd() {
	if [ "$DRY_RUN" = "true" ]; then
		log_info "[DRY-RUN] $*"
		return 0
	fi
	"$@"
}

high_risk_guard() {
	local action_title="${1:-高风险操作}"
	local impact_summary="${2:-该操作不可逆，请谨慎确认。}"
	local reply=""
	if [ "${JB_NONINTERACTIVE}" = "true" ]; then
		log_warn "非交互模式：高风险操作默认取消 (${action_title})"
		return 1
	fi
	printf '%s\n' "⚠ 高风险操作: ${action_title}" >&2
	printf '%s\n' "影响摘要: ${impact_summary}" >&2
	read -r -p "是否继续查看二次确认? [y/N]: " reply </dev/tty
	case "${reply,,}" in
	y | yes) ;;
	*)
		log_warn "已取消操作。"
		return 1
		;;
	esac
	read -r -p "二次确认：请输入 yes 继续执行: " reply </dev/tty
	if [ "${reply,,}" != "yes" ]; then
		log_warn "已取消操作。"
		return 1
	fi
	return 0
}

ensure_safe_path() {
	local target="$1"
	if [ -z "${target}" ] || [ "${target}" = "/" ]; then
		log_err "拒绝对危险路径执行破坏性操作: '${target}'"
		exit 1
	fi
}

self_elevate_or_die() {
	if [ "$(id -u)" -eq 0 ]; then
		return 0
	fi

	if ! command -v sudo >/dev/null 2>&1; then
		log_err "未安装 sudo，无法自动提权。"
		exit 1
	fi

	case "$0" in
	/dev/fd/* | /proc/self/fd/*)
		local tmp_script
		tmp_script=$(mktemp /tmp/rm_cert_module.XXXXXX.sh)
		cat <"$0" >"$tmp_script"
		chmod 700 "$tmp_script" || true
		if [ "${JB_NONINTERACTIVE}" = "true" ]; then
			if sudo -n true 2>/dev/null; then
				exec sudo -n -E bash "$tmp_script" "$@"
			fi
			log_err "非交互模式下无法自动提权（需要免密 sudo）。"
			exit 1
		fi
		exec sudo -E bash "$tmp_script" "$@"
		;;
	*)
		if [ "${JB_NONINTERACTIVE}" = "true" ]; then
			if sudo -n true 2>/dev/null; then
				exec sudo -n -E bash "$0" "$@"
			fi
			log_err "非交互模式下无法自动提权（需要免密 sudo）。"
			exit 1
		fi
		exec sudo -E bash "$0" "$@"
		;;
	esac
}

self_elevate_or_die "$@"
parse_dry_run_args "$@"
set -- "${RUN_ARGS[@]}"

log_info "=============================="
log_info "⚠️  开始卸载 SSL 脚本相关内容"
log_info "=============================="

if ! high_risk_guard "卸载证书管理相关组件" "将删除 acme.sh、cert 模块文件、可选删除域名证书目录并清理续期任务。"; then
	log_info "已取消执行。"
	exit 0
fi

# 1️⃣ 删除 acme.sh
if [ -d "$HOME/.acme.sh" ]; then
	log_info "🔹 删除 acme.sh 目录..."
	ensure_safe_path "$HOME/.acme.sh"
	run_destructive_cmd rm -rf "$HOME/.acme.sh"
else
	log_info "ℹ️ acme.sh 目录不存在，跳过"
fi

# 2️⃣ 删除脚本文件
SCRIPT_PATH="/opt/vps_install_modules/cert.sh"
if [ -f "$SCRIPT_PATH" ]; then
	log_info "🔹 删除脚本文件 $SCRIPT_PATH ..."
	ensure_safe_path "$SCRIPT_PATH"
	run_destructive_cmd rm -f "$SCRIPT_PATH"
else
	log_info "ℹ️ 脚本文件不存在，跳过"
fi

# 3️⃣ 交互式输入要删除的域名证书目录
DOMAINS=()
if [ "${JB_NONINTERACTIVE}" = "true" ]; then
	log_warn "非交互模式：跳过证书删除步骤"
	DOMAINS=()
else
	while true; do
		read -r -p "请输入要卸载证书的域名（回车结束输入）: " DOMAIN </dev/tty
		if [[ -z "$DOMAIN" ]]; then
			break
		fi
		DOMAINS+=("$DOMAIN")
	done
fi

if [ ${#DOMAINS[@]} -eq 0 ]; then
	log_info "ℹ️ 未输入任何域名，跳过证书删除步骤。"
else
	mkdir -p "$BACKUP_ROOT"

	for DOMAIN in "${DOMAINS[@]}"; do
		CERT_DIR="/etc/ssl/$DOMAIN"
		if [ -d "$CERT_DIR" ]; then
			if [ "${JB_NONINTERACTIVE}" = "true" ]; then
				BACKUP=""
			else
				read -r -p "是否备份 $DOMAIN 证书到 $BACKUP_ROOT/$DOMAIN ? [y/N]: " BACKUP </dev/tty
			fi
			if [[ "$BACKUP" =~ ^[Yy]$ ]]; then
				DEST="$BACKUP_ROOT/$DOMAIN"
				mkdir -p "$DEST"
				cp -r "$CERT_DIR"/* "$DEST"/
				log_info "✅ 已备份 $DOMAIN 证书到 $DEST"
			fi

			log_info "🔹 删除证书目录 $CERT_DIR ..."
			ensure_safe_path "$CERT_DIR"
			run_destructive_cmd rm -rf "$CERT_DIR"
		else
			log_info "ℹ️ 证书目录 $CERT_DIR 不存在，跳过"
		fi
	done
fi

# 4️⃣ 清理 crontab 自动续期任务
log_info "🔹 清理 acme.sh 自动续期 crontab..."
if command -v crontab >/dev/null 2>&1; then
	current_cron="$(crontab -l 2>/dev/null || true)"
	if [ -n "${current_cron}" ]; then
		filtered_cron="$(printf '%s\n' "${current_cron}" | grep -v 'acme.sh' || true)"
		if [ -n "${filtered_cron}" ]; then
			if [ "$DRY_RUN" = "true" ]; then
				log_info "[DRY-RUN] crontab 更新（移除 acme.sh 任务）"
			else
				printf '%s\n' "${filtered_cron}" | crontab -
			fi
		else
			if [ "$DRY_RUN" = "true" ]; then
				log_info "[DRY-RUN] crontab -r"
			else
				crontab -r 2>/dev/null || true
			fi
		fi
	else
		log_info "ℹ️ 当前用户无 crontab，跳过"
	fi
else
	log_warn "⚠️ 未检测到 crontab 命令，跳过自动续期任务清理"
fi

# 5️⃣ 卸载 socat（可选）
if command -v socat &>/dev/null; then
	if command -v apt &>/dev/null; then
		run_destructive_cmd apt remove -y socat
	elif command -v yum &>/dev/null; then
		run_destructive_cmd yum remove -y socat
	elif command -v dnf &>/dev/null; then
		run_destructive_cmd dnf remove -y socat
	else
		log_warn "⚠️ 未知包管理器，无法自动卸载 socat"
	fi
else
	log_info "ℹ️ socat 未安装，跳过"
fi

log_info "=============================="
log_info "✅ 卸载完成！"
log_info "📂 备份目录（如有备份）：$BACKUP_ROOT"
log_info "=============================="
