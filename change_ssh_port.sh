#!/usr/bin/env bash
#
# change_ssh_port.sh — безопасный просмотр и смена порта SSH в Ubuntu 24.04 LTS
# Требует прав root.
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "❌ Скрипт нужно запускать от имени root (или через sudo)."
    exit 1
fi

# Проверка наличия утилиты ss (пакет iproute2)
if ! command -v ss >/dev/null 2>&1; then
    echo "❌ Утилита 'ss' не найдена (пакет iproute2). Установите: apt install iproute2"
    exit 1
fi

# Глобальные переменные, объявленные ДО функции rollback для безопасности
CONFIG_FILE="/etc/ssh/sshd_config"
TIMESTAMP=""
DROPIN_FILES=()
SOCKET_WAS_ENABLED="false"

# ─────────────────────────────────────────────────────────────
# Функция полного отката изменений (вызывается при любой ошибке)
# ─────────────────────────────────────────────────────────────
rollback() {
    echo "❌ Выполняется полный откат изменений..."
    
    local main_bak=""
    if [[ -n "${CONFIG_FILE:-}" && -n "${TIMESTAMP:-}" ]]; then
        main_bak="${CONFIG_FILE}.bak.${TIMESTAMP}"
        if [[ -f "$main_bak" ]]; then
            cp -a "$main_bak" "$CONFIG_FILE"
            echo "   ↪ Восстановлен: $CONFIG_FILE"
        fi
    fi
    
    local bak_file=""
    for f in "${DROPIN_FILES[@]:-}"; do
        [[ -z "$f" ]] && continue
        bak_file="${f}.bak.${TIMESTAMP}"
        if [[ -f "$bak_file" ]]; then
            cp -a "$bak_file" "$f"
            echo "   ↪ Восстановлен: $f"
        fi
    done
    
    # Безопасный откат состояния socket/service
    if [[ "${SOCKET_WAS_ENABLED:-}" == "true" ]]; then
        systemctl enable --now ssh.socket 2>/dev/null || true
        echo "   ↪ Восстановлен: ssh.socket"
    fi
    
    echo "✅ Откат завершён. Проверьте состояние службы: systemctl status ssh"
}

# ─────────────────────────────────────────────────────────────
# Функция: получить текущий порт SSH
# ─────────────────────────────────────────────────────────────
get_current_ssh_port() {
    local port=""
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        port=$(grep -hE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
               | tail -n1 | awk '{print $2}' || true)
    fi
    if [[ -z "$port" && -f /etc/ssh/sshd_config ]]; then
        port=$(grep -hE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null \
               | tail -n1 | awk '{print $2}' || true)
    fi
    echo "${port:-22}"
}

# ─────────────────────────────────────────────────────────────
# Функция: проверить, свободен ли порт
# ─────────────────────────────────────────────────────────────
is_port_free() {
    local p=$1
    if ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
# Основной сценарий
# ─────────────────────────────────────────────────────────────
CURRENT_PORT=$(get_current_ssh_port)
echo "=============================================="
echo " Текущий порт SSH: $CURRENT_PORT"
echo "=============================================="
echo

read -rp "Заменить порт? (1 — да, 0 — выход): " choice || { echo "Отмена."; exit 0; }

case "$choice" in
    1) ;;
    0)
        echo "Выход."
        exit 0
        ;;
    *)
        echo "Неверный выбор. Выход."
        exit 1
        ;;
esac

while :; do
    read -rp "Введите новый порт SSH (1-65535): " NEW_PORT || { echo "Отмена."; exit 0; }

    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && (( NEW_PORT >= 1 && NEW_PORT <= 65535 )); then
        :
    else
        echo "❌ Порт должен быть числом от 1 до 65535. Попробуйте снова."
        continue
    fi

    if (( NEW_PORT == CURRENT_PORT )); then
        echo "⚠️  Это текущий порт. Введите другой."
        continue
    fi

    if ! is_port_free "$NEW_PORT"; then
        echo "❌ Порт $NEW_PORT уже занят другим сервисом. Выберите другой."
        continue
    fi

    break
done

# Запоминаем состояние socket ДО любых изменений
if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
    SOCKET_WAS_ENABLED="true"
fi

TIMESTAMP=$(date +%s)

