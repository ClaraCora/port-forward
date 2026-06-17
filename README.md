# port-forward-nft

GitHub: <https://github.com/ClaraCora/port-forward>

一个基于 **nftables 原生管理** 的交互式端口转发脚本，适合 Debian / Ubuntu / 其他已使用 `nf_tables` 的 Linux 服务器。

脚本使用独立的 `inet port_forward` 表，只管理自己创建的规则，避免误删系统里已有的 nftables 规则。

---

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ClaraCora/port-forward/main/port-forward-nft.sh)
```

## 下载后运行

```bash
curl -fsSL -o port-forward-nft.sh https://raw.githubusercontent.com/ClaraCora/port-forward/main/port-forward-nft.sh
chmod +x port-forward-nft.sh
sudo ./port-forward-nft.sh
```

---

## 主要功能

- 添加 TCP / UDP / TCP+UDP 端口转发
- 查看脚本管理的 nftables 规则和简洁摘要
- 按本机监听端口删除对应转发规则
- 一键清空脚本管理的 `inet port_forward` 表
- 将当前脚本规则写入 `/etc/nftables.conf` 持久化
- 修复关键转发 sysctl 项
- 可选执行 BBR 和网络参数优化
- 自动备份 `/etc/sysctl.conf` 与 `/etc/nftables.conf`

---

## 新版菜单

菜单按用途分组，并会在主菜单下方显示当前转发摘要。查看规则时默认展示简洁表格，原始 nftables 规则可按需展开：

```text
规则管理
	1) 添加端口转发
	2) 查看规则与摘要
	3) 删除指定本机端口
	4) 清空脚本管理规则

系统与持久化
	5) 写入 nftables.conf 持久化
	6) 修复转发 sysctl
	7) 网络参数优化（BBR）

	0) 退出
```

添加规则时会依次询问：

- 本机监听端口
- 目标 IPv4 地址
- 目标端口
- 协议：`tcp`、`udp` 或 `both`

确认后脚本会写入 DNAT、MASQUERADE 和 FORWARD 放行规则。

查看规则的默认输出类似：

```text
序号 本机端口     目标                   协议
---- ------------ ---------------------- ----------
1    42257        172.93.219.76:42257    both
```

---

## 适用场景

- VPS / 云服务器端口映射
- 中转机、跳板机、前置转发节点
- TCP / UDP 游戏、服务、代理流量转发
- 已使用 `iptables v1.8.x (nf_tables)` 或原生 nftables 的系统

检查系统后端：

```bash
iptables --version
```

如果输出类似下面内容，说明系统底层已经是 nftables：

```text
iptables v1.8.9 (nf_tables)
```

---

## 规则模型

脚本创建并管理：

```text
table inet port_forward
```

包含三条链：

- `prerouting`：处理入口 DNAT
- `postrouting`：处理出口 MASQUERADE
- `forward`：放行转发流量

每组规则都会带有类似下面的注释，删除和摘要都依赖该标记：

```text
pf:tcp:本机端口:目标IP:目标端口
```

---

## 持久化说明

运行时添加的 nftables 规则默认立即生效，但重启后可能丢失。

如需重启后保留规则，请在菜单中执行：

```text
5) 写入 nftables.conf 持久化
```

脚本会：

1. 备份当前 `/etc/nftables.conf` 到 `/etc/port-forward/`
2. 替换脚本专属的托管配置块
3. 使用 `nft -f /etc/nftables.conf` 验证配置
4. 验证失败时自动恢复备份

建议确认 nftables 服务已启用：

```bash
sudo systemctl enable nftables
```

---

## sysctl 与优化

菜单中的 `修复转发 sysctl` 只写入关键转发项：

- `net.ipv4.ip_forward = 1`
- `net.ipv4.conf.all.forwarding = 1`
- `net.ipv4.conf.default.forwarding = 1`
- `net.ipv6.conf.all.forwarding = 1`
- `net.ipv6.conf.default.forwarding = 1`

菜单中的 `网络参数优化（BBR）` 会先识别当前系统，再让你选择对应配置：

- `Debian 12 通用优化`
- `Debian 13 推荐优化`
- `Ubuntu 24.04 推荐优化`

脚本会默认推荐与当前系统匹配的配置；如果系统不在这三类中，也可以手动选择其中一套。运行时会自动加载对应的 `sysctl` 配置块，不支持的项会被跳过，不会中断脚本。

---

## 安全边界

- 仅管理 `inet port_forward` 表，不会主动清空其他 nftables 表
- 删除指定端口时，只删除带 `pf:` 注释且匹配该本机端口的规则
- 清空规则时，只删除脚本创建的整张 `inet port_forward` 表
- 修改系统配置前会创建备份文件

备份目录：

```text
/etc/port-forward/
```

---

## 常见问题

### 添加规则后外部仍无法访问？

请检查：

- 云厂商安全组是否放行本机监听端口
- 服务器本机防火墙是否允许该端口
- 目标 IP 和目标端口是否可达
- 是否已开启 IPv4 转发

### 重启后规则消失？

请执行菜单 `5) 写入 nftables.conf 持久化`，并确保 `nftables` 服务已启用。

### 会影响我已有的 nftables 规则吗？

脚本只管理 `inet port_forward` 表。持久化时也只替换 `/etc/nftables.conf` 中脚本托管标记之间的内容。

### 适合 iptables 传统后端吗？

不推荐。本脚本面向 nftables 原生环境。如果系统仍使用 legacy iptables，请使用仓库中的 `port-forward.sh` 或先迁移到 nftables。
