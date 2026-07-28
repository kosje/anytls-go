#!/bin/bash

# ==========================================
# AnyTLS + Caddy ACME + Realm 管理脚本
# ==========================================


RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"


INSTALL_DIR="/root/anytls"
SERVICE_FILE="/etc/systemd/system/anytls.service"

CADDY_FILE="/etc/caddy/Caddyfile"

REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_SERVICE="/etc/systemd/system/realm.service"


if [ "$EUID" -ne 0 ];then
    echo "请使用root运行"
    exit 1
fi


install_dep(){

    apt update -y

    apt install -y \
    curl wget unzip tar ca-certificates debian-keyring debian-archive-keyring apt-transport-https

}



install_caddy(){

echo -e "${YELLOW}安装Caddy...${PLAIN}"

apt install -y curl debian-keyring debian-archive-keyring apt-transport-https

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg


curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
| tee /etc/apt/sources.list.d/caddy-stable.list


apt update -y

apt install -y caddy


}



install_anytls(){


install_dep


read -p "请输入你的域名，例如 node.example.com: " DOMAIN


if [ -z "$DOMAIN" ];then

echo "域名不能为空"

exit 1

fi



echo -e "${YELLOW}下载 AnyTLS...${PLAIN}"


mkdir -p $INSTALL_DIR

cd $INSTALL_DIR



VERSION=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest \
| grep tag_name \
| cut -d '"' -f4)



wget -O anytls.zip \
https://github.com/anytls/anytls-go/releases/download/${VERSION}/anytls_${VERSION#v}_linux_amd64.zip



unzip -o anytls.zip

rm -f anytls.zip


chmod +x anytls-server



PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)



echo -e "${YELLOW}生成AnyTLS服务${PLAIN}"


cat > $SERVICE_FILE <<EOF

[Unit]
Description=AnyTLS Server
After=network.target


[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR

ExecStart=$INSTALL_DIR/anytls-server \
-l 127.0.0.1:8443 \
-p $PASSWORD


Restart=always
RestartSec=3


[Install]
WantedBy=multi-user.target

EOF



systemctl daemon-reload

systemctl enable --now anytls



install_caddy



echo -e "${YELLOW}配置Caddy TLS反代${PLAIN}"


cat > $CADDY_FILE <<EOF

{
    email admin@$DOMAIN
}


$DOMAIN {

    reverse_proxy 127.0.0.1:8443

}

EOF



systemctl restart caddy



sleep 5



LINK="anytls://${PASSWORD}@${DOMAIN}:443?security=tls&sni=${DOMAIN}&type=tcp&headerType=none#AnyTLS"



echo

echo -e "${GREEN}==============================${PLAIN}"

echo -e "${GREEN}安装完成${PLAIN}"

echo

echo "域名:"
echo "$DOMAIN"

echo

echo "密码:"
echo "$PASSWORD"

echo

echo "节点:"
echo

echo "$LINK"


echo

echo -e "${GREEN}==============================${PLAIN}"



}



update_anytls(){


if [ ! -d "$INSTALL_DIR" ];then

echo "未安装"

exit

fi


systemctl stop anytls


cd $INSTALL_DIR


VERSION=$(curl -s https://api.github.com/repos/anytls/anytls-go/releases/latest \
| grep tag_name \
| cut -d '"' -f4)


wget -O anytls.zip \
https://github.com/anytls/anytls-go/releases/download/${VERSION}/anytls_${VERSION#v}_linux_amd64.zip


unzip -o anytls.zip

rm anytls.zip


chmod +x anytls-server


systemctl start anytls


echo "更新完成"

}



uninstall_anytls(){

systemctl stop anytls

systemctl disable anytls

rm -f $SERVICE_FILE

rm -rf $INSTALL_DIR


echo "AnyTLS已卸载"

}




install_realm(){


apt install -y wget tar


read -p "监听端口:" LP
LP=${LP:-12345}


read -p "目标IP:" RIP
RIP=${RIP:-127.0.0.1}


read -p "目标端口:" RP
RP=${RP:-12345}



wget -qO realm.tar.gz \
https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz


tar xf realm.tar.gz

chmod +x realm

mv realm $REALM_BIN


mkdir -p $REALM_DIR


cat > $REALM_DIR/config.toml <<EOF

[[endpoints]]

listen="0.0.0.0:$LP"

remote="$RIP:$RP"

EOF



cat > $REALM_SERVICE <<EOF

[Unit]
Description=realm


[Service]

ExecStart=$REALM_BIN -c $REALM_DIR/config.toml

Restart=always


[Install]

WantedBy=multi-user.target

EOF



systemctl daemon-reload

systemctl enable --now realm


echo "Realm完成"


}



menu(){

echo

echo "======================"

echo " AnyTLS + Realm"

echo "======================"

echo "1.安装AnyTLS"

echo "2.更新AnyTLS"

echo "3.卸载AnyTLS"

echo "4.安装Realm"

echo "0.退出"


read -p "选择:" NUM


case $NUM in

1)
install_anytls
;;

2)
update_anytls
;;

3)
uninstall_anytls
;;

4)
install_realm
;;

0)
exit
;;

*)
echo "错误"

;;

esac


}


menu
