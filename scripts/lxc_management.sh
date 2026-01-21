#!/bin/bash

# ============================================
# LXC 容器管理脚本 (适配版)
# 基于 v6.8 完整功能版本
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================
# 公共函数
# ============================================

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

press_enter() {
    echo ""
    read -p "按 Enter 键继续..."
}

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "此功能需要 root 权限"
        print_info "请使用 sudo 运行主脚本"
        press_enter
        return 1
    fi
    return 0
}

# ==============================================================================
#                                   基础辅助函数
# ==============================================================================

check_lxc_installed() {
    if command -v lxc-create &> /dev/null; then
        return 0
    else
        return 1
    fi
}

get_container_ip() {
    local container_name=$1
    local state=$(lxc-info -n "$container_name" -s 2>/dev/null | awk '{print $2}')
    if [ "$state" != "RUNNING" ]; then
        echo "-"
        return
    fi
    local ip=$(lxc-attach -n "$container_name" -- ip -4 addr show eth0 2>/dev/null | \
         grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -z "$ip" ] && echo "获取中..." || echo "$ip"
}

get_container_remark() {
    local container_name=$1
    local config_file="/var/lib/lxc/$container_name/config"
    local remark=$(grep "^# LXC_REMARK:" "$config_file" 2>/dev/null | cut -d':' -f2- | sed 's/^[ \t]*//')
    [ -z "$remark" ] && echo "-" || echo "$remark"
}

is_privileged() {
    local container_name=$1
    local config_file="/var/lib/lxc/$container_name/config"
    if grep -q "lxc.apparmor.profile.*=.*unconfined" "$config_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

generate_new_mac() {
    printf "00:16:3e:%02x:%02x:%02x" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

ensure_host_subids() {
    touch /etc/subuid /etc/subgid
    grep -q "^root:100000:65536" /etc/subuid || echo "root:100000:65536" >> /etc/subuid
    grep -q "^root:100000:65536" /etc/subgid || echo "root:100000:65536" >> /etc/subgid
}

show_containers_simple() {
    local filter=$1
    echo "=========================================================="
    printf "  %-15s %-10s %-10s %-20s\n" "名称" "状态" "模式" "备注"
    echo "----------------------------------------------------------"
    local all_containers=$(lxc-ls 2>/dev/null)
    if [ -z "$all_containers" ]; then
        echo -e "${YELLOW}  没有容器${NC}"
        echo "=========================================================="
        return 1
    fi
    for c in $all_containers; do
        local state=$(lxc-info -n "$c" -s 2>/dev/null | awk '{print $2}')
        local mode_tag=$(is_privileged "$c" && echo -e "${RED}特权${NC}" || echo -e "${GREEN}非特${NC}")
        local remark=$(get_container_remark "$c")
        case $filter in
            running) [ "$state" = "RUNNING" ] && printf "  %-15s [%-8s] %-14b %s\n" "$c" "$state" "$mode_tag" "$remark" ;;
            stopped) [ "$state" = "STOPPED" ] && printf "  %-15s [%-8s] %-14b %s\n" "$c" "$state" "$mode_tag" "$remark" ;;
            *)       printf "  %-15s [%-8s] %-14b %s\n" "$c" "$state" "$mode_tag" "$remark" ;;
        esac
    done
    echo "=========================================================="
}

# ==============================================================================
#                                   核心功能模块
# ==============================================================================

install_lxc() {
    clear
    echo "=========================================="
    echo "   安装 LXC 环境"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    if check_lxc_installed; then
        print_warning "LXC 已安装"
        lxc-ls --version
        press_enter
        return
    fi
    
    print_info "正在安装 LXC 及相关工具..."
    echo ""
    
    apt-get update
    apt-get install -y lxc lxc-templates debootstrap bridge-utils libvirt-clients uidmap iptables iptables-persistent
    
    if [ $? -eq 0 ]; then
        print_success "LXC 安装成功"
        
        # 启用服务
        systemctl enable lxc lxc-net
        systemctl start lxc-net
        
        print_success "LXC 服务已启动"
        echo ""
        print_info "已安装组件："
        echo "  - LXC 核心"
        echo "  - 容器模板"
        echo "  - 网络桥接工具"
        echo "  - iptables 持久化"
    else
        print_error "安装失败"
    fi
    
    press_enter
}

