#!/bin/bash
set -euo pipefail

# ============================================
# Debian 12 系统配置工具 - 主菜单
# ============================================

# GitHub 配置
GITHUB_USER="wyrover"
GITHUB_REPO="vps-setup"
GITHUB_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# 直接执行在线子脚本（改进版）
run_subscript() {
    local script_name=$1
    local script_url="${BASE_URL}/scripts/${script_name}.sh"
    
    echo ""
    print_info "正在加载模块: ${script_name}..."
    
    # 直接执行，不捕获退出码
    bash <(curl -fsSL "$script_url")
    
    # 或者简单捕获但不处理
    # bash <(curl -fsSL "$script_url") || true
    
    return 0
}

# 测试连接
test_connection() {
    echo ""
    print_info "测试 GitHub 连接..."
    
    local test_url="${BASE_URL}/scripts/system.sh"
    
    if curl -fsSL --head "$test_url" &> /dev/null; then
        print_success "GitHub 连接正常"
        echo "  测试URL: ${test_url}"
        return 0
    else
        print_error "无法连接到 GitHub"
        print_warning "可能的原因："
        echo "  1. 仓库不存在或为私有仓库"
        echo "  2. 网络连接问题"
        echo "  3. 文件路径错误"
        echo ""
        echo "当前配置："
        echo "  仓库: ${GITHUB_USER}/${GITHUB_REPO}"
        echo "  分支: ${GITHUB_BRANCH}"
        echo "  测试URL: ${test_url}"
        return 1
    fi
}

# ============================================
# 主菜单
# ============================================

show_main_menu() {
    clear
    echo "=========================================="
    echo "   Debian 12 系统配置工具 - 主菜单"
    echo "=========================================="
    echo ""
    echo "【分类菜单】"
    echo ""
    echo "1. 🔒 安全配置"
    echo "   (SSH密钥、Fail2ban、防火墙等)"
    echo ""
    echo "2. ⚙️  系统配置"
    echo "   (Hostname、时区、软件包等)"
    echo ""
    echo "3. 📊 监控查看"
    echo "   (Fail2ban状态、防火墙状态、系统信息等)"
    echo ""
    echo "4. 🌐 网络配置"
    echo "   (网络接口、路由、DNS等)"
    echo ""
    echo "9. 🔧 测试连接"
    echo "0. 退出"
    echo ""
    echo "=========================================="
    echo "GitHub: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo "=========================================="
}

main_menu() {
    while true; do
        show_main_menu
        read -p "请选择分类 [0-9]: " choice
        
        case $choice in
            1)
                run_subscript "security"
                ;;
            2)
                run_subscript "system"
                ;;
            3)
                run_subscript "monitoring"
                ;;
            4)
                run_subscript "network"
                ;;
            9)
                test_connection
                read -p "按 Enter 键继续..."
                ;;
            0)
                echo ""
                print_info "感谢使用，再见！"
                exit 0
                ;;
            *)
                print_error "无效选择，请重新输入"
                sleep 2
                ;;
        esac
    done
}

# ============================================
# 脚本入口
# ============================================

# 检查依赖
if ! command -v curl &> /dev/null; then
    print_error "未找到 curl 命令，请先安装: sudo apt install curl"
    exit 1
fi

# 显示欢迎信息
clear
echo "=========================================="
echo "   欢迎使用 Debian 12 系统配置工具"
echo "=========================================="
echo ""
print_info "正在初始化..."
sleep 1

# 启动主菜单
main_menu
