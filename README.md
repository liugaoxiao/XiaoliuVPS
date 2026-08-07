# XiaoliuVPS

面向 Debian/Ubuntu VPS 的 sing-box 节点管理与动态网络优化脚本。

项目包含：

- `singbox.sh`：节点创建、配置管理、服务管理、订阅信息和脚本更新。
- `optimize.sh`：基于实际 CPU 和内存的 BBR/FQ 网络优化。

## 快速安装

以 root 身份执行：

```bash
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/singbox.sh -o /tmp/singbox.sh
bash /tmp/singbox.sh
```

安装完成后可使用快捷命令：

```bash
x6
```

## 主菜单

- `13`：从本仓库更新 `singbox.sh`。
- `20`：打开动态网络优化工具。
- 节点管理：创建、删除、查看和重启 sing-box 节点。

更新主脚本：

```bash
x6
# 选择 13
```

应用网络优化：

```bash
x6
# 选择 20，再选择 1
```

## 动态网络优化

`optimize.sh` 不使用固定的 64MB 参数，而是读取 `/proc/meminfo` 的实际 `MemTotal`：

| 实际内存 | TCP 最大缓冲区 |
| --- | ---: |
| 小于 512MB | 8MB |
| 512MB 至小于 1GB | 32MB |
| 1GB 及以上 | 64MB |

根据 CPU 核数还会调整网络设备接收队列；2 核及以上且网卡支持时，尝试启用 RPS/RFS 多核收包分发。

包含的网络参数和功能：

- BBR 拥塞控制与 FQ 队列调度。
- TCP/UDP 缓冲区、连接队列和本地端口范围优化。
- TCP Fast Open、SYN cookies、MTU 探测和连接回收优化。
- TCP keepalive、`tcp_retries2`、`tcp_notsent_lowat` 等连接稳定性参数。
- 内核支持时启用动态 conntrack 容量。
- 文件句柄上限和 BBR 模块开机加载。
- sysctl 应用失败时恢复运行时参数和本脚本上一次的配置文件。

普通公网 VPS 和提供商 NAT VPS 使用同一套优化逻辑。NAT VPS 仍按普通 VPS 创建节点，网络优化不会修改其端口映射或提供商网络策略。

## 安全边界

优化脚本只管理以下文件：

```text
/etc/sysctl.d/90-xiaoliu-vps-optimize.conf
/etc/security/limits.d/90-xiaoliu-vps-optimize.conf
/etc/systemd/system.conf.d/90-xiaoliu-vps-optimize.conf
/etc/modules-load.d/xiaoliu-vps-optimize.conf
```

它不会：

- 覆盖 `/etc/sysctl.conf`。
- 默认开启 IPv4/IPv6 转发或 `route_localnet`。
- 添加 nftables/iptables 防火墙规则、MSS Clamp 或全局 UDP/SYN 限速。
- 自动修改 SSH、DNS、ICMP 或系统登录策略。

Reality、TLS、Hysteria2 TLS 和可选端口跳跃等协议层配置由 `singbox.sh` 管理；它们不等于主机防火墙、SSH 密钥认证或服务商 DDoS 防护。

## 恢复优化配置

运行：

```bash
x6
# 选择 20，再选择 3
```

这会删除本工具管理的持久化文件并尝试重载系统配置，同时恢复脚本保存的 RPS/RFS 网卡队列值。已有的其他 sysctl、节点配置和防火墙规则不会由恢复菜单删除。

## 兼容性

建议使用 Debian 11/12 或 Ubuntu LTS，并以 root 运行。脚本会检测 BBR、conntrack 和网卡 RPS/RFS 支持；不支持的可选内核功能会跳过，不会因此强行修改系统。

## 免责声明

网络优化效果取决于 VPS CPU、内存、虚拟化类型、线路质量、拥塞情况、客户端和服务商限制。BBR/FQ 等参数不能修复 NAT 端口映射、代理出口 IP、IPv6 泄漏或端到端路由问题。

## 文件

- [`singbox.sh`](./singbox.sh)：sing-box 节点管理脚本。
- [`optimize.sh`](./optimize.sh)：动态网络优化脚本。
