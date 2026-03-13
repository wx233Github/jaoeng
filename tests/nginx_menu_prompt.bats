#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.menu.prompt.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "prompt_menu_choice 在非交互允许空输入时返回失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="true"
    IS_INTERACTIVE_MODE="false"
    if prompt_menu_choice "1-2" "true"; then
      exit 1
    fi
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "prompt_menu_choice 强制数字范围校验并重试" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="false"
    IS_INTERACTIVE_MODE="true"
    inputs=("9" "1")
    idx=0
    _read_input_prompt() {
      REPLY="${inputs[$idx]:-}"
      idx=$((idx + 1))
      return 0
    }
    choice=$(prompt_menu_choice "1-2" "false")
    [ "$choice" = "1" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
