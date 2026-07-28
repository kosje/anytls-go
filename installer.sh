#!/bin/bash

# ==========================================
# Anytls-go & Realm 综合管理脚本 (带域名/ACME及自毁卸载)
# ==========================================

# 颜色设置
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# Anytls-go 变量
INSTALL_DIR="/root/anytls"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# Realm 变量
REALM_BIN="/usr/local/bin/realm"
REALM_CONF_DIR="/etc/realm"
REALM_SERVICE="/etc/systemd/system/realm.service"

# 检查是否为root用户
if [ $EUID -ne 0 ]; then
    echo -e "${RED}❌ 错误：请使用 root 权限或 sudo 运行此脚本！${PLAIN}"
    exit 1
fi

# ==========================================
# 生成快捷命令 anytls
# ==========================================
if [ -f "$0" ] && [ "$(realpath $0)" != "/usr/local/bin/anytls" ]; then
    cp "$(realpath $0)" /usr/local/bin/anytls
    chmod +x /usr/local/bin/anytls
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}✅ 快捷命令配置成功！${PLAIN}"
    echo -e "${GREEN}👉 以后在任意路径下输入 ${YELLOW}anytls${GREEN} 即可调出本面板${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"
    sleep 2
fi

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在检查并安装必要的依赖 (curl, wget, unzip, tar, socat, cron)...${PLAIN}"
    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y curl wget unzip tar socat cron
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget unzip tar socat cron
    else
        echo -e "${RED}不支持的包管理器，请手动安装 curl, wget, unzip, tar, socat, cron！${PLAIN}"
    fi
}

# ==========================================
# Anytls-go 功能模块
# ==========================================

get_latest_version() {
    LATEST_VERSION=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}获取最新版本失败，请检查网络！${PLAIN}"
        exit 1
    fi
    VERSION_NUM=${LATEST_VERSION#v}
    echo -e "${GREEN}检测到 Anytls-go 最新版本为: ${LATEST_VERSION}${PLAIN}"
}

install_anytls() {
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}Anytls-go 似乎已经安装。如果需要覆盖安装，请先卸载。${PLAIN}"
        exit 1
    fi

    install_dependencies
    
    # 获取本机IP
    PUBLIC_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com)
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="请替换为您的服务器IP"
    fi

    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${YELLOW}是否使用自定义域名并申请真实 TLS 证书?${PLAIN}"
    echo -e "配置域名后，客户端将进行严格的 TLS 证书验证 (去掉 insecure)。"
    echo -e "如果不使用，将降级为自签名证书验证。"
    read -p "请输入选项 [y/n，默认 n]: " USE_DOMAIN

    CERT_ARGS=""
    LINK_HOST="$PUBLIC_IP"
    LINK_SNI=""
    LINK_INSECURE="&insecure=1&allowInsecure=1"

    if [[ "$USE_DOMAIN" == "y" || "$USE_DOMAIN" == "Y" ]]; then
        read -p "请输入您的域名 (请务必确保已提前解析到本机IP: $PUBLIC_IP): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}域名不能为空！${PLAIN}"
            exit 1
        fi
        
        # 申请证书
        echo -e "${YELLOW}正在通过 acme.sh 申请证书 (请确保 80 端口未被占用)...${PLAIN}"
        curl -sL https://get.acme.sh | sh -s email=admin@$DOMAIN
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        
        ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
        if [ $? -ne 0 ]; then
            echo -e "${RED}证书申请失败！请检查 80 端口是否被占用，或域名是否正确解析。${PLAIN}"
            exit 1
        fi
        
        mkdir -p $INSTALL_DIR
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file       $INSTALL_DIR/server.key  \
            --fullchain-file $INSTALL_DIR/server.crt \
            --reloadcmd      "systemctl restart anytls"
            
        CERT_ARGS="-c $INSTALL_DIR/server.crt -k $INSTALL_DIR/server.key"
        LINK_HOST="$DOMAIN"
        LINK_SNI="&sni=$DOMAIN"
        LINK_INSECURE="" # 去掉跳过证书验证的参数
    fi

    get_latest_version

    PORT=$(shuf -i 10000-65000 -n 1)
    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    echo -e "${YELLOW}正在下载 Anytls-go ${LATEST_VERSION}...${PLAIN}"
    mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST_VERSION}/anytls_${VERSION_NUM}_linux_amd64.zip"
    
    wget -N --no-check-certificate -O anytls.zip "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查服务器网络！${PLAIN}"
        rm -rf $INSTALL_DIR
        exit 1
    fi

    unzip anytls.zip
    rm -f anytls.zip
    chmod +x anytls-server

    echo -e "${YELLOW}正在配置 Systemd 服务...${PLAIN}"
    cat > $SERVICE_FILE << EOT
