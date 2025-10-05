#!/bin/bash
# =============================================================
# 🚀 VPS 一键安装入口脚本 (v74.17-修复sed解析错误)
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v74.17"

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
if locale -a | grep -q "C.UTF-8"; then export LC_ALL=C.UTF-8; else export LC_ALL=C; fi

# --- 备用 UI 渲染函数 (Fallback UI rendering functions) ---
# 这些函数在 utils.sh 未加载或加载失败时提供基本的菜单渲染能力，防止脚本崩溃。
# 如果 utils.sh 成功加载，其内部的同名函数将覆盖这些备用定义。
_get_visual_width() {
    local str="$1"
    # 移除ANSI颜色码
    local clean_str=$(echo "$str" | sed 's/\x1b\[[0-9;]*m//g')
    # 使用 wc -m 计算字符数，fallback 到字节数如果 wc -m 不可用
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

# --- [核心架构]: 智能自引导启动器 ---
INSTALL_DIR="/opt/vps_install_modules"; FINAL_SCRIPT_PATH="${INSTALL_DIR}/install.sh"; CONFIG_PATH="${INSTALL_DIR}/config.json"; UTILS_PATH="${INSTALL_DIR}/utils.sh"
if [ "$0" != "$FINAL_SCRIPT_PATH" ]; then
    STARTER_BLUE='\033[0;34m'; STARTER_GREEN='\033[0;32m'; STARTER_RED='\033[0;31m'; STARTER_NC='\033[0m'
    echo_info() { echo -e "${STARTER_BLUE}[启动器]${STARTER_NC} $1"; }
    echo_success() { echo -e "${STARTER_GREEN}[启动器]${STARTER_NC} $1"; }
    echo_error() { echo -e "${STARTER_RED}[启动器错误]${STARTER_NC} $1" >&2; exit 1; }
    
    # 检查 curl 依赖
    if ! command -v curl &> /dev/null; then echo_error "curl 命令未找到, 请先安装."; fi

    # 确保安装目录存在
    if [ ! -d "$INSTALL_DIR" ]; then
        echo_info "安装目录 $INSTALL_DIR 不存在，正在尝试创建..."
        # 优化：抑制 mkdir 的 run_with_sudo 日志
        if ! JB_SUDO_LOG_QUIET="true" sudo mkdir -p "$INSTALL_DIR"; then
            echo_error "无法创建安装目录 $INSTALL_DIR。请检查权限或手动创建。"
        fi
    fi

    # 检查是否需要首次安装或强制刷新
    if [ ! -f "$FINAL_SCRIPT_PATH" ] || [ ! -f "$CONFIG_PATH" ] || [ ! -f "$UTILS_PATH" ] || [ "${FORCE_REFRESH}" = "true" ]; then
        echo_info "正在执行首次安装或强制刷新核心组件..."
        BASE_URL="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
        declare -A core_files=( ["主程序"]="install.sh" ["配置文件"]="config.json" ["工具库"]="utils.sh" )
        for name in "${!core_files[@]}"; do
            file_path="${core_files[$name]}"
            echo_info "正在下载最新的 ${name} (${file_path})..."
            temp_file="/tmp/$(basename "${file_path}").$$"
            if ! curl -fsSL "${BASE_URL}/${file_path}?_=$(date +%s)" -o "$temp_file"; then
                echo_error "下载 ${name} 失败。"
            fi
            # 优化：抑制 mv 的 run_with_sudo 日志
            if ! JB_SUDO_LOG_QUIET="true" sudo mv "$temp_file" "${INSTALL_DIR}/${file_path}"; then
                echo_error "移动 ${name} 到 ${INSTALL_DIR} 失败。"
            fi
        done
        
        echo_info "正在设置核心脚本执行权限并调整目录所有权..."
        # 优化：抑制 chmod 和 chown 的 run_with_sudo 日志
        if ! JB_SUDO_LOG_QUIET="true" sudo chmod +x "$FINAL_SCRIPT_PATH" "$UTILS_PATH"; then
            echo_error "设置核心脚本执行权限失败。"
        fi
        # 核心：将安装目录所有权赋给当前用户，以便后续非root操作
        if ! JB_SUDO_LOG_QUIET="true" sudo chown -R "$(whoami):$(whoami)" "$INSTALL_DIR"; then
            echo_warn "无法将安装目录 $INSTALL_DIR 的所有权赋给当前用户 $(whoami)。后续操作可能需要手动sudo。"
        else
            echo_success "安装目录 $INSTALL_DIR 所有权已调整为当前用户。"
        fi

        echo_info "正在创建/更新快捷指令 'jb'..."
        BIN_DIR="/usr/local/bin"
        # 使用 sudo -E bash -c 来执行 ln 命令，确保环境变量和权限正确
        # 优化：抑制 ln 的 run_with_sudo 日志
        if ! JB_SUDO_LOG_QUIET="true" sudo -E bash -c "ln -sf '$FINAL_SCRIPT_PATH' '$BIN_DIR/jb'"; then
            echo_warn "无法创建快捷指令 'jb'。请检查权限或手动创建链接。"
        fi
        echo_success "安装/更新完成！"
    fi
    echo -e "${STARTER_BLUE}────────────────────────────────────────────────────────────${STARTER_NC}"
    echo ""
    # 核心：主程序以当前用户身份执行
    # 注意：这里不再尝试 export -f run_with_sudo，因为函数尚未定义。
    # run_with_sudo 将在主程序逻辑中定义并导出。
    exec bash "$FINAL_SCRIPT_PATH" "$@"
fi

# --- 主程序逻辑 ---

# 引入 utils
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    # 如果 utils.sh 无法加载，使用备用日志函数
    log_err() { echo -e "${RED}[错误] $*${NC}" >&2; }
    log_warn() { echo -e "${YELLOW}[警告] $*${NC}" >&2; }
    log_info() { echo -e "${CYAN}[信息] $*${NC}"; }
    log_success() { echo -e "${GREEN}[成功] $*${NC}"; }
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到或无法加载！脚本功能可能受限或不稳定。"
fi

# --- Helper function to run commands with sudo ---
# 如果函数未被导出，这里重新定义以确保可用性
if ! declare -f run_with_sudo &>/dev/null; then
  run_with_sudo() {
      # 优化：根据 JB_SUDO_LOG_QUIET 环境变量决定是否输出日志
      if [ "${JB_SUDO_LOG_QUIET:-}" != "true" ]; then
          log_info "正在尝试以 root 权限执行: $*"
      fi
      sudo -E "$@" < /dev/tty
  }
  export -f run_with_sudo # 确保在加载 utils.sh 后，如果 utils.sh 没有定义，这里也能导出
fi


declare -A CONFIG
CONFIG[base_url]="https://raw.githubusercontent.com/wx233Github/jaoeng/main"
CONFIG[install_dir]="/opt/vps_install_modules"
CONFIG[bin_dir]="/usr/local/bin"
CONFIG[dependencies]='curl cmp ln dirname flock jq'
CONFIG[lock_file]="/tmp/vps_install_modules.lock"
CONFIG[enable_auto_clear]="false"
CONFIG[timezone]="Asia/Shanghai"
CONFIG[default_interval]="" # 初始化，用于存储 config.json 根目录的 default_interval
CONFIG[default_cron_hour]="" # 初始化，用于存储 config.json 根目录的 default_cron_hour

AUTO_YES="false"
if [ "${NON_INTERACTIVE:-}" = "true" ] || [ "${YES_TO_ALL:-}" = "true" ]; then
    AUTO_YES="true"
fi

load_config() {
    CONFIG_FILE="${CONFIG[install_dir]}/config.json"
    if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
        # 修复：使用更安全的 Bash 参数扩展代替有问题的 sed 命令
        while IFS='=' read -r key value; do
            # 只有当值的首尾是双引号时，才剥离它们
            if [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            CONFIG[$key]="$value"
        done < <(jq -r 'to_entries
            | map(select(.key != "menus" and .key != "dependencies" and (.key | startswith("comment") | not)))
            | map("\(.key)=\(.value)")
            | .[]' "$CONFIG_FILE" 2>/dev/null || true)
        
        CONFIG[dependencies]="$(jq -r '.dependencies.common // "curl cmp ln dirname flock jq"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[dependencies]}")"
        CONFIG[lock_file]="$(jq -r '.lock_file // "/tmp/vps_install_modules.lock"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[lock_file]}")"
        CONFIG[enable_auto_clear]="$(jq -r '.enable_auto_clear // false' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[enable_auto_clear]}")"
        CONFIG[timezone]="$(jq -r '.timezone // "Asia/Shanghai"' "$CONFIG_FILE" 2>/dev/null || echo "${CONFIG[timezone]}")"
        
        # 核心：读取根目录的 default_interval 和 default_cron_hour
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
        log_warn "缺少核心依赖: ${missing_deps[*]}"
        local pm
        if command -v apt-get &>/dev/null; then pm="apt"; elif command -v dnf &>/dev/null; then pm="dnf"; elif command -v yum &>/dev/null; then pm="yum"; else pm="unknown"; fi
        if [ "$pm" = "unknown" ]; then
            log_err "无法检测到包管理器, 请手动安装: ${missing_deps[*]}"
            exit 1
        fi
        if [ "$AUTO_YES" = "true" ]; then
            choice="y"
        else
            read -p "$(echo -e "${YELLOW}是否尝试自动安装? (y/N): ${NC}")" choice < /dev/tty
        fi
        if echo "$choice" | grep -qE '^[Yy]$'; then
            log_info "正在使用 $pm 安装..."
            local update_cmd=""
            if [ "$pm" = "apt" ]; then update_cmd="JB_SUDO_LOG_QUIET='true' run_with_sudo apt-get update"; fi # 优化：抑制 apt-get update 的日志
            # 优化：抑制包安装的 run_with_sudo 日志
            if ! ($update_cmd && JB_SUDO_LOG_QUIET='true' run_with_sudo "$pm" install -y "${missing_deps[@]}"); then
                log_err "依赖安装失败."
                exit 1
            fi
            log_success "依赖安装完成！"
        else
            log_err "用户取消安装."
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
    # 如果当前执行的脚本不是最终安装路径的脚本，则不执行自更新（由启动器处理）
    if [ "$0" != "$SCRIPT_PATH" ]; then
        return
    fi
    local temp_script="/tmp/install.sh.tmp.$$"
    if ! _download_file "install.sh" "$temp_script"; then
        log_warn "主程序 (install.sh) 更新检查失败 (无法连接)。"
        rm -f "$temp_script" 2>/dev/null || true
        return
    fi
    if ! cmp -s "$SCRIPT_PATH" "$temp_script"; then
        log_success "主程序 (install.sh) 已更新。正在无缝重启..."
        # 优化：抑制 mv 和 chmod 的 run_with_sudo 日志
        JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_script" "$SCRIPT_PATH"
        JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "$SCRIPT_PATH"
        flock -u 200 || true
        rm -f "${CONFIG[lock_file]}" 2>/dev/null || true # 锁文件在 /tmp，用户可删除
        trap - EXIT # 取消退出陷阱，防止在 exec 后再次执行
        # 核心：重启自身，仍以当前用户身份执行
        export -f run_with_sudo # 再次导出，确保新执行的脚本也能识别
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
        log_err "模块 (${script_name}) 下载失败 (HTTP: $http_code, Curl: $curl_exit_code)"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi
    if [ -f "$local_file" ] && cmp -s "$local_file" "$tmp_file"; then
        rm -f "$tmp_file" 2>/dev/null || true
        return 0
    else
        log_success "模块 (${script_name}) 已更新。"
        # 优化：抑制 mkdir, mv, chmod 的 run_with_sudo 日志
        JB_SUDO_LOG_QUIET="true" run_with_sudo mkdir -p "$(dirname "$local_file")"
        JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$tmp_file" "$local_file"
        JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "$local_file" || true
    fi
}

