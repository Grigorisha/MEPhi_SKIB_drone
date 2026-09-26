#!/usr/bin/env bash
# =============================================================================
# Прошивка Arduino робота по USB — без разборки.
#
#   bash flash_arduino.sh путь/к/firmware.hex
#
# 1. Останавливает mephi-bringup: пока он работает, порт мотора занят.
# 2. Вычитывает ТЕКУЩУЮ прошивку в ~/MEPhi_SKIB_drone/firmware_backups/.
# 3. Пишет новую; avrdude сам сверяет записанное.
# 4. Запускает mephi-bringup обратно — в том числе если что-то упало.
#
# Откат на прошлую прошивку — тем же скриптом:
#   bash flash_arduino.sh ~/MEPhi_SKIB_drone/firmware_backups/arduino-ДАТА.hex
#
# Нужны: avrdude (apt) и правило sudoers mephi-services — оба ставит
# setup_demo_system.sh. Без правила sudo просто спросит пароль.
# =============================================================================
set -eo pipefail

HEX="${1:-}"
PORT="${PORT:-/dev/ttyUSB_MOTOR}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/MEPhi_SKIB_drone/firmware_backups}"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

[ -n "$HEX" ] || die "укажите hex-файл: bash $0 firmware.hex"
[ -f "$HEX" ] || die "нет файла $HEX"
command -v avrdude >/dev/null || die "нет avrdude — запустите setup_demo_system.sh или: sudo apt install avrdude"
[ -e "$PORT" ] || die "нет порта $PORT — Arduino не подключена?"

mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/arduino-$(date +%Y%m%d-%H%M%S).hex"

# Что бы ни случилось дальше — вернуть робота в строй.
restart_bringup() {
  echo
  echo ">>> Запускаю mephi-bringup обратно"
  sudo systemctl start mephi-bringup && echo "    запущен" || echo "    НЕ ЗАПУСТИЛСЯ — проверьте: systemctl status mephi-bringup"
}
trap restart_bringup EXIT

echo ">>> Останавливаю mephi-bringup (он держит порт Arduino)"
sudo systemctl stop mephi-bringup

for _ in $(seq 1 30); do
  fuser "$PORT" >/dev/null 2>&1 || break
  sleep 0.5
done
fuser "$PORT" >/dev/null 2>&1 && die "порт $PORT всё ещё кем-то занят: $(fuser -v "$PORT" 2>&1 | tail -n +2)"

# Между сессиями avrdude нужна пауза: без неё следующая сессия ловит не
# загрузчик, а уже запустившуюся прошивку и падает с «protocol error, expect=0x14»
# (проверено 26.09.2026: подряд — ошибка, с паузой 2 с — три успеха из трёх).
avr() {
  local attempt
  for attempt in 1 2 3; do
    sleep 2
    if avrdude -q -q -p atmega328p -c arduino -P "$PORT" -b "$BAUD" "$@"; then
      return 0
    fi
    echo "    попытка $attempt не удалась"
  done
  return 1
}

# UNO-клоны бывают с загрузчиком на 115200 (optiboot) и на 57600 (старый).
BAUD=""
for b in 115200 57600; do
  sleep 2
  if avrdude -q -q -p atmega328p -c arduino -P "$PORT" -b "$b" -n >/dev/null 2>&1; then
    BAUD="$b"; break
  fi
done
[ -n "$BAUD" ] || die "загрузчик Arduino не отвечает ни на 115200, ни на 57600"
echo ">>> Загрузчик отвечает на $BAUD бод"

echo ">>> Бэкап текущей прошивки: $BACKUP"
avr -U "flash:r:$BACKUP:i" || die "бэкап не удался — прошивать не буду"
[ -s "$BACKUP" ] || die "бэкап пустой — прошивать не буду"

echo ">>> Пишу $HEX (с проверкой)"
avr -D -U "flash:w:$HEX:i" \
  || die "запись не удалась. Загрузчик от этого не портится — повторите скрипт или откатите бэкап: bash $0 $BACKUP"

echo
echo "Готово. Прошито:  $HEX"
echo "        Бэкап:    $BACKUP"
echo "Откат:  bash $0 $BACKUP"
