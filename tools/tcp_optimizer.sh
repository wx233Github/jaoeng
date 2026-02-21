#!/bin/bash
# =============================================================
# 🚀 tcp_optimizer.sh (v5.4.0 - 终极画像调优引擎)
# =============================================================
# 作者：System Admin
# 描述：全景 Linux 网络调优引擎。集成 XanMod 向导、专属画像(网游/流媒体/平衡)与状态实时监控。
# 版本历史：
#   v5.4.0 - 重构主界面，增加内核与算法状态实时显示，严格锁定菜单选项文本与底层路由映射
#   v5.3.0 - 新增 XanMod 内核向导、应用画像系统、加入激进抢占模式
#   v5.2.0 - 迁移至 /etc/sysctl.d 独立文件
# =============================================================

set -euo pipefail

# -------------------------------------------------------------
# 全局变量与常量
# -------------------------------------------------------------
readonly SYSCTL_d_DIR="/etc/sysctl.d"
readonly SYSCTL_CONF="${SYSCTL_d_DIR}/99-z-tcp-optimizer.conf"

readonly MODULES_LOAD_DIR="/etc/modules-load.d"
readonly MODULES_CONF="${MODULES_LOAD_DIR}/tcp_optimizer.conf"
readonly MODPROBE_D_CONF="/etc/modprobe.d/tcp_optimizer_bbr.conf"
readonly LOG_FILE="/var/log/tcp_optimizer.log"
readonly TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

readonly NIC_OPT_SERVICE="/etc/systemd/system/nic-optimize.service"
readonly GAI_CONF="/etc/gai.conf"

IS_CONTAINER=0
IS_CHINA_IP=0
IS_SYSTEMD=0
TOTAL_MEM_KB=0

# 内核版本基线
readonly MIN_KERNEL_BBR="4.9"
readonly MIN_KERNEL_CAKE="4.19"
readonly MIN_KERNEL_FQ_PIE="5.6"

# 颜色定义
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_BLUE='\033[0;34m'

# -------------------------------------------------------------
# 基础工具与审计日志
# -------------------------------------------------------------

