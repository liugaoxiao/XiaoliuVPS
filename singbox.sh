#!/bin/bash

# 基础路径定义
export SCRIPT_VERSION="20"
export DEFAULT_SNI="www.amd.com"
export WS_EARLY_DATA_SIZE="2560"
export WS_EARLY_DATA_HEADER="Sec-WebSocket-Protocol"
SELF_SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SELF_SCRIPT_PATH")"
SINGBOX_DIR="/usr/local/etc/sing-box"
MANAGED_SCRIPT_PATH="/usr/local/lib/singbox-lite/singbox.sh"
MAIN_PANEL_COMMAND="/usr/local/bin/x6"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main"
SCRIPT_UPDATE_URL="${GITHUB_RAW_BASE}/singbox.sh"

# 注入 sing-box 1.12+ 废弃配置兼容环境变量 (用于脚本内嵌的前台命令调用，如 check/generate)
export ENABLE_DEPRECATED_LEGACY_DNS_SERVERS="true"
export ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM="true"
export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER="true"

# --- 核心工具函数 ---

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
ORANGE='\033[0;33m'

# 打印消息函数
_info() { echo -e "${CYAN}[信息] $1${NC}" >&2; }
_success() { echo -e "${GREEN}[成功] $1${NC}" >&2; }
_warn() { echo -e "${YELLOW}[注意] $1${NC}" >&2; }
_warning() { _warn "$1"; } # 别名兼容
_error() { echo -e "${RED}[错误] $1${NC}" >&2; }

# 检查 root 权限
_check_root() {
    if [[ $EUID -ne 0 ]]; then
        _error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

_install_main_panel_command() {
    local source_path="$SELF_SCRIPT_PATH"
    local temp_path="${MANAGED_SCRIPT_PATH}.tmp.$$"

    mkdir -p "$(dirname "$MANAGED_SCRIPT_PATH")"
    if [ -f "$source_path" ] && [ -r "$source_path" ] && grep -q '^export SCRIPT_VERSION=' "$source_path"; then
        cp "$source_path" "$temp_path"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$temp_path" "${SCRIPT_UPDATE_URL}?v=$(date +%s)" || true
    else
        _warn "无法安装 x6 快捷命令：当前脚本来自管道且 wget 不可用"
        return 0
    fi

    if [ ! -s "$temp_path" ] || ! head -n 1 "$temp_path" | grep -q '^#!/bin/bash' || ! grep -q '^export SCRIPT_VERSION=' "$temp_path" || ! bash -n "$temp_path" 2>/dev/null; then
        rm -f "$temp_path"
        _warn "无法安装 x6 快捷命令：脚本文件校验失败"
        return 0
    fi

    chmod 0755 "$temp_path"
    mv -f "$temp_path" "$MANAGED_SCRIPT_PATH"
    cat > "$MAIN_PANEL_COMMAND" <<'EOF'
#!/bin/sh
exec /bin/bash /usr/local/lib/singbox-lite/singbox.sh "$@"
EOF
    chmod 0755 "$MAIN_PANEL_COMMAND"
}

# 编解码器 (纯 Bash 稳健实现)
_url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
}
_url_encode() {
    # [修复] 使用 jq 内建 @uri 过滤器，完美处理 UTF-8 多字节字符
    # jq 是必装依赖，@uri 以字节为单位执行标准 percent-encoding
    printf '%s' "$1" | jq -sRr @uri
}

_ws_path_with_early_data() {
    local ws_path="${1:-/}"
    if [[ "$ws_path" == *"ed="* ]]; then
        printf '%s' "$ws_path"
        return
    fi
    if [[ "$ws_path" == *"?"* ]]; then
        printf '%s&ed=%s' "$ws_path" "$WS_EARLY_DATA_SIZE"
    else
        printf '%s?ed=%s' "$ws_path" "$WS_EARLY_DATA_SIZE"
    fi
}

_cert_sha256_hex() {
    local cert_path="$1"
    [ -f "$cert_path" ] || return 1
    openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | \
        awk -F= 'NR==1 { gsub(":", "", $2); print tolower($2) }'
}

