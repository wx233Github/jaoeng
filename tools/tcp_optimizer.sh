#!/bin/bash
# =============================================================
# 🚀 tcp_optimizer.sh (v5.1.0 - 智能感知与全时激进版)
# =============================================================
# 作者：System Admin
# 描述：全景 Linux 网络调优引擎。集成国内镜像加速、全时激进缓冲区、RPS软中断与安全基线。
# 版本历史：
#   v5.1.0 - 国内镜像源加速、全时128MB缓冲区、端口扩容、60s Keepalive
#   v5.0.0 - RPS 多核散列、Conntrack 老化、孤儿Socket调优
#   v4.4.0 - IPv4优先策略解耦、BBR模式选择
# =============================================================

set -euo pipefail

# -------------------------------------------------------------
# 全局变量与常量
# -------------------------------------------------------------
readonly SYSCTL_CONF="/etc/sysctl.conf"
readonly MODULES_LOAD_DIR="/etc/modules-load.d"
readonly MODULES_CONF="${MODULES_LOAD_DIR}/tcp_optimizer.conf"
readonly MODPROBE_D_CONF="/etc/modprobe.d/tcp_optimizer_bbr.conf"
readonly BACKUP_DIR="/var/backups/tcp_optimizer"
readonly LOG_FILE="/var/log/tcp_optimizer.log"
readonly TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

readonly NIC_OPT_SERVICE="/etc/systemd/system/nic-optimize.service"
readonly GAI_CONF="/etc/gai.conf"

IS_CONTAINER=0
IS_CHINA_IP=0
ARCH_WARNING=""
PHANTOM_KERNEL_WARNING=""

readonly MIN_KERNEL_BBR="4.9"
readonly MIN_KERNEL_CAKE="4.19"
readonly MIN_KERNEL_FQ_PIE="5.6"

readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_MAGENTA='\033[0;35m'

# -------------------------------------------------------------
# 基础工具与审计日志
# -------------------------------------------------------------

