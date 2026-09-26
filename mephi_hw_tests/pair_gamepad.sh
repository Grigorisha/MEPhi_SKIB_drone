#!/usr/bin/env bash
# =============================================================================
# Сопряжение Xbox-геймпада с роботом. Нужно один раз: устройство помечается
# доверенным (trust), и дальше пульт подключается сам при каждом включении.
#
#   bash pair_gamepad.sh [секунд_ожидания]
#
# Пульт в режим сопряжения: включить кнопкой Xbox, затем зажать маленькую
# кнопку сопряжения на торце пульта, пока логотип не замигает часто.
# =============================================================================
WAIT="${1:-300}"
LOG="${LOG:-/tmp/pair_gamepad.log}"

find_mac() { bluetoothctl devices 2>/dev/null | grep -i "xbox" | awk '{print $2}' | head -1; }

echo "Жду Xbox-геймпад в режиме сопряжения до $WAIT с..."
{
  echo "power on"
  echo "agent NoInputNoOutput"
  echo "default-agent"
  echo "pairable on"
  echo "scan on"
  MAC=""
  for _ in $(seq 1 "$WAIT"); do
    sleep 1
    MAC="$(find_mac)"
    [ -n "$MAC" ] && break
  done
  if [ -z "$MAC" ]; then
    echo "scan off"; echo "quit"
    exit 0
  fi
  echo "Найден $MAC — сопрягаю" >&2
  echo "scan off"
  sleep 1
  echo "pair $MAC";    sleep 10
  echo "trust $MAC";   sleep 2
  echo "connect $MAC"; sleep 8
  echo "quit"
} | bluetoothctl > "$LOG" 2>&1

MAC="$(find_mac)"
if [ -z "$MAC" ]; then
  echo "Геймпад не найден за $WAIT с. Логотип должен мигать часто — запустите ещё раз."
  exit 1
fi
echo "Устройство: $MAC"
bluetoothctl info "$MAC" | grep -E "Name|Paired|Trusted|Connected"
ls -l /dev/input/js* 2>/dev/null || echo "/dev/input/js* пока нет"
