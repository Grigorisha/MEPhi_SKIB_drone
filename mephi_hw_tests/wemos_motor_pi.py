#!/usr/bin/env python3
"""Raspberry Pi 4B adaptation of WEMOS_Motor_Shield_Arduino_Library."""

from __future__ import annotations

import fcntl
import os
import time
from typing import Iterable

try:  # pragma: no cover - optional backend
    from smbus2 import SMBus
except ImportError:  # pragma: no cover
    try:
        from smbus import SMBus
    except ImportError:
        SMBus = None

try:  # pragma: no cover - optional standby support
    import RPi.GPIO as GPIO
except ImportError:  # pragma: no cover
    GPIO = None


_MOTOR_A = 0
_MOTOR_B = 1

_SHORT_BRAKE = 0
_CCW = 1
_CW = 2
_STOP = 3
_STANDBY = 4

DEFAULT_I2C_ADDRESS = 0x30
SUPPORTED_ADDRESSES = (0x2D, 0x2E, 0x2F, 0x30)
I2C_SLAVE = 0x0703


class LinuxI2CBus:
    """Fallback I2C backend using /dev/i2c-* directly."""

    def __init__(self, bus_number: int) -> None:
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

    def _select_address(self, address: int) -> None:
        fcntl.ioctl(self._fd, I2C_SLAVE, address)

    def write_byte(self, address: int, value: int) -> None:
        self._select_address(address)
        os.write(self._fd, bytes([value & 0xFF]))

    def write_i2c_block_data(self, address: int, command: int, values: list[int]) -> None:
        self._select_address(address)
        payload = bytes([command & 0xFF] + [value & 0xFF for value in values])
        os.write(self._fd, payload)

    def close(self) -> None:
        os.close(self._fd)


class _I2CBusAdapter:
    def __init__(self, bus: int) -> None:
        # The original Arduino library uses Wire.beginTransmission() +
        # Wire.write(...) and sends a plain I2C byte stream with no SMBus
        # block-length prefix. Many Linux SMBus helpers add SMBus framing,
        # which breaks this motor shield even when the address is correct.
        # Prefer the raw /dev/i2c-* backend so the bytes on the wire match
        # the working Arduino example exactly.
        self._bus = LinuxI2CBus(bus)
        self.backend = "linux-i2c"

    def write_byte(self, address: int, value: int) -> None:
        self._bus.write_byte(address, value)

    def write_i2c_block_data(self, address: int, command: int, values: list[int]) -> None:
        self._bus.write_i2c_block_data(address, command, values)

    def close(self) -> None:
        self._bus.close()


class Motor:
    """Arduino-like Motor API adapted for Raspberry Pi."""

    LOLIN_CHANGE_STATUS = 0x04
    LOLIN_CHANGE_FREQ = 0x05
    LOLIN_CHANGE_DUTY = 0x06

    LOLIN_STOP = 0x00
    LOLIN_CCW = 0x01
    LOLIN_CW = 0x02
    LOLIN_SHORT_BRAKE = 0x03
    LOLIN_STANDBY = 0x04

    def __init__(
        self,
        address: int,
        motor: int,
        freq: int,
        stby_pin: int | None = None,
        *,
        bus: int = 1,
        protocol: str = "legacy",
        gpio_mode: str = "board",
    ) -> None:
        self._address = address
        self._motor = _MOTOR_A if motor == _MOTOR_A else _MOTOR_B
        self._protocol = protocol
        self._bus = _I2CBusAdapter(bus)
        self._use_stby_io = stby_pin is not None
        self._stby_pin = stby_pin

        if self._use_stby_io:
            if GPIO is None:
                raise RuntimeError("RPi.GPIO is required when stby_pin is used.")
            GPIO.setwarnings(False)
            GPIO.setmode(GPIO.BOARD if gpio_mode == "board" else GPIO.BCM)
            GPIO.setup(self._stby_pin, GPIO.OUT, initial=GPIO.LOW)

        self.setfreq(freq)

    @property
    def backend(self) -> str:
        return self._bus.backend

    def _write(self, command: int, values: list[int]) -> None:
        try:
            self._bus.write_i2c_block_data(self._address, command, values)
        except Exception as exc:
            raise RuntimeError(
                f"Motor shield at I2C address 0x{self._address:02X} did not respond. "
                "Check power, GND, SDA/SCL wiring, I2C enable, and address jumpers."
            ) from exc
        time.sleep(0.05)

    def _legacy_setfreq(self, freq: int) -> None:
        payload = [
            ((freq >> 16) & 0x0F),
            ((freq >> 16) & 0xFF),
            ((freq >> 8) & 0xFF),
            (freq & 0xFF),
        ]
        self._write(payload[0], payload[1:])

    def _lolin_setfreq(self, freq: int) -> None:
        self._write(
            self.LOLIN_CHANGE_FREQ,
            [self._motor, freq & 0xFF, (freq >> 8) & 0xFF, (freq >> 16) & 0xFF],
        )

    def setfreq(self, freq: int) -> None:
        freq = max(1, min(80000, int(freq)))
        if self._protocol == "legacy":
            self._legacy_setfreq(freq)
        elif self._protocol == "lolin":
            self._lolin_setfreq(freq)
        else:
            raise ValueError("protocol must be 'legacy' or 'lolin'")

    def _legacy_setmotor(self, direction: int, pwm_val: float) -> None:
        pwm_scaled = min(10000, max(0, int(float(pwm_val) * 100)))
        self._write(
            self._motor | 0x10,
            [int(direction) & 0xFF, (pwm_scaled >> 8) & 0xFF, pwm_scaled & 0xFF],
        )

    def _lolin_status(self, direction: int) -> int:
        return {
            _SHORT_BRAKE: self.LOLIN_SHORT_BRAKE,
            _CCW: self.LOLIN_CCW,
            _CW: self.LOLIN_CW,
            _STOP: self.LOLIN_STOP,
            _STANDBY: self.LOLIN_STANDBY,
        }[direction]

    def _lolin_setmotor(self, direction: int, pwm_val: float) -> None:
        pwm_scaled = min(10000, max(0, int(float(pwm_val) * 100)))
        self._write(self.LOLIN_CHANGE_STATUS, [self._motor, self._lolin_status(direction)])
        self._write(
            self.LOLIN_CHANGE_DUTY,
            [self._motor, pwm_scaled & 0xFF, (pwm_scaled >> 8) & 0xFF],
        )

    def setmotor(self, direction: int, pwm_val: float = 100.0) -> None:
        if self._use_stby_io:
            if direction == _STANDBY:
                GPIO.output(self._stby_pin, GPIO.LOW)
                return
            GPIO.output(self._stby_pin, GPIO.HIGH)

        if self._protocol == "legacy":
            self._legacy_setmotor(direction, pwm_val)
        elif self._protocol == "lolin":
            self._lolin_setmotor(direction, pwm_val)
        else:
            raise ValueError("protocol must be 'legacy' or 'lolin'")

    def close(self) -> None:
        self._bus.close()

    def __enter__(self) -> "Motor":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


def scan_addresses(bus: int = 1, addresses: Iterable[int] = SUPPORTED_ADDRESSES) -> list[int]:
    found: list[int] = []
    adapter = _I2CBusAdapter(bus)
    try:
        for address in addresses:
            try:
                adapter.write_byte(address, 0x00)
                found.append(address)
            except Exception:
                continue
    finally:
        adapter.close()
    return found