_tls_insecure_params() {
    local skip_verify="$1"
    local cert_path="$2"
    local insecure_param=""
    if [[ "$skip_verify" == "true" ]]; then
        insecure_param="&insecure=1"
        local cert_pcs=$(_cert_sha256_hex "$cert_path")
        [ -n "$cert_pcs" ] && insecure_param="${insecure_param}&pcs=${cert_pcs}"
    fi
    printf '%s' "$insecure_param"
}

_append_pcs_to_tls_link() {
    local url="$1"
    local cert_path="$2"
    [ -n "$url" ] || return 0
    [[ "$url" == *"pcs="* ]] && { printf '%s' "$url"; return 0; }

    local cert_pcs=$(_cert_sha256_hex "$cert_path")
    [ -n "$cert_pcs" ] || { printf '%s' "$url"; return 0; }

    local body="$url"
    local fragment=""
    if [[ "$url" == *"#"* ]]; then
        body="${url%%#*}"
        fragment="#${url#*#}"
    fi

    local sep="&"
    [[ "$body" != *"?"* ]] && sep="?"
    printf '%s%s%s%s' "$body" "$sep" "pcs=${cert_pcs}" "$fragment"
}

_ss_base64_encode() {
    # Shadowsocks SIP002 规范要求 Base64 编码不带填充 (No Padding)
    printf '%s' "$1" | base64 | tr -d '\n\r ' | sed 's/=//g'
}

# 公网 IP 获取 (带全局缓存)
_get_public_ip() {
    [ -n "$server_ip" ] && [ "$server_ip" != "null" ] && { echo "$server_ip"; return; }
    local ip=$(timeout 5 curl -s4 --max-time 2 icanhazip.com 2>/dev/null || timeout 5 curl -s4 --max-time 2 ipinfo.io/ip 2>/dev/null)
    [ -z "$ip" ] && ip=$(timeout 5 curl -s6 --max-time 2 icanhazip.com 2>/dev/null || timeout 5 curl -s6 --max-time 2 ipinfo.io/ip 2>/dev/null)
    server_ip="$ip"
    echo "$ip"
}
_get_ip() { _get_public_ip; } # 别名兼容

# 系统环境检测
_detect_init_system() {
    if [ -f /sbin/openrc-run ] || command -v rc-service &>/dev/null; then
        export INIT_SYSTEM="openrc"
        export SERVICE_FILE="/etc/init.d/sing-box"
    elif command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        export INIT_SYSTEM="systemd"
        export SERVICE_FILE="/etc/systemd/system/sing-box.service"
    else
        export INIT_SYSTEM="direct"
        export SERVICE_FILE=""
    fi
}

# 端口占用检查
_check_port_occupied() {
    local port=$1
    local proto=${2:-tcp}
    if [[ "$proto" == "tcp" ]]; then
        if command -v ss &>/dev/null; then
            ss -lnpt | grep -q ":${port} " && return 0
        else
            netstat -lnpt | grep -q ":${port} " && return 0
        fi
    else
        if command -v ss &>/dev/null; then
            ss -lnpu | grep -q ":${port} " && return 0
        else
            netstat -lnpu | grep -q ":${port} " && return 0
        fi
    fi
    return 1
}

_is_pid_running_cmd() {
    local pid="$1"
    local pattern="$2"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then
        tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq "$pattern"
    else
        ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$pattern"
    fi
}

_is_pid_file_running_cmd() {
    local pid_file="$1"
    local pattern="$2"
    local pid
    [ -s "$pid_file" ] || return 1
    pid=$(cat "$pid_file" 2>/dev/null)
    _is_pid_running_cmd "$pid" "$pattern"
}

# 配置文件端口扫描 (预检是否已被本程序占用)
_check_port_in_config() {
    local port=$1
    [ ! -f "$CONFIG_FILE" ] && return 1
    jq -e ".inbounds[] | select(.listen_port == ($port|tonumber))" "$CONFIG_FILE" >/dev/null 2>&1
}

