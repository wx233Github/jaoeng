#!/bin/bash
# =============================================================
# 🚀 tcp_optimizer.sh (v2.0.0 - 五边形全栈网络优化引擎)
# =============================================================
# 作者：System Admin
# 描述：生产级 Linux 网络调优脚本。覆盖硬件、网卡队列、拥塞控制、TC 限幅及遥测。
# 版本历史：
#   v2.0.0 - 新增 Ring Buffer 扩容、CAKE 带宽整形、高并发 TCP 优化、遥测监控、IRQ检查
#   v1.5.0 - 新增自动关闭 TSO/GSO 及 Systemd 持久化、MTU 巨型帧诊断
#   v1.4.0 - 新增 UDP/QUIC 缓冲区优化
#   v1.3.0 - 新增虚拟化检测、基准测试
#   v1.0.0 - 初始发布
# =============================================================

set -euo pipefail

# -------------------------------------------------------------
# 全局变量与常量
# -------------------------------------------------------------
readonly SYSCTL_CONF="/etc/sysctl.conf"
readonly MODULES_LOAD_DIR="/etc/modules-load.d"
readonly MODULES_CONF="${MODULES_LOAD_DIR}/tcp_optimizer.conf"
readonly BACKUP_DIR="/var/backups/tcp_optimizer"
readonly TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# 服务持久化路径
readonly NIC_OPT_SERVICE="/etc/systemd/system/nic-optimize.service"
readonly TC_CAKE_SERVICE="/etc/systemd/system/tc-cake.service"

# 虚拟化状态标记 (0=物理机/VM, 1=容器)
IS_CONTAINER=0

# 内核版本需求
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
# 基础工具函数
# -------------------------------------------------------------

log_info() { printf "${COLOR_GREEN}[%s] [INFO] %s${COLOR_RESET}\n" "$(date '+%F %T')" "$*" >&2; }
log_error() { printf "${COLOR_RED}[%s] [ERROR] %s${COLOR_RESET}\n" "$(date '+%F %T')" "$*" >&2; }
log_warn() { printf "${COLOR_YELLOW}[%s] [WARN] %s${COLOR_RESET}\n" "$(date '+%F %T')" "$*" >&2; }
log_step() { printf "${COLOR_CYAN}[%s] [STEP] %s${COLOR_RESET}\n" "$(date '+%F %T')" "$*" >&2; }
log_diag() { printf "${COLOR_BLUE}[%s] [DIAG] %s${COLOR_RESET}\n" "$(date '+%F %T')" "$*" >&2; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_warn "脚本非正常退出 (Code: ${exit_code})。状态可能未完全保存。"
    fi
}
trap cleanup EXIT

# -------------------------------------------------------------
# 环境检查
# -------------------------------------------------------------

check_root() {
    [[ "$(id -u)" -ne 0 ]] && { log_error "必须以 root 用户执行。"; exit 1; }
}

check_dependencies() {
    local deps=(sysctl uname sed modprobe tc grep sort awk ip ping timeout ss bc)
    for cmd in "${deps[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            log_error "缺少必要依赖命令: ${cmd}"
            exit 1
        fi
    done
}

check_virtualization() {
    log_step "检测虚拟化环境..."
    local virt_type="none"
    if command -v systemd-detect-virt &>/dev/null; then
        virt_type=$(systemd-detect-virt -c || echo "none")
    else
        grep -q "docker" /proc/1/cgroup 2>/dev/null && virt_type="docker"
        [[ -f /proc/user_beancounters ]] && virt_type="openvz"
    fi

    if [[ "${virt_type}" != "none" ]]; then
        IS_CONTAINER=1
        log_warn "检测到容器环境: ${virt_type} (将跳过硬件层与队列整形优化)"
    fi
}

get_default_iface() {
    ip route show default | awk '/default/ {print $5}' | head -n1 || echo ""
}

