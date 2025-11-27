#!/usr/bin/env bash
# =============================================================
# Watchtower 管理模块 v6.4.0 - 官方通知 + 方案 F 中文模板（完整终极版）
# 功能 100% 保留，仅删除自制日志监控，改用官方通知 + 自定义中文模板
# 直接替换原文件即可使用
# =============================================================

SCRIPT_VERSION="v6.4.0"

set -eo pipefail
export LANG=${LANG:-en_US.UTF-8}
export LC_ALL=${LC_ALL:-C.UTF-8}

# --- 加载通用工具函数库 ---
UTILS_PATH="/opt/vps_install_modules/utils.sh"
if [ -f "$UTILS_PATH" ]; then
    source "$UTILS_PATH"
else
    log_err() { echo "[错误] $*" >&2; }
    log_info() { echo "[信息] $*"; }
    log_warn() { echo "[警告] $*"; }
    log_success() { echo "[成功] $*"; }
    _render_menu() { local title="$1"; shift; echo -e "\n${BLUE}--- \( title --- \){NC}"; printf " %s\n" "$@"; }
    press_enter_to_continue() { read -r -p "按 Enter 继续..."; }
    confirm_action() { read -r -p "$1 ([y]/n): " choice; case "$choice" in n|N) return 1;; *) return 0;; esac; }
    GREEN="\033[32m"; RED="\033[31m"; YELLOW="\033[33m"; CYAN="\033[36m"; BLUE="\033[34m"; ORANGE="\033[38;5;208m"; NC="\033[0m"
    log_err "致命错误: 通用工具库 $UTILS_PATH 未找到！"
    exit 1
fi

if ! declare -f run_with_sudo &>/dev/null; then
    log_err "致命错误: run_with_sudo 函数未定义。"
    exit 1
fi

CONFIG_FILE="$HOME/.docker-auto-update-watchtower.conf"

# --- 模块变量 ---
TG_BOT_TOKEN="" TG_CHAT_ID="" EMAIL_TO=""
WATCHTOWER_EXCLUDE_LIST="" WATCHTOWER_EXTRA_ARGS="" WATCHTOWER_DEBUG_ENABLED=""
WATCHTOWER_CONFIG_INTERVAL="" WATCHTOWER_ENABLED=""
WATCHTOWER_NOTIFY_ON_NO_UPDATES=""

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null || true
    local default_interval="21600"
    local default_exclude_list="portainer,portainer_agent"
    local default_notify_on_no_updates="true"

    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
    EMAIL_TO="${EMAIL_TO:-}"
    WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST:-$default_exclude_list}"
    WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS:-}"
    WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED:-false}"
    WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL:-$default_interval}"
    WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED:-false}"
    WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES:-$default_notify_on_no_updates}"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
WATCHTOWER_EXCLUDE_LIST="${WATCHTOWER_EXCLUDE_LIST}"
WATCHTOWER_EXTRA_ARGS="${WATCHTOWER_EXTRA_ARGS}"
WATCHTOWER_DEBUG_ENABLED="${WATCHTOWER_DEBUG_ENABLED}"
WATCHTOWER_CONFIG_INTERVAL="${WATCHTOWER_CONFIG_INTERVAL}"
WATCHTOWER_ENABLED="${WATCHTOWER_ENABLED}"
WATCHTOWER_NOTIFY_ON_NO_UPDATES="${WATCHTOWER_NOTIFY_ON_NO_UPDATES}"
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# --- 依赖检查 ---
command -v docker >/dev/null || { log_err "Docker 未安装"; exit 10; }
docker info >/dev/null 2>&1 || { log_err "Docker 服务未运行"; exit 10; }

load_config

# ==================== 官方通知 + 方案 F 中文模板 ====================
_render_chinese_template() {
    cat <<'EOF'
新版本已部署!

在服务器 {{.Hostname}} 上，
我们为您更新了 {{.Report.Updated}} 个服务:

更新内容:{{range .Report.Scanned}}{{if .Updated}}
 • {{.Container}}{{end}}{{end}}

所有服务均已平稳重启。

{{else}}同步检查完成

服务器 {{.Hostname}} 上的所有
Docker 服务都已是最新版本，无需操作。{{end}}
EOF
}

