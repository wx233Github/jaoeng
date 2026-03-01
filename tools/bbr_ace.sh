#!/usr/bin/env bash
# =============================================================
# 🚀 bbr_ace.sh (v6.7.0 - UI Refresh Edition)
# =============================================================

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

readonly BASE_DIR="/opt/vps_install_modules"
readonly LOG_FILE="${BASE_DIR}/bbr_ace.log"
readonly BACKUP_DIR="${BASE_DIR}/backups"
readonly MAX_BACKUPS=5
readonly SYSCTL_D_DIR="/etc/sysctl.d"
readonly SYSCTL_CONF="${SYSCTL_D_DIR}/99-z-tcp-optimizer.conf"
readonly MODULES_LOAD_DIR="/etc/modules-load.d"
readonly MODULES_CONF="${MODULES_LOAD_DIR}/tcp_optimizer.conf"
readonly MODPROBE_BBR_CONF="/etc/modprobe.d/tcp_optimizer_bbr.conf"
readonly MODPROBE_CONN_CONF="/etc/modprobe.d/tcp_optimizer_conntrack.conf"
readonly LIMITS_CONF="/etc/security/limits.d/99-z-tcp-optimizer.conf"
readonly SYSTEMD_SYS_CONF="/etc/systemd/system.conf.d/99-z-tcp-optimizer.conf"
readonly SYSTEMD_USR_CONF="/etc/systemd/user.conf.d/99-z-tcp-optimizer.conf"
readonly NIC_OPT_SERVICE="/etc/systemd/system/nic-optimize.service"
readonly GAI_CONF="/etc/gai.conf"
readonly MODE_STATE_FILE="${BASE_DIR}/current_profile_mode"
readonly XANMOD_REPO_FILE="/etc/apt/sources.list.d/xanmod-release.list"
readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly UTILS_PRIMARY_PATH="/opt/vps_install_modules/utils.sh"
readonly UTILS_FALLBACK_PATH="${SCRIPT_DIR}/../utils.sh"
readonly SCRIPT_VERSION="v6.7.0"

IS_CONTAINER=0
IS_SYSTEMD=0
TOTAL_MEM_KB=0
USE_UTILS_UI=0

readonly CONFIG_FILES=(
    "${SYSCTL_CONF}"
    "${NIC_OPT_SERVICE}"
    "${MODULES_CONF}"
    "${MODPROBE_BBR_CONF}"
    "${MODPROBE_CONN_CONF}"
    "${LIMITS_CONF}"
    "${SYSTEMD_SYS_CONF}"
    "${SYSTEMD_USR_CONF}"
    "${MODE_STATE_FILE}"
)

readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly ORANGE='\033[38;5;208m'

mkdir -p "${BASE_DIR}" "${BACKUP_DIR}"

init_utils_ui() {
    if [[ -r "${UTILS_PRIMARY_PATH}" ]]; then
        # shellcheck source=/opt/vps_install_modules/utils.sh
        if source "${UTILS_PRIMARY_PATH}"; then
            if declare -f _render_menu >/dev/null 2>&1 && declare -f _prompt_for_menu_choice >/dev/null 2>&1; then
                USE_UTILS_UI=1
                return 0
            fi
        fi
    fi

    if [[ -r "${UTILS_FALLBACK_PATH}" ]]; then
        # shellcheck source=/dev/null
        if source "${UTILS_FALLBACK_PATH}"; then
            if declare -f _render_menu >/dev/null 2>&1 && declare -f _prompt_for_menu_choice >/dev/null 2>&1; then
                USE_UTILS_UI=1
                return 0
            fi
        fi
    fi
    USE_UTILS_UI=0
    return 1
}

ui_generate_line() {
    local len="${1:-40}"
    local char="${2:-─}"
    local spaces=""
    if [[ "${len}" -le 0 ]]; then
        printf ""
        return 0
    fi
    printf -v spaces "%${len}s" ""
    printf "%s" "${spaces// /${char}}"
}

