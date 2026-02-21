#!/bin/bash
# =============================================================
# 🚀 tcp_optimizer.sh (v5.5.0 - 终极画像调优引擎 / 容错增强版)
# =============================================================
# 作者：System Admin
# 描述：全景 Linux 网络调优引擎。集成 XanMod 向导、终极画像选择。
# 版本历史：
#   v5.5.0 - 修复 sysctl/modprobe 失败导致脚本意外退出的 Bug，增强容器兼容性
#   v5.4.0 - 重构菜单 UI，细化 Gaming/Streaming/Balanced 画像策略
#   v5.3.0 - 新增 XanMod 内核向导、应用画像 (Profile) 系统
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

# 颜色定义
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_WHITE='\033[1;37m'

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
    if curl -s --connect-timeout 2 -I https://www.google.com >/dev/null 2>&1; then
        IS_CHINA_IP=0
    else
        IS_CHINA_IP=1
    fi
}

install_dependencies() {
    local missing=("$@")
    if command -v apt-get &>/dev/null; then
        # 容错：update 失败不应中断脚本
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
        if [[ "${ui_dep,,}" == "y" ]]; then
            install_dependencies "${missing[@]}"
        else log_error "终止执行。"; exit 1; fi
    fi
}

check_environment() {
    local virt_type="none"
    if command -v systemd-detect-virt &>/dev/null; then virt_type=$(systemd-detect-virt -c || echo none); else
        grep -q "docker" /proc/1/cgroup 2>/dev/null && virt_type="docker"
        [[ -f /proc/user_beancounters ]] && virt_type="openvz"
    fi
    if [[ "${virt_type}" != "none" && "${virt_type}" != "kvm" && "${virt_type}" != "vmware" && "${virt_type}" != "microsoft" ]]; then
        IS_CONTAINER=1
    fi
    TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    check_systemd
}

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
        read -rp "按回车返回..."
        return
    fi

    if [[ ! -f /etc/debian_version ]]; then
        log_warn "非 Debian/Ubuntu 系统，暂不支持自动安装 XanMod。"
        read -rp "按回车返回..."
        return
    fi

    echo "即将安装 XanMod x64v3 内核 (原生支持 BBRv3 + CAKE)。"
    read -rp "确认安装? [y/N]: " ui_inst
    if [[ "${ui_inst,,}" != "y" ]]; then return; fi

    log_step "导入 GPG Key..."
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
    
    log_step "添加源列表..."
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list

    log_step "更新并安装..."
    apt-get update -y || true
    if apt-get install -y linux-xanmod-x64v3; then
        echo -e "${COLOR_GREEN}XanMod 内核安装成功！${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}请重启服务器以启用新内核。${COLOR_RESET}"
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
    
    # TSO/GSO (Skip AWS ENA)
    if [[ ! -f "/sys/class/net/${iface}/device/vendor" ]] || [[ "$(cat "/sys/class/net/${iface}/device/vendor")" != "0x1d0f" ]]; then
        local tso_state=$(ethtool -k "${iface}" 2>/dev/null | awk '/tcp-segmentation-offload:/ {print $2}' || echo "unknown")
        [[ "${tso_state}" == "on" ]] && cmd_all+="/sbin/ethtool -K ${iface} tso off gso off; "
    fi

    # Ring Buffer
    if ethtool -g "${iface}" &>/dev/null; then
        local rx_max=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '1p' || echo "")
        local rx_cur=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '2p' || echo "")
        if [[ -n "${rx_max}" && -n "${rx_cur}" && "${rx_cur}" -lt "${rx_max}" ]]; then
            cmd_all+="/sbin/ethtool -G ${iface} rx ${rx_max} tx ${rx_max} 2>/dev/null || true; "
        fi
    fi

    # RPS & Txqueuelen
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
Description=NIC Hardware & RPS Optimization
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
    
    local mod_name="tcp_bbr"
    if [[ "${target_cc}" == "bbr3" ]] && modprobe -n tcp_bbr3 &>/dev/null; then mod_name="tcp_bbr3"; fi

    local param_file="/sys/module/${mod_name}/parameters/min_rtt_win_sec"
    
    if [[ -w "${param_file}" ]]; then
        echo 2 > "${param_file}" 2>/dev/null || true
        mkdir -p "$(dirname "${MODPROBE_D_CONF}")"
        echo "options ${mod_name} min_rtt_win_sec=2" > "${MODPROBE_D_CONF}"
    fi
}

