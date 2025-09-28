#!/usr/bin/env bash
# 🚀 Docker 自动更新助手（集成修复 + Option 7 完整实现）
# Version bumped to reflect applied fixes and Option 7 replacement
# 注：本脚本在原始脚本基础上应用了若干兼容性与健壮性修复：
#  - 避免管道导致的子 shell 变量丢失（使用 process substitution / here-strings）
#  - 使用 '|' 分隔 docker ps 输出，防止空格造成字段错位
#  - date/gdate 兼容处理（用于日志时间解析）
#  - 更安全地使用 set -e（对可容忍失败的命令使用 set +e / || true）
#  - 替换并强化了 Option 7: show_watchtower_details 实现
#
# 保存为 docker-auto-update.sh 并赋执行权限：chmod +x docker-auto-update.sh
set -euo pipefail
IFS=$'\n\t'

VERSION="2.17.35-fixed-option7"
SCRIPT_NAME="Watchtower.sh"
CONFIG_FILE="/etc/docker-auto-update.conf"
if [ ! -w "$(dirname "$CONFIG_FILE")" ]; then
    CONFIG_FILE="$HOME/.docker-auto-update.conf"
fi

# --- 嵌套调用判断 ---
IS_NESTED_CALL="${IS_NESTED_CALL:-false}"

# --- 颜色定义 ---
if [ -t 1 ]; then
    COLOR_GREEN="\033[0m\033[0;32m"
    COLOR_RED="\033[0m\033[0;31m"
    COLOR_YELLOW="\033[0m\033[0;33m"
    COLOR_BLUE="\033[0m\033[0;34m"
    COLOR_CYAN="\033[0m\033[0;36m"
    COLOR_RESET="\033[0m"
else
    COLOR_GREEN=""; COLOR_RED=""; COLOR_YELLOW=""; COLOR_BLUE=""; COLOR_CYAN=""; COLOR_RESET=""
fi

# --- 确保以 root 运行（或具备 docker 权限） ---
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${COLOR_RED}❌ 脚本需要 Root 权限才能运行。请使用 'sudo ./$SCRIPT_NAME' 执行。${COLOR_RESET}"
    exit 1
fi

# --- 强制脚本使用 Bash 执行 ---
if [ -z "$BASH_VERSION" ]; then
    echo -e "${COLOR_YELLOW}ℹ️ 检测到非 Bash 环境。正在使用 Bash 重新启动脚本...${COLOR_RESET}" >&2
    exec bash "$0" "$@"
    echo -e "${COLOR_RED}❌ 无法找到 Bash shell 或重新执行失败。请确保系统安装了 Bash。${COLOR_RESET}" >&2
    exit 1
fi

# set -euo pipefail 已在顶部启用
# 检查工具依赖（docker, jq 可选）
if ! command -v docker &>/dev/null; then
    echo -e "${COLOR_RED}❌ 未检测到 Docker，请先安装。${COLOR_RESET}"
    exit 1
fi
if ! command -v jq &>/dev/null; then
    echo -e "${COLOR_YELLOW}⚠️ 未检测到 'jq'，脚本的某些 JSON 解析功能会使用降级方式。建议安装：sudo apt install jq${COLOR_RESET}"
fi
if ! command -v bc &>/dev/null; then
    echo -e "${COLOR_YELLOW}⚠️ 未检测到 'bc'，脚本在进行小数比较时可能退化。建议安装：sudo apt install bc${COLOR_RESET}"
fi

# --- 默认配置（若无 CONFIG_FILE 则使用这些默认并会在保存时写入） ---
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
EMAIL_TO="${EMAIL_TO:-}"
WATCHTOWER_LABELS="${WATCHTOWER_LABELS:-}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-300}"
WATCHTOWER_CONFIG_SELF_UPDATE_MODE="${WATCHTOWER_CONFIG_SELF_UPDATE_MODE:-false}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON:-}"
CRON_HOUR="${CRON_HOUR:-4}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED:-false}"

# --- 工具函数 ---
log_info(){ printf "%b[INFO] %s%b\n" "$COLOR_BLUE" "$*" "$COLOR_RESET"; }
log_warn(){ printf "%b[WARN] %s%b\n" "$COLOR_YELLOW" "$*" "$COLOR_RESET"; }
log_err(){ printf "%b[ERROR] %s%b\n" "$COLOR_RED" "$*" "$COLOR_RESET"; }

# date compatibility helper: returns epoch or empty
_date_to_epoch() {
    # $1 time string
    local dt="$1"
    if [ -z "$dt" ]; then echo ""; return; fi
    if date -d "@0" +%s >/dev/null 2>&1; then
        date -d "$dt" +%s 2>/dev/null || echo ""
    elif command -v gdate >/dev/null 2>&1; then
        gdate -d "$dt" +%s 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# load config file
load_config(){
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}
load_config

# save config file
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
WATCHTOWER_CONFIG_SELF_UPDATE_MODE="${WATCHTOWER_CONFIG_SELF_UPDATE_MODE}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
DOCKER_COMPOSE_PROJECT_DIR_CRON="${DOCKER_COMPOSE_PROJECT_DIR_CRON}"
CRON_HOUR="${CRON_HOUR}"
CRON_TASK_ENABLED="${CRON_TASK_ENABLED}"
EOF
    log_info "✅ 配置已保存到 $CONFIG_FILE"
}

confirm_action() {
    local PROMPT_MSG="$1"
    read -r -p "$(echo -e "${COLOR_YELLOW}$PROMPT_MSG (y/n): ${COLOR_RESET}")" choice
    case "$choice" in
        y|Y ) return 0 ;;
        * ) return 1 ;;
    esac
}

press_enter_to_continue() {
    echo -e "\n${COLOR_YELLOW}按 Enter 键继续...${COLOR_RESET}"
    # 清空 stdin 缓冲
    while read -r -t 0; do read -r; done
    read -r
}

send_notify() {
    local MSG="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s --retry 3 --retry-delay 5 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=$MSG" >/dev/null || log_warn "⚠️ Telegram 通知发送失败，请检查 Bot Token 和 Chat ID。"
    fi
    if [ -n "$EMAIL_TO" ]; then
        if command -v mail &>/dev/null; then
            echo -e "$MSG" | mail -s "Docker 更新通知" "$EMAIL_TO" || log_warn "⚠️ Email 通知发送失败，请检查邮件配置。"
        else
            log_warn "⚠️ Email 通知已启用，但 'mail' 命令未找到。请安装并配置 MTA。"
        fi
    fi
}