_add_official_chinese_notification() {
    [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    local url="telegram://$TG_BOT_TOKEN@telegram?channels=$TG_CHAT_ID"
    local template
    template=\( (printf '%s' " \)(_render_chinese_template)" | tr '\n' '\\n' | sed 's/"/\\"/g')
    WATCHTOWER_EXTRA_ARGS="$WATCHTOWER_EXTRA_ARGS --notification-url $url"
    WATCHTOWER_EXTRA_ARGS="$WATCHTOWER_EXTRA_ARGS --notification-template \"$template\""
    [[ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" == "true" ]] && WATCHTOWER_EXTRA_ARGS="$WATCHTOWER_EXTRA_ARGS --notification-report-always"
}

# ==================== 启动逻辑（核心）===================
_start_watchtower_container_logic() {
    load_config
    _add_official_chinese_notification

    local wt_interval="${1:-$WATCHTOWER_CONFIG_INTERVAL}"
    local interactive_mode="${2:-false}"
    local wt_image="containrrr/watchtower:latest"
    local docker_run_args=(-e "TZ=\( {JB_TIMEZONE:-Asia/Shanghai}" -h " \)(hostname)")
    local wt_args=("--cleanup")

    if [ "$interactive_mode" = "true" ]; then
        docker_run_args+=(--rm --name watchtower-once)
        wt_args+=(--run-once)
    else
        docker_run_args+=(-d --name watchtower --restart unless-stopped)
        wt_args+=(--interval "$wt_interval")
    fi

    docker_run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    [[ "$WATCHTOWER_DEBUG_ENABLED" == "true" ]] && wt_args+=(--debug)
    [[ -n "$WATCHTOWER_EXTRA_ARGS" ]] && read -ra extra <<<"\( WATCHTOWER_EXTRA_ARGS"; wt_args+=(" \){extra[@]}")

    local containers=()
    if [[ -n "$WATCHTOWER_EXCLUDE_LIST" ]]; then
        local pattern=$(echo "$WATCHTOWER_EXCLUDE_LIST" | sed 's/,/\\|/g')
        mapfile -t containers < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}' | grep -vE "^(\( {pattern}|watchtower|watchtower-once) \)")
        [[ ${#containers[@]} -eq 0 && "$interactive_mode" != "true" ]] && { log_err "排除列表导致无容器可监控"; return 1; }
    else
        mapfile -t containers < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}')
    fi

    JB_SUDO_LOG_QUIET="true" run_with_sudo docker pull "$wt_image" >/dev/null 2>&1 || true

    local cmd=(docker run "${docker_run_args[@]}" "\( wt_image" " \){wt_args[@]}" "${containers[@]}")
    if [ "$interactive_mode" = "true" ]; then
        log_info "正在执行一次性更新..."
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${cmd[@]}"
    else
        run_with_sudo docker rm -f watchtower &>/dev/null || true
        JB_SUDO_LOG_QUIET="true" run_with_sudo "${cmd[@]}"
        sleep 2
        if run_with_sudo docker ps --format '{{.Names}}' | grep -qFx watchtower; then
            log_success "Watchtower 已启动（官方中文通知已启用）"
            WATCHTOWER_ENABLED="true"; save_config
        else
            log_err "Watchtower 启动失败"
        fi
    fi
}

# ==================== 辅助函数 ====================
_format_seconds_to_human() {
    local total_seconds="$1"
    if ! [[ "\( total_seconds" =~ ^[0-9]+ \) ]] || [ "$total_seconds" -le 0 ]; then echo "N/A"; return; fi
    local days=$((total_seconds / 86400))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))
    local result=""
    ((days>0)) && result+="${days}天"
    ((hours>0)) && result+="${hours}小时"
    ((minutes>0)) && result+="${minutes}分钟"
    ((seconds>0)) && result+="${seconds}秒"
    echo "${result:-0秒}"
}

_prompt_for_interval() {
    local default_interval_seconds="$1"
    local current_display_value="$(_format_seconds_to_human "$default_interval_seconds")"
    while true; do
        local input_value
        input_value=\( (_prompt_user_input "检查间隔 (当前: \){current_display_value}, 支持 1h/30m/1d): " "")
        [[ -z "$input_value" ]] && { echo "$default_interval_seconds"; return; }

        local seconds=0
        if [[ "\( input_value" =~ ^[0-9]+ \) ]]; then
            seconds="$input_value"
        elif [[ "\( input_value" =~ ^([0-9]+)(s|m|h|d) \) ]]; then
            case "${BASH_REMATCH[2]}" in
                s) seconds="${BASH_REMATCH[1]}" ;;
                m) seconds=\( (( \){BASH_REMATCH[1]} * 60 )) ;;
                h) seconds=\( (( \){BASH_REMATCH[1]} * 3600 )) ;;
                d) seconds=\( (( \){BASH_REMATCH[1]} * 86400 )) ;;
            esac
        else
            log_warn "无效格式，请输入秒数或 1h/30m/1d"
            continue
        fi
        ((seconds>0)) && { echo "$seconds"; return; } || log_warn "必须大于0"
    done
}

