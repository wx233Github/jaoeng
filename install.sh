#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.6.15 - install.sh)
# - [更新] 与 Watchtower.sh 和 utils.sh 的最新版本同步。
# - [优化] 模块配置通过环境变量 JB_<MODULE>_CONF_<KEY> 传递。
# - [修复] 修正了 `_extract_interval_from_cmd` 函数中 `if` 语句的错误闭合 (} -> fi)。
# - [修复] 修正了 `_get_watchtower_remaining_time` 函数中 `if` 语句的错误闭合 (return; } -> return; fi)。
# - [修复] 修正了 `_parse_watchtower_timestamp_from_log_line` 函数中 `fih` 拼写错误。
# - [修复] 彻底解决 Watchtower 通知模板 Bash 转义问题。
# - [修复] 修复了菜单对齐问题（通过更新 utils.sh）。
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.15" # 脚本版本

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 路径定义 ---
BASE_DIR="/opt/vps_install_modules"
MODULES_DIR="$BASE_DIR/tools"
CONFIG_DIR="/etc" # 优先使用 /etc 存储主配置文件
CONFIG_FILE_JSON="$CONFIG_DIR/docker-auto-update-config.json"
UTILS_FILE="$BASE_DIR/utils.sh"

# 如果 /etc 不可写，则使用 $HOME
if ! [ -w "$CONFIG_DIR" ]; then
    CONFIG_DIR="$HOME"
    CONFIG_FILE_JSON="$HOME/.docker-auto-update-config.json"
fi

# --- 加载通用工具函数库 ---
# 必须先加载 utils.sh 才能使用其中的日志和菜单函数
if [ -f "$UTILS_FILE" ]; then
    source "$UTILS_FILE"
else
    # 如果 utils.sh 未找到，提供一个临时的 log_err 函数以避免脚本立即崩溃
    log_err() { echo "[错误] $*" >&2; }
    log_err "致命错误: 通用工具库 $UTILS_FILE 未找到！请确保其存在并有执行权限。"
    exit 1
fi

# --- 默认配置 (JSON 格式) ---
# 注意：这里定义的是 config.json 的默认结构和值
# 模块的默认配置应放在 modules.<module_name>.conf 下
DEFAULT_CONFIG_JSON=$(cat <<EOF
{
  "general": {
    "timezone": "Asia/Shanghai",
    "enable_auto_clear": true
  },
  "modules": {
    "watchtower": {
      "enabled": false,
      "conf": {
        "default_interval": 300,
        "default_cron_hour": 4,
        "exclude_containers": "",
        "extra_args": "",
        "debug_enabled": false,
        "config_interval": null,
        "notify_on_no_updates": false,
        "cron_task_enabled": false,
        "cron_hour": null,
        "compose_project_dir_cron": null,
        "bot_token": null,
        "chat_id": null,
        "email_to": null
      }
    }
  }
}
EOF
)

# --- 配置管理函数 ---

# 加载 config.json
load_config_json() {
    if [ ! -f "$CONFIG_FILE_JSON" ]; then
        log_warn "配置文件 $CONFIG_FILE_JSON 不存在，将创建默认配置。"
        echo "$DEFAULT_CONFIG_JSON" | jq . > "$CONFIG_FILE_JSON"
        chmod 600 "$CONFIG_FILE_JSON" || log_warn "⚠️ 无法设置配置文件权限。"
    fi
    # 确保 config_json_content 变量全局可用
    export CONFIG_JSON_CONTENT=$(cat "$CONFIG_FILE_JSON")
    # 导出通用配置
    export JB_TIMEZONE=$(_get_config_value ".general.timezone")
    export JB_ENABLE_AUTO_CLEAR=$(_get_config_value ".general.enable_auto_clear")
}

# 保存 config.json
save_config_json() {
    mkdir -p "$(dirname "$CONFIG_FILE_JSON")" 2>/dev/null || true
    echo "$CONFIG_JSON_CONTENT" | jq . > "$CONFIG_FILE_JSON"
    chmod 600 "$CONFIG_FILE_JSON" || log_warn "⚠️ 无法设置配置文件权限。"
}

# 从配置中获取值
# 参数1: jq 路径 (例如 ".general.timezone")
_get_config_value() {
    local path="$1"
    local value
    value=$(echo "$CONFIG_JSON_CONTENT" | jq -r "$path" 2>/dev/null || true)
    if [ "$value" = "null" ]; then
        echo ""
    else
        echo "$value"
    fi
}

# 设置配置值
# 参数1: jq 路径
# 参数2: 新值 (字符串)
_set_config_value() {
    local path="$1"
    local new_value="$2"
    CONFIG_JSON_CONTENT=$(echo "$CONFIG_JSON_CONTENT" | jq "$path = \"$new_value\"")
}

# 提示用户输入配置值
# 参数1: 配置路径
# 参数2: 提示信息
_prompt_for_config_value() {
    local path="$1"
    local prompt_msg="$2"
    local current_value=$(_get_config_value "$path")
    read -r -p "$(echo -e "${CYAN}${prompt_msg} (当前: ${current_value:-未设置}): ${NC}")" input
    if [ -n "$input" ]; then
        _set_config_value "$path" "$input"
    fi
}

# 提示用户输入布尔值
# 参数1: 配置路径
# 参数2: 提示信息
_prompt_for_bool() {
    local path="$1"
    local prompt_msg="$2"
    local current_value=$(_get_config_value "$path")
    read -r -p "$(echo -e "${CYAN}${prompt_msg} (y/N, 当前: ${current_value:-false}): ${NC}")" response
    if echo "$response" | grep -qE '^[Yy]$'; then
        _set_config_value "$path" "true"
    else
        _set_config_value "$path" "false"
    fi
}

# 提示用户输入列表值 (逗号分隔)
# 参数1: 配置路径
# 参数2: 提示信息
_prompt_for_list() {
    local path="$1"
    local prompt_msg="$2"
    local current_value=$(_get_config_value "$path")
    read -r -p "$(echo -e "${CYAN}${prompt_msg} (逗号分隔, 当前: ${current_value:-无}): ${NC}")" input
    _set_config_value "$path" "$input"
}

# --- 依赖检查 ---
check_dependencies() {
    log_info "正在检查系统依赖..."
    local missing_deps=()

    command -v docker &>/dev/null || missing_deps+=("Docker")
    command -v jq &>/dev/null || missing_deps+=("jq (用于JSON处理)")
    command -v curl &>/dev/null || missing_deps+=("curl (用于网络请求)")
    command -v sed &>/dev/null || missing_deps+=("sed")
    command -v grep &>/dev/null || missing_deps+=("grep")
    command -v head &>/dev/null || missing_deps+=("head")
    
    if [ "${#missing_deps[@]}" -gt 0 ]; then
        log_err "检测到以下依赖缺失，请先安装它们：${missing_deps[*]}"
        log_info "对于 Debian/Ubuntu 系统，可以使用 'sudo apt update && sudo apt install -y docker.io jq curl sed grep coreutils' 安装。"
        log_info "对于 CentOS/RHEL 系统，可以使用 'sudo yum install -y docker jq curl sed grep coreutils' 安装。"
        exit 1
    fi
    log_success "所有依赖检查通过。"
}

# --- 模块文件管理 ---

# _install_module_files: 安装模块脚本
# 参数1: 模块名称 (例如 "watchtower")
# 参数2: 模块脚本内容
_install_module_files() {
    local module_name="$1"
    local script_content="$2"
    local module_script_path="$MODULES_DIR/$module_name.sh"

    mkdir -p "$MODULES_DIR"

    echo "$script_content" | sudo tee "$module_script_path" >/dev/null
    sudo chmod +x "$module_script_path"
    log_success "模块脚本 ${module_name}.sh 已安装到 $module_script_path"
}

# _update_module_files: 更新模块脚本
# 参数1: 模块名称
# 参数2: 模块脚本内容
_update_module_files() {
    local module_name="$1"
    local script_content="$2"
    local module_script_path="$MODULES_DIR/$module_name.sh"

    if [ -f "$module_script_path" ]; then
        echo "$script_content" | sudo tee "$module_script_path" >/dev/null
        sudo chmod +x "$module_script_path"
        log_success "模块脚本 ${module_name}.sh 已更新。"
    else
        log_warn "模块脚本 ${module_name}.sh 不存在，将进行安装。"
        _install_module_files "$module_name" "$script_content"
    fi
}

# _uninstall_module_files: 卸载模块脚本
# 参数1: 模块名称
_uninstall_module_files() {
    local module_name="$1"
    local module_script_path="$MODULES_DIR/$module_name.sh"

    if [ -f "$module_script_path" ]; then
        sudo rm -f "$module_script_path"
        log_success "模块脚本 ${module_name}.sh 已卸载。"
    else
        log_warn "模块脚本 ${module_name}.sh 不存在，无需卸载。"
    fi
}

# --- 模块特定逻辑 ---

# Watchtower 模块的安装逻辑
_install_watchtower_module_logic() {
    log_info "正在安装 Watchtower 模块..."
    # 嵌入 Watchtower.sh 脚本内容
    local watchtower_script_content=$(cat <<'WATCHTOWER_EOF'
#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.6.15 - 终极修复版)
# - [终极修复] 彻底解决 WATCHTOWER_NOTIFICATION_TEMPLATE 环境变量传递问题：
#   - 恢复中文及表情模板。
#   - 使用 `cat <<'EOF'` 定义原始模板，并对 Bash 敏感字符（反引号）进行转义。
#   - 使用 `printf %q` 对最终命令进行引用，并通过 `eval` 执行，确保 Bash 正确解析。
# - [修复] 修正了 _parse_watchtower_timestamp_from_log_line 函数中 fih 拼写错误。
# - [修复] 修正了 _get_watchtower_remaining_time 函数中 'if' 语句的错误闭合 (return; } -> return; fi)。
# - [修复] 修正了 _extract_interval_from_cmd 函数中 'if' 语句的错误闭合 (} -> fi)。
# - [优化] config.json 中 notify_on_no_updates 默认 true
# - [优化] config.conf 存储优先级高于 config.json
# - [新增] 容器管理界面新增启动所有/停止所有功能
# - [修复] 修复了 load_config 等函数 command not found 问题
# - [优化] 菜单标题及版本信息显示
# - [适配] 适配 config.json 中 Watchtower 模块的默认配置
# - [优化] 时间处理函数自包含，减少对 utils.sh 的依赖
# - [修正] Watchtower详情页面“下次检查”状态显示逻辑
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.15" # 脚本版本

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    # 如果 utils.sh 未找到，提供一个临时的 log_err 函数以避免脚本立即崩溃
    log_err() { echo "[错误] $*" >&2; }
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- config.json 传递的 Watchtower 模块配置 (由 install.sh 提供) ---
# 这些变量直接从 config.json 映射过来，作为默认值
WT_CONF_DEFAULT_INTERVAL_FROM_JSON="${JB_WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"
WT_CONF_DEFAULT_CRON_HOUR_FROM_JSON="${JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"
WT_EXCLUDE_CONTAINERS_FROM_JSON="${JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_NOTIFY_ON_NO_UPDATES_FROM_JSON="${JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-false}"
# 其他可能从 config.json 传递的 WATCHTOWER_CONF_* 变量，用于初始化，但本地配置优先
WATCHTOWER_EXTRA_ARGS_FROM_JSON="${JB_WATCHTOWER_CONF_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL_FROM_JSON="${JB_WATCHTOWER_CONF_CONFIG_INTERVAL:-}" # 如果 config.json 有指定，用于初始化
WATCHTOWER_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON_FROM_JSON="${JB_WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR_FROM_JSON="${JB_WATCHTOWER_CONF_CRON_HOUR:-}"
CRON_TASK_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_TASK_ENABLED:-false}"
TG_BOT_TOKEN_FROM_JSON="${JB_WATCHTOWER_CONF_BOT_TOKEN:-}"
TG_CHAT_ID_FROM_JSON="${JB_WATCHTOWER_CONF_CHAT_ID:-}"
EMAIL_TO_FROM_JSON="${JB_WATCHTOWER_CONF_EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST_FROM_JSON="${JB_WATCHTOWER_CONF_EXCLUDE_LIST:-}"


CONFIG_FILE="/etc/docker-auto-update.conf"
if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# --- 模块专属函数 ---

# 初始化变量，使用 config.json 的默认值
# 这些是脚本内部使用的变量，它们的值会被本地配置文件覆盖
TG_BOT_TOKEN="${TG_BOT_TOKEN_FROM_JSON}"
TG_CHAT_ID="${TG_CHAT_ID_FROM_JSON}"
EMAIL_TO="${EMAIL_TO_FROM_JSON}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST_FROM_JSON}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_FROM_JSON}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED_FROM_JSON}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL_FROM_JSON}" # 优先使用 config.json 的具体配置
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED_FROM_JSON}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON_FROM_JSON}"
CRON_HOUR="${CRON_HOUR_FROM_JSON}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED_FROM_JSON}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WT_NOTIFY_ON_NO_UPDATES_FROM_JSON}"