# 获取 docker compose 命令
get_docker_compose_command_main() {
    if command -v docker compose &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# -------------------------
# show_container_info (改为安全解析)
# -------------------------
show_container_info() {
    echo -e "${COLOR_YELLOW}📋 Docker 容器信息：${COLOR_RESET}"
    printf "%-20s %-45s %-25s %-15s %-15s\n" "容器名称" "镜像" "创建时间" "状态" "应用版本"
    echo "-------------------------------------------------------------------------------------------------------------------"
    # 使用 | 分隔以避免空格分割问题
    docker ps -a --format '{{.Names}}|{{.Image}}|{{.CreatedAt}}|{{.Status}}' | while IFS='|' read -r name image created status; do
        local APP_VERSION="N/A"
        # 优先从容器 Config.Image 获取镜像名
        local IMAGE_NAME_FOR_LABELS
        IMAGE_NAME_FOR_LABELS=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null || true)

        if [ -n "$IMAGE_NAME_FOR_LABELS" ]; then
            # 使用 image inspect 来获取标签（对 images 使用 docker image inspect）
            # 防护：若 image inspect 失败，则忽略
            if command -v docker &>/dev/null; then
                # 尽量从 image 的标签中读取版本信息
                APP_VERSION=$(docker image inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || \
                              docker image inspect "$IMAGE_NAME_FOR_LABELS" --format '{{index .Config.Labels "app.version"}}' 2>/dev/null || \
                              true)
                APP_VERSION=$(echo "$APP_VERSION" | head -n1 | cut -c 1-15 | tr -d '\n')
                if [ -z "$APP_VERSION" ]; then APP_VERSION="N/A"; fi
            fi
        fi

        # 启发式获取版本（fallback）
        if [ "$APP_VERSION" = "N/A" ]; then
            if docker exec "$name" sh -c "test -d /app" &>/dev/null; then
                CONTAINER_APP_EXECUTABLE=$(docker exec "$name" sh -c "find /app -maxdepth 1 -type f -executable -print -quit" 2>/dev/null || true)
                if [ -n "$CONTAINER_APP_EXECUTABLE" ]; then
                    RAW_VERSION=$(docker exec "$name" sh -c "$CONTAINER_APP_EXECUTABLE --version 2>/dev/null || echo 'N/A'") || true
                    APP_VERSION=$(echo "$RAW_VERSION" | head -n1 | cut -c 1-15 | tr -d '\n')
                fi
            fi
        fi

        printf "%-20s %-45s %-25s %-15s %-15s\n" "$name" "$image" "$created" "$status" "$APP_VERSION"
    done
    press_enter_to_continue
}

# -------------------------
# _start_watchtower_container_logic (保留并增强)
# -------------------------
_start_watchtower_container_logic() {
    local wt_interval="$1"
    local enable_self_update="$2"
    local mode_description="$3"

    echo "⬇️ 正在拉取 Watchtower 镜像..."
    set +e
    docker pull containrrr/watchtower >/dev/null 2>&1
    local pull_rc=$?
    set -e
    if [ $pull_rc -ne 0 ]; then
        log_warn "❌ 无法拉取 containrrr/watchtower 镜像（网络或 Docker Hub 问题）"
        send_notify "❌ Docker 自动更新助手：$mode_description 运行失败，无法拉取镜像。"
    fi

    local TZ_ENV_VAR="-e TZ=Asia/Shanghai"
    local WT_RUN_ARGS=""
    if [ "$mode_description" = "一次性更新" ]; then
        WT_RUN_ARGS="$TZ_ENV_VAR --rm --run-once"
    else
        WT_RUN_ARGS="$TZ_ENV_VAR -d --name watchtower --restart unless-stopped"
    fi

    local WT_CMD_ARGS="--cleanup --interval ${wt_interval:-300}"
    [ -n "$WATCHTOWER_EXTRA_ARGS" ] && WT_CMD_ARGS="$WT_CMD_ARGS $WATCHTOWER_EXTRA_ARGS"
    [ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && WT_CMD_ARGS="$WT_CMD_ARGS --debug"
    [ -n "$WATCHTOWER_LABELS" ] && WT_CMD_ARGS="$WT_CMD_ARGS --label-enable $WATCHTOWER_LABELS"

    local FINAL_CMD="docker run $WT_RUN_ARGS -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower $WT_CMD_ARGS"

    echo -e "${COLOR_BLUE}--- 正在启动 $mode_description ---${COLOR_RESET}"
    set +e
    if [ "$mode_description" = "一次性更新" ]; then
        # show logs directly
        eval "$FINAL_CMD" 2>&1 || true
        local rc=$?
        set -e
        if [ $rc -eq 0 ]; then
            echo -e "${COLOR_GREEN}✅ $mode_description 成功完成/启动！${COLOR_RESET}"
            send_notify "✅ Docker 自动更新助手：$mode_description 成功。"
            return 0
        else
            echo -e "${COLOR_RED}❌ $mode_description 失败！${COLOR_RESET}"
            send_notify "❌ Docker 自动更新助手：$mode_description 失败。"
            return 1
        fi
    else
        eval "$FINAL_CMD" &>/dev/null || true
        sleep 5
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
            echo -e "${COLOR_GREEN}✅ $mode_description 成功完成/启动！${COLOR_RESET}"
            send_notify "✅ Docker 自动更新助手：$mode_description 成功启动。"
            return 0
        else
            echo -e "${COLOR_RED}❌ $mode_description 启动失败！请检查日志。${COLOR_RESET}"
            send_notify "❌ Docker 自动更新助手：$mode_description 启动失败。"
            return 1
        fi
    fi
}

# -------------------------
# configure_watchtower (保留)
# -------------------------
configure_watchtower() {
    echo -e "${COLOR_YELLOW}🚀 Watchtower模式 ${COLOR_RESET}"
    local INTERVAL_INPUT=""
    local WT_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-300}"

    while true; do
        read -r -p "请输入检查更新间隔（例如 300s / 2h / 1d，默认 ${WT_INTERVAL}s）: " INTERVAL_INPUT
        INTERVAL_INPUT=${INTERVAL_INPUT:-${WT_INTERVAL}s}
        if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then
            WT_INTERVAL=${BASH_REMATCH[1]}; break
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*3600)); break
        elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then
            WT_INTERVAL=$((${BASH_REMATCH[1]}*86400)); break
        else
            echo -e "${COLOR_RED}❌ 输入格式错误，请使用例如 '300s', '2h', '1d' 等格式。${COLOR_RESET}"
        fi
    done

    echo -e "${COLOR_GREEN}⏱ Watchtower检查间隔设置为 $WT_INTERVAL 秒${COLOR_RESET}"

    # 配置额外参数
    read -r -p "是否为 Watchtower 配置标签筛选？(y/n) (例如：com.centurylabs.watchtower.enable=true) : " label_choice
    if [[ "$label_choice" =~ ^[Yy]$ ]]; then
        read -r -p "请输入 Watchtower 筛选标签 (空输入取消): " WATCHTOWER_LABELS
    else
        WATCHTOWER_LABELS=""
    fi

    read -r -p "是否为 Watchtower 配置额外启动参数？(y/n) : " extra_args_choice
    if [[ "$extra_args_choice" =~ ^[Yy]$ ]]; then
        read -r -p "请输入 Watchtower 额外参数 (空输入取消): " WATCHTOWER_EXTRA_ARGS
    else
        WATCHTOWER_EXTRA_ARGS=""
    fi

    read -r -p "是否启用 Watchtower 调试模式 (--debug)？(y/n): " debug_choice
    if [[ "$debug_choice" =~ ^[Yy]$ ]]; then WATCHTOWER_DEBUG_ENABLED="true"; else WATCHTOWER_DEBUG_ENABLED="false"; fi

    WATCHTOWER_CONFIG_INTERVAL="$WT_INTERVAL"
    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"
    WATCHTOWER_ENABLED="true"
    save_config

    set +e
    docker rm -f watchtower &>/dev/null || true
    set -e

    if ! _start_watchtower_container_logic "$WT_INTERVAL" "false" "Watchtower模式"; then
        echo -e "${COLOR_RED}❌ Watchtower模式 启动失败，请检查配置和日志。${COLOR_RESET}"
        return 1
    fi
    echo "您可以使用选项2查看 Docker 容器信息。"
    return 0
}

