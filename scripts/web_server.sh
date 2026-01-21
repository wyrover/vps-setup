#!/bin/bash

# ============================================
# Web 服务器管理脚本
# 支持 OpenResty、Nginx 和 Caddy
# ============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

# ============================================
# OpenResty 管理函数
# ============================================

# 检查 OpenResty 是否安装
check_openresty() {
    if [ -f /usr/local/openresty/nginx/sbin/nginx ]; then
        return 0
    else
        return 1
    fi
}

# 安装 OpenResty
install_openresty() {
    clear
    echo "=========================================="
    echo "   安装 OpenResty"
    echo "=========================================="
    echo ""
    
    if check_openresty; then
        print_warning "OpenResty 已安装"
        /usr/local/openresty/nginx/sbin/nginx -v
        press_enter
        return
    fi
    
    print_info "正在安装依赖..."
    echo ""
    
    sudo apt update
    sudo apt install -y wget gnupg ca-certificates lsb-release
    
    # 添加 OpenResty APT 仓库
    print_info "添加 OpenResty 仓库..."
    wget -O - https://openresty.org/package/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/openresty.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $(lsb_release -sc) openresty" | \
        sudo tee /etc/apt/sources.list.d/openresty.list
    
    # 安装 OpenResty
    print_info "正在安装 OpenResty..."
    sudo apt update
    sudo apt install -y openresty
    
    if [ $? -eq 0 ]; then
        print_success "OpenResty 安装成功"
        echo ""
        /usr/local/openresty/nginx/sbin/nginx -v
        
        # 检查服务是否已存在
        if systemctl list-unit-files | grep -q openresty.service; then
            print_success "systemd 服务已自动创建"
        else
            print_warning "未检测到 systemd 服务，尝试手动创建..."
            create_openresty_service
        fi
        
        # 启动服务
        sudo systemctl start openresty
        sudo systemctl enable openresty
        
        print_success "OpenResty 服务已启动并设置为开机自启"
        
        # 显示服务状态
        echo ""
        print_info "服务状态："
        sudo systemctl status openresty --no-pager -l | head -n 10
    else
        print_error "OpenResty 安装失败"
    fi
    
    press_enter
}

# 创建 OpenResty systemd 服务（备用方案）
create_openresty_service() {
    print_info "创建 systemd 服务..."
    
    sudo tee /etc/systemd/system/openresty.service > /dev/null << 'EOF'
[Unit]
Description=OpenResty Web Server
Documentation=https://openresty.org/
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/openresty/nginx/logs/nginx.pid
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t
ExecStart=/usr/local/openresty/nginx/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    print_success "systemd 服务已创建"
}

# 创建 OpenResty 站点配置
create_openresty_site() {
    clear
    echo "=========================================="
    echo "   创建 OpenResty 站点"
    echo "=========================================="
    echo ""
    
    read -p "站点域名 (例如: example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    read -p "网站根目录 (默认: /var/www/${domain}): " webroot
    webroot=${webroot:-/var/www/${domain}}
    
    read -p "监听端口 (默认: 80): " port
    port=${port:-80}
    
    # 创建网站目录
    sudo mkdir -p "$webroot"
    sudo chown -R www-data:www-data "$webroot"
    
    # 创建默认 index.html
    sudo tee "$webroot/index.html" > /dev/null << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to ${domain}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>Welcome to ${domain}</h1>
    <p>This site is powered by OpenResty.</p>
</body>
</html>
EOF
    
    # 创建配置文件目录
    sudo mkdir -p /usr/local/openresty/nginx/conf/sites-available
    sudo mkdir -p /usr/local/openresty/nginx/conf/sites-enabled
    
    # 创建站点配置
    local config_file="/usr/local/openresty/nginx/conf/sites-available/${domain}.conf"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen ${port};
    server_name ${domain} www.${domain};
    
    root ${webroot};
    index index.html index.htm;
    
    access_log /usr/local/openresty/nginx/logs/${domain}-access.log;
    error_log /usr/local/openresty/nginx/logs/${domain}-error.log;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 静态文件缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
    
    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
    }
}
EOF
    
    # 创建软链接启用站点
    sudo ln -sf "$config_file" "/usr/local/openresty/nginx/conf/sites-enabled/${domain}.conf"
    
    # 更新主配置文件包含站点配置
    if ! grep -q "sites-enabled" /usr/local/openresty/nginx/conf/nginx.conf; then
        sudo sed -i '/http {/a \    include /usr/local/openresty/nginx/conf/sites-enabled/*.conf;' \
            /usr/local/openresty/nginx/conf/nginx.conf
    fi
    
    # 测试配置
    if sudo /usr/local/openresty/nginx/sbin/nginx -t; then
        sudo systemctl reload openresty
        print_success "站点创建成功"
        echo ""
        echo "站点信息："
        echo "  域名: ${domain}"
        echo "  根目录: ${webroot}"
        echo "  端口: ${port}"
        echo "  配置文件: ${config_file}"
        echo ""
        print_info "请确保域名已解析到服务器IP"
    else
        print_error "配置文件有误"
        sudo rm -f "/usr/local/openresty/nginx/conf/sites-enabled/${domain}.conf"
    fi
    
    press_enter
}

