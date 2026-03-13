#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.safe.rm.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "safe_rm 在 DRY_RUN 时不删除文件" {
  run bash -c '
    set -euo pipefail
    source "$1"
    SAFE_PATH_ROOTS=("/tmp")
    DRY_RUN="true"
    f="$(mktemp /tmp/nginx.safe.rm.XXXXXX)"
    safe_rm "$f" "测试删除"
    [ -f "$f" ]
    rm -f "$f"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "safe_rm 在非 DRY_RUN 时删除文件" {
  run bash -c '
    set -euo pipefail
    source "$1"
    SAFE_PATH_ROOTS=("/tmp")
    DRY_RUN="false"
    f="$(mktemp /tmp/nginx.safe.rm.XXXXXX)"
    safe_rm "$f" "测试删除"
    [ ! -f "$f" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