ui_get_visual_width() {
    local text="${1:-}"
    local plain_text=""
    plain_text="$(printf '%b' "${text}" | sed 's/\x1b\[[0-9;]*m//g')"
    if [[ -z "${plain_text}" ]]; then
        printf "0"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import unicodedata,sys; s=sys.stdin.read(); print(sum(2 if unicodedata.east_asian_width(c) in ('W','F','A') else 1 for c in s.strip()))" <<< "${plain_text}" 2>/dev/null || printf "%s" "${#plain_text}"
    else
        printf "%s" "${#plain_text}"
    fi
}

ui_render_menu() {
    local title="${1:-}"
    shift
    local -a lines=("$@")
    if [[ "${USE_UTILS_UI}" -eq 1 ]] && declare -f _render_menu >/dev/null 2>&1; then
        _render_menu "${title}" "${lines[@]}"
        return 0
    fi

    local max_content_width=0
    local title_width=0
    local current_width=0
    local box_inner_width=0
    local pad_total=0
    local pad_left=0
    local pad_right=0
    local line=""

    title_width="$(ui_get_visual_width "${title}")"
    max_content_width="${title_width}"
    for line in "${lines[@]}"; do
        current_width="$(ui_get_visual_width "${line}")"
        if [[ "${current_width}" -gt "${max_content_width}" ]]; then
            max_content_width="${current_width}"
        fi
    done
    box_inner_width="${max_content_width}"
    if [[ "${box_inner_width}" -lt 56 ]]; then
        box_inner_width=56
    fi

    printf "\n"
    printf "%b\n" "${COLOR_GREEN}╭$(ui_generate_line "${box_inner_width}" "─")╮${COLOR_RESET}"
    if [[ -n "${title}" ]]; then
        pad_total=$(( box_inner_width - title_width ))
        pad_left=$(( pad_total / 2 ))
        pad_right=$(( pad_total - pad_left ))
        printf "%b\n" "${COLOR_GREEN}│${COLOR_RESET}$(printf '%*s' "${pad_left}" "")${BOLD}${title}${COLOR_RESET}$(printf '%*s' "${pad_right}" "")${COLOR_GREEN}│${COLOR_RESET}"
    fi
    printf "%b\n" "${COLOR_GREEN}╰$(ui_generate_line "${box_inner_width}" "─")╯${COLOR_RESET}"
    for line in "${lines[@]}"; do
        printf "%b\n" "${line}"
    done
    printf "%b\n" "${COLOR_GREEN}$(ui_generate_line "$((box_inner_width + 2))" "─")${COLOR_RESET}"
}

ui_prompt_choice() {
    local numeric_range="${1:-}"
    local prompt_text="${2:-选项}"
    local choice=""
    if [[ "${USE_UTILS_UI}" -eq 1 ]] && declare -f _prompt_for_menu_choice >/dev/null 2>&1; then
        _prompt_for_menu_choice "${numeric_range}" ""
        return 0
    fi

    if [[ "${JB_NONINTERACTIVE}" == "true" ]]; then
        printf ""
        return 0
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        printf ""
        return 0
    fi
    printf "%b" "${ORANGE}> ${COLOR_RESET}${prompt_text} [${numeric_range}] (↩ 返回): " > /dev/tty
    read -r choice < /dev/tty || choice=""
    printf "%s" "${choice}"
}

level_to_num() {
    local level="${1:-INFO}"
    case "${level}" in
        ERROR) echo 0 ;;
        WARN) echo 1 ;;
        INFO) echo 2 ;;
        DEBUG) echo 3 ;;
        *) echo 2 ;;
    esac
}

log_msg() {
    local level="${1}"
    local color="${2}"
    shift 2
    local msg="$*"
    local ts
    ts="$(date '+%F %T')"

    local target_num current_num
    target_num="$(level_to_num "${level}")"
    current_num="$(level_to_num "${LOG_LEVEL}")"

    if [[ "${target_num}" -le "${current_num}" ]]; then
        printf "%b[%s] %s%b\n" "${color}" "${level}" "${msg}" "${COLOR_RESET}" >&2
    fi
    printf "[%s] [%s] %s\n" "${ts}" "${level}" "${msg}" >> "${LOG_FILE}"
}

log_info()  { log_msg "INFO" "${COLOR_GREEN}" "$*"; }
log_warn()  { log_msg "WARN" "${COLOR_YELLOW}" "$*"; }
log_error() { log_msg "ERROR" "${COLOR_RED}" "$*"; }
log_step()  { log_msg "STEP" "${COLOR_CYAN}" "$*"; }

die() {
    local exit_code="${1:-1}"
    shift || true
    log_error "$*"
    exit "${exit_code}"
}

cleanup() {
    :
}

