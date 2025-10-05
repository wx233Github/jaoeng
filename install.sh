#!/bin/bash
# =============================================================
# VPS Install Script (v74.16-Fix local error and header comments)
# =============================================================

# Script metadata
SCRIPT_VERSION="v74.16"

# Force use Bash
# Check if the current shell is bash, if not, try to re-execute with bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script requires Bash to run. Attempting to re-execute with Bash..." >&2
    exec /bin/bash "$0" "$@"
fi

# Strict mode and environment settings
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
if locale -a | grep -q "C.UTF-8"; then export LC_ALL=C.UTF-8; else export LC_ALL=C; fi

# Fallback UI rendering functions (These functions provide basic menu rendering capabilities
# in case utils.sh is not loaded or fails to load, preventing script crashes.
# If utils.sh loads successfully, its internal functions with the same names will override these fallback definitions.)
_get_visual_width() {
    local str="$1"
    # Remove ANSI color codes
    local clean_str=$(echo "$str" | sed 's/\x1b\[[0-9;]*m//g')
    # Use wc -m for character count, fallback to byte count if wc -m is unavailable
    if command -v wc &>/dev/null && wc --help 2>&1 | grep -q -- "-m"; then
        echo "$clean_str" | wc -m
    else
        echo "${#clean_str}" # Fallback to byte count if wc -m is not available
    fi
}

generate_line() {
    local length="$1"
    local char="${2:-─}"
    if [ "$length" -le 0 ]; then echo ""; return; fi
    printf "%${length}s" "" | sed "s/ /$char/g"
}

# Core Architecture: Smart Self-Bootstrapper
INSTALL_DIR="/opt/vps_install_modules"; FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"; CONFIG_PATH="${INSTALL_DIR}/config.json"; UTILS_PATH="${INSTALL_DIR}/utils.sh"
if [ "$0" != "$FINAL_SCRIPT_PATH" ]; then
    STARTER_BLUE='\033[0;34m'; STARTER_GREEN='\033[0;32m'; STARTER_RED='\033[0;31m'; STARTER_NC='\033[0m'
    echo_info() { echo -e "${STARTER_BLUE}[Bootstrapper]${STARTER_NC} $1"; }
    echo_success() { echo -e "${STARTER_GREEN}[Bootstrapper]${STARTER_NC} $1"; }
    echo_error() { echo -e "${STARTER_RED}[Bootstrapper Error]${STARTER_NC} $1" >&2; exit 1; }
    
    # Check curl dependency
    if ! command -v curl &> /dev/null; then echo_error "curl command not found, please install it first."; fi

    # Ensure install directory exists
    if [ ! -d "$INSTALL_DIR" ]; then
        echo_info "Install directory $INSTALL_DIR does not exist, attempting to create..."
        # Optimization: suppress mkdir's run_with_sudo logs
        if ! JB_SUDO_LOG_QUIET="true" sudo mkdir -p "$INSTALL_DIR"; then
            echo_error "Failed to create install directory $INSTALL_DIR. Check permissions or create manually."
        fi
    fi

    # Check if first installation or forced refresh is needed
    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH}" = "true" ]; then
        echo_info "Performing first installation or forced refresh of core components..."
        BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        declare -A core_files=( ["Main Program"]="install.sh" ["Configuration File"]="config.json" ["Utility Library"]="utils.sh" )
        for name in "${!core_files[@]}"; do
            file_path="${core_files[$name]}"
            echo_info "Downloading latest ${name} (${file_path})..."
            temp_file="/tmp/$(basename "${file_path}").$$"
            if ! curl -fsSL "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then
                echo_error "Failed to download ${name}."
            fi
            # Optimization: suppress mv's run_with_sudo logs
            if ! JB_SUDO_LOG_QUIET="true" sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"; then
                echo_error "Failed to move ${name} to ${INSTALL_DIR}."
            fi
        done
        
        echo_info "Setting core script execution permissions and adjusting directory ownership..."
        # Optimization: suppress chmod and chown's run_with_sudo logs
        if ! JB_SUDO_LOG_QUIET="true" sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH"; then
            echo_error "Failed to set core script execution permissions."
        fi
        # Core: assign ownership of install directory to current user for subsequent non-root operations
        if ! JB_SUDO_LOG_QUIET="true" sudo chown -R "$(whoami):$(whoami)" "$INSTALL_DIR"; then
            echo_warn "Failed to assign ownership of install directory $INSTALL_DIR to current user $(whoami). Subsequent operations may require manual sudo."
        else
            echo_success "Install directory $INSTALL_DIR ownership adjusted to current user."
        fi

        echo_info "Creating/updating shortcut command 'jb'..."
        BIN_DIR="/usr/local/bin"
        # Use sudo -E bash -c to execute ln command, ensuring correct environment variables and permissions
        # Optimization: suppress ln's run_with_sudo logs
        if ! JB_SUDO_LOG_QUIET="true" sudo -E bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"; then
            echo_warn "Failed to create shortcut command 'jb'. Check permissions or create link manually."
        fi
        echo_success "Installation/update complete!"
    fi
    echo -e "${STARTER_BLUE}────────────────────────────────────────────────────────────${STARTER_NC}"
    echo ""
    # Core: main program executes as current user
    # Note: run_with_sudo is not attempted to be exported here, as the function is not yet defined.
    # run_with_sudo will be defined and exported in the main program logic.
    exec bash "$FINAL_SCRIPT_PATH" "$@"
