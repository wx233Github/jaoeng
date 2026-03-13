#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.project.prompt.XXXXXX.sh)"
  awk -v root="$REPO_ROOT" '
    /^SCRIPT_PATH=/ {print "SCRIPT_PATH=\"" root "/nginx.sh\""; next}
    /^SCRIPT_DIR=/ {print "SCRIPT_DIR=\"" root "\""; next}
    {print}
  ' "$SCRIPT_PATH" | sed '$d' >"$LIB_PATH"
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

@test "_gather_project_details 先询问域名再询问端口" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="false"
    IS_INTERACTIVE_MODE="true"
    log_file="$(mktemp /tmp/nginx.prompt.order.XXXXXX)"
    prompt_input() {
      printf "%s\n" "$1" >>"$log_file"
      if [ "$1" = "主域名" ]; then
        printf "%s\n" "example.com"
        return 0
      fi
      if [ "$1" = "后端目标 (容器名/端口)" ]; then
        printf "%s\n" "3000"
        return 0
      fi
      printf "%s\n" ""
      return 0
    }
    _check_dns_resolution() { return 0; }
    confirm_or_cancel() { return 1; }
    _detect_reusable_wildcard_cert() { printf "%s\t%s\t%s\n" "false" "" ""; }
    _prompt_ca_selection() { printf "%s\t%s\n" "" ""; }
    _prompt_validation_method_selection() { printf "%s\x01%s\x01%s\x01%s\x01%s\x01%s\n" "http-01" "" "n" "false" "local_port" "3000"; }
    _resolve_mcp_token_from_json() { printf "%s" ""; }
    _build_project_payload_json() { printf "{}\n"; }
    cur='{}'
    _gather_project_details "$cur" "true" ""
    line1=""
    line2=""
    while IFS= read -r line; do
      if [ -z "$line1" ]; then line1="$line"; continue; fi
      if [ -z "$line2" ]; then line2="$line"; break; fi
    done <"$log_file"
    [ "$line1" = "主域名" ]
    [ "$line2" = "后端目标 (容器名/端口)" ]
    rm -f "$log_file"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