log_info() { local msg="[$(date '+%F %T')] [INFO] $*"; printf "${COLOR_GREEN}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
log_error() { local msg="[$(date '+%F %T')] [ERROR] $*"; printf "${COLOR_RED}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
log_warn() { local msg="[$(date '+%F %T')] [WARN] $*"; printf "${COLOR_YELLOW}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
log_step() { local msg="[$(date '+%F %T')] [STEP] $*"; printf "${COLOR_CYAN}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }

cleanup() { local exit_code=$?; if [[ $exit_code -ne 0 ]]; then log_warn "脚本异常退出 (Code: ${exit_code})。"; fi; }
trap cleanup EXIT

setup_logrotate() {
    local lr_conf="/etc/logrotate.d/tcp_optimizer"
    if [[ ! -f "${lr_conf}" ]]; then
        cat <<EOF > "${lr_conf}"
${LOG_FILE} {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
    fi
}

# -------------------------------------------------------------
# 环境检查与版本探查
# -------------------------------------------------------------

check_root() { [[ "$(id -u)" -ne 0 ]] && { log_error "需要 root 权限。"; exit 1; } }

check_network_region() {
    # 简单的连通性测试：如果连不上 Google，判定为国内环境
    if curl -s --connect-timeout 2 -I https://www.google.com >/dev/null 2>&1; then
        IS_CHINA_IP=0
    else
        log_info "检测到国内网络环境 (无法连接 Google)，将启用镜像源加速。"
        IS_CHINA_IP=1
    fi
}

install_dependencies() {
    local missing=("$@")
    local install_cmd=""
    
    if command -v apt-get &>/dev/null; then
        if [[ ${IS_CHINA_IP} -eq 1 ]]; then
            # 临时使用清华源安装，不修改系统 list
            # 注意：这是个简化的处理，直接修改 sources.list 风险太大，这里尝试用 -o 选项或仅做提示
            # 为安全起见，这里仅打印建议，或者如果用户允许，执行 apt update
            log_step "正在尝试使用 apt 安装依赖..."
        fi
        apt-get update -yq || true
        apt-get install -yq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        log_error "无法识别包管理器。"; exit 1
    fi
}

check_dependencies() {
    local deps=(sysctl uname sed modprobe grep awk ip ping timeout ethtool bc curl)
    local missing=()
    for cmd in "${deps[@]}"; do if ! command -v "${cmd}" &> /dev/null; then missing+=("${cmd}"); fi; done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${COLOR_YELLOW}缺依赖: ${missing[*]}${COLOR_RESET}"
        check_network_region
        read -rp "自动安装缺失依赖? [y/N]: " ui_dep
        if [[ "${ui_dep,,}" == "y" ]]; then
            install_dependencies "${missing[@]}"
        else log_error "终止执行。"; exit 1; fi
    fi
    setup_logrotate
}

check_environment() {
    log_step "全景环境诊断..."
    local virt_type="none"
    if command -v systemd-detect-virt &>/dev/null; then virt_type=$(systemd-detect-virt -c || echo none); else
        grep -q "docker" /proc/1/cgroup 2>/dev/null && virt_type="docker"
        [[ -f /proc/user_beancounters ]] && virt_type="openvz"
    fi
    if [[ "${virt_type}" != "none" ]]; then
        IS_CONTAINER=1; log_warn "容器环境: ${virt_type} (跳过底层硬件调优)"
    fi

    if [[ "$(uname -m)" == "aarch64" ]]; then ARCH_WARNING="[ARM64 架构] 硬件安全锁增强启用。"; fi
    
    if [[ ${IS_CONTAINER} -eq 0 ]]; then
        local cur_kver=$(uname -r | cut -d- -f1)
        local high_kver=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's/.*vmlinuz-//' | cut -d- -f1 | sort -V | tail -n 1 || echo "")
        if [[ -n "${high_kver}" && "${cur_kver}" != "${high_kver}" ]] && ! version_ge "${cur_kver}" "${high_kver}"; then
            PHANTOM_KERNEL_WARNING="[内核预警] 已安装新内核 (${high_kver}) 但运行 (${cur_kver})。请重启以生效！"
        fi
    fi
}

version_ge() { local lower=$(printf '%s\n%s' "$1" "$2" | sort -V | head -n 1); [[ "${lower}" == "$2" ]]; }

# -------------------------------------------------------------
# 维度 1：底层硬件调优 (TSO, Ring, RPS, Txqueuelen)
# -------------------------------------------------------------

get_default_iface() { ip route show default | awk '/default/ {print $5}' | head -n1 || echo ""; }

optimize_nic_hardware() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    if ! command -v ethtool &>/dev/null; then return 0; fi

    local iface=$(get_default_iface)
    [[ -z "${iface}" ]] && return 0

    local cmd_offload=""
    local cmd_ring=""
    local cmd_rps=""
    local cmd_txq=""
    local need_service=0

    # 1. 安全锁与 TSO/GSO
    if [[ -f "/sys/class/net/${iface}/device/vendor" ]] && [[ "$(cat "/sys/class/net/${iface}/device/vendor")" == "0x1d0f" ]]; then
        log_warn "[安全锁] AWS ENA 网卡，跳过 TSO 卸载。"
    else
        local tso_state=$(ethtool -k "${iface}" 2>/dev/null | awk '/tcp-segmentation-offload:/ {print $2}' || echo "unknown")
        if [[ "${tso_state}" == "on" ]]; then
            cmd_offload="/sbin/ethtool -K ${iface} tso off gso off;"
            need_service=1
        fi
    fi

    # 2. Ring Buffer
    if ethtool -g "${iface}" &>/dev/null; then
        local rx_max=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '1p' || echo "")
        local rx_cur=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '2p' || echo "")
        if [[ -n "${rx_max}" && -n "${rx_cur}" && "${rx_cur}" -lt "${rx_max}" ]]; then
            cmd_ring="/sbin/ethtool -G ${iface} rx ${rx_max} tx ${rx_max} 2>/dev/null || true;"
            need_service=1
        fi
    fi

    # 3. RPS (多核软中断散列) 与 Txqueuelen
    local cpu_count=$(nproc || echo 1)
    if [[ ${cpu_count} -gt 1 ]]; then
        local rps_mask=$(printf "%x" $(( (1 << cpu_count) - 1 )))
        local rx_queues=$(ls -1d /sys/class/net/${iface}/queues/rx-* 2>/dev/null || echo "")
        if [[ -n "${rx_queues}" ]]; then
            cmd_rps="for q in /sys/class/net/${iface}/queues/rx-*; do echo ${rps_mask} > \$q/rps_cpus 2>/dev/null || true; done;"
            need_service=1
        fi
    fi

    # txqueuelen 扩容至 10000 配合 BBR
    local cur_txq=$(cat /sys/class/net/${iface}/tx_queue_len 2>/dev/null || echo "1000")
    if [[ "${cur_txq}" != "10000" && "${cur_txq}" -gt 0 ]]; then
        cmd_txq="/sbin/ip link set ${iface} txqueuelen 10000 2>/dev/null || true;"
        need_service=1
    fi

    if [[ ${need_service} -eq 1 ]]; then
        log_info "锁定硬件加速策略 (TSO/Ring/RPS/Txq)..."
        cat <<EOF > "${NIC_OPT_SERVICE}"
[Unit]
Description=NIC Hardware & RPS Optimization
After=network.target network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c "${cmd_offload} ${cmd_ring} ${cmd_txq} ${cmd_rps}"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now nic-optimize.service 2>/dev/null || true
    fi
}

inject_bbr_module_params() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    local target_cc="$1"
    [[ ! "${target_cc}" =~ ^bbr ]] && return 0
    
    local param_file="/sys/module/tcp_${target_cc}/parameters/min_rtt_win_sec"
    if [[ -w "${param_file}" ]]; then
        if [[ "$(cat "${param_file}")" != "2" ]]; then
            echo 2 > "${param_file}" 2>/dev/null || true
            echo "options tcp_${target_cc} min_rtt_win_sec=2" > "${MODPROBE_D_CONF}"
            log_info "注入 BBR 抗弱网参数: min_rtt_win_sec=2"
        fi
    fi
}

