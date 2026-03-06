#!/usr/bin/env bash
# =============================================================
# 🚀 Docker 管理模块 (v4.3.9-菜单逻辑与交互优化)
# - 优化: 将“安装”与“卸载/重装”合并为统一的“安装管理”菜单，简化主界面。
# - 新增: 为安装、重装和卸载操作增加了 [y/n] 确认步骤，防止误操作。
# - 修复: 修正了从子菜单返回主菜单时需要按两次回车的交互问题。
# - 更新: 脚本版本号。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.3.9"

# --- 严格模式与环境设定 ---
set -euo pipefail
IFS=$'\n\t'
export LANG="${LANG:-en_US.UTF_8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
	# shellcheck source=/dev/null
	source "$UTILS_PATH"
else
	RED='\e[0;31m'
	GREEN='\e[0;32m'
	YELLOW='\e[0;33m'
	NC='\e[0m'
	log_err() { echo -e "${RED}[错误] $*${NC}" >&2; }
	log_warn() { echo -e "${YELLOW}[警告] $*${NC}" >&2; }
	log_info() { echo -e "[信息] $*"; }
	log_success() { echo -e "${GREEN}[成功] $*${NC}"; }
	_render_menu() {
		local title="$1"
		shift
		echo "--- $title ---"
		printf " %s\n" "$@"
	}
	press_enter_to_continue() {
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
			log_warn "非交互模式：跳过等待"
			return 0
		fi
		read -r -p "按 Enter 继续..." </dev/tty
	}
	confirm_action() {
		local prompt="$1"
		local choice
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
			log_warn "非交互模式：默认确认"
			return 0
		fi
		read -r -p "${prompt} ([y]/n): " choice </dev/tty
		case "$choice" in n | N) return 1 ;; *) return 0 ;; esac
	}
	_prompt_for_menu_choice() {
		read -r -p "> 选项: " choice </dev/tty
		echo "$choice"
	}
	log_warn "未找到通用工具库 $UTILS_PATH，已启用内置兼容函数。"
fi

if ! declare -f run_with_sudo &>/dev/null; then
	run_with_sudo() {
		if [ "$(id -u)" -eq 0 ]; then
			"$@"
			return $?
		fi
		if ! command -v sudo >/dev/null 2>&1; then
			log_err "需要 root 权限执行该操作，且未安装 sudo。"
			return 1
		fi
		if sudo -n true 2>/dev/null; then
			sudo -n "$@"
			return $?
		fi
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
			log_err "非交互模式下无法获取 sudo 权限。"
			return 1
		fi
		sudo "$@"
	}
fi

if ! declare -f should_clear_screen &>/dev/null; then
	declare -A DOCKER_SMART_CLEAR_SEEN=()
	should_clear_screen() {
		local menu_key="${1:-docker:default}"
		local mode="${JB_CLEAR_MODE:-}"
		if [ -z "$mode" ]; then
			if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then
				mode="full"
			else
				mode="off"
			fi
		fi

		case "$mode" in
		off | false) return 1 ;;
		full | true) return 0 ;;
		smart)
			if [ -n "${DOCKER_SMART_CLEAR_SEEN[$menu_key]+x}" ]; then
				return 1
			fi
			DOCKER_SMART_CLEAR_SEEN["$menu_key"]=1
			return 0
			;;
		*) return 1 ;;
		esac
	}
fi

ensure_safe_path() {
	local target="$1"
	if [ -z "${target}" ] || [ "${target}" = "/" ]; then
		log_err "拒绝对危险路径执行破坏性操作: '${target}'"
		return 1
	fi
	return 0
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
		tmp_script=$(mktemp /tmp/docker_module.XXXXXX.sh)
		cat <"$0" >"$tmp_script"
		chmod 700 "$tmp_script" || true
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
			if sudo -n true 2>/dev/null; then
				exec sudo -n -E bash "$tmp_script" "$@"
			fi
			log_err "非交互模式下无法自动提权（需要免密 sudo）。"
			exit 1
		fi
		exec sudo -E bash "$tmp_script" "$@"
		;;
	*)
		if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
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