_update_core_files() {
    local temp_utils="/tmp/utils.sh.tmp.$$"
    if _download_file "utils.sh" "$temp_utils"; then
        if [ ! -f "$UTILS_PATH" ] || ! cmp -s "$UTILS_PATH" "$temp_utils"; then
            log_success "核心工具库 (utils.sh) 已更新。"
            JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_utils" "$UTILS_PATH"
            JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "$UTILS_PATH"
        else
            rm -f "$temp_utils" 2>/dev/null || true
        fi
    else
        log_warn "核心工具库 (utils.sh) 更新检查失败。"
    fi

    # ADDED: Explicitly update config.json here
    local temp_config="/tmp/config.json.tmp.$$"
    if _download_file "config.json" "$temp_config"; then
        if [ ! -f "$CONFIG_PATH" ] || ! cmp -s "$CONFIG_PATH" "$temp_config"; then
            log_success "核心配置文件 (config.json) 已更新。"
            JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_config" "$CONFIG_PATH"
        else
            rm -f "$temp_config" 2>/dev/null || true
        fi
    else
        log_warn "核心配置文件 (config.json) 更新检查失败。"
    fi
}

_update_all_modules() {
    local cfg="${CONFIG[install_dir]}/config.json"
    if [ ! -f "$cfg" ]; then
        log_warn "配置文件 ${cfg} 不存在，跳过模块更新。"
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
        log_info "未检测到可更新的模块。"
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
    log_success "所有组件更新检查完成！"
}