# 加载本地配置文件 (config.conf)，覆盖 config.json 的默认值
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # 注意: source 命令会直接执行文件内容，覆盖同名变量
        source "$CONFIG_FILE" &>/dev/null || true
    fi
    # 确保所有变量都有最终值，本地配置优先，若本地为空则回退到 config.json 默认值
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TG_BOT_TOKEN_FROM_JSON}}"
    TG_CHAT_ID="${TG_CHAT_ID:-${TG_CHAT_ID_FROM_JSON}}"
    EMAIL_TO="${EMAIL_TO:-${EMAIL_TO_FROM_JSON}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-${WATCHTOWER_EXCLUDE_LIST_FROM_JSON}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-${WATCHTOWER_EXTRA_ARGS_FROM_JSON}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${WATCHTOWER_DEBUG_ENABLED_FROM_JSON}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONFIG_INTERVAL_FROM_JSON:-${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}}}" # 如果本地和 config.json 都没有具体配置，才使用 config.json 的 default_interval
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${WATCHTOWER_ENABLED_FROM_JSON}}"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-${DOCKER_COMPOSE_PROJECT_DIR_CRON_FROM_JSON}}"
    CRON_HOUR="${CRON_HOUR:-${CRON_HOUR_FROM_JSON:-${WT_CONF_DEFAULT_CRON_HOUR_FROM_JSON}}}" # 如果本地和 config.json 都没有具体配置，才使用 config.json 的 default_cron_hour
    CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-${CRON_TASK_ENABLED_FROM_JSON}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WT_NOTIFY_ON_NO_UPDATES_FROM_JSON}}"
}

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}


# --- Watchtower 模块所需的通用时间处理函数 (自包含在 Watchtower.sh 中) ---

# 解析 Watchtower 日志行中的时间戳
_parse_watchtower_timestamp_from_log_line() {
    local log_line="$1"
    local timestamp=""
    # 尝试匹配 time="YYYY-MM-DDTHH:MM:SS+ZZ:ZZ" 格式
    timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    # 尝试匹配 YYYY-MM-DDTHH:MM:SSZ 格式 (例如 Watchtower 1.7.1)
    timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    # 尝试匹配 "Scheduling first run: YYYY-MM-DD HH:MM:SS" 格式
    timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    echo ""
    return 1
}

# 将日期时间字符串转换为 Unix 时间戳 (epoch)
_date_to_epoch() {
    local dt="$1"
    [ -z "$dt" ] && echo "" && return 1 # 如果输入为空，返回空字符串并失败
    
    # 尝试使用 GNU date
    if date -d "now" >/dev/null 2>&1; then
        date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""; return 1)
    # 尝试使用 BSD date (通过 gdate 命令)
    elif command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1; then
        gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""; return 1)
    else
        log_warn "⚠️ 'date' 或 'gdate' 不支持。无法解析时间戳。"
        echo ""
        return 1
    fi
}

# 将秒数格式化为更易读的字符串 (例如 300s, 2h)
_format_seconds_to_human() {
    local seconds="$1"
    if ! echo "$seconds" | grep -qE '^[0-9]+$'; then
        echo "N/A"
        return 1
    fi
    
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}秒"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))分"
    elif [ "$seconds" -lt 86400 ]; then
        echo "$((seconds / 3600))时"
    else
        echo "$((seconds / 86400))天"
    fi
    return 0
}


send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        (curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "text=${message}" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1) &
    fi
}

_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2" # 例如 "一次性更新" 或 "Watchtower模式"

    local cmd_base=(docker run -e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_image="containrrr/watchtower"
    local wt_args=("--cleanup")
    local container_names=()

    if [ "$mode_description" = "一次性更新" ]; then
        cmd_base+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        cmd_base+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi
    cmd_base+=(-v /var/run/docker.sock:/var/run/docker.sock)

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        log_info "✅ 检测到 Telegram 配置，将为 Watchtower 启用通知。"
        # Shoutrrr URL for Telegram
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&ParseMode=Markdown")
        
        # 根据 WATCHTOWER_NOTIFY_ON_NO_UPDATES 设置 WATCHTOWER_REPORT_NO_UPDATES
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            cmd_base+=(-e WATCHTOWER_REPORT_NO_UPDATES=true)
            log_info "✅ 将启用 '无更新也通知' 模式。"
        else
            log_info "ℹ️ 将启用 '仅有更新才通知' 模式。"
        fi

        # Step 1: 定义原始 Go Template 模板字符串，使用 `cat <<'EOF'` 确保Bash不提前解析内部内容。
        # 内部的 `"` 和 `` ` `` 都是 Go Template 期望的字面量。
        local NOTIFICATION_TEMPLATE_RAW=$(cat <<'EOF'
🐳 *Docker 容器更新报告*

*服务器:* `{{.Host}}`

{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*
{{range .Updated}}
- 🔄 *{{.Name}}*
  🖼️ *镜像:* `{{.ImageName}}`
  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}

⏰ *时间:* `{{.Time.Format "2006-01-02 15:04:05"}}`
EOF
)
        # Step 2: 对原始模板字符串进行 Bash 转义，仅转义 Bash 自身会误解的字符。
        # 主要是反引号 `，因为它们会被 Bash 误认为是命令替换。
        # 换行符和 Go Template 内部的 `"` 不需要额外转义，它们会通过 `"${VAR}"` 被正确传递。
        local ESCAPED_TEMPLATE_FOR_BASH=$(echo "$NOTIFICATION_TEMPLATE_RAW" | sed 's/`/\\`/g')
        
        # Step 3: 将转义后的模板字符串作为环境变量添加到 cmd_base 数组。
        # Bash 的数组和双引号会确保其作为单个参数传递，包括换行符。
        # Watchtower 的 Go Template 解析器会处理内部的 ` ` ` 和 `"`。
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE=${ESCAPED_TEMPLATE_FOR_BASH}")
    fi

    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
        wt_args+=("--debug")
    fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then
        read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"
        wt_args+=("${extra_tokens[@]}")
    fi

    local final_exclude_list=""
    local source_msg=""
    # 优先使用脚本内 WATCHTOWER_EXCLUDE_LIST，其次是 config.json 的 exclude_containers
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
        final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
        source_msg="脚本内部"
    elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_JSON:-}" ]; then
        final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_JSON}"
        source_msg="config.json (exclude_containers)"
    elif [ -n "${WATCHTOWER_EXCLUDE_LIST_FROM_JSON:-}" ]; then # 兼容旧的 config.json 字段
        final_exclude_list="${WATCHTOWER_EXCLUDE_LIST_FROM_JSON}"
        source_msg="config.json (exclude_list)"
    fi
    
    local included_containers
    if [ -n "$final_exclude_list" ]; then
        log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"
        local exclude_pattern
        exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
        if [ -n "$included_containers" ]; then
            log_info "计算后的监控范围: ${included_containers}"
            read -r -a container_names <<< "$included_containers"
        else
            log_warn "排除规则导致监控列表为空！"
        fi
    else
        log_info "未发现排除规则，Watchtower 将监控所有容器。"
    fi

    echo "⬇️ 正在拉取 Watchtower 镜像..."
    set +e; docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    _print_header "正在启动 $mode_description"
    local final_cmd=("${cmd_base[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    # 使用 printf %q 对每个参数进行 Bash 引用，然后通过 eval 执行。
    # 这是最健壮的方式，可以处理所有特殊字符和多行字符串。
    local final_cmd_str=""
    for arg in "${final_cmd[@]}"; do
        final_cmd_str+=" $(printf %q "$arg")"
    done
    
    echo -e "${CYAN}执行命令: ${final_cmd_str}${NC}"
    
    set +e; eval "$final_cmd_str"; local rc=$?; set -e
    
    if [ "$mode_description" = "一次性更新" ]; then
        if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi
        return $rc
    else
        sleep 3
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."
    set +e
    docker rm -f watchtower &>/dev/null
    set -e
    
    local interval="${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower模式"; then
        log_err "Watchtower 重建失败！"
        WATCHTOWER_ENABLED="false"
        save_config
        return 1
    fi
    send_notify "🔄 Watchtower 服务已重建并启动。"
    log_success "Watchtower 重建成功。"
}

_prompt_and_rebuild_watchtower_if_needed() {
    if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        if confirm_action "配置已更新，是否立即重建 Watchtower 以应用新配置?"; then
            _rebuild_watchtower
        else
            log_warn "操作已取消。新配置将在下次手动重建 Watchtower 后生效。"
        fi
    fi
}

_configure_telegram() {
    read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"
    read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT
    TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"
    read -r -p "是否在没有容器更新时也发送 Telegram 通知? (y/N, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " notify_on_no_updates_choice
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Yy]$'; then
        WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"
    else
        WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"
    fi
    log_info "Telegram 配置已更新。"
}

_configure_email() {
    read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT
    EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"
    log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi

        local -a items_array=(
            "  1. › 配置 Telegram  ($tg_status, 无更新也通知: $notify_on_no_updates_status)"
            "  2. › 配置 Email      ($email_status)"
            "  3. › 发送测试通知"
            "  4. › 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; _prompt_and_rebuild_watchtower_if_needed; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3)
                if [ -z "$TG_BOT_TOKEN" ] && [ -z "$EMAIL_TO" ]; then
                    log_warn "请先配置至少一种通知方式。"
                else
                    log_info "正在发送测试..."
                    send_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} 的*测试消息*。"
                    log_info "测试通知已发送。请检查你的 Telegram 或邮箱。"
                fi
                press_enter_to_continue
                ;;
            4)
                if confirm_action "确定要清空所有通知配置吗?"; then
                    TG_BOT_TOKEN=""
                    TG_CHAT_ID=""
                    EMAIL_TO=""
                    WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"
                    save_config
                    log_info "所有通知配置已清空。"
                    _prompt_and_rebuild_watchtower_if_needed
                else
                    log_info "操作已取消。"
                fi
                press_enter_to_continue
                ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

show_container_info() { 
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a content_lines_array=()
        local header_line; header_line=$(printf "%-5s %-25s %-45s %-20s" "编号" "名称" "镜像" "状态")
        content_lines_array+=("$header_line")
        local -a containers=()
        local i=1
        while IFS='|' read -r name image status; do 
            containers+=("$name")
            local status_colored="$status"
            if echo "$status" | grep -qE '^Up'; then status_colored="${GREEN}运行中${NC}"
            elif echo "$status" | grep -qE '^Exited|Created'; then status_colored="${RED}已退出${NC}"
            else status_colored="${YELLOW}${status}${NC}"; fi
            content_lines_array+=("$(printf "%-5s %-25.25s %-45.45s %b" "$i" "$name" "$image" "$status_colored")")
            i=$((i + 1))
        done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        content_lines_array+=("")
        content_lines_array+=(" a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice
        case "$choice" in 
            "") return ;;
            a|A)
                if confirm_action "确定要启动所有已停止的容器吗?"; then
                    log_info "正在启动..."
                    local stopped_containers; stopped_containers=$(docker ps -aq -f status=exited)
                    if [ -n "$stopped_containers" ]; then docker start $stopped_containers &>/dev/null || true; fi
                    log_success "操作完成。"
                    press_enter_to_continue
                else
                    log_info "操作已取消。"
                fi
                ;; 
            s|S)
                if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then
                    log_info "正在停止..."
                    local running_containers; running_containers=$(docker ps -q)
                    if [ -n "$running_containers" ]; then docker stop $running_containers &>/dev/null || true; fi
                    log_success "操作完成。"
                    press_enter_to_continue
                else
                    log_info "操作已取消。"
                fi
                ;; 
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
                    log_warn "无效输入或编号超范围。"
                    sleep 1
                    continue
                fi
                local selected_container="${containers[$((choice - 1))]}"
                if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
                local -a action_items_array=(
                    "  1. › 查看日志 (Logs)"
                    "  2. › 重启 (Restart)"
                    "  3. › 停止 (Stop)"
                    "  4. › 删除 (Remove)"
                    "  5. › 查看详情 (Inspect)"
                    "  6. › 进入容器 (Exec)"
                )
                _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"
                read -r -p " └──> 请选择, 或按 Enter 返回: " action
                case "$action" in 
                    1)
                        echo -e "${YELLOW}日志 (Ctrl+C 停止)...${NC}"
                        trap '' INT # 临时禁用中断
                        docker logs -f --tail 100 "$selected_container" || true
                        trap 'echo -e "\n操作被中断。"; exit 10' INT # 恢复中断处理
                        press_enter_to_continue
                        ;;
                    2)
                        echo "重启中..."
                        if docker restart "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                        sleep 1
                        ;; 
                    3)
                        echo "停止中..."
                        if docker stop "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                        sleep 1
                        ;; 
                    4)
                        if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then
                            echo "删除中..."
                            if docker rm -f "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                            sleep 1
                        else
                            echo "已取消。"
                        fi
                        ;; 
                    5)
                        _print_header "容器详情: ${selected_container}"
                        (docker inspect "$selected_container" | jq '.' 2>/dev/null || docker inspect "$selected_container") | less -R
                        ;; 
                    6)
                        if [ "$(docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]; then
                            log_warn "容器未在运行，无法进入。"
                        else
                            log_info "尝试进入容器... (输入 'exit' 退出)"
                            docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true
                        fi
                        press_enter_to_continue
                        ;; 
                    *) ;; 
                esac
                ;;
        esac
    done
}

