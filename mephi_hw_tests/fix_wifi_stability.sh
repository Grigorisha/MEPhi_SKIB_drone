#!/usr/bin/env bash
# =============================================================================
# Стабильный Wi-Fi робота. Запускается один раз, с паролем:
#
#   ssh -t Vindicator2 'sudo bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/fix_wifi_stability.sh'
#
# 1. Выключает энергосбережение Wi-Fi (было wifi.powersave = 3): на встроенном
#    Wi-Fi Raspberry Pi оно даёт залипания связи, особенно вместе с Bluetooth.
# 2. Ставит терпеливого сторожа wifi-reconnect (старый сохраняется как .bak).
# 3. Переподключает Wi-Fi, чтобы настройка применилась сразу: SSH оборвётся
#    секунд на 10 — так и должно быть.
# =============================================================================
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo"; exit 1; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. Энергосбережение Wi-Fi: выключить ==="
# Файл сортируется после default-wifi-powersave-on.conf и перекрывает его.
cat > /etc/NetworkManager/conf.d/mephi-wifi-powersave-off.conf <<'CONF'
# Энергосбережение Wi-Fi выключено: на Raspberry Pi оно даёт залипания связи.
# Ставится mephi_hw_tests/fix_wifi_stability.sh.
[connection]
wifi.powersave = 2
CONF
echo "  /etc/NetworkManager/conf.d/mephi-wifi-powersave-off.conf: wifi.powersave = 2"

echo "=== 2. Терпеливый сторож Wi-Fi ==="
cp -n /usr/local/bin/wifi-reconnect.sh /usr/local/bin/wifi-reconnect.sh.bak
install -m 0755 "$DIR/wifi-reconnect.sh" /usr/local/bin/wifi-reconnect.sh
systemctl restart wifi-reconnect && echo "  сторож перезапущен (прежний: /usr/local/bin/wifi-reconnect.sh.bak)"

echo "=== 3. Применение ==="
systemctl reload NetworkManager
echo "  Через 3 с Wi-Fi переподключится, SSH оборвётся секунд на 10 — это нормально."
nohup bash -c 'sleep 3; nmcli connection up "$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: "\$2==\"wlan0\" {print \$1; exit}")"' >/dev/null 2>&1 &
