#!/usr/bin/env bash
# =============================================
# Docker 自动更新管理 - 主菜单（增强版）
# - 主菜单顶部显示状态报告（容器状态 + CPU/内存）
# - 菜单选项（1-6）：
#     1) 设置更新模式 (Watchtower / Cron)
#     2) 查看容器信息
#     3) 配置通知 (Telegram / Email)
#     4) 任务管理 (启动/停止/重启/移除容器)
#     5) 查看/编辑脚本配置
#     6) 手动运行 Watchtower
# =============================================
set -euo pipefail
IFS=$'\n\t'

# -----------------------
# 配置
CONFIG_FILE="/etc/docker-auto-update.conf"
# 如果没有权限写 /etc，则默认到用户目录
if [ ! -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# 默认配置（会在 save_config 时写入 CONFIG_FILE）
: "${TG_BOT_TOKEN:=""}"
: "${TG_CHAT_ID:=""}"
: "${EMAIL_TO:=""}"
: "${WATCHTOWER_LABELS:=""}"
: "${WATCHTOWER_EXTRA_ARGS:=""}"
: "${WATCHTOWER_DEBUG_ENABLED:="false"}"
: "${WATCHTOWER_CONFIG_INTERVAL:="300"}"
: "${WATCHTOWER_ENABLED:="false"}"
: "${DOCKER_COMPOSE_PROJECT_DIR_CRON:=""}"
: "${CRON_HOUR:="4"}"
: "${CRON_TASK_ENABLED:="false"}"

# -----------------------
# Colors
if [ -t 1 ]; then
    GREEN="\033[0;32m"
    RED="\033[0;31m"
    YELLOW="\033[0;33m"
    BLUE="\033[0;34m"
    CYAN="\033[0;36m"
    RESET="\033[0m"
else
    GREEN=""; RED=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

# -----------------------
# Helpers
log_info(){ printf "%b[INFO] %s%b\n" "$BLUE" "$*" "$RESET"; }
log_warn(){ printf "%b[WARN] %s%b\n" "$YELLOW" "$*" "$RESET"; }
log_err(){ printf "%b[ERROR] %s%b\n" "$RED" "$*" "$RESET"; }

# -----------------------
# Requirement checks
check_requirements(){
    if ! command -v docker &>/dev/null; then
        log_err "Docker 未安装或不可用。请先安装 Docker（并确保当前用户有权限使用 Docker）。"
        exit 1
    fi
    # jq optional
    if ! command -v jq &>/dev/null; then
        log_warn "未检测到 jq，某些 JSON 解析功能可能受限。建议安装 jq。"
    fi
    if ! command -v bc &>/dev/null; then
        log_warn "未检测到 bc，脚本内对数字比较时可能使用替代方式。建议安装 bc。"
    fi
}
check_requirements

# -----------------------
# Load config if exists
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}
load_config

save_config(){
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_LABELS="${WATCHTOWER_LABELS}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
EOF
    log_info "配置已保存到 $CONFIG_FILE"
}

# -----------------------
# Utility: get containers info arrays
# -----------------------
get_all_containers(){
    # Return lines: name|status|id
    docker ps -a --format '{{.Names}}|{{.Status}}|{{.ID}}' 2>/dev/null || true
}