version_ge() {
    local lower
    lower=$(printf '%s\n%s' "$1" "$2" | sort -V | head -n 1)
    [[ "${lower}" == "$2" ]]
}

# -------------------------------------------------------------
# 硬件与底层调优 (IRQ, MTU, TSO, Ring Buffer)
# -------------------------------------------------------------

check_irqbalance() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    log_diag "检查 IRQ (中断) 平衡状态..."
    if systemctl is-active irqbalance &>/dev/null || pgrep irqbalance &>/dev/null; then
        log_info "irqbalance 服务运行正常 (多核网卡中断分配均衡)。"
    else
        echo -e "${COLOR_YELLOW}警告: 未检测到 irqbalance 运行。${COLOR_RESET}"
        echo "在多核高吞吐服务器上，单核处理网卡中断会严重限制带宽。"
        echo "建议执行: apt/yum install irqbalance && systemctl start irqbalance"
    fi
}

optimize_nic_hardware() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    if ! command -v ethtool &>/dev/null; then return 0; fi

    local iface=$(get_default_iface)
    [[ -z "${iface}" ]] && return 0

    log_diag "正在分析网卡 [${iface}] 硬件特性 (TSO/GSO & Ring Buffer)..."
    
    local cmd_offload=""
    local cmd_ring=""
    local need_service=0

    # 1. TSO/GSO 检查
    local tso_state=$(ethtool -k "${iface}" | awk '/tcp-segmentation-offload:/ {print $2}')
    if [[ "${tso_state}" == "on" ]]; then
        echo -e "${COLOR_YELLOW}[诊断] 检测到 TSO (TCP 分段卸载) 已开启。${COLOR_RESET} (可能引发 BBR 微突发延迟)"
        read -rp "是否自动关闭 TSO/GSO 并持久化? [y/N]: " ui_tso
        if [[ "${ui_tso,,}" == "y" ]]; then
            cmd_offload="/sbin/ethtool -K ${iface} tso off gso off;"
            ethtool -K "${iface}" tso off gso off 2>/dev/null || true
            need_service=1
            log_info "TSO/GSO 已下发关闭指令。"
        fi
    fi

    # 2. Ring Buffer 检查
    if ethtool -g "${iface}" &>/dev/null; then
        local rx_max=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '1p')
        local rx_cur=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '2p')
        
        if [[ -n "${rx_max}" && -n "${rx_cur}" && "${rx_cur}" -lt "${rx_max}" ]]; then
            echo -e "${COLOR_YELLOW}[诊断] 网卡 RX Ring Buffer 当前为 ${rx_cur}，硬件支持最大 ${rx_max}。${COLOR_RESET} (可能导致高负载时物理层丢包)"
            read -rp "是否扩容 Ring Buffer 至最大值 (${rx_max}) 并持久化? [y/N]: " ui_ring
            if [[ "${ui_ring,,}" == "y" ]]; then
                cmd_ring="/sbin/ethtool -G ${iface} rx ${rx_max} tx ${rx_max} 2>/dev/null || true;"
                eval "${cmd_ring}"
                need_service=1
                log_info "Ring Buffer 已下发扩容指令。"
            fi
        fi
    fi

    # 3. 生成持久化服务
    if [[ ${need_service} -eq 1 ]]; then
        log_step "配置硬件优化持久化服务 (nic-optimize.service)..."
        cat <<EOF > "${NIC_OPT_SERVICE}"
[Unit]
Description=NIC Hardware Optimization (TSO/GSO/RingBuffer)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "${cmd_offload} ${cmd_ring}"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable nic-optimize.service
        log_info "网卡硬件参数已锁定。"
    fi
}

# -------------------------------------------------------------
# 遥测监控面板 (Telemetry Dashboard)
# -------------------------------------------------------------