confirm_and_force_update() {
    log_warn "警告: 这将从 GitHub 强制拉取所有最新脚本和【主配置文件 config.json】。"
    log_warn "您对 config.json 的【所有本地修改都将丢失】！这是一个恢复出厂设置的操作。"
    read -p "$(echo -e "${RED}此操作不可逆，请输入 'yes' 确认继续: ${NC}")" choice < /dev/tty
    if [ "$choice" = "yes" ]; then
        log_info "开始强制完全重置..."
        declare -A core_files_to_reset=( ["主程序"]="install.sh" ["工具库"]="utils.sh" ["配置文件"]="config.json" )
        for name in "${!core_files_to_reset[@]}"; do
            local file_path="${core_files_to_reset[$name]}"
            log_info "正在强制更新 ${name}..."
            local temp_file="/tmp/$(basename "$file_path").tmp.$$"
            if ! _download_file "$file_path" "$temp_file"; then
                log_err "下载最新的 ${name} 失败。"
                continue
            fi
            # 优化：抑制 mv 的 run_with_sudo 日志
            JB_SUDO_LOG_QUIET="true" run_with_sudo mv "$temp_file" "${CONFIG[install_dir]}/${file_path}"
            log_success "${name} 已重置为最新版本。"
        done
        log_info "正在恢复核心脚本执行权限..."
        # 优化：抑制 chmod 的 run_with_sudo 日志
        JB_SUDO_LOG_QUIET="true" run_with_sudo chmod +x "${CONFIG[install_dir]}/install.sh" "${CONFIG[install_dir]}/utils.sh" || true
        log_success "权限已恢复。"
        _update_all_modules
        log_success "强制重置完成！"
        log_info "脚本将在2秒后自动重启以应用所有更新..."
        sleep 2
        flock -u 200 || true
        rm -f "${CONFIG[lock_file]}" 2>/dev/null || true # 锁文件在 /tmp，用户可删除
        trap - EXIT
        # 核心：重启自身，仍以当前用户身份执行
        export -f run_with_sudo # 再次导出，确保新执行的脚本也能识别
        exec bash "$FINAL_SCRIPT_PATH" "$@"
    else
        log_info "操作已取消."
    fi
    return 10
}

