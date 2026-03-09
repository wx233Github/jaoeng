#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.tx.lifecycle.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "非法状态转移返回 ERR_TX_CONTRACT 并输出 CONTRACT_INVALID" {
  run bash -c '
    set -euo pipefail
    source "$1"
    tx_begin "tx.example.com"
    set +e
    tx_transition "committed" "skip phases"
    rc=$?
    set -e
    printf "RC=%s\n" "$rc"
    [ "$rc" -eq "${ERR_TX_CONTRACT:-31}" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:CONTRACT_INVALID]"* ]]
}

@test "preflight 失败会阻断事务并返回 PRECHECK_BLOCK" {
  run bash -c '
    set -euo pipefail
    source "$1"
    run_preflight() { return 1; }
    acquire_project_lock() { return 0; }
    release_project_lock() { return 0; }
    _save_project_json() { return 0; }
    _write_and_enable_nginx_config() { return 0; }
    control_nginx_reload_if_needed() { return 0; }
    set +e
    _apply_project_transaction "tx.example.com" "{\"domain\":\"tx.example.com\"}" "" "standard"
    rc=$?
    set -e
    printf "RC=%s\n" "$rc"
    [ "$rc" -eq "${ERR_CFG_VALIDATE:-20}" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:PRECHECK_BLOCK]"* ]]
}

@test "幂等重试同 token+hash 直接成功，冲突重放返回 EX_DATAERR" {
  run bash -c '
    set -euo pipefail
    source "$1"
    base="{\"domain\":\"idem.example.com\",\"idempotency_token\":\"token-123456\"}"
    h=$(_json_sha256 "$base")
    old_ok="{\"domain\":\"idem.example.com\",\"idempotency_token\":\"token-123456\",\"config_hash\":\"$h\"}"
    old_bad="{\"domain\":\"idem.example.com\",\"idempotency_token\":\"token-123456\",\"config_hash\":\"deadbeef\"}"

    run_preflight() { return 0; }
    acquire_project_lock() { return 0; }
    release_project_lock() { return 0; }
    _save_project_json() { return 0; }
    _write_and_enable_nginx_config() { return 0; }
    control_nginx_reload_if_needed() { return 0; }

    _apply_project_transaction "idem.example.com" "$base" "$old_ok" "standard"

    set +e
    _apply_project_transaction "idem.example.com" "$base" "$old_bad" "standard"
    rc=$?
    set -e
    printf "RC=%s\n" "$rc"
    [ "$rc" -eq "${EX_DATAERR:-65}" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:IDEMPOTENT_REPLAY]"* ]]
  [[ "$output" == *"[TX:REPLAY_CONFLICT]"* ]]
}

@test "提交成功路径输出 APPLY_COMMIT" {
  run bash -c '
    set -euo pipefail
    source "$1"
    run_preflight() { return 0; }
    acquire_project_lock() { return 0; }
    release_project_lock() { return 0; }
    _save_project_json() { return 0; }
    _write_and_enable_nginx_config() { return 0; }
    control_nginx_reload_if_needed() { return 0; }
    _apply_project_transaction "ok.example.com" "{\"domain\":\"ok.example.com\"}" "" "standard"
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:APPLY_COMMIT]"* ]]
}

@test "锁竞争路径输出 LOCK_HELD" {
  run bash -c '
    set -euo pipefail
    source "$1"
    acquire_project_lock() { return 1; }
    set +e
    _apply_project_transaction "lock.example.com" "{\"domain\":\"lock.example.com\"}" "" "standard"
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:LOCK_HELD]"* ]]
}

@test "回滚完成路径输出 ROLLBACK_DONE" {
  run bash -c '
    set -euo pipefail
    source "$1"
    _save_project_json() { return 0; }
    _write_and_enable_nginx_config() { return 0; }
    _remove_and_disable_nginx_config() { return 0; }
    _delete_project_json() { return 0; }
    control_nginx_reload_if_needed() { return 0; }
    tx_begin "rb.example.com"
    tx_transition "failed" "force rollback"
    _rollback_project_transaction "rb.example.com" "{\"domain\":\"rb.example.com\"}" "standard"
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:ROLLBACK_DONE]"* ]]
}

@test "续签漂移路径输出 RECONCILE_DRIFT" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.tx.reconcile.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
    export PROJECTS_METADATA_FILE="$td/projects.json"
    printf "[]\n" >"$PROJECTS_METADATA_FILE"

    preflight_hard_gate() { return 0; }
    acquire_cert_lock() { return 0; }
    _renew_fail_cleanup() { return 0; }
    jq() { printf "bad.example.com\1$td/missing.cer\1http-01\n"; }
    _get_project_json() { printf "{\"domain\":\"bad.example.com\"}\n"; }
    _issue_and_install_certificate() { return 1; }
    _renew_fail_incr() { printf "3\n"; }
    _send_tg_notify() { return 0; }
    control_nginx_reload_if_needed() { return 0; }

    set +e
    check_and_auto_renew_certs
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[TX:RECONCILE_DRIFT]"* ]]
}
