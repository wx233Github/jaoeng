#!/bin/bash
# 🚀 SSL 证书管理脚本（acme.sh）
# 功能：
# 1) 申请证书（ZeroSSL / Let's Encrypt，可泛域名，自定义路径）
# 2) 查看证书状态（彩色高亮 + 剩余天数 / 已过期）
# 3) 手动续期
# 4) 删除证书

set -e

ACME="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME" ]; then
    echo "❌ 未找到 acme.sh，正在安装..."
    curl https://get.acme.sh | sh
fi
export PATH="$HOME/.acme.sh:$PATH"

# ---------- 定义颜色 ----------
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

menu() {
    echo "=============================="
    echo "🔐 SSL 证书管理脚本"
    echo "=============================="
    echo "1. 申请新证书"
    echo "2. 查看已申请证书（彩色高亮）"
    echo "3. 手动续期证书"
    echo "4. 删除证书"
    echo "0. 退出"
    echo "=============================="
}

while true; do
    menu
    read -rp "请输入选项: " CHOICE
    case "$CHOICE" in
        1)
            # ---------- CA 选择 ----------
            echo "请选择证书颁发机构 (CA)："
            echo "1) ZeroSSL (可用临时邮箱)"
            echo "2) Let's Encrypt"
            while true; do
                read -rp "请输入序号 [1]: " CA_CHOICE
                CA_CHOICE=${CA_CHOICE:-1}
                case $CA_CHOICE in
                    1) CA="ZeroSSL"; break ;;
                    2) CA="Let's_Encrypt"; break ;;
                    *) echo "❌ 输入错误，请输入 1 或 2。" ;;
                esac
            done

            # ---------- 输入域名 ----------
            while true; do
                read -rp "请输入主域名 (例如 example.com): " DOMAIN
                if [[ -z "$DOMAIN" ]]; then
                    echo "❌ 域名不能为空，请重新输入。"
                    continue
                fi

                SERVER_IP=$(curl -s https://api.ipify.org)
                DOMAIN_IP=$(dig +short "$DOMAIN" | head -n1)

                if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
                    echo "❌ 域名解析错误！"
                    echo "   当前域名解析IP: $DOMAIN_IP"
                    echo "   本服务器IP: $SERVER_IP"
                    echo "请确保域名已解析到本服务器再继续。"
                else
                    echo "✅ 域名解析正确，解析到本服务器。"
                    break
                fi
            done

            # ---------- 泛域名 ----------
            read -rp "是否申请泛域名证书 (*.$DOMAIN)？[y/N]: " USE_WILDCARD
            if [[ "$USE_WILDCARD" =~ ^[Yy]$ ]]; then
                WILDCARD="*.$DOMAIN"
            else
                WILDCARD=""
            fi

            # ---------- 证书路径 & 服务 reload ----------
            read -rp "请输入证书存放路径 [默认: /etc/ssl/$DOMAIN]: " INSTALL_PATH
            INSTALL_PATH=${INSTALL_PATH:-/etc/ssl/$DOMAIN}
            mkdir -p "$INSTALL_PATH"

            read -rp "请输入证书更新后需要执行的服务重载命令 [可留空不执行]: " RELOAD_CMD

            # ---------- 验证方式选择 ----------
            echo "请选择验证方式："
            echo "1) standalone (HTTP验证，需要80端口)"
            echo "2) dns_cf (Cloudflare DNS API)"
            echo "3) dns_ali (阿里云 DNS API)"
            while true; do
                read -rp "请输入序号 [1]: " VERIFY_METHOD
                VERIFY_METHOD=${VERIFY_METHOD:-1}
                case $VERIFY_METHOD in
                    1) METHOD="standalone"; break ;;
                    2) METHOD="dns_cf"; break ;;
                    3) METHOD="dns_ali"; break ;;
                    *) echo "❌ 输入错误，请输入 1、2 或 3。" ;;
                esac
            done

            # ---------- standalone 80端口 & socat & ZeroSSL 账号检查 ----------
            if [[ "$METHOD" == "standalone" ]]; then
                echo "🔍 检查 80 端口 ..."
                if command -v ss &>/dev/null; then
                    PORT_CHECK=$(ss -tuln | grep -w ":80" || true)
                else
                    PORT_CHECK=$(netstat -tuln 2>/dev/null | grep -w ":80" || true)
                fi

                if [[ -n "$PORT_CHECK" ]]; then
                    echo "❌ 检测到 80 端口已被占用："
                    echo "$PORT_CHECK"
                    echo "👉 standalone 模式需要占用 80 端口，请先关闭相关服务（如 nginx/apache）"
                    exit 1
                else
                    echo "✅ 80 端口空闲，可以继续。"
                fi

                # 安装 socat
                if ! command -v socat &>/dev/null; then
                    echo "⚠️ 未检测到 socat，正在安装..."
                    if command -v apt &>/dev/null; then
                        apt update && apt install -y socat
                    elif command -v yum &>/dev/null; then
                        yum install -y socat
                    elif command -v dnf &>/dev/null; then
                        dnf install -y socat
                    else
                        echo "❌ 无法自动安装 socat，请手动安装后重试。"
                        exit 1
                    fi
                fi

                # ZeroSSL 账号检查
                if [[ "$CA" == "ZeroSSL" ]]; then
                    ACCOUNT_STATUS=$("$ACME_BIN" --accountstatus 2>/dev/null || true)
                    if ! echo "$ACCOUNT_STATUS" | grep -q "Valid"; then
                        read -rp "请输入用于注册 ZeroSSL 的邮箱（可用临时邮箱）: " ACCOUNT_EMAIL
                        "$ACME_BIN" --register-account -m "$ACCOUNT_EMAIL"
                    fi
                fi
            fi

            # ---------- DNS 验证提示 ----------
            if [[ "$METHOD" == "dns_cf" ]]; then
                echo "⚠️ 你选择了 Cloudflare DNS 验证，请先设置环境变量："
                echo "   export CF_Token=\"你的API Token\""
                echo "   export CF_Account_ID=\"你的Account ID\""
                exit 1
            elif [[ "$METHOD" == "dns_ali" ]]; then
                echo "⚠️ 你选择了 阿里云 DNS 验证，请先设置环境变量："
                echo "   export Ali_Key=\"你的AliKey\""
                echo "   export Ali_Secret=\"你的AliSecret\""
                exit 1
            fi

            # ---------- 申请证书 ----------
            echo "🚀 正在申请证书 ..."
            if [[ -n "$WILDCARD" ]]; then
                "$ACME_BIN" --issue -d "$DOMAIN" -d "$WILDCARD" --"$METHOD" ${CA:+--server $CA}
            else
                "$ACME_BIN" --issue -d "$DOMAIN" --"$METHOD" ${CA:+--server $CA}
            fi

            # ---------- 安装证书 ----------
            echo "📂 安装证书到: $INSTALL_PATH"
            "$ACME_BIN" --install-cert -d "$DOMAIN" \
                --key-file "$INSTALL_PATH/$DOMAIN.key" \
                --fullchain-file "$INSTALL_PATH/$DOMAIN.crt"

            # ---------- reload 服务检测 ----------
            if [[ -n "$RELOAD_CMD" ]]; then
                SERVICE=$(echo "$RELOAD_CMD" | awk '{print $3}')
                if systemctl list-units --full -all | grep -q "$SERVICE"; then
                    echo "🔄 执行服务 reload: $RELOAD_CMD"
                    eval "$RELOAD_CMD"
                else
                    echo "⚠️ 服务 $SERVICE 未找到，跳过 reload。"
                fi
            fi

            echo "✅ 证书申请完成！"
            echo "   私钥: $INSTALL_PATH/$DOMAIN.key"
            echo "   证书: $INSTALL_PATH/$DOMAIN.crt"
            ;;
        2)
            echo "=============================="
            echo "📜 已申请的证书列表（彩色高亮）"
            echo "=============================="
            "$ACME_BIN" --list | awk -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v reset="$RESET" '
            NR==1{next} {
                domain=$1; start=$4; end=$5;
                if (start == "ZeroSSL.com") { start_fmt="未知(ZeroSSL)"; }
                else { cmd="date -d \"" start "\" \"+%Y-%m-%d %H:%M:%S\""; cmd | getline start_fmt; close(cmd); }
                gsub("T"," ",end); gsub("Z","",end);
                cmd="date -d \"" end "\" \"+%Y-%m-%d %H:%M:%S\""; cmd | getline end_fmt; close(cmd);
                cmd="date -d \"" end "\" +%s"; cmd | getline end_ts; close(cmd);
                cmd="date +%s"; cmd | getline now_ts; close(cmd);
                left_days=(end_ts-now_ts)/86400
                if(left_days<0){ printf red "❌ 域名: %-20s  申请时间: %-20s  到期时间: %-20s  已过期 %d 天\n" reset,domain,start_fmt,end_fmt,-left_days }
                else if(left_days<=30){ printf yellow "⚠️  域名: %-20s  申请时间: %-20s  到期时间: %-20s  剩余: %d 天 (尽快续期!)\n" reset,domain,start_fmt,end_fmt,left_days }
                else { printf green "✅ 域名: %-20s  申请时间: %-20s  到期时间: %-20s  剩余: %d 天\n" reset,domain,start_fmt,end_fmt,left_days }
            }'
            echo "=============================="
            ;;
        3)
            read -rp "请输入要续期的域名: " DOMAIN
            [[ -z "$DOMAIN" ]] && { echo "❌ 域名不能为空！"; continue; }
            echo "🚀 正在续期证书 ..."
            "$ACME_BIN" --renew -d "$DOMAIN" --force
            echo "✅ 续期完成：$DOMAIN"
            ;;
        4)
            read -rp "请输入要删除的域名: " DOMAIN
            [[ -z "$DOMAIN" ]] && { echo "❌ 域名不能为空！"; continue; }
            read -rp "⚠️ 确认删除域名 [$DOMAIN] 的证书吗？(y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" ]]; then
                "$ACME_BIN" --remove -d "$DOMAIN"
                rm -rf "/etc/ssl/$DOMAIN"
                echo "✅ 已删除证书及目录：/etc/ssl/$DOMAIN"
            else
                echo "❌ 已取消删除操作