# -----------------------
# Status report printing
# -----------------------
show_status_report(){
    local rows
    rows=$(get_all_containers)
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    echo "╔════════════════════════════════════════════════════════════════════╗"
    printf "║ %s%-58s%s ║\n" "$CYAN" "容器管理主菜单 - 状态报告 (实时)" "$RESET"
    echo "╠════════════════════════════════════════════════════════════════════╣"
    echo "║ 状态报告:                                                           ║"
    echo "║ ┌────────────────────────────────────────────────────────────────┐ ║"
    printf "║ │ %-20s %-18s %-10s %-10s │ ║\n" "容器名称" "状态" "CPU%" "MEM"
    if [ -z "$rows" ]; then
        printf "║ │ %-64s │ ║\n" "（未检测到任何容器）"
    else
        # For each container, get CPU/MEM from docker stats (no-stream)
        # Build a map of id->stats first for speed
        # stats lines: name|cpu|mem
        local stats_map
        stats_map=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' 2>/dev/null || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            name=$(echo "$line" | cut -d'|' -f1)
            status=$(echo "$line" | cut -d'|' -f2- | sed 's/|/ /g' | awk '{print $1}')
            id=$(echo "$line" | cut -d'|' -f3)
            # find stats
            cpu="-"
            mem="-"
            if [ -n "$stats_map" ]; then
                stat_line=$(echo "$stats_map" | awk -F'|' -v nm="$name" '$1==nm {print $0; exit}')
                if [ -n "$stat_line" ]; then
                    cpu=$(echo "$stat_line" | cut -d'|' -f2)
                    mem=$(echo "$stat_line" | cut -d'|' -f3)
                fi
            fi
            # color status
            local status_short
            if echo "$status" | grep -qi '^Up' >/dev/null 2>&1; then
                status_short="${GREEN}运行中${RESET}"
            else
                status_short="${RED}已停止${RESET}"
            fi
            # trim values to reasonable width
            cpu_display="${cpu}"
            mem_display="${mem}"
            printf "║ │ %-20s %-18b %-10s %-10s │ ║\n" "$name" "$status_short" "$cpu_display" "$mem_display"
        done <<< "$rows"
    fi
    echo "║ └────────────────────────────────────────────────────────────────┘ ║"
    printf "║ 最后刷新时间: %-48s ║\n" "$now"
    echo "╠════════════════════════════════════════════════════════════════════╣"
    echo "║ 主菜单选项：                                                         ║"
    echo "║ 1) 设置更新模式 (Watchtower / Cron)                                 ║"
    echo "║       → Watchtower / Cron 定时更新                                   ║"
    echo "║ 2) 查看容器信息                                                      ║"
    echo "║       → 显示所有容器状态和资源占用                                   ║"
    echo "║ 3) 配置通知 (Telegram / Email)                                       ║"
    echo "║       → Telegram / Email 推送                                        ║"
    echo "║ 4) 任务管理 (停止/重启/移除容器)                                     ║"
    echo "║       → 停止 / 重启 / 移除容器                                        ║"
    echo "║ 5) 查看/编辑脚本配置                                                  ║"
    echo "║       → 配置文件查看与修改                                           ║"
    echo "║ 6) 手动运行 Watchtower                                                ║"
    echo "║       → 立即检查容器更新                                              ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
}

# -----------------------
# Helpers: choose container by number
# -----------------------
select_container_menu(){
    local lines
    lines=$(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.ID}}' 2>/dev/null || true)
    if [ -z "$lines" ]; then
        log_warn "未检测到容器。"
        return 1
    fi
    echo "请选择容器（输入编号），或 0 返回："
    local i=0
    local arr=()
    while IFS= read -r l; do
        name=$(echo "$l" | awk '{print $1}')
        st=$(echo "$l" | awk '{print $2}')
        id=$(echo "$l" | awk '{print $3}')
        arr+=("$name|$id")
        ((i++))
        printf "%2d) %-20s %-20s\n" "$i" "$name" "$st"
    done <<< "$lines"
    printf "%2d) 返回\n" 0
    while true; do
        read -r -p "选择编号: " sel
        if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
            echo "请输入数字编号。"
            continue
        fi
        if [ "$sel" -eq 0 ]; then
            return 2
        fi
        if [ "$sel" -ge 1 ] && [ "$sel" -le "${#arr[@]}" ]; then
            choice="${arr[$((sel-1))]}"
            selected_name="${choice%%|*}"
            selected_id="${choice##*|}"
            echo "$selected_name|$selected_id"
            return 0
        fi
        echo "编号超出范围，请重试。"
    done
}

