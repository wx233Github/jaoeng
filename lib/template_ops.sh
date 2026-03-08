#!/usr/bin/env bash

tm_template_impact_report() {
	local mode="${1:-}"
	local apply_mode="${2:-append}"
	local cleanup_mode="${3:-all}"
	shift 3 || true
	local -a domains=("$@")
	local ids_raw="${TEMPLATE_IDS:-}"
	local resolved=""
	local domain=""
	local cur=""
	local current_custom=""
	local merged_custom=""
	local cleaned_custom=""
	local payload=""
	local -a ids=()
	local matched=0
	local predicted_changes=0
	local before_blocks=0
	local after_blocks=0
	local before_dirs=0
	local after_dirs=0
	local changed_dirs=0

	case "$mode" in
	default)
		# shellcheck disable=SC2016
		resolved=$(_manifest_query --arg id "$ids_raw" '.default_combos[] | select(.id == $id) | .templates | join(" ")' 2>/dev/null || true)
		IFS=' ' read -r -a ids <<<"$resolved"
		;;
	custom)
		ids_raw="${ids_raw//,/ }"
		IFS=' ' read -r -a ids <<<"$ids_raw"
		;;
	cleanup)
		if [ "$cleanup_mode" = "ids" ]; then
			ids_raw="${ids_raw//,/ }"
			IFS=' ' read -r -a ids <<<"$ids_raw"
		fi
		;;
	esac

	if [ "$mode" = "default" ] || [ "$mode" = "custom" ]; then
		if ! _validate_template_selection "${ids[@]}"; then
			return "$EX_DATAERR"
		fi
		if ! payload=$(_render_templates_payload "${ids[@]}"); then
			return "$EX_DATAERR"
		fi
	fi

	for domain in "${domains[@]}"; do
		[ -z "$domain" ] && continue
		matched=$((matched + 1))
		cur=$(_get_project_json "$domain")
		current_custom=$(jq -r '.custom_config // empty' <<<"$cur")
		case "$mode" in
		default | custom)
			if [ "$apply_mode" = "replace" ]; then
				merged_custom="$payload"
			else
				merged_custom="$(_extract_template_blocks_by_ids "$current_custom" "${ids[@]}")"
				if [ -n "$merged_custom" ]; then
					merged_custom="${merged_custom}"$'\n'"${payload}"
				else
					merged_custom="$payload"
				fi
			fi
			if [ "$merged_custom" != "$current_custom" ]; then
				predicted_changes=$((predicted_changes + 1))
			fi
			before_blocks=$(_count_template_blocks "$current_custom")
			after_blocks=$(_count_template_blocks "$merged_custom")
			before_dirs=$(_count_unique_directives "$current_custom")
			after_dirs=$(_count_unique_directives "$merged_custom")
			changed_dirs=$(_count_changed_directives "$current_custom" "$merged_custom")
			log_message INFO "影响分析 ${domain}: 模板块 ${before_blocks} -> ${after_blocks}, 指令 ${before_dirs} -> ${after_dirs}, 变更指令=${changed_dirs}"
			_emit_template_impact_domain_json "$domain" "$before_blocks" "$after_blocks" "$before_dirs" "$after_dirs" "$changed_dirs"
			;;
		cleanup)
			if [ "$cleanup_mode" = "all" ]; then
				cleaned_custom=$(_extract_all_template_blocks "$current_custom")
			else
				cleaned_custom=$(_extract_template_blocks_by_ids "$current_custom" "${ids[@]}")
			fi
			if [ "$cleaned_custom" != "$current_custom" ]; then
				predicted_changes=$((predicted_changes + 1))
			fi
			before_blocks=$(_count_template_blocks "$current_custom")
			after_blocks=$(_count_template_blocks "$cleaned_custom")
			before_dirs=$(_count_unique_directives "$current_custom")
			after_dirs=$(_count_unique_directives "$cleaned_custom")
			changed_dirs=$(_count_changed_directives "$current_custom" "$cleaned_custom")
			log_message INFO "影响分析 ${domain}: 模板块 ${before_blocks} -> ${after_blocks}, 指令 ${before_dirs} -> ${after_dirs}, 变更指令=${changed_dirs}"
			_emit_template_impact_domain_json "$domain" "$before_blocks" "$after_blocks" "$before_dirs" "$after_dirs" "$changed_dirs"
			;;
		esac
	done

	_emit_template_cli_summary "$mode" "${TEMPLATE_DOMAIN:-}" "$matched" "$predicted_changes" 0 0 "true"
	return 0
}