configure_exclusion_list() {
    declare -A excluded_map
    # 优先使用脚本内 WATCHTOWER_EXCLUDE_LIST，其次是 config.json 的 exclude_containers
    local initial_exclude_list=""
    if [ -n "$WATCHTOWER_EXCLUDE_LIST" ]; then
        initial_exclude_list="$WATCHTOWER_EXCLUDE_LIST"
    elif [ -n "$WT_EXCLUDE_CONTAINERS_FROM_JSON" ]; then
        initial_exclude_list="$WT_EXCLUDE_CONTAINERS_FROM_JSON"
    fi

    if [ -n "$initial_exclude_list" ]; then
        local IFS=,
        for container_name in $initial_exclude_list; do
            container_name=$(echo "$container_name" | xargs)
            if [ -n "$container_name" ]; then
                excluded_map["$container_name"]=1
            fi
        done
        unset IFS
    fi

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-}" = "true" ]; then clear; fi
        local -a all_containers_array=()
        while IFS= read -r line; do
            all_containers_array+=("$line")
        done < <(docker ps --format '{{.Names}}')

        local -a items_array=()
        local i=0
        while [ $i -lt ${#all_containers_array[@]} ]; do
            local container="${all_containers_array[$i]}"
            local is_excluded=" "
            if [ -n "${excluded_map[$container]+_}" ]; then
                is_excluded="✔"
            fi
            items_array+=("  $((i + 1)). [${GREEN}${is_excluded}${NC}] $container")
            i=$((i + 1))
        done
        items_array+=("")
        local current_excluded_display=""
        if [ ${#excluded_map[@]} -gt 0 ]; then
            current_excluded_display=$(IFS=,; echo "${!excluded_map[*]:-}")
        fi
        items_array+=("${CYAN}当前排除 (脚本内): ${current_excluded_display:-(空, 将使用 config.json 的 exclude_containers)}${NC}")
        items_array+=("${CYAN}备用排除 (config.json 的 exclude_containers): ${WT_EXCLUDE_CONTAINERS_FROM_JSON:-无}${NC}")

        _render_menu "配置排除列表 (高优先级)" "${items_array[@]}"
        read -r -p " └──> 输入数字(可用','分隔)切换, 'c'确认, [回车]使用备用配置: " choice

        case "$choice" in
            c|C) break ;;
            "")
                excluded_map=()
                log_info "已清空脚本内配置，将使用 config.json 的备用配置。"
                sleep 1.5
                break
                ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' ')
                IFS=',' read -r -a selected_indices <<< "$clean_choice"
                local has_invalid_input=false
                for index in "${selected_indices[@]}"; do
                    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#all_containers_array[@]} ]; then
                        local target_container="${all_containers_array[$((index - 1))]}"
                        if [ -n "${excluded_map[$target_container]+_}" ]; then
                            unset excluded_map["$target_container"]
                        else
                            excluded_map["$target_container"]=1
                        fi
                    elif [ -n "$index" ]; then
                        has_invalid_input=true
                    fi
                done
                if [ "$has_invalid_input" = "true" ]; then
                    log_warn "输入 '${choice}' 中包含无效选项，已忽略。"
                    sleep 1.5
                fi
                ;;
        esac
    done
    local final_excluded_list=""
    if [ ${#excluded_map[@]} -gt 0 ]; then
        final_excluded_list=$(IFS=,; echo "${!excluded_map[*]:-}")
    fi
    WATCHTOWER_EXCLUDE_LIST="$final_excluded_list"
}

configure_watchtower(){
    _print_header "🚀 Watchtower 配置"
    local WT_INTERVAL_TMP="$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}}" "请输入检查间隔 (config.json 默认: $(_format_seconds_to_human "${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}"))")"
    log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"
    sleep 1

    configure_exclusion_list

    read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then
        read -r -p "请输入额外参数: " temp_extra_args
    fi

    read -r -p "是否启用调试模式? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " debug_choice
    local temp_debug_enabled="false"
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then
        temp_debug_enabled="true"
    fi

    local final_exclude_list_display
    # 显示时优先脚本内配置，其次 config.json 的 exclude_containers
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
        final_exclude_list_display="${WATCHTOWER_EXCLUDE_LIST}"
        source_msg="脚本"
    elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_JSON:-}" ]; then
        final_exclude_list_display="${WT_EXCLUDE_CONTAINERS_FROM_JSON}"
        source_msg="config.json (exclude_containers)"
    else
        final_exclude_list_display="无"
        source_msg=""
    fi

    local -a confirm_array=(
        " 检查间隔: $(_format_seconds_to_human "$WT_INTERVAL_TMP")"
        " 排除列表 (${source_msg}): ${final_exclude_list_display//,/, }"
        " 额外参数: ${temp_extra_args:-无}"
        " 调试模式: $temp_debug_enabled"
    )
    _render_menu "配置确认" "${confirm_array[@]}"
    read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice
    if echo "$confirm_choice" | grep -qE '^[Nn]$'; then
        log_info "操作已取消。"
        return 10
    fi

    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"
    WATCHTOWER_EXTRA_ARGS="$temp_extra_args"
    WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"
    WATCHTOWER_ENABLED="true"
    save_config
    
    _rebuild_watchtower || return 1
    return 0
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a items_array=(
            "  1. › 停止/移除 Watchtower"
            "  2. › 重建 Watchtower"
        )
        _render_menu "⚙️ 任务管理 ⚙️" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    if confirm_action "确定移除 Watchtower？"; then
                        set +e
                        docker rm -f watchtower &>/dev/null
                        set -e
                        WATCHTOWER_ENABLED="false"
                        save_config
                        send_notify "🗑️ Watchtower 已从您的服务器移除。"
                        echo -e "${GREEN}✅ 已移除。${NC}"
                    fi
                else
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    _rebuild_watchtower
                else
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue
                ;;
            *)
                if [ -z "$choice" ]; then return; else log_warn "无效选项"; sleep 1; fi
                ;;
        esac
    done
}

get_watchtower_all_raw_logs(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 1
    fi
    docker logs --tail 2000 watchtower 2>&1 || true
}

_extract_interval_from_cmd(){
    local cmd_json="$1"
    local interval=""
    if command -v jq >/dev/null 2>&1; then
        interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
    else
        local tokens; read -r -a tokens <<< "$(echo "$cmd_json" | tr -d '[],"')"
        local prev=""
        for t in "${tokens[@]}"; do
            if [ "$prev" = "--interval" ]; then
                interval="$t"
                break
            fi # <--- 修正了这里！
            prev="$t"
        done
    fi
    interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g')
    if [ -z "$interval" ]; then
        echo ""
    else
        echo "$interval"
    fi
}

get_watchtower_inspect_summary(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 2
    fi
    local cmd
    cmd=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    _extract_interval_from_cmd "$cmd" 2>/dev/null || true
}

get_last_session_time(){
    local logs
    logs=$(get_watchtower_all_raw_logs 2>/dev/null || true)
    if [ -z "$logs" ]; then echo ""; return 1; fi
    local line ts
    if echo "$logs" | grep -qiE "permission denied|cannot connect"; then
        echo -e "${RED}错误:权限不足${NC}"
        return 1
    fi
    line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    if [ -n "$line" ]; then
        ts=$(_parse_watchtower_timestamp_from_log_line "$line")
        if [ -n "$ts" ]; then
            echo "$ts"
            return 0
        fi
    fi
    echo ""
    return 1
}

get_updates_last_24h(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 1
    fi
    local since
    if date -d "24 hours ago" >/dev/null 2>&1; then
        since=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    elif command -v gdate >/dev/null 2>&1; then
        since=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    fi
    local raw_logs
    if [ -n "$since" ]; then
        raw_logs=$(docker logs --since "$since" watchtower 2>&1 || true)
    fi
    if [ -z "$raw_logs" ]; then
        raw_logs=$(docker logs --tail 200 watchtower 2>&1 || true)
    fi
    # 过滤 Watchtower 日志，只显示关键事件和错误
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|fatal|permission denied|cannot connect|Could not do a head request|Notification template error|Could not use configured notification template" || true
}

_format_and_highlight_log_line(){
    local line="$1"
    local ts
    ts=$(_parse_watchtower_timestamp_from_log_line "$line")
    case "$line" in
        *"Session done"*)
            local f s u c
            f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p')
            s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p')
            u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p')
            c="$GREEN"
            if [ "${f:-0}" -gt 0 ]; then c="$YELLOW"; fi
            printf "%s %b%s%b\n" "$ts" "$c" "✅ 扫描: ${s:-?}, 更新: ${u:-?}, 失败: ${f:-?}" "$NC"
            ;;
        *"Found new"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$NC"
            ;;
        *"Stopping "*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$NC"
            ;;
        *"Creating "*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$NC"
            ;;
        *"No new images found"*)
            printf "%s %b%s%b\n" "$ts" "$CYAN" "ℹ️ 未发现新镜像。" "$NC"
            ;;
        *"Scheduling first run"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🕒 首次运行已调度" "$NC"
            ;;
        *"Starting Watchtower"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "✨ Watchtower 已启动" "$NC"
            ;;
        *)
            if echo "$line" | grep -qiE "\b(unauthorized|failed|error|fatal)\b|permission denied|cannot connect|Could not do a head request|Notification template error|Could not use configured notification template"; then
                local msg
                msg=$(echo "$line" | sed -n 's/.*error="\([^"]*\)".*/\1/p' | tr -d '\n')
                if [ -z "$msg" ] && [[ "$line" == *"msg="* ]]; then # 优先从msg=中提取，如果没有，则尝试从error=中提取
                    msg=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p' | tr -d '\n')
                fi
                if [ -z "$msg" ]; then
                    msg=$(echo "$line" | sed -E 's/.*(level=(error|warn|info|fatal)|time="[^"]*")\s*//g' | tr -d '\n')
                fi
                local full_msg="${msg:-$line}"
                local truncated_msg
                if [ ${#full_msg} -gt 50 ]; then
                    truncated_msg="${full_msg:0:47}..."
                else
                    truncated_msg="$full_msg"
                fi
                printf "%s %b%s%b\n" "$ts" "$RED" "❌ 错误: ${truncated_msg}" "$NC"
            fi
            ;;
    esac
}

_get_watchtower_remaining_time(){
    local int="$1"
    local logs="$2"
    if [ -z "$int" ] || [ -z "$logs" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local log_line ts epoch rem
    log_line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)

    if [ -z "$log_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    ts=$(_parse_watchtower_timestamp_from_log_line "$log_line")
    epoch=$(_date_to_epoch "$ts")

    if [ "$epoch" -gt 0 ]; then
        if [[ "$log_line" == *"Session done"* ]]; then
            rem=$((int - ($(date +%s) - epoch) ))
        elif [[ "$log_line" == *"Scheduling first run"* ]]; then
            # 如果是首次调度，计算距离调度时间的剩余时间 (未来时间 - 当前时间)
            rem=$((epoch - $(date +%s)))
        elif [[ "$log_line" == *"Starting Watchtower"* ]]; then
            # 如果 Watchtower 刚刚启动，但还没有调度第一次运行，显示等待
            echo -e "${YELLOW}等待首次调度...${NC}"; return;
        fi

        if [ "$rem" -gt 0 ]; then
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" $((rem / 3600)) $(((rem % 3600) / 60)) $((rem % 60)) "$NC"
        else
            local overdue=$(( -rem ))
            printf "%b已逾期 %02d分%02d秒, 正在等待...%b" "$YELLOW" $((overdue / 60)) $((overdue % 60)) "$NC"
        fi
    else
        echo -e "${YELLOW}计算中...${NC}"
    fi
}


show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local title="📊 Watchtower 详情与管理 📊"
        local interval raw_logs countdown updates

        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")

        local -a content_lines_array=(
            "上次活动: $(get_last_session_time || echo 'N/A')"
            "下次检查: $countdown"
            ""
            "最近 24h 摘要："
        )
        updates=$(get_updates_last_24h || true)
        if [ -z "$updates" ]; then
            content_lines_array+=("  无日志事件。")
        else
            while IFS= read -r line; do
                content_lines_array+=("  $(_format_and_highlight_log_line "$line")")
            done <<< "$updates"
        fi

        _render_menu "$title" "${content_lines_array[@]}"
        read -r -p " └──> [1] 实时日志, [2] 容器管理, [3] 触 发 扫 描 , [Enter] 返 回 : " pick
        case "$pick" in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    echo -e "\n按 Ctrl+C 停止..."
                    trap '' INT # 临时禁用中断
                    docker logs --tail 200 -f watchtower || true
                    trap 'echo -e "\n操作被中断。"; exit 10' INT # 恢复中断处理
                    press_enter_to_continue
                else
                    echo -e "\n${RED}Watchtower 未运行。${NC}"
                    press_enter_to_continue
                fi
                ;;
            2) show_container_info ;;
            3)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    log_info "正在发送 SIGHUP 信号以触发扫描..."
                    if docker kill -s SIGHUP watchtower; then
                        log_success "信号已发送！请在下方查看实时日志..."
                        echo -e "按 Ctrl+C 停止..."; sleep 2
                        trap '' INT # 临时禁用中断
                        docker logs -f --tail 100 watchtower || true
                        trap 'echo -e "\n操作被中断。"; exit 10' INT # 恢复中断处理
                    else
                        log_err "发送信号失败！"
                    fi
                else
                    log_warn "Watchtower 未运行，无法触发扫描。"
                fi
                press_enter_to_continue
                ;;
            *) return ;;
        esac
    done
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then
        log_info "操作已取消。"
        return 1
    fi
    echo -e "${YELLOW}🆕 运行一次 Watchtower${NC}"
    if ! _start_watchtower_container_logic "" "一次性更新"; then
        return 1
    fi
    return 0
}

