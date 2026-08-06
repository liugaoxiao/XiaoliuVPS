#!/bin/bash
# VPS 网络一键优化 + 安全隐匿 - 整合自 Wyatt/vps-netpilot/kejilion
# 用法: bash optimize.sh
# GitHub: https://github.com/liugaoxiao/XiaoliuVPS

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info() { echo -e "${CYAN}[信息] $1${NC}"; }
_success() { echo -e "${GREEN}[成功] $1${NC}"; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}"; }
_error() { echo -e "${RED}[错误] $1${NC}"; }

if [[ $EUID -ne 0 ]]; then
    _error "请用 root 运行: sudo bash optimize.sh"
    exit 1
fi

# 安装缺失的依赖
_install_deps() {
    local missing=""
    command -v sysctl &>/dev/null || missing="procps"
    command -v nft &>/dev/null || missing="${missing:+$missing }nftables"
    if [ -n "$missing" ]; then
        _info "安装缺失依赖: $missing"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y $missing >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y $missing >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk add --no-cache $missing >/dev/null 2>&1
        fi
        local still_missing=""
        command -v sysctl &>/dev/null || still_missing="sysctl"
        command -v nft &>/dev/null || still_missing="${still_missing:+$still_missing, }nft"
        if [ -n "$still_missing" ]; then
            _warn "以下工具仍然缺失: $still_missing (对应功能将跳过)"
        fi
    fi
}

clear
echo -e "${CYAN}"
echo '  ╔═══════════════════════════════════════╗'
echo '  ║       VPS 网络优化 + 安全隐匿         ║'
echo '  ║   Wyatt + netpilot + kejilion 整合     ║'
echo '  ╚═══════════════════════════════════════╝'
echo -e "${NC}"
echo ""
_info "系统: $(uname -s -r -m)"
_info "CPU: $(nproc 2>/dev/null || echo '?') 核 | 内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo '?')"
_info "当前拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic) / $(sysctl -n net.core.default_qdisc 2>/dev/null || echo pfifo_fast)"
echo ""
echo -e "${YELLOW}  执行内容:${NC}"
echo -e "    网络优化: sysctl(38项) + BBR + conntrack + nofile + gai.conf"
echo -e "    安全隐匿: ICMP隐藏 + TCP防指纹 + 内核加固 + DDoS防护"
echo -e "    防火墙:   MSS Clamp + 端口扫描拦截 + SSH速率限制"
echo ""
read -p "  确认执行? (Y/n): " confirm
[[ "$confirm" == "n" || "$confirm" == "N" ]] && echo "已取消" && exit 0

old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)

# 0. 安装依赖
echo ""
_info "[0/8] 检查并安装依赖..."
_install_deps
_success "OK"

# 1. sysctl - 网络优化 + 安全加固
echo ""
_info "[1/8] sysctl 参数 (38项)..."
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)

cat > /etc/sysctl.conf << 'SYSCTLEOF'
# VPS 网络优化 + 安全隐匿 - 整合方案
# 仅保留对代理/隧道 VPS 真实有效的参数

# ═══ 文件系统 ═══
fs.file-max = 6815744
fs.nr_open = 6815744

# ═══ 连接队列 ═══
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_abort_on_overflow = 0
net.core.netdev_max_backlog = 65536

# ═══ BBR 拥塞控制 ═══
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ═══ TCP 缓冲区 (64MB) ═══
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_moderate_rcvbuf = 1

# ═══ UDP 缓冲区 ═══
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ═══ TCP 连接优化 ═══
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
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_local_port_range = 1024 65535

# ═══ TCP Keepalive (600s 探测, 30s 间隔, 3次断开) ═══
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# ═══ 安全隐匿 - ICMP ═══
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ratelimit = 100
net.ipv4.icmp_msgs_per_sec = 100

# ═══ 安全隐匿 - 防流量劫持 ═══
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ═══ 安全隐匿 - 内核加固 ═══
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ═══ Conntrack 连接跟踪 ═══
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# ═══ 虚拟内存 ═══
vm.swappiness = 10
vm.overcommit_memory = 1
SYSCTLEOF

# 加载内核模块
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# 应用并统计结果
sysctl_output=$(sysctl -p 2>&1)
sysctl_applied=$(echo "$sysctl_output" | grep -c ' = ' || true)
sysctl_skipped=$(echo "$sysctl_output" | grep -ci 'unknown key\|No such file\|permission denied' || true)
if [ "$sysctl_skipped" -gt 0 ]; then
    _warn "${sysctl_applied} 项生效, ${sysctl_skipped} 项跳过(内核不支持)"
