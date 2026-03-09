#!/usr/bin/env bash

_get_project_json() { jq -c --arg d "${1:-}" '.[] | select(.domain == $d)' "$PROJECTS_METADATA_FILE" 2>/dev/null || printf '%s' ""; }

_mcp_token_file_for_domain() {
	local domain="${1:-}"
	if ! _is_valid_domain "$domain"; then return 1; fi
	printf '%s\n' "${MCP_TOKEN_DIR}/${domain}.token"
}

_save_mcp_token_for_domain() {
	local domain="${1:-}"
	local token="${2:-}"
	if [ -z "$token" ]; then return 1; fi
	if ! _is_valid_mcp_token "$token"; then return 1; fi
	local token_file
	token_file=$(_mcp_token_file_for_domain "$domain") || return 1
	if ! _require_safe_path "$token_file" "保存 MCP Token"; then return 1; fi
	mkdir -p "$MCP_TOKEN_DIR"
	chmod 700 "$MCP_TOKEN_DIR" 2>/dev/null || true
	local tmp_file
	tmp_file=$(mktemp "${MCP_TOKEN_DIR}/.${domain}.token.tmp.XXXXXX")
	chmod 600 "$tmp_file"
	printf '%s\n' "$token" >"$tmp_file"
	mv "$tmp_file" "$token_file"
	chmod 600 "$token_file" 2>/dev/null || true
	printf '%s\n' "$token_file"
}

_read_mcp_token_from_ref() {
	local token_ref="${1:-}"
	if [ -z "$token_ref" ]; then return 1; fi
	if ! _require_safe_path "$token_ref" "读取 MCP Token"; then return 1; fi
	if [ ! -f "$token_ref" ]; then return 1; fi
	local token=""
	token=$(head -n1 "$token_ref" 2>/dev/null || true)
	if ! _is_valid_mcp_token "$token"; then return 1; fi
	printf '%s\n' "$token"
}

_resolve_mcp_token_from_json() {
	local json="${1:-}"
	local fallback_domain="${2:-}"
	local inline_token=""
	local token_ref=""
	local domain=""
	inline_token=$(jq -r '.mcp_token // empty' <<<"$json" 2>/dev/null || true)
	if _is_valid_mcp_token "$inline_token"; then
		printf '%s\n' "$inline_token"
		return 0
	fi
	token_ref=$(jq -r '.mcp_token_ref // empty' <<<"$json" 2>/dev/null || true)
	if [ -n "$token_ref" ]; then
		_read_mcp_token_from_ref "$token_ref"
		return $?
	fi
	domain=$(jq -r '.domain // empty' <<<"$json" 2>/dev/null || true)
	if [ -z "$domain" ]; then domain="$fallback_domain"; fi
	if [ -n "$domain" ]; then
		local token_file
		token_file=$(_mcp_token_file_for_domain "$domain" 2>/dev/null || true)
		if [ -n "$token_file" ] && [ -f "$token_file" ]; then
			_read_mcp_token_from_ref "$token_file"
			return $?
		fi
	fi
	return 1
}

_remove_mcp_token_for_domain() {
	local domain="${1:-}"
	local token_ref="${2:-}"
	local token_file=""
	if [ -n "$token_ref" ]; then
		token_file="$token_ref"
	else
		token_file=$(_mcp_token_file_for_domain "$domain" 2>/dev/null || true)
	fi
	if [ -z "$token_file" ]; then return 0; fi
	if ! _require_safe_path "$token_file" "删除 MCP Token"; then return 1; fi
	rm -f "$token_file" 2>/dev/null || true
	return 0
}

_externalize_mcp_token_in_json() {
	local json="${1:-}"
	local domain=""
	local mcp_path=""
	local token=""
	local token_ref=""
	domain=$(jq -r '.domain // empty' <<<"$json" 2>/dev/null || true)
	mcp_path=$(jq -r '.mcp_protect_path // empty' <<<"$json" 2>/dev/null || true)
	token=$(jq -r '.mcp_token // empty' <<<"$json" 2>/dev/null || true)
	token_ref=$(jq -r '.mcp_token_ref // empty' <<<"$json" 2>/dev/null || true)

	if [ -z "$mcp_path" ]; then
		jq '.mcp_token = "" | .mcp_token_ref = ""' <<<"$json"
		return 0
	fi

	if [ -n "$token" ]; then
		local saved_ref
		saved_ref=$(_save_mcp_token_for_domain "$domain" "$token") || return 1
		jq --arg ref "$saved_ref" '.mcp_token = "" | .mcp_token_ref = $ref' <<<"$json"
		return 0
	fi

	if [ -n "$token_ref" ]; then
		jq '.mcp_token = ""' <<<"$json"
		return 0
	fi

	return 1
}