error_handler() {
    local exit_code="${1:-1}"
    local line_no="${2:-0}"
    local command="${3:-unknown}"
    if [[ "${exit_code}" -ne 0 ]]; then
        log_error "脚本异常退出! (Line: ${line_no}, Command: '${command}', ExitCode: ${exit_code})"
    fi
    exit "${exit_code}"
}

trap cleanup EXIT
trap 'error_handler $? ${LINENO} "${BASH_COMMAND}"' ERR

ensure_safe_path() {
    local target="${1:-}"
    if [[ -z "${target}" || "${target}" == "/" ]]; then
        die 1 "拒绝对危险路径执行破坏性操作: '${target}'"
    fi
}

sanitize_noninteractive_flag() {
    case "${JB_NONINTERACTIVE}" in
        true|false) return 0 ;;
        *)
            log_warn "JB_NONINTERACTIVE 值非法: ${JB_NONINTERACTIVE}，已回退为 false"
            JB_NONINTERACTIVE="false"
            ;;
    esac
}

read_confirm() {
    local prompt="${1:-确认继续? [Y/n]: }"
    local reply=""
    if [[ "${JB_NONINTERACTIVE}" == "true" ]]; then
        log_warn "非交互模式：默认是"
        return 0
    fi
    read -r -p "${prompt}" reply < /dev/tty
    case "${reply,,}" in
        ""|y|yes) return 0 ;;
        n|no) return 1 ;;
        *) return 1 ;;
    esac
}

read_required_yes() {
    local prompt="${1:-请输入 yes 继续，其他输入取消: }"
    local reply=""
    if [[ "${JB_NONINTERACTIVE}" == "true" ]]; then
        log_warn "非交互模式：高风险操作默认取消"
        return 1
    fi
    read -r -p "${prompt}" reply < /dev/tty
    [[ "${reply,,}" == "yes" ]]
}

validate_args() {
    if [[ "$#" -gt 0 ]]; then
        log_warn "忽略额外参数: $*"
    fi
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die 1 "需要 root 权限。"
    fi
}

check_dependencies() {
    local deps=(sysctl uname sed modprobe grep awk ip ss tar date)
    local missing=()
    local cmd
    for cmd in "${deps[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            missing+=("${cmd}")
        fi
    done
    if [[ "${#missing[@]}" -gt 0 ]]; then
        die 1 "缺失依赖命令: ${missing[*]}"
    fi
}

check_systemd() {
    if [[ -d /run/systemd/system ]] || grep -q systemd <(head -n 1 /proc/1/comm 2>/dev/null || printf ""); then
        IS_SYSTEMD=1
    else
        IS_SYSTEMD=0
    fi
}

check_environment() {
    log_step "全景环境诊断..."
    local raw_virt=""
    local virt_type="physical/kvm"

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        raw_virt="$(systemd-detect-virt -c 2>/dev/null || true)"
        raw_virt="$(printf '%s' "${raw_virt}" | tr -d '[:space:]')"
    fi

    if [[ -z "${raw_virt}" || "${raw_virt}" == "none" ]]; then
        if grep -qE 'docker|lxc' /proc/1/cgroup 2>/dev/null; then
            virt_type="docker/lxc"
        elif [[ -f /.dockerenv ]]; then
            virt_type="docker"
        fi
    else
        virt_type="${raw_virt}"
    fi

    if [[ "${virt_type}" =~ (lxc|docker|openvz|systemd-nspawn) ]]; then
        IS_CONTAINER=1
        log_warn "检测到容器环境: ${virt_type} (将跳过底层内核模块加载)"
    else
        IS_CONTAINER=0
        log_info "运行环境: ${virt_type} (支持底层性能调优)"
    fi

    TOTAL_MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
    check_systemd
}

get_mode_label() {
    local mode="${1:-}"
    case "${mode}" in
        stock) printf "BBR+FQ 原版参数" ;;
        aggressive) printf "BBRV1 + FQ + 激进128MB" ;;
        *) printf "未选择" ;;
    esac
}

read_current_mode() {
    local mode=""
    if [[ -f "${MODE_STATE_FILE}" ]]; then
        read -r mode < "${MODE_STATE_FILE}" || mode=""
    fi
    if [[ -z "${mode}" ]]; then
        local cur_cc cur_qdisc
        local cur_rmem_max cur_slow_start_idle
        cur_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf "")"
        cur_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf "")"
        cur_rmem_max="$(sysctl -n net.core.rmem_max 2>/dev/null || printf "")"
        cur_slow_start_idle="$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || printf "")"
        if [[ "${cur_cc}" == "bbr" && "${cur_qdisc}" == "fq" ]]; then
            if [[ "${cur_rmem_max}" == "134217728" || "${cur_slow_start_idle}" == "0" ]]; then
                mode="aggressive"
            else
                mode="stock"
            fi
        fi
    fi
    printf "%s" "$(get_mode_label "${mode}")"
}

