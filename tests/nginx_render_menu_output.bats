#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.render.menu.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "_render_menu 在无 tty 时输出到 stdout" {
  run bash -c '
    set -euo pipefail
    source "$1"
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      exit 0
    fi
    output=$(_render_menu "标题" "1. 项目" 2>/dev/null)
    [[ "$output" =~ 标题 ]]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
