#!/bin/bash

# ============================================
# 数据库管理脚本
# 支持 PostgreSQL 和 MySQL/MariaDB
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
# PostgreSQL 管理函数
# ============================================

# 检查 PostgreSQL 是否安装
check_postgresql() {
    if command -v psql &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 安装 PostgreSQL
install_postgresql() {
    clear
    echo "=========================================="
    echo "   安装 PostgreSQL"
    echo "=========================================="
    echo ""
    
    if check_postgresql; then
        print_warning "PostgreSQL 已安装"
        psql --version
        press_enter
        return
    fi
    
    print_info "正在安装 PostgreSQL..."
    echo ""
    
    sudo apt update
    sudo apt install -y postgresql postgresql-contrib
    
    if [ $? -eq 0 ]; then
        print_success "PostgreSQL 安装成功"
        echo ""
        print_info "PostgreSQL 版本: $(psql --version)"
        print_info "PostgreSQL 服务状态:"
        sudo systemctl status postgresql --no-pager -l
    else
        print_error "PostgreSQL 安装失败"
    fi
    
    press_enter
}

# 创建 PostgreSQL 数据库
create_postgresql_database() {
    clear
    echo "=========================================="
    echo "   创建 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    read -p "数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    read -p "数据库用户名: " db_user
    if [ -z "$db_user" ]; then
        print_error "用户名不能为空"
        press_enter
        return
    fi
    
    read -sp "数据库密码: " db_password
    echo ""
    
    if [ -z "$db_password" ]; then
        print_error "密码不能为空"
        press_enter
        return
    fi
    
    echo ""
    print_info "正在创建数据库和用户..."
    
    # 创建用户
    sudo -u postgres psql << EOF
CREATE USER ${db_user} WITH PASSWORD '${db_password}';
CREATE DATABASE ${db_name} OWNER ${db_user};
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};
\q
EOF
    
    if [ $? -eq 0 ]; then
        print_success "数据库创建成功"
        echo ""
        echo "数据库信息："
        echo "  数据库名: ${db_name}"
        echo "  用户名: ${db_user}"
        echo "  密码: ${db_password}"
        echo ""
        echo "连接命令："
        echo "  psql -U ${db_user} -d ${db_name} -h localhost"
    else
        print_error "数据库创建失败"
    fi
    
    press_enter
}

# 列出 PostgreSQL 数据库
list_postgresql_databases() {
    clear
    echo "=========================================="
    echo "   PostgreSQL 数据库列表"
    echo "=========================================="
    echo ""
    
    sudo -u postgres psql -c "\l"
    
    echo ""
    print_info "用户列表:"
    sudo -u postgres psql -c "\du"
    
    press_enter
}

# 备份 PostgreSQL 数据库
backup_postgresql_database() {
    clear
    echo "=========================================="
    echo "   备份 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
    echo ""
    
    read -p "要备份的数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    # 备份目录
    backup_dir="/var/backups/postgresql"
    sudo mkdir -p "$backup_dir"
    
    # 备份文件名
    backup_file="${backup_dir}/${db_name}_$(date +%Y%m%d_%H%M%S).sql"
    
    print_info "正在备份数据库..."
    
    sudo -u postgres pg_dump "$db_name" > "$backup_file"
    
    if [ $? -eq 0 ]; then
        # 压缩备份
        gzip "$backup_file"
        print_success "备份完成"
        echo ""
        echo "备份文件: ${backup_file}.gz"
        echo "文件大小: $(du -h ${backup_file}.gz | awk '{print $1}')"
    else
        print_error "备份失败"
    fi
    
    press_enter
}

