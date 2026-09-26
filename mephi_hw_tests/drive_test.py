#!/usr/bin/env python3
"""Тест цепочки привода Vindicator2 на приподнятом роботе.

Публикует Twist через twist_mux (по умолчанию в /cmd_vel_keyboard — тот же путь,
что пойдёт от геймпада, только с приоритетом 20), записывает /joint_states и
/odom и сравнивает измеренную скорость каждого борта с той, что должна была
получиться по кинематике diff_drive.

    python3 drive_test.py --vx 0.05 --dur 4          # медленно вперёд
    python3 drive_test.py --wz 0.6 --dur 4           # разворот на месте влево
    python3 drive_test.py --vx 0.05 --wz 0.6 --dur 4 # дуга

Безопасность: команды идут 20 Гц; после окна движения скрипт шлёт нули.
Если скрипт упадёт, twist_mux отпустит тему через 0.5 с, а diff_controller
обнулит скорость по cmd_vel_timeout (0.5 с).
"""
import argparse
import math
import statistics
import time

import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.node import Node
from sensor_msgs.msg import JointState

LEFT, RIGHT = 'left_wheel_joint', 'right_wheel_joint'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--vx', type=float, default=0.0, help='линейная скорость, м/с')
    ap.add_argument('--wz', type=float, default=0.0, help='угловая скорость, рад/с (+ = влево)')
    ap.add_argument('--dur', type=float, default=3.0, help='длительность движения, с')
    ap.add_argument('--countdown', type=int, default=3)
    ap.add_argument('--topic', default='/cmd_vel_keyboard')
    ap.add_argument('--radius', type=float, default=0.035)
    ap.add_argument('--sep', type=float, default=0.154)
    ap.add_argument('--ticks', type=int, default=585, help='enc_ticks_per_rev из hardware.yaml')
    a = ap.parse_args()

    rclpy.init()
    node = Node('drive_test')
    pub = node.create_publisher(Twist, a.topic, 10)
    js, od = [], []

    def js_cb(m):
        d = {}
        for i, name in enumerate(m.name):
            vel = m.velocity[i] if i < len(m.velocity) else float('nan')
            d[name] = (m.position[i], vel)
        js.append((time.monotonic(), d))

    def od_cb(m):
        q = m.pose.pose.orientation
        yaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        od.append((time.monotonic(), m.pose.pose.position.x, m.pose.pose.position.y, yaw))

    node.create_subscription(JointState, '/joint_states', js_cb, 100)
    node.create_subscription(Odometry, '/odom', od_cb, 100)

    def spin_for(sec, twist=None, rate=20.0):
        end = time.monotonic() + sec
        nxt = time.monotonic()
        while time.monotonic() < end:
            if twist is not None and time.monotonic() >= nxt:
                pub.publish(twist)
                nxt += 1.0 / rate
            rclpy.spin_once(node, timeout_sec=0.005)

    for i in range(a.countdown, 0, -1):
        print(f'  старт через {i}...', flush=True)
        spin_for(1.0)

    cmd = Twist()
    cmd.linear.x = a.vx
    cmd.angular.z = a.wz
    print(f'  >>> ДВИЖЕНИЕ vx={a.vx:+.3f} м/с  wz={a.wz:+.3f} рад/с  {a.dur:.1f} с', flush=True)
    t0 = time.monotonic()
    spin_for(a.dur, cmd)
    t1 = time.monotonic()
    spin_for(1.0, Twist())          # явный стоп
    print('  >>> СТОП', flush=True)
    spin_for(1.0)                   # смотрим, остановились ли
    t_end = time.monotonic()

    node.destroy_node()
    rclpy.shutdown()

    # ---------------- разбор ----------------
    exp = {
        LEFT: (a.vx - a.wz * a.sep / 2) / a.radius,
        RIGHT: (a.vx + a.wz * a.sep / 2) / a.radius,
    }
    steady_from = t0 + 0.4 * a.dur

    def pos_at(t, name):
        best = min(js, key=lambda s: abs(s[0] - t)) if js else None
        return best[1][name][0] if best and name in best[1] else float('nan')

    print()
    print(f'  сообщений /joint_states: {len(js)}, /odom: {len(od)}')
    print()
    print(f'  {"борт":<6} {"задано":>8} {"измерено":>9} {"разброс":>8} {"макс":>7} {"отнош.":>7}  '
          f'{"оборотов":>9}  вывод')
    for name, label in ((LEFT, 'левый'), (RIGHT, 'правый')):
        steady = [s[1][name][1] for s in js if steady_from <= s[0] <= t1 and name in s[1]]
        moving = [s[1][name][1] for s in js if t0 <= s[0] <= t1 and name in s[1]]
        after = [s[1][name][1] for s in js if t1 + 1.2 <= s[0] <= t_end and name in s[1]]
        if not steady:
            print(f'  {label:<6} нет данных')
            continue
        mean = statistics.fmean(steady)
        sd = statistics.pstdev(steady)
        vmax = max(abs(v) for v in moving)
        e = exp[name]
        ratio = mean / e if abs(e) > 1e-9 else float('nan')
        revs = (pos_at(t1, name) - pos_at(t0, name)) / (2 * math.pi)
        still = max((abs(v) for v in after), default=0.0)

        if abs(e) < 1e-9:
            verdict = 'должен стоять' + (' — стоит' if vmax < 0.2 else f' — ДВИГАЕТСЯ ({vmax:.2f})')
        elif abs(mean) < 0.1 * abs(e):
            verdict = 'НЕ КРУТИТСЯ (или энкодер молчит)'
        elif abs(ratio) > 2.0:
            verdict = 'КРУТИТСЯ СЛИШКОМ БЫСТРО — похоже на разгон PID до упора'
        elif ratio < 0:
            verdict = 'ЗНАК ОБРАТНЫЙ: энкодер считает в другую сторону'
        elif abs(ratio) < 0.7:
            verdict = 'медленнее заданного — упор по скорости?'
        else:
            verdict = 'ok'
        if sd > 0.35 * abs(mean) and abs(mean) > 0.1:
            verdict += '; скорость неровная'
        if still > 0.2:
            verdict += f'; ПОСЛЕ СТОПА ЕЩЁ КРУТИТСЯ ({still:.2f})'

        print(f'  {label:<6} {e:>+8.2f} {mean:>+9.2f} {sd:>8.2f} {vmax:>7.2f} {ratio:>+7.2f}  '
              f'{revs:>+9.2f}  {verdict}')

    if od:
        first = min(od, key=lambda s: abs(s[0] - t0))
        last = min(od, key=lambda s: abs(s[0] - t_end))
        dx = last[1] - first[1]
        dyaw = math.degrees(math.atan2(math.sin(last[3] - first[3]), math.cos(last[3] - first[3])))
        exp_dx = a.vx * a.dur
        exp_dyaw = math.degrees(a.wz * a.dur)
        print()
        print(f'  одометрия: dx = {dx:+.3f} м (ожидалось {exp_dx:+.3f}),  '
              f'dyaw = {dyaw:+.1f}° (ожидалось {exp_dyaw:+.1f}°)')
    print('  (скорости в рад/с колеса; задано — по кинематике diff_drive с радиусом '
          f'{a.radius} м и базой {a.sep} м)')


if __name__ == '__main__':
    main()
