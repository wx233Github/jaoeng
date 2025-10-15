#!/bin/bash
# =============================================================
# 🚀 Docker 管理模块 (v4.3.2-UI精确对齐修复)
# - 修复: 彻底重写 `main_menu` 的双栏布局渲染，放弃 `_render_menu`，
#         改为手动绘制UI盒子，通过精确计算视觉宽度和动态填充，完美解决UI混乱问题。
# - 新增: 根据用户请求，在模块启动时添加欢迎信息。
# - 修复: 修正了UI盒子绘制中宽度计算和填充的逻辑，确保左右两列和主盒子边框的精确对齐，解决右侧边框偏移。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.3.2"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C_UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    RED='\e[0;31m'; NC='\e[0m'
    log_err() { echo -e "${RED}[错误] $*${NC}" >&2; }
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- 确保 run_with_sudo 函数可用 ---
if ! declare -f run_with_sudo &>/dev/null; then
  log_err "致命错误: run_with_sudo 函数未定义。请确保从 install.sh 启动此脚本。"
  exit 1
fi

# --- 全局状态变量 ---
DOCKER_INSTALLED="false"
DOCKER_SERVICE_STATUS="unknown"
DOCKER_VERSION=""
COMPOSE_VERSION=""
DOCKER_INSTALL_URL=""
DISTRO=""
CODENAME=""

# --- Docker 安装源配置 ---
readonly DOCKER_URL_OFFICIAL="https://download.docker.com"
readonly DOCKER_URL_MIRROR="https://mirrors.ustc.edu.cn/docker-ce"

# --- 核心辅助函数 ---

execute_with_spinner() {
    local message="$1"; shift; local command_to_run=("$@"); local LOG_FILE; LOG_FILE=$(mktemp)
    echo -n "- ${message}"; "${command_to_run[@]}" >"$LOG_FILE" 2>&1 &
    local pid=$!; local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}; printf " [%c]  " "$spinstr"; spinstr=$temp${spinstr%"$temp"}; sleep 0.1; printf "\b\b\b\b\b"
    done
    wait $pid; local rc=$?; printf "     \b\b\b\b\b"
    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}✓ 完成${NC}"
    else
        echo -e "${RED}✗ 失败${NC}"; echo "-------------------- 错误日志 --------------------"; cat "$LOG_FILE"
        echo "--------------------------------------------------"; log_err "操作失败，脚本已终止。请检查上述错误日志。"
        rm -f "$LOG_FILE"; exit 1
    fi; rm -f "$LOG_FILE"
}

pre_check_dependencies() {
    local missing_deps=()
    if ! command -v curl &> /dev/null; then missing_deps+=("curl"); fi
    if ! command -v jq &> /dev/null; then missing_deps+=("jq"); fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warn "核心依赖 '${missing_deps[*]}' 未找到，正在尝试自动安装..."
        execute_with_spinner "更新软件源..." run_with_sudo apt-get update -qq
        execute_with_spinner "安装缺失的依赖: ${missing_deps[*]}..." run_with_sudo apt-get install -y "${missing_deps[@]}"
    fi
}

get_docker_status() {
    if command -v docker &> /dev/null; then
        DOCKER_INSTALLED="true"
        DOCKER_SERVICE_STATUS=$(systemctl is-active docker.service 2>/dev/null || echo "unknown")
        DOCKER_VERSION=$(docker --version)
        COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "未安装")
    else
        DOCKER_INSTALLED="false"
        DOCKER_SERVICE_STATUS="not-installed"
        DOCKER_VERSION=""; COMPOSE_VERSION=""
    fi
}

determine_install_source() {
    log_info "🌐 正在检测最佳 Docker 安装源..."
    local curl_output; curl_output=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 "$DOCKER_URL_OFFICIAL")
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
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) 
                DISTRO=$ID; CODENAME=$VERSION_CODENAME 
                if [ -z "$CODENAME" ]; then
                    log_err "无法从此系统获取到发行版代号 (Version Codename)，无法继续。"
                    exit 1
                fi
                ;;
            *) log_err "不支持的系统: $ID。"; exit 1 ;;
        esac
    else
        log_err "无法检测到系统发行版信息。"; exit 1
    fi
}

