#!/usr/bin/env bats

@test "main menu item returning 10 exits script with code 10" {
  tmp_script=$(mktemp /tmp/install.menu.exit.exec.XXXXXX.sh)
  cat >"$tmp_script" <<"EOF"
REPO_ROOT="${1}"
SCRIPT_PATH="${REPO_ROOT}/install.sh"
LIB_PATH=$(mktemp /tmp/install.menu.exit.lib.XXXXXX.sh)
sed '$d' "${SCRIPT_PATH}" >"${LIB_PATH}"

config_path=$(mktemp /tmp/install.menu.exit.config.XXXXXX.json)
cat >"${config_path}" <<"JSON"
{
  "menus": {
    "MAIN_MENU": {
      "title": "MAIN",
      "items": [
        {"name": "nginx", "type": "item", "action": "nginx.sh"}
      ]
    }
  }
}
JSON

readlink() { printf "%s\\n" "/opt/vps_install_modules/install.sh"; }
source() {
  if [ "${1}" = "/opt/vps_install_modules/utils.sh" ]; then
    builtin source "/root/aa/vps-kit-mcp/utils.sh"
    return 0
  fi
  builtin source "${1}"
}
source "${LIB_PATH}"
CONFIG_PATH="${config_path}"
JB_ENABLE_AUTO_UPDATE="false"

jq() {
  local filter=""
  for arg in "${@}"; do
    if [[ "${arg}" == .* ]]; then
      filter="${arg}"
    fi
  done
  case "${filter}" in
  .menus*)
    printf "%s\\n" "{\\"title\\":\\"MAIN\\",\\"items\\":[{\\"name\\":\\"nginx\\",\\"type\\":\\"item\\",\\"action\\":\\"nginx.sh\\"}]}"
    ;;
  .title)
    printf "%s\\n" "MAIN"
    ;;
  .items*)
    if [[ "${filter}" == *"@tsv"* ]]; then
      printf "%b\\n" "NO_ICON\\tnginx\\titem\\tnginx.sh"
    else
      printf "%s\\n" "{\\"name\\":\\"nginx\\",\\"type\\":\\"item\\",\\"action\\":\\"nginx.sh\\"}"
    fi
    ;;
  .type)
    printf "%s\\n" "item"
    ;;
  .name)
    printf "%s\\n" "nginx"
    ;;
  .action)
    printf "%s\\n" "nginx.sh"
    ;;
  *)
    return 1
    ;;
  esac
}

refresh_auto_update_state() { :; }
handle_auto_update_core_restart() { :; }
should_clear_screen() { return 1; }
_render_menu() { :; }
_get_docker_status() { :; }
_get_nginx_status() { :; }
_get_watchtower_status() { :; }
_get_visual_width() { printf "%s\\n" "10"; }
_prompt_for_menu_choice() { printf "%s\\n" "1"; }
run_module() { return 10; }

CURRENT_MENU_NAME="MAIN_MENU"
display_and_process_menu
EOF
  run env -i PATH="/usr/local/bin:/usr/bin:/bin" /bin/bash "$tmp_script" /root/aa/vps-kit-mcp
  rm -f "$tmp_script"
  [ "$status" -eq 10 ]
}
