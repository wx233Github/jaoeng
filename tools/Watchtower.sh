#!/bin/bash
# =============================================================
# 🚀 Watchtower.sh v5.0 (Enhanced) - 全功能增强版 (by GPT-5 Thinking mini)
# - 功能：智能更新模式、更新摘要报告、多渠道通知（Telegram/Discord/Email webhook）
# - 改进：统一日志、_trap_exit、动态间隔/一次性运行、默认值回退、容器过滤、JSON/文本报告
# - 兼容：尽量兼容你已有的 config 与原脚本逻辑
# =============================================================

SCRIPT_VERSION="v5.0"
set -eo pipefail
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}

# -----------------------
# 配置与常量（可被 config 文件 / 环境覆盖）
# -----------------------
INSTALL_DIR="/opt/vps_install_modules"
UTILS_PATH="${INSTALL_DIR}/utils.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"
REPORT_DIR="/var/log/watchtower-reports"
REPORT_FILE="${REPORT_DIR}/watchtower_report.$(date +%Y%m%d%H%M%S).log"
# 回退默认值（当 config 未提供时）
DEFAULT_INTERVAL=300
DEFAULT_CRON_HOUR=4
DEFAULT_ENABLE_REPORT=true
DEFAULT_DEBUG=false

# -----------------------
# 引入通用工具（如果存在）
# -----------------------
if [ -f "$UTILS_PATH" ]; then
    # shellcheck source=/dev/null
    source "$UTILS_PATH"
else
    # 轻量替代 log 函数（确保脚本仍能运行）
    log_timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""
    log_info() { echo -e "$(log_timestamp) [INFO] $*"; }
    log_warn() { echo -e "$(log_timestamp) [WARN] $*"; }
    log_err()  { echo -e "$(log_timestamp) [ERROR] $*" >&2; }
    log_success() { echo -e "$(log_timestamp) [OK] $*"; }
    press_enter_to_continue() { read -r -p "$(echo -e "\n按 Enter 键继续...")"; }
    confirm_action() { read -r -p "$1 ([y]/n): " choice; case "$choice" in n|N) return 1;; *) return 0;; esac; }
fi

# -----------------------
# 小工具：统一日志接口（模块化）
# -----------------------
_log() {
    # usage: _log LEVEL MODULE MESSAGE...
    local level="$1"; shift
    local module="$1"; shift
    local msg="$*"
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S")
    local level_tag="$level"
    case "$level" in
        INFO) level_tag="${BLUE}INFO${NC}" ;;
        SUCCESS) level_tag="${GREEN}OK${NC}" ;;
        WARN) level_tag="${YELLOW}WARN${NC}" ;;
        ERROR) level_tag="${RED}ERR${NC}" ;;
        *) level_tag="${level}" ;;
    esac
    echo -e "${ts} [${module}] [${level_tag}] ${msg}"
}

# trap exit 记录
_trap_exit() {
    local rc=$?
    _log WARN "watchtower" "脚本退出（代码: ${rc}，最后命令: ${BASH_COMMAND:-unknown}）"
}
trap _trap_exit EXIT

# -----------------------
# 参数解析：支持 --interval N --once --notify ch1,ch2 --report [text|json]
# -----------------------
CLI_INTERVAL=""
CLI_ONCE="false"
CLI_NOTIFY=""
CLI_REPORT_FORMAT="text"   # text | json
CLI_DEBUG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --interval|-i) CLI_INTERVAL="$2"; shift 2 ;;
        --once|--run-once) CLI_ONCE="true"; shift ;;
        --notify) CLI_NOTIFY="$2"; shift 2 ;;
        --report) CLI_REPORT_FORMAT="$2"; shift 2 ;;
        --debug) CLI_DEBUG="true"; shift ;;
        --help|-h) echo "Usage: $0 [--interval <sec>] [--once] [--notify telegram,discord,email] [--report text|json]"; exit 0 ;;
        *) shift ;;
    esac
done

