#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.inject.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "active conf include 注入预检失败时不写入" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.inject.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
    conf="$td/custom-nginx.conf"
    cat >"$conf" <<"EOF"
events {}
http {
    server { listen 80; }
}
EOF

    export SAFE_PATH_ROOTS=("$td")
    _get_active_nginx_main_conf() { printf "%s\n" "$conf"; }
    nginx() { return 1; }

    before=$(sha256sum "$conf" | awk "{print \$1}")
    _ensure_active_nginx_http_include_sites_enabled || true
    after=$(sha256sum "$conf" | awk "{print \$1}")
    [ "$before" = "$after" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
