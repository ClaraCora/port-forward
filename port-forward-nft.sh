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
SYSCTL_BEGIN_MARK="# BEGIN managed by port-forward-nft sysctl"
SYSCTL_END_MARK="# END managed by port-forward-nft sysctl"

print_line() {
  printf '%s\n' "-----------------------------------------"
}

print_section() {
  echo
  echo "========================================="
  echo "   $1"
  echo "========================================="
}

pause_return() {
  echo
  read -r -p "按 Enter 返回主菜单..." _
}

confirm_action() {
  local prompt="$1"
  local answer
  read -r -p "$prompt [y/N]: " answer
  [[ "$(trim "$answer")" =~ ^[Yy]$ ]]
}

prompt_required() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt" value
    value=$(trim "$value")
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "❌ 输入不能为空，请重新输入" >&2
  done
}

prompt_port() {
  local prompt="$1"
  local value
  while true; do
    value=$(prompt_required "$prompt")
    if is_valid_port "$value"; then
      printf '%s' "$value"
      return 0
    fi
    echo "❌ 端口无效，必须为 1-65535" >&2
  done
}

prompt_ipv4() {
  local prompt="$1"
  local value
  while true; do
    value=$(prompt_required "$prompt")
    if is_valid_ipv4 "$value"; then
      printf '%s' "$value"
      return 0
    fi
    echo "❌ IPv4 地址无效，请重新输入" >&2
  done
}

prompt_protocol() {
  local value
  while true; do
    read -r -p "协议 [1=tcp, 2=udp, 3=both，默认 3]: " value
    value=$(trim "$value")
    case "${value:-3}" in
      1|tcp|TCP) echo "tcp"; return 0 ;;
      2|udp|UDP) echo "udp"; return 0 ;;
      3|both|BOTH) echo "both"; return 0 ;;
      *) echo "❌ 协议无效，请输入 1/2/3 或 tcp/udp/both" >&2 ;;
    esac
  done
}

banner() {
  echo "========================================="
  echo "   🔁 NFTABLES 原生端口转发管理工具"
  echo "========================================="
  echo "   table: ${SCRIPT_TABLE_FAMILY} ${SCRIPT_TABLE_NAME}"
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
  confirm_action "是否尝试自动安装 nftables？" || exit 0

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

ensure_runtime_dependencies() {
  local missing=()
  local cmd
  for cmd in ip awk sed grep mktemp sysctl; do
    command_exists "$cmd" || missing+=("$cmd")
  done

  if (( ${#missing[@]} > 0 )); then
    echo "❌ 缺少必要命令：${missing[*]}"
    echo "请先安装缺失依赖后再运行。"
    exit 1
  fi
}

detect_linux_distribution() {
  local os_id="unknown"
  local os_version="unknown"
  local os_name="unknown"

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-unknown}"
    os_version="${VERSION_ID:-unknown}"
    os_name="${PRETTY_NAME:-${NAME:-unknown}}"
  fi

  printf '%s\t%s\t%s' "$os_id" "$os_version" "$os_name"
}

render_sysctl_profile_block() {
  local profile="$1"
  case "$profile" in
    debian12)
      cat <<'EOF'
# ==========================
# Debian 12 网络优化配置
# ==========================
fs.file-max = 6815744

# ==========================
# 连接队列 / 服务端并发
# ==========================
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# ==========================
# BBR / 队列调度
# ==========================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ==========================
# TCP 行为优化
# ==========================
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_timestamps = 1

# ==========================
# 缓冲区 / 吞吐优化
# ==========================
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_local_port_range = 1024 65535

# ==========================
# 路由 / 转发 / NAT 相关
# ==========================
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.conf.all.route_localnet = 1
EOF
      ;;
    debian13)
      cat <<'EOF'
# ==========================
# Debian 13 网络优化配置
# ==========================
fs.file-max = 1048576

# ==========================
# TCP / 队列调度
# ==========================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# ==========================
# TCP 高级优化
# ==========================
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3

# ==========================
# 缓冲区 / 吞吐优化
# ==========================
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096
net.core.netdev_max_backlog = 16384

# ==========================
# 转发与路由 / 安全
# ==========================
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# ==========================
# 内存稳定性
# ==========================
vm.overcommit_memory = 1
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
      ;;
    ubuntu24)
      cat <<'EOF'
# ==========================
# Ubuntu 24.04 网络优化配置
# ==========================
fs.file-max = 1048576

# ==========================
# 基础网络设置
# ==========================
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1

# ==========================
# TCP 高级优化
# ==========================
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3

# ==========================
# 缓冲区 / 并发
# ==========================
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192

# ==========================
# 转发与路由
# ==========================
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# ==========================
# SYN 防护与连接稳定性
# ==========================
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# ==========================
# 内存与系统稳定性
# ==========================
vm.overcommit_memory = 1
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
      ;;
    *)
      return 1
      ;;
  esac
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
  touch "$SYSCTL_FILE"
  cp "$SYSCTL_FILE" "$backup_file"
  echo "$backup_file"
}