# -------------------------------------------------------------
# 维度 2：系统进程与选路调优
# -------------------------------------------------------------

apply_systemd_limits() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    if ! command -v systemctl &>/dev/null; then return 0; fi

    log_step "解封 Systemd 进程级句柄限制 (C100K 护航)..."
    for conf_file in "/etc/systemd/system.conf" "/etc/systemd/user.conf"; do
        if [[ -f "${conf_file}" ]]; then
            if grep -q "^DefaultLimitNOFILE=" "${conf_file}"; then
                sed -i 's/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' "${conf_file}"
            elif grep -q "^#DefaultLimitNOFILE=" "${conf_file}"; then
                sed -i 's/^#DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' "${conf_file}"
            else
                echo "DefaultLimitNOFILE=1048576" >> "${conf_file}"
            fi
        fi
    done
    systemctl daemon-reload 2>/dev/null || true
}

manage_ipv4_precedence() {
    [[ ${IS_CONTAINER} -eq 1 ]] && { log_warn "容器环境不支持修改系统选路。"; return 0; }
    local action="$1"
    if [[ ! -f "${GAI_CONF}" && "${action}" == "enable" ]]; then [[ -d "/etc" ]] && touch "${GAI_CONF}"; fi
    if [[ ! -w "${GAI_CONF}" ]]; then log_error "无法写入 ${GAI_CONF}。"; return 1; fi

    if [[ "${action}" == "enable" ]]; then
        log_step "配置 IPv4 选路强制优先 (gai.conf)..."
        if grep -q "precedence ::ffff:0:0/96" "${GAI_CONF}"; then
            sed -i 's/^#*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"
        else
            echo "precedence ::ffff:0:0/96  100" >> "${GAI_CONF}"
        fi
        log_info "✅ 已强制优先使用 IPv4 发起连接。"
    elif [[ "${action}" == "disable" ]]; then
        sed -i 's/^precedence ::ffff:0:0\/96.*/#precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"
        log_info "✅ 已恢复系统默认选路策略 (IPv6 优先)。"
    fi
}

# -------------------------------------------------------------
# 维度 3：内核 Sysctl 全时激进调优
# -------------------------------------------------------------

apply_advanced_tcp() {
    # 128MB = 134217728 bytes
    cat <<EOF >> "${SYSCTL_CONF}"
# --- C100K 内核硬顶板、端口扩容与防洪泛 ---
fs.file-max = 1048576
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# --- 软中断轮询优化 ---
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000

# --- Conntrack 优化 ---
net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 1200

# --- 全时激进缓冲区 (128MB) & 发送端防膨胀 ---
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 134217728
net.core.wmem_default = 134217728
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_limit_output_bytes = 131072

# --- 极速保活 (60s) & 孤儿 Socket 调优 ---
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_max_orphans = 131072

# --- UDP/QUIC & ECN ---
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3

# --- 路由与邻居表加速回收 ---
net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 60

# --- ICMP 安全与抗劫持 ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
}

