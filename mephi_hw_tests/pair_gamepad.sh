#!/usr/bin/env bash
# =============================================================================
# Сопряжение Bluetooth-геймпада с роботом. Нужно один раз: ключ сохраняется,
# устройство становится доверенным. Дальше пульт подключает служба
# mephi-gamepad-keeper (setup_gamepad_keeper.sh): после перезагрузки робота
# Flydigi сам его не вызывал.
#
#   bash pair_gamepad.sh [секунд_ожидания] [MAC]
#
# Пульт в режим сопряжения (у Flydigi Apex 5 / Xbox — зажать кнопку сопряжения,
# пока индикатор не замигает часто). Без MAC берётся геймпад, который ещё НЕ
# сопряжён: старые пульты остаются в списке, и «первый попавшийся» был бы чужим.
#
# Если пульт подключается, работает пару секунд и отваливается — у робота нет
# его ключа, а пульт помнит робота со старой попытки. Лечится этим же скриптом.
# =============================================================================
WAIT="${1:-300}"
TARGET="${2:-}"
NAME_RE="${NAME_RE:-xbox|flydigi|apex|gamepad|controller}"
LOG="${LOG:-/tmp/pair_gamepad.log}"
FOUND=/tmp/pair_gamepad.mac
rm -f "$FOUND"; : > "$LOG"

find_mac() {
  local m
  if [ -n "$TARGET" ]; then
    bluetoothctl devices 2>/dev/null | grep -qi "$TARGET" && echo "$TARGET"
    return
  fi
  for m in $(bluetoothctl devices 2>/dev/null | grep -iE "$NAME_RE" | awk '{print $2}'); do
    bluetoothctl info "$m" 2>/dev/null | grep -q "Paired: no" && { echo "$m"; return; }
  done
}
count() { grep -c "$1" "$LOG" 2>/dev/null; }

echo "Жду геймпад в режиме сопряжения до $WAIT с..."
{
  echo "power on"
  echo "agent NoInputNoOutput"
  echo "default-agent"
  echo "pairable on"
  echo "discoverable on"      # некоторые пульты сами инициируют сопряжение
  echo "scan on"
  MAC=""
  for _ in $(seq 1 "$WAIT"); do
    sleep 1
    MAC="$(find_mac)"
    [ -n "$MAC" ] && break
  done
  if [ -z "$MAC" ]; then echo "scan off"; echo "discoverable off"; echo "quit"; exit 0; fi
  echo "Найден $MAC — сопрягаю" >&2
  echo "$MAC" > "$FOUND"
  echo "scan off"
  sleep 1
  # Первая попытка часто срывается (Bluetooth делит чип с Wi-Fi) — до 4 попыток.
  for attempt in 1 2 3 4; do
    ok0=$(count "Pairing successful"); fail0=$(count "Failed to pair")
    echo "pair $MAC"
    for _ in $(seq 1 20); do
      sleep 1
      [ "$(count 'Pairing successful')" -gt "$ok0" ] && break 2
      [ "$(count 'Failed to pair')" -gt "$fail0" ] && break
    done
    echo "  попытка $attempt не удалась" >&2
    sleep 2
  done
  echo "trust $MAC";   sleep 2
  echo "connect $MAC"; sleep 8
  echo "discoverable off"
  echo "quit"
} | bluetoothctl > "$LOG" 2>&1

MAC="$(cat "$FOUND" 2>/dev/null)"
if [ -z "$MAC" ]; then
  echo "Геймпад не найден за $WAIT с. Индикатор должен мигать часто — запустите ещё раз."
  exit 1
fi
echo "Устройство: $MAC"
grep -qi "Pairing successful" "$LOG" && echo "Сопряжение: успешно" || echo "Сопряжение: НЕ удалось (подробности: $LOG)"
bluetoothctl info "$MAC" | grep -E "Name|Paired|Trusted|Connected"
sleep 2
ls -l /dev/input/js* 2>/dev/null || echo "/dev/input/js* пока нет"