view_and_edit_config(){
    local -a config_items
    config_items=(
        "TG Token|TG_BOT_TOKEN|string"
        "TG Chat ID|TG_CHAT_ID|string"
        "Email|EMAIL_TO|string"
        "排除列表|WATCHTOWER_EXCLUDE_LIST|string_list" # string_list 用于显示多个值
        "额外参数|WATCHTOWER_EXTRA_ARGS|string"
        "调试模式|WATCHTOWER_DEBUG_ENABLED|bool"
        "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval"
        "Watchtower 启用状态|WATCHTOWER_ENABLED|bool"
        "Cron 执行小时|CRON_HOUR|number_range|0-23"
        "Cron 项目目录|DOCKER_COMPOSE_PROJECT_DIR_CRON|string"
        "Cron 任务启用状态|CRON_TASK_ENABLED|bool"
        "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool" # 新增
    )

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        load_config # 每次进入菜单都重新加载配置，确保最新
        local -a content_lines_array=()
        local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"
            local label; label=$(echo "$item" | cut -d'|' -f1)
            local var_name; var_name=$(echo "$item" | cut -d'|' -f2)
            local type; type=$(echo "$item" | cut -d'|' -f3)
            local extra; extra=$(echo "$item" | cut -d'|' -f4)
            local current_value="${!var_name}"
            local display_text=""
            local color="${CYAN}"

            case "$type" in
                string)
                    if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi
                    ;;
                string_list) # 针对排除列表的显示
                    if [ -n "$current_value" ]; then color="${YELLOW}"; display_text="${current_value//,/, }"; else color="${CYAN}"; display_text="无"; fi
                    ;;
                bool)
                    if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi
                    ;;
                interval)
                    display_text=$(_format_seconds_to_human "$current_value")
                    if [ "$display_text" != "N/A" ] && [ -n "$current_value" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi
                    ;;
                number_range)
                    if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi
                    ;;
            esac
            content_lines_array+=("$(printf " %2d. %-20s: %b%s%b" "$((i + 1))" "$label" "$color" "$display_text" "$NC")")
        done

        _render_menu "⚙️ 配置查看与编辑 (底层) ⚙️" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号编辑, 或按 Enter 返回: " choice
        if [ -z "$choice" ]; then return; fi

        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then
            log_warn "无效选项。"
            sleep 1
            continue
        fi

        local selected_index=$((choice - 1))
        local selected_item="${config_items[$selected_index]}"
        local label; label=$(echo "$selected_item" | cut -d'|' -f1)
        local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2)
        local type; type=$(echo "$selected_item" | cut -d'|' -f3)
        local extra; extra=$(echo "$selected_item" | cut -d'|' -f4)
        local current_value="${!var_name}"
        local new_value=""

        case "$type" in
            string|string_list) # string_list 也按 string 编辑
                read -r -p "请输入新的 '$label' (当前: $current_value): " new_value
                declare "$var_name"="${new_value:-$current_value}"
                ;;
            bool)
                read -r -p "是否启用 '$label'? (y/N, 当前: $current_value): " new_value
                if echo "$new_value" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi
                ;;
            interval)
                new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔")
                if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi
                ;;
            number_range)
                local min; min=$(echo "$extra" | cut -d'-' -f1)
                local max; max=$(echo "$extra" | cut -d'-' -f2)
                while true; do
                    read -r -p "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " new_value
                    if [ -z "$new_value" ]; then break; fi # 允许空值以保留当前值
                    if echo "$new_value" | grep -qE '^[0-9]+$' && [ "$new_value" -ge "$min" ] && [ "$new_value" -le "$max" ]; then
                        declare "$var_name"="$new_value"
                        break
                    else
                        log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"
                    fi
                done
                ;;
        esac
        save_config
        log_info "'$label' 已更新。"
        sleep 1
    done
}

main_menu(){
    # 在进入 Watchtower 模块主菜单时，打印一次欢迎和版本信息
    log_info "欢迎使用 Watchtower 模块 ${SCRIPT_VERSION}"

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        load_config # 每次进入菜单都重新加载配置，确保最新

        local STATUS_RAW="未运行"; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${GREEN}已启动${NC}"; else STATUS_COLOR="${RED}未运行${NC}"; fi
        
        local interval=""; local raw_logs="";
        if [ "$STATUS_RAW" = "已启动" ]; then
            interval=$(get_watchtower_inspect_summary)
            raw_logs=$(get_watchtower_all_raw_logs)
        fi
        
        local COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        local TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l)
        local RUNNING=$(docker ps --format '{{.ID}}' | wc -l)
        local STOPPED=$((TOTAL - RUNNING))

        local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE="";
        # 优先使用脚本内 WATCHTOWER_EXCLUDE_LIST，其次是 config.json 的 exclude_containers
        if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
            FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
            FINAL_EXCLUDE_SOURCE="脚本"
        elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_JSON:-}" ]; then
            FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_JSON}"
            FINAL_EXCLUDE_SOURCE="config.json (exclude_containers)"
        else
            FINAL_EXCLUDE_LIST="无"
            FINAL_EXCLUDE_SOURCE=""
        fi

        local NOTIFY_STATUS="";
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi
        if [ -n "$EMAIL_TO" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS (无更新也通知)"; else NOTIFY_STATUS="(无更新也通知)"; fi
        fi

        local header_text="Watchtower 管理" # 菜单标题不带版本号
        
        local -a content_array=(
            " 🕝 Watchtower 状态: ${STATUS_COLOR} (名称排除模式)"
            " ⏳ 下次检查: ${COUNTDOWN}"
            " 📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        if [ "$FINAL_EXCLUDE_LIST" != "无" ]; then content_array+=(" 🚫 排 除 列 表 : ${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC} (${CYAN}${FINAL_EXCLUDE_SOURCE}${NC})"); fi
        if [ -n "$NOTIFY_STATUS" ]; then content_array+=(" 🔔 通 知 已 启 用 : ${GREEN}${NOTIFY_STATUS}${NC}"); fi
        
        content_array+=(""
            "主菜单："
            "  1. › 配 置  Watchtower"
            "  2. › 配 置 通 知"
            "  3. › 任 务 管 理"
            "  4. › 查 看 /编 辑 配 置  (底 层 )"
            "  5. › 手 动 更 新 所 有 容 器"
            "  6. › 详 情 与 管 理"
        )
        
        _render_menu "$header_text" "${content_array[@]}"
        read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) view_and_edit_config ;;
          5) run_watchtower_once; press_enter_to_continue ;;
          6) show_watchtower_details ;;
          "") exit 10 ;; # 返回主脚本菜单
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done # 循环回到主菜单
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    if [ "${1:-}" = "--run-once" ]; then run_watchtower_once; exit $?; fi
    main_menu
    exit 10 # 退出脚本
}

main "$@"
WATCHTOWER_EOF
)
    _install_module_files "Watchtower" "$watchtower_script_content"
    # 启用 Watchtower 模块
    _set_config_value ".modules.watchtower.enabled" "true"
    save_config_json
    log_success "Watchtower 模块安装完成。"
}

# Watchtower 模块的更新逻辑
_update_watchtower_module_logic() {
    log_info "正在更新 Watchtower 模块..."
    local watchtower_script_content=$(cat <<'WATCHTOWER_EOF'
#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.6.15 - 终极修复版)
# - [终极修复] 彻底解决 WATCHTOWER_NOTIFICATION_TEMPLATE 环境变量传递问题：
#   - 恢复中文及表情模板。
#   - 使用 `cat <<'EOF'` 定义原始模板，并对 Bash 敏感字符（反引号）进行转义。
#   - 使用 `printf %q` 对最终命令进行引用，并通过 `eval` 执行，确保 Bash 正确解析。
# - [修复] 修正了 _parse_watchtower_timestamp_from_log_line 函数中 fih 拼写错误。
# - [修复] 修正了 _get_watchtower_remaining_time 函数中 'if' 语句的错误闭合 (return; } -> return; fi)。
# - [修复] 修正了 _extract_interval_from_cmd 函数中 'if' 语句的错误闭合 (} -> fi)。
# - [优化] config.json 中 notify_on_no_updates 默认 true
# - [优化] config.conf 存储优先级高于 config.json
# - [新增] 容器管理界面新增启动所有/停止所有功能
# - [修复] 修复了 load_config 等函数 command not found 问题
# - [优化] 菜单标题及版本信息显示
# - [适配] 适配 config.json 中 Watchtower 模块的默认配置
# - [优化] 时间处理函数自包含，减少对 utils.sh 的依赖
# - [修正] Watchtower详情页面“下次检查”状态显示逻辑
# =============================================================

# --- 脚本元数据 ---
SCRIPT_VERSION="v4.6.15" # 脚本版本

# --- 严格模式与环境设定 ---
set -eo pipefail
export LANG=${LANG:-en_US.UTF_8}
export LC_ALL=${LC_ALL:-C.UTF_8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    # 如果 utils.sh 未找到，提供一个临时的 log_err 函数以避免脚本立即崩溃
    log_err() { echo "[错误] $*" >&2; }
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

# --- config.json 传递的 Watchtower 模块配置 (由 install.sh 提供) ---
# 这些变量直接从 config.json 映射过来，作为默认值
WT_CONF_DEFAULT_INTERVAL_FROM_JSON="${JB_WATCHTOWER_CONF_DEFAULT_INTERVAL:-300}"
WT_CONF_DEFAULT_CRON_HOUR_FROM_JSON="${JB_WATCHTOWER_CONF_DEFAULT_CRON_HOUR:-4}"
WT_EXCLUDE_CONTAINERS_FROM_JSON="${JB_WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}"
WT_NOTIFY_ON_NO_UPDATES_FROM_JSON="${JB_WATCHTOWER_CONF_NOTIFY_ON_NO_UPDATES:-false}"
# 其他可能从 config.json 传递的 WATCHTOWER_CONF_* 变量，用于初始化，但本地配置优先
WATCHTOWER_EXTRA_ARGS_FROM_JSON="${JB_WATCHTOWER_CONF_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL_FROM_JSON="${JB_WATCHTOWER_CONF_CONFIG_INTERVAL:-}" # 如果 config.json 有指定，用于初始化
WATCHTOWER_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON_FROM_JSON="${JB_WATCHTOWER_CONF_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR_FROM_JSON="${JB_WATCHTOWER_CONF_CRON_HOUR:-}"
CRON_TASK_ENABLED_FROM_JSON="${JB_WATCHTOWER_CONF_TASK_ENABLED:-false}"
TG_BOT_TOKEN_FROM_JSON="${JB_WATCHTOWER_CONF_BOT_TOKEN:-}"
TG_CHAT_ID_FROM_JSON="${JB_WATCHTOWER_CONF_CHAT_ID:-}"
EMAIL_TO_FROM_JSON="${JB_WATCHTOWER_CONF_EMAIL_TO:-}"
WATCHTOWER_EXCLUDE_LIST_FROM_JSON="${JB_WATCHTOWER_CONF_EXCLUDE_LIST:-}"


CONFIG_FILE="/etc/docker-auto-update.conf"
if ! [ -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# --- 模块专属函数 ---

# 初始化变量，使用 config.json 的默认值
# 这些是脚本内部使用的变量，它们的值会被本地配置文件覆盖
TG_BOT_TOKEN="${TG_BOT_TOKEN_FROM_JSON}"
TG_CHAT_ID="${TG_CHAT_ID_FROM_JSON}"
EMAIL_TO="${EMAIL_TO_FROM_JSON}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST_FROM_JSON}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_FROM_JSON}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED_FROM_JSON}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL_FROM_JSON}" # 优先使用 config.json 的具体配置
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED_FROM_JSON}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON_FROM_JSON}"
CRON_HOUR="${CRON_HOUR_FROM_JSON}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED_FROM_JSON}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WT_NOTIFY_ON_NO_UPDATES_FROM_JSON}"

# 加载本地配置文件 (config.conf)，覆盖 config.json 的默认值
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # 注意: source 命令会直接执行文件内容，覆盖同名变量
        source "$CONFIG_FILE" &>/dev/null || true
    fi
    # 确保所有变量都有最终值，本地配置优先，若本地为空则回退到 config.json 默认值
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TG_BOT_TOKEN_FROM_JSON}}"
    TG_CHAT_ID="${TG_CHAT_ID:-${TG_CHAT_ID_FROM_JSON}}"
    EMAIL_TO="${EMAIL_TO:-${EMAIL_TO_FROM_JSON}}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-${WATCHTOWER_EXCLUDE_LIST_FROM_JSON}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-${WATCHTOWER_EXTRA_ARGS_FROM_JSON}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${WATCHTOWER_DEBUG_ENABLED_FROM_JSON}}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONFIG_INTERVAL_FROM_JSON:-${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}}}" # 如果本地和 config.json 都没有具体配置，才使用 config.json 的 default_interval
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-${WATCHTOWER_ENABLED_FROM_JSON}}"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-${DOCKER_COMPOSE_PROJECT_DIR_CRON_FROM_JSON}}"
    CRON_HOUR="${CRON_HOUR:-${CRON_HOUR_FROM_JSON:-${WT_CONF_DEFAULT_CRON_HOUR_FROM_JSON}}}" # 如果本地和 config.json 都没有具体配置，才使用 config.json 的 default_cron_hour
    CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-${CRON_TASK_ENABLED_FROM_JSON}}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-${WT_NOTIFY_ON_NO_UPDATES_FROM_JSON}}"
}

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
EOF
    chmod 600 "$CONFIG_FILE" || log_warn "⚠️ 无法设置配置文件权限。"
}


# --- Watchtower 模块所需的通用时间处理函数 (自包含在 Watchtower.sh 中) ---

