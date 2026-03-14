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

@test "active conf 为 sing-box 且开关开启时跳过注入" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.inject.singbox.XXXXXX)"
    conf="/etc/sing-box/nginx.conf"
    backup=""
    cleanup() {
      if [ -n "$backup" ] && [ -f "$backup" ]; then
        cp -p "$backup" "$conf"
      else
        rm -f "$conf"
      fi
      rmdir /etc/sing-box 2>/dev/null || true
      rm -rf "$td"
    }
    trap cleanup EXIT

    if [ -f "$conf" ]; then
      backup="$td/nginx.conf.bak"
      cp -p "$conf" "$backup"
    fi

    mkdir -p /etc/sing-box
    cat >"$conf" <<"EOF"
events {}
http {
    server { listen 12030; }
}
EOF

    export NGINX_SKIP_INCLUDE_CONFS=true
    _get_active_nginx_main_conf() { printf "%s\n" "$conf"; }

    before=$(sha256sum "$conf" | awk "{print \$1}")
    _ensure_active_nginx_http_include_sites_enabled || true
    after=$(sha256sum "$conf" | awk "{print \$1}")

    [ "$before" = "$after" ]
    ! grep -q "sites-enabled" "$conf"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
