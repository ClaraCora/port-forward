#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================
# nftables 端口转发管理工具（原生重构版）
# 功能：添加/查看/删除脚本管理的 TCP/UDP 转发规则
# 额外：
# - 修复 /etc/sysctl.conf（仅更新需要的项，不重复追加）
# - 将当前 inet port_forward 表写入 /etc/nftables.conf 持久化
# 说明：
# - 使用独立 nft table: inet port_forward
# - 仅管理本脚本创建的规则，避免误伤现有规则
# - sysctl 修复仅修改指定键，存在则替换，不存在则添加
# =========================================

SCRIPT_TABLE_FAMILY="inet"
SCRIPT_TABLE_NAME="port_forward"
SYSCTL_FILE="/etc/sysctl.conf"
SYSCTL_BACKUP_DIR="/etc/port-forward"
NFTABLES_CONF="/etc/nftables.conf"
NFTABLES_CONF_BACKUP_DIR="/etc/port-forward"
BEGIN_MARK="# BEGIN managed by port-forward-nft"
END_MARK="# END managed by port-forward-nft"

banner() {
  echo "========================================="
  echo "   🔁 NFTABLES 原生端口转发管理工具"
  echo "========================================="
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "❌ 请使用 root 权限运行：sudo $0"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ensure_nft() {
  if command_exists nft; then
    return 0
  fi

  echo "⚠️ 未检测到 nft 命令"
  read -r -p "是否尝试自动安装 nftables？(y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0

  if command_exists apt; then
    apt update && apt install -y nftables
  elif command_exists dnf; then
    dnf install -y nftables
  elif command_exists yum; then
    yum install -y nftables
  else
    echo "❌ 无法自动安装，请手动安装 nftables"
    exit 1
  fi
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_valid_ipv4() {
  local ip="$1"
  local IFS=.
  local -a octets
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

get_default_iface() {
  ip route show default 2>/dev/null | awk '{print $5}' | head -n1
}

get_primary_ip() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 0
  ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

ensure_table_and_chains() {
  nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" >/dev/null 2>&1 || nft add table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME"

  nft list chain "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" prerouting >/dev/null 2>&1 || \
    nft add chain "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" prerouting '{ type nat hook prerouting priority dstnat; policy accept; }'

  nft list chain "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" postrouting >/dev/null 2>&1 || \
    nft add chain "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'

  nft list chain "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" forward >/dev/null 2>&1 || \
    nft add chain "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" forward '{ type filter hook forward priority filter; policy accept; }'
}

sysctl_backup() {
  mkdir -p "$SYSCTL_BACKUP_DIR"
  local backup_file="$SYSCTL_BACKUP_DIR/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
  cp "$SYSCTL_FILE" "$backup_file"
  echo "$backup_file"
}

nftables_conf_backup() {
  mkdir -p "$NFTABLES_CONF_BACKUP_DIR"
  local backup_file="$NFTABLES_CONF_BACKUP_DIR/nftables.conf.backup.$(date +%Y%m%d_%H%M%S)"
  cp "$NFTABLES_CONF" "$backup_file"
  echo "$backup_file"
}

set_sysctl_key() {
  local key="$1"
  local value="$2"

  touch "$SYSCTL_FILE"
  if grep -Eq "^[[:space:]]*${key//./\.}[[:space:]]*=" "$SYSCTL_FILE"; then
    sed -i -E "s|^[[:space:]]*${key//./\\.}[[:space:]]*=.*$|${key} = ${value}|" "$SYSCTL_FILE"
  else
    printf '\n%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
  fi
}

apply_sysctl_keys() {
  while (( "$#" )); do
    local key="$1"
    local value="$2"
    shift 2
    set_sysctl_key "$key" "$value"
    sysctl -w "$key=$value" >/dev/null
  done
}

repair_sysctl_flow() {
  echo "========================================="
  echo "   🛠 修复 /etc/sysctl.conf（定向更新）"
  echo "========================================="
  echo "将仅修复以下关键项："
  echo "  • net.ipv4.ip_forward"
  echo "  • net.ipv4.conf.all.forwarding"
  echo "  • net.ipv4.conf.default.forwarding"
  echo "  • net.ipv6.conf.all.forwarding"
  echo "  • net.ipv6.conf.default.forwarding"
  echo
  read -r -p "是否继续？(y/n): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "❎ 已取消"; return; }

  local backup_file
  backup_file=$(sysctl_backup)
  echo "📦 已备份到：$backup_file"

  apply_sysctl_keys \
    net.ipv4.ip_forward 1 \
    net.ipv4.conf.all.forwarding 1 \
    net.ipv4.conf.default.forwarding 1 \
    net.ipv6.conf.all.forwarding 1 \
    net.ipv6.conf.default.forwarding 1

  echo "✅ /etc/sysctl.conf 已修复（仅更新指定项）"
}

optimize_system_flow() {
  echo "========================================="
  echo "   ⚡ 系统网络参数优化（nftables 版）"
  echo "========================================="
  echo "此操作会更新指定 sysctl 键，不会反复追加整段配置。"
  echo
  read -r -p "是否继续优化？(y/n): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "❎ 已取消优化"; return; }

  local backup_file
  backup_file=$(sysctl_backup)
  echo "📦 已备份 sysctl.conf 到：$backup_file"

  if modprobe tcp_bbr 2>/dev/null; then
    echo "✅ 已加载 tcp_bbr 模块"
  else
    echo "⚠️ 未能加载 tcp_bbr；若内核不支持，BBR 可能不会生效"
  fi

  apply_sysctl_keys \
    fs.file-max 6815744 \
    net.ipv4.tcp_max_syn_backlog 8192 \
    net.core.somaxconn 8192 \
    net.ipv4.tcp_tw_reuse 1 \
    net.core.default_qdisc fq \
    net.ipv4.tcp_congestion_control bbr \
    net.ipv4.tcp_no_metrics_save 1 \
    net.ipv4.tcp_ecn 0 \
    net.ipv4.tcp_mtu_probing 1 \
    net.ipv4.tcp_rfc1337 1 \
    net.ipv4.tcp_sack 1 \
    net.ipv4.tcp_fack 1 \
    net.ipv4.tcp_window_scaling 1 \
    net.ipv4.tcp_adv_win_scale 2 \
    net.ipv4.tcp_moderate_rcvbuf 1 \
    net.ipv4.tcp_fin_timeout 30 \
    net.ipv4.tcp_rmem "4096 87380 67108864" \
    net.ipv4.tcp_wmem "4096 65536 67108864" \
    net.core.rmem_max 67108864 \
    net.core.wmem_max 67108864 \
    net.ipv4.udp_rmem_min 8192 \
    net.ipv4.udp_wmem_min 8192 \
    net.ipv4.ip_local_port_range "1024 65535" \
    net.ipv4.tcp_timestamps 1 \
    net.ipv4.conf.all.rp_filter 0 \
    net.ipv4.conf.default.rp_filter 0 \
    net.ipv4.ip_forward 1 \
    net.ipv4.conf.all.forwarding 1 \
    net.ipv4.conf.default.forwarding 1 \
    net.ipv6.conf.all.forwarding 1 \
    net.ipv6.conf.default.forwarding 1 \
    net.ipv4.conf.all.route_localnet 1

  echo "✅ 系统优化完成"
  echo "  • BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "  • IPv4 转发: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  echo "  • qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
}

list_rules_flow() {
  ensure_table_and_chains
  echo "========================================="
  echo "当前规则表：${SCRIPT_TABLE_FAMILY} ${SCRIPT_TABLE_NAME}"
  echo "========================================="
  nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME"
  echo "-----------------------------------------"
  show_rules_summary
  echo "========================================="
}

add_rule_unique() {
  local family="$1" table="$2" chain="$3" expr="$4"
  if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -Fq -- "$expr"; then
    nft add rule "$family" "$table" "$chain" $expr
  fi
}

has_managed_rule_entries() {
  nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | grep -Eq 'comment "pf:(tcp|udp):'
}

show_rules_summary() {
  local rules
  rules=$(nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | grep -E 'comment "pf:(tcp|udp):' || true)
  if [[ -z "$rules" ]]; then
    echo "当前还没有任何转发条目，只创建了基础表和链。"
    return 0
  fi

  echo "转发摘要："
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local comment
    comment=$(sed -n 's/.*comment "\([^"]*\)".*/\1/p' <<< "$line")
    if [[ "$comment" =~ ^pf:(tcp|udp):([0-9]+):([0-9.]+):([0-9]+)$ ]]; then
      echo "- ${BASH_REMATCH[2]} -> ${BASH_REMATCH[3]}:${BASH_REMATCH[4]} (${BASH_REMATCH[1]})"
    fi
  done <<< "$rules"
}

add_forwarding_flow() {
  ensure_table_and_chains

  local src_port dst_ip dst_port proto_choice iface host_ip
  read -r -p "请输入本机端口: " src_port
  read -r -p "请输入目标 IP: " dst_ip
  read -r -p "请输入目标端口: " dst_port
  read -r -p "协议 [tcp/udp/both，默认 both]: " proto_choice

  src_port=$(trim "$src_port")
  dst_ip=$(trim "$dst_ip")
  dst_port=$(trim "$dst_port")
  proto_choice=$(trim "$proto_choice")
  [[ -n "$proto_choice" ]] || proto_choice="both"

  if [[ -z "$src_port" || -z "$dst_ip" || -z "$dst_port" ]]; then
    echo "❌ 输入不能为空"
    return
  fi
  if ! is_valid_port "$src_port"; then
    echo "❌ 本机端口无效，必须为 1-65535"
    return
  fi
  if ! is_valid_port "$dst_port"; then
    echo "❌ 目标端口无效，必须为 1-65535"
    return
  fi
  if ! is_valid_ipv4 "$dst_ip"; then
    echo "❌ 目标 IPv4 地址无效"
    return
  fi
  case "$proto_choice" in
    tcp|udp|both) ;;
    *) echo "❌ 协议无效，仅支持 tcp / udp / both"; return ;;
  esac

  iface=$(get_default_iface)
  if [[ -z "$iface" ]]; then
    echo "❌ 无法检测默认网卡"
    return
  fi
  host_ip=$(get_primary_ip "$iface")
  echo "📡 默认网卡: $iface${host_ip:+  (本机 IPv4: $host_ip) }"

  local protos=( )
  if [[ "$proto_choice" == "both" ]]; then
    protos=(tcp udp)
  else
    protos=("$proto_choice")
  fi

  local proto
  for proto in "${protos[@]}"; do
    add_rule_unique "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" prerouting \
      "iifname \"$iface\" $proto dport $src_port counter dnat ip to $dst_ip:$dst_port comment \"pf:$proto:$src_port:$dst_ip:$dst_port\""

    add_rule_unique "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" postrouting \
      "ip daddr $dst_ip $proto dport $dst_port counter masquerade comment \"pf:$proto:$src_port:$dst_ip:$dst_port\""

    add_rule_unique "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" forward \
      "iifname \"$iface\" ip daddr $dst_ip $proto dport $dst_port ct state new,established,related counter accept comment \"pf:$proto:$src_port:$dst_ip:$dst_port\""

    add_rule_unique "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" forward \
      "ip saddr $dst_ip $proto sport $dst_port ct state established,related counter accept comment \"pf:$proto:$src_port:$dst_ip:$dst_port\""

    echo "✅ 已添加：$proto $src_port -> $dst_ip:$dst_port"
  done

  echo "ℹ️ 如需系统重启后保留规则，请执行菜单中的 nftables.conf 持久化功能"
}

delete_by_port_flow() {
  ensure_table_and_chains
  local del_port
  read -r -p "请输入要删除的本机端口: " del_port
  del_port=$(trim "$del_port")
  if ! is_valid_port "$del_port"; then
    echo "❌ 端口号无效，必须为 1-65535"
    return
  fi

  local matches
  matches=$(nft -a list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | grep -E "comment \"pf:(tcp|udp):${del_port}:" || true)
  if [[ -z "$matches" ]]; then
    echo "❌ 未找到本脚本管理的端口 $del_port 规则"
    return
  fi

  echo "即将删除以下规则："
  echo "$matches"
  read -r -p "确认删除？(y/n): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "❎ 已取消删除"; return; }

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local chain handle
    chain=$(awk '{print $1}' <<< "$line")
    handle=$(sed -n 's/.*handle \([0-9]\+\)$/\1/p' <<< "$line")
    if [[ -n "$chain" && -n "$handle" ]]; then
      nft delete rule "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" "$chain" handle "$handle"
      echo "✅ 已删除：chain=$chain handle=$handle"
    fi
  done < <(nft -a list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | awk -v p="$del_port" '/handle [0-9]+$/ && $0 ~ "comment \"pf:(tcp|udp):" p ":"/')
}

uninstall_managed_rules_flow() {
  ensure_table_and_chains
  echo "⚠️ 将删除整张 ${SCRIPT_TABLE_FAMILY} ${SCRIPT_TABLE_NAME} 表。"
  echo "这只会影响本脚本管理的 nftables 规则。"
  read -r -p "确认继续？(y/n): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "❎ 已取消"; return; }

  if nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" >/dev/null 2>&1; then
    nft delete table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME"
    echo "✅ 已删除 ${SCRIPT_TABLE_FAMILY} ${SCRIPT_TABLE_NAME}"
  else
    echo "ℹ️ 未发现目标表"
  fi
}

render_managed_table_block() {
  nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null
}

persist_nftables_conf_flow() {
  ensure_table_and_chains

  if [[ ! -f "$NFTABLES_CONF" ]]; then
    echo "⚠️ 未发现 $NFTABLES_CONF，将创建新文件"
    printf 'flush ruleset\n\n' > "$NFTABLES_CONF"
  fi

  local backup_file
  backup_file=$(nftables_conf_backup)
  echo "📦 已备份 $NFTABLES_CONF 到：$backup_file"

  local managed_block tmp_file
  managed_block=$(render_managed_table_block)
  tmp_file=$(mktemp)

  awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$NFTABLES_CONF" > "$tmp_file"

  # 清理尾部空行，避免重复追加越来越乱
  sed -i ':a;/^\n*$/{$d;N;ba' -e '}' "$tmp_file" 2>/dev/null || true

  {
    cat "$tmp_file"
    printf '\n\n%s\n' "$BEGIN_MARK"
    printf '%s\n' "$managed_block"
    printf '%s\n' "$END_MARK"
  } > "$NFTABLES_CONF"

  rm -f "$tmp_file"

  if nft -f "$NFTABLES_CONF"; then
    echo "✅ 已写入并验证 $NFTABLES_CONF"
  else
    echo "❌ 写入后验证失败，请检查配置，备份文件：$backup_file"
    return 1
  fi

  if command_exists systemctl; then
    if systemctl is-enabled nftables >/dev/null 2>&1; then
      echo "✅ nftables 服务已启用，重启后会按 $NFTABLES_CONF 加载"
    else
      echo "⚠️ nftables 服务尚未启用，可执行：systemctl enable nftables"
    fi
  fi
}

show_menu() {
  echo
  echo "请选择操作："
  echo "1) 添加端口转发"
  echo "2) 查看本脚本管理的 nftables 规则"
  echo "3) 删除指定本机端口的转发规则"
  echo "4) 卸载本脚本管理的全部规则"
  echo "5) 优化系统参数（BBR + 网络优化）"
  echo "6) 修复 /etc/sysctl.conf（仅修关键转发项）"
  echo "7) 写入 /etc/nftables.conf 持久化"
  echo "8) 退出"
}

main() {
  banner
  require_root
  ensure_nft

  while true; do
    show_menu
    read -r -p "输入选项 [1-8]: " option
    case "$(trim "$option")" in
      1) add_forwarding_flow ;;
      2) list_rules_flow ;;
      3) delete_by_port_flow ;;
      4) uninstall_managed_rules_flow ;;
      5) optimize_system_flow ;;
      6) repair_sysctl_flow ;;
      7) persist_nftables_conf_flow ;;
      8)
        echo "退出脚本"
        exit 0
        ;;
      *) echo "❌ 无效选项，请输入 1-8" ;;
    esac
  done
}

main "$@"