uninstall_docker() {
    log_warn "你确定要卸载 Docker 和 Compose 吗？这将删除所有相关软件包、镜像、容器和卷！"
    read -r -p "   请输入 'yes' 确认卸载，输入其他任何内容取消: " confirm < /dev/tty
    if [[ "$confirm" == "yes" ]]; then
        log_info "🧹 开始卸载..."
        execute_with_spinner "停止 Docker 服务..." run_with_sudo systemctl stop docker.service docker.socket
        execute_with_spinner "卸载 Docker 和 Compose 软件包..." run_with_sudo apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        execute_with_spinner "清理残留软件包配置..." run_with_sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        execute_with_spinner "自动移除不再需要的依赖..." run_with_sudo apt-get autoremove -y --purge
        execute_with_spinner "删除 Docker 数据和配置目录..." run_with_sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list

        log_info "检查 docker 用户组残留..."
        if getent group docker >/dev/null; then
            local users_in_docker_group; users_in_docker_group=$(getent group docker | cut -d: -f4 | sed 's/,/ /g')
            if [ -n "$users_in_docker_group" ]; then
                log_warn "以下用户仍在 'docker' 组中: ${users_in_docker_group}"
                if confirm_action "是否将他们从 'docker' 组中移除?"; then
                    for user in $users_in_docker_group; do
                        execute_with_spinner "从 'docker' 组中移除用户 '$user'..." run_with_sudo gpasswd -d "$user" docker
                    done
                fi
            fi
            if [ -z "$(getent group docker | cut -d: -f4)" ]; then
                execute_with_spinner "删除空的 'docker' 用户组..." run_with_sudo groupdel docker
            fi
        fi
        log_success "✅ Docker 和 Compose 已成功卸载。"
        return 0
    else
        log_warn "🚫 操作已取消。"; return 1
    fi
}

configure_docker_mirror() {
    local choice_made=false
    if [[ "$1" == "auto" ]]; then
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
            bash -c "run_with_sudo touch $DAEMON_FILE && \
            JSON_CONTENT=\$(run_with_sudo cat $DAEMON_FILE | jq --argjson mirrors '$MIRRORS_JSON' '.[\"registry-mirrors\"] = \$mirrors' 2>/dev/null) && \
            if [ -z \"\$JSON_CONTENT\" ]; then JSON_CONTENT=\$(jq -n --argjson mirrors '$MIRRORS_JSON' '{\"registry-mirrors\": \$mirrors}'); fi && \
            echo \"\$JSON_CONTENT\" | run_with_sudo tee $DAEMON_FILE > /dev/null"
        execute_with_spinner "应用配置并重启 Docker..." run_with_sudo systemctl daemon-reload && run_with_sudo systemctl restart docker
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
    log_info "🚀 开始安装 Docker & Docker Compose..."
    determine_install_source; check_distro
    log_success "✅ 系统: $DISTRO ($CODENAME)，安装源已确定，准备就绪！"
    execute_with_spinner "清理旧版本 Docker (如有)..." run_with_sudo apt-get remove -y docker docker-engine docker.io containerd runc
    execute_with_spinner "更新软件源..." run_with_sudo apt-get update -qq
    execute_with_spinner "创建 APT 密钥环目录..." run_with_sudo install -m 0755 -d /etc/apt/keyrings
    execute_with_spinner "添加 Docker GPG 密钥..." bash -c "curl -fsSL \"${DOCKER_URL_OFFICIAL}/linux/${DISTRO}/gpg\" | run_with_sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"
    execute_with_spinner "设置 Docker GPG 密钥权限..." run_with_sudo chmod a+r /etc/apt/keyrings/docker.gpg
    local docker_list_content="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_INSTALL_URL}/linux/${DISTRO} ${CODENAME} stable"
    execute_with_spinner "添加 Docker 软件源..." bash -c "echo \"$docker_list_content\" | run_with_sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"
    execute_with_spinner "再次更新软件源..." run_with_sudo apt-get update -qq
    execute_with_spinner "安装 Docker 引擎和 Compose 插件..." run_with_sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    execute_with_spinner "启动 Docker 并设置开机自启..." run_with_sudo systemctl enable --now docker
    execute_with_spinner "运行 hello-world 容器进行功能测试..." run_with_sudo docker run --rm hello-world
    execute_with_spinner "清理测试镜像..." run_with_sudo docker image rm hello-world
    log_success "\n🎉 Docker 安装成功！"; get_docker_status
    printf "   Docker 版本: %s\n   Compose 版本: %s\n\n" "$DOCKER_VERSION" "$COMPOSE_VERSION"
    configure_docker_mirror "auto"; add_user_to_docker_group
    log_success "--------------------------------------------------"; log_success "✅ 所有操作已完成！"
}

