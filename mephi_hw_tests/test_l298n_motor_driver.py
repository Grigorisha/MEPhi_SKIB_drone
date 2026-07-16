#!/usr/bin/env python3
"""Safe PWM test for an L298N motor driver connected to Raspberry Pi 4B."""

from __future__ import annotations

import argparse
import signal
import sys
import time
from dataclasses import dataclass

import RPi.GPIO as GPIO


@dataclass(frozen=True)
class MotorPins:
    name: str
    enable_bcm: int
    in1_bcm: int
    in2_bcm: int


LEFT_MOTOR = MotorPins("left", enable_bcm=26, in1_bcm=19, in2_bcm=13)
RIGHT_MOTOR = MotorPins("right", enable_bcm=22, in1_bcm=6, in2_bcm=5)
PWM_FREQUENCY_HZ = 1000


class L298NMotor:
    def __init__(self, pins: MotorPins, pwm_frequency_hz: int) -> None:
        self.pins = pins
        self._pwm_frequency_hz = pwm_frequency_hz
        self._pwm: GPIO.PWM | None = None

    def setup(self) -> None:
        GPIO.setup(self.pins.enable_bcm, GPIO.OUT, initial=GPIO.LOW)
        GPIO.setup(self.pins.in1_bcm, GPIO.OUT, initial=GPIO.LOW)
        GPIO.setup(self.pins.in2_bcm, GPIO.OUT, initial=GPIO.LOW)
        self._pwm = GPIO.PWM(self.pins.enable_bcm, self._pwm_frequency_hz)
        self._pwm.start(0.0)

    def drive(self, direction: str, duty_cycle: float) -> None:
        duty_cycle = max(0.0, min(100.0, float(duty_cycle)))
        if direction == "forward":
            GPIO.output(self.pins.in1_bcm, GPIO.HIGH)
            GPIO.output(self.pins.in2_bcm, GPIO.LOW)
        elif direction == "reverse":
            GPIO.output(self.pins.in1_bcm, GPIO.LOW)
            GPIO.output(self.pins.in2_bcm, GPIO.HIGH)
        else:
            raise ValueError("direction must be 'forward' or 'reverse'")

        if self._pwm is None:
            raise RuntimeError("PWM is not initialized")
        self._pwm.ChangeDutyCycle(duty_cycle)

    def brake(self) -> None:
        if self._pwm is not None:
            self._pwm.ChangeDutyCycle(0.0)
        GPIO.output(self.pins.in1_bcm, GPIO.LOW)
        GPIO.output(self.pins.in2_bcm, GPIO.LOW)

    def cleanup(self) -> None:
        self.brake()
        if self._pwm is not None:
            self._pwm.stop()
            self._pwm = None


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Safe PWM test for two DC motors connected to L298N on Raspberry Pi 4B."
    )
    parser.add_argument("--mode", choices=("both", "left", "right"), default="both")
    parser.add_argument("--direction", choices=("forward", "reverse"), default="forward")
    parser.add_argument(
        "--speed",
        type=float,
        default=35.0,
        help="Target PWM duty cycle in percent (0..100).",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=2.0,
        help="Time to keep the selected speed in each phase.",
    )
    parser.add_argument(
        "--ramp-step",
        type=float,
        default=5.0,
        help="Duty-cycle increment for soft start/stop.",
    )
    parser.add_argument(
        "--ramp-delay",
        type=float,
        default=0.12,
        help="Delay between ramp steps in seconds.",
    )
    parser.add_argument(
        "--pause-between-phases",
        type=float,
        default=0.7,
        help="Pause between forward and reverse phases.",
    )
    parser.add_argument(
        "--pwm-frequency",
        type=int,
        default=PWM_FREQUENCY_HZ,
        help="Software PWM frequency in Hz.",
    )
    parser.add_argument(
        "--skip-reverse-phase",
        action="store_true",
        help="Only run the selected direction once.",
    )
    return parser


def print_header(args: argparse.Namespace, motors: list[L298NMotor]) -> None:
    print("=" * 72)
    print("L298N motor test for Raspberry Pi 4B")
    print("=" * 72)
    print("BCM pin map:")
    for motor in motors:
        print(
            f"  {motor.pins.name:5s}: EN={motor.pins.enable_bcm:2d}  "
            f"IN1={motor.pins.in1_bcm:2d}  IN2={motor.pins.in2_bcm:2d}"
        )
    print()
    print("Test settings:")
    print(
        f"  mode={args.mode}  direction={args.direction}  speed={args.speed:.1f}%  "
        f"duration={args.duration:.1f}s"
    )
    print(
        f"  pwm_frequency={args.pwm_frequency}Hz  ramp_step={args.ramp_step:.1f}%  "
        f"ramp_delay={args.ramp_delay:.2f}s"
    )
    print()
    print("Safety notes:")
    print("  Use external motor power for L298N and keep GND common with Raspberry Pi.")
    print("  ENA GPIO26 and ENB GPIO22 use software PWM in this script.")
    print("  Start with low speed and keep wheels free from obstacles.")
    print("=" * 72)


