#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/boot/firmware/config.txt"
BACKUP_FILE="/boot/firmware/config.txt.bak.lidar-uart"

echo "Configuring Raspberry Pi 4 UART for direct lidar connection..."
echo "Target file: ${CONFIG_FILE}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

cp "${CONFIG_FILE}" "${BACKUP_FILE}"
echo "Backup saved to: ${BACKUP_FILE}"

python3 - <<'PY'
from pathlib import Path

config_path = Path("/boot/firmware/config.txt")
text = config_path.read_text()

required_lines = [
    "enable_uart=1",
    "dtoverlay=disable-bt",
]

missing = [line for line in required_lines if line not in text]
if missing:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n# Direct UART lidar configuration\n"
    for line in missing:
        text += f"{line}\n"
    config_path.write_text(text)
PY

if systemctl list-unit-files | grep -q '^hciuart.service'; then
  systemctl disable hciuart.service || true
  systemctl stop hciuart.service || true
fi

echo
echo "Configuration written."
echo "Important wiring note:"
echo "  - BOARD 12 / BCM 18 : lidar motor PWM"
echo "  - BOARD 8  / BCM 14 : Raspberry Pi TX -> lidar RX"
echo "  - BOARD 10 / BCM 15 : Raspberry Pi RX <- lidar TX   (required for data)"
echo
echo "Reboot is required:"
echo "  sudo reboot"
echo
echo "After reboot, test with:"
echo "  python3 /home/pi/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/test_lidar_uart.py --motor-pwm --seconds 5"
