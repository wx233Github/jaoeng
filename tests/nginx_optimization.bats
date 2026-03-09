#!/usr/bin/env bats
# Coverage Matrix
# - _apply_nginx_conf_with_validation: 配置应用在临时文件包含字面量\n时拒绝写入
# - _apply_nginx_conf_with_validation: nginx -t 失败时有快照则回滚
# - _apply_nginx_conf_with_validation: nginx -t 失败且无快照则删除目标配置
# - _apply_project_transaction: 项目事务在完成后释放 project 锁
# - _write_and_enable_nginx_config: T3 MCP 路径配置 + Token 缺失拒绝写入
# - _write_and_enable_nginx_config: T3 MCP Token 配置 + 路径缺失拒绝写入
# - _write_and_enable_nginx_config: 健康检查失败回滚并返回校验错误
#
# Fixture Conventions
# - 每个测试使用 mktemp -d + trap 清理，避免污染真实目录
# - 涉及写入/读取路径时设置 SAFE_PATH_ROOTS 指向临时目录
# - 外部依赖仅通过 stub 函数替换（systemctl/crontab/jq 等）

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  SCRIPT_PATH_FILE="$SCRIPT_PATH"
  LIB_PATH="$(mktemp /tmp/nginx.opt.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH_FILE" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "配置应用在临时文件包含字面量\\n时拒绝写入" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.render.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export CONF_BACKUP_DIR="$td/conf_backups"
    mkdir -p "$CONF_BACKUP_DIR"

    temp_conf="$td/temp.conf"
    target_conf="$td/target.conf"
    printf "%s\n" "server {" >"$temp_conf"
    printf "%s\n" "  return 200 \\n;" >>"$temp_conf"
    printf "%s\n" "}" >>"$temp_conf"

    set +e
    _apply_nginx_conf_with_validation "$temp_conf" "$target_conf" "demo" "http" "true"
    rc=$?
    set -e

    [ "$rc" -eq 20 ]
    [ ! -f "$target_conf" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "nginx -t 失败时有快照则回滚配置" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.render.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export CONF_BACKUP_DIR="$td/conf_backups"
    mkdir -p "$CONF_BACKUP_DIR"

    temp_conf="$td/temp.conf"
    target_conf="$td/target.conf"
    expected_conf="$td/expected.conf"
    printf "%s\n" "original-config" >"$target_conf"
    printf "%s\n" "original-config" >"$expected_conf"
    printf "%s\n" "new-config" >"$temp_conf"

    nginx() {
      if [ "${1:-}" = "-t" ]; then
        printf "%s\n" "nginx test failed" >&2
        return 1
      fi
      return 0
    }

    set +e
    _apply_nginx_conf_with_validation "$temp_conf" "$target_conf" "demo" "http" "false"
    rc=$?
    set -e

    [ "$rc" -eq "$ERR_CFG_VALIDATE" ]
    cmp -s "$expected_conf" "$target_conf"
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "nginx -t 失败且无快照则删除目标配置" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.render.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export CONF_BACKUP_DIR="$td/conf_backups"
    mkdir -p "$CONF_BACKUP_DIR"

    temp_conf="$td/temp.conf"
    target_conf="$td/target.conf"
    printf "%s\n" "new-config" >"$temp_conf"

    nginx() {
      if [ "${1:-}" = "-t" ]; then
        printf "%s\n" "nginx test failed" >&2
        return 1
      fi
      return 0
    }

    set +e
    _apply_nginx_conf_with_validation "$temp_conf" "$target_conf" "demo" "http" "false"
    rc=$?
    set -e

    [ "$rc" -eq "$ERR_CFG_VALIDATE" ]
    [ ! -f "$target_conf" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "MCP 接口路径配置但 Token 为空时拒绝写入" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.mcp.XXXXXX)"
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

    marker="$td/apply_called"
    get_vps_ip() { VPS_IPV6=""; }
    _apply_nginx_conf_with_validation() { printf "%s\n" "called" >"$marker"; return 0; }
    _health_check_nginx_config() { return 0; }

    json=$(jq -n --arg p "8080" --arg cert "$cert" --arg key "$key" --arg mp "/mcp" \
      "{resolved_port:\$p, cert_file:\$cert, key_file:\$key, mcp_protect_path:\$mp}")

    set +e
    _write_and_enable_nginx_config "example.com" "$json"
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    [ ! -f "$NGINX_SITES_AVAILABLE_DIR/example.com.conf" ]
    [ ! -e "$NGINX_SITES_ENABLED_DIR/example.com.conf" ]
    [ ! -f "$marker" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "MCP Token 配置但接口路径为空时拒绝写入" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.mcp.XXXXXX)"
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

    marker="$td/apply_called"
    get_vps_ip() { VPS_IPV6=""; }
    _apply_nginx_conf_with_validation() { printf "%s\n" "called" >"$marker"; return 0; }
    _health_check_nginx_config() { return 0; }

    json=$(jq -n --arg p "8080" --arg cert "$cert" --arg key "$key" --arg mt "0123456789abcdef" \
      "{resolved_port:\$p, cert_file:\$cert, key_file:\$key, mcp_token:\$mt}")

    set +e
    _write_and_enable_nginx_config "example.com" "$json"
    rc=$?
    set -e

    [ "$rc" -ne 0 ]
    [ ! -f "$NGINX_SITES_AVAILABLE_DIR/example.com.conf" ]
    [ ! -e "$NGINX_SITES_ENABLED_DIR/example.com.conf" ]
    [ ! -f "$marker" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "健康检查失败时回滚配置并返回校验错误" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.health.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT

    export SAFE_PATH_ROOTS=("$td")
    export NGINX_SITES_AVAILABLE_DIR="$td/sites-available"
    export NGINX_SITES_ENABLED_DIR="$td/sites-enabled"
    export NGINX_WEBROOT_DIR="$td/webroot"
    export CONF_BACKUP_DIR="$td/conf_backups"
    mkdir -p "$NGINX_SITES_AVAILABLE_DIR" "$NGINX_SITES_ENABLED_DIR" "$NGINX_WEBROOT_DIR" "$CONF_BACKUP_DIR"

    cert="$td/test.cer"
    key="$td/test.key"
    : >"$cert"
    : >"$key"

    backup_conf="$CONF_BACKUP_DIR/http_example.com_20240101_000000.conf.bak"
    printf "%s\n" "rollback-config" >"$backup_conf"

    get_vps_ip() { VPS_IPV6=""; }
    _apply_nginx_conf_with_validation() { cp "$1" "$2"; return 0; }
    _health_check_nginx_config() { return 1; }
    control_nginx_reload_if_needed() { printf "%s\n" "reload" >"$td/reload"; return 0; }

    json=$(jq -n --arg p "8080" --arg cert "$cert" --arg key "$key" \
      "{resolved_port:\$p, cert_file:\$cert, key_file:\$key}")

    set +e
    _write_and_enable_nginx_config "example.com" "$json"
    rc=$?
    set -e

    [ "$rc" -eq "$ERR_CFG_VALIDATE" ]
    cmp -s "$backup_conf" "$NGINX_SITES_AVAILABLE_DIR/example.com.conf"
    [ -f "$td/reload" ]
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "项目事务在完成后释放 project 锁" {
  run bash -c '
    set -euo pipefail
    source "$1"
    td="$(mktemp -d /tmp/nginx.opt.store.XXXXXX)"
    trap "rm -rf \"$td\"" EXIT
    mark="$td/mark"
    : >"$mark"

    acquire_project_lock() { printf "%s\n" "acquire" >>"$mark"; return 0; }
    release_project_lock() { printf "%s\n" "release" >>"$mark"; return 0; }
    _save_project_json() { return 0; }
    _write_and_enable_nginx_config() { return 0; }
    control_nginx_reload_if_needed() { return 0; }

    _apply_project_transaction "a.example.com" "{\"domain\":\"a.example.com\"}" "" "standard"

    grep -q "^acquire$" "$mark"
    grep -q "^release$" "$mark"
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
}