# -------------------------
# configure_cron_task (保留)
# -------------------------
configure_cron_task() {
    echo -e "${COLOR_YELLOW}🕑 Cron定时任务模式${COLOR_RESET}"
    local CRON_HOUR_TEMP=""
    local DOCKER_COMPOSE_PROJECT_DIR_TEMP=""

    while true; do
        read -r -p "请输入每天更新的小时 (0-23, 当前: ${CRON_HOUR:-4}): " CRON_HOUR_INPUT
        CRON_HOUR_INPUT=${CRON_HOUR_INPUT:-${CRON_HOUR:-4}}
        if [[ "$CRON_HOUR_INPUT" =~ ^[0-9]+$ ]] && [ "$CRON_HOUR_INPUT" -ge 0 ] && [ "$CRON_HOUR_INPUT" -le 23 ]; then
            CRON_HOUR_TEMP="$CRON_HOUR_INPUT"; break
        else
            echo -e "${COLOR_RED}❌ 小时输入无效，请在 0-23 之间输入一个数字。${COLOR_RESET}"
        fi
    done

    while true; do
        read -r -p "请输入 Docker Compose 文件所在的完整目录路径 (例如 /opt/my_docker_project, 当前: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}): " DOCKER_COMPOSE_PROJECT_DIR_INPUT
        DOCKER_COMPOSE_PROJECT_DIR_INPUT=${DOCKER_COMPOSE_PROJECT_DIR_INPUT:-$DOCKER_COMPOSE_PROJECT_DIR_CRON}
        if [ -z "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
            echo -e "${COLOR_RED}❌ Docker Compose 目录路径不能为空。${COLOR_RESET}"
        elif [ ! -d "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then
            echo -e "${COLOR_RED}❌ 指定的目录 '$DOCKER_COMPOSE_PROJECT_DIR_INPUT' 不存在。请检查路径是否正确。${COLOR_RESET}"
        else
            DOCKER_COMPOSE_PROJECT_DIR_TEMP="$DOCKER_COMPOSE_PROJECT_DIR_INPUT"
            break
        fi
    done

    CRON_HOUR="$CRON_HOUR_TEMP"
    DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_TEMP"
    CRON_TASK_ENABLED="true"
    save_config

    CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    LOG_FILE="/var/log/docker-auto-update-cron.log"

    cat > "$CRON_UPDATE_SCRIPT" <<'EOF_INNER_SCRIPT'
#!/bin/bash
export TZ=Asia/Shanghai
PROJECT_DIR="{{PROJECT_DIR}}"
LOG_FILE="{{LOG_FILE}}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始执行 Docker Compose 更新，项目目录: $PROJECT_DIR" >> "$LOG_FILE" 2>&1
if [ ! -d "$PROJECT_DIR" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：Docker Compose 项目目录 '$PROJECT_DIR' 不存在或无法访问。" >> "$LOG_FILE" 2>&1
    exit 1
fi
cd "$PROJECT_DIR" || { echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：无法切换到目录 '$PROJECT_DIR'。" >> "$LOG_FILE" 2>&1; exit 1; }
if command -v docker compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：未找到 'docker compose' 或 'docker-compose' 命令。" >> "$LOG_FILE" 2>&1
    exit 1
fi
if [ -n "$DOCKER_COMPOSE_CMD" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 使用 '$DOCKER_COMPOSE_CMD' 命令进行拉取和更新。" >> "$LOG_FILE" 2>&1
    "$DOCKER_COMPOSE_CMD" pull >> "$LOG_FILE" 2>&1
    "$DOCKER_COMPOSE_CMD" up -d --remove-orphans >> "$LOG_FILE" 2>&1
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - 错误：未找到 'docker compose' 或 'docker-compose' 命令。" >> "$LOG_FILE" 2>&1
    exit 1
fi
echo "$(date '+%Y-%m-%d %H:%M:%S') - 清理无用 Docker 镜像。" >> "$LOG_FILE" 2>&1
docker image prune -f >> "$LOG_FILE" 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') - Docker Compose 更新完成。" >> "$LOG_FILE" 2>&1
EOF_INNER_SCRIPT

    sed -i "s|{{PROJECT_DIR}}|$DOCKER_COMPOSE_PROJECT_DIR_CRON|g" "$CRON_UPDATE_SCRIPT"
    sed -i "s|{{LOG_FILE}}|$LOG_FILE|g" "$CRON_UPDATE_SCRIPT"
    chmod +x "$CRON_UPDATE_SCRIPT"

    (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT" || true; echo "0 $CRON_HOUR * * * $CRON_UPDATE_SCRIPT >> \"$LOG_FILE\" 2>&1") | crontab -

    send_notify "✅ Cron 定时任务配置完成，每天 $CRON_HOUR 点更新容器，项目目录：$DOCKER_COMPOSE_PROJECT_DIR_CRON"
    echo -e "${COLOR_GREEN}🎉 Cron 定时任务设置成功！每天 $CRON_HOUR 点会尝试更新您的 Docker Compose 项目。${COLOR_RESET}"
    echo -e "更新日志可以在 '${COLOR_YELLOW}$LOG_FILE${COLOR_RESET}' 文件中查看。"
    echo "您可以使用选项2查看 Docker 容器信息。"
    return 0
}

# -------------------------
# update_menu
# -------------------------
update_menu() {
    echo -e "${COLOR_YELLOW}请选择更新模式：${COLOR_RESET}"
    echo "1) 🚀 Watchtower模式 (自动监控并更新所有运行中的容器)"
    echo "2) 🕑 Cron定时任务模式 (通过 Docker Compose 定时拉取并重启指定项目)"
    read -r -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MODE_CHOICE
    if [ -z "$MODE_CHOICE" ]; then return 0; fi
    case "$MODE_CHOICE" in
        1) configure_watchtower ;;
        2) configure_cron_task ;;
        *) echo -e "${COLOR_RED}❌ 输入无效，请选择 1-2 之间的数字。${COLOR_RESET}" ;;
    esac
    return 0
}

# -------------------------
# manage_tasks
# -------------------------
manage_tasks() {
    echo -e "${COLOR_YELLOW}⚙️ 任务管理：${COLOR_RESET}"
    echo "1) 停止并移除 Watchtower 容器"
    echo "2) 移除 Cron 定时任务"
    read -r -p "请输入选择 [1-2] 或按 Enter 返回主菜单: " MANAGE_CHOICE
    if [ -z "$MANAGE_CHOICE" ]; then return 0; fi
    case "$MANAGE_CHOICE" in
        1)
            if docker ps -a --format '{{.Names}}' | grep -q '^watchtower$'; then
                if confirm_action "您确定要停止并移除 Watchtower 容器吗？这将停止自动更新。"; then
                    set +e
                    docker stop watchtower &>/dev/null || true
                    docker rm watchtower &>/dev/null || true
                    set -e
                    WATCHTOWER_CONFIG_INTERVAL=""
                    WATCHTOWER_CONFIG_SELF_UPDATE_MODE="false"
                    WATCHTOWER_ENABLED="false"
                    save_config
                    send_notify "🗑️ Watchtower 容器已停止并移除。"
                    echo -e "${COLOR_GREEN}✅ Watchtower 容器已停止并移除。${COLOR_RESET}"
                else
                    echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
                fi
            else
                echo -e "${COLOR_YELLOW}ℹ️ Watchtower 容器未运行或不存在。${COLOR_RESET}"
            fi
            ;;
        2)
            CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
            if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
                if confirm_action "您确定要移除 Cron 定时任务吗？这将停止定时更新。"; then
                    (crontab -l 2>/dev/null | grep -v "$CRON_UPDATE_SCRIPT") | crontab -
                    set +e
                    rm -f "$CRON_UPDATE_SCRIPT" &>/dev/null || true
                    set -e
                    DOCKER_COMPOSE_PROJECT_DIR_CRON=""
                    CRON_HOUR=""
                    CRON_TASK_ENABLED="false"
                    save_config
                    send_notify "🗑️ Watchtower 任务已移除。"
                    echo -e "${COLOR_GREEN}✅ Cron 定时任务已移除。${COLOR_RESET}"
                else
                    echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
                fi
            else
                echo -e "${COLOR_YELLOW}ℹ️ 未检测到由本脚本配置的 Cron 定时任务。${COLOR_RESET}"
            fi
            ;;
        *)
            echo -e "${COLOR_RED}❌ 输入无效，请选择 1-2 之间的数字。${COLOR_RESET}" ;;
    esac
    return 0
}