fi

# Main program logic

# Include utils
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    # If utils.sh cannot be loaded, provide a fallback log_err function to prevent script from crashing immediately
    log_err() { echo -e "${RED}[Error] $*${NC}" >&2; }
    log_warn() { echo -e "${YELLOW}[Warning] $*${NC}" >&2; }
    log_info() { echo -e "${CYAN}[Info] $*${NC}"; }
    log_success() { echo -e "${GREEN}[Success] $*${NC}"; }
    log_err "Fatal Error: Common utility library $UTILS_PATH not found or failed to load! Script functionality may be limited or unstable."
fi

# Helper function to run commands with sudo
# If the function is not exported, redefine it here to ensure availability
if ! declare -f run_with_sudo &>/dev/null; then
  run_with_sudo() {
      # Optimization: decide whether to output logs based on JB_SUDO_LOG_QUIET environment variable
      if [ "${JB_SUDO_LOG_QUIET:-}" != "true" ]; then
          log_info "Attempting to execute with root privileges: $*"
      fi
      sudo -E "$@" < /dev/tty
  }
  export -f run_with_sudo # Ensure that after utils.sh is loaded, if utils.sh does not define it, it can be exported here
fi


declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]="/tmp/vps_install_modules.lock"
CONFIG[enable_auto_clear]="false"
CONFIG[timezone]="Asia/Shanghai"
CONFIG[default_interval]="" # Initialize to store default_interval from config.json root
CONFIG[default_cron_hour]="" # Initialize to store default_cron_hour from config.json root

AUTO_YES="false"
if [ "${NON_INTERACTIVE:-}" = "true" ] || [ "${YES_TO_ALL:-}" = "true" ]; then
    AUTO_YES="true"
fi

load_config() {
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"
    if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
        while IFS='=' read -r key value; do
            value=$(printf '%s' "$value" | sed 's/^"\(.*\)"$/\1/')
            CONFIG[$key]="$value"
        done < <(jq -r 'to_entries
            | map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not)))
            | map("\(.key)=\(.value)")
            | .[]' "$CONFIG_FILE" 2>/dev/null || true)
        CONFIG[dependencies]="$(jq -r '.dependencies.common // "curl cmp ln dirname flock jq"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[dependencies]}")"
        CONFIG[lock_file]="$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[lock_file]}")"
        CONFIG[enable_auto_clear]="$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[enable_auto_clear]}")"
        CONFIG[timezone]="$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[timezone]}")"
        
        # Core: read default_interval and default_cron_hour from root directory
        local root_default_interval; root_default_interval=$(jq -r '.default_interval // ""' "$CONFIG_FILE" 2>/dev/null || true)
        if echo "$root_default_interval" | grep -qE '^[0-9]+$'; then
            CONFIG[default_interval]="$root_default_interval"
        fi
        local root_default_cron_hour; root_default_cron_hour=$(jq -r '.default_cron_hour // ""' "$CONFIG_FILE" 2>/dev/null || true)
        if echo "$root_default_cron_hour" | grep -qE '^[0-9]+$'; then
            CONFIG[default_cron_hour]="$root_default_cron_hour"
        fi

    fi
}