log_info() { local msg="[$(date '+%F %T')] [INFO] $*"; printf "${COLOR_GREEN}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
log_error() { local msg="[$(date '+%F %T')] [ERROR] $*"; printf "${COLOR_RED}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
log_warn() { local msg="[$(date '+%F %T')] [WARN] $*"; printf "${COLOR_YELLOW}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }
log_step() { local msg="[$(date '+%F %T')] [STEP] $*"; printf "${COLOR_CYAN}%s${COLOR_RESET}\n" "${msg}" >&2; echo "${msg}" >> "${LOG_FILE}"; }

cleanup() { 
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then 
        log_warn "脚本异常退出 (Code: ${exit_code})。请检查日志 ${LOG_FILE}"
    fi
}
trap cleanup EXIT

# -------------------------------------------------------------
# 环境与内核检查
# -------------------------------------------------------------

check_root() { [[ "$(id -u)" -ne 0 ]] && { log_error "需要 root 权限。"; exit 1; } }

check_systemd() {
    if [[ -d /run/systemd/system ]] || grep -q systemd <(head -n 1 /proc/1/comm 2>/dev/null); then IS_SYSTEMD=1; else IS_SYSTEMD=0; fi
}

check_network_region() {
    log_step "正在检测网络连通性..."
    if curl -s --connect-timeout 2 -I https://www.google.com >/dev/null 2>&1; then IS_CHINA_IP=0; else IS_CHINA_IP=1; fi
}

install_dependencies() {
    local missing=("$@")
    if command -v apt-get &>/dev/null; then
        apt-get update -yq || true
        apt-get install -yq "${missing[@]}"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing[@]}"
    else
        log_error "无法识别包管理器，请手动安装: ${missing[*]}"; exit 1
    fi
}

check_dependencies() {
    local deps=(sysctl uname sed modprobe grep awk ip ping timeout ethtool bc curl wget gpg)
    local missing=()
    for cmd in "${deps[@]}"; do if ! command -v "${cmd}" &> /dev/null; then missing+=("${cmd}"); fi; done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${COLOR_YELLOW}缺失依赖: ${missing[*]}${COLOR_RESET}"
        check_network_region
        read -rp "自动安装缺失依赖? [y/N]: " ui_dep
        if [[ "${ui_dep,,}" == "y" ]]; then install_dependencies "${missing[@]}"; else log_error "终止执行。"; exit 1; fi
    fi
}

check_environment() {
    log_step "全景环境诊断..."
    local virt_type="none"
    if command -v systemd-detect-virt &>/dev/null; then virt_type=$(systemd-detect-virt -c || echo none); else
        grep -q "docker" /proc/1/cgroup 2>/dev/null && virt_type="docker"
        [[ -f /proc/user_beancounters ]] && virt_type="openvz"
    fi
    if [[ "${virt_type}" != "none" && "${virt_type}" != "kvm" && "${virt_type}" != "vmware" && "${virt_type}" != "microsoft" ]]; then
        IS_CONTAINER=1; log_warn "容器环境: ${virt_type} (跳过硬件调优与内核安装)"
    fi
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    check_systemd
}

version_ge() { local lower=$(printf '%s\n%s' "$1" "$2" | sort -V | head -n 1); [[ "${lower}" == "$2" ]]; }

# -------------------------------------------------------------
# 模块：XanMod 内核向导
# -------------------------------------------------------------

install_xanmod_kernel() {
    [[ ${IS_CONTAINER} -eq 1 ]] && { log_warn "容器环境无法更换内核。"; return; }
    
    echo -e "${COLOR_BLUE}========================================================${COLOR_RESET}"
    echo -e "${COLOR_BLUE}   XanMod Kernel 安装向导 (Debian/Ubuntu Only)          ${COLOR_RESET}"
    echo -e "${COLOR_BLUE}========================================================${COLOR_RESET}"
    
    if grep -iq "xanmod" /proc/version; then
        log_info "✅ 检测到当前已运行 XanMod 内核。"
        read -rp "按回车继续..."
        return
    fi
    if [[ ! -f /etc/debian_version ]]; then log_warn "非 Debian/Ubuntu，暂不支持自动安装 XanMod。"; return; fi

    read -rp "是否尝试安装 XanMod Kernel (推荐 x64v3)? [y/N]: " ui_inst
    if [[ "${ui_inst,,}" != "y" ]]; then return; fi

    log_step "正在导入 XanMod GPG Key..."
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list
    apt-get update -y
    
    log_step "安装 linux-xanmod-x64v3 ..."
    if apt-get install -y linux-xanmod-x64v3; then
        echo -e "${COLOR_GREEN}XanMod 内核安装成功！请在脚本结束后重启服务器。${COLOR_RESET}"
    else
        log_error "安装失败，请检查网络。"
    fi
    read -rp "按回车继续..."
}

# -------------------------------------------------------------
# 模块：底层硬件调优
# -------------------------------------------------------------

get_default_iface() { ip route show default | awk '/default/ {print $5}' | head -n1 || echo ""; }

optimize_nic_hardware() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    if ! command -v ethtool &>/dev/null; then return 0; fi

    local iface=$(get_default_iface)
    [[ -z "${iface}" ]] && return 0

    local cmd_all=""
    
    if [[ ! -f "/sys/class/net/${iface}/device/vendor" ]] || [[ "$(cat "/sys/class/net/${iface}/device/vendor")" != "0x1d0f" ]]; then
        local tso_state=$(ethtool -k "${iface}" 2>/dev/null | awk '/tcp-segmentation-offload:/ {print $2}' || echo "unknown")
        [[ "${tso_state}" == "on" ]] && cmd_all+="/sbin/ethtool -K ${iface} tso off gso off; "
    fi

    if ethtool -g "${iface}" &>/dev/null; then
        local rx_max=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '1p' || echo "")
        local rx_cur=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '2p' || echo "")
        if [[ -n "${rx_max}" && -n "${rx_cur}" && "${rx_cur}" -lt "${rx_max}" ]]; then
            cmd_all+="/sbin/ethtool -G ${iface} rx ${rx_max} tx ${rx_max} 2>/dev/null || true; "
        fi
    fi

    local cpu_count=$(nproc || echo 1)
    if [[ ${cpu_count} -gt 1 ]]; then
        local rps_mask=$(printf "%x" $(( (1 << cpu_count) - 1 )))
        local rx_queues=$(ls -1d /sys/class/net/${iface}/queues/rx-* 2>/dev/null || echo "")
        if [[ -n "${rx_queues}" ]]; then
            cmd_all+="for q in /sys/class/net/${iface}/queues/rx-*; do echo ${rps_mask} > \$q/rps_cpus 2>/dev/null || true; done; "
        fi
    fi

    local cur_txq=$(cat /sys/class/net/${iface}/tx_queue_len 2>/dev/null || echo "1000")
    if [[ "${cur_txq}" != "10000" && "${cur_txq}" -gt 0 ]]; then
        cmd_all+="/sbin/ip link set ${iface} txqueuelen 10000 2>/dev/null || true; "
    fi

    if [[ -n "${cmd_all}" && ${IS_SYSTEMD} -eq 1 ]]; then
        cat <<EOF > "${NIC_OPT_SERVICE}"
