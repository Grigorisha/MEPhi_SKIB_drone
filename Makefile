# =============================================================================
# Raspberry Pi Management Makefile
# =============================================================================

.DEFAULT_GOAL := help

.PHONY: \
	gui-on gui-off gui-status \
	build clean \
	deps deps-skip-classic rosdep-check \
	ports udev-install udev-check \
	esp-check \
	bringup lidar-watchdog teleop-keyboard teleop-joystick \
	up down attach status \
	slam rviz \
	nav nav-slam \
	sim sim-classic \
	help

ROS_DISTRO ?= humble
ROS_SETUP  ?= /opt/ros/$(ROS_DISTRO)/setup.bash
WS_SETUP   ?= $(CURDIR)/install/setup.bash

# Явно, не полагаясь на .bashrc: цели вызываются и по SSH неинтерактивно,
# и через sudo (который по умолчанию сбрасывает окружение) — в обоих случаях
# .bashrc не подхватывается, а рассинхрон домена — самая частая причина
# "ничего не видно" между роботом и студенческими ВМ.
ROS_DOMAIN_ID ?= 42

COLCON_ARGS ?= --event-handlers console_direct+ --symlink-install

# На Raspberry Pi (jammy/arm64) classic gazebo deb-пакеты часто недоступны.
SKIP_CLASSIC_KEYS ?= gazebo_ros_pkgs gazebo_ros gazebo_ros2_control

# Путь к карте для навигации (по умолчанию из README).
MAP ?= $(HOME)/andino_map.yaml
LIDAR_PORT ?= /dev/ttyUSB_LIDAR
INCLUDE_CAMERA ?= False
INCLUDE_RPLIDAR ?= False
STACK_SESSION ?= andino_stack
ESP_PORT ?= /dev/ttyUSB_MOTOR
ESP_BAUD ?= 57600

UDEV_RULES_SRC ?= $(CURDIR)/udev/99-mephi-ros2-drone-usb-serial.rules
UDEV_RULES_DST ?= /etc/udev/rules.d/99-mephi-ros2-drone-usb-serial.rules

## Включить графический менеджер (gdm3)
gui-on:
	sudo systemctl enable gdm3
	sudo systemctl start gdm3
	@echo "Графический менеджер включён"

## Отключить графический менеджер (gdm3) — экономия ~200-300MB RAM
gui-off:
	sudo systemctl stop gdm3
	sudo systemctl disable gdm3
	@echo "Графический менеджер отключён"

## Проверить статус графического менеджера
gui-status:
	@systemctl is-active gdm3 2>/dev/null && echo "gdm3: РАБОТАЕТ" || echo "gdm3: ОСТАНОВЛЕН"
	@systemctl is-enabled gdm3 2>/dev/null && echo "Автозагрузка: ВКЛ" || echo "Автозагрузка: ВЫКЛ"

## Собрать workspace (colcon)
build:
	@bash -lc 'set -eo pipefail; \
		cd "$(CURDIR)"; \
		source "$(ROS_SETUP)"; \
		colcon build $(COLCON_ARGS)'

## Очистить артефакты сборки
clean:
	@bash -lc 'set -eo pipefail; \
		cd "$(CURDIR)"; \
		rm -rf build install log'

## Установить зависимости через rosdep (может требовать sudo/apt)
deps:
	@bash -lc 'set -eo pipefail; \
		cd "$(CURDIR)"; \
		source "$(ROS_SETUP)"; \
		rosdep update; \
		rosdep install --from-paths . --ignore-src -r -y'

## Установить зависимости через rosdep, пропустив Classic Gazebo ключи (рекомендовано для jammy/arm64)
deps-skip-classic:
	@bash -lc 'set -eo pipefail; \
		cd "$(CURDIR)"; \
		source "$(ROS_SETUP)"; \
		rosdep update; \
		rosdep install --from-paths . --ignore-src -r -y --skip-keys "$(SKIP_CLASSIC_KEYS)"'

## Проверить, каких rosdep зависимостей не хватает
rosdep-check:
	@bash -lc 'set -eo pipefail; \
		cd "$(CURDIR)"; \
		source "$(ROS_SETUP)"; \
		rosdep check --from-paths . --ignore-src || true'