configure_exclusion_list() {
    declare -A excluded_map
    [[ -n "$WATCHTOWER_EXCLUDE_LIST" ]] && IFS=, read -ra items <<<"\( WATCHTOWER_EXCLUDE_LIST"; for i in " \){items[@]}"; do excluded_map["${i// /}"]=1; done
    while true; do
        clear
        mapfile -t all_containers < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps --format '{{.Names}}')
        local items=() i=1
        for c in "${all_containers[@]}"; do
            [[ -n "${excluded_map[$c]}" ]] && items+=("\( i. [ \){GREEN}✔${NC}] $c") || items+=("$i. [ ] $c")
            ((i++))
        done
        items+=("") items+=("当前排除: ${WATCHTOWER_EXCLUDE_LIST:-无}")
        _render_menu "配置排除列表（输入编号切换，c完成，回车清空）" "${items[@]}"
        read -r choice
        case "$choice" in
            c|C) break ;;
            "") excluded_map=(); log_info "已清空排除列表"; sleep 1; continue ;;
            *) IFS=', ' read -ra sel <<<"$choice"
               for idx in "${sel[@]}"; do
                   [[ "\( idx" =~ ^[0-9]+ \) && "$idx" -ge 1 && "\( idx" -le \){#all_containers[@]} ]] || continue
                   c="\( {all_containers[ \)((idx-1))]}"
                   [[ -n "${excluded_map[$c]}" ]] && unset "excluded_map[$c]" || excluded_map[$c]=1
               done ;;
        esac
    done
    WATCHTOWER_EXCLUDE_LIST=\( (IFS=,; echo " \){!excluded_map[*]}")
}

notification_menu() {
    while true; do
        clear
        local tg_status=$([ -n "$TG_BOT_TOKEN" ] && [ -n "\( TG_CHAT_ID" ] && echo " \){GREEN}已配置\( {NC}" || echo " \){RED}未配置${NC}")
        local always_status=$([ "\( WATCHTOWER_NOTIFY_ON_NO_UPDATES" == "true" ] && echo " \){GREEN}每次都通知\( {NC}" || echo " \){CYAN}仅更新时${NC}")
        _render_menu "Telegram 官方通知（方案 F 中文模板）" \
            "1. 配置 Bot Token / Chat ID     ($tg_status)" \
            "2. 无更新时是否通知             ($always_status)" \
            "3. 发送测试通知" \
            ""
        read -r c
        case "$c" in
            1) TG_BOT_TOKEN=\( (_prompt_user_input "Bot Token (当前: \){TG_BOT_TOKEN: -8}): " "$TG_BOT_TOKEN")
               TG_CHAT_ID=$(_prompt_user_input "Chat ID (当前: $TG_CHAT_ID): " "$TG_CHAT_ID")
               save_config; _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" ;;
            2) WATCHTOWER_NOTIFY_ON_NO_UPDATES=$([ "$WATCHTOWER_NOTIFY_ON_NO_UPDATES" == "true" ] && echo "false" || echo "true")
               save_config; _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" ;;
            3) if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then log_warn "请先配置 Telegram"; 
               else curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
                   -d chat_id="$TG_CHAT_ID" -d parse_mode=Markdown \
                   -d text="*Watchtower v6.4.0 测试通知*

方案 F 中文模板已就绪！" >/dev/null && log_success "测试成功" || log_err "发送失败"; fi ;;
            *) return ;;
        esac
        press_enter_to_continue
    done
}