[Unit]
Description=AnyTLS Server Service
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p ${PASSWORD} ${CERT_ARGS}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOT

    systemctl daemon-reload
    systemctl enable anytls
    systemctl start anytls

    HOST_NAME=$(hostname)
    
    # 生成节点分享链接
    ANYTLS_LINK="anytls://${PASSWORD}@${LINK_HOST}:${PORT}?security=tls${LINK_SNI}${LINK_INSECURE}&type=tcp&headerType=none#${HOST_NAME}"

    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}✅ Anytls-go 安装成功并已设置开机自启！${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "👉 监听地址: ${YELLOW}0.0.0.0${PLAIN}"
    echo -e "👉 连接端口: ${YELLOW}${PORT}${PLAIN}"
    echo -e "👉 连接密码: ${YELLOW}${PASSWORD}${PLAIN}"
    if [[ "$USE_DOMAIN" == "y" || "$USE_DOMAIN" == "Y" ]]; then
        echo -e "👉 绑定域名: ${YELLOW}${DOMAIN}${PLAIN}"
        echo -e "👉 证书状态: ${GREEN}已配置真实证书 (启用 SNI 验证)${PLAIN}"
    fi
    echo -e "${GREEN}----------------------------------------${PLAIN}"
    echo -e "🔗 ${GREEN}节点分享链接 (可直接复制导入客户端):${PLAIN}"
    echo -e "${YELLOW}${ANYTLS_LINK}${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "服务状态检查: systemctl status anytls"
}

update_anytls() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${RED}未检测到 Anytls-go，请先安装！${PLAIN}"
        exit 1
    fi

    get_latest_version
    echo -e "${YELLOW}正在停止现有服务...${PLAIN}"
    systemctl stop anytls

    echo -e "${YELLOW}正在下载新版本...${PLAIN}"
    cd $INSTALL_DIR
    DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/${LATEST_VERSION}/anytls_${VERSION_NUM}_linux_amd64.zip"
    wget -N --no-check-certificate -O anytls.zip "$DOWNLOAD_URL"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！恢复之前的服务状态...${PLAIN}"
        systemctl start anytls
        exit 1
    fi

    rm -f anytls-server
    unzip anytls.zip
    rm -f anytls.zip
    chmod +x anytls-server

    echo -e "${YELLOW}正在启动服务...${PLAIN}"
    systemctl start anytls
    echo -e "${GREEN}✅ Anytls-go 已成功更新到最新版本 ${LATEST_VERSION}！${PLAIN}"
}

uninstall_anytls() {
    echo -e "${YELLOW}正在卸载 Anytls-go...${PLAIN}"
    pkill -f anytls-server 2>/dev/null
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop anytls
        systemctl disable anytls
        rm -f $SERVICE_FILE
        systemctl daemon-reload
    fi
    rm -rf $INSTALL_DIR
    echo -e "${GREEN}✅ Anytls-go 卸载完成！${PLAIN}"
}

# ==========================================
# Realm 中转功能模块
# ==========================================

install_realm() {
    echo -e "${GREEN}==========================================${PLAIN}"
    echo -e "${GREEN}    欢迎使用 Realm 一键中转部署脚本${PLAIN}"
    echo -e "${GREEN}==========================================${PLAIN}"

    install_dependencies

    read -p "请输入本地中转机监听端口 [默认 12345]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-12345}

    read -p "请输入落地节点 IP [默认 127.0.0.1]: " REMOTE_IP
    REMOTE_IP=${REMOTE_IP:-127.0.0.1}

    read -p "请输入落地节点端口 [默认 12345]: " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-12345}

    echo -e "\n${YELLOW}[1/4] 开始检测系统架构并下载 Realm...${PLAIN}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        REALM_URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    elif [[ "$ARCH" == "aarch64" ]]; then
        REALM_URL="https://github.com/zhboner/realm/releases/latest/download/realm-aarch64-unknown-linux-gnu.tar.gz"
    else
        echo -e "${RED}❌ 不支持的系统架构: $ARCH${PLAIN}"
        exit 1
    fi

    wget -qO realm.tar.gz "$REALM_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 下载 Realm 失败，请检查中转机网络是否能正常访问 GitHub。${PLAIN}"
        exit 1
    fi

    tar -xf realm.tar.gz
    chmod +x realm
    mv realm $REALM_BIN
    rm -f realm.tar.gz

    echo -e "${YELLOW}[2/4] 生成配置文件...${PLAIN}"
    mkdir -p $REALM_CONF_DIR
    cat <<INICFG > ${REALM_CONF_DIR}/config.toml
