#!/bin/bash
set -euo pipefail


# ============================================
# Web 应用安装管理脚本
# 支持 Tiny Tiny RSS, WordPress, phpMyAdmin, DokuWiki
# 功能：覆盖安装、数据备份、Basic Auth、SSL 证书
# 兼容：OpenResty 和 Nginx
# ============================================


# 配置变量
WEB_ROOT="/var/www"
PHP_VERSION="8.2"
PHP_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
BACKUP_DIR="/root/web_backups"

# Web 服务器配置（将在初始化时设置）
WEB_SERVER=""           # "openresty" 或 "nginx"
NGINX_CONF_DIR=""       # Nginx/OpenResty 配置根目录
SITES_AVAIL=""          # sites-available 目录
SITES_ENABLED=""        # sites-enabled 目录
SSL_DIR=""              # SSL 证书目录
NGINX_BIN=""            # nginx/openresty 可执行文件
SERVICE_NAME=""         # 服务名称


# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'


print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }


press_enter() {
    echo ""
    read -p "按 Enter 键继续..."
}


# ============================================
# Web 服务器检测和初始化
# ============================================


# 检测并初始化 Web 服务器配置
init_webserver_config() {
    # 检测 OpenResty
    if command -v openresty &> /dev/null; then
        WEB_SERVER="openresty"
        NGINX_BIN="openresty"
        SERVICE_NAME="openresty"
        
        # OpenResty 标准路径
        if [ -d "/usr/local/openresty/nginx" ]; then
            NGINX_CONF_DIR="/usr/local/openresty/nginx/conf"
        else
            # 备用路径
            NGINX_CONF_DIR="/etc/openresty"
        fi
        
        SITES_AVAIL="${NGINX_CONF_DIR}/sites-available"
        SITES_ENABLED="${NGINX_CONF_DIR}/sites-enabled"
        SSL_DIR="${NGINX_CONF_DIR}/ssl"
        
        return 0
    fi
    
    # 检测 Nginx
    if command -v nginx &> /dev/null; then
        WEB_SERVER="nginx"
        NGINX_BIN="nginx"
        SERVICE_NAME="nginx"
        
        # Nginx 标准路径
        NGINX_CONF_DIR="/etc/nginx"
        SITES_AVAIL="${NGINX_CONF_DIR}/sites-available"
        SITES_ENABLED="${NGINX_CONF_DIR}/sites-enabled"
        SSL_DIR="${NGINX_CONF_DIR}/ssl"
        
        return 0
    fi
    
    # 未检测到任何 Web 服务器
    WEB_SERVER="none"
    return 1
}


# 显示 Web 服务器信息
show_webserver_info() {
    if [ "$WEB_SERVER" = "none" ]; then
        echo -e "${YELLOW}○${NC} Web 服务器: 未安装"
        return
    fi
    
    local version=""
    if [ "$WEB_SERVER" = "openresty" ]; then
        version=$(openresty -v 2>&1 | grep -oP 'openresty/\K[0-9.]+' || echo "unknown")
        print_success "Web 服务器: OpenResty ${version}"
    else
        version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
        print_success "Web 服务器: Nginx ${version}"
    fi
    
    echo "  配置目录: ${NGINX_CONF_DIR}"
    echo "  站点目录: ${SITES_AVAIL}"
    echo "  SSL 目录: ${SSL_DIR}"
}


# 检查 Web 服务器是否安装
check_webserver() {
    init_webserver_config
    [ "$WEB_SERVER" != "none" ]
}


# 重载 Web 服务器
reload_webserver() {
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器"
        return 1
    fi
    
    # 测试配置
    if $NGINX_BIN -t 2>/dev/null; then
        systemctl reload "$SERVICE_NAME"
        print_success "${WEB_SERVER} 配置已重载"
        return 0
    else
        print_error "${WEB_SERVER} 配置测试失败"
        $NGINX_BIN -t
        return 1
    fi
}


# ============================================
# 辅助函数
# ============================================


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


# 检查必要工具
ensure_tools() {
    local tools="wget curl openssl unzip git"
    local missing=""
    
    for tool in $tools; do
        if ! command -v $tool &> /dev/null; then
            missing="$missing $tool"
        fi
    done
    
    # 检查 htpasswd (apache2-utils)
    if ! command -v htpasswd &> /dev/null; then
        missing="$missing apache2-utils"
    fi
    
    if [ -n "$missing" ]; then
        print_info "安装必要工具:$missing"
        apt update -qq
        apt install -y $missing
        print_success "工具安装完成"
    fi
}


# 检查服务
check_php() { command -v php &> /dev/null; }
check_mysql() { command -v mysql &> /dev/null; }
check_postgresql() { command -v psql &> /dev/null; }


# 生成随机密码
generate_password() {
    local length=${1:-16}
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}


# 生成自签名 SSL 证书
generate_ssl_cert() {
    local domain=$1
    local key_file="${SSL_DIR}/${domain}.key"
    local cert_file="${SSL_DIR}/${domain}.crt"
    
    mkdir -p "$SSL_DIR"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=${domain}" &>/dev/null
    
    echo "$cert_file:$key_file"
}


# 创建 MySQL 数据库
create_mysql_db() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3
    
    mysql << EOF
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${db_user}'@'localhost';
CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
}


# 创建 PostgreSQL 数据库
create_postgresql_db() {
    local db_name=$1
    local db_user=$2
    local db_pass=$3
    
    sudo -u postgres psql << EOF
DROP USER IF EXISTS ${db_user};
CREATE USER ${db_user} WITH PASSWORD '${db_pass}';
DROP DATABASE IF EXISTS ${db_name};
CREATE DATABASE ${db_name} OWNER ${db_user};
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};
\q
EOF
}