uninstall_script() {
    log_warn "警告: 这将从您的系统中彻底移除本脚本及其所有组件！"
    log_warn "  - 安装目录: ${CONFIG[install_dir]}"
    log_warn "  - 快捷方式: ${CONFIG[bin_dir]}/jb"
    read -p "$(echo -e "${RED}这是一个不可逆的操作, 您确定要继续吗? (请输入 'yes' 确认): ${NC}")" choice < /dev/tty
    if [ "$choice" = "yes" ]; then
        log_info "开始卸载..."
        # 优化：抑制 rm 的 run_with_sudo 日志
        JB_SUDO_LOG_QUIET="true" run_with_sudo rm -rf "${CONFIG[install_dir]}"
        log_success "安装目录已移除."
        JB_SUDO_LOG_QUIET="true" run_with_sudo rm -f "${CONFIG[bin_dir]}/jb"
        log_success "快捷方式已移除."
        log_success "脚本已成功卸载."
        log_info "再见！"
        exit 0
    else
        log_info "卸载操作已取消."
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
    log_info "您选择了 [$display_name]"

    if [ ! -f "$local_path" ]; then
        log_info "正在下载模块..."
        if ! download_module_to_cache "$script_name"; then
            log_err "下载失败."
            return 1
        fi
    fi

    local env_exports="export IS_NESTED_CALL=true
export FORCE_COLOR=true
export JB_ENABLE_AUTO_CLEAR='${CONFIG[enable_auto_clear]}'
export JB_TIMEZONE='${CONFIG[timezone]}'
export LC_ALL=${LC_ALL}
"
    # 核心：如果根目录有 default_interval 或 default_cron_hour，导出它们
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

    # 改进 jq_script，将 null 值转换为 ""
    local jq_script='to_entries | .[] | select((.key | startswith("comment") | not)) | .key as $k | .value as $v | 
        if ($v|type) == "array" then [$k, ($v|join(","))] 
        elif ($v|type) | IN("string", "number", "boolean") then [$k, $v] 
        elif ($v|type) == "null" then [$k, ""] # Treat null as empty string
        else empty end | @tsv'

    while IFS=$'\t' read -r key value; do
        if [ -n "$key" ]; then
            local key_upper
            key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]')
            
            # 针对数值型配置进行前置验证
            if [[ "$key" == *"interval"* ]] || [[ "$key" == *"hour"* ]]; then
                if ! echo "$value" | grep -qE '^[0-9]+$'; then
                    log_warn "config.json中'${module_key}.${key}'的值'${value}'不是有效数字，将忽略此配置。"
                    continue # 忽略无效的数值配置
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
# 核心：将 run_with_sudo 函数定义注入到子脚本中
if declare -f run_with_sudo &>/dev/null; then
  export -f run_with_sudo
