#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.path.profile.XXXXXX.sh)"
  awk -v root="$REPO_ROOT" '
    /^SCRIPT_PATH=/ {print "SCRIPT_PATH=\"" root "/nginx.sh\""; next}
    /^SCRIPT_DIR=/ {print "SCRIPT_DIR=\"" root "\""; next}
    {print}
  ' "$SCRIPT_PATH" | sed '$d' >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "_ensure_system_path_sbin 写入 profile" {
  run bash -c '
    set -euo pipefail
    source "$1"
    DRY_RUN="false"
    prof="$(mktemp /tmp/nginx.profile.XXXXXX)"
    printf "%s\n" "# test" >"$prof"
    NGINX_PROFILE_PATH="$prof"
    _ensure_system_path_sbin
    grep -q "Added by nginx.sh" "$prof"
    rm -f "$prof"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