check_and_install_dependencies() {
    local missing_deps=()
    local deps=(${CONFIG[dependencies]})
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_warn "Missing core dependencies: ${missing_deps[*]}"
        local pm
        if command -v apt-get &>/dev/null; then pm="apt"; elif command -v dnf &>/dev/null; then pm="dnf"; elif command -v yum &>/dev/null; then pm="yum"; else pm="unknown"; fi
        if [ "$pm" = "unknown" ]; then
            log_err "Cannot detect package manager, please install manually: ${missing_deps[*]}"
            exit 1
        fi
        if [ "$AUTO_YES" = "true" ]; then
            choice="y"
        else
            read -p "$(echo -e "${YELLOW}Attempt to install automatically? (y/N): ${NC}")" choice < /dev/tty
        fi
        if echo "$choice" | grep -qE '^[Yy]$'; then
            log_info "Installing using $pm..."
            local update_cmd=""
            if [ "$pm" = "apt" ]; then update_cmd="JB_SUDO_LOG_QUIET='true' run_with_sudo apt-get update"; fi # Optimization: suppress apt-get update logs
            # Optimization: suppress package installation run_with_sudo logs
            if ! ($update_cmd && JB_SUDO_LOG_QUIET='true' run_with_sudo "$pm" install -y "${missing_deps[@]}"); then
                log_err "Dependency installation failed."
                exit 1
            fi
            log_success "Dependency installation complete!"
        else
            log_err "User cancelled installation."
            exit 1
        fi
    fi
}

_download_file() {
    local relpath="$1"
    local dest="$2"
    local url="${CONFIG[base_url]}/${relpath}?_=$(date +%s)"
    if ! curl -fsSL --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 2 "$url" -o "$dest"; then
        return 1
    fi
    return 0
}

self_update() {
    local SCRIPT_PATH="${CONFIG[install_dir]}/install.sh"
    # If the currently executing script is not the final installed script, do not perform self-update (handled by bootstrapper)
    if [ "$0" != "$SCRIPT_PATH" ]; then
        return
    fi
    local temp_script="/tmp/install.sh.tmp.$$"
    if ! _download_file "install.sh" "$temp_script"; then
        log_warn "Main program (install.sh) update check failed (cannot connect)."
        rm -f "$temp_script" 2>/dev/null || true
        return
    fi
    if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then
        log_success "Main program (install.sh) updated. Seamlessly restarting..."
        # Optimization: suppress mv and chmod's run_with_sudo logs
        JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_script" "$SCRIPT_PATH"
        JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "$SCRIPT_PATH"
        flock -u 200 || true
        rm -f "${CONFIG[lock_file]}" 2>/dev/null || true # Lock file is in /tmp, user can delete
        trap - EXIT # Cancel exit trap to prevent re-execution after exec
        # Core: restart itself, still executing as current user
        export -f run_with_sudo # Export again to ensure the newly executed script can also recognize it
        exec bash "$SCRIPT_PATH" "$@"
    fi
    rm -f "$temp_script" 2>/dev/null || true
}