# 解析 Watchtower 日志行中的时间戳
_parse_watchtower_timestamp_from_log_line() {
    local log_line="$1"
    local timestamp=""
    # 尝试匹配 time="YYYY-MM-DDTHH:MM:SS+ZZ:ZZ" 格式
    timestamp=$(echo "$log_line" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    # 尝试匹配 YYYY-MM-DDTHH:MM:SSZ 格式 (例如 Watchtower 1.7.1)
    timestamp=$(echo "$log_line" | grep -Eo '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    # 尝试匹配 "Scheduling first run: YYYY-MM-DD HH:MM:SS" 格式
    timestamp=$(echo "$log_line" | sed -nE 's/.*Scheduling first run: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}).*/\1/p' | head -n1 || true)
    if [ -n "$timestamp" ]; then
        echo "$timestamp"
        return 0
    fi
    echo ""
    return 1
}

# 将日期时间字符串转换为 Unix 时间戳 (epoch)
_date_to_epoch() {
    local dt="$1"
    [ -z "$dt" ] && echo "" && return 1 # 如果输入为空，返回空字符串并失败
    
    # 尝试使用 GNU date
    if date -d "now" >/dev/null 2>&1; then
        date -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'date -d' 解析 '$dt' 失败。"; echo ""; return 1)
    # 尝试使用 BSD date (通过 gdate 命令)
    elif command -v gdate >/dev/null 2>&1 && gdate -d "now" >/dev/null 2>&1; then
        gdate -d "$dt" +%s 2>/dev/null || (log_warn "⚠️ 'gdate -d' 解析 '$dt' 失败。"; echo ""; return 1)
    else
        log_warn "⚠️ 'date' 或 'gdate' 不支持。无法解析时间戳。"
        echo ""
        return 1
    fi
}

# 将秒数格式化为更易读的字符串 (例如 300s, 2h)
_format_seconds_to_human() {
    local seconds="$1"
    if ! echo "$seconds" | grep -qE '^[0-9]+$'; then
        echo "N/A"
        return 1
    fi
    
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}秒"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))分"
    elif [ "$seconds" -lt 86400 ]; then
        echo "$((seconds / 3600))时"
    else
        echo "$((seconds / 86400))天"
    fi
    return 0
}


send_notify() {
    local message="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        (curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "text=${message}" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" >/dev/null 2>&1) &
    fi
}

_start_watchtower_container_logic(){
    local wt_interval="$1"
    local mode_description="$2" # 例如 "一次性更新" 或 "Watchtower模式"

    local cmd_base=(docker run -e "TZ=${JB_TIMEZONE:-Asia/Shanghai}" -h "$(hostname)")
    local wt_image="containrrr/watchtower"
    local wt_args=("--cleanup")
    local container_names=()

    if [ "$mode_description" = "一次性更新" ]; then
        cmd_base+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        cmd_base+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "${wt_interval:-300}")
    fi
    cmd_base+=(-v /var/run/docker.sock:/var/run/docker.sock)

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        log_info "✅ 检测到 Telegram 配置，将为 Watchtower 启用通知。"
        # Shoutrrr URL for Telegram
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_URL=telegram://${TG_BOT_TOKEN}@telegram?channels=${TG_CHAT_ID}&ParseMode=Markdown")
        
        # 根据 WATCHTOWER_NOTIFY_ON_NO_UPDATES 设置 WATCHTOWER_REPORT_NO_UPDATES
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            cmd_base+=(-e WATCHTOWER_REPORT_NO_UPDATES=true)
            log_info "✅ 将启用 '无更新也通知' 模式。"
        else
            log_info "ℹ️ 将启用 '仅有更新才通知' 模式。"
        fi

        # Step 1: 定义原始 Go Template 模板字符串，使用 `cat <<'EOF'` 确保Bash不提前解析内部内容。
        # 内部的 `"` 和 `` ` `` 都是 Go Template 期望的字面量。
        local NOTIFICATION_TEMPLATE_RAW=$(cat <<'EOF'
🐳 *Docker 容器更新报告*

*服务器:* `{{.Host}}`

{{if .Updated}}✅ *扫描完成！共更新 {{len .Updated}} 个容器。*
{{range .Updated}}
- 🔄 *{{.Name}}*
  🖼️ *镜像:* `{{.ImageName}}`
  🆔 *ID:* `{{.OldImageID.Short}}` -> `{{.NewImageID.Short}}`{{end}}{{else if .Scanned}}✅ *扫描完成！未发现可更新的容器。*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{else if .Failed}}❌ *扫描失败！*
  (共扫描 {{.Scanned}} 个, 失败 {{.Failed}} 个){{end}}

⏰ *时间:* `{{.Time.Format "2006-01-02 15:04:05"}}`
EOF
)
        # Step 2: 对原始模板字符串进行 Bash 转义，仅转义 Bash 自身会误解的字符。
        # 主要是反引号 `，因为它们会被 Bash 误认为是命令替换。
        # 换行符和 Go Template 内部的 `"` 不需要额外转义，它们会通过 `"${VAR}"` 被正确传递。
        local ESCAPED_TEMPLATE_FOR_BASH=$(echo "$NOTIFICATION_TEMPLATE_RAW" | sed 's/`/\\`/g')
        
        # Step 3: 将转义后的模板字符串作为环境变量添加到 cmd_base 数组。
        # Bash 的数组和双引号会确保其作为单个参数传递，包括换行符。
        # Watchtower 的 Go Template 解析器会处理内部的 ` ` ` 和 `"`。
        cmd_base+=(-e "WATCHTOWER_NOTIFICATION_TEMPLATE=${ESCAPED_TEMPLATE_FOR_BASH}")
    fi

    if [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ]; then
        wt_args+=("--debug")
    fi
    if [ -n "$WATCHTOWER_EXTRA_ARGS" ]; then
        read -r -a extra_tokens <<<"$WATCHTOWER_EXTRA_ARGS"
        wt_args+=("${extra_tokens[@]}")
    fi

    local final_exclude_list=""
    local source_msg=""
    # 优先使用脚本内 WATCHTOWER_EXCLUDE_LIST，其次是 config.json 的 exclude_containers
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
        final_exclude_list="${WATCHTOWER_EXCLUDE_LIST}"
        source_msg="脚本内部"
    elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_JSON:-}" ]; then
        final_exclude_list="${WT_EXCLUDE_CONTAINERS_FROM_JSON}"
        source_msg="config.json (exclude_containers)"
    elif [ -n "${WATCHTOWER_EXCLUDE_LIST_FROM_JSON:-}" ]; then # 兼容旧的 config.json 字段
        final_exclude_list="${WATCHTOWER_EXCLUDE_LIST_FROM_FROM_JSON}"
        source_msg="config.json (exclude_list)"
    fi
    
    local included_containers
    if [ -n "$final_exclude_list" ]; then
        log_info "发现排除规则 (来源: ${source_msg}): ${final_exclude_list}"
        local exclude_pattern
        exclude_pattern=$(echo "$final_exclude_list" | sed 's/,/\\|/g')
        included_containers=$(docker ps --format '{{.Names}}' | grep -vE "^(${exclude_pattern}|watchtower)$" || true)
        if [ -n "$included_containers" ]; then
            log_info "计算后的监控范围: ${included_containers}"
            read -r -a container_names <<< "$included_containers"
        else
            log_warn "排除规则导致监控列表为空！"
        fi
    else
        log_info "未发现排除规则，Watchtower 将监控所有容器。"
    fi

    echo "⬇️ 正在拉取 Watchtower 镜像..."
    set +e; docker pull "$wt_image" >/dev/null 2>&1 || true; set -e
    
    _print_header "正在启动 $mode_description"
    local final_cmd=("${cmd_base[@]}" "$wt_image" "${wt_args[@]}" "${container_names[@]}")
    
    # 使用 printf %q 对每个参数进行 Bash 引用，然后通过 eval 执行。
    # 这是最健壮的方式，可以处理所有特殊字符和多行字符串。
    local final_cmd_str=""
    for arg in "${final_cmd[@]}"; do
        final_cmd_str+=" $(printf %q "$arg")"
    done
    
    echo -e "${CYAN}执行命令: ${final_cmd_str}${NC}"
    
    set +e; eval "$final_cmd_str"; local rc=$?; set -e
    
    if [ "$mode_description" = "一次性更新" ]; then
        if [ $rc -eq 0 ]; then echo -e "${GREEN}✅ $mode_description 完成。${NC}"; else echo -e "${RED}❌ $mode_description 失败。${NC}"; fi
        return $rc
    else
        sleep 3
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then echo -e "${GREEN}✅ $mode_description 启动成功。${NC}"; else echo -e "${RED}❌ $mode_description 启动失败。${NC}"; fi
        return 0
    fi
}

_rebuild_watchtower() {
    log_info "正在重建 Watchtower 容器..."
    set +e
    docker rm -f watchtower &>/dev/null
    set -e
    
    local interval="${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}}"
    if ! _start_watchtower_container_logic "$interval" "Watchtower模式"; then
        log_err "Watchtower 重建失败！"
        WATCHTOWER_ENABLED="false"
        save_config
        return 1
    fi
    send_notify "🔄 Watchtower 服务已重建并启动。"
    log_success "Watchtower 重建成功。"
}

_prompt_and_rebuild_watchtower_if_needed() {
    if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        if confirm_action "配置已更新，是否立即重建 Watchtower 以应用新配置?"; then
            _rebuild_watchtower
        else
            log_warn "操作已取消。新配置将在下次手动重建 Watchtower 后生效。"
        fi
    fi
}

_configure_telegram() {
    read -r -p "请输入 Bot Token (当前: ...${TG_BOT_TOKEN: -5}): " TG_BOT_TOKEN_INPUT
    TG_BOT_TOKEN="${TG_BOT_TOKEN_INPUT:-$TG_BOT_TOKEN}"
    read -r -p "请输入 Chat ID (当前: ${TG_CHAT_ID}): " TG_CHAT_ID_INPUT
    TG_CHAT_ID="${TG_CHAT_ID_INPUT:-$TG_CHAT_ID}"
    read -r -p "是否在没有容器更新时也发送 Telegram 通知? (y/N, 当前: ${WATCHTOWER_NOTIFY_ON_NO_UPDATES}): " notify_on_no_updates_choice
    if echo "$notify_on_no_updates_choice" | grep -qE '^[Yy]$'; then
        WATCHTOWER_NOTIFY_ON_NO_UPDATES="true"
    else
        WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"
    fi
    log_info "Telegram 配置已更新。"
}

_configure_email() {
    read -r -p "请输入接收邮箱 (当前: ${EMAIL_TO}): " EMAIL_TO_INPUT
    EMAIL_TO="${EMAIL_TO_INPUT:-$EMAIL_TO}"
    log_info "Email 配置已更新。"
}

notification_menu() {
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local tg_status="${RED}未配置${NC}"; if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then tg_status="${GREEN}已配置${NC}"; fi
        local email_status="${RED}未配置${NC}"; if [ -n "$EMAIL_TO" ]; then email_status="${GREEN}已配置${NC}"; fi
        local notify_on_no_updates_status="${CYAN}否${NC}"; if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then notify_on_no_updates_status="${GREEN}是${NC}"; fi

        local -a items_array=(
            "  1. › 配置 Telegram  ($tg_status, 无更新也通知: $notify_on_no_updates_status)"
            "  2. › 配置 Email      ($email_status)"
            "  3. › 发送测试通知"
            "  4. › 清空所有通知配置"
        )
        _render_menu "⚙️ 通知配置 ⚙️" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1) _configure_telegram; save_config; _prompt_and_rebuild_watchtower_if_needed; press_enter_to_continue ;;
            2) _configure_email; save_config; press_enter_to_continue ;;
            3)
                if [ -z "$TG_BOT_TOKEN" ] && [ -z "$EMAIL_TO" ]; then
                    log_warn "请先配置至少一种通知方式。"
                else
                    log_info "正在发送测试..."
                    send_notify "这是一条来自 Docker 助手 ${SCRIPT_VERSION} 的*测试消息*。"
                    log_info "测试通知已发送。请检查你的 Telegram 或邮箱。"
                fi
                press_enter_to_continue
                ;;
            4)
                if confirm_action "确定要清空所有通知配置吗?"; then
                    TG_BOT_TOKEN=""
                    TG_CHAT_ID=""
                    EMAIL_TO=""
                    WATCHTOWER_NOTIFY_ON_NO_UPDATES="false"
                    save_config
                    log_info "所有通知配置已清空。"
                    _prompt_and_rebuild_watchtower_if_needed
                else
                    log_info "操作已取消。"
                fi
                press_enter_to_continue
                ;;
            "") return ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

show_container_info() { 
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a content_lines_array=()
        local header_line; header_line=$(printf "%-5s %-25s %-45s %-20s" "编号" "名称" "镜像" "状态")
        content_lines_array+=("$header_line")
        local -a containers=()
        local i=1
        while IFS='|' read -r name image status; do 
            containers+=("$name")
            local status_colored="$status"
            if echo "$status" | grep -qE '^Up'; then status_colored="${GREEN}运行中${NC}"
            elif echo "$status" | grep -qE '^Exited|Created'; then status_colored="${RED}已退出${NC}"
            else status_colored="${YELLOW}${status}${NC}"; fi
            content_lines_array+=("$(printf "%-5s %-25.25s %-45.45s %b" "$i" "$name" "$image" "$status_colored")")
            i=$((i + 1))
        done < <(docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        content_lines_array+=("")
        content_lines_array+=(" a. 全部启动 (Start All)   s. 全部停止 (Stop All)")
        _render_menu "📋 容器管理 📋" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号管理, 'a'/'s' 批量操作, 或按 Enter 返回: " choice
        case "$choice" in 
            "") return ;;
            a|A)
                if confirm_action "确定要启动所有已停止的容器吗?"; then
                    log_info "正在启动..."
                    local stopped_containers; stopped_containers=$(docker ps -aq -f status=exited)
                    if [ -n "$stopped_containers" ]; then docker start $stopped_containers &>/dev/null || true; fi
                    log_success "操作完成。"
                    press_enter_to_continue
                else
                    log_info "操作已取消。"
                fi
                ;; 
            s|S)
                if confirm_action "警告: 确定要停止所有正在运行的容器吗?"; then
                    log_info "正在停止..."
                    local running_containers; running_containers=$(docker ps -q)
                    if [ -n "$running_containers" ]; then docker stop $running_containers &>/dev/null || true; fi
                    log_success "操作完成。"
                    press_enter_to_continue
                else
                    log_info "操作已取消。"
                fi
                ;; 
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
                    log_warn "无效输入或编号超范围。"
                    sleep 1
                    continue
                fi
                local selected_container="${containers[$((choice - 1))]}"
                if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
                local -a action_items_array=(
                    "  1. › 查看日志 (Logs)"
                    "  2. › 重启 (Restart)"
                    "  3. › 停止 (Stop)"
                    "  4. › 删除 (Remove)"
                    "  5. › 查看详情 (Inspect)"
                    "  6. › 进入容器 (Exec)"
                )
                _render_menu "操作容器: ${selected_container}" "${action_items_array[@]}"
                read -r -p " └──> 请选择, 或按 Enter 返回: " action
                case "$action" in 
                    1)
                        echo -e "${YELLOW}日志 (Ctrl+C 停止)...${NC}"
                        trap '' INT # 临时禁用中断
                        docker logs -f --tail 100 "$selected_container" || true
                        trap 'echo -e "\n操作被中断。"; exit 10' INT # 恢复中断处理
                        press_enter_to_continue
                        ;;
                    2)
                        echo "重启中..."
                        if docker restart "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                        sleep 1
                        ;; 
                    3)
                        echo "停止中..."
                        if docker stop "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                        sleep 1
                        ;; 
                    4)
                        if confirm_action "警告: 这将永久删除 '${selected_container}'！"; then
                            echo "删除中..."
                            if docker rm -f "$selected_container"; then echo -e "${GREEN}✅ 成功。${NC}"; else echo -e "${RED}❌ 失败。${NC}"; fi
                            sleep 1
                        else
                            echo "已取消。"
                        fi
                        ;; 
                    5)
                        _print_header "容器详情: ${selected_container}"
                        (docker inspect "$selected_container" | jq '.' 2>/dev/null || docker inspect "$selected_container") | less -R
                        ;; 
                    6)
                        if [ "$(docker inspect --format '{{.State.Status}}' "$selected_container")" != "running" ]; then
                            log_warn "容器未在运行，无法进入。"
                        else
                            log_info "尝试进入容器... (输入 'exit' 退出)"
                            docker exec -it "$selected_container" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true
                        fi
                        press_enter_to_continue
                        ;; 
                    *) ;; 
                esac
                ;;
        esac
    done
}