# 综合端口碰撞检测
_check_port_conflict() {
    local port=$1
    local proto=${2:-tcp}
    local silent=${3:-false}
    if _check_port_in_config "$port"; then
        [ "$silent" != "true" ] && _error "端口 ${port} 已在 sing-box 配置文件中被占用。"
        return 0
    fi
    if _check_port_occupied "$port" "$proto"; then
        [ "$silent" != "true" ] && _error "端口 ${port} 已被系统其他程序占用。"
        return 0
    fi
    if [[ "$proto" == "udp" ]]; then
        local hop_conflict
        hop_conflict=$(_find_udp_hop_conflict_in_range "$port" "$port")
        if [ -n "$hop_conflict" ]; then
            local c_tag c_name c_range c_mode
            IFS=$'\t' read -r c_tag c_name c_range c_mode <<< "$hop_conflict"
            [ "$silent" != "true" ] && _error "UDP 端口 ${port} 落在已有 HY2 端口跳跃范围 ${c_range} 内（${c_name}, ${c_tag}, ${c_mode}）。"
            return 0
        fi
    fi
    return 1
}

_find_pf_udp_conflict_in_range() {
    local start="$1" end="$2"
    local pf_meta="${SINGBOX_DIR}/relay_pf.json"
    [ -f "$pf_meta" ] || return 1
    jq -r --argjson start "$start" --argjson end "$end" '
        to_entries[]
        | (.key | tonumber?) as $port
        | select($port != null and $port >= $start and $port <= $end)
        | select(.value.network == "udp" or .value.network == "tcp+udp")
        | [
            .key,
            (.value.name // "端口转发"),
            (.value.network_display // .value.network // "UDP"),
            ((.value.target_addr // "") + ":" + ((.value.target_port // "") | tostring))
          ]
        | @tsv
    ' "$pf_meta" 2>/dev/null | head -n 1
}

_find_udp_hop_conflict_in_range() {
    local start="$1" end="$2" exclude_tag="${3:-}"
    local conflict=""
    if [ -f "$METADATA_FILE" ]; then
        conflict=$(jq -r --argjson start "$start" --argjson end "$end" --arg exclude "$exclude_tag" '
            to_entries[]
            | select(.key != $exclude)
            | select(.value.portHopping)
            | (.value.portHopping | capture("^(?<start>[0-9]+)-(?<end>[0-9]+)$")?) as $range
            | select($range != null)
            | ($range.start | tonumber) as $other_start
            | ($range.end | tonumber) as $other_end
            | select($start <= $other_end and $end >= $other_start)
            | [
                .key,
                (.value.name // .key),
                .value.portHopping,
                ("主HY2/" + (.value.portHoppingMode // "unknown"))
              ]
            | @tsv
        ' "$METADATA_FILE" 2>/dev/null | head -n 1)
        [ -n "$conflict" ] && { echo "$conflict"; return 0; }
    fi

    local relay_links="${SINGBOX_DIR}/relay_links.json"
    if [ -f "$relay_links" ]; then
        conflict=$(jq -r --argjson start "$start" --argjson end "$end" --arg exclude "$exclude_tag" '
            to_entries[]
            | select(.key != $exclude)
            | select(.value.port_hopping)
            | (.value.port_hopping | capture("^(?<start>[0-9]+)-(?<end>[0-9]+)$")?) as $range
            | select($range != null)
            | ($range.start | tonumber) as $other_start
            | ($range.end | tonumber) as $other_end
            | select($start <= $other_end and $end >= $other_start)
            | [
                .key,
                (.value.node_name // .key),
                .value.port_hopping,
                "中转HY2/nftables"
              ]
            | @tsv
        ' "$relay_links" 2>/dev/null | head -n 1)
        [ -n "$conflict" ] && { echo "$conflict"; return 0; }
    fi

    return 1
}

# nftables 规则管理 (独立表，避免污染系统其他防火墙规则)
export NFT_TABLE="singboxlite"
export NFT_PERSIST_FILE="/etc/nftables.d/singboxlite.nft"

_nft_ensure_base() {
    command -v nft &>/dev/null || return 1
    nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || nft add table inet "$NFT_TABLE" >/dev/null 2>&1 || return 1
    nft list chain inet "$NFT_TABLE" prerouting >/dev/null 2>&1 || nft add chain inet "$NFT_TABLE" prerouting '{ type nat hook prerouting priority -100; policy accept; }' >/dev/null 2>&1 || retur[...]
