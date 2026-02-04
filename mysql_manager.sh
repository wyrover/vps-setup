#!/bin/bash
set -euo pipefail

#==========================================================
# MySQL/MariaDB 远程访问管理脚本（完整版）
#==========================================================

# 默认配置
DEFAULT_BIND_LOCAL="127.0.0.1"
DEFAULT_BIND_REMOTE="0.0.0.0"
DEFAULT_REMOTE_HOST="10.0.0.%"        # 默认允许的 IP 段
MYSQL_SERVICE="mariadb"                # 或 "mysql"
ROOT_USER="root"
DOWNLOAD_DIR="/tmp/mysql_imports"      # 下载目录

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#==========================================================
# 函数：生成随机密码（确保包含数字和符号）
#==========================================================
generate_random_password() {
    local length=${1:-16}
    local password=""
    local has_digit=0
    local has_special=0
    
    # 定义字符集
    local uppercase="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local lowercase="abcdefghijklmnopqrstuvwxyz"
    local digits="0123456789"
    local specials="!@#$%^&*-_=+"
    local all_chars="${uppercase}${lowercase}${digits}${specials}"
    
    # 循环生成密码，直到满足要求
    while true; do
        password=""
        has_digit=0
        has_special=0
        
        # 生成随机密码
        while [ ${#password} -lt $length ]; do
            local random_byte
            random_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
            local index=$((random_byte % ${#all_chars}))
            local char="${all_chars:$index:1}"
            password="${password}${char}"
            
            # 检查是否包含数字
            if [[ "$char" =~ [0-9] ]]; then
                has_digit=1
            fi
            
            # 检查是否包含特殊符号
            if [[ "$char" =~ [!@#\$%^\&*\-_=+] ]]; then
                has_special=1
            fi
        done
        
        # 如果密码满足要求（包含数字和符号），跳出循环
        if [ $has_digit -eq 1 ] && [ $has_special -eq 1 ]; then
            break
        fi
    done
    
    echo "$password"
}

#==========================================================
# 函数：生成随机密码（备用方法 - 使用 $RANDOM）
#==========================================================
generate_random_password_fallback() {
    local length=${1:-16}
    local password=""
    local has_digit=0
    local has_special=0
    
    # 定义字符集
    local uppercase="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local lowercase="abcdefghijklmnopqrstuvwxyz"
    local digits="0123456789"
    local specials="!@#$%^&*-_=+"
    local all_chars="${uppercase}${lowercase}${digits}${specials}"
    
    # 循环生成密码，直到满足要求
    while true; do
        password=""
        has_digit=0
        has_special=0
        
        # 生成随机密码
        for ((i=0; i<length; i++)); do
            local index=$((RANDOM % ${#all_chars}))
            local char="${all_chars:$index:1}"
            password="${password}${char}"
            
            # 检查是否包含数字
            if [[ "$char" =~ [0-9] ]]; then
                has_digit=1
            fi
            
            # 检查是否包含特殊符号
            if [[ "$char" =~ [!@#\$%^\&*\-_=+] ]]; then
                has_special=1
            fi
        done
        
        # 如果密码满足要求，跳出循环
        if [ $has_digit -eq 1 ] && [ $has_special -eq 1 ]; then
            break
        fi
    done
    
    echo "$password"
}

#==========================================================
# 函数：生成随机密码（确保包含要求 - 优化版本）
#==========================================================
generate_random_password_optimized() {
    local length=${1:-16}
    
    # 定义字符集
    local uppercase="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local lowercase="abcdefghijklmnopqrstuvwxyz"
    local digits="0123456789"
    local specials="!@#$%^&*-_=+"
    local all_chars="${uppercase}${lowercase}${digits}${specials}"
    
    # 确保至少有一个数字和一个符号
    local password=""
    
    # 第一步：随机选择一个数字
    local random_byte
    random_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
    password="${password}${digits:$((random_byte % ${#digits})):1}"
    
    # 第二步：随机选择一个特殊符号
    random_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
    password="${password}${specials:$((random_byte % ${#specials})):1}"
    
    # 第三步：填充剩余字符
    local remaining=$((length - 2))
    for ((i=0; i<remaining; i++)); do
        random_byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
        password="${password}${all_chars:$((random_byte % ${#all_chars})):1}"
    done
    
    # 第四步：打乱密码顺序（避免前两位总是数字+符号）
    password=$(echo "$password" | fold -w1 | shuf | tr -d '\n')
    
    echo "$password"
}

#==========================================================
# 函数：验证密码强度
#==========================================================
validate_password() {
    local password="$1"
    local has_digit=0
    local has_special=0
    
    # 检查是否包含数字
    if [[ "$password" =~ [0-9] ]]; then
        has_digit=1
    fi
    
    # 检查是否包含特殊符号
    if [[ "$password" =~ [!@#\$%^\&*\-_=+] ]]; then
        has_special=1
    fi
    
    # 返回验证结果
    if [ $has_digit -eq 1 ] && [ $has_special -eq 1 ] && [ ${#password} -ge 8 ]; then
        return 0  # 密码有效
    else
        return 1  # 密码无效
    fi
}

#==========================================================
# 函数：交互式读取输入（带默认值）
#==========================================================
read_with_default() {
    local prompt="$1"
    local default="$2"
    local varname="$3"
    local input
    
    if [ -n "$default" ]; then
        read -p "$prompt [默认: $default]: " input
    else
        read -p "$prompt: " input
    fi
    
    # 使用默认值（如果用户直接按 Enter）
    eval "$varname=\"${input:-$default}\""
}

#==========================================================
# 函数：安全读取密码（带随机生成的默认值）
#==========================================================
read_password_with_random_default() {
    local prompt="$1"
    local varname="$2"
    local default_password
    local input
    
    # 生成随机密码作为默认值（优先使用优化版本）
    if command -v shuf >/dev/null 2>&1 && [ -r /dev/urandom ]; then
        default_password=$(generate_random_password_optimized 16)
    elif [ -r /dev/urandom ]; then
        default_password=$(generate_random_password 16)
    else
        # 如果 /dev/urandom 不可用，使用 $RANDOM 作为备用
        default_password=$(generate_random_password_fallback 16)
    fi
    
    echo -e "${CYAN}提示: 直接按 Enter 将使用随机生成的安全密码（包含数字和符号）${NC}"
    
    while true; do
        read -sp "$prompt [默认: 随机生成]: " input
        echo
        
        # 如果用户直接按 Enter，使用随机生成的密码
        if [ -z "$input" ]; then
            eval "$varname=\"$default_password\""
            break
        else
            # 验证用户输入的密码
            if validate_password "$input"; then
                eval "$varname=\"$input\""
                break
            else
                echo -e "${RED}✗ 密码必须包含至少一个数字、一个特殊符号(!@#\$%^&*-_=+)，且长度不少于8位${NC}"
                echo -e "${YELLOW}请重新输入密码:${NC}"
            fi
        fi
    done
}

#==========================================================
# 函数：安全读取密码（普通密码，不生成随机）
#==========================================================
read_password_simple() {
    local prompt="$1"
    local varname="$2"
    local input
    
    read -sp "$prompt: " input
    echo
    
    eval "$varname=\"$input\""
}

#==========================================================
# 函数：修改绑定地址
#==========================================================
change_bind_address() {
    local target_bind="$1"
    local config_files=(
        "/etc/mysql/mysql.conf.d/mysqld.cnf"
        "/etc/mysql/mariadb.conf.d/50-server.cnf"
        "/etc/my.cnf"
        "/etc/mysql/my.cnf"
    )
    
    local found=0
    for cfg in "${config_files[@]}"; do
        if [ -f "$cfg" ]; then
            echo -e "${YELLOW}检查配置文件: $cfg${NC}"
            
            # 备份原文件
            sudo cp "$cfg" "${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
            
            if grep -qE "^\s*bind-address" "$cfg"; then
                # 替换现有的 bind-address
                sudo sed -i "s/^\s*bind-address\s*=.*/bind-address = ${target_bind}/" "$cfg"
                echo -e "${GREEN}✓ 已更新 bind-address = ${target_bind}${NC}"
                found=1
            else
                # 在 [mysqld] 段落添加 bind-address
                if grep -q "^\[mysqld\]" "$cfg"; then
                    sudo sed -i "/^\[mysqld\]/a bind-address = ${target_bind}" "$cfg"
                    echo -e "${GREEN}✓ 已添加 bind-address = ${target_bind}${NC}"
                    found=1
                else
                    # 直接追加到文件末尾
                    echo -e "\n[mysqld]\nbind-address = ${target_bind}" | sudo tee -a "$cfg" >/dev/null
                    echo -e "${GREEN}✓ 已添加 [mysqld] 和 bind-address = ${target_bind}${NC}"
                    found=1
                fi
            fi
            break
        fi
    done
    
    if [ "$found" -eq 0 ]; then
        echo -e "${RED}✗ 未找到配置文件，请手动设置 bind-address${NC}"
        return 1
    fi
}

#==========================================================
# 函数：重启数据库服务
#==========================================================
restart_db() {
    echo -e "${YELLOW}正在重启数据库服务...${NC}"
    
    if sudo systemctl is-active --quiet "${MYSQL_SERVICE}"; then
        sudo systemctl restart "${MYSQL_SERVICE}"
        echo -e "${GREEN}✓ 数据库服务已重启${NC}"
    else
        echo -e "${RED}✗ 数据库服务未运行，尝试启动...${NC}"
        sudo systemctl start "${MYSQL_SERVICE}"
    fi
    
    sleep 2
}

#==========================================================
# 函数：配置远程访问
#==========================================================
setup_remote_access() {
    local password="$1"
    local remote_host="$2"
    
    echo -e "${YELLOW}正在配置远程访问权限...${NC}"
    
    # 创建 SQL 语句
    local sql="
    CREATE USER IF NOT EXISTS '${ROOT_USER}'@'${remote_host}' IDENTIFIED BY '${password}';
    GRANT ALL PRIVILEGES ON *.* TO '${ROOT_USER}'@'${remote_host}' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
    "
    
    # 执行 SQL（尝试不同的认证方式）
    if echo "$sql" | mysql -u"${ROOT_USER}" 2>/dev/null; then
        echo -e "${GREEN}✓ 远程访问权限配置成功${NC}"
    elif echo "$sql" | mysql -u"${ROOT_USER}" -p"${password}" 2>/dev/null; then
        echo -e "${GREEN}✓ 远程访问权限配置成功${NC}"
    else
        echo -e "${RED}✗ 配置失败，请检查 root 密码是否正确${NC}"
        return 1
    fi
    
    echo -e "${GREEN}已授权 ${ROOT_USER}@${remote_host} 远程访问${NC}"
}

#==========================================================
# 函数：修改 root 密码
#==========================================================
change_root_password() {
    local new_password="$1"
    
    echo -e "${YELLOW}正在修改本地 root 密码...${NC}"
    
    # 创建 SQL 语句
    local sql="
    ALTER USER '${ROOT_USER}'@'localhost' IDENTIFIED BY '${new_password}';
    FLUSH PRIVILEGES;
    "
    
    # 执行 SQL
    if echo "$sql" | mysql -u"${ROOT_USER}" 2>/dev/null; then
        echo -e "${GREEN}✓ 本地 root 密码修改成功${NC}"
        return 0
    else
        echo -e "${RED}✗ 密码修改失败${NC}"
        return 1
    fi
}

#==========================================================
# 函数：下载 SQL 文件（支持 Basic Auth）
#==========================================================
download_sql_file() {
    local url="$1"
    local username="$2"
    local password="$3"
    local output_file="$4"
    
    echo -e "${YELLOW}正在下载文件...${NC}"
    echo -e "${CYAN}URL: $url${NC}"
    
    # 使用 curl 下载，支持 Basic Auth
    if [ -n "$username" ] && [ -n "$password" ]; then
        if curl -f -L -u "${username}:${password}" -o "$output_file" "$url" --progress-bar; then
            echo -e "${GREEN}✓ 文件下载成功: $output_file${NC}"
            return 0
        else
            echo -e "${RED}✗ 文件下载失败${NC}"
            return 1
        fi
    else
        # 无认证下载
        if curl -f -L -o "$output_file" "$url" --progress-bar; then
            echo -e "${GREEN}✓ 文件下载成功: $output_file${NC}"
            return 0
        else
            echo -e "${RED}✗ 文件下载失败${NC}"
            return 1
        fi
    fi
}

#==========================================================
# 函数：解压文件
#==========================================================
decompress_file() {
    local file="$1"
    local output_file="${file%.*}"  # 移除最后一个扩展名
    
    echo -e "${YELLOW}正在解压文件...${NC}"
    
    case "$file" in
        *.bz2)
            if bunzip2 -k -f "$file"; then
                echo -e "${GREEN}✓ 解压成功: $output_file${NC}"
                echo "$output_file"
                return 0
            else
                echo -e "${RED}✗ 解压失败${NC}"
                return 1
            fi
            ;;
        *.gz)
            if gunzip -k -f "$file"; then
                echo -e "${GREEN}✓ 解压成功: $output_file${NC}"
                echo "$output_file"
                return 0
            else
                echo -e "${RED}✗ 解压失败${NC}"
                return 1
            fi
            ;;
        *.zip)
            output_file="${file%.*}"
            if unzip -o "$file" -d "$(dirname "$file")"; then
                echo -e "${GREEN}✓ 解压成功${NC}"
                # 尝试找到 .sql 文件
                local sql_file
                sql_file=$(find "$(dirname "$file")" -name "*.sql" -type f | head -n 1)
                echo "$sql_file"
                return 0
            else
                echo -e "${RED}✗ 解压失败${NC}"
                return 1
            fi
            ;;
        *.sql)
            echo -e "${CYAN}文件已经是 SQL 格式，无需解压${NC}"
            echo "$file"
            return 0
            ;;
        *)
            echo -e "${RED}✗ 不支持的文件格式${NC}"
            return 1
            ;;
    esac
}

#==========================================================
# 函数：显示当前监听状态
#==========================================================
show_status() {
    echo -e "\n${YELLOW}当前数据库监听状态:${NC}"
    if command -v ss >/dev/null 2>&1; then
        sudo ss -tlnp | grep 3306 || echo "未检测到 3306 端口监听"
    elif command -v netstat >/dev/null 2>&1; then
        sudo netstat -tlnp | grep 3306 || echo "未检测到 3306 端口监听"
    else
        echo "无法检测（需要 ss 或 netstat 工具）"
    fi
}

#==========================================================
# 函数：打印密码信息框
#==========================================================
print_password_box() {
    local password="$1"
    local host="$2"
    
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           远程访问凭据 (请妥善保存)                        ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC} ${CYAN}用户名:${NC}     %-45s ${GREEN}║${NC}\n" "${ROOT_USER}"
    printf "${GREEN}║${NC} ${CYAN}密码:${NC}       %-45s ${GREEN}║${NC}\n" "${password}"
    printf "${GREEN}║${NC} ${CYAN}允许主机:${NC}   %-45s ${GREEN}║${NC}\n" "${host}"
    printf "${GREEN}║${NC} ${CYAN}密码强度:${NC}   包含大小写字母、数字和特殊符号%-12s ${GREEN}║${NC}\n" ""
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${YELLOW}连接示例:${NC}                                                  ${GREEN}║${NC}"
    printf "${GREEN}║${NC}   mysql -h <服务器IP> -u${ROOT_USER} -p                         ${GREEN}║${NC}\n"
    echo -e "${GREEN}║${NC}   然后输入上述密码                                        ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

#==========================================================
# 函数：打印本地密码信息框
#==========================================================
print_local_password_box() {
    local password="$1"
    
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           本地 root 密码 (请妥善保存)                      ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC} ${CYAN}用户名:${NC}     %-45s ${GREEN}║${NC}\n" "${ROOT_USER}"
    printf "${GREEN}║${NC} ${CYAN}密码:${NC}       %-45s ${GREEN}║${NC}\n" "${password}"
    printf "${GREEN}║${NC} ${CYAN}主机:${NC}       %-45s ${GREEN}║${NC}\n" "localhost"
    printf "${GREEN}║${NC} ${CYAN}密码强度:${NC}   包含大小写字母、数字和特殊符号%-12s ${GREEN}║${NC}\n" ""
    echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} ${YELLOW}连接示例:${NC}                                                  ${GREEN}║${NC}"
    printf "${GREEN}║${NC}   mysql -u${ROOT_USER} -p                                       ${GREEN}║${NC}\n"
    echo -e "${GREEN}║${NC}   然后输入上述密码                                        ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
}

#==========================================================
# 菜单：修改 root 密码
#==========================================================
menu_change_root_password() {
    echo -e "\n${GREEN}============================================${NC}"
    echo -e "${GREEN}  修改本地 root 密码${NC}"
    echo -e "${GREEN}============================================${NC}\n"
    
    echo -e "${YELLOW}请设置新的 root 密码:${NC}"
    echo -e "${CYAN}密码要求: 至少8位，必须包含数字和特殊符号(!@#\$%^&*-_=+)${NC}"
    
    local new_password
    read_password_with_random_default "新密码" "new_password"
    
    # 确认
    echo -e "\n${YELLOW}确认要修改本地 root@localhost 的密码吗？${NC}"
    read -p "继续？[Y/n]: " confirm
    
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        if change_root_password "$new_password"; then
            print_local_password_box "$new_password"
            echo -e "${RED}重要提示: 请立即保存密码到安全位置${NC}\n"
        fi
    else
        echo -e "${YELLOW}已取消操作${NC}"
    fi
}

#==========================================================
# 菜单：配置绑定地址和远程访问
#==========================================================
menu_configure_binding() {
    echo -e "\n${GREEN}============================================${NC}"
    echo -e "${GREEN}  配置数据库绑定地址${NC}"
    echo -e "${GREEN}============================================${NC}\n"
    
    # 1. 选择绑定模式
    echo "请选择绑定模式:"
    echo "  1) 本地模式 (127.0.0.1) - 仅本机访问"
    echo "  2) 远程模式 (0.0.0.0) - 允许外部访问"
    read -p "请输入选项 [1/2]: " bind_choice
    
    case "$bind_choice" in
        1)
            TARGET_BIND="$DEFAULT_BIND_LOCAL"
            echo -e "${GREEN}已选择: 本地模式${NC}\n"
            REMOTE_MODE=false
            ;;
        2)
            TARGET_BIND="$DEFAULT_BIND_REMOTE"
            echo -e "${GREEN}已选择: 远程模式${NC}\n"
            REMOTE_MODE=true
            ;;
        *)
            echo -e "${RED}无效选项，返回主菜单${NC}\n"
            return
            ;;
    esac
    
    # 2. 修改绑定地址
    change_bind_address "$TARGET_BIND"
    
    # 3. 如果选择远程模式，配置远程访问
    if [ "$REMOTE_MODE" = true ]; then
        echo -e "\n${YELLOW}配置远程访问参数:${NC}"
        
        # 交互式输入 IP 段
        read_with_default "允许访问的 IP 段（如 10.0.0.% 或 192.168.1.5）" \
                         "$DEFAULT_REMOTE_HOST" \
                         "REMOTE_HOST"
        
        # 交互式输入密码（带随机生成的默认值）
        echo -e "\n${YELLOW}请设置 root 用户的远程访问密码:${NC}"
        echo -e "${CYAN}密码要求: 至少8位，必须包含数字和特殊符号(!@#\$%^&*-_=+)${NC}"
        read_password_with_random_default "root 远程密码" "ROOT_PASSWORD"
        
        # 确认配置
        echo -e "\n${YELLOW}配置摘要:${NC}"
        echo "  - 绑定地址: $TARGET_BIND"
        echo "  - 允许访问: ${ROOT_USER}@${REMOTE_HOST}"
        echo "  - 密码: ${ROOT_PASSWORD:0:4}****${ROOT_PASSWORD: -4}"
        read -p "确认继续？[Y/n]: " confirm
        
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            restart_db
            setup_remote_access "$ROOT_PASSWORD" "$REMOTE_HOST"
            
            echo -e "\n${GREEN}============================================${NC}"
            echo -e "${GREEN}  配置完成！${NC}"
            echo -e "${GREEN}============================================${NC}"
            
            # 打印密码信息框
            print_password_box "$ROOT_PASSWORD" "$REMOTE_HOST"
            
            echo -e "${RED}重要安全提示:${NC}"
            echo -e "  1. 请立即保存上述密码到安全位置"
            echo -e "  2. 请配置防火墙规则限制 3306 端口访问"
            echo -e "  3. 建议启用 SSL/TLS 加密连接"
            echo -e "  4. 定期更换强密码\n"
            
            echo -e "${YELLOW}防火墙配置示例 (ufw):${NC}"
            echo -e "  sudo ufw allow from ${REMOTE_HOST/\%/0\/24} to any port 3306"
            echo -e "\n${YELLOW}防火墙配置示例 (iptables):${NC}"
            echo -e "  sudo iptables -A INPUT -p tcp -s ${REMOTE_HOST/\%/0\/24} --dport 3306 -j ACCEPT"
            
            show_status
        else
            echo -e "${YELLOW}已取消配置${NC}"
        fi
    else
        # 仅本地模式，直接重启
        restart_db
        echo -e "\n${GREEN}已切换到本地模式，仅允许 127.0.0.1 访问${NC}"
        show_status
    fi
}

#==========================================================
# 菜单：下载并导入 SQL 文件（增强版）
#==========================================================
menu_import_sql() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           下载并导入 SQL 文件（支持 Basic Auth）           ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    # 创建下载目录
    mkdir -p "$DOWNLOAD_DIR"
    
    # ============================================
    # 1. 输入下载 URL
    # ============================================
    echo -e "${CYAN}请输入 SQL 文件的下载链接:${NC}"
    echo -e "${YELLOW}示例: https://xxx.com/dev798_20260204_020002.sql.bz2${NC}"
    local download_url
    read -p "URL: " download_url
    
    if [ -z "$download_url" ]; then
        echo -e "${RED}✗ URL 不能为空${NC}"
        return
    fi
    
    # ============================================
    # 2. Basic Auth 认证
    # ============================================
    echo -e "\n${CYAN}是否需要 Basic Auth 认证？${NC}"
    read -p "[y/N]: " need_auth
    
    local auth_username=""
    local auth_password=""
    
    if [[ "$need_auth" =~ ^[Yy]$ ]]; then
        read -p "用户名: " auth_username
        read_password_simple "密码" "auth_password"
    fi
    
    # ============================================
    # 3. 下载文件
    # ============================================
    local filename
    filename=$(basename "$download_url")
    local download_path="${DOWNLOAD_DIR}/${filename}"
    
    # 检查本地缓存
    if [ -f "$download_path" ]; then
        echo -e "${YELLOW}文件已存在本地缓存，是否重新下载？${NC}"
        read -p "[y/N]: " redownload
        if [[ ! "$redownload" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}✓ 使用本地缓存文件${NC}"
        else
            rm -f "$download_path"
            if ! download_sql_file "$download_url" "$auth_username" "$auth_password" "$download_path"; then
                echo -e "${RED}✗ 下载失败，操作终止${NC}"
                return
            fi
        fi
    else
        if ! download_sql_file "$download_url" "$auth_username" "$auth_password" "$download_path"; then
            echo -e "${RED}✗ 下载失败，操作终止${NC}"
            return
        fi
    fi
    
    # ============================================
    # 4. 解压文件
    # ============================================
    local sql_file
    sql_file=$(decompress_file "$download_path")
    
    if [ -z "$sql_file" ] || [ ! -f "$sql_file" ]; then
        echo -e "${RED}✗ 解压失败或找不到 SQL 文件，操作终止${NC}"
        return
    fi
    
    # ============================================
    # 5. 智能嗅探数据库名
    # ============================================
    echo -e "\n${YELLOW}正在分析 SQL 文件结构...${NC}"
    
    local header_content
    local db_in_file=""
    local contains_create_stmts=false
    
    # 根据文件类型读取前100行
    if [[ "$download_path" == *.bz2 ]]; then
        header_content=$(bzcat "$download_path" | head -n 100)
    elif [[ "$download_path" == *.gz ]]; then
        header_content=$(zcat "$download_path" | head -n 100)
    else
        header_content=$(head -n 100 "$sql_file")
    fi
    
    # 尝试检测数据库名
    if echo "$header_content" | grep -qi "Current Database:"; then
        db_in_file=$(echo "$header_content" | grep -i "Current Database:" | awk -F '`' '{print $2}' | head -n 1)
        contains_create_stmts=true
    elif echo "$header_content" | grep -qi "^USE "; then
        db_in_file=$(echo "$header_content" | grep -i "^USE " | head -n 1 | awk -F '`' '{print $2}')
        contains_create_stmts=true
    elif echo "$header_content" | grep -qi "CREATE DATABASE"; then
        db_in_file=$(echo "$header_content" | grep -i "CREATE DATABASE" | head -n 1 | awk -F '`' '{print $2}')
        contains_create_stmts=true
    fi
    
    local target_db=""
    
    if [ -n "$db_in_file" ]; then
        echo -e "${GREEN}✓ 检测到文件中的目标数据库: ${CYAN}${db_in_file}${NC}"
        target_db="$db_in_file"
    else
        echo -e "${YELLOW}⚠ 未能检测到目标数据库名${NC}"
        contains_create_stmts=false
    fi
    
    # 允许用户覆盖或输入数据库名
    echo -e "\n${CYAN}请输入目标数据库名:${NC}"
    local input_db
    if [ -n "$target_db" ]; then
        read -p "数据库名 [默认: $target_db]: " input_db
        target_db="${input_db:-$target_db}"
    else
        while [ -z "$target_db" ]; do
            read -p "数据库名: " target_db
        done
    fi
    
    # ============================================
    # 6. 数据库连接信息
    # ============================================
    echo -e "\n${CYAN}请输入数据库连接信息:${NC}"
    local db_user
    local db_password
    local db_host
    local db_port
    
    read_with_default "数据库主机" "localhost" "db_host"
    read_with_default "数据库端口" "3306" "db_port"
    read_with_default "数据库用户" "root" "db_user"
    read_password_simple "数据库密码（如无密码直接按 Enter）" "db_password"
    
    # ============================================
    # 7. 询问是否清洗现有数据库
    # ============================================
    echo -e "\n${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                      警告                                  ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${RED}是否要在还原前删除现有数据库 '${target_db}'？${NC}"
    echo -e "${RED}警告: 这将删除 '${target_db}' 中的所有数据！${NC}"
    read -p "输入 'yes' 确认删除，按 Enter 取消操作: " clean_db_choice
    
    if [ "$clean_db_choice" != "yes" ]; then
        echo -e "${YELLOW}用户选择不删除数据库，操作已取消${NC}"
        rm -f "$sql_file"
        [ "$sql_file" != "$download_path" ] && rm -f "$download_path"
        return
    fi
    
    # ============================================
    # 8. 询问是否创建新用户
    # ============================================
    echo -e "\n${CYAN}是否为 '${target_db}' 创建新的 MySQL 用户？${NC}"
    read -p "[Y/n]: " create_user_choice
    create_user_choice=${create_user_choice:-yes}
    
    local new_db_user=""
    local new_db_pass=""
    local user_host="%"
    
    if [[ "$create_user_choice" =~ ^[Yy]|^[Yy][Ee][Ss]$ ]]; then
        read -p "输入新用户名 [默认: ${target_db}_user]: " input_user
        new_db_user=${input_user:-"${target_db}_user"}
        
        echo -e "${CYAN}密码要求: 至少8位，必须包含数字和特殊符号(!@#\$%^&*-_=+)${NC}"
        read_password_with_random_default "用户密码" "new_db_pass"
        
        echo -e "\n${CYAN}是否允许远程访问？ (Host='%')${NC}"
        read -p "[Y/n]: " remote_access_choice
        remote_access_choice=${remote_access_choice:-yes}
        
        if [[ "$remote_access_choice" =~ ^[Yy]|^[Yy][Ee][Ss]$ ]]; then
            user_host="%"
            echo -e "${GREEN}用户将以 Host='%' 创建（允许远程访问）${NC}"
        else
            user_host="localhost"
            echo -e "${GREEN}用户将以 Host='localhost' 创建（仅本地访问）${NC}"
        fi
    fi
    
    # ============================================
    # 9. 最终确认
    # ============================================
    echo -e "\n${RED}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                     最终确认                               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "源文件     : ${YELLOW}${filename}${NC}"
    echo -e "目标数据库 : ${YELLOW}${target_db}${NC}"
    echo -e "操作       : ${RED}删除并还原${NC}"
    if [ -n "$new_db_user" ]; then
        echo -e "创建用户   : ${YELLOW}${new_db_user}@${user_host}${NC}"
    fi
    echo "============================================================"
    read -p "输入 'confirm' 执行还原操作: " final_confirm
    
    if [ "$final_confirm" != "confirm" ]; then
        echo -e "${YELLOW}操作已取消${NC}"
        rm -f "$sql_file"
        [ "$sql_file" != "$download_path" ] && rm -f "$download_path"
        return
    fi
    
    # ============================================
    # 10. 执行还原操作
    # ============================================
    export MYSQL_PWD="$db_password"
    local mysql_cmd="mysql -h${db_host} -P${db_port} -u${db_user}"
    
    # 删除数据库
    echo -e "\n${YELLOW}正在删除数据库 ${target_db}...${NC}"
    if $mysql_cmd -e "DROP DATABASE IF EXISTS \`${target_db}\`;" 2>/dev/null; then
        echo -e "${GREEN}✓ 数据库已删除${NC}"
    else
        echo -e "${RED}✗ 删除数据库失败${NC}"
        unset MYSQL_PWD
        return
    fi
    
    # 创建数据库
    echo -e "${YELLOW}正在创建数据库 ${target_db}...${NC}"
    if $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS \`${target_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
        echo -e "${GREEN}✓ 数据库已创建${NC}"
    else
        echo -e "${RED}✗ 创建数据库失败${NC}"
        unset MYSQL_PWD
        return
    fi
    
    # 还原数据
    echo -e "${YELLOW}正在还原数据...${NC}"
    
    local restore_success=false
    if [ "$contains_create_stmts" = true ]; then
        # 文件包含 USE 或 CREATE DATABASE 语句
        if [[ "$download_path" == *.bz2 ]]; then
            bunzip2 < "$download_path" | $mysql_cmd 2>/dev/null
        elif [[ "$download_path" == *.gz ]]; then
            gunzip < "$download_path" | $mysql_cmd 2>/dev/null
        else
            $mysql_cmd < "$sql_file" 2>/dev/null
        fi
    else
        # 文件不包含数据库选择语句，需要指定数据库
        if [[ "$download_path" == *.bz2 ]]; then
            bunzip2 < "$download_path" | $mysql_cmd "$target_db" 2>/dev/null
        elif [[ "$download_path" == *.gz ]]; then
            gunzip < "$download_path" | $mysql_cmd "$target_db" 2>/dev/null
        else
            $mysql_cmd "$target_db" < "$sql_file" 2>/dev/null
        fi
    fi
    
    if [ ${PIPESTATUS[1]} -eq 0 ]; then
        echo -e "${GREEN}✓ 数据还原完成${NC}"
        restore_success=true
    else
        echo -e "${RED}✗ 数据还原遇到错误${NC}"
    fi
    
    # ============================================
    # 11. 创建用户并授权
    # ============================================
    if [ -n "$new_db_user" ] && [ "$restore_success" = true ]; then
        echo -e "${YELLOW}正在创建用户并授权...${NC}"
        
        local sql_user_op="
        DROP USER IF EXISTS '${new_db_user}'@'${user_host}';
        CREATE USER '${new_db_user}'@'${user_host}' IDENTIFIED BY '${new_db_pass}';
        GRANT ALL PRIVILEGES ON \`${target_db}\`.* TO '${new_db_user}'@'${user_host}';
        FLUSH PRIVILEGES;"
        
        if $mysql_cmd -e "$sql_user_op" 2>/dev/null; then
            echo -e "${GREEN}✓ 用户创建成功${NC}"
        else
            echo -e "${RED}✗ 用户创建失败${NC}"
        fi
    fi
    
    # ============================================
    # 12. 验证与信息打印
    # ============================================
    if [ "$restore_success" = true ]; then
        echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                   还原摘要                                 ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
        
        echo -e "${CYAN}数据库 '${target_db}' 中的表:${NC}"
        $mysql_cmd -e "SHOW TABLES FROM \`${target_db}\`;" 2>/dev/null | tail -n +2 | head -n 20
        
        local table_count
        table_count=$($mysql_cmd -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${target_db}';" 2>/dev/null)
        echo -e "\n${GREEN}总共 ${table_count} 个表${NC}\n"
        
        if [ -n "$new_db_user" ]; then
            echo -e "${CYAN}用户访问信息:${NC}"
            $mysql_cmd -N -e "SELECT CONCAT('  ', user, '@', host) AS 'User' FROM mysql.user WHERE user='${new_db_user}';" 2>/dev/null
            
            echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${GREEN}║                  连接凭据                                  ║${NC}"
            echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
            printf "${GREEN}║${NC} ${CYAN}数据库:${NC}     %-45s ${GREEN}║${NC}\n" "$target_db"
            printf "${GREEN}║${NC} ${CYAN}用户名:${NC}     %-45s ${GREEN}║${NC}\n" "$new_db_user"
            printf "${GREEN}║${NC} ${CYAN}主机:${NC}       %-45s ${GREEN}║${NC}\n" "$user_host"
            printf "${GREEN}║${NC} ${CYAN}密码:${NC}       %-45s ${GREEN}║${NC}\n" "$new_db_pass"
            echo -e "${GREEN}╠════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${GREEN}║${NC} ${YELLOW}连接示例:${NC}                                                  ${GREEN}║${NC}"
            printf "${GREEN}║${NC}   mysql -h${db_host} -u${new_db_user} -p ${target_db}%-12s ${GREEN}║${NC}\n" ""
            echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
        fi
    fi
    
    # ============================================
    # 13. 清理临时文件
    # ============================================
    unset MYSQL_PWD
    
    echo -e "${YELLOW}是否删除临时文件？${NC}"
    read -p "[Y/n]: " cleanup_choice
    cleanup_choice=${cleanup_choice:-yes}
    
    if [[ "$cleanup_choice" =~ ^[Yy]|^[Yy][Ee][Ss]$ ]]; then
        rm -f "$sql_file"
        [ "$sql_file" != "$download_path" ] && rm -f "$download_path"
        echo -e "${GREEN}✓ 临时文件已清理${NC}"
    else
        echo -e "${YELLOW}临时文件保留在: ${download_path}${NC}"
    fi
    
    echo -e "\n${GREEN}操作完成！${NC}"
}

#==========================================================
# 主菜单
#==========================================================
show_main_menu() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}║        MySQL/MariaDB 远程访问管理脚本                      ║${NC}"
    echo -e "${GREEN}║                                                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}请选择操作:${NC}\n"
    echo "  1) 配置数据库绑定地址（本地/远程模式）"
    echo "  2) 修改本地 root 密码"
    echo "  3) 下载并导入 SQL 文件（支持 Basic Auth）"
    echo "  4) 查看数据库监听状态"
    echo "  5) 退出"
    echo
}

#==========================================================
# 主流程
#==========================================================
main() {
    while true; do
        show_main_menu
        read -p "请输入选项 [1-5]: " choice
        
        case "$choice" in
            1)
                menu_configure_binding
                read -p "按 Enter 键返回主菜单..."
                ;;
            2)
                menu_change_root_password
                read -p "按 Enter 键返回主菜单..."
                ;;
            3)
                menu_import_sql
                read -p "按 Enter 键返回主菜单..."
                ;;
            4)
                show_status
                read -p "按 Enter 键返回主菜单..."
                ;;
            5)
                echo -e "\n${GREEN}感谢使用，再见！${NC}\n"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 2
                ;;
        esac
    done
}

# 执行主流程
main
