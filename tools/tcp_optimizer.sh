#!/usr/bin/env bash
# =============================================================
# 🚀 tcp_optimizer.sh (v6.5.1 - 终极语法修复 & 安全确认版)
# =============================================================
# 作者：System Admin
# 描述：全景 Linux 网络调优引擎。彻底修复 here-doc 语法，引入配置审计工具与安全确认。
# 版本历史：
#   v6.5.1 - 彻底重构文件写入逻辑，根除 here-doc 漏洞；为卸载增加安全确认；新增应用后即时验证
#   v6.5.0 - 新增配置审计工具，重组菜单
#   v6.4.1 - 修复 here-document 语法崩溃，移除终端时间戳
# =============================================================

set -euo pipefail
IFS=$'\n\t'

JB_NONINTERACTIVE="${JB_NONINTERACTIVE:-false}"

ensure_safe_path() { local target="$1"; if [ -z "${target}" ] || [ "${target}" = "/" ]; then log_error "拒绝对危险路径执行破坏性操作: '${target}'"; exit 1; fi; }

sanitize_noninteractive_flag() { case "${JB_NONINTERACTIVE:-false}" in true|false) return 0 ;; *) log_warn "JB_NONINTERACTIVE 值非法: ${JB_NONINTERACTIVE}，已回退为 false"; JB_NONINTERACTIVE="false"; return 0 ;; esac; }

read_confirm() { local prompt="$1"; local reply=""; if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then log_warn "非交互模式：默认否"; return 1; fi; read -r -p "${prompt}" reply < /dev/tty; [[ "${reply,,}" == "y" ]]; }

# ... [全局变量与常量保持不变] ...
readonly BASE_DIR="/opt/vps_install_modules"; readonly LOG_FILE="${BASE_DIR}/tcp_optimizer.log"; readonly BACKUP_DIR="${BASE_DIR}/backups"; readonly MAX_BACKUPS=5; readonly SYSCTL_d_DIR="/etc/sysctl.d"; readonly SYSCTL_CONF="${SYSCTL_d_DIR}/99-z-tcp-optimizer.conf"; readonly MODULES_LOAD_DIR="/etc/modules-load.d"; readonly MODULES_CONF="${MODULES_LOAD_DIR}/tcp_optimizer.conf"; readonly MODPROBE_BBR_CONF="/etc/modprobe.d/tcp_optimizer_bbr.conf"; readonly MODPROBE_CONN_CONF="/etc/modprobe.d/tcp_optimizer_conntrack.conf"; readonly LIMITS_CONF="/etc/security/limits.d/99-z-tcp-optimizer.conf"; readonly SYSTEMD_SYS_CONF="/etc/systemd/system.conf.d/99-z-tcp-optimizer.conf"; readonly SYSTEMD_USR_CONF="/etc/systemd/user.conf.d/99-z-tcp-optimizer.conf"; readonly NIC_OPT_SERVICE="/etc/systemd/system/nic-optimize.service"; readonly GAI_CONF="/etc/gai.conf"; readonly TIMESTAMP=$(date '+%Y%m%d_%H%M%S'); IS_CONTAINER=0; IS_CHINA_IP=0; IS_SYSTEMD=0; TOTAL_MEM_KB=0; HAS_IPV6_STACK=0; readonly CONFIG_FILES=("${SYSCTL_CONF}" "${NIC_OPT_SERVICE}" "${MODULES_CONF}" "${MODPROBE_BBR_CONF}" "${MODPROBE_CONN_CONF}" "${LIMITS_CONF}" "${SYSTEMD_SYS_CONF}" "${SYSTEMD_USR_CONF}"); readonly COLOR_RESET='\033[0m'; readonly COLOR_GREEN='\033[0;32m'; readonly COLOR_RED='\033[0;31m'; readonly COLOR_YELLOW='\033[1;33m'; readonly COLOR_CYAN='\033[0;36m'; readonly COLOR_BLUE='\033[0;34m';