docker_service_menu() {
    while true;
    do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        get_docker_status
        local status_color="$GREEN"; if [ "$DOCKER_SERVICE_STATUS" != "active" ]; then status_color="$RED"; fi
        local -a content_array=(
            "当前服务状态: ${status_color}${DOCKER_SERVICE_STATUS}${NC}"
            ""
            "1. 启动 Docker 服务"
            "2. 停止 Docker 服务"
            "3. 重启 Docker 服务"
            "4. 查看服务日志 (实时)"
        )
        _render_menu "Docker 服务管理" "${content_array[@]}"
        read -r -p " └──> 请输入选项 [1-4] (或按 Enter 返回): " choice < /dev/tty
        case "$choice" in
            1) execute_with_spinner "正在启动 Docker 服务..." run_with_sudo systemctl start docker.service ;;
            2) execute_with_spinner "正在停止 Docker 服务..." run_with_sudo systemctl stop docker.service ;;
            3) execute_with_spinner "正在重启 Docker 服务..." run_with_sudo systemctl restart docker.service ;;
            4) 
                log_info "实时日志 (按 Ctrl+C 停止)..."; sleep 1
                run_with_sudo journalctl -u docker.service -f --no-pager || true
                press_enter_to_continue
                ;;
            "") return ;;
            *) log_warn "无效选项 '${choice}'。"; sleep 1 ;;
        esac
        if [[ "$choice" =~ ^[1-3]$ ]]; then press_enter_to_continue; fi
    done
}

docker_prune_system() {
    log_warn "警告：这是一个有潜在破坏性的操作！"
    log_warn "此操作将删除所有未使用的 Docker 资源，包括："
    log_warn "  - 所有已停止的容器"
    log_warn "  - 所有未被任何容器使用的网络"
    log_warn "  - 所有悬空镜像 (dangling images)"
    log_warn "  - 所有构建缓存"
    log_warn "${RED}  - 所有未被任何容器使用的数据卷 (Volumes)！${NC}"
    log_warn "这意味着存储在数据卷中的数据库、配置文件等都可能被永久删除！"
    
    local confirm_string="yes-i-am-sure"
    read -r -p "为确认您理解风险，请输入 '${confirm_string}': " confirm < /dev/tty
    if [[ "$confirm" == "$confirm_string" ]]; then
        log_info "正在执行系统清理..."
        run_with_sudo docker system prune -a -f --volumes
        log_success "✅ 系统清理完成。"
    else
        log_warn "🚫 输入不匹配，操作已取消。"
    fi
}

