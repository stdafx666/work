#!/bin/bash
# ============================================================
# FlyPass VPN — Скрипт установки сервера
# Запускать на чистом Ubuntu 22.04 от root:
#   curl -sO https://raw.githubusercontent.com/.../setup.sh && bash setup.sh
# ============================================================

set -e  # Остановить при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Сброс цвета

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

echo ""
echo "=================================================="
echo "   ✈  FlyPass VPN — Установка сервера"
echo "=================================================="
echo ""

# Проверка что запущен от root
if [ "$EUID" -ne 0 ]; then
    err "Запусти скрипт от root: sudo bash setup.sh"
fi

# Проверка ОС
if ! grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null; then
    warn "Рекомендуется Ubuntu 22.04. Продолжаем на свой страх и риск..."
fi

# ── ШАГ 1: Обновление системы ─────────────────────────────────
info "Обновление пакетов..."
apt-get update -qq
apt-get upgrade -y -qq
log "Система обновлена"

# ── ШАГ 2: Установка базовых утилит ──────────────────────────
info "Установка базовых утилит..."
apt-get install -y -qq \
    curl wget git unzip nano htop \
    fail2ban ufw \
    ca-certificates gnupg lsb-release \
    python3 python3-pip \
    jq
log "Базовые утилиты установлены"

# ── ШАГ 3: Установка Docker ───────────────────────────────────
info "Установка Docker..."
if command -v docker &> /dev/null; then
    warn "Docker уже установлен: $(docker --version)"
else
    # Официальный репозиторий Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    log "Docker установлен: $(docker --version)"
fi

# Docker Compose (отдельная команда)
if ! command -v docker-compose &> /dev/null; then
    curl -SL "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-linux-x86_64" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log "Docker Compose установлен"
fi

# ── ШАГ 4: Настройка файрвола ─────────────────────────────────
info "Настройка UFW (файрвол)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP (Caddy → редирект на HTTPS)'
ufw allow 443/tcp   comment 'HTTPS'
ufw allow 443/udp   comment 'HTTP/3 (QUIC)'
# Порты VPN закрыты здесь — открываются на узлах, не на главном сервере
ufw --force enable
log "Файрвол настроен"

# ── ШАГ 5: Настройка Fail2ban ─────────────────────────────────
info "Настройка Fail2ban (защита от брутфорса)..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 86400    ; бан на 24 часа
findtime = 600      ; окно поиска 10 минут
maxretry = 5        ; максимум 5 попыток

[sshd]
enabled = true
port    = ssh
logpath = /var/log/auth.log
EOF
systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban настроен"

# ── ШАГ 6: Отключение входа по паролю SSH ────────────────────
info "Настройка SSH (только ключи)..."
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
# Убедимся что авторизация по ключам включена
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl reload sshd
warn "SSH теперь только по ключам! Убедись что ключ добавлен в ~/.ssh/authorized_keys"

# ── ШАГ 7: Установка rclone (для бэкапов в Backblaze) ────────
info "Установка rclone..."
curl https://rclone.org/install.sh | bash -qq
log "rclone установлен"

# ── ШАГ 8: Создание структуры папок проекта ──────────────────
info "Создание структуры проекта..."
mkdir -p /opt/flypass/{api,bot,web,cloudflare,scripts,migrations,logs/caddy}
cd /opt/flypass
log "Папка проекта: /opt/flypass"

# ── ШАГ 9: Настройка автоматических бэкапов ──────────────────
info "Настройка бэкапов..."
cat > /opt/flypass/scripts/backup.sh << 'BACKUP_SCRIPT'
#!/bin/bash
# ============================================================
# FlyPass — Автоматический бэкап в Backblaze B2
# Запускается каждые 6 часов через cron
# ============================================================
set -e

BACKUP_DIR="/tmp/flypass_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "[$(date)] Начало бэкапа..."

# 1. Дамп PostgreSQL
docker exec flypass_postgres pg_dump \
    -U "$DB_USER" -d "$DB_NAME" \
    --no-password -Fc \
    > "$BACKUP_DIR/database.dump"
echo "[$(date)] БД сохранена"

# 2. Дамп Redis
docker exec flypass_redis redis-cli \
    -a "$REDIS_PASSWORD" BGSAVE
sleep 2
docker cp flypass_redis:/data/dump.rdb "$BACKUP_DIR/redis.rdb"
echo "[$(date)] Redis сохранён"

# 3. Конфиги и .env (зашифрованные)
tar -czf "$BACKUP_DIR/configs.tar.gz" \
    /opt/flypass/Caddyfile \
    /opt/flypass/docker-compose.yml \
    2>/dev/null || true