nftables_conf_backup() {
  mkdir -p "$NFTABLES_CONF_BACKUP_DIR"
  local backup_file="$NFTABLES_CONF_BACKUP_DIR/nftables.conf.backup.$(date +%Y%m%d_%H%M%S)"
  cp "$NFTABLES_CONF" "$backup_file"
  echo "$backup_file"
}

strip_managed_sysctl_block() {
  local input="$1"
  local output="$2"
  awk -v begin="$SYSCTL_BEGIN_MARK" -v end="$SYSCTL_END_MARK" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$input" > "$output"
}

write_managed_sysctl_block() {
  local block="$1"
  touch "$SYSCTL_FILE"
  local tmp_file cleaned_file
  tmp_file=$(mktemp)
  cleaned_file=$(mktemp)

  strip_managed_sysctl_block "$SYSCTL_FILE" "$cleaned_file"

  {
    cat "$cleaned_file"
    printf '\n%s\n' "$SYSCTL_BEGIN_MARK"
    printf '%s\n' "$block"
    printf '%s\n' "$SYSCTL_END_MARK"
  } > "$tmp_file"

  mv "$tmp_file" "$SYSCTL_FILE"
  rm -f "$cleaned_file"
}

apply_sysctl_runtime_pairs() {
  while (( "$#" )); do
    local key="$1"
    local value="$2"
    shift 2
    if ! sysctl -w "$key=$value" >/dev/null 2>&1; then
      echo "⚠️ 跳过不支持或不可写的 sysctl：$key=$value"
    fi
  done
}

render_sysctl_repair_block() {
  cat <<'EOF'
# ==========================
# 路由 / 转发 / NAT 相关
# ==========================
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
}

render_sysctl_optimized_block() {
  render_sysctl_profile_block "debian12"
}

recommended_sysctl_profile() {
  local os_id="$1"
  local os_version="$2"
  case "$os_id:$os_version" in
    debian:12*) echo "debian12" ;;
    debian:13*) echo "debian13" ;;
    ubuntu:24.04*) echo "ubuntu24" ;;
    *) echo "debian12" ;;
  esac
}

profile_display_name() {
  case "$1" in
    debian12) echo "Debian 12 通用优化" ;;
    debian13) echo "Debian 13 推荐优化" ;;
    ubuntu24) echo "Ubuntu 24.04 推荐优化" ;;
    *) echo "未知配置" ;;
  esac
}

tty_echo() {
  if [[ -w /dev/tty ]]; then
    printf '%s\n' "$*" > /dev/tty
  else
    printf '%s\n' "$*" >&2
  fi
}