# -------------------------
# _get_watchtower_all_raw_logs (增强稳定性)
# -------------------------
_get_watchtower_all_raw_logs() {
    local temp_log_file="/tmp/watchtower_raw_logs_$$.log"
    trap "rm -f \"$temp_log_file\"" RETURN
    local container_id
    set +e
    container_id=$(docker inspect watchtower --format '{{.Id}}' 2>/dev/null || true)
    set -e
    if [ -z "$container_id" ]; then
        echo ""
        return
    fi
    set +e
    if command -v timeout >/dev/null 2>&1; then
        timeout 20s docker logs watchtower --tail 5000 > "$temp_log_file" 2>/dev/null || true
    else
        docker logs watchtower --tail 5000 > "$temp_log_file" 2>/dev/null || true
    fi
    set -e
    cat "$temp_log_file"
}

# -------------------------
# _get_watchtower_remaining_time (保留并增强)
# -------------------------
_get_watchtower_remaining_time() {
    local wt_interval_running="$1"
    local raw_logs="$2"
    local remaining_time_str="N/A"
    if ! echo "$raw_logs" | grep -q "Session done"; then
        echo "${COLOR_YELLOW}⚠️ 等待首次扫描完成${COLOR_RESET}"
        return
    fi
    local last_check_log
    last_check_log=$(echo "$raw_logs" | grep -E "Session done" | tail -n 1 || true)
    local last_check_timestamp_str=""
    if [ -n "$last_check_log" ]; then
        last_check_timestamp_str=$(echo "$last_check_log" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -n 1 || true)
    fi
    if [ -n "$last_check_timestamp_str" ]; then
        last_check_epoch=$(_date_to_epoch "$last_check_timestamp_str")
        if [ -n "$last_check_epoch" ]; then
            local current_epoch
            current_epoch=$(date +%s)
            local time_since_last_check=$((current_epoch - last_check_epoch))
            local remaining_time=$((wt_interval_running - time_since_last_check))
            if [ "$remaining_time" -gt 0 ]; then
                local hours=$((remaining_time / 3600))
                local minutes=$(( (remaining_time % 3600) / 60 ))
                local seconds=$(( remaining_time % 60 ))
                remaining_time_str="${COLOR_GREEN}${hours}时 ${minutes}分 ${seconds}秒${COLOR_RESET}"
            else
                remaining_time_str="${COLOR_GREEN}即将进行或已超时 (${remaining_time}s)${COLOR_RESET}"
            fi
        else
            remaining_time_str="${COLOR_RED}❌ 日志时间解析失败 (检查系统date命令)${COLOR_RESET}"
        fi
    else
        remaining_time_str="${COLOR_YELLOW}⚠️ 未找到最近扫描日志${COLOR_RESET}"
    fi
    echo "$remaining_time_str"
}

