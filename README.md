# VPS 一键优化 + 安全隐匿

整合 Wyatt/vps-netpilot/kejilion 的网络优化方案 + 安全隐匿加固，一键完成。

## 快速使用

```bash
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/optimize.sh | bash
```

## 优化内容

### 网络性能 (sysctl 38项)
- BBR 拥塞控制 + fq 队列
- TCP/UDP 缓冲区 64MB
- 连接队列 somaxconn=65535
- TCP Fast Open + fin_timeout=15s
- conntrack 连接跟踪调优
- TCP Keepalive 死连接检测
- 文件描述符 nofile=1048576 (limits.conf + systemd)
- IPv4 优先解析 gai.conf

### 安全隐匿
- **ICMP 隐藏** — 关闭 ping 回复，防主机探测
- **防流量劫持** — 关闭 ICMP 重定向 + 源路由
- **内核加固** — 隐藏内核指针(kptr_restrict=2) + 限制 dmesg
- **TCP 防指纹** — rp_filter=1 + log_martians
- **SSH 加固** — MaxAuthTries=3 + 禁空密码 + 禁X11/转发 + 隐藏 Banner

### 防火墙 (nftables)
- MSS Clamp 自动 MTU 适配
- 无效连接丢弃 + 已建立连接快速放行
- SYN/UDP/ICMP 洪水限速
- SSH 暴力破解防护 (4次/分钟)
- XMAS/SYN-RST 扫描拦截
- 新连接速率限制 (200/秒)
- 分片包丢弃

## 运行命令

```bash
# 直接运行
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/optimize.sh -o optimize.sh
chmod +x optimize.sh
sudo bash optimize.sh

# 一键管道
curl -LfsS https://raw.githubusercontent.com/liugaoxiao/XiaoliuVPS/main/optimize.sh | sudo bash
```

## 参数来源

| 模块 | 来源 |
|------|------|
| BBR + fq + TCP 缓冲区 | Wyatt |
| Conntrack + 虚拟内存 + file-max | vps-netpilot |
| somaxconn + SynCookies + gai.conf + nofile | kejilion/sh |
| MSS Clamp + DDoS 防护 | vps-netpilot |
| ICMP 隐藏 + 内核加固 + SSH 加固 | 安全最佳实践 |
