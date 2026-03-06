#!/usr/bin/env bash
# =============================================
# 🚀 VPS GitHub 一键脚本拉取入口 (彻底修正版)
# =============================================

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"
DOWNLOAD_ONLY="false"
BASE_URL="${JB_BASE_URL:-https://raw.githubusercontent.com/wx233Github/jaoeng/main}"

log_info() { printf '%s\n' "$*"; }
log_warn() { printf '%s\n' "$*" >&2; }
log_err() { printf '%s\n' "$*" >&2; }

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
		tmp_script=$(mktemp /tmp/rm_install_module.XXXXXX.sh)
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

parse_cli_flags() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--download-only)
			DOWNLOAD_ONLY="true"
			;;
		--base-url=*)
			BASE_URL="${1#--base-url=}"
			;;
		esac
		shift
	done
}

parse_cli_flags "$@"

# 格式: "显示名:真实路径"
SCRIPTS=(
	"主程序入口:install.sh"
	"Docker 管理:docker.sh"
	"Nginx 管理:nginx.sh"
	"证书管理:cert.sh"
	"BBR ACE 网络调优:tools/bbr_ace.sh"
	"Watchtower 管理:tools/Watchtower.sh"
	"删除证书:rm/rm_cert.sh"
)

# 下载脚本（打印信息，不返回文件名）
download() {
	local file="$1"             # GitHub路径，例如 rm/rm_cert.sh
	local url="$BASE_URL/$file" # 完整URL
	local save_name
	save_name=$(basename "$file") # 本地保存名 rm_cert.sh
	if [ -z "$save_name" ]; then
		log_err "保存文件名为空，拒绝下载"
		exit 1
	fi

	# 下载
	if command -v wget >/dev/null 2>&1; then
		wget -qO "$save_name" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$save_name" "$url"
	else
		log_err "❌ 系统缺少 wget 或 curl"
		exit 1
	fi

	chmod +x "$save_name"
	log_info "📥 已保存为 $save_name"
}

# 主菜单
main_menu() {
	while true; do
		log_info "================================"
		log_info "  🚀 VPS GitHub 一键脚本入口"
		log_info "================================"
		if [ "$DOWNLOAD_ONLY" = "true" ]; then
			log_info "  模式: 仅下载，不执行"
		fi
		log_info "0. 退出"
		i=1
		for entry in "${SCRIPTS[@]}"; do
			name="${entry%%:*}" # 显示名
			log_info "$i. $name"
			((i++))
		done
		if [ "${JB_NONINTERACTIVE}" = "true" ]; then
			log_warn "非交互模式：已退出"
			exit 0
		fi
		read -r -p "请选择要执行的脚本 (0-${#SCRIPTS[@]}，回车退出): " choice </dev/tty

		if [ -z "$choice" ]; then
			log_info "👋 回车退出"
			exit 0
		elif ! [[ "$choice" =~ ^[0-9]+$ ]]; then
			log_warn "❌ 请输入数字选项"
			continue
		elif [ "$choice" -eq 0 ]; then
			log_info "👋 退出"
			exit 0
		elif [ "$choice" -ge 1 ] && [ "$choice" -le "${#SCRIPTS[@]}" ]; then
			entry="${SCRIPTS[$((choice - 1))]}"
			name="${entry%%:*}"             # 显示名
			file="${entry##*:}"             # GitHub路径
			script_file=$(basename "$file") # 本地文件名

			log_info "🔽 正在拉取 [$name] ..."
			download "$file" # 仅打印信息
			if [ "$DOWNLOAD_ONLY" = "true" ]; then
				log_info "📦 已下载 [$name]，按模式配置不自动执行。"
			else
				log_info "🚀 执行 [$name]"
				./"$script_file"
			fi
		else
			log_warn "❌ 无效选项，请重新输入"
		fi
		log_info "" # 换行美化
	done
}

# 启动菜单
main_menu
