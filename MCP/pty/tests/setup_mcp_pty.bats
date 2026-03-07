#!/usr/bin/env bats

setup() {
  export TARGET_SCRIPT="/root/jb/jaoeng/MCP/pty/setup_mcp_pty.sh"
}

@test "--help 可正常输出" {
  run bash "$TARGET_SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--with-opencode"* ]]
}

@test "未知参数返回 EX_USAGE(64)" {
  run bash "$TARGET_SCRIPT" --not-exists
  [ "$status" -eq 64 ]
  [[ "$output" == *"未知参数"* ]]
}

@test "参数解析支持可选模式与路径覆盖" {
  run bash <<'EOF'
source "/root/jb/jaoeng/MCP/pty/setup_mcp_pty.sh"
WITH_OPENCODE="false"
DRY_RUN="false"
REMOTE_RAW_BASE=""
LOCAL_BASE_DIR=""
OPENCODE_CONFIG_PATH=""
OPENCODE_INSTRUCTIONS_PATH=""
parse_args --with-opencode --dry-run --remote-raw-base "https://example.com/raw" --local-dir "/tmp/mcp-pty" --opencode-config "/tmp/opencode.json" --opencode-instruction-path "/tmp/pty.md"
[ "$WITH_OPENCODE" = "true" ]
[ "$DRY_RUN" = "true" ]
[ "$REMOTE_RAW_BASE" = "https://example.com/raw" ]
[ "$LOCAL_BASE_DIR" = "/tmp/mcp-pty" ]
[ "$OPENCODE_CONFIG_PATH" = "/tmp/opencode.json" ]
[ "$OPENCODE_INSTRUCTIONS_PATH" = "/tmp/pty.md" ]
EOF
  [ "$status" -eq 0 ]
}

@test "opencode 配置写入包含 pty-runner 与 instructions" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq 不存在，跳过此测试"
  fi

  run bash <<'EOF'
set -euo pipefail
source "/root/jb/jaoeng/MCP/pty/setup_mcp_pty.sh"
DRY_RUN="false"

tmp_home="$(mktemp -d)"
config_path="${tmp_home}/.config/opencode/opencode.json"
server_path="${tmp_home}/mcp/mcp-pty/server.py"
instruction_path="${tmp_home}/.config/opencode/instructions/pty.md"

mkdir -p "$(dirname "$config_path")" "$(dirname "$server_path")" "$(dirname "$instruction_path")"
printf "{}\n" >"$config_path"

update_opencode_config "$config_path" "$server_path" "$instruction_path"

jq -e --arg server "$server_path" --arg ins "$instruction_path" '
  .mcp["pty-runner"].command == ["uv", "run", "--script", $server]
  and .mcp["pty-runner"].environment.PATH == "{env:HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  and .mcp["pty-runner"].environment.LANG == "C.UTF-8"
  and .mcp["pty-runner"].environment.LC_ALL == "C.UTF-8"
  and (.instructions | index($ins) != null)
' "$config_path" >/dev/null
EOF
  [ "$status" -eq 0 ]
}

@test "HOME 路径会写入 {env:HOME} 模板" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq 不存在，跳过此测试"
  fi

  run bash <<'EOF'
set -euo pipefail
source "/root/jb/jaoeng/MCP/pty/setup_mcp_pty.sh"
DRY_RUN="false"

tmp_home="$(mktemp -d)"
config_path="${tmp_home}/.config/opencode/opencode.json"
server_path="${HOME}/mcp/mcp-pty/server.py"
instruction_path="${HOME}/.config/opencode/instructions/pty.md"

mkdir -p "$(dirname "$config_path")"
cat >"$config_path" <<'JSON'
{
  "instructions": [
    "${HOME}/.config/opencode/instructions/pty.md",
    "{env:HOME}/.config/opencode/instructions/pty.md"
  ]
}
JSON

update_opencode_config "$config_path" "$server_path" "$instruction_path"

jq -e '
  .mcp["pty-runner"].command == ["uv", "run", "--script", "{env:HOME}/mcp/mcp-pty/server.py"]
  and (.instructions | index("{env:HOME}/.config/opencode/instructions/pty.md") != null)
  and (.instructions | index("${HOME}/.config/opencode/instructions/pty.md") == null)
' "$config_path" >/dev/null
EOF
  [ "$status" -eq 0 ]
}