configure_exclusion_list() {
    declare -A excluded_map
    # 优先使用脚本内 WATCHTOWER_EXCLUDE_LIST，其次是 config.json 的 exclude_containers
    local initial_exclude_list=""
    if [ -n "$WATCHTOWER_EXCLUDE_LIST" ]; then
        initial_exclude_list="$WATCHTOWER_EXCLUDE_LIST"
    elif [ -n "$WT_EXCLUDE_CONTAINERS_FROM_JSON" ]; then
        initial_exclude_list="$WT_EXCLUDE_CONTAINERS_FROM_JSON"
    fi

    if [ -n "$initial_exclude_list" ]; then
        local IFS=,
        for container_name in $initial_exclude_list; do
            container_name=$(echo "$container_name" | xargs)
            if [ -n "$container_name" ]; then
                excluded_map["$container_name"]=1
            fi
        done
        unset IFS
    fi

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR:-}" = "true" ]; then clear; fi
        local -a all_containers_array=()
        while IFS= read -r line; do
            all_containers_array+=("$line")
        done < <(docker ps --format '{{.Names}}')

        local -a items_array=()
        local i=0
        while [ $i -lt ${#all_containers_array[@]} ]; do
            local container="${all_containers_array[$i]}"
            local is_excluded=" "
            if [ -n "${excluded_map[$container]+_}" ]; then
                is_excluded="✔"
            fi
            items_array+=("  $((i + 1)). [${GREEN}${is_excluded}${NC}] $container")
            i=$((i + 1))
        done
        items_array+=("")
        local current_excluded_display=""
        if [ ${#excluded_map[@]} -gt 0 ]; then
            current_excluded_display=$(IFS=,; echo "${!excluded_map[*]:-}")
        fi
        items_array+=("${CYAN}当前排除 (脚本内): ${current_excluded_display:-(空, 将使用 config.json 的 exclude_containers)}${NC}")
        items_array+=("${CYAN}备用排除 (config.json 的 exclude_containers): ${WT_EXCLUDE_CONTAINERS_FROM_JSON:-无}${NC}")

        _render_menu "配置排除列表 (高优先级)" "${items_array[@]}"
        read -r -p " └──> 输入数字(可用','分隔)切换, 'c'确认, [回车]使用备用配置: " choice

        case "$choice" in
            c|C) break ;;
            "")
                excluded_map=()
                log_info "已清空脚本内配置，将使用 config.json 的备用配置。"
                sleep 1.5
                break
                ;;
            *)
                local clean_choice; clean_choice=$(echo "$choice" | tr -d ' ')
                IFS=',' read -r -a selected_indices <<< "$clean_choice"
                local has_invalid_input=false
                for index in "${selected_indices[@]}"; do
                    if [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -ge 1 ] && [ "$index" -le ${#all_containers_array[@]} ]; then
                        local target_container="${all_containers_array[$((index - 1))]}"
                        if [ -n "${excluded_map[$target_container]+_}" ]; then
                            unset excluded_map["$target_container"]
                        else
                            excluded_map["$target_container"]=1
                        fi
                    elif [ -n "$index" ]; then
                        has_invalid_input=true
                    fi
                done
                if [ "$has_invalid_input" = "true" ]; then
                    log_warn "输入 '${choice}' 中包含无效选项，已忽略。"
                    sleep 1.5
                fi
                ;;
        esac
    done
    local final_excluded_list=""
    if [ ${#excluded_map[@]} -gt 0 ]; then
        final_excluded_list=$(IFS=,; echo "${!excluded_map[*]:-}")
    fi
    WATCHTOWER_EXCLUDE_LIST="$final_excluded_list"
}

configure_watchtower(){
    _print_header "🚀 Watchtower 配置"
    local WT_INTERVAL_TMP="$(_prompt_for_interval "${WATCHTOWER_CONFIG_INTERVAL:-${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}}" "请输入检查间隔 (config.json 默认: $(_format_seconds_to_human "${WT_CONF_DEFAULT_INTERVAL_FROM_JSON}"))")"
    log_info "检查间隔已设置为: $(_format_seconds_to_human "$WT_INTERVAL_TMP")。"
    sleep 1

    configure_exclusion_list

    read -r -p "是否配置额外参数？(y/N, 当前: ${WATCHTOWER_EXTRA_ARGS:-无}): " extra_args_choice
    local temp_extra_args="${WATCHTOWER_EXTRA_ARGS:-}"
    if echo "$extra_args_choice" | grep -qE '^[Yy]$'; then
        read -r -p "请输入额外参数: " temp_extra_args
    fi

    read -r -p "是否启用调试模式? (y/N, 当前: ${WATCHTOWER_DEBUG_ENABLED}): " debug_choice
    local temp_debug_enabled="false"
    if echo "$debug_choice" | grep -qE '^[Yy]$'; then
        temp_debug_enabled="true"
    fi

    local final_exclude_list_display
    # 显示时优先脚本内配置，其次 config.json 的 exclude_containers
    if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
        final_exclude_list_display="${WATCHTOWER_EXCLUDE_LIST}"
        source_msg="脚本"
    elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_JSON:-}" ]; then
        final_exclude_list_display="${WT_EXCLUDE_CONTAINERS_FROM_JSON}"
        source_msg="config.json (exclude_containers)"
    else
        final_exclude_list_display="无"
        source_msg=""
    fi

    local -a confirm_array=(
        " 检查间隔: $(_format_seconds_to_human "$WT_INTERVAL_TMP")"
        " 排除列表 (${source_msg}): ${final_exclude_list_display//,/, }"
        " 额外参数: ${temp_extra_args:-无}"
        " 调试模式: $temp_debug_enabled"
    )
    _render_menu "配置确认" "${confirm_array[@]}"
    read -r -p "确认应用此配置吗? ([y/回车]继续, [n]取消): " confirm_choice
    if echo "$confirm_choice" | grep -qE '^[Nn]$'; then
        log_info "操作已取消。"
        return 10
    fi

    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL_TMP"
    WATCHTOWER_EXTRA_ARGS="$temp_extra_args"
    WATCHTOWER_DEBUG_ENABLED="$temp_debug_enabled"
    WATCHTOWER_ENABLED="true"
    save_config
    
    _rebuild_watchtower || return 1
    return 0
}

manage_tasks(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local -a items_array=(
            "  1. › 停止/移除 Watchtower"
            "  2. › 重建 Watchtower"
        )
        _render_menu "⚙️ 任务管理 ⚙️" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 返回: " choice
        case "$choice" in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    if confirm_action "确定移除 Watchtower？"; then
                        set +e
                        docker rm -f watchtower &>/dev/null
                        set -e
                        WATCHTOWER_ENABLED="false"
                        save_config
                        send_notify "🗑️ Watchtower 已从您的服务器移除。"
                        echo -e "${GREEN}✅ 已移除。${NC}"
                    fi
                else
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    _rebuild_watchtower
                else
                    echo -e "${YELLOW}ℹ️ Watchtower 未运行。${NC}"
                fi
                press_enter_to_continue
                ;;
            *)
                if [ -z "$choice" ]; then return; else log_warn "无效选项"; sleep 1; fi
                ;;
        esac
    done
}

get_watchtower_all_raw_logs(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 1
    fi
    docker logs --tail 2000 watchtower 2>&1 || true
}

_extract_interval_from_cmd(){
    local cmd_json="$1"
    local interval=""
    if command -v jq >/dev/null 2>&1; then
        interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
    else
        local tokens; read -r -a tokens <<< "$(echo "$cmd_json" | tr -d '[],"')"
        local prev=""
        for t in "${tokens[@]}"; do
            if [ "$prev" = "--interval" ]; then
                interval="$t"
                break
            fi # <--- 修正了这里！
            prev="$t"
        done
    fi
    interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g')
    if [ -z "$interval" ]; then
        echo ""
    else
        echo "$interval"
    fi
}

get_watchtower_inspect_summary(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 2
    fi
    local cmd
    cmd=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    _extract_interval_from_cmd "$cmd" 2>/dev/null || true
}

get_last_session_time(){
    local logs
    logs=$(get_watchtower_all_raw_logs 2>/dev/null || true)
    if [ -z "$logs" ]; then echo ""; return 1; fi
    local line ts
    if echo "$logs" | grep -qiE "permission denied|cannot connect"; then
        echo -e "${RED}错误:权限不足${NC}"
        return 1
    fi
    line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)
    if [ -n "$line" ]; then
        ts=$(_parse_watchtower_timestamp_from_log_line "$line")
        if [ -n "$ts" ]; then
            echo "$ts"
            return 0
        fi
    fi
    echo ""
    return 1
}

get_updates_last_24h(){
    if ! docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo ""
        return 1
    fi
    local since
    if date -d "24 hours ago" >/dev/null 2>&1; then
        since=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    elif command -v gdate >/dev/null 2>&1; then
        since=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)
    fi
    local raw_logs
    if [ -n "$since" ]; then
        raw_logs=$(docker logs --since "$since" watchtower 2>&1 || true)
    fi
    if [ -z "$raw_logs" ]; then
        raw_logs=$(docker logs --tail 200 watchtower 2>&1 || true)
    fi
    # 过滤 Watchtower 日志，只显示关键事件和错误
    echo "$raw_logs" | grep -E "Found new|Stopping|Creating|Session done|No new|Scheduling first run|Starting Watchtower|unauthorized|failed|error|fatal|permission denied|cannot connect|Could not do a head request|Notification template error|Could not use configured notification template" || true
}

