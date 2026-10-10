#!/usr/bin/env bash
# =============================================================================
# Удалённый рабочий стол робота по RDP (xrdp + XFCE) — для Remmina.
#
#   ssh -t Vindicator2 'sudo bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/setup_remote_desktop.sh'
#
# Монитора у робота нет, и он грузится без графики (gdm3 не запущен), так что
# «существующего экрана» нет. xrdp поднимает отдельный рабочий стол на каждое
# подключение. XFCE вместо GNOME: GNOME под xrdp на Pi рисуется программно,
# тормозит и отнимает процессор у ROS. Повторный запуск безопасен.
# =============================================================================
set -o pipefail
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo: sudo bash $0"; exit 1; }
USER_NAME="${SUDO_USER:-pi}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
PKGS="xrdp xorgxrdp xfce4 xfce4-terminal dbus-x11"

echo
echo "=== 1. Пакеты: xrdp и XFCE (без рекомендованных — чтобы не прилетел дисплей-менеджер) ==="
install_pkgs() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    -o DPkg::Lock::Timeout=120 $PKGS
}
if ! install_pkgs; then
  echo "  из текущего индекса не вышло — обновляю его (с таймаутами) и пробую ещё раз"
  apt-get update -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 -o Acquire::Retries=0 || true
  install_pkgs || { echo "ОШИБКА: пакеты не установились"; exit 1; }
fi

echo
echo "=== 2. Сертификат xrdp ==="
adduser xrdp ssl-cert >/dev/null && echo "  xrdp в группе ssl-cert"

echo
echo "=== 3. Сессия RDP запускает XFCE ==="
echo "startxfce4" > "$HOME_DIR/.xsession"
chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.xsession"
echo "  $HOME_DIR/.xsession -> startxfce4"

echo
echo "=== 4. Без всплывающих запросов пароля colord в удалённой сессии ==="
install -d /etc/polkit-1/localauthority/50-local.d
cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow colord for remote sessions]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
echo "  правило polkit установлено"

echo
echo "=== 5. Файрвол: RDP (3389/tcp) из домашних и рабочих подсетей ==="
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  ufw allow from "$net" to any port 3389 proto tcp comment "RDP xrdp" >/dev/null && echo "  открыт 3389 для $net"
done

echo
echo "=== 6. Запуск xrdp ==="
systemctl enable -q xrdp
systemctl restart xrdp
sleep 1
if ss -tln | grep -q ":3389 "; then
  echo "  xrdp слушает порт 3389"
else
  echo "  ОШИБКА: xrdp не слушает 3389 — см. journalctl -u xrdp"; exit 1
fi

echo
echo "Готово. В Remmina: протокол RDP, сервер $(hostname -I | awk '{print $1}'), пользователь $USER_NAME."
echo "На ноутбуке с проектом: make desktop"