setup_network_bridge() {
    clear
    echo "=========================================="
    echo "   配置网络桥接"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_info "配置 LXC 网络桥接 (10.0.0.1/24)..."
    echo ""
    
    # 创建 LXC 网络配置
    cat > /etc/default/lxc-net << 'EOF'
USE_LXC_BRIDGE="true"
LXC_BRIDGE="lxcbr0"
LXC_ADDR="10.0.0.1"
LXC_NETMASK="255.255.255.0"
LXC_NETWORK="10.0.0.0/24"
LXC_DHCP_RANGE="10.0.0.100,10.0.0.254"
LXC_DHCP_MAX="253"
LXC_DHCP_CONFILE="/etc/lxc/dnsmasq.conf"
EOF
    
    # 创建配置目录
    mkdir -p /etc/lxc
    touch /etc/lxc/dnsmasq.conf /etc/lxc/dhcp_hosts.conf
    
    # 重启网络服务
    systemctl restart lxc-net
    
    print_success "网络桥接配置完成"
    echo ""
    
    # 配置 IP 转发
    print_info "配置 IP 转发..."
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-lxc.conf
    sysctl -p /etc/sysctl.d/99-lxc.conf
    
    # 配置 iptables NAT
    local IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    print_info "在网卡 ${IFACE} 上配置 NAT..."
    
    iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o "$IFACE" -j MASQUERADE
    iptables -A FORWARD -i lxcbr0 -o "$IFACE" -j ACCEPT
    iptables -A FORWARD -i "$IFACE" -o lxcbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    
    # 保存 iptables 规则
    iptables-save > /etc/iptables/rules.v4
    
    print_success "网络配置完成"
    echo ""
    print_info "网络信息："
    echo "  桥接接口: lxcbr0"
    echo "  桥接地址: 10.0.0.1/24"
    echo "  DHCP 范围: 10.0.0.100-254"
    echo "  静态 IP: 10.0.0.2-99 (可用)"
    
    press_enter
}

configure_host_swap() {
    clear
    echo "=========================================="
    echo "   配置宿主机 Swap"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    # 显示当前内存状态
    print_info "当前内存状态："
    free -h
    echo ""
    
    read -p "Swap 大小 (GB): " gb
    
    if [ -z "$gb" ] || ! [[ "$gb" =~ ^[0-9]+$ ]]; then
        print_error "无效的大小"
        press_enter
        return
    fi
    
    # 删除旧的 swap 文件
    if [ -f /swapfile ]; then
        print_info "删除旧的 swap 文件..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '/swapfile/d' /etc/fstab
    fi
    
    # 创建新的 swap 文件
    print_info "创建 ${gb}GB swap 文件..."
    dd if=/dev/zero of=/swapfile bs=1M count=$((gb*1024)) status=progress
    
    # 设置权限
    chmod 600 /swapfile
    
    # 格式化并启用
    mkswap /swapfile
    swapon /swapfile
    
    # 添加到 fstab
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    
    print_success "Swap 配置完成"
    echo ""
    print_info "新的内存状态："
    free -h
    
    press_enter
}

create_debian12() {
    clear
    echo "=========================================="
    echo "   创建 Debian 12 容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        print_error "容器名称不能为空"
        press_enter
        return
    fi
    
    # 检查容器是否已存在
    if lxc-info -n "$container_name" &>/dev/null; then
        print_error "容器 ${container_name} 已存在"
        press_enter
        return
    fi
    
    print_info "正在创建 Debian 12 容器..."
    echo ""
    
    # 创建容器
    lxc-create -t download -n "$container_name" -- -d debian -r bookworm -a amd64
    
    if [ $? -eq 0 ]; then
        print_success "容器创建成功"
        echo ""
        
        local config_file="/var/lib/lxc/$container_name/config"
        
        # 配置自动启动
        print_info "配置自动启动..."
        echo -e "lxc.start.auto = 1\nlxc.start.delay = 5\nlxc.start.order = 100" >> "$config_file"
        
        # 配置 Swap（如果宿主机有 Swap）
        local host_swap=$(free -m | awk '/^Swap:/{print $2}')
        if [ "$host_swap" -gt 0 ]; then
            print_info "配置容器 Swap 限制..."
            echo "lxc.cgroup2.memory.swap.max = $((host_swap/2))M" >> "$config_file"
        fi
        
        # 询问是否添加备注
        echo ""
        read -p "是否添加备注？(y/n): " add_remark
        if [[ "$add_remark" =~ ^[yY]$ ]]; then
            read -p "请输入备注: " remark
            echo "# LXC_REMARK: $remark" >> "$config_file"
        fi
        
        # 询问是否立即启动
        echo ""
        read -p "是否立即启动容器？(y/n): " start_now
        if [[ "$start_now" =~ ^[yY]$ ]]; then
            lxc-start -n "$container_name"
            print_success "容器已启动"
            
            sleep 2
            
            # 询问是否配置静态 IP
            read -p "是否配置静态 IP？(y/n): " set_ip
            if [[ "$set_ip" =~ ^[yY]$ ]]; then
                set_static_ip "$container_name"
            fi
        fi
    else
        print_error "容器创建失败"
    fi
    
    press_enter
}