# 备份站点
backup_site() {
    local site_dir=$1
    local site_name=$(basename "$site_dir")
    
    mkdir -p "$BACKUP_DIR"
    
    local backup_file="${BACKUP_DIR}/${site_name}_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    print_info "备份站点到: $backup_file"
    tar czf "$backup_file" -C "$(dirname "$site_dir")" "$(basename "$site_dir")" 2>/dev/null
    
    print_success "备份完成 ($(du -h "$backup_file" | awk '{print $1}'))"
}


# 删除站点配置和文件
remove_site() {
    local domain=$1
    local site_dir="${WEB_ROOT}/${domain}"
    
    # 删除 Nginx/OpenResty 配置
    rm -f "${SITES_ENABLED}/${domain}.conf"
    rm -f "${SITES_AVAIL}/${domain}.conf"
    
    # 删除 SSL 证书
    rm -f "${SSL_DIR}/${domain}.key"
    rm -f "${SSL_DIR}/${domain}.crt"
    
    # 删除站点目录
    if [ -d "$site_dir" ]; then
        rm -rf "$site_dir"
    fi
}


# 确保配置目录存在
ensure_config_dirs() {
    mkdir -p "$SITES_AVAIL" "$SITES_ENABLED" "$SSL_DIR"
    
    # 检查主配置文件是否包含 sites-enabled
    local main_conf="${NGINX_CONF_DIR}/nginx.conf"
    
    if [ -f "$main_conf" ]; then
        if ! grep -q "include.*sites-enabled" "$main_conf"; then
            print_warning "${WEB_SERVER} 主配置未包含 sites-enabled"
            print_info "请在 http 块中添加: include ${SITES_ENABLED}/*.conf;"
        fi
    fi
}


# 检查依赖是否满足
check_dependencies() {
    local app_name=$1
    local missing=""
    
    # 检查 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        missing="${missing}\n  - Web 服务器 (Nginx/OpenResty)"
    fi
    
    # 检查 PHP
    if ! check_php; then
        missing="${missing}\n  - PHP ${PHP_VERSION}"
    fi
    
    # 根据应用检查数据库
    case $app_name in
        "wordpress"|"phpmyadmin")
            if ! check_mysql; then
                missing="${missing}\n  - MySQL/MariaDB"
            fi
            ;;
        "ttrss")
            if ! check_postgresql; then
                missing="${missing}\n  - PostgreSQL"
            fi
            ;;
    esac
    
    if [ -n "$missing" ]; then
        print_error "缺少必要组件:"
        echo -e "$missing"
        echo ""
        print_info "请先使用主菜单的其他选项安装以下组件："
        echo "  - Web 服务器管理 -> 安装 Nginx/OpenResty"
        echo "  - 数据库管理 -> 安装数据库"
        return 1
    fi
    
    return 0
}


# ============================================
# 安装 phpMyAdmin (带 Basic Auth)
# ============================================


