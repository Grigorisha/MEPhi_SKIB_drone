#!/usr/bin/env python3
"""Simple motor rotation test for D1 mini TB6612FNG on Raspberry Pi."""

from __future__ import annotations

import argparse
import signal
import sys
import time

from wemos_motor_pi import (
    DEFAULT_I2C_ADDRESS,
    SUPPORTED_ADDRESSES,
    Motor,
    _CCW,
    _CW,
    _MOTOR_A,
    _MOTOR_B,
    _STOP,
    scan_addresses,
)


def parse_int_auto(value: str) -> int:
    return int(value, 0)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Motor rotation test for WEMOS/D1 mini TB6612FNG on Raspberry Pi."
    )
    parser.add_argument("--i2c-address", type=parse_int_auto, default=DEFAULT_I2C_ADDRESS)
    parser.add_argument("--i2c-bus", type=int, default=1)
    parser.add_argument("--protocol", choices=("legacy", "lolin"), default="legacy")
    parser.add_argument("--speed", type=float, default=30.0)
    parser.add_argument("--duration", type=float, default=2.0)
    parser.add_argument("--step", type=float, default=5.0)
    parser.add_argument("--step-delay", type=float, default=0.1)
    parser.add_argument("--mode", choices=("both", "motor-a", "motor-b"), default="both")
    parser.add_argument("--direction", choices=("cw", "ccw"), default="cw")
    parser.add_argument("--skip-reverse", action="store_true")
    parser.add_argument("--scan", action="store_true")
    return parser


def print_header(args: argparse.Namespace) -> None:
    print("=" * 72)
    print("WEMOS TB6612FNG motor rotation test")
    print("=" * 72)
    print("Raspberry Pi wiring:")
    print("  SDA  : BOARD 3 -> BCM 2")
    print("  SCL  : BOARD 5 -> BCM 3")
    print("  VCC  : BOARD 1 -> 3.3V")
    print("  GND  : common ground with motor shield")
    print()
    print("Test settings:")
    print(f"  i2c_bus={args.i2c_bus}  i2c_address=0x{args.i2c_address:02X}  protocol={args.protocol}")
    print(f"  mode={args.mode}  direction={args.direction}  speed={args.speed}%  duration={args.duration}s")
    print("=" * 72)


def ramp_motor(motor: Motor, direction: int, target_speed: float, step: float, step_delay: float) -> None:
    current = 0.0
    while current < target_speed:
        current = min(current + max(0.1, step), target_speed)
        motor.setmotor(direction, current)
        time.sleep(step_delay)


def ramp_stop(motor: Motor, direction: int, current_speed: float, step: float, step_delay: float) -> None:
    current = max(0.0, current_speed)
    while current > 0:
        current = max(0.0, current - max(0.1, step))
        if current == 0:
            motor.setmotor(_STOP)
        else:
            motor.setmotor(direction, current)
        time.sleep(step_delay)
    motor.setmotor(_STOP)


def run_phase(
    name: str,
    motors: list[Motor],
    direction: int,
    speed: float,
    duration: float,
    step: float,
    step_delay: float,
    stop_requested: dict[str, bool],
) -> None:
    print(f"Phase: {name}")
    for motor in motors:
        ramp_motor(motor, direction, speed, step, step_delay)
    end_time = time.monotonic() + duration
    while time.monotonic() < end_time and not stop_requested["value"]:
        time.sleep(0.1)
    for motor in motors:
        ramp_stop(motor, direction, speed, step, step_delay)
    print(f"Phase complete: {name}")


def stop_all(motors: list[Motor]) -> None:
    for motor in motors:
        try:
            motor.setmotor(_STOP)
        except Exception:
            pass


def main() -> int:
    args = build_arg_parser().parse_args()
    stop_requested = {"value": False}

    def _request_stop(_sig: int, _frame: object) -> None:
        stop_requested["value"] = True
        print("\nStop requested, stopping motors...")

    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)

    print_header(args)

    if args.scan:
        found = scan_addresses(bus=args.i2c_bus, addresses=SUPPORTED_ADDRESSES)
        found_text = ", ".join(f"0x{address:02X}" for address in found) if found else "none"
        print(f"Detected shield addresses: {found_text}")

    motor_a = Motor(args.i2c_address, _MOTOR_A, 1000, bus=args.i2c_bus, protocol=args.protocol)
    motor_b = Motor(args.i2c_address, _MOTOR_B, 1000, bus=args.i2c_bus, protocol=args.protocol)

    motors = [motor_a, motor_b]
    if args.mode == "motor-a":
        motors = [motor_a]
    elif args.mode == "motor-b":
        motors = [motor_b]

    first_direction = _CW if args.direction == "cw" else _CCW
    second_direction = _CCW if first_direction == _CW else _CW

    try:
        run_phase(
            name=f"{args.mode} {args.direction}",
            motors=motors,
            direction=first_direction,
            speed=args.speed,
            duration=args.duration,
            step=args.step,
            step_delay=args.step_delay,
            stop_requested=stop_requested,
        )
        if stop_requested["value"] or args.skip_reverse:
            return 130 if stop_requested["value"] else 0

        time.sleep(0.5)
        run_phase(
            name=f"{args.mode} reverse",
            motors=motors,
            direction=second_direction,
            speed=args.speed,
            duration=args.duration,
            step=args.step,
            step_delay=args.step_delay,
            stop_requested=stop_requested,
        )
        return 0 if not stop_requested["value"] else 130
    finally:
        stop_all([motor_a, motor_b])
        motor_a.close()
        motor_b.close()
        print("Motor test complete.")


if __name__ == "__main__":
    sys.exit(main())