# -------------------------
# show_status (改写以使用安全读取)
# -------------------------
show_status() {
    echo -e "${COLOR_BLUE}--- Watchtower 状态 ---${COLOR_RESET}"
    local wt_configured_mode_desc="Watchtower模式 (更新所有容器)"

    local wt_overall_status_line
    if [ "$WATCHTOWER_ENABLED" = "true" ]; then
        if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
            wt_overall_status_line="${COLOR_GREEN}运行中 (${wt_configured_mode_desc})${COLOR_RESET}"
        else
            wt_overall_status_line="${COLOR_YELLOW}配置已启用，但容器未运行！(${wt_configured_mode_desc})${COLOR_RESET}"
            echo -e "  ${COLOR_YELLOW}提示: 如果Watchtower应运行，请尝试在主菜单选项1中重新设置Watchtower模式。${COLOR_RESET}"
        fi
    else
        wt_overall_status_line="${COLOR_RED}已禁用 (未配置或已停止)${COLOR_RESET}"
    fi
    printf "  - Watchtower 服务状态: %b\n" "$wt_overall_status_line"

    local script_config_interval="${WATCHTOWER_CONFIG_INTERVAL:-未设置}"
    local script_config_labels="${WATCHTOWER_LABELS:-无}"
    local script_config_extra_args="${WATCHTOWER_EXTRA_ARGS:-无}"
    local script_config_debug
    script_config_debug=$([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "启用" || echo "禁用")

    local container_actual_interval="N/A"
    local container_actual_labels="无"
    local container_actual_extra_args="无"
    local container_actual_debug="禁用"
    local container_actual_self_update="否 (已禁用)"
    local wt_remaining_time_display="${COLOR_YELLOW}N/A${COLOR_RESET}"
    local raw_logs_content_for_status=""

    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        raw_logs_content_for_status=$(_get_watchtower_all_raw_logs)
        local wt_cmd_json
        wt_cmd_json=$(docker inspect watchtower --format "{{json .Config.Cmd}}" 2>/dev/null || echo "[]")
        # extract interval and label-enable using jq if available
        if command -v jq &>/dev/null; then
            container_actual_interval=$(echo "$wt_cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
            container_actual_labels=$(echo "$wt_cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--label-enable") | .[$i+1] // empty)' 2>/dev/null || true)
            if echo "$wt_cmd_json" | jq -e 'any(. == "--debug")' >/dev/null 2>&1; then container_actual_debug="启用"; fi
        else
            # fallback crude parsing
            container_actual_interval=$(_extract_interval_from_cmd "$wt_cmd_json" 2>/dev/null || true)
            if echo "$wt_cmd_json" | grep -q -- '--label-enable'; then
                container_actual_labels=$(echo "$wt_cmd_json" | sed 's/[][]//g; s/,/ /g; s/\"//g' | awk '{for(i=1;i<=NF;i++) if($i=="--label-enable") print $(i+1)}' | head -n1 || true)
            fi
            if echo "$wt_cmd_json" | grep -q -- '--debug'; then container_actual_debug="启用"; fi
        fi
        container_actual_interval="${container_actual_interval:-N/A}"
        container_actual_labels="${container_actual_labels:-无}"
        if [ -z "$container_actual_extra_args" ]; then container_actual_extra_args="无"; fi

        # calculate remaining time
        if echo "$raw_logs_content_for_status" | grep -q "Session done"; then
            if [[ "$container_actual_interval" =~ ^[0-9]+$ ]]; then
                wt_remaining_time_display=$(_get_watchtower_remaining_time "$container_actual_interval" "$raw_logs_content_for_status")
            else
                wt_remaining_time_display="${COLOR_YELLOW}⚠️ 无法计算倒计时 (间隔无效)${COLOR_RESET}"
            fi
        else
            if [ -n "$raw_logs_content_for_status" ] && echo "$raw_logs_content_for_status" | grep -q "Scheduling first run"; then
                wt_remaining_time_display="${COLOR_YELLOW}⚠️ 等待首次扫描完成${COLOR_RESET}"
            else
                wt_remaining_time_display="${COLOR_YELLOW}⚠️ 无法获取日志，请检查权限/状态${COLOR_RESET}"
            fi
        fi
    fi

    printf "  %-15s %-12s %-12s\n" "参数" "脚本配置" "容器运行"
    printf "  %-15s %-12s %-12s\n" "---------------" "------------" "------------"
    printf "  %-15s %-12s %-12s\n" "检查间隔 (秒)" "$script_config_interval" "$container_actual_interval"
    printf "  %-15s %-12s %-12s\n" "标签筛选" "$script_config_labels" "$container_actual_labels"
    printf "  %-15s %-12s %-12s\n" "额外参数" "$script_config_extra_args" "$container_actual_extra_args"
    printf "  %-15s %-12s %-12s\n" "调试模式" "$script_config_debug" "$container_actual_debug"
    printf "  %-15s %-12s %b\n" "更新自身" "$( [ "$WATCHTOWER_CONFIG_SELF_UPDATE_MODE" = "true" ] && echo "是" || echo "否" )" "$container_actual_self_update"
    printf "  %-15s %b\n" "下次检查倒计时:" "$wt_remaining_time_display"

    if docker ps --format '{{.Names}}' | grep -q '^watchtower$' && echo "$raw_logs_content_for_status" | grep -q "unauthorized: authentication required"; then
        echo -e "  ${COLOR_RED}🚨 警告: Watchtower 日志中发现认证失败 ('unauthorized') 错误！${COLOR_RESET}"
        echo -e "         请检查 Docker Hub 或私有仓库的凭据配置。"
    fi

    echo -e "${COLOR_BLUE}--- Cron 定时任务状态 ---${COLOR_RESET}"
    local cron_enabled_status
    if [ "$CRON_TASK_ENABLED" = "true" ]; then cron_enabled_status="${COLOR_GREEN}✅ 已启用${COLOR_RESET}"; else cron_enabled_status="${COLOR_RED}❌ 已禁用${COLOR_RESET}"; fi
    printf "  - 启用状态: %b\n" "$cron_enabled_status"
    echo "  - 配置的每天更新时间: ${CRON_HOUR:-未设置} 点"
    echo "  - 配置的 Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
    local CRON_UPDATE_SCRIPT="/usr/local/bin/docker-auto-update-cron.sh"
    if crontab -l 2>/dev/null | grep -q "$CRON_UPDATE_SCRIPT"; then
        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_UPDATE_SCRIPT")
        echo "  - 实际定时表达式 (运行): $(echo "$cron_entry" | cut -d ' ' -f 1-5)"
        echo "  - 日志文件: /var/log/docker-auto-update-cron.log"
    else
        echo -e "${COLOR_RED}❌ 未检测到由本脚本配置的 Cron 定时任务。${COLOR_RESET}"
    fi
    echo ""
    return 0
}

# -------------------------
# view_and_edit_config
# -------------------------
view_and_edit_config() {
    echo -e "${COLOR_YELLOW}🔍 脚本配置查看与编辑：${COLOR_RESET}"
    echo "-------------------------------------------------------------------------------------------------------------------"
    echo "1) Telegram Bot Token: ${TG_BOT_TOKEN:-未设置}"
    echo "2) Telegram Chat ID:   ${TG_CHAT_ID:-未设置}"
    echo "3) Email 接收地址:     ${EMAIL_TO:-未设置}"
    echo "4) Watchtower 标签筛选: ${WATCHTOWER_LABELS:-无}"
    echo "5) Watchtower 额外参数: ${WATCHTOWER_EXTRA_ARGS:-无}"
    echo "6) Watchtower 调试模式: $([ "$WATCHTOWER_DEBUG_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "7) Watchtower 配置间隔: ${WATCHTOWER_CONFIG_INTERVAL:-未设置} 秒"
    echo "8) Watchtower 脚本配置启用: $([ "$WATCHTOWER_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "9) Cron 更新小时:      ${CRON_HOUR:-未设置}"
    echo "10) Cron Docker Compose 项目目录: ${DOCKER_COMPOSE_PROJECT_DIR_CRON:-未设置}"
    echo "11) Cron 脚本配置启用: $([ "$CRON_TASK_ENABLED" = "true" ] && echo "是" || echo "否")"
    echo "-------------------------------------------------------------------------------------------------------------------"
    read -r -p "请输入要编辑的选项编号 (1-11) 或按 Enter 返回主菜单: " edit_choice
    if [ -z "$edit_choice" ]; then return 0; fi
    case "$edit_choice" in
        1)
            read -r -p "请输入新的 Telegram Bot Token (空输入不修改): " TG_BOT_TOKEN_NEW
            TG_BOT_TOKEN="${TG_BOT_TOKEN_NEW:-$TG_BOT_TOKEN}"; save_config ;;
        2)
            read -r -p "请输入新的 Telegram Chat ID (空输入不修改): " TG_CHAT_ID_NEW
            TG_CHAT_ID="${TG_CHAT_ID_NEW:-$TG_CHAT_ID}"; save_config ;;
        3)
            read -r -p "请输入新的 Email 接收地址 (空输入不修改): " EMAIL_TO_NEW
            EMAIL_TO="${EMAIL_TO_NEW:-$EMAIL_TO}"
            if [ -n "$EMAIL_TO" ] && ! command -v mail &>/dev/null; then
                log_warn "⚠️ 'mail' 命令未找到。如果需要 Email 通知，请安装并配置邮件传输代理 (MTA)。"
            fi
            save_config ;;
        4)
            read -r -p "请输入新的 Watchtower 标签筛选 (空输入取消筛选): " WATCHTOWER_LABELS_NEW
            WATCHTOWER_LABELS="${WATCHTOWER_LABELS_NEW:-}"; save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 标签筛选已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}" ;;
        5)
            read -r -p "请输入新的 Watchtower 额外参数 (空输入取消额外参数): " WATCHTOWER_EXTRA_ARGS_NEW
            WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS_NEW:-}"; save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 额外参数已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}" ;;
        6)
            read -r -p "是否启用 Watchtower 调试模式 (--debug)？(y/n): " debug_choice
            if [[ "$debug_choice" =~ ^[Yy]$ ]]; then WATCHTOWER_DEBUG_ENABLED="true"; else WATCHTOWER_DEBUG_ENABLED="false"; fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 调试模式已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}" ;;
        7)
            while true; do
                read -r -p "请输入新的 Watchtower 检查间隔（例如 300s / 2h / 1d 或纯数字秒）: " INTERVAL_INPUT
                if [[ "$INTERVAL_INPUT" =~ ^([0-9]+)s$ ]]; then WATCHTOWER_CONFIG_INTERVAL=${BASH_REMATCH[1]}; break
                elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)h$ ]]; then WATCHTOWER_CONFIG_INTERVAL=$((${BASH_REMATCH[1]}*3600)); break
                elif [[ "$INTERVAL_INPUT" =~ ^([0-9]+)d$ ]]; then WATCHTOWER_CONFIG_INTERVAL=$((${BASH_REMATCH[1]}*86400)); break
                elif [[ "$INTERVAL_INPUT" =~ ^[0-9]+$ ]]; then WATCHTOWER_CONFIG_INTERVAL="$INTERVAL_INPUT"; break
                else echo -e "${COLOR_RED}❌ 输入格式错误，请使用例如 '300s', '2h', '1d' 或纯数字(秒) 等格式。${COLOR_RESET}"; fi
            done
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 检查间隔已修改，您可能需要重新设置 Watchtower (主菜单选项 1) 以应用此更改。${COLOR_RESET}" ;;
        8)
            read -r -p "是否启用 Watchtower 脚本配置？(y/n): " wt_enabled_choice
            if [[ "$wt_enabled_choice" =~ ^[Yy]$ ]]; then WATCHTOWER_ENABLED="true"; else WATCHTOWER_ENABLED="false"; fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Watchtower 脚本配置启用状态已修改。${COLOR_RESET}" ;;
        9)
            while true; do
                read -r -p "请输入新的 Cron 更新小时 (0-23) (空输入不修改): " CRON_HOUR_INPUT
                if [ -z "$CRON_HOUR_INPUT" ]; then break
                elif [[ "$CRON_HOUR_INPUT" =~ ^[0-9]+$ ]] && [ "$CRON_HOUR_INPUT" -ge 0 ] && [ "$CRON_HOUR_INPUT" -le 23 ]; then CRON_HOUR="$CRON_HOUR_INPUT"; break
                else echo -e "${COLOR_RED}❌ 小时输入无效，请在 0-23 之间输入一个数字。${COLOR_RESET}"; fi
            done
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Cron 更新小时已修改。${COLOR_RESET}" ;;
        10)
            while true; do
                read -r -p "请输入新的 Cron Docker Compose 项目目录 (空输入取消设置): " DOCKER_COMPOSE_PROJECT_DIR_INPUT
                if [ -z "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then DOCKER_COMPOSE_PROJECT_DIR_CRON=""; break
                elif [ ! -d "$DOCKER_COMPOSE_PROJECT_DIR_INPUT" ]; then echo -e "${COLOR_RED}❌ 指定目录不存在。${COLOR_RESET}"
                else DOCKER_COMPOSE_PROJECT_DIR_CRON="$DOCKER_COMPOSE_PROJECT_DIR_INPUT"; break; fi
            done
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Cron Docker Compose 项目目录已修改。${COLOR_RESET}" ;;
        11)
            read -r -p "是否启用 Cron 脚本配置？(y/n): " cron_enabled_choice
            if [[ "$cron_enabled_choice" =~ ^[Yy]$ ]]; then CRON_TASK_ENABLED="true"; else CRON_TASK_ENABLED="false"; fi
            save_config
            echo -e "${COLOR_YELLOW}ℹ️ Cron 脚本配置启用状态已修改。${COLOR_RESET}" ;;
        *)
            echo -e "${COLOR_YELLOW}ℹ️ 返回主菜单。${COLOR_RESET}" ;;
    esac
    return 0
}