_format_and_highlight_log_line(){
    local line="$1"
    local ts
    ts=$(_parse_watchtower_timestamp_from_log_line "$line")
    case "$line" in
        *"Session done"*)
            local f s u c
            f=$(echo "$line" | sed -n 's/.*Failed=\([0-9]*\).*/\1/p')
            s=$(echo "$line" | sed -n 's/.*Scanned=\([0-9]*\).*/\1/p')
            u=$(echo "$line" | sed -n 's/.*Updated=\([0-9]*\).*/\1/p')
            c="$GREEN"
            if [ "${f:-0}" -gt 0 ]; then c="$YELLOW"; fi
            printf "%s %b%s%b\n" "$ts" "$c" "✅ 扫描: ${s:-?}, 更新: ${u:-?}, 失败: ${f:-?}" "$NC"
            ;;
        *"Found new"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🆕 发现新镜像: $(echo "$line" | sed -n 's/.*Found new \(.*\) image .*/\1/p')" "$NC"
            ;;
        *"Stopping "*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🛑 停止旧容器: $(echo "$line" | sed -n 's/.*Stopping \/\([^ ]*\).*/\/\1/p')" "$NC"
            ;;
        *"Creating "*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🚀 创建新容器: $(echo "$line" | sed -n 's/.*Creating \/\(.*\).*/\/\1/p')" "$NC"
            ;;
        *"No new images found"*)
            printf "%s %b%s%b\n" "$ts" "$CYAN" "ℹ️ 未发现新镜像。" "$NC"
            ;;
        *"Scheduling first run"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "🕒 首次运行已调度" "$NC"
            ;;
        *"Starting Watchtower"*)
            printf "%s %b%s%b\n" "$ts" "$GREEN" "✨ Watchtower 已启动" "$NC"
            ;;
        *)
            if echo "$line" | grep -qiE "\b(unauthorized|failed|error|fatal)\b|permission denied|cannot connect|Could not do a head request|Notification template error|Could not use configured notification template"; then
                local msg
                msg=$(echo "$line" | sed -n 's/.*error="\([^"]*\)".*/\1/p' | tr -d '\n')
                if [ -z "$msg" ] && [[ "$line" == *"msg="* ]]; then # 优先从msg=中提取，如果没有，则尝试从error=中提取
                    msg=$(echo "$line" | sed -n 's/.*msg="\([^"]*\)".*/\1/p' | tr -d '\n')
                fi
                if [ -z "$msg" ]; then
                    msg=$(echo "$line" | sed -E 's/.*(level=(error|warn|info|fatal)|time="[^"]*")\s*//g' | tr -d '\n')
                fi
                local full_msg="${msg:-$line}"
                local truncated_msg
                if [ ${#full_msg} -gt 50 ]; then
                    truncated_msg="${full_msg:0:47}..."
                else
                    truncated_msg="$full_msg"
                fi
                printf "%s %b%s%b\n" "$ts" "$RED" "❌ 错误: ${truncated_msg}" "$NC"
            fi
            ;;
    esac
}

_get_watchtower_remaining_time(){
    local int="$1"
    local logs="$2"
    if [ -z "$int" ] || [ -z "$logs" ]; then echo -e "${YELLOW}N/A${NC}"; return; fi

    local log_line ts epoch rem
    log_line=$(echo "$logs" | grep -E "Session done|Scheduling first run|Starting Watchtower" | tail -n 1 || true)

    if [ -z "$log_line" ]; then echo -e "${YELLOW}等待首次扫描...${NC}"; return; fi

    ts=$(_parse_watchtower_timestamp_from_log_line "$log_line")
    epoch=$(_date_to_epoch "$ts")

    if [ "$epoch" -gt 0 ]; then
        if [[ "$log_line" == *"Session done"* ]]; then
            rem=$((int - ($(date +%s) - epoch) ))
        elif [[ "$log_line" == *"Scheduling first run"* ]]; then
            # 如果是首次调度，计算距离调度时间的剩余时间 (未来时间 - 当前时间)
            rem=$((epoch - $(date +%s)))
        elif [[ "$log_line" == *"Starting Watchtower"* ]]; then
            # 如果 Watchtower 刚刚启动，但还没有调度第一次运行，显示等待
            echo -e "${YELLOW}等待首次调度...${NC}"; return;
        fi

        if [ "$rem" -gt 0 ]; then
            printf "%b%02d时%02d分%02d秒%b" "$GREEN" $((rem / 3600)) $(((rem % 3600) / 60)) $((rem % 60)) "$NC"
        else
            local overdue=$(( -rem ))
            printf "%b已逾期 %02d分%02d秒, 正在等待...%b" "$YELLOW" $((overdue / 60)) $((overdue % 60)) "$NC"
        fi
    else
        echo -e "${YELLOW}计算中...${NC}"
    fi
}


show_watchtower_details(){
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        local title="📊 Watchtower 详情与管理 📊"
        local interval raw_logs countdown updates

        interval=$(get_watchtower_inspect_summary)
        raw_logs=$(get_watchtower_all_raw_logs)
        countdown=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")

        local -a content_lines_array=(
            "上次活动: $(get_last_session_time || echo 'N/A')"
            "下次检查: $countdown"
            ""
            "最近 24h 摘要："
        )
        updates=$(get_updates_last_24h || true)
        if [ -z "$updates" ]; then
            content_lines_array+=("  无日志事件。")
        else
            while IFS= read -r line; do
                content_lines_array+=("  $(_format_and_highlight_log_line "$line")")
            done <<< "$updates"
        fi

        _render_menu "$title" "${content_lines_array[@]}"
        read -r -p " └──> [1] 实时日志, [2] 容器管理, [3] 触 发 扫 描 , [Enter] 返 回 : " pick
        case "$pick" in
            1)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    echo -e "\n按 Ctrl+C 停止..."
                    trap '' INT # 临时禁用中断
                    docker logs --tail 200 -f watchtower || true
                    trap 'echo -e "\n操作被中断。"; exit 10' INT # 恢复中断处理
                    press_enter_to_continue
                else
                    echo -e "\n${RED}Watchtower 未运行。${NC}"
                    press_enter_to_continue
                fi
                ;;
            2) show_container_info ;;
            3)
                if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                    log_info "正在发送 SIGHUP 信号以触发扫描..."
                    if docker kill -s SIGHUP watchtower; then
                        log_success "信号已发送！请在下方查看实时日志..."
                        echo -e "按 Ctrl+C 停止..."; sleep 2
                        trap '' INT # 临时禁用中断
                        docker logs -f --tail 100 watchtower || true
                        trap 'echo -e "\n操作被中断。"; exit 10' INT # 恢复中断处理
                    else
                        log_err "发送信号失败！"
                    fi
                else
                    log_warn "Watchtower 未运行，无法触发扫描。"
                fi
                press_enter_to_continue
                ;;
            *) return ;;
        esac
    done
}

run_watchtower_once(){
    if ! confirm_action "确定要运行一次 Watchtower 来更新所有容器吗?"; then
        log_info "操作已取消。"
        return 1
    fi
    echo -e "${YELLOW}🆕 运行一次 Watchtower${NC}"
    if ! _start_watchtower_container_logic "" "一次性更新"; then
        return 1
    fi
    return 0
}

view_and_edit_config(){
    local -a config_items
    config_items=(
        "TG Token|TG_BOT_TOKEN|string"
        "TG Chat ID|TG_CHAT_ID|string"
        "Email|EMAIL_TO|string"
        "排除列表|WATCHTOWER_EXCLUDE_LIST|string_list" # string_list 用于显示多个值
        "额外参数|WATCHTOWER_EXTRA_ARGS|string"
        "调试模式|WATCHTOWER_DEBUG_ENABLED|bool"
        "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval"
        "Watchtower 启用状态|WATCHTOWER_ENABLED|bool"
        "Cron 执行小时|CRON_HOUR|number_range|0-23"
        "Cron 项目目录|DOCKER_COMPOSE_PROJECT_DIR_CRON|string"
        "Cron 任务启用状态|CRON_TASK_ENABLED|bool"
        "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool" # 新增
    )

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        load_config # 每次进入菜单都重新加载配置，确保最新
        local -a content_lines_array=()
        local i
        for i in "${!config_items[@]}"; do
            local item="${config_items[$i]}"
            local label; label=$(echo "$item" | cut -d'|' -f1)
            local var_name; var_name=$(echo "$item" | cut -d'|' -f2)
            local type; type=$(echo "$item" | cut -d'|' -f3)
            local extra; extra=$(echo "$item" | cut -d'|' -f4)
            local current_value="${!var_name}"
            local display_text=""
            local color="${CYAN}"

            case "$type" in
                string)
                    if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi
                    ;;
                string_list) # 针对排除列表的显示
                    if [ -n "$current_value" ]; then color="${YELLOW}"; display_text="${current_value//,/, }"; else color="${CYAN}"; display_text="无"; fi
                    ;;
                bool)
                    if [ "$current_value" = "true" ]; then color="${GREEN}"; display_text="是"; else color="${CYAN}"; display_text="否"; fi
                    ;;
                interval)
                    display_text=$(_format_seconds_to_human "$current_value")
                    if [ "$display_text" != "N/A" ] && [ -n "$current_value" ]; then color="${GREEN}"; else color="${RED}"; display_text="未设置"; fi
                    ;;
                number_range)
                    if [ -n "$current_value" ]; then color="${GREEN}"; display_text="$current_value"; else color="${RED}"; display_text="未设置"; fi
                    ;;
            esac
            content_lines_array+=("$(printf " %2d. %-20s: %b%s%b" "$((i + 1))" "$label" "$color" "$display_text" "$NC")")
        done

        _render_menu "⚙️ 配置查看与编辑 (底层) ⚙️" "${content_lines_array[@]}"
        read -r -p " └──> 输入编号编辑, 或按 Enter 返回: " choice
        if [ -z "$choice" ]; then return; fi

        if ! echo "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#config_items[@]}" ]; then
            log_warn "无效选项。"
            sleep 1
            continue
        fi

        local selected_index=$((choice - 1))
        local selected_item="${config_items[$selected_index]}"
        local label; label=$(echo "$selected_item" | cut -d'|' -f1)
        local var_name; var_name=$(echo "$selected_item" | cut -d'|' -f2)
        local type; type=$(echo "$selected_item" | cut -d'|' -f3)
        local extra; extra=$(echo "$selected_item" | cut -d'|' -f4)
        local current_value="${!var_name}"
        local new_value=""

        case "$type" in
            string|string_list) # string_list 也按 string 编辑
                read -r -p "请输入新的 '$label' (当前: $current_value): " new_value
                declare "$var_name"="${new_value:-$current_value}"
                ;;
            bool)
                read -r -p "是否启用 '$label'? (y/N, 当前: $current_value): " new_value
                if echo "$new_value" | grep -qE '^[Yy]$'; then declare "$var_name"="true"; else declare "$var_name"="false"; fi
                ;;
            interval)
                new_value=$(_prompt_for_interval "${current_value:-300}" "为 '$label' 设置新间隔")
                if [ -n "$new_value" ]; then declare "$var_name"="$new_value"; fi
                ;;
            number_range)
                local min; min=$(echo "$extra" | cut -d'-' -f1)
                local max; max=$(echo "$extra" | cut -d'-' -f2)
                while true; do
                    read -r -p "请输入新的 '$label' (${min}-${max}, 当前: $current_value): " new_value
                    if [ -z "$new_value" ]; then break; fi # 允许空值以保留当前值
                    if echo "$new_value" | grep -qE '^[0-9]+$' && [ "$new_value" -ge "$min" ] && [ "$new_value" -le "$max" ]; then
                        declare "$var_name"="$new_value"
                        break
                    else
                        log_warn "无效输入, 请输入 ${min} 到 ${max} 之间的数字。"
                    fi
                done
                ;;
        esac
        save_config
        log_info "'$label' 已更新。"
        sleep 1
    done
}

main_menu(){
    # 在进入 Watchtower 模块主菜单时，打印一次欢迎和版本信息
    log_info "欢迎使用 Watchtower 模块 ${SCRIPT_VERSION}"

    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        load_config # 每次进入菜单都重新加载配置，确保最新

        local STATUS_RAW="未运行"; if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then STATUS_RAW="已启动"; fi
        local STATUS_COLOR; if [ "$STATUS_RAW" = "已启动" ]; then STATUS_COLOR="${GREEN}已启动${NC}"; else STATUS_COLOR="${RED}未运行${NC}"; fi
        
        local interval=""; local raw_logs="";
        if [ "$STATUS_RAW" = "已启动" ]; then
            interval=$(get_watchtower_inspect_summary)
            raw_logs=$(get_watchtower_all_raw_logs)
        fi
        
        local COUNTDOWN=$(_get_watchtower_remaining_time "${interval}" "${raw_logs}")
        local TOTAL=$(docker ps -a --format '{{.ID}}' | wc -l)
        local RUNNING=$(docker ps --format '{{.ID}}' | wc -l)
        local STOPPED=$((TOTAL - RUNNING))

        local FINAL_EXCLUDE_LIST=""; local FINAL_EXCLUDE_SOURCE="";
        # 优先使用脚本内 WATCHTOWER_EXCLUDE_LIST，其次是 config.json 的 exclude_containers
        if [ -n "${WATCHTOWER_EXCLUDE_LIST:-}" ]; then
            FINAL_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
            FINAL_EXCLUDE_SOURCE="脚本"
        elif [ -n "${WT_EXCLUDE_CONTAINERS_FROM_JSON:-}" ]; then
            FINAL_EXCLUDE_LIST="${WT_EXCLUDE_CONTAINERS_FROM_JSON}"
            FINAL_EXCLUDE_SOURCE="config.json (exclude_containers)"
        else
            FINAL_EXCLUDE_LIST="无"
            FINAL_EXCLUDE_SOURCE=""
        fi

        local NOTIFY_STATUS="";
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then NOTIFY_STATUS="Telegram"; fi
        if [ -n "$EMAIL_TO" ]; then if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS, Email"; else NOTIFY_STATUS="Email"; fi; fi
        if [ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" = "true" ]; then
            if [ -n "$NOTIFY_STATUS" ]; then NOTIFY_STATUS="$NOTIFY_STATUS (无更新也通知)"; else NOTIFY_STATUS="(无更新也通知)"; fi
        fi

        local header_text="Watchtower 管理" # 菜单标题不带版本号
        
        local -a content_array=(
            " 🕝 Watchtower 状态: ${STATUS_COLOR} (名称排除模式)"
            " ⏳ 下次检查: ${COUNTDOWN}"
            " 📦 容器概览: 总计 $TOTAL (${GREEN}运行中 ${RUNNING}${NC}, ${RED}已停止 ${STOPPED}${NC})"
        )
        if [ "$FINAL_EXCLUDE_LIST" != "无" ]; then content_array+=(" 🚫 排 除 列 表 : ${YELLOW}${FINAL_EXCLUDE_LIST//,/, }${NC} (${CYAN}${FINAL_EXCLUDE_SOURCE}${NC})"); fi
        if [ -n "$NOTIFY_STATUS" ]; then content_array+=(" 🔔 通 知 已 启 用 : ${GREEN}${NOTIFY_STATUS}${NC}"); fi
        
        content_array+=(""
            "主菜单："
            "  1. › 配 置  Watchtower"
            "  2. › 配 置 通 知"
            "  3. › 任 务 管 理"
            "  4. › 查 看 /编 辑 配 置  (底 层 )"
            "  5. › 手 动 更 新 所 有 容 器"
            "  6. › 详 情 与 管 理"
        )
        
        _render_menu "$header_text" "${content_array[@]}"
        read -r -p " └──> 输入选项 [1-6] 或按 Enter 返回: " choice
        case "$choice" in
          1) configure_watchtower || true; press_enter_to_continue ;;
          2) notification_menu ;;
          3) manage_tasks ;;
          4) view_and_edit_config ;;
          5) run_watchtower_once; press_enter_to_continue ;;
          6) show_watchtower_details ;;
          "") exit 10 ;; # 返回主脚本菜单
          *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done # 循环回到主菜单
}

