#!/bin/bash
# =========================================
# 交互式端口转发管理工具（TCP+UDP）
# 功能：添加/查看/删除/卸载端口转发
# =========================================

echo "========================================="
echo "   🔁  IPTABLES TCP+UDP 端口转发管理工具"
echo "========================================="

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行：sudo $0"
    exit 1
fi

# 检查 iptables
if ! command -v iptables &> /dev/null; then
    echo "⚠️  未检测到 iptables，是否安装？(y/n)"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        if command -v apt &> /dev/null; then
            apt update && apt install -y iptables
        elif command -v yum &> /dev/null; then
            yum install -y iptables
        else
            echo "❌ 无法自动安装，请手动安装 iptables"
            exit 1
        fi
    else
        exit 0
    fi
fi

# 开启 IP 转发
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# 功能菜单
while true; do
    echo
    echo "请选择操作："
    echo "1) 添加 TCP+UDP 端口转发"
    echo "2) 查看当前 NAT 转发规则"
    echo "3) 删除指定端口转发（可靠）"
    echo "4) 卸载并恢复 NAT 表初始状态"
    echo "5) 优化系统参数（BBR + 网络优化）"
    echo "6) 退出"
    read -p "输入选项 [1-6]: " option

    case "$option" in
        1)
            read -p "请输入本机端口: " SRC_PORT
            read -p "请输入目标 IP: " DST_IP
            read -p "请输入目标端口: " DST_PORT
            
            # 输入验证
            if [[ -z "$SRC_PORT" || -z "$DST_IP" || -z "$DST_PORT" ]]; then
                echo "❌ 输入不能为空！"
                continue
            fi

            # 端口号验证（1-65535）
            if ! [[ "$SRC_PORT" =~ ^[0-9]+$ ]] || [ "$SRC_PORT" -lt 1 ] || [ "$SRC_PORT" -gt 65535 ]; then
                echo "❌ 本机端口无效！请输入 1-65535 之间的数字"
                continue
            fi
            if ! [[ "$DST_PORT" =~ ^[0-9]+$ ]] || [ "$DST_PORT" -lt 1 ] || [ "$DST_PORT" -gt 65535 ]; then
                echo "❌ 目标端口无效！请输入 1-65535 之间的数字"
                continue
            fi

            # IP 地址验证
            if ! [[ "$DST_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "❌ IP 地址格式无效！"
                continue
            fi

            # 检查是否已存在相同的转发规则
            if iptables-save -t nat | grep -q "PREROUTING.*--dport $SRC_PORT"; then
                echo "⚠️  警告：端口 $SRC_PORT 已存在转发规则！"
                read -p "是否继续添加？(y/n): " overwrite
                if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                    echo "❎ 已取消添加"
                    continue
                fi
            fi

            # 获取主网卡接口
            IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
            if [[ -z "$IFACE" ]]; then
                echo "❌ 无法检测到默认网卡接口"
                continue
            fi
            echo "📡 检测到网卡接口: $IFACE"

            # 添加新规则（TCP+UDP）
            for proto in tcp udp; do
                # NAT 规则
                iptables -t nat -A PREROUTING -i "$IFACE" -p "$proto" --dport "$SRC_PORT" -j DNAT --to-destination "$DST_IP:$DST_PORT"
                iptables -t nat -A POSTROUTING -o "$IFACE" -p "$proto" -d "$DST_IP" --dport "$DST_PORT" -j MASQUERADE
                
                # FORWARD 规则（允许转发）
                iptables -A FORWARD -i "$IFACE" -p "$proto" --dport "$DST_PORT" -d "$DST_IP" -j ACCEPT
                iptables -A FORWARD -o "$IFACE" -p "$proto" --sport "$DST_PORT" -s "$DST_IP" -j ACCEPT
            done

            echo "✅ 成功添加 TCP+UDP 转发：$SRC_PORT → $DST_IP:$DST_PORT"

            read -p "是否保存规则以便重启后生效？(y/n): " save_ans
            if [[ "$save_ans" =~ ^[Yy]$ ]]; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                echo "✅ 已保存规则"
            fi
            ;;
        2)
            echo "========================================="
            echo "当前 NAT 转发规则（本机端口 → 目标 IP:端口）："

            # 使用 iptables-save 解析 NAT 表显示规则
            iptables-save -t nat | grep -E "PREROUTING|POSTROUTING" | while read -r line; do
                if [[ "$line" =~ --dport[[:space:]]+([0-9]+) ]]; then
                    SRC_PORT="${BASH_REMATCH[1]}"
                fi
                if [[ "$line" =~ --to-destination[[:space:]]+([0-9.]+:[0-9]+) ]]; then
                    DST="${BASH_REMATCH[1]}"
                fi
                if [[ -n "$SRC_PORT" && -n "$DST" ]]; then
                    echo "端口 $SRC_PORT → 目标 $DST"
                    SRC_PORT=""
                    DST=""
                fi
            done

            echo "========================================="
            ;;
        3)
            read -p "请输入要删除的本机端口: " DEL_PORT
            if [[ -z "$DEL_PORT" ]]; then
                echo "❌ 端口不能为空！"
                continue
            fi

            # 端口号验证
            if ! [[ "$DEL_PORT" =~ ^[0-9]+$ ]] || [ "$DEL_PORT" -lt 1 ] || [ "$DEL_PORT" -gt 65535 ]; then
                echo "❌ 端口号无效！请输入 1-65535 之间的数字"
                continue
            fi

            # 检查端口是否有转发规则
            RULE_COUNT=$(iptables-save -t nat | grep -c "PREROUTING.*--dport $DEL_PORT")
            if [[ "$RULE_COUNT" -eq 0 ]]; then
                echo "❌ 未找到端口 $DEL_PORT 的转发规则！"
                continue
            fi

            # 显示即将删除的规则
            echo "========================================="
            echo "即将删除以下规则："
            iptables-save -t nat | grep "PREROUTING.*--dport $DEL_PORT" | sed 's/^-A /  /'
            echo "========================================="

            # 确认删除
            read -p "确认删除端口 $DEL_PORT 的所有转发规则？(y/n): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "❎ 已取消删除"
                continue
            fi

            # 删除规则（同时删除 NAT 和 FORWARD）
            TMP_FILE=$(mktemp)
            iptables-save > "$TMP_FILE"
            
            # 只删除 PREROUTING 中本机端口匹配的规则（更精确）
            grep -v "PREROUTING.*--dport $DEL_PORT" "$TMP_FILE" | \
            grep -v "POSTROUTING.*--dport $DEL_PORT" | \
            grep -v "FORWARD.*--dport $DEL_PORT" | \
            grep -v "FORWARD.*--sport $DEL_PORT" > "$TMP_FILE.new"
            
            iptables-restore < "$TMP_FILE.new"
            rm -f "$TMP_FILE" "$TMP_FILE.new"

            echo "✅ 已删除端口 $DEL_PORT 的所有转发规则"

            # 询问是否保存
            read -p "是否保存规则以便重启后生效？(y/n): " save_del
            if [[ "$save_del" =~ ^[Yy]$ ]]; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4
                echo "✅ 已保存规则"
            fi
            ;;
        4)
            echo "⚠️  卸载将清空 NAT 表和 FORWARD 规则，恢复初始状态！"
            read -p "确认卸载？(y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 清空 NAT 表
                iptables -t nat -F
                iptables -t nat -X
                iptables -t nat -Z

                # 清空 FORWARD 链
                iptables -F FORWARD

                # 删除持久化文件
                rm -f /etc/iptables/rules.v4

                echo "✅ NAT 表和 FORWARD 链已恢复初始状态，持久化文件已删除"

                read -p "是否删除脚本本身？(y/n): " del_self
                if [[ "$del_self" =~ ^[Yy]$ ]]; then
                    SCRIPT_PATH=$(realpath "$0")
                    rm -f "$SCRIPT_PATH"
                    echo "✅ 脚本已删除：$SCRIPT_PATH"
                    exit 0
                fi
            else
                echo "❎ 已取消卸载"
            fi
            ;;
        5)
            echo "========================================="
            echo "   ⚡ 系统网络参数优化（BBR + 高性能）"
            echo "========================================="
            echo "此操作将优化以下内容："
            echo "  • 启用 BBR 拥塞控制算法"
            echo "  • TCP 性能优化"
            echo "  • 缓冲区优化（适配低内存）"
            echo "  • 转发与路由优化"
            echo "  • 系统稳定性优化"
            echo
            read -p "是否继续优化？(y/n): " optimize_confirm
            if [[ ! "$optimize_confirm" =~ ^[Yy]$ ]]; then
                echo "❎ 已取消优化"
                continue
            fi

            # 检查 BBR 模块是否可用
            if ! modprobe tcp_bbr 2>/dev/null; then
                echo "⚠️  警告：BBR 模块不可用，可能需要更新内核（建议 4.9+）"
                read -p "是否继续其他优化？(y/n): " continue_optimize
                if [[ ! "$continue_optimize" =~ ^[Yy]$ ]]; then
                    continue
                fi
            fi

            # 备份原有配置
            BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
            cp /etc/sysctl.conf "$BACKUP_FILE"
            echo "📦 已备份配置到：$BACKUP_FILE"

            # 写入优化参数
            cat >> /etc/sysctl.conf << 'EOF'

