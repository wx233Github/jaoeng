#!/bin/bash

# ===================================================================================
# 🚀 Docker & Docker Compose 终极一键脚本 (Ubuntu/Debian) v2.6
#
# 新特性 (v2.6):
#   - 修复: 在“重新安装”流程中，即使用户取消了卸载步骤，脚本依然会继续安装的逻辑错误。
# ===================================================================================

# 识别是否作为子脚本被调用
IS_NESTED_CALL="${IS_NESTED_CALL:-false}"

# --- 全局变量和常量 ---
readonly C_RESET='\e[0m'
readonly C_GREEN='\e[0;32m'
readonly C_YELLOW='\e[1;33m'
readonly C_RED='\e[0;31m'
readonly C_BLUE='\e[0;34m'

# --- Docker 安装源配置 ---
readonly DOCKER_URL_OFFICIAL="https://download.docker.com"
readonly DOCKER_URL_MIRROR="https://mirrors.ustc.edu.cn/docker-ce"
DOCKER_INSTALL_URL=""

# 系统信息
DISTRO=""
CODENAME=""

# --- 辅助函数 ---

cecho() {
    local color="$1"
    local message="$2"
    printf "${color}%s${C_RESET}\n" "$message"
}

spinner() {
    local pid=$!
    local message="$1"
    local spinstr='|/-\'
    
    printf "%s " "$message"
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\b\b\b"
    done
    printf "   \b\b\b"
    cecho "$C_GREEN" "✓ 完成"
}

handle_exit() {
    if [ "$IS_NESTED_CALL" = "true" ]; then
        # 返回 10，告知主脚本用户选择了“返回”。不打印任何信息。
        exit 10
    else
        # 独立运行时，打印提示信息后正常退出
        cecho "$C_BLUE" "👋 操作已取消，脚本退出。"
        exit 0
    fi
}


check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        cecho "$C_RED" "❌ 错误: 请使用 root 用户运行此脚本，或在命令前添加 sudo。"
        exit 1
    fi
}

determine_install_source() {
    cecho "$C_BLUE" "🌐 正在检测最佳 Docker 安装源..."
    if curl -s --connect-timeout 5 -o /dev/null "$DOCKER_URL_OFFICIAL"; then
        cecho "$C_GREEN" "   -> Docker 官方源 (${DOCKER_URL_OFFICIAL}) 连接成功。"
        DOCKER_INSTALL_URL=$DOCKER_URL_OFFICIAL
    else
        cecho "$C_YELLOW" "   -> Docker 官方源连接失败或超时。"
        read -p "$(echo -e ${C_YELLOW}"🤔 是否尝试切换到国内镜像源 (USTC) 进行安装？[Y/n]: "${C_RESET})" choice
        if [[ -z "$choice" || "$choice" =~ ^[yY]$ ]]; then
            DOCKER_INSTALL_URL=$DOCKER_URL_MIRROR
            cecho "$C_GREEN" "   -> 已切换到国内镜像源: ${DOCKER_INSTALL_URL}"
            if ! curl -s --connect-timeout 5 -o /dev/null "$DOCKER_INSTALL_URL"; then
                 cecho "$C_RED" "❌ 错误: 国内镜像源也无法连接。请检查您的网络设置。"
                 exit 1
            fi
        else
            cecho "$C_RED" "❌ 用户取消操作，无法继续安装。"
            exit 1
        fi
    fi
}

check_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) DISTRO=$ID; CODENAME=$VERSION_CODENAME ;;
            *) cecho "$C_RED" "❌ 错误: 不支持的系统: $ID。"; exit 1 ;;
        esac
    else
        cecho "$C_RED" "❌ 错误: 无法检测到系统发行版信息。"; exit 1
    fi
}


# --- 核心功能函数 ---
uninstall_docker() {
    cecho "$C_YELLOW" "🤔 你确定要卸载 Docker 和 Compose 吗？这将删除所有相关软件包、镜像、容器和卷！"
    read -p "   请输入 'yes' 确认卸载，输入其他任何内容取消: " confirm
    if [[ "$confirm" == "yes" ]]; then
        cecho "$C_BLUE" "🧹 开始卸载..."
        (systemctl stop docker.service docker.socket >/dev/null 2>&1) & spinner "   -> 停止 Docker 服务..."
        (apt-get remove -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 && apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 && apt-get autoremove -y >/dev/null 2>&1) & spinner "   -> 卸载 Docker 和 Compose 软件包..."
        (rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list) & spinner "   -> 删除残留文件和配置..."
        cecho "$C_GREEN" "✅ Docker 和 Compose 已成功卸载。"
    else
        cecho "$C_YELLOW" "🚫 操作已取消。"
        # 【关键修复】返回一个失败的退出码 (1)，这样 && 命令链就会中断，不会继续执行安装。
        return 1
    fi
}