# -------------------------------------------------------------
# 模块：Sysctl 与画像生成
# -------------------------------------------------------------

generate_sysctl_content() {
    local target_qdisc="$1"
    local target_cc="$2"
    local is_aggressive="$3"
    local buffer_size="134217728" 

    echo "# ============================================================="
    echo "# TCP Optimizer (Profile: ${target_cc} + ${target_qdisc} | Aggressive: ${is_aggressive})"
    echo "# ============================================================="

    cat <<EOF
# --- C100K 核心 ---
fs.file-max = 2097152
fs.nr_open = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1

# --- 全时激进缓冲区 (128MB) ---
net.core.rmem_max = ${buffer_size}
net.core.wmem_max = ${buffer_size}
net.core.rmem_default = ${buffer_size}
net.core.wmem_default = ${buffer_size}
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_limit_output_bytes = 131072

# --- 连接追踪与保活 ---
net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_max_orphans = 65536

# --- 算法与队列 ---
net.core.default_qdisc = ${target_qdisc}
net.ipv4.tcp_congestion_control = ${target_cc}
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# --- 路由 ---
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

    # 1. 检测可用算法
    local avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    local has_bbr3=0
    if echo "${avail_cc}" | grep -qw "bbr3"; then has_bbr3=1; fi

    # 2. 确定策略 (与 v5.4.0 逻辑一致)
    case "${profile_type}" in
        "gaming")
            # 极速网游: BBRv3 + CAKE (优先) > BBRv1 + FQ_PIE
            log_step "加载画像: [极速网游 / Gaming]"
            if [[ ${has_bbr3} -eq 1 ]]; then target_cc="bbr3"; else target_cc="bbr"; fi
            
            # 使用 set +e 探测模块，避免脚本退出
            set +e
            if modprobe sch_cake >/dev/null 2>&1; then target_qdisc="cake"
            elif modprobe sch_fq_pie >/dev/null 2>&1; then target_qdisc="fq_pie"
            else target_qdisc="fq"; fi
            set -e
            
            is_aggressive=0
            ;;
        "streaming")
            # 流媒体: BBRv1 + FQ + 激进参数
            log_step "加载画像: [流媒体 / Streaming]"
            target_cc="bbr" 
            target_qdisc="fq"
            is_aggressive=1
            ;;
        "balanced")
            # 平衡模式: BBRv3 + FQ_PIE
            log_step "加载画像: [平衡模式 / Balanced]"
            if [[ ${has_bbr3} -eq 1 ]]; then target_cc="bbr3"; else target_cc="bbr"; fi
            
            set +e
            if modprobe sch_fq_pie >/dev/null 2>&1; then target_qdisc="fq_pie"
            else target_qdisc="fq"; fi
            set -e
            
            is_aggressive=0
            ;;
    esac

    # 3. 加载模块 (容错处理)
    if [[ ${IS_CONTAINER} -eq 0 ]]; then
        log_step "加载内核模块..."
        set +e # 关闭严格模式，防止模块加载失败(如VPS锁定内核)导致退出
        [[ "${target_qdisc}" != "fq" ]] && modprobe "sch_${target_qdisc}" 2>/dev/null
        modprobe "tcp_${target_cc}" 2>/dev/null
        set -e
    fi

    # 4. 硬件调优与参数注入
    optimize_nic_hardware
    inject_bbr_module_params "${target_cc}" "${is_aggressive}"
    
    # 5. 写入与应用 Sysctl
    log_step "写入 Sysctl 配置..."
    mkdir -p "${SYSCTL_d_DIR}"
    generate_sysctl_content "${target_qdisc}" "${target_cc}" "${is_aggressive}" > "${SYSCTL_CONF}"

    # 生效 (关键修复：允许失败)
    set +e
    modprobe nf_conntrack >/dev/null 2>&1
    log_step "应用内核参数 (可能出现部分参数报错，已自动忽略)..."
    
    if sysctl -p "${SYSCTL_CONF}" >/dev/null 2>&1; then
        log_info "内核参数完整加载成功。"
    else
        log_warn "部分内核参数应用失败。原因可能是：1.容器环境权限不足 2.内核版本不支持特定参数(如CAKE/SlowStart)。"
        log_warn "但这通常是无害的，有效参数已生效。"
    fi
    set -e

    log_info "✅ 优化完成！"
    if [[ "${is_aggressive}" == "1" ]]; then
        echo -e "${COLOR_RED}🔥 已启用激进抢占 (No Slow-Start)${COLOR_RESET}"
    fi
}

