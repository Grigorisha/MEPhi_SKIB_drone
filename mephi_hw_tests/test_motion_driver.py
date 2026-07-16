#!/usr/bin/env python3
"""Motion driver and encoder test for Raspberry Pi and D1 mini TB6612FNG."""

from __future__ import annotations

import argparse
import signal
import sys
import threading
import time
from dataclasses import dataclass

import RPi.GPIO as GPIO

from wemos_motor_pi import DEFAULT_I2C_ADDRESS, Motor, _CCW, _CW, _MOTOR_A, _MOTOR_B, _STOP


@dataclass(frozen=True)
class PinSpec:
    name: str
    board: int
    bcm: int


I2C_SDA = PinSpec("i2c_sda", board=3, bcm=2)
I2C_SCL = PinSpec("i2c_scl", board=5, bcm=3)
ENCODER_1_A = PinSpec("encoder_1_a", board=18, bcm=24)
ENCODER_1_B = PinSpec("encoder_1_b", board=22, bcm=25)
ENCODER_2_A = PinSpec("encoder_2_a", board=24, bcm=8)
ENCODER_2_B = PinSpec("encoder_2_b", board=26, bcm=7)

ENCODER_DELTA = (0, 1, -1, 0, -1, 0, 0, 1, 1, 0, 0, -1, 0, -1, 1, 0)


class QuadratureEncoder:
    def __init__(self, name: str, channel_a: PinSpec, channel_b: PinSpec, pull_up: bool) -> None:
        self.name = name
        self.channel_a = channel_a
        self.channel_b = channel_b
        self.pull_up = pull_up
        self._lock = threading.Lock()
        self._state = 0
        self._count = 0
        self._invalid_steps = 0
        self._using_interrupts = False
        self._poll_stop = threading.Event()
        self._poll_thread: threading.Thread | None = None

    def setup(self) -> None:
        pud = GPIO.PUD_UP if self.pull_up else GPIO.PUD_DOWN
        GPIO.setup(self.channel_a.board, GPIO.IN, pull_up_down=pud)
        GPIO.setup(self.channel_b.board, GPIO.IN, pull_up_down=pud)
        self._state = self._read_ab()
        try:
            GPIO.add_event_detect(self.channel_a.board, GPIO.BOTH, callback=self._on_edge)
            try:
                GPIO.add_event_detect(self.channel_b.board, GPIO.BOTH, callback=self._on_edge)
            except RuntimeError:
                self._remove_event_detect(self.channel_a.board)
                raise
            self._using_interrupts = True
            print(f"[{self.name}] input mode: GPIO edge detection")
        except RuntimeError as exc:
            self._using_interrupts = False
            print(f"[{self.name}] edge detection unavailable ({exc}); using polling fallback")
            self._start_polling()

    def _read_ab(self) -> int:
        a = GPIO.input(self.channel_a.board)
        b = GPIO.input(self.channel_b.board)
        return (b << 1) | a

    def _apply_ab(self, ab_state: int) -> None:
        self._state = ((self._state << 2) | ab_state) & 0x0F
        delta = ENCODER_DELTA[self._state]
        self._count += delta
        if delta == 0 and ((self._state & 0x03) != ((self._state >> 2) & 0x03)):
            self._invalid_steps += 1

    def _on_edge(self, _channel: int) -> None:
        with self._lock:
            self._apply_ab(self._read_ab())

    def _start_polling(self) -> None:
        self._poll_stop.clear()
        self._poll_thread = threading.Thread(target=self._poll_loop, name=f"{self.name}_poll", daemon=True)
        self._poll_thread.start()

    def _poll_loop(self) -> None:
        previous = self._read_ab()
        while not self._poll_stop.is_set():
            current = self._read_ab()
            if current != previous:
                with self._lock:
                    self._apply_ab(current)
                previous = current
            time.sleep(0.001)

    def _remove_event_detect(self, pin: int) -> None:
        try:
            GPIO.remove_event_detect(pin)
        except RuntimeError:
            pass

    def snapshot(self) -> tuple[int, int]:
        with self._lock:
            return self._count, self._invalid_steps

    def reset(self) -> None:
        with self._lock:
            self._count = 0
            self._invalid_steps = 0
            self._state = self._read_ab()

    def cleanup(self) -> None:
        self._poll_stop.set()
        if self._poll_thread is not None and self._poll_thread.is_alive():
            self._poll_thread.join(timeout=0.2)
        if self._using_interrupts:
            self._remove_event_detect(self.channel_a.board)
            self._remove_event_detect(self.channel_b.board)