monitor_tcp_bbr() {
    clear
    log_step "启动 BBR/TCP 实时遥测仪 (按 Ctrl+C 退出)..."
    echo "依赖: ss (iproute2)"
    echo "================================================="
    
    while true; do
        echo -en "\033[H\033[2J" # 清屏
        echo -e "${COLOR_CYAN}>>> TCP BBR 实时连接追踪 (刷新频率: 2s) <<<${COLOR_RESET}"
        echo "时间: $(date '+%H:%M:%S')"
        echo "----------------------------------------------------------------------"
        printf "%-25s %-15s %-10s %-15s\n" "Remote Address" "RTT(延迟)" "Cwnd(窗口)" "Pacing Rate"
        echo "----------------------------------------------------------------------"
        
        # 抓取 ESTAB 状态且包含 bbr 的连接
        local ss_out=$(ss -tin state established | grep -A 1 "bbr")
        
        if [[ -z "${ss_out}" ]]; then
            echo "当前无活动的 BBR TCP 连接。尝试在其他终端下载文件或发包测试。"
        else
            # 解析 ss 输出
            echo "${ss_out}" | awk '
            /^ESTAB/ { 
                split($5, a, ":"); remote=a[1] 
            }
            /bbr/ {
                rtt="--"; cwnd="--"; pacing="--"
                match($0, /rtt:[0-9.]+\/[0-9.]+/); if(RSTART) rtt=substr($0, RSTART+4, RLENGTH-4)
                match($0, /cwnd:[0-9]+/); if(RSTART) cwnd=substr($0, RSTART+5, RLENGTH-5)
                match($0, /pacing_rate [0-9.]+[A-Za-z]+/); if(RSTART) pacing=substr($0, RSTART+12, RLENGTH-12)
                printf "%-25s %-15s %-10s %-15s\n", remote, rtt " ms", cwnd, pacing
            }' | head -n 15
        fi
        echo "----------------------------------------------------------------------"
        echo "Pacing Rate: BBR 决定当前连接的最大发送速率"
        echo "Cwnd: 拥塞窗口大小 (越大吞吐越高)"
        sleep 2
    done
}

# -------------------------------------------------------------
# 回滚与看门狗
# -------------------------------------------------------------

rollback_config() {
    local backup_file="$1"
    if [[ -f "${backup_file}" ]]; then
        log_warn "=== 触发自动回滚 ==="
        cp "${backup_file}" "${SYSCTL_CONF}"
        sysctl -p >/dev/null 2>&1 || true
        
        local iface=$(get_default_iface)
        if [[ -n "${iface}" ]]; then
            tc qdisc del dev "${iface}" root 2>/dev/null || true
        fi
        
        [[ -f "${MODULES_CONF}" ]] && rm -f "${MODULES_CONF}"
        [[ -f "${TC_CAKE_SERVICE}" ]] && rm -f "${TC_CAKE_SERVICE}" && systemctl disable tc-cake.service 2>/dev/null || true
        
        log_warn "网络状态已重置。"
    fi
}

connectivity_watchdog() {
    log_step "启动连通性看门狗..."
    local gateway=$(ip route show default | awk '/default/ {print $3}' | head -n1 || echo "1.1.1.1")
    
    if ping -c 3 -W 1 -i 0.2 "${gateway}" >/dev/null 2>&1; then
        echo -e "看门狗: ${COLOR_GREEN}PASS${COLOR_RESET}"
    else
        echo -e "看门狗: ${COLOR_RED}FAIL${COLOR_RESET} (连接丢失)"
        return 1
    fi

    echo -e "${COLOR_YELLOW}配置已下发，请在 15 秒内输入 'y' 确认保留，否则自动回滚。${COLOR_RESET}"
    local ui
    if timeout 15s bash -c 'read -rp "确认? (y/N): " ui; [[ "${ui,,}" == "y" ]]'; then
        log_info "配置已锁定。"
        return 0
    else
        log_error "未确认，拒绝锁定。"
        return 1
    fi
}

