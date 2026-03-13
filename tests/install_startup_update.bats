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

@test "auto_update_status_text_for_state 输出短提示" {
  run bash -c '
    set -euo pipefail
    source "$1"
    [ "$(auto_update_status_text_for_state latest 0)" = "✅ 后台：最新" ]
    [ "$(auto_update_status_text_for_state updated 3)" = "✅ 后台：已更新3" ]
    [ "$(auto_update_status_text_for_state updated 0)" = "✅ 后台：已更新" ]
    [ "$(auto_update_status_text_for_state updated_core 0)" = "⚠ 主程序待更新" ]
    [ "$(auto_update_status_text_for_state running 0)" = "⠙ 后台检查中" ]
    [ "$(auto_update_status_text_for_state error 0)" = "⚠ 后台检查异常" ]
    [ "$(auto_update_status_text_for_state disabled 0)" = "ℹ 后台已关闭" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "handle_auto_update_core_restart 清理状态并重置标记" {
  run bash -c '
    set -euo pipefail
    source "$1"
    restart_main_script() { :; }
    run_destructive_with_sudo() { shift; rm -f "$@"; }
    DRY_RUN="false"
    AUTO_UPDATE_STATE="updated_core"
    AUTO_UPDATE_UPDATED_CORE="true"
    AUTO_UPDATE_UPDATED_COUNT="1"
    AUTO_UPDATE_STATUS_FILE="$(mktemp /tmp/jb_auto_update.status.XXXXXX)"
    AUTO_UPDATE_PID_FILE="$(mktemp /tmp/jb_auto_update.pid.XXXXXX)"
    printf "state=updated_core\nupdated_count=1\nupdated_core=true\n" >"$AUTO_UPDATE_STATUS_FILE"
    printf "999999\n" >"$AUTO_UPDATE_PID_FILE"
    handle_auto_update_core_restart
    [ "$AUTO_UPDATE_UPDATED_CORE" = "false" ]
    [ "$AUTO_UPDATE_STATE" = "updated" ]
    [ -f "$AUTO_UPDATE_STATUS_FILE" ]
    updated_core=""
    while IFS='=' read -r key value; do
      if [ "$key" = "updated_core" ]; then updated_core="$value"; fi
    done <"$AUTO_UPDATE_STATUS_FILE"
    [ "$updated_core" = "false" ]
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
