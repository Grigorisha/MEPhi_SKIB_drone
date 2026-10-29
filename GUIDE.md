# Руководство по проекту MEPhI_ROS2_drone (Vindicator2)

Как устроен робот, как с ним работать каждый день и как его дорабатывать.
Описано состояние ветки `humble` на конец октября 2026.

Если какой-то документ расходится с кодом, верен код. Свежие находки о
неисправностях первыми попадают в [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).

---

## 1. Что это

**MEPhI_ROS2_drone** — открытый учебный робот НИЯУ МИФИ на ROS 2 Humble, форк
[Andino](https://github.com/Ekumen-OS/andino). Отсюда имена пакетов `andino_*`:
переименовывать их не стали.

**Vindicator2** — экземпляр, который сейчас в работе. Это гусеничная платформа.
В URDF и в контроллере она описана как дифференциальный привод с двумя
колёсами: на каждый борт по одному «колесу».

Что работает на железе:

- езда с Bluetooth-геймпада и с клавиатуры по SSH, с приоритетами источников
  через `twist_mux`;
- лидар `/scan` с автоматическим восстановлением при обрывах USB;
- одометрия `/odom`, TF и модель робота в rviz;
- автозапуск всего стека при включении питания.

Что есть в коде, но на текущем роботе не отлажено: SLAM (`andino_slam`),
навигация Nav2 (`andino_navigation`), симуляция в Gazebo Classic. Перед SLAM
нужно исправить радиус колеса, иначе карта поплывёт
([TROUBLESHOOTING §5](./TROUBLESHOOTING.md#5-радиус-колеса-расходится)).

---

## 2. Карта документации

| Документ | Для чего |
|---|---|
| `GUIDE.md` (этот) | Устройство, эксплуатация, разработка |
| [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) | Известные неисправности: симптом → причина → лечение. Начинайте с него, если что-то сломалось |
| [`README.md`](./README.md) | Сборка с нуля: Ubuntu на Pi, ROS 2, видео. Писался для исходного двухколёсного робота, см. оговорки в [§10](#10-первичная-настройка-робота) |
| [`andino_hardware/`](./andino_hardware), [`schematic/`](./schematic), [`3D/`](./3D) | Перечень компонентов, инструкции по сборке корпуса и электрики, модели для печати и резки |
| [`andino_firmware/README.md`](./andino_firmware/README.md) | Прошивка Arduino и её отладочные команды |
| `masterclass_ros2_plan.md`, `masterclass_student_guide.md` | Мастер-класс для школьников. Написаны в июле 2026, до `twist_mux` и до того, как нашли ufw; оговорки в [§11](#11-известные-ограничения-и-открытые-задачи) |
| [`LIDAR_TEST_PLAN.md`](./LIDAR_TEST_PLAN.md) | Отдельный эксперимент: лидар от робота-пылесоса на ESP32. К основному стеку не относится |

---

## 3. Железо

| Узел | Что это | Как подключено |
|---|---|---|
| Бортовой компьютер | Raspberry Pi 4B 8 ГБ, Ubuntu 22.04.5, ROS 2 Humble | Wi-Fi; Bluetooth для геймпада |
| Контроллер моторов | Arduino UNO R3 (USB-мост CH340), прошивка `andino_firmware` | USB → `/dev/ttyUSB_MOTOR` (он же `/dev/ttyUSB_ARDUINO`), 57600 бод |
| Драйвер моторов | L298N | к Arduino, распиновка в `andino_firmware/src/hw.h` |
| Моторы | 2 × JGY-370B с энкодерами, 585 тиков на оборот (значение не подтверждено замером) | к L298N и Arduino |
| Лидар | Slamtec RPLIDAR A1 (USB-мост CP2102) | USB → `/dev/ttyUSB_LIDAR`, 115200 бод |
| Питание | LiPo 3S 11,1 В 5200 мА·ч + понижающий DC-DC | — |
| Пульт | Flydigi Apex 5 в режиме ПК (представляется как Xbox One S) | Bluetooth → `/dev/input/js0` |

Стабильные имена портов задаёт udev-правило
[`udev/99-mephi-ros2-drone-usb-serial.rules`](./udev/99-mephi-ros2-drone-usb-serial.rules)
по VID:PID мостов. Если поставить второе устройство на таком же мосте, правило
перестанет их различать.

IMU в перечне компонентов есть, но в ROS-стек не заведён.

---

## 4. Как устроен софт

### Поток данных

```text
 Геймпад (BT)                    Клавиатура (по SSH)           Nav2
 joy_linux_node → teleop_node    teleop_twist_keyboard         (пока пишет прямо
       │ /cmd_vel_joy                  │ /cmd_vel_keyboard       в /cmd_vel, §11)
       │ приоритет 30                  │ приоритет 20
       └───────────────┬───────────────┘
                   twist_mux  ← /cmd_vel_nav, приоритет 10
                       │ /cmd_vel
                diff_controller ─────────→ /odom, TF odom → base_link
      (controller_manager, 50 Гц)
         joint_state_broadcaster ────────→ /joint_states
                       │
       DiffDriveAndino — плагин ros2_control из andino_base
                       │ /dev/ttyUSB_MOTOR, 57600: «m L R» (тиков/с), «e» (энкодеры)
       Arduino UNO, andino_firmware: PID 30 Гц, автостоп через 3 с без команд
                       │
              L298N → моторы ← энкодеры

 RPLIDAR A1 → rplidar_composition (под lidar_watchdog.sh) → /scan
 andino_description (URDF) → robot_state_publisher → /robot_description, /tf_static
```

Дерево TF без SLAM: `odom → base_link → second_base_link → rplidar_laser_link`.
Фрейм `map` появляется только при запущенном SLAM. Поэтому в rviz для базовой
проверки Fixed Frame = `odom`.

### Нормальные показатели

| Тема | Частота | Кто публикует |
|---|---|---|
| `/odom` | 50 Гц | `diff_controller` |
| `/joint_states` | ~50 Гц | `joint_state_broadcaster` |
| `/scan` | ~6,3 Гц (нода рапортует 10 Гц, расхождение не разобрано) | `rplidar_composition` |
| `/cmd_vel` | только во время движения | ровно один публикатор — `twist_mux` |

### Где лежат ключевые параметры

| Что | Файл |
|---|---|
| Порт, скорость, таймаут (100 мс), тики энкодера | `andino_description/config/andino/hardware.yaml` |
| Колея 0,154 м, радиус колеса 0,035 м — **для одометрии** | `andino_control/config/andino_controllers.yaml` |
| Радиус колеса 0,045 м — для модели в rviz (расходится с предыдущим) | `andino_description/config/andino/wheel.yaml` |
| Приоритеты источников команд | `andino_bringup/config/twist_mux.yaml` |
| Оси и масштабы геймпада | `andino_bringup/config/joystick.yaml` |
| Состав bringup: description, control, twist_mux, геймпад, опционально лидар и камера | `andino_bringup/launch/andino_robot.launch.py` |
| Пины и соглашение о знаках | `andino_firmware/src/hw.h` |
| Скорость порта, PID, автостоп | `andino_firmware/src/constants.h` |
| `ROS_DOMAIN_ID=42` | зашит в `Makefile` и `lidar_watchdog.sh`, плюс `~/.bashrc` на роботе |

### Пакеты и каталоги

| Каталог | Содержимое |
|---|---|
| `andino_base` | Плагин ros2_control `DiffDriveAndino` и драйвер текстового протокола Arduino |
| `andino_bringup` | Launch-файлы робота, лидара, камеры, телеуправления; конфиги twist_mux и геймпада |
| `andino_control` | Запуск `controller_manager` с `diff_controller` и `joint_state_broadcaster` |
| `andino_description` | URDF/xacro, меши, параметры железа |
| `andino_firmware` | Прошивка Arduino (PlatformIO, env `uno`) |
| `andino_slam`, `andino_navigation` | slam_toolbox и Nav2 |
| `andino_gz_classic`, `andino_apps` | Симуляция; на Pi пакетов Gazebo Classic обычно нет |
| `mephi_hw_tests` | Служебные скрипты МИФИ (разбор ниже) |
| `systemd`, `sudoers.d`, `udev` | Системная обвязка робота, ставится скриптами и целями Makefile |

**`mephi_hw_tests`** смешивает рабочие инструменты и старые эксперименты.

- Используются сейчас: `lidar_watchdog.sh`, `ros2_net_setup.sh`,
  `flash_arduino.sh`, `wheels_check.sh` + `drive_test.py`, `pair_gamepad.sh`,
  `powerlog.py`, а также разовые установщики `setup_demo_system.sh`,
  `setup_remote_desktop.sh`, `fix_wifi_stability.sh`, `fix_ip_conflict.sh`,
  `bluez_gamepad_fix.sh`.
- Отключено как тупиковое: `gamepad-keeper.sh`, `setup_gamepad_keeper.sh`
  ([TROUBLESHOOTING §11](./TROUBLESHOOTING.md#11-пульт-не-переподключается-сам)).
- Эксперименты с другим железом, в текущей конфигурации не нужны:
  `test_l298n_motor_driver.py`, `test_motion_driver.py`,
  `test_wemos_motor_rotation.py`, `wemos_motor_pi.py`,
  `check_i2c_motor_shield.py`, `esp_uart_check.py`, `test_lidar_uart.py`,
  `configure_lidar_uart_pi4.sh`.

---

## 5. Что живёт на роботе

**Рабочая копия — `~/MEPhi_SKIB_drone/MEPhI_ROS2_drone`** (клон этого
репозитория, ветка `humble`). Пути к ней зашиты в systemd-юниты. На диске
есть ещё две копии проекта, их не трогать
([TROUBLESHOOTING §7](./TROUBLESHOOTING.md#7-три-копии-проекта-на-диске)).
Workspace собирается прямо в корне репозитория: `build/`, `install/`, `log/`
лежат рядом с пакетами и игнорируются git.

### Сервисы

| Сервис | Что делает |
|---|---|
| `mephi-bringup.service` | `make bringup INCLUDE_RPLIDAR=False`: описание робота, контроллеры, twist_mux, геймпад. От пользователя `pi`, `Restart=always`. Дополнение `demo.conf`: старт после синхронизации часов (ждёт не дольше 30 с), остановка за 15 с |
| `mephi-lidar-watchdog.service` | Запускает лидар отдельно. Раз в 10 с проверяет `/scan`, при тишине делает `usbreset` и перезапускает ноду. Тоже от `pi`: если запустить от root, ломается shared memory Fast-DDS |
| `wifi-reconnect` | Сторож Wi-Fi: переподключает только после ~2 минут без связи со шлюзом. Ставится `fix_wifi_stability.sh` |
| `xrdp` | Удалённый рабочий стол (XFCE) для Remmina. Ставится `setup_remote_desktop.sh` |
| `mephi-gamepad-keeper.service` | **Выключена, не включать.** Её вызовы сталкивались с вызовами самого пульта |

Пульт ни в какой службе не нуждается: сопряжённый и доверенный, он сам
подключается к роботу примерно через 2 с после включения.

Правила sudo без пароля для `pi` (минимальные):

- `sudoers.d/mephi-usbreset` — только `/usr/bin/usbreset`, для watchdog;
- `sudoers.d/mephi-services` — только `systemctl start/stop/restart mephi-bringup`,
  для перепрошивки и перезапуска стека.

### Логи

```bash
journalctl -u mephi-bringup -f        # стек робота
tail -f /tmp/lidar_watchdog.log       # лидар и его переподключения (очищается при перезагрузке)
sudo vcgencmd get_rsts                # причина последнего сброса: 1000 — пропадало питание
```

---

## 6. Повседневная работа

### Включение

1. Включить питание. Стек поднимается сам после загрузки. Без интернета это
   дольше: bringup до 30 с ждёт синхронизации часов. Пульт подключается
   примерно на 20-й секунде загрузки.
2. Проверить: `ssh Vindicator2`, затем
   `cd ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone && make service-status`.

### Подключение

- **SSH:** `ssh Vindicator2`, алиас в `~/.ssh/config`. Адрес робот получает по
  DHCP и может смениться. Ключ хоста привязан к имени через `HostKeyAlias`,
  поэтому при смене адреса достаточно поправить `HostName`.
- **Рабочий стол:** Remmina по RDP, пользователь `pi`.
- **ROS 2 по сети с ноутбука:** та же Wi-Fi-сеть, `ROS_DOMAIN_ID=42`, и на
  роботе открыт ufw для подсети ноутбука. Подробности в [§9](#9-сеть).

На ноутбуке разработчика есть набор команд для работы с роботом:
`~/Documents/vindicator`. Он лежит вне репозитория. Основные цели:
`make find` (найти робота по MAC и прописать адрес в ssh, Remmina и rviz),
`make check`, `make doctor`, `make rviz`, `make keyboard`, `make wheels`,
`make desktop`.

### Управление

**Геймпад** — основной способ. Всё на левом стике: вверх/вниз — вперёд/назад
(до 0,5 м/с), влево/вправо — поворот. Кнопки удержания нет: отпустили стик —
робот стоит.

**Клавиатура** — запасной вариант. Нода запускается на самом роботе, поэтому
работает при любой сети, пока жив SSH:

```bash
ssh -t Vindicator2
source /opt/ros/humble/setup.bash && export ROS_DOMAIN_ID=42
ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r cmd_vel:=/cmd_vel_keyboard
```

Клавиши: `i` — вперёд, `,` — назад, `j`/`l` — разворот, `k` — стоп, `q`/`z` —
скорость ±10 %.

> **Пока пульт подключён, клавиатура не работает.** Пульт непрерывно шлёт
> команды (нули, если стик отпущен) с приоритетом 30, и twist_mux отдаёт
> управление ему. Для клавиатуры пульт выключить.
>
> Команда без `-r cmd_vel:=/cmd_vel_keyboard` (так написано в материалах
> мастер-класса и в целях `make teleop-keyboard` / `make up`) пишет прямо в
> `/cmd_vel` в обход twist_mux. Без пульта она работает, но приоритетов при
> этом нет.

Безопасность: при потере связи прошивка глушит моторы через 3 с без команд, а
twist_mux отпускает источник через 0,5 с молчания. Проверки привода — только
на приподнятом роботе.

### Посмотреть данные

```bash
# на роботе
ros2 topic list
ros2 topic hz /odom      # 50 Гц
ros2 topic hz /scan      # ~6,3 Гц

# rviz без настройки сети: окно рисуется на Pi, картинка идёт по SSH
ssh -X Vindicator2
rviz2                    # Add → By topic → /scan → LaserScan; Fixed Frame = odom
```

Чтобы в rviz на ноутбуке была видна модель робота, на ноутбуке нужен пакет с
мешами ([TROUBLESHOOTING §3](./TROUBLESHOOTING.md#3-в-rviz-нет-модели-робота)).

### Выключение

`sudo poweroff`, и только потом отключать аккумулятор. При штатном выключении
`fake-hwclock` сохраняет время: аппаратных часов у Pi нет
([TROUBLESHOOTING §6](./TROUBLESHOOTING.md#6-нет-часов-реального-времени)).
Кроме того, SD-карта плохо переносит внезапную потерю питания.

---

## 7. Разработка

### Цикл правки

Вся работа идёт через GitHub, ветка `humble`. Правки, сделанные прямо на
роботе, тоже коммитятся и пушатся: незакоммиченными их не оставлять.

```bash
# на ноутбуке
git pull                 # перед работой: на роботе могли что-то закоммитить
# ...правки...
git commit -m "Что сделано" && git push

# на роботе
ssh Vindicator2
cd ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone
git pull
make build                               # если менялся C++ или добавлялись файлы
sudo systemctl restart mephi-bringup     # без пароля
```

Сборка идёт с `--symlink-install`. Поэтому правки уже существующих yaml,
launch и xacro подхватываются после перезапуска сервиса без пересборки. Новые
файлы и изменения C++ требуют `make build`. `make service-restart` перезапускает
оба сервиса и спрашивает пароль: правило sudoers покрывает только
`mephi-bringup`.

**Не запускайте `make bringup` руками при работающем сервисе:** порт мотора
занят, а второй комплект нод задвоит темы. Сначала `make service-stop`.

Принятый стиль коммитов: по-русски, заголовок в повелительном наклонении
(«Исправить…», «Добавить…»), в теле — почему сделано так и как проверено.

### Прошивка Arduino

Нижний уровень трогают в последнюю очередь. Соглашение о знаках закреплено в
`hw.h`: **на каждом борту положительный ШИМ и рост счётчика энкодера означают
«вперёд»**. Если перепаяют моторы или энкодеры, проверьте `wheels_check.sh` и
поменяйте пары пинов в `hw.h`. Знаки в ROS не трогайте: прежняя инверсия в
`andino_base` маскировала положительную обратную связь PID на левом борту.

```bash
# собрать (на ноутбуке, нужен PlatformIO)
cd andino_firmware && pio run -e uno            # → .pio/build/uno/firmware.hex
scp .pio/build/uno/firmware.hex Vindicator2:~/

# залить: скрипт остановит bringup, сохранит текущую прошивку в
# ~/MEPhi_SKIB_drone/firmware_backups/, запишет новую, проверит и запустит bringup
ssh -t Vindicator2 'bash ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone/mephi_hw_tests/flash_arduino.sh ~/firmware.hex'

# откат — тем же скриптом с файлом из firmware_backups/
```

Для ручной отладки через монитор порта (57600 бод, конец строки CR) сначала
остановите bringup. Команды: `e` — энкодеры, `r` — сброс энкодеров,
`m L R` — скорость в тиках/с, `o L R` — прямой ШИМ, `u kp:kd:ki:ko` — PID.

### Проверка изменений

- **Привод:** робот приподнят, `bash mephi_hw_tests/wheels_check.sh` на
  роботе. Каждый тест запускается по Enter. Внутри работает `drive_test.py`:
  он шлёт команды через twist_mux и сравнивает измеренную скорость каждого
  борта с расчётной. Отдельный прогон:
  `python3 mephi_hw_tests/drive_test.py --vx 0.15 --dur 3`. Запускать в shell,
  где подключён ROS и задан `ROS_DOMAIN_ID=42`.
- **Связь с Arduino:** час работы без строк `timed out` в
  `journalctl -u mephi-bringup`.
- **Лидар:** `ros2 topic hz /scan` и отсутствие новых записей о переподключении
  в `/tmp/lidar_watchdog.log`.

**CI в GitHub Actions** (`ci.yml` — colcon, `mcu-ci.yml` — PlatformIO)
унаследован от Andino и падает на каждом пуше с июля 2026. Например,
`mcu-ci.yml` запускает тесты в окружении `desktop`, которого в
`platformio.ini` нет. Пока CI не починен, красный статус ничего не говорит:
проверять нужно на роботе.

---

## 8. Шпаргалка по Makefile

Все цели запускаются из корня репозитория на роботе. `make help` выводит
полный список.

| Задача | Цели |
|---|---|
| Зависимости и сборка | `make deps-skip-classic` (на Pi), `make build`, `make clean`, `make rosdep-check` |
| Сервисы | `make service-install` (один раз), `service-enable` / `disable`, `service-start` / `stop` / `restart`, `service-status`, `service-logs` |
| Ручной запуск | `make bringup` (лидар по умолчанию выключен, его ведёт watchdog), `make lidar-watchdog`, `make up` / `attach` / `status` / `down` (стек в tmux) |
| Порты | `make ports`, `make udev-install`, `make udev-check` |
| Сеть | `make net-check` (без sudo), `make net-allow`, `make net-clean` |
| Карта и навигация | `make slam`, `make nav MAP=~/andino_map.yaml`, `make nav-slam`, `make rviz` |
| Симуляция | `make sim`, `make sim-classic` (нужен Gazebo Classic) |
| Графика на Pi | `make gui-on` / `gui-off` / `gui-status` (по умолчанию выключена, экономит RAM) |

---

## 9. Сеть

- **`ROS_DOMAIN_ID=42`** на всех машинах.
- Робот живёт в Wi-Fi `18KPU` и получает адрес по DHCP. Статический адрес
  конфликтовал с чужим устройством
  ([TROUBLESHOOTING §10](./TROUBLESHOOTING.md#10-робот-пропадает-из-сети-конфликт-ip)).
  Постоянный адрес лучше получить резервированием на роутере по MAC.
  `~/setup_network.sh` на роботе не запускать: он возвращает статический адрес.
- **На роботе включён ufw.** SSH пропускается всегда, а DDS — только из
  подсетей, для которых есть правило. Типичный симптом: ping и SSH работают, а
  ноутбук не видит ни одной ноды, и ошибок нигде нет
  ([TROUBLESHOOTING §1](./TROUBLESHOOTING.md#1-внешняя-машина-не-видит-робота-firewall)).

На новой площадке:

```bash
make net-check     # интерфейс, SSID, адрес, подсеть, ufw, слушает ли DDS
make net-allow     # открыть DDS для текущей подсети
make net-clean     # убрать правила прежних сетей
```

Если ноды всё равно не видны, точка доступа режет multicast. Тогда нужен
unicast discovery через профиль Fast-DDS (готовый пример в TROUBLESHOOTING §1).
Самое надёжное для выездов — свой роутер.

Запасной путь, которому сеть не важна: всё запускать на роботе через SSH.
Это клавиатура, `ros2 topic`, rviz через `ssh -X`. Так устроен мастер-класс.

---

## 10. Первичная настройка робота

Порядок для нового Pi или после переустановки системы. Каждый скрипт можно
безопасно запускать повторно.

1. **Ubuntu 22.04 и ROS 2 Humble** — по [README](./README.md#установка-ubuntu-2204-на-raspberry-pi).
2. **Клонировать именно сюда** (путь зашит в systemd-юниты):

   ```bash
   mkdir -p ~/MEPhi_SKIB_drone
   git clone -b humble https://github.com/Grigorisha/MEPhi_SKIB_drone.git ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone
   cd ~/MEPhi_SKIB_drone/MEPhI_ROS2_drone
   ```

   README предлагает другой путь (`~/MEPhI_ROS2_drone_ws/src`) и исходный
   репозиторий команды. Для этого робота так делать не надо.
3. **Зависимости.** `make deps-skip-classic`, затем то, чего rosdep не знает:

   ```bash
   sudo apt install -y ros-humble-twist-mux ros-humble-diagnostic-updater \
                       ros-humble-teleop-twist-keyboard usbutils fake-hwclock
   ```

   `diagnostic-updater` нужен версии не ниже 4.0.7, иначе twist_mux падает при
   старте ([TROUBLESHOOTING §8](./TROUBLESHOOTING.md#8-мультиплексор-команд-twist_mux)).
4. **Сборка:** `make build`.
5. **Порты:** `make udev-install`, переподключить USB, затем `make udev-check`.
   README описывает правила по серийным номерам — вместо них используйте файл
   из репозитория.
6. **Прошивка**, если Arduino новая: см. [§7](#прошивка-arduino).
7. **Автозапуск:** `make service-install && make service-enable`.
8. **Система:**

   ```bash
   sudo bash mephi_hw_tests/setup_demo_system.sh    # Bluetooth, группа input, avrdude,
                                                    # sudoers, старт после синхронизации часов;
                                                    # в конце перезагрузка
   # после перезагрузки:
   sudo bash mephi_hw_tests/fix_wifi_stability.sh   # энергосбережение Wi-Fi off, терпеливый сторож
   sudo bash mephi_hw_tests/bluez_gamepad_fix.sh    # BlueZ для сторонних пультов (Flydigi, клоны Xbox)
   bash mephi_hw_tests/pair_gamepad.sh              # пульт в режиме сопряжения
   sudo bash mephi_hw_tests/setup_remote_desktop.sh # по желанию: RDP для Remmina
   make net-allow
   echo 'export ROS_DOMAIN_ID=42' >> ~/.bashrc
   ```

9. **Проверка:** приподнять робота и выполнить `wheels_check.sh`. Затем
   `ros2 topic hz /odom` и `/scan`. Наконец перезагрузить Pi и убедиться, что
   всё поднялось само.

---

## 11. Известные ограничения и открытые задачи

Подробности и статус — в [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).

| Что | Состояние |
|---|---|
| Радиус колеса: 0,035 м в контроллере против 0,045 м в URDF; 585 тиков/оборот не подтверждены | Открыто, нужен замер. Пока не сделано, одометрия врёт, а SLAM и Nav2 бессмысленны (§5) |
| Nav2 публикует прямо в `/cmd_vel`, мимо twist_mux | Открыто: выход Nav2 нужно ремапить на `/cmd_vel_nav`, иначе пульт не сможет перехватить управление (§8) |
| Дребезг USB лидара | Обходится watchdog'ом; причину (разъём, кабель, питание) не устранили (§4) |
| Таймауты ответа Arduino | Таймаут снижен до 100 мс, перед каждой командой очищается входной буфер. На стендовой проверке 10.10.2026 таймаутов не было, раздел остаётся открытым (§9) |
| Внезапные перезагрузки, `get_rsts` = 1000 | Причина не установлена; подозрение на просадку питания под нагрузкой гусениц (§12) |
| Нет RTC | Стоит `fake-hwclock`; полноценно решит модуль DS3231 (§6) |
| `/scan` 6,3 Гц вместо заявленных нодой 10 Гц | Не разобрано |
| Материалы мастер-класса | Клавиатура там пишет в обход twist_mux. Нативная ROS-сеть там объявлена ненадёжной, но главную причину — ufw на роботе — нашли позже, её лечит `make net-allow`. SSH-подход остаётся рабочим запасным путём |
| Комментарий в `joystick.yaml` про «полный ШИМ» и `kFullSpeed` | Устарел: режим прямого ШИМ убран, драйвер снова управляет скоростью через PID прошивки |
| CI | Падает с июля 2026 (см. [§7](#проверка-изменений)) |
