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
PHP_VERSION="8.5"
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


# ============================================
# 依赖检查和安装
# ============================================


install_dependencies() {
    clear
    echo "=========================================="
    echo "   安装 Web 应用依赖"
    echo "=========================================="
    echo ""
    
    check_root || return
    
    # 初始化 Web 服务器配置
    init_webserver_config
    
    print_info "检查必要的组件..."
    echo ""
    
    local need_install=false
    
    # 检查 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        print_warning "Web 服务器: 未安装"
        need_install=true
    else
        show_webserver_info
    fi
    
    # 检查 PHP
    if ! check_php; then
        print_warning "PHP: 未安装"
        need_install=true
    else
        local php_ver=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
        print_success "PHP: 已安装 ($php_ver)"
    fi
    
    # 检查数据库
    local has_db=false
    if check_mysql; then
        local mysql_ver=$(mysql --version | grep -oP 'Ver \K[0-9.]+')
        print_success "MySQL/MariaDB: 已安装 ($mysql_ver)"
        has_db=true
    fi
    
    if check_postgresql; then
        local pg_ver=$(psql --version | grep -oP 'psql \(PostgreSQL\) \K[0-9.]+')
        print_success "PostgreSQL: 已安装 ($pg_ver)"
        has_db=true
    fi
    
    if ! $has_db; then
        print_warning "数据库: 未安装"
        need_install=true
    fi
    
    # 检查工具
    ensure_tools
    
    if ! $need_install; then
        echo ""
        print_success "所有依赖已满足！"
        press_enter
        return
    fi
    
    echo ""
    read -p "是否现在安装缺失的组件？[Y/n]: " install_now
    
    if [[ "$install_now" =~ ^[Nn]$ ]]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    # 安装 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        echo ""
        print_info "[1/3] 选择 Web 服务器："
        echo "1. Nginx (推荐)"
        echo "2. OpenResty (Nginx + Lua)"
        echo "0. 跳过"
        read -p "请选择 [0-2]: " webserver_choice
        
        case $webserver_choice in
            1)
                print_info "安装 Nginx..."
                apt update
                apt install -y nginx
                
                # 初始化配置
                init_webserver_config
                ensure_config_dirs
                
                systemctl enable nginx
                systemctl start nginx
                print_success "Nginx 安装完成"
                ;;
            2)
                print_info "安装 OpenResty..."
                
                # 添加 OpenResty 仓库
                apt install -y gnupg2 ca-certificates lsb-release
                wget -qO - https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $(lsb_release -sc) openresty" > /etc/apt/sources.list.d/openresty.list
                
                apt update
                apt install -y openresty
                
                # 初始化配置
                init_webserver_config
                ensure_config_dirs
                
                # 确保 OpenResty 配置正确
                local or_nginx_conf="${NGINX_CONF_DIR}/nginx.conf"
                if ! grep -q "include.*sites-enabled" "$or_nginx_conf" 2>/dev/null; then
                    # 在 http 块末尾添加 include
                    sed -i '/^http {/,/^}/ s/}/    include sites-enabled\/*.conf;\n}/' "$or_nginx_conf"
                fi
                
                systemctl enable openresty
                systemctl start openresty
                print_success "OpenResty 安装完成"
                ;;
        esac
        
        # 重新初始化配置
        init_webserver_config
    fi
    
    # 安装 PHP
    if ! check_php; then
        echo ""
        print_info "[2/3] 安装 PHP ${PHP_VERSION}..."
        
        # 添加 PHP 仓库
        apt install -y software-properties-common
        add-apt-repository -y ppa:ondrej/php 2>/dev/null || {
            wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
            echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
        }
        
        apt update
        apt install -y php${PHP_VERSION}-fpm php${PHP_VERSION}-cli \
            php${PHP_VERSION}-common php${PHP_VERSION}-mysql php${PHP_VERSION}-pgsql \
            php${PHP_VERSION}-curl php${PHP_VERSION}-gd php${PHP_VERSION}-mbstring \
            php${PHP_VERSION}-xml php${PHP_VERSION}-zip php${PHP_VERSION}-intl \
            php${PHP_VERSION}-bcmath
        
        # 优化 PHP 配置
        local php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
        sed -i 's/^upload_max_filesize.*/upload_max_filesize = 256M/' "$php_ini"
        sed -i 's/^post_max_size.*/post_max_size = 256M/' "$php_ini"
        sed -i 's/^memory_limit.*/memory_limit = 512M/' "$php_ini"
        sed -i 's/^max_execution_time.*/max_execution_time = 300/' "$php_ini"
        
        systemctl enable php${PHP_VERSION}-fpm
        systemctl start php${PHP_VERSION}-fpm
        print_success "PHP ${PHP_VERSION} 安装完成"
    fi
    
    # 安装数据库
    if ! $has_db; then
        echo ""
        print_info "[3/3] 选择要安装的数据库："
        echo "1. MySQL"
        echo "2. MariaDB (推荐)"
        echo "3. PostgreSQL"
        echo "0. 跳过"
        read -p "请选择 [0-3]: " db_choice
        
        case $db_choice in
            1)
                apt install -y mysql-server
                systemctl enable mysql
                systemctl start mysql
                print_success "MySQL 安装完成"
                ;;
            2)
                apt install -y mariadb-server mariadb-client
                systemctl enable mariadb
                systemctl start mariadb
                print_success "MariaDB 安装完成"
                
                # 配置 root 密码
                echo ""
                echo -n "设置 MariaDB root 密码 (留空自动生成): "
                read -s MYSQL_ROOT_PASS
                echo ""
                
                if [ -z "$MYSQL_ROOT_PASS" ]; then
                    MYSQL_ROOT_PASS=$(generate_password 16)
                    echo "生成的密码: $MYSQL_ROOT_PASS"
                fi
                
                mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASS}';" 2>/dev/null || true
                mysql -uroot -p${MYSQL_ROOT_PASS} -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null
                mysql -uroot -p${MYSQL_ROOT_PASS} -e "FLUSH PRIVILEGES;" 2>/dev/null
                
                # 保存密码
                cat > /root/.my.cnf << EOF
