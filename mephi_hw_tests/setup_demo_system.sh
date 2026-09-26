#!/usr/bin/env bash
# =============================================================================
# Системная подготовка Vindicator2 к демонстрации. Запускается один раз, с паролем:
#
#   ssh -t Vindicator2 'sudo bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/setup_demo_system.sh'
#
# Повторный запуск безопасен: каждый шаг проверяет, не сделан ли он уже.
# В конце — перезагрузка: Bluetooth и группа input включаются только так.
#
#   0. Отключает фоновые автообновления Ubuntu на время демонстраций.
#   1. avrdude (прошивка Arduino по USB), joystick и evtest (проверка геймпада).
#   2. pi может запускать/останавливать mephi-bringup без пароля — прошивке нужно
#      освободить порт Arduino, а после правок стек надо перезапускать.
#   3. mephi-bringup стартует после синхронизации часов и останавливается за 15 с.
#   4. Bluetooth: снимается dtoverlay=disable-bt — остаток от лидара на внутреннем
#      UART. Лидар давно на USB, UART никто не использует.
#   5. disable_ertm=1 — без этого старые прошивки Xbox-геймпадов не спариваются.
#   6. pi в группе input — иначе сервис робота не прочитает геймпад.
# =============================================================================
set -o pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Нужен root. Запустите так:"
  echo "  sudo bash $0"
  exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="${SUDO_USER:-pi}"
RESULTS=()
ok()   { RESULTS+=("  [OK]      $1"); echo "  [OK] $1"; }
fail() { RESULTS+=("  [ОШИБКА]  $1"); echo "  [ОШИБКА] $1"; }

echo
echo "=== 0. Демо-режим: без фоновых автообновлений Ubuntu ==="
# Пропустив плановый запуск, unattended-upgrade стартует сразу после включения
# и 15+ минут считает зависимости на процессоре Pi, держа блокировку dpkg, —
# так было 26.09.2026. На демонстрации это конкуренция с ROS за процессор.
# Вернуть после сезона выставок:
#   sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
if systemctl disable --now -q apt-daily.timer apt-daily-upgrade.timer; then
  ok "автообновления отключены (apt-daily, apt-daily-upgrade)"
else
  fail "не удалось отключить таймеры автообновления"
fi

echo
echo "=== 1. Пакеты ==="
# Индекс apt не обновляем: все три пакета в нём уже есть, а apt update умеет
# молча висеть на недоступном репозитории Gazebo. Ожидание блокировки dpkg
# ограничено — если её держит автообновление, будет видно сообщение apt.
install_pkgs() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=120 avrdude joystick evtest
}
if install_pkgs; then
  ok "установлены avrdude, joystick, evtest"
else
  echo "  из текущего индекса не вышло — обновляю его (с таймаутами) и пробую ещё раз"
  apt-get update -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=0 || true
  if install_pkgs; then ok "установлены avrdude, joystick, evtest"; else fail "не удалось установить пакеты"; fi
fi

echo
echo "=== 2. Сервис робота без пароля ==="
SRC="$REPO/sudoers.d/mephi-services"
# Битый файл в sudoers.d может отключить sudo целиком — поэтому сначала проверка.
if visudo -cf "$SRC" >/dev/null; then
  install -m 0440 -o root -g root "$SRC" /etc/sudoers.d/mephi-services \
    && ok "sudoers: pi может start/stop/restart mephi-bringup" \
    || fail "sudoers: не удалось установить"
else
  fail "sudoers: файл не прошёл проверку visudo — НЕ установлен"
fi

echo
echo "=== 3. Запуск после синхронизации часов ==="
if install -D -m 0644 "$REPO/systemd/mephi-bringup.service.d/demo.conf" \
       /etc/systemd/system/mephi-bringup.service.d/demo.conf \
   && install -D -m 0644 "$REPO/systemd/systemd-time-wait-sync.service.d/timeout.conf" \
       /etc/systemd/system/systemd-time-wait-sync.service.d/timeout.conf \
   && systemctl daemon-reload \
   && systemctl enable -q systemd-time-wait-sync.service; then
  ok "systemd: ждать часы (до 30 с), останавливаться за 15 с"
else
  fail "systemd: drop-in не установлен"
fi

echo
echo "=== 4. Bluetooth ==="
CFG=/boot/firmware/config.txt
if grep -qE '^dtoverlay=disable-bt\s*$' "$CFG"; then
  cp -n "$CFG" "$CFG.bak-before-bt"
  sed -i -E 's|^dtoverlay=disable-bt\s*$|# dtoverlay=disable-bt  # снято 26.09.2026: лидар на USB, Bluetooth нужен для геймпада|' "$CFG"
  if grep -qE '^dtoverlay=disable-bt' "$CFG"; then
    fail "config.txt: строка осталась"
  else
    ok "config.txt: disable-bt снят (бэкап: $CFG.bak-before-bt)"
  fi
else
  ok "config.txt: disable-bt уже снят"
fi
systemctl enable -q hciuart.service 2>/dev/null && ok "hciuart включён" || fail "hciuart не включился"

echo
echo "=== 5. ERTM ==="
echo "options bluetooth disable_ertm=1" > /etc/modprobe.d/xbox-bluetooth.conf \
  && ok "bluetooth disable_ertm=1" || fail "disable_ertm"

echo
echo "=== 6. Доступ к геймпаду ==="
usermod -aG input "$USER_NAME" && ok "$USER_NAME в группе input" || fail "группа input"

echo
echo "=================== ИТОГ ==================="
printf '%s\n' "${RESULTS[@]}"
echo
echo "Перезагрузка через 15 секунд — нужна для Bluetooth и группы input."
echo "Ctrl+C — отменить (тогда перезагрузите позже сами: sudo reboot)."
sleep 15
systemctl reboot