prompt_sysctl_profile() {
  local recommended="$1"
  local choice default_choice

  case "$recommended" in
    debian12) default_choice=1 ;;
    debian13) default_choice=2 ;;
    ubuntu24) default_choice=3 ;;
    *) default_choice=1 ;;
  esac

  tty_echo "请选择要应用的优化配置："
  tty_echo "  1) Debian 12 通用优化$([[ "$recommended" == "debian12" ]] && echo "  ← 推荐")"
  tty_echo "  2) Debian 13 推荐优化$([[ "$recommended" == "debian13" ]] && echo "  ← 推荐")"
  tty_echo "  3) Ubuntu 24.04 推荐优化$([[ "$recommended" == "ubuntu24" ]] && echo "  ← 推荐")"
  tty_echo "  0) 取消"

  while true; do
    if [[ -r /dev/tty && -w /dev/tty ]]; then
      read -r -p "请选择 [0-3，默认 $default_choice]: " choice < /dev/tty
    else
      read -r -p "请选择 [0-3，默认 $default_choice]: " choice
    fi
    choice=$(trim "$choice")
    [[ -n "$choice" ]] || choice="$default_choice"
    case "$choice" in
      1) echo "debian12"; return 0 ;;
      2) echo "debian13"; return 0 ;;
      3) echo "ubuntu24"; return 0 ;;
      0) return 1 ;;
      *) tty_echo "❌ 无效选项，请输入 0-3" ;;
    esac
  done
}

apply_sysctl_block_runtime() {
  local block="$1"
  while IFS= read -r line; do
    line=$(trim "${line%%#*}")
    [[ -n "$line" ]] || continue
    [[ "$line" == *=* ]] || continue

    local key value
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")
    [[ -n "$key" && -n "$value" ]] || continue

    apply_sysctl_runtime_pairs "$key" "$value"
  done <<< "$block"
}

repair_sysctl_flow() {
  print_section "🛠 修复 /etc/sysctl.conf（定向更新）"
  echo "将仅修复以下关键项："
  echo "  • net.ipv4.ip_forward"
  echo "  • net.ipv4.conf.all.forwarding"
  echo "  • net.ipv4.conf.default.forwarding"
  echo "  • net.ipv6.conf.all.forwarding"
  echo "  • net.ipv6.conf.default.forwarding"
  echo
  confirm_action "是否继续？" || { echo "❎ 已取消"; return; }

  local backup_file
  backup_file=$(sysctl_backup)
  echo "📦 已备份到：$backup_file"

  apply_sysctl_runtime_pairs \
    net.ipv4.ip_forward 1 \
    net.ipv4.conf.all.forwarding 1 \
    net.ipv4.conf.default.forwarding 1 \
    net.ipv6.conf.all.forwarding 1 \
    net.ipv6.conf.default.forwarding 1

  local repair_block
  repair_block=$(render_sysctl_repair_block)
  write_managed_sysctl_block "$repair_block"

  echo "✅ /etc/sysctl.conf 已修复（仅更新指定项）"
}

optimize_system_flow() {
  print_section "⚡ 系统网络参数优化（nftables 版）"
  echo "此操作会根据系统版本选择 BBR / 网络优化配置，不会反复追加整段配置。"
  echo

  local detected os_id os_version os_name recommended_profile selected_profile profile_name
  detected=$(detect_linux_distribution)
  IFS=$'\t' read -r os_id os_version os_name <<< "$detected"
  recommended_profile=$(recommended_sysctl_profile "$os_id" "$os_version")

  echo "检测到系统：$os_name"
  echo "推荐配置：$(profile_display_name "$recommended_profile")"
  echo

  selected_profile=$(prompt_sysctl_profile "$recommended_profile") || { echo "❎ 已取消优化"; return; }
  profile_name=$(profile_display_name "$selected_profile")
  echo "将应用：$profile_name"
  confirm_action "是否继续优化？" || { echo "❎ 已取消优化"; return; }

  local backup_file
  backup_file=$(sysctl_backup)
  echo "📦 已备份 sysctl.conf 到：$backup_file"

  if modprobe tcp_bbr 2>/dev/null; then
    echo "✅ 已加载 tcp_bbr 模块"
  else
    echo "⚠️ 未能加载 tcp_bbr；若内核不支持，BBR 可能不会生效"
  fi

  local optimized_block
  optimized_block=$(render_sysctl_profile_block "$selected_profile")
  apply_sysctl_block_runtime "$optimized_block"
  write_managed_sysctl_block "$optimized_block"

  echo "✅ 系统优化完成"
  echo "  • 配置: $profile_name"
  echo "  • BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  echo "  • IPv4 转发: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  echo "  • qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
}