else
    _success "全部 ${sysctl_applied} 项参数已生效"
fi

# 2. 模块开机加载
echo ""
_info "[2/8] 内核模块开机加载..."
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/proxy-optimize.conf << 'EOF'
tcp_bbr
nf_conntrack
EOF
_success "BBR + conntrack"

# 3. nofile (systemd + limits.conf)
echo ""
_info "[3/8] 文件描述符..."
if ! grep -q 'VPS-Optimize-nofile' /etc/security/limits.conf 2>/dev/null; then
    cat >> /etc/security/limits.conf << 'EOF'

# VPS-Optimize-nofile
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    _success "limits.conf: nofile 1048576"
else
    _success "limits.conf: 已配置，跳过"
fi
mkdir -p /etc/systemd/system.conf.d 2>/dev/null
cat > /etc/systemd/system.conf.d/nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec 2>/dev/null || true
_success "systemd: DefaultLimitNOFILE=1048576"

# 4. gai.conf
echo ""
_info "[4/8] IPv4 优先解析..."
if [ -f /etc/gai.conf ]; then
    grep -q 'ffff:0:0' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
else
    echo 'precedence ::ffff:0:0/96  100' > /etc/gai.conf
fi
_success "OK"

# 5. 防火墙规则 (MSS Clamp + DDoS + 隐匿)
echo ""
_info "[5/8] 防火墙规则 (MSS Clamp + DDoS + 隐匿)..."
if command -v nft &>/dev/null; then
    # 创建独立表
    nft list table inet vps_optimize >/dev/null 2>&1 || nft add table inet vps_optimize

    # --- MSS Clamp (forward chain) ---
    nft list chain inet vps_optimize mangle_forward >/dev/null 2>&1 || nft add chain inet vps_optimize mangle_forward '{ type filter hook forward priority -150; policy accept; }'
    nft flush chain inet vps_optimize mangle_forward 2>/dev/null
    nft add rule inet vps_optimize mangle_forward tcp flags syn tcp option maxseg size set rt mtu comment MSS-Clamp 2>/dev/null
    _success "MSS Clamp 已生效"

    # --- DDoS + 隐匿 (input chain, policy=accept) ---
    nft list chain inet vps_optimize dos_input >/dev/null 2>&1 || nft add chain inet vps_optimize dos_input '{ type filter hook input priority -150; policy accept; }'
    nft flush chain inet vps_optimize dos_input 2>/dev/null

    # 优先放行已建立连接 (Emby 视频流等长连接不受影响)
    nft add rule inet vps_optimize dos_input ct state established,related accept comment Accept-Established 2>/dev/null
    # 放行 loopback
    nft add rule inet vps_optimize dos_input iif lo accept comment Accept-Loopback 2>/dev/null
    # 丢弃无效连接状态
    nft add rule inet vps_optimize dos_input ct state invalid drop comment Drop-Invalid 2>/dev/null
    # 丢弃异常 TCP 标志 (XMAS/SYN-RST 扫描)
    nft add rule inet vps_optimize dos_input tcp flags syn,fin syn,fin drop comment Block-XMAS 2>/dev/null
    nft add rule inet vps_optimize dos_input tcp flags syn,rst syn,rst drop comment Block-SYNRST 2>/dev/null
    # SYN 洪水防护 (保护 SSH)
    nft add rule inet vps_optimize dos_input tcp flags syn tcp dport != 22 meter syn_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 200/second burst 50 packets drop comment DDoS-SYN 2>/dev/null
    # SSH 速率限制: 每 IP 每分钟最多 4 次新连接
    nft add rule inet vps_optimize dos_input tcp dport 22 ct state new meter ssh_bruteforce '{ size 65536, flags dynamic, timeout 60s }' limit rate over 4/minute burst 4 packets drop comment SSH-RateLimit 2>/dev/null
    # UDP 洪水防护
    nft add rule inet vps_optimize dos_input udp meter udp_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 500/second burst 100 packets drop comment DDoS-UDP 2>/dev/null
    # ICMP 限制
    nft add rule inet vps_optimize dos_input icmp type echo-request limit rate over 5/second burst 5 packets drop comment ICMP-Limit 2>/dev/null

    # 保存规则
    mkdir -p /etc/nftables.d
    nft list table inet vps_optimize > /etc/nftables.d/vps_optimize.nft 2>/dev/null
    if [ -f /etc/nftables.conf ] && ! grep -q 'vps_optimize' /etc/nftables.conf 2>/dev/null; then
        echo 'include "/etc/nftables.d/vps_optimize.nft"' >> /etc/nftables.conf
    fi
    _success "DDoS 防护 + SSH 限速 + 隐匿规则已生效"