# .env шифруем перед бэкапом
gpg --symmetric --cipher-algo AES256 \
    --passphrase "$SECRET_KEY" \
    --output "$BACKUP_DIR/env.gpg" \
    /opt/flypass/.env
echo "[$(date)] Конфиги сохранены"

# 4. Загрузка в Backblaze B2
rclone copy "$BACKUP_DIR" "b2:$B2_BUCKET_NAME/$(date +%Y-%m-%d)/" \
    --config /root/.config/rclone/rclone.conf

echo "[$(date)] Бэкап загружен в Backblaze B2"

# 5. Удаляем старые бэкапы (оставляем 30 дней)
rclone delete "b2:$B2_BUCKET_NAME/" \
    --min-age 30d \
    --config /root/.config/rclone/rclone.conf

# Чистим временную папку
rm -rf "$BACKUP_DIR"
echo "[$(date)] Бэкап завершён ✓"
BACKUP_SCRIPT
chmod +x /opt/flypass/scripts/backup.sh

# Добавляем в cron (каждые 6 часов)
(crontab -l 2>/dev/null; echo "0 */6 * * * /opt/flypass/scripts/backup.sh >> /opt/flypass/logs/backup.log 2>&1") | crontab -
log "Бэкапы настроены (каждые 6 часов)"

# ── ШАГ 10: Скрипт восстановления ────────────────────────────
cat > /opt/flypass/scripts/restore.sh << 'RESTORE_SCRIPT'
#!/bin/bash
# ============================================================
# FlyPass — Восстановление из бэкапа Backblaze B2
# Использование: bash restore.sh [дата в формате YYYY-MM-DD]
# Пример:        bash restore.sh 2025-01-15
# ============================================================
set -e

DATE=${1:-$(date +%Y-%m-%d)}  # Если дата не указана — берём сегодня

echo "Восстановление из бэкапа за: $DATE"
echo "Загрузка из Backblaze B2..."

RESTORE_DIR="/tmp/flypass_restore_$DATE"
mkdir -p "$RESTORE_DIR"

# Скачать бэкап
rclone copy "b2:$B2_BUCKET_NAME/$DATE/" "$RESTORE_DIR/"

if [ ! -f "$RESTORE_DIR/database.dump" ]; then
    echo "ОШИБКА: Бэкап за $DATE не найден!"
    exit 1
fi

# Остановить контейнеры
cd /opt/flypass
docker-compose stop api bot celery celery_beat

# Восстановить БД
docker exec -i flypass_postgres pg_restore \
    -U "$DB_USER" -d "$DB_NAME" \
    --clean --if-exists \
    < "$RESTORE_DIR/database.dump"
echo "БД восстановлена ✓"

# Восстановить Redis
docker cp "$RESTORE_DIR/redis.rdb" flypass_redis:/data/dump.rdb
docker restart flypass_redis
echo "Redis восстановлен ✓"

# Восстановить .env (если нужно)
if [ -f "$RESTORE_DIR/env.gpg" ]; then
    echo "Для расшифровки .env введи SECRET_KEY:"
    gpg --decrypt "$RESTORE_DIR/env.gpg" > /opt/flypass/.env
    echo ".env восстановлен ✓"
fi

# Запустить контейнеры
docker-compose start api bot celery celery_beat

rm -rf "$RESTORE_DIR"
echo ""
echo "✅ Восстановление завершено!"
RESTORE_SCRIPT
chmod +x /opt/flypass/scripts/restore.sh

# ── Итог ──────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo "  ✅  Сервер подготовлен!"
echo "=================================================="
echo ""
echo "Следующие шаги:"
echo ""
echo "  1. Скопируй файлы проекта в /opt/flypass/"
echo ""
echo "  2. Создай .env файл:"
echo "     cd /opt/flypass && cp .env.example .env && nano .env"
echo ""
echo "  3. Настрой rclone для Backblaze:"
echo "     rclone config"
echo "     → выбери 'n' (new remote) → name: b2 → тип: 2 (Backblaze)"
echo ""
echo "  4. Запусти все сервисы:"
echo "     cd /opt/flypass && docker-compose up -d"
echo ""
echo "  5. Проверь логи:"
echo "     docker-compose logs -f"
echo ""
warn "НЕ ЗАБУДЬ: добавь свой SSH ключ перед перезагрузкой!"
warn "Пароль SSH отключён. Без ключа не войдёшь!"
echo ""
