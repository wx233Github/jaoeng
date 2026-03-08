#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "MCP 接口路径校验：必须为非根路径" {
  run bash -c 'source "$1"; _is_valid_location_path "/mcp"' _ "$LIB_PATH"
  [ "$status" -eq 0 ]

  run bash -c 'source "$1"; _is_valid_location_path "/"' _ "$LIB_PATH"
  [ "$status" -ne 0 ]
}

@test "MCP Token 校验：长度至少 16" {
  run bash -c 'source "$1"; _is_valid_mcp_token "0123456789abcdef"' _ "$LIB_PATH"
  [ "$status" -eq 0 ]

  run bash -c 'source "$1"; _is_valid_mcp_token "short-token"' _ "$LIB_PATH"
  [ "$status" -ne 0 ]
}

@test "生成站点配置时包含 MCP Token 防护规则" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.mcp.cfg.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export NGINX_SITES_AVAILABLE_DIR="$td/sites-available"
    export NGINX_SITES_ENABLED_DIR="$td/sites-enabled"
    export NGINX_WEBROOT_DIR="$td/webroot"
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR"

    cert="$td/test.cer"
    key="$td/test.key"
    : >"$cert"
    : >"$key"

    get_vps_ip() { VPS_IPV6=""; }
    _apply_nginx_conf_with_validation() { cp "$1" "$2"; return 0; }
    _health_check_nginx_config() { return 0; }

    json=$(jq -n --arg p "8080" --arg cert "$cert" --arg key "$key" --arg mp "/mcp" --arg mt "0123456789abcdef" \
      "{resolved_port:\$p, cert_file:\$cert, key_file:\$key, mcp_protect_path:\$mp, mcp_token:\$mt}")

    _write_and_enable_nginx_config "example.com" "$json"
    conf="$NGINX_SITES_AVAILABLE_DIR/example.com.conf"
    [ -f "$conf" ]
    grep -q "location = /mcp" "$conf"
    grep -q "return 403" "$conf"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "保存项目时 mcp_token 脱敏外置存储" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.mcp.persist.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export PROJECTS_METADATA_FILE="$td/projects.json"
    export JSON_BACKUP_DIR="$td/projects_backups"
    export MCP_TOKEN_DIR="$td/mcp_tokens"
    mkdir -p "$JSON_BACKUP_DIR" "$MCP_TOKEN_DIR"
    printf "%s\n" "[]" >"$PROJECTS_METADATA_FILE"

    json=$(jq -n --arg d "example.com" --arg t "0123456789abcdef" --arg p "/mcp" \
      "{domain:\$d,resolved_port:\"8080\",acme_validation_method:\"http-01\",cert_file:\"/tmp/cert\",key_file:\"/tmp/key\",mcp_protect_path:\$p,mcp_token:\$t}")

    _save_project_json "$json"

    stored_token=$(jq -r ".[0].mcp_token // empty" "$PROJECTS_METADATA_FILE")
    [ -z "$stored_token" ]
    token_ref=$(jq -r ".[0].mcp_token_ref // empty" "$PROJECTS_METADATA_FILE")
    [ -n "$token_ref" ]
    [ -f "$token_ref" ]
    token_file_value=$(head -n1 "$token_ref")
    [ "$token_file_value" = "0123456789abcdef" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