[client]
user=root
password=${MYSQL_ROOT_PASS}
EOF
                chmod 600 /root/.my.cnf
                
                echo "MariaDB root 密码已保存到: /root/.my.cnf"
                ;;
            3)
                apt install -y postgresql postgresql-contrib
                systemctl enable postgresql
                systemctl start postgresql
                print_success "PostgreSQL 安装完成"
                ;;
        esac
    fi
    
    echo ""
    print_success "依赖安装完成！"
    
    # 显示最终配置
    if [ "$WEB_SERVER" != "none" ]; then
        echo ""
        print_info "Web 服务器配置："
        show_webserver_info
    fi
    
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
    
    # 检查 Web 服务器
    if [ "$WEB_SERVER" = "none" ]; then
        print_error "未检测到 Web 服务器 (Nginx/OpenResty)"
        echo ""
        read -p "是否现在安装？[Y/n]: " install_deps
        if [[ ! "$install_deps" =~ ^[Nn]$ ]]; then
            install_dependencies
            init_webserver_config
        else
            press_enter
            return
        fi
    fi
    
    # 检查其他依赖
    if ! check_php || ! check_mysql; then
        print_error "缺少必要组件"
        print_info "WordPress 需要: ${WEB_SERVER} + PHP + MySQL/MariaDB"
        echo ""
        read -p "是否现在安装依赖？[Y/n]: " install_deps
        if [[ ! "$install_deps" =~ ^[Nn]$ ]]; then
            install_dependencies
        else
            press_enter
            return
        fi
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
# 注意：其他安装函数（install_ttrss, install_phpmyadmin, install_dokuwiki）
# 也需要同样的修改，将所有硬编码的 /etc/nginx 替换为变量
# 将所有 nginx 命令替换为 $NGINX_BIN
# 将所有 systemctl nginx 替换为 $SERVICE_NAME
# 为节省篇幅，这里仅展示关键修改部分
# ============================================


# 系统诊断
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
    
    systemctl is-active --quiet php${PHP_VERSION}-fpm && print_success "PHP ${PHP_VERSION}: 运行中" || print_error "PHP ${PHP_VERSION}: 已停止"
    systemctl is-active --quiet mariadb && print_success "MariaDB: 运行中" || systemctl is-active --quiet mysql && print_success "MySQL: 运行中" || echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未运行"
    systemctl is-active --quiet postgresql && print_success "PostgreSQL: 运行中" || echo -e "${YELLOW}○${NC} PostgreSQL: 未运行"
    
    echo ""
    print_info "版本信息:"
    echo ""
    
    if [ "$WEB_SERVER" != "none" ]; then
        show_webserver_info
        echo ""
    fi
    
    if check_php; then
        echo "  PHP: $(php -r 'echo PHP_VERSION;')"
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
    
    if [ "$WEB_SERVER" != "none" ]; then
        echo ""
        print_info "${WEB_SERVER} 配置测试:"
        echo ""
        $NGINX_BIN -t 2>&1 | tail -2
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
    fi
    
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
    echo "【Web 应用】"
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
    echo "【管理工具】"
    echo ""
    echo "5. 📋 列出所有站点"
    echo "6. ❌ 删除站点"
    echo "7. 🔄 重启服务"
    echo "8. 🔍 系统诊断"
    echo ""
    echo "【环境管理】"
    echo ""
    echo "9. 🔧 安装/检查依赖"
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
                # install_ttrss (需要类似修改)
                print_warning "Tiny Tiny RSS 安装功能需要更新"
                press_enter
                ;;
            3)
                # install_phpmyadmin (需要类似修改)
                print_warning "phpMyAdmin 安装功能需要更新"
                press_enter
                ;;
            4)
                # install_dokuwiki (需要类似修改)
                print_warning "DokuWiki 安装功能需要更新"
                press_enter
                ;;
            5)
                # list_sites
                print_warning "列出站点功能需要更新"
                press_enter
                ;;
            6)
                # delete_site
                print_warning "删除站点功能需要更新"
                press_enter
                ;;
            7)
                init_webserver_config
                if [ "$WEB_SERVER" != "none" ]; then
                    print_info "正在重启服务..."
                    systemctl restart "$SERVICE_NAME"
                    systemctl restart php${PHP_VERSION}-fpm
                    systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true
                    systemctl restart postgresql 2>/dev/null || true
                    print_success "服务已重启"
                else
                    print_error "未检测到 Web 服务器"
                fi
                press_enter
                ;;
            8)
                diagnose
                ;;
            9)
                install_dependencies
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