# ==========================================
# 网络优化配置（自动添加）
# ==========================================

# ==========================
# 文件描述符限制
# ==========================
fs.file-max = 1048576

# ==========================
# TCP 网络优化
# ==========================
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1

# ==========================
# 缓冲区优化（适配低内存）
# ==========================
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 16384 16777216
net.ipv4.udp_rmem_min=4096
net.ipv4.udp_wmem_min=4096

# ==========================
# 路由与转发设置（旁路/代理必备）
# ==========================
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# ==========================
# 拥塞控制算法
# ==========================
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# ==========================
# 一般系统稳定性建议
# ==========================
vm.swappiness=10
vm.overcommit_memory=1

EOF

            # 应用配置
            echo "⚙️  正在应用优化参数..."
            sysctl -p > /dev/null 2>&1

            echo "========================================="
            echo "✅ 系统优化完成！"
            echo
            echo "📊 当前状态："
            echo "  • BBR 状态：$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')"
            echo "  • IP 转发：$(sysctl net.ipv4.ip_forward 2>/dev/null | awk '{print $3}')"
            echo "  • 队列算法：$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')"
            echo
            echo "💡 提示：配置已持久化到 /etc/sysctl.conf"
            echo "   重启后依然生效，备份文件：$BACKUP_FILE"
            echo "========================================="
            ;;
        6)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "❌ 无效选项，请输入 1-6"
            ;;
    esac
done
