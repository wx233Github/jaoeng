#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.tx.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "事务应用在 reload 失败时触发回滚" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.txn.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
    mark="$td/mark"
    : >"$mark"

    _save_project_json() { printf "%s\n" "save:$1" >>"$mark"; return 0; }
    _write_and_enable_nginx_config() { printf "%s\n" "write:$1" >>"$mark"; return 0; }
    control_nginx_reload_if_needed() { return 1; }
    _delete_project_json() { printf "%s\n" "delete:$1" >>"$mark"; return 0; }
    _remove_and_disable_nginx_config() { printf "%s\n" "remove:$1" >>"$mark"; return 0; }

    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "{\"domain\":\"a.example.com\",\"resolved_port\":\"8080\"}" "standard" || true

    grep -q "save:{\"domain\":\"a.example.com\"}" "$mark"
    grep -q "write:a.example.com" "$mark"
    grep -q "save:{\"domain\":\"a.example.com\",\"resolved_port\":\"8080\"}" "$mark"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "事务应用在 cert_only 模式不写站点配置" {
  run bash -c '
    set -euo pipefail
    source "$1"
    _save_project_json() { return 0; }
    _write_and_enable_nginx_config() { return 99; }
    control_nginx_reload_if_needed() { return 0; }
    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "" "cert_only"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
