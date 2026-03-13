#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  DOCKER_SRC="${REPO_ROOT}/docker.sh"
  CERT_SRC="${REPO_ROOT}/cert.sh"
  WATCHTOWER_SRC="${REPO_ROOT}/tools/Watchtower.sh"
  DOCKER_LIB="$(mktemp /tmp/docker.fallback.XXXXXX.sh)"
  CERT_LIB="$(mktemp /tmp/cert.fallback.XXXXXX.sh)"
  WATCHTOWER_LIB="$(mktemp /tmp/watchtower.fallback.XXXXXX.sh)"
  awk '/^UTILS_PATH=/ {print "UTILS_PATH=\"/tmp/__missing_utils__\""; next} {print}' "$DOCKER_SRC" | sed '$d' >"$DOCKER_LIB"
  awk '/^UTILS_PATH=/ {print "UTILS_PATH=\"/tmp/__missing_utils__\""; next} {print}' "$CERT_SRC" | sed '$d' >"$CERT_LIB"
  awk '
    $0 == "if [[ \"${BASH_SOURCE[0]}\" == \"${0}\" ]]; then" {skip_main=1; next}
    skip_main && $0 == "fi" {skip_main=0; next}
    skip_main {next}
    $0 == "  source \"/opt/vps_install_modules/utils.sh\"" {print "  :"; next}
    $0 == "  source \"${SCRIPT_DIR}/../utils.sh\"" {print "  :"; next}
    {print}
  ' "$WATCHTOWER_SRC" >"$WATCHTOWER_LIB"
}

teardown() {
  rm -f "$DOCKER_LIB" "$CERT_LIB" "$WATCHTOWER_LIB"
}

@test "docker fallback: 非交互 confirm_action 返回失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="true"
    if confirm_action "test"; then
      exit 1
    fi
  ' _ "$DOCKER_LIB"
  [ "$status" -eq 0 ]
}

@test "cert fallback: 非交互 confirm_action 返回失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="true"
    if confirm_action "test"; then
      exit 1
    fi
  ' _ "$CERT_LIB"
  [ "$status" -eq 0 ]
}

@test "watchtower fallback: 非交互菜单返回失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    JB_NONINTERACTIVE="true"
    if _prompt_for_menu_choice "1-2"; then
      exit 1
    fi
  ' _ "$WATCHTOWER_LIB"
  [ "$status" -eq 0 ]
}
