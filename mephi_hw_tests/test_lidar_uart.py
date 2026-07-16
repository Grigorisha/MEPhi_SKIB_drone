#!/usr/bin/env python3
"""Standalone direct-UART lidar probe for Raspberry Pi 4B.

This script is intended for a direct Raspberry Pi GPIO connection, not for the
USB adapter flow used by `rplidar_ros`.

Pin map relevant to the user's current wiring:
- BOARD 12 -> BCM 18 : PWM / motor control for lidar
- BOARD 8  -> BCM 14 : UART TX from Raspberry Pi to lidar RX

Important hardware note:
- Receiving scan data requires Raspberry Pi RXD0 as well:
  BOARD 10 -> BCM 15 -> lidar TX
- With only BOARD 8 connected, Raspberry Pi can transmit commands but cannot
  receive measurements back from the lidar.
"""

from __future__ import annotations

import argparse
import binascii
import os
import signal
import sys
import termios
import time
from dataclasses import dataclass

try:
    import RPi.GPIO as GPIO
except ImportError:  # pragma: no cover - depends on target hardware
    GPIO = None


@dataclass(frozen=True)
class PinSpec:
    name: str
    board: int
    bcm: int


LIDAR_PWM_PIN = PinSpec("lidar_pwm", board=12, bcm=18)
PI_UART_TX_PIN = PinSpec("pi_uart_tx", board=8, bcm=14)
PI_UART_RX_PIN = PinSpec("pi_uart_rx", board=10, bcm=15)

RPLIDAR_CMD_STOP = bytes.fromhex("A5 25")
RPLIDAR_CMD_GET_HEALTH = bytes.fromhex("A5 52")
RPLIDAR_CMD_SCAN = bytes.fromhex("A5 20")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Direct Raspberry Pi GPIO test for UART lidar data."
    )
    parser.add_argument(
        "--device",
        default="/dev/ttyAMA0",
        help="Serial device to probe. Default: /dev/ttyAMA0",
    )
    parser.add_argument(
        "--baud",
        type=int,
        default=115200,
        help="UART baud rate. Default: 115200",
    )
    parser.add_argument(
        "--seconds",
        type=float,
        default=5.0,
        help="Read window after sending commands. Default: 5.0 s",
    )
    parser.add_argument(
        "--motor-pwm",
        action="store_true",
        help="Drive BOARD 12 / BCM 18 with PWM during the probe.",
    )
    parser.add_argument(
        "--motor-duty",
        type=float,
        default=60.0,
        help="PWM duty cycle percent for the lidar motor. Default: 60",
    )
    parser.add_argument(
        "--motor-hz",
        type=int,
        default=1000,
        help="PWM frequency in Hz for BOARD 12. Default: 1000",
    )
    parser.add_argument(
        "--skip-scan-command",
        action="store_true",
        help="Only listen on UART without sending RPLIDAR commands.",
    )
    return parser


def baud_constant(baud: int) -> int:
    mapping = {
        9600: termios.B9600,
        19200: termios.B19200,
        38400: termios.B38400,
        57600: termios.B57600,
        115200: termios.B115200,
        230400: termios.B230400,
    }
    if baud not in mapping:
        raise ValueError(f"Unsupported baud rate for this probe: {baud}")
    return mapping[baud]


def open_serial(path: str, baud: int) -> int:
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    speed = baud_constant(baud)
    attrs[4] = speed
    attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def write_command(fd: int, payload: bytes, label: str) -> None:
    os.write(fd, payload)
    print(f"Sent {label}: {payload.hex(' ')}")


def read_bytes(fd: int, seconds: float) -> bytes:
    deadline = time.monotonic() + seconds
    data = bytearray()
    while time.monotonic() < deadline:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            data.extend(chunk)
        else:
            time.sleep(0.02)
    return bytes(data)