main_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-false}" = "true" ]; then clear; fi
        get_docker_status
        
        if [ "$DOCKER_INSTALLED" = "true" ]; then
            local status_color="$GREEN"; if [ "$DOCKER_SERVICE_STATUS" != "active" ]; then status_color="$RED"; fi
            
            local left_options=(
                "  1. 重新安装 Docker"
                "  2. 卸载 Docker"
                "  3. 配置镜像/用户组"
                "  4. 服务管理"
                "  5. 系统清理 (Prune)"
            )
            local right_status=(
                "${CYAN}┌─ Docker 状态 ──────────────────┐${NC}"
                "  ${CYAN}│${NC} ${GREEN}已安装${NC}"
                "  ${CYAN}│${NC} 服务: ${status_color}${DOCKER_SERVICE_STATUS}${NC}"
                "  ${CYAN}│${NC} 版本: ${DOCKER_VERSION}"
                "  ${CYAN}│${NC} Compose: ${COMPOSE_VERSION}"
                "${CYAN}└────────────────────────────────┘${NC}"
            )
            local options_map=("reinstall" "uninstall" "config" "service" "prune")

            # --- 核心UI修复：手动绘制整个UI盒子，不再使用 _render_menu ---
            local title="Docker & Docker Compose 管理"
            local max_left_width=0
            for item in "${left_options[@]}"; do
                local width=$(_get_visual_width "$item")
                if [ "$width" -gt "$max_left_width" ]; then max_left_width=$width; fi
            done

            local max_right_width=0
            for item in "${right_status[@]}"; do
                local width=$(_get_visual_width "$item")
                if [ "$width" -gt "$max_right_width" ]; then max_right_width=$width; fi
            done

            local spacing=4 # 左右两列之间的固定间距

            # 计算内容区域的理想宽度（不含外侧的 '│' 字符）
            # 这个宽度需要容纳最宽的标题，或者最宽的左右两列内容 + 它们之间的间距 + 左右各一个内边距空格
            local ideal_content_width_for_rows=$((1 + max_left_width + spacing + max_right_width + 1)) # 左右各1个内边距空格
            local title_visual_width=$(_get_visual_width "$title")

            local main_box_inner_width=$ideal_content_width_for_rows
            if [ "$title_visual_width" -gt "$main_box_inner_width" ]; then
                main_box_inner_width=$title_visual_width
            fi

            # 确保最小宽度，如果需要
            if [ "$main_box_inner_width" -lt 40 ]; then main_box_inner_width=40; fi

            echo ""; echo -e "${GREEN}╭$(generate_line "$main_box_inner_width" "─")╮${NC}"

            local padding_total_title=$((main_box_inner_width - title_visual_width))
            local padding_left_title=$((padding_total_title / 2))
            local padding_right_title=$((padding_total_title - padding_left_title))
            echo -e "${GREEN}│$(printf '%*s' "$padding_left_title")${BOLD}${title}${NC}${GREEN}$(printf '%*s' "$padding_right_title")│${NC}"

            echo -e "${GREEN}├$(generate_line "$main_box_inner_width" "─")┤${NC}"

            local num_left=${#left_options[@]}; local num_right=${#right_status[@]}; local max_lines=$(( num_left > num_right ? num_left : num_right ))
            for (( i=0; i<max_lines; i++ )); do
                local left_item="${left_options[i]:-}"
                local right_item="${right_status[i]:-}"

                local current_left_item_width=$(_get_visual_width "$left_item")
                local current_right_item_width=$(_get_visual_width "$right_item")

                local left_item_padding=$((max_left_width - current_left_item_width))
                local right_item_padding=$((max_right_width - current_right_item_width))

                printf -v padded_left_display "%s%*s" "$left_item" "$left_item_padding" ""
                printf -v padded_right_display "%s%*s" "$right_item" "$right_item_padding" ""

                # 构建一行内容 (包括左右内边距空格)
                local row_content_to_print=" ${padded_left_display}$(printf '%*s' "$spacing")${padded_right_display} "
                local row_content_visual_width=$(_get_visual_width "$row_content_to_print")

                # 计算需要填充的额外空格，以使该行总宽度与 main_box_inner_width 匹配
                local extra_padding_for_row=$((main_box_inner_width - row_content_visual_width))
                if [ "$extra_padding_for_row" -lt 0 ]; then extra_padding_for_row=0; fi # 避免负数填充

                echo -e "${GREEN}│${NC}${row_content_to_print}$(printf '%*s' "$extra_padding_for_row")${GREEN}│${NC}"
            done
            echo -e "${GREEN}╰$(generate_line "$main_box_inner_width" "─")╯${NC}"
            # 底部分隔线，总长度包含外边角字符 ('╭' 和 '╮')
            echo -e "${GREEN}$(generate_line "$((main_box_inner_width + 2))" "─")${NC}" 

            read -r -p " └──> 请输入选项 [1-5] (或按 Enter 返回): " choice < /dev/tty

        else
            local -a content_array=("ℹ️ ${YELLOW}检测到 Docker 未安装${NC}" "" "  1. 安装 Docker 和 Compose")
            local options_map=("install")
            _render_menu "Docker & Docker Compose 安装" "${content_array[@]}"
            read -r -p " └──> 请输入选项 [1] (或按 Enter 返回): " choice < /dev/tty
        fi

        if [ -z "$choice" ]; then exit 10; fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#options_map[@]} ]; then
            log_warn "无效选项 '${choice}'。"; sleep 1; continue
        fi
        
        local action="${options_map[$((choice-1))]}"
        case "$action" in
            reinstall) if uninstall_docker; then install_docker; fi ;;
            uninstall) uninstall_docker ;;
            config) configure_docker_mirror && add_user_to_docker_group ;;
            service) docker_service_menu ;;
            prune) docker_prune_system ;;
            install) install_docker ;;
        esac
        press_enter_to_continue
    done
}

# --- 脚本执行入口 ---
main() {
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    log_info "您选择了 [Docker & Compose 管理]"
    log_info "欢迎使用 Docker 模块 ${SCRIPT_VERSION}"
    pre_check_dependencies
    main_menu "$@"
}

main "$@"