download_module_to_cache() {
    local script_name="$1"
    local local_file="${CONFIG[install_dir]}/$script_name"
    local tmp_file="/tmp/$(basename "$script_name").$$"
    local url="${CONFIG[base_url]}/${script_name}?_=$(date +%s)"
    local http_code
    http_code=$(curl -sS --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 2 -w "%{http_code}" -o "$tmp_file" "$url" 2>/dev/null) || true
    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ] || [ "$http_code" != "200" ] || [ ! -s "$tmp_file" ]; then
        log_err "Module (${script_name}) download failed (HTTP: $http_code, Curl: $curl_exit_code)"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    if [ -f "$local_file" ] && cmp -s "$local_file" "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    else
        log_success "Module (${script_name}) updated."
        # Optimization: suppress mkdir, mv, chmod's run_with_sudo logs
        JB_SUDO_LOG_QUIET="true" run_with_sudo mkdir -p "$(dirname "$local_file")"
        JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$tmp_file" "$local_file"
        JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "$local_file" || true
    fi
}

_update_core_files() {
    local temp_utils="/tmp/utils.sh.tmp.$$"
    if _download_file "utils.sh" "$temp_utils"; then
        if [ ! -f "$UTILS_PATH" ] || ! cmp -s "$UTILS_PATH" "$temp_utils"; then
            log_success "Core utility library (utils.sh) updated."
            JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_utils" "$UTILS_PATH"
            JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "$UTILS_PATH"
        else
            rm -f "$temp_utils" 2>/dev/null || true
        fi
    else
        log_warn "Core utility library (utils.sh) update check failed."
    fi

    # Explicitly update config.json here
    local temp_config="/tmp/config.json.tmp.$$"
    if _download_file "config.json" "$temp_config"; then
        if [ ! -f "$CONFIG_PATH" ] || ! cmp -s "$CONFIG_PATH" "$temp_config"; then
            log_success "Core configuration file (config.json) updated."
            JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_config" "$CONFIG_PATH"
        else
            rm -f "$temp_config" 2>/dev/null || true
        fi
    else
        log_warn "Core configuration file (config.json) update check failed."
    fi
}

_update_all_modules() {
    local cfg="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$cfg" ]; then
        log_warn "Configuration file ${cfg} does not exist, skipping module update."
        return
    fi
    local scripts_to_update
    scripts_to_update=$(jq -r '
        .menus // {} |
        to_entries[]? |
        .value.items?[]? |
        select(.type == "item") |
        .action
    ' "$cfg" 2>/dev/null || true)
    if [ -z "$scripts_to_update" ]; then
        log_info "No updatable modules detected."
        return
    fi
    local pids=()
    for script_name in $scripts_to_update; do
        download_module_to_cache "$script_name" & pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
}

force_update_all() {
    self_update
    _update_core_files # Now includes config.json
    _update_all_modules
    log_success "All components update check complete!"
}

confirm_and_force_update() {
    log_warn "Warning: This will force pull all latest scripts and the [main configuration file config.json] from GitHub."
    log_warn "All your local modifications to config.json will be lost! This is a factory reset operation."
    read -p "$(echo -e "${RED}This operation is irreversible, please type 'yes' to confirm: ${NC}")" choice < /dev/tty
    if [ "$choice" = "yes" ]; then
        log_info "Starting forced full reset..."
        declare -A core_files_to_reset=( ["Main Program"]="install.sh" ["Utility Library"]="utils.sh" ["Configuration File"]="config.json" )
        for name in "${!core_files_to_reset[@]}"; do
            local file_path="${core_files_to_reset[$name]}"
            log_info "Forcing update of ${name}..."
            local temp_file="/tmp/$(basename "$file_path").tmp.$$"
            if ! _download_file "$file_path" "$temp_file"; then
                log_err "Failed to download latest ${name}."
                continue
            fi
            # Optimization: suppress mv's run_with_sudo logs
            JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_file" "${CONFIG[install_dir]}/${file_path}"
            log_success "${name} reset to latest version."
        done
        log_info "Restoring core script execution permissions..."
        # Optimization: suppress chmod's run_with_sudo logs
        JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "${CONFIG[install_dir]}/install.sh" "${CONFIG[install_dir]}/utils.sh" || true
        log_success "Permissions restored."
        _update_all_modules
        log_success "Forced reset complete!"
        log_info "Script will automatically restart in 2 seconds to apply all updates..."
        sleep 2
        flock -u 200 || true
        rm -f "${CONFIG[lock_file]}" 2>/dev/null || true # Lock file is in /tmp, user can delete
        trap - EXIT
        # Core: restart itself, still executing as current user
        export -f run_with_sudo # Export again to ensure the newly executed script can also recognize it
        exec bash "$FINAL_SCRIPT_PATH" "$@"
    else
        log_info "Operation cancelled."
    fi
    return 10
}

