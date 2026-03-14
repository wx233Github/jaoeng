#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  LIB_PATH="${REPO_ROOT}/lib/nginx_core.sh"
  LOG_FILE="$(mktemp /tmp/nginx.logging.format.XXXXXX)"
}

teardown() {
  rm -f "$LOG_FILE"
}

@test "plain_no_ctx" {
  run bash -c '
    source "$1"
    export LOG_FILE="$2"
    : >"$LOG_FILE"
    LOG_FORMAT="plain" QUIET_MODE="true" log_message INFO "hello"
    cat "$LOG_FILE"
  ' _ "$LIB_PATH" "$LOG_FILE"
  [ "$status" -eq 0 ]
  run bash -c 'grep -E "ctx=|\[[^]]+:[0-9]+\]" "$1"' _ "$LOG_FILE"
  [ "$status" -eq 1 ]
}

@test "kv_no_ctx" {
  run bash -c '
    source "$1"
    export LOG_FILE="$2"
    : >"$LOG_FILE"
    LOG_FORMAT="kv" QUIET_MODE="true" log_message INFO "hello"
    cat "$LOG_FILE"
  ' _ "$LIB_PATH" "$LOG_FILE"
  [ "$status" -eq 0 ]
  run bash -c 'grep -E "ctx=|\[[^]]+:[0-9]+\]" "$1"' _ "$LOG_FILE"
  [ "$status" -eq 1 ]
}
