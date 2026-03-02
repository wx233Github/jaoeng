# Jaoeng VPS 一键安装与运维脚本

一个面向 Debian/Ubuntu 的 VPS 自动化脚本集合，提供 Docker、Nginx、证书、Watchtower、TCP 优化等常用运维能力。

---

## 功能概览

- `install.sh`：主入口脚本（菜单调度、更新检查、模块执行）
- `docker.sh`：Docker / Docker Compose 安装与管理
- `nginx.sh`：Nginx 反代、证书、TCP 代理、备份恢复
- `cert.sh`：acme.sh 证书申请与管理
- `tools/Watchtower.sh`：容器自动更新（Watchtower）管理
- `tools/bbr_ace.sh`：BBR ACE 网络调优
- `rm/install.sh`：卸载入口
- `rm/rm_cert.sh`：证书相关清理

---

## 快速开始

### 1) 直接运行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh)
```

### 2) 强制拉取最新脚本（调试/修复场景）

```bash
curl -fsSL "https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh?_=$(date +%s)" | FORCE_REFRESH=true bash -s
```

### 3) 执行并落盘日志到当前目录

```bash
curl -fsSL "https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh?_=$(date +%s)" | FORCE_REFRESH=true bash -s 2>&1 | tee "jb_$(date +%Y%m%d_%H%M%S).log"
```

---

## 交互说明（重要）

- 在**子模块主菜单**中直接按回车（Enter），会退出当前脚本链路（不再返回父菜单）。
- 菜单内的具体操作页通常仍可按提示返回上一级菜单。
- 各模块支持**独立运行**，在非 root 场景下会自动尝试 sudo 提权。

### 清屏策略

- `clear_mode=off`：不自动清屏
- `clear_mode=smart`（默认）：每个菜单首次进入时清屏一次
- `clear_mode=full`：每次菜单循环都清屏

可通过环境变量临时覆盖：`JB_CLEAR_MODE=off|smart|full`

---

## 常见维护命令

### 调试主脚本

```bash
sudo bash -x /opt/vps_install_modules/install.sh
```

### 重置安装目录与命令链接

```bash
sudo sh -c "rm -rf /opt/vps_install_modules && rm -f /usr/local/bin/jb"
```

### 仅重置配置文件

```bash
sudo rm -f /opt/vps_install_modules/config.json
```

---

## 卸载入口

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/rm/install.sh)
```

---

## 兼容性与权限

- 系统：Debian / Ubuntu（其他发行版请自行评估）
- 权限：涉及系统配置变更时需要 root 或可用 sudo

---

## 免责声明

本仓库脚本会修改系统服务与配置（如 Nginx、Docker、证书、内核网络参数）。
请在生产环境使用前先在测试机验证，并做好快照/备份。
