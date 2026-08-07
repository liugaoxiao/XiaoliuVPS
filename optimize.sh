#!/usr/bin/env bash
# XiaoliuVPS network optimization
# Hardware-adaptive BBR/FQ profile for normal VPS and NAT VPS nodes.

set -Eeuo pipefail

MANAGED_FILE=/etc/sysctl.d/90-xiaoliu-vps-optimize.conf
LIMITS_FILE=/etc/security/limits.d/90-xiaoliu-vps-optimize.conf
SYSTEMD_FILE=/etc/systemd/system.conf.d/90-xiaoliu-vps-optimize.conf
MODULE_FILE=/etc/modules-load.d/xiaoliu-vps-optimize.conf
RPS_STATE_FILE=/var/lib/xiaoliu-vps-optimize/rps.state
CONNTRACK_MAX=0
CONNTRACK_ENABLED=0
RPS_ENABLED=0

info() { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 运行。"
command -v sysctl >/dev/null 2>&1 || die "缺少 sysctl。"

write_file() {
    local destination=$1
    local temporary="${destination}.new.$$"
    mkdir -p "$(dirname "$destination")"
    cat > "$temporary"
    chmod 0644 "$temporary"
    mv -f "$temporary" "$destination"
}

detect_hardware() {
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 1048576)
    RAM_MB=$((RAM_KB / 1024))

    # Use actual available memory, not the provider's advertised package size.
    if [ "$RAM_MB" -lt 512 ]; then
        TCP_BUFFER_MAX=8388608
        UDP_BUFFER_MIN=8192
        TCP_BUFFER_DEFAULT=65536
        PROFILE_NAME="低内存 8MB"
    elif [ "$RAM_MB" -lt 1024 ]; then
        TCP_BUFFER_MAX=33554432
        UDP_BUFFER_MIN=16384
        TCP_BUFFER_DEFAULT=131072
        PROFILE_NAME="标准 32MB"
    else
        TCP_BUFFER_MAX=67108864
        UDP_BUFFER_MIN=16384
        TCP_BUFFER_DEFAULT=262144
        PROFILE_NAME="高带宽 64MB"
    fi

    FILE_MAX=$((RAM_MB * 1024))
    [ "$FILE_MAX" -lt 1048576 ] && FILE_MAX=1048576
    [ "$FILE_MAX" -gt 6815744 ] && FILE_MAX=6815744
    NETDEV_BACKLOG=$((CPU_CORES * 32768))
    [ "$NETDEV_BACKLOG" -lt 32768 ] && NETDEV_BACKLOG=32768
    [ "$NETDEV_BACKLOG" -gt 262144 ] && NETDEV_BACKLOG=262144
    CONNTRACK_MAX=$((RAM_KB / 16))
    [ "$CONNTRACK_MAX" -lt 65536 ] && CONNTRACK_MAX=65536
    [ "$CONNTRACK_MAX" -gt 524288 ] && CONNTRACK_MAX=524288
    [ -w /proc/sys/net/netfilter/nf_conntrack_max ] && CONNTRACK_ENABLED=1 || CONNTRACK_ENABLED=0

    info "硬件检测: ${CPU_CORES} 核 CPU, 实际内存 ${RAM_MB}MB"
    info "动态档位: ${PROFILE_NAME}; TCP 最大缓冲 $((TCP_BUFFER_MAX / 1048576))MB"
}

