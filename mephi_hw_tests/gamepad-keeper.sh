#!/usr/bin/env bash
# =============================================================================
# Хранитель Bluetooth-геймпада (служба mephi-gamepad-keeper).
# Ставится setup_gamepad_keeper.sh.
#
# Зачем. BlueZ сам возвращает HID-пульт только 3 минуты после обрыва (6 попыток
# раз в 30 с, profiles/input/device.c) и ни разу после загрузки: ждёт, что пульт
# вызовет робота сам. Flydigi Apex 5 в режиме ПК (выдаёт себя за Xbox One S)
# на это полагаться не даёт: после трёх перезагрузок 10.10.2026 он сам не
# подключился ни разу, а по вызову с робота (bluetoothctl/blueman) подключался.
#
# Что делает. Каждые 3 с проверяет все доверенные HID-устройства робота:
#   - устройство ввода есть (Uniq=MAC в /proc/bus/input/devices) — всё хорошо;
#   - радиоканал есть, а устройства ввода нет дольше 15 с — рвёт полуживую связь;
#   - пульта нет — вызывает его сам: первые 2 минуты каждые 5 с, дальше каждые
#     10 с, пока не появится (вызов выключенного пульта занимает радио ~5 с);
#   - чип трижды подряд отвечает «Operation already in progress» (HCI 0x0B:
#     прошивка считает связь живой, а ядро её не видит) — сбрасывает адаптер.
# Пока идёт поиск устройств (сопряжение, blueman) — не вмешивается.
#
# Wi-Fi вызовы не мешают: замер 10.10.2026 на 5 ГГц — 0 потерь пинга до шлюза
# за 20 с непрерывных вызовов.
# =============================================================================
POLL=3
HALF_OPEN_S=15
ADAPTER=/org/bluez/hci0

log() { logger -t gamepad-keeper -- "$*"; }
now() { date +%s; }
prop() { busctl get-property org.bluez "$1" "$2" "$3" 2>/dev/null; }   # -> "b true"
dev_path() { echo "$ADAPTER/dev_${1//:/_}"; }

# Доверенные HID-устройства (UUID 0x1124) из хранилища BlueZ.
gamepads() {
  local addr d
  addr=$(prop $ADAPTER org.bluez.Adapter1 Address | awk -F'"' '{print $2}')
  [ -n "$addr" ] || return
  for d in /var/lib/bluetooth/"$addr"/??:??:??:??:??:??; do
    [ -f "$d/info" ] || continue
    grep -q '^Trusted=true' "$d/info" && grep -q '00001124-' "$d/info" && basename "$d"
  done
}

hid_up() { grep -qi "^U: Uniq=$1\$" /proc/bus/input/devices; }

reset_adapter() {
  btmgmt --index 0 power off >/dev/null 2>&1
  sleep 2
  btmgmt --index 0 power on >/dev/null 2>&1
  sleep 3
}

declare -A STATE LAST_TRY TRIES HALF EALREADY
last_restart=0
log "запущен"

while true; do
  sleep "$POLL"

  # Адаптер на месте и включён?
  if ! powered=$(prop $ADAPTER org.bluez.Adapter1 Powered); then
    if [ $(( $(now) - last_restart )) -gt 300 ] && [ ! -e /sys/class/bluetooth/hci0 ]; then
      log "адаптера hci0 нет — перезапускаю hciuart и bluetooth"
      systemctl restart hciuart bluetooth
      last_restart=$(now)
    fi
    continue
  fi
  if [ "$powered" = "b false" ]; then
    log "адаптер выключен — включаю"
    busctl set-property org.bluez $ADAPTER org.bluez.Adapter1 Powered b true 2>/dev/null
    continue
  fi
  # Идёт поиск устройств — кто-то сопрягает пульт, не мешаем.
  [ "$(prop $ADAPTER org.bluez.Adapter1 Discovering)" = "b true" ] && continue

  for mac in $(gamepads); do
    p=$(dev_path "$mac")
    t=$(now)

    if hid_up "$mac"; then
      [ "${STATE[$mac]}" != up ] && log "пульт $mac на связи"
      STATE[$mac]=up; TRIES[$mac]=0; HALF[$mac]=0; EALREADY[$mac]=0
      continue
    fi
    if [ "${STATE[$mac]}" = up ]; then
      log "пульт $mac пропал — вызываю"
      STATE[$mac]=down; LAST_TRY[$mac]=0
    fi

    # Радиоканал есть, а устройства ввода нет: дать 15 с на установку, потом рвать.
    if [ "$(prop "$p" org.bluez.Device1 Connected)" = "b true" ]; then
      [ "${HALF[$mac]:-0}" -eq 0 ] && HALF[$mac]=$t
      if [ $(( t - HALF[$mac] )) -ge $HALF_OPEN_S ]; then
        log "пульт $mac: радиоканал без устройства ввода ${HALF_OPEN_S} с — разрываю"
        busctl --timeout=10 call org.bluez "$p" org.bluez.Device1 Disconnect >/dev/null 2>&1
        HALF[$mac]=0; LAST_TRY[$mac]=$t
      fi
      continue
    fi
    HALF[$mac]=0

    tries=${TRIES[$mac]:-0}
    gap=5; [ "$tries" -ge 24 ] && gap=10
    [ $(( t - ${LAST_TRY[$mac]:-0} )) -lt $gap ] && continue

    out=$(busctl --timeout=25 call org.bluez "$p" org.bluez.Device1 Connect 2>&1)
    rc=$?
    LAST_TRY[$mac]=$(now); TRIES[$mac]=$(( tries + 1 ))
    if [ $rc -eq 0 ]; then
      log "пульт $mac откликнулся на вызов"
      EALREADY[$mac]=0
    elif echo "$out" | grep -qi "already in progress"; then
      EALREADY[$mac]=$(( ${EALREADY[$mac]:-0} + 1 ))
      if [ "${EALREADY[$mac]}" -ge 3 ]; then
        log "пульт $mac: чип трижды ответил «соединение уже есть», а его нет — сбрасываю адаптер"
        reset_adapter
        EALREADY[$mac]=0
      fi
    else
      EALREADY[$mac]=0
      [ "$tries" -eq 0 ] && log "пульт $mac не отвечает (${out#Call failed: }) — выключен? Вызываю дальше"
    fi
  done
done
