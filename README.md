# MEPhI_ROS2_drone

**MEPhI_ROS2_drone** - это двухколесный робот с открытым исходным кодом, разработанный для образовательных целей командой студентов из НИЯУ МИФИ. MEPhI_ROS2_drone полностью интегрирован с ROS2 и является отличной базовой платформой для плавного введения в ROS2. Благодаря открытому коду и исходным файлам 3D моделей любой желающий может модифицировать и настроить робота в соответствии со своими требованиями.

*Данный проект является форком проекта [Andino](https://github.com/Ekumen-OS/andino), ПО, конструкция и электрическая схема которого были доработаны под наши требования.

> Как устроен и как обслуживается текущий робот (Vindicator2) — [`GUIDE.md`](./GUIDE.md). Известные неисправности и их лечение — [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).

<p align="center">
  <img src="MEPhI_ROS2_drone.jpg" width=700 />
</p>

## Описание проекта
- [`3D`](./3D): 3D модели деталей и сборки робота, также содержит `.stl` для 3D печати и `.dxf` для лазерной резки
- [`schematic`](./schematic): электрическая схема робота и инструкция по ее сборке
- [`MEPhI_ROS2_drone_hardware`](./andino_hardware): содержит инструкцию по сборке `MEPhI_ROS2_drone` и перечень используемого оборудования
- [`MEPhI_ROS2_drone_firmware`](./andino_firmware): содержит код отладочной платы Arduino UNO R3 для сопряжения с raspberry pi 4 и инструкцию по его заливке на плату
- [`MEPhI_ROS2_drone_bringup`](./andino_bringup): содержит файлы запуска для старта всех связанных драйверов и нод, которые будут использоваться в роботе
- [`MEPhI_ROS2_drone_description`](./andino_description): содержит описание робота в формате `.urdf`
- [`MEPhI_ROS2_drone_base`](./andino_base): это программно-аппаратный модуль проекта, который обеспечивает связь с микроконтроллером для управления моторами и предоставляет утилиты для отладки
- [`MEPhI_ROS2_drone_control`](./andino_control/): запускает [controller_manager](https://control.ros.org/humble/doc/ros2_control/controller_manager/doc/userdoc.html) вместе с [ros2 controllers](https://control.ros.org/master/doc/ros2_controllers/doc/controllers_index.html): [diff_drive_controller](https://control.ros.org/master/doc/ros2_controllers/diff_drive_controller/doc/userdoc.html) и [joint_state_broadcaster](https://control.ros.org/master/doc/ros2_controllers/joint_state_broadcaster/doc/userdoc.html)
- [`MEPhI_ROS2_drone_slam`](./andino_slam/): обеспечивает работу `SLAM` (одновременная локализация и построение карты)
- [`MEPhI_ROS2_drone_navigation`](./andino_navigation/): стек навигации, основанный на `Nav2`

## Видеоматериалы работы

### Отображение LaserScan в rviz2

[![LaserScan](https://img.youtube.com/vi/dyld3nLJG04/0.jpg)](https://youtu.be/dyld3nLJG04)

### Построение карты в ручном режиме

[![LaserScan](https://img.youtube.com/vi/CHcgCHSs_-0/0.jpg)](https://youtu.be/CHcgCHSs_-0)

### Автономное движение по карте

[![LaserScan](https://img.youtube.com/vi/ocD7KzcdPOI/0.jpg)](https://youtu.be/ocD7KzcdPOI)

## Сборка MEPhI_ROS2_drone

- Сборка конструкции робота подробно описана в [`andino_hardware`](./andino_hardware/)
- Сборка электрической схемы подробно описана в [`schematic`](./schematic/)

## Установка Ubuntu 22.04 на Raspberry Pi

Для работы MEPhI_ROS2_drone на Raspberry Pi 4B необходимо установить и настроить Ubuntu 22.04 LTS.

### Шаг 1: Загрузка и запись образа
1. Перейдите на сайт [https://ubuntu.com/download/raspberry-pi](https://ubuntu.com/download/raspberry-pi)
2. Выберете руководство по установке Ubuntu Desktop

### Шаг 2: Начальная настройка
1. Вставьте карту MicroSD в Raspberry Pi и подключите кабель питания USB-C 
2. Подключите монитор и клавиатуру
3. Проследуйте указаниям на экране
4. Запустите терминал и введите
```
sudo apt update && sudo apt upgrade -y
```
5. Проверьте версию Ubuntu (ожидаемый вывод: `Ubuntu 22.04 LTS`):
```
lsb_release -a
```
6. Проверьте подключение к интернету:
```
ping google.com
```

## Настройка USB портов

Назначьте фиксированные имена USB-портам для стабильного распознавания устройств в ROS2.

1. Подключите Arduino UNO R3 и RPLIDAR A1 к Raspberry Pi
2. Просмотрите подключенные USB-устройства:
```
ls -l /dev/ttyUSB*
```
Пример вывода:
```
crw-rw---- 1 root dialout 188, 0 Apr 06 03:10 /dev/ttyUSB0
crw-rw---- 1 root dialout 188, 1 Apr 06 03:10 /dev/ttyUSB1
```
3. Определите устройства:
 - Отключите RPLIDAR и снова выполните ls -l /dev/ttyUSB*. Исчезнувшее устройство — RPLIDAR
 - Повторите для Arduino
 - Пример: `/dev/ttyUSB0 = Arduino`, `/dev/ttyUSB1 = RPLIDAR`

4. Получите идентификаторы устройств:
```
udevadm info --name=/dev/ttyUSB0 --attribute-walk | grep -i "serial\|vendor"
```
Пример для Arduino:
```
ATTRS{serial}=="A1234567"
ATTRS{vendor}=="Arduino"
```
Пример для RPLIDAR:
```
ATTRS{serial}=="B7890123"
ATTRS{vendor}=="SLAMTEC"
```
5. Создайте правила udev:
 - Отредактируйте файл правил:
 ```
 sudo nano /etc/udev/rules.d/99-usb-serial.rules
 ```
 - Добавьте (замените serial на ваши значения):
```
SUBSYSTEM=="tty", ATTRS{serial}=="A1234567", SYMLINK+="ttyUSB_ARDUINO"
SUBSYSTEM=="tty", ATTRS{serial}=="B7890123", SYMLINK+="ttyUSB_LIDAR"
```
- Сохраните (Ctrl+O, Enter, Ctrl+X)

6. Перезагрузите правила:
```
sudo udevadm control --reload-rules
sudo udevadm trigger
```
7. Проверьте новые имена:
```
ls -l /dev/ttyUSB*
```
Ожидаемый вывод:
```
lrwxrwxrwx 1 root root 7 Apr 06 03:15 /dev/ttyUSB_ARDUINO -> ttyUSB0
lrwxrwxrwx 1 root root 7 Apr 06 03:15 /dev/ttyUSB_LIDAR -> ttyUSB1
```

## Прошивка отладочной платы Arduino UNO R3

Следуйте руководству в [`MEPhI_ROS2_drone_firmware`](./andino_firmware)

## Установка ROS2 Humble

### Шаг 1: Установка зависимостей
1. Настройте локализацию:
```
sudo apt update && sudo apt install -y locales
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8
```
2. Добавьте репозиторий ROS2:
```
sudo apt install -y software-properties-common
sudo add-apt-repository universe
sudo apt update && sudo apt install -y curl gnupg lsb-release
sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null
```
### Шаг 2: Установка ROS2
1. Установите ROS2 Humble Desktop:
```
sudo apt update
sudo apt install -y ros-humble-desktop
```
2. Установите инструменты разработки:
```
sudo apt install -y python3-colcon-common-extensions python3-rosdep python3-vcstool
```
3. Инициализируйте rosdep:
```
sudo rosdep init
rosdep update
```
4. Настройте окружение:
```
echo "source /opt/ros/humble/setup.bash" >> ~/.bashrc
source ~/.bashrc
```

## Сборка рабочего пространства MEPhI_ROS2_drone
### Шаг 1: Клонирование репозитория
1. Создайте рабочее пространство:
```
mkdir -p ~/MEPhI_ROS2_drone_ws/src
cd ~/MEPhI_ROS2_drone_ws/src
```
2. Склонируйте репозиторий:
```
git clone -b humble https://github.com/Muhamedli/MEPhI_ROS2_drone.git
```
### Шаг 2: Установка зависимостей
1. Установите зависимости ROS:
```
cd ~/MEPhI_ROS2_drone_ws
rosdep install --from-paths src --ignore-src -r -y
```
### Шаг 3: Сборка
1. Соберите проект:
```
colcon build
```
2. Подгрузите окружение:
```
echo "source ~/MEPhI_ROS2_drone_ws/install/setup.bash" >> ~/.bashrc
source ~/MEPhI_ROS2_drone_ws/install/setup.bash
```

## Настройка и запуск SLAM
SLAM позволяет роботу строить карту неизвестной среды и одновременно определять свое местоположение. В этом разделе используется пакет MEPhI_ROS2_drone_slam с алгоритмом Cartographer.

### Шаг 1: Запуск базовых нод
1. Запустите базовые ноды робота:
```
ros2 launch andino_bringup andino_robot.launch.py
```
Это активирует ноды для работы с двигателями и лидаром.

2. Проверьте доступные топики:
```
ros2 topic list
```
Ожидаемые топики:
- `/odom`: данные одометрии
- `/scan`: данные лидара

### Шаг 2: Запуск SLAM
1. Запустите SLAM:
```
ros2 launch andino_slam slam_toolbox_online_async.launch.py
```
2. Запустите rviz:
```
rviz2
```
3. Управляйте роботом для построения карты:
 - В новом терминале запустите телеуправление:
 ```
ros2 launch andino_bringup teleop_keyboard.launch.py
 ```
 - Используйте клавиши (исполнительные клавиши будут отображены на мониторе) для медленного перемещения робота по помещению

 ### Шаг 3: Сохранение карты
 1. Сохраните созданную карту:
 ```
 ros2 run nav2_map_server map_saver_cli -f ~/andino_map
 ```
 - Карта сохранится в файлах `andino_map.pgm` и `andino_map.yaml` в домашней директории
 2. Остановите SLAM:
 - Нажмите Ctrl+C в терминале с SLAM

 ### Шаг 4: Повторное использование карты
 1. Запустите навигацию с сохраненной картой:
 ```
 ros2 launch andino_navigation bringup.launch.py map:=~/andino_map.yaml
 ```
 2. Установите начальную позицию в RViz:
 - Используйте инструмент `2D Pose Estimate` в RViz
 - Щелкните на карте, чтобы указать приблизительное положение робота

 ## Устранение неполадок
 1. Лидар не работает:
 - Проверьте порт:
 ```
 ls -l /dev/ttyUSB_LIDAR
 ```
 - Убедитесь, что RPLIDAR подключен и питается
 2. Двигатели не реагируют:
 - Проверьте прошивку Arduino: отправьте `o 100 100` через Монитор порта
 - Убедитесь, что порт `/dev/ttyUSB_ARDUINO` доступен
 3. Карта не строится:
 - Проверьте топик /scan:
 ```
 ros2 topic echo /scan
 ```
 - Убедитесь, что робот движется и лидар собирает данные
 4. RViz не открывается:
 - Убедитесь, что RViz установлен:
 ```
 sudo apt install -y ros-humble-rviz2
 ```