list_rules_flow() {
  ensure_table_and_chains
  print_section "📋 端口转发规则"
  show_rules_table

  echo
  if confirm_action "是否查看原始 nftables 规则？"; then
    print_section "原始规则：${SCRIPT_TABLE_FAMILY} ${SCRIPT_TABLE_NAME}"
    nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME"
  fi
}

add_rule_unique() {
  local family="$1" table="$2" chain="$3" expr="$4"
  if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -Fq -- "$expr"; then
    local rule_expr="${expr//\"/}"
    nft add rule "$family" "$table" "$chain" $rule_expr
  else
    echo "ℹ️ 规则已存在，跳过：$chain $expr"
  fi
}

has_managed_rule_entries() {
  nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | grep -Eq 'comment "pf:(tcp|udp):'
}

collect_forwarding_entries() {
  local rules
  rules=$(nft list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | grep -E 'comment "pf:(tcp|udp):' || true)
  [[ -n "$rules" ]] || return 0

  declare -A seen=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local comment
    comment=$(sed -n 's/.*comment "\([^"]*\)".*/\1/p' <<< "$line")
    [[ -n "$comment" ]] || continue
    [[ -n "${seen[$comment]:-}" ]] && continue
    seen[$comment]=1
    if [[ "$comment" =~ ^pf:(tcp|udp):([0-9]+):([0-9.]+):([0-9]+)$ ]]; then
      printf '%s\t%s\t%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[1]}"
    fi
  done <<< "$rules"
}

show_rules_table() {
  local entries
  entries=$(collect_forwarding_entries)
  if [[ -z "$entries" ]]; then
    echo "当前没有转发规则。"
    echo "提示：选择 1 可以添加新的端口转发。"
    return 0
  fi

  awk -F '\t' '
    {
      key=$1 SUBSEP $2 SUBSEP $3
      if (!(key in order)) {
        order[key]=++count
        src[count]=$1
        dstip[count]=$2
        dstport[count]=$3
      }
      proto[key,$4]=1
    }
    END {
      printf "%-4s %-12s %-22s %-10s\n", "序号", "本机端口", "目标", "协议"
      printf "%-4s %-12s %-22s %-10s\n", "----", "------------", "----------------------", "----------"
      for (i=1; i<=count; i++) {
        key=src[i] SUBSEP dstip[i] SUBSEP dstport[i]
        if (proto[key,"tcp"] && proto[key,"udp"]) p="both"
        else if (proto[key,"tcp"]) p="tcp"
        else if (proto[key,"udp"]) p="udp"
        else p="unknown"
        printf "%-4d %-12s %-22s %-10s\n", i, src[i], dstip[i] ":" dstport[i], p
      }
    }
  ' <<< "$entries"
}

show_rules_summary() {
  local entries
  entries=$(collect_forwarding_entries)
  if [[ -z "$entries" ]]; then
    echo "当前还没有任何转发条目，只创建了基础表和链。"
    return 0
  fi

  echo "转发摘要："
  awk -F '\t' '
    {
      key=$1 SUBSEP $2 SUBSEP $3
      if (!(key in order)) {
        order[key]=++count
        src[count]=$1
        dstip[count]=$2
        dstport[count]=$3
      }
      proto[key,$4]=1
    }
    END {
      for (i=1; i<=count; i++) {
        key=src[i] SUBSEP dstip[i] SUBSEP dstport[i]
        if (proto[key,"tcp"] && proto[key,"udp"]) p="both"
        else if (proto[key,"tcp"]) p="tcp"
        else if (proto[key,"udp"]) p="udp"
        else p="unknown"
        printf "- %s -> %s:%s (%s)\n", src[i], dstip[i], dstport[i], p
      }
    }
  ' <<< "$entries"
}