manage_backups() {
    local backups=()
    local i
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/config_backup_*.tar.gz 2>/dev/null || true)
    if [[ "${#backups[@]}" -le "${MAX_BACKUPS}" ]]; then
        return 0
    fi
    log_info "备份数量超出限制(${MAX_BACKUPS})，正在清理最旧的备份..."
    for ((i=MAX_BACKUPS; i<${#backups[@]}; i++)); do
        rm -f "${backups[i]}"
    done
}

backup_configs() {
    log_step "正在创建当前配置的快照..."
    local backup_file="${BACKUP_DIR}/config_backup_${TIMESTAMP}.tar.gz"
    local files_to_backup=()
    local f
    for f in "${CONFIG_FILES[@]}"; do
        if [[ -f "${f}" ]]; then
            files_to_backup+=("${f}")
        fi
    done
    if [[ "${#files_to_backup[@]}" -eq 0 ]]; then
        log_info "当前无可备份配置，跳过快照。"
        return 0
    fi
    tar -czf "${backup_file}" "${files_to_backup[@]}" 2>/dev/null
    log_info "配置已备份至: ${backup_file}"
    manage_backups
}

restore_configs() {
    log_step "正在查找可用备份..."
    local backups=()
    local backup_choice=""
    local temp_dir=""
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/config_backup_*.tar.gz 2>/dev/null || true)
    if [[ "${#backups[@]}" -eq 0 ]]; then
        log_warn "未找到任何备份文件。"
        return 1
    fi

    if [[ "${JB_NONINTERACTIVE}" == "true" ]]; then
        log_warn "非交互模式不支持选择备份恢复。"
        return 1
    fi

    echo "请选择要恢复的配置备份:"
    select backup_choice in "${backups[@]}"; do
        if [[ -z "${backup_choice}" ]]; then
            log_warn "无效选择。"
            return 1
        fi
        temp_dir="$(mktemp -d)"
        if [[ -z "${temp_dir}" || ! -d "${temp_dir}" ]]; then
            die 1 "无法创建临时目录"
        fi

        if tar -xzf "${backup_choice}" -C "${temp_dir}"; then
            log_info "备份文件验证通过，正在应用..."
            rm -f "${CONFIG_FILES[@]}"
            cp -rf "${temp_dir}"/* /
            rm -rf "${temp_dir}"
            if [[ "${IS_SYSTEMD}" -eq 1 ]]; then
                systemctl daemon-reload || true
                systemctl restart systemd-sysctl 2>/dev/null || true
                systemctl enable --now nic-optimize.service 2>/dev/null || true
            fi
            log_info "配置恢复并已应用。"
            return 0
        fi

        rm -rf "${temp_dir}"
        log_error "备份文件损坏或解压失败，当前配置未受影响。"
        return 1
    done
}

manage_ipv4_precedence() {
    if [[ "${IS_CONTAINER}" -eq 1 ]]; then
        return 0
    fi
    local action="${1:-}"
    if [[ ! -f "${GAI_CONF}" ]]; then
        touch "${GAI_CONF}"
    fi

    if [[ "${action}" == "enable" ]]; then
        if grep -q "precedence ::ffff:0:0/96" "${GAI_CONF}"; then
            sed -i 's/^#*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"
        else
            printf "%s\n" "precedence ::ffff:0:0/96  100" >> "${GAI_CONF}"
        fi
        log_info "IPv4 优先已启用。"
    else
        sed -i 's/^precedence ::ffff:0:0\/96.*/#precedence ::ffff:0:0\/96  100/' "${GAI_CONF}" || true
        log_info "已恢复系统默认选路策略。"
    fi
}

generate_stock_sysctl_content() {
    printf "%s\n" "# ============================================================="
    printf "%s\n" "# TCP Optimizer Configuration (Stock BBR+FQ)"
    printf "%s\n" "# ============================================================="
    printf "%s\n" "net.core.default_qdisc = fq"
    printf "%s\n" "net.ipv4.tcp_congestion_control = bbr"
}

generate_aggressive_sysctl_content() {
    local buffer_size="134217728"
    printf "%s\n" "# ============================================================="
    printf "%s\n" "# TCP Optimizer Configuration (BBRV1+FQ Aggressive 128MB)"
    printf "%s\n" "# ============================================================="
    printf "%s\n" "net.core.default_qdisc = fq"
    printf "%s\n" "net.ipv4.tcp_congestion_control = bbr"
    printf "%s\n" "net.core.rmem_max = ${buffer_size}"
    printf "%s\n" "net.core.wmem_max = ${buffer_size}"
    printf "%s\n" "net.core.rmem_default = ${buffer_size}"
    printf "%s\n" "net.core.wmem_default = ${buffer_size}"
    printf "%s\n" "net.ipv4.udp_rmem_min = 131072"
    printf "%s\n" "net.ipv4.udp_wmem_min = 131072"
    printf "%s\n" "net.ipv4.tcp_notsent_lowat = 16384"
    printf "%s\n" "net.ipv4.tcp_limit_output_bytes = 131072"
    printf "%s\n" "net.ipv4.tcp_slow_start_after_idle = 0"
    printf "%s\n" "net.ipv4.tcp_retries2 = 8"
}

apply_profile() {
    local profile_type="${1:-stock}"
    local mode_key="stock"
    local target_qdisc="fq"
    local target_cc="bbr"
    local profile_label="BBR+FQ 原版参数 / Stock"
    local avail_cc=""
    local final_cc=""
    local final_qdisc=""

    case "${profile_type}" in
        stock)
            mode_key="stock"
            profile_label="BBR+FQ 原版参数 / Stock"
            ;;
        aggressive)
            mode_key="aggressive"
            profile_label="BBRV1 + FQ + 激进128MB"
            ;;
        *)
            log_warn "未知模式 ${profile_type}，已回退到 BBR+FQ 原版参数。"
            mode_key="stock"
            profile_label="BBR+FQ 原版参数 / Stock"
            ;;
    esac

    backup_configs
    log_step "加载画像: [${profile_label}]"

    if [[ "${IS_CONTAINER}" -eq 0 ]]; then
        modprobe sch_fq 2>/dev/null || true
        modprobe tcp_bbr 2>/dev/null || true
    fi

    avail_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf "")"
    if ! echo "${avail_cc}" | grep -qw "${target_cc}"; then
        die 1 "当前内核未提供 ${target_cc}，无法应用原版模式。"
    fi

    mkdir -p "${SYSCTL_D_DIR}"
    case "${mode_key}" in
        aggressive) generate_aggressive_sysctl_content > "${SYSCTL_CONF}" ;;
        *) generate_stock_sysctl_content > "${SYSCTL_CONF}" ;;
    esac
    sysctl -e -p "${SYSCTL_CONF}" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

    final_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf "unknown")"
    final_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf "unknown")"

    if [[ "${final_cc}" == "${target_cc}" && "${final_qdisc}" == "${target_qdisc}" ]]; then
        log_info "✅ 模式应用成功: ${target_cc} + ${target_qdisc}"
        printf "%s\n" "${mode_key}" > "${MODE_STATE_FILE}"
    else
        log_warn "模式应用后检测不一致，当前: ${final_cc} + ${final_qdisc}"
    fi
}

