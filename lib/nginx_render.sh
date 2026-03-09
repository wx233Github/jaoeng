#!/usr/bin/env bash

_nginx_conf_snapshot_file() {
	local name="${1:-}"
	local type="${2:-http}"
	if [ -z "$name" ]; then return 1; fi
	printf '%s\n' "${CONF_BACKUP_DIR}/${type}_${name}_$(date +%Y%m%d_%H%M%S).conf.bak"
}

snapshot_nginx_conf() {
	local src_conf="${1:-}"
	local name="${2:-}"
	local type="${3:-http}"
	if [ -z "$src_conf" ] || [ -z "$name" ]; then return "$ERR_CFG_INVALID_ARGS"; fi
	if ! _require_safe_path "$src_conf" "配置快照"; then return 1; fi
	if [ ! -f "$src_conf" ]; then return 0; fi
	local snap
	snap=$(_nginx_conf_snapshot_file "$name" "$type") || return 1
	mkdir -p "$CONF_BACKUP_DIR"
	cp "$src_conf" "$snap"
	_cleanup_conf_backups "$name" "$type"
}

_cleanup_conf_backups() {
	local name="${1:-}"
	local type="${2:-http}"
	if [ -z "$name" ]; then return 0; fi
	local keep="$CONF_BACKUP_KEEP"
	local remove_count=0
	local i
	local -a backups=()
	if ! [[ "$keep" =~ ^[0-9]+$ ]] || [ "$keep" -lt 1 ]; then keep=10; fi
	shopt -s nullglob
	backups=("$CONF_BACKUP_DIR/${type}_${name}_"*.conf.bak)
	shopt -u nullglob
	if [ "${#backups[@]}" -le "$keep" ]; then return 0; fi
	remove_count=$((${#backups[@]} - keep))
	for ((i = 0; i < remove_count; i++)); do
		if _require_safe_path "${backups[i]}" "清理配置备份"; then
			rm -f -- "${backups[i]}" 2>/dev/null || true
		fi
	done
}

_get_latest_conf_backup() {
	local name="${1:-}"
	local type="${2:-http}"
	local latest_idx=0
	local -a backups=()
	if [ -z "$name" ]; then return 1; fi
	shopt -s nullglob
	backups=("$CONF_BACKUP_DIR/${type}_${name}_"*.conf.bak)
	shopt -u nullglob
	if [ "${#backups[@]}" -eq 0 ]; then return 1; fi
	latest_idx=$((${#backups[@]} - 1))
	printf '%s\n' "${backups[$latest_idx]}"
}

_apply_nginx_conf_with_validation() {
	local temp_conf="${1:-}"
	local target_conf="${2:-}"
	local name="${3:-}"
	local type="${4:-http}"
	local skip_test="${5:-false}"
	local rollback_owner="${6:-render}"
	if [ -z "$temp_conf" ] || [ -z "$target_conf" ] || [ -z "$name" ]; then return "$ERR_CFG_INVALID_ARGS"; fi
	if ! _require_safe_path "$target_conf" "配置写入"; then return "$ERR_CFG_INVALID_ARGS"; fi
	if [ ! -f "$temp_conf" ] || [ ! -s "$temp_conf" ]; then
		log_message ERROR "配置写入失败: 临时配置不存在或为空。"
		return "$ERR_CFG_INVALID_ARGS"
	fi
	if grep -q '\\n' "$temp_conf" 2>/dev/null; then
		rm -f "$temp_conf"
		log_message ERROR "检测到非法字面量 \\n，已拒绝写入。"
		return "$ERR_CFG_VALIDATE"
	fi
	# shellcheck disable=SC2016
	if grep -Fq '\$cf_ip' "$temp_conf" 2>/dev/null; then
		rm -f "$temp_conf"
		log_message ERROR "$(printf '检测到非法转义变量 \\$cf_ip，已拒绝写入。')"
		return "$ERR_CFG_VALIDATE"
	fi
	if [ -f "$target_conf" ] && cmp -s "$temp_conf" "$target_conf"; then
		log_message INFO "配置未变化，跳过写入与重载: $target_conf"
		rm -f "$temp_conf"
		return 0
	fi
	_tx_emit_marker "APPLY_STAGE" "target=${target_conf}, owner=${rollback_owner}"
	snapshot_nginx_conf "$target_conf" "$name" "$type" || true
	mv "$temp_conf" "$target_conf"
	_tx_emit_marker "APPLY_PROMOTE" "target=${target_conf}"
	_mark_nginx_conf_changed
	if [ "$skip_test" != "true" ]; then
		local test_output=""
		local test_rc=0
		test_output=$(nginx -t 2>&1) || test_rc=$?
		if [ "$test_rc" -eq 0 ]; then
			_tx_emit_marker "APPLY_VERIFY_OK" "target=${target_conf}"
			NGINX_TEST_CACHE_RESULT=0
			NGINX_TEST_CACHE_GEN="$NGINX_CONF_GEN"
			NGINX_TEST_CACHE_TS=$(date +%s)
			chmod 640 "$target_conf" || true
			return 0
		fi
		_tx_emit_marker "APPLY_VERIFY_FAILED" "target=${target_conf}, owner=${rollback_owner}" "ERROR"

		local rollback_conf=""
		if [ "$rollback_owner" = "render" ]; then
			rollback_conf=$(_get_latest_conf_backup "$name" "$type" || true)
			if [ -n "$rollback_conf" ] && [ -f "$rollback_conf" ]; then
				cp "$rollback_conf" "$target_conf"
			else
				rm -f "$target_conf"
			fi
			_mark_nginx_conf_changed
		else
			_tx_emit_marker "RENDER_VALIDATE_FAILED" "rollback_owner=transaction, conf=${target_conf}" "ERROR"
		fi
		NGINX_TEST_CACHE_RESULT=1
		NGINX_TEST_CACHE_GEN="$NGINX_CONF_GEN"
		NGINX_TEST_CACHE_TS=$(date +%s)
		nginx -t >/dev/null 2>&1 || true
		if [ "$rollback_owner" = "render" ]; then
			log_message ERROR "Nginx 配置检查失败,已回滚 (snapshot: ${rollback_conf:-none})"
		else
			log_message ERROR "Nginx 配置检查失败,交由事务层回滚 (snapshot: skipped)"
		fi
		if [ -n "$test_output" ]; then
			printf '%s\n' "$test_output" >&2
		fi
		return "$ERR_CFG_VALIDATE"
	fi
	chmod 640 "$target_conf" || true
	return 0
}

_build_proxy_common_directives() {
	cat <<'EOF'
        proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s; proxy_send_timeout 300s;
EOF
}

_render_proxy_location_block() {
	local location_expr="${1:-/}"
	local port="${2:-}"
	local guard_token="${3:-}"
	local guard_line=""
	if [ -n "$guard_token" ]; then
		# shellcheck disable=SC2016
		printf -v guard_line '        if ($http_x_oenmcp_token != "%s") { return 403; }' "$guard_token"
	fi
	cat <<EOF
    location ${location_expr} {
${guard_line}
        proxy_pass http://127.0.0.1:${port};
$(_build_proxy_common_directives)
    }
EOF
}

_write_and_enable_nginx_config() {
	local domain="${1:-}"
	local json="${2:-}"
	local conf="$NGINX_SITES_AVAILABLE_DIR/$domain.conf"
	if ! _require_valid_domain "$domain"; then return 1; fi
	if ! _require_safe_path "$conf" "配置写入"; then return 1; fi
	if [ -z "$json" ]; then
		log_message ERROR "配置生成失败: 传入 JSON 为空。"
		return 1
	fi
	local port cert key max_body custom_cfg cf_strict mcp_path mcp_token
	port=$(jq -r '.resolved_port // empty' <<<"$json" 2>/dev/null || true)
	cert=$(jq -r '.cert_file // empty' <<<"$json" 2>/dev/null || true)
	key=$(jq -r '.key_file // empty' <<<"$json" 2>/dev/null || true)
	max_body=$(jq -r '.client_max_body_size // empty' <<<"$json" 2>/dev/null || true)
	custom_cfg=$(jq -r '.custom_config // empty' <<<"$json" 2>/dev/null || true)
	cf_strict=$(jq -r '.cf_strict_mode // "n"' <<<"$json" 2>/dev/null || true)
	mcp_path=$(jq -r '.mcp_protect_path // empty' <<<"$json" 2>/dev/null || true)
	mcp_token=$(_resolve_mcp_token_from_json "$json" "$domain" 2>/dev/null || true)
	if [ -z "$port" ] || [ -z "$cert" ] || [ -z "$key" ]; then
		log_message ERROR "配置生成失败: 关键字段缺失(端口/证书/密钥)。"
		return 1
	fi
	if [ "$port" == "cert_only" ]; then return 0; fi
	if ! _require_valid_port "$port"; then return 1; fi

	if ! _require_safe_path "$cert" "证书文件"; then return 1; fi
	if ! _require_safe_path "$key" "密钥文件"; then return 1; fi
	local body_cfg=""
	local normalized_max_body=""
	if [ -n "$max_body" ] && [ "$max_body" != "null" ]; then
		normalized_max_body=$(_normalize_max_body_size "$max_body" 2>/dev/null || true)
		if [ -z "$normalized_max_body" ]; then
			log_message ERROR "client_max_body_size 值无效: ${max_body}"
			return 1
		fi
		body_cfg="client_max_body_size ${normalized_max_body};"
	fi
	if [ -z "$body_cfg" ]; then
		body_cfg="client_max_body_size 0;"
	fi
	if [ -n "$mcp_path" ] && ! _is_valid_location_path "$mcp_path"; then
		log_message ERROR "MCP 接口路径无效: ${mcp_path}"
		return 1
	fi
	if [ -n "$mcp_token" ] && ! _is_valid_mcp_token "$mcp_token"; then
		log_message ERROR "MCP Token 无效: 仅允许安全字符且长度 16-128"
		return 1
	fi
	if [ -n "$mcp_path" ] && [ -z "$mcp_token" ]; then
		log_message ERROR "MCP 接口路径已配置但 Token 为空。"
		return 1
	fi
	if [ -n "$mcp_token" ] && [ -z "$mcp_path" ]; then
		log_message ERROR "MCP Token 已配置但接口路径为空。"
		return 1
	fi
	local mcp_protect_cfg=""
	if [ -n "$mcp_path" ] && [ -n "$mcp_token" ]; then
		mcp_protect_cfg="$(_render_proxy_location_block "= ${mcp_path}" "$port" "$mcp_token")
$(_render_proxy_location_block "^~ ${mcp_path}/" "$port" "$mcp_token")"
	fi
	local extra_cfg=""
	if [ -n "$custom_cfg" ] && [ "$custom_cfg" != "null" ]; then
		if _is_valid_custom_directive_silent "$custom_cfg"; then
			extra_cfg="$custom_cfg"
		else
			local custom_as_max_body=""
			custom_as_max_body=$(_normalize_max_body_size "$custom_cfg" 2>/dev/null || true)
			if [ -z "$body_cfg" ] && [ -n "$custom_as_max_body" ]; then
				body_cfg="client_max_body_size ${custom_as_max_body};"
				log_message WARN "检测到旧格式 custom_config 中的请求体大小配置，已自动迁移。"
			else
				log_message WARN "检测到无效 custom_config，已忽略以防止 Nginx 配置损坏。"
			fi
		fi
	fi
	local cf_strict_cfg=""
	if [ "$cf_strict" == "y" ]; then
		if [ ! -f "/etc/nginx/conf.d/cf_geo.conf" ]; then
			_update_cloudflare_ips || true
		fi
		if [ -f "/etc/nginx/conf.d/cf_geo.conf" ]; then
			cf_strict_cfg=$'\n    if ($cf_ip = 0) { return 444; }'
		else
			log_message WARN "Cloudflare 严格防御依赖项缺失(cf_geo.conf)，本次已跳过严格防御指令。"
		fi
	fi

	if [[ -z "$port" || "$port" == "null" ]]; then
		log_message ERROR "端口为空,请检查项目配置。"
		return 1
	fi
	get_vps_ip

	local temp_conf
	temp_conf=$(mktemp "${conf}.tmp.XXXXXX")
	cat >"$temp_conf" <<EOF
server {
    listen 80; $([[ -n "$VPS_IPV6" ]] && printf '%s' "listen [::]:80;")
    server_name ${domain};
    location /.well-known/acme-challenge/ { root ${NGINX_WEBROOT_DIR}; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl; $([[ -n "$VPS_IPV6" ]] && printf '%s' "listen [::]:443 ssl;")
    http2 on;
    server_name ${domain};
    ssl_certificate ${cert}; ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE+AESGCM:ECDHE+CHACHA20';
    add_header Strict-Transport-Security "max-age=31536000;" always;
    ${body_cfg}${cf_strict_cfg}
    ${extra_cfg}
${mcp_protect_cfg}
$(_render_proxy_location_block "/" "$port" "")
}
EOF
	local skip_test="false"
	local rollback_owner="${RENDER_ROLLBACK_OWNER:-render}"
	if [ "${SKIP_NGINX_TEST_IN_APPLY:-false}" = "true" ]; then skip_test="true"; fi
	_apply_nginx_conf_with_validation "$temp_conf" "$conf" "$domain" "http" "$skip_test" "$rollback_owner"
	local apply_ret=$?
	if [ $apply_ret -ne 0 ]; then
		return $apply_ret
	fi
	ln -sf "$conf" "$NGINX_SITES_ENABLED_DIR/"
	chmod 640 "$conf" 2>/dev/null || true
	if ! _health_check_nginx_config "$domain"; then
		_tx_emit_marker "POST_VERIFY_FAILED" "domain=${domain}, owner=${rollback_owner}" "ERROR"
		if [ "$rollback_owner" = "render" ]; then
			local rollback_conf
			rollback_conf=$(_get_latest_conf_backup "$domain" "http" || true)
			if [ -n "$rollback_conf" ] && [ -f "$rollback_conf" ]; then
				cp "$rollback_conf" "$conf"
				NGINX_RELOAD_NEEDED="true"
				control_nginx_reload_if_needed || true
				log_message ERROR "健康检查失败,已回滚配置 (snapshot: ${rollback_conf:-none})"
			else
				log_message ERROR "健康检查失败且无可用快照: $domain"
			fi
		else
			_tx_emit_marker "HEALTHCHECK_FAILED" "rollback_owner=transaction, domain=${domain}" "ERROR"
			log_message ERROR "健康检查失败,交由事务层回滚: $domain"
		fi
		return "$ERR_CFG_VALIDATE"
	fi
	_tx_emit_marker "POST_VERIFY_OK" "domain=${domain}"
}

_remove_and_disable_nginx_config() {
	local domain="${1:-}"
	if ! _require_valid_domain "$domain"; then return 1; fi
	if ! _require_safe_path "$NGINX_SITES_AVAILABLE_DIR/${domain}.conf" "删除"; then return 1; fi
	if ! _require_safe_path "$NGINX_SITES_ENABLED_DIR/${domain}.conf" "删除"; then return 1; fi
	rm -f "$NGINX_SITES_AVAILABLE_DIR/${domain}.conf" "$NGINX_SITES_ENABLED_DIR/${domain}.conf"
}
