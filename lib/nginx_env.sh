#!/usr/bin/env bash

# 已废弃: 统一使用 check_dependencies()

_check_nginx_config() {
  if ! _nginx_test_cached; then
    log_error "Nginx 配置检查失败。"
    nginx -t || true
    return 1
  fi
  return 0
}

_check_dns_tools() {
  if command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1; then
    return 0
  fi
  log_warn "未找到 dig/host, DNS 诊断将跳过。"
  return 1
}

run_diagnostics() {
  _generate_op_id
  log_info "开始执行自检 (--check)"
  if [ "$(id -u)" -ne 0 ]; then log_warn "当前非 root, 部分检查可能失败。"; fi
  check_dependencies || true
  _check_dns_tools || true
  _check_nginx_config || true
  if [ -f "$PROJECTS_METADATA_FILE" ]; then jq -e . "$PROJECTS_METADATA_FILE" >/dev/null 2>&1 || log_error "projects.json 格式异常"; fi
  if [ -f "$TCP_PROJECTS_METADATA_FILE" ]; then jq -e . "$TCP_PROJECTS_METADATA_FILE" >/dev/null 2>&1 || log_error "tcp_projects.json 格式异常"; fi
  log_info "自检完成"
}

_preflight_check_active_conf_include() {
  local active_conf=""
  active_conf=$(_get_active_nginx_main_conf)
  if [ -z "$active_conf" ] || [ ! -f "$active_conf" ]; then
    log_message ERROR "preflight: 未找到 active nginx 主配置: ${active_conf:-unknown}"
    return 1
  fi
  if [ "$active_conf" = "/etc/nginx/nginx.conf" ]; then
    return 0
  fi
  if grep -Eq 'include[[:space:]]+/etc/nginx/sites-enabled/\*\.conf;' "$active_conf" 2>/dev/null; then
    return 0
  fi
  log_message ERROR "preflight: active 主配置未接入 /etc/nginx/sites-enabled/*.conf: ${active_conf}"
  return 1
}

_preflight_check_reload_strategy() {
  local strategy=""
  strategy=$(_select_reload_strategy)
  case "$strategy" in
  systemctl)
    if systemctl status nginx >/dev/null 2>&1; then return 0; fi
    ;;
  nginx_conf:*)
    local conf_path="${strategy#nginx_conf:}"
    if [ -f "$conf_path" ] && nginx -t -c "$conf_path" >/dev/null 2>&1; then return 0; fi
    ;;
  nginx_plain)
    if nginx -t >/dev/null 2>&1; then return 0; fi
    ;;
  esac
  log_message ERROR "preflight: reload 策略不可用(${strategy:-unknown})"
  return 1
}

_preflight_check_template_assets() {
  if ! _ensure_template_manifest_available >/dev/null 2>&1; then
    log_message ERROR "preflight: 模板清单不可用: ${NGINX_TEMPLATE_MANIFEST}"
    return 1
  fi
  local missing_count=0
  local snippet=""
  while IFS= read -r snippet; do
    [ -z "$snippet" ] && continue
    if [ ! -f "${NGINX_TEMPLATE_DIR}/${snippet}" ]; then
      log_message ERROR "preflight: 缺失模板片段: ${NGINX_TEMPLATE_DIR}/${snippet}"
      missing_count=$((missing_count + 1))
    fi
  done < <(jq -r '.templates[]?.snippet_file // empty' "$NGINX_TEMPLATE_MANIFEST" 2>/dev/null || true)
  [ "$missing_count" -eq 0 ]
}

_preflight_check_mcp_token_refs() {
  local ok=0
  local domain=""
  local token_ref=""
  local mcp_path=""
  while IFS=$'\t' read -r domain mcp_path token_ref; do
    [ -z "$domain" ] && continue
    [ -z "$mcp_path" ] && continue
    if [ -z "$token_ref" ]; then
      log_message ERROR "preflight: ${domain} 已启用 MCP 路径但缺少 mcp_token_ref"
      ok=1
      continue
    fi
    if ! _require_safe_path "$token_ref" "preflight MCP token 引用"; then
      ok=1
      continue
    fi
    if [ ! -f "$token_ref" ]; then
      log_message ERROR "preflight: ${domain} 的 mcp_token_ref 文件不存在: ${token_ref}"
      ok=1
      continue
    fi
    local perm=""
    perm=$(stat -c '%a' "$token_ref" 2>/dev/null || true)
    if [ -n "$perm" ] && [ "$perm" != "600" ]; then
      log_message WARN "preflight: ${domain} 的 token 文件权限建议为 600，当前 ${perm}"
    fi
    local token=""
    token=$(_read_mcp_token_from_ref "$token_ref" 2>/dev/null || true)
    if ! _is_valid_mcp_token "$token"; then
      log_message ERROR "preflight: ${domain} 的 token 引用无效"
      ok=1
    fi
  done < <(jq -r '.[] | [(.domain // ""), (.mcp_protect_path // ""), (.mcp_token_ref // "")] | @tsv' "$PROJECTS_METADATA_FILE" 2>/dev/null || true)

  [ "$ok" -eq 0 ]
}

run_preflight() {
  _generate_op_id
  log_message INFO "开始执行 preflight 运行前检查"
  local fail=0
  check_dependencies || fail=$((fail + 1))
  _preflight_check_active_conf_include || fail=$((fail + 1))
  _preflight_check_reload_strategy || fail=$((fail + 1))
  _preflight_check_template_assets || fail=$((fail + 1))
  _preflight_check_mcp_token_refs || fail=$((fail + 1))
  if [ -f /etc/nginx/nginx.conf ] && grep -qE '^[[:space:]]*stream[[:space:]]*\{' /etc/nginx/nginx.conf; then
    _stream_module_available || fail=$((fail + 1))
  fi
  if [ "$fail" -gt 0 ]; then
    log_message ERROR "preflight 失败: ${fail} 项检查未通过"
    return "$ERR_CFG_VALIDATE"
  fi
  log_message SUCCESS "preflight 通过"
  return 0
}