else
  # Fallback definition if for some reason it's not inherited
  run_with_sudo() {
      echo -e "${CYAN}[子脚本 - 信息]${NC} 正在尝试以 root 权限执行: \$*" >&2
      sudo -E "\$@" < /dev/tty
  }
  export -f run_with_sudo
fi
$env_exports
# 核心：模块脚本以当前用户身份执行，如果需要root权限，模块内部应调用 run_with_sudo
exec bash '$local_path' $extra_args_str
EOF
    # 核心：执行 runner 脚本，不使用 sudo
    bash "$tmp_runner" < /dev/tty || local exit_code=$?
    rm -f "$tmp_runner" 2>/dev/null || true

    if [ "${exit_code:-0}" = "0" ]; then
        log_success "模块 [$display_name] 执行完毕."
    elif [ "${exit_code:-0}" = "10" ]; then
        log_info "已从 [$display_name] 返回."
    else
        log_warn "模块 [$display_name] 执行出错 (码: ${exit_code:-1})."
    fi

    return ${exit_code:-0}
}

_render_menu() {
    local title="$1"; shift
    local -a lines=("$@")

    local max_content_width=0 # 仅计算内容宽度，不含内部空格和边框
    
    local title_content_width=$(_get_visual_width "$title")
    if (( title_content_width > max_content_width )); then max_content_width=$title_content_width; fi

    for line in "${lines[@]}"; do
        local line_content_width=$(_get_visual_width "$line")
        if (( line_content_width > max_content_width )); then max_content_width=$line_content_width; fi
    done
    
    local inner_padding_chars=2 # 左右各一个空格，用于内容与边框之间的间距
    local box_inner_width=$((max_content_width + inner_padding_chars))
    if [ "$box_inner_width" -lt 38 ]; then box_inner_width=38; fi # 最小内容区域宽度 (38 + 2边框 = 40总宽)

    log_debug "DEBUG: _render_menu - title_content_width: $title_content_width, max_content_width: $max_content_width, box_inner_width: $box_inner_width"

    # 顶部
    echo ""; echo -e "${GREEN}╭$(generate_line "$box_inner_width" "─")╮${NC}"
    
    # 标题
    if [ -n "$title" ]; then
        local current_title_line_width=$((title_content_width + inner_padding_chars)) # 标题内容宽度 + 左右各1空格
        local padding_total=$((box_inner_width - current_title_line_width))
        local padding_left=$((padding_total / 2))
        local padding_right=$((padding_total - padding_left))
        
        local left_padding_str; left_padding_str=$(printf '%*s' "$padding_left")
        local right_padding_str; right_padding_str=$(printf '%*s' "$padding_right")

        log_debug "DEBUG: Title: '$title', padding_left: $padding_left, padding_right: $padding_right"
        echo -e "${GREEN}│${left_padding_str} ${title} ${right_padding_str}│${NC}"
    fi
    
    # 选项
    for line in "${lines[@]}"; do
        local line_content_width=$(_get_visual_width "$line")
        # 计算右侧填充：总内容区域宽度 - 当前行内容宽度 - 左侧一个空格
        local padding_right_for_line=$((box_inner_width - line_content_width - 1)) 
        if [ "$padding_right_for_line" -lt 0 ]; then padding_right_for_line=0; fi
        log_debug "DEBUG: Line: '$line', line_content_width: $line_content_width, padding_right_for_line: $padding_right_for_line"
        echo -e "${GREEN}│ ${line} $(printf '%*s' "$padding_right_for_line")${GREEN}│${NC}" # 左侧固定一个空格
    done

    # 底部
    echo -e "${GREEN}╰$(generate_line "$box_inner_width" "─")╯${NC}"
}