manage_ipv4_precedence() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    local action="$1"
    if [[ ! -f "${GAI_CONF}" ]]; then [[ -d "/etc" ]] && touch "${GAI_CONF}"; fi
    if [[ "${action}" == "enable" ]]; then
        if grep -q "precedence ::ffff:0:0/96" "${GAI_CONF}"; then
            sed -i 's/^#*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"
        else
            echo "precedence ::ffff:0:0/96  100" >> "${GAI_CONF}"
        fi
        log_info "IPv4 优先策略已启用。"
    else
        sed -i 's/^precedence ::ffff:0:0\/96.*/#precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"
        log_info "IPv4 优先策略已禁用。"
    fi
}

# -------------------------------------------------------------
# 交互菜单
# -------------------------------------------------------------

get_current_status() {
    local kver=$(uname -r)
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    echo -e " 内核: ${COLOR_WHITE}${kver}${COLOR_RESET}"
    echo -e " 算法: ${COLOR_CYAN}${cc}${COLOR_RESET} + ${COLOR_CYAN}${qdisc}${COLOR_RESET}"
}

show_menu() {
    clear
    local mem_mb=$((TOTAL_MEM_KB / 1024))
    echo "========================================================"
    echo -e " 终极画像调优引擎 ${COLOR_YELLOW}(v5.5.0 Stable)${COLOR_RESET}"
    echo "========================================================"
    get_current_status
    echo "--------------------------------------------------------"
    if [[ ${mem_mb} -lt 1500 ]]; then
        echo -e " ${COLOR_RED}[警告] 内存 < 1.5GB。流媒体模式(128MB缓冲)可能导致崩溃！${COLOR_RESET}"
        echo "--------------------------------------------------------"
    fi
    echo -e " 1. 极速网游 ${COLOR_GREEN}[Gaming]${COLOR_RESET}"
    echo -e "    -> ${COLOR_WHITE}BBRv3 + CAKE/FQ_PIE + 低抖动${COLOR_RESET} (推荐 XanMod)"
    echo ""
    echo -e " 2. 流媒体   ${COLOR_RED}[Streaming]${COLOR_RESET}"
    echo -e "    -> ${COLOR_WHITE}BBRv1 + FQ + 激进128MB缓冲${COLOR_RESET} (暴力吞吐)"
    echo ""
    echo -e " 3. 平衡模式 ${COLOR_BLUE}[Balanced]${COLOR_RESET}"
    echo -e "    -> ${COLOR_WHITE}BBRv3 + FQ_PIE${COLOR_RESET} (通用场景)"
    echo "--------------------------------------------------------"
    echo " 4. 安装 XanMod 内核 (Debian/Ubuntu Only)"
    echo " 5. 开启 IPv4 强制优先"
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
        read -rp "请选择画像或指令 [0-7]: " c
        case "$c" in
            1) apply_profile "gaming"; read -rp "按回车继续...";;
            2) apply_profile "streaming"; read -rp "按回车继续...";;
            3) apply_profile "balanced"; read -rp "按回车继续...";;
            4) install_xanmod_kernel;;
            5) manage_ipv4_precedence "enable"; read -rp "按回车继续...";;
            6) manage_ipv4_precedence "disable"; read -rp "按回车继续...";;
            7) 
                log_warn "正在卸载..."
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