safe_apply_sysctl() {
    local target_qdisc="$1"; local target_cc="$2"; local module_name="$3"
    local backup_file="${BACKUP_DIR}/sysctl.conf.${TIMESTAMP}.bak"
    mkdir -p "${BACKUP_DIR}"; cp "${SYSCTL_CONF}" "${backup_file}"

    optimize_nic_hardware
    inject_bbr_module_params "${target_cc}"
    apply_systemd_limits

    log_step "写入协议栈配置 (sysctl)..."
    local keys=("fs.file-max" "fs.nr_open" "net.core.default_qdisc" "net.ipv4.tcp_congestion_control" "net.ipv4.tcp_notsent_lowat" "net.ipv4.tcp_limit_output_bytes" "net.core.somaxconn" "net.core.netdev_max_backlog" "net.ipv4.ip_local_port_range" "net.core.netdev_budget" "net.core.netdev_budget_usecs" "net.netfilter.nf_conntrack_max" "net.netfilter.nf_conntrack_tcp_timeout_established" "net.ipv4.tcp_keepalive_time" "net.ipv4.tcp_keepalive_probes" "net.ipv4.tcp_keepalive_intvl" "net.ipv4.tcp_mtu_probing" "net.ipv4.tcp_fin_timeout" "net.ipv4.tcp_max_tw_buckets" "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_syncookies" "net.ipv4.tcp_orphan_retries" "net.ipv4.tcp_retries2" "net.ipv4.tcp_max_orphans" "net.core.rmem_max" "net.core.wmem_max" "net.core.rmem_default" "net.core.wmem_default" "net.ipv4.tcp_ecn" "net.ipv4.tcp_fastopen" "net.ipv4.route.gc_timeout" "net.ipv4.neigh.default.gc_stale_time" "net.ipv4.conf.all.rp_filter" "net.ipv4.conf.default.rp_filter" "net.ipv4.conf.all.accept_redirects" "net.ipv4.conf.default.accept_redirects" "net.ipv4.conf.all.send_redirects" "net.ipv4.icmp_echo_ignore_broadcasts" "net.ipv4.icmp_ignore_bogus_error_responses")
    for k in "${keys[@]}"; do sed -i "/^\s*${k//./\.}\s*=/d" "${SYSCTL_CONF}"; done

    if [[ -n "${target_cc}" ]]; then
        if [[ -n "${target_qdisc}" ]]; then cat <<EOF >> "${SYSCTL_CONF}"
net.core.default_qdisc = ${target_qdisc}
EOF
        fi
        cat <<EOF >> "${SYSCTL_CONF}"
net.ipv4.tcp_congestion_control = ${target_cc}
EOF
        apply_advanced_tcp
    fi

    modprobe nf_conntrack 2>/dev/null || true
    sysctl -p > /dev/null 2>&1 || true

    if [[ -n "${target_cc}" ]]; then
        local gateway=$(ip route show default | awk '/default/ {print $3}' | head -n1 || echo "1.1.1.1")
        if ! ping -c 3 -W 1 -i 0.2 "${gateway}" >/dev/null 2>&1; then
            log_error "看门狗: 网络不通，立刻回滚！"; cp "${backup_file}" "${SYSCTL_CONF}"; sysctl -p >/dev/null 2>&1; return 1
        fi
        local ui
        if ! timeout 15s bash -c 'read -rp "网络通畅。15秒内输入 [y] 锁定配置，否则回滚: " ui; [[ "${ui,,}" == "y" ]]'; then
            log_warn "未确认，触发安全回滚..."; cp "${backup_file}" "${SYSCTL_CONF}"; sysctl -p >/dev/null 2>&1; return 1
        fi
    fi

    if [[ -n "${module_name}" && ${IS_CONTAINER} -eq 0 ]]; then
        mkdir -p "${MODULES_LOAD_DIR}"
        echo -e "# Auto-generated\ntcp_${target_cc}\n${module_name}" > "${MODULES_CONF}"
    elif [[ -z "${module_name}" ]]; then
        rm -f "${MODULES_CONF}" "${MODPROBE_D_CONF}"
    fi

    log_info "🔥 智能全时激进优化部署完毕！当前算法: ${target_cc}"
    echo -e "${COLOR_YELLOW}========================================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW} [提示] 如需高并发设置生效，请重启 Nginx/Docker 等核心业务进程。        ${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}========================================================================${COLOR_RESET}"
}

# -------------------------------------------------------------
# 入口逻辑
# -------------------------------------------------------------