_project_snapshot_file() {
	local domain="${1:-}"
	if [ -z "$domain" ]; then return 1; fi
	printf '%s\n' "${JSON_BACKUP_DIR}/project_${domain}_$(date +%Y%m%d_%H%M%S).json.bak"
}

snapshot_project_json() {
	local domain="${1:-}" json="${2:-}"
	if [ -z "$domain" ] || [ -z "$json" ]; then return 1; fi
	local snap
	snap=$(_project_snapshot_file "$domain") || return 1
	printf '%s\n' "$json" >"$snap"
}

snapshot_json() {
	local target_file="${1:-$PROJECTS_METADATA_FILE}"
	if [ -f "$target_file" ]; then
		local base_name snap_name
		local keep=10
		local remove_count=0
		local i
		local -a backups=()
		base_name=$(basename "$target_file" .json)
		snap_name="${JSON_BACKUP_DIR}/${base_name}_$(date +%Y%m%d_%H%M%S).json.bak"
		cp "$target_file" "$snap_name"
		shopt -s nullglob
		backups=("${JSON_BACKUP_DIR}/${base_name}_"*.json.bak)
		shopt -u nullglob
		if [ "${#backups[@]}" -gt "$keep" ]; then
			remove_count=$((${#backups[@]} - keep))
			for ((i = 0; i < remove_count; i++)); do
				if _require_safe_path "${backups[i]}" "清理 JSON 备份"; then
					rm -f -- "${backups[i]}" 2>/dev/null || true
				fi
			done
		fi
	fi
}

json_upsert_by_key() {
	local target_file="${1:-}" key_name="${2:-}" key_value="${3:-}" json="${4:-}"
	if [ -z "$target_file" ] || [ -z "$key_name" ] || [ -z "$key_value" ] || [ -z "$json" ]; then
		return 1
	fi
	local temp
	temp=$(mktemp)
	chmod 600 "$temp"
	if jq -e --arg k "$key_name" --arg v "$key_value" '.[] | select(.[$k] == $v)' "$target_file" >/dev/null 2>&1; then
		jq --argjson new_val "$json" --arg k "$key_name" --arg v "$key_value" 'map(if .[$k] == $v then $new_val else . end)' "$target_file" >"$temp"
	else
		jq --argjson new_val "$json" '. + [$new_val]' "$target_file" >"$temp"
	fi
	if [ -s "$temp" ]; then
		mv "$temp" "$target_file"
		return 0
	fi
	rm -f "$temp"
	return 1
}

_save_project_json() {
	local json="${1:-}"
	if [ -z "$json" ]; then return 1; fi
	local domain
	domain=$(jq -r .domain <<<"$json")
	if [ -z "$domain" ] || [ "$domain" = "null" ]; then return 1; fi
	local old_json=""
	local old_ref=""
	old_json=$(_get_project_json "$domain")
	if [ -n "$old_json" ]; then
		old_ref=$(jq -r '.mcp_token_ref // empty' <<<"$old_json" 2>/dev/null || true)
	fi
	local normalized_json=""
	if ! normalized_json=$(_externalize_mcp_token_in_json "$json" 2>/dev/null); then
		log_message ERROR "MCP Token 持久化失败，已拒绝写入项目配置。"
		return 1
	fi
	local new_path
	new_path=$(jq -r '.mcp_protect_path // empty' <<<"$normalized_json" 2>/dev/null || true)
	if [ -z "$new_path" ] && [ -n "$old_ref" ]; then
		_remove_mcp_token_for_domain "$domain" "$old_ref" || true
	fi
	snapshot_json "$PROJECTS_METADATA_FILE"
	json_upsert_by_key "$PROJECTS_METADATA_FILE" "domain" "$domain" "$normalized_json"
}

_delete_project_json() {
	snapshot_json "$PROJECTS_METADATA_FILE"
	local domain="${1:-}"
	local token_ref=""
	if [ -n "$domain" ]; then
		token_ref=$(jq -r --arg d "$domain" '.[] | select(.domain == $d) | .mcp_token_ref // empty' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)
	fi
	local temp
	temp=$(mktemp)
	chmod 600 "$temp"
	jq --arg d "$domain" 'del(.[] | select(.domain == $d))' "$PROJECTS_METADATA_FILE" >"$temp" && mv "$temp" "$PROJECTS_METADATA_FILE"
	if [ -n "$domain" ]; then
		_remove_mcp_token_for_domain "$domain" "$token_ref" || true
	fi
}

_rollback_project_transaction() {
	local domain="${1:-}"
	local old_json="${2:-}"
	local mode="${3:-standard}"
	local rc=0
	if [ -z "$domain" ]; then return 1; fi
	_tx_emit_marker "ROLLBACK_BEGIN" "domain=${domain}, mode=${mode}" "WARN"

	if [ -n "$old_json" ]; then
		if ! _save_project_json "$old_json"; then rc=1; fi
	else
		if ! _delete_project_json "$domain"; then rc=1; fi
	fi

	if [ "$mode" != "cert_only" ]; then
		if [ -n "$old_json" ]; then
			if ! _write_and_enable_nginx_config "$domain" "$old_json"; then rc=1; fi
		else
			if ! _remove_and_disable_nginx_config "$domain"; then rc=1; fi
		fi
	fi

	NGINX_RELOAD_NEEDED="true"
	if ! control_nginx_reload_if_needed; then rc=1; fi
	if [ "$rc" -ne 0 ]; then
		tx_fail "ROLLBACK_FAILED" "domain=${domain}, mode=${mode}" "${ERR_CFG_VALIDATE:-20}" || true
		return "${ERR_CFG_VALIDATE:-20}"
	fi
	tx_transition "rolled_back" "rollback completed" || true
	_tx_emit_marker "ROLLBACK_DONE" "domain=${domain}, mode=${mode}" "WARN"
	return 0
}

_apply_project_transaction() {
	local domain="${1:-}"
	local new_json="${2:-}"
	local old_json="${3:-}"
	local mode="${4:-standard}"
	local rc=0
	local fail_message=""
	local idempotency_token=""
	local config_hash=""
	local old_token=""
	local old_hash=""
	if [ -z "$domain" ] || [ -z "$new_json" ]; then return 1; fi

	config_hash=$(_json_sha256 "$new_json" 2>/dev/null || true)
	if [ -z "$config_hash" ]; then
		tx_fail "HASH_INVALID" "unable to compute config hash" "${EX_DATAERR:-65}" || true
		return "${EX_DATAERR:-65}"
	fi
	idempotency_token=$(jq -r '.idempotency_token // empty' <<<"$new_json" 2>/dev/null || true)
	if [ -z "$idempotency_token" ]; then
		idempotency_token="${domain}:${config_hash:0:16}"
	fi
	if [ -n "$old_json" ]; then
		old_token=$(jq -r '.idempotency_token // empty' <<<"$old_json" 2>/dev/null || true)
		old_hash=$(jq -r '.config_hash // empty' <<<"$old_json" 2>/dev/null || true)
	fi
	if [ -n "$old_token" ] && [ "$idempotency_token" = "$old_token" ]; then
		if [ -n "$old_hash" ] && [ "$config_hash" = "$old_hash" ]; then
			_tx_emit_marker "IDEMPOTENT_REPLAY" "domain=${domain}, token=${idempotency_token}"
			return 0
		fi
		tx_fail "REPLAY_CONFLICT" "same token with different hash" "${EX_DATAERR:-65}" || true
		return "${EX_DATAERR:-65}"
	fi
	new_json=$(jq --arg tok "$idempotency_token" --arg h "$config_hash" '.idempotency_token = $tok | .config_hash = $h' <<<"$new_json")

	tx_begin "$domain" || return "$?"
	if ! preflight_hard_gate "project_transaction:${domain}"; then
		tx_fail "PRECHECK_BLOCK" "preflight gate blocked transaction" "${ERR_CFG_VALIDATE:-20}" || true
		return "${ERR_CFG_VALIDATE:-20}"
	fi
	tx_transition "preflight_ok" "preflight hard gate passed" || return "$?"

	if ! acquire_project_lock; then
		fail_message="无法获取项目事务锁"
		tx_fail "LOCK_HELD" "$fail_message" 1
		return 1
	fi

	if ! _save_project_json "$new_json"; then
		fail_message="项目元数据写入失败"
		tx_fail "WRITE_JSON_FAILED" "$fail_message" 1 || true
		rc=1
	fi

	if [ "$rc" -eq 0 ] && [ "$mode" != "cert_only" ]; then
		local RENDER_ROLLBACK_OWNER="transaction"
		if ! _write_and_enable_nginx_config "$domain" "$new_json"; then
			fail_message="站点配置写入失败，开始回滚"
			tx_fail "WRITE_CONF_FAILED" "$fail_message" 1 || true
			_rollback_project_transaction "$domain" "$old_json" "$mode"
			rc=1
		fi
	fi

	if [ "$rc" -eq 0 ]; then
		tx_transition "applied" "json/config staged and applied" || rc=$?
	fi

	if [ "$rc" -eq 0 ]; then
		NGINX_RELOAD_NEEDED="true"
		if ! control_nginx_reload_if_needed; then
			fail_message="Nginx 重载失败，开始回滚"
			tx_fail "RELOAD_FAILED" "$fail_message" 1 || true
			_rollback_project_transaction "$domain" "$old_json" "$mode"
			rc=1
		else
			tx_transition "reload_ok" "nginx reload success" || rc=$?
		fi
	fi

	if [ "$rc" -eq 0 ]; then
		tx_transition "committed" "transaction committed" || rc=$?
		tx_mark_commit || true
	fi

	release_project_lock || true
	return "$rc"
}