tm_rollback_templates_by_op() {
	local op_id="${1:-}"
	local domain_filter="${2:-}"
	local before_ts="${3:-}"
	local log_path=""
	local line=""
	local ts_str=""
	local action=""
	local domain=""
	local target_epoch=0
	local before_epoch=0
	local snap=""
	local snap_json=""
	local matched=0
	local ok=0
	local fail=0
	local -a domains=()
	if [ -n "$before_ts" ]; then
		before_epoch=$(date -d "$before_ts" +%s 2>/dev/null || printf '%s' "0")
	fi
	local -a processed=()

	log_path=$(_sanitize_log_file "$NGINX_TEMPLATE_AUDIT_LOG" 2>/dev/null || true)
	[ -z "$log_path" ] && log_path="/tmp/nginx_template_audit.log"
	if [ ! -f "$log_path" ]; then
		log_message ERROR "模板审计日志不存在，无法按操作ID回滚: ${log_path}"
		_emit_template_cli_summary "rollback" "$op_id" 0 0 1 "$EX_DATAERR" "false"
		return "$EX_DATAERR"
	fi

	while IFS= read -r line; do
		[[ "$line" != *"op=${op_id}"* ]] && continue
		ts_str=$(awk -F '\t' '{print $1}' <<<"$line")
		action=$(awk -F '\t' '{print $2}' <<<"$line")
		domain=$(awk -F '\t' '{print $3}' <<<"$line")
		if [ -n "$domain_filter" ] && [ "$domain" != "$domain_filter" ]; then
			continue
		fi
		target_epoch=$(date -d "$ts_str" +%s 2>/dev/null || printf '%s' "0")
		if [ "$before_epoch" -gt 0 ] && [ "$target_epoch" -gt "$before_epoch" ]; then
			continue
		fi
		if [ "$action" != "apply" ] && [ "$action" != "cleanup" ]; then
			continue
		fi
		if ! _template_contains_id "$domain" "${domains[@]}"; then
			domains+=("$domain")
		fi
		if _template_contains_id "$domain" "${processed[@]}"; then
			continue
		fi
		matched=$((matched + 1))
		snap=$(_find_best_snapshot_for_domain "$domain" "$target_epoch" 2>/dev/null || true)
		if [ -z "$snap" ] || [ ! -f "$snap" ]; then
			log_message ERROR "未找到可回滚快照: ${domain}"
			fail=$((fail + 1))
			continue
		fi
		snap_json=$(cat "$snap" 2>/dev/null || true)
		if [ -z "$snap_json" ] || ! jq -e . >/dev/null 2>&1 <<<"$snap_json"; then
			log_message ERROR "快照 JSON 非法: ${snap}"
			fail=$((fail + 1))
			continue
		fi
		if ! _save_project_json "$snap_json"; then
			log_message ERROR "恢复项目 JSON 失败: ${domain}"
			fail=$((fail + 1))
			continue
		fi
		if ! _write_and_enable_nginx_config "$domain" "$snap_json"; then
			log_message ERROR "恢复 Nginx 配置失败: ${domain}"
			fail=$((fail + 1))
			continue
		fi
		ok=$((ok + 1))
		processed+=("$domain")
		_append_template_audit_log "rollback" "$domain" "from_op=${op_id};snapshot=$(basename "$snap")" 0 0
		# shellcheck disable=SC2034
		NGINX_RELOAD_NEEDED="true"
	done <"$log_path"

	if [ "$matched" -eq 0 ]; then
		log_message ERROR "未找到操作ID对应模板变更: ${op_id}"
		_emit_template_cli_summary "rollback" "$op_id" 0 0 1 "$EX_DATAERR" "false"
		return "$EX_DATAERR"
	fi
	if [ "$ok" -gt 0 ] && ! control_nginx_reload_if_needed; then
		fail=$((fail + 1))
	fi
	if [ "$fail" -gt 0 ]; then
		_emit_template_cli_summary "rollback" "$op_id" "$matched" "$ok" "$fail" "$EX_SOFTWARE" "false"
		return "$EX_SOFTWARE"
	fi
	_emit_template_cli_summary "rollback" "$op_id" "$matched" "$ok" "$fail" 0 "false"
	return 0
}

