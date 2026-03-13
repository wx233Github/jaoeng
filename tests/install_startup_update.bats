#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/install.sh"
  LIB_PATH="$(mktemp /tmp/install.startup.XXXXXX.sh)"
  awk '
    /if \[ "\$REAL_SCRIPT_PATH" != "\$FINAL_SCRIPT_PATH" \]; then/ {skip=1; next}
    skip && /# --- 主程序依赖加载 ---/ {skip=0; print; next}
    !skip {print}
  ' "$SCRIPT_PATH" | sed '$d' >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "_log_prefix 输出包含函数名与行号" {
  run bash -c '
    set -euo pipefail
    source "$1"
    test_func() { _log_prefix; }
    output=$(test_func)
    [[ "$output" =~ ^\[[A-Za-z0-9_]+:[0-9]+\]\ $ ]]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
