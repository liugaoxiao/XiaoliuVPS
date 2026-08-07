#!/usr/bin/env bash
# VPS optimization and safe restore
# Managed files only; does not overwrite distribution configuration.

set -Eeuo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
_info() { echo -e "${CYAN}[INFO] $*${NC}"; }
_success() { echo -e "${GREEN}[OK] $*${NC}"; }
_warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
_error() { echo -e "${RED}[ERROR] $*${NC}" >&2; }
_die() { _error "$*"; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || _die "Run as root: sudo bash optimize.sh"

STATE_DIR=/var/lib/vps-optimize
BASELINE_DIR="$STATE_DIR/baseline"
SYSCTL_FILE=/etc/sysctl.d/90-vps-optimize.conf
LIMITS_FILE=/etc/security/limits.d/90-vps-optimize.conf
SYSTEMD_FILE=/etc/systemd/system.conf.d/90-vps-optimize.conf
MODULE_FILE=/etc/modules-load.d/vps-optimize.conf
UDEV_FILE=/etc/udev/rules.d/99-vps-optimize-txqueuelen.rules
SSH_FILE=/etc/ssh/sshd_config.d/90-vps-optimize.conf
NFT_FILE=/etc/nftables.d/vps-optimize.nft
NFT_INCLUDE='# vps-optimize managed include'
NFT_SERVICE_STATE="$BASELINE_DIR/nftables-service-enabled"
SYN_RATE=${SYN_RATE:-2000}
UDP_RATE=${UDP_RATE:-2000}
SSH_RATE=${SSH_RATE:-20}

_cleanup_tmp() { [ -n "${TMPDIR_WORK:-}" ] && rm -rf "$TMPDIR_WORK"; }
trap _cleanup_tmp EXIT
_require() { command -v "$1" >/dev/null 2>&1 || _die "Required command not found: $1"; }

_detect_hardware() {
    CPU_CORES=$(nproc 2>/dev/null || echo 1)
    RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 1048576)
    RAM_MB=$((RAM_KB / 1024))
    FILE_MAX=$((RAM_MB * 512)); [ "$FILE_MAX" -lt 1048576 ] && FILE_MAX=1048576; [ "$FILE_MAX" -gt 16777216 ] && FILE_MAX=16777216
    CONNTRACK_MAX=$((RAM_MB * 64)); [ "$CONNTRACK_MAX" -lt 32768 ] && CONNTRACK_MAX=32768; [ "$CONNTRACK_MAX" -gt 524288 ] && CONNTRACK_MAX=524288
    NETDEV_BACKLOG=$((CPU_CORES * 65536)); [ "$NETDEV_BACKLOG" -lt 65536 ] && NETDEV_BACKLOG=65536; [ "$NETDEV_BACKLOG" -gt 524288 ] && NETDEV_BACKLOG=524288
    if [ "$RAM_MB" -ge 1536 ]; then TCP_BUF_MAX=67108864; UDP_BUF_MIN=16384; else TCP_BUF_MAX=33554432; UDP_BUF_MIN=8192; fi
    _info "Hardware: ${CPU_CORES} CPU cores, ${RAM_MB} MB RAM"
}
_capture_baseline() {
    mkdir -p "$BASELINE_DIR"
    [ -f "$BASELINE_DIR/created_at" ] && return 0
    _info "Capturing one-time baseline at $BASELINE_DIR"
    date -u +%FT%TZ > "$BASELINE_DIR/created_at"
    uname -a > "$BASELINE_DIR/uname" 2>/dev/null || true
    for key in net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.icmp_echo_ignore_all kernel.kptr_restrict; do
        printf '%s=' "$key" >> "$BASELINE_DIR/runtime-sysctl"
        sysctl -n "$key" 2>/dev/null >> "$BASELINE_DIR/runtime-sysctl" || echo >> "$BASELINE_DIR/runtime-sysctl"
    done
}
_write_atomic() { local target=$1 source=$2; mkdir -p "$(dirname "$target")"; install -m 0644 "$source" "${target}.new"; mv -f "${target}.new" "$target"; }
_capture_sysctl_values() {
    local source=$1 state=$2 key ignored
    : > "$state"
    while IFS='=' read -r key ignored; do
        key=$(printf '%s' "$key" | tr -d ' '); [ -n "$key" ] || continue
        printf '%s=' "$key" >> "$state"; sysctl -n "$key" 2>/dev/null >> "$state" || echo >> "$state"
    done < <(grep -E '^[a-zA-Z0-9_.]+[[:space:]]*=' "$source")
}
_restore_sysctl_values() { local state=$1 key value; [ -f "$state" ] || return 0; while IFS='=' read -r key value; do [ -n "$key" ] && [ -n "$value" ] && sysctl -w "$key=$value" >/dev/null 2>&1 || true; done < "$state"; }
_capture_managed_sysctls() { local source=$1 state="$BASELINE_DIR/managed-runtime-sysctl"; [ -f "$state" ] || _capture_sysctl_values "$source" "$state"; }
_reload_ssh() {
    command -v systemctl >/dev/null 2>&1 || { _warn "systemctl is unavailable; SSH configuration was validated but not reloaded"; return 0; }
    if systemctl is-active --quiet ssh; then systemctl reload ssh
    elif systemctl is-active --quiet sshd; then systemctl reload sshd
    else _warn "SSH service is not active; configuration was validated but not reloaded"; fi
}
_apply_sysctl() {
    local tmp="$TMPDIR_WORK/sysctl.conf" output
    cat > "$tmp" <<EOF
# Managed by vps-optimize. Remove this file to stop persistence.
fs.file-max = ${FILE_MAX}
fs.nr_open = ${FILE_MAX}
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 87380 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_BUF_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_rmem_min = ${UDP_BUF_MIN}
net.ipv4.udp_wmem_min = ${UDP_BUF_MIN}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_keepalive_time = 1800
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
vm.swappiness = 10
EOF
    _capture_managed_sysctls "$tmp"; _capture_sysctl_values "$tmp" "$TMPDIR_WORK/sysctl.runtime.previous"
    [ -f "$SYSCTL_FILE" ] && cp "$SYSCTL_FILE" "$TMPDIR_WORK/sysctl.previous"
    output=$(sysctl -p "$tmp" 2>&1) || { printf '%s\n' "$output" >&2; _restore_sysctl_values "$TMPDIR_WORK/sysctl.runtime.previous"; [ -f "$TMPDIR_WORK/sysctl.previous" ] && _write_atomic "$SYSCTL_FILE" "$TMPDIR_WORK/sysctl.previous" || rm -f "$SYSCTL_FILE"; _die "sysctl apply failed; previous runtime values and managed file restored"; }
    if printf '%s\n' "$output" | grep -qiE 'unknown key|cannot stat|permission denied'; then printf '%s\n' "$output" >&2; _restore_sysctl_values "$TMPDIR_WORK/sysctl.runtime.previous"; [ -f "$TMPDIR_WORK/sysctl.previous" ] && _write_atomic "$SYSCTL_FILE" "$TMPDIR_WORK/sysctl.previous" || rm -f "$SYSCTL_FILE"; _die "Unsupported sysctl key detected; previous runtime values and managed file restored"; fi
    _write_atomic "$SYSCTL_FILE" "$tmp"; _success "sysctl applied from $SYSCTL_FILE"
}
_apply_limits() {
    cat > "$TMPDIR_WORK/limits.conf" <<'EOF'
# Managed by vps-optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    _write_atomic "$LIMITS_FILE" "$TMPDIR_WORK/limits.conf"
    printf '[Manager]\nDefaultLimitNOFILE=1048576\n' > "$TMPDIR_WORK/systemd.conf"; _write_atomic "$SYSTEMD_FILE" "$TMPDIR_WORK/systemd.conf"
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reexec || _warn "systemd daemon-reexec failed; limits apply after next reboot"; else _warn "systemctl unavailable; systemd limits apply only where systemd is present"; fi
}
_apply_modules_and_queue() {
    printf 'tcp_bbr\nnf_conntrack\n' > "$TMPDIR_WORK/modules.conf"; _write_atomic "$MODULE_FILE" "$TMPDIR_WORK/modules.conf"
    modprobe tcp_bbr 2>/dev/null || true; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr || _die "BBR is unavailable in this kernel"
    modprobe nf_conntrack 2>/dev/null || _warn "nf_conntrack module cannot be loaded"; _require ip
    while IFS= read -r iface; do ip link set "$iface" txqueuelen 10000 || _warn "Cannot set txqueuelen on $iface"; done < <(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | sed 's/@.*//')
    cat > "$TMPDIR_WORK/udev.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL!="lo", RUN+="/sbin/ip link set $name txqueuelen 10000"
EOF
    _write_atomic "$UDEV_FILE" "$TMPDIR_WORK/udev.rules"
    if command -v udevadm >/dev/null 2>&1; then udevadm control --reload-rules || _warn "udev reload failed; queue persistence applies after reboot"; else _warn "udevadm unavailable; queue persistence depends on the host network manager"; fi
}
_apply_ssh() {
    _require sshd; [ -d /etc/ssh/sshd_config.d ] || { _warn "sshd_config.d is unavailable; SSH configuration skipped"; return 0; }
    cat > "$TMPDIR_WORK/ssh.conf" <<'EOF'
# Managed by vps-optimize
PermitEmptyPasswords no
MaxAuthTries 5
X11Forwarding no
Banner /dev/null
EOF
    [ -f "$SSH_FILE" ] && cp "$SSH_FILE" "$TMPDIR_WORK/ssh.previous"; _write_atomic "$SSH_FILE" "$TMPDIR_WORK/ssh.conf"
    sshd -t -f /etc/ssh/sshd_config || { [ -f "$TMPDIR_WORK/ssh.previous" ] && _write_atomic "$SSH_FILE" "$TMPDIR_WORK/ssh.previous" || rm -f "$SSH_FILE"; _die "sshd validation failed; previous managed SSH file restored"; }
    local effective setting; effective=$(sshd -T -f /etc/ssh/sshd_config) || { [ -f "$TMPDIR_WORK/ssh.previous" ] && _write_atomic "$SSH_FILE" "$TMPDIR_WORK/ssh.previous" || rm -f "$SSH_FILE"; _die "sshd effective configuration could not be read"; }
    for setting in 'permitemptypasswords no' 'maxauthtries 5' 'x11forwarding no' 'banner /dev/null'; do printf '%s\n' "$effective" | grep -qxF "$setting" || { [ -f "$TMPDIR_WORK/ssh.previous" ] && _write_atomic "$SSH_FILE" "$TMPDIR_WORK/ssh.previous" || rm -f "$SSH_FILE"; _die "SSH setting not effective: $setting"; }; done
    _reload_ssh || { [ -f "$TMPDIR_WORK/ssh.previous" ] && _write_atomic "$SSH_FILE" "$TMPDIR_WORK/ssh.previous" || rm -f "$SSH_FILE"; _die "SSH reload failed; previous managed SSH file restored"; }
    _success "SSH configuration validated and applied"
}
_apply_nftables() {
    command -v nft >/dev/null 2>&1 || { _warn "nft is unavailable; firewall protection skipped"; return 0; }
    if command -v systemctl >/dev/null 2>&1 && { systemctl is-active --quiet ufw || systemctl is-active --quiet firewalld; }; then _warn "UFW or firewalld is active; firewall changes skipped to avoid conflicting control planes"; return 0; fi
    if nft list table inet vps_optimize >/dev/null 2>&1; then nft list table inet vps_optimize | grep -qF 'vps-optimize invalid' || _die "Existing inet vps_optimize table is not owned by this script"; fi
    if [ ! -f "$NFT_SERVICE_STATE" ] && command -v systemctl >/dev/null 2>&1; then systemctl is-enabled --quiet nftables && echo enabled > "$NFT_SERVICE_STATE" || echo disabled > "$NFT_SERVICE_STATE"; fi
    cat > "$TMPDIR_WORK/nft.conf" <<EOF
# Managed by vps-optimize. This chain only drops invalid, malformed, or excessive traffic.
table inet vps_optimize {
  chain input_guard {
    type filter hook input priority filter - 5; policy accept;
    ct state invalid drop comment "vps-optimize invalid"
    tcp flags syn,fin syn,fin drop comment "vps-optimize xmas"
    tcp flags syn,rst syn,rst drop comment "vps-optimize syn-rst"
    ip protocol icmp icmp type echo-request limit rate over 5/second burst 5 packets drop comment "vps-optimize icmp4-rate"
    meta nfproto ipv6 icmpv6 type echo-request limit rate over 5/second burst 5 packets drop comment "vps-optimize icmp6-rate"
    meta nfproto ipv4 tcp flags syn tcp dport != 22 meter syn_rate4 { ip saddr timeout 10s limit rate over ${SYN_RATE}/second burst 400 packets } drop comment "vps-optimize syn4-rate"
    meta nfproto ipv6 tcp flags syn tcp dport != 22 meter syn_rate6 { ip6 saddr timeout 10s limit rate over ${SYN_RATE}/second burst 400 packets } drop comment "vps-optimize syn6-rate"
    meta nfproto ipv4 tcp dport 22 ct state new meter ssh_rate4 { ip saddr timeout 60s limit rate over ${SSH_RATE}/minute burst 20 packets } drop comment "vps-optimize ssh4-rate"
    meta nfproto ipv6 tcp dport 22 ct state new meter ssh_rate6 { ip6 saddr timeout 60s limit rate over ${SSH_RATE}/minute burst 20 packets } drop comment "vps-optimize ssh6-rate"
    meta nfproto ipv4 udp meter udp_rate4 { ip saddr timeout 10s limit rate over ${UDP_RATE}/second burst 400 packets } drop comment "vps-optimize udp4-rate"
    meta nfproto ipv6 udp meter udp_rate6 { ip6 saddr timeout 10s limit rate over ${UDP_RATE}/second burst 400 packets } drop comment "vps-optimize udp6-rate"
  }
}
EOF
    nft -c -f "$TMPDIR_WORK/nft.conf" || _die "nftables syntax validation failed; firewall unchanged"
    nft list table inet vps_optimize > "$TMPDIR_WORK/previous.nft" 2>/dev/null || :
    if [ ! -e "$BASELINE_DIR/vps_optimize.nft" ] && [ ! -e "$BASELINE_DIR/vps_optimize.none" ]; then if [ -s "$TMPDIR_WORK/previous.nft" ]; then cp "$TMPDIR_WORK/previous.nft" "$BASELINE_DIR/vps_optimize.nft"; else : > "$BASELINE_DIR/vps_optimize.none"; fi; fi
    nft delete table inet vps_optimize 2>/dev/null || true
    if ! nft -f "$TMPDIR_WORK/nft.conf"; then [ -s "$TMPDIR_WORK/previous.nft" ] && nft -f "$TMPDIR_WORK/previous.nft" 2>/dev/null || _warn "Previous firewall table could not be restored"; _die "nftables load failed; previous table restore was attempted"; fi
    _write_atomic "$NFT_FILE" "$TMPDIR_WORK/nft.conf"
    if [ ! -f /etc/nftables.conf ]; then printf '%s\ninclude "%s"\n' "$NFT_INCLUDE" "$NFT_FILE" > "$TMPDIR_WORK/nftables.conf"; _write_atomic /etc/nftables.conf "$TMPDIR_WORK/nftables.conf"
    elif ! grep -qF "$NFT_INCLUDE" /etc/nftables.conf; then cp /etc/nftables.conf "$TMPDIR_WORK/nftables.conf"; printf '\n%s\ninclude "%s"\n' "$NFT_INCLUDE" "$NFT_FILE" >> "$TMPDIR_WORK/nftables.conf"; nft -c -f "$TMPDIR_WORK/nftables.conf" || _die "nftables persistence file validation failed"; _write_atomic /etc/nftables.conf "$TMPDIR_WORK/nftables.conf"; fi
    if command -v systemctl >/dev/null 2>&1; then systemctl enable nftables >/dev/null 2>&1 || _warn "nftables service could not be enabled; verify persistence on this distribution"; else _warn "systemctl unavailable; verify nftables persistence manually"; fi
    _success "nftables syntax checked and loaded"
}
_verify() {
    local failed=0
    [ -f "$SYSCTL_FILE" ] || { _error "Missing managed sysctl file"; failed=1; }
    [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" = bbr ] || { _error "BBR is not active"; failed=1; }
    [ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" = fq ] || { _error "fq qdisc is not active"; failed=1; }
    [ -f "$LIMITS_FILE" ] && [ -f "$SYSTEMD_FILE" ] || { _error "nofile configuration is incomplete"; failed=1; }
    if command -v nft >/dev/null 2>&1 && [ -f "$NFT_FILE" ]; then nft list table inet vps_optimize >/dev/null 2>&1 || { _error "Firewall table is missing"; failed=1; }; fi
    if [ -f "$SSH_FILE" ]; then sshd -t -f /etc/ssh/sshd_config || { _error "SSH configuration is invalid"; failed=1; }; fi
    [ "$failed" -eq 0 ] || return 1; _success "Verification passed: managed files, BBR/fq, optional firewall, and SSH"
}
_optimize_all() {
    TMPDIR_WORK=$(mktemp -d); _require sysctl; _require awk; _require sed; _require grep
    _capture_baseline; _detect_hardware; modprobe tcp_bbr 2>/dev/null || true; modprobe nf_conntrack 2>/dev/null || true
    _apply_sysctl; _apply_limits; _apply_modules_and_queue
    _info "Address-family policy unchanged; configure IPv6-only egress in the proxy core"
    _apply_ssh; _apply_nftables; _verify
}
_restore_all() {
    echo "This removes only files managed by this script and restores captured runtime values."
    read -r -p "Confirm restore? (y/N): " confirm < /dev/tty; [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled"; return; }
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE" "$SYSTEMD_FILE" "$MODULE_FILE" "$UDEV_FILE" "$SSH_FILE" "$NFT_FILE"
    if command -v nft >/dev/null 2>&1; then nft delete table inet vps_optimize 2>/dev/null || true; [ -s "$BASELINE_DIR/vps_optimize.nft" ] && nft -f "$BASELINE_DIR/vps_optimize.nft" || true; fi
    if [ -f /etc/nftables.conf ]; then sed -i "\\|$NFT_INCLUDE|d;\\|$NFT_FILE|d" /etc/nftables.conf; fi
    if [ -s "$BASELINE_DIR/vps_optimize.nft" ]; then _write_atomic "$NFT_FILE" "$BASELINE_DIR/vps_optimize.nft"; [ -f /etc/nftables.conf ] && printf '\n%s\ninclude "%s"\n' "$NFT_INCLUDE" "$NFT_FILE" >> /etc/nftables.conf; fi
    if command -v systemctl >/dev/null 2>&1 && [ -f "$NFT_SERVICE_STATE" ] && [ "$(cat "$NFT_SERVICE_STATE")" = disabled ]; then systemctl disable nftables >/dev/null 2>&1 || _warn "Could not restore disabled nftables service state"; fi
    sysctl --system >/dev/null 2>&1 || _warn "sysctl --system reported unsupported distribution keys"; _restore_sysctl_values "$BASELINE_DIR/managed-runtime-sysctl"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reexec || true; command -v udevadm >/dev/null 2>&1 && udevadm control --reload-rules || true
    if [ -f /etc/ssh/sshd_config ]; then sshd -t -f /etc/ssh/sshd_config && _reload_ssh || _warn "SSH reload skipped because validation failed"; fi
    _success "Managed files removed. Baseline retained at $BASELINE_DIR"
}
clear
echo -e "${CYAN}VPS Network Optimization and Safe Restore${NC}"
echo "1) Apply managed optimization"; echo "2) Restore managed changes"; echo "3) Reboot VPS"
read -r -p "Select [1/2/3]: " choice < /dev/tty
case "$choice" in
  1) _optimize_all ;;
  2) _restore_all ;;
  3) read -r -p "Confirm reboot? (y/N): " yes < /dev/tty; [[ "$yes" =~ ^[Yy]$ ]] && { _info "Rebooting in 3 seconds"; sleep 3; reboot; } ;;
  *) _die "Invalid option" ;;
esac
