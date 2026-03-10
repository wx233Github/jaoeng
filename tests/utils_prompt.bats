#!/usr/bin/env bats

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
	UTILS_PATH="${REPO_ROOT}/utils.sh"
}

@test "_prompt_for_menu_choice 优先读取标准输入" {
	run bash -c '
    set -euo pipefail
    source "$1"
    JB_TTY_PATH="/tmp/tty.missing"
    JB_NONINTERACTIVE=false
    printf "2\n" | _prompt_for_menu_choice "1-3" ""
  ' _ "$UTILS_PATH"
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
}

@test "_prompt_user_input 优先读取标准输入" {
	run bash -c '
    set -euo pipefail
    source "$1"
    JB_TTY_PATH="/tmp/tty.missing"
    JB_NONINTERACTIVE=false
    printf "hello\n" | _prompt_user_input "请输入" "default"
  ' _ "$UTILS_PATH"
	[ "$status" -eq 0 ]
	[ "$output" = "hello" ]
}