# -------------------------------------------------------------
# 协议栈调优核心逻辑
# -------------------------------------------------------------

apply_advanced_tcp() {
    # 彻底清理并禁用会导致丢包的 tcp_tw_recycle
    sed -i '/net.ipv4.tcp_tw_recycle/d' "${SYSCTL_CONF}"
    
    cat <<EOF >> "${SYSCTL_CONF}"
# --- Advanced TCP & High Concurrency Optimization ---
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
EOF
}

configure_cake_shaper() {
    [[ ${IS_CONTAINER} -eq 1 ]] && return 0
    local iface=$(get_default_iface)
    [[ -z "${iface}" ]] && return 0

    echo -e "${COLOR_CYAN}[CAKE 带宽整形]${COLOR_RESET} 如果上游带宽受限，配置限幅能彻底消除缓冲膨胀。"
    read -rp "是否配置 CAKE 带宽限幅？[不配置请按回车, 配置请输入公网总带宽(单位:Mbps)]: " ui_bw
    
    if [[ "${ui_bw}" =~ ^[0-9]+$ ]]; then
        # 计算 95% 保留带宽防止上游队列积压
        local safe_bw=$(echo "${ui_bw} * 0.95" | bc | awk '{printf "%d", $1}')
        if [[ ${safe_bw} -lt 1 ]]; then safe_bw=1; fi
        
        log_step "将为网卡 ${iface} 配置 CAKE 带宽限幅: ${safe_bw}mbit..."
        
        # 清理旧规则
        tc qdisc del dev "${iface}" root 2>/dev/null || true
        # 写入 tc 服务持久化
        cat <<EOF > "${TC_CAKE_SERVICE}"
[Unit]
Description=CAKE Bandwidth Shaper
After=network.target network-online.target

[Service]
Type=oneshot
ExecStartPre=-/sbin/tc qdisc del dev ${iface} root
ExecStart=/sbin/tc qdisc add dev ${iface} root cake bandwidth ${safe_bw}mbit nat
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable tc-cake.service
        systemctl restart tc-cake.service
        log_info "TC CAKE 带宽限幅 (${safe_bw}Mbit) 已生效。"
    else
        log_info "跳过带宽整形，将使用无限制的 CAKE sysctl 模式。"
    fi
}

safe_apply_sysctl() {
    local target_qdisc="$1"
    local target_cc="$2"
    local module_name="$3"

    local backup_file=$(backup_config)

    # 1. 硬件/中断预调优
    check_irqbalance
    optimize_nic_hardware

    # 2. Sysctl 处理
    log_step "写入全栈协议配置..."
    sed -i '/net.core.default_qdisc/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_congestion_control/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_ecn/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_fastopen/d' "${SYSCTL_CONF}"
    sed -i '/net.core.rmem_/d' "${SYSCTL_CONF}"
    sed -i '/net.core.wmem_/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_fin_timeout/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_max_tw_buckets/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_max_syn_backlog/d' "${SYSCTL_CONF}"
    sed -i '/net.ipv4.tcp_syncookies/d' "${SYSCTL_CONF}"

    if [[ -n "${target_qdisc}" && -n "${target_cc}" ]]; then
        # 如果是带有带宽整形的 CAKE，qdisc 交由 tc 接管，sysctl 设为 fq_codel 避免冲突
        local sysctl_qdisc="${target_qdisc}"
        if [[ "${target_qdisc}" == "cake_shaped" ]]; then
            sysctl_qdisc="fq_codel"
        fi

        cat <<EOF >> "${SYSCTL_CONF}"
net.core.default_qdisc = ${sysctl_qdisc}
net.ipv4.tcp_congestion_control = ${target_cc}
EOF
        apply_advanced_tcp
    fi

    sysctl -p > /dev/null 2>&1 || true

    # 3. 队列整形处理 (TC CAKE)
    if [[ "${target_qdisc}" == "cake" || "${target_qdisc}" == "cake_shaped" ]]; then
        configure_cake_shaper
    fi

    # 4. 看门狗
    if [[ -n "${target_qdisc}" ]]; then
        if ! connectivity_watchdog; then
            rollback_config "${backup_file}"
            return 1
        fi
    fi

    # 5. 模块持久化
    if [[ -n "${module_name}" && ${IS_CONTAINER} -eq 0 ]]; then
        mkdir -p "${MODULES_LOAD_DIR}"
        echo -e "# Auto-generated\ntcp_bbr\n${module_name}" > "${MODULES_CONF}"
    elif [[ -z "${module_name}" ]]; then
        # 恢复默认时清理所有
        rm -f "${MODULES_CONF}"
        tc qdisc del dev "$(get_default_iface)" root 2>/dev/null || true
        if [[ -f "${TC_CAKE_SERVICE}" ]]; then systemctl disable tc-cake.service 2>/dev/null; rm -f "${TC_CAKE_SERVICE}"; fi
        if [[ -f "${NIC_OPT_SERVICE}" ]]; then systemctl disable nic-optimize.service 2>/dev/null; rm -f "${NIC_OPT_SERVICE}"; fi
    fi

    log_info "核心优化完成。"
}