audit_configs() {
    log_step "正在审计当前生效的内核参数..."
    if [[ ! -f "${SYSCTL_CONF}" ]]; then
        log_warn "未找到优化配置文件，系统可能处于默认状态。"
        return 0
    fi

    local mismatches=0
    local line=""
    local key=""
    local val=""
    local current_val=""

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        key="$(printf "%s" "${line}" | cut -d'=' -f1 | tr -d '[:space:]')"
        val="$(printf "%s" "${line}" | cut -d'=' -f2- | tr -d '[:space:]')"
        current_val="$(sysctl -n "${key}" 2>/dev/null || printf "N/A")"
        current_val="$(printf "%s" "${current_val}" | tr -d '[:space:]')"

        if [[ "${current_val}" == "${val}" ]]; then
            printf "%b[MATCH]%b %-40s = %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "${key}" "${val}"
        else
            printf "%b[MISMATCH]%b %-40s | Expected: %s | Current: %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "${key}" "${val}" "${current_val}"
            mismatches=$((mismatches + 1))
        fi
    done < "${SYSCTL_CONF}"

    if [[ "${mismatches}" -eq 0 ]]; then
        log_info "所有参数均已正确应用。"
    else
        log_warn "${mismatches} 个参数与配置文件不匹配，可能已被其他进程覆盖。"
    fi
}

