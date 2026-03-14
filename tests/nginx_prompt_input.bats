#!/usr/bin/env bats

@test "prompt_input 在交互模式下输出提示" {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  run env REPO_ROOT="$REPO_ROOT" bash -c '
    set -euo pipefail
    out=$(mktemp)
    printf "example.com\n" | script -q "$out" -c "bash -lc \\\"source $REPO_ROOT/lib/nginx_core.sh; IS_INTERACTIVE_MODE=true; JB_NONINTERACTIVE=false; prompt_input '"'"'主域名'"'"' '' '' '' '"'"'false'"'"' >/dev/null\\\""
    grep -q "主域名" "$out"
    rm -f "$out"
  '
  [ "$status" -eq 0 ]
}
