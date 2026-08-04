#!/bin/bash

# ==========================================
# VMESS + WS + TLS + Cloudflare 自动化部署脚本
# 适用系统: Debian 12 / Ubuntu
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}>>> 开始初始化 VMESS + WS + TLS 部署流程${NC}"

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行此脚本！${NC}"
  exit 1
fi

# 2. 交互式收集配置信息
echo -e "${YELLOW}请输入你在 Cloudflare 绑定的真实域名 (例如: sg.yourdomain.com):${NC}"
read -p "域名: " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空，退出部署。${NC}"
    exit 1
fi

echo -e "${YELLOW}请输入 WebSocket 伪装路径 (留空则自动随机生成):${NC}"
read -p "路径 (须以 / 开头，例如 /sg-ws-path): " WS_PATH
if [ -z "$WS_PATH" ]; then
    WS_PATH="/$(head -n 10 /dev/urandom | md5sum | head -c 8)"
    echo -e "已生成随机路径: ${GREEN}${WS_PATH}${NC}"
fi

# 3. 安装必要的基础组件
echo -e "${GREEN}>>> 正在更新系统源并安装 curl, nginx, uuid-runtime, base64...${NC}"
apt update -y
apt install -y curl nginx uuid-runtime base64

# 4. 配置证书
mkdir -p /etc/nginx/certs
echo -e "${YELLOW}>>> 请粘贴 Cloudflare Origin 证书 (PEM格式)，粘贴完成后在新行按【Ctrl+D】保存并继续：${NC}"
cat > /etc/nginx/certs/cf-origin.pem
echo -e "${YELLOW}>>> 请粘贴 Cloudflare Origin 私钥 (KEY格式)，粘贴完成后在新行按【Ctrl+D】保存并继续：${NC}"
cat > /etc/nginx/certs/cf-origin.key

# 5. 部署 Xray-core
echo -e "${GREEN}>>> 正在拉取并安装 Xray-core 官方稳定版...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

UUID=$(uuidgen)
echo -e "已生成 Xray 核心 UUID: ${GREEN}${UUID}${NC}"

cat > /usr/local/etc/xray/config.json << EOF
{
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

# 6. 配置 Nginx 反向代理
echo -e "${GREEN}>>> 正在配置 Nginx 反代与 TLS 卸载...${NC}"
cat > /etc/nginx/conf.d/sg-proxy.conf << EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/certs/cf-origin.pem;
    ssl_certificate_key /etc/nginx/certs/cf-origin.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://www.bing.com; 
    }

    location ${WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# 移除默认配置（防止冲突）并重启服务
rm -f /etc/nginx/sites-enabled/default
systemctl restart xray
systemctl enable xray
systemctl restart nginx
systemctl enable nginx

# 7. 生成 vmess:// 导入链接
echo -e "${GREEN}>>> 正在生成客户端导入信息...${NC}"

# 构建 VMESS JSON 结构
# add: 默认填入优选域名 icook.hk，你也可以手动在客户端改成其他测速最佳的 IP
VMESS_JSON="{\"v\":\"2\",\"ps\":\"SG-CDN节点\",\"add\":\"icook.hk\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"alpn\":\"\"}"

# Base64 编码 (使用 -w 0 禁止自动换行)
VMESS_LINK="vmess://$(echo -n ${VMESS_JSON} | base64 -w 0)"

echo -e "\n=================================================="
echo -e "${GREEN}部署完成！请复制以下信息到你的客户端：${NC}"
echo -e "=================================================="
echo -e "分享链接: \n${YELLOW}${VMESS_LINK}${NC}\n"
echo -e "如果你需要手动填写节点信息："
echo -e "  - 协议:     VMESS"
echo -e "  - 地址(IP): icook.hk (或你自己测出的其他优选IP)"
echo -e "  - 端口:     443"
echo -e "  - UUID:     ${UUID}"
echo -e "  - 传输协议: ws (WebSocket)"
echo -e "  - 伪装域名: ${DOMAIN}"
echo -e "  - Path:     ${WS_PATH}"
echo -e "  - 底层安全: tls"
echo -e "  - SNI:      ${DOMAIN}"
echo -e "=================================================="
echo -e "维护提示："
echo -e "  Xray 重启: systemctl restart xray"
echo -e "  Nginx 重启: systemctl restart nginx"