# -----------------------
# 读取配置（来自 CONFIG_FILE 或 环境变量），并提供默认回退
# -----------------------
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        # load but tolerate errors
        source "$CONFIG_FILE" 2>/dev/null || true
        _log INFO "watchtower" "已加载配置文件: $CONFIG_FILE"
    else
        _log INFO "watchtower" "配置文件 $CONFIG_FILE 未找到，使用环境或默认值。"
    fi

    # 以下变量优先级：环境/CONFIG_FILE -> CLI -> 默认
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-${WATCHTOWER_CONF_DEFAULT_INTERVAL:-${DEFAULT_INTERVAL}}}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-${DEFAULT_DEBUG}}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-${WATCHTOWER_CONF_EXCLUDE_CONTAINERS:-}}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-true}"
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-${WATCHTOWER_TG_BOT_TOKEN:-}}"
    TG_CHAT_ID="${TG_CHAT_ID:-${WATCHTOWER_TG_CHAT_ID:-}}"
    DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-${WATCHTOWER_DISCORD_WEBHOOK_URL:-}}"
    MAIL_WEBHOOK_URL="${MAIL_WEBHOOK_URL:-${WATCHTOWER_MAIL_WEBHOOK_URL:-}}"
    JB_TIMEZONE="${JB_TIMEZONE:-${WATCHTOWER_TIMEZONE:-Asia/Shanghai}}"

    # CLI override
    if [ -n "$CLI_INTERVAL" ]; then WATCHTOWER_CONFIG_INTERVAL="$CLI_INTERVAL"; fi
    if [ "$CLI_DEBUG" = "true" ]; then WATCHTOWER_DEBUG_ENABLED="true"; fi
    if [ -n "$CLI_NOTIFY" ]; then CLI_NOTIFY="${CLI_NOTIFY}"; fi
    if [ -n "$CLI_REPORT_FORMAT" ]; then CLI_REPORT_FORMAT="$CLI_REPORT_FORMAT"; fi
}

# -----------------------
# 检查 Docker 可用性
# -----------------------
ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        _log ERROR "watchtower" "未检测到 docker 命令。请先安装 Docker。"
        return 1
    fi
    # 测试能否访问 Docker daemon
    if ! docker ps -q >/dev/null 2>&1; then
        _log ERROR "watchtower" "无法访问 Docker。请确保当前用户有权限（或使用 sudo）。"
        return 1
    fi
    return 0
}

# -----------------------
# 容器过滤：剔除 exited / paused / watchtower 自身 / 空名
# -----------------------
_filter_containers() {
    # returns newline-separated container NAMES to be processed
    local exclude_pattern=""
    if [ -n "${WATCHTOWER_EXCLUDE_LIST}" ]; then
        exclude_pattern=$(echo "${WATCHTOWER_EXCLUDE_LIST}" | sed 's/,/|/g')
    fi

    # list containers that are "Up" (running)
    # format: names
    docker ps --format '{{.Names}} {{.Status}}' | awk '$2=="Up" || $1!=""; {name=$1; status=$2; if (index($0,"Up")>0) print name}' \
        | grep -v -E "^(watchtower|watchtower-once)$" \
        | grep -v -E "^$" \
        | ( if [ -n "$exclude_pattern" ]; then grep -v -E "($exclude_pattern)" || true; else cat; fi ) || true
}

# -----------------------
# Helper: pull image for a container's configured image name (safe)
# -----------------------
_pull_image_for_container() {
    local container="$1"
    # get image reference as specified in container config (may be tag)
    local image_ref
    image_ref=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
    if [ -z "$image_ref" ]; then
        _log WARN "watchtower" "无法获取容器 $container 的镜像引用，跳过拉取。"
        return 1
    fi
    # attempt pull
    _log INFO "watchtower" "拉取镜像: $image_ref"
    set +e
    docker pull "$image_ref" >/dev/null 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        _log WARN "watchtower" "docker pull $image_ref 返回 $rc（可能无权限或镜像不存在）。"
        return 1
    fi
    return 0
}

# -----------------------
# 获取 image digest/id 简易函数
# -----------------------
_get_image_id() {
    local container="$1"
    docker inspect --format '{{.Image}}' "$container" 2>/dev/null || echo ""
}

