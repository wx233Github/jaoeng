#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/install.sh"
  LIB_PATH="$(mktemp /tmp/install.startup.mode.XXXXXX.sh)"
  awk '
    /if \[ "\$REAL_SCRIPT_PATH" != "\$FINAL_SCRIPT_PATH" \]; then/ {skip=1; next}
    skip && /# --- 主程序依赖加载 ---/ {skip=0; print; next}
    !skip {print}
  ' "$SCRIPT_PATH" | sed '$d' >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "startup_update_mode_label 返回中文标签" {
  run bash -c '
    set -euo pipefail
    source "$1"
    [ "$(startup_update_mode_label background)" = "后台" ]
    [ "$(startup_update_mode_label legacy)" = "前台" ]
    [ "$(startup_update_mode_label unknown)" = "未知" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "set_startup_update_mode 写入配置" {
  run bash -c '
    set -euo pipefail
    source "$1"
    CONFIG_PATH="$(mktemp /tmp/install.startup.mode.config.XXXXXX.json)"
    printf "%s" "{}" >"$CONFIG_PATH"
    set_startup_update_mode "background"
    jq -e ".startup_update_mode == \"background\"" "$CONFIG_PATH" >/dev/null
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