## Показать serial устройства и подсказки по портам
ports:
	@bash -lc 'set -eo pipefail; \
		echo "ttyUSB/ttyACM:"; ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true; \
		echo ""; \
		echo "udev свойства:"; \
		for d in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyACM0; do \
		  [ -e "$$d" ] || continue; \
		  echo "=== $$d"; \
		  udevadm info --name="$$d" --query=property | egrep "^(ID_VENDOR_ID|ID_MODEL_ID|ID_VENDOR=|ID_MODEL=|ID_SERIAL=|ID_SERIAL_SHORT=|DEVPATH=|DEVNAME=)" || true; \
		done; \
		echo ""; \
		echo "symlinks:"; \
		ls -l /dev/ttyUSB_LIDAR /dev/ttyUSB_MOTOR /dev/ttyUSB_ARDUINO 2>/dev/null || true'

## Установить udev правила для стабильных имён /dev/ttyUSB_LIDAR и /dev/ttyUSB_MOTOR
udev-install:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(UDEV_RULES_SRC)" ]; then echo "Нет файла правил: $(UDEV_RULES_SRC)"; exit 1; fi; \
		echo "Установка udev правил -> $(UDEV_RULES_DST)"; \
		sudo install -m 0644 "$(UDEV_RULES_SRC)" "$(UDEV_RULES_DST)"; \
		sudo udevadm control --reload-rules; \
		sudo udevadm trigger; \
		echo "Готово. Переподключи Motor controller и LIDAR (USB) и проверь: ls -l /dev/ttyUSB_LIDAR /dev/ttyUSB_MOTOR"'

## Проверить, появились ли symlink'и после udev правил
udev-check:
	@bash -lc 'set -eo pipefail; \
		ls -l /dev/ttyUSB_LIDAR /dev/ttyUSB_MOTOR /dev/ttyUSB_ARDUINO 2>/dev/null || true; \
		echo ""; \
		echo "Если symlink'ов нет — переподключи устройства и запусти: make udev-install"'

## Проверить UART ответы ESP (help/status/e/m/r)
esp-check:
	@bash -lc 'set -eo pipefail; \
		python3 mephi_hw_tests/esp_uart_check.py --port "$(ESP_PORT)" --baud "$(ESP_BAUD)"'

## Запуск робота (железо): description + control + (опционально) lidar/camera
bringup:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_bringup andino_robot.launch.py include_camera:="$(INCLUDE_CAMERA)" include_rplidar:="$(INCLUDE_RPLIDAR)" rplidar_serial_port:="$(LIDAR_PORT)"'

## Наблюдатель за лидаром: автоматически переподключает USB и перезапускает
## ноду, если /scan замолкает (нужен root — просит sudo). Запускать вместо
## include_rplidar в bringup: make bringup INCLUDE_RPLIDAR=False + это отдельно.
lidar-watchdog:
	@sudo bash mephi_hw_tests/lidar_watchdog.sh

## Телеуправление с клавиатуры
teleop-keyboard:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r __node:=teleop_twist_keyboard_node'

## Телеуправление с джойстика
teleop-joystick:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_bringup teleop_joystick.launch.py'

## Поднять весь стек в tmux: bringup + keyboard teleop
up:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		if ! command -v tmux >/dev/null 2>&1; then \
		  echo "tmux не установлен. Установи: sudo apt install tmux"; exit 1; \
		fi; \
		if tmux has-session -t "$(STACK_SESSION)" 2>/dev/null; then \
		  echo "Сессия $(STACK_SESSION) уже запущена. Подключись: make attach"; exit 0; \
		fi; \
		tmux new-session -d -s "$(STACK_SESSION)" -n bringup "bash -lc '\''export ROS_DOMAIN_ID=\"$(ROS_DOMAIN_ID)\"; source \"$(ROS_SETUP)\"; source \"$(WS_SETUP)\"; ros2 launch andino_bringup andino_robot.launch.py include_camera:=\"$(INCLUDE_CAMERA)\" include_rplidar:=\"$(INCLUDE_RPLIDAR)\" rplidar_serial_port:=\"$(LIDAR_PORT)\"'\''"; \
		tmux split-window -t "$(STACK_SESSION):bringup" -v "bash -lc '\''sleep 5; export ROS_DOMAIN_ID=\"$(ROS_DOMAIN_ID)\"; source \"$(ROS_SETUP)\"; source \"$(WS_SETUP)\"; ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r __node:=teleop_twist_keyboard_node'\''"; \
		tmux select-pane -t "$(STACK_SESSION):bringup.1"; \
		echo "Стек поднят в tmux-сессии: $(STACK_SESSION)"; \
		echo "Подключиться: make attach"; \
		echo "Остановить всё: make down"'

## Подключиться к tmux-сессии стека
attach:
	@bash -lc 'set -eo pipefail; \
		tmux attach -t "$(STACK_SESSION)"'

