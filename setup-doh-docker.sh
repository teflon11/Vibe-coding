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
WORK_DIR="/opt/doh-docker"
INFO_FILE="/root/doh-docker-info.txt"

# ──────────────────────────────────────
# 1. Проверка зависимостей
# ──────────────────────────────────────
if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
    log_error "Docker или Docker Compose не найдены!"
    log_error "Установите их: apt update && apt install -y docker.io docker-compose-plugin"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен с правами root (sudo)"
    exit 1
fi

echo ""
echo "=========================================="
echo "  DoH DNS сервер (Docker) — установка"
echo "=========================================="
echo ""

# ──────────────────────────────────────
# 2. Запрос домена
# ──────────────────────────────────────
while true; do
    read -rp "Введите домен для DoH сервера (например, dns.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')
    
    if [[ $DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        break
    else
        log_error "Неверный формат домена."
    fi
done

# ──────────────────────────────────────
# 3. Проверка сертификатов
# ──────────────────────────────────────
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    log_error "SSL-сертификаты для домена ${DOMAIN} не найдены в ${CERT_DIR}/"
    log_error "Сначала выпустите сертификаты на хост-машине, затем запустите этот скрипт."
    exit 1
fi

log_info "SSL-сертификаты найдены."

# ──────────────────────────────────────
# 4. Подготовка рабочей директории
# ──────────────────────────────────────
log_step "Подготовка окружения Docker..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ──────────────────────────────────────
# 5. Генерация секретного токена
# ──────────────────────────────────────
SECRET_TOKEN=$(openssl rand -hex 32)
SECRET_PATH="/${SECRET_TOKEN}/"
DOH_URL="https://${DOMAIN}${SECRET_PATH}"

# ──────────────────────────────────────
# 6. Создание конфигов
# ──────────────────────────────────────
log_step "Создание конфигурационных файлов..."

# 6.1 docker-compose.yml
cat > "$WORK_DIR/docker-compose.yml" <<COMPOSEEOF
services:
  doh-backend:
    image: m13253/dns-over-https-server:latest
    container_name: doh-backend
    restart: unless-stopped
    networks:
      - doh-net
    environment:
      - UPSTREAM_DNS_SERVER=udp:1.1.1.1:53,udp:8.8.8.8:53
      - DOH_HTTP_PREFIX=/dns-query
      - DOH_SERVER_LISTEN=:8053
      - DOH_SERVER_VERBOSE=false

  nginx-proxy:
    image: nginx:alpine
    container_name: nginx-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    networks:
      - doh-net
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      # Монтируем всю директорию letsencrypt для корректной работы симлинков
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - doh-backend

networks:
  doh-net:
    driver: bridge
COMPOSEEOF

# 6.2 nginx.conf
cat > "$WORK_DIR/nginx.conf" <<NGINXEOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    
    # Безопасные настройки TLS (универсальный fallback)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Резолвер для Docker-сети (преобразование имени doh-backend в IP)
    resolver 127.0.0.11 valid=10s;

    location ${SECRET_PATH} {
        # Проксируем на стандартный префикс /dns-query. 
        # Nginx заменит совпавший SECRET_PATH на /dns-query, что идеально для бэкенда.
        proxy_pass http://doh-backend:8053/dns-query;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
    }

    # Маскировка: любой другой запрос получает 404
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

# ──────────────────────────────────────
# 7. Настройка автоматического обновления сертификатов (Docker)
# ──────────────────────────────────────
log_step "Настройка автоматического обновления сертификатов..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-doh-nginx.sh <<HOOKEOF
#!/bin/bash
if [[ "\$RENEWED_DOMAINS" == *"${DOMAIN}"* ]]; then
    docker exec nginx-proxy nginx -s reload
fi
HOOKEOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-doh-nginx.sh
log_info "Настроен хук для безопасной перезагрузки Nginx в Docker при обновлении сертификатов"

# ──────────────────────────────────────
# 8. Запуск контейнеров
# ──────────────────────────────────────
log_step "Запуск Docker-контейнеров..."
docker compose up -d

sleep 3

# Надежная проверка статуса без создания новых контейнеров с занятыми портами
if ! docker compose ps --status running | grep -q "nginx-proxy"; then
    log_error "Не удалось запустить контейнеры. Проверьте логи:"
    docker compose logs
    exit 1
fi

log_step "Проверка конфигурации Nginx внутри запущенного контейнера..."
if ! docker exec nginx-proxy nginx -t &> /dev/null; then
    log_error "Ошибка в конфигурации Nginx внутри контейнера:"
    docker exec nginx-proxy nginx -t
    docker compose logs nginx-proxy
    exit 1
fi

log_info "Контейнеры успешно запущены и работают корректно."

# ──────────────────────────────────────
# 9. Финальная проверка и вывод
# ──────────────────────────────────────
log_step "Проверка работы DoH..."
# Проверка без -k, чтобы реально валидировать SSL-сертификат
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "accept: application/dns-message" \
    "https://${DOMAIN}${SECRET_PATH}?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "400" ]; then
    log_info "DoH работает корректно ✓"
else
    log_warn "DoH отвечает с кодом $HTTP_CODE. Проверьте: docker compose logs nginx-proxy"
fi

# Сохранение информации
cat > "$INFO_FILE" <<INFOEOF
Домен:          ${DOMAIN}
Дата создания:  $(date '+%Y-%m-%d %H:%M:%S')

DoH URL:        ${DOH_URL}
Секретный токен: ${SECRET_TOKEN}

Рабочая директория Docker: ${WORK_DIR}

Автоматическое обновление:
  При продлении сертификатов (certbot renew) Nginx в контейнере 
  будет перезагружен автоматически через хук.
INFOEOF

chmod 600 "$INFO_FILE"

echo ""
echo "=========================================="
echo -e "${GREEN}  ✓ DoH DNS сервер (Docker) успешно развёрнут!${NC}"
echo "=========================================="
echo ""
echo -e "  ${CYAN}DoH адрес для Keenetic:${NC}"
echo -e "  ${GREEN}${DOH_URL}${NC}"
echo ""
echo "=========================================="
echo -e "  ${YELLOW}Управление сервером:${NC}"
echo "=========================================="
echo "  Просмотр логов:      cd ${WORK_DIR} && docker compose logs -f"
echo "  Перезапуск:          cd ${WORK_DIR} && docker compose restart"
echo "  Обновление образов:  cd ${WORK_DIR} && docker compose pull && docker compose up -d"
echo "  Полное удаление:     cd ${WORK_DIR} && docker compose down && cd .. && rm -rf ${WORK_DIR}"
echo ""
echo -e "  ${BLUE}Информация сохранена: ${INFO_FILE}${NC}"
echo -e "  ${RED}⚠  Сохраните DoH URL в безопасном месте!${NC}"
echo "=========================================="