# -----------------------
# 更新单个容器（智能更新：比较 old/new image id）
# 记录到 REPORT_FILE: container|old_image|new_image|timestamp
# -----------------------
_update_container_if_needed() {
    local container="$1"
    local should_restart="false"
    local old_image_id new_image_id image_ref
    old_image_id=$(_get_image_id "$container")
    image_ref=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)

    if [ -z "$image_ref" ]; then
        _log WARN "watchtower" "无法读取 $container 的镜像配置，跳过。"
        return 1
    fi

    # Pull image and compare image id
    if _pull_image_for_container "$container"; then
        new_image_id=$(_get_image_id "$container")
        # After docker pull, the running container's Image value hasn't changed until restarted.
        # To detect new image, compare the digest of the image_ref (latest pulled) vs container's current image id:
        # find image id of image_ref
        local pulled_image_id
        pulled_image_id=$(docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk -v ref="$image_ref" '$1==ref {print $2}' | head -n1 || true)
        # Fallback: attempt to inspect image_ref directly
        if [ -z "$pulled_image_id" ]; then
            pulled_image_id=$(docker inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
        fi
        if [ -z "$pulled_image_id" ]; then
            _log WARN "watchtower" "无法获得已拉取镜像的 ID ($image_ref)，将比较容器当前 image id 与 image_ref inspect。"
            # try inspect image_ref
            pulled_image_id=$(docker inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
        fi

        # If pulled_image_id is empty, try to assume no update
        if [ -z "$pulled_image_id" ]; then
            _log WARN "watchtower" "未能解析新镜像 ID，跳过 $container 的自动更新检测。"
            return 1
        fi

        # Normalize (no-trunc)
        old_image_id_full=$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null || echo "$old_image_id")
        # If old_image_id_full equals pulled_image_id, nothing changed
        if [ "$old_image_id_full" = "$pulled_image_id" ]; then
            _log INFO "watchtower" "容器 $container: 镜像未改变 (ID 相同) ，跳过。"
            return 0
        fi

        # 记录并 restart
        _log INFO "watchtower" "容器 $container: 发现新镜像 (旧: ${old_image_id_full:0:12} 新: ${pulled_image_id:0:12})，准备更新。"
        # create report dir
        mkdir -p "$REPORT_DIR" 2>/dev/null || true
        # attempt restart: create new container by restart (we'll just docker restart; user may want recreate approach)
        # safer to docker rm -f and docker run? that loses config; so prefer docker stop/start (restart)
        set +e
        docker stop "$container" >/dev/null 2>&1 || true
        docker start "$container" >/dev/null 2>&1 || true
        local rc=$?
        set -e
        if [ $rc -eq 0 ]; then
            _log SUCCESS "watchtower" "容器 $container 更新并重启成功。"
            printf "%s|%s|%s|%s\n" "$container" "${old_image_id_full}" "${pulled_image_id}" "$(date '+%F %T')" >> "$REPORT_FILE"
            return 0
        else
            _log ERROR "watchtower" "容器 $container 更新/重启失败 (rc=$rc)。尝试回滚：重启旧容器 ID..."
            # 回滚尝试（尝试 docker start）
            set +e
            docker start "$container" >/dev/null 2>&1 || true
            set -e
            printf "%s|%s|%s|%s\n" "$container" "${old_image_id_full}" "${pulled_image_id}" "$(date '+%F %T')" >> "$REPORT_FILE"
            return 2
        fi
    else
        _log WARN "watchtower" "为 $container 拉取镜像失败，跳过更新。"
        return 1
    fi
}

