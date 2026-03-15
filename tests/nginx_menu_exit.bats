#!/usr/bin/env bats

@test "nginx main menu exits with code 10 on empty input" {
  tmp_script=$(mktemp /tmp/nginx.menu.exit.exec.XXXXXX.sh)
  cat >"$tmp_script" <<"EOF"
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

source "/root/aa/vps-kit-mcp/lib/nginx_flow.sh"

PURPLE=""
BRIGHT_RED=""
BOLD=""
NC=""

_generate_op_id() { :; }
_ensure_menu_interactive() { return 0; }
_draw_dashboard() { :; }
prompt_menu_choice() { printf '%s\n' ""; return 0; }

main_menu
EOF
  run /bin/bash "$tmp_script"
  rm -f "$tmp_script"
  [ "$status" -eq 10 ]
}