main(){ 
    trap 'echo -e "\n操作被中断。"; exit 10' INT
    if [ "${1:-}" = "--run-once" ]; then run_watchtower_once; exit $?; fi
    main_menu
    exit 10 # 退出脚本
}

main "$@"
WATCHTOWER_EOF
)
    _update_module_files "Watchtower" "$watchtower_script_content"
    log_success "Watchtower 模块更新完成。"
}

# Watchtower 模块的卸载逻辑
_uninstall_watchtower_module_logic() {
    log_info "正在卸载 Watchtower 模块..."
    if confirm_action "确定要停止并移除 Watchtower 容器吗?"; then
        set +e
        docker rm -f watchtower &>/dev/null
        set -e
        log_success "Watchtower 容器已停止并移除。"
    else
        log_info "已取消移除 Watchtower 容器。"
    fi
    _uninstall_module_files "Watchtower"
    _set_config_value ".modules.watchtower.enabled" "false"
    save_config_json
    # 清理本地配置文件
    if [ -f "/etc/docker-auto-update.conf" ]; then
        sudo rm -f "/etc/docker-auto-update.conf"
        log_info "已移除 Watchtower 本地配置文件 /etc/docker-auto-update.conf"
    fi
    if [ -f "$HOME/.docker-auto-update.conf" ]; then
        rm -f "$HOME/.docker-auto-update.conf"
        log_info "已移除 Watchtower 本地配置文件 $HOME/.docker-auto-update.conf"
    fi
    log_success "Watchtower 模块卸载完成。"
}

# --- 核心功能：运行模块脚本，并传递配置 ---
_run_module() {
    local module_name="$1"
    local module_script="$MODULES_DIR/$module_name.sh"

    if [ ! -f "$module_script" ]; then
        log_err "模块脚本 $module_script 不存在。"
        return 1
    fi

    log_info "正在运行模块: ${module_name}..."

    # 从 config.json 中读取模块的配置，并导出为环境变量
    local module_config_path="modules.${module_name}.conf"
    local config_json_content_local="$CONFIG_JSON_CONTENT" # 使用局部变量，避免修改全局
    local uppercase_module_name=$(echo "$module_name" | tr '[:lower:]' '[:upper:]')
    local config_keys
    config_keys=$(echo "$config_json_content_local" | jq -r ".${module_config_path} | keys[]" 2>/dev/null || true)

    local -a exported_env_vars=()
    if [ -n "$config_keys" ]; then
        for key in $config_keys; do
            local value
            value=$(echo "$config_json_content_local" | jq -r ".${module_config_path}.${key}" 2>/dev/null || true)
            # 转换为大写，并替换特殊字符为下划线
            local env_key="JB_${uppercase_module_name}_CONF_$(echo "$key" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_]/_/g')"
            export "$env_key"="$value"
            exported_env_vars+=("$env_key")
            # log_debug "导出环境变量: ${env_key}=\"${value}\"" # 调试用
        done
    fi

    # 执行模块脚本
    "$module_script"
    local rc=$?

    # 清除导出的环境变量，避免影响其他模块或后续操作
    for env_key in "${exported_env_vars[@]}"; do
        unset "$env_key"
    done

    return $rc
}


# --- 主菜单函数 ---
main_menu() {
    # 确保在每次进入主菜单时加载最新的配置
    load_config_json

    local header_text="Docker 自动更新助手 ${SCRIPT_VERSION}"
    
    while true; do
        if [ "${JB_ENABLE_AUTO_CLEAR}" = "true" ]; then clear; fi
        
        local watchtower_status="${RED}未安装${NC}"
        if [ "$(_get_config_value ".modules.watchtower.enabled")" = "true" ]; then
            if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
                watchtower_status="${GREEN}已启动${NC}"
            else
                watchtower_status="${YELLOW}已安装, 未运行${NC}"
            fi
        fi

        local -a items_array=(
            "  1. › 安 装 / 更 新 主 程 序"
            "  2. › 配 置 全 局 设 置"
            "  3. › Watchtower 管 理 (${watchtower_status})"
            "  4. › 卸 载 主 程 序"
        )
        _render_menu "$header_text" "${items_array[@]}"
        read -r -p " └──> 请选择, 或按 Enter 退出: " choice

        case "$choice" in
            1)
                if confirm_action "确定要更新主程序吗?"; then
                    log_info "正在更新 install.sh 和 utils.sh..."
                    # 重新安装 install.sh 自身
                    _update_module_files "install" "$(cat "$0")"
                    # 更新 utils.sh
                    _update_module_files "utils" "$(cat "$UTILS_FILE_CONTENT")" # 假设有一个变量存储 utils.sh 的内容
                    log_success "主程序更新完成。请重新运行脚本以应用最新版本。"
                    press_enter_to_continue
                    exit 0 # 更新后退出，让用户重新启动
                else
                    log_info "操作已取消。"
                    press_enter_to_continue
                fi
                ;;
            2)
                _print_header "⚙️ 全局设置 ⚙️"
                _prompt_for_config_value ".general.timezone" "请输入时区 (例如 Asia/Shanghai)"
                _prompt_for_bool ".general.enable_auto_clear" "是否在每次菜单操作后自动清屏?"
                save_config_json
                log_success "全局设置已更新。"
                press_enter_to_continue
                ;;
            3) _run_module "Watchtower" || true; press_enter_to_continue ;;
            4)
                if confirm_action "警告: 这将卸载所有模块并删除主程序！确定吗?"; then
                    _uninstall_watchtower_module_logic # 卸载 Watchtower 模块
                    _uninstall_module_files "install" # 卸载 install.sh 自身
                    _uninstall_module_files "utils" # 卸载 utils.sh
                    sudo rm -f "$CONFIG_FILE_JSON" # 删除主配置文件
                    log_success "主程序及所有模块已卸载。"
                    log_info "您可能需要手动删除 $BASE_DIR 目录。"
                    press_enter_to_continue
                    exit 0
                else
                    log_info "操作已取消。"
                    press_enter_to_continue
                fi
                ;;
            "") exit 0 ;;
            *) log_warn "无效选项。"; sleep 1 ;;
        esac
    done
}

# --- 入口点 ---
main() {
    trap 'echo -e "\n操作被中断。"; exit 1' INT # 捕获中断信号
    check_dependencies
    
    # 检查并安装 utils.sh (如果它不存在或版本过旧，这里会更新)
    local utils_current_version=""
    if [ -f "$UTILS_FILE" ]; then
        utils_current_version=$(grep -m 1 '^SCRIPT_VERSION=' "$UTILS_FILE" | cut -d'"' -f2 || true)
    fi
    # 假设 utils.sh 的最新内容在这里
    local utils_script_content=$(cat <<'UTILS_EOF'
#!/bin/bash
# =============================================================
# 🚀 Docker 自动更新助手 (v4.6.15 - utils.sh)
# - [修复] 修正 _render_menu 函数，使用 _get_display_width 正确计算菜单项宽度，解决中文对齐问题。
# - [优化] _get_display_width 函数，在没有 python 时回退到 wc -m。
# - [优化] _prompt_for_interval 函数，增加更友好的提示。
# =============================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 日志函数 ---
log_info() {
    echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S') [信息] $*${NC}"
}

log_success() {
    echo -e "${GREEN}$(date '+%Y-%m-%d %H:%M:%S') [成功] $*${NC}"
}

log_warn() {
    echo -e "${YELLOW}$(date '+%Y-%m-%d %H:%M:%S') [警告] $*${NC}" >&2
}

log_err() {
    echo -e "${RED}$(date '+%Y-%m-%d %H:%M:%S') [错误] $*${NC}" >&2
}

# --- 辅助函数 ---

# press_enter_to_continue: 提示用户按回车键继续
press_enter_to_continue() {
    echo -e "\n按 ${GREEN}Enter${NC} 键继续..."
    read -r
}

# confirm_action: 提示用户确认操作
# 参数1: 提示信息
# 返回值: 0表示确认，1表示取消
confirm_action() {
    read -r -p "$(echo -e "${YELLOW}$1 (y/N): ${NC}")" response
    case "$response" in
        [yY][eE][sS]|[yY])
            true
            ;;
        *)
            false
            ;;
    esac
}

# _get_display_width: 计算字符串的显示宽度，处理ANSI颜色码和多字节字符
# 参数1: 字符串
_get_display_width() {
    local str="$1"
    # 移除ANSI颜色码
    local clean_str=$(echo "$str" | sed 's/\x1b\[[0-9;]*m//g')
    # 使用Python计算显示宽度，处理多字节字符 (East Asian Width)
    # Fallback to wc -m (character count) if python is not available, which is better than wc -c
    if command -v python3 &>/dev/null; then
        python3 -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$clean_str" || echo "${#clean_str}"
    elif command -v python &>/dev/null; then
        python -c 'import unicodedata, sys; print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F", "A") else 1 for c in sys.stdin.read().strip()))' <<< "$clean_str" || echo "${#clean_str}"
    else
        # Fallback to wc -m (character count) if Python is not available
        # This is less accurate for mixed-width characters but better than wc -c (byte count)
        echo "$clean_str" | wc -m
    fi
}

# center_text: 将文本居中
# 参数1: 文本
# 参数2: 总宽度
center_text() {
    local text="$1"
    local total_width="$2"
    local text_width=$(_get_display_width "$text")
    if [ "$text_width" -ge "$total_width" ]; then
        echo "$text"
        return
    fi
    local padding_left=$(((total_width - text_width) / 2))
    local padding_right=$((total_width - text_width - padding_left))
    printf "%${padding_left}s%s%${padding_right}s" "" "$text" ""
}

# _render_menu: 渲染一个带边框的菜单
# 参数1: 菜单标题
# 参数2...N: 菜单项 (每项一行)
_render_menu() {
    local title="$1"
    shift
    local items_array=("$@")

    local max_width=0
    # 计算标题的显示宽度并初始化 max_width
    local title_display_width=$(_get_display_width "$title")
    if [ "$title_display_width" -gt "$max_width" ]; then
        max_width="$title_display_width"
    fi

    # 计算所有菜单项的显示宽度，并更新 max_width
    for item in "${items_array[@]}"; do
        local item_display_width=$(_get_display_width "$item")
        if [ "$item_display_width" -gt "$max_width" ]; then
            max_width="$item_display_width"
        fi
    done

    # 确保菜单有足够的宽度，至少比标题宽4个字符 (标题两侧各2个空格)
    # 并且确保最小宽度，防止菜单过窄
    if [ "$max_width" -lt 30 ]; then # 最小宽度可以根据需要调整
        max_width=30
    fi
    if [ "$max_width" -lt "$((title_display_width + 4))" ]; then
        max_width="$((title_display_width + 4))"
    fi

    # 绘制顶部边框
    local border_line=$(printf "%-${max_width}s" "" | sed 's/ /─/g')
    echo -e "╭─${border_line}─╮"

    # 绘制标题行
    printf "│ %s │\n" "$(center_text "$title" "$max_width")"

    # 绘制标题下分隔线
    echo -e "├─${border_line}─┤"

    # 绘制菜单项
    for item in "${items_array[@]}"; do
        # printf "%-${max_width}s" 会根据字符宽度进行填充
        printf "│ %-${max_width}s │\n" "$item"
    done

    # 绘制底部边框
    echo -e "╰─${border_line}─╯"
}


# _prompt_for_interval: 提示用户输入时间间隔，并将其转换为秒
# 参数1: 默认间隔 (秒)
# 参数2: 提示信息
# 返回值: 转换后的秒数
_prompt_for_interval() {
    local default_interval="$1"
    local prompt_message="$2"
    local unit_map=(
        ["s"]="秒" ["m"]="分" ["h"]="时" ["d"]="天"
        ["秒"]="s" ["分"]="m" ["时"]="h" ["天"]="d"
    )

    local current_value_human=$(_format_seconds_to_human "$default_interval")
    
    while true; do
        read -r -p "$(echo -e "${CYAN}${prompt_message} (例如: 300s, 5m, 2h, 1d, 当前: ${current_value_human}): ${NC}")" input

        if [ -z "$input" ]; then
            echo "$default_interval"
            return 0
        fi

        local num=$(echo "$input" | grep -Eo '^[0-9]+')
        local unit=$(echo "$input" | grep -Eo '[a-zA-Z一-龥]+$')

        if [ -z "$num" ]; then
            log_warn "无效输入。请输入数字和单位 (例如: 300s, 5m)。"
            continue
        fi

        local unit_in_seconds=1 # 默认单位为秒
        case "${unit,,}" in # 转换为小写进行匹配
            s|sec|秒) unit_in_seconds=1 ;;
            m|min|分) unit_in_seconds=60 ;;
            h|hr|时) unit_in_seconds=3600 ;;
            d|day|天) unit_in_seconds=86400 ;;
            *)
                log_warn "无效单位 '${unit}'。请使用 s (秒), m (分), h (时), d (天)。"
                continue
                ;;
        esac

        local total_seconds=$((num * unit_in_seconds))
        echo "$total_seconds"
        return 0
    done
}
UTILS_EOF
)
    if [ ! -f "$UTILS_FILE" ] || ! grep -q "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$UTILS_FILE"; then
        log_info "正在安装/更新 utils.sh 到最新版本 ${SCRIPT_VERSION}..."
        echo "$utils_script_content" | sudo tee "$UTILS_FILE" >/dev/null
        sudo chmod +x "$UTILS_FILE"
        log_success "utils.sh 已更新/安装。"
        # 重新加载 utils.sh 以确保使用最新函数定义
        source "$UTILS_FILE"
    fi

    main_menu
}

main "$@"
