#!/bin/bash


echo "Желаете установить OpenVPN?"

until [[ $CONTINUE =~ (y|n) ]]; 
    do
		read -rp "Continue? [y/n]: " -e -i y  CONTINUE
	done

if [[ $CONTINUE == "n" ]]; then
	exit 1
fi

if [[ $CONTINUE == "y" ]]; then
      # обновляем и удаляем лишнее
      sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get autoremove -y     
	sudo apt-get -y install openvpn easy-rsa;
      if [ $? -eq 0 ]; then
        echo "Successfully created file"
      else
        exit 1
      fi
fi

# создаем директорию от нашего имени
mkdir ~/easy-rsa
# Из папку установленной пакетом создаем символьную ссылку в нашу папку
ln -s /usr/share/easy-rsa/* ~/easy-rsa/

# Убеждаемся, что владелец наш пользователь non-root user с привилегиями sudo и ограничиваем доступ
sudo chown $(whoami) ~/easy-rsa
chmod 700 ~/easy-rsa


# ------------------------------------------------------------------------------------------------------------------------
# Шаг 2 — Создание PKI для OpenVPN
cd ~/easy-rsa
echo -e 'set_var EASYRSA_ALGO "ec"\nset_var EASYRSA_DIGEST "sha512"' > vars
./easyrsa init-pki

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 3 — Создание запроса сертификата и закрытого ключа сервера OpenVPN

cd ~/easy-rsa
# server - произовльное имя
./easyrsa gen-req server nopass
# вписываем имя
# В результате будет создан закрытый ключ для сервера и файл запроса сертификата с именем
sudo cp /home/$(whoami)/easy-rsa/pki/private/server.key /etc/openvpn/server/
# ------------------------------------------------------------------------------------------------------------------------
# Шаг 4 — Подпись запроса сертификата сервера OpenVPN

# По инструкции центр сертификации должен быть поднят на отдельном сервере, но мы все делаем на одном
cd ~/easy-rsa
./easyrsa import-req /home/$(whoami)/easy-rsa/pki/reqs/server.req server
sudo ./easyrsa --batch build-ca nopass
      # Вводится пароль который необходим будет на следующем шаге
sudo ./easyrsa sign-req server server
      # Вводим "yes", а затем пароль от предыдущего шага
sudo cp /home/$(whoami)/easy-rsa/pki/{ca.crt,issued/server.crt} /etc/openvpn/server #созможно надо cp

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 5 — Настройка криптографических материалов OpenVPN

# Сгенерируем дополнительный общий секретный ключ, который будет использовать сервер и все клиенты
cd ~/easy-rsa
openvpn --genkey --secret ta.key
sudo cp ta.key /etc/openvpn/server

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 6 — Создание сертификата клиента и пары ключей

mkdir -p ~/client-configs/keys
chmod -R 700 ~/client-configs
cd ~/easy-rsa
# client1 - можно задать свое
./easyrsa gen-req client1 nopass
cp pki/private/client1.key ~/client-configs/keys/
# опять в инструкции выполняется на сервере
./easyrsa import-req pki/reqs/client1.req client2
sudo ./easyrsa sign-req client client2
#  /home/mikop/easy-rsa/pki/issued/client2.crt
sudo cp pki/issued/client2.crt ~/client-configs/keys/
cp ~/easy-rsa/ta.key ~/client-configs/keys/
sudo cp /etc/openvpn/server/ca.crt ~/client-configs/keys/
sudo chown $(whoami).$(whoami) ~/client-configs/keys/*
# В результате вы сгенерировали ключи и сертификаты для сервера и клиента и сохранили их в соответствующих директориях на вашем сервере OpenVPN. 
# С этими файлами еще предстоит выполнить несколько действий, но к ним мы вернемся позднее

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 7 — Настройка OpenVPN

sudo cp /usr/share/doc/openvpn/examples/sample-config-files/server.conf.gz /etc/openvpn/server/
sudo gunzip /etc/openvpn/server/server.conf.gz
sudo sed -i "s/tls-auth ta.key 0 \# This file is secret/\;tls-auth ta.key 0 \# This file is secret\ntls-crypt ta.key/g" /etc/openvpn/server/server.conf
sudo sed -i "s/cipher AES-256-CBC/\;cipher AES-256-CBC\ncipher AES-256-GCM\nauth SHA256/g" /etc/openvpn/server/server.conf
sudo sed -i "s/dh dh2048.pem/\;dh dh2048.pem\ndh none/g" /etc/openvpn/server/server.conf
sudo sed -i "s/\;user nobody/user nobody/g" /etc/openvpn/server/server.conf
sudo sed -i "s/\;group nogroup/group nogroup/g" /etc/openvpn/server/server.conf
# для перенаправления всего трафика через VPN. Можно поменять DNS
sudo sed -i 's/\;push "redirect-gateway def1 bypass-dhcp"/push "redirect-gateway def1 bypass-dhcp"/g' /etc/openvpn/server/server.conf
sudo sed -i 's/\;push "dhcp-option DNS 208.67.222.222"/push "dhcp-option DNS 208.67.222.222"/g' /etc/openvpn/server/server.conf
sudo sed -i 's/\;push "dhcp-option DNS 208.67.220.220"/push "dhcp-option DNS 208.67.220.220"/g' /etc/openvpn/server/server.conf

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 8 — Настройка конфигурации сети сервера OpenVPN

sudo sh -c "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 9 — Настройка брандмауэра

sudo sed -i "s/\# Don't delete these required/OPENVPN config\n\n\# Don't delete these required/g" /etc/ufw/before.rules
sudo sed -i "s/OPENVPN config/\# START OPENVPN RULES\n\# NAT table rules\n\*nat\n:POSTROUTING ACCEPT [0:0]\nOPENVPN config/g" /etc/ufw/before.rules
sudo sed -i "s/OPENVPN config/# Allow traffic from OpenVPN client to "`ip route list default | awk '{print $5}'`" (change to the interface you discovered\!)\nOPENVPN config/g" /etc/ufw/before.rules
sudo sed -i "s/OPENVPN config/\-A POSTROUTING \-s 10.8.0.0\/8 \-o "`ip route list default | awk '{print $5}'`" \-j MASQUERADE\nCOMMIT\n# END OPENVPN RULES/g" /etc/ufw/before.rules
sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw
sudo ufw allow 1194/udp
sudo ufw allow OpenSSH
sudo ufw disable
sudo ufw enable

# ------------------------------------------------------------------------------------------------------------------------


sudo systemctl -f enable openvpn-server@server.service
sudo systemctl start openvpn-server@server.service
# sudo systemctl status openvpn-server@server.service
# для просмотра ошибок
# journalctl -u openvpn-server@server -e

# ------------------------------------------------------------------------------------------------------------------------
# Шаг 11 — Создание инфраструктуры конфигурации клиентских систем

mkdir -p ~/client-configs/files
cp /usr/share/doc/openvpn/examples/sample-config-files/client.conf ~/client-configs/base.conf
# Указываем наш IP адресс
# echo $(ip -br a | grep UP | awk '{print $3}' | cut -d '/' -f1)
sudo sed -i "s/remote my-server-1 1194/remote "`echo $(ip -br a | grep UP | awk '{print $3}' | cut -d '/' -f1)`" 1194/g" ~/client-configs/base.conf
sudo sed -i "s/\;user nobody/user nobody/g" ~/client-configs/base.conf
sudo sed -i "s/\;group nogroup/group nogroup/g" ~/client-configs/base.conf
sudo sed -i "s/ca ca.crt/;ca ca.crt/g" ~/client-configs/base.conf
sudo sed -i "s/cert client.crt/;cert client.crt/g" ~/client-configs/base.conf
sudo sed -i "s/key client.key/;key client.key/g" ~/client-configs/base.conf
sudo sed -i "s/tls-auth ta.key 1/;tls-auth ta.key 1/g" ~/client-configs/base.conf
sudo sed -i "s/cipher AES-256-CBC/cipher AES-256-GCM\nauth SHA256/g" ~/client-configs/base.conf
sudo echo 'key-direction 1' >> ~/client-configs/base.conf
# Для тех кто использует resolvconf 
sudo echo '; script-security 2' >> ~/client-configs/base.conf
sudo echo '; up /etc/openvpn/update-resolv-conf' >> ~/client-configs/base.conf
sudo echo '; down /etc/openvpn/update-resolv-conf' >> ~/client-configs/base.conf
# Для тех кто использует systemd-resolved
sudo echo '; script-security 2' >> ~/client-configs/base.conf
sudo echo '; up /etc/openvpn/update-systemd-resolved' >> ~/client-configs/base.conf
sudo echo '; down /etc/openvpn/update-systemd-resolved' >> ~/client-configs/base.conf
sudo echo '; down-pre' >> ~/client-configs/base.conf
sudo echo '; dhcp-option DOMAIN-ROUTE .' >> ~/client-configs/base.conf

sudo echo "#!/bin/bash

# First argument: Client identifier

KEY_DIR=~/client-configs/keys
OUTPUT_DIR=~/client-configs/files
BASE_CONFIG=~/client-configs/base.conf

cat \${BASE_CONFIG} \\
    <(echo -e '<ca>') \\
    \${KEY_DIR}/ca.crt \\
    <(echo -e '</ca>\n<cert>') \\
    \${KEY_DIR}/\${1}.crt \\
    <(echo -e '</cert>\n<key>') \\
    \${KEY_DIR}/\${2}.key \\
    <(echo -e '</key>\n<tls-crypt>') \\
    \${KEY_DIR}/ta.key \\
    <(echo -e '</tls-crypt>') \\
    > ~/client-configs/\${1}.ovpn" >> ~/client-configs/make_config.sh
sudo chmod 700 ~/client-configs/make_config.sh

# ------------------------------------------------------------------------------------------------------------------------

# Шаг 12 — Создание конфигураций клиентов
cd ~/client-configs
./make_config.sh client2 client1

sudo reboot

# Литература:
# https://www.digitalocean.com/community/tutorials/how-to-set-up-and-configure-an-openvpn-server-on-ubuntu-20-04-ru