# port-forward-nft

GitHub: <https://github.com/ClaraCora/port-forward>

一个基于 **nftables 原生管理** 的交互式端口转发脚本，适合 Debian / Ubuntu / 其他已使用 `nf_tables` 的 Linux 服务器。

---

## Quick Run

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ClaraCora/port-forward/main/port-forward-nft.sh)
```

## Download and Run

```bash
curl -fsSL -o port-forward-nft.sh https://raw.githubusercontent.com/ClaraCora/port-forward/main/port-forward-nft.sh && chmod +x port-forward-nft.sh && sudo ./port-forward-nft.sh
```

---

## 功能列表

- 添加端口转发
- 查看本脚本管理的 nftables 规则
- 删除指定本机端口的转发规则
- 卸载本脚本管理的全部规则
- 优化系统参数（BBR + 网络优化）
- 修复 `/etc/sysctl.conf`（仅修关键转发项）
- 写入 `/etc/nftables.conf` 持久化

---

## 适用场景

- 端口转发 / 端口映射
- 中转机 / 穿透机
- TCP / UDP 代理转发前置机
- 使用 `iptables v1.8.x (nf_tables)` 或已原生使用 nftables 的 VPS

---

## 推荐环境

如果你的系统执行：

```bash
iptables --version
```

输出类似：

```bash
iptables v1.8.9 (nf_tables)
```

说明系统底层已经是 nftables，推荐优先使用这个版本。
