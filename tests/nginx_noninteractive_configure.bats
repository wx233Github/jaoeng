#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.noninteractive.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "configure_nginx_projects 在非交互时直接失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="true"
    IS_INTERACTIVE_MODE="false"
    _ensure_menu_interactive() { :; }
    if configure_nginx_projects; then
      exit 1
    fi
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