# Сохраняем список drop-in файлов ДО модификации для гарантированно корректного отката
if [[ -d /etc/ssh/sshd_config.d ]]; then
    shopt -s nullglob
    DROPIN_FILES=(/etc/ssh/sshd_config.d/*.conf)
    shopt -u nullglob
fi

echo "→ Создание резервных копий..."
cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.${TIMESTAMP}"

for f in "${DROPIN_FILES[@]:-}"; do
    [[ -z "$f" ]] && continue
    cp -a "$f" "${f}.bak.${TIMESTAMP}"
done

# Очистка старых комментариев перед вставкой (идемпотентность при повторных запусках)
echo "→ Очистка старых пометок скрипта..."
files_to_clean=("$CONFIG_FILE")
for f in "${DROPIN_FILES[@]:-}"; do
    [[ -z "$f" ]] && continue
    files_to_clean+=("$f")
done
sed -i -E '/^#[[:space:]]*Port \(отключено скриптом\)/d' "${files_to_clean[@]}"

echo "→ Обновление конфигурации..."
# Комментируем старые Port в drop-in файлах
for f in "${DROPIN_FILES[@]:-}"; do
    [[ -z "$f" ]] && continue
    sed -i -E 's/^(\s*)Port\s+[0-9]+/\1# Port (отключено скриптом)/' "$f"
done

# Комментируем старый Port в основном конфиге и добавляем новый в самое начало
sed -i -E 's/^(\s*)Port\s+[0-9]+/\1# Port (отключено скриптом)/' "$CONFIG_FILE"
sed -i "1i Port $NEW_PORT" "$CONFIG_FILE"

echo "→ Проверка синтаксиса конфигурации sshd..."
if ! sshd -t; then
    echo "❌ Ошибка в синтаксисе конфигурации SSH."
    rollback
    exit 1
fi

# КРИТИЧЕСКАЯ ПРАВКА: Использование && для предотвращения выполнения restart, 
# если disable или enable завершились ошибкой (избегаем конфликта за порт).
echo "→ Применение изменений (перезапуск служб)..."
RESTART_OK="true"
if [[ "$SOCKET_WAS_ENABLED" == "true" ]]; then
    echo "   Отключаем ssh.socket и включаем классический ssh.service..."
    if systemctl disable --now ssh.socket \
       && systemctl enable ssh \
       && systemctl restart ssh; then
        : # Успех
    else
        RESTART_OK="false"
    fi
else
    echo "   Перезапуск службы ssh..."
    systemctl restart ssh || RESTART_OK="false"
fi

if [[ "$RESTART_OK" != "true" ]]; then
    echo "❌ Не удалось перезапустить/включить службы SSH."
    rollback
    exit 1
fi

# Финальная проверка
sleep 1
if ss -H -ltn "sport = :$NEW_PORT" 2>/dev/null | grep -q .; then
    echo "✅ sshd успешно слушает порт $NEW_PORT"
else
    echo "⚠️  Внимание: sshd не обнаружен на порту $NEW_PORT."
    echo "   Проверьте вручную: ss -ltnp | grep sshd"
    echo "   Если порт не слушается, выполните: systemctl restart ssh"
fi

NEW_CURRENT_PORT=$(get_current_ssh_port)
echo
echo "=============================================="
echo " Текущий порт SSH: $NEW_CURRENT_PORT"
echo "=============================================="

# Безопасная проверка ListenAddress через массив и nullglob
shopt -s nullglob
listen_files=(/etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf)
shopt -u nullglob
if grep -qE '^\s*ListenAddress\s+.*:[0-9]+' "${listen_files[@]}" 2>/dev/null; then
    echo "⚠️  Внимание: обнаружена директива ListenAddress с явным указанием порта."
    echo "   Если там указан старый порт, смена 'Port' может не дать эффекта. Проверьте конфиг."
fi

echo "💡 Не забудьте открыть новый порт в фаерволе (если используется):"
if command -v ufw >/dev/null 2>&1; then
    echo "   sudo ufw allow $NEW_PORT/tcp"
else
    echo "   (Проверьте правила вашего фаервола: iptables, firewalld или панель хостинга)"
fi
echo

read -rp "Нажмите 0 для выхода: " exit_choice || true
echo "Выход."
exit 0
