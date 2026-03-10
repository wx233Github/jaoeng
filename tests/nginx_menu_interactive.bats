#!/usr/bin/env bats

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
	SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
	LIB_PATH="$(mktemp /tmp/nginx.menu.interactive.XXXXXX.sh)"
	sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
	rm -f "$LIB_PATH"
}

@test "_ensure_menu_interactive 在检测到 tty 时恢复交互模式" {
	run bash -c '
    set -euo pipefail
    source "$1"
    IS_INTERACTIVE_MODE="false"
    JB_NONINTERACTIVE="false"
    _tty_available() { return 0; }
    _ensure_menu_interactive
    [ "$IS_INTERACTIVE_MODE" = "true" ]
  ' _ "$LIB_PATH"
	[ "$status" -eq 0 ]
}