tm_apply_templates_to_domain() {
	local d="${1:-}"
	local mode="${2:-append}"
	shift 2 || true
	local template_ids=("$@")
	local cur=""
	local payload=""
	local current_custom=""
	local base_custom=""
	local merged_custom=""
	local new_json=""
	local ids_text=""
	local cert_path=""
	local started_at=0
	local finished_at=0
	local elapsed_ms=0
	started_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")

	cur=$(_get_project_json "$d")
	if [ -z "$cur" ]; then
		log_message ERROR "项目不存在: ${d}"
		return 1
	fi

	if [ "${#template_ids[@]}" -eq 0 ]; then
		log_message ERROR "未提供模板 ID。"
		return 1
	fi
	local deduped_ids
	deduped_ids=$(_dedupe_template_ids "${template_ids[@]}")
	IFS=' ' read -r -a template_ids <<<"$deduped_ids"
	if ! _validate_template_selection "${template_ids[@]}"; then
		return "$EX_DATAERR"
	fi

	if ! payload=$(_render_templates_payload "${template_ids[@]}"); then
		return 1
	fi

	current_custom=$(jq -r '.custom_config // empty' <<<"$cur")
	current_custom=$(_normalize_custom_config_text "$current_custom")
	if ! _template_block_marker_balance_ok "$current_custom"; then
		log_message ERROR "检测到模板注释块边界不成对，已拒绝应用。请先执行模板清理。"
		return 1
	fi
	if [ -n "$current_custom" ] && ! _is_valid_custom_directive_silent "$current_custom"; then
		log_message WARN "检测到历史 custom_config 非法，已自动清空后继续。"
		cur=$(jq '.custom_config = ""' <<<"$cur")
		current_custom=""
	fi

	if [ "$mode" = "replace" ]; then
		merged_custom="$payload"
	else
		base_custom=$(_extract_template_blocks_by_ids "$current_custom" "${template_ids[@]}")
		if [ -n "$base_custom" ]; then
			merged_custom="${base_custom}"$'\n'"${payload}"
		else
			merged_custom="$payload"
		fi
	fi
	merged_custom=$(_normalize_custom_config_text "$merged_custom")

	if _template_contains_id "hsts" "${template_ids[@]}"; then
		cert_path=$(jq -r '.cert_file // empty' <<<"$cur")
		if [ -z "$cert_path" ] || [ ! -f "$cert_path" ]; then
			log_message WARN "检测到 hsts 模板，但当前项目证书文件不存在: ${cert_path:-未设置}"
			if ! _template_operation_confirm_or_auto "仍要继续应用 HSTS 模板吗?" "n"; then
				return 0
			fi
		fi
	fi

	if ! _is_valid_custom_directive_silent "$merged_custom"; then
		log_message ERROR "模板合并结果校验失败，已拒绝写入。"
		return 1
	fi

	ids_text="${template_ids[*]}"
	if [ "$merged_custom" = "$current_custom" ]; then
		log_message INFO "模板应用结果无变化，已跳过写入。"
		return 0
	fi
	_print_template_diff_summary "$current_custom" "$merged_custom"
	printf '%b' "\n${CYAN}预览(${mode}):${NC}\n${merged_custom}\n"
	if ! _template_operation_confirm_or_auto "确认应用模板组合 [${ids_text}] 到 ${d}?" "y"; then
		log_message WARN "用户取消模板应用。"
		return 0
	fi

	if [ "$TEMPLATE_DRY_RUN" = "true" ]; then
		log_message INFO "template dry-run: 仅预览，不写入。"
		finished_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
		elapsed_ms=$((finished_at - started_at))
		_append_template_audit_log "apply-dry-run" "$d" "mode=${mode};ids=${ids_text}" 0 "$elapsed_ms"
		return 0
	fi
	if ! _template_approval_gate "apply" "$d" "$ids_text" "$mode"; then
		return "$EX_SOFTWARE"
	fi

	new_json=$(jq --arg v "$merged_custom" '.custom_config = $v' <<<"$cur")
	snapshot_project_json "$d" "$cur"
	if _save_project_json "$new_json"; then
		NGINX_RELOAD_NEEDED="true"
		if _write_and_enable_nginx_config "$d" "$new_json"; then
			if [ "${TEMPLATE_DEFER_RELOAD:-false}" != "true" ] && ! control_nginx_reload_if_needed; then
				log_message ERROR "模板应用后 Nginx 重载失败。"
				_save_project_json "$cur" || true
				_write_and_enable_nginx_config "$d" "$cur" || true
				NGINX_RELOAD_NEEDED="true"
				control_nginx_reload_if_needed || true
				return 1
			fi
			log_message SUCCESS "模板应用成功: ${d} ($mode, ${ids_text})"
			finished_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
			elapsed_ms=$((finished_at - started_at))
			_append_template_audit_log "apply" "$d" "mode=${mode};ids=${ids_text}" 0 "$elapsed_ms"
			printf '%b' "已应用模板组合: ${ids_text}\n"
			printf '%b' "模式: $([ "$mode" = "replace" ] && printf '%s' "Site替换（覆盖）" || printf '%s' "Block追加（推荐）")\n"
			return 0
		fi
		log_message ERROR "模板应用失败，开始回滚。"
		_save_project_json "$cur" || true
		_write_and_enable_nginx_config "$d" "$cur" || true
		NGINX_RELOAD_NEEDED="true"
		control_nginx_reload_if_needed || true
		finished_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
		elapsed_ms=$((finished_at - started_at))
		_append_template_audit_log "apply-failed" "$d" "mode=${mode};ids=${ids_text}" "$EX_SOFTWARE" "$elapsed_ms"
		return 1
	fi

	log_message ERROR "保存项目 JSON 失败，模板未应用。"
	return 1
}

