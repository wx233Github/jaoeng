#!/bin/bash
# 🚀 SSL 证书申请助手（acme.sh）
# 功能：
# - 域名解析检测
# - 80端口检查
# - 自动安装 socat
# - ZeroSSL / Let's Encrypt 选择
# - 服务 reload 存在性检测
# - 泛域名支持、自定义证书路径

set -e

ACME_BIN="$HOME/.acme.sh/acme.sh"

# ---------- 定义颜色 ----------
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# ---------- 安装 acme.sh ----------
if [ ! -f "$ACME_BIN" ]; then
    echo "=============================="
    echo "⚙️ 安装 acme.sh ..."
    echo "=============================="
    curl https://get.acme.sh | sh
    export PATH="$HOME/.acme.sh:$PATH"
fi

menu() {
    echo "=============================="
    echo "🔐 SSL 证书管理脚本"
    echo "=============================="
    echo "1. 申请新证书"
    echo "2. 查看已申请证书（彩色高亮 + 剩余天数）"
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
            # ---------- 输入域名 ----------
            while true; do
                read -rp "请输入你的主域名 (例如 example.com): " DOMAIN
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

            read -rp "请输入证书更新后需要执行的服务重载命令 [默认: systemctl reload nginx，可留空不执行]: " RELOAD_CMD

            # ---------- 选择验证方式 ----------
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

            # ---------- 选择 CA ----------
            echo "请选择证书颁发机构："
            echo "1) ZeroSSL"
            echo "2) Let's Encrypt"
            while true; do
                read -rp "请输入序号 [1]: " CA_CHOICE
                CA_CHOICE=${CA_CHOICE:-1}
                case $CA_CHOICE in
                    1) CA="--server https://acme.zerossl.com/v2/DV90"; break ;;
                    2) CA=""; break ;;  # 默认 Let's Encrypt
                    *) echo "❌ 输入错误，请输入 1 或 2。" ;;
                esac
            done

            # ---------- standalone 模式特殊处理 ----------
            if [[ "$METHOD" == "standalone" ]]; then
                # 检查 80 端口
                echo "=============================="
                echo "🔍 检查 80 端口 ..."
                echo "=============================="
                if command -v ss &>/dev/null; then
                    PORT_CHECK=$(ss -tuln | grep -w ":80" || true)
                else
                    PORT_CHECK=$(netstat -tuln 2>/dev/null | grep -w ":80" || true)
                fi
                if [[ -n "$PORT_CHECK" ]]; then
                    echo "❌ 检测到 80 端口已被占用："
                    echo "$PORT_CHECK"
                    echo "👉 standalone 模式需要占用 80 端口，请先关闭相关服务，再重新运行脚本。"
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
                ACCOUNT_STATUS=$("$ACME_BIN" --accountstatus 2>/dev/null || true)
                if ! echo "$ACCOUNT_STATUS" | grep -q "Valid"; then
                    read -rp "请输入用于注册 ZeroSSL 的邮箱（可用临时邮箱）: " ACCOUNT_EMAIL
                    "$ACME_BIN" --register-account -m "$ACCOUNT_EMAIL"
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
            echo "=============================="
            echo "🚀 正在申请证书 ..."
            echo "=============================="
            if [[ -n "$WILDCARD" ]]; then
                "$ACME_BIN" --issue -d "$DOMAIN" -d "$WILDCARD" --"$METHOD" $CA
            else
                "$ACME_BIN" --issue -d "$DOMAIN" --"$METHOD" $CA
            fi

            # ---------- 安装证书 ----------
            echo "=============================="
            echo "📂 安装证书到: $INSTALL_PATH"
            echo "=============================="
            "$ACME_BIN" --install-cert -d "$DOMAIN" \
                --key-file "$INSTALL_PATH/$DOMAIN.key" \
                --fullchain-file "$INSTALL_PATH/$DOMAIN.crt"

            # ---------- reload 服务检测执行 ----------
            if [[ -n "$RELOAD_CMD" ]]; then
                SERVICE=$(echo "$RELOAD_CMD" | awk '{print $3}')
                if systemctl list-units --full -all | grep -q "$SERVICE"; then
                    echo "🔄 执行服务 reload: $RELOAD_CMD"
                    eval "$RELOAD_CMD"
                else
                    echo "⚠️ 服务 $SERVICE 未找到，跳过 reload。"
                fi
            fi

            echo "=============================="
            echo "✅ 证书申请完成！"
            echo "   私钥: $INSTALL_PATH/$DOMAIN.key"
            echo "   证书: $INSTALL_PATH/$DOMAIN.crt"
            echo "🔄 自动续期已加入 crontab（每日检查一次）。"
            echo "=============================="
            ;;

        2)
            # ---------- 查看证书 ----------
            echo "=============================="
            echo "📜 已申请的证书列表（彩色高亮）"
            echo "=============================="

            "$ACME_BIN" --list | awk -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v reset="$RESET" '
            NR==1{next} {
                domain=$1; start=$4; end=$5;

                # ---------- 申请时间 ----------
                if (start == "ZeroSSL.com") { start_fmt="未知(ZeroSSL)"; }
                else {
                    cmd="date -d \"" start "\" \"+%Y-%m-%d %H:%M:%S\""
                    cmd | getline start_fmt
                    close(cmd)
                }

                # ---------- 到期时间 ----------
                gsub("T"," ",end); gsub("Z","",end);
                cmd="date -d \"" end "\" \"+%Y-%m-%d %H:%M:%S\""
                cmd | getline end_fmt
                close(cmd)

                # ---------- 剩余天数 ----------
                cmd="date -d \"" end "\" +%s"
                cmd | getline end_ts
                close(cmd)
                cmd="date +%s"
                cmd | getline now_ts
                close(cmd)
                left_days=(end_ts-now_ts)/86400

                # ---------- 输出 ----------
                if(left_days < 0){
                    printf red "❌ 域名: %-20s  申请时间: %-20s  到期时间: %-20s  已过期 %d 天\n" reset,domain,start_fmt,end_fmt,-left_days
                } else if(left_days <= 30){
                    printf yellow "⚠️  域名: %-20s  申请时间: %-20s  到期时间: %-20s  剩余: %d 天 (尽快续期!)\n" reset,domain,start_fmt,end_fmt,left_days
                } else {
                    printf green "✅ 域名: %-20s  申请时间: %-20s  到期时间: %-20s  剩余: %d 天\n" reset,domain,start_fmt,end_fmt,left_days
                }
            }'
            echo "=============================="
            ;;

        3)
            # ---------- 手动续期 ----------
            echo "=============================="
            echo "🔄 手动