# ... [日志函数与错误捕获保持不变] ...
mkdir -p "${BASE_DIR}" "${BACKUP_DIR}"; log_msg() { local level="$1" color="$2" msg="$3"; printf "${color}[%s] %s${COLOR_RESET}\n" "${level}" "${msg}" >&2; echo "[$(date '+%F %T')] [${level}] ${msg}" >> "${LOG_FILE}"; }; log_info()  { log_msg "INFO" "${COLOR_GREEN}" "$*"; }; log_error() { log_msg "ERROR" "${COLOR_RED}" "$*"; }; log_warn()  { log_msg "WARN" "${COLOR_YELLOW}" "$*"; }; log_step()  { log_msg "STEP" "${COLOR_CYAN}" "$*"; }; error_handler() { local exit_code=$?; local line_no=$1; local command="${BASH_COMMAND}"; if [[ $exit_code -ne 0 ]]; then log_error "脚本异常退出! (Line: ${line_no}, Command: '${command}', ExitCode: ${exit_code})"; fi; }; trap 'error_handler ${LINENO}' EXIT;

# ... [check_* functions, version_ge, 等成熟函数保持不变] ...
check_root() { if [[ "$(id -u)" -ne 0 ]]; then log_error "需要 root 权限。"; exit 1; fi }
check_systemd() { if [[ -d /run/systemd/system ]] || grep -q systemd <(head -n 1 /proc/1/comm 2>/dev/null || echo ""); then IS_SYSTEMD=1; else IS_SYSTEMD=0; fi; }
check_network_region() { if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then IS_CHINA_IP=0; return; fi; log_step "检测网络连通性..."; if curl -s --connect-timeout 2 -I https://www.google.com >/dev/null 2>&1; then IS_CHINA_IP=0; else IS_CHINA_IP=1; fi; }
install_dependencies() { local install_list=("$@"); export DEBIAN_FRONTEND=noninteractive; local DPKG_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"; if command -v apt-get &>/dev/null; then apt-get update -yq || true; apt-get install -yq ${DPKG_OPTS} "${install_list[@]}"; elif command -v yum &>/dev/null; then yum install -y "${install_list[@]}"; else log_error "无法识别包管理器"; exit 1; fi; }
check_dependencies() { local deps=(sysctl uname sed modprobe grep awk ip ping timeout ethtool bc curl wget gpg ss rngd tar); local missing=(); local install_list=(); for cmd in "${deps[@]}"; do if ! command -v "${cmd}" &>/dev/null; then missing+=("${cmd}"); if [[ "${cmd}" == "rngd" ]]; then install_list+=("rng-tools"); else install_list+=("${cmd}"); fi; fi; done; if [[ ${#missing[@]} -gt 0 ]]; then echo -e "${COLOR_YELLOW}缺失依赖: ${missing[*]}${COLOR_RESET}"; check_network_region; if read_confirm "自动安装缺失依赖? [y/N]: "; then install_dependencies "${install_list[@]}" || log_warn "部分依赖安装失败..."; else exit 1; fi; fi; }
check_environment() { log_step "全景环境诊断..."; local raw_virt=""; local virt_type="physical"; if command -v systemd-detect-virt &>/dev/null; then raw_virt=$(systemd-detect-virt -c 2>/dev/null || true); fi; raw_virt=$(echo "${raw_virt}" | tr -d '[:space:]'); if [[ -z "${raw_virt}" || "${raw_virt}" == "none" ]]; then if grep -qE 'docker|lxc' /proc/1/cgroup 2>/dev/null; then virt_type="docker/lxc"; elif [[ -f /proc/user_beancounters ]]; then virt_type="openvz"; elif [[ -f /.dockerenv ]]; then virt_type="docker"; else virt_type="physical/kvm"; fi; else virt_type="${raw_virt}"; fi; if [[ "${virt_type}" =~ (lxc|docker|openvz|systemd-nspawn) ]]; then IS_CONTAINER=1; log_warn "检测到纯容器环境: ${virt_type} (将跳过网卡底层调优)"; else IS_CONTAINER=0; log_info "运行环境: ${virt_type} (支持底层性能调优)"; fi; TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo); if [[ -d "/proc/sys/net/ipv6" ]]; then HAS_IPV6_STACK=1; else HAS_IPV6_STACK=0; fi; check_systemd; }
version_ge() { local lower=$(printf '%s\n%s' "$1" "$2" | sort -V | head -n 1); [[ "${lower}" == "$2" ]]; }

apply_system_limits() {
    if [[ ${IS_CONTAINER} -eq 1 ]]; then return 0; fi
    log_step "配置全栈进程级极限句柄 (Drop-in 架构)..."
    ulimit -SHn 1048576 2>/dev/null || true
    mkdir -p "$(dirname "${LIMITS_CONF}")"
    printf "%s\n" "* soft nofile 1048576" "* hard nofile 1048576" "root soft nofile 1048576" "root hard nofile 1048576" > "${LIMITS_CONF}"
    if [[ ${IS_SYSTEMD} -eq 1 ]]; then
        mkdir -p "$(dirname "${SYSTEMD_SYS_CONF}")" "$(dirname "${SYSTEMD_USR_CONF}")"
        printf "%s\n" "[Manager]" "DefaultLimitNOFILE=1048576" > "${SYSTEMD_SYS_CONF}"
        printf "%s\n" "[Manager]" "DefaultLimitNOFILE=1048576" > "${SYSTEMD_USR_CONF}"
        systemctl daemon-reload 2>/dev/null || true
    fi
}
get_default_iface() { ip route show default | awk '/default/ {print $5}' | head -n1 || echo ""; }
optimize_nic_hardware() { if [[ ${IS_CONTAINER} -eq 1 ]]; then return 0; fi; if ! command -v ethtool &>/dev/null; then return 0; fi; local iface=$(get_default_iface); if [[ -z "${iface}" ]]; then return 0; fi; local cmd_all=""; if [[ ! -f "/sys/class/net/${iface}/device/vendor" ]] || [[ "$(cat "/sys/class/net/${iface}/device/vendor")" != "0x1d0f" ]]; then local tso_state=$(ethtool -k "${iface}" 2>/dev/null | awk '/tcp-segmentation-offload:/ {print $2}' || echo "unknown"); if [[ "${tso_state}" == "on" ]]; then cmd_all+="/sbin/ethtool -K ${iface} tso off gso off || true; "; fi; fi; if ethtool -g "${iface}" &>/dev/null; then local rx_max=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '1p' || echo ""); local rx_cur=$(ethtool -g "${iface}" | awk '/RX:/ {print $2}' | sed -n '2p' || echo ""); if [[ -n "${rx_max}" && -n "${rx_cur}" && "${rx_cur}" -lt "${rx_max}" ]]; then cmd_all+="/sbin/ethtool -G ${iface} rx ${rx_max} tx ${rx_max} 2>/dev/null || true; "; fi; fi; local cpu_count=$(nproc || echo 1); if [[ ${cpu_count} -gt 1 ]]; then local math_cpu=$(( cpu_count > 31 ? 31 : cpu_count )); local rps_mask=$(printf "%x" $(( (1 << math_cpu) - 1 ))); cmd_all+="shopt -s nullglob; for q in /sys/class/net/${iface}/queues/rx-*; do echo ${rps_mask} > \$q/rps_cpus 2>/dev/null || true; done; shopt -u nullglob; "; fi; local cur_txq=$(cat /sys/class/net/${iface}/tx_queue_len 2>/dev/null || echo "1000"); if [[ "${cur_txq}" != "10000" && "${cur_txq}" -gt 0 ]]; then cmd_all+="/sbin/ip link set ${iface} txqueuelen 10000 2>/dev/null || true; "; fi; if [[ -n "${cmd_all}" && ${IS_SYSTEMD} -eq 1 ]]; then printf "%s\n" "[Unit]" "Description=NIC Hardware Optimization" "After=network.target network-online.target" "" "[Service]" "Type=oneshot" "ExecStart=/bin/bash -c \"${cmd_all}\"" "RemainAfterExit=yes" "" "[Install]" "WantedBy=multi-user.target" > "${NIC_OPT_SERVICE}"; systemctl daemon-reload && systemctl enable --now nic-optimize.service 2>/dev/null || true; fi; }
inject_kernel_modules() { if [[ ${IS_CONTAINER} -eq 1 ]]; then return 0; fi; local target_cc="$1"; if [[ "${target_cc}" =~ ^bbr ]]; then mkdir -p "$(dirname "${MODPROBE_BBR_CONF}")"; echo "options tcp_${target_cc} min_rtt_win_sec=2" > "${MODPROBE_BBR_CONF}"; fi; mkdir -p "$(dirname "${MODPROBE_CONN_CONF}")"; echo "options nf_conntrack hashsize=500000" > "${MODPROBE_CONN_CONF}"; modprobe nf_conntrack 2>/dev/null || true; if [[ -w "/sys/module/nf_conntrack/parameters/hashsize" ]]; then echo 500000 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true; fi; }
generate_sysctl_content() { local target_qdisc="$1" content=""; local target_cc="$2"; local is_aggressive="$3"; local target_ecn="$4"; local buffer_size="134217728"; local syn_backlog="16384"; local udp_min="16384"; local tw_buckets=$(( TOTAL_MEM_KB / 32 )); local max_orphans=$(( TOTAL_MEM_KB / 64 )); [[ ${tw_buckets} -lt 55000 ]] && tw_buckets=55000; [[ ${max_orphans} -lt 65536 ]] && max_orphans=65536; if [[ "${is_aggressive}" == "1" ]]; then syn_backlog="32768"; udp_min="131072"; fi; 
    content+="# =============================================================\n"
    content+="# TCP Optimizer Configuration (Auto-generated v6.5.1)\n"
    content+="# =============================================================\n\n"
    content+="fs.file-max = 67108864\nfs.nr_open = 10485760\n"
    content+="net.core.somaxconn = 65535\nnet.core.netdev_max_backlog = 16384\n"
    content+="net.ipv4.ip_local_port_range = 10000 65000\nnet.ipv4.tcp_max_syn_backlog = ${syn_backlog}\n"
    content+="net.ipv4.tcp_syncookies = 1\n\n# --- VM/IO 内存子系统调优 ---\n"
    content+="vm.swappiness = 10\nvm.vfs_cache_pressure = 50\n"
    content+="vm.dirty_ratio = 10\nvm.dirty_background_ratio = 5\n\n"
    content+="# --- 单人狂暴缓冲区 (128MB) ---\nnet.core.rmem_max = ${buffer_size}\n"
    content+="net.core.wmem_max = ${buffer_size}\nnet.core.rmem_default = ${buffer_size}\n"
    content+="net.core.wmem_default = ${buffer_size}\nnet.ipv4.tcp_notsent_lowat = 16384\n"
    content+="net.ipv4.tcp_limit_output_bytes = 131072\n\n# --- 现代协议栈加速 ---\n"
    content+="net.ipv4.udp_rmem_min = ${udp_min}\nnet.ipv4.udp_wmem_min = ${udp_min}\n"
    content+="net.core.bpf_jit_enable = 1\nnet.core.optmem_max = 131072\n\n"
    content+="# --- 极速连接复用与动态容量 ---\nnet.netfilter.nf_conntrack_max = 2000000\n"
    content+="net.netfilter.nf_conntrack_tcp_timeout_established = 1200\n"
    content+="net.ipv4.tcp_keepalive_time = 60\nnet.ipv4.tcp_keepalive_probes = 6\n"
    content+="net.ipv4.tcp_keepalive_intvl = 10\nnet.ipv4.tcp_fin_timeout = 15\n"
    content+="net.ipv4.tcp_tw_reuse = 1\nnet.ipv4.tcp_max_tw_buckets = ${tw_buckets}\n"
    content+="net.ipv4.tcp_orphan_retries = 1\nnet.ipv4.tcp_max_orphans = ${max_orphans}\n\n"
    content+="# --- 调度算法 ---\nnet.core.default_qdisc = ${target_qdisc}\n"
    content+="net.ipv4.tcp_congestion_control = ${target_cc}\nnet.ipv4.tcp_ecn = ${target_ecn}\n"
    content+="net.ipv4.tcp_fastopen = 3\nnet.ipv4.tcp_mtu_probing = 1\nnet.ipv4.tcp_frto = 2\n\n"
    content+="# --- 路由安全与 ARP 邻居表扩容 ---\nnet.ipv4.route.gc_timeout = 100\n"
    content+="net.ipv4.neigh.default.gc_stale_time = 60\nnet.ipv4.neigh.default.gc_thresh1 = 1024\n"
    content+="net.ipv4.neigh.default.gc_thresh2 = 4096\nnet.ipv4.neigh.default.gc_thresh3 = 16384\n"
    content+="net.ipv4.conf.all.rp_filter = 1\nnet.ipv4.conf.default.rp_filter = 1\n"
    content+="net.ipv4.conf.all.accept_redirects = 0\nnet.ipv4.icmp_echo_ignore_broadcasts = 1\n"
    if [[ ${HAS_IPV6_STACK} -eq 1 ]]; then
        content+="\nnet.ipv6.neigh.default.gc_stale_time = 60\nnet.ipv6.neigh.default.gc_thresh1 = 1024\n"
        content+="net.ipv6.neigh.default.gc_thresh2 = 4096\nnet.ipv6.neigh.default.gc_thresh3 = 16384\n"
    fi
    if [[ "${is_aggressive}" == "1" ]]; then
        content+="\n# --- 暴力吞吐模式 (Aggressive) ---\n"
        content+="net.ipv4.tcp_slow_start_after_idle = 0\nnet.ipv4.tcp_retries2 = 8\n"
    fi
    printf "%s" "${content}"
}
manage_ipv4_precedence() { if [[ ${IS_CONTAINER} -eq 1 ]]; then return 0; fi; local action="$1"; if [[ ! -f "${GAI_CONF}" ]]; then if [[ -d "/etc" ]]; then touch "${GAI_CONF}"; fi; fi; if [[ "${action}" == "enable" ]]; then if grep -q "precedence ::ffff:0:0/96" "${GAI_CONF}"; then sed -i 's/^#*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"; else echo "precedence ::ffff:0:0/96  100" >> "${GAI_CONF}"; fi; log_info "IPv4 优先已启用。"; else sed -i 's/^precedence ::ffff:0:0\/96.*/#precedence ::ffff:0:0\/96  100/' "${GAI_CONF}"; log_info "已恢复系统选路策略。"; fi; }

# ... [Modules for kernel, audit, backup/restore] ...
remove_old_kernels() { log_step "正在查找可清理的旧内核..."; if ! command -v dpkg &>/dev/null; then log_warn "非 Debian/Ubuntu 系统，暂不支持内核自动清理。"; return; fi; local current_kernel; current_kernel=$(uname -r); local kernels_to_remove=(); kernels_to_remove=($(dpkg --list | grep 'linux-image' | awk '{ print $2 }' | grep -v "${current_kernel}")); if [[ ${#kernels_to_remove[@]} -eq 0 ]]; then log_info "没有发现可清理的旧内核。"; return; fi; echo "以下旧内核将被清理:"; printf " - %s\n" "${kernels_to_remove[@]}"; if ! read_confirm "确认要继续吗? [y/N]: "; then log_warn "操作已取消。"; return; fi; export DEBIAN_FRONTEND=noninteractive; apt-get purge -y "${kernels_to_remove[@]}"; apt-get autoremove -y; update-grub 2>/dev/null || true; log_info "旧内核清理完成。"; }
kernel_manager() { echo "--- 内核维护工具 ---"; echo "1. 安装/更新 XanMod 内核"; echo "2. 清理所有冗余旧内核"; echo "0. 返回主菜单"; read -rp "请选择操作 [0-2]: " choice; case "${choice}" in 1) install_xanmod_kernel ;; 2) remove_old_kernels ;; 0|*) return ;; esac; }
install_xanmod_kernel() { if [[ ${IS_CONTAINER} -eq 1 ]]; then log_warn "容器环境无法更换内核。"; return; fi; echo -e "${COLOR_BLUE}========================================================${COLOR_RESET}"; echo -e "${COLOR_BLUE}   XanMod Kernel 安装向导 (Debian/Ubuntu Only)          ${COLOR_RESET}"; echo -e "${COLOR_BLUE}========================================================${COLOR_RESET}"; if grep -iq "xanmod" /proc/version 2>/dev/null; then log_info "✅ 检测到当前已运行 XanMod 内核。"; read_confirm "按回车继续..." || true; return; fi; if [[ ! -f /etc/debian_version ]]; then log_warn "非 Debian/Ubuntu，暂不支持自动安装 XanMod。"; return; fi; if read_confirm "是否需要先清理旧内核为新内核腾出空间? [y/N]: "; then remove_old_kernels; fi; if ! read_confirm "是否继续安装 XanMod Kernel (推荐 x64v3)? [y/N]: "; then return; fi; export DEBIAN_FRONTEND=noninteractive; local DPKG_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"; log_step "正在导入 XanMod GPG Key..."; wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes; echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list; apt-get update -y; log_step "安装 linux-xanmod-x64v3 (极端静默模式)..."; if apt-get install -yq ${DPKG_OPTS} linux-xanmod-x64v3; then echo -e "${COLOR_GREEN}XanMod 内核安装成功！请在脚本结束后重启服务器以生效。${COLOR_RESET}"; else log_error "安装失败，请检查网络。"; fi; }
manage_backups() { local backups=(); backups=($(ls -t "${BACKUP_DIR}"/config_backup_*.tar.gz 2>/dev/null || true)); if [[ ${#backups[@]} -gt ${MAX_BACKUPS} ]]; then log_info "备份数量超出限制(${MAX_BACKUPS})，正在清理最旧的备份..."; ls -tr "${BACKUP_DIR}"/config_backup_*.tar.gz | head -n $((${#backups[@]} - MAX_BACKUPS)) | xargs -r rm -f; fi; }
backup_configs() { log_step "正在创建当前配置的快照..."; local backup_file="${BACKUP_DIR}/config_backup_${TIMESTAMP}.tar.gz"; local files_to_backup=(); for f in "${CONFIG_FILES[@]}"; do if [[ -f "${f}" ]]; then files_to_backup+=("${f}"); fi; done; if [[ ${#files_to_backup[@]} -gt 0 ]]; then tar -czf "${backup_file}" "${files_to_backup[@]}" 2>/dev/null; log_info "配置已备份至: ${backup_file}"; manage_backups; fi; }
restore_configs() { log_step "正在查找可用备份..."; local backups=(); backups=($(find "${BACKUP_DIR}" -name "*.tar.gz" 2>/dev/null | sort -r)); if [[ ${#backups[@]} -eq 0 ]]; then log_warn "未找到任何备份文件。"; return 1; fi; echo "请选择要恢复的配置备份:"; select backup_choice in "${backups[@]}"; do if [[ -z "${backup_choice}" ]]; then log_warn "无效选择。"; return 1; fi; local temp_dir; temp_dir=$(mktemp -d); if [[ -z "${temp_dir}" || ! -d "${temp_dir}" ]]; then log_error "无法创建临时目录"; return 1; fi; trap 'rm -rf "${temp_dir}"' RETURN; log_step "正在验证并解压备份至临时目录..."; if tar -xzf "${backup_choice}" -C "${temp_dir}"; then log_info "备份文件验证通过。正在应用..."; rm -f "${CONFIG_FILES[@]}"; cp -r "${temp_dir}"/* /; if [[ ${IS_SYSTEMD} -eq 1 ]]; then systemctl daemon-reload; systemctl restart systemd-sysctl; systemctl enable --now nic-optimize.service 2>/dev/null || true; fi; log_info "配置恢复并已应用。"; return 0; else log_error "备份文件已损坏或解压失败！当前配置未受影响。"; return 1; fi; done; }
audit_configs() { log_step "正在审计当前生效的内核参数..."; if [[ ! -f "${SYSCTL_CONF}" ]]; then log_warn "未找到优化配置文件，系统可能处于默认状态。"; return; fi; local mismatches=0; while IFS= read -r line; do [[ "$line" =~ ^\s*# || -z "$line" ]] && continue; local key val; key=$(echo "$line" | cut -d'=' -f1 | tr -d '[:space:]'); val=$(echo "$line" | cut -d'=' -f2- | tr -d '[:space:]'); local current_val; current_val=$(sysctl -n "${key}" 2>/dev/null || echo "N/A"); current_val=$(echo "$current_val" | tr -d '[:space:]' | tr '\t' ' '); if [[ "${current_val}" == "${val}" ]]; then printf "${COLOR_GREEN}[MATCH]${COLOR_RESET} %-45s = %s\n" "${key}" "${val}"; else printf "${COLOR_YELLOW}[MISMATCH]${COLOR_RESET} %-45s | Expected: %s | Current: %s\n" "${key}" "${val}" "${current_val}"; mismatches=$((mismatches + 1)); fi; done < "${SYSCTL_CONF}"; if [[ ${mismatches} -eq 0 ]]; then log_info "所有参数均已正确应用。"; else log_warn "${mismatches} 个参数与配置文件不匹配，可能已被其他进程覆盖。"; fi; }
apply_profile() { local profile_type="$1"; local target_qdisc=""; local target_cc="bbr"; local is_aggressive=0; local target_ecn=1; local kver; kver=$(uname -r | cut -d- -f1); backup_configs; if [[ ${IS_CONTAINER} -eq 0 ]]; then modprobe tcp_bbr3 2>/dev/null || true; fi; local avail_cc; avail_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo ""); case "${profile_type}" in "latency") log_step "加载画像: [极速网游 / Gaming]"; if version_ge "${kver}" "${MIN_KERNEL_CAKE}"; then target_qdisc="cake"; elif version_ge "${kver}" "${MIN_KERNEL_FQ_PIE}"; then target_qdisc="fq_pie"; else target_qdisc="fq_codel"; fi; if echo "${avail_cc}" | grep -q "bbr3"; then target_cc="bbr3"; else target_cc="bbr"; fi; is_aggressive=0; target_ecn=1 ;; "throughput") log_step "加载画像: [流媒体 / Streaming]"; target_qdisc="fq"; target_cc="bbr"; is_aggressive=1; target_ecn=1 ;; "balanced") log_step "加载画像: [平衡模式 / Balanced]"; if version_ge "${kver}" "${MIN_KERNEL_FQ_PIE}"; then target_qdisc="fq_pie"; else target_qdisc="fq"; fi; if echo "${avail_cc}" | grep -q "bbr3"; then target_cc="bbr3"; else target_cc="bbr"; fi; is_aggressive=0; target_ecn=2 ;; esac; if [[ ${IS_CONTAINER} -eq 0 ]]; then if [[ "${target_qdisc}" == "cake" ]]; then modprobe sch_cake 2>/dev/null || true; fi; if [[ "${target_qdisc}" == "fq_pie" ]]; then modprobe sch_fq_pie 2>/dev/null || true; fi; if [[ "${target_qdisc}" == "fq" ]]; then modprobe sch_fq 2>/dev/null || true; fi; modprobe "tcp_${target_cc}" 2>/dev/null || true; fi; apply_system_limits; optimize_nic_hardware; inject_kernel_modules "${target_cc}"; mkdir -p "${SYSCTL_d_DIR}"; generate_sysctl_content "${target_qdisc}" "${target_cc}" "${is_aggressive}" "${target_ecn}" > "${SYSCTL_CONF}"; sysctl -e -p "${SYSCTL_CONF}" 2>/dev/null || sysctl --system >/dev/null 2>&1 || true; local final_cc; final_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown"); if [[ "${final_cc}" == "${target_cc}" ]]; then log_info "✅ 拥塞控制算法已成功加载至内核。"; else log_warn "拥塞控制算法未能加载！当前: ${final_cc}, 期望: ${target_cc}。"; fi;}

# -------------------------------------------------------------
# 交互菜单
# -------------------------------------------------------------

show_menu() {
    clear
    local mem_mb=$((TOTAL_MEM_KB / 1024)); local cur_kver; cur_kver=$(uname -r); local cur_cc; cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知"); local cur_qdisc; cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知"); local active_conn; active_conn=$(ss -tn state established 2>/dev/null | wc -l || echo "1"); active_conn=$((active_conn - 1)); [[ ${active_conn} -lt 0 ]] && active_conn=0
    echo "========================================================"
    echo -e " 🚀 终极画像调优引擎 ${COLOR_YELLOW}(v6.5.1 Audit Edition)${COLOR_RESET}"
    echo "========================================================"
    echo -e " 物理内存: ${COLOR_CYAN}${mem_mb} MB${COLOR_RESET}    并发承载: ${COLOR_GREEN}${active_conn} 活跃连接${COLOR_RESET}"
    echo -e " 内核版本: ${COLOR_CYAN}${cur_kver}${COLOR_RESET}    拥塞算法: ${COLOR_CYAN}${cur_cc} + ${cur_qdisc}${COLOR_RESET}"
    if [[ ${mem_mb} -lt 1500 ]]; then echo -e " ${COLOR_RED}[警告] 物理内存 < 1.5GB。极客模式已强开 128MB 核心缓冲！${COLOR_RESET}"; fi
    echo "--------------------------------------------------------"
    echo " 1. 极速网游[Ganing](BBRV3 + CAKE/FQ_PIE+低抖动）"
    echo " 2. 流媒体[Streaning]BBRV1 +FQ+激进128MB)"
    echo " 3. 平衡模式[Balanced](BBRV3 + FQ PIE)"
    echo "--------------------------------------------------------"
    echo " 4. 开启 IPv4 强制优先"
    echo " 5. 恢复 IPv6 默认优先级"
    echo -e " 6. ${COLOR_BLUE}内核维护工具 (安装/清理)${COLOR_RESET}"
    echo -e " 7. ${COLOR_YELLOW}从备份恢复配置 (时光机)${COLOR_RESET}"
    echo -e " 8. ${COLOR_CYAN}审计当前系统配置${COLOR_RESET}"
    echo -e " 9. ${COLOR_RED}彻底卸载/恢复系统默认${COLOR_RESET}"
    echo "--------------------------------------------------------"
    echo " 0. 退出"
    echo "========================================================"
}

main() {
    trap 'error_handler ${LINENO}' EXIT
    sanitize_noninteractive_flag
    check_root; check_dependencies; check_environment
    
    while true; do
        show_menu
        if [ "${JB_NONINTERACTIVE:-false}" = "true" ]; then
            log_warn "非交互模式：已退出"
            exit 0
        fi
        read -r -p "请下发执行指令 [0-9]: " c < /dev/tty
        case "$c" in
            1) apply_profile "latency"; read -r -p "按回车继续..." < /dev/tty;;
            2) apply_profile "throughput"; read -r -p "按回车继续..." < /dev/tty;;
            3) apply_profile "balanced"; read -r -p "按回车继续..." < /dev/tty;;
            4) manage_ipv4_precedence "enable"; read -r -p "按回车继续..." < /dev/tty;;
            5) manage_ipv4_precedence "disable"; read -r -p "按回车继续..." < /dev/tty;;
            6) kernel_manager; read -r -p "按回车返回主菜单..." < /dev/tty;;
            7) restore_configs; read -r -p "按回车继续..." < /dev/tty;;
            8) audit_configs; read -r -p "按回车继续..." < /dev/tty;;
            9) 
                echo -e "${COLOR_RED}警告: 此操作将删除所有优化配置和备份，且不可逆！${COLOR_RESET}"
                if read_confirm "确认要彻底卸载吗? [y/N]: "; then
                    log_warn "正在彻底清理配置、驻留服务与所有备份..."
                    ensure_safe_path "${BACKUP_DIR}"
                    rm -f "${CONFIG_FILES[@]}"
                    rm -rf "${BACKUP_DIR}"
                    if [[ ${IS_SYSTEMD} -eq 1 ]]; then 
                        systemctl disable --now nic-optimize.service 2>/dev/null || true
                        mkdir -p "$(dirname "${SYSTEMD_SYS_CONF}")"; echo "[Manager]" > "${SYSTEMD_SYS_CONF}"
                        systemctl daemon-reload || true
                    fi
                    sysctl -w net.ipv4.tcp_congestion_control=cubic 2>/dev/null || true
                    sysctl -w net.core.default_qdisc=fq_codel 2>/dev/null || true
                    sysctl --system >/dev/null 2>&1 || true
                    log_info "已彻底卸载 Drop-in 配置与优化防线，并回退至默认状态。"
                else
                    log_warn "卸载操作已取消。"
                fi
                read -r -p "按回车继续..." < /dev/tty
                ;;
            0) exit 0 ;;
            *) sleep 0.5 ;;
        esac
    done
}

main "${@}"
trap - EXIT