[Unit]
Description=NIC Hardware Optimization
After=network.target network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c "${cmd_all}"
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
        echo 2 > "${param_file}" 2>/dev/null || true
        mkdir -p "$(dirname "${MODPROBE_D_CONF}")"
        echo "options tcp_${target_cc} min_rtt_win_sec=2" > "${MODPROBE_D_CONF}"
    fi
}

# -------------------------------------------------------------
# 模块：Sysctl 与画像生成
# -------------------------------------------------------------

generate_sysctl_content() {
    local target_qdisc="$1"
    local target_cc="$2"
    local is_aggressive="$3"
    local buffer_size="134217728" # 128MB 全时激进

    echo "# ============================================================="
    echo "# TCP Optimizer Configuration (Auto-generated v5.4.0)"
    echo "# ============================================================="

    cat <<EOF
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

net.core.rmem_max = ${buffer_size}
net.core.wmem_max = ${buffer_size}
net.core.rmem_default = ${buffer_size}
net.core.wmem_default = ${buffer_size}
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_limit_output_bytes = 131072

net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_max_orphans = 65536

net.core.default_qdisc = ${target_qdisc}
net.ipv4.tcp_congestion_control = ${target_cc}
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

net.ipv4.route.gc_timeout = 100
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

    if [[ "${is_aggressive}" == "1" ]]; then
        echo ""
        echo "# --- 暴力吞吐模式 (Aggressive) ---"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        echo "net.ipv4.tcp_retries2 = 8"
    fi
}

apply_profile() {
    local profile_type="$1"
    local target_qdisc=""
    local target_cc="bbr"
    local is_aggressive=0
    local kver=$(uname -r | cut -d- -f1)
    local avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")

    case "${profile_type}" in
        "latency")
            # 网游模式: BBRv3 + CAKE/FQ_PIE
            log_step "加载画像: [极速网游 / Gaming]"
            if version_ge "${kver}" "${MIN_KERNEL_CAKE}"; then target_qdisc="cake"; elif version_ge "${kver}" "${MIN_KERNEL_FQ_PIE}"; then target_qdisc="fq_pie"; else target_qdisc="fq_codel"; fi
            if echo "${avail_cc}" | grep -q "bbr3"; then target_cc="bbr3"; else target_cc="bbr"; fi
            is_aggressive=0
            ;;
        "throughput")
            # 流媒体模式: BBRv1 + FQ + 激进128MB
            log_step "加载画像: [流媒体 / Streaming]"
            target_qdisc="fq"
            target_cc="bbr" # 强制 BBRv1 暴力吞吐
            is_aggressive=1
            ;;
        "balanced")
            # 平衡模式: BBRv3 + FQ_PIE
            log_step "加载画像: [平衡模式 / Balanced]"
            if version_ge "${kver}" "${MIN_KERNEL_FQ_PIE}"; then target_qdisc="fq_pie"; else target_qdisc="fq"; fi
            if echo "${avail_cc}" | grep -q "bbr3"; then target_cc="bbr3"; else target_cc="bbr"; fi
            is_aggressive=0
            ;;
    esac

    [[ ${IS_CONTAINER} -eq 0 ]] && {
        [[ "${target_qdisc}" == "cake" ]] && modprobe sch_cake 2>/dev/null
        [[ "${target_qdisc}" == "fq_pie" ]] && modprobe sch_fq_pie 2>/dev/null
        [[ "${target_qdisc}" == "fq" ]] && modprobe sch_fq 2>/dev/null
        modprobe "tcp_${target_cc}" 2>/dev/null
    }

    optimize_nic_hardware
    inject_bbr_module_params "${target_cc}" "${is_aggressive}"
    
    mkdir -p "${SYSCTL_d_DIR}"
    [[ -f "${SYSCTL_CONF}" ]] && cp "${SYSCTL_CONF}" "${SYSCTL_CONF}.${TIMESTAMP}.bak"
    generate_sysctl_content "${target_qdisc}" "${target_cc}" "${is_aggressive}" > "${SYSCTL_CONF}"

    modprobe nf_conntrack 2>/dev/null || true
    sysctl -p "${SYSCTL_CONF}" 2>/dev/null || sysctl --system >/dev/null

    local applied_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local applied_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    log_info "✅ 配置已生效: [ 算法: ${applied_cc} + ${applied_qdisc} ]"
}

