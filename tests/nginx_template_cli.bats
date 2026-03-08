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

@test "模板模式非法时返回失败" {
  run bash "$SCRIPT_PATH" --template-mode invalid --template-domain example.com --non-interactive
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

@test "rollback-op 在无审计日志时返回 EX_DATAERR(65)" {
  audit_file="/tmp/nginx_template_audit.missing.$$"
  rm -f "$audit_file"
  run env NGINX_TEMPLATE_AUDIT_LOG="$audit_file" bash "$SCRIPT_PATH" --template-rollback-op op_test --json --non-interactive
  [ "$status" -eq 65 ]
}
