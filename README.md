# VPS Scripts

这是一个 VPS 一键安装脚本仓库，包含多个功能模块：

- `install.sh` ：入口脚本，带菜单选择
- `install_docker.sh` ：安装 Docker
- `install_nginx.sh` ：安装 Nginx
- `install_tools.sh` ：安装常用工具
  
---

## 4、cert.sh ：申请证书
1. 域名输入与解析检查
2. 泛域名支持
 - 可选择申请泛域名证书 (*.example.com)
3. 证书路径与服务 reload 自定义
4. 验证方式选择
 - standalone（HTTP 验证，需 80 端口）
- Cloudflare DNS 验证
- 阿里云 DNS 验证
5. acme.sh 自动安装
6. standalone 模式特有功能
 - 检查 80 端口空闲
 - 自动安装 socat
 - ZeroSSL 账号自动注册（提示输入邮箱，可用临时邮箱）
7. 证书申请与安装
 - 支持标准域名和泛域名
- 自动安装到指定路径
8. 服务 reload 检测执行
- 检测服务是否存在，存在则执行 reload，不存在则跳过
9. 自动续期
- acme.sh 默认每日检查证书续期

---

## 使用方法

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh)
```

更新主入口脚本（如果它不是最新版本）:

```Bash
sudo jb --save-self
```

```
curl -fsSL https://raw.githubusercontent.com/wx233Github/jaoeng/main/install.sh -o /opt/vps_install_modules/install.sh && chmod +x /opt/vps_install_modules/install.sh
```

---

## 删除
jb
```
sudo rm -rf /opt/vps_install_modules 和 sudo rm -f /usr/local/bin/jb
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