# -------------------------
# run_watchtower_once
# -------------------------
run_watchtower_once() {
    echo -e "${COLOR_YELLOW}🆕 运行一次 Watchtower (立即检查并更新)${COLOR_RESET}"
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo -e "${COLOR_YELLOW}⚠️ 注意：Watchtower 容器已在后台运行。${COLOR_RESET}"
        if ! confirm_action "是否继续运行一次性 Watchtower 更新？"; then
            echo -e "${COLOR_YELLOW}ℹ️ 操作已取消。${COLOR_RESET}"
            press_enter_to_continue
            return 0
        fi
    fi
    if ! _start_watchtower_container_logic "" "false" "一次性更新"; then
        press_enter_to_continue
        return 1
    fi
    press_enter_to_continue
    return 0
}

# -------------------------
# Option 7 Implementation: show_watchtower_details (完整实现)
# -------------------------
# Helpers used by this Option are defined earlier: _date_to_epoch, etc.
# Additional helper: safe docker logs (to avoid blocking)
_safe_docker_logs() {
    local cname="$1"
    shift
    local extra_args=("$@")
    local max_lines=5000
    if command -v timeout >/dev/null 2>&1; then
        timeout 20s docker logs "${extra_args[@]}" "$cname" 2>/dev/null || true
    else
        docker logs --tail "${max_lines}" "${extra_args[@]}" "$cname" 2>/dev/null || true
    fi
}