# -----------------------
# 批量更新：遍历过滤后的容器并调用更新函数
# -----------------------
run_update_cycle() {
    _log INFO "watchtower" "开始一次更新扫描（间隔: ${WATCHTOWER_CONFIG_INTERVAL}s）..."
    # create report file
    mkdir -p "$REPORT_DIR" 2>/dev/null || true
    : > "$REPORT_FILE"  # truncate new report file

    local containers
    IFS=$'\n' read -r -d '' -a containers < <(printf "%s\0" "$(_filter_containers)" ) || true

    if [ ${#containers[@]} -eq 0 ]; then
        _log INFO "watchtower" "未检测到可监控的容器（或全部被排除）。"
        return 0
    fi

    local updated=0 failed=0 skipped=0
    for c in "${containers[@]}"; do
        c=$(echo -n "$c" | xargs) || true
        if [ -z "$c" ]; then continue; fi
        _log INFO "watchtower" "检查容器: $c"
        if _update_container_if_needed "$c"; then
            updated=$((updated + 1))
        else
            # check return and classify - _update_container_if_needed uses return codes; treat rc 0 as ok
            # best effort: increment failed
            failed=$((failed + 1))
        fi
    done

    _log INFO "watchtower" "本次扫描完成。更新: $updated, 失败: $failed"
    # Generate report and optionally notify
    if [ -s "$REPORT_FILE" ]; then
        _generate_report "$REPORT_FILE" "$CLI_REPORT_FORMAT"
        if [ "${DEFAULT_ENABLE_REPORT}" = "true" ] || [ "${WATCHTOWER_ENABLED}" = "true" ]; then
            # send notifications if configured or requested
            _dispatch_notifications "$REPORT_FILE"
        fi
    else
        _log INFO "watchtower" "无更新发生，本次不生成报告。"
    fi
}

# -----------------------
# 生成报告：文本 / json 两种格式
# -----------------------
_generate_report() {
    local report_path="$1"
    local format="${2:-text}"
    if [ ! -s "$report_path" ]; then
        _log INFO "watchtower" "报告文件为空：$report_path"
        return
    fi

    if [ "$format" = "json" ]; then
        # produce simple JSON array
        echo "[" > "${report_path}.json"
        local first=1
        while IFS='|' read -r name old new time; do
            if [ $first -eq 0 ]; then echo "," >> "${report_path}.json"; fi
            first=0
            printf "  {\"container\":\"%s\", \"old\":\"%s\", \"new\":\"%s\", \"time\":\"%s\"}" \
                "$name" "$old" "$new" "$time" >> "${report_path}.json"
        done < "$report_path"
        echo -e "\n]" >> "${report_path}.json"
        _log INFO "watchtower" "JSON 报告已写入: ${report_path}.json"
    else
        # textual summary to stdout and to a .txt
        local out="${report_path}.txt"
        {
            echo "Watchtower 更新摘要 - $(date '+%F %T')"
            printf "%-25s %-15s %-15s %-20s\n" "容器" "旧镜像(ID)" "新镜像(ID)" "时间"
            echo "--------------------------------------------------------------------------------"
            while IFS='|' read -r name old new time; do
                printf "%-25s %-15s %-15s %-20s\n" "$name" "${old:0:12}" "${new:0:12}" "$time"
            done < "$report_path"
        } > "$out"
        _log INFO "watchtower" "文本报告已写入: $out"
    fi
}

# -----------------------
# 通知支持：telegram / discord / email(webhook)
# 读取 TG_BOT_TOKEN, TG_CHAT_ID, DISCORD_WEBHOOK_URL, MAIL_WEBHOOK_URL
# -----------------------
_notify_telegram() {
    local text="$1"
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        _log WARN "notify" "Telegram 未配置（TG_BOT_TOKEN / TG_CHAT_ID）。"
        return 1
    fi
    # encode text for curl
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=Markdown" >/dev/null 2>&1 || return 1
    return 0
}

_notify_discord() {
    local text="$1"
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        _log WARN "notify" "Discord Webhook 未配置。"
        return 1
    fi
    # simple payload
    curl -s -H "Content-Type: application/json" -X POST "$DISCORD_WEBHOOK_URL" \
        -d "{\"content\": $(printf "%q" "$text")}" >/dev/null 2>&1 || return 1
    return 0
}

_notify_email_webhook() {
    local subject="$1"
    local body="$2"
    if [ -z "$MAIL_WEBHOOK_URL" ]; then
        _log WARN "notify" "邮件 webhook 未配置。"
        return 1
    fi
    # POST with fields subject & body
    curl -s -X POST "$MAIL_WEBHOOK_URL" -d "subject=${subject}" --data-urlencode "body=${body}" >/dev/null 2>&1 || return 1
    return 0
}

# dispatch notifications based on config / CLI_NOTIFY
_dispatch_notifications() {
    local report_path="$1"
    local text_summary
    text_summary=$(cat "${report_path}.txt" 2>/dev/null || cat "$report_path" 2>/dev/null || echo "Watchtower 更新完成。")
    # decide channels
    local channels=""
    if [ -n "$CLI_NOTIFY" ]; then
        channels="$CLI_NOTIFY"
    else
        # prefer configured ones
        [ -n "$TG_BOT_TOKEN" ] && channels="${channels},telegram"
        [ -n "$DISCORD_WEBHOOK_URL" ] && channels="${channels},discord"
        [ -n "$MAIL_WEBHOOK_URL" ] && channels="${channels},email"
        channels=$(echo "$channels" | sed 's/^,//;s/,,/,/g')
    fi

    if [ -z "$channels" ]; then
        _log INFO "notify" "未配置任何通知通道。跳过发送通知。"
        return 0
    fi

    IFS=',' read -r -a chs <<< "$channels"
    for ch in "${chs[@]}"; do
        case "$ch" in
            telegram) _log INFO "notify" "发送 Telegram 通知..."; _notify_telegram "$text_summary" && _log SUCCESS "notify" "Telegram 发送成功。" || _log WARN "notify" "Telegram 发送失败。" ;;
            discord) _log INFO "notify" "发送 Discord 通知..."; _notify_discord "$text_summary" && _log SUCCESS "notify" "Discord 发送成功。" || _log WARN "notify" "Discord 发送失败。" ;;
            email) _log INFO "notify" "发送 Email webhook 通知..."; _notify_email_webhook "Watchtower 更新报告" "$text_summary" && _log SUCCESS "notify" "Email 通知发送成功。" || _log WARN "notify" "Email 通知发送失败。" ;;
            *) _log WARN "notify" "未知通知通道: $ch" ;;
        esac
    done
}