configure_docker_mirror() {
    local prompt; local default_choice="n"; local choice
    if [[ "$DOCKER_INSTALL_URL" == "$DOCKER_URL_MIRROR" ]]; then
        prompt="🤔 检测到您使用了国内安装源，强烈推荐配置 Docker Hub 镜像加速器，是否配置？[Y/n]: "; default_choice="y"
    else
        prompt="🤔 是否需要为 Docker Hub 配置国内镜像加速器 (适合从国内拉取镜像)？[y/N]: "
    fi
    read -p "$(echo -e ${C_YELLOW}${prompt}${C_RESET})" choice
    local configure_needed=false
    if [[ "$default_choice" == "y" && (-z "$choice" || "$choice" =~ ^[yY]$) ]] || \
       [[ "$default_choice" == "n" && "$choice" =~ ^[yY]$ ]]; then
        configure_needed=true
    fi
    if [[ "$configure_needed" == true ]]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json <<EOF
{ "registry-mirrors": [ "https://mirror.baidubce.com", "https://hub-mirror.c.163.com", "https://docker.m.daocloud.io" ] }
EOF
        (systemctl daemon-reload && systemctl restart docker) & spinner "   -> 正在应用配置并重启 Docker..."
        cecho "$C_GREEN" "✅ 镜像加速器配置完成！"
    fi
}

add_user_to_docker_group() {
    local user_to_add=""
    if [ -n "$SUDO_USER" ]; then
        user_to_add=$SUDO_USER
        cecho "$C_BLUE" "👤 检测到您使用 sudo 运行，将自动把用户 '$user_to_add' 加入 docker 组。"
    else
        read -p "$(echo -e ${C_YELLOW}"🤔 是否要将某个普通用户加入 docker 组以便无 sudo 使用 docker？(请输入用户名，或直接回车跳过): "${C_RESET})" user_to_add
    fi
    if [ -n "$user_to_add" ]; then
        if id "$user_to_add" &>/dev/null; then
            (usermod -aG docker "$user_to_add") & spinner "   -> 正在将用户 '$user_to_add' 加入 docker 组..."
            cecho "$C_YELLOW" "⚠️ 请让用户 '$user_to_add' 重新登录以使组权限生效！"
        else
            cecho "$C_RED" "❌ 用户 '$user_to_add' 不存在，已跳过此步骤。"
        fi
    fi
}

install_docker() {
    cecho "$C_BLUE" "🚀 开始安装 Docker & Docker Compose..."
    determine_install_source; check_distro
    cecho "$C_GREEN" "✅ 系统: $DISTRO ($CODENAME)，安装源已确定，准备就绪！"
    (apt-get remove -y docker docker-engine docker.io containerd runc >/dev/null 2&>1) & spinner "   -> 清理旧版本 Docker (如有)..."
    (apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1) & spinner "   -> 更新软件源并安装必要依赖..."
    install -m 0755 -d /etc/apt/keyrings
    (curl -fsSL "${DOCKER_URL_OFFICIAL}/linux/${DISTRO}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg) & spinner "   -> 添加 Docker GPG 密钥..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_INSTALL_URL}/linux/${DISTRO} ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    (apt-get update -qq >/dev/null 2>&1 && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1) & spinner "   -> 安装 Docker 引擎和 Compose 插件..."
    (systemctl enable --now docker >/dev/null 2>&1) & spinner "   -> 启动 Docker 并设置开机自启..."
    cecho "$C_GREEN" "🎉 Docker 安装成功！"
    printf "   Docker 版本: %s\n" "$(docker --version)"
    printf "   Compose 版本: %s\n" "$(docker compose version)"
    (docker run --rm hello-world >/dev/null 2>&1 && docker image rm hello-world >/dev/null 2>&1) & spinner "   -> 运行 hello-world 容器进行功能测试..."
    configure_docker_mirror; add_user_to_docker_group
    cecho "$C_GREEN" "--------------------------------------------------"
    cecho "$C_GREEN" "✅ 所有操作已完成！"
    cecho "$C_YELLOW" "💡 重要提示：如果添加了用户到 docker 组，请务必重新登录或重启系统！"
}

# --- 主程序逻辑 ---

main() {
    check_root

    if [ "$IS_NESTED_CALL" != "true" ]; then
        clear
    fi

    echo

    cecho "$C_BLUE" "==================================================="
    cecho "$C_BLUE" "  Docker & Docker Compose 交互式管理脚本 v2.6  "
    cecho "$C_BLUE" "==================================================="
    
    if command -v docker &> /dev/null; then
        cecho "$C_GREEN" "\n✅ 检测到 Docker 已安装。"
        printf "   Docker 版本: %s\n" "$(docker --version)"
        printf "   Compose 版本: %s\n\n" "$(docker compose version 2>/dev/null || echo '未安装')"
        
        cecho "$C_YELLOW" "请选择要执行的操作:"
        echo "  1) 重新安装 Docker 和 Compose"
        echo "  2) 卸载 Docker 和 Compose"
        echo "  3) 配置镜像加速和用户组"
        read -p "请输入选项 [1-3] (直接回车返回): " choice
        
        if [[ -z "$choice" ]]; then
            handle_exit
        fi

        case $choice in
            1) uninstall_docker && install_docker ;;
            2) uninstall_docker ;;
            3) DOCKER_INSTALL_URL=""; configure_docker_mirror && add_user_to_docker_group ;;
            *) cecho "$C_RED" "❌ 无效选项 '${choice}'。"; exit 1 ;;
        esac
    else
        cecho "$C_YELLOW" "\nℹ️ 检测到 Docker 未安装。"
        cecho "$C_YELLOW" "请选择要执行的操作:"
        echo "  1) 安装 Docker 和 Docker Compose"
        read -p "请输入选项 [1] (直接回车返回): " choice
        
        if [[ -z "$choice" ]]; then
            handle_exit
        fi
        
        case $choice in
            1) install_docker ;;
            *) cecho "$C_RED" "❌ 无效选项 '${choice}'。"; exit 1 ;;
        esac
    fi
}

# --- 脚本执行入口 ---
main "$@"
