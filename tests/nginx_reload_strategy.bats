#!/usr/bin/env bats
# Coverage Matrix
# - _select_reload_strategy: 无 systemctl 优先 nginx -c / 无 -c 时回退 nginx -s reload
# - control_nginx: 通过策略选择间接约束（nginx_conf/nginx_plain 输出）
#
# Fixture Conventions
# - 测试内 stub systemctl/pgrep，禁止访问真实 systemctl

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.reload.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "可从 master process 命令中提取 -c 配置路径" {
  run bash -c 'source "$1"; _extract_nginx_conf_from_master_cmd "123 nginx: master process /usr/sbin/nginx -c /etc/sing-box/nginx.conf"' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/sing-box/nginx.conf" ]
}

@test "reload 策略在无 systemctl 时优先使用 nginx -c" {
  run bash -c '
    source "$1"
    systemctl() { return 1; }
    pgrep() { printf "%s\n" "123 nginx: master process /usr/sbin/nginx -c /etc/sing-box/nginx.conf"; }
    _select_reload_strategy
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "nginx_conf:/etc/sing-box/nginx.conf" ]
}

@test "reload 策略在无 systemctl 且无 -c 时回退 nginx -s reload" {
  run bash -c '
    source "$1"
    systemctl() { return 1; }
    pgrep() { return 1; }
    _select_reload_strategy
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "nginx_plain" ]
}
