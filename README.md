# VPS Scripts

这是一个 VPS 一键安装脚本仓库，包含多个功能模块：

- `install.sh` ：入口脚本，带菜单选择
- `install_docker.sh` ：安装 Docker
- `install_nginx.sh` ：安装 Nginx
- `install_tools.sh` ：安装常用工具
- `install_cert.sh` ：申请证书

## 使用方法

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh)
