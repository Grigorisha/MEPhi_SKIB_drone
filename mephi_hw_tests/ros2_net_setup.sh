#!/bin/bash
# =============================================================================
# Настройка и диагностика ROS 2 сети для MEPhI_ROS2_drone (Vindicator2).
#
# ЗАЧЕМ ЭТОТ СКРИПТ
#
# 22.08.2026 полдня ушло на поиск причины, по которой внешний ноутбук не видел
# НИ ОДНОЙ ноды робота. Виноват был ufw на самом Pi: он молча резал весь
# DDS-трафик. Коварство в том, что признаки исправной сети при этом налицо —
# ping идёт, SSH работает, робот сам себя видит прекрасно. Пусто только у
# внешней машины, и никакой ошибки нигде не появляется.
#
# Правило ufw привязано к подсети. На выставке подсеть будет другой, и всё
# сломается снова — поэтому здесь автоопределение, а не зашитый адрес.
#
# ИСПОЛЬЗОВАНИЕ
#   bash ros2_net_setup.sh check    # только диагностика, sudo не нужен
#   bash ros2_net_setup.sh allow    # открыть DDS для текущей подсети (спросит пароль)
#   bash ros2_net_setup.sh clean    # убрать старые правила от прежних подсетей
#
# Через Makefile:  make net-check | make net-allow
# =============================================================================

set -eo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ОШИБКА]${NC} $1"; }
head_(){ echo -e "\n${BOLD}$1${NC}"; }

ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"

# --- Определяем, через какой интерфейс робот реально смотрит в сеть ----------
detect_net() {
  IFACE="$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' || true)"
  [ -z "$IFACE" ] && IFACE="$(ip -o -4 addr show scope global | awk 'NR==1{print $2}')"
  IPADDR="$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
  CIDR="$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)"
  # сетевой адрес подсети: 10.1.18.175/24 -> 10.1.18.0/24
  SUBNET="$(python3 -c "import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))" "$CIDR" 2>/dev/null || true)"
  SSID="$(iwgetid -r 2>/dev/null || echo '-')"
}

# --- Порты DDS для домена: 7400 + 250*domain --------------------------------
dds_ports() {
  local base=$((7400 + 250 * ROS_DOMAIN_ID))
  echo "$base (multicast discovery), $((base+1)) (multicast user), $((base+10))+ (unicast)"
}

# =============================================================================
cmd_check() {
  detect_net
  head_ "1. Сеть робота"
  echo "   Интерфейс:     $IFACE"
  echo "   Wi-Fi SSID:    $SSID"
  echo "   IP робота:     $IPADDR"
  echo "   Подсеть:       ${SUBNET:-не определена}"
  echo "   ROS_DOMAIN_ID: $ROS_DOMAIN_ID"
  echo "   Порты DDS:     $(dds_ports)"

  head_ "2. Firewall — главный подозреваемый"
  local ufw_state
  ufw_state="$(systemctl is-active ufw 2>/dev/null || echo unknown)"
  if [ "$ufw_state" != "active" ]; then
    ok "ufw не запущен — трафик он не режет"
  else
    echo "   ufw активен — значит он и решает, дойдёт ли DDS снаружи."
    if sudo -n ufw status 2>/dev/null | grep -q "${SUBNET%%/*}"; then
      ok "Правило для подсети ${SUBNET} на месте"
    elif sudo -n true 2>/dev/null; then
      err "Правила для ${SUBNET} НЕТ — внешние машины робота не увидят"
      echo "   Лечится: make net-allow"
    else
      warn "Прочитать правила без пароля нельзя. Проверьте сами:"
      echo "      sudo ufw status | grep ${SUBNET%%/*}"
      echo "   Если строки с ${SUBNET%%/*} нет — ставьте правило: make net-allow"
    fi
  fi

  head_ "3. Слушает ли DDS"
  if ss -ulnp 2>/dev/null | grep -q ":$((7400 + 250 * ROS_DOMAIN_ID))"; then
    ok "Порт $((7400 + 250 * ROS_DOMAIN_ID)) занят — ноды в домене $ROS_DOMAIN_ID работают"
  else
    warn "Порт $((7400 + 250 * ROS_DOMAIN_ID)) не слушается. Робот запущен? systemctl status mephi-bringup"
  fi

  head_ "4. Ноды, видимые с самого робота"
  source /opt/ros/humble/setup.bash 2>/dev/null || true
  if command -v ros2 >/dev/null 2>&1; then
    export ROS_DOMAIN_ID
    local n
    n="$(timeout 12 ros2 node list 2>/dev/null | grep -c . || echo 0)"
    if [ "$n" -gt 0 ]; then ok "Видно нод: $n"; else warn "Ноды не видны даже локально — робот не запущен"; fi
  else
    warn "ros2 не найден — нет /opt/ros/humble?"
  fi

  head_ "5. Что проверить на внешней машине"
  cat <<EOF
   export ROS_DOMAIN_ID=$ROS_DOMAIN_ID
   ros2 node list                 # должны появиться ноды робота
   ping $IPADDR   # если ping идёт, а нод нет — это firewall
EOF
}

# =============================================================================
cmd_allow() {
  detect_net
  if [ -z "$SUBNET" ]; then err "Не удалось определить подсеть"; exit 1; fi

  head_ "Открываю DDS для подсети $SUBNET (интерфейс $IFACE, SSID $SSID)"
  echo "Разрешается только UDP и только из локальной подсети."
  echo

  # Почему не список портов: FastDDS раздаёт user-трафик по ДИНАМИЧЕСКИМ портам,
  # которые меняются при каждом рестарте нод. Фиксированы лишь discovery-порты,
  # поэтому правило по портам работать не будет.
  sudo ufw allow from "$SUBNET" proto udp comment "ROS2 DDS domain $ROS_DOMAIN_ID"
  sudo ufw reload
  ok "Правило добавлено"
  echo
  sudo ufw status | grep -E "^Status|$(echo "$SUBNET" | cut -d/ -f1)" || true
  echo
  echo "Теперь на внешней машине: export ROS_DOMAIN_ID=$ROS_DOMAIN_ID && ros2 node list"
}

# =============================================================================
cmd_clean() {
  head_ "Правила ufw, относящиеся к ROS2"
  sudo ufw status numbered | grep -i "ROS2 DDS" || { echo "   таких правил нет"; return 0; }
  echo
  echo "Удалить лишнее (например, от старой сети):"
  echo "   sudo ufw status numbered      # посмотреть номера"
  echo "   sudo ufw delete <номер>       # удалять с БОЛЬШЕГО номера к меньшему,"
  echo "                                 # иначе нумерация съедет"
}

case "${1:-check}" in
  check) cmd_check ;;
  allow) cmd_allow ;;
  clean) cmd_clean ;;
  *) echo "Использование: $0 {check|allow|clean}"; exit 1 ;;
esac