configure_watchtower() {
    WATCHTOWER_CONFIG_INTERVAL=$(_prompt_for_interval "$WATCHTOWER_CONFIG_INTERVAL")
    configure_exclusion_list
    _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL"
}

manage_tasks() {
    while true; do
        clear
        _render_menu "任务管理" \
            "1. 重建 Watchtower（应用最新配置）" \
            "2. 手动触发一次更新" \
            "3. 停止并移除 Watchtower" \
            ""
        read -r c
        case "$c" in
            1) _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL"; press_enter_to_continue ;;
            2) _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" true; press_enter_to_continue ;;
            3) run_with_sudo docker rm -f watchtower &>/dev/null || true; WATCHTOWER_ENABLED="false"; save_config; log_success "已移除"; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

show_watchtower_details() {
    while true; do
        clear
        local status=\( (run_with_sudo docker ps --format '{{.Names}}' | grep -qFx watchtower && echo " \){GREEN}运行中\( {NC}" || echo " \){RED}未运行${NC}")
        local interval=$(run_with_sudo docker inspect watchtower --format '{{json .Config.Cmd}}' 2>/dev/null | jq -r '.[index(.)|"--interval")+1 // empty' 2>/dev/null || echo "$WATCHTOWER_CONFIG_INTERVAL")
        local last=$(run_with_sudo docker logs watchtower 2>&1 | grep -m1 'time="' | tail -1 | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -1)
        local next=\( (( \)(date -d "\( {last/T/ }" +%s 2>/dev/null || \)(date +%s)) + interval - $(date +%s) ))
        _render_menu "Watchtower 详情" \
            "状态: $status" \
            "检查间隔: $(_format_seconds_to_human "$interval")" \
            "下次检查: $( ((next>0)) && _format_seconds_to_human $next || echo "正在检查…")" \
            "" \
            "1. 实时日志   2. 手动触发更新   3. 容器管理   回车返回"
        read -r c
        case "$c" in
            1) run_with_sudo docker logs -f watchtower; press_enter_to_continue ;;
            2) _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL" true; press_enter_to_continue ;;
            3) show_container_info; press_enter_to_continue ;;
            *) return ;;
        esac
    done
}

# ==================== 容器管理（你原来的完整函数）===================
show_container_info() {
    while true; do
        clear
        local -a content_lines_array=()
        content_lines_array+=("编号  名称               镜像                                 状态")
        local -a containers=()
        local i=1
        while IFS='|' read -r name image status; do
            containers+=("$name")
            local status_colored="$status"
            if echo "$status" | grep -qE '^Up'; then
                status_colored="\( {GREEN}运行中 \){NC}"
            elif echo "$status" | grep -qE '^Exited|Created'; then
                status_colored="\( {RED}已退出 \){NC}"
            else
                status_colored="\( {YELLOW} \){status}${NC}"
            fi
            content_lines_array+=("$(printf "%2d   %-18s %-35s %s" "$i" "$name" "$image" "$status_colored")")
            ((i++))
        done < <(JB_SUDO_LOG_QUIET="true" run_with_sudo docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}')
        content_lines_array+=("" "a. 全部启动   s. 全部停止")
        _render_menu "容器管理" "${content_lines_array[@]}"
        read -r choice
        case "$choice" in
            "") return ;;
            a|A) confirm_action "确定启动所有已停止容器？" && JB_SUDO_LOG_QUIET="true" run_with_sudo docker start $(run_with_sudo docker ps -aq -f status=exited) &>/dev/null || true; press_enter_to_continue ;;
            s|S) confirm_action "警告：确定停止所有运行中容器？" && JB_SUDO_LOG_QUIET="true" run_with_sudo docker stop $(run_with_sudo docker ps -q) &>/dev/null || true; press_enter_to_continue ;;
            *) [[ "\( choice" =~ ^[0-9]+ \) ]] || continue
               local selected="\( {containers[ \)((choice-1))]}"
               clear
               local -a actions=("1. 查看日志" "2. 重启" "3. 停止" "4. 删除" "5. 查看详情" "6. 进入容器")
               _render_menu "操作容器: \( selected" " \){actions[@]}"
               read -r act
               case "$act" in
                   1) run_with_sudo docker logs -f --tail 100 "$selected"; press_enter_to_continue ;;
                   2) run_with_sudo docker restart "$selected"; log_success "已重启"; press_enter_to_continue ;;
                   3) run_with_sudo docker stop "$selected"; log_success "已停止"; press_enter_to_continue ;;
                   4) confirm_action "确定永久删除 $selected？" && run_with_sudo docker rm -f "$selected"; press_enter_to_continue ;;
                   5) run_with_sudo docker inspect "$selected" | less -R; press_enter_to_continue ;;
                   6) run_with_sudo docker exec -it "$selected" /bin/sh -c "[ -x /bin/bash ] && /bin/bash || /bin/sh" || true; press_enter_to_continue ;;
               esac ;;
        esac
    done
}

