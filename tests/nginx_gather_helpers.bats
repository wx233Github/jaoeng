#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.gather.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "后端目标收集 helper 可返回本地端口" {
  run bash -c '
    set -euo pipefail
    source "$1"
    prompt_input() { printf "%s\n" "8080"; }
    out=$(_prompt_backend_target_for_project "{}" "")
    [ "$out" = "local_port	8080" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "复用泛域名证书 helper 在 skip_cert=true 时跳过" {
  run bash -c '
    set -euo pipefail
    source "$1"
    out=$(_detect_reusable_wildcard_cert "a.example.com" "true")
    [ "$out" = "false		" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "复用泛域名证书 helper 可解析匹配证书" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.gather.wc.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
    export PROJECTS_METADATA_FILE="$td/projects.json"
    printf "%s\n" "[{\"domain\":\"example.com\",\"use_wildcard\":\"y\",\"cert_file\":\"/etc/ssl/example.com.cer\",\"key_file\":\"/etc/ssl/example.com.key\"}]" >"$PROJECTS_METADATA_FILE"
    confirm_or_cancel() { return 0; }
    _get_project_json() { printf "%s\n" "{\"cert_file\":\"/etc/ssl/example.com.cer\",\"key_file\":\"/etc/ssl/example.com.key\"}"; }
    out=$(_detect_reusable_wildcard_cert "api.example.com" "false")
    [ "$out" = "true	/etc/ssl/example.com.cer	/etc/ssl/example.com.key" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