[network]
no_tcp_delay = true
use_v6 = false

[[endpoints]]
listen = "0.0.0.0:${LOCAL_PORT}"
remote = "${REMOTE_IP}:${REMOTE_PORT}"
INICFG

    echo -e "${YELLOW}[3/4] 配置 Systemd 守护进程...${PLAIN}"
    cat <<SVC > $REALM_SERVICE
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=${REALM_BIN} -c ${REALM_CONF_DIR}/config.toml

[Install]
WantedBy=multi-user.target
SVC

    echo -e "${YELLOW}[4/4] 启动 Realm 服务...${PLAIN}"
    systemctl daemon-reload
    systemctl enable --now realm

    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}==========================================${PLAIN}"
        echo -e "${GREEN}✅ Realm 中转服务搭建成功并已启动！${PLAIN}"
        echo -e "👉 中转机监听端口: ${YELLOW}${LOCAL_PORT}${PLAIN}"
        echo -e "👉 目标落地节点: ${YELLOW}${REMOTE_IP}:${REMOTE_PORT}${PLAIN}"
        echo -e "${GREEN}------------------------------------------${PLAIN}"
        echo -e "${YELLOW}⚠️ 最后提醒: 请务必确保当前中转机${PLAIN}"
        echo -e "${YELLOW}的系统防火墙/服务商安全组已放行 TCP 端口 ${LOCAL_PORT}${PLAIN}"
        echo -e "${GREEN}==========================================${PLAIN}"
    else
        echo -e "${RED}❌ 服务启动失败，请运行 'systemctl status realm' 查看错误日志。${PLAIN}"
    fi
}

uninstall_realm() {
    echo -e "${YELLOW}正在卸载 Realm 中转服务...${PLAIN}"
    if [ -f "$REALM_SERVICE" ]; then
        systemctl stop realm
        systemctl disable realm
        rm -f $REALM_SERVICE
        systemctl daemon-reload
    fi
    rm -rf $REALM_CONF_DIR
    rm -f $REALM_BIN
    echo -e "${GREEN}✅ Realm 中转服务卸载完成！${PLAIN}"
}

# ==========================================
# 卸载脚本与快捷命令模块
# ==========================================
uninstall_script() {
    echo -e "${YELLOW}警告：此操作将彻底删除本管理脚本及快捷命令 'anytls'。${PLAIN}"
    read -p "是否需要同时卸载已运行的 AnyTLS 和 Realm 服务？(y/n, 默认 n): " rm_srv
    if [[ "$rm_srv" == "y" || "$rm_srv" == "Y" ]]; then
        uninstall_anytls
        uninstall_realm
    fi
    
    echo -e "${YELLOW}正在清理脚本文件...${PLAIN}"
    rm -f /usr/local/bin/anytls
    
    # 获取真实执行路径并自毁
    SCRIPT_PATH=$(realpath "$0")
    rm -f "$SCRIPT_PATH"
    
    echo -e "${GREEN}✅ 脚本及快捷命令已完全卸载！您以后将无法使用 anytls 唤出面板。${PLAIN}"
    exit 0
}

# ==========================================
# 主菜单逻辑
# ==========================================
echo -e "${GREEN}Anytls-go & Realm 综合管理脚本${PLAIN}"
echo -e "=========================================="
echo -e " 1. ${GREEN}安装${PLAIN} Anytls-go 节点"
echo -e " 2. ${GREEN}更新${PLAIN} Anytls-go 节点"
echo -e " 3. ${RED}卸载${PLAIN} Anytls-go 节点"
echo -e "------------------------------------------"
echo -e " 4. ${GREEN}安装/配置${PLAIN} Realm 极简中转"
echo -e " 5. ${RED}卸载${PLAIN} Realm 中转"
echo -e "------------------------------------------"
echo -e " 6. ${RED}完全卸载${PLAIN} 本管理脚本及快捷命令"
echo -e "=========================================="
echo -e " 0. 退出脚本"
echo -e "=========================================="
read -p "请输入选项 [0-6]: " num

case "$num" in
    1) install_anytls ;;
    2) update_anytls ;;
    3)
        read -p "确定要卸载 Anytls-go 吗？(y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then uninstall_anytls; fi
        ;;
    4) install_realm ;;
    5)
        read -p "确定要卸载 Realm 中转吗？(y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then uninstall_realm; fi
        ;;
    6)
        read -p "确定要彻底删除本脚本和快捷命令吗？(y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then uninstall_script; fi
        ;;
    0) exit 0 ;;
    *) echo -e "${RED}输入错误，请重新运行脚本！${PLAIN}" ;;
esac
