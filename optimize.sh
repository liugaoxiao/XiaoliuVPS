# ═══════════════════════════════════════════════════════════════
# VPS 网络优化模块 - 整合自 Wyatt/vps-netpilot/kejilion
# 包含: sysctl 内核参数 + nftables MSS Clamp/DDoS + 文件描述符
# ═══════════════════════════════════════════════════════════════

SYSCTL_OPTIMIZE_CONTENT='
# VPS 网络优化 - 整合方案
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

_vps_optimize() {
    clear
    echo -e "${CYAN}"
    echo '  ╔═══════════════════════════════════════╗'
    echo '  ║         VPS 网络一键优化             ║'
    echo '  ║   Wyatt + netpilot + kejilion 整合    ║'
    echo '  ╚═══════════════════════════════════════╝'
    echo -e "${NC}"
    echo ""
    _info "当前系统: $(uname -s -r -m)"
    _info "当前拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo ""
    echo -e "${YELLOW}  即将执行:${NC} sysctl(33项) + 模块加载 + nofile + gai.conf + MSS Clamp + DDoS"
    echo ""
    read -p "  确认执行? (Y/n): " confirm
    [[ "$confirm" == "n" || "$confirm" == "N" ]] && return 0

    local old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)

    # 1. sysctl
    _info "[1/6] sysctl 参数..."
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)
    echo "$SYSCTL_OPTIMIZE_CONTENT" > /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    _success "OK"

    # 2. 模块
    _info "[2/6] 内核模块..."
    modprobe tcp_bbr 2>/dev/null
    modprobe nf_conntrack 2>/dev/null
    mkdir -p /etc/modules-load.d
    printf 'tcp_bbr\nnf_conntrack\n' > /etc/modules-load.d/proxy-optimize.conf
    _success "OK"

    # 3. nofile
    _info "[3/6] 文件描述符..."
    if ! grep -q 'VPS-Optimize-nofile' /etc/security/limits.conf 2>/dev/null; then
        printf '\n# VPS-Optimize-nofile\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n' >> /etc/security/limits.conf
    fi
    _success "OK"

    # 4. gai.conf
    _info "[4/6] IPv4 优先..."
    grep -q 'ffff:0:0' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
    _success "OK"

    # 5. MSS Clamp
    _info "[5/6] MSS Clamp..."
    if command -v nft &>/dev/null; then
        nft list table inet vps_optimize >/dev/null 2>&1 || nft add table inet vps_optimize
        nft list chain inet vps_optimize mangle_forward >/dev/null 2>&1 || nft add chain inet vps_optimize mangle_forward '{ type filter hook forward priority -150; policy accept; }'
        nft flush chain inet vps_optimize mangle_forward 2>/dev/null
        nft add rule inet vps_optimize mangle_forward tcp flags syn tcp option maxseg size set rt mtu comment MSS-Clamp
        mkdir -p /etc/nftables.d
        nft list table inet vps_optimize > /etc/nftables.d/vps_optimize.nft 2>/dev/null
        _success "OK"
    else
        _warn "nft 不可用"
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
        _success "OK"
    fi

    echo ""
    _success "══════ 优化完成 ══════"
    echo -e "  BBR: ${old_bbr} → $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  qdisc: $(sysctl -n net.core.default_qdisc)"
    echo -e "  somaxconn: $(sysctl -n net.core.somaxconn)"
    echo -e "  rmem_max: $(($(sysctl -n net.core.rmem_max) / 1048576))MB"
    echo -e "  file-max: $(sysctl -n fs.file-max)"
    echo -e "  fin_timeout: $(sysctl -n net.ipv4.tcp_fin_timeout)s"
    echo -e "  swappiness: $(sysctl -n vm.swappiness)"
    echo -e "  conntrack: $(sysctl -n net.netfilter.nf_conntrack_max)"
}