# 列出 OpenResty 站点
list_openresty_sites() {
    clear
    echo "=========================================="
    echo "   OpenResty 站点列表"
    echo "=========================================="
    echo ""
    
    local sites_dir="/usr/local/openresty/nginx/conf/sites-enabled"
    
    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A $sites_dir 2>/dev/null)" ]; then
        print_warning "没有已启用的站点"
        press_enter
        return
    fi
    
    print_info "已启用的站点："
    echo ""
    
    for conf in "$sites_dir"/*.conf; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .conf)
            local port=$(grep -m 1 "listen" "$conf" | awk '{print $2}' | tr -d ';')
            local root=$(grep "root" "$conf" | awk '{print $2}' | tr -d ';')
            
            echo -e "${GREEN}●${NC} ${domain}"
            echo "   端口: ${port}"
            echo "   根目录: ${root}"
            echo ""
        fi
    done
    
    press_enter
}

# 删除 OpenResty 站点
delete_openresty_site() {
    clear
    echo "=========================================="
    echo "   删除 OpenResty 站点"
    echo "=========================================="
    echo ""
    
    local sites_dir="/usr/local/openresty/nginx/conf/sites-enabled"
    
    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A $sites_dir 2>/dev/null)" ]; then
        print_warning "没有可删除的站点"
        press_enter
        return
    fi
    
    print_info "已启用的站点："
    echo ""
    
    local i=1
    declare -A site_map
    
    for conf in "$sites_dir"/*.conf; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .conf)
            echo "${i}. ${domain}"
            site_map[$i]="$domain"
            ((i++))
        fi
    done
    
    echo ""
    read -p "选择要删除的站点编号: " choice
    
    local selected_domain="${site_map[$choice]}"
    
    if [ -z "$selected_domain" ]; then
        print_error "无效选择"
        press_enter
        return
    fi
    
    # 获取网站根目录
    local webroot=$(grep "root" "/usr/local/openresty/nginx/conf/sites-available/${selected_domain}.conf" 2>/dev/null | awk '{print $2}' | tr -d ';')
    
    print_warning "警告：此操作将删除站点配置"
    read -p "确认删除 ${selected_domain}？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 删除配置文件
    sudo rm -f "/usr/local/openresty/nginx/conf/sites-enabled/${selected_domain}.conf"
    sudo rm -f "/usr/local/openresty/nginx/conf/sites-available/${selected_domain}.conf"
    
    # 重载配置
    if sudo /usr/local/openresty/nginx/sbin/nginx -t; then
        sudo systemctl reload openresty
        print_success "站点已删除"
        
        echo ""
        read -p "是否同时删除网站文件？(yes/no): " delete_files
        if [ "$delete_files" = "yes" ] && [ -n "$webroot" ] && [ -d "$webroot" ]; then
            sudo rm -rf "$webroot"
            print_success "网站文件已删除"
        fi
    else
        print_error "配置重载失败"
    fi
    
    press_enter
}

# OpenResty 服务管理
manage_openresty_service() {
    clear
    echo "=========================================="
    echo "   OpenResty 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 重载配置"
    echo "6. 测试配置"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-6]: " choice
    
    case $choice in
        1)
            sudo systemctl status openresty --no-pager -l
            ;;
        2)
            sudo systemctl start openresty
            print_success "OpenResty 服务已启动"
            ;;
        3)
            sudo systemctl stop openresty
            print_success "OpenResty 服务已停止"
            ;;
        4)
            sudo systemctl restart openresty
            print_success "OpenResty 服务已重启"
            ;;
        5)
            if sudo /usr/local/openresty/nginx/sbin/nginx -t; then
                sudo systemctl reload openresty
                print_success "配置已重载"
            else
                print_error "配置测试失败，未重载"
            fi
            ;;
        6)
            sudo /usr/local/openresty/nginx/sbin/nginx -t
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# 查看 OpenResty 日志
view_openresty_logs() {
    clear
    echo "=========================================="
    echo "   OpenResty 日志查看"
    echo "=========================================="
    echo ""
    
    echo "1. 访问日志 (access.log)"
    echo "2. 错误日志 (error.log)"
    echo "3. 站点访问日志"
    echo "4. 站点错误日志"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    local log_dir="/usr/local/openresty/nginx/logs"
    
    case $choice in
        1)
            echo ""
            print_info "最近100行访问日志："
            echo ""
            sudo tail -n 100 "$log_dir/access.log"
            ;;
        2)
            echo ""
            print_info "最近100行错误日志："
            echo ""
            sudo tail -n 100 "$log_dir/error.log"
            ;;
        3)
            echo ""
            print_info "可用的站点日志："
            ls -1 "$log_dir"/*-access.log 2>/dev/null | xargs -n 1 basename
            echo ""
            read -p "输入站点名称: " site
            if [ -f "$log_dir/${site}-access.log" ]; then
                sudo tail -n 100 "$log_dir/${site}-access.log"
            else
                print_error "日志文件不存在"
            fi
            ;;
        4)
            echo ""
            print_info "可用的站点日志："
            ls -1 "$log_dir"/*-error.log 2>/dev/null | xargs -n 1 basename
            echo ""
            read -p "输入站点名称: " site
            if [ -f "$log_dir/${site}-error.log" ]; then
                sudo tail -n 100 "$log_dir/${site}-error.log"
            else
                print_error "日志文件不存在"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# OpenResty 子菜单
openresty_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   OpenResty 管理"
        echo "=========================================="
        echo ""
        
        if check_openresty; then
            print_success "OpenResty 已安装"
            openresty_version=$(/usr/local/openresty/nginx/sbin/nginx -v 2>&1 | awk -F'/' '{print $2}')
            echo "  版本: ${openresty_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet openresty; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "OpenResty 未安装"
        fi
        
        echo ""
        echo "1. 安装 OpenResty"
        echo "2. 创建站点"
        echo "3. 列出站点"
        echo "4. 删除站点"
        echo "5. 服务管理"
        echo "6. 查看日志"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-6]: " choice
        
        case $choice in
            1) install_openresty ;;
            2) create_openresty_site ;;
            3) list_openresty_sites ;;
            4) delete_openresty_site ;;
            5) manage_openresty_service ;;
            6) view_openresty_logs ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============================================
# Nginx 管理函数
# ============================================

# 检查 Nginx 是否安装
check_nginx() {
    if command -v nginx &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 安装 Nginx
install_nginx() {
    clear
    echo "=========================================="
    echo "   安装 Nginx"
    echo "=========================================="
    echo ""
    
    if check_nginx; then
        print_warning "Nginx 已安装"
        nginx -v
        press_enter
        return
    fi
    
    print_info "正在安装 Nginx..."
    echo ""
    
    sudo apt update
    sudo apt install -y nginx
    
    if [ $? -eq 0 ]; then
        print_success "Nginx 安装成功"
        echo ""
        nginx -v
        
        # 启动服务
        sudo systemctl start nginx
        sudo systemctl enable nginx
        
        print_success "Nginx 服务已启动并设置为开机自启"
    else
        print_error "Nginx 安装失败"
    fi
    
    press_enter
}

# 创建 Nginx 站点
create_nginx_site() {
    clear
    echo "=========================================="
    echo "   创建 Nginx 站点"
    echo "=========================================="
    echo ""
    
    read -p "站点域名 (例如: example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    read -p "网站根目录 (默认: /var/www/${domain}): " webroot
    webroot=${webroot:-/var/www/${domain}}
    
    read -p "监听端口 (默认: 80): " port
    port=${port:-80}
    
    # 创建网站目录
    sudo mkdir -p "$webroot"
    sudo chown -R www-data:www-data "$webroot"
    
    # 创建默认 index.html
    sudo tee "$webroot/index.html" > /dev/null << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to ${domain}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>Welcome to ${domain}</h1>
    <p>This site is powered by Nginx.</p>
</body>
</html>
EOF
    
    # 创建站点配置
    local config_file="/etc/nginx/sites-available/${domain}"
    
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen ${port};
    server_name ${domain} www.${domain};
    
    root ${webroot};
    index index.html index.htm index.php;
    
    access_log /var/log/nginx/${domain}-access.log;
    error_log /var/log/nginx/${domain}-error.log;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # PHP 支持 (如需要，取消注释)
    # location ~ \.php$ {
    #     include snippets/fastcgi-php.conf;
    #     fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
    # }
    
    # 静态文件缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
    
    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
    }
}
EOF
    
    # 创建软链接启用站点
    sudo ln -sf "$config_file" "/etc/nginx/sites-enabled/${domain}"
    
    # 测试配置
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_success "站点创建成功"
        echo ""
        echo "站点信息："
        echo "  域名: ${domain}"
        echo "  根目录: ${webroot}"
        echo "  端口: ${port}"
        echo "  配置文件: ${config_file}"
        echo ""
        print_info "请确保域名已解析到服务器IP"
    else
        print_error "配置文件有误"
        sudo rm -f "/etc/nginx/sites-enabled/${domain}"
    fi
    
    press_enter
}

# 列出 Nginx 站点
list_nginx_sites() {
    clear
    echo "=========================================="
    echo "   Nginx 站点列表"
    echo "=========================================="
    echo ""
    
    local sites_dir="/etc/nginx/sites-enabled"
    
    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A $sites_dir 2>/dev/null)" ]; then
        print_warning "没有已启用的站点"
        press_enter
        return
    fi
    
    print_info "已启用的站点："
    echo ""
    
    for conf in "$sites_dir"/*; do
        if [ -f "$conf" ] && [ "$(basename $conf)" != "default" ]; then
            local domain=$(basename "$conf")
            local port=$(grep -m 1 "listen" "$conf" | awk '{print $2}' | tr -d ';')
            local root=$(grep "root" "$conf" | awk '{print $2}' | tr -d ';')
            
            echo -e "${GREEN}●${NC} ${domain}"
            echo "   端口: ${port}"
            echo "   根目录: ${root}"
            echo ""
        fi
    done
    
    press_enter
}

# 删除 Nginx 站点
delete_nginx_site() {
    clear
    echo "=========================================="
    echo "   删除 Nginx 站点"
    echo "=========================================="
    echo ""
    
    local sites_dir="/etc/nginx/sites-enabled"
    
    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A $sites_dir 2>/dev/null)" ]; then
        print_warning "没有可删除的站点"
        press_enter
        return
    fi
    
    print_info "已启用的站点："
    echo ""
    
    local i=1
    declare -A site_map
    
    for conf in "$sites_dir"/*; do
        if [ -f "$conf" ] && [ "$(basename $conf)" != "default" ]; then
            local domain=$(basename "$conf")
            echo "${i}. ${domain}"
            site_map[$i]="$domain"
            ((i++))
        fi
    done
    
    echo ""
    read -p "选择要删除的站点编号: " choice
    
    local selected_domain="${site_map[$choice]}"
    
    if [ -z "$selected_domain" ]; then
        print_error "无效选择"
        press_enter
        return
    fi
    
    # 获取网站根目录
    local webroot=$(grep "root" "/etc/nginx/sites-available/${selected_domain}" 2>/dev/null | awk '{print $2}' | tr -d ';')
    
    print_warning "警告：此操作将删除站点配置"
    read -p "确认删除 ${selected_domain}？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 删除配置文件
    sudo rm -f "/etc/nginx/sites-enabled/${selected_domain}"
    sudo rm -f "/etc/nginx/sites-available/${selected_domain}"
    
    # 重载配置
    if sudo nginx -t; then
        sudo systemctl reload nginx
        print_success "站点已删除"
        
        echo ""
        read -p "是否同时删除网站文件？(yes/no): " delete_files
        if [ "$delete_files" = "yes" ] && [ -n "$webroot" ] && [ -d "$webroot" ]; then
            sudo rm -rf "$webroot"
            print_success "网站文件已删除"
        fi
    else
        print_error "配置重载失败"
    fi
    
    press_enter
}

# Nginx 服务管理
manage_nginx_service() {
    clear
    echo "=========================================="
    echo "   Nginx 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 重载配置"
    echo "6. 测试配置"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-6]: " choice
    
    case $choice in
        1)
            sudo systemctl status nginx --no-pager -l
            ;;
        2)
            sudo systemctl start nginx
            print_success "Nginx 服务已启动"
            ;;
        3)
            sudo systemctl stop nginx
            print_success "Nginx 服务已停止"
            ;;
        4)
            sudo systemctl restart nginx
            print_success "Nginx 服务已重启"
            ;;
        5)
            if sudo nginx -t; then
                sudo systemctl reload nginx
                print_success "配置已重载"
            else
                print_error "配置测试失败，未重载"
            fi
            ;;
        6)
            sudo nginx -t
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# 查看 Nginx 日志
view_nginx_logs() {
    clear
    echo "=========================================="
    echo "   Nginx 日志查看"
    echo "=========================================="
    echo ""
    
    echo "1. 访问日志 (access.log)"
    echo "2. 错误日志 (error.log)"
    echo "3. 站点访问日志"
    echo "4. 站点错误日志"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    local log_dir="/var/log/nginx"
    
    case $choice in
        1)
            echo ""
            print_info "最近100行访问日志："
            echo ""
            sudo tail -n 100 "$log_dir/access.log"
            ;;
        2)
            echo ""
            print_info "最近100行错误日志："
            echo ""
            sudo tail -n 100 "$log_dir/error.log"
            ;;
        3)
            echo ""
            print_info "可用的站点日志："
            ls -1 "$log_dir"/*-access.log 2>/dev/null | xargs -n 1 basename
            echo ""
            read -p "输入站点名称: " site
            if [ -f "$log_dir/${site}-access.log" ]; then
                sudo tail -n 100 "$log_dir/${site}-access.log"
            else
                print_error "日志文件不存在"
            fi
            ;;
        4)
            echo ""
            print_info "可用的站点日志："
            ls -1 "$log_dir"/*-error.log 2>/dev/null | xargs -n 1 basename
            echo ""
            read -p "输入站点名称: " site
            if [ -f "$log_dir/${site}-error.log" ]; then
                sudo tail -n 100 "$log_dir/${site}-error.log"
            else
                print_error "日志文件不存在"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Nginx 子菜单
nginx_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   Nginx 管理"
        echo "=========================================="
        echo ""
        
        if check_nginx; then
            print_success "Nginx 已安装"
            nginx_version=$(nginx -v 2>&1 | awk -F'/' '{print $2}')
            echo "  版本: ${nginx_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet nginx; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "Nginx 未安装"
        fi
        
        echo ""
        echo "1. 安装 Nginx"
        echo "2. 创建站点"
        echo "3. 列出站点"
        echo "4. 删除站点"
        echo "5. 服务管理"
        echo "6. 查看日志"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-6]: " choice
        
        case $choice in
            1) install_nginx ;;
            2) create_nginx_site ;;
            3) list_nginx_sites ;;
            4) delete_nginx_site ;;
            5) manage_nginx_service ;;
            6) view_nginx_logs ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============================================
# Caddy 管理函数
# ============================================

# 检查 Caddy 是否安装
check_caddy() {
    if command -v caddy &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 安装 Caddy
install_caddy() {
    clear
    echo "=========================================="
    echo "   安装 Caddy"
    echo "=========================================="
    echo ""
    
    if check_caddy; then
        print_warning "Caddy 已安装"
        caddy version
        press_enter
        return
    fi
    
    print_info "正在安装依赖..."
    echo ""
    
    sudo apt update
    sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
    
    # 添加 Caddy 官方仓库
    print_info "添加 Caddy 仓库..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
    
    # 安装 Caddy
    print_info "正在安装 Caddy..."
    sudo apt update
    sudo apt install -y caddy
    
    if [ $? -eq 0 ]; then
        print_success "Caddy 安装成功"
        echo ""
        caddy version
        
        # Caddy 安装后会自动创建 systemd 服务
        print_success "systemd 服务已自动创建"
        
        # 启动服务
        sudo systemctl enable caddy
        sudo systemctl start caddy
        
        print_success "Caddy 服务已启动并设置为开机自启"
        
        # 显示服务状态
        echo ""
        print_info "服务状态："
        sudo systemctl status caddy --no-pager -l | head -n 10
    else
        print_error "Caddy 安装失败"
    fi
    
    press_enter
}

# 创建 Caddy 站点
create_caddy_site() {
    clear
    echo "=========================================="
    echo "   创建 Caddy 站点"
    echo "=========================================="
    echo ""
    
    read -p "站点域名 (例如: example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    read -p "网站根目录 (默认: /var/www/${domain}): " webroot
    webroot=${webroot:-/var/www/${domain}}
    
    read -p "是否启用自动 HTTPS (Let's Encrypt)? (y/n): " enable_https
    
    # 创建网站目录
    sudo mkdir -p "$webroot"
    sudo chown -R caddy:caddy "$webroot"
    
    # 创建默认 index.html
    sudo tee "$webroot/index.html" > /dev/null << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to ${domain}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>Welcome to ${domain}</h1>
    <p>This site is powered by Caddy.</p>
</body>
</html>
EOF
    
    # 创建 Caddy 配置目录
    sudo mkdir -p /etc/caddy/sites
    
    # 创建站点配置
    local config_file="/etc/caddy/sites/${domain}.caddy"
    
    if [ "$enable_https" = "y" ] || [ "$enable_https" = "Y" ]; then
        # 启用 HTTPS（自动获取证书）
        sudo tee "$config_file" > /dev/null << EOF
${domain} {
    root * ${webroot}
    file_server
    
    # 日志
    log {
        output file /var/log/caddy/${domain}-access.log
    }
    
    # 编码
    encode gzip
    
    # 错误页面
    handle_errors {
        @404 {
            expression {http.error.status_code} == 404
        }
        rewrite @404 /404.html
    }
}
EOF
    else
        # 仅 HTTP
        sudo tee "$config_file" > /dev/null << EOF
http://${domain} {
    root * ${webroot}
    file_server
    
    # 日志
    log {
        output file /var/log/caddy/${domain}-access.log
    }
    
    # 编码
    encode gzip
}
EOF
    fi
    
    # 创建日志目录
    sudo mkdir -p /var/log/caddy
    sudo chown -R caddy:caddy /var/log/caddy
    
    # 更新主配置文件包含站点配置
    if ! grep -q "import sites/\*" /etc/caddy/Caddyfile; then
        echo "import sites/*" | sudo tee -a /etc/caddy/Caddyfile > /dev/null
    fi
    
    # 验证配置
    if sudo caddy validate --config /etc/caddy/Caddyfile; then
        sudo systemctl reload caddy
        print_success "站点创建成功"
        echo ""
        echo "站点信息："
        echo "  域名: ${domain}"
        echo "  根目录: ${webroot}"
        if [ "$enable_https" = "y" ] || [ "$enable_https" = "Y" ]; then
            echo "  协议: HTTPS (自动证书)"
            print_info "Caddy 将自动从 Let's Encrypt 获取 SSL 证书"
        else
            echo "  协议: HTTP"
        fi
        echo "  配置文件: ${config_file}"
        echo ""
        print_info "请确保域名已解析到服务器IP"
        if [ "$enable_https" = "y" ] || [ "$enable_https" = "Y" ]; then
            print_warning "HTTPS 需要域名能够正确解析到此服务器"
        fi
    else
        print_error "配置文件有误"
        sudo rm -f "$config_file"
    fi
    
    press_enter
}

# 列出 Caddy 站点
list_caddy_sites() {
    clear
    echo "=========================================="
    echo "   Caddy 站点列表"
    echo "=========================================="
    echo ""
    
    local sites_dir="/etc/caddy/sites"
    
    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A $sites_dir 2>/dev/null)" ]; then
        print_warning "没有已配置的站点"
        press_enter
        return
    fi
    
    print_info "已配置的站点："
    echo ""
    
    for conf in "$sites_dir"/*.caddy; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .caddy)
            local root=$(grep "root \*" "$conf" | awk '{print $3}')
            local protocol="HTTP"
            
            # 检查是否配置了 HTTPS
            if grep -q "^${domain} {" "$conf"; then
                protocol="HTTPS (自动证书)"
            fi
            
            echo -e "${GREEN}●${NC} ${domain}"
            echo "   协议: ${protocol}"
            echo "   根目录: ${root}"
            echo ""
        fi
    done
    
    press_enter
}

# 删除 Caddy 站点
delete_caddy_site() {
    clear
    echo "=========================================="
    echo "   删除 Caddy 站点"
    echo "=========================================="
    echo ""
    
    local sites_dir="/etc/caddy/sites"
    
    if [ ! -d "$sites_dir" ] || [ -z "$(ls -A $sites_dir 2>/dev/null)" ]; then
        print_warning "没有可删除的站点"
        press_enter
        return
    fi
    
    print_info "已配置的站点："
    echo ""
    
    local i=1
    declare -A site_map
    
    for conf in "$sites_dir"/*.caddy; do
        if [ -f "$conf" ]; then
            local domain=$(basename "$conf" .caddy)
            echo "${i}. ${domain}"
            site_map[$i]="$domain"
            ((i++))
        fi
    done
    
    echo ""
    read -p "选择要删除的站点编号: " choice
    
    local selected_domain="${site_map[$choice]}"
    
    if [ -z "$selected_domain" ]; then
        print_error "无效选择"
        press_enter
        return
    fi
    
    # 获取网站根目录
    local webroot=$(grep "root \*" "/etc/caddy/sites/${selected_domain}.caddy" 2>/dev/null | awk '{print $3}')
    
    print_warning "警告：此操作将删除站点配置"
    read -p "确认删除 ${selected_domain}？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 删除配置文件
    sudo rm -f "/etc/caddy/sites/${selected_domain}.caddy"
    
    # 重载配置
    if sudo caddy validate --config /etc/caddy/Caddyfile; then
        sudo systemctl reload caddy
        print_success "站点已删除"
        
        echo ""
        read -p "是否同时删除网站文件？(yes/no): " delete_files
        if [ "$delete_files" = "yes" ] && [ -n "$webroot" ] && [ -d "$webroot" ]; then
            sudo rm -rf "$webroot"
            print_success "网站文件已删除"
        fi
    else
        print_error "配置验证失败"
    fi
    
    press_enter
}

# Caddy 服务管理
manage_caddy_service() {
    clear
    echo "=========================================="
    echo "   Caddy 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 重载配置"
    echo "6. 验证配置"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-6]: " choice
    
    case $choice in
        1)
            sudo systemctl status caddy --no-pager -l
            ;;
        2)
            sudo systemctl start caddy
            print_success "Caddy 服务已启动"
            ;;
        3)
            sudo systemctl stop caddy
            print_success "Caddy 服务已停止"
            ;;
        4)
            sudo systemctl restart caddy
            print_success "Caddy 服务已重启"
            ;;
        5)
            if sudo caddy validate --config /etc/caddy/Caddyfile; then
                sudo systemctl reload caddy
                print_success "配置已重载"
            else
                print_error "配置验证失败，未重载"
            fi
            ;;
        6)
            sudo caddy validate --config /etc/caddy/Caddyfile
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# 查看 Caddy 日志
view_caddy_logs() {
    clear
    echo "=========================================="
    echo "   Caddy 日志查看"
    echo "=========================================="
    echo ""
    
    echo "1. 系统日志 (journalctl)"
    echo "2. 站点访问日志"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-2]: " choice
    
    case $choice in
        1)
            echo ""
            print_info "最近100行系统日志："
            echo ""
            sudo journalctl -u caddy -n 100 --no-pager
            ;;
        2)
            echo ""
            print_info "可用的站点日志："
            ls -1 /var/log/caddy/*-access.log 2>/dev/null | xargs -n 1 basename
            echo ""
            read -p "输入站点名称: " site
            if [ -f "/var/log/caddy/${site}-access.log" ]; then
                sudo tail -n 100 "/var/log/caddy/${site}-access.log"
            else
                print_error "日志文件不存在"
            fi
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# Caddy 子菜单
caddy_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   Caddy 管理"
        echo "=========================================="
        echo ""
        
        if check_caddy; then
            print_success "Caddy 已安装"
            caddy_version=$(caddy version | head -n 1)
            echo "  版本: ${caddy_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet caddy; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "Caddy 未安装"
        fi
        
        echo ""
        echo "1. 安装 Caddy"
        echo "2. 创建站点"
        echo "3. 列出站点"
        echo "4. 删除站点"
        echo "5. 服务管理"
        echo "6. 查看日志"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-6]: " choice
        
        case $choice in
            1) install_caddy ;;
            2) create_caddy_site ;;
            3) list_caddy_sites ;;
            4) delete_caddy_site ;;
            5) manage_caddy_service ;;
            6) view_caddy_logs ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============================================
# 主菜单
# ============================================

main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   Web 服务器管理"
        echo "=========================================="
        echo ""
        
        # 显示安装状态
        if check_openresty; then
            print_success "OpenResty: 已安装"
        else
            echo -e "${YELLOW}○${NC} OpenResty: 未安装"
        fi
        
        if check_nginx; then
            print_success "Nginx: 已安装"
        else
            echo -e "${YELLOW}○${NC} Nginx: 未安装"
        fi
        
        if check_caddy; then
            print_success "Caddy: 已安装"
        else
            echo -e "${YELLOW}○${NC} Caddy: 未安装"
        fi
        
        echo ""
        echo "1. OpenResty 管理"
        echo "2. Nginx 管理"
        echo "3. Caddy 管理"
        echo ""
        echo "0. 返回主菜单"
        echo ""
        
        read -p "请选择 [0-3]: " choice
        
        case $choice in
            1) openresty_menu ;;
            2) nginx_menu ;;
            3) caddy_menu ;;
            0) exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main_menu
