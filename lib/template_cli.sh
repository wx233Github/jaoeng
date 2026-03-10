#!/usr/bin/env bash

tm_parse_args() {
  IS_INTERACTIVE_MODE="true"
  DRY_RUN="false"
  SHOW_HELP="false"
  TEMPLATE_MODE=""
  TEMPLATE_IDS=""
  TEMPLATE_DOMAIN=""
  TEMPLATE_VARS_RAW=""
  TEMPLATE_APPLY_MODE="append"
  TEMPLATE_CLEANUP_MODE=""
  TEMPLATE_PARALLELISM=1
  TEMPLATE_DRY_RUN="false"
  TEMPLATE_BATCH_AUTO_CONFIRM="false"
  TEMPLATE_PRECHECK="false"
  TEMPLATE_FAIL_FAST="false"
  TEMPLATE_CONTINUE_ON_ERROR="false"
  TEMPLATE_OUTPUT_JSON="false"
  TEMPLATE_DEFER_RELOAD="false"
  TEMPLATE_IMPACT_REPORT="false"
  TEMPLATE_ROLLBACK_OP=""
  TEMPLATE_ROLLBACK_DOMAIN=""
  TEMPLATE_ROLLBACK_BEFORE=""
  TEMPLATE_AUDIT_REPORT="false"
  TEMPLATE_APPROVAL_HOOK=""
  QUIET_MODE="false"
  PRECHECK_ONLY="false"
  CHECK_ONLY="false"
  CRON_MODE="false"
  CF_IP_UPDATE_MODE="false"
  LEGACY_AUDIT_ONLY_USED="false"
  AUDIT_REPORT="false"
  AUDIT_OUTPUT_JSON="false"
  PLAN_MODE="false"
  TX_RECOVER="false"
  TEMPLATE_VARS=()
  local i=1
  while [ "$i" -le "$#" ]; do
    local arg="${!i}"
    case "$arg" in
    -h | --help)
      SHOW_HELP="true"
      i=$((i + 1))
      ;;
    --cron)
      IS_INTERACTIVE_MODE="false"
      CRON_MODE="true"
      i=$((i + 1))
      ;;
    --non-interactive)
      IS_INTERACTIVE_MODE="false"
      i=$((i + 1))
      ;;
    --check)
      CHECK_ONLY="true"
      i=$((i + 1))
      ;;
    --audit-only)
      LEGACY_AUDIT_ONLY_USED="true"
      i=$((i + 1))
      ;;
    --cf-ip-update)
      CF_IP_UPDATE_MODE="true"
      i=$((i + 1))
      ;;
    --dry-run)
      DRY_RUN="true"
      i=$((i + 1))
      ;;
    --plan)
      PLAN_MODE="true"
      DRY_RUN="true"
      i=$((i + 1))
      ;;
    --preflight)
      PRECHECK_ONLY="true"
      i=$((i + 1))
      ;;
    --audit-report)
      AUDIT_REPORT="true"
      if [ "${TEMPLATE_OUTPUT_JSON:-false}" = "true" ]; then AUDIT_OUTPUT_JSON="true"; fi
      i=$((i + 1))
      ;;
    --tx-recover)
      TX_RECOVER="true"
      i=$((i + 1))
      ;;
    --log-kv)
      LOG_FORMAT="kv"
      i=$((i + 1))
      ;;
    --log-plain)
      LOG_FORMAT="plain"
      i=$((i + 1))
      ;;
    --template-mode)
      i=$((i + 1))
      TEMPLATE_MODE="${!i:-}"
      i=$((i + 1))
      ;;
    --template-ids)
      i=$((i + 1))
      TEMPLATE_IDS="${!i:-}"
      i=$((i + 1))
      ;;
    --template-domain)
      i=$((i + 1))
      TEMPLATE_DOMAIN="${!i:-}"
      i=$((i + 1))
      ;;
    --template-vars)
      i=$((i + 1))
      TEMPLATE_VARS_RAW="${!i:-}"
      i=$((i + 1))
      ;;
    --template-apply-mode)
      i=$((i + 1))
      TEMPLATE_APPLY_MODE="${!i:-append}"
      i=$((i + 1))
      ;;
    --template-cleanup-mode)
      i=$((i + 1))
      TEMPLATE_CLEANUP_MODE="${!i:-}"
      i=$((i + 1))
      ;;
    --template-parallelism)
      i=$((i + 1))
      TEMPLATE_PARALLELISM="${!i:-1}"
      i=$((i + 1))
      ;;
    --template-dry-run)
      TEMPLATE_DRY_RUN="true"
      i=$((i + 1))
      ;;
    --template-precheck)
      TEMPLATE_PRECHECK="true"
      i=$((i + 1))
      ;;
    --fail-fast)
      TEMPLATE_FAIL_FAST="true"
      i=$((i + 1))
      ;;
    --continue-on-error)
      TEMPLATE_CONTINUE_ON_ERROR="true"
      i=$((i + 1))
      ;;
    --json)
      TEMPLATE_OUTPUT_JSON="true"
      if [ "${AUDIT_REPORT:-false}" = "true" ]; then AUDIT_OUTPUT_JSON="true"; fi
      i=$((i + 1))
      ;;
    --template-impact-report)
      TEMPLATE_IMPACT_REPORT="true"
      i=$((i + 1))
      ;;
    --template-rollback-op)
      i=$((i + 1))
      TEMPLATE_ROLLBACK_OP="${!i:-}"
      i=$((i + 1))
      ;;
    --template-rollback-domain)
      i=$((i + 1))
      TEMPLATE_ROLLBACK_DOMAIN="${!i:-}"
      i=$((i + 1))
      ;;
    --template-rollback-before)
      i=$((i + 1))
      TEMPLATE_ROLLBACK_BEFORE="${!i:-}"
      i=$((i + 1))
      ;;
    --template-audit-report)
      TEMPLATE_AUDIT_REPORT="true"
      i=$((i + 1))
      ;;
    --template-approval-hook)
      i=$((i + 1))
      TEMPLATE_APPROVAL_HOOK="${!i:-}"
      i=$((i + 1))
      ;;
    --quiet)
      QUIET_MODE="true"
      i=$((i + 1))
      ;;
    *) i=$((i + 1)) ;;
    esac
  done
  if [ "$DRY_RUN" = "true" ]; then
    log_message WARN "已启用 dry-run：破坏性操作仅记录，不实际执行。"
  fi
  _template_cli_globals_noop
}

