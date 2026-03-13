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

@test "run_startup_update_legacy 不输出 config.json 更新提示" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_RESTARTED="false"
    run_comprehensive_auto_update() {
      printf "%s\n" "config.json"
    }
    startup_update_spinner() { :; }
    startup_update_done_line() { :; }
    run_startup_update_legacy
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ 配置文件[[:space:]]config\.json[[:space:]]已更新 ]]
}