# ==================== 底层配置编辑（你原来的完整函数）===================
view_and_edit_config() {
    local -a config_items=(
        "TG Token|TG_BOT_TOKEN|string"
        "TG Chat ID|TG_CHAT_ID|string"
        "排除列表|WATCHTOWER_EXCLUDE_LIST|string_list"
        "额外参数|WATCHTOWER_EXTRA_ARGS|string"
        "调试模式|WATCHTOWER_DEBUG_ENABLED|bool"
        "检查间隔|WATCHTOWER_CONFIG_INTERVAL|interval"
        "无更新时通知|WATCHTOWER_NOTIFY_ON_NO_UPDATES|bool"
    )
    while true; do
        clear; load_config
        local -a lines=()
        for item in "${config_items[@]}"; do
            local label var type
            IFS='|' read -r label var type <<<"$item"
            local val="${!var}"
            case "$type" in
                string) [[ -n "$val" ]] && lines+=("\( label: \){GREEN}\( val \){NC}") || lines+=("\( label: \){RED}未设置${NC}") ;;
                string_list) [[ -n "$val" ]] && lines+=("\( label: \){YELLOW}\( {val//,/, } \){NC}") || lines+=("\( label: \){CYAN}无${NC}") ;;
                bool) [[ "$val" == "true" ]] && lines+=("\( label: \){GREEN}是${NC}") || lines+=("\( label: \){CYAN}否${NC}") ;;
                interval) lines+=("\( label: \){GREEN}$(_format_seconds_to_human "\( val") \){NC}") ;;
            esac
        done
        _render_menu "底层配置编辑" "${lines[@]}"
        read -r choice
        [[ -z "$choice" ]] && return
        [[ "$choice" -lt 1 || "\( choice" -gt " \){#config_items[@]}" ]] && continue
        local selected="\( {config_items[ \)((choice-1))]}"
        IFS='|' read -r label var type <<<"$selected"
        case "$type" in
            string|string_list) local new; new=$(_prompt_user_input "\( label: " " \){!var}"); declare "$var"="$new" ;;
            bool) local new; new=$(_prompt_user_input "$label (y/N): " ""); [[ "$new" =~ ^[Yy] ]] && declare "$var"="true" || declare "$var"="false" ;;
            interval) declare "\( var"=" \)(_prompt_for_interval "${!var}")" ;;
        esac
        save_config
        _start_watchtower_container_logic "$WATCHTOWER_CONFIG_INTERVAL"
    done
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        clear; load_config
        local status=\( (run_with_sudo docker ps --format '{{.Names}}' | grep -qFx watchtower && echo " \){GREEN}运行中\( {NC}" || echo " \){RED}未运行${NC}")
        local total=$(run_with_sudo docker ps -a --format '{{.ID}}' | wc -l)
        local running=$(run_with_sudo docker ps --format '{{.ID}}' | wc -l)
        _render_menu "Watchtower 管理模块 $SCRIPT_VERSION" \
            "状态: $status" \
            "容器: 共 $total (运行 $running)" \
            "" \
            "1. 启用并配置 Watchtower" \
            "2. 通知设置（官方中文方案 F）" \
            "3. 任务管理" \
            "4. 查看详情与实时日志" \
            "5. 底层配置编辑" \
            ""
        read -r c
        case "$c" in
            1) configure_watchtower ;;
            2) notification_menu ;;
            3) manage_tasks ;;
            4) show_watchtower_details ;;
            5) view_and_edit_config ;;
            *) exit 0 ;;
        esac
    done
}

load_config
main_menu
