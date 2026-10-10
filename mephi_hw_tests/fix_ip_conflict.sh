#!/usr/bin/env bash
# =============================================================================
# Робот в сети 18KPU — на адрес по DHCP вместо статического 10.1.18.175.
#
#   ssh -t Vindicator2 'sudo bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/fix_ip_conflict.sh'
#
# Почему. 10.1.18.175 лежит внутри DHCP-диапазона роутера, и роутер выдал его
# ещё и другому устройству (MAC c2:39:39:6b:94:48, судя по трафику — телефон).
# Два устройства с одним адресом: роутер и ноутбук то и дело шлют пакеты
# робота телефону. Отсюда «робот периодически пропадает из сети» — SSH и Remmina
# рвутся, сторож Wi-Fi не может допинговать шлюз, хотя Wi-Fi подключён.
# Улики 10.10.2026: ufw робота отбрасывал ответы, которых робот не запрашивал
# (DNS 85.143.112.2/3, HTTPS Huawei и Google — трафик того телефона), а пока
# робот перезагружался, на 10.1.18.175 отвечало чужое устройство.
#
# После запуска адрес робота поменяется. На ноутбуке: make find — найдёт робота
# по MAC и обновит ssh, Remmina и rviz. Постоянный адрес без конфликтов даёт
# резервирование на роутере: MAC Wi-Fi робота d8:3a:dd:cb:41:f8.
# =============================================================================
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo"; exit 1; }
CON="${1:-18KPU}"
F="/etc/NetworkManager/system-connections/$CON.nmconnection"
[ -f "$F" ] || { echo "Нет соединения $CON ($F)"; exit 1; }

cp -n "$F" "/root/$CON.nmconnection.before-dhcp"
# Адрес и шлюз очищаются явно: при method=auto NetworkManager добавил бы
# статический адрес к выданному по DHCP, и конфликт остался бы.
nmcli connection modify "$CON" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
echo "$CON: $(nmcli -g ipv4.method connection show "$CON") (бэкап: /root/$CON.nmconnection.before-dhcp)"
echo "Через 3 с Wi-Fi переподключится с новым адресом, SSH оборвётся — это нормально."
echo "Дальше на ноутбуке: make find"
nohup bash -c "sleep 3; nmcli connection up '$CON'" >/dev/null 2>&1 &
