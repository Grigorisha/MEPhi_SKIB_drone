#!/usr/bin/env bash
# =============================================================================
# Сторож Wi-Fi робота (служба wifi-reconnect). Ставится fix_wifi_stability.sh.
#
# Прежняя версия рвала Wi-Fi после первой же неудачной проверки шлюза. На Pi 4
# Wi-Fi и Bluetooth делят один чип, и короткие паузы в связи случаются — сторож
# превращал паузу в разрыв всех SSH-сессий и Remmina (10.10.2026 так «падал»
# робот дважды за час, хотя Wi-Fi каждый раз возвращался за 9 секунд).
#
# Теперь: проверка раз в 30 с, переподключение только после 4 неудач подряд
# (~2 минуты без связи со шлюзом), и мягкое — через nmcli connection up.
# =============================================================================
INTERFACE="wlan0"
CHECK_INTERVAL=30
FAILS_TO_ACT=4
fails=0

gateway() { ip route | awk -v i="$INTERFACE" '$1=="default" && $0 ~ "dev "i {print $3; exit}'; }
active_con() { nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v i="$INTERFACE" '$2==i {print $1; exit}'; }

while true; do
  sleep "$CHECK_INTERVAL"
  gw="$(gateway)"
  if [ -n "$gw" ] && ping -c 3 -W 3 "$gw" >/dev/null 2>&1; then
    [ "$fails" -gt 0 ] && logger -t wifi-reconnect "Связь со шлюзом $gw восстановилась сама (после $fails неудач)"
    fails=0
    continue
  fi
  fails=$((fails + 1))
  logger -t wifi-reconnect "Шлюз ${gw:-нет маршрута} не отвечает ($fails из $FAILS_TO_ACT)"
  [ "$fails" -lt "$FAILS_TO_ACT" ] && continue

  con="$(active_con)"
  if [ -n "$con" ]; then
    logger -t wifi-reconnect "Переподключаю Wi-Fi: nmcli connection up '$con'"
    nmcli connection up "$con" >/dev/null 2>&1 || true
  else
    logger -t wifi-reconnect "Wi-Fi не подключён — прошу NetworkManager подключиться"
    nmcli device wifi rescan >/dev/null 2>&1 || true
    sleep 5
    nmcli device connect "$INTERFACE" >/dev/null 2>&1 || true
  fi
  fails=0
  sleep 20
done