def parse_int_auto(value: str) -> int:
    return int(value, 0)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Safe test for D1 mini TB6612FNG I2C motor driver and two encoders."
    )
    parser.add_argument("--force-drive", action="store_true")
    parser.add_argument("--speed", type=float, default=30.0)
    parser.add_argument("--duration", type=float, default=3.0)
    parser.add_argument("--sample-interval", type=float, default=0.5)
    parser.add_argument("--ramp-step", type=float, default=5.0)
    parser.add_argument("--ramp-delay", type=float, default=0.08)
    parser.add_argument("--i2c-bus", type=int, default=1)
    parser.add_argument("--i2c-address", type=parse_int_auto, default=DEFAULT_I2C_ADDRESS)
    parser.add_argument("--protocol", choices=("legacy", "lolin"), default="legacy")
    parser.add_argument("--encoder-pull-up", action="store_true", default=True)
    parser.add_argument("--encoder-pull-down", action="store_true")
    parser.add_argument("--watch-seconds", type=float, default=10.0)
    parser.add_argument("--skip-reverse-phase", action="store_true")
    return parser


def print_header(args: argparse.Namespace) -> None:
    print("=" * 72)
    print("MEPhI motion driver and encoder test")
    print("=" * 72)
    print("Pin map from hardware_test_plan.md")
    print(f"  Motor driver I2C SDA : BOARD {I2C_SDA.board} -> BCM {I2C_SDA.bcm}")
    print(f"  Motor driver I2C SCL : BOARD {I2C_SCL.board} -> BCM {I2C_SCL.bcm}")
    print(f"  Encoder1            : A BOARD {ENCODER_1_A.board} -> BCM {ENCODER_1_A.bcm}, "
          f"B BOARD {ENCODER_1_B.board} -> BCM {ENCODER_1_B.bcm}")
    print(f"  Encoder2            : A BOARD {ENCODER_2_A.board} -> BCM {ENCODER_2_A.bcm}, "
          f"B BOARD {ENCODER_2_B.board} -> BCM {ENCODER_2_B.bcm}")
    print()
    print("Motor driver settings:")
    print(f"  I2C bus={args.i2c_bus}  address=0x{args.i2c_address:02X}  protocol={args.protocol}")
    print("=" * 72)


def sign_label(value: int) -> str:
    if value > 0:
        return "forward"
    if value < 0:
        return "reverse"
    return "still"


def report_encoders(
    encoders: list[QuadratureEncoder],
    last_counts: dict[str, int],
    interval_s: float,
) -> dict[str, int]:
    updated: dict[str, int] = {}
    for encoder in encoders:
        count, invalid = encoder.snapshot()
        delta = count - last_counts[encoder.name]
        ticks_per_second = delta / interval_s if interval_s > 0 else 0.0
        print(
            f"[{encoder.name}] total={count:6d}  delta={delta:5d}  "
            f"dir={sign_label(delta):7s}  rate={ticks_per_second:7.1f} tick/s  invalid={invalid}"
        )
        updated[encoder.name] = count
    return updated


def watch_encoders(
    encoders: list[QuadratureEncoder],
    seconds: float,
    sample_interval: float,
    stop_requested: dict[str, bool],
) -> None:
    print(f"Encoder-only mode for {seconds:.1f} s.")
    last_counts = {encoder.name: encoder.snapshot()[0] for encoder in encoders}
    end_time = time.monotonic() + seconds
    while time.monotonic() < end_time and not stop_requested["value"]:
        time.sleep(sample_interval)
        last_counts = report_encoders(encoders, last_counts, sample_interval)