_print_header() { _render_menu "$1" ""; }

display_menu() {
    if [ "${CONFIG[enable_auto_clear]}" = "true" ]; then clear 2>/dev/null || true; fi
    local config_path="${CONFIG[install_dir]}/config.json"
    log_debug "DEBUG: display_menu called. config_path: $config_path"

    if [ ! -f "$config_path" ]; then
        log_err "配置文件 ${config_path} 未找到，请确保已安装核心文件。"
        exit 1 # Exit Code 100 for config file missing
    fi
    log_debug "DEBUG: config.json exists. Content (first 100 chars): $(head -c 100 "$config_path" 2>/dev/null || echo "Error reading file")"

    local menu_json
    # 修复：使用 2>/dev/null 替代 2>/dev/tty
    menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path" 2>/dev/null || echo "")
    if [ -z "$menu_json" ] || [ "$menu_json" = "null" ]; then
        log_err "菜单 ${CURRENT_MENU_NAME} 配置无效或无法解析！"
        log_debug "DEBUG: Failed to parse menu_json for $CURRENT_MENU_NAME. menu_json was: '$menu_json'"
        exit 1 # Exit Code 101 for menu parsing failure
    fi
    log_debug "DEBUG: menu_json for $CURRENT_MENU_NAME successfully parsed."

    local main_title_text
    main_title_text=$(jq -r '.title // "VPS 安装脚本"' <<< "$menu_json" 2>/dev/null || echo "无法获取标题")
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
    # 修复：使用 2>/dev/null 替代 2>/dev/tty
    menu_len=$(jq -r '.items | length' <<< "$menu_json" 2>/dev/null || echo "0")
    log_debug "DEBUG: menu_len: $menu_len"
    local exit_hint="退出"
    if [ "$CURRENT_MENU_NAME" != "MAIN_MENU" ]; then exit_hint="返回"; fi
    local prompt_text=" └──> 请选择 [1-${menu_len}], 或 [Enter] ${exit_hint}: "

    if [ "$AUTO_YES" = "true" ]; then
        choice=""
        echo -e "${BLUE}${prompt_text}${NC} [非交互模式]"
    else
        read -p "$(echo -e "${BLUE}${prompt_text}${NC}")" choice < /dev/tty
    fi
}