# --- 全局状态变量 ---
DOCKER_INSTALLED="false"
DOCKER_SERVICE_STATUS="unknown"
DOCKER_VERSION=""
COMPOSE_VERSION=""
DOCKER_INSTALL_URL=""
DISTRO=""
CODENAME=""
DOCKER_REPO_CODENAME=""
DRY_RUN="false"
declare -a RUN_ARGS=()

# --- Docker 安装源配置 ---
readonly DOCKER_URL_OFFICIAL="https://download.docker.com"
readonly DOCKER_URL_MIRROR="https://mirrors.ustc.edu.cn/docker-ce"

# --- 核心辅助函数 ---

execute_with_spinner() {
	local message="$1"
	shift
	local command_to_run=("$@")
	local LOG_FILE
	LOG_FILE=$(mktemp)
	echo -n "- ${message}"
	"${command_to_run[@]}" >"$LOG_FILE" 2>&1 &
	local pid=$!
	local spinstr="|/-\\"
	while ps -p $pid >/dev/null; do
		local temp=${spinstr#?}
		printf " [%c]  " "$spinstr"
		spinstr=$temp${spinstr%"$temp"}
		sleep 0.1
		printf "\b\b\b\b\b"
	done
	wait $pid
	local rc=$?
	printf "     \b\b\b\b\b"
	if [ $rc -eq 0 ]; then
		echo -e "${GREEN}✓ 完成${NC}"
	else
		echo -e "${RED}✗ 失败${NC}"
		echo "-------------------- 错误日志 --------------------"
		cat "$LOG_FILE"
		echo "--------------------------------------------------"
		log_err "操作失败，脚本已终止。请检查上述错误日志。"
		rm -f "$LOG_FILE"
		exit 1
	fi
	rm -f "$LOG_FILE"
}

update_docker_daemon_config() {
	local daemon_file="$1"
	local mirrors_json="$2"
	local tmp_file
	tmp_file=$(mktemp "/tmp/docker_daemon_XXXXXX")

	if run_with_sudo test -s "$daemon_file" && run_with_sudo cat "$daemon_file" | jq --argjson mirrors "$mirrors_json" '.["registry-mirrors"] = $mirrors' >"$tmp_file" 2>/dev/null; then
		:
	else
		jq -n --argjson mirrors "$mirrors_json" '{"registry-mirrors": $mirrors}' >"$tmp_file"
	fi

	run_with_sudo install -m 0644 "$tmp_file" "$daemon_file"
	rm -f "$tmp_file"
}

install_docker_gpg_key() {
	local gpg_url="$1"
	local output_file="$2"
	local tmp_file
	tmp_file=$(mktemp "/tmp/docker_gpg_XXXXXX")
	curl -fsSL "$gpg_url" -o "$tmp_file"
	run_with_sudo gpg --dearmor --yes -o "$output_file" "$tmp_file"
	rm -f "$tmp_file"
}

write_docker_apt_source() {
	local content="$1"
	local target_file="$2"
	local tmp_file
	tmp_file=$(mktemp "/tmp/docker_apt_source_XXXXXX")
	printf '%s\n' "$content" >"$tmp_file"
	run_with_sudo install -m 0644 "$tmp_file" "$target_file"
	rm -f "$tmp_file"
}

pre_check_dependencies() {
	local missing_deps=()
	if ! command -v curl &>/dev/null; then missing_deps+=("curl"); fi
	if ! command -v jq &>/dev/null; then missing_deps+=("jq"); fi

	if [ ${#missing_deps[@]} -gt 0 ]; then
		log_warn "核心依赖 '${missing_deps[*]}' 未找到，正在尝试自动安装..."
		execute_with_spinner "更新软件源..." run_with_sudo apt-get update -qq
		execute_with_spinner "安装缺失的依赖: ${missing_deps[*]}..." run_with_sudo apt-get install -y "${missing_deps[@]}"
	fi
}

init_runtime() {
	sanitize_noninteractive_flag
}

get_docker_status() {
	if command -v docker &>/dev/null; then
		DOCKER_INSTALLED="true"
		DOCKER_SERVICE_STATUS=$(systemctl is-active docker.service 2>/dev/null || echo "unknown")
		DOCKER_VERSION=$(docker --version)
		COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "未安装")
	else
		DOCKER_INSTALLED="false"
		DOCKER_SERVICE_STATUS="not-installed"
		DOCKER_VERSION=""
		COMPOSE_VERSION=""
	fi
}

determine_install_source() {
	log_info "🌐 正在检测最佳 Docker 安装源..."
	local curl_output
	curl_output=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$DOCKER_URL_OFFICIAL")
	if [[ "$curl_output" == "200" || "$curl_output" == "301" || "$curl_output" == "302" ]]; then
		log_success "-> Docker 官方源 (${DOCKER_URL_OFFICIAL}) 连接成功。"
		DOCKER_INSTALL_URL=$DOCKER_URL_OFFICIAL
	else
		log_warn "-> Docker 官方源连接失败 (状态码: $curl_output)。"
		if confirm_action "🤔 是否尝试切换到国内镜像源 (USTC) 进行安装？"; then
			DOCKER_INSTALL_URL=$DOCKER_URL_MIRROR
			log_success "-> 已切换到国内镜像源: ${DOCKER_INSTALL_URL}"
		else
			log_warn "用户取消切换，将继续尝试使用官方源。"
			DOCKER_INSTALL_URL=$DOCKER_URL_OFFICIAL
		fi
	fi
}

check_distro() {
	if [ -f /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		case "$ID" in
		ubuntu | debian)
			DISTRO=$ID
			CODENAME=$VERSION_CODENAME
			if [ -z "$CODENAME" ]; then
				log_err "无法从此系统获取到发行版代号 (Version Codename)，无法继续。"
				exit 1
			fi
			DOCKER_REPO_CODENAME="$CODENAME"
			;;
		*)
			log_err "不支持的系统: $ID。"
			exit 1
			;;
		esac
	else
		log_err "无法检测到系统发行版信息。"
		exit 1
	fi
}

cleanup_docker_apt_source() {
	ensure_safe_path "/etc/apt/sources.list.d/docker.list"
	ensure_safe_path "/etc/apt/keyrings/docker.gpg"
	run_destructive_with_sudo rm -f /etc/apt/sources.list.d/docker.list
	run_destructive_with_sudo rm -f /etc/apt/keyrings/docker.gpg
}

resolve_docker_repo_codename() {
	DOCKER_REPO_CODENAME="$CODENAME"
	if [ "$DISTRO" = "debian" ] && [ "$CODENAME" = "trixie" ]; then
		log_warn "检测到 Debian trixie，Docker 官方源可能尚未提供该代号，尝试回退到 bookworm 仓库。"
		DOCKER_REPO_CODENAME="bookworm"
	fi
}

write_docker_repo_and_update() {
	local docker_list_content
	docker_list_content="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_INSTALL_URL}/linux/${DISTRO} ${DOCKER_REPO_CODENAME} stable"
	execute_with_spinner "添加 Docker 软件源 (${DISTRO}/${DOCKER_REPO_CODENAME})..." write_docker_apt_source "$docker_list_content" "/etc/apt/sources.list.d/docker.list"
	execute_with_spinner "再次更新软件源..." run_with_sudo apt-get update -qq
}

ensure_docker_repo_ready() {
	if write_docker_repo_and_update; then
		return 0
	fi

	if [ "$DISTRO" = "debian" ] && [ "$DOCKER_REPO_CODENAME" = "bookworm" ]; then
		log_warn "bookworm 回退源仍不可用，尝试使用 bullseye 兼容仓库。"
		DOCKER_REPO_CODENAME="bullseye"
		write_docker_repo_and_update
		return $?
	fi

	return 1
}

uninstall_docker() {
	if ! confirm_action "⚠️  确定要卸载 Docker 和 Compose 吗？这将删除所有相关软件包！"; then
		log_warn "🚫 操作已取消。"
		return 1
	fi

	log_info "🧹 开始卸载..."
	execute_with_spinner "停止 Docker 服务..." run_destructive_with_sudo systemctl stop docker.service docker.socket
	execute_with_spinner "卸载 Docker 和 Compose 软件包..." run_destructive_with_sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
	execute_with_spinner "清理残留软件包配置..." run_destructive_with_sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
	execute_with_spinner "自动移除不再需要的依赖..." run_destructive_with_sudo apt-get autoremove -y --purge

	if confirm_action "是否同时删除 Docker 数据目录 (镜像, 容器, 数据卷)? 这是一个【不可逆】操作！"; then
		ensure_safe_path "/var/lib/docker"
		ensure_safe_path "/var/lib/containerd"
		ensure_safe_path "/etc/docker"
		execute_with_spinner "删除 Docker 数据和配置目录..." run_destructive_with_sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
	fi
	ensure_safe_path "/etc/apt/keyrings/docker.gpg"
	ensure_safe_path "/etc/apt/sources.list.d/docker.list"
	execute_with_spinner "清理 APT 源..." run_destructive_with_sudo rm -rf /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list

	log_info "检查 docker 用户组残留..."
	if getent group docker >/dev/null; then
		local users_in_docker_group
		users_in_docker_group=$(getent group docker | cut -d: -f4 | sed 's/,/ /g')
		if [ -n "$users_in_docker_group" ]; then
			log_warn "以下用户仍在 'docker' 组中: ${users_in_docker_group}"
			if confirm_action "是否将他们从 'docker' 组中移除?"; then
				for user in $users_in_docker_group; do
					execute_with_spinner "从 'docker' 组中移除用户 '$user'..." run_destructive_with_sudo gpasswd -d "$user" docker
				done
			fi
		fi
		if [ -z "$(getent group docker | cut -d: -f4)" ]; then
			execute_with_spinner "删除空的 'docker' 用户组..." run_destructive_with_sudo groupdel docker
		fi
	fi
	log_success "✅ Docker 和 Compose 已成功卸载。"
	return 0
}

configure_docker_mirror() {
	local choice_made=false
	if [[ "${1:-}" == "auto" ]]; then
		if [[ "$DOCKER_INSTALL_URL" != "$DOCKER_URL_MIRROR" ]]; then return 0; fi
		log_warn "检测到您使用了国内安装源，强烈推荐配置 Docker Hub 镜像加速器。"
		if confirm_action "   是否立即配置？"; then choice_made=true; fi
	else
		if confirm_action "🤔 是否需要为 Docker Hub 配置国内镜像加速器？"; then choice_made=true; fi
	fi

	if [[ "$choice_made" == true ]]; then
		local DAEMON_FILE="/etc/docker/daemon.json"
		local MIRRORS_JSON='["https://mirror.baidubce.com", "https://hub-mirror.c.163.com", "https://docker.m.daocloud.io"]'
		execute_with_spinner "创建 Docker 配置目录..." run_with_sudo mkdir -p /etc/docker
		execute_with_spinner "写入/更新镜像加速器配置..." \
			update_docker_daemon_config "$DAEMON_FILE" "$MIRRORS_JSON"
		execute_with_spinner "应用配置并重启 Docker..." run_destructive_with_sudo systemctl daemon-reload && run_destructive_with_sudo systemctl restart docker
		log_success "✅ 镜像加速器配置完成！"
	fi
}

add_user_to_docker_group() {
	local user_to_add=""
	if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
		user_to_add=$SUDO_USER
		if ! confirm_action "👤 检测到您使用 sudo 运行，是否将用户 '$user_to_add' 加入 docker 组？"; then user_to_add=""; fi
	else
		user_to_add=$(_prompt_user_input "🤔 是否要将某个普通用户加入 docker 组以便无 sudo 使用 docker？(请输入用户名，或直接回车跳过): " "")
	fi

	if [ -n "$user_to_add" ]; then
		if id "$user_to_add" &>/dev/null; then
			execute_with_spinner "正在将用户 '$user_to_add' 加入 docker 组..." run_with_sudo usermod -aG docker "$user_to_add"
			log_warn "安全警告: 用户 '$user_to_add' 已被授予 Docker 控制权限。"
			log_warn "这等同于给予了该用户系统的 root 权限，请务必知晓此风险！"
			log_warn "⚠️ 请让用户 '$user_to_add' 重新登录以使组权限生效！"
		else
			log_err "❌ 用户 '$user_to_add' 不存在，已跳过此步骤。"
		fi
	fi
}

install_docker() {
	if ! confirm_action "是否确定开始安装 Docker?"; then
		log_warn "操作已取消。"
		return 1
	fi
	log_info "🚀 开始安装 Docker & Docker Compose..."
	determine_install_source
	check_distro
	resolve_docker_repo_codename
	log_success "✅ 系统: $DISTRO ($CODENAME)，安装源已确定，准备就绪！"
	execute_with_spinner "清理旧版本 Docker (如有)..." run_destructive_with_sudo apt-get remove -y docker docker-engine docker.io containerd runc
	execute_with_spinner "清理历史 Docker APT 源 (防止版本冲突)..." cleanup_docker_apt_source
	execute_with_spinner "更新软件源..." run_with_sudo apt-get update -qq
	execute_with_spinner "创建 APT 密钥环目录..." run_with_sudo install -m 0755 -d /etc/apt/keyrings
	execute_with_spinner "添加 Docker GPG 密钥..." install_docker_gpg_key "${DOCKER_URL_OFFICIAL}/linux/${DISTRO}/gpg" "/etc/apt/keyrings/docker.gpg"
	execute_with_spinner "设置 Docker GPG 密钥权限..." run_with_sudo chmod a+r /etc/apt/keyrings/docker.gpg
	ensure_docker_repo_ready
	execute_with_spinner "安装 Docker 引擎和 Compose 插件..." run_with_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
	execute_with_spinner "启动 Docker 并设置开机自启..." run_with_sudo systemctl enable --now docker
	execute_with_spinner "运行 hello-world 容器进行功能测试..." run_with_sudo docker run --rm hello-world
	execute_with_spinner "清理测试镜像..." run_with_sudo docker image rm hello-world
	log_success "\n🎉 Docker 安装成功！"
	get_docker_status
	printf "   Docker 版本: %s\n   Compose 版本: %s\n\n" "$DOCKER_VERSION" "$COMPOSE_VERSION"
	configure_docker_mirror "auto"
	add_user_to_docker_group
	log_success "--------------------------------------------------"
	log_success "✅ 所有操作已完成！"
}

docker_service_menu() {
	while true; do
		if should_clear_screen "docker:service_menu"; then clear; fi
		get_docker_status
		local status_color="$GREEN"
		if [ "$DOCKER_SERVICE_STATUS" != "active" ]; then status_color="$RED"; fi
		local -a content_array=(
			"当前服务状态: ${status_color}${DOCKER_SERVICE_STATUS}${NC}"
			""
			"1. 启动 Docker 服务"
			"2. 停止 Docker 服务"
			"3. 重启 Docker 服务"
			"4. 查看服务日志 (实时)"
		)
		_render_menu "Docker 服务管理" "${content_array[@]}"
		local choice
		choice=$(_prompt_for_menu_choice "1-4")
		case "$choice" in
		1) execute_with_spinner "正在启动 Docker 服务..." run_with_sudo systemctl start docker.service ;;
		2) execute_with_spinner "正在停止 Docker 服务..." run_destructive_with_sudo systemctl stop docker.service ;;
		3) execute_with_spinner "正在重启 Docker 服务..." run_destructive_with_sudo systemctl restart docker.service ;;
		4)
			log_info "实时日志 (按 Ctrl+C 停止)..."
			sleep 1
			run_with_sudo journalctl -u docker.service -f --no-pager || true
			press_enter_to_continue
			;;
		"") return ;;
		*)
			log_warn "无效选项 '${choice}'。"
			sleep 1
			;;
		esac
	done
}