uninstall_script() {
    log_warn "Warning: This will completely remove this script and all its components from your system!"
    log_warn "  - Install directory: ${CONFIG[install_dir]}"
    log_warn "  - Shortcut: ${CONFIG[bin_dir]}/jb"
    read -p "$(echo -e "${RED}This is an irreversible operation, are you sure you want to continue? (Please type 'yes' to confirm): ${NC}")" choice < /dev/tty
    if [ "$choice" = "yes" ]; then
        log_info "Starting uninstallation..."
        # Optimization: suppress rm's run_with_sudo logs
        JB_SUDO_LOG_QUIET="true" run_with_sudo rm -rf "${CONFIG[install_dir]}"
        log_success "Install directory removed."
        JB_SUDO_LOG_QUIET="true" run_with_sudo rm -f "${CONFIG[bin_dir]}/jb"
        log_success "Shortcut removed."
        log_success "Script successfully uninstalled."
        log_info "Goodbye!"
        exit 0
    else
        log_info "Uninstallation cancelled."
        return 10
    fi
}

_quote_args() {
    for arg in "$@"; do printf "%q " "$arg"; done
}

execute_module() {
    local script_name="$1"
    local display_name="$2"
    shift 2
    local local_path="${CONFIG[install_dir]}/$script_name"
    log_info "You selected [$display_name]"

    if [ ! -f "$local_path" ]; then
        log_info "Downloading module..."
        if ! download_module_to_cache "$script_name"; then
            log_err "Download failed."
            return 1
        fi
    fi

    local env_exports="export IS_NESTED_CALL=true
export FORCE_COLOR=true
export JB_ENABLE_AUTO_CLEAR='${CONFIG[enable_auto_clear]}'
export JB_TIMEZONE='${CONFIG[timezone]}'
export LC_ALL=${LC_ALL}
"
    # Core: If default_interval or default_cron_hour exist in the root, export them
    if [ -n "${CONFIG[default_interval]}" ]; then
        env_exports+="export JB_DEFAULT_INTERVAL='${CONFIG[default_interval]}'\n"
        log_debug "DEBUG: Exporting global default_interval: ${CONFIG[default_interval]}"
    fi
    if [ -n "${CONFIG[default_cron_hour]}" ]; then
        env_exports+="export JB_DEFAULT_CRON_HOUR='${CONFIG[default_cron_hour]}'\n"
        log_debug "DEBUG: Exporting global default_cron_hour: ${CONFIG[default_cron_hour]}"
    fi

    local module_key
    module_key=$(basename "$script_name" .sh | tr '[:upper:]' '[:lower:]')
    local config_path="${CONFIG[install_dir]}/config.json"
    local module_config_json="null"
    if [ -f "$config_path" ] && command -v jq &>/dev/null; then
        module_config_json=$(jq -r --arg key "$module_key" '.module_configs[$key] // "null"' "$config_path" 2>/dev/null || echo "null")
    fi
    
    log_debug "DEBUG: Processing module_config_json for '$module_key': '$module_config_json'"

    # Improved jq_script, converting null values to ""
    local jq_script='to_entries | .[] | select((.key | startswith("comment") | not)) | .key as $k | .value as $v | 
        if ($v|type) == "array" then [$k, ($v|join(","))] 
        elif ($v|type) | IN("string", "number", "boolean") then [$k, $v] 
        elif ($v|type) == "null" then [$k, ""] # Treat null as empty string
        else empty end | @tsv'

    while IFS=$'\t' read -r key value; do
        if [ -n "$key" ]; then
            local key_upper
            key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
            
            # Pre-validate numeric configurations
            if [[ "$key" == *"interval"* ]] || [[ "$key" == *"hour"* ]]; then
                if ! echo "$value" | grep -qE '^[0-9]+$'; then
                    log_warn "Value '${value}' for '${module_key}.${key}' in config.json is not a valid number, ignoring this configuration."
                    continue # Ignore invalid numeric configurations
                fi
            fi
            value=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
            env_exports+=$(printf "export %s_CONF_%s='%s'\n" "$(echo "$module_key" | tr '[:lower:]' '[:upper:]')" "$key_upper" "$value")
            log_debug "DEBUG: Exporting: ${module_key^^}_CONF_${key_upper}='${value}'"
        fi
    done < <(echo "$module_config_json" | jq -r "$jq_script" 2>/dev/null || true)
    
    log_debug "DEBUG: Final env_exports for '$module_key':\n$env_exports"

    local extra_args_str
    extra_args_str=$(_quote_args "$@")
    local tmp_runner="/tmp/jb_runner.$$"
    cat > "$tmp_runner" <<EOF
#!/bin/bash
set -e
# Core: inject run_with_sudo function definition into sub-script
if declare -f run_with_sudo &>/dev/null; then
  export -f run_with_sudo
else
  # Fallback definition if for some reason it's not inherited
  run_with_sudo() {
      echo -e "${CYAN}[Sub-script - Info]${NC} Attempting to execute with root privileges: \$*" >&2
      sudo -E "\$@" < /dev/tty
  }
  export -f run_with_sudo
fi
$env_exports
# Core: module script executes as current user, if root privileges are needed, module should call run_with_sudo internally
exec bash '$local_path' $extra_args_str
EOF
    # Core: execute runner script, no sudo
    bash "$tmp_runner" < /dev/tty || local exit_code=$?
    rm -f "$tmp_runner" 2>/dev/null || true

    if [ "${exit_code:-0}" = "0" ]; then
        log_success "Module [$display_name] executed successfully."
    elif [ "${exit_code:-0}" = "10" ]; then
        log_info "Returned from [$display_name]."
    else
        log_warn "Module [$display_name] execution failed (Code: ${exit_code:-1})."
    fi

    return ${exit_code:-0}
}

