#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.logging.dryrun.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "log_message 默认隐藏函数名与行号" {
  run bash -c '
    source "$1"
    LOG_LEVEL="INFO"
    LOG_FILE="/tmp/nginx.log.context"
    LOG_WITH_OP_TAG="false"
    IS_INTERACTIVE_MODE="true"
    QUIET_MODE="false"
    test_log() { log_message INFO "hello"; }
    test_log
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \[INFO\]\ hello ]]
  [[ ! "$output" =~ \[[^:]+:[0-9]+\] ]]
  [[ ! "$output" =~ ^\[[0-9]{4}- ]]
}

@test "log_message includes function and line without timestamp" {
  run bash -c '
    source "$1"
    LOG_LEVEL="INFO"
    LOG_FILE="/tmp/nginx.log.context"
    LOG_WITH_OP_TAG="false"
    LOG_HIDE_CTX_PREFIX="false"
    IS_INTERACTIVE_MODE="true"
    QUIET_MODE="false"
    test_log() { log_message INFO "hello"; }
    test_log
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \[INFO\]\ \[[^:]+:[0-9]+\]\ hello ]]
  [[ ! "$output" =~ ^\[[0-9]{4}- ]]
}

@test "dry-run skips destructive commands" {
  run bash -c '
    source "$1"
    LOG_LEVEL="INFO"
    LOG_FILE="/tmp/nginx.log.dryrun"
    IS_INTERACTIVE_MODE="true"
    QUIET_MODE="false"
    DRY_RUN="true"
    target=$(mktemp /tmp/nginx.dryrun.target.XXXXXX)
    rm "$target"
    if [ ! -f "$target" ]; then
      printf "%s\n" "unexpected removal"
      exit 1
    fi
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" =~ \[DRY-RUN\] ]]
  [[ "$output" =~ command[[:space:]]rm ]]
}
