#!/bin/bash
# VPS 一键优化 / 一键恢复 - 整合自 Wyatt/vps-netpilot/kejilion
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

# 备份目录
BACKUP_DIR="/var/lib/vps-optimize-backup"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# ═══════════════════════════════════════
# 硬件检测 - 动态计算最优参数
# ═══════════════════════════════════════
_detect_hardware() {
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    RAM_KB=$(grep -i '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    RAM_MB=$(( ${RAM_KB:-262144} / 1024 ))

    # 文件描述符: 内存*512, 最小1M, 最大16M
    FILE_MAX=$((RAM_MB * 512))
    [ "$FILE_MAX" -lt 1048576 ] && FILE_MAX=1048576
    [ "$FILE_MAX" -gt 16777216 ] && FILE_MAX=16777216

    # conntrack: 内存*64, 最小32K, 最大512K
    CONNTRACK_MAX=$((RAM_MB * 64))
    [ "$CONNTRACK_MAX" -lt 32768 ] && CONNTRACK_MAX=32768
    [ "$CONNTRACK_MAX" -gt 524288 ] && CONNTRACK_MAX=524288

    # 网卡收包队列: 核数*65536, 最小64K, 最大512K
    NETDEV_BACKLOG=$((CPU_CORES * 65536))
    [ "$NETDEV_BACKLOG" -lt 65536 ] && NETDEV_BACKLOG=65536
    [ "$NETDEV_BACKLOG" -gt 524288 ] && NETDEV_BACKLOG=524288

    # TCP 缓冲区: >=1.5G 内存用 64MB, 否则 32MB
    if [ "$RAM_MB" -ge 1536 ]; then
        TCP_BUF_MAX=67108864
        TCP_BUF_RMEM="4096 87380 67108864"
        TCP_BUF_WMEM="4096 65536 67108864"
        UDP_BUF_MIN=16384
    else
        TCP_BUF_MAX=33554432
        TCP_BUF_RMEM="4096 87380 33554432"
        TCP_BUF_WMEM="4096 65536 33554432"
        UDP_BUF_MIN=8192
    fi

    _info "检测到: ${CPU_CORES}核 CPU, ${RAM_MB}MB 内存"
}

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

# ═══════════════════════════════════════
# 备份函数 (优化前调用)
# ═══════════════════════════════════════
_backup_all() {
    mkdir -p "$BACKUP_DIR"
    _info "备份当前配置到 $BACKUP_DIR ..."

    # sysctl.conf
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak"

    # sshd_config
    [ -f /etc/ssh/sshd_config ] && cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak"

    # limits.conf
    [ -f /etc/security/limits.conf ] && cp /etc/security/limits.conf "$BACKUP_DIR/limits.conf.bak"

    # gai.conf
    [ -f /etc/gai.conf ] && cp /etc/gai.conf "$BACKUP_DIR/gai.conf.bak"

    # nftables (保存我们创建的表的状态)
    nft list table inet vps_optimize > "$BACKUP_DIR/vps_optimize.nft.bak" 2>/dev/null || true

    # modules-load.d
    if [ -f /etc/modules-load.d/proxy-optimize.conf ]; then
        cp /etc/modules-load.d/proxy-optimize.conf "$BACKUP_DIR/proxy-optimize.modules.bak"
    fi
    mkdir -p "$BACKUP_DIR/modules-load.d.bak"
    cp /etc/modules-load.d/*.conf "$BACKUP_DIR/modules-load.d.bak/" 2>/dev/null || true

    # 标记备份时间
    echo "$TIMESTAMP" > "$BACKUP_DIR/last_backup"

    _success "备份完成"
}

# ═══════════════════════════════════════
# 恢复函数
# ═══════════════════════════════════════
_restore_all() {
    echo ""
    echo -e "${YELLOW}  ╔═══════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}  ║         ⚠️  恢复默认配置  ⚠️           ║${NC}"
    echo -e "${YELLOW}  ╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  将恢复以下内容:"
    echo -e "    · sysctl.conf → Debian 默认值"
    echo -e "    · 删除 nftables vps_optimize 规则表"
    echo -e "    · sshd_config → 移除脚本添加的加固项"
    echo -e "    · 删除 nofile 限制配置"
    echo -e "    · 删除 gai.conf IPv4 优先"
    echo -e "    · 删除模块开机加载配置"
    echo ""
    read -p "  确认恢复? (y/N): " confirm < /dev/tty
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消" && exit 0

    # 1. sysctl - 恢复备份并重置内核参数
    echo ""
    _info "[1/7] 恢复 sysctl ..."
    if [ -f "$BACKUP_DIR/sysctl.conf.bak" ]; then
        cp "$BACKUP_DIR/sysctl.conf.bak" /etc/sysctl.conf
        _success "已从备份恢复 sysctl.conf"
    else
        # 无备份时：逐个移除脚本设置的参数
        if [ -f /etc/sysctl.conf ]; then
            for key in fs.file-max fs.nr_open net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_abort_on_overflow net.core.netdev_max_backlog net.core.busy_read net.core.busy_poll net.core.netdev_budget net.core.netdev_budget_usecs net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min net.ipv4.tcp_fastopen net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_timestamps net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_retries2 net.ipv4.tcp_max_orphans net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_syncookies net.ipv4.tcp_notsent_lowat net.ipv4.tcp_sack net.ipv4.tcp_mtu_probing net.ipv4.tcp_rfc1337 net.ipv4.tcp_ecn net.ipv4.tcp_no_metrics_save net.ipv4.ip_local_port_range net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.icmp_echo_ignore_all net.ipv4.icmp_echo_ignore_broadcasts net.ipv4.icmp_ratelimit net.ipv4.icmp_msgs_per_sec net.ipv4.conf.all.accept_redirects net.ipv4.conf.default.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.default.send_redirects net.ipv4.conf.all.accept_source_route net.ipv4.conf.default.accept_source_route net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter kernel.kptr_restrict kernel.dmesg_restrict net.ipv4.conf.all.log_martians net.ipv4.conf.default.log_martians net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_tcp_timeout_established net.netfilter.nf_conntrack_tcp_timeout_time_wait net.netfilter.nf_conntrack_tcp_timeout_close_wait net.netfilter.nf_conntrack_tcp_timeout_fin_wait net.netfilter.nf_conntrack_tcp_timeout_last_ack net.netfilter.nf_conntrack_udp_timeout net.netfilter.nf_conntrack_udp_timeout_stream vm.swappiness vm.overcommit_memory; do
                sed -i "/^${key} /d" /etc/sysctl.conf 2>/dev/null
            done
            sed -i '/VPS 网络优化/d' /etc/sysctl.conf
            sed -i '/仅保留对代理/d' /etc/sysctl.conf
            sed -i '/^# ═══/d' /etc/sysctl.conf
            sed -i '/^$/N;/^\n$/d' /etc/sysctl.conf 2>/dev/null
        fi
        _warn "无备份，已从 sysctl.conf 移除优化参数"
    fi
    # 重置关键内核参数为 Debian 默认值
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1
    sysctl -w kernel.kptr_restrict=1 >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
    _success "sysctl 已恢复"

    # 2. 删除 nftables 优化表
    echo ""
    _info "[2/7] 删除 nftables 规则 ..."
    if nft list table inet vps_optimize >/dev/null 2>&1; then
        nft delete table inet vps_optimize 2>/dev/null
        _success "vps_optimize 表已删除"
    else
        _success "vps_optimize 表不存在，跳过"
    fi
    # 清理 include
    if [ -f /etc/nftables.conf ]; then
        sed -i '/vps_optimize/d' /etc/nftables.conf 2>/dev/null
    fi
    rm -f /etc/nftables.d/vps_optimize.nft 2>/dev/null

    # 3. 恢复 sshd_config
    echo ""
    _info "[3/7] 恢复 SSH 配置 ..."
    if [ -f "$BACKUP_DIR/sshd_config.bak" ]; then
        cp "$BACKUP_DIR/sshd_config.bak" /etc/ssh/sshd_config
        _success "已从备份恢复 sshd_config"
    else
        # 仅移除脚本添加的行
        local sshd="/etc/ssh/sshd_config"
        if [ -f "$sshd" ]; then
            sed -i '/^PermitEmptyPasswords no$/d' "$sshd"
            sed -i '/^MaxAuthTries [0-9]*$/d' "$sshd"
            sed -i '/^X11Forwarding no$/d' "$sshd"
            sed -i '/^Banner \/dev\/null$/d' "$sshd"
            sed -i '/^Banner none$/d' "$sshd"
            sed -i '/^DebianBanner no$/d' "$sshd"
            _success "已移除脚本添加的 SSH 配置"
        fi
    fi
    # 重载 SSH
    if command -v systemctl &>/dev/null && systemctl is-active sshd >/dev/null 2>&1; then
        systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null
    elif command -v systemctl &>/dev/null && systemctl is-active ssh >/dev/null 2>&1; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null
    fi

    # 4. 删除 nofile 配置
    echo ""
    _info "[4/7] 恢复文件描述符 ..."
    if [ -f "$BACKUP_DIR/limits.conf.bak" ]; then
        cp "$BACKUP_DIR/limits.conf.bak" /etc/security/limits.conf
        _success "已从备份恢复 limits.conf"
    else
        # 仅移除脚本添加的块
        if [ -f /etc/security/limits.conf ]; then
            sed -i '/# VPS-Optimize-nofile/,+4d' /etc/security/limits.conf 2>/dev/null
            _success "已移除脚本添加的 nofile 限制"
        fi
    fi
    rm -f /etc/systemd/system.conf.d/nofile.conf 2>/dev/null
    rm -f /etc/udev/rules.d/99-txqueuelen.rules 2>/dev/null
    udevadm control --reload-rules 2>/dev/null || true
    systemctl daemon-reexec 2>/dev/null || true
    _success "systemd nofile 已清除"

    # 5. 恢复 gai.conf
    echo ""
    _info "[5/7] 恢复 IPv4 优先解析 ..."
    if [ -f "$BACKUP_DIR/gai.conf.bak" ]; then
        cp "$BACKUP_DIR/gai.conf.bak" /etc/gai.conf
        _success "已从备份恢复 gai.conf"
    else
        if [ -f /etc/gai.conf ]; then
            sed -i '/^precedence ::ffff:0:0\/96  100$/d' /etc/gai.conf
            _success "已移除 IPv4 优先配置"
        fi
    fi

    # 6. 恢复模块开机加载
    echo ""
    _info "[6/7] 恢复模块开机加载 ..."
    rm -f /etc/modules-load.d/proxy-optimize.conf 2>/dev/null
    if [ -d "$BACKUP_DIR/modules-load.d.bak" ]; then
        cp "$BACKUP_DIR/modules-load.d.bak"/*.conf /etc/modules-load.d/ 2>/dev/null || true
        _success "modules-load.d 已从备份恢复"
    else
        _success "proxy-optimize.conf 已删除"
    fi

    # 7. 清理备份目录
    echo ""
    _info "[7/7] 清理备份 ..."
    rm -rf "$BACKUP_DIR"
    _success "备份已清理"

    # 验证
    echo ""
    echo -e "${GREEN}══════════════ 恢复完成 ══════════════${NC}"
    echo -e "  当前拥塞: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
    echo -e "  ICMP:     ping $(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null | grep -q '^1$' && echo '不通' || echo '通')"
    echo -e "  防火墙:   $(nft list table inet vps_optimize >/dev/null 2>&1 && echo 'vps_optimize 仍存在' || echo '已清除')"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
}

# ═══════════════════════════════════════
# 优化函数
# ═══════════════════════════════════════
_optimize_all() {
    old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)

    # 0. 备份 + 安装依赖 + 硬件检测
    echo ""
    _info "[0/8] 备份 + 安装依赖 + 硬件检测..."
    _backup_all
    _install_deps
    _detect_hardware
    _success "OK"

    # 1. sysctl - 网络优化 + 安全加固
    echo ""
    _info "[1/8] sysctl 参数 (根据 ${CPU_CORES}核/${RAM_MB}MB 动态计算)..."

    cat > /etc/sysctl.conf << SYSCTLEOF
# VPS 网络优化 + 安全隐匿 - 整合方案
# 仅保留对代理/隧道 VPS 真实有效的参数
# 动态检测: ${CPU_CORES}核 CPU, ${RAM_MB}MB 内存

# ═══ 文件系统 (根据内存: ${RAM_MB}MB) ═══
fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}

# ═══ 连接队列 (根据CPU: ${CPU_CORES}核) ═══
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_abort_on_overflow = 0
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# ═══ 吞吐量优化 ═══
net.core.busy_read = 50
net.core.busy_poll = 50
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 6000

# ═══ BBR 拥塞控制 ═══
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ═══ TCP 缓冲区 (根据内存: ${RAM_MB}MB) ═══
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = ${TCP_BUF_RMEM}
net.ipv4.tcp_wmem = ${TCP_BUF_WMEM}
net.ipv4.tcp_moderate_rcvbuf = 1

# ═══ UDP 缓冲区 ═══
net.ipv4.udp_rmem_min = ${UDP_BUF_MIN}
net.ipv4.udp_wmem_min = ${UDP_BUF_MIN}

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

# ═══ TCP Keepalive (1800s 探测, 30s 间隔, 3次断开) ═══
net.ipv4.tcp_keepalive_time = 1800
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

# ═══ Conntrack 连接跟踪 (根据内存: ${RAM_MB}MB) ═══
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# ═══ 虚拟内存 ═══
vm.swappiness = 10
vm.overcommit_memory = 0
SYSCTLEOF

    # 加载内核模块
    modprobe nf_conntrack 2>/dev/null || true
    modprobe tcp_bbr 2>/dev/null || true

    # 网卡 TX 队列长度 (默认 1000，增大可减少高吞吐时丢包)
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        ip link set "$iface" txqueuelen 10000 2>/dev/null || true
    done

    # 持久化 txqueuelen (重启后生效)
    cat > /etc/udev/rules.d/99-txqueuelen.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="net", RUN+="/sbin/ip link set $name txqueuelen 10000"
EOF
    udevadm control --reload-rules 2>/dev/null || true

    # 应用并统计结果
    sysctl_output=$(sysctl -p 2>&1)
    sysctl_applied=$(echo "$sysctl_output" | grep -c '^[a-z].* = ' || true)
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

        # 优先放行已建立连接 (所有已有会话不受影响)
        nft add rule inet vps_optimize dos_input ct state established,related accept comment Accept-Established 2>/dev/null
        # 放行 loopback
        nft add rule inet vps_optimize dos_input iif lo accept comment Accept-Loopback 2>/dev/null
        # 丢弃无效连接状态
        nft add rule inet vps_optimize dos_input ct state invalid drop comment Drop-Invalid 2>/dev/null
        # 丢弃异常 TCP 标志 (XMAS/SYN-RST 扫描)
        nft add rule inet vps_optimize dos_input tcp flags syn,fin syn,fin drop comment Block-XMAS 2>/dev/null
        nft add rule inet vps_optimize dos_input tcp flags syn,rst syn,rst drop comment Block-SYNRST 2>/dev/null
        # SYN 洪水防护 (保护 SSH)
        nft add rule inet vps_optimize dos_input tcp flags syn tcp dport != 22 meter syn_flood '{ size 65536, flags dynamic, timeout 10s }' limit rate over 500/second burst 100 packets drop comment DDoS-SYN 2>/dev/null
        # SSH 速率限制: 每 IP 每分钟最多 10 次新连接
        nft add rule inet vps_optimize dos_input tcp dport 22 ct state new meter ssh_bruteforce '{ size 65536, flags dynamic, timeout 60s }' limit rate over 10/minute burst 10 packets drop comment SSH-RateLimit 2>/dev/null
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

    # 6. SSH 安全加固 + Banner 隐藏
    echo ""
    _info "[6/8] SSH 安全加固 + Banner 隐藏..."
    SSH_CONF="/etc/ssh/sshd_config"
    if [ -f "$SSH_CONF" ]; then
        sshd_changed=false
        if ! grep -qE '^\s*PermitEmptyPasswords\s+no' "$SSH_CONF" 2>/dev/null; then
            echo 'PermitEmptyPasswords no' >> "$SSH_CONF"
            sshd_changed=true
        fi
        if ! grep -qE '^\s*MaxAuthTries\s+' "$SSH_CONF" 2>/dev/null; then
            echo 'MaxAuthTries 5' >> "$SSH_CONF"
            sshd_changed=true
        fi
        if ! grep -qE '^\s*X11Forwarding\s+no' "$SSH_CONF" 2>/dev/null; then
            echo 'X11Forwarding no' >> "$SSH_CONF"
            sshd_changed=true
        fi
        if ! grep -qE '^\s*Banner\s+' "$SSH_CONF" 2>/dev/null; then
            echo 'Banner /dev/null' >> "$SSH_CONF"
            sshd_changed=true
        fi
        if ! grep -qE '^\s*DebianBanner\s+no' "$SSH_CONF" 2>/dev/null; then
            echo 'DebianBanner no' >> "$SSH_CONF"
            sshd_changed=true
        fi
        if [ "$sshd_changed" = true ]; then
            # 先验证配置语法，防止锁死 SSH
            if sshd -t 2>/dev/null; then
                if command -v systemctl &>/dev/null && systemctl is-active sshd >/dev/null 2>&1; then
                    systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null
                elif command -v systemctl &>/dev/null && systemctl is-active ssh >/dev/null 2>&1; then
                    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null
                elif command -v rc-service &>/dev/null; then
                    rc-service sshd reload 2>/dev/null || rc-service sshd restart 2>/dev/null
                fi
                _success "SSH 加固已生效 (MaxAuthTries=5, 禁空密码, 禁X11, Banner隐藏)"
            else
                _error "sshd 配置语法检查失败! 已跳过重载，请手动检查 $SSH_CONF"
            fi
        else
            _success "SSH 已配置，跳过"
        fi
    else
        _warn "sshd_config 不存在，跳过"
    fi

    # 7. 验证
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
    echo -e "  SSH限速:   ${GREEN}10次/分钟${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
}

# ═══════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════
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
echo -e "  ${CYAN}请选择操作:${NC}"
echo ""
echo -e "    ${GREEN}1${NC}) 一键优化 (网络 + 安全 + 防火墙)"
echo -e "    ${RED}2${NC}) 恢复默认 (撤销所有优化)"
echo ""
echo -e "  ${YELLOW}优化内容:${NC}"
echo -e "    网络优化: sysctl(42项+动态) + BBR + conntrack + nofile + gai.conf"
echo -e "    安全隐匿: ICMP隐藏 + TCP防指纹 + 内核加固 + DDoS防护"
echo -e "    防火墙:   MSS Clamp + 端口扫描拦截 + SSH速率限制"
echo ""
read -p "  输入选项 [1/2]: " choice < /dev/tty

case "$choice" in
    1)
        echo ""
        _info "开始优化..."
        _optimize_all
        ;;
    2)
        _restore_all
        ;;
    *)
        _error "无效选项: $choice"
        exit 1
        ;;
esac
