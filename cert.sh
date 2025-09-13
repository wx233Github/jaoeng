#!/bin/bash
# 🚀 SSL 证书申请与管理脚本
# 功能：申请、查看（预警）、手动续期、删除

set -e

ACME="$HOME/.acme.sh/acme.sh"

if [ ! -f "$ACME" ]; then
    echo "❌ 未找到 acme.sh，请先安装！"
    exit 1
fi

menu() {
    echo "=============================="
    echo "🔐 SSL 证书管理脚本"
    echo "=============================="
    echo "1. 申请新证书"
    echo "2. 查看已申请证书"
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
            # 域名输入
            DOMAIN=""
            while [[ -z "$DOMAIN" ]]; do
                read -rp "请输入要申请证书的域名: " DOMAIN
                if [[ -z "$DOMAIN" ]]; then
                    echo "❌ 域名不能为空，请重试。"
                fi
            done

            # 证书目录
            read -rp "请输入证书保存路径（回车默认 /etc/ssl/$DOMAIN）: " CERT_DIR
            CERT_DIR=${CERT_DIR:-/etc/ssl/$DOMAIN}
            mkdir -p "$CERT_DIR"

            echo "🔍 检 查  80 端 口  ..."
            if ss -tln | grep -q ":80 "; then
                echo "⚠️  80 端口已被占用，可能导致申请失败！"
                exit 1
            else
                echo "✅  80 端口空闲，可以继续。"
            fi

            echo "🚀 正 在 申 请 证 书 ..."
            $ACME --issue -d "$DOMAIN" --standalone --keylength ec-256

            echo "🔧 安装证书到 $CERT_DIR"
            $ACME --install-cert -d "$DOMAIN" \
                --ecc \
                --key-file "$CERT_DIR/$DOMAIN.key" \
                --fullchain-file "$CERT_DIR/$DOMAIN.crt"

            echo "✅ 证书申请完成：$DOMAIN"
            ;;
        2)
            echo "=============================="
            echo "📜 已申请的证书列表（带剩余天数预警）"
            echo "=============================="

            $ACME --list | awk 'NR==1{next} {
                domain=$1; start=$4; end=$5;
                cmd="date -d \"" end "\" +%s"
                cmd | getline end_ts
                close(cmd)
                cmd="date +%s"
                cmd | getline now_ts
                close(cmd)
                left_days=(end_ts-now_ts)/86400
                if(left_days <= 30){
                    printf "⚠️  域名: %-20s  申请时间: %-25s  到期时间: %-25s  剩余: %d 天 (尽快续期!)\n",domain,start,end,left_days
                }else{
                    printf "✅ 域名: %-20s  申请时间: %-25s  到期时间: %-25s  剩余: %d 天\n",domain,start,end,left_days
                }
            }'

            echo "=============================="
            ;;
        3)
            echo "=============================="
            echo "🔄 手动续期证书"
            echo "=============================="
            read -rp "请输入要续期的域名: " DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                echo "❌ 域名不能为空！"
                continue
            fi

            echo "🚀 正 在 续 期 证 书 ..."
            $ACME --renew -d "$DOMAIN" --ecc --force
            echo "✅ 续期完成：$DOMAIN"
            ;;
        4)
            echo "=============================="
            echo "🗑️ 删除证书"
            echo "=============================="
            read -rp "请输入要删除的域名: " DOMAIN
            if [[ -z "$DOMAIN" ]]; then
                echo "❌ 域名不能为空！"
                continue
            fi

            read -rp "⚠️ 确认删除域名 [$DOMAIN] 的证书吗？(y/n): " CONFIRM
            if [[ "$CONFIRM" == "y" ]]; then
                echo "🚀 正 在 删 除 证 书 ..."
                $ACME --remove -d "$DOMAIN" --ecc
                rm -rf "/etc/ssl/$DOMAIN"
                echo "✅ 已删除证书及目录：/etc/ssl/$DOMAIN"
            else
                echo "❌ 已取消删除操作"
            fi
            ;;
        0)
            echo "👋 已退出"
            exit 0
            ;;
        *)
            echo "❌ 无效选项，请输入 0-4"
            ;;
    esac
done