# -----------------------
# Option 1: 设置更新模式 (Watchtower / Cron)
# -----------------------
configure_update_mode(){
    echo "配置更新模式："
    echo "1) Watchtower (后台运行)"
    echo "2) Cron 定时任务 (通过 docker compose 拉取并更新指定项目)"
    echo "0) 返回"
    read -r -p "选择: " opt
    case "$opt" in
        1)
            # Ask interval
            while true; do
                read -r -p "请输入 Watchtower 检查间隔（例如 300s / 2h / 1d，回车使用当前 ${WATCHTOWER_CONFIG_INTERVAL}s）: " inpt
                inpt=${inpt:-${WATCHTOWER_CONFIG_INTERVAL}}
                if [[ "$inpt" =~ ^([0-9]+)s$ ]]; then
                    WATCHTOWER_CONFIG_INTERVAL=${BASH_REMATCH[1]}
                    break
                elif [[ "$inpt" =~ ^([0-9]+)h$ ]]; then
                    WATCHTOWER_CONFIG_INTERVAL=$((${BASH_REMATCH[1]}*3600)); break
                elif [[ "$inpt" =~ ^([0-9]+)d$ ]]; then
                    WATCHTOWER_CONFIG_INTERVAL=$((${BASH_REMATCH[1]}*86400)); break
                elif [[ "$inpt" =~ ^[0-9]+$ ]]; then
                    WATCHTOWER_CONFIG_INTERVAL="$inpt"; break
                else
                    echo "格式错误，请使用例如 300s / 2h / 1d 或纯数字(秒)。"
                fi
            done
            # extra args & labels & debug
            read -r -p "是否设置 Watchtower 筛选标签 (留空跳过): " lbl
            WATCHTOWER_LABELS="${lbl:-$WATCHTOWER_LABELS}"
            read -r -p "是否设置 Watchtower 额外参数 (留空跳过): " extra
            WATCHTOWER_EXTRA_ARGS="${extra:-$WATCHTOWER_EXTRA_ARGS}"
            read -r -p "是否启用 Watchtower 调试 (--debug) (y/N): " dbg
            if [[ "$dbg" =~ ^[Yy]$ ]]; then WATCHTOWER_DEBUG_ENABLED="true"; else WATCHTOWER_DEBUG_ENABLED="false"; fi
            WATCHTOWER_ENABLED="true"
            save_config
            # restart watchtower
            log_info "正在（重）启动 Watchtower..."
            set +e
            docker rm -f watchtower &>/dev/null || true
            set -e
            WT_ARGS="--cleanup --interval ${WATCHTOWER_CONFIG_INTERVAL}"
            [ -n "$WATCHTOWER_EXTRA_ARGS" ] && WT_ARGS="$WT_ARGS $WATCHTOWER_EXTRA_ARGS"
            [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && WT_ARGS="$WT_ARGS --debug"
            if [ -n "$WATCHTOWER_LABELS" ]; then
                WT_ARGS="$WT_ARGS --label-enable $WATCHTOWER_LABELS"
            fi
            docker pull containrrr/watchtower >/dev/null 2>&1 || log_warn "pull watchtower 失败（可能网络或 Docker Hub 问题）"
            docker run -d --name watchtower -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower $WT_ARGS >/dev/null 2>&1 || log_warn "启动 Watchtower 失败，请检查日志"
            log_info "Watchtower 启动完成（或已尝试启动）"
            read -p "按回车返回主菜单..."
            ;;
        2)
            # Cron mode
            read -r -p "请输入每天更新的小时 (0-23) (当前: ${CRON_HOUR:-4}): " hr
            hr=${hr:-${CRON_HOUR:-4}}
            if ! [[ "$hr" =~ ^[0-9]+$ ]] || [ "$hr" -lt 0 ] || [ "$hr" -gt 23 ]; then
                log_err "小时输入无效，取消。"
                read -p "按回车返回主菜单..."
                return
            fi
            CRON_HOUR="$hr"
            while true; do
                read -r -p "请输入 Docker Compose 项目目录（包含 docker-compose.yml 的目录）: " proj
                if [ -z "$proj" ]; then
                    echo "目录不能为空。"
                    continue
                fi
                if [ ! -d "$proj" ]; then
                    echo "目录不存在，请检查路径。"
                    continue
                fi
                DOCKER_COMPOSE_PROJECT_DIR_CRON="$proj"
                break
            done
            # write cron script
            CRON_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
            LOG_FILE="/var/log/docker-auto-update-cron.log"
            cat > "$CRON_SCRIPT" <<'EOCRON'
#!/bin/bash
export TZ=Asia/Shanghai
PROJECT_DIR="{{PROJECT_DIR}}"
LOG_FILE="{{LOG_FILE}}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Start updating $PROJECT_DIR" >> "$LOG_FILE" 2>&1
cd "$PROJECT_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') - Cannot enter $PROJECT_DIR" >> "$LOG_FILE"; exit 1; }
if command -v docker compose &>/dev/null; then
    DOCKERCMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKERCMD="docker-compose"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - docker compose not found" >> "$LOG_FILE"
    exit 1
fi
$DOCKERCMD pull >> "$LOG_FILE" 2>&1
$DOCKERCMD up -d --remove-orphans >> "$LOG_FILE" 2>&1
docker image prune -f >> "$LOG_FILE" 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') - Update done" >> "$LOG_FILE" 2>&1
EOCRON
            # replace placeholders
            sed -i "s|{{PROJECT_DIR}}|$DOCKER_COMPOSE_PROJECT_DIR_CRON|g" "$CRON_SCRIPT"
            sed -i "s|{{LOG_FILE}}|$LOG_FILE|g" "$CRON_SCRIPT"
            chmod +x "$CRON_SCRIPT"
            # install cron job
            (crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" || true; echo "0 $CRON_HOUR * * * $CRON_SCRIPT >> \"$LOG_FILE\" 2>&1") | crontab -
            CRON_TASK_ENABLED="true"
            save_config
            log_info "Cron 定时任务已设置：每天 ${CRON_HOUR} 点，脚本 $CRON_SCRIPT"
            read -p "按回车返回主菜单..."
            ;;
        0)
            return
            ;;
        *)
            echo "无效选择"
            ;;
    esac
}

