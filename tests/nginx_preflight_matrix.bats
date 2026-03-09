#!/usr/bin/env bats
# Coverage Matrix
# - run_preflight: 子检查失败矩阵 (active conf include/reload/template assets/mcp token invalid)
# - run_preflight: MCP token 权限警告不影响通过
#
# Fixture Conventions
# - 每个测试使用 mktemp -d + trap 清理，避免污染真实目录
# - 涉及文件访问时设置 SAFE_PATH_ROOTS 指向临时目录
# - 外部依赖仅通过 stub 函数替换

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.preflight.matrix.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "preflight active 主配置未接入 sites-enabled 时返回 20" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.matrix.active.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    active_conf="$td/nginx.conf"
    [ "${active_conf#"$td/"}" != "$active_conf" ]
    printf "%s\n" "events {}" "http {}" >"$active_conf"

    _get_active_nginx_main_conf() { printf "%s\n" "$active_conf"; }
    check_dependencies() { return 0; }
    _preflight_check_reload_strategy() { return 0; }
    _preflight_check_template_assets() { return 0; }
    _preflight_check_mcp_token_refs() { return 0; }
    _stream_module_available() { return 0; }

    set +e
    run_preflight
    code=$?
    set -e
    [ "$code" -eq 20 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "preflight reload 策略不可用时返回 20" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.matrix.reload.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    check_dependencies() { return 0; }
    _preflight_check_active_conf_include() { return 0; }
    _preflight_check_template_assets() { return 0; }
    _preflight_check_mcp_token_refs() { return 0; }
    _stream_module_available() { return 0; }
    _select_reload_strategy() { printf "%s\n" "systemctl"; }
    systemctl() { return 1; }

    set +e
    run_preflight
    code=$?
    set -e
    [ "$code" -eq 20 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "preflight 缺失模板片段时返回 20" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.matrix.templates.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export NGINX_TEMPLATE_DIR="$td/templates"
    export NGINX_TEMPLATE_MANIFEST="$td/templates/manifest.json"
    [ "${NGINX_TEMPLATE_DIR#"$td/"}" != "$NGINX_TEMPLATE_DIR" ]
    [ "${NGINX_TEMPLATE_MANIFEST#"$td/"}" != "$NGINX_TEMPLATE_MANIFEST" ]
    mkdir -p "$NGINX_TEMPLATE_DIR"
    printf "%s\n" "{}" >"$NGINX_TEMPLATE_MANIFEST"

    check_dependencies() { return 0; }
    _preflight_check_active_conf_include() { return 0; }
    _preflight_check_reload_strategy() { return 0; }
    _preflight_check_mcp_token_refs() { return 0; }
    _stream_module_available() { return 0; }
    _ensure_template_manifest_available() { return 0; }
    jq() { printf "%s\n" "missing.conf"; }

    set +e
    run_preflight
    code=$?
    set -e
    [ "$code" -eq 20 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "preflight MCP token 引用无效时返回 20" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.matrix.mcp.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export PROJECTS_METADATA_FILE="$td/projects.json"
    token_ref_path="$td/bad.token"
    [ "${PROJECTS_METADATA_FILE#"$td/"}" != "$PROJECTS_METADATA_FILE" ]
    [ "${token_ref_path#"$td/"}" != "$token_ref_path" ]
    printf "%s\n" "bad" >"$token_ref_path"
    chmod 600 "$token_ref_path"
    [ "$(stat -c "%a" "$token_ref_path")" -eq 600 ]
    printf "%s\n" "[]" >"$PROJECTS_METADATA_FILE"

    check_dependencies() { return 0; }
    _preflight_check_active_conf_include() { return 0; }
    _preflight_check_reload_strategy() { return 0; }
    _preflight_check_template_assets() { return 0; }
    _stream_module_available() { return 0; }
    jq() { printf "%s\t%s\t%s\n" "a.example.com" "/mcp" "$token_ref_path"; }

    set +e
    run_preflight
    code=$?
    set -e
    [ "$code" -eq 20 ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "preflight MCP token 权限非 600 仅警告仍通过" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.preflight.matrix.perm.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export PROJECTS_METADATA_FILE="$td/projects.json"
    token_ref_path="$td/ok.token"
    [ "${PROJECTS_METADATA_FILE#"$td/"}" != "$PROJECTS_METADATA_FILE" ]
    [ "${token_ref_path#"$td/"}" != "$token_ref_path" ]
    printf "%s\n" "0123456789abcdef" >"$token_ref_path"
    chmod 644 "$token_ref_path"
    [ "$(stat -c "%a" "$token_ref_path")" -eq 644 ]
    printf "%s\n" "[]" >"$PROJECTS_METADATA_FILE"

    check_dependencies() { return 0; }
    _preflight_check_active_conf_include() { return 0; }
    _preflight_check_reload_strategy() { return 0; }
    _preflight_check_template_assets() { return 0; }
    _stream_module_available() { return 0; }
    jq() { printf "%s\t%s\t%s\n" "a.example.com" "/mcp" "$token_ref_path"; }

    run_preflight
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}
