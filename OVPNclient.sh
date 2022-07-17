#!/bin/bash

read -rp "Enter client name [e.g. mikop]: " -e -i mikop name
cd ~/easy-rsa
./easyrsa gen-req ${name}2 nopass
cp pki/private/${name}2.key ~/client-configs/keys/
./easyrsa import-req pki/reqs/${name}2.req ${name}
sudo ./easyrsa sign-req client ${name}
sudo cp pki/issued/${name}.crt ~/client-configs/keys/
cp ~/easy-rsa/ta.key ~/client-configs/keys/
sudo cp /etc/openvpn/server/ca.crt ~/client-configs/keys/
sudo chown $(whoami).$(whoami) ~/client-configs/keys/*
cd ~/client-configs
./make_config.sh ${name} ${name}2
mv ~/client-configs/${name}.ovpn ~