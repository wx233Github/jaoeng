#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  MANIFEST_PATH="${REPO_ROOT}/templates/nginx/manifest.json"
  SCHEMA_PATH="${REPO_ROOT}/templates/nginx/manifest.schema.json"
  PROJECTS_FILE="/etc/nginx/projects.json"
  PROJECTS_BACKUP=""

  if [ -f "$PROJECTS_FILE" ]; then
    PROJECTS_BACKUP="$(mktemp /tmp/projects.json.bats.backup.XXXXXX)"
    cp "$PROJECTS_FILE" "$PROJECTS_BACKUP"
  fi

  mkdir -p /etc/nginx
  cat >"$PROJECTS_FILE" <<'EOF'
[
  {
    "domain": "api.example.com",
    "custom_config": ""
  },
  {
    "domain": "admin.api.example.com",
    "custom_config": ""
  },
  {
    "domain": "shop.example.com",
    "custom_config": ""
  }
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

@test "模板 manifest 与 schema 均为合法 JSON" {
  run jq -e . "$MANIFEST_PATH"
  [ "$status" -eq 0 ]

  run jq -e . "$SCHEMA_PATH"
  [ "$status" -eq 0 ]
}

@test "default_combos 引用的模板 ID 均存在" {
  run jq -e '([.templates[].id] | unique) as $ids | all(.default_combos[].templates[]; ($ids | index(.) != null))' "$MANIFEST_PATH"
  [ "$status" -eq 0 ]
}

@test "default_combos 提供独立 desc 且不与 name 重复" {
  run jq -e 'all(.default_combos[]; ((.desc // "") | length) > 0 and .desc != .name)' "$MANIFEST_PATH"
  [ "$status" -eq 0 ]
}

@test "requires/conflicts 引用的模板 ID 均存在" {
  run jq -e '([.templates[].id] | unique) as $ids | all(.templates[]; ((.requires // []) + (.conflicts // [])) | all(.[]; ($ids | index(.) != null)))' "$MANIFEST_PATH"
  [ "$status" -eq 0 ]
}

@test "--help 返回成功并包含模板 CLI 说明" {
  run bash "$SCRIPT_PATH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"模板中心 CLI"* ]]
  [[ "$output" == *"--template-mode"* ]]
}

@test "legacy 参数 --audit-only 被拒绝并给出迁移提示" {
  run bash "$SCRIPT_PATH" --audit-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"--audit-only 已移除"* ]]
  [[ "$output" == *"请使用 --check"* ]]
}

@test "模板模式非法时返回失败" {
  run bash "$SCRIPT_PATH" --template-mode invalid --template-domain example.com --non-interactive
  [ "$status" -ne 0 ]
}

@test "参数缺值: --template-mode 缺少值时返回失败" {
  run bash "$SCRIPT_PATH" --template-mode --template-domain example.com --non-interactive
  [ "$status" -ne 0 ]
}

@test "custom 模式缺少 --template-ids 时返回失败" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain example.com --non-interactive
  [ "$status" -ne 0 ]
}

@test "glob 批量: 混合包含与排除表达式可执行 dry-run" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.example.com,!admin.api.example.com" --template-ids security_headers --template-apply-mode append --template-dry-run --non-interactive
  [ "$status" -eq 0 ]
}

@test "glob 批量: 仅排除表达式可执行 dry-run" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "!admin.api.example.com" --template-ids security_headers --template-apply-mode append --template-dry-run --non-interactive
  [ "$status" -eq 0 ]
}

@test "glob 批量: 未匹配域名返回 EX_DATAERR(65)" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.none.example.com" --template-ids security_headers --template-apply-mode append --template-dry-run --non-interactive
  [ "$status" -eq 65 ]
}

@test "precheck + json 输出返回成功" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.example.com,!admin.api.example.com" --template-ids security_headers --template-precheck --json --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *'"precheck":true'* ]]
  [[ "$output" == *'"mode":"custom"'* ]]
}

@test "依赖约束: hsts 单独应用返回 EX_DATAERR(65)" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids hsts --template-dry-run --non-interactive
  [ "$status" -eq 65 ]
}

@test "参数约束: fail-fast 与 continue-on-error 互斥" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --fail-fast --continue-on-error --template-dry-run --non-interactive
  [ "$status" -ne 0 ]
}

@test "cleanup + glob 可执行 dry-run" {
  run bash "$SCRIPT_PATH" --template-mode cleanup --template-domain "*.example.com" --template-cleanup-mode all --template-dry-run --non-interactive
  [ "$status" -eq 0 ]
}

@test "manifest 非法时返回 EX_CONFIG(78)" {
  bad_manifest="$(mktemp /tmp/nginx.manifest.bad.XXXXXX.json)"
  printf '%s\n' '{bad json' >"$bad_manifest"
  run env NGINX_TEMPLATE_MANIFEST="$bad_manifest" bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-dry-run --non-interactive
  [ "$status" -eq 78 ]
  rm -f "$bad_manifest"
}

