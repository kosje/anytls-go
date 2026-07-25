#!/bin/bash

# 颜色设置
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

INSTALL_DIR="/root/anytls"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# 检查是否为root用户
if [ $EUID -ne 0 ]; then
    echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在检查并安装必要的依赖 (curl, wget, unzip)...${PLAIN}"
    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y curl wget unzip
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget unzip
    else
        echo -e "${RED}不支持的包管理器，请手动安装 curl, wget, unzip！${PLAIN}"
    fi
}

# 获取最新版本号
get_latest_version() {
    LATEST_VERSION=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}获取最新版本失败，请检查网络！${PLAIN}"
        exit 1
    fi
    VERSION_NUM=${LATEST_VERSION#v}
    echo -e "${GREEN}检测到 Anytls-go 最新版本为: ${LATEST_VERSION}${PLAIN}"
}

# 安装 Anytls-go
install_anytls() {
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}Anytls-go 似乎已经安装。如果需要覆盖安装，请先卸载。${PLAIN}"
        exit 1
    fi

    install_dependencies
    get_latest_version

    # 生成 10000 到 65000 之间的随机端口
    PORT=$(shuf -i 10000-65000 -n 1)
    
    # 生成 20位随机密码 (包含大小写字母和数字)
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
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p ${PASSWORD}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOT

    systemctl daemon-reload
    systemctl enable anytls
    systemctl start anytls

    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "${GREEN}Anytls-go 安装成功并已设置开机自启！${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "监听地址: ${YELLOW}0.0.0.0${PLAIN}"
    echo -e "连接端口: ${YELLOW}${PORT}${PLAIN}"
    echo -e "连接密码: ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "${GREEN}========================================${PLAIN}"
    echo -e "服务状态检查: systemctl status anytls"
}

# 更新 Anytls-go
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
    echo -e "${GREEN}Anytls-go 已成功更新到最新版本 ${LATEST_VERSION}！${PLAIN}"
}

# 卸载 Anytls-go
uninstall_anytls() {
    echo -e "${YELLOW}正在卸载 Anytls-go...${PLAIN}"
    
    # 结束进程
    pkill -f anytls-server 2>/dev/null

    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop anytls
        systemctl disable anytls
        rm -f $SERVICE_FILE
        systemctl daemon-reload
    fi

    rm -rf $INSTALL_DIR
    echo -e "${GREEN}Anytls-go 卸载完成！${PLAIN}"
}

# 菜单
echo -e "${GREEN}Anytls-go 一键管理脚本${PLAIN}"
echo -e "1. ${GREEN}安装${PLAIN} Anytls-go"
echo -e "2. ${GREEN}更新${PLAIN} Anytls-go (保留原端口和密码)"
echo -e "3. ${RED}卸载${PLAIN} Anytls-go"
echo -e "0. 退出脚本"
read -p "请输入选项 [0-3]: " num

case "$num" in
    1)
        install_anytls
        ;;
    2)
        update_anytls
        ;;
    3)
        read -p "确定要卸载 Anytls-go 吗？(y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            uninstall_anytls
        else
            echo -e "${YELLOW}已取消卸载。${PLAIN}"
        fi
        ;;
    0)
        exit 0
        ;;
    *)
        echo -e "${RED}输入错误，请重新运行脚本！${PLAIN}"
        ;;
esac
