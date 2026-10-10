#!/usr/bin/env python3
# Чёрный ящик питания: переживает внезапную потерю питания (O_SYNC на каждую строку).
# Пишет: сигнал низкого напряжения rpi_volt, пульс раз в секунду, активность стиков.
import os, time, struct, select, glob, subprocess
LOG = os.path.expanduser("~/power.log")
fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_SYNC, 0o644)
def log(s):
    os.write(fd, (time.strftime("%H:%M:%S") + f".{int(time.time()*10)%10} " + s + "\n").encode())
alarm_path = glob.glob("/sys/class/hwmon/hwmon*/in0_lcrit_alarm")[0]
js = None; axes = {}; last_beat = 0; prev_alarm = None; peak = 0.0; pp = None; gw_ok = "?"
gw = subprocess.run(["sh","-c","ip route | awk '/^default/{print $3; exit}'"],capture_output=True,text=True).stdout.strip()
log("старт, uptime %s" % open("/proc/uptime").read().split()[0])
while True:
    if js is None and os.path.exists("/dev/input/js0"):
        try: js = os.open("/dev/input/js0", os.O_RDONLY | os.O_NONBLOCK); log("js0 открыт")
        except OSError: js = None
    r = []
    if js is not None:
        r, _, _ = select.select([js], [], [], 0.2)
    else:
        time.sleep(0.2)
    if r:
        try:
            data = os.read(js, 8 * 64)
            for i in range(0, len(data) - 7, 8):
                _, val, typ, num = struct.unpack("IhBB", data[i:i+8])
                if typ & 0x02 and num in (0, 1):
                    axes[num] = val / 32767.0
        except OSError:
            os.close(js); js = None; axes = {}; log("js0 пропал")
    peak = max(peak, max([abs(v) for v in axes.values()] or [0]))
    a = open(alarm_path).read().strip()
    if a != prev_alarm:
        log("НИЗКОЕ НАПРЯЖЕНИЕ" if a == "1" else "напряжение норма"); prev_alarm = a
    now = time.time()
    if now - last_beat >= 1.0:
        if pp is not None:
            rc = pp.poll(); gw_ok = "нет" if rc is None or rc != 0 else "да"
            if rc is None: pp.kill()
        pp = subprocess.Popen(["ping","-c1","-W1",gw], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if gw else None
        log("пульс стик=%.2f шлюз=%s" % (peak, gw_ok)); last_beat = now; peak = 0.0