update_stock_kernel() {
    if [[ "${IS_CONTAINER}" -eq 1 ]]; then
        log_warn "容器环境无法更新宿主机内核。"
        return 0
    fi

    if ! read_confirm "是否继续更新系统仓库原版内核? [Y/n]: "; then
        log_warn "操作已取消。"
        return 0
    fi

    log_step "开始更新原版内核（系统仓库）..."
    export DEBIAN_FRONTEND=noninteractive
    local DPKG_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        if [[ -f "${XANMOD_REPO_FILE}" ]]; then
            log_warn "检测到历史第三方内核源: ${XANMOD_REPO_FILE}（本次仅执行系统仓库元包更新）"
        fi
        if ! (apt-get install -yq ${DPKG_OPTS} --install-recommends linux-image-amd64 linux-headers-amd64 || apt-get install -yq ${DPKG_OPTS} --install-recommends linux-image-generic linux-headers-generic); then
            apt-get upgrade -yq ${DPKG_OPTS}
        fi
        update-grub 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y upgrade --refresh "kernel*" || dnf -y upgrade --refresh
    elif command -v yum >/dev/null 2>&1; then
        yum -y update kernel || yum -y update
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm --needed linux linux-headers
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive refresh
        zypper --non-interactive update kernel-default kernel-default-devel || zypper --non-interactive update
    else
        die 1 "暂不支持当前系统的包管理器，请手动更新内核。"
    fi

    log_info "原版内核更新流程已完成。"
    if read_required_yes "高风险操作：是否立即重启系统以加载新内核? 请输入 yes 继续: "; then
        log_warn "用户确认重启，正在执行系统重启..."
        sync
        systemctl reboot || reboot
    else
        log_info "已取消立即重启。请稍后手动重启以使新内核生效。"
    fi
}

disable_xanmod_repo() {
    if [[ ! -f "${XANMOD_REPO_FILE}" ]]; then
        return 0
    fi

    local disabled_repo="${XANMOD_REPO_FILE}.disabled.${TIMESTAMP}"
    mv -f "${XANMOD_REPO_FILE}" "${disabled_repo}"
    log_info "已禁用 XanMod 源: ${disabled_repo}"
}

install_stock_kernel_apt() {
    export DEBIAN_FRONTEND=noninteractive
    local DPKG_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
    local distro_id=""

    if [[ -r /etc/os-release ]]; then
        distro_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    fi

    apt-get update -y

    if [[ "${distro_id}" == "ubuntu" ]]; then
        if ! (apt-get install -yq ${DPKG_OPTS} --install-recommends linux-image-generic linux-headers-generic || apt-get install -yq ${DPKG_OPTS} --install-recommends linux-image-amd64 linux-headers-amd64); then
            apt-get upgrade -yq ${DPKG_OPTS}
        fi
    else
        if ! (apt-get install -yq ${DPKG_OPTS} --install-recommends linux-image-amd64 linux-headers-amd64 || apt-get install -yq ${DPKG_OPTS} --install-recommends linux-image-generic linux-headers-generic); then
            apt-get upgrade -yq ${DPKG_OPTS}
        fi
    fi

    update-grub 2>/dev/null || true
}

cleanup_xanmod_kernel_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "当前系统不是 apt 系，跳过 XanMod 包清理。"
        return 0
    fi

    local xanmod_pkgs=()
    mapfile -t xanmod_pkgs < <(dpkg --list 'linux-xanmod*' 'linux-image-*xanmod*' 'linux-headers-*xanmod*' 2>/dev/null | awk '/^ii/ {print $2}')

    if [[ "${#xanmod_pkgs[@]}" -eq 0 ]]; then
        log_info "未检测到已安装的 XanMod 内核包。"
        return 0
    fi

    log_warn "检测到 XanMod 包: ${xanmod_pkgs[*]}"
    if ! read_required_yes "高风险操作：确认清理以上 XanMod 内核包? 请输入 yes 继续: "; then
        log_warn "已取消 XanMod 包清理。"
        return 0
    fi

    apt-get purge -y "${xanmod_pkgs[@]}" || log_warn "部分 XanMod 包清理失败，请手动检查。"
    apt-get autoremove -y || true
    update-grub 2>/dev/null || true
    log_info "XanMod 包清理流程已完成。"
}

