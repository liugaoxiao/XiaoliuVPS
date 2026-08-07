#!/usr/bin/env bash
# XiaoliuVPS network optimization
# Wyatt-compatible BBR/FQ profile. Only manages files under /etc/sysctl.d.

set -Eeuo pipefail

MANAGED_FILE=/etc/sysctl.d/90-xiaoliu-vps-optimize.conf
LIMITS_FILE=/etc/security/limits.d/90-xiaoliu-vps-optimize.conf
SYSTEMD_FILE=/etc/systemd/system.conf.d/90-xiaoliu-vps-optimize.conf
MODULE_FILE=/etc/modules-load.d/xiaoliu-vps-optimize.conf

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

apply_profile() {
    info "检查 BBR 支持..."
    modprobe tcp_bbr 2>/dev/null || true
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || die "当前内核不支持 BBR。"

    info "写入 Wyatt 兼容的 BBR/FQ 优化参数..."
    write_file "$MANAGED_FILE" <<'EOF'
# Managed by XiaoliuVPS. Do not edit unless you understand sysctl precedence.
# Core values match Wyatt TCP+BBR; this file does not overwrite /etc/sysctl.conf.
fs.file-max = 6815744
fs.nr_open = 6815744
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 65536
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
EOF

    local output
    if ! output=$(sysctl -p "$MANAGED_FILE" 2>&1); then
        printf '%s\n' "$output" >&2
        die "sysctl 应用失败，配置文件已保留以便检查：$MANAGED_FILE"
    fi
    if printf '%s\n' "$output" | grep -qiE 'unknown key|cannot stat|permission denied'; then
        printf '%s\n' "$output" >&2
        die "发现不支持的 sysctl 参数，未继续配置其他项目。"
    fi

    write_file "$MODULE_FILE" <<'EOF'
tcp_bbr
EOF
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
    ok "优化完成。未修改 /etc/sysctl.conf，未添加防火墙或全局 UDP/SYN 限速规则。"
}

verify_profile() {
    local failed=0
    local key expected actual
    while read -r key expected; do
        actual=$(sysctl -n "$key" 2>/dev/null || true)
        if [ "$actual" = "$expected" ]; then
            ok "$key = $actual"
        else
            printf '\033[0;31m[ERROR]\033[0m %s = %s，预期 %s\n' "$key" "${actual:-不可用}" "$expected" >&2
            failed=1
        fi
    done <<'EOF'
net.ipv4.tcp_congestion_control bbr
net.core.default_qdisc fq
net.core.rmem_max 67108864
net.core.wmem_max 67108864
net.core.somaxconn 65535
EOF
    [ "$failed" -eq 0 ] || return 1
}

restore_profile() {
    rm -f "$MANAGED_FILE" "$LIMITS_FILE" "$SYSTEMD_FILE" "$MODULE_FILE"
    sysctl --system
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reexec || true
    fi
    ok "已删除 XiaoliuVPS 管理的优化文件。其他 sysctl 配置保持不变。"
    warn "已运行的连接不会回退；新的默认 sysctl 值由系统其余配置决定。"
}

printf '\nXiaoliuVPS BBR 网络优化\n'
printf '1) 应用 Wyatt 兼容优化\n'
printf '2) 查看当前关键参数\n'
printf '3) 删除本脚本的持久化配置\n'
read -r -p '请选择 [1/2/3]: ' choice < /dev/tty
case "$choice" in
    1) apply_profile ;;
    2) verify_profile && ok "关键参数验证通过。" ;;
    3) restore_profile ;;
    *) die "无效选项。" ;;
esac