_render_menu() {
    local title="$1"; shift
    local -a lines=("$@")

    local max_content_width=0 # Only calculate content width, excluding internal spaces and borders
    
    local title_content_width=$(_get_visual_width "$title")
    if (( title_content_width > max_content_width )); then max_content_width=$title_content_width; fi

    for line in "${lines[@]}"; do
        local line_content_width=$(_get_visual_width "$line")
        if (( line_content_width > max_content_width )); then max_content_width=$line_content_width; fi
    done
    
    local inner_padding_chars=2 # One space on each side, for spacing between content and border
    local box_inner_width=$((max_content_width + inner_padding_chars))
    if [ "$box_inner_width" -lt 38 ]; then box_inner_width=38; fi # Minimum content area width (38 + 2 borders = 40 total width)

    log_debug "DEBUG: _render_menu - title_content_width: $title_content_width, max_content_width: $max_content_width, box_inner_width: $box_inner_width"

    # Top
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    
    # Title
    if [ -n "$title" ]; then
        local current_title_line_width=$((title_content_width + inner_padding_chars)) # Title content width + 1 space on each side
        local padding_total=$((box_inner_width - current_title_line_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        
        local left_padding_str; left_padding_str=$(printf '%*s' "$padding_left")
        local right_padding_str; right_padding_str=$(printf '%*s' "$padding_right")

        log_debug "DEBUG: Title: '$title', padding_left: $padding_left, padding_right: $padding_right"
        echo -e "${GREEN}│${left_padding_str} ${title} ${right_padding_str}│${NC}"
    fi
    
    # Options
    for line in "${lines[@]}"; do
        local line_content_width=$(_get_visual_width "$line")
        # Calculate right padding: total content area width - current line content width - one left space
        local padding_right_for_line=$((box_inner_width - line_content_width - 1)) 
        if [ "$padding_right_for_line" -lt 0 ]; then padding_right_for_line=0; fi
        log_debug "DEBUG: Line: '$line', line_content_width: $line_content_width, padding_right_for_line: $padding_right_for_line"
        echo -e "${GREEN}│ ${line} $(printf '%*s' "$padding_right_for_line")${GREEN}│${NC}" # Fixed one space on the left
    done

    # Bottom
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
}

_print_header() { _render_menu "$1" ""; }

display_menu() {
    if [ "${CONFIG[enable_auto_clear]}" = "true" ]; then clear 2>/dev/null || true; fi
    local config_path="${CONFIG[install_dir]}/config.json"
    log_debug "DEBUG: display_menu called. config_path: $config_path"

    if [ ! -f "$config_path" ]; then
        log_err "Configuration file ${config_path} not found, please ensure core files are installed."
        exit 1 # Exit Code 100 for config file missing
    fi
    log_debug "DEBUG: config.json exists. Content (first 100 chars): $(head -c 100 "$config_path" 2>/dev/null || echo "Error reading file")"

    local menu_json
    menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path" 2>/dev/null || echo "")
    if [ -z "$menu_json" ] || [ "$menu_json" = "null" ]; then
        log_err "Menu ${CURRENT_MENU_NAME} configuration is invalid or cannot be parsed!"
        log_debug "DEBUG: Failed to parse menu_json for $CURRENT_MENU_NAME. menu_json was: '$menu_json'"
        exit 1 # Exit Code 101 for menu parsing failure
    fi
    log_debug "DEBUG: menu_json for $CURRENT_MENU_NAME successfully parsed."

    local main_title_text
    main_title_text=$(jq -r '.title // "VPS Install Script"' <<< "$menu_json" 2>/dev/null || echo "Could not get title")
    log_debug "DEBUG: main_title_text: '$main_title_text'"

    local -a menu_items_array=()
    local i=1
    while IFS=$'\t' read -r icon name; do
        menu_items_array+=("$(printf "  ${YELLOW}%2d.${NC} %s %s" "$i" "$icon" "$name")")
        i=$((i + 1))
    done < <(jq -r '.items[]? | ((.icon // "›") + "\t" + .name)' <<< "$menu_json" 2>/dev/null || true)
    log_debug "DEBUG: menu_items_array count: ${#menu_items_array[@]}"

    _render_menu "$main_title_text" "${menu_items_array[@]}"

    local menu_len
    menu_len=$(jq -r '.items | length' <<< "$menu_json" 2>/dev/null || echo "0")
    log_debug "DEBUG: menu_len: $menu_len"
    local exit_hint="Exit"
    if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then exit_hint="Return"; fi
    local prompt_text=" └──> Please select [1-${menu_len}], or [Enter] ${exit_hint}: "

    if [ "$AUTO_YES" = "true" ]; then
        choice=""
        echo -e "${BLUE}${prompt_text}${NC} [Non-interactive mode]"
    else
        read -p "$(echo -e "${BLUE}${prompt_text}${NC}")" choice < /dev/tty
    fi
}

process_menu_selection() {
    local config_path="${CONFIG[install_dir]}/config.json"
    local menu_json
    menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path" 2>/dev/null || echo "")
    local menu_len
    menu_len=$(jq -r '.items | length' <<< "$menu_json" 2>/dev/null || echo "0")

    if [ -z "$choice" ]; then
        if [ "$CURRENT_MENU_NAME" = "MAIN_MENU" ]; then
            exit 0 # Exit Code 0 for graceful exit from main menu
        else
            CURRENT_MENU_NAME="MAIN_MENU"
            return 10
        fi
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$menu_len" ]; then
        log_warn "Invalid option."
        return 10
    fi

    local item_json
    item_json=$(echo "$menu_json" | jq -r --argjson idx "$(expr $choice - 1)" '.items[$idx]' 2>/dev/null || echo "")
    if [ -z "$item_json" ] || [ "$item_json" = "null" ]; then
        log_warn "Menu item configuration is invalid or incomplete."
        return 10
    fi

    local type
    type=$(echo "$item_json" | jq -r ".type" 2>/dev/null || echo "")
    local name
    name=$(echo "$item_json" | jq -r ".name" 2>/dev/null || echo "")
    local action
    action=$(echo "$item_json" | jq -r ".action" 2>/dev/null || echo "")

    case "$type" in
        item)
            execute_module "$action" "$name"
            return $?
            ;;
        submenu)
            CURRENT_MENU_NAME=$action
            return 10
            ;;
        func)
            "$action"
            return $?
            ;;
        *)
            log_warn "Unknown menu type: $type"
            return 10
            ;;
    esac
}

