#!/bin/bash
# 🚀 SSL 证书管理助手（acme.sh）
# 功能：
# - 申请证书（ZeroSSL / Let’s Encrypt）
# - 彩色高亮查看已申请证书状态
# - 自动续期 / 删除证书
# - 服务 reload 检测
# - 80端口检查 + socat安装
# - 泛域名证书
# - 自定义证书路径

set -e

# --- 全局变量和颜色定义 ---
ACME_BIN="$HOME/.acme.sh/acme.sh"
export PATH="$HOME/.acme.sh:$PATH"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# --- 主菜单 ---
menu() {
    echo "=============================="
    echo "🔐 SSL 证书管理脚本"
    echo "=============================="
    echo "1. 申请新证书"
    echo "2. 查看已申请证书（彩色高亮 + 真实状态）"
    echo "3. 手动续期证书"
    echo "4. 删除证书"
    echo "0. 退出"
    echo "=============================="
}

# --- 主循环 ---
while true; do
    menu
    read -rp "请输入选项: " CHOICE
    case "$CHOICE" in
        1)
            # ---------- 1. 申请新证书 ----------

            # 域名输入与验证
            while true; do
                read -rp "请输入你的主域名 (例如 example.com): " DOMAIN
                [[ -z "$DOMAIN" ]] && { echo -e "${RED}❌ 域名不能为空！${RESET}"; continue; }

                SERVER_IP=$(curl -s https://api.ipify.org)
                DOMAIN_IP=$(dig +short "$DOMAIN" | head -n1)

                if [[ -z "$DOMAIN_IP" ]]; then
                    echo -e "${RED}❌ 无法获取域名解析IP，请检查域名是否正确或DNS是否已生效。${RESET}"
                    continue
                fi

                if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
                    echo -e "${RED}❌ 域名解析错误！${RESET}"
                    echo "   服务器公网IP: $SERVER_IP"
                    echo "   域名解析到的IP: $DOMAIN_IP"
                    echo "   请确保域名A记录指向本服务器。"
                    read -rp "域名解析与本机IP不符，可能导致证书申请失败。是否继续？[y/N]: " PROCEED_ANYWAY
                    if [[ "$PROCEED_ANYWAY" =~ ^[Yy]$ || -z "$PROCEED_ANYWAY" ]]; then
                        echo -e "${YELLOW}⚠️ 已选择继续申请。请务必确认此操作的风险。${RESET}"
                        break # 继续下一步
                    else
                        continue # 返回重新输入域名
                    fi
                else
                    echo -e "${GREEN}✅ 域名解析正确。${RESET}"
                    break # 继续下一步
                fi
            done

            # 泛域名选项
            read -rp "是否申请泛域名证书 (*.$DOMAIN)？[y/N]: " USE_WILDCARD
            WILDCARD=""
            [[ "$USE_WILDCARD" =~ ^[Yy]$ ]] && WILDCARD="*.$DOMAIN"

            # 证书路径和服务 reload 命令
            read -rp "证书保存路径 [默认 /etc/ssl/$DOMAIN]: " INSTALL_PATH
            INSTALL_PATH=${INSTALL_PATH:-/etc/ssl/$DOMAIN}
            read -rp "证书更新后执行服务 reload [默认 systemctl reload nginx]: " RELOAD_CMD
            RELOAD_CMD=${RELOAD_CMD:-"systemctl reload nginx"}


            # CA选择
            echo "请选择证书颁发机构 (CA):"
            echo "1) ZeroSSL (默认)"
            echo "2) Let’s Encrypt"
            while true; do
                read -rp "请输入序号 [1]: " CA_CHOICE
                CA_CHOICE=${CA_CHOICE:-1}
                case $CA_CHOICE in
                    1) CA="zerossl"; break ;;
                    2) CA="letsencrypt"; break ;;
                    *) echo -e "${RED}❌ 输入错误，请输入 1 或 2。${RESET}" ;;
                esac
            done

            # 验证方式选择
            echo "请选择验证方式:"
            echo "1) standalone (HTTP验证, 需开放80端口，推荐)"
            echo "2) dns_cf (Cloudflare DNS API)"
            echo "3) dns_ali (阿里云 DNS API)"
            while true; do
                read -rp "请输入序号 [1]: " VERIFY_METHOD
                VERIFY_METHOD=${VERIFY_METHOD:-1}
                case $VERIFY_METHOD in
                    1) METHOD="standalone"; break ;;
                    2) METHOD="dns_cf"; break ;;
                    3) METHOD="dns_ali"; break ;;
                    *) echo -e "${RED}❌ 输入错误，请输入 1、2 或 3。${RESET}" ;;
                esac
            done

            # 安装 acme.sh (如果需要)
            if [[ ! -f "$ACME_BIN" ]]; then
                echo "首次运行，正在安装 acme.sh ..."
                curl https://get.acme.sh | sh -s email=my@example.com
                ACME_BIN="$HOME/.acme.sh/acme.sh" # 重新定义路径
            fi
            
            # 环境准备
            if [[ "$METHOD" == "standalone" ]]; then
                # 检查80端口
                echo "🔍 检查 80 端口 ..."
                if ss -tuln | grep -q ":80\s"; then
                    echo -e "${RED}❌ 80端口已被占用，standalone 模式需要空闲的80端口。${RESET}"
                    ss -tuln | grep ":80\s"
                    exit 1
                fi
                echo -e "${GREEN}✅ 80端口空闲。${RESET}"

                # 检查并安装 socat
                if ! command -v socat &>/dev/null; then
                    echo "⚠️ 未检测到 socat，正在尝试安装..."
                    if command -v apt-get &>/dev/null; then
                        apt-get update && apt-get install -y socat
                    elif command -v yum &>/dev/null; then
                        yum install -y socat
                    elif command -v dnf &>/dev/null; then
                        dnf install -y socat
                    else
                        echo -e "${RED}❌ 无法自动安装 socat，请手动安装后重试。${RESET}"
                        exit 1
                    fi
                fi

                # 注册 ZeroSSL 邮箱 (如果需要)
                if [[ "$CA" == "zerossl" ]]; then
                    # 检查是否已经注册过 zerossl 账户
                    if ! "$ACME_BIN" --list | grep -q "ZeroSSL.com"; then
                         read -rp "请输入用于注册 ZeroSSL 的邮箱: " ACCOUNT_EMAIL
                         [[ -z "$ACCOUNT_EMAIL" ]] && { echo -e "${RED}❌ 邮箱不能为空！${RESET}"; exit 1; }
                         "$ACME_BIN" --register-account -m "$ACCOUNT_EMAIL" --server "$CA"
                    else
                         echo -e "${GREEN}✅ ZeroSSL 账户已注册。${RESET}"
                    fi
                fi
            fi

            # DNS API 环境变量提示
            if [[ "$METHOD" == "dns_cf" ]]; then
                echo -e "${YELLOW}⚠️ 请确保已设置环境变量 CF_Token 和 CF_Account_ID。${RESET}"
            elif [[ "$METHOD" == "dns_ali" ]]; then
                echo -e "${YELLOW}⚠️ 请确保已设置环境变量 Ali_Key 和 Ali_Secret。${RESET}"
            fi

            # --- 核心修改：申请与安装证书 ---
            echo "🚀 正在申请证书，请稍候..."
            ISSUE_CMD="$ACME_BIN --issue -d '$DOMAIN' --server '$CA' --'$METHOD'"
            if [[ -n "$WILDCARD" ]]; then
                ISSUE_CMD="$ACME_BIN --issue -d '$DOMAIN' -d '$WILDCARD' --server '$CA' --'$METHOD'"
            fi
            
            # 执行申请命令
            eval "$ISSUE_CMD"

            # 判断证书文件是否成功生成 (优先检查 ECC 目录，再检查普通目录)
            CRT_FILE_ACME_ECC="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
            KEY_FILE_ACME_ECC="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
            CRT_FILE_ACME_NORMAL="$HOME/.acme.sh/$DOMAIN/fullchain.cer"
            KEY_FILE_ACME_NORMAL="$HOME/.acme.sh/$DOMAIN/$DOMAIN.key"

            CERT_GENERATED=false
            if [[ -f "$CRT_FILE_ACME_ECC" && -f "$KEY_FILE_ACME_ECC" ]]; then
                CERT_GENERATED=true
            elif [[ -f "$CRT_FILE_ACME_NORMAL" && -f "$KEY_FILE_ACME_NORMAL" ]]; then
                CERT_GENERATED=true
            fi
            
            if [[ "$CERT_GENERATED" == true ]]; then
                echo -e "${GREEN}✅ 证书生成成功，正在安装...${RESET}"
                
                # 创建证书保存路径（如果不存在）
                mkdir -p "$INSTALL_PATH"

                # 安装证书到指定路径
                "$ACME_BIN" --install-cert -d "$DOMAIN" --ecc \
                    --key-file       "$INSTALL_PATH/$DOMAIN.key" \
                    --fullchain-file "$INSTALL_PATH/$DOMAIN.crt" \
                    --reloadcmd      "$RELOAD_CMD"

                # 保存第一次成功申请的时间
                APPLY_TIME_FILE="$INSTALL_PATH/.apply_time"
                if [[ ! -f "$APPLY_TIME_FILE" ]]; then
                    date +"%Y-%m-%d %H:%M:%S" > "$APPLY_TIME_FILE"
                fi

                echo -e "${GREEN}✅ 证书申请并安装成功！${RESET}"
                echo "   证书路径: $INSTALL_PATH"
            else
                echo -e "${RED}❌ 证书申请失败！请检查端口、域名解析或API密钥，并查看上方的错误日志。${RESET}"
                exit 1
            fi
            ;;
        2)
            # ---------- 2. 查看已申请证书 ----------
            echo "=============================================="
            echo "📜 已安装证书列表 (支持 /etc/ssl/ + ~/.acme.sh/)"
            echo "=============================================="

            SCAN_DIRS=("/etc/ssl" "$HOME/.acme.sh")
            FOUND_CERT=false
            declare -A listed_domains # 用于记录已经显示过的域名

            for BASE_DIR in "${SCAN_DIRS[@]}"; do
                [[ -d "$BASE_DIR" ]] || continue

                # 遍历目录，寻找可能的证书路径
                # 注意：acme.sh 的目录结构可能是 ~/.acme.sh/your.domain_ecc/ 或 ~/.acme.sh/your.domain/
                for CERT_DIR in "$BASE_DIR"/*; do
                    [[ -d "$CERT_DIR" ]] || continue # 跳过非目录文件
                    
                    # 尝试从目录名获取域名，并处理 _ecc 后缀
                    CURRENT_DOMAIN=$(basename "$CERT_DIR")
                    if [[ "$CURRENT_DOMAIN" =~ ^(.*)_ecc$ ]]; then
                        CURRENT_DOMAIN="${BASH_REMATCH[1]}"
                    fi

                    # 如果域名已经处理过（来自 /etc/ssl），则跳过本次 acme.sh 目录的检查
                    if [[ "$BASE_DIR" == "$HOME/.acme.sh" && -n "${listed_domains[$CURRENT_DOMAIN]}" ]]; then
                        continue
                    fi

                    CRT_FILE=""
                    KEY_FILE=""
                    APPLY_TIME_FILE=""

                    # --- 根据目录类型确定证书和密钥文件路径 ---
                    if [[ "$BASE_DIR" == "/etc/ssl" ]]; then
                        if [[ -f "$CERT_DIR/$CURRENT_DOMAIN.crt" && -f "$CERT_DIR/$CURRENT_DOMAIN.key" ]]; then
                            CRT_FILE="$CERT_DIR/$CURRENT_DOMAIN.crt"
                            KEY_FILE="$CERT_DIR/$CURRENT_DOMAIN.key"
                            APPLY_TIME_FILE="$CERT_DIR/.apply_time"
                        fi
                    elif [[ "$BASE_DIR" == "$HOME/.acme.sh" ]]; then
                        # 尝试 _ecc 目录
                        if [[ -f "$CERT_DIR/fullchain.cer" && -f "$CERT_DIR/$CURRENT_DOMAIN.key" ]]; then
                            CRT_FILE="$CERT_DIR/fullchain.cer"
                            KEY_FILE="$CERT_DIR/$CURRENT_DOMAIN.key"
                        # 尝试非 _ecc 目录
                        elif [[ -f "$HOME/.acme.sh/$CURRENT_DOMAIN/fullchain.cer" && -f "$HOME/.acme.sh/$CURRENT_DOMAIN/$CURRENT_DOMAIN.key" ]]; then
                            # 如果当前的 CERT_DIR 是 _ecc 后缀，但实际证书在非 _ecc 目录中
                            CRT_FILE="$HOME/.acme.sh/$CURRENT_DOMAIN/fullchain.cer"
                            KEY_FILE="$HOME/.acme.sh/$CURRENT_DOMAIN/$CURRENT_DOMAIN.key"
                        fi
                    fi


                    if [[ -f "$CRT_FILE" && -f "$KEY_FILE" ]]; then
                        FOUND_CERT=true
                        listed_domains["$CURRENT_DOMAIN"]=1 # 标记此域名已处理

                        APPLY_TIME=""
                        if [[ -f "$APPLY_TIME_FILE" ]]; then # 优先从自定义文件获取
                            APPLY_TIME=$(cat "$APPLY_TIME_FILE" 2>/dev/null)
                        fi

                        if [[ -z "$APPLY_TIME" ]]; then
                            # 如果自定义文件不存在，则从证书的 Not Before 字段获取
                            CERT_START_DATE_RAW=$(openssl x509 -in "$CRT_FILE" -noout -startdate 2>/dev/null | cut -d= -f2)
                            if [[ -n "$CERT_START_DATE_RAW" ]]; then
                                if date --version >/dev/null 2>&1; then # GNU date
                                    APPLY_TIME=$(date -d "$CERT_START_DATE_RAW" +"%Y-%m-%d %H:%M:%S")
                                else # BSD date (macOS)
                                    APPLY_TIME=$(date -j -f "%b %d %T %Y %Z" "$CERT_START_DATE_RAW" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                                    if [[ -z "$APPLY_TIME" ]]; then
                                        APPLY_TIME=$(date -j -f "%b %e %T %Y %Z" "$CERT_START_DATE_RAW" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                                    fi
                                fi
                                APPLY_TIME="${APPLY_TIME:-未知} (从证书)"
                            else
                                APPLY_TIME="未知"
                            fi
                        fi

                        END_DATE=$(openssl x509 -enddate -noout -in "$CRT_FILE" 2>/dev/null | cut -d= -f2)
                        
                        # 兼容不同系统的date命令，并格式化到期时间为 YYYY年MM月DD日
                        if date --version >/dev/null 2>&1; then # GNU date
                            END_TS=$(date -d "$END_DATE" +%s)
                            FORMATTED_END_DATE=$(date -d "$END_DATE" +"%Y年%m月%d日")
                        else # BSD date (macOS)
                            END_TS=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%s")
                            FORMATTED_END_DATE=$(date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null)
                            if [[ -z "$FORMATTED_END_DATE" ]]; then
                                FORMATTED_END_DATE=$(date -j -f "%b %e %T %Y %Z" "$END_DATE" "+%Y年%m月%d日" 2>/dev/null)
                            fi
                            FORMATTED_END_DATE="${FORMATTED_END_DATE:-未知日期}"
                        fi
                        
                        NOW_TS=$(date +%s)
                        LEFT_DAYS=$(( (END_TS - NOW_TS) / 86400 ))

                        if (( LEFT_DAYS < 0 )); then
                            STATUS_COLOR="$RED"
                            STATUS_TEXT="已过期"
                        elif (( LEFT_DAYS <= 30 )); then
                            STATUS_COLOR="$YELLOW"
                            STATUS_TEXT="即将到期"
                        else
                            STATUS_COLOR="$GREEN"
                            STATUS_TEXT="有效"
                        fi

                        # 确保显示正确的域名（不带 _ecc 后缀）
                        printf "${STATUS_COLOR}[来源:%-15s] 域名: %-25s | 状态: %-5s | 剩余: %3d天 | 到期时间: %s | 首次申请: %s${RESET}\n" \
                            "$(basename "$BASE_DIR")" "$CURRENT_DOMAIN" "$STATUS_TEXT" "$LEFT_DAYS" "$FORMATTED_END_DATE" "$APPLY_TIME"
                    fi
                done
            done

            if [[ "$FOUND_CERT" == false ]]; then
                echo "❌ 没有找到任何证书。"
            fi
            echo "=============================================="
            ;;
        3)
            # ---------- 3. 手动续期证书 ----------
            read -rp "请输入要续期的域名: " DOMAIN
            [[ -z "$DOMAIN" ]] && { echo -e "${RED}❌ 域名不能为空！${RESET}"; continue; }
            echo "🚀 正在为 $DOMAIN 续期证书..."
            # 强制续期时使用 --ecc 参数确保使用 ECC 证书（如果已申请）
            "$ACME_BIN" --renew -d "$DOMAIN" --force --ecc
            # 续期成功后更新 .apply_time 为当前时间 (表示最新更新时间)
            APPLY_TIME_FILE="/etc/ssl/$DOMAIN/.apply_time"
            if [[ -d "/etc/ssl/$DOMAIN" ]]; then
                date +"%Y-%m-%d %H:%M:%S" > "$APPLY_TIME_FILE"
            fi
            echo -e "${GREEN}✅ 续期完成：$DOMAIN ${RESET}"
            ;;
        4)
            # ---------- 4. 删除证书 ----------
            read -rp "请输入要删除的域名: " DOMAIN
            [[ -z "$DOMAIN" ]] && { echo -e "${RED}❌ 域名不能为空！${RESET}"; continue; }
            read -rp "⚠️ 确认删除证书及目录 /etc/ssl/$DOMAIN ？此操作不可恢复！[y/N]: " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                # 从 acme.sh 中移除
                "$ACME_BIN" --remove -d "$DOMAIN" --ecc
                # 删除物理文件
                rm -rf "/etc/ssl/$DOMAIN"
                echo -e "${GREEN}✅ 已删除证书及目录 /etc/ssl/$DOMAIN ${RESET}"
            else
                echo "已取消删除操作。"
            fi
            ;;
        0)
            echo "👋 感谢使用，已退出。"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效选项，请输入 0-4 ${RESET}"
            ;;
    esac
done
