#!/bin/bash
# =============================================================================
# Наблюдатель за RPLIDAR.
#
# Проблема: USB-контакт лидара периодически "дребезжит" (подтверждено на
# практике — после долгой работы без переподключения /scan замолкает без
# единой ошибки в логе, хотя сама нода rplidar_composition остаётся жива).
# Лечится программным "передёргиванием" USB (usbreset), эквивалентным
# физическому выдёргиванию кабеля — так это чинилось руками при диагностике.
#
# Что делает скрипт:
#   - запускает rplidar_composition отдельно от общего bringup;
#   - раз в CHECK_INTERVAL секунд проверяет, публикуется ли /scan;
#   - если данных нет — пишет об этом в лог, программно ресетит USB-порт
#     лидара и перезапускает ноду;
#   - как только данные снова пошли — просто молчит, нода продолжает висеть.
#
# Требует root (usbreset нужны права). Запускать:
#   sudo bash mephi_hw_tests/lidar_watchdog.sh
#
# Основной bringup (мотор/описание робота) поднимать отдельно, без лидара:
#   make bringup INCLUDE_RPLIDAR=False
# =============================================================================

RPLIDAR_PORT="${RPLIDAR_PORT:-/dev/ttyUSB_LIDAR}"
RPLIDAR_BAUD="${RPLIDAR_BAUD:-115200}"
FRAME_ID="${FRAME_ID:-rplidar_laser_link}"
USB_ID="${USB_ID:-10c4:ea60}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
STALL_WINDOW="${STALL_WINDOW:-6}"
LOG_FILE="${LOG_FILE:-/tmp/lidar_watchdog.log}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROS_SETUP="/opt/ros/humble/setup.bash"
WS_SETUP="$REPO_ROOT/install/setup.bash"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

if [ "$EUID" -ne 0 ]; then
  echo "Нужен root (для usbreset). Запусти: sudo bash $0"
  exit 1
fi

# shellcheck disable=SC1090
source "$ROS_SETUP"
if [ -f "$WS_SETUP" ]; then
  # shellcheck disable=SC1090
  source "$WS_SETUP"
fi

RPLIDAR_PID=""

start_rplidar() {
  ros2 run rplidar_ros rplidar_composition --ros-args \
    -p serial_port:="$RPLIDAR_PORT" -p serial_baudrate:="$RPLIDAR_BAUD" \
    -p frame_id:="$FRAME_ID" -p angle_compensate:=true -p scan_mode:=Sensitivity \
    >> "$LOG_FILE" 2>&1 &
  RPLIDAR_PID=$!
  log "rplidar_composition запущен (pid=$RPLIDAR_PID)"
}

stop_rplidar() {
  if [ -n "$RPLIDAR_PID" ] && kill -0 "$RPLIDAR_PID" 2>/dev/null; then
    kill -9 "$RPLIDAR_PID" 2>/dev/null
    wait "$RPLIDAR_PID" 2>/dev/null
  fi
  pkill -9 -f rplidar_composition 2>/dev/null
  RPLIDAR_PID=""
}

is_scan_alive() {
  timeout "$STALL_WINDOW" ros2 topic hz /scan --window 3 2>/dev/null | grep -q "average rate"
}

recover() {
  log "ДАННЫХ НЕТ: /scan не публикуется. Программно переподключаю USB ($USB_ID) и перезапускаю ноду..."
  stop_rplidar
  usbreset "$USB_ID" >> "$LOG_FILE" 2>&1
  sleep 3
  start_rplidar
  sleep 5
  if is_scan_alive; then
    log "Восстановлено, /scan снова публикуется."
  else
    log "После переподключения данных всё ещё нет — похоже на физическую проблему (кабель/разъём), само не починится."
  fi
}

cleanup() {
  log "Остановка watchdog."
  stop_rplidar
  exit 0
}
trap cleanup INT TERM

log "Watchdog лидара запущен. Порт=$RPLIDAR_PORT USB_ID=$USB_ID, проверка каждые ${CHECK_INTERVAL}с"
start_rplidar
sleep 5

while true; do
  sleep "$CHECK_INTERVAL"
  if kill -0 "$RPLIDAR_PID" 2>/dev/null; then
    if ! is_scan_alive; then
      recover
    fi
  else
    log "Процесс ноды лидара умер — перезапускаю."
    recover
  fi
done
