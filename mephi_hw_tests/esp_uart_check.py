#!/usr/bin/env python3
"""Quick UART health-check for ESP motor controller."""

import argparse
import sys
import time

import serial


def read_line_with_deadline(ser: serial.Serial, timeout_s: float = 1.0) -> str:
    deadline = time.monotonic() + timeout_s
    buf = bytearray()
    while time.monotonic() < deadline:
        waiting = ser.in_waiting
        if waiting:
            chunk = ser.read(waiting)
            buf.extend(chunk)
            if b"\n" in buf:
                line = bytes(buf).split(b"\n", 1)[0]
                return line.decode(errors="replace").strip()
        else:
            time.sleep(0.02)

    if buf:
        # Return partial payload so diagnostics still show what device emits.
        return bytes(buf).decode(errors="replace").strip()
    return ""


def send_cmd(ser: serial.Serial, cmd: str) -> str:
    ser.reset_input_buffer()
    ser.write((cmd + "\r").encode())
    ser.flush()
    line = read_line_with_deadline(ser, timeout_s=1.2)
    print(f">>> {cmd}")
    print(f"<<< {line if line else '<timeout>'}")
    return line


def is_int(value: str) -> bool:
    return value.lstrip("-").isdigit()


def is_encoder_reply(line: str) -> bool:
    parts = line.split()
    return len(parts) == 2 and is_int(parts[0]) and is_int(parts[1])


def main() -> int:
    parser = argparse.ArgumentParser(description="Check UART replies from ESP motor controller.")
    parser.add_argument("--port", required=True, help="Serial port path (e.g. /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=57600, help="UART baudrate")
    args = parser.parse_args()

    print(f"[ESP] open {args.port} @ {args.baud}")
    try:
        ser = serial.Serial(port=args.port, baudrate=args.baud, timeout=0.1, write_timeout=1)
    except serial.SerialException as exc:
        print(f"[ESP] FAIL: cannot open serial port: {exc}")
        return 2

    ok = True
    replies = {}
    try:
        # Opening port may reset ESP; allow it to boot.
        time.sleep(2.0)
        for cmd in ("help", "status", "e", "m 0 0", "r"):
            reply = send_cmd(ser, cmd)
            replies[cmd] = reply
            if not reply:
                ok = False
    finally:
        ser.close()

    # Strict protocol checks for ROS2 integration.
    if replies.get("m 0 0", "") != "OK":
        ok = False
    if replies.get("r", "") != "OK":
        ok = False
    if not is_encoder_reply(replies.get("e", "")):
        ok = False

    if not ok:
        print("[ESP] FAIL: UART replies are not protocol-compatible for ROS2")
        return 3

    print("[ESP] OK: UART replies are protocol-compatible")
    return 0


if __name__ == "__main__":
    sys.exit(main())