manage_ipv4_precedence() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    local action="$1"
    if [[ ! -f "${GAI_CONF}" ]]; then [[ -d "/etc" ]] && touch "${GAI_CONF}"; fi
    if [[ "${action}" == "enable" ]]; then
        if grep -q "precedence ::ffff:0:0/96" "${GAI_CONF}"; then sed -i 's/^#*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"; else echo "precedence ::ffff:0:0/96  100" >> "${GAI_CONF}"; fi
        log_info "IPv4 优先已启用。"
    else
        sed -i 's/^precedence ::ffff:0:0\/96.*/#precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"
        log_info "已恢复系统选路策略。"
    fi
}

# -------------------------------------------------------------
# 交互菜单
# -------------------------------------------------------------

show_menu() {
    clear
    local mem_mb=$((TOTAL_MEM_KB / 1024))
    local cur_kver=$(uname -r)
    local cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")

    echo "========================================================"
    echo -e " 🚀 终极画像调优引擎 ${COLOR_YELLOW}(v5.4.0)${COLOR_RESET}"
    echo "========================================================"
    echo -e " 内核：${COLOR_CYAN}${cur_kver}${COLOR_RESET}    算法：${COLOR_CYAN}${cur_cc} + ${cur_qdisc}${COLOR_RESET}"
    echo -e " 物理内存: ${COLOR_CYAN}${mem_mb} MB${COLOR_RESET}"
    if [[ ${mem_mb} -lt 1500 ]]; then
        echo -e " ${COLOR_RED}[警告] 内存 < 1.5GB。全时 128MB 缓冲区可能导致 OOM 崩溃！${COLOR_RESET}"
    fi
    echo "--------------------------------------------------------"
    echo " 1. 极速网游[Ganing](BBRV3 + CAKE/FQ_PIE+低抖动）"
    echo " 2. 流媒体[Streaning]BBRV1 +FQ+激进128MB)"
    echo " 3. 平衡模式[Balanced](BBRV3 + FQ PIE)"
    echo "--------------------------------------------------------"
    echo " 4. 安装 XanMod 内核 (Debian/Ubuntu 推荐)"
    echo " 5. 开启 IPv4 强制优先 (解决 IPv6 绕路)"
    echo " 6. 恢复 IPv6 默认优先级"
    echo " 7. 卸载/恢复系统默认"
    echo "--------------------------------------------------------"
    echo " 0. 退出"
    echo "========================================================"
}

main() {
    check_root; check_dependencies; check_environment
    while true; do
        show_menu
        read -rp "请下发执行指令 [0-7]: " c
        case "$c" in
            1) apply_profile "latency"; read -rp "按回车继续...";;
            2) apply_profile "throughput"; read -rp "按回车继续...";;
            3) apply_profile "balanced"; read -rp "按回车继续...";;
            4) install_xanmod_kernel;;
            5) manage_ipv4_precedence "enable"; read -rp "按回车继续...";;
            6) manage_ipv4_precedence "disable"; read -rp "按回车继续...";;
            7) 
                log_warn "正在抹除配置..."
                rm -f "${SYSCTL_CONF}" "${NIC_OPT_SERVICE}" "${MODULES_CONF}" "${MODPROBE_D_CONF}"
                [[ ${IS_SYSTEMD} -eq 1 ]] && systemctl daemon-reload
                sysctl --system >/dev/null 2>&1
                log_info "已恢复系统默认状态。"
                read -rp "按回车继续..."
                ;;
            0) exit 0 ;;
            *) sleep 0.5 ;;
        esac
    done
}
main "${@}"
