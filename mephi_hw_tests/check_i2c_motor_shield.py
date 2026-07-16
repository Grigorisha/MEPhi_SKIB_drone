#!/usr/bin/env python3
"""Check whether an I2C device is visible on Raspberry Pi pins 3/5.

Target wiring from `hardware_test_plan.md`:
- BOARD 3 -> BCM 2 -> SDA1
- BOARD 5 -> BCM 3 -> SCL1

This script does not require smbus/smbus2. It uses `/dev/i2c-1` directly.
"""

from __future__ import annotations

import argparse
import fcntl
import os
import sys


I2C_SLAVE = 0x0703
DEFAULT_BUS = 1
STANDARD_SHIELD_ADDRESSES = (0x2D, 0x2E, 0x2F, 0x30)


class LinuxI2CBus:
    def __init__(self, bus_number: int) -> None:
        self.bus_number = bus_number
        self.device_path = f"/dev/i2c-{bus_number}"
        try:
            self._fd = os.open(self.device_path, os.O_RDWR)
        except FileNotFoundError as exc:
            raise RuntimeError(
                f"{self.device_path} not found. Enable I2C on Raspberry Pi first."
            ) from exc
        except PermissionError as exc:
            raise RuntimeError(
                f"Permission denied opening {self.device_path}. "
                "Add your user to the i2c group or run with appropriate permissions."
            ) from exc

    def probe(self, address: int) -> bool:
        try:
            fcntl.ioctl(self._fd, I2C_SLAVE, address)
            os.write(self._fd, b"\x00")
            return True
        except OSError:
            return False

    def close(self) -> None:
        os.close(self._fd)


def parse_int_auto(value: str) -> int:
    return int(value, 0)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Check whether an I2C motor shield is visible on Raspberry Pi bus 1."
    )
    parser.add_argument(
        "--bus",
        type=int,
        default=DEFAULT_BUS,
        help="Linux I2C bus number. Default: 1.",
    )
    parser.add_argument(
        "--address",
        type=parse_int_auto,
        default=None,
        help="Check only one specific address, for example 0x30.",
    )
    parser.add_argument(
        "--full-scan",
        action="store_true",
        help="Scan the full 7-bit I2C range instead of only standard motor shield addresses.",
    )
    return parser


def print_header(bus_number: int) -> None:
    print("=" * 72)
    print("Raspberry Pi I2C visibility check")
    print("=" * 72)
    print("Expected pins:")
    print("  BOARD 3 -> BCM 2 -> SDA1")
    print("  BOARD 5 -> BCM 3 -> SCL1")
    print(f"Linux I2C bus: /dev/i2c-{bus_number}")
    print("=" * 72)


def format_addresses(addresses: list[int]) -> str:
    if not addresses:
        return "none"
    return ", ".join(f"0x{address:02X}" for address in addresses)


def main() -> int:
    args = build_arg_parser().parse_args()
    print_header(args.bus)

    try:
        bus = LinuxI2CBus(args.bus)
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        return 1

    try:
        if args.address is not None:
            visible = bus.probe(args.address)
            if visible:
                print(f"Device ACK received at address 0x{args.address:02X}")
                return 0
            print(f"No response at address 0x{args.address:02X}")
            return 2

        addresses = list(range(0x03, 0x78)) if args.full_scan else list(STANDARD_SHIELD_ADDRESSES)
        found = [address for address in addresses if bus.probe(address)]

        if args.full_scan:
            print(f"Devices visible on bus {args.bus}: {format_addresses(found)}")
        else:
            print(f"Standard motor shield addresses visible: {format_addresses(found)}")

        if not found:
            print()
            print("No device responded on the tested I2C addresses.")
            print("Check:")
            print("  - I2C is enabled on Raspberry Pi")
            print("  - SDA and SCL are not swapped")
            print("  - shield logic power is present")
            print("  - common GND exists between shield and Raspberry Pi")
            print("  - AD0/AD1 jumpers select the expected address")
            return 2

        print()
        print("I2C device detected. You can now test the motor script with one of these addresses.")
        return 0
    finally:
        bus.close()


if __name__ == "__main__":
    sys.exit(main())