# -----------------------
# Option 2: 查看容器信息 (详细)
# -----------------------
view_container_info(){
    echo "所有容器（包含停止）："
    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    echo
    echo "容器资源占用（瞬时快照）:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
    read -p "按回车返回主菜单..."
}

# -----------------------
# Option 3: 配置通知 (Telegram / Email)
# -----------------------
configure_notifications(){
    echo "通知配置："
    echo "1) Telegram"
    echo "2) Email"
    echo "0) 返回"
    read -r -p "选择: " opt
    case "$opt" in
        1)
            read -r -p "输入 Telegram Bot Token (回车保持当前): " tb
            TG_BOT_TOKEN="${tb:-$TG_BOT_TOKEN}"
            read -r -p "输入 Telegram Chat ID (回车保持当前): " tc
            TG_CHAT_ID="${tc:-$TG_CHAT_ID}"
            save_config
            log_info "Telegram 配置已更新 (请确保 Bot 可发送消息)"
            read -p "按回车返回主菜单..."
            ;;
        2)
            read -r -p "输入接收通知的 Email (回车保持当前): " em
            EMAIL_TO="${em:-$EMAIL_TO}"
            save_config
            log_info "Email 配置已更新 (请确保系统 mail 命令可用)"
            read -p "按回车返回主菜单..."
            ;;
        0) return;;
        *) echo "无效选择";;
    esac
}

# -----------------------
# Option 4: 任务管理 - 选择容器并操作
# -----------------------
task_management(){
    # select container
    sel_line=$(select_container_menu)
    sel_ret=$?
    if [ "$sel_ret" -ne 0 ]; then return; fi
    sel_name="${sel_line%%|*}"
    sel_id="${sel_line##*|}"
    while true; do
        echo
        echo "容器: $sel_name ($sel_id)"
        echo "1) 启动"
        echo "2) 停止"
        echo "3) 重启"
        echo "4) 查看日志 (tail -n 200)"
        echo "5) 移除 (rm)"
        echo "0) 返回"
        read -r -p "选择操作: " act
        case "$act" in
            1)
                docker start "$sel_name" && log_info "$sel_name 已启动" || log_err "启动失败"
                ;;
            2)
                docker stop "$sel_name" && log_info "$sel_name 已停止" || log_err "停止失败"
                ;;
            3)
                docker restart "$sel_name" && log_info "$sel_name 已重启" || log_err "重启失败"
                ;;
            4)
                echo "显示最近 200 行日志，按 Ctrl+C 停止查看"
                docker logs --tail 200 -f "$sel_name"
                ;;
            5)
                read -r -p "确定要移除容器 $sel_name ? (y/N): " conf
                if [[ "$conf" =~ ^[Yy]$ ]]; then
                    docker rm -f "$sel_name" && log_info "$sel_name 已移除" || log_err "移除失败"
                    return
                fi
                ;;
            0) return ;;
            *) echo "无效选项" ;;
        esac
    done
}

# -----------------------
# Option 5: 查看/编辑脚本配置
# -----------------------
edit_script_config(){
    echo "配置文件位置: $CONFIG_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "# Docker 自动更新配置文件" > "$CONFIG_FILE"
        save_config
    fi
    # prefer $EDITOR
    : "${EDITOR:=vi}"
    read -r -p "是否使用 $EDITOR 编辑配置？(Y/n): " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        "$EDITOR" "$CONFIG_FILE"
        load_config
        log_info "配置已重新加载"
    fi
}

# -----------------------
# Option 6: 手动运行 Watchtower (一次性)
# -----------------------
run_watchtower_once(){
    # If background watchtower exists, warn
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        log_warn "检测到后台 Watchtower 容器正在运行。一次性运行将以独立容器执行，不会停止后台进程。"
        read -r -p "是否继续执行一次性运行？(y/N): " c
        if ! [[ "$c" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    log_info "执行一次性 Watchtower（拉取并尝试更新）..."
    set +e
    docker pull containrrr/watchtower >/dev/null 2>&1 || log_warn "拉取 watchtower 镜像失败"
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --run-once ${WATCHTOWER_EXTRA_ARGS:-} || log_warn "一次性运行 Watchtower 返回非零状态"
    set -e
    log_info "一次性 Watchtower 运行完成 (已尝试更新)"
    read -p "按回车返回主菜单..."
}

# -----------------------
# Main loop
# -----------------------
while true; do
    clear
    show_status_report
    printf "请输入选项 [1-6]: "
    read -r choice
    case "$choice" in
        1) configure_update_mode ;;
        2) view_container_info ;;
        3) configure_notifications ;;
        4) task_management ;;
        5) edit_script_config ;;
        6) run_watchtower_once ;;
        *) log_warn "无效选项，请输入 1-6"; sleep 1 ;;
    esac
done