tm_cleanup_template_blocks_for_domain() {
	local d="${1:-}"
	local clean_mode="${2:-all}"
	shift 2 || true
	local ids=("$@")
	local cur=""
	local current_custom=""
	local cleaned_custom=""
	local new_json=""
	local started_at=0
	local finished_at=0
	local elapsed_ms=0
	started_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")

	cur=$(_get_project_json "$d")
	if [ -z "$cur" ]; then
		log_message ERROR "项目不存在: ${d}"
		return 1
	fi

	current_custom=$(jq -r '.custom_config // empty' <<<"$cur")
	current_custom=$(_normalize_custom_config_text "$current_custom")
	if [ -z "$current_custom" ]; then
		log_message INFO "当前项目无 custom_config，跳过清理。"
		return 0
	fi
	if ! _template_block_marker_balance_ok "$current_custom"; then
		log_message ERROR "检测到模板注释块边界不成对，已拒绝自动清理。"
		return 1
	fi

	if [ "$clean_mode" = "all" ]; then
		cleaned_custom=$(_extract_all_template_blocks "$current_custom")
	else
		cleaned_custom=$(_extract_template_blocks_by_ids "$current_custom" "${ids[@]}")
	fi
	cleaned_custom=$(_normalize_custom_config_text "$cleaned_custom")

	if [ "$cleaned_custom" = "$current_custom" ]; then
		log_message WARN "未匹配到可清理的模板注释块。"
		return 0
	fi

	_print_template_diff_summary "$current_custom" "$cleaned_custom"
	printf '%b' "\n${CYAN}清理预览:${NC}\n${cleaned_custom}\n"
	if ! _template_operation_confirm_or_auto "确认执行模板块清理?" "y"; then
		log_message WARN "用户取消模板清理。"
		return 0
	fi

	if [ "$TEMPLATE_DRY_RUN" = "true" ]; then
		log_message INFO "template dry-run: 仅预览清理，不写入。"
		finished_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
		elapsed_ms=$((finished_at - started_at))
		_append_template_audit_log "cleanup-dry-run" "$d" "mode=${clean_mode};ids=${ids[*]:-all}" 0 "$elapsed_ms"
		return 0
	fi
	if ! _template_approval_gate "cleanup" "$d" "${ids[*]:-all}" "$clean_mode"; then
		return "$EX_SOFTWARE"
	fi

	if [ -n "$cleaned_custom" ] && ! _is_valid_custom_directive_silent "$cleaned_custom"; then
		log_message ERROR "清理结果校验失败，已拒绝写入。"
		return 1
	fi

	new_json=$(jq --arg v "$cleaned_custom" '.custom_config = $v' <<<"$cur")
	snapshot_project_json "$d" "$cur"
	if _save_project_json "$new_json"; then
		NGINX_RELOAD_NEEDED="true"
		if _write_and_enable_nginx_config "$d" "$new_json"; then
			if [ "${TEMPLATE_DEFER_RELOAD:-false}" != "true" ] && ! control_nginx_reload_if_needed; then
				log_message ERROR "模板清理后 Nginx 重载失败。"
				_save_project_json "$cur" || true
				_write_and_enable_nginx_config "$d" "$cur" || true
				NGINX_RELOAD_NEEDED="true"
				control_nginx_reload_if_needed || true
				return 1
			fi
			log_message SUCCESS "模板注释块清理成功: ${d}"
			finished_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
			elapsed_ms=$((finished_at - started_at))
			_append_template_audit_log "cleanup" "$d" "mode=${clean_mode};ids=${ids[*]:-all}" 0 "$elapsed_ms"
			return 0
		fi
		log_message ERROR "模板清理应用失败，开始回滚。"
		_save_project_json "$cur" || true
		_write_and_enable_nginx_config "$d" "$cur" || true
		# shellcheck disable=SC2034
		NGINX_RELOAD_NEEDED="true"
		control_nginx_reload_if_needed || true
		finished_at=$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")
		elapsed_ms=$((finished_at - started_at))
		_append_template_audit_log "cleanup-failed" "$d" "mode=${clean_mode};ids=${ids[*]:-all}" "$EX_SOFTWARE" "$elapsed_ms"
		return 1
	fi

	log_message ERROR "保存项目 JSON 失败，清理未应用。"
	return 1
}

