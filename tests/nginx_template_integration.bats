#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  PROJECTS_FILE="/etc/nginx/projects.json"
  PROJECTS_BACKUP=""

  if [ -f "$PROJECTS_FILE" ]; then
    PROJECTS_BACKUP="$(mktemp /tmp/projects.json.integration.backup.XXXXXX)"
    cp "$PROJECTS_FILE" "$PROJECTS_BACKUP"
  fi

  mkdir -p /etc/nginx
  cat >"$PROJECTS_FILE" <<'EOF'
[
  {"domain":"api.example.com","custom_config":""},
  {"domain":"admin.api.example.com","custom_config":""},
  {"domain":"shop.example.com","custom_config":""}
]
EOF
}

teardown() {
  if [ -n "$PROJECTS_BACKUP" ] && [ -f "$PROJECTS_BACKUP" ]; then
    cp "$PROJECTS_BACKUP" "$PROJECTS_FILE"
    rm -f "$PROJECTS_BACKUP"
  else
    rm -f "$PROJECTS_FILE"
  fi
}

@test "并行 dry-run 批量应用可执行" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.example.com,!admin.api.example.com" --template-ids security_headers --template-dry-run --template-parallelism 2 --json --non-interactive
  [ "$status" -eq 0 ]
}

@test "并行写入模式会被拒绝" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.example.com" --template-ids security_headers --template-parallelism 2 --non-interactive
  [ "$status" -ne 0 ]
}

@test "审批钩子参数校验: 非绝对路径拒绝" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-dry-run --template-approval-hook ./hook.sh --non-interactive
  [ "$status" -ne 0 ]
}

@test "审批钩子执行: 返回非零应拒绝" {
  hook="$(mktemp /tmp/template_hook_deny.XXXXXX.sh)"
  cat >"$hook" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$hook"
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-approval-hook "$hook" --non-interactive
  [ "$status" -eq 70 ]
  rm -f "$hook"
}

@test "审计统计包含平均耗时与失败域摘要" {
  audit_file="/var/log/nginx_template_audit.integration.$$"
  cat >"$audit_file" <<'EOF'
2026-03-08 10:00:00	apply	api.example.com	op=op_a	actor=root	rc=0	elapsed_ms=20	mode=append;ids=security_headers
2026-03-08 10:00:01	apply-failed	api.example.com	op=op_b	actor=root	rc=70	elapsed_ms=30	mode=append;ids=hsts
2026-03-08 10:00:02	cleanup-failed	shop.example.com	op=op_c	actor=root	rc=70	elapsed_ms=40	mode=all;ids=all
EOF
  run env NGINX_TEMPLATE_AUDIT_LOG="$audit_file" bash "$SCRIPT_PATH" --template-audit-report --json --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *'"avg_elapsed_ms":30'* ]]
  [[ "$output" == *'"top_failed_domains":'* ]]
  rm -f "$audit_file"
}