@test "impact-report 必须与 template-mode 同时使用" {
  run bash "$SCRIPT_PATH" --template-impact-report --non-interactive
  [ "$status" -ne 0 ]
}

@test "impact-report + json 输出成功" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.example.com" --template-ids security_headers --template-impact-report --json --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *'"precheck":true'* ]]
}

@test "impact-report json 包含域名级指令变化摘要" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-impact-report --json --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *'"domain":"api.example.com"'* ]]
  [[ "$output" == *'"changed_directives":'* ]]
}

@test "rollback-op 在无审计日志时返回 EX_DATAERR(65)" {
  audit_file="/var/log/nginx_template_audit.missing.$$"
  rm -f "$audit_file"
  run env NGINX_TEMPLATE_AUDIT_LOG="$audit_file" bash "$SCRIPT_PATH" --template-rollback-op op_test --json --non-interactive
  [ "$status" -eq 65 ]
}

@test "audit-report 在无审计日志时返回 EX_DATAERR(65)" {
  audit_file="/var/log/nginx_template_audit.missing.report.$$"
  rm -f "$audit_file"
  run env NGINX_TEMPLATE_AUDIT_LOG="$audit_file" bash "$SCRIPT_PATH" --template-audit-report --json --non-interactive
  [ "$status" -eq 65 ]
}

@test "audit-report 可输出统计 JSON" {
  audit_file="/var/log/nginx_template_audit.sample.$$"
  cat >"$audit_file" <<'EOF'
2026-03-08 10:00:00	apply	api.example.com	op=op_a	actor=root	rc=0	elapsed_ms=12	mode=append;ids=security_headers
2026-03-08 10:01:00	cleanup	api.example.com	op=op_b	actor=root	rc=0	elapsed_ms=10	mode=all;ids=all
2026-03-08 10:02:00	rollback	api.example.com	op=op_c	actor=root	rc=0	elapsed_ms=8	from_op=op_a
EOF
  run env NGINX_TEMPLATE_AUDIT_LOG="$audit_file" bash "$SCRIPT_PATH" --template-audit-report --json --non-interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *'"apply_ok":1'* ]]
  [[ "$output" == *'"cleanup_ok":1'* ]]
  [[ "$output" == *'"rollback_ok":1'* ]]
  rm -f "$audit_file"
}

@test "参数约束: template-mode 与 template-audit-report 互斥" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-audit-report --non-interactive
  [ "$status" -ne 0 ]
}

@test "参数约束: 并行模式不允许 fail-fast" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "*.example.com" --template-ids security_headers --template-dry-run --template-parallelism 2 --fail-fast --non-interactive
  [ "$status" -ne 0 ]
}

@test "参数约束: rollback-before 时间格式校验" {
  run bash "$SCRIPT_PATH" --template-rollback-op op_test --template-rollback-before bad-time --json --non-interactive
  [ "$status" -ne 0 ]
}

@test "兼容性校验: min_nginx_version 过高应失败" {
  custom_manifest="$(mktemp "${REPO_ROOT}/templates/nginx/manifest.test.XXXX.json")"
  jq '.templates |= map(if .id == "security_headers" then . + {min_nginx_version:"99.0.0"} else . end)' "$MANIFEST_PATH" >"$custom_manifest"
  run env NGINX_TEMPLATE_MANIFEST="$custom_manifest" bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-precheck --non-interactive
  [ "$status" -eq 65 ]
  rm -f "$custom_manifest"
}

@test "template-vars 可覆盖 hsts 默认变量" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers,hsts --template-vars HSTS_MAX_AGE=86400 --template-precheck --json --non-interactive
  [ "$status" -eq 0 ]
}

@test "template-vars 未声明变量应失败" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers --template-vars HSTS_MAX_AGE=86400 --template-dry-run --non-interactive
  [ "$status" -eq 65 ]
}

@test "template-vars 值不匹配 pattern 应失败" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids security_headers,hsts --template-vars HSTS_MAX_AGE=abc --template-dry-run --non-interactive
  [ "$status" -eq 65 ]
}

@test "reverse proxy 模板变量可覆盖并通过 precheck" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids reverse_proxy_enhanced --template-vars PROXY_CONNECT_TIMEOUT=120s,PROXY_SEND_TIMEOUT=900s,PROXY_READ_TIMEOUT=900s --template-precheck --json --non-interactive
  [ "$status" -eq 0 ]
}

@test "reverse proxy 模板变量非法单位应失败" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids reverse_proxy_enhanced --template-vars PROXY_CONNECT_TIMEOUT=120x --template-precheck --non-interactive
  [ "$status" -eq 65 ]
}

@test "wordpress 模板变量可覆盖并通过 precheck" {
  run bash "$SCRIPT_PATH" --template-mode custom --template-domain "api.example.com" --template-ids wordpress_basic --template-vars WP_CLIENT_MAX_BODY_SIZE=128m,WP_PROXY_READ_TIMEOUT=400s,WP_PROXY_SEND_TIMEOUT=400s --template-precheck --json --non-interactive
  [ "$status" -eq 0 ]
}