install_phpmyadmin() {
    clear
    echo "=========================================="
    echo "   安装 phpMyAdmin"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "phpmyadmin"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "域名 (如: pma.example.com, 默认: _): " domain
    domain=${domain:-_}
    
    local install_dir="${WEB_ROOT}/phpmyadmin"
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "phpMyAdmin 已安装在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r confirm
        if [[ "$confirm" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 备份
        backup_site "$install_dir"
        
        # 删除旧配置
        remove_site "$domain"
        rm -f "${NGINX_CONF_DIR}/.htpasswd_phpmyadmin"
    fi
    
    # Basic Auth 配置
    echo ""
    print_info "配置 Basic Auth 认证"
    read -p "用户名 (默认: admin): " pma_user
    pma_user=${pma_user:-admin}
    
    read -sp "密码 (留空自动生成): " pma_pass
    echo ""
    
    if [ -z "$pma_pass" ]; then
        pma_pass=$(generate_password 12)
        print_info "生成的密码: $pma_pass"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  Basic Auth 用户: ${pma_user}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 下载 phpMyAdmin
    echo ""
    print_info "[1/5] 下载 phpMyAdmin..."
    mkdir -p "$install_dir"
    cd /tmp
    
    # 获取最新版本
    PMA_VERSION="5.2.1"
    wget -q --show-progress "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz" -O pma.tar.gz
    
    tar xzf pma.tar.gz
    cp -r "phpMyAdmin-${PMA_VERSION}-all-languages"/* "$install_dir/"
    rm -rf pma.tar.gz "phpMyAdmin-${PMA_VERSION}-all-languages"
    
    # 配置 phpMyAdmin
    print_info "[2/5] 配置 phpMyAdmin..."
    cd "$install_dir"
    cp config.sample.inc.php config.inc.php
    
    local blowfish_secret=$(generate_password 32)
    sed -i "s|\$cfg\['blowfish_secret'\] = ''|\$cfg['blowfish_secret'] = '${blowfish_secret}'|" config.inc.php
    
    mkdir -p tmp
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
    chmod 777 tmp
    
    # 创建 Basic Auth
    print_info "[3/5] 配置 Basic Auth..."
    htpasswd -bc "${NGINX_CONF_DIR}/.htpasswd_phpmyadmin" "$pma_user" "$pma_pass"
    
    # 生成 SSL 证书
    print_info "[4/5] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建 Nginx 配置
    print_info "[5/5] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/phpmyadmin.conf" << PMACONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index index.php;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/phpmyadmin.access.log;
    error_log /var/log/${WEB_SERVER}/phpmyadmin.error.log;
    
    # Basic Auth 认证
    auth_basic "phpMyAdmin Access";
    auth_basic_user_file ${NGINX_CONF_DIR}/.htpasswd_phpmyadmin;
    
    client_max_body_size 512M;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    # 安全加固
    location ~ ^/(libraries|setup|sql)/ {
        deny all;
    }
    
    location ~ /\. {
        deny all;
    }
}
PMACONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/phpmyadmin.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 保存信息
    cat > /root/phpmyadmin-info.txt << INFO
phpMyAdmin 安装信息
===================
Web 服务器: ${WEB_SERVER}
访问地址: https://${domain}
安装目录: ${install_dir}

Basic Auth 认证
----------------
用户名: ${pma_user}
密码: ${pma_pass}

配置文件
--------
${WEB_SERVER} 配置: ${SITES_AVAIL}/phpmyadmin.conf
密码文件: ${NGINX_CONF_DIR}/.htpasswd_phpmyadmin
SSL 证书: ${ssl_cert}
SSL 密钥: ${ssl_key}

使用说明
--------
1. 访问时首先需要通过 Basic Auth 认证
2. 然后使用 MariaDB/MySQL 数据库用户名密码登录
3. 双重认证提高了安全性

重要提示
--------
- 建议使用 Let's Encrypt 配置真实 SSL 证书
- 定期更新 phpMyAdmin 到最新版本
- 限制访问 IP 地址（可选）

管理命令
--------
查看日志: tail -f /var/log/${WEB_SERVER}/phpmyadmin.access.log
重启服务: systemctl reload ${SERVICE_NAME}

生成时间: $(date)
INFO
    
    chmod 600 /root/phpmyadmin-info.txt
    
    echo ""
    print_success "phpMyAdmin 安装完成！"
    echo ""
    cat /root/phpmyadmin-info.txt
    
    press_enter
}


# ============================================
# 安装 WordPress
# ============================================


install_wordpress() {
    clear
    echo "=========================================="
    echo "   安装 WordPress"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "wordpress"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "站点域名 (如: blog.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/${domain}"
    local db_name="wp_${domain//./_}"
    local db_user="${db_name}_user"
    local db_pass=""
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "WordPress 站点已存在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 读取旧数据库信息
        local old_db_name=""
        local old_db_user=""
        if [ -f "$install_dir/SITE-INFO.txt" ]; then
            old_db_name=$(grep "数据库名:" "$install_dir/SITE-INFO.txt" | awk '{print $2}')
            old_db_user=$(grep "数据库用户:" "$install_dir/SITE-INFO.txt" | awk '{print $2}')
        fi
        
        # 备份
        backup_site "$install_dir"
        
        # 删除旧配置
        remove_site "$domain"
        
        # 询问是否删除旧数据库
        if [ -n "$old_db_name" ]; then
            echo -n "是否删除旧数据库 ${old_db_name}? (yes/no): "
            read -r delete_db
            if [[ "$delete_db" == "yes" ]]; then
                mysql -e "DROP DATABASE IF EXISTS \`${old_db_name}\`;" 2>/dev/null
                mysql -e "DROP USER IF EXISTS '${old_db_user}'@'localhost';" 2>/dev/null
                print_success "已删除旧数据库"
            fi
        fi
    fi
    
    # 数据库配置
    echo ""
    print_info "数据库配置"
    read -p "数据库名 (默认: ${db_name}): " custom_db_name
    db_name=${custom_db_name:-$db_name}
    
    read -p "数据库用户 (默认: ${db_user}): " custom_db_user
    db_user=${custom_db_user:-$db_user}
    
    read -sp "数据库密码 (留空自动生成): " db_pass
    echo ""
    
    if [ -z "$db_pass" ]; then
        db_pass=$(generate_password 16)
        print_info "生成的密码: $db_pass"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  数据库名: ${db_name}"
    echo "  数据库用户: ${db_user}"
    echo "  配置目录: ${SITES_AVAIL}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 创建数据库
    echo ""
    print_info "[1/5] 创建数据库..."
    create_mysql_db "$db_name" "$db_user" "$db_pass"
    
    # 下载 WordPress
    print_info "[2/5] 下载 WordPress..."
    mkdir -p "$install_dir"
    cd /tmp
    wget -q --show-progress -O wordpress.tar.gz https://wordpress.org/latest.tar.gz
    tar xzf wordpress.tar.gz
    cp -r wordpress/* "$install_dir/"
    rm -rf wordpress wordpress.tar.gz
    
    # 配置 WordPress
    print_info "[3/5] 配置 WordPress..."
    cd "$install_dir"
    cp wp-config-sample.php wp-config.php
    
    sed -i "s/database_name_here/${db_name}/" wp-config.php
    sed -i "s/username_here/${db_user}/" wp-config.php
    sed -i "s/password_here/${db_pass}/" wp-config.php
    
    # 生成安全密钥
    curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> wp-config.php
    
    # 设置权限
    chown -R www-data:www-data "$install_dir"
    find "$install_dir" -type d -exec chmod 755 {} \;
    find "$install_dir" -type f -exec chmod 644 {} \;
    
    # 生成 SSL 证书
    print_info "[4/5] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建配置文件
    print_info "[5/5] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << WPCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index index.php index.html;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    client_max_body_size 512M;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    location ~ /\. {
        deny all;
    }
}
WPCONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 保存信息
    cat > "$install_dir/SITE-INFO.txt" << INFO
WordPress 站点信息
==================
Web 服务器: ${WEB_SERVER}
域名: ${domain}
目录: ${install_dir}

数据库信息
----------
数据库名: ${db_name}
数据库用户: ${db_user}
数据库密码: ${db_pass}

访问地址
--------
前台: https://${domain}
后台: https://${domain}/wp-admin/
安装: https://${domain}/wp-admin/install.php

配置文件
--------
WordPress: ${install_dir}/wp-config.php
${WEB_SERVER}: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}

管理命令
--------
查看日志: tail -f /var/log/${WEB_SERVER}/${domain}.access.log
重启服务: systemctl reload ${SERVICE_NAME}
备份站点: tar czf wordpress-backup.tar.gz ${install_dir}

生成时间: $(date)
INFO
    
    chmod 600 "$install_dir/SITE-INFO.txt"
    
    echo ""
    print_success "WordPress 安装完成！"
    echo ""
    cat "$install_dir/SITE-INFO.txt"
    echo ""
    print_warning "请访问安装向导完成 WordPress 初始化配置"
    
    press_enter
}


# ============================================
# 安装 Tiny Tiny RSS
# ============================================


install_ttrss() {
    clear
    echo "=========================================="
    echo "   安装 Tiny Tiny RSS"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "ttrss"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "域名 (如: rss.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/${domain}"
    local db_name="ttrss"
    local db_user="ttrss"
    local db_pass=""
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "Tiny Tiny RSS 已存在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 备份
        backup_site "$install_dir"
        
        # 删除旧配置
        remove_site "$domain"
        
        # 停止更新守护进程
        systemctl stop ttrss-update 2>/dev/null || true
        systemctl disable ttrss-update 2>/dev/null || true
        rm -f /etc/systemd/system/ttrss-update.service
    fi
    
    # 数据库配置
    echo ""
    print_info "数据库配置"
    read -p "数据库名 (默认: ${db_name}): " custom_db_name
    db_name=${custom_db_name:-$db_name}
    
    read -p "数据库用户 (默认: ${db_user}): " custom_db_user
    db_user=${custom_db_user:-$db_user}
    
    read -sp "数据库密码 (留空自动生成): " db_pass
    echo ""
    
    if [ -z "$db_pass" ]; then
        db_pass=$(generate_password 16)
        print_info "生成的密码: $db_pass"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  数据库: PostgreSQL"
    echo "  数据库名: ${db_name}"
    echo "  数据库用户: ${db_user}"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 创建数据库
    echo ""
    print_info "[1/6] 创建数据库..."
    create_postgresql_db "$db_name" "$db_user" "$db_pass"
    
    # 下载 Tiny Tiny RSS
    print_info "[2/6] 下载 Tiny Tiny RSS..."
    mkdir -p "$install_dir"
    cd /tmp
    rm -rf tt-rss
    git clone --depth=1 https://git.tt-rss.org/fox/tt-rss.git
    cp -r tt-rss/* "$install_dir/"
    rm -rf tt-rss
    
    # 配置 Tiny Tiny RSS
    print_info "[3/6] 配置 Tiny Tiny RSS..."
    cd "$install_dir"
    cp config.php-dist config.php
    
    sed -i "s|define('DB_TYPE', 'pgsql');|define('DB_TYPE', 'pgsql');|" config.php
    sed -i "s|define('DB_HOST', 'localhost');|define('DB_HOST', 'localhost');|" config.php
    sed -i "s|define('DB_USER', 'fox');|define('DB_USER', '${db_user}');|" config.php
    sed -i "s|define('DB_NAME', 'fox');|define('DB_NAME', '${db_name}');|" config.php
    sed -i "s|define('DB_PASS', '');|define('DB_PASS', '${db_pass}');|" config.php
    sed -i "s|define('SELF_URL_PATH', 'http://yourserver/tt-rss/');|define('SELF_URL_PATH', 'https://${domain}/');|" config.php
    
    # 初始化数据库
    sudo -u postgres psql -d "$db_name" < schema/ttrss_schema_pgsql.sql 2>/dev/null || true
    
    # 设置权限
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
    
    # 生成 SSL 证书
    print_info "[4/6] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建 Nginx 配置
    print_info "[5/6] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << TTRSSCONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index index.php;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    location ~ /\. {
        deny all;
    }
}
TTRSSCONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 配置更新守护进程
    print_info "[6/6] 配置更新守护进程..."
    cat > /etc/systemd/system/ttrss-update.service << TTRSSSERVICE
[Unit]
Description=Tiny Tiny RSS Update Daemon
After=network.target postgresql.service

[Service]
Type=simple
User=www-data
ExecStart=/usr/bin/php ${install_dir}/update_daemon2.php
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
TTRSSSERVICE
    
    systemctl daemon-reload
    systemctl enable ttrss-update
    systemctl start ttrss-update
    
    # 保存信息
    cat > "$install_dir/TTRSS-INFO.txt" << INFO
Tiny Tiny RSS 安装信息
======================
Web 服务器: ${WEB_SERVER}
域名: ${domain}
目录: ${install_dir}

数据库信息
----------
类型: PostgreSQL
数据库名: ${db_name}
数据库用户: ${db_user}
数据库密码: ${db_pass}

访问地址
--------
前台: https://${domain}
默认用户: admin
默认密码: password

配置文件
--------
TTRSS: ${install_dir}/config.php
${WEB_SERVER}: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}
更新服务: /etc/systemd/system/ttrss-update.service

管理命令
--------
查看更新服务状态: systemctl status ttrss-update
重启更新服务: systemctl restart ttrss-update
查看日志: tail -f /var/log/${WEB_SERVER}/${domain}.access.log
重启 Web 服务: systemctl reload ${SERVICE_NAME}

重要提示
--------
⚠️  请立即修改默认密码！
⚠️  访问后台: https://${domain}/?do=prefPrefs

生成时间: $(date)
INFO
    
    chmod 600 "$install_dir/TTRSS-INFO.txt"
    
    echo ""
    print_success "Tiny Tiny RSS 安装完成！"
    echo ""
    cat "$install_dir/TTRSS-INFO.txt"
    echo ""
    print_warning "请立即访问并修改默认密码！"
    
    press_enter
}


# ============================================
# 安装 DokuWiki
# ============================================


install_dokuwiki() {
    clear
    echo "=========================================="
    echo "   安装 DokuWiki"
    echo "=========================================="
    echo ""
    
    check_root || return
    init_webserver_config
    ensure_tools
    
    # 检查依赖
    if ! check_dependencies "dokuwiki"; then
        press_enter
        return
    fi
    
    ensure_config_dirs
    
    # 配置参数
    read -p "域名 (如: wiki.example.com): " domain
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local install_dir="${WEB_ROOT}/${domain}"
    
    # 检查是否已存在
    if [ -d "$install_dir" ]; then
        echo ""
        print_warning "DokuWiki 已存在: $install_dir"
        echo -n "是否覆盖安装? (yes/no): "
        read -r overwrite
        if [[ "$overwrite" != "yes" ]]; then
            print_info "已取消"
            press_enter
            return
        fi
        
        # 询问是否备份数据
        if [ -d "$install_dir/data" ]; then
            echo -n "是否备份现有数据? (yes/no): "
            read -r backup_confirm
            if [[ "$backup_confirm" == "yes" ]]; then
                backup_site "$install_dir"
            fi
        fi
        
        # 删除旧配置
        remove_site "$domain"
    fi
    
    echo ""
    print_info "安装配置："
    echo "  Web 服务器: ${WEB_SERVER}"
    echo "  域名: ${domain}"
    echo "  目录: ${install_dir}"
    echo "  数据库: 无需数据库（使用文件存储）"
    echo ""
    
    read -p "确认安装？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 下载 DokuWiki
    echo ""
    print_info "[1/4] 下载 DokuWiki..."
    mkdir -p "$install_dir"
    cd /tmp
    wget -q --show-progress -O dokuwiki.tar.gz \
        "https://download.dokuwiki.org/src/dokuwiki/dokuwiki-stable.tgz"
    
    tar xzf dokuwiki.tar.gz -C "$install_dir" --strip-components=1
    rm dokuwiki.tar.gz
    
    # 设置权限
    print_info "[2/4] 设置权限..."
    chown -R www-data:www-data "$install_dir"
    chmod -R 755 "$install_dir"
    chmod -R 775 "$install_dir/data" "$install_dir/conf"
    
    # 生成 SSL 证书
    print_info "[3/4] 生成 SSL 证书..."
    local ssl_files=$(generate_ssl_cert "$domain")
    local ssl_cert=$(echo "$ssl_files" | cut -d: -f1)
    local ssl_key=$(echo "$ssl_files" | cut -d: -f2)
    
    # 创建 Nginx 配置
    print_info "[4/4] 配置 ${WEB_SERVER}..."
    cat > "${SITES_AVAIL}/${domain}.conf" << WIKICONF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};
    
    root ${install_dir};
    index doku.php;
    
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    access_log /var/log/${WEB_SERVER}/${domain}.access.log;
    error_log /var/log/${WEB_SERVER}/${domain}.error.log;
    
    client_max_body_size 50M;
    
    # 安全加固：禁止访问敏感目录
    location ~ /(data|conf|bin|inc|vendor)/ {
        deny all;
    }
    
    location ~ /\.ht {
        deny all;
    }
    
    location / {
        try_files \$uri \$uri/ @dokuwiki;
    }
    
    location @dokuwiki {
        rewrite ^/_media/(.*) /lib/exe/fetch.php?media=\$1 last;
        rewrite ^/_detail/(.*) /lib/exe/detail.php?media=\$1 last;
        rewrite ^/_export/([^/]+)/(.*) /doku.php?do=export_\$1&id=\$2 last;
        rewrite ^/(.*) /doku.php?id=\$1&\$args last;
    }
    
    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass unix:${PHP_SOCK};
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param REDIRECT_STATUS 200;
    }
    
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
}
WIKICONF
    
    # 创建日志目录
    mkdir -p "/var/log/${WEB_SERVER}"
    
    ln -sf "${SITES_AVAIL}/${domain}.conf" "${SITES_ENABLED}/"
    reload_webserver
    
    # 保存信息
    cat > "$install_dir/WIKI-INFO.txt" << INFO
DokuWiki 安装信息
=================
Web 服务器: ${WEB_SERVER}
域名: ${domain}
目录: ${install_dir}

访问地址
--------
前台: https://${domain}
安装向导: https://${domain}/install.php
管理面板: https://${domain}/?do=admin

配置文件
--------
${WEB_SERVER}: ${SITES_AVAIL}/${domain}.conf
SSL 证书: ${ssl_cert}
数据目录: ${install_dir}/data
配置目录: ${install_dir}/conf
主配置: ${install_dir}/conf/local.php

安装步骤
--------
1. 访问: https://${domain}/install.php
2. 完成 DokuWiki 初始化配置
   - 设置 Wiki 名称
   - 创建管理员账号
   - 配置 ACL 权限
3. 安装完成后删除 install.php:
   rm ${install_dir}/install.php

特性
----
- 无需数据库，使用文件存储
- 内置 ACL 权限管理系统
- 支持多种标记语法
- 版本控制和历史记录
- 丰富的插件和模板

管理命令
--------
查看日志: tail -f /var/log/${WEB_SERVER}/${domain}.access.log
备份数据: tar czf wiki-backup.tar.gz ${install_dir}/data ${install_dir}/conf
重启服务: systemctl reload ${SERVICE_NAME}

生成时间: $(date)
INFO
    
    chmod 600 "$install_dir/WIKI-INFO.txt"
    
    echo ""
    print_success "DokuWiki 安装完成！"
    echo ""
    cat "$install_dir/WIKI-INFO.txt"
    echo ""
    print_warning "⚠️  重要: 请立即访问 https://${domain}/install.php 完成初始化！"
    print_warning "⚠️  配置完成后务必删除 install.php 文件！"
    
    press_enter
}


# ============================================
# 列出所有站点
# ============================================


list_sites() {
    clear
    echo "=========================================="
    echo "   已部署的站点"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    if [ "$WEB_SERVER" = "none" ]; then
        print_warning "未检测到 Web 服务器"
        press_enter
        return
    fi
    
    if [ ! -d "$SITES_ENABLED" ] || [ -z "$(ls -A "$SITES_ENABLED" 2>/dev/null)" ]; then
        print_warning "暂无已部署的站点"
        press_enter
        return
    fi
    
    local count=0
    for conf in "$SITES_ENABLED"/*.conf; do
        [ -f "$conf" ] || continue
        
        local name=$(basename "$conf" .conf)
        local domain=$(grep "server_name" "$conf" | grep -v "return" | head -1 | awk '{print $2}' | tr -d ';')
        local root=$(grep "root" "$conf" | head -1 | awk '{print $2}' | tr -d ';')
        
        count=$((count+1))
        echo -e "${CYAN}[$count] ${domain}${NC}"
        echo "    目录: $root"
        echo "    配置: $conf"
        
        # 检查是否有信息文件
        if [ -f "$root/SITE-INFO.txt" ]; then
            echo "    类型: WordPress"
            echo "    信息: $root/SITE-INFO.txt"
        elif [ -f "$root/WIKI-INFO.txt" ]; then
            echo "    类型: DokuWiki"
            echo "    信息: $root/WIKI-INFO.txt"
        elif [ -f "$root/TTRSS-INFO.txt" ]; then
            echo "    类型: Tiny Tiny RSS"
            echo "    信息: $root/TTRSS-INFO.txt"
        elif [ "$root" = "${WEB_ROOT}/phpmyadmin" ]; then
            echo "    类型: phpMyAdmin"
            echo "    信息: /root/phpmyadmin-info.txt"
        fi
        
        # 检查 SSL 证书
        local ssl_cert="${SSL_DIR}/${domain}.crt"
        if [ -f "$ssl_cert" ]; then
            local expire_date=$(openssl x509 -in "$ssl_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
            echo "    SSL: ${expire_date}"
        fi
        
        echo ""
    done
    
    echo "----------------------------------------"
    print_success "总计: $count 个站点 (${WEB_SERVER})"
    
    # 显示备份信息
    if [ -d "$BACKUP_DIR" ]; then
        local backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        if [ "$backup_count" -gt 0 ]; then
            echo ""
            print_info "备份文件: $backup_count 个 (${BACKUP_DIR})"
        fi
    fi
    
    press_enter
}


# ============================================
# 删除站点
# ============================================


delete_site() {
    clear
    echo "=========================================="
    echo "   删除站点"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    # 先列出站点
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器"
        press_enter
        return
    fi
    
    if [ ! -d "$SITES_ENABLED" ] || [ -z "$(ls -A "$SITES_ENABLED" 2>/dev/null)" ]; then
        print_warning "暂无已部署的站点"
        press_enter
        return
    fi
    
    print_info "当前站点列表："
    echo ""
    
    local count=0
    local -a domains
    for conf in "$SITES_ENABLED"/*.conf; do
        [ -f "$conf" ] || continue
        local domain=$(grep "server_name" "$conf" | grep -v "return" | head -1 | awk '{print $2}' | tr -d ';')
        count=$((count+1))
        domains+=("$domain")
        echo "  $count. $domain"
    done
    
    echo ""
    read -p "输入要删除的域名: " domain
    
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local site_dir="${WEB_ROOT}/${domain}"
    local site_conf="${SITES_AVAIL}/${domain}.conf"
    
    # 特殊处理 phpmyadmin
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        site_dir="${WEB_ROOT}/phpmyadmin"
        site_conf="${SITES_AVAIL}/phpmyadmin.conf"
    fi
    
    if [ ! -f "$site_conf" ]; then
        print_error "站点不存在: $domain"
        press_enter
        return
    fi
    
    # 读取数据库信息
    local db_name=""
    local db_user=""
    local db_type=""
    
    if [ -f "$site_dir/SITE-INFO.txt" ]; then
        db_name=$(grep "数据库名:" "$site_dir/SITE-INFO.txt" | awk '{print $2}')
        db_user=$(grep "数据库用户:" "$site_dir/SITE-INFO.txt" | awk '{print $2}')
        db_type="mysql"
    elif [ -f "$site_dir/TTRSS-INFO.txt" ]; then
        db_name=$(grep "数据库名:" "$site_dir/TTRSS-INFO.txt" | awk '{print $2}')
        db_user=$(grep "数据库用户:" "$site_dir/TTRSS-INFO.txt" | awk '{print $2}')
        db_type="postgresql"
    fi
    
    # 显示将删除的内容
    echo ""
    print_warning "将删除以下内容:"
    echo "  - 站点目录: $site_dir"
    echo "  - ${WEB_SERVER} 配置: $site_conf"
    echo "  - SSL 证书: ${SSL_DIR}/${domain}.*"
    [ -n "$db_name" ] && echo "  - 数据库: $db_name ($db_type)"
    
    # 特殊文件
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        echo "  - Basic Auth: ${NGINX_CONF_DIR}/.htpasswd_phpmyadmin"
    fi
    
    echo ""
    read -p "确认删除？输入域名以确认: " confirm
    
    if [ "$confirm" != "$domain" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 询问是否备份
    echo ""
    read -p "删除前是否备份? (yes/no): " backup_confirm
    if [[ "$backup_confirm" == "yes" ]]; then
        if [ -d "$site_dir" ]; then
            backup_site "$site_dir"
        fi
    fi
    
    # 删除站点
    print_info "正在删除站点..."
    
    # 停止相关服务
    if [ -f "/etc/systemd/system/ttrss-update.service" ]; then
        systemctl stop ttrss-update 2>/dev/null || true
        systemctl disable ttrss-update 2>/dev/null || true
        rm -f /etc/systemd/system/ttrss-update.service
        systemctl daemon-reload
        print_success "已停止 TTRSS 更新服务"
    fi
    
    # 删除文件和配置
    remove_site "$domain"
    
    # 删除特殊文件
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        rm -f "${NGINX_CONF_DIR}/.htpasswd_phpmyadmin"
        rm -f /root/phpmyadmin-info.txt
    fi
    
    # 删除数据库
    if [ -n "$db_name" ]; then
        echo ""
        echo -n "是否删除数据库 ${db_name}? (yes/no): "
        read -r delete_db
        if [[ "$delete_db" == "yes" ]]; then
            if [ "$db_type" = "mysql" ]; then
                mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" 2>/dev/null
                mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" 2>/dev/null
            elif [ "$db_type" = "postgresql" ]; then
                sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null
                sudo -u postgres psql -c "DROP USER IF EXISTS ${db_user};" 2>/dev/null
            fi
            print_success "已删除数据库"
        fi
    fi
    
    reload_webserver
    
    echo ""
    print_success "站点 ${domain} 已删除！"
    
    press_enter
}


# ============================================
# 系统诊断
# ============================================


diagnose() {
    clear
    echo "=========================================="
    echo "   系统诊断"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    print_info "服务状态:"
    echo ""
    
    if [ "$WEB_SERVER" != "none" ]; then
        systemctl is-active --quiet "$SERVICE_NAME" && print_success "${WEB_SERVER}: 运行中" || print_error "${WEB_SERVER}: 已停止"
    else
        print_warning "Web 服务器: 未安装"
    fi
    
    systemctl is-active --quiet php${PHP_VERSION}-fpm && print_success "PHP ${PHP_VERSION}: 运行中" || echo -e "${YELLOW}○${NC} PHP ${PHP_VERSION}: 未运行"
    systemctl is-active --quiet mariadb && print_success "MariaDB: 运行中" || systemctl is-active --quiet mysql && print_success "MySQL: 运行中" || echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未运行"
    systemctl is-active --quiet postgresql && print_success "PostgreSQL: 运行中" || echo -e "${YELLOW}○${NC} PostgreSQL: 未运行"
    
    # 检查 TTRSS 更新服务
    if systemctl is-active --quiet ttrss-update 2>/dev/null; then
        print_success "TTRSS Update: 运行中"
    fi
    
    echo ""
    print_info "版本信息:"
    echo ""
    
    if [ "$WEB_SERVER" != "none" ]; then
        show_webserver_info
        echo ""
    fi
    
    if check_php; then
        echo "  PHP: $(php -r 'echo PHP_VERSION;')"
        echo "  PHP Socket: ${PHP_SOCK}"
        if [ -S "$PHP_SOCK" ]; then
            print_success "  PHP-FPM Socket: 正常"
        else
            print_error "  PHP-FPM Socket: 未找到"
        fi
    fi
    
    if check_mysql; then
        echo "  MySQL/MariaDB: $(mysql --version | grep -oP 'Ver \K[0-9.]+')"
    fi
    
    if check_postgresql; then
        echo "  PostgreSQL: $(psql --version | grep -oP 'psql \(PostgreSQL\) \K[0-9.]+')"
    fi
    
    echo ""
    print_info "站点统计:"
    echo ""
    
    if [ -d "$SITES_ENABLED" ]; then
        local site_count=$(ls -1 "$SITES_ENABLED"/*.conf 2>/dev/null | wc -l)
        echo "  已部署站点: $site_count 个"
    else
        echo "  已部署站点: 0 个"
    fi
    
    local backup_count=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
    echo "  备份文件: $backup_count 个"
    
    if [ -d "$SSL_DIR" ]; then
        local ssl_count=$(ls -1 "$SSL_DIR"/*.crt 2>/dev/null | wc -l)
        echo "  SSL 证书: $ssl_count 个"
    fi
    
    if [ "$WEB_SERVER" != "none" ]; then
        echo ""
        print_info "${WEB_SERVER} 配置测试:"
        echo ""
        $NGINX_BIN -t 2>&1 | tail -2
    fi
    
    echo ""
    print_info "磁盘使用:"
    echo ""
    df -h "$WEB_ROOT" | tail -1 | awk '{print "  Web 目录: " $3 " / " $2 " (" $5 ")"}'
    if [ -d "$BACKUP_DIR" ]; then
        local backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
        echo "  备份目录: ${backup_size}"
    fi
    
    press_enter
}


# ============================================
# 查看站点信息
# ============================================


view_site_info() {
    clear
    echo "=========================================="
    echo "   查看站点信息"
    echo "=========================================="
    echo ""
    
    init_webserver_config
    
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器"
        press_enter
        return
    fi
    
    if [ ! -d "$SITES_ENABLED" ] || [ -z "$(ls -A "$SITES_ENABLED" 2>/dev/null)" ]; then
        print_warning "暂无已部署的站点"
        press_enter
        return
    fi
    
    print_info "当前站点列表："
    echo ""
    
    local count=0
    for conf in "$SITES_ENABLED"/*.conf; do
        [ -f "$conf" ] || continue
        local domain=$(grep "server_name" "$conf" | grep -v "return" | head -1 | awk '{print $2}' | tr -d ';')
        count=$((count+1))
        echo "  $count. $domain"
    done
    
    echo ""
    read -p "输入要查看的域名: " domain
    
    if [ -z "$domain" ]; then
        print_error "域名不能为空"
        press_enter
        return
    fi
    
    local site_dir="${WEB_ROOT}/${domain}"
    
    # 特殊处理 phpmyadmin
    if [ "$domain" = "_" ] || [ "$domain" = "phpmyadmin" ]; then
        if [ -f "/root/phpmyadmin-info.txt" ]; then
            echo ""
            cat /root/phpmyadmin-info.txt
        else
            print_error "未找到站点信息"
        fi
        press_enter
        return
    fi
    
    # 查找信息文件
    local info_file=""
    if [ -f "$site_dir/SITE-INFO.txt" ]; then
        info_file="$site_dir/SITE-INFO.txt"
    elif [ -f "$site_dir/WIKI-INFO.txt" ]; then
        info_file="$site_dir/WIKI-INFO.txt"
    elif [ -f "$site_dir/TTRSS-INFO.txt" ]; then
        info_file="$site_dir/TTRSS-INFO.txt"
    fi
    
    if [ -n "$info_file" ] && [ -f "$info_file" ]; then
        echo ""
        cat "$info_file"
    else
        print_error "未找到站点信息文件"
    fi
    
    press_enter
}


# ============================================
# 主菜单
# ============================================


show_webapp_menu() {
    clear
    
    # 初始化 Web 服务器配置
    init_webserver_config
    
    echo "=========================================="
    echo "   Web 应用安装管理"
    echo "=========================================="
    echo ""
    
    # 显示环境状态
    echo -e "${CYAN}环境状态:${NC}"
    
    if [ "$WEB_SERVER" != "none" ]; then
        show_webserver_info
    else
        echo -e "${YELLOW}○${NC} Web 服务器: 未安装"
        echo "  请先使用主菜单安装 Nginx/OpenResty"
    fi
    
    echo ""
    
    if check_php; then
        print_success "PHP: 已安装 ($(php -r 'echo PHP_VERSION;' 2>/dev/null))"
    else
        echo -e "${YELLOW}○${NC} PHP: 未安装"
    fi
    
    if check_mysql; then
        print_success "MySQL/MariaDB: 已安装"
    else
        echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未安装"
    fi
    
    if check_postgresql; then
        print_success "PostgreSQL: 已安装"
    else
        echo -e "${YELLOW}○${NC} PostgreSQL: 未安装"
    fi
    
    echo ""
    echo "【Web 应用安装】"
    echo ""
    echo "1. 📝 WordPress (博客/CMS)"
    echo "   需要: Nginx/OpenResty + PHP + MySQL"
    echo ""
    echo "2. 📰 Tiny Tiny RSS (RSS 阅读器)"
    echo "   需要: Nginx/OpenResty + PHP + PostgreSQL"
    echo ""
    echo "3. 🗄️  phpMyAdmin (数据库管理)"
    echo "   需要: Nginx/OpenResty + PHP + MySQL"
    echo ""
    echo "4. 📚 DokuWiki (无数据库 Wiki)"
    echo "   需要: Nginx/OpenResty + PHP"
    echo ""
    echo "【站点管理】"
    echo ""
    echo "5. 📋 列出所有站点"
    echo "6. 📄 查看站点信息"
    echo "7. ❌ 删除站点"
    echo ""
    echo "【系统管理】"
    echo ""
    echo "8. 🔄 重启服务"
    echo "9. 🔍 系统诊断"
    echo ""
    echo "0. 返回主菜单"
    echo "=========================================="
}


webapp_menu() {
    while true; do
        show_webapp_menu
        read -p "请选择 [0-9]: " choice
        
        case $choice in
            1)
                install_wordpress
                ;;
            2)
                install_ttrss
                ;;
            3)
                install_phpmyadmin
                ;;
            4)
                install_dokuwiki
                ;;
            5)
                list_sites
                ;;
            6)
                view_site_info
                ;;
            7)
                delete_site
                ;;
            8)
                init_webserver_config
                if [ "$WEB_SERVER" != "none" ]; then
                    print_info "正在重启服务..."
                    systemctl restart "$SERVICE_NAME"
                    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null || true
                    systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
                    systemctl restart postgresql 2>/dev/null || true
                    systemctl restart ttrss-update 2>/dev/null || true
                    print_success "服务已重启"
                else
                    print_error "未检测到 Web 服务器"
                fi
                press_enter
                ;;
            9)
                diagnose
                ;;
            0)
                print_success "返回主菜单"
                sleep 1
                return 0
                ;;
            *)
                print_error "无效选择"
                sleep 1
                ;;
        esac
    done
}


# 启动菜单
webapp_menu
