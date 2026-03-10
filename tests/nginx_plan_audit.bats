#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.plan.audit.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "plan mode collects actions" {
  run bash -c '
    source "$1"
    LOG_LEVEL="INFO"
    LOG_FILE="/tmp/nginx.plan.log"
    IS_INTERACTIVE_MODE="true"
    QUIET_MODE="false"
    DRY_RUN="true"
    PLAN_MODE="true"
    target=$(mktemp /tmp/nginx.plan.target.XXXXXX)
    rm "$target"
    _plan_flush
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "计划:" ]]
  [[ "$output" =~ "command" ]]
  [[ "$output" =~ "rm" ]]
}

@test "audit report summarizes wal" {
  run bash -c '
    source "$1"
    tmp_wal=$(mktemp /tmp/nginx.wal.XXXXXX)
    printf "%s\n" "1|op1|example.com|BEGIN|standard|/tmp/snap.json|msg" >"$tmp_wal"
    printf "%s\n" "2|op1|example.com|COMMIT|standard|/tmp/snap.json|msg" >>"$tmp_wal"
    printf "%s\n" "3|op2|example.com|FAIL|standard|/tmp/snap.json|msg" >>"$tmp_wal"
    TX_WAL_FILE="$tmp_wal"
    tx_wal_summary
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "total=3" ]]
}