tm_template_parallel_execute() {
	local op_type="${1:-apply}"
	local op_mode="${2:-append}"
	local ids_text="${3:-}"
	shift 3 || true
	local -a domain_list=("$@")
	local -a ids=()
	local -a pids=()
	local pid=""
	local ok=0
	local fail=0
	local parallelism="${TEMPLATE_PARALLELISM:-1}"
	if [ "$parallelism" -le 1 ]; then
		printf '%s\n' "0 0"
		return 1
	fi
	if [ -n "$ids_text" ]; then
		IFS=' ' read -r -a ids <<<"$ids_text"
	fi
	for domain in "${domain_list[@]}"; do
		while [ "$(jobs -pr | wc -l)" -ge "$parallelism" ]; do
			sleep 0.1
		done
		if [ "$op_type" = "apply" ]; then
			(tm_apply_templates_to_domain "$domain" "$op_mode" "${ids[@]}") &
		else
			(tm_cleanup_template_blocks_for_domain "$domain" "$op_mode" "${ids[@]}") &
		fi
		pids+=("$!")
	done
	for pid in "${pids[@]}"; do
		if wait "$pid"; then
			ok=$((ok + 1))
		else
			fail=$((fail + 1))
		fi
	done
	printf '%s %s\n' "$ok" "$fail"
	return 0
}