docker_prune_system() {
	log_warn "警告：这是一个有潜在破坏性的操作！"
	log_warn "此操作将删除所有未使用的 Docker 资源，包括："
	log_warn "  - 所有已停止的容器"
	log_warn "  - 所有未被任何容器使用的网络"
	log_warn "  - 所有悬空镜像 (dangling images)"
	log_warn "  - 所有构建缓存"

	if confirm_action "是否同时清理【所有未被使用的数据卷】? 这是最危险的步骤!"; then
		log_info "正在执行系统清理 (包含未使用的卷)..."
		run_destructive_with_sudo docker system prune -a -f --volumes
	else
		log_info "正在执行系统清理 (不包含数据卷)..."
		run_destructive_with_sudo docker system prune -a -f
	fi
	log_success "✅ 系统清理完成。"
}

repair_docker_service() {
	if [ "$DOCKER_INSTALLED" != "true" ]; then
		log_warn "Docker 未安装，无法执行服务修复。"
		return 0
	fi
	log_info "开始执行服务快速修复（不重装、不改镜像源）..."
	run_destructive_with_sudo systemctl daemon-reload || true
	run_destructive_with_sudo systemctl restart docker.service || true
	get_docker_status
	log_info "修复后服务状态: ${DOCKER_SERVICE_STATUS}"
}

