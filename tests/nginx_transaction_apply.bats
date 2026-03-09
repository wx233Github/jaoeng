#!/usr/bin/env bats
# Coverage Matrix
# - _apply_project_transaction: 事务应用在 reload 失败时触发回滚 / cert_only 模式不写站点配置
# - _write_and_enable_nginx_config: 事务应用在 reload 失败时触发回滚
# - control_nginx (via control_nginx_reload_if_needed stub): 事务应用在 reload 失败时触发回滚
#
# Fixture Conventions
# - 每个测试使用 mktemp -d + trap 清理，避免污染真实目录
# - 外部依赖仅通过 stub 函数替换，禁止触达真实 nginx/systemctl

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
	preflight_hard_gate() { return 0; }

    acquire_project_lock() { printf "%s\n" "acquire" >>"$mark"; return 0; }
    release_project_lock() { printf "%s\n" "release" >>"$mark"; return 0; }
    _save_project_json() { printf "%s\n" "save:$1" >>"$mark"; return 0; }
    _write_and_enable_nginx_config() { printf "%s\n" "write:$1" >>"$mark"; return 0; }
    _rollback_project_transaction() { printf "%s\n" "rollback:$1" >>"$mark"; return 0; }
    control_nginx_reload_if_needed() { return 1; }

    rc=0
    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "{\"domain\":\"a.example.com\",\"resolved_port\":\"8080\"}" "standard" || rc=$?
    [ "$rc" -ne 0 ]

	grep -q "save:" "$mark"
	grep -q "\"domain\"" "$mark"
	grep -q "a.example.com" "$mark"
    grep -q "write:a.example.com" "$mark"
    grep -q "rollback:a.example.com" "$mark"
    grep -q "release" "$mark"
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "事务应用在 cert_only 模式不写站点配置" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.txn.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
	mark="$td/mark"
	: >"$mark"
	preflight_hard_gate() { return 0; }

    acquire_project_lock() { printf "%s\n" "acquire" >>"$mark"; return 0; }
    release_project_lock() { printf "%s\n" "release" >>"$mark"; return 0; }
    _save_project_json() { printf "%s\n" "save" >>"$mark"; return 0; }
    _write_and_enable_nginx_config() { printf "%s\n" "write" >>"$mark"; return 99; }
    _rollback_project_transaction() { printf "%s\n" "rollback" >>"$mark"; return 0; }
    control_nginx_reload_if_needed() { printf "%s\n" "reload" >>"$mark"; return 0; }

    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "" "cert_only"

    mapfile -t lines <"$mark"
    [ "${lines[0]}" = "acquire" ]
    [ "${lines[1]}" = "save" ]
    [ "${lines[2]}" = "reload" ]
    [ "${lines[3]}" = "release" ]
    [ "${#lines[@]}" -eq 4 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "事务应用在 lock 获取失败时立即失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.txn.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
	mark="$td/mark"
	: >"$mark"
	preflight_hard_gate() { return 0; }

    acquire_project_lock() { printf "%s\n" "acquire" >>"$mark"; return 1; }
    release_project_lock() { printf "%s\n" "release" >>"$mark"; return 0; }
    _save_project_json() { printf "%s\n" "save" >>"$mark"; return 0; }
    _write_and_enable_nginx_config() { printf "%s\n" "write" >>"$mark"; return 0; }
    _rollback_project_transaction() { printf "%s\n" "rollback" >>"$mark"; return 0; }
    control_nginx_reload_if_needed() { printf "%s\n" "reload" >>"$mark"; return 0; }

    rc=0
    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "" "standard" || rc=$?
    [ "$rc" -ne 0 ]

    mapfile -t lines <"$mark"
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "acquire" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "事务应用在保存失败时释放锁" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.txn.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
	mark="$td/mark"
	: >"$mark"
	preflight_hard_gate() { return 0; }

    acquire_project_lock() { printf "%s\n" "acquire" >>"$mark"; return 0; }
    release_project_lock() { printf "%s\n" "release" >>"$mark"; return 0; }
    _save_project_json() { printf "%s\n" "save" >>"$mark"; return 1; }
    _write_and_enable_nginx_config() { printf "%s\n" "write" >>"$mark"; return 0; }
    _rollback_project_transaction() { printf "%s\n" "rollback" >>"$mark"; return 0; }
    control_nginx_reload_if_needed() { printf "%s\n" "reload" >>"$mark"; return 0; }

    rc=0
    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "" "standard" || rc=$?
    [ "$rc" -ne 0 ]

    mapfile -t lines <"$mark"
    [ "${lines[0]}" = "acquire" ]
    [ "${lines[1]}" = "save" ]
    [ "${lines[2]}" = "release" ]
    [ "${#lines[@]}" -eq 3 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "事务应用在写配置失败时回滚并释放锁" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.txn.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
	mark="$td/mark"
	: >"$mark"
	preflight_hard_gate() { return 0; }

    acquire_project_lock() { printf "%s\n" "acquire" >>"$mark"; return 0; }
    release_project_lock() { printf "%s\n" "release" >>"$mark"; return 0; }
    _save_project_json() { printf "%s\n" "save" >>"$mark"; return 0; }
    _write_and_enable_nginx_config() { printf "%s\n" "write" >>"$mark"; return 1; }
    _rollback_project_transaction() { printf "%s\n" "rollback" >>"$mark"; return 0; }
    control_nginx_reload_if_needed() { printf "%s\n" "reload" >>"$mark"; return 0; }

    rc=0
    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "{\"domain\":\"a.example.com\"}" "standard" || rc=$?
    [ "$rc" -ne 0 ]

    mapfile -t lines <"$mark"
    [ "${lines[0]}" = "acquire" ]
    [ "${lines[1]}" = "save" ]
    [ "${lines[2]}" = "write" ]
    [ "${lines[3]}" = "rollback" ]
    [ "${lines[4]}" = "release" ]
    [ "${#lines[@]}" -eq 5 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}