# 恢复 PostgreSQL 数据库
restore_postgresql_database() {
    clear
    echo "=========================================="
    echo "   恢复 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    backup_dir="/var/backups/postgresql"
    
    if [ ! -d "$backup_dir" ]; then
        print_error "备份目录不存在: $backup_dir"
        press_enter
        return
    fi
    
    # 列出备份文件
    print_info "可用的备份文件："
    ls -lh "$backup_dir"/*.sql.gz 2>/dev/null || echo "  没有找到备份文件"
    echo ""
    
    read -p "备份文件路径: " backup_file
    if [ ! -f "$backup_file" ]; then
        print_error "文件不存在"
        press_enter
        return
    fi
    
    read -p "目标数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    print_warning "此操作将覆盖数据库 ${db_name} 的所有数据"
    read -p "确认继续？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在恢复数据库..."
    
    # 解压并恢复
    if [[ "$backup_file" == *.gz ]]; then
        gunzip -c "$backup_file" | sudo -u postgres psql "$db_name"
    else
        sudo -u postgres psql "$db_name" < "$backup_file"
    fi
    
    if [ $? -eq 0 ]; then
        print_success "数据库恢复成功"
    else
        print_error "数据库恢复失败"
    fi
    
    press_enter
}

# 删除 PostgreSQL 数据库
delete_postgresql_database() {
    clear
    echo "=========================================="
    echo "   删除 PostgreSQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"
    echo ""
    
    read -p "要删除的数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    print_warning "警告：此操作将永久删除数据库 ${db_name}"
    read -p "请输入数据库名称以确认: " confirm_name
    
    if [ "$confirm_name" != "$db_name" ]; then
        print_error "名称不匹配，已取消"
        press_enter
        return
    fi
    
    print_info "正在删除数据库..."
    
    sudo -u postgres psql -c "DROP DATABASE ${db_name};"
    
    if [ $? -eq 0 ]; then
        print_success "数据库已删除"
    else
        print_error "数据库删除失败"
    fi
    
    press_enter
}

# PostgreSQL 服务管理
manage_postgresql_service() {
    clear
    echo "=========================================="
    echo "   PostgreSQL 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "5. 重新加载配置"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-5]: " choice
    
    case $choice in
        1)
            sudo systemctl status postgresql --no-pager -l
            ;;
        2)
            sudo systemctl start postgresql
            print_success "PostgreSQL 服务已启动"
            ;;
        3)
            sudo systemctl stop postgresql
            print_success "PostgreSQL 服务已停止"
            ;;
        4)
            sudo systemctl restart postgresql
            print_success "PostgreSQL 服务已重启"
            ;;
        5)
            sudo systemctl reload postgresql
            print_success "PostgreSQL 配置已重新加载"
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# PostgreSQL 子菜单
postgresql_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   PostgreSQL 管理"
        echo "=========================================="
        echo ""
        
        if check_postgresql; then
            print_success "PostgreSQL 已安装"
            pg_version=$(sudo -u postgres psql -V | awk '{print $3}')
            echo "  版本: ${pg_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet postgresql; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "PostgreSQL 未安装"
        fi
        
        echo ""
        echo "1. 安装 PostgreSQL"
        echo "2. 创建数据库"
        echo "3. 列出数据库"
        echo "4. 备份数据库"
        echo "5. 恢复数据库"
        echo "6. 删除数据库"
        echo "7. 服务管理"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-7]: " choice
        
        case $choice in
            1) install_postgresql ;;
            2) create_postgresql_database ;;
            3) list_postgresql_databases ;;
            4) backup_postgresql_database ;;
            5) restore_postgresql_database ;;
            6) delete_postgresql_database ;;
            7) manage_postgresql_service ;;
            0) return ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# ============================================
# MySQL/MariaDB 管理函数
# ============================================

# 检查 MySQL 是否安装
check_mysql() {
    if command -v mysql &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 安装 MySQL
install_mysql() {
    clear
    echo "=========================================="
    echo "   安装 MySQL/MariaDB"
    echo "=========================================="
    echo ""
    
    if check_mysql; then
        print_warning "MySQL/MariaDB 已安装"
        mysql --version
        press_enter
        return
    fi
    
    echo "选择安装版本："
    echo "1. MySQL (官方版本)"
    echo "2. MariaDB (开源分支)"
    echo ""
    
    read -p "请选择 [1-2]: " db_type
    
    print_info "正在安装..."
    echo ""
    
    sudo apt update
    
    case $db_type in
        1)
            sudo apt install -y mysql-server
            ;;
        2)
            sudo apt install -y mariadb-server
            ;;
        *)
            print_error "无效选择"
            press_enter
            return
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        print_success "安装成功"
        echo ""
        print_info "版本: $(mysql --version)"
        echo ""
        print_warning "建议运行安全配置："
        echo "  sudo mysql_secure_installation"
    else
        print_error "安装失败"
    fi
    
    press_enter
}

# 创建 MySQL 数据库
create_mysql_database() {
    clear
    echo "=========================================="
    echo "   创建 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    read -p "数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    read -p "数据库用户名: " db_user
    if [ -z "$db_user" ]; then
        print_error "用户名不能为空"
        press_enter
        return
    fi
    
    read -sp "数据库密码: " db_password
    echo ""
    
    if [ -z "$db_password" ]; then
        print_error "密码不能为空"
        press_enter
        return
    fi
    
    echo ""
    print_info "正在创建数据库和用户..."
    
    sudo mysql << EOF
CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    if [ $? -eq 0 ]; then
        print_success "数据库创建成功"
        echo ""
        echo "数据库信息："
        echo "  数据库名: ${db_name}"
        echo "  用户名: ${db_user}"
        echo "  密码: ${db_password}"
        echo ""
        echo "连接命令："
        echo "  mysql -u ${db_user} -p${db_password} ${db_name}"
    else
        print_error "数据库创建失败"
    fi
    
    press_enter
}

# 列出 MySQL 数据库
list_mysql_databases() {
    clear
    echo "=========================================="
    echo "   MySQL 数据库列表"
    echo "=========================================="
    echo ""
    
    sudo mysql -e "SHOW DATABASES;"
    
    echo ""
    print_info "用户列表:"
    sudo mysql -e "SELECT User, Host FROM mysql.user;"
    
    press_enter
}

# 备份 MySQL 数据库
backup_mysql_database() {
    clear
    echo "=========================================="
    echo "   备份 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo mysql -N -e "SHOW DATABASES;" | grep -v "information_schema\|performance_schema\|mysql\|sys"
    echo ""
    
    read -p "要备份的数据库名称 (all 表示所有): " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    # 备份目录
    backup_dir="/var/backups/mysql"
    sudo mkdir -p "$backup_dir"
    
    # 备份文件名
    if [ "$db_name" = "all" ]; then
        backup_file="${backup_dir}/all_databases_$(date +%Y%m%d_%H%M%S).sql"
        print_info "正在备份所有数据库..."
        sudo mysqldump --all-databases > "$backup_file"
    else
        backup_file="${backup_dir}/${db_name}_$(date +%Y%m%d_%H%M%S).sql"
        print_info "正在备份数据库..."
        sudo mysqldump "$db_name" > "$backup_file"
    fi
    
    if [ $? -eq 0 ]; then
        # 压缩备份
        gzip "$backup_file"
        print_success "备份完成"
        echo ""
        echo "备份文件: ${backup_file}.gz"
        echo "文件大小: $(du -h ${backup_file}.gz | awk '{print $1}')"
    else
        print_error "备份失败"
    fi
    
    press_enter
}

# 恢复 MySQL 数据库
restore_mysql_database() {
    clear
    echo "=========================================="
    echo "   恢复 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    backup_dir="/var/backups/mysql"
    
    if [ ! -d "$backup_dir" ]; then
        print_error "备份目录不存在: $backup_dir"
        press_enter
        return
    fi
    
    # 列出备份文件
    print_info "可用的备份文件："
    ls -lh "$backup_dir"/*.sql.gz 2>/dev/null || echo "  没有找到备份文件"
    echo ""
    
    read -p "备份文件路径: " backup_file
    if [ ! -f "$backup_file" ]; then
        print_error "文件不存在"
        press_enter
        return
    fi
    
    read -p "目标数据库名称 (留空表示从备份恢复所有): " db_name
    
    print_warning "此操作将覆盖数据库数据"
    read -p "确认继续？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        print_info "已取消"
        press_enter
        return
    fi
    
    print_info "正在恢复数据库..."
    
    # 解压并恢复
    if [[ "$backup_file" == *.gz ]]; then
        if [ -z "$db_name" ]; then
            gunzip -c "$backup_file" | sudo mysql
        else
            gunzip -c "$backup_file" | sudo mysql "$db_name"
        fi
    else
        if [ -z "$db_name" ]; then
            sudo mysql < "$backup_file"
        else
            sudo mysql "$db_name" < "$backup_file"
        fi
    fi
    
    if [ $? -eq 0 ]; then
        print_success "数据库恢复成功"
    else
        print_error "数据库恢复失败"
    fi
    
    press_enter
}

# 删除 MySQL 数据库
delete_mysql_database() {
    clear
    echo "=========================================="
    echo "   删除 MySQL 数据库"
    echo "=========================================="
    echo ""
    
    # 列出数据库
    print_info "可用的数据库："
    sudo mysql -N -e "SHOW DATABASES;" | grep -v "information_schema\|performance_schema\|mysql\|sys"
    echo ""
    
    read -p "要删除的数据库名称: " db_name
    if [ -z "$db_name" ]; then
        print_error "数据库名称不能为空"
        press_enter
        return
    fi
    
    print_warning "警告：此操作将永久删除数据库 ${db_name}"
    read -p "请输入数据库名称以确认: " confirm_name
    
    if [ "$confirm_name" != "$db_name" ]; then
        print_error "名称不匹配，已取消"
        press_enter
        return
    fi
    
    print_info "正在删除数据库..."
    
    sudo mysql -e "DROP DATABASE ${db_name};"
    
    if [ $? -eq 0 ]; then
        print_success "数据库已删除"
    else
        print_error "数据库删除失败"
    fi
    
    press_enter
}

# MySQL 服务管理
manage_mysql_service() {
    clear
    echo "=========================================="
    echo "   MySQL 服务管理"
    echo "=========================================="
    echo ""
    
    echo "1. 查看服务状态"
    echo "2. 启动服务"
    echo "3. 停止服务"
    echo "4. 重启服务"
    echo "0. 返回"
    echo ""
    
    read -p "请选择 [0-4]: " choice
    
    # 检测使用的是 MySQL 还是 MariaDB
    service_name="mysql"
    if systemctl list-units --type=service | grep -q "mariadb"; then
        service_name="mariadb"
    fi
    
    case $choice in
        1)
            sudo systemctl status $service_name --no-pager -l
            ;;
        2)
            sudo systemctl start $service_name
            print_success "MySQL 服务已启动"
            ;;
        3)
            sudo systemctl stop $service_name
            print_success "MySQL 服务已停止"
            ;;
        4)
            sudo systemctl restart $service_name
            print_success "MySQL 服务已重启"
            ;;
        0)
            return
            ;;
    esac
    
    press_enter
}

# MySQL 子菜单
mysql_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   MySQL/MariaDB 管理"
        echo "=========================================="
        echo ""
        
        if check_mysql; then
            print_success "MySQL/MariaDB 已安装"
            mysql_version=$(mysql --version | awk '{print $5}' | sed 's/,//')
            echo "  版本: ${mysql_version}"
            
            # 显示服务状态
            if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
                print_success "服务状态: 运行中"
            else
                print_error "服务状态: 已停止"
            fi
        else
            print_warning "MySQL/MariaDB 未安装"
        fi
        
        echo ""
        echo "1. 安装 MySQL/MariaDB"
        echo "2. 创建数据库"
        echo "3. 列出数据库"
        echo "4. 备份数据库"
        echo "5. 恢复数据库"
        echo "6. 删除数据库"
        echo "7. 服务管理"
        echo "0. 返回上级菜单"
        echo ""
        
        read -p "请选择 [0-7]: " choice
        
        case $choice in
            1) install_mysql ;;
            2) create_mysql_database ;;
            3) list_mysql_databases ;;
            4) backup_mysql_database ;;
            5) restore_mysql_database ;;
            6) delete_mysql_database ;;
            7) manage_mysql_service ;;
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
        echo "   数据库管理"
        echo "=========================================="
        echo ""
        
        # 显示安装状态
        if check_postgresql; then
            print_success "PostgreSQL: 已安装"
        else
            echo -e "${YELLOW}○${NC} PostgreSQL: 未安装"
        fi
        
        if check_mysql; then
            print_success "MySQL/MariaDB: 已安装"
        else
            echo -e "${YELLOW}○${NC} MySQL/MariaDB: 未安装"
        fi
        
        echo ""
        echo "1. PostgreSQL 管理"
        echo "2. MySQL/MariaDB 管理"
        echo ""
        echo "0. 返回主菜单"
        echo ""
        
        read -p "请选择 [0-2]: " choice
        
        case $choice in
            1) postgresql_menu ;;
            2) mysql_menu ;;
            0) exit 0 ;;
            *) print_error "无效选择"; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main_menu