## Статус tmux-сессии стека
status:
	@bash -lc 'set -eo pipefail; \
		if tmux has-session -t "$(STACK_SESSION)" 2>/dev/null; then \
		  echo "Сессия $(STACK_SESSION) запущена"; \
		  tmux list-panes -t "$(STACK_SESSION):bringup" -F "pane #{pane_index}: #{pane_current_command}"; \
		else \
		  echo "Сессия $(STACK_SESSION) не запущена"; \
		fi'

## Остановить весь стек (убить tmux-сессию)
down:
	@bash -lc 'set -eo pipefail; \
		if tmux has-session -t "$(STACK_SESSION)" 2>/dev/null; then \
		  tmux kill-session -t "$(STACK_SESSION)"; \
		  echo "Сессия $(STACK_SESSION) остановлена"; \
		else \
		  echo "Сессия $(STACK_SESSION) не найдена"; \
		fi'

## Запуск SLAM (slam_toolbox online async)
slam:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_slam slam_toolbox_online_async.launch.py'

## Запуск RViz (bringup)
rviz:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_bringup rviz.launch.py'

## Навигация Nav2 по карте (map:=...)
nav:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_navigation bringup.launch.py map:="$(MAP)"'

## Навигация Nav2 в режиме SLAM (slam:=True)
nav-slam:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_navigation bringup.launch.py slam:=True'

## Симуляция + навигация (andino_apps). Требует Gazebo Classic зависимости (на jammy/arm64 может отсутствовать)
sim:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_apps andino_simulation_navigation.launch.py'

## Только симуляция одного робота (andino_gz_classic). Требует Gazebo Classic зависимости.
sim-classic:
	@bash -lc 'set -eo pipefail; \
		if [ ! -f "$(WS_SETUP)" ]; then echo "Нет $(WS_SETUP). Сначала сделай: make build"; exit 1; fi; \
		export ROS_DOMAIN_ID="$(ROS_DOMAIN_ID)"; \
		source "$(ROS_SETUP)"; source "$(WS_SETUP)"; \
		ros2 launch andino_gz_classic andino_one_robot.launch.py'

## Показать доступные команды
help:
	@echo "Доступные команды:"
	@echo "  make gui-on      — включить графический менеджер"
	@echo "  make gui-off     — отключить графический менеджер (экономия RAM)"
	@echo "  make gui-status  — проверить статус графического менеджера"
	@echo ""
	@echo "  make deps                 — поставить зависимости (rosdep)"
	@echo "  make deps-skip-classic     — deps без Classic Gazebo ключей (для jammy/arm64)"
	@echo "  make rosdep-check          — показать, чего не хватает"
	@echo "  make build                — собрать workspace (colcon)"
	@echo "  make clean                — удалить build/install/log"
	@echo ""
	@echo "  make bringup              — запуск робота (железо)"
	@echo "    LIDAR_PORT=/dev/ttyUSB_LIDAR (можно переопределить)"
	@echo "    INCLUDE_CAMERA=True|False, INCLUDE_RPLIDAR=True|False"
	@echo "  make lidar-watchdog        — лидар отдельно, с авто-переподключением при обрыве /scan (нужен sudo)"
	@echo "  make up                   — поднять весь стек в tmux (bringup + keyboard teleop)"
	@echo "  make attach               — подключиться к tmux-сессии стека"
	@echo "  make status               — показать статус tmux-сессии стека"
	@echo "  make down                 — остановить весь стек (tmux kill-session)"
	@echo "  make ports                — показать serial устройства"
	@echo "  make udev-install          — поставить udev правила (нужен sudo)"
	@echo "  make udev-check            — проверить /dev/ttyUSB_LIDAR и /dev/ttyUSB_MOTOR"
	@echo "  make esp-check             — проверить UART ответы ESP перед bringup"
	@echo "    ESP_PORT=$(ESP_PORT), ESP_BAUD=$(ESP_BAUD)"
	@echo "  make teleop-keyboard      — телеуправление с клавиатуры"
	@echo "  make teleop-joystick      — телеуправление с джойстика"
	@echo "  make slam                 — SLAM (slam_toolbox)"
	@echo "  make rviz                 — RViz"
	@echo "  make nav MAP=~/andino_map.yaml — Nav2 по карте"
	@echo "  make nav-slam             — Nav2 в режиме SLAM"
	@echo "  make sim                  — симуляция+навигация (classic, если доступно)"
	@echo "  make sim-classic          — симуляция одного робота (classic, если доступно)"
	@echo "  make help        — показать эту справку"
