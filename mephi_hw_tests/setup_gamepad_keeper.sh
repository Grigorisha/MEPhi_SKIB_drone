#!/usr/bin/env bash
# =============================================================================
# Автоподключение Bluetooth-геймпада: ставит службу mephi-gamepad-keeper.
#
#   ssh -t Vindicator2 'sudo bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/setup_gamepad_keeper.sh'
#
# Служба вызывает доверенный пульт, когда его нет на связи: после загрузки,
# после разрядки, выключения или ухода из зоны. Пульт должен быть один раз
# сопряжён (pair_gamepad.sh). Подробности — в шапке gamepad-keeper.sh.
# Повторный запуск безопасен.
# =============================================================================
[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo"; exit 1; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$DIR")"

install -m 0755 "$DIR/gamepad-keeper.sh" /usr/local/bin/gamepad-keeper.sh
install -m 0644 "$REPO/systemd/mephi-gamepad-keeper.service" /etc/systemd/system/mephi-gamepad-keeper.service
systemctl daemon-reload
systemctl enable -q mephi-gamepad-keeper
systemctl restart mephi-gamepad-keeper
sleep 1
echo "служба: $(systemctl is-active mephi-gamepad-keeper), автозапуск: $(systemctl is-enabled mephi-gamepad-keeper)"
echo "журнал: journalctl -t gamepad-keeper -f"
