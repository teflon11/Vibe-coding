#!/bin/bash

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (используйте sudo)"
  exit 1
fi

# 2. НАСТРОЙКИ
# (Явно указан ::1 - технически второй адрес подсети, так как :: является адресом самой сети)
# ВНИМАНИЕ: Убедитесь, что этот адрес совпадает с выданным вам в панели VDSina!
IPV6_ADDR="2a0d:8480:0:7e8::1/64"
IPV6_GATEWAY="fe80::1"
HOSTNAME="host-2a0d-8480-0-7e8.hosted-by-vdsina.ru"

# 3. Определение основного сетевого интерфейса
INTERFACE=$(ip -4 route show default | awk '/default/ {print $5}' | head -n 1)
if [ -z "$INTERFACE" ] || ! ip link show "$INTERFACE" &>/dev/null; then
    INTERFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp)' | head -n 1)
fi
if [ -z "$INTERFACE" ]; then
    INTERFACE="eth0"
fi

echo "=========================================================="
echo "🔍 Сетевой интерфейс: $INTERFACE"
echo "📝 IPv6 адрес: $IPV6_ADDR"
echo "🚪 Шлюз: $IPV6_GATEWAY"
echo "=========================================================="

# 4. Проверка: включен ли IPv6 в ядре системы
DISABLED_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
DISABLED_DEF=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)
DISABLED_INT=$(sysctl -n net.ipv6.conf.$INTERFACE.disable_ipv6 2>/dev/null)

# Страховка: если интерфейс ещё не поднят или имя нестандартное, sysctl может вернуть пустую строку
if [ -z "$DISABLED_INT" ]; then DISABLED_INT=0; fi

# Проверяем, не отключен ли IPv6 на уровне загрузки ядра (критическая ошибка, требующая перезагрузки)
if grep -q "ipv6.disable=1" /proc/cmdline 2>/dev/null; then
    echo "❌ КРИТИЧЕСКАЯ ОШИБКА: IPv6 отключен на уровне параметров загрузки ядра (ipv6.disable=1)."
    echo "Скрипт не может это исправить без перезагрузки. Вам нужно:"
    echo "1. Открыть /etc/default/grub и удалить ipv6.disable=1 из GRUB_CMDLINE_LINUX"
    echo "2. Выполнить: sudo update-grub"
    echo "3. Перезагрузить сервер: sudo reboot"
    echo "После перезагрузки запустите этот скрипт снова."
    exit 1
fi

if [ "$DISABLED_ALL" = "1" ] || [ "$DISABLED_DEF" = "1" ] || [ "$DISABLED_INT" = "1" ]; then
    echo "⚠️ Обнаружено, что IPv6 отключен в sysctl. Включаю IPv6..."
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0
    sysctl -w net.ipv6.conf.$INTERFACE.disable_ipv6=0
    
    # Безопасное сохранение настроек через sysctl.d (не трогая основной sysctl.conf)
    cat <<EOF > /etc/sysctl.d/99-ipv6-enable.conf
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.$INTERFACE.disable_ipv6 = 0
EOF
    echo "✅ Настройки IPv6 в ядре включены и сохранены в /etc/sysctl.d/99-ipv6-enable.conf"
fi

# 5. Резервная копия
BACKUP_FILE="/etc/netplan/99-backup-$(date +%F-%H%M%S).yaml"
cp /etc/netplan/*.yaml "$BACKUP_FILE" 2>/dev/null || true
echo "💾 Резервная копия создана: $BACKUP_FILE"

# 6. Создание конфигурации Netplan
NETPLAN_FILE="/etc/netplan/60-ipv6-vdsina.yaml"
cat <<EOF > "$NETPLAN_FILE"
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE:
      dhcp4: true
      dhcp6: false
      addresses:
        - "$IPV6_ADDR"
      routes:
        - to: "::/0"
          via: "$IPV6_GATEWAY"
          on-link: true
EOF

echo "⚙️ Конфигурация записана в $NETPLAN_FILE"

# 7. Проверка синтаксиса YAML перед применением (защита от опечаток)
echo "🔍 Проверка синтаксиса Netplan (netplan generate)..."
if ! netplan generate; then
    echo "❌ Ошибка синтаксиса в файле $NETPLAN_FILE! Применение отменено."
    echo "Проверьте YAML отступы и корректность IP-адреса."
    exit 1
fi

# 8. БЕЗОПАСНОЕ применение (строгий таймаут 60 сек)
echo ""
echo "=========================================================="
echo "🔄 СЕЙЧАС БУДЕТ ВЫПОЛНЕН 'netplan try --timeout 60'"
echo "⏳ У вас есть 60 секунд."
echo "💡 РЕКОМЕНДАЦИЯ: Откройте ВТОРОЕ окно терминала и попробуйте подключиться по SSH."
echo "   Если подключение успешно, вернитесь сюда и нажмите Enter для сохранения."
echo "   Если ничего не нажать, настройки автоматически откатятся через 60 секунд."
echo "=========================================================="

if netplan try --timeout 60; then
    echo ""
    echo "✅ Настройки сети успешно применены и подтверждены!"
    
    # 9. Установка hostname (перенесена сюда для атомарности: только если сеть работает)
    hostnamectl set-hostname "$HOSTNAME"
    if ! grep -qE "^127\.0\.1\.1[[:space:]]+$HOSTNAME([[:space:]]|$)" /etc/hosts; then
        echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
        echo "🏷️ Hostname установлен и добавлен в /etc/hosts"
    else
        echo "🏷️ Hostname установлен (запись в /etc/hosts уже существует)"
    fi

    # 10. Проверка связи
    echo "🔍 Проверка связи (ping IPv6)..."
    sleep 2
    if ping -6 -c 3 2001:4860:4860::8888 > /dev/null 2>&1; then
        echo "🎉 УСПЕХ! IPv6 работает корректно."
        echo "Ваш назначенный глобальный IPv6 адрес:"
        ip -6 addr show dev "$INTERFACE" | grep "inet6.*scope global"
    else
        echo "❌ Пинг не проходит. Проверьте вывод: ip -6 route"
    fi
else
    echo ""
    echo "❌ Настройки автоматически отменены (откат) из-за ошибки или истечения 60 секунд."
    echo "🛡️ Ваш сервер остался в исходном безопасном состоянии. IPv4 (SSH) не пострадал."
fi
