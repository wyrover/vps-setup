#!/bin/bash
set -euo pipefail

# ============================================
# 安全配置子菜单
# ============================================

# 配置
PUBKEY="${SSH_PUBKEY:-YOUR_SSH_PUBLIC_KEY_HERE}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_DIR="$HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
FAIL2BAN_JAIL="/etc/fail2ban/jail.local"
MAX_RETRY=3

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }

# ============================================
# 功能函数
# ============================================

# 功能 1: 添加 SSH 公钥
setup_ssh_key() {
    echo ""
    echo "=========================================="
    echo "添加 SSH 公钥"
    echo "=========================================="
    
    # 检查公钥
    if [[ "$PUBKEY" == "YOUR_SSH_PUBLIC_KEY_HERE" ]]; then
        echo "请输入 SSH 公钥（完整的一行）："
        read -r PUBKEY
        
        if [[ -z "$PUBKEY" ]]; then
            print_error "公钥不能为空"
            read -p "按 Enter 键返回..."
            return 1
        fi
    fi
    
    # 检查 SSH 配置
    echo "[步骤 1/3] 检查 SSH 服务器配置..."
    
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        print_error "未找到 $SSHD_CONFIG"
        read -p "按 Enter 键返回..."
        return 1
    fi
    
    NEEDS_RESTART=false
    
    if grep -q "^PubkeyAuthentication no" "$SSHD_CONFIG"; then
        sudo sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSHD_CONFIG"
        NEEDS_RESTART=true
    elif grep -q "^#PubkeyAuthentication" "$SSHD_CONFIG"; then
        sudo sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
        NEEDS_RESTART=true
    elif grep -q "^PubkeyAuthentication yes" "$SSHD_CONFIG"; then
        print_success "公钥认证已启用"
    else
        echo "PubkeyAuthentication yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        NEEDS_RESTART=true
    fi
    
    # 重启 SSH 服务
    echo ""
    echo "[步骤 2/3] 应用 SSH 配置..."
    
    if $NEEDS_RESTART; then
        if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
            print_success "SSH 服务已重启"
        else
            print_error "SSH 服务重启失败"
            read -p "按 Enter 键返回..."
            return 1
        fi
    else
        print_success "无需重启 SSH 服务"
    fi
    
    # 添加公钥
    echo ""
    echo "[步骤 3/3] 添加公钥到 authorized_keys..."
    
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTHORIZED_KEYS"
    chmod 600 "$AUTHORIZED_KEYS"
    
    if grep -qF "$PUBKEY" "$AUTHORIZED_KEYS"; then
        print_success "公钥已存在"
    else
        echo "$PUBKEY" >> "$AUTHORIZED_KEYS"
        print_success "公钥添加成功"
    fi
    
    echo ""
    print_success "SSH 公钥配置完成！"
    read -p "按 Enter 键返回..."
}

# 功能 2: 安装配置 Fail2ban
setup_fail2ban() {
    echo ""
    echo "=========================================="
    echo "安装和配置 Fail2ban"
    echo "=========================================="
    
    echo "[步骤 1/4] 检查安装状态..."
    
    if command -v fail2ban-client &> /dev/null; then
        print_success "Fail2ban 已安装"
    else
        print_warning "Fail2ban 未安装，正在安装..."
        sudo apt update
        sudo apt install -y fail2ban
        print_success "安装完成"
    fi
    
    echo ""
    echo "[步骤 2/4] 配置 Fail2ban..."
    
    if [[ -f "$FAIL2BAN_JAIL" ]]; then
        sudo cp "$FAIL2BAN_JAIL" "${FAIL2BAN_JAIL}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    sudo tee "$FAIL2BAN_JAIL" > /dev/null <<EOF
[DEFAULT]
bantime = -1
findtime = 10m
maxretry = $MAX_RETRY
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
mode = aggressive
EOF

    print_success "配置文件已创建"
    
    echo ""
    echo "[步骤 3/4] 启动服务..."
    
    sudo systemctl enable fail2ban
    sudo systemctl restart fail2ban
    print_success "Fail2ban 服务已启动"
    
    echo ""
    echo "[步骤 4/4] 验证配置..."
    sleep 2
    
    if sudo fail2ban-client status sshd &> /dev/null; then
        print_success "SSH 保护已启用"
        sudo fail2ban-client status sshd
    fi
    
    echo ""
    print_success "Fail2ban 配置完成！"
    read -p "按 Enter 键返回..."
}

# 功能 3: 配置防火墙
setup_firewall() {
    echo ""
    echo "=========================================="
    echo "安装和配置防火墙（UFW）"
    echo "=========================================="
    
    echo "[步骤 1/5] 检查安装状态..."
    
    if command -v ufw &> /dev/null; then
        print_success "UFW 已安装"
    else
        print_warning "UFW 未安装，正在安装..."
        sudo apt update
        sudo apt install -y ufw
        print_success "安装完成"
    fi
    
    echo ""
    echo "[步骤 2/5] 配置规则..."
    
    read -p "是否重置现有规则？[y/N]: " reset
    if [[ "$reset" =~ ^[Yy]$ ]]; then
        echo "y" | sudo ufw reset
        print_success "规则已重置"
    fi
    
    echo ""
    echo "[步骤 3/5] 设置默认策略..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    print_success "默认策略已设置"
    
    echo ""
    echo "[步骤 4/5] 添加端口规则..."
    sudo ufw allow 22/tcp comment 'SSH'
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'
    print_success "端口 22、80、443 已开放"
    
    echo ""
    echo "[步骤 5/5] 启用防火墙..."
    
    echo ""
    print_warning "启用防火墙后，只有允许的端口可以访问！"
    read -p "确认启用？[y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "y" | sudo ufw enable
        sudo systemctl enable ufw
        print_success "防火墙已启用"
    else
        print_warning "已取消启用"
    fi
    
    echo ""
    sudo ufw status verbose
    read -p "按 Enter 键返回..."
}

# 功能 4: 一键安全加固
quick_security() {
    echo ""
    echo "=========================================="
    echo "一键安全加固"
    echo "=========================================="
    echo ""
    echo "将依次执行："
    echo "1. 配置 SSH 公钥"
    echo "2. 安装配置 Fail2ban"
    echo "3. 安装配置防火墙"
    echo ""
    read -p "确认继续？[y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        setup_ssh_key
        setup_fail2ban
        setup_firewall
        echo ""
        print_success "一键安全加固完成！"
        read -p "按 Enter 键返回..."
    fi
}

# ============================================
# 安全配置子菜单
# ============================================

show_security_menu() {
    clear
    echo "=========================================="
    echo "   安全配置菜单"
    echo "=========================================="
    echo ""
    echo "1. 添加 SSH 公钥（启用密钥认证）"
    echo "2. 安装配置 Fail2ban（3次失败永久封禁）"
    echo "3. 安装配置防火墙（默认开放22/80/443）"
    echo "4. 一键安全加固（执行1+2+3）"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}

security_menu() {
    while true; do
        show_security_menu
        read -p "请选择操作 [0-4]: " choice
        
        case $choice in
            1)
                setup_ssh_key
                ;;
            2)
                setup_fail2ban
                ;;
            3)
                setup_firewall
                ;;
            4)
                quick_security
                ;;
            0)
                echo ""
                print_success "返回主菜单"
                sleep 1
                return 0
                ;;
            *)
                print_error "无效选择"
                sleep 2
                ;;
        esac
    done
}

# 启动安全配置菜单
security_menu
