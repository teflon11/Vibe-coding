#!/bin/bash

set -e

# ──────────────────────────────────────
# Цвета
# ──────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }

# ──────────────────────────────────────
# Константы
# ──────────────────────────────────────
DOH_VERSION="2.3.0"
DOH_DIR="/opt/doh-server"
DOH_BIN="${DOH_DIR}/doh-server"
DOH_CONF="${DOH_DIR}/doh.conf"
NGINX_CONF="/etc/nginx/sites-available/doh"
INFO_FILE="/root/doh-server-info.txt"
SERVICE_NAME="doh-server"
DOH_USER="doh"

# ──────────────────────────────────────
# 1. Проверка зависимостей (Fail Fast)
# ──────────────────────────────────────
check_prerequisites() {
    local missing=()
    for cmd in nginx wget curl dig openssl tar systemctl apt-get ss; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    # Дополнительная проверка: Nginx установлен как полноценный пакет
    if ! dpkg -l 2>/dev/null | grep -q '^ii.*nginx '; then
        missing+=("nginx (пакет)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        # Очистка строки от "(пакет)" для корректной команды установки
        local install_cmds=()
        for item in "${missing[@]}"; do
            install_cmds+=("${item/ (пакет)/}")
        done
        log_error "Отсутствуют необходимые утилиты: ${missing[*]}"
        log_error "Установите их вручную: apt update && apt install -y ${install_cmds[*]}"
        exit 1
    fi
    log_info "Все необходимые базовые зависимости найдены."
}

# ──────────────────────────────────────
# 2. Проверка прав root
# ──────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен с правами root (sudo)"
    exit 1
fi

# ──────────────────────────────────────
# 3. Проверка ОС
# ──────────────────────────────────────
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_warn "Скрипт оптимизирован для Ubuntu. На других системах возможны проблемы."
    fi
    log_info "Система: $PRETTY_NAME"
else
    log_warn "Не удалось определить ОС"
fi

check_prerequisites

echo ""
echo "=========================================="
echo "  DoH DNS сервер — установка"
echo "=========================================="
echo ""

# ──────────────────────────────────────
# 4. Запрос и валидация домена
# ──────────────────────────────────────
while true; do
    read -rp "Введите домен для DoH сервера (например, dns.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    
    if [[ ${#DOMAIN} -gt 253 ]]; then
        log_error "Домен слишком длинный (максимум 253 символа)."
        continue
    fi
    
    if [[ $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        break
    else
        log_error "Неверный формат домена. Используйте только буквы, цифры и дефисы."
    fi
done

# ──────────────────────────────────────
# 4.5. Проверка DNS записей домена
# ──────────────────────────────────────
log_step "Проверка DNS записей домена..."
DOMAIN_IP=$(dig +short "${DOMAIN}" A | head -1)
MY_IP=$(curl -s --max-time 5 ifconfig.me || echo "не определён")

if [ -n "$DOMAIN_IP" ] && [ "$DOMAIN_IP" != "$MY_IP" ]; then
    log_warn "Домен ${DOMAIN} (${DOMAIN_IP}) не указывает на IP этого сервера (${MY_IP})"
    read -rp "Продолжить установку? [y/N]: " CONFIRM_IP
    if [[ ! "$CONFIRM_IP" =~ ^[Yy]$ ]]; then
        log_info "Установка отменена. Настройте A-запись домена и запустите скрипт снова."
        exit 1
    fi
else
    log_info "DNS записи домена проверены (IP: ${DOMAIN_IP:-не определён})"
fi

# ──────────────────────────────────────
# 5. Проверка наличия и читаемости сертификатов
# ──────────────────────────────────────
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    log_error "SSL-сертификаты для домена ${DOMAIN} не найдены!"
    log_error "Ожидаемый каталог: ${CERT_DIR}/"
    echo ""
    log_error "Сначала выпустите сертификаты, затем запустите этот скрипт."
    exit 1
fi

if [ ! -r "${CERT_DIR}/fullchain.pem" ] || [ ! -r "${CERT_DIR}/privkey.pem" ]; then
    log_error "Нет прав на чтение сертификатов в ${CERT_DIR}/"
    log_error "Проверьте права доступа к файлам."
    exit 1
fi

# Проверка срока действия сертификата
if ! openssl x509 -checkend 86400 -noout -in "${CERT_DIR}/fullchain.pem" 2>/dev/null; then
    log_warn "⚠ Сертификат истекает в течение 24 часов! Рекомендую обновить его перед продолжением."
fi

# КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Проверка файлов Certbot с fallback
CERTBOT_NGINX_OPTS="/etc/letsencrypt/options-ssl-nginx.conf"
CERTBOT_DHPARAM="/etc/letsencrypt/ssl-dhparams.pem"
USE_CERTBOT_FILES=true

if [ ! -f "$CERTBOT_NGINX_OPTS" ] || [ ! -f "$CERTBOT_DHPARAM" ]; then
    USE_CERTBOT_FILES=false
    log_warn "Файлы Certbot для Nginx не найдены."
    log_warn "  - $CERTBOT_NGINX_OPTS"
    log_warn "  - $CERTBOT_DHPARAM"
    log_warn "Будут использованы встроенные безопасные директивы SSL (это нормально, если сертификат выпущен через acme.sh или --standalone)."
fi

log_info "SSL-сертификаты для ${DOMAIN} найдены и доступны для чтения"

# ──────────────────────────────────────
# 6. Функция: проверка установленности
# ──────────────────────────────────────
is_installed() {
    if [ -f "$NGINX_CONF" ] || \
       systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        return 0
    fi
    return 1
}

# ──────────────────────────────────────
# 7. Функция: показать текущую информацию
# ──────────────────────────────────────
show_current_info() {
    if [ -f "$INFO_FILE" ]; then
        echo ""
        echo "=========================================="
        echo -e "${CYAN}  Текущий DoH сервер${NC}"
        echo "=========================================="
        cat "$INFO_FILE"
        echo "=========================================="
    else
        log_warn "Файл с информацией не найден (${INFO_FILE})"
    fi
}

# ──────────────────────────────────────
# 8. Функция: безопасное удаление старой установки
# ──────────────────────────────────────
cleanup_old() {
    log_step "Создание резервных копий и удаление старой установки..."

    local timestamp
    timestamp=$(date +%s)
    
    if [ -f "$NGINX_CONF" ]; then cp "$NGINX_CONF" "${NGINX_CONF}.bak.${timestamp}"; fi
    if [ -f "$DOH_CONF" ]; then cp "$DOH_CONF" "${DOH_CONF}.bak.${timestamp}"; fi

    # АБСОЛЮТНО НАДЕЖНАЯ ротация бэкапов (GNU find)
    find /etc/nginx/sites-available -maxdepth 1 -name "doh.bak.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +4 | cut -d' ' -f2- | xargs -r rm -f
    find "$DOH_DIR" -maxdepth 1 -name "doh.conf.bak.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +4 | cut -d' ' -f2- | xargs -r rm -f

    # Очистка doh-server
    if systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}\.service"; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            systemctl stop "$SERVICE_NAME"
        fi
        if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            systemctl disable "$SERVICE_NAME" 2>/dev/null
        fi
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    fi

    rm -f "$NGINX_CONF"
    rm -f "/etc/nginx/sites-enabled/doh"
    rm -f "$INFO_FILE"

    if id "$DOH_USER" &>/dev/null; then
        userdel "$DOH_USER" 2>/dev/null || true
        log_info "Пользователь ${DOH_USER} удалён"
    fi

    log_info "Старая установка полностью удалена"
}

# ──────────────────────────────────────
# 9. Функция: полная установка
# ──────────────────────────────────────
install_doh() {
    export DEBIAN_FRONTEND=noninteractive

    # ── 9.1 Проверка сети ──
    log_step "Проверка доступности upstream DNS (1.1.1.1)..."
    if ! curl -sf --max-time 5 https://1.1.1.1/dns-query -H "accept: application/dns-message" >/dev/null; then
        log_warn "Не удалось достичь 1.1.1.1. Проверьте исходящие подключения с VPS."
    else
        log_info "Upstream DNS доступен"
    fi

    # ── 9.2 Создание пользователя ──
    if ! id "$DOH_USER" &>/dev/null; then
        useradd -r -s /bin/false -d "$DOH_DIR" "$DOH_USER"
        log_info "Создан системный пользователь '${DOH_USER}' для безопасного запуска"
    fi

    # ── 9.3 Установка doh-server ──
    log_step "Установка doh-server..."
    mkdir -p "$DOH_DIR"

    if ss -tlnp 2>/dev/null | grep -qE ":8053\b"; then
        log_error "Порт 8053 уже занят другим процессом! Проверьте: ss -tlnp | grep 8053"
        exit 1
    fi

    if [ ! -f "$DOH_BIN" ]; then
        cd /tmp
        log_info "Скачивание doh-server v${DOH_VERSION}..."
        if ! wget -q --show-progress https://github.com/m13253/dns-over-https/releases/download/v${DOH_VERSION}/doh-server_${DOH_VERSION}_linux_amd64.tar.gz; then
            log_error "Не удалось скачать doh-server."
            exit 1
        fi
        
        if ! tar -xzf doh-server_${DOH_VERSION}_linux_amd64.tar.gz; then
            log_error "Не удалось распаковать архив doh-server"
            exit 1
        fi
        
        mv doh-server_${DOH_VERSION}_linux_amd64/doh-server "$DOH_BIN"
        chmod +x "$DOH_BIN"
        rm -rf doh-server_${DOH_VERSION}_linux_amd64 doh-server_${DOH_VERSION}_linux_amd64.tar.gz
        cd - >/dev/null
        log_info "doh-server успешно установлен"
    else
        log_info "doh-server уже присутствует, пропускаем скачивание"
    fi

    chown -R "${DOH_USER}:${DOH_USER}" "$DOH_DIR"

    # ── 9.4 Конфиг doh-server ──
    log_step "Настройка doh-server..."
    cat > "$DOH_CONF" <<DOHEOF
listen = [
    "127.0.0.1:8053",
]

upstream = [
    "https://1.1.1.1/dns-query",
    "https://8.8.8.8/dns-query",
]

verbose = false
debug = false
DOHEOF
    chown "${DOH_USER}:${DOH_USER}" "$DOH_CONF"

    # ── 9.5 Systemd-сервис для doh-server ──
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SVCEOF
[Unit]
Description=DNS over HTTPS Backend
After=network.target

[Service]
Type=simple
User=${DOH_USER}
Group=${DOH_USER}
WorkingDirectory=${DOH_DIR}
ExecStart=${DOH_BIN} -conf ${DOH_CONF}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "Не удалось запустить ${SERVICE_NAME}"
        journalctl -u "$SERVICE_NAME" -n 15 --no-pager
        exit 1
    fi

    if ! ss -tlnp 2>/dev/null | grep -qE "127\.0\.0\.1:8053\b"; then
        log_warn "doh-server не слушает 127.0.0.1:8053! Проверьте: ss -tlnp | grep 8053"
    else
        log_info "doh-server запущен и корректно слушает 127.0.0.1:8053"
    fi

    # ── 9.6 Секретный токен ──
    log_step "Генерация нового секретного токена..."
    SECRET_TOKEN=$(openssl rand -hex 32)
    if [ ${#SECRET_TOKEN} -ne 64 ]; then
        log_error "Ошибка генерации токена!"
        exit 1
    fi
    SECRET_PATH="/${SECRET_TOKEN}/"

    # ── 9.7 Nginx-конфиг ──
    log_step "Создание конфигурации Nginx..."
    
    OTHER_SITES=$(ls -A /etc/nginx/sites-enabled/ 2>/dev/null | grep -vE '^(default|doh)(\..*)?$' || true)
    if [ -n "$OTHER_SITES" ]; then
        log_warn "На сервере есть другие активные сайты Nginx:"
        echo "$OTHER_SITES" | sed 's/^/  - /'
        log_warn "Убедитесь, что они не конфликтуют за порт 443"
    fi

    rm -f /etc/nginx/sites-enabled/default

    # Формируем SSL-часть в зависимости от наличия файлов Certbot
    if [ "$USE_CERTBOT_FILES" = true ]; then
        SSL_BLOCK="    include ${CERTBOT_NGINX_OPTS};
    ssl_dhparam ${CERTBOT_DHPARAM};"
    else
        SSL_BLOCK="    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;"
    fi

    cat > "$NGINX_CONF" <<NGINXEOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
${SSL_BLOCK}

    # Секретный путь для DoH-запросов
    location ${SECRET_PATH} {
        proxy_pass http://127.0.0.1:8053/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Connection "";

        proxy_connect_timeout 5s;
        proxy_send_timeout 10s;
        proxy_read_timeout 10s;
        proxy_buffering off;
    }

    # Маскировка: любой другой запрос получает стандартный 404
    location / {
        return 404;
    }
}

server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
NGINXEOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    # Безопасная проверка Nginx с откатом при ошибке
    NGINX_TEST_OUTPUT=$(nginx -t 2>&1) || {
        log_error "Ошибка в конфигурации Nginx:"
        echo "$NGINX_TEST_OUTPUT"
        rm -f "/etc/nginx/sites-enabled/doh"
        systemctl reload nginx 2>/dev/null || true
        exit 1
    }

    systemctl reload nginx
    log_info "Nginx настроен и перезагружен"

    # ── 9.8 Firewall (напоминание) ──
    log_info "Настройка firewall пропущена по вашему запросу."
    log_info "Не забудьте вручную открыть порты: 22, 80, 443. Порт 53 НЕ должен быть открыт наружу!"

    # ── 9.9 Сохранение информации ──
    DOH_URL="https://${DOMAIN}${SECRET_PATH}"
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me || echo "не определён")

    cat > "$INFO_FILE" <<INFOEOF
Домен:          ${DOMAIN}
IP сервера:     ${SERVER_IP}
Дата создания:  $(date '+%Y-%m-%d %H:%M:%S')

DoH URL:        ${DOH_URL}
Секретный токен: ${SECRET_TOKEN}

Архитектура:
  - DoH (443): Nginx -> doh-server (пользователь: ${DOH_USER})
  - Обычный DNS (53): не используется
  - Маскировка: любой URL кроме секретного возвращает 404

Порты для UFW:
  - 22/tcp   — SSH
  - 80/tcp   — HTTP (Let's Encrypt + редирект на HTTPS)
  - 443/tcp  — DoH (через секретный URL)
  - 53       — НЕ ОТКРЫВАТЬ!
INFOEOF

    chmod 600 "$INFO_FILE"

    # ── 9.10 Финальная проверка DoH ──
    log_step "Проверка работы DoH..."
    # base64 с fallback для систем без флага -w0
    if base64 -w0 </dev/null &>/dev/null 2>&1; then
        DOH_TEST_QUERY=$(printf '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' | base64 -w0 | tr '+/' '-_' | tr -d '=')
    else
        DOH_TEST_QUERY=$(printf '\x00\x00\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
    fi
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "accept: application/dns-message" \
        "https://${DOMAIN}${SECRET_PATH}?dns=${DOH_TEST_QUERY}")
    
    if [ "$HTTP_CODE" = "200" ]; then
        log_info "DoH работает корректно ✓ (DNS-запрос выполнен успешно)"
    else
        log_warn "DoH не отвечает корректно (HTTP код: $HTTP_CODE). Проверьте: journalctl -u ${SERVICE_NAME} -n 30"
    fi

    # ── 9.11 Итоговый вывод ──
    echo ""
    echo "=========================================="
    echo -e "${GREEN}  ✓ DoH DNS сервер успешно развёрнут!${NC}"
    echo "=========================================="
    echo ""
    echo -e "  Домен:          ${DOMAIN}"
    echo -e "  Секретный токен: ${YELLOW}${SECRET_TOKEN}${NC}"
    echo ""
    echo -e "  ${CYAN}DoH адрес (DNS over HTTPS):${NC}"
    echo -e "  ${GREEN}${DOH_URL}${NC}"
    echo ""
    echo "=========================================="
    echo -e "  ${YELLOW}Настройка Keenetic:${NC}"
    echo "=========================================="
    echo "  1. Мои сети и интернет → Интернет → ваше подключение"
    echo "     → снять галочку «Получать DNS от провайдера»"
    echo "  2. Мои сети и интернет → Интернет → DNS"
    echo "     → включить «DNS over HTTPS (DoH)»"
    echo "     → добавить сервер:"
    echo "       ${DOH_URL}"
    echo "  3. Сохранить"
    echo ""
    echo "=========================================="
    echo -e "  ${RED}⚠  ВАЖНО: Настройте UFW вручную!${NC}"
    echo "=========================================="
    echo "  Открыть:  22, 80, 443"
    echo "  Закрыть:  53 (для внешних подключений)"
    echo ""
    echo "=========================================="
    echo -e "  ${BLUE}Информация сохранена: ${INFO_FILE}${NC}"
    echo -e "  ${RED}⚠  Сохраните DoH URL в безопасном месте!${NC}"
    echo -e "  ${RED}   Без этого URL никто не сможет воспользоваться вашим DNS.${NC}"
    echo "=========================================="
    echo ""
}

# ──────────────────────────────────────
# 10. Главный logic: установлена ли уже?
# ──────────────────────────────────────
if is_installed; then
    echo ""
    log_warn "DoH сервер уже установлен на этом VPS!"
    echo ""

    show_current_info
    echo ""

    while true; do
        echo -e "  ${CYAN}1${NC}) Переустановить сервер (сгенерировать новый секретный URL + бэкап конфигов)"
        echo -e "  ${CYAN}2${NC}) Полностью удалить сервер и все его компоненты (с сохранением бэкапов)"
        echo -e "  ${CYAN}0${NC}) Выйти без изменений"
        echo ""
        read -rp "Ваш выбор [0/1/2]: " CHOICE

        case "$CHOICE" in
            1)
                echo ""
                cleanup_old
                echo ""
                install_doh
                exit 0
                ;;
            2)
                echo ""
                read -rp "${RED}⚠ Вы уверены, что хотите полностью удалить DoH сервер? (Будут созданы бэкапы конфигов) [y/N]: ${NC}" CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    echo ""
                    cleanup_old
                    echo ""
                    log_info "DoH сервер полностью удален. Резервные копии конфигов сохранены с суффиксом .bak"
                    log_info "Не забудьте вручную удалить правила UFW, если они больше не нужны."
                    exit 0
                else
                    echo ""
                    log_info "Удаление отменено."
                fi
                ;;
            0)
                echo ""
                log_info "Выход без изменений."
                exit 0
                ;;
            *)
                log_error "Неверный ввод. Пожалуйста, введите 0, 1 или 2."
                echo ""
                ;;
        esac
    done
else
    echo ""
    log_info "DoH сервер не обнаружен. Начинаем установку..."
    echo ""
    install_doh
fi