def select_motors(mode: str) -> list[L298NMotor]:
    left = L298NMotor(LEFT_MOTOR, PWM_FREQUENCY_HZ)
    right = L298NMotor(RIGHT_MOTOR, PWM_FREQUENCY_HZ)
    if mode == "left":
        return [left]
    if mode == "right":
        return [right]
    return [left, right]


def ramp_to_speed(
    motors: list[L298NMotor],
    direction: str,
    target_speed: float,
    ramp_step: float,
    ramp_delay: float,
    stop_requested: dict[str, bool],
) -> None:
    current = 0.0
    step = max(0.1, ramp_step)
    while current < target_speed and not stop_requested["value"]:
        current = min(current + step, target_speed)
        for motor in motors:
            motor.drive(direction, current)
        print(f"  ramp -> {current:5.1f}%")
        time.sleep(ramp_delay)


def hold_speed(
    motors: list[L298NMotor],
    direction: str,
    speed: float,
    duration: float,
    stop_requested: dict[str, bool],
) -> None:
    end_time = time.monotonic() + duration
    while time.monotonic() < end_time and not stop_requested["value"]:
        for motor in motors:
            motor.drive(direction, speed)
        time.sleep(0.1)


def ramp_to_stop(
    motors: list[L298NMotor],
    direction: str,
    speed: float,
    ramp_step: float,
    ramp_delay: float,
) -> None:
    current = max(0.0, speed)
    step = max(0.1, ramp_step)
    while current > 0.0:
        current = max(0.0, current - step)
        for motor in motors:
            if current > 0.0:
                motor.drive(direction, current)
            else:
                motor.brake()
        print(f"  stop -> {current:5.1f}%")
        time.sleep(ramp_delay)


def run_phase(
    motors: list[L298NMotor],
    phase_name: str,
    direction: str,
    speed: float,
    duration: float,
    ramp_step: float,
    ramp_delay: float,
    stop_requested: dict[str, bool],
) -> None:
    print(f"Phase: {phase_name}")
    ramp_to_speed(motors, direction, speed, ramp_step, ramp_delay, stop_requested)
    if not stop_requested["value"]:
        hold_speed(motors, direction, speed, duration, stop_requested)
    ramp_to_stop(motors, direction, speed, ramp_step, ramp_delay)
    print(f"Phase complete: {phase_name}")


def opposite_direction(direction: str) -> str:
    return "reverse" if direction == "forward" else "forward"


def main() -> int:
    args = build_arg_parser().parse_args()
    stop_requested = {"value": False}

    def _request_stop(_sig: int, _frame: object) -> None:
        stop_requested["value"] = True
        print("\nStop requested, shutting down motors safely...")

    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)

    motors = select_motors(args.mode)
    for motor in motors:
        motor._pwm_frequency_hz = args.pwm_frequency

    print_header(args, motors)

    GPIO.setwarnings(False)
    GPIO.setmode(GPIO.BCM)

    try:
        for motor in motors:
            motor.setup()

        run_phase(
            motors=motors,
            phase_name=f"{args.mode} {args.direction}",
            direction=args.direction,
            speed=max(0.0, min(100.0, args.speed)),
            duration=max(0.0, args.duration),
            ramp_step=max(0.1, args.ramp_step),
            ramp_delay=max(0.01, args.ramp_delay),
            stop_requested=stop_requested,
        )

        if stop_requested["value"] or args.skip_reverse_phase:
            return 130 if stop_requested["value"] else 0

        time.sleep(max(0.0, args.pause_between_phases))
        reverse_direction = opposite_direction(args.direction)
        run_phase(
            motors=motors,
            phase_name=f"{args.mode} {reverse_direction}",
            direction=reverse_direction,
            speed=max(0.0, min(100.0, args.speed)),
            duration=max(0.0, args.duration),
            ramp_step=max(0.1, args.ramp_step),
            ramp_delay=max(0.01, args.ramp_delay),
            stop_requested=stop_requested,
        )
        return 0 if not stop_requested["value"] else 130
    finally:
        for motor in motors:
            try:
                motor.cleanup()
            except Exception:
                pass
        GPIO.cleanup()
        print("GPIO cleanup complete.")


if __name__ == "__main__":
    sys.exit(main())
