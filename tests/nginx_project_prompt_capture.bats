#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.project.prompt.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "_gather_project_details 能捕获提示输入" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="false"
    IS_INTERACTIVE_MODE="true"
    prompt_input() { printf "%s\n" "example.com"; }
    _detect_reusable_wildcard_cert() { printf "%s\t%s\t%s\n" "false" "" ""; }
    _resolve_mcp_token_from_json() { printf "%s" ""; }
    _build_project_payload_json() { printf "{\"domain\":\"%s\"}\n" "$1"; }
    json=$(_gather_project_details "{}" "true" "cert_only")
    jq -e ".domain == \"example.com\"" <<<"$json" >/dev/null
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
