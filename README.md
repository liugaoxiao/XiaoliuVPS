# VPS 一键优化脚本

整合 Wyatt/vps-netpilot/kejilion 的网络优化方案，一键优化 VPS 网络性能。

## 快速使用

```bash
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/optimize.sh | bash
```

## 优化内容

### sysctl 参数 (35项)
- **BBR 拥塞控制** — tcp_congestion_control=bbr, qdisc=fq
- **TCP 缓冲区** — rmem/wmem 64MB
- **连接队列** — somaxconn=65535, tcp_max_syn_backlog=16384
- **TCP 快速恢复** — tcp_fastopen=3, tcp_fin_timeout=15s, tcp_tw_reuse=1
- **连接跟踪** — nf_conntrack_max=131072, 含 last_ack 优化
- **文件描述符** — file-max=6815744
- **IPv4/IPv6 转发** — 支持代理/隧道
- **虚拟内存** — swappiness=10, overcommit_memory=1

### 非 sysctl 操作
- **MSS Clamp** — nftables 自动设置 MSS MTU
- **DDoS 防护** — SYN/UDP/ICMP 速率限制 + XMAS/SYN-RST 扫描拦截
- **文件描述符限制** — limits.conf + systemd DefaultLimitNOFILE
- **IPv4 优先解析** — gai.conf precedence
- **内核模块** — tcp_bbr + nf_conntrack 开机加载
- **依赖安装** — 自动安装 nftables 等缺失依赖

## 运行命令

```bash
# 方法一: 直接运行
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/optimize.sh -o optimize.sh
chmod +x optimize.sh
sudo bash optimize.sh

# 方法二: 一键管道
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/optimize.sh | sudo bash
```

## 参数来源

| 参数 | 来源 |
|------|------|
| BBR + fq + TCP 缓冲区 + Fast Open | Wyatt |
| Conntrack + 虚拟内存 + file-max | vps-netpilot |
| somaxconn + SynCookies + gai.conf + nofile | kejilion/sh |
| MSS Clamp + DDoS 防护 | vps-netpilot |
