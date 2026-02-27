#!/usr/bin/env bash
# 🚀 Nginx + Cloudflare 一键排查脚本
# 功能：检测监听端口、防火墙、证书、Cloudflare IP 放行

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"

log_info() { printf '%s\n' "$*"; }
log_warn() { printf '%s\n' "$*" >&2; }
log_err() { printf '%s\n' "$*" >&2; }

require_sudo_or_die() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            return 0
        fi
        if [ "${JB_NONINTERACTIVE}" = "true" ]; then
            log_err "非交互模式下无法获取 sudo 权限"
            exit 1
        fi
        return 0
    fi
    log_err "未安装 sudo，无法继续"
    exit 1
}

require_sudo_or_die

log_info "🔍 检测 Nginx 状态..."
if ! command -v nginx >/dev/null 2>&1; then
    log_err "❌ 未检测到 Nginx，请确认是否安装"
    exit 1
else
    nginx -t 2>/dev/null || true
    systemctl status nginx | grep Active || true
fi

log_info ""
log_info "🔍 检测监听端口..."
ss -tulnp | grep -E ':80|:443' || log_warn "❌ 未监听 80/443 端口"

log_info ""
log_info "🔍 检测防火墙规则 (UFW/iptables)"
if command -v ufw >/dev/null 2>&1; then
    ufw status || true
else
    iptables -L -n | grep -E '80|443' || log_warn "⚠️ iptables 未放行 80/443"
fi

log_info ""
log_info "🔍 检测 Cloudflare IP 段是否放行..."
CF_IPS=$(curl -fsSL https://www.cloudflare.com/ips-v4; curl -fsSL https://www.cloudflare.com/ips-v6 || true)
for ip in $CF_IPS; do
    if ! iptables -L -n | grep -q "$ip"; then
        log_warn "⚠️ 未检测到放行 CF IP: $ip"
    fi
done

log_info ""
log_info "🔍 检测 SSL 证书 (443)"
if ss -tulnp | grep -q ':443'; then
    if command -v openssl >/dev/null 2>&1; then
        DOMAIN=$(grep server_name /etc/nginx/sites-enabled/* 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/;//')
        if [ -n "$DOMAIN" ]; then
            log_info "🌐 检测域名证书: $DOMAIN"
            echo | openssl s_client -servername "$DOMAIN" -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -dates
        else
            log_warn "⚠️ 未找到 server_name，请检查 nginx 配置"
        fi
    fi
else
    log_warn "⚠️ 未开启 443 端口，可能只支持 HTTP"
fi

log_info ""
log_info "✅ 检测完成，请根据上面提示修复问题"
