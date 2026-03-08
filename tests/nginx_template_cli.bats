#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  MANIFEST_PATH="${REPO_ROOT}/templates/nginx/manifest.json"
  SCHEMA_PATH="${REPO_ROOT}/templates/nginx/manifest.schema.json"
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
