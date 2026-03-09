#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.preflight.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "preflight 在 MCP token 引用缺失时返回校验码 20" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export PROJECTS_METADATA_FILE="$td/projects.json"
    printf "%s\n" "[{\"domain\":\"a.example.com\",\"mcp_protect_path\":\"/mcp\",\"mcp_token_ref\":\"$td/notfound.token\"}]" >"$PROJECTS_METADATA_FILE"

    check_dependencies() { return 0; }
    _preflight_check_active_conf_include() { return 0; }
    _preflight_check_reload_strategy() { return 0; }
    _preflight_check_template_assets() { return 0; }
    _stream_module_available() { return 0; }

    set +e
    run_preflight
    code=$?
    set -e
    [ "$code" -eq 20 ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "preflight 全部通过时返回 0" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.ok.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
    token="$td/a.token"
    printf "%s\n" "0123456789abcdef" >"$token"
    chmod 600 "$token"
    export SAFE_PATH_ROOTS=("$td")
    export PROJECTS_METADATA_FILE="$td/projects.json"
    printf "%s\n" "[{\"domain\":\"a.example.com\",\"mcp_protect_path\":\"/mcp\",\"mcp_token_ref\":\"$token\"}]" >"$PROJECTS_METADATA_FILE"

    check_dependencies() { return 0; }
    _preflight_check_active_conf_include() { return 0; }
    _preflight_check_reload_strategy() { return 0; }
    _preflight_check_template_assets() { return 0; }
    _stream_module_available() { return 0; }

    run_preflight
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