switch_xanmod_to_stock_kernel() {
    if [[ "${IS_CONTAINER}" -eq 1 ]]; then
        log_warn "容器环境无法切换宿主机内核。"
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "从 XanMod 切回原版内核仅支持 Debian/Ubuntu (apt)。"
        return 0
    fi

    local running_kernel=""
    local xanmod_pkgs=()
    local has_xanmod_trace=0
    running_kernel="$(uname -r)"

    mapfile -t xanmod_pkgs < <(dpkg --list 'linux-xanmod*' 'linux-image-*xanmod*' 'linux-headers-*xanmod*' 2>/dev/null | awk '/^ii/ {print $2}')

    if [[ -f "${XANMOD_REPO_FILE}" || "${running_kernel}" == *xanmod* || "${#xanmod_pkgs[@]}" -gt 0 ]]; then
        has_xanmod_trace=1
    fi

    if [[ "${has_xanmod_trace}" -eq 0 ]]; then
        log_info "未检测到 XanMod 痕迹，执行原版内核更新。"
        update_stock_kernel
        return 0
    fi

    log_warn "检测到 XanMod 痕迹（源/内核/包），将执行回退至原版内核流程。"
    if ! read_confirm "确认从 XanMod 切回原版内核? [Y/n]: "; then
        log_warn "操作已取消。"
        return 0
    fi

    disable_xanmod_repo
    install_stock_kernel_apt
    log_info "原版内核已安装/更新完成。"

    if [[ "${#xanmod_pkgs[@]}" -gt 0 ]]; then
        log_warn "为确保下次启动优先进入原版内核，建议清理 XanMod 包。"
        cleanup_xanmod_kernel_packages
    fi

    if read_required_yes "高风险操作：是否立即重启系统以切换到原版内核? 请输入 yes 继续: "; then
        log_warn "用户确认重启，正在执行系统重启..."
        sync
        systemctl reboot || reboot
    else
        log_info "已取消立即重启。请稍后手动重启完成切换。"
    fi
}

remove_old_kernels() {
    log_step "正在查找可清理的旧内核..."
    if ! command -v dpkg >/dev/null 2>&1; then
        log_warn "非 Debian/Ubuntu 系统，暂不支持旧内核自动清理。"
        return 0
    fi

    local current_kernel=""
    local kernels_to_remove=()
    local pkg=""
    current_kernel="$(uname -r)"

    while IFS= read -r pkg; do
        [[ -z "${pkg}" ]] && continue
        if [[ "${pkg}" == *"${current_kernel}"* ]]; then
            continue
        fi
        kernels_to_remove+=("${pkg}")
    done < <(dpkg --list 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/ {print $2}')

    if [[ "${#kernels_to_remove[@]}" -eq 0 ]]; then
        log_info "没有发现可清理的旧内核。"
        return 0
    fi

    echo "以下旧内核将被清理:"
    printf " - %s\n" "${kernels_to_remove[@]}"
    if ! read_required_yes "高风险操作：确认清理以上旧内核? 请输入 yes 继续: "; then
        log_warn "操作已取消。"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y "${kernels_to_remove[@]}"
    apt-get autoremove -y
    update-grub 2>/dev/null || true
    log_info "旧内核清理完成。"
}

kernel_manager() {
    local -a km_lines=()
    km_lines+=(" ${COLOR_CYAN}内核维护子菜单${COLOR_RESET}")
    km_lines+=("   1) 更新原版内核 (系统仓库)")
    km_lines+=("   2) 从 XanMod 切回原版内核 (Debian/Ubuntu)")
    km_lines+=("   3) 清理所有冗余旧内核 (Debian/Ubuntu)")
    km_lines+=("   0) 返回主菜单")
    ui_render_menu "🧰 BBR ACE - 内核维护" "${km_lines[@]}"

    if [[ "${JB_NONINTERACTIVE}" == "true" ]]; then
        log_warn "非交互模式：内核维护工具已跳过。"
        return 0
    fi
    local choice=""
    choice="$(ui_prompt_choice "0-3" "请选择内核维护操作")"
    case "${choice}" in
        1) update_stock_kernel ;;
        2) switch_xanmod_to_stock_kernel ;;
        3) remove_old_kernels ;;
        0|*) return 0 ;;
    esac
}