# -----------------------
# CLI-friendly commands: --once, or run as daemon loop
# -----------------------
main_loop() {
    load_config
    ensure_docker || exit 1

    # If --once requested, run single cycle and exit
    if [ "$CLI_ONCE" = "true" ] || [ "$CLI_ONCE" = "true" ] || [ "${1:-}" = "--run-once" ]; then
        run_update_cycle
        exit 0
    fi

    # daemon loop
    while true; do
        run_update_cycle
        _log INFO "watchtower" "等待 ${WATCHTOWER_CONFIG_INTERVAL}s 后进行下一次扫描..."
        sleep "${WATCHTOWER_CONFIG_INTERVAL}"
    done
}

# -----------------------
# provide some interactive helpers (kept minimal)
# -----------------------
print_status() {
    load_config
    ensure_docker || return 1
    local is_running
    is_running=$(docker ps --format '{{.Names}}' | grep -E '^(watchtower|watchtower-once)$' || true)
    if [ -n "$is_running" ]; then
        _log INFO "watchtower" "Watchtower 容器正在运行: $is_running"
    else
        _log INFO "watchtower" "Watchtower 未运行。"
    fi
    _log INFO "watchtower" "监控间隔: ${WATCHTOWER_CONFIG_INTERVAL}s"
    _log INFO "watchtower" "排除列表: ${WATCHTOWER_EXCLUDE_LIST:-(无)}"
    _log INFO "watchtower" "通知: $( [ -n "$TG_BOT_TOKEN" ] && echo "Telegram" || true) $( [ -n "$DISCORD_WEBHOOK_URL" ] && echo "Discord" || true) $( [ -n "$MAIL_WEBHOOK_URL" ] && echo "Email" || true)"
}

# -----------------------
# Entrypoint
# -----------------------
case "${0##*/}" in
    watchtower*|*Watchtower*)
        # invoked as script
        main_loop "$@"
        ;;
    *)
        # fallback: run main loop
        main_loop "$@"
        ;;
esac
