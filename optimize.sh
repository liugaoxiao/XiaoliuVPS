#!/bin/bash
# VPS 网络一键优化 - 整合自 Wyatt/vps-netpilot/kejilion
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
        # 验证安装结果
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
echo '  ║         VPS 网络一键优化             ║'
echo '  ║   Wyatt + netpilot + kejilion 整合    ║'
echo '  ╚═══════════════════════════════════════╝'
echo -e "${NC}"
echo ""
_info "系统: $(uname -s -r -m)"
_info "CPU: $(nproc 2>/dev/null || echo '?') 核 | 内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo '?')"
_info "当前拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic) / $(sysctl -n net.core.default_qdisc 2>/dev/null || echo pfifo_fast)"
echo ""
echo -e "${YELLOW}  执行内容:${NC} 依赖安装 + sysctl(28项) + 模块 + nofile + gai.conf + MSS Clamp + DDoS"
echo ""
read -p "  确认执行? (Y/n): " confirm
[[ "$confirm" == "n" || "$confirm" == "N" ]] && echo "已取消" && exit 0

old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)

# 0. 安装依赖
echo ""
_info "[0/7] 检查并安装依赖..."
_install_deps
_success "OK"

# 1. sysctl - 备份并写入
echo ""
_info "[1/7] sysctl 参数 (28项)..."
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s)

# 生成干净的 sysctl.conf
cat > /etc/sysctl.conf << 'SYSCTLEOF'
# VPS 网络优化 - 整合方案 (Wyatt + netpilot + kejilion)
# 仅保留对代理/隧道 VPS 真实有效的参数

# 文件系统
fs.file-max = 6815744
fs.nr_open = 6815744

# 连接队列
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_abort_on_overflow = 0
net.core.netdev_max_backlog = 65536

# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区 (64MB)
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_moderate_rcvbuf = 1

# UDP 缓冲区
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# TCP 连接优化
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

# TCP Keepalive (600s 后探测, 30s 间隔, 3次失败断开)
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# Conntrack 连接跟踪
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# 虚拟内存
vm.swappiness = 10
vm.overcommit_memory = 1
SYSCTLEOF

# 加载 conntrack 模块 (sysctl 需要)
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
_info "[2/7] 内核模块开机加载..."
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/proxy-optimize.conf << 'EOF'
tcp_bbr
nf_conntrack
EOF
_success "BBR + conntrack"

# 3. nofile (systemd + limits.conf)
echo ""
_info "[3/7] 文件描述符..."
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
# systemd 默认 nofile
mkdir -p /etc/systemd/system.conf.d 2>/dev/null
cat > /etc/systemd/system.conf.d/nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
systemctl daemon-reexec 2>/dev/null || true
_success "systemd: DefaultLimitNOFILE=1048576"

# 4. gai.conf
echo ""
_info "[4/7] IPv4 优先解析..."
if [ -f /etc/gai.conf ]; then
    grep -q 'ffff:0:0' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
else
    echo 'precedence ::ffff:0:0/96  100' > /etc/gai.conf
fi
_success "OK"

# 5. MSS Clamp
echo ""
_info "[5/7] MSS Clamp (nftables)..."
if command -v nft &>/dev/null; then
    nft list table inet vps_optimize >/dev/null 2>&1 || nft add table inet vps_optimize
    nft list chain inet vps_optimize mangle_forward >/dev/null 2>&1 || nft add chain inet vps_optimize mangle_forward '{ type filter hook forward priority -150; policy accept; }'
    nft flush chain inet vps_optimize mangle_forward 2>/dev/null
    nft add rule inet vps_optimize mangle_forward tcp flags syn tcp option maxseg size set rt mtu comment MSS-Clamp 2>/dev/null
    mkdir -p /etc/nftables.d
    nft list table inet vps_optimize > /etc/nftables.d/vps_optimize.nft 2>/dev/null
    if [ -f /etc/nftables.conf ] && ! grep -q 'vps_optimize' /etc/nftables.conf 2>/dev/null; then
        echo 'include "/etc/nftables.d/vps_optimize.nft"' >> /etc/nftables.conf
    fi
    _success "MSS Clamp 已生效"
else
    _warn "nftables 不可用，跳过"
fi

# 6. DDoS
echo ""
_info "[6/7] DDoS 防护..."
if command -v nft &>/dev/null; then
    nft list chain inet vps_optimize dos_input >/dev/null 2>&1 || nft add chain inet vps_optimize dos_input '{ type filter hook input priority -150; policy accept; }'
    nft flush chain inet vps_optimize dos_input 2>/dev/null
    # SYN 洪水 (保护 SSH)
    nft add rule inet vps_optimize dos_input tcp flags syn tcp dport != 22 meter syn_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 200/second burst 50 packets drop comment DDoS-SYN 2>/dev/null
    # UDP 洪水
    nft add rule inet vps_optimize dos_input udp meter udp_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 500/second burst 100 packets drop comment DDoS-UDP 2>/dev/null
    # ICMP 限制
    nft add rule inet vps_optimize dos_input icmp type echo-request limit rate over 50/second burst 20 packets drop comment DDoS-ICMP 2>/dev/null
    # 异常 TCP 标志 (XMAS/NULL 扫描)
    nft add rule inet vps_optimize dos_input tcp flags syn,fin syn,fin drop comment DDoS-XMAS 2>/dev/null
    nft add rule inet vps_optimize dos_input tcp flags syn,rst syn,rst drop comment DDoS-SYNRST 2>/dev/null
    nft list table inet vps_optimize > /etc/nftables.d/vps_optimize.nft 2>/dev/null
    _success "DDoS 防护已生效"
else
    _warn "nftables 不可用，跳过"
fi

# 7. 验证
echo ""
echo -e "${GREEN}══════════════ 优化完成 ══════════════${NC}"

# 安全读取 sysctl 值
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

# 安全计算 MB
if [[ "$rmem" =~ ^[0-9]+$ ]]; then
    rmem_mb=$((rmem / 1048576))
else
    rmem_mb="$rmem"
fi

echo -e "  BBR:       ${old_bbr} → ${GREEN}${new_bbr}${NC}"
echo -e "  qdisc:     ${GREEN}${qdisc}${NC}"
echo -e "  somaxconn: ${GREEN}${somaxconn}${NC}"
echo -e "  rmem_max:  ${GREEN}${rmem_mb} MB${NC}"
echo -e "  file-max:  ${GREEN}${filemax}${NC}"
echo -e "  fin_time:  ${GREEN}${fintime}s${NC}"
echo -e "  swappiness:${GREEN} ${swapp}${NC}"
echo -e "  conntrack: ${GREEN}${conntrack}${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
