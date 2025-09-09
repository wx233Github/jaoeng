#!/bin/bash

# 🚀 Docker & Docker Compose 一键安装脚本 (Ubuntu/Debian, 自动确认)
set -e

# 设置自动确认
export DEBIAN_FRONTEND=noninteractive

# 检查是否 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行，或在命令前加 sudo"
    exit 1
fi

echo "🔍 检测系统信息..."
. /etc/os-release

# 判断系统
case "$ID" in
    ubuntu)
        DISTRO="ubuntu"
        CODENAME=$(lsb_release -cs)
        ;;
    debian)
        DISTRO="debian"
        CODENAME=$(lsb_release -cs)
        ;;
    *)
        echo "❌ 不支持的系统: $ID"
        exit 1
        ;;
esac

echo "✅ 系统: $DISTRO ($CODENAME)"

# 卸载旧版本 Docker
echo "🧹 检测并卸载旧版本 Docker..."
apt remove -y docker docker-engine docker.io containerd runc || true
apt purge -y docker docker-engine docker.io containerd runc || true
rm -rf /var/lib/docker /var/lib/containerd || true

# 安装依赖
echo "📦 安装必要依赖..."
apt update
apt install -y ca-certificates curl gnupg lsb-release

# 添加 Docker GPG Key
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$DISTRO/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# 添加 Docker 官方源
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO $CODENAME stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

# 更新并安装 Docker
echo "🚀 安装 Docker..."
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# 加入 docker 组
if [ -n "$SUDO_USER" ]; then
    usermod -aG docker "$SUDO_USER"
fi

# 启动并开机自启
systemctl enable docker
systemctl start docker

# 验证安装
echo "✅ Docker 安装完成，版本信息："
docker --version
docker compose version || true

# 测试 Docker 是否能运行
echo "🧪 测试 Docker 是否正常运行..."
if docker run --rm hello-world >/dev/null 2>&1; then
    echo "🎉 Docker 测试成功！"
    # 删除测试镜像
    docker image rm hello-world >/dev/null 2>&1 || true
else
    echo "❌ Docker 测试失败，请检查安装或网络"
fi

# 测试 Docker Compose
echo "🧪 测试 Docker Compose 是否正常运行..."
if docker compose version >/dev/null 2>&1; then
    echo "🎉 Docker Compose 测试成功！"
else
    echo "❌ Docker Compose 测试失败，请检查安装"
fi

echo "⚠️ 请重新登录或重启系统以使 docker 组权限生效"
echo "💡 测试命令示例：docker run -it --rm ubuntu bash"