add_forwarding_flow() {
  ensure_table_and_chains

  local src_port dst_ip dst_port proto_choice iface host_ip
  print_section "➕ 添加端口转发"
  src_port=$(prompt_port "本机监听端口: ")
  dst_ip=$(prompt_ipv4 "目标 IPv4 地址: ")
  dst_port=$(prompt_port "目标端口: ")
  proto_choice=$(prompt_protocol)

  iface=$(get_default_iface)
  if [[ -z "$iface" ]]; then
    echo "❌ 无法检测默认网卡"
    return
  fi
  host_ip=$(get_primary_ip "$iface")
  echo "📡 默认网卡: $iface${host_ip:+  (本机 IPv4: $host_ip) }"
  echo "📌 规则预览: $proto_choice $src_port -> $dst_ip:$dst_port"
  confirm_action "确认添加以上转发？" || { echo "❎ 已取消添加"; return; }

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

  if confirm_action "是否立即写入 /etc/nftables.conf 持久化？"; then
    persist_nftables_conf_flow
  else
    echo "ℹ️ 如需系统重启后保留规则，可稍后执行菜单中的“写入 /etc/nftables.conf 持久化”"
  fi
}

delete_by_port_flow() {
  ensure_table_and_chains
  local del_port
  print_section "🗑 删除指定端口规则"
  del_port=$(prompt_port "要删除的本机端口: ")

  local matches
  matches=$(nft -a list table "$SCRIPT_TABLE_FAMILY" "$SCRIPT_TABLE_NAME" 2>/dev/null | grep -E "comment \"pf:(tcp|udp):${del_port}:" || true)
  if [[ -z "$matches" ]]; then
    echo "❌ 未找到本脚本管理的端口 $del_port 规则"
    return
  fi

  echo "即将删除以下规则："
  echo "$matches"
  confirm_action "确认删除？" || { echo "❎ 已取消删除"; return; }

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
  print_section "🧹 卸载脚本管理的全部规则"
  echo "⚠️ 将删除整张 ${SCRIPT_TABLE_FAMILY} ${SCRIPT_TABLE_NAME} 表。"
  echo "这只会影响本脚本管理的 nftables 规则。"
  confirm_action "确认继续？" || { echo "❎ 已取消"; return; }

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
  print_section "💾 写入 /etc/nftables.conf 持久化"

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
  awk 'BEGIN{block=0} { lines[NR]=$0; if ($0 ~ /[^[:space:]]/) block=NR } END { for (i=1; i<=block; i++) print lines[i] }' "$tmp_file" > "$tmp_file.trimmed"
  mv "$tmp_file.trimmed" "$tmp_file"

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
    cp "$backup_file" "$NFTABLES_CONF"
    echo "↩️ 已自动恢复原配置"
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
  print_line
  echo "规则管理"
  echo "  1) 添加端口转发"
  echo "  2) 查看规则与摘要"
  echo "  3) 删除指定本机端口"
  echo "  4) 清空脚本管理规则"
  echo
  echo "系统与持久化"
  echo "  5) 写入 nftables.conf 持久化"
  echo "  6) 修复转发 sysctl"
  echo "  7) 网络参数优化（BBR）"
  echo
  echo "  0) 退出"
  print_line
}

main() {
  banner
  require_root
  ensure_nft
  ensure_runtime_dependencies

  while true; do
    show_menu
    show_rules_summary
    echo
    read -r -p "请选择 [0-7]: " option
    case "$(trim "$option")" in
      1) add_forwarding_flow ;;
      2) list_rules_flow ;;
      3) delete_by_port_flow ;;
      4) uninstall_managed_rules_flow ;;
      5) persist_nftables_conf_flow ;;
      6) repair_sysctl_flow ;;
      7) optimize_system_flow ;;
      0|q|Q|exit)
        echo "退出脚本"
        exit 0
        ;;
      *) echo "❌ 无效选项，请输入 0-7" ;;
    esac
    pause_return
  done
}

main "$@"
