#!/usr/bin/env bats
# Coverage Matrix
# - _select_reload_strategy: cache hit
# - control_nginx: reload fallback chain + full failure
#
# Fixture Conventions
# - sed '$d' nginx.sh > temp lib, source in subshell
# - stub systemctl/pgrep/run_cmd/nginx; no real systemctl/nginx

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/nginx.sh"
  LIB_PATH="$(mktemp /tmp/nginx.reload.control.lib.XXXXXX.sh)"
  sed '$d' "$SCRIPT_PATH" >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "cache hit returns cached reload strategy" {
  run bash -c '
    source "$1"
    marker=$(mktemp /tmp/nginx.reload.cache.marker.XXXXXX)
    systemctl() { printf "%s\n" "systemctl-called" >>"$marker"; return 0; }
    date() { printf "%s\n" "100"; }
    NGINX_RELOAD_STRATEGY_CACHE="nginx_plain"
    NGINX_RELOAD_STRATEGY_CACHE_TS=100
    NGINX_RELOAD_STRATEGY_CACHE_TTL_SECS=30
    _select_reload_strategy
    if [ -s "$marker" ]; then
      printf "%s\n" "unexpected systemctl"
      exit 1
    fi
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  [ "$output" = "nginx_plain" ]
}

@test "cache expired reselects strategy and updates cache timestamp" {
  run bash -c '
    source "$1"
    marker=$(mktemp /tmp/nginx.reload.cache.expired.marker.XXXXXX)
    systemctl() { local IFS=" "; printf "%s\n" "systemctl:$*" >>"$marker"; return 0; }
    date() { printf "%s\n" "200"; }
    NGINX_RELOAD_STRATEGY_CACHE="nginx_plain"
    NGINX_RELOAD_STRATEGY_CACHE_TS=100
    NGINX_RELOAD_STRATEGY_CACHE_TTL_SECS=30
    _select_reload_strategy
    printf "%s\n" "cache:${NGINX_RELOAD_STRATEGY_CACHE}"
    printf "%s\n" "ts:${NGINX_RELOAD_STRATEGY_CACHE_TS}"
    cat "$marker"
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  lines=()
  while IFS= read -r line; do
    [ -n "$line" ] && lines+=("$line")
  done <<<"$output"
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "systemctl" ]
  [ "${lines[1]}" = "cache:systemctl" ]
  [ "${lines[2]}" = "ts:200" ]
  [ "${lines[3]}" = "systemctl:status nginx" ]
}

@test "fallback success path uses systemctl -> nginx -c -> nginx -s" {
  run bash -c '
    source "$1"
    marker=$(mktemp /tmp/nginx.reload.fallback.marker.XXXXXX)
    IFS=$'"'"' \t\n'"'"'
    set +e
    trap - ERR
    CONF_PATH_STUB="/tmp/nginx.fallback.conf"
    _nginx_test_cached() { return 0; }
    log_message() { return 0; }
    _select_reload_strategy() { printf "%s\n" "systemctl"; }
    _extract_nginx_conf_from_master_cmd() { printf "%s\n" "$CONF_PATH_STUB"; }
    systemctl() { local IFS=" "; printf "%s\n" "systemctl:$*" >>"$marker"; return 1; }
    pgrep() { printf "%s\n" "123 nginx: master process /usr/sbin/nginx -c ${CONF_PATH_STUB}"; }
    run_cmd() {
      shift
      local IFS=" "
      printf "%s\n" "run_cmd:$*" >>"$marker"
      if [ "$1" = "nginx" ]; then
        shift
        nginx "$@"
        return $?
      fi
      return 1
    }
    NGINX_C_RESULT=1
    NGINX_S_RESULT=0
    nginx() {
      if [ "$1" = "-c" ] && [ "$2" = "${CONF_PATH_STUB}" ] && [ "$3" = "-s" ] && [ "$4" = "reload" ]; then
        return "$NGINX_C_RESULT"
      fi
      if [ "$1" = "-s" ] && [ "$2" = "reload" ]; then
        return "$NGINX_S_RESULT"
      fi
      return 1
    }
    control_nginx reload
    rc=$?
    cat "$marker"
    exit $rc
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 0 ]
  lines=()
  while IFS= read -r line; do
    [ -n "$line" ] && lines+=("$line")
  done <<<"$output"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "systemctl:reload nginx" ]
  [ "${lines[1]}" = "run_cmd:nginx -c /tmp/nginx.fallback.conf -s reload" ]
  [ "${lines[2]}" = "run_cmd:nginx -s reload" ]
}

@test "full fallback failure returns non-zero" {
  run bash -c '
    source "$1"
    marker=$(mktemp /tmp/nginx.reload.failure.marker.XXXXXX)
    IFS=$'"'"' \t\n'"'"'
    set +e
    trap - ERR
    CONF_PATH_STUB="/tmp/nginx.failure.conf"
    _nginx_test_cached() { return 0; }
    log_message() { return 0; }
    _select_reload_strategy() { printf "%s\n" "systemctl"; }
    _extract_nginx_conf_from_master_cmd() { printf "%s\n" "$CONF_PATH_STUB"; }
    systemctl() { local IFS=" "; printf "%s\n" "systemctl:$*" >>"$marker"; return 1; }
    pgrep() { printf "%s\n" "123 nginx: master process /usr/sbin/nginx -c ${CONF_PATH_STUB}"; }
    run_cmd() {
      shift
      local IFS=" "
      printf "%s\n" "run_cmd:$*" >>"$marker"
      if [ "$1" = "nginx" ]; then
        shift
        nginx "$@"
        return $?
      fi
      return 1
    }
    NGINX_C_RESULT=1
    NGINX_S_RESULT=1
    nginx() {
      if [ "$1" = "-c" ] && [ "$2" = "${CONF_PATH_STUB}" ] && [ "$3" = "-s" ] && [ "$4" = "reload" ]; then
        return "$NGINX_C_RESULT"
      fi
      if [ "$1" = "-s" ] && [ "$2" = "reload" ]; then
        return "$NGINX_S_RESULT"
      fi
      return 1
    }
    control_nginx reload
    rc=$?
    cat "$marker"
    exit $rc
  ' "$SCRIPT_PATH" "$LIB_PATH"
  [ "$status" -eq 1 ]
  lines=()
  while IFS= read -r line; do
    [ -n "$line" ] && lines+=("$line")
  done <<<"$output"
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "systemctl:reload nginx" ]
  [ "${lines[1]}" = "run_cmd:nginx -c /tmp/nginx.failure.conf -s reload" ]
  [ "${lines[2]}" = "run_cmd:nginx -s reload" ]
}
