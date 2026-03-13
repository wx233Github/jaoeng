#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME%/tests}"
  SCRIPT_PATH="${REPO_ROOT}/install.sh"
  LIB_PATH="$(mktemp /tmp/install.module.sync.XXXXXX.sh)"
  awk '
    /if \[ "\$REAL_SCRIPT_PATH" != "\$FINAL_SCRIPT_PATH" \]; then/ {skip=1; next}
    skip && /# --- 主程序依赖加载 ---/ {skip=0; print; next}
    !skip {print}
  ' "$SCRIPT_PATH" | sed '$d' >"$LIB_PATH"
}

teardown() {
  rm -f "$LIB_PATH"
}

@test "_sync_module_sidecars 会调用下载与依赖同步" {
  run bash -c '
    set -euo pipefail
    source "$1"
    download_called="no"
    sidecar_called="no"
    download_module_to_cache() { download_called="yes"; return 0; }
    ensure_module_sidecar_libs() { sidecar_called="yes"; return 0; }
    _sync_module_sidecars "nginx.sh"
    [ "$download_called" = "yes" ]
    [ "$sidecar_called" = "yes" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}