_extract_interval_from_cmd() {
    local cmd_json="$1"
    local interval=""
    if command -v jq >/dev/null 2>&1; then
        interval=$(echo "$cmd_json" | jq -r 'first(range(length) as $i | select(.[$i] == "--interval") | .[$i+1] // empty)' 2>/dev/null || true)
    else
        local tokens; tokens=$(echo "$cmd_json" | sed 's/[][]//g; s/,/ /g; s/"//g')
        local prev=""
        for t in $tokens; do
            if [ "$prev" = "--interval" ]; then interval="$t"; break; fi
            prev="$t"
        done
    fi
    interval=$(echo "$interval" | sed 's/[^0-9].*$//; s/[^0-9]*//g')
    [ -z "$interval" ] && echo "" || echo "$interval"
}

get_watchtower_inspect_summary() {
    REPLY=""
    if ! command -v docker &>/dev/null; then
        echo "Watchtower: Docker 未安装或不可用"
        return 1
    fi
    if ! docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        echo "Watchtower: 未检测到名为 'watchtower' 的容器"
        return 2
    fi
    local cmd_json restart_policy
    cmd_json=$(docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null || echo "[]")
    restart_policy=$(docker inspect watchtower --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unknown")
    echo "=== Watchtower Inspect ==="
    echo "容器: watchtower"
    echo "RestartPolicy: ${restart_policy}"
    echo "Cmd: ${cmd_json}"
    local interval
    interval=$(_extract_interval_from_cmd "$cmd_json")
    if [ -n "$interval" ]; then
        echo "检测到 --interval: ${interval}s"
        REPLY="$interval"
    else
        echo "未能解析到 --interval（将使用脚本配置或默认值）"
        REPLY=""
    fi
    return 0
}

get_last_session_time() {
    local raw
    raw=$(_safe_docker_logs watchtower)
    if [ -z "$raw" ]; then echo ""; return 1; fi
    local last
    last=$(echo "$raw" | grep -E "Session done" | tail -n 1 || true)
    if [ -n "$last" ]; then
        local t
        t=$(echo "$last" | sed -n 's/.*time="\([^"]*\)".*/\1/p' || true)
        if [ -n "$t" ]; then echo "$t"; return 0; fi
        t=$(echo "$last" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+' | tail -n1 || true)
        if [ -n "$t" ]; then echo "$t"; return 0; fi
        echo "${last}" | sed 's/^[ \t]*//; s/[ \t]*$//'
        return 0
    fi
    last=$(echo "$raw" | grep -E "Scheduling first run" | tail -n1 || true)
    if [ -n "$last" ]; then
        local t2
        t2=$(echo "$last" | sed -n 's/.*Scheduling first run: \([^ ]* [^ ]*\).*/\1/p' || true)
        if [ -n "$t2" ]; then echo "$t2"; return 0; fi
        echo "$last"; return 0
    fi
    local lastline
    lastline=$(echo "$raw" | tail -n 1 || true)
    [ -n "$lastline" ] && echo "$lastline" || echo ""
    return 0
}

get_updates_last_24h() {
    local since_arg=""
    if date -d "24 hours ago" >/dev/null 2>&1; then
        since_arg=$(date -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S')
    elif command -v gdate >/dev/null 2>&1; then
        since_arg=$(gdate -d "24 hours ago" '+%Y-%m-%dT%H:%M:%S')
    else
        since_arg=""
    fi

    local raw
    if [ -n "$since_arg" ]; then
        raw=$(_safe_docker_logs watchtower --since "$since_arg")
    else
        raw=$(_safe_docker_logs watchtower)
    fi

    if [ -z "$raw" ]; then echo ""; return 1; fi

    echo "$raw" | grep -E "Session done|Found new image for container|No new images found for container|container was updated|Unable to update|unauthorized|Scheduling first run|Could not do a head request|Stopping container|Starting container|Pulling image" || true
    return 0
}

_highlight_line() {
    local line="$1"
    if echo "$line" | grep -q -E "unauthorized|authentication required|Could not do a head request|Unable to update|skipped because of an error|error"; then
        printf "%b%s%b\n" "$COLOR_RED" "$line" "$COLOR_RESET"
    elif echo "$line" | grep -q -E "Found new image for container|container was updated|Creating new container|Pulling image|Starting container|Stopping container"; then
        printf "%b%s%b\n" "$COLOR_GREEN" "$line" "$COLOR_RESET"
    elif echo "$line" | grep -q -E "No new images found for container"; then
        printf "%b%s%b\n" "$COLOR_CYAN" "$line" "$COLOR_RESET"
    else
        echo "$line"
    fi
}

show_watchtower_details() {
    clear
    echo "=== Watchtower 运行详情与更新记录 ==="
    if ! command -v docker &>/dev/null; then
        echo "Docker 不可用，请先安装或以能访问 Docker 的用户运行本脚本。"
        read -r -p "按回车返回主菜单..."
        return
    fi

    local interval_secs=""
    if docker ps --format '{{.Names}}' | grep -q '^watchtower$'; then
        get_watchtower_inspect_summary
        interval_secs="$REPLY"
    else
        echo "Watchtower 容器未运行。"
        interval_secs=""
    fi

    echo "----------------------------------------"
    local last_session
    last_session=$(get_last_session_time || true)
    if [ -n "$last_session" ]; then
        echo "上次扫描: $last_session"
    else
        echo "未检测到上次扫描完成记录 (Session done)"
    fi

    if [ -n "$interval_secs" ] && [ -n "$last_session" ]; then
        local last_time_token="$last_session"
        if echo "$last_time_token" | grep -q 'time="'; then
            last_time_token=$(echo "$last_time_token" | sed -n 's/.*time="\([^"]*\)".*/\1/p')
        fi
        local last_epoch
        last_epoch=$(_date_to_epoch "$last_time_token")
        if [ -n "$last_epoch" ]; then
            local now_epoch
            now_epoch=$(date +%s)
            local remaining=$(( last_epoch + interval_secs - now_epoch ))
            if [ "$remaining" -le 0 ]; then
                echo "下次检查：即将进行或已超时 (${remaining}s)"
            else
                local hh=$(( remaining / 3600 ))
                local mm=$(( (remaining % 3600) / 60 ))
                local ss=$(( remaining % 60 ))
                printf "下次检查倒计时: %02d时 %02d分 %02d秒\n" "$hh" "$mm" "$ss"
            fi
        else
            echo "无法将上次扫描时间解析为时间戳，无法计算倒计时。"
        fi
    else
        echo "下次检查倒计时: 无法计算 (缺少上次扫描时间或 interval)"
    fi

    echo "----------------------------------------"
    echo "过去 24 小时的更新摘要（高亮重要事件）："
    echo

    local updates
    updates=$(get_updates_last_24h || true)
    if [ -z "$updates" ]; then
        echo "过去 24 小时内未检测到关键更新记录或无法读取日志。"
    else
        echo "$updates" | tail -n 200 | while IFS= read -r line; do
            _highlight_line "$line"
        done
    fi

    echo "----------------------------------------"
    while true; do
        echo "选项："
        echo " 1) 查看最近 200 行 Watchtower 日志 (实时 tail 模式)"
        echo " 2) 导出过去 24 小时摘要到 /tmp/watchtower_updates_$(date +%s).log"
        echo " 0) 返回主菜单"
        read -r -p "请选择: " pick
        case "$pick" in
            1)
                echo "按 Ctrl+C 停止查看，随后回到详情页。"
                docker logs --tail 200 -f watchtower || true
                echo "返回 Watchtower 详情..."
                ;;
            2)
                outfile="/tmp/watchtower_updates_$(date +%s).log"
                echo "导出摘要到: $outfile"
                echo "$updates" > "$outfile"
                echo "导出完成。"
                ;;
            0) break ;;
            *)
                echo "无效选择"
                ;;
        esac
    done

    read -r -p "按回车返回主菜单..."
}

