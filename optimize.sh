#!/bin/bash
# VPS 网络一键优化 - 整合自 Wyatt/vps-netpilot/kejilion
# 用法: bash optimize.sh
# GitHub: https://github.com/liugaoxiao/XiaoliuVPS

set -euo pipefail

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info() { echo -e "${CYAN}[信息] $1${NC}"; }
_success() { echo -e "${GREEN}[成功] $1${NC}"; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}"; }
_error() { echo -e "${RED}[错误] $1${NC}"; }

# 检查 root
if [[ $EUID -ne 0 ]]; then
    _error "请用 root 运行: sudo bash optimize.sh"
    exit 1
fi

SYSCTL_CONTENT='
fs.file-max = 6815744
fs.nr_open = 6815744
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_abort_on_overflow = 1
net.core.netdev_max_backlog = 65536
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_retries2 = 12
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.route.max_size = 1048576
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.core.rps_sock_flow_entries = 32768
vm.swappiness = 10
vm.overcommit_memory = 1
'

clear
echo -e "${CYAN}"
echo '  ╔═══════════════════════════════════════╗'
echo '  ║         VPS 网络一键优化             ║'
echo '  ║   Wyatt + netpilot + kejilion 整合    ║'
echo '  ╚═══════════════════════════════════════╝'
echo -e "${NC}"
echo ""
_info "系统: $(uname -s -r -m)"
_info "CPU: $(nproc 2>/dev/null || echo '?') 核 | 内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo '?')"
_info "当前拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
echo ""
echo -e "${YELLOW}  执行内容:${NC} sysctl(33项) + 模块加载 + nofile + gai.conf + MSS Clamp + DDoS"
echo ""
read -p "  确认执行? (Y/n): " confirm
[[ "$confirm" == "n" || "$confirm" == "N" ]] && echo "已取消" && exit 0

old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)

# 1. sysctl
echo ""
_info "[1/6] sysctl 参数..."
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)
echo "$SYSCTL_CONTENT" > /etc/sysctl.conf
sysctl -p >/dev/null 2>&1
_success "33项参数已生效"

# 2. 模块
_info "[2/6] 内核模块..."
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
mkdir -p /etc/modules-load.d
printf 'tcp_bbr\nnf_conntrack\n' > /etc/modules-load.d/proxy-optimize.conf
_success "BBR + conntrack 已加载"

# 3. nofile
_info "[3/6] 文件描述符..."
if ! grep -q 'VPS-Optimize-nofile' /etc/security/limits.conf 2>/dev/null; then
    printf '\n# VPS-Optimize-nofile\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' >> /etc/security/limits.conf
    _success "nofile 1048576"
else
    _success "已配置，跳过"
fi

# 4. gai.conf
_info "[4/6] IPv4 优先解析..."
if [ -f /etc/gai.conf ]; then
    grep -q 'ffff:0:0' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
else
    echo 'precedence ::ffff:0:0/96  100' > /etc/gai.conf
fi
_success "OK"

# 5. MSS Clamp
_info "[5/6] MSS Clamp (nftables)..."
if command -v nft &>/dev/null; then
    nft list table inet vps_optimize >/dev/null 2>&1 || nft add table inet vps_optimize
    nft list chain inet vps_optimize mangle_forward >/dev/null 2>&1 || nft add chain inet vps_optimize mangle_forward '{ type filter hook forward priority -150; policy accept; }'
    nft flush chain inet vps_optimize mangle_forward 2>/dev/null
    nft add rule inet vps_optimize mangle_forward tcp flags syn tcp option maxseg size set rt mtu comment MSS-Clamp
    mkdir -p /etc/nftables.d
    nft list table inet vps_optimize > /etc/nftables.d/vps_optimize.nft 2>/dev/null
    if [ -f /etc/nftables.conf ] && ! grep -q 'vps_optimize' /etc/nftables.conf 2>/dev/null; then
        echo 'include "/etc/nftables.d/vps_optimize.nft"' >> /etc/nftables.conf
    fi
    _success "MSS Clamp 已生效"
else
    _warn "nft 不可用，跳过"
fi

# 6. DDoS
_info "[6/6] DDoS 防护..."
if command -v nft &>/dev/null; then
    nft list chain inet vps_optimize dos_input >/dev/null 2>&1 || nft add chain inet vps_optimize dos_input '{ type filter hook input priority -150; policy accept; }'
    nft flush chain inet vps_optimize dos_input 2>/dev/null
    nft add rule inet vps_optimize dos_input tcp flags syn tcp dport != 22 meter syn_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 200/second burst 50 packets drop comment DDoS-SYN
    nft add rule inet vps_optimize dos_input udp meter udp_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 500/second burst 100 packets drop comment DDoS-UDP
    nft add rule inet vps_optimize dos_input icmp type echo-request limit rate over 50/second burst 20 packets drop comment DDoS-ICMP
    nft add rule inet vps_optimize dos_input tcp flags & fin == 0 tcp flags & syn == 0 tcp flags & rst == 0 drop comment DDoS-Invalid
    nft list table inet vps_optimize > /etc/nftables.d/vps_optimize.nft 2>/dev/null
    _success "DDoS 防护已生效"
else
    _warn "nft 不可用，跳过"
fi

# 验证
echo ""
echo -e "${GREEN}══════════════ 优化完成 ══════════════${NC}"
echo -e "  BBR:       ${old_bbr} → ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
echo -e "  qdisc:     ${GREEN}$(sysctl -n net.core.default_qdisc)${NC}"
echo -e "  somaxconn: ${GREEN}$(sysctl -n net.core.somaxconn)${NC}"
echo -e "  rmem_max:  ${GREEN}$(($(sysctl -n net.core.rmem_max) / 1048576)) MB${NC}"
echo -e "  file-max:  ${GREEN}$(sysctl -n fs.file-max)${NC}"
echo -e "  fin_time:  ${GREEN}$(sysctl -n net.ipv4.tcp_fin_timeout)s${NC}"
echo -e "  swappiness:${GREEN} $(sysctl -n vm.swappiness)${NC}"
echo -e "  conntrack: ${GREEN}$(sysctl -n net.netfilter.nf_conntrack_max)${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
rm -f /tmp/vps_opt.sh 2>/dev/null