def ramp_motors(motors: list[Motor], direction: int, target_speed: float, step: float, delay: float) -> None:
    current = 0.0
    while current < target_speed:
        current = min(current + max(0.1, step), target_speed)
        for motor in motors:
            motor.setmotor(direction, current)
        time.sleep(delay)


def stop_motors(motors: list[Motor], direction: int, speed: float, step: float, delay: float) -> None:
    current = max(0.0, speed)
    while current > 0:
        current = max(0.0, current - max(0.1, step))
        for motor in motors:
            if current == 0:
                motor.setmotor(_STOP)
            else:
                motor.setmotor(direction, current)
        time.sleep(delay)
    for motor in motors:
        motor.setmotor(_STOP)


def run_phase(
    motors: list[Motor],
    encoders: list[QuadratureEncoder],
    phase_name: str,
    direction: int,
    speed: float,
    duration: float,
    sample_interval: float,
    ramp_step: float,
    ramp_delay: float,
    stop_requested: dict[str, bool],
) -> None:
    print(f"Phase: {phase_name}")
    last_counts = {encoder.name: encoder.snapshot()[0] for encoder in encoders}
    ramp_motors(motors, direction, speed, ramp_step, ramp_delay)
    phase_end = time.monotonic() + duration
    while time.monotonic() < phase_end and not stop_requested["value"]:
        time.sleep(sample_interval)
        last_counts = report_encoders(encoders, last_counts, sample_interval)
    stop_motors(motors, direction, speed, ramp_step, ramp_delay)
    print(f"Phase complete: {phase_name}")


def main() -> int:
    args = build_arg_parser().parse_args()
    if args.encoder_pull_down:
        args.encoder_pull_up = False

    stop_requested = {"value": False}

    def _request_stop(_sig: int, _frame: object) -> None:
        stop_requested["value"] = True
        print("\nStop requested, shutting down safely...")

    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)

    print_header(args)
    GPIO.setwarnings(False)
    GPIO.setmode(GPIO.BOARD)

    encoders = [
        QuadratureEncoder("encoder_1", ENCODER_1_A, ENCODER_1_B, pull_up=args.encoder_pull_up),
        QuadratureEncoder("encoder_2", ENCODER_2_A, ENCODER_2_B, pull_up=args.encoder_pull_up),
    ]
    motor_a = motor_b = None

    try:
        for encoder in encoders:
            encoder.setup()
            encoder.reset()

        if not args.force_drive:
            watch_encoders(encoders, args.watch_seconds, args.sample_interval, stop_requested)
            return 0

        motor_a = Motor(args.i2c_address, _MOTOR_A, 1000, bus=args.i2c_bus, protocol=args.protocol)
        motor_b = Motor(args.i2c_address, _MOTOR_B, 1000, bus=args.i2c_bus, protocol=args.protocol)
        motors = [motor_a, motor_b]

        run_phase(
            motors,
            encoders,
            "same direction",
            _CW,
            abs(args.speed),
            args.duration,
            args.sample_interval,
            args.ramp_step,
            args.ramp_delay,
            stop_requested,
        )
        if stop_requested["value"] or args.skip_reverse_phase:
            return 130 if stop_requested["value"] else 0

        time.sleep(1.0)
        run_phase(
            motors,
            encoders,
            "same direction reverse",
            _CCW,
            abs(args.speed),
            args.duration,
            args.sample_interval,
            args.ramp_step,
            args.ramp_delay,
            stop_requested,
        )
        return 0 if not stop_requested["value"] else 130
    finally:
        for encoder in encoders:
            encoder.cleanup()
        if motor_a is not None:
            try:
                motor_a.setmotor(_STOP)
            except Exception:
                pass
            motor_a.close()
        if motor_b is not None:
            try:
                motor_b.setmotor(_STOP)
            except Exception:
                pass
            motor_b.close()
        GPIO.cleanup()
        print("GPIO cleanup complete.")


if __name__ == "__main__":
    sys.exit(main())