process_menu_selection() {
    local config_path="${CONFIG[install_dir]}/config.json"
    local menu_json
    # 修复：使用 2>/dev/null 替代 2>/dev/tty
    menu_json=$(jq -r --arg menu "$CURRENT_MENU_NAME" '.menus[$menu]' "$config_path" 2>/dev/null || echo "")
    local menu_len
    # 修复：使用 2>/dev/null 替代 2>/dev/tty
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
        log_warn "无效选项."
        return 10
    fi

    local item_json
    item_json=$(echo "$menu_json" | jq -r --argjson idx "$(expr $choice - 1)" '.items[$idx]' 2>/dev/null || echo "")
    if [ -z "$item_json" ] || [ "$item_json" = "null" ]; then
        log_warn "菜单项配置无效或不完整。"
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
            log_warn "未知菜单类型: $type"
            return 10
            ;;
    esac
}

main() {
    exec 200>"${CONFIG[lock_file]}"
    if ! flock -n 200; then
        echo -e "\033[0;33m[警告] 检测到另一实例正在运行."
        exit 1
    fi
    # 退出陷阱，确保在脚本退出时释放文件锁
    trap 'trap_exit_code=$?; flock -u 200; rm -f "${CONFIG[lock_file]}" 2>/dev/null || true; log_info "脚本已退出 (Exit Code: ${trap_exit_code})."' EXIT

    # 检查核心依赖，如果缺失则尝试安装
    if ! command -v flock >/dev/null || ! command -v jq >/dev/null; then
        check_and_install_dependencies
    fi

    load_config # 首次加载配置

    if [ $# -gt 0 ]; then
        # This block is skipped if user runs `jb` without args.
        local command="$1"; shift
        case "$command" in
            update)
                log_info "正在以 Headless 模式安全更新所有脚本..."
                force_update_all
                exit 0
                ;;
            uninstall)
                log_info "正在以 Headless 模式执行卸载..."
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
                    log_info "正在以 Headless 模式执行: ${display_name}"
                    if [ "$type" = "func" ]; then
                        "$action_to_run" "$@"
                    else
                        execute_module "$action_to_run" "$display_name" "$@"
                    fi
                    exit $?
                else
                    log_err "未知命令: $command"
                    exit 1
                fi
        esac
    fi

    log_info "脚本启动 (${SCRIPT_VERSION})"
    echo -ne "$(log_timestamp) ${BLUE}[信息]${NC} 正在智能更新 🕛"
    sleep 0.5
    echo -ne "\r$(log_timestamp) ${BLUE}[信息]${NC} 正在智能更新 🔄\n"
    force_update_all # 执行所有更新
    
    load_config # 核心修复：更新后重新加载配置，确保使用最新配置

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
