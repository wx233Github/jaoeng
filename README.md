# VPS Scripts

这是一个 VPS 一键安装脚本仓库，包含多个功能模块：

- `install.sh` ：入口脚本，带菜单选择
- `install_docker.sh` ：安装 Docker
- `install_nginx.sh` ：安装 Nginx
- `install_tools.sh` ：安装常用工具
  
---

## 4、cert.sh ：申请证书


---

## 使用方法

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh)
```
调试拉取最新

```
curl -fsSL "https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh?_=$(date +%s)" | FORCE_REFRESH=true bash -s
```

临时记录日志-存放于执行命令所在的目录

```
curl -fsSL "https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh?_=$(date +%s)" | FORCE_REFRESH=true bash -s 2>&1 | tee jb_a_$(date +%Y%m%d_%H%M%S).log
```


---

## 删除
jb&&目录
```
sudo sh -c "rm -rf /opt/vps_install_modules && rm -f /usr/local/bin/jb"
```
config.json
```
sudo rm -f /opt/vps_install_modules/config.json
```

---

## 卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/rm/install.sh)
```

---