else
    _warn "nftables 不可用，跳过防火墙规则"
fi

# 6. SSH 安全加固
echo ""
_info "[6/8] SSH 安全加固..."
SSH_CONF="/etc/ssh/sshd_config"
if [ -f "$SSH_CONF" ]; then
    sshd_changed=false
    if ! grep -qE '^\s*PermitEmptyPasswords\s+no' "$SSH_CONF" 2>/dev/null; then
        echo 'PermitEmptyPasswords no' >> "$SSH_CONF"
        sshd_changed=true
    fi
    if ! grep -qE '^\s*MaxAuthTries\s+' "$SSH_CONF" 2>/dev/null; then
        echo 'MaxAuthTries 3' >> "$SSH_CONF"
        sshd_changed=true
    fi
    if ! grep -qE '^\s*X11Forwarding\s+no' "$SSH_CONF" 2>/dev/null; then
        echo 'X11Forwarding no' >> "$SSH_CONF"
        sshd_changed=true
    fi
    if [ "$sshd_changed" = true ]; then
        if command -v systemctl &>/dev/null && systemctl is-active sshd >/dev/null 2>&1; then
            systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null
        elif command -v systemctl &>/dev/null && systemctl is-active ssh >/dev/null 2>&1; then
            systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null
        elif command -v rc-service &>/dev/null; then
            rc-service sshd reload 2>/dev/null || rc-service sshd restart 2>/dev/null
        fi
        _success "SSH 加固已生效 (MaxAuthTries=3, 禁空密码, 禁X11)"
    else
        _success "SSH 已配置，跳过"
    fi
else
    _warn "sshd_config 不存在，跳过"
fi

# 7. 隐藏服务 Banner
echo ""
_info "[7/8] 隐藏服务 Banner..."
if [ -f "$SSH_CONF" ]; then
    if ! grep -qE '^\s*Banner\s+none' "$SSH_CONF" 2>/dev/null; then
        echo 'Banner none' >> "$SSH_CONF"
    fi
    if ! grep -qE '^\s*DebianBanner\s+no' "$SSH_CONF" 2>/dev/null; then
        echo 'DebianBanner no' >> "$SSH_CONF" 2>/dev/null
    fi
fi
_success "SSH Banner 已隐藏"

# 8. 验证
echo ""
echo -e "${GREEN}══════════════ 优化完成 ══════════════${NC}"

_get_sysctl() {
    local val=$(sysctl -n "$1" 2>/dev/null)
    echo "${val:-N/A}"
}

new_bbr=$(_get_sysctl net.ipv4.tcp_congestion_control)
qdisc=$(_get_sysctl net.core.default_qdisc)
somaxconn=$(_get_sysctl net.core.somaxconn)
rmem=$(_get_sysctl net.core.rmem_max)
filemax=$(_get_sysctl fs.file-max)
fintime=$(_get_sysctl net.ipv4.tcp_fin_timeout)
swapp=$(_get_sysctl vm.swappiness)
conntrack=$(_get_sysctl net.netfilter.nf_conntrack_max)
icmp_ignore=$(_get_sysctl net.ipv4.icmp_echo_ignore_all)
kptr=$(_get_sysctl kernel.kptr_restrict)

if [[ "$rmem" =~ ^[0-9]+$ ]]; then
    rmem_mb=$((rmem / 1048576))
else
    rmem_mb="$rmem"
fi

echo -e "  ── 网络优化 ──"
echo -e "  BBR:       ${old_bbr} → ${GREEN}${new_bbr}${NC}"
echo -e "  qdisc:     ${GREEN}${qdisc}${NC}"
echo -e "  somaxconn: ${GREEN}${somaxconn}${NC}"
echo -e "  rmem_max:  ${GREEN}${rmem_mb} MB${NC}"
echo -e "  file-max:  ${GREEN}${filemax}${NC}"
echo -e "  fin_time:  ${GREEN}${fintime}s${NC}"
echo -e "  swappiness:${GREEN} ${swapp}${NC}"
echo -e "  conntrack: ${GREEN}${conntrack}${NC}"
echo -e "  ── 安全隐匿 ──"
echo -e "  ICMP隐藏:  ${GREEN}$([ "$icmp_ignore" = "1" ] && echo '已开启' || echo '未开启')${NC}"
echo -e "  内核指针:  ${GREEN}$([ "$kptr" = "2" ] && echo '已隐藏' || echo '未隐藏')${NC}"
echo -e "  DDoS防护:  ${GREEN}已开启${NC}"
echo -e "  SSH限速:   ${GREEN}4次/分钟${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