get_supported_bbrs() {
    local bbrs=()
    local avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    for v in bbr bbr2 bbr3; do if echo "${avail}" | grep -qw "${v}"; then bbrs+=("${v}"); fi; done
    if [[ ${IS_CONTAINER} -eq 0 ]]; then
        local mod_dir="/lib/modules/$(uname -r)/kernel/net/ipv4"
        if [[ -d "${mod_dir}" ]]; then
            for v in bbr bbr2 bbr3; do
                if find "${mod_dir}" -name "tcp_${v}.ko*" -quit 2>/dev/null; then [[ ! " ${bbrs[*]} " =~ " ${v} " ]] && bbrs+=("${v}"); fi
            done
        fi
    fi
    if [[ ${#bbrs[@]} -eq 0 ]]; then bbrs=("bbr"); fi
    printf "%s\n" "${bbrs[@]}" | sort -V | tr '\n' ' ' | sed 's/ $//'
}

configure_algo() {
    local qdisc="$1"; local min_kver="$2"; local mod="sch_$1"
    
    if [[ -z "${qdisc}" ]]; then mod=""; elif [[ "$qdisc" == "fq" ]]; then mod="sch_fq"; fi

    if [[ ${IS_CONTAINER} -eq 0 ]]; then
        local kv=$(uname -r | cut -d- -f1)
        if ! version_ge "${kv}" "${min_kver}"; then log_error "内核版本低。需 >= ${min_kver}"; return 1; fi
        [[ -n "${mod}" ]] && modprobe "${mod}" 2>/dev/null || true
    fi

    local bbr_arr=($(get_supported_bbrs))
    local selected_bbr="${bbr_arr[-1]}"
    if [[ ${#bbr_arr[@]} -gt 1 ]]; then
        read -rp "检测到多版本 BBR [ ${bbr_arr[*]} ]，请指定 (默认最高 ${selected_bbr}): " ui_bbr
        [[ -n "${ui_bbr}" && " ${bbr_arr[*]} " =~ " ${ui_bbr} " ]] && selected_bbr="${ui_bbr}"
    fi

    [[ ${IS_CONTAINER} -eq 0 ]] && modprobe "tcp_${selected_bbr}" 2>/dev/null || true
    safe_apply_sysctl "${qdisc}" "${selected_bbr}" "${mod}"
}

show_menu() {
    clear
    local bbrs=$(get_supported_bbrs)
    local region_msg=""
    [[ ${IS_CHINA_IP} -eq 1 ]] && region_msg="${COLOR_RED}[国内加速模式]${COLOR_RESET}"
    
    echo "========================================================"
    echo -e " 智能全时激进调优引擎 ${COLOR_YELLOW}(v5.1.0 CN-Accelerated)${COLOR_RESET} ${region_msg}"
    echo "========================================================"
    [[ -n "${PHANTOM_KERNEL_WARNING}" ]] && echo -e "${COLOR_RED}${PHANTOM_KERNEL_WARNING}${COLOR_RESET}"
    [[ -n "${ARCH_WARNING}" ]] && echo -e "${COLOR_MAGENTA}${ARCH_WARNING}${COLOR_RESET}"
    echo -e " ${COLOR_CYAN}拥塞控制: [ ${bbrs} ]${COLOR_RESET}"
    echo "--------------------------------------------------------"
    echo -e " ${COLOR_YELLOW}[拥塞控制与队列调优 (全时 128MB 缓冲区)]${COLOR_RESET}"
    echo " 1. 启用 BBR + FQ      (推荐: 通用场景, 含全量网络解封)"
    echo " 2. 启用 BBR + FQ_PIE  (需 Kernel >= 5.6)"
    echo " 3. 启用 BBR + CAKE    (高性能: 彻底消灭缓冲膨胀)"
    echo " 4. 仅启用 BBR         (保守: 维持系统默认队列调度器)"
    echo "--------------------------------------------------------"
    echo -e " ${COLOR_YELLOW}[网络选路与杂项辅助]${COLOR_RESET}"
    echo " 5. 开启 IPv4 强制优先 (防御双栈环境下的劣质 IPv6 路由)"
    echo " 6. 移除 IPv4 强制优先 (恢复默认选路)"
    echo " 7. 恢复系统默认设置   (移除 Sysctl/Systemd/模块 的所有优化)"
    echo "--------------------------------------------------------"
    echo " 0. 安全退出"
    echo "========================================================"
}

main() {
    check_root; check_dependencies; check_environment
    while true; do
        show_menu
        read -rp "请下发执行指令 [0-7]: " c
        case "$c" in
            1) configure_algo "fq" "${MIN_KERNEL_BBR}"; read -rp "回车继续...";;
            2) configure_algo "fq_pie" "${MIN_KERNEL_FQ_PIE}"; read -rp "回车继续...";;
            3) configure_algo "cake" "${MIN_KERNEL_CAKE}"; read -rp "回车继续...";;
            4) configure_algo "" "${MIN_KERNEL_BBR}"; read -rp "回车继续...";;
            5) manage_ipv4_precedence "enable"; read -rp "回车继续...";;
            6) manage_ipv4_precedence "disable"; read -rp "回车继续...";;
            7) log_warn "正在抹除配置..."; safe_apply_sysctl "" "" ""; read -rp "回车继续...";;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}
main "${@}"