set_static_ip() {
    clear
    echo "=========================================="
    echo "   设置静态 IP"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    local target=$1
    
    if [ -z "$target" ]; then
        show_containers_simple "all"
        echo ""
        read -p "容器名称: " target
    fi
    
    if [ -z "$target" ] || [ ! -f "/var/lib/lxc/$target/config" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    read -p "静态 IP (10.0.0.2-99): " static_ip
    
    if [[ ! "$static_ip" =~ ^10\.0\.0\.[2-9][0-9]?$ ]]; then
        print_error "IP 地址格式错误或超出范围"
        press_enter
        return
    fi
    
    print_info "配置静态 IP..."
    
    # 获取或生成 MAC 地址
    local container_mac=$(grep "lxc.net.0.hwaddr" "/var/lib/lxc/$target/config" | awk '{print $3}')
    if [ -z "$container_mac" ]; then
        container_mac=$(generate_new_mac)
        echo "lxc.net.0.hwaddr = $container_mac" >> "/var/lib/lxc/$target/config"
        print_info "生成 MAC 地址: $container_mac"
    fi
    
    # 清理旧的绑定记录
    sed -i "/,${target},/d; /${container_mac},/d; /,${static_ip}$/d" /etc/lxc/dhcp_hosts.conf
    
    # 添加新的绑定
    echo "${container_mac},${target},${static_ip}" >> /etc/lxc/dhcp_hosts.conf
    
    # 清理租约文件
    if [ -f /var/lib/misc/dnsmasq.lxcbr0.leases ]; then
        sed -i "/$container_mac/d; /$target/d; /$static_ip/d" /var/lib/misc/dnsmasq.lxcbr0.leases
    fi
    
    # 重启容器和网络
    print_info "重启容器以应用更改..."
    lxc-stop -n "$target" -k 2>/dev/null || true
    systemctl restart lxc-net
    lxc-start -n "$target"
    
    print_success "静态 IP ${static_ip} 已绑定"
    echo ""
    print_info "MAC 地址: $container_mac"
    
    press_enter
}

toggle_privileged() {
    clear
    echo "=========================================="
    echo "   切换特权模式"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    local config_file="/var/lib/lxc/$container_name/config"
    local rootfs="/var/lib/lxc/$container_name/rootfs"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    echo ""
    echo "1. 切换到特权模式 (支持 Docker)"
    echo "2. 切换到非特权模式"
    echo ""
    read -p "请选择 [1-2]: " choice
    
    # 清理旧配置
    sed -i '/# 特权/,/# 非特权/d; /^lxc.idmap/d; /^lxc.apparmor/d; /^lxc.mount.auto/d; /^lxc.cap.drop/d' "$config_file"
    
    if [ "$choice" = "1" ]; then
        print_info "配置特权模式..."
        cat >> "$config_file" << 'EOF'
# 特权模式配置 (Docker Support)
lxc.apparmor.profile = unconfined
lxc.apparmor.allow_nesting = 1
lxc.cap.drop =
lxc.mount.auto = proc:mixed sys:rw cgroup:mixed
EOF
        print_success "已切换到特权模式"
    else
        print_info "配置非特权模式..."
        ensure_host_subids
        cat >> "$config_file" << 'EOF'
# 非特权模式配置
lxc.mount.auto = proc:mixed sys:mixed cgroup:mixed
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
EOF
        print_success "已切换到非特权模式"
    fi
    
    # 修复权限
    print_info "修复文件系统权限..."
    chown -R 0:0 "$rootfs"
    
    # 重启容器
    print_info "重启容器..."
    lxc-stop -n "$container_name" -k 2>/dev/null || true
    lxc-start -n "$container_name"
    
    print_success "配置完成"
    
    press_enter
}

setup_port_forward() {
    clear
    echo "=========================================="
    echo "   配置端口转发"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "running"
    echo ""
    
    read -p "容器名称: " container_name
    local container_ip=$(get_container_ip "$container_name")
    
    if [ "$container_ip" = "-" ] || [ "$container_ip" = "获取中..." ]; then
        print_error "容器未运行或无法获取 IP"
        press_enter
        return
    fi
    
    echo ""
    print_info "容器 IP: $container_ip"
    echo ""
    
    read -p "外部端口 (宿主机): " host_port
    read -p "内部端口 (容器): " container_port
    
    if [ -z "$host_port" ] || [ -z "$container_port" ]; then
        print_error "端口不能为空"
        press_enter
        return
    fi
    
    local IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    print_info "在网卡 ${IFACE} 上配置端口转发..."
    
    # 配置 iptables 规则（修复版：增加 -i 限制）
    iptables -t nat -A PREROUTING -i "$IFACE" -p tcp --dport "$host_port" -j DNAT --to-destination "$container_ip":"$container_port"
    iptables -A FORWARD -p tcp -d "$container_ip" --dport "$container_port" -j ACCEPT
    
    # 保存规则
    iptables-save > /etc/iptables/rules.v4
    
    print_success "端口转发配置完成"
    echo ""
    print_info "转发规则："
    echo "  外部端口: $host_port (${IFACE})"
    echo "  -> 容器: $container_name ($container_ip:$container_port)"
    
    press_enter
}

show_dashboard() {
    clear
    echo "=========================================="
    echo "   LXC 容器控制台"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    echo "=========================================================================================================="
    printf "%-12s %-10s %-15s %-15s %-5s %-10s %-10s %-8s\n" "名称" "状态" "IP地址" "备注" "自启" "内存" "Swap" "CPU"
    echo "----------------------------------------------------------------------------------------------------------"
    
    for container in $(lxc-ls 2>/dev/null); do
        local config_file="/var/lib/lxc/$container/config"
        local state=$(lxc-info -n "$container" -s 2>/dev/null | awk '{print $2}')
        local ip=$(get_container_ip "$container")
        local remark=$(get_container_remark "$container")
        remark=${remark:0:15}
        
        local autostart=$(grep -q "lxc.start.auto = 1" "$config_file" 2>/dev/null && echo -e "${GREEN}是${NC}" || echo "否")
        local mem=$(grep "memory.max" "$config_file" 2>/dev/null | awk '{print $3}' || echo "无限")
        local swap=$(grep "swap.max" "$config_file" 2>/dev/null | awk '{print $3}' || echo "无限")
        local cpu=$(grep "cpuset.cpus" "$config_file" 2>/dev/null | awk '{print $3}' || echo "全部")
        
        local remark_tag=$(is_privileged "$container" && echo -e "${RED}[特]${NC} $remark" || echo -e "${GREEN}[非]${NC} $remark")
        
        printf "%-12s %-10s %-15s %-26b %-14b %-10s %-10s %-8s\n" "$container" "$state" "$ip" "$remark_tag" "$autostart" "$mem" "$swap" "$cpu"
    done
    
    echo "=========================================================================================================="
    
    press_enter
}

show_realtime_stats() {
    clear
    echo "=========================================="
    echo "   容器资源使用快照"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    printf "%-15s %-15s %-15s %-15s %-15s\n" "名称" "内存使用" "CPU时间" "运行时间" "磁盘占用"
    echo "----------------------------------------------------------------------------------------"
    
    for container in $(lxc-ls --running 2>/dev/null); do
        local info=$(lxc-info -n "$container" -H 2>/dev/null)
        local pid=$(lxc-info -n "$container" -p -H 2>/dev/null)
        
        local mem=$(echo "$info" | grep "Memory use" | awk '{print $3, $4}')
        [ -z "$mem" ] && mem="-"
        
        local disk=$(du -sh "/var/lib/lxc/$container/rootfs" 2>/dev/null | awk '{print $1}')
        [ -z "$disk" ] && disk="-"
        
        local uptime="-"
        if [ -n "$pid" ]; then
            uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
            [ -z "$uptime" ] && uptime="-"
        fi
        
        printf "%-15s %-15s %-15s %-15s %-15s\n" "$container" "$mem" "-" "$uptime" "$disk"
    done
    
    press_enter
}

clone_container() {
    clear
    echo "=========================================="
    echo "   克隆容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "源容器名称: " source
    read -p "新容器名称: " new_name
    
    if [ -z "$source" ] || [ -z "$new_name" ]; then
        print_error "容器名称不能为空"
        press_enter
        return
    fi
    
    print_info "正在克隆容器..."
    
    lxc-copy -n "$source" -N "$new_name"
    
    if [ $? -eq 0 ]; then
        print_success "克隆成功"
        
        local config_file="/var/lib/lxc/$new_name/config"
        
        # 删除旧的 MAC 地址和备注
        sed -i '/lxc.net.0.hwaddr/d; /# LXC_REMARK/d' "$config_file"
        
        # 生成新的 MAC 地址
        local new_mac=$(generate_new_mac)
        echo "lxc.net.0.hwaddr = $new_mac" >> "$config_file"
        
        print_info "新 MAC 地址: $new_mac"
        
        # 修改容器内的主机名
        if [ -f "/var/lib/lxc/$new_name/rootfs/etc/hostname" ]; then
            echo "$new_name" > "/var/lib/lxc/$new_name/rootfs/etc/hostname"
        fi
        
        print_success "克隆完成"
    else
        print_error "克隆失败"
    fi
    
    press_enter
}

# 其他功能函数
set_resource_limits() {
    clear
    echo "=========================================="
    echo "   设置资源限制"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    echo ""
    read -p "内存限制 (如 1G，留空跳过): " mem_limit
    
    if [ -n "$mem_limit" ]; then
        sed -i '/memory.max/d' "$config_file"
        echo "lxc.cgroup2.memory.max = $mem_limit" >> "$config_file"
        print_success "内存限制已设置: $mem_limit"
    fi
    
    press_enter
}

set_container_remark() {
    clear
    echo "=========================================="
    echo "   设置容器备注"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    read -p "备注信息: " remark
    
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    sed -i '/# LXC_REMARK/d' "$config_file"
    echo "# LXC_REMARK: $remark" >> "$config_file"
    
    print_success "备注已设置"
    
    press_enter
}

set_container_autostart() {
    clear
    echo "=========================================="
    echo "   设置开机自启"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    sed -i '/lxc.start/d' "$config_file"
    echo "lxc.start.auto = 1" >> "$config_file"
    
    print_success "开机自启已启用"
    
    press_enter
}

backup_container() {
    clear
    echo "=========================================="
    echo "   备份容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ ! -d "/var/lib/lxc/$container_name" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    local backup_file="/root/${container_name}_$(date +%F).tar.gz"
    
    print_info "正在备份容器..."
    tar czf "$backup_file" -C /var/lib/lxc "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "备份完成"
        echo ""
        echo "备份文件: $backup_file"
        echo "文件大小: $(du -h $backup_file | awk '{print $1}')"
    else
        print_error "备份失败"
    fi
    
    press_enter
}

restore_container() {
    clear
    echo "=========================================="
    echo "   恢复容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    read -p "备份文件路径: " backup_file
    
    if [ ! -f "$backup_file" ]; then
        print_error "备份文件不存在"
        press_enter
        return
    fi
    
    print_info "正在恢复容器..."
    tar xzf "$backup_file" -C /var/lib/lxc/
    
    if [ $? -eq 0 ]; then
        print_success "恢复完成"
    else
        print_error "恢复失败"
    fi
    
    press_enter
}

show_network_status() {
    clear
    echo "=========================================="
    echo "   网络状态"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_info "网桥信息："
    brctl show
    echo ""
    
    print_info "lxcbr0 接口信息："
    ip addr show lxcbr0
    echo ""
    
    press_enter
}

manage_port_forwards() {
    clear
    echo "=========================================="
    echo "   端口转发管理"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_info "当前端口转发规则："
    echo ""
    iptables -t nat -L PREROUTING -n -v --line-numbers
    echo ""
    
    echo "1. 删除规则"
    echo "2. 返回"
    echo ""
    read -p "请选择: " choice
    
    if [ "$choice" = "1" ]; then
        read -p "输入规则序号: " rule_num
        iptables -t nat -D PREROUTING "$rule_num"
        iptables-save > /etc/iptables/rules.v4
        print_success "规则已删除"
    fi
    
    press_enter
}

start_container() {
    clear
    echo "=========================================="
    echo "   启动容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "stopped"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_info "正在启动容器..."
    lxc-start -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已启动"
    else
        print_error "启动失败"
    fi
    
    press_enter
}

stop_container() {
    clear
    echo "=========================================="
    echo "   停止容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "running"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_info "正在停止容器..."
    lxc-stop -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已停止"
    else
        print_error "停止失败"
    fi
    
    press_enter
}

enter_container() {
    clear
    echo "=========================================="
    echo "   进入容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "running"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_info "进入容器 (输入 exit 退出)..."
    echo ""
    lxc-attach -n "$container_name"
}

delete_container() {
    clear
    echo "=========================================="
    echo "   删除容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    print_warning "警告：此操作将永久删除容器"
    read -p "确认删除？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "停止容器..."
    lxc-stop -n "$container_name" -k 2>/dev/null || true
    
    print_info "删除容器..."
    lxc-destroy -n "$container_name"
    
    if [ $? -eq 0 ]; then
        print_success "容器已删除"
    else
        print_error "删除失败"
    fi
    
    press_enter
}

delete_all_containers() {
    clear
    echo "=========================================="
    echo "   删除所有容器"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    print_error "危险操作：将删除所有容器"
    echo ""
    read -p "输入 DELETE 确认: " confirm
    
    if [ "$confirm" != "DELETE" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "删除所有容器..."
    
    for container in $(lxc-ls 2>/dev/null); do
        lxc-stop -n "$container" -k 2>/dev/null || true
        lxc-destroy -n "$container"
    done
    
    print_success "所有容器已删除"
    
    press_enter
}

debug_container_config() {
    clear
    echo "=========================================="
    echo "   查看容器配置"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    show_containers_simple "all"
    echo ""
    
    read -p "容器名称: " container_name
    
    if [ -z "$container_name" ]; then
        press_enter
        return
    fi
    
    local config_file="/var/lib/lxc/$container_name/config"
    
    if [ ! -f "$config_file" ]; then
        print_error "容器不存在"
        press_enter
        return
    fi
    
    echo ""
    print_info "配置文件内容："
    echo ""
    cat "$config_file"
    echo ""
    
    press_enter
}

# ==============================================================================
#                                   主菜单
# ==============================================================================

main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   LXC 容器管理 (v6.8)"
        echo "=========================================="
        echo ""
        
        # 显示安装状态
        if check_lxc_installed; then
            print_success "LXC 已安装"
            
            # 显示容器统计
            if check_root; then
                local total=$(lxc-ls 2>/dev/null | wc -w)
                local running=$(lxc-ls --running 2>/dev/null | wc -w)
                echo "  容器: ${running} 运行中 / ${total} 总计"
            fi
        else
            print_warning "LXC 未安装"
        fi
        
        echo ""
        echo -e "${BLUE}[基础环境]${NC}"
        echo "0.  安装 LXC 环境"
        echo "1.  配置网络桥接 (10.0.0.0/24)"
        echo "2.  配置宿主机 Swap"
        echo ""
        echo -e "${BLUE}[日常管理]${NC}"
        echo "3.  创建 Debian 12 容器"
        echo "4.  启动容器"
        echo "5.  停止容器"
        echo "6.  进入容器"
        echo "7.  删除容器"
        echo "8.  克隆容器"
        echo ""
        echo -e "${BLUE}[配置修改]${NC}"
        echo "9.  设置资源限制"
        echo "10. 设置静态 IP"
        echo "11. 设置容器备注"
        echo "12. 设置开机自启"
        echo "20. 切换特权模式"
        echo ""
        echo -e "${BLUE}[数据维护]${NC}"
        echo "13. 备份容器"
        echo "14. 恢复容器"
        echo "22. 删除所有容器 (危险)"
        echo ""
        echo -e "${CYAN}[监控面板]${NC}"
        echo "15. 查看网络状态"
        echo "16. 端口转发管理"
        echo "17. 全景控制台"
        echo "18. 资源使用快照"
        echo "19. 配置端口转发"
        echo "23. 查看容器配置 (调试)"
        echo ""
        echo "0.  返回主菜单"
        echo ""
        echo "=========================================="
        read -p "请选择操作: " choice
        
        case $choice in
            0) install_lxc ;;
            1) setup_network_bridge ;;
            2) configure_host_swap ;;
            3) create_debian12 ;;
            4) start_container ;;
            5) stop_container ;;
            6) enter_container ;;
            7) delete_container ;;
            8) clone_container ;;
            9) set_resource_limits ;;
            10) set_static_ip ;;
            11) set_container_remark ;;
            12) set_container_autostart ;;
            13) backup_container ;;
            14) restore_container ;;
            15) show_network_status ;;
            16) manage_port_forwards ;;
            17) show_dashboard ;;
            18) show_realtime_stats ;;
            19) setup_port_forward ;;
            20) toggle_privileged ;;
            22) delete_all_containers ;;
            23) debug_container_config ;;
            0) exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main_menu