# -------------------------------------------------------------
# 业务入口
# -------------------------------------------------------------

configure_algo() {
    local qdisc="$1"
    local cc="bbr"
    local min_kver="$2"
    local mod="sch_$1"
    [[ "$qdisc" == "fq" ]] && mod="sch_fq"

    if [[ ${IS_CONTAINER} -eq 0 ]]; then
        local kv=$(uname -r | cut -d- -f1)
        if ! version_ge "${kv}" "${min_kver}"; then log_error "内核需 >= $min_kver"; return 1; fi
        modprobe "${mod}" || { log_error "无法加载 ${mod}"; return 1; }
        modprobe tcp_bbr || true
    fi

    # 标记符，用于在应用 sysctl 后触发 configure_cake_shaper
    local target_qdisc="${qdisc}"
    [[ "${qdisc}" == "cake" ]] && target_qdisc="cake_shaped"

    safe_apply_sysctl "${target_qdisc}" "${cc}" "${mod}"
}

show_menu() {
    clear
    echo "========================================================"
    echo -e " 五边形全栈网络优化引擎 ${COLOR_YELLOW}(v2.0.0 Pro)${COLOR_RESET}"
    echo "========================================================"
    echo " 1. 启用 BBR + FQ      (推荐: 通用场景, 含高并发防洪泛)"
    echo " 2. 启用 BBR + FQ_PIE  (需 Kernel >= 5.6)"
    echo " 3. 启用 BBR + CAKE    (极客: 彻底消灭缓冲膨胀, 硬件调优)"
    echo " 4. 实时监控 BBR 状态  (延迟/拥塞窗口/发送速率)"
    echo " 5. 恢复系统默认设置   (移除所有优化与 Systemd 服务)"
    echo " 0. 退出"
    echo "========================================================"
}

main() {
    check_root
    check_dependencies
    check_virtualization

    while true; do
        show_menu
        read -rp "选择 [0-5]: " c
        case "$c" in
            1) configure_algo "fq" "${MIN_KERNEL_BBR}"; read -rp "Press Enter...";;
            2) configure_algo "fq_pie" "${MIN_KERNEL_FQ_PIE}"; read -rp "Press Enter...";;
            3) configure_algo "cake" "${MIN_KERNEL_CAKE}"; read -rp "Press Enter...";;
            4) monitor_tcp_bbr;;
            5) log_warn "准备恢复默认..."; safe_apply_sysctl "" "" ""; read -rp "Press Enter...";;
            0) exit 0 ;;
            *) log_error "无效输入"; sleep 1 ;;
        esac
    done
}

main "${@}"