uninstall_and_restore_defaults() {
    echo -e "${COLOR_RED}警告: 此操作将删除本脚本优化配置和备份，且不可逆！${COLOR_RESET}"
    if ! read_required_yes "高风险操作：确认要彻底卸载吗? 请输入 yes 继续: "; then
        log_warn "卸载操作已取消。"
        return 0
    fi

    log_warn "正在彻底清理配置、驻留服务与所有备份..."
    ensure_safe_path "${BACKUP_DIR}"
    rm -f "${CONFIG_FILES[@]}"
    rm -rf "${BACKUP_DIR}"

    if [[ "${IS_SYSTEMD}" -eq 1 ]]; then
        systemctl disable --now nic-optimize.service 2>/dev/null || true
        systemctl daemon-reload || true
    fi

    sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
    sysctl -w net.core.default_qdisc=fq_codel 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    log_info "已卸载本脚本配置，并回退到系统默认拥塞策略。"
}

show_menu() {
    clear
    local mem_mb=0
    local cur_kver=""
    local cur_cc=""
    local cur_qdisc=""
    local active_conn=0
    local current_mode=""

    mem_mb=$((TOTAL_MEM_KB / 1024))
    cur_kver="$(uname -r)"
    cur_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf "未知")"
    cur_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf "未知")"
    active_conn="$(ss -tn state established 2>/dev/null | wc -l || printf "1")"
    active_conn=$((active_conn - 1))
    [[ "${active_conn}" -lt 0 ]] && active_conn=0
    current_mode="$(read_current_mode)"

    local -a lines=()
    lines+=(" ${COLOR_CYAN}系统概览${COLOR_RESET}")
    lines+=("   内核版本: ${COLOR_CYAN}${cur_kver}${COLOR_RESET}")
    lines+=("   物理内存: ${COLOR_CYAN}${mem_mb} MB${COLOR_RESET}    活跃连接: ${COLOR_GREEN}${active_conn}${COLOR_RESET}")
    lines+=("   拥塞算法: ${COLOR_CYAN}${cur_cc} + ${cur_qdisc}${COLOR_RESET}")
    lines+=("   当前模式: ${COLOR_BLUE}${current_mode}${COLOR_RESET}")
    lines+=(" ")
    lines+=(" ${COLOR_CYAN}模式选择${COLOR_RESET}")
    lines+=("   1) BBR+FQ 原版参数 [Stock]")
    lines+=("   2) BBRV1 + FQ + 激进128MB")
    lines+=(" ")
    lines+=(" ${COLOR_CYAN}网络策略${COLOR_RESET}")
    lines+=("   3) 开启 IPv4 强制优先")
    lines+=("   4) 恢复 IPv6 默认优先级")
    lines+=(" ")
    lines+=(" ${COLOR_CYAN}维护与恢复${COLOR_RESET}")
    lines+=("   5) 内核维护工具 (更新/清理)")
    lines+=("   6) 从备份恢复配置 (时光机)")
    lines+=("   7) 审计当前系统配置")
    lines+=("   8) 彻底卸载/恢复系统默认")
    lines+=(" ")
    lines+=("   0) 退出")

    ui_render_menu "🚀 BBR ACE 网络调优引擎 (${SCRIPT_VERSION})" "${lines[@]}"
}

main() {
    init_utils_ui || true
    sanitize_noninteractive_flag
    validate_args "$@"
    check_root
    check_dependencies
    check_environment

    while true; do
        show_menu
        if [[ "${JB_NONINTERACTIVE}" == "true" ]]; then
            log_warn "非交互模式：已退出"
            exit 0
        fi

        local c=""
        c="$(ui_prompt_choice "0-8" "请选择操作")"
        case "${c}" in
            "") exit 10 ;;
            1) apply_profile "stock"; read -r -p "按回车继续..." < /dev/tty ;;
            2) apply_profile "aggressive"; read -r -p "按回车继续..." < /dev/tty ;;
            3) manage_ipv4_precedence "enable"; read -r -p "按回车继续..." < /dev/tty ;;
            4) manage_ipv4_precedence "disable"; read -r -p "按回车继续..." < /dev/tty ;;
            5) kernel_manager; read -r -p "按回车返回主菜单..." < /dev/tty ;;
            6) restore_configs; read -r -p "按回车继续..." < /dev/tty ;;
            7) audit_configs; read -r -p "按回车继续..." < /dev/tty ;;
            8) uninstall_and_restore_defaults; read -r -p "按回车继续..." < /dev/tty ;;
            0) exit 0 ;;
            *) sleep 0.5 ;;
        esac
    done
}

main "$@"
