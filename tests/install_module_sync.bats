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

@test "_sync_module_sidecars 会调用下载" {
  run bash -c '
    set -euo pipefail
    source "$1"
    tmp_bin=$(mktemp -d)
    printf "%s\n" "#!/usr/bin/env bash" "exit 0" >"$tmp_bin/jq"
    chmod +x "$tmp_bin/jq"
    PATH="$tmp_bin:$PATH"
    download_called="no"
    download_module_to_cache() { download_called="yes"; return 0; }
    _sync_module_sidecars "nginx.sh"
    [ "$download_called" = "yes" ]
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "_sync_module_sidecars 遇到无更新仍返回成功" {
  run bash -c '
    set -euo pipefail
    source "$1"
    tmp_bin=$(mktemp -d)
    printf "%s\n" "#!/usr/bin/env bash" "exit 0" >"$tmp_bin/jq"
    chmod +x "$tmp_bin/jq"
    PATH="$tmp_bin:$PATH"
    download_module_to_cache() { return 2; }
    _sync_module_sidecars "nginx.sh"
  ' _ "$LIB_PATH"
  [ "$status" -eq 0 ]
}

@test "_sync_module_sidecars 下载失败返回失败" {
  run bash -c '
    set -euo pipefail
    source "$1"
    tmp_bin=$(mktemp -d)
    printf "%s\n" "#!/usr/bin/env bash" "exit 0" >"$tmp_bin/jq"
    chmod +x "$tmp_bin/jq"
    PATH="$tmp_bin:$PATH"
    download_module_to_cache() { return 1; }
    _sync_module_sidecars "nginx.sh"
  ' _ "$LIB_PATH"
  [ "$status" -ne 0 ]
}