_template_cli_globals_noop() {
  : "$SHOW_HELP" "$CRON_MODE" "$IS_INTERACTIVE_MODE" "$CHECK_ONLY" "$CF_IP_UPDATE_MODE" "$PLAN_MODE"
  : "$PRECHECK_ONLY" "$TX_RECOVER" "$LOG_FORMAT" "$AUDIT_OUTPUT_JSON" "$QUIET_MODE"
  : "${TEMPLATE_VARS[*]-}"
}

tm_validate_args() {
  local arg
  local skip_next="false"
  local pending_value_flag=""
  for arg in "$@"; do
    if [ "$skip_next" = "true" ]; then
      if [[ "$arg" == --* ]]; then
        log_message ERROR "参数 ${pending_value_flag} 缺少参数值"
        return 1
      fi
      skip_next="false"
      pending_value_flag=""
      continue
    fi
    case "$arg" in
    -h | --help | --cron | --non-interactive | --check | --audit-only | --cf-ip-update | --dry-run | --plan | --preflight | --template-dry-run | --template-precheck | --fail-fast | --continue-on-error | --json | --quiet | --template-impact-report | --template-audit-report | --audit-report | --tx-recover | --log-kv | --log-plain) ;;
    --template-mode | --template-ids | --template-domain | --template-vars | --template-apply-mode | --template-cleanup-mode | --template-parallelism | --template-rollback-op | --template-rollback-domain | --template-rollback-before | --template-approval-hook)
      skip_next="true"
      pending_value_flag="$arg"
      ;;
    *)
      log_message ERROR "未知参数: $arg"
      return 1
      ;;
    esac
  done
  if [ "$skip_next" = "true" ]; then
    log_message ERROR "参数 ${pending_value_flag} 缺少参数值"
    return 1
  fi

  if [ "${LEGACY_AUDIT_ONLY_USED:-false}" = "true" ]; then
    log_message ERROR "参数 --audit-only 已移除，请使用 --check"
    return 1
  fi
  if [ "${AUDIT_REPORT:-false}" = "true" ] && [ -n "$TEMPLATE_MODE" ]; then
    log_message ERROR "--audit-report 与 --template-mode 不能同时使用"
    return 1
  fi
  if [ "${AUDIT_REPORT:-false}" = "true" ] && [ -n "$TEMPLATE_ROLLBACK_OP" ]; then
    log_message ERROR "--audit-report 与 --template-rollback-op 不能同时使用"
    return 1
  fi

  if [ -n "$TEMPLATE_MODE" ]; then
    if [ "${TEMPLATE_AUDIT_REPORT:-false}" = "true" ]; then
      log_message ERROR "--template-audit-report 与 --template-mode 不能同时使用"
      return 1
    fi
    if [ -n "$TEMPLATE_ROLLBACK_OP" ]; then
      log_message ERROR "--template-mode 与 --template-rollback-op 不能同时使用"
      return 1
    fi
    if [ -z "$TEMPLATE_DOMAIN" ]; then
      log_message ERROR "模板 CLI 模式必须提供 --template-domain"
      return 1
    fi
    if ! _is_glob_domain_expr "$TEMPLATE_DOMAIN"; then
      if ! _require_valid_domain "$TEMPLATE_DOMAIN"; then
        log_message ERROR "--template-domain 非法: ${TEMPLATE_DOMAIN}"
        return 1
      fi
    fi
    case "$TEMPLATE_MODE" in
    default | custom | cleanup) ;;
    *)
      log_message ERROR "--template-mode 仅支持 default/custom/cleanup"
      return 1
      ;;
    esac
    if [ "$TEMPLATE_MODE" = "default" ] || [ "$TEMPLATE_MODE" = "custom" ]; then
      if [ -z "$TEMPLATE_IDS" ]; then
        log_message ERROR "${TEMPLATE_MODE} 模式必须提供 --template-ids"
        return 1
      fi
    fi
    case "$TEMPLATE_APPLY_MODE" in
    append | replace) ;;
    *)
      log_message ERROR "--template-apply-mode 仅支持 append/replace"
      return 1
      ;;
    esac
    if [ "$TEMPLATE_MODE" = "cleanup" ]; then
      case "$TEMPLATE_CLEANUP_MODE" in
      all | ids) ;;
      *)
        log_message ERROR "--template-cleanup-mode 仅支持 all/ids"
        return 1
        ;;
      esac
    fi
    if [ "$TEMPLATE_FAIL_FAST" = "true" ] && [ "$TEMPLATE_CONTINUE_ON_ERROR" = "true" ]; then
      log_message ERROR "--fail-fast 与 --continue-on-error 不能同时使用"
      return 1
    fi
    if ! [[ "${TEMPLATE_PARALLELISM:-1}" =~ ^[0-9]+$ ]] || [ "${TEMPLATE_PARALLELISM:-1}" -lt 1 ]; then
      log_message ERROR "--template-parallelism 必须为 >=1 的整数"
      return 1
    fi
    if [ "${TEMPLATE_PARALLELISM:-1}" -gt 1 ] && [ "$TEMPLATE_DRY_RUN" != "true" ] && [ "$TEMPLATE_PRECHECK" != "true" ] && [ "${TEMPLATE_IMPACT_REPORT:-false}" != "true" ]; then
      log_message ERROR "并行模式仅支持 dry-run/precheck/impact-report，写入模式请使用串行"
      return 1
    fi
    if [ "${TEMPLATE_PARALLELISM:-1}" -gt 1 ] && [ "$TEMPLATE_FAIL_FAST" = "true" ]; then
      log_message ERROR "并行模式不支持 --fail-fast"
      return 1
    fi
  fi
  if [ -n "$TEMPLATE_VARS_RAW" ]; then
    if [ -z "$TEMPLATE_MODE" ] || { [ "$TEMPLATE_MODE" != "default" ] && [ "$TEMPLATE_MODE" != "custom" ]; }; then
      log_message ERROR "--template-vars 仅支持 default/custom 模式"
      return 1
    fi
    if ! _parse_template_vars_raw "$TEMPLATE_VARS_RAW"; then
      log_message ERROR "--template-vars 格式非法，应为 KEY=VALUE,KEY2=VALUE2"
      return 1
    fi
  fi
  if [ "${TEMPLATE_IMPACT_REPORT:-false}" = "true" ] && [ -z "$TEMPLATE_MODE" ]; then
    log_message ERROR "--template-impact-report 仅支持与 --template-mode 一起使用"
    return 1
  fi
  if [ -n "$TEMPLATE_ROLLBACK_OP" ]; then
    if [ "${TEMPLATE_AUDIT_REPORT:-false}" = "true" ]; then
      log_message ERROR "--template-rollback-op 与 --template-audit-report 不能同时使用"
      return 1
    fi
    if ! [[ "$TEMPLATE_ROLLBACK_OP" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      log_message ERROR "--template-rollback-op 格式非法"
      return 1
    fi
    if [ -n "$TEMPLATE_ROLLBACK_DOMAIN" ] && ! _require_valid_domain "$TEMPLATE_ROLLBACK_DOMAIN"; then
      log_message ERROR "--template-rollback-domain 非法"
      return 1
    fi
    if [ -n "$TEMPLATE_ROLLBACK_BEFORE" ] && ! date -d "$TEMPLATE_ROLLBACK_BEFORE" +%s >/dev/null 2>&1; then
      log_message ERROR "--template-rollback-before 时间格式非法"
      return 1
    fi
  fi
  if [ -n "$TEMPLATE_APPROVAL_HOOK" ]; then
    if [[ "$TEMPLATE_APPROVAL_HOOK" != /* ]] || [ ! -x "$TEMPLATE_APPROVAL_HOOK" ]; then
      log_message ERROR "--template-approval-hook 必须是可执行绝对路径"
      return 1
    fi
  fi

  return 0
}

tm_print_usage() {
  cat <<'EOF'
用法:
  nginx.sh [选项]

常用选项:
	  --cron, --non-interactive      非交互执行续期流程
	  --cf-ip-update                 仅更新 Cloudflare 防御 IP 库
	  --check                        仅执行诊断
	  --audit-report                 输出事务/WAL 审计摘要
	--preflight                    仅执行运行前安全检查（失败退出20）
	--dry-run                      全局干跑（破坏性操作仅记录）
	  --plan                         输出变更计划（自动启用 dry-run）
	  --tx-recover                   扫描并处理未完成事务
	  --log-kv                       日志输出为 key=value 结构化格式
	  --log-plain                    日志输出为默认格式
	  --quiet                        控制台仅输出关键错误（日志文件不受影响）
	  -h, --help                     显示帮助

模板中心 CLI:
  --template-mode <default|custom|cleanup>
  --template-domain <domain|glob-expression>
  --template-ids <id[,id...]>
  --template-vars <KEY=VALUE[,KEY=VALUE...]>
  --template-apply-mode <append|replace>
  --template-cleanup-mode <all|ids>
  --template-parallelism <N>
  --template-dry-run
  --template-precheck            仅校验模板与匹配，不执行写入
  --template-impact-report       输出影响分析（不写入）
  --template-rollback-op <op_id> 按操作ID回滚模板变更
  --template-rollback-domain <domain>
  --template-rollback-before <"YYYY-MM-DD HH:MM:SS">
  --template-audit-report        输出模板审计统计摘要
  --template-approval-hook </abs/path/to/hook>
  --fail-fast                    批量模式遇错立即停止
  --continue-on-error            批量模式忽略失败继续执行
  --json                         模板 CLI 输出 JSON 摘要

模板 CLI 示例:
  nginx.sh --template-mode default --template-domain example.com --template-ids general_reverse_proxy --template-apply-mode append --template-dry-run --non-interactive
  nginx.sh --template-mode custom --template-domain "*.api.example.com,!admin.api.example.com" --template-ids security_headers,reverse_proxy_enhanced --template-apply-mode replace --non-interactive
  nginx.sh --template-mode cleanup --template-domain example.com --template-cleanup-mode ids --template-ids hsts --non-interactive
  nginx.sh --template-mode custom --template-domain "*.example.com,!admin.example.com" --template-ids security_headers --template-precheck --json --non-interactive
  nginx.sh --template-mode custom --template-domain example.com --template-ids security_headers,hsts --template-vars HSTS_MAX_AGE=86400 --template-dry-run --non-interactive
  nginx.sh --template-mode default --template-domain "*.example.com" --template-ids https_production --template-impact-report --json --non-interactive
  nginx.sh --template-rollback-op 20260308_120001_1234_5678 --json --non-interactive
  nginx.sh --template-rollback-op 20260308_120001_1234_5678 --template-rollback-domain api.example.com --template-rollback-before "2026-03-08 12:10:00" --json --non-interactive
  nginx.sh --template-audit-report --json --non-interactive

退出码(模板CLI):
  64 参数错误
  65 数据/匹配错误
  70 执行失败
EOF
}

tm_run_template_cli_mode() {
  if [ "${TEMPLATE_AUDIT_REPORT:-false}" = "true" ]; then
    _template_audit_report
    return $?
  fi
  if [ -n "${TEMPLATE_ROLLBACK_OP:-}" ]; then
    _rollback_templates_by_op "$TEMPLATE_ROLLBACK_OP" "${TEMPLATE_ROLLBACK_DOMAIN:-}" "${TEMPLATE_ROLLBACK_BEFORE:-}"
    return $?
  fi
  local d="${TEMPLATE_DOMAIN:-}"
  local ids_raw="${TEMPLATE_IDS:-}"
  local resolved=""
  local mode="${TEMPLATE_MODE:-}"
  local apply_mode="${TEMPLATE_APPLY_MODE:-append}"
  local fail=0
  local ok=0
  local domain=""
  local final_code=0
  local batch_result=""
  local -a ids=()
  local -a domains=()

  if [ -z "$mode" ]; then
    final_code="$EX_USAGE"
    _emit_template_cli_summary "$mode" "$d" 0 0 0 "$final_code" "false"
    return "$final_code"
  fi
  if ! _ensure_template_manifest_available; then
    final_code="$EX_CONFIG"
    _emit_template_cli_summary "$mode" "$d" 0 0 0 "$final_code" "false"
    return "$final_code"
  fi

  if _is_glob_domain_expr "$d"; then
    local match_output=""
    local match_rc=0
    match_output=$(_match_domains_by_glob_expr "$d" 2>/dev/null) || match_rc=$?
    if [ "$match_rc" -ne 0 ]; then
      log_message ERROR "域名表达式解析失败: ${d}"
      final_code="$EX_DATAERR"
      _emit_template_cli_summary "$mode" "$d" 0 0 0 "$final_code" "false"
      return "$final_code"
    fi
    while IFS= read -r domain; do
      [ -z "$domain" ] && continue
      domains+=("$domain")
    done <<<"$match_output"
    if [ "${#domains[@]}" -eq 0 ]; then
      log_message ERROR "模板 CLI 未匹配到任何域名: ${d}"
      final_code="$EX_DATAERR"
      _emit_template_cli_summary "$mode" "$d" 0 0 0 "$final_code" "false"
      return "$final_code"
    fi
    TEMPLATE_BATCH_AUTO_CONFIRM="true"
  else
    domains+=("$d")
  fi

  if [ "${TEMPLATE_IMPACT_REPORT:-false}" = "true" ]; then
    if ! _template_impact_report "$mode" "$apply_mode" "${TEMPLATE_CLEANUP_MODE:-all}" "${domains[@]}"; then
      final_code=$?
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 1 "$final_code" "false"
      return "$final_code"
    fi
    return 0
  fi

  if [ "${TEMPLATE_CONTINUE_ON_ERROR:-false}" = "true" ]; then
    TEMPLATE_FAIL_FAST="false"
  fi
  if [ "${#domains[@]}" -gt 1 ]; then
    TEMPLATE_DEFER_RELOAD="true"
  fi

  case "$mode" in
  default)
    if [ -z "$ids_raw" ]; then
      log_message ERROR "default 模式需要 --template-ids <combo_id>"
      final_code="$EX_USAGE"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
    fi
    local resolved_rc=0
    # shellcheck disable=SC2016
    resolved=$(_manifest_query --arg id "$ids_raw" '.default_combos[] | select(.id == $id) | .templates | join(" ")' 2>/dev/null) || resolved_rc=$?
    if [ "$resolved_rc" -ne 0 ]; then
      log_message ERROR "读取默认模板组合失败: ${ids_raw}"
      final_code="$EX_CONFIG"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
    fi
    if [ -z "$resolved" ] || [ "$resolved" = "null" ]; then
      log_message ERROR "未找到默认模板组合: ${ids_raw}"
      final_code="$EX_DATAERR"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
    fi
    IFS=' ' read -r -a ids <<<"$resolved"
    if ! _validate_template_selection "${ids[@]}"; then
      final_code="$EX_DATAERR"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
    fi
    if [ "${TEMPLATE_PRECHECK:-false}" = "true" ]; then
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 0 "true"
      return 0
    fi
    if [ "${TEMPLATE_PARALLELISM:-1}" -gt 1 ]; then
      batch_result=$(_template_parallel_execute "apply" "$apply_mode" "${ids[*]}" "${domains[@]}")
      ok=$(awk '{print $1}' <<<"$batch_result")
      fail=$(awk '{print $2}' <<<"$batch_result")
    else
      for domain in "${domains[@]}"; do
        if _apply_templates_to_domain "$domain" "$apply_mode" "${ids[@]}"; then
          ok=$((ok + 1))
        else
          fail=$((fail + 1))
          if [ "${TEMPLATE_FAIL_FAST:-false}" = "true" ]; then
            break
          fi
        fi
      done
    fi
    ;;
  custom)
    if [ -z "$ids_raw" ]; then
      log_message ERROR "custom 模式需要 --template-ids <id1,id2>"
      final_code="$EX_USAGE"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
    fi
    ids_raw="${ids_raw//,/ }"
    IFS=' ' read -r -a ids <<<"$ids_raw"
    if ! _validate_template_selection "${ids[@]}"; then
      final_code="$EX_DATAERR"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
    fi
    if [ "${TEMPLATE_PRECHECK:-false}" = "true" ]; then
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 0 "true"
      return 0
    fi
    if [ "${TEMPLATE_PARALLELISM:-1}" -gt 1 ]; then
      batch_result=$(_template_parallel_execute "apply" "$apply_mode" "${ids[*]}" "${domains[@]}")
      ok=$(awk '{print $1}' <<<"$batch_result")
      fail=$(awk '{print $2}' <<<"$batch_result")
    else
      for domain in "${domains[@]}"; do
        if _apply_templates_to_domain "$domain" "$apply_mode" "${ids[@]}"; then
          ok=$((ok + 1))
        else
          fail=$((fail + 1))
          if [ "${TEMPLATE_FAIL_FAST:-false}" = "true" ]; then
            break
          fi
        fi
      done
    fi
    ;;
  cleanup)
    if [ "${TEMPLATE_PRECHECK:-false}" = "true" ]; then
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 0 "true"
      return 0
    fi
    case "$TEMPLATE_CLEANUP_MODE" in
    all)
      if [ "${TEMPLATE_PARALLELISM:-1}" -gt 1 ]; then
        batch_result=$(_template_parallel_execute "cleanup" "all" "" "${domains[@]}")
        ok=$(awk '{print $1}' <<<"$batch_result")
        fail=$(awk '{print $2}' <<<"$batch_result")
      else
        for domain in "${domains[@]}"; do
          if _cleanup_template_blocks_for_domain "$domain" "all"; then
            ok=$((ok + 1))
          else
            fail=$((fail + 1))
            if [ "${TEMPLATE_FAIL_FAST:-false}" = "true" ]; then
              break
            fi
          fi
        done
      fi
      ;;
    ids)
      if [ -z "$ids_raw" ]; then
        log_message ERROR "cleanup ids 模式需要 --template-ids <id1,id2>"
        final_code="$EX_USAGE"
        _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
        return "$final_code"
      fi
      ids_raw="${ids_raw//,/ }"
      IFS=' ' read -r -a ids <<<"$ids_raw"
      if [ "${TEMPLATE_PARALLELISM:-1}" -gt 1 ]; then
        batch_result=$(_template_parallel_execute "cleanup" "ids" "${ids[*]}" "${domains[@]}")
        ok=$(awk '{print $1}' <<<"$batch_result")
        fail=$(awk '{print $2}' <<<"$batch_result")
      else
        for domain in "${domains[@]}"; do
          if _cleanup_template_blocks_for_domain "$domain" "ids" "${ids[@]}"; then
            ok=$((ok + 1))
          else
            fail=$((fail + 1))
            if [ "${TEMPLATE_FAIL_FAST:-false}" = "true" ]; then
              break
            fi
          fi
        done
      fi
      ;;
    *)
      log_message ERROR "cleanup 模式缺少合法 --template-cleanup-mode"
      final_code="$EX_USAGE"
      _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
      return "$final_code"
      ;;
    esac
    ;;
  *)
    log_message ERROR "未知模板模式: ${mode}"
    final_code="$EX_USAGE"
    _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" 0 0 "$final_code" "false"
    return "$final_code"
    ;;
  esac

  if [ "${TEMPLATE_DEFER_RELOAD:-false}" = "true" ] && [ "$ok" -gt 0 ] && [ "${TEMPLATE_DRY_RUN:-false}" != "true" ]; then
    if ! control_nginx_reload_if_needed; then
      log_message ERROR "批量模板应用后统一重载失败"
      fail=$((fail + 1))
    fi
  fi
  TEMPLATE_DEFER_RELOAD="false"
  if [ "$TEMPLATE_BATCH_AUTO_CONFIRM" = "true" ]; then
    log_message INFO "模板 CLI 批量执行完成: 成功=${ok}, 失败=${fail}"
  fi
  TEMPLATE_BATCH_AUTO_CONFIRM="false"
  if [ "$fail" -gt 0 ]; then
    final_code="$EX_SOFTWARE"
    _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" "$ok" "$fail" "$final_code" "false"
    return "$final_code"
  fi
  _emit_template_cli_summary "$mode" "$d" "${#domains[@]}" "$ok" "$fail" 0 "false"
  return 0
}