main() {
    exec 200>"${CONFIG[lock_file]}"
    if ! flock -n 200; then
        echo -e "\033[0;33m[Warning] Another instance detected running."
        exit 1
    fi
    # Exit trap, ensure file lock is released when script exits
    trap 'local trap_exit_code=$?; flock -u 200; rm -f "${CONFIG[lock_file]}" 2>/dev/null || true; log_info "Script exited (Exit Code: ${trap_exit_code})."' EXIT # Added exit code

    # Check core dependencies, install if missing
    if ! command -v flock >/dev/null || ! command -v jq >/dev/null; then
        check_and_install_dependencies
    fi

    load_config # First load config

    if [ $# -gt 0 ]; then
        # This block is skipped if user runs `jb` without args.
        local command="$1"; shift
        case "$command" in
            update)
                log_info "Safely updating all scripts in Headless mode..."
                force_update_all
                exit 0
                ;;
            uninstall)
                log_info "Performing uninstallation in Headless mode..."
                uninstall_script
                exit 0
                ;;
            *)
                local item_json
                item_json=$(jq -r --arg cmd "$command" '.menus[] | .items[]? | select(.type != "submenu") | select(.action == $cmd or (.name | ascii_downcase | startswith($cmd)))' "${CONFIG[install_dir]}/config.json" 2>/dev/null | head -n 1)
                if [ -n "$item_json" ]; then
                    local action_to_run
                    action_to_run=$(echo "$item_json" | jq -r '.action' 2>/dev/null || echo "")
                    local display_name
                    display_name=$(echo "$item_json" | jq -r '.name' 2>/dev/null || echo "")
                    local type
                    type=$(echo "$item_json" | jq -r '.type' 2>/dev/null || echo "")
                    log_info "Executing: ${display_name} in Headless mode"
                    if [ "$type" = "func" ]; then
                        "$action_to_run" "$@"
                    else
                        execute_module "$action_to_run" "$display_name" "$@"
                    fi
                    exit $?
                else
                    log_err "Unknown command: $command"
                    exit 1
                fi
        esac
    fi

    log_info "Script started (v${SCRIPT_VERSION})"
    echo -ne "$(log_timestamp) ${BLUE}[Info]${NC} Intelligently updating 🕛"
    sleep 0.5
    echo -ne "\r$(log_timestamp) ${BLUE}[Info]${NC} Intelligently updating 🔄\n"
    force_update_all # Perform all updates
    
    load_config # Core fix: reload config after update to ensure latest config is used

    log_debug "DEBUG: force_update_all completed and config reloaded. Attempting to display menu." # NEW DEBUG LINE

    CURRENT_MENU_NAME="MAIN_MENU"
    while true; do
        display_menu
        local exit_code=0
        process_menu_selection || exit_code=$?
        if [ "$exit_code" -ne 10 ]; then
            while read -r -t 0; do :; done
            press_enter_to_continue < /dev/tty
        fi
    done
}

main "$@"