def print_header(args: argparse.Namespace) -> None:
    print("=" * 72)
    print("MEPhI direct lidar UART probe")
    print("=" * 72)
    print("Current direct pin usage:")
    print(f"  Motor PWM : BOARD {LIDAR_PWM_PIN.board} -> BCM {LIDAR_PWM_PIN.bcm}")
    print(f"  Pi UART TX: BOARD {PI_UART_TX_PIN.board} -> BCM {PI_UART_TX_PIN.bcm}")
    print(f"  Pi UART RX: BOARD {PI_UART_RX_PIN.board} -> BCM {PI_UART_RX_PIN.bcm} (required for data)")
    print()
    print(f"Serial device : {args.device}")
    print(f"Baud rate     : {args.baud}")
    print(f"Read window   : {args.seconds:.1f} s")
    print(f"Motor PWM     : {'enabled' if args.motor_pwm else 'disabled'}")
    print()
    print("Warnings:")
    print("  - With only BOARD 8 wired, scan data cannot come back into Raspberry Pi.")
    print("  - For direct UART, connect lidar TX to BOARD 10 / BCM 15.")
    print("  - UART boot configuration on Raspberry Pi must be enabled.")
    print("=" * 72)


def summarize_data(data: bytes) -> None:
    print()
    print(f"bytes_read={len(data)}")
    if not data:
        print("No bytes were received.")
        print("Most likely causes:")
        print("  1. Lidar TX is not connected to BOARD 10 / BCM 15.")
        print("  2. UART is not enabled in /boot/firmware/config.txt.")
        print("  3. Lidar motor is not spinning.")
        print("  4. Wrong voltage levels, GND, or baud rate.")
        return

    sample = data[:64]
    print(f"hex_sample={binascii.hexlify(sample, sep=b' ').decode()}")
    ascii_sample = "".join(chr(b) if 32 <= b < 127 else "." for b in sample)
    print(f"ascii_sample={ascii_sample}")

    if b"\xA5\x5A" in data:
        print("Detected RPLIDAR response descriptor header 0xA5 0x5A.")
    else:
        print("RPLIDAR descriptor header 0xA5 0x5A was not found in the captured bytes.")


def main() -> int:
    args = build_arg_parser().parse_args()
    print_header(args)

    stop_requested = {"value": False}

    def _request_stop(_sig: int, _frame: object) -> None:
        stop_requested["value"] = True
        print("\nStop requested, shutting down safely...")

    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)

    if args.motor_pwm and GPIO is None:
        raise SystemExit(
            "RPi.GPIO is not installed, so PWM mode is unavailable.\n"
            "Install it on Raspberry Pi with:\n"
            "  sudo apt update\n"
            "  sudo apt install python3-rpi.gpio"
        )

    if GPIO is not None:
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BOARD)
    pwm = None
    fd = None

    try:
        if args.motor_pwm:
            GPIO.setup(LIDAR_PWM_PIN.board, GPIO.OUT, initial=GPIO.LOW)
            pwm = GPIO.PWM(LIDAR_PWM_PIN.board, args.motor_hz)
            pwm.start(max(0.0, min(100.0, args.motor_duty)))
            time.sleep(0.8)

        fd = open_serial(args.device, args.baud)

        if not args.skip_scan_command:
            write_command(fd, RPLIDAR_CMD_STOP, "STOP")
            time.sleep(0.05)
            write_command(fd, RPLIDAR_CMD_GET_HEALTH, "GET_HEALTH")
            time.sleep(0.05)
            write_command(fd, RPLIDAR_CMD_SCAN, "SCAN")

        data = read_bytes(fd, args.seconds)
        summarize_data(data)
        return 0 if data else 2
    finally:
        if fd is not None:
            os.close(fd)
        if pwm is not None:
            pwm.ChangeDutyCycle(0)
            pwm.stop()
        if GPIO is not None:
            GPIO.cleanup()
            print("GPIO cleanup complete.")


if __name__ == "__main__":
    sys.exit(main())
