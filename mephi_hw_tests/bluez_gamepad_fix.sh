#!/usr/bin/env bash
# =============================================================================
# Настройки BlueZ для сторонних геймпадов и клонов Xbox (Flydigi и т. п.).
# Рецепт из руководства xpadneo:
#   https://github.com/atar-axis/xpadneo/blob/master/docs/TROUBLESHOOTING.md
#
#   ssh -t Vindicator2 'sudo bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/bluez_gamepad_fix.sh'
#
# UserspaceHID=true        классический HID через uhid, а не ядерный hidp — у нас
#                          hidp отвечал «Operation already in progress» и рвал связь
# ClassicBondedOnly=false  пускать HID-устройства, сопряжённые без сохранения ключа
# LEAutoSecurity=false     то же для BLE-клонов
# JustWorksRepairing=always  разрешить пульту, который помнит робота, сопрячься
#                          заново — иначе AuthenticationFailed
# Безопасность чуть ниже (к роботу проще подключить устройство ввода) —
# для демонстрационного робота приемлемо. Повторный запуск безопасен.
# =============================================================================
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo"; exit 1; }
IN=/etc/bluetooth/input.conf
MAIN=/etc/bluetooth/main.conf
cp -n "$IN" "$IN.bak-before-gamepad"; cp -n "$MAIN" "$MAIN.bak-before-gamepad"

set_input() {   # в input.conf одна секция [General] — дописываем в конец
  sed -i "/^$1\s*=/d" "$IN"
  echo "$1=$2" >> "$IN"
}
set_input UserspaceHID true
set_input ClassicBondedOnly false
set_input LEAutoSecurity false

# в main.conf несколько секций — вставляем строго под [General]
sed -i "/^JustWorksRepairing\s*=/d" "$MAIN"
sed -i "/^\[General\]/a JustWorksRepairing = always" "$MAIN"

echo "input.conf:"; grep -E "^(UserspaceHID|ClassicBondedOnly|LEAutoSecurity)" "$IN" | sed 's/^/  /'
echo "main.conf [General]:"; grep -E "^JustWorksRepairing" "$MAIN" | sed 's/^/  /'
systemctl restart bluetooth && echo "bluetooth перезапущен"
echo "Бэкапы: $IN.bak-before-gamepad, $MAIN.bak-before-gamepad"