write_sysctl_profile() {
    local destination=${1:-$MANAGED_FILE}
    write_file "$destination" <<EOF
# Managed by XiaoliuVPS. Generated from actual CPU and memory.
# Does not overwrite /etc/sysctl.conf and has no firewall rate-limiting rules.
fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = ${TCP_BUFFER_MAX}
net.core.wmem_max = ${TCP_BUFFER_MAX}
net.core.rmem_default = ${TCP_BUFFER_DEFAULT}
net.core.wmem_default = ${TCP_BUFFER_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${TCP_BUFFER_DEFAULT} ${TCP_BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_BUFFER_DEFAULT} ${TCP_BUFFER_MAX}
net.ipv4.udp_rmem_min = ${UDP_BUFFER_MIN}
net.ipv4.udp_wmem_min = ${UDP_BUFFER_MIN}
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_retries2 = 12
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
EOF
    if [ "$CONNTRACK_ENABLED" -eq 1 ]; then
        cat >> "$destination" <<EOF
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF
    fi
    if [ -w /proc/sys/net/core/rps_sock_flow_entries ]; then
        printf 'net.core.rps_sock_flow_entries = 32768\n' >> "$destination"
    fi
}

capture_runtime_sysctls() {
    local source=$1 state=$2 key
    : > "$state"
    while IFS='=' read -r key _; do
        key=${key//[[:space:]]/}
        [ -n "$key" ] || continue
        printf '%s=' "$key" >> "$state"
        sysctl -n "$key" 2>/dev/null >> "$state" || printf '\n' >> "$state"
    done < <(grep -E '^[[:alnum:]_.]+[[:space:]]*=' "$source")
}

restore_runtime_sysctls() {
    local state=$1 key value
    [ -f "$state" ] || return 0
    while IFS='=' read -r key value; do
        [ -n "$key" ] && [ -n "$value" ] && sysctl -w "$key=$value" >/dev/null 2>&1 || true
    done < "$state"
}

apply_profile() {
    modprobe nf_conntrack 2>/dev/null || true
    detect_hardware
    info "检查 BBR 支持..."
    modprobe tcp_bbr 2>/dev/null || true
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || die "当前内核不支持 BBR。"

    local temporary runtime_state previous_file output
    temporary=$(mktemp /tmp/xiaoliu-vps-sysctl.XXXXXX)
    runtime_state=$(mktemp /tmp/xiaoliu-vps-runtime.XXXXXX)
    previous_file=$(mktemp /tmp/xiaoliu-vps-previous.XXXXXX)

    info "生成动态 BBR/FQ 参数..."
    write_sysctl_profile "$temporary"
    capture_runtime_sysctls "$temporary" "$runtime_state"
    [ -f "$MANAGED_FILE" ] && cp "$MANAGED_FILE" "$previous_file"

    if ! output=$(sysctl -p "$temporary" 2>&1) || printf '%s\n' "$output" | grep -qiE 'unknown key|cannot stat|permission denied'; then
        printf '%s\n' "$output" >&2
        restore_runtime_sysctls "$runtime_state"
        [ -s "$previous_file" ] && cp "$previous_file" "$MANAGED_FILE" || rm -f "$MANAGED_FILE"
        rm -f "$temporary" "$runtime_state" "$previous_file"
        die "sysctl 应用失败，已恢复本次修改前的运行时参数与持久化文件。"
    fi
    write_file "$MANAGED_FILE" < "$temporary"
    rm -f "$temporary" "$runtime_state" "$previous_file"

    if [ "$CONNTRACK_ENABLED" -eq 1 ]; then
        write_file "$MODULE_FILE" <<'EOF'
tcp_bbr
nf_conntrack
EOF
    else
        write_file "$MODULE_FILE" <<'EOF'
tcp_bbr
EOF
    fi
    apply_rps_rfs
    write_file "$LIMITS_FILE" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    write_file "$SYSTEMD_FILE" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reexec || warn "systemd 重载失败，文件句柄限制会在下次重启后生效。"
    fi

    verify_profile
    ok "优化完成。未修改 /etc/sysctl.conf，未添加防火墙或全局 UDP/SYN 限速。"
}

verify_profile() {
    detect_hardware
    local failed=0 key expected actual
    while read -r key expected; do
        actual=$(sysctl -n "$key" 2>/dev/null || true)
        if [ "$actual" = "$expected" ]; then
            ok "$key = $actual"
        else
            printf '\033[0;31m[ERROR]\033[0m %s = %s，预期 %s\n' "$key" "${actual:-不可用}" "$expected" >&2
            failed=1
        fi
    done <<EOF
net.ipv4.tcp_congestion_control bbr
net.core.default_qdisc fq
net.core.rmem_max ${TCP_BUFFER_MAX}
net.core.wmem_max ${TCP_BUFFER_MAX}
net.core.somaxconn 65535
EOF
    [ "$failed" -eq 0 ] || return 1
    if [ "$CONNTRACK_ENABLED" -eq 1 ]; then
        ok "nf_conntrack_max = ${CONNTRACK_MAX}"
    fi
    if [ "$RPS_ENABLED" -eq 1 ]; then
        ok "RPS/RFS 已按网卡队列启用"
    fi
    return 0
}

apply_rps_rfs() {
    RPS_ENABLED=0
    [ "$CPU_CORES" -gt 1 ] || return 0
    local mask="" i queue eth
    if [ "$CPU_CORES" -le 32 ]; then
        mask=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))
    else
        for ((i=0; i<8; i++)); do mask="${mask}f"; done
    fi
    mkdir -p "$(dirname "$RPS_STATE_FILE")"
    : > "$RPS_STATE_FILE"
    for eth in /sys/class/net/*; do
        [ -d "$eth/queues" ] || continue
        for queue in "$eth"/queues/rx-*; do
            [ -w "$queue/rps_cpus" ] || continue
                        printf '%s=%s\n' "$queue/rps_cpus" "$(cat "$queue/rps_cpus")" >> "$RPS_STATE_FILE"
            printf '%s=%s\n' "$queue/rps_flow_cnt" "$(cat "$queue/rps_flow_cnt" 2>/dev/null || echo 0)" >> "$RPS_STATE_FILE"
            printf '%s\n' "$mask" > "$queue/rps_cpus"
            [ -w "$queue/rps_flow_cnt" ] && printf '4096\n' > "$queue/rps_flow_cnt"
            RPS_ENABLED=1
        done
    done
}

restore_rps_rfs() {
    local path value
    [ -f "$RPS_STATE_FILE" ] || return 0
    while IFS='=' read -r path value; do
        [ -w "$path" ] && printf '%s
' "$value" > "$path" || true
    done < "$RPS_STATE_FILE"
    rm -f "$RPS_STATE_FILE"
}

show_status() {
    detect_hardware
    printf '\n当前关键参数：\n'
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.core.somaxconn 2>/dev/null || true
    [ -f "$MANAGED_FILE" ] && info "当前配置: $MANAGED_FILE" || warn "尚未应用 XiaoliuVPS 优化配置。"
}

restore_profile() {
    rm -f "$MANAGED_FILE" "$LIMITS_FILE" "$SYSTEMD_FILE" "$MODULE_FILE"
    restore_rps_rfs
    sysctl --system || warn "系统其他 sysctl 配置存在错误；本脚本管理的文件已删除。"
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reexec || true; fi
    ok "已删除 XiaoliuVPS 管理的优化文件。其他 sysctl 配置保持不变。"
}

printf '\nXiaoliuVPS 动态网络优化\n'
printf '1) 自动检测硬件并应用优化\n'
printf '2) 查看当前状态\n'
printf '3) 删除本脚本的持久化配置\n'
read -r -p '请选择 [1/2/3]: ' choice < /dev/tty
case "$choice" in
    1) apply_profile ;;
    2) show_status ;;
    3) restore_profile ;;
    *) die "无效选项。" ;;
esac