_manage_installation() {
	while true; do
		if should_clear_screen "docker:manage_installation"; then clear; fi
		local -a menu_items=(
			"1. 重新安装 Docker"
			"2. 卸载 Docker"
		)
		_render_menu "安装管理" "${menu_items[@]}"
		local choice
		choice=$(_prompt_for_menu_choice "1-2")

		case "$choice" in
		1)
			if confirm_action "确定要重新安装 Docker 吗? 这将先执行卸载流程。"; then
				if uninstall_docker; then
					install_docker
				fi
			fi
			break # Return to main menu after action
			;;
		2)
			uninstall_docker
			break # Return to main menu after action
			;;
		"") return ;; # Return to main menu
		*)
			log_warn "无效选项 '${choice}'。"
			sleep 1
			;;
		esac
	done
}

main_menu() {
	while true; do
		if should_clear_screen "docker:main_menu"; then clear; fi
		get_docker_status

		local status_color="$GREEN"
		if [ "$DOCKER_SERVICE_STATUS" != "active" ]; then status_color="$RED"; fi

		local -a menu_items=()
		local options_map=()
		local action_taken_in_submenu=false

		if [ "$DOCKER_INSTALLED" = "true" ]; then
			menu_items+=(
				"ℹ️ ${GREEN}Docker 已安装${NC}"
				"服务状态: ${status_color}${DOCKER_SERVICE_STATUS}${NC}"
				"Docker 版本: ${DOCKER_VERSION}"
				"Compose 版本: ${COMPOSE_VERSION}"
				""
				"1. 服务管理"
				"2. 配置镜像/用户组"
				"3. 系统清理 (Prune)"
				"4. 重新安装 Docker"
				"5. 卸载 Docker"
				"6. 快速修复服务状态"
			)
			options_map=("service" "config" "prune" "reinstall" "uninstall" "repair")
		else
			menu_items+=(
				"ℹ️ ${YELLOW}检测到 Docker 未安装${NC}"
				""
				"1. 安装 Docker 和 Compose"
			)
			options_map=("install")
		fi

		_render_menu "Docker & Docker Compose 管理" "${menu_items[@]}"
		local choice
		choice=$(_prompt_for_menu_choice "1-${#options_map[@]}")

		if [ -z "$choice" ]; then
			return 10
		fi
		if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#options_map[@]} ]; then
			log_warn "无效选项 '${choice}'。"
			sleep 1
			continue
		fi

		local action="${options_map[$((choice - 1))]}"
		case "$action" in
		install) install_docker ;;
		config) configure_docker_mirror && add_user_to_docker_group ;;
		service)
			docker_service_menu
			action_taken_in_submenu=true
			;;
		prune) docker_prune_system ;;
		reinstall)
			log_warn "影响摘要: 将先卸载后重装 Docker，可能中断容器服务。"
			if confirm_action "确定要重新安装 Docker 吗? 这将先执行卸载流程。"; then
				if uninstall_docker; then
					install_docker
				fi
			fi
			;;
		uninstall) uninstall_docker ;;
		repair) repair_docker_service ;;
		esac

		if [[ "$action_taken_in_submenu" == false ]]; then
			press_enter_to_continue
		fi
	done
}

# --- 脚本执行入口 ---
main() {
	trap 'printf "\n操作被中断。\n" >&2; exit 10' INT
	self_elevate_or_die "$@"
	parse_dry_run_args "$@"
	log_info "您选择了 [Docker & Compose 管理]"
	log_info "欢迎使用 Docker 模块 ${SCRIPT_VERSION}"
	init_runtime
	pre_check_dependencies
	main_menu "${RUN_ARGS[@]}"
}

main "$@"
