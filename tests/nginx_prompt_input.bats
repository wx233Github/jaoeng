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

@test "_gather_project_details 会输出包含 domain 与 method 的 JSON" {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  run env REPO_ROOT="$REPO_ROOT" bash -c '
    set -euo pipefail
    TMP=$(mktemp /tmp/nginx.core.XXXXXX.sh)
    head -n -1 "$REPO_ROOT/nginx.sh" >"$TMP"
    source "$TMP"
    IS_INTERACTIVE_MODE=true
    JB_NONINTERACTIVE=false
    prompt_input() {
      case "$1" in
        "主域名") printf "%s\n" "mcphub.ckd.qzz.io" ;;
        *) printf "%s\n" "" ;;
      esac
    }
    _prompt_backend_target_for_project() { printf "%s\t%s\n" "local_port" "3000"; }
    _check_dns_resolution() { return 0; }
    _detect_reusable_wildcard_cert() { printf "%s\t%s\t%s\n" "false" "" ""; }
    _render_menu() { return 0; }
    prompt_menu_choice() { printf "%s\n" "1"; }
    confirm_or_cancel() { return 1; }
    _prompt_mcp_protection_settings() { printf "%s\t%s\n" "" ""; }
    json=$(_gather_project_details "{}" "false" "standard")
    echo "$json" | jq -e '.domain == "mcphub.ckd.qzz.io"' >/dev/null
    echo "$json" | jq -e '.acme_validation_method == "http-01"' >/dev/null
    rm -f "$TMP"
  '
  [ "$status" -eq 0 ]
}