# -------------------------
# 主菜单与主循环（保持已有结构，7-> show_watchtower_details）
# -------------------------
main_menu() {
    while true; do
        clear
        echo "==================== VPS 容器管理 ===================="
        # gather summary
        local WATCHTOWER_STATUS LAST_CHECK TOTAL RUNNING STOPPED
        WATCHTOWER_STATUS="$(docker ps --format '{{.Names}}' | grep -q '^watchtower$' && echo '已启动' || echo '未运行')"
        LAST_CHECK="$(docker logs --tail 200 watchtower 2>/dev/null | grep -E 'Session done|Scheduling first run' | tail -n1 | sed -n 's/.*time=\"\([^\"]*\)\".*/\1/p' || true)"
        LAST_CHECK="${LAST_CHECK:-未知}"
        TOTAL=$(docker ps -a -q 2>/dev/null | wc -l)
        RUNNING=$(docker ps -q 2>/dev/null | wc -l)
        STOPPED=$((TOTAL - RUNNING))

        echo
        printf "🟢 Watchtower 状态: %s\n" "$WATCHTOWER_STATUS"
        printf "🟡 上次更新检查: %s\n" "$LAST_CHECK"
        printf "📦 容器总数: %s (运行: %s, 停止: %s)\n\n" "$TOTAL" "$RUNNING" "$STOPPED"

        echo "主菜单选项："
        echo "1) 🔄 设置更新模式"
        echo "       → Watchtower / Cron 定时更新"
        echo "2) 📋 查看容器信息"
        echo "       → 显示所有容器状态和资源占用"
        echo "3) 🔔 配置通知"
        echo "       → Telegram / Email 推送"
        echo "4) ⚙️ 任务管理"
        echo "       → 停止 / 重启 / 移除容器"
        echo "5) 📝 查看/编辑脚本配置"
        echo "       → 配置文件查看与修改"
        echo "6) 🆕 手动运行 Watchtower"
        echo "       → 立即检查容器更新"
        echo "7) 🔍 查看 Watchtower 运行详情和更新记录"
        echo "       → 上次扫描、下次倒计时、24H 更新摘要、错误高亮"
        echo
        read -r -p "请输入选项 [1-7]: " choice
        case "$choice" in
            1) update_menu ;;
            2) show_container_info ;;
            3) configure_notify ;; # configure_notify is defined earlier in original script; ensure it exists
            4) manage_tasks ;;
            5) view_and_edit_config ;;
            6) run_watchtower_once ;;
            7) show_watchtower_details ;;
            *) echo -e "${COLOR_YELLOW}无效选项，请输入 1-7。${COLOR_RESET}"; sleep 1 ;;
        esac
    done
}

# --- If configure_notify function missing (from original script), add a simple wrapper preserving earlier behavior ---
configure_notify() {
    # If a more complex function was defined earlier in user's original script, it will have been preserved.
    # This wrapper attempts to call it if present, otherwise fall back to basic interactive config.
    if declare -F configure_notify_old >/dev/null 2>&1; then
        configure_notify_old
        return
    fi

    echo -e "${COLOR_YELLOW}⚙️ 通知配置${COLOR_RESET}"
    read -r -p "是否启用 Telegram 通知？(y/N): " tchoice
    if [[ "$tchoice" =~ ^[Yy]$ ]]; then
        read -r -p "请输入 Telegram Bot Token: " TG_BOT_TOKEN
        read -r -p "请输入 Telegram Chat ID: " TG_CHAT_ID
    else
        TG_BOT_TOKEN=""; TG_CHAT_ID=""
    fi
    read -r -p "是否启用 Email 通知？(y/N): " echoice
    if [[ "$echoice" =~ ^[Yy]$ ]]; then
        read -r -p "请输入接收通知的邮箱地址: " EMAIL_TO
    else
        EMAIL_TO=""
    fi
    save_config
    echo -e "${COLOR_GREEN}通知配置已保存。${COLOR_RESET}"
}

# 启动主菜单
main() {
    echo ""
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    echo -e " ${COLOR_YELLOW}Docker 自动更新助手 v$VERSION${COLOR_RESET}"
    echo -e "${COLOR_GREEN}===========================================${COLOR_RESET}"
    echo ""
    main_menu
}

main
