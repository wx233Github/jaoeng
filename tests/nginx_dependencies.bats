#!/usr/bin/env bats

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
	SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
	LIB_PATH="$(mktemp /tmp/nginx.deps.lib.XXXXXX.sh)"
	sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
	rm -f "$LIB_PATH"
}

@test "_ensure_nginx_in_path 会自动补齐 PATH" {
	run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.deps.path.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    NGINX_BIN_CANDIDATES=("$td/nginx")
    LOG_FILE="$td/test.log"
    SAFE_PATH_ROOTS=("/tmp" "$td")
    export PATH="/bin"

    cat <<"EOF" >"$td/nginx"
#!/bin/sh
echo "nginx version: nginx/1.2.3" >&2
exit 0
EOF
    chmod +x "$td/nginx"

    _ensure_nginx_in_path
    case ":$PATH:" in
      *":$td:"*) exit 0 ;;
      *) exit 1 ;;
    esac
  ' _ "$LIB_PATH"
	[ "$status" -eq 0 ]
}

@test "check_dependencies 在 nginx 不在 PATH 时仍可通过" {
	run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.deps.check.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    LOG_FILE="$td/test.log"
    SAFE_PATH_ROOTS=("/tmp" "$td")
    PATH="/bin:/usr/bin"
    export PATH
    mkdir -p "$td/bin"

    for cmd in curl socat openssl jq idn nano flock timeout awk sed grep sha256sum ls date cp dig mkdir touch; do
      cat <<"EOF" >"$td/bin/$cmd"
#!/bin/sh
exit 0
EOF
      chmod +x "$td/bin/$cmd"
    done

    NGINX_BIN_CANDIDATES=("$td/sbin/nginx")
    mkdir -p "$td/sbin"
    cat <<"EOF" >"$td/sbin/nginx"
#!/bin/sh
exit 0
EOF
    chmod +x "$td/sbin/nginx"

    export PATH="$td/bin:/bin:/usr/bin"
    check_dependencies
  ' _ "$LIB_PATH"
	[ "$status" -eq 0 ]
}
