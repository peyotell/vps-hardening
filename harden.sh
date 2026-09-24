```bash
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# VPS Hardening Script
# Ubuntu 24.04 LTS
#
# Что делает:
# - обновляет систему
# - устанавливает OpenSSH, UFW, Fail2ban, unattended-upgrades
# - добавляет новый SSH-ключ для root
# - меняет SSH-порт
# - временно оставляет старый SSH-порт и парольную авторизацию
# - позволяет вручную проверить новый SSH-вход
# - после подтверждения отключает парольную SSH-аутентификацию
# - настраивает UFW
# - настраивает Fail2ban
# - настраивает unattended-upgrades
#
# ВАЖНО:
# - root SSH остаётся разрешён
# - root входит только по SSH-ключу после финального этапа
# - существующая SSH-сессия должна оставаться открытой
# ============================================================

trap 'echo; echo "[ERROR] Скрипт завершился с ошибкой на строке $LINENO."; exit 1' ERR

# ------------------------------------------------------------
# Цвета
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------
# Вспомогательные функции
# ------------------------------------------------------------

log() {
    echo -e "${GREEN}[ OK ]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

ask() {
    local prompt="$1"
    local __resultvar="$2"
    local value

    printf "%s" "$prompt" > /dev/tty
    IFS= read -r value < /dev/tty

    printf -v "$__resultvar" '%s' "$value"
}

confirm() {
    local prompt="$1"
    local answer

    printf "%s [y/N]: " "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty

    [[ "$answer" =~ ^[YyДд]$ ]]
}

# ------------------------------------------------------------
# Обработчик ошибок
# ------------------------------------------------------------

on_error() {
    local line="$1"
    local command="$2"

    echo
    echo -e "${RED}[ERROR]${NC} Команда завершилась с ошибкой."
    echo "Строка: $line"
    echo "Команда: $command"
    echo
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------
# Проверка root
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    die "Скрипт необходимо запускать от root."
fi

# ------------------------------------------------------------
# Проверка Ubuntu 24.04
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    die "Не найден /etc/os-release."
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    die "Скрипт рассчитан на Ubuntu 24.04 LTS. Обнаружено: ${PRETTY_NAME:-неизвестно}"
fi

log "Обнаружена Ubuntu 24.04 LTS."

echo
echo "Продолжаю..."
sleep 2

# ============================================================
# Ожидание APT / DPKG
# ============================================================

wait_for_apt() {
    local timeout=120
    local elapsed=0

    echo
    log "Проверяю доступность APT/dpkg..."

    while \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 ||
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    do
        if (( elapsed >= timeout )); then
            echo
            die "APT/dpkg остаётся занят более 2 минут. Другой процесс всё ещё использует менеджер пакетов."
        fi

        if (( elapsed == 0 )); then
            warn "APT/dpkg сейчас занят другим процессом."
            echo "Ожидаю освобождения блокировки (максимум 2 минуты)..."
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "APT/dpkg свободен."
}

# ============================================================
# Обновление системы
# ============================================================

echo
echo "============================================================"
echo " Обновление системы"
echo "============================================================"
echo

wait_for_apt

apt-get update

wait_for_apt

apt-get install -y \
    openssh-server \
    ufw \
    fail2ban \
    unattended-upgrades

wait_for_apt

apt-get full-upgrade -y

log "Система обновлена."

# ============================================================
# SSH service / socket
# ============================================================

echo
echo "============================================================"
echo " Подготовка SSH"
echo "============================================================"
echo

if systemctl is-active --quiet ssh.socket; then
    log "Обнаружен ssh.socket. Переключаюсь на ssh.service."

    systemctl disable --now ssh.socket
    systemctl enable --now ssh.service
else
    systemctl enable --now ssh.service
fi

SSH_SERVICE="ssh.service"

# ------------------------------------------------------------
# Определяем текущий SSH-порт
# ------------------------------------------------------------

CURRENT_SSH_PORT="$(
    ss -ltnp 2>/dev/null |
        grep -E 'sshd' |
        sed -nE 's/.*:([0-9]+).*sshd.*/\1/p' |
        head -n1
)"

if [[ -z "$CURRENT_SSH_PORT" ]]; then
    CURRENT_SSH_PORT="22"
fi

log "Текущий SSH-порт: ${CURRENT_SSH_PORT}"

# ------------------------------------------------------------
# Новый SSH-порт
# ------------------------------------------------------------

while true; do
    ask "Введите новый SSH-порт (1024-65535): " SSH_PORT

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        warn "Порт должен быть числом."
        continue
    fi

    if (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
        warn "Порт должен быть в диапазоне 1024-65535."
        continue
    fi

    if [[ "$SSH_PORT" == "$CURRENT_SSH_PORT" ]]; then
        warn "Новый порт должен отличаться от текущего SSH-порта."
        continue
    fi

    if ss -ltn | awk '{print $4}' | grep -qE ":${SSH_PORT}$"; then
        warn "Порт ${SSH_PORT} уже используется."
        continue
    fi

    break
done

log "Новый SSH-порт: ${SSH_PORT}"

# ============================================================
# SSH key
# ============================================================

echo
echo "============================================================"
echo " SSH-ключ"
echo "============================================================"
echo

HOSTNAME_VALUE="$(hostname)"

KEY_NAME="vps_${HOSTNAME_VALUE}_root_ed25519"

echo "Создай новый SSH-ключ в отдельном терминале:"
echo
echo "  ssh-keygen -t ed25519 -f ~/.ssh/${KEY_NAME}"
echo
echo "Если файл с таким именем уже существует, при необходимости"
echo "укажи другое имя непосредственно в ssh-keygen."
echo

while true; do
    ask "Вставь сюда содержимое публичного ключа (.pub): " SSH_PUBLIC_KEY

    if [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[^[:space:]]+ ]]; then
        break
    fi

    warn "Похоже, это невалидный SSH public key."
    echo "Ожидается строка, начинающаяся с ssh-ed25519, ssh-rsa или ecdsa-sha2-..."
done

log "Публичный SSH-ключ принят."

# ============================================================
# Дополнительные TCP-порты
# ============================================================

echo
echo "============================================================"
echo " Дополнительные TCP-порты"
echo "============================================================"
echo

echo "Можно указать дополнительные TCP-порты через запятую."
echo "Например: 80,443"
echo "Если дополнительных портов нет — просто нажми Enter."
echo

ask "Дополнительные TCP-порты: " EXTRA_PORTS

# ------------------------------------------------------------
# Проверка дополнительных портов
# ------------------------------------------------------------

EXTRA_PORTS_CLEAN=""

if [[ -n "$EXTRA_PORTS" ]]; then
    IFS=',' read -ra PORT_ARRAY <<< "$EXTRA_PORTS"

    for PORT in "${PORT_ARRAY[@]}"; do
        PORT="$(echo "$PORT" | xargs)"

        if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
            die "Некорректный порт: ${PORT}"
        fi

        if (( PORT < 1 || PORT > 65535 )); then
            die "Порт вне диапазона 1-65535: ${PORT}"
        fi

        if [[ -n "$EXTRA_PORTS_CLEAN" ]]; then
            EXTRA_PORTS_CLEAN+=","
        fi

        EXTRA_PORTS_CLEAN+="$PORT"
    done
fi

# ============================================================
# Итоговая проверка
# ============================================================

echo
echo "============================================================"
echo " Проверка настроек"
echo "============================================================"
echo

echo "Текущий SSH-порт:       ${CURRENT_SSH_PORT}"
echo "Новый SSH-порт:         ${SSH_PORT}"
echo "SSH root:               разрешён"
echo "SSH authentication:     public key"
echo "Доп. TCP-порты:         ${EXTRA_PORTS_CLEAN:-нет}"
echo "Fail2ban:               будет включён"
echo "Unattended upgrades:    будут включены"
echo

if ! confirm "Продолжить настройку"; then
    echo
    warn "Отменено."
    exit 0
fi

# ============================================================
# Backup
# ============================================================

echo
echo "============================================================"
echo " Создание резервной копии"
echo "============================================================"
echo

BACKUP_DIR="/root/vps-hardening-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

cp -a /etc/ssh "$BACKUP_DIR/ssh"
cp -a /etc/ufw "$BACKUP_DIR/ufw" 2>/dev/null || true
cp -a /etc/fail2ban "$BACKUP_DIR/fail2ban" 2>/dev/null || true

log "Backup: ${BACKUP_DIR}"

# ============================================================
# Установка SSH-ключа
# ============================================================

echo
echo "============================================================"
echo " Установка SSH-ключа"
echo "============================================================"
echo

mkdir -p /root/.ssh
chmod 700 /root/.ssh

touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if ! grep -Fqx "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys; then
    echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
fi

chown -R root:root /root/.ssh

log "SSH public key установлен."

# ============================================================
# Временная SSH-конфигурация
# ============================================================

echo
echo "============================================================"
echo " Временная SSH-конфигурация"
echo "============================================================"
echo

SSH_DROPIN="/etc/ssh/sshd_config.d/00-vps-hardening.conf"

cat > "$SSH_DROPIN" <<EOF
# Managed by vps-hardening
Port ${CURRENT_SSH_PORT}
Port ${SSH_PORT}

PubkeyAuthentication yes
PermitRootLogin prohibit-password

# Временно оставляем парольную аутентификацию.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

chmod 644 "$SSH_DROPIN"

sshd -t

systemctl restart "$SSH_SERVICE"

log "SSH временно слушает старый и новый порты."

# ============================================================
# UFW
# ============================================================

echo
echo "============================================================"
echo " Настройка UFW"
echo "============================================================"
echo

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# Старый SSH-порт временно оставляем открытым
ufw allow "${CURRENT_SSH_PORT}/tcp" comment "Temporary old SSH"

# Новый SSH-порт
ufw allow "${SSH_PORT}/tcp" comment "New SSH"

if [[ -n "$EXTRA_PORTS_CLEAN" ]]; then
    IFS=',' read -ra PORT_ARRAY <<< "$EXTRA_PORTS_CLEAN"

    for PORT in "${PORT_ARRAY[@]}"; do
        ufw allow "${PORT}/tcp" comment "Additional TCP port"
    done
fi

ufw --force enable

log "UFW настроен."

# ============================================================
# Проверка SSH-портов
# ============================================================

echo
echo "Проверяю SSH-порты..."

if ! ss -ltn | awk '{print $4}' | grep -qE ":${CURRENT_SSH_PORT}$"; then
    die "Старый SSH-порт ${CURRENT_SSH_PORT} не слушается."
fi

if ! ss -ltn | awk '{print $4}' | grep -qE ":${SSH_PORT}$"; then
    die "Новый SSH-порт ${SSH_PORT} не слушается."
fi

log "Оба SSH-порта доступны."

# ============================================================
# Ручная проверка нового SSH
# ============================================================

echo
echo "============================================================"
echo " ПРОВЕРКА НОВОГО SSH-ПОДКЛЮЧЕНИЯ"
echo "============================================================"
echo

echo "Открой второй терминал на своём компьютере."
echo
echo "Выполни:"
echo
echo "  ssh -i ~/.ssh/${KEY_NAME} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Замени SERVER_IP на IP-адрес VPS."
echo
echo "Если подключение успешно, вернись в этот терминал."
echo

if ! confirm "Новый SSH-вход успешно работает"; then
    echo
    warn "Останавливаю настройку для безопасности."
    echo
    echo "Старый SSH-порт ${CURRENT_SSH_PORT} оставлен."
    echo "Парольная SSH-аутентификация оставлена."
    echo "Новый SSH-порт ${SSH_PORT} также оставлен доступным."
    echo
    exit 0
fi

log "Новый SSH-вход подтверждён."

# ============================================================
# Финальная SSH-конфигурация
# ============================================================

echo
echo "============================================================"
echo " Финальная SSH-конфигурация"
echo "============================================================"
echo

cat > "$SSH_DROPIN" <<EOF
# Managed by vps-hardening
Port ${SSH_PORT}

PubkeyAuthentication yes
PermitRootLogin prohibit-password

PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

chmod 644 "$SSH_DROPIN"

sshd -t

systemctl restart "$SSH_SERVICE"

log "Парольная SSH-аутентификация отключена."

# ============================================================
# Удаляем старый SSH-порт из UFW
# ============================================================

echo
echo "Закрываю старый SSH-порт в UFW..."

ufw delete allow "${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true

log "Старый SSH-порт ${CURRENT_SSH_PORT} закрыт."

# ============================================================
# Fail2ban
# ============================================================

echo
echo "============================================================"
echo " Настройка Fail2ban"
echo "============================================================"
echo

FAIL2BAN_CONFIG="/etc/fail2ban/jail.d/sshd.local"

cat > "$FAIL2BAN_CONFIG" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

systemctl enable --now fail2ban
systemctl restart fail2ban

log "Fail2ban настроен."

# ============================================================
# Unattended upgrades
# ============================================================

echo
echo "============================================================"
echo " Настройка автоматических обновлений"
echo "============================================================"
echo

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now unattended-upgrades 2>/dev/null || true

log "Автоматические обновления настроены."

# ============================================================
# Финальная диагностика
# ============================================================

echo
echo "============================================================"
echo " Финальная проверка"
echo "============================================================"
echo

echo
echo "--- ОС ---"
grep PRETTY_NAME /etc/os-release

echo
echo "--- Hostname ---"
hostname

echo
echo "--- SSH config ---"
sshd -T | grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '

echo
echo "--- SSH listening ---"
ss -ltnp | grep sshd || true

echo
echo "--- UFW ---"
ufw status verbose

echo
echo "--- Fail2ban ---"
systemctl --no-pager --full status fail2ban || true

echo
echo "--- SSH service ---"
systemctl --no-pager --full status "$SSH_SERVICE" || true

echo
echo "============================================================"
echo " ГОТОВО"
echo "============================================================"
echo

echo "SSH-порт:        ${SSH_PORT}"
echo "Root SSH:        разрешён"
echo "Авторизация:     SSH-ключ"
echo "Пароль SSH:      отключён"
echo "UFW:             включён"
echo "Fail2ban:        включён"
echo "Автообновления:  включены"
echo
echo "Backup:"
echo "  ${BACKUP_DIR}"
echo
echo "Локальный ключ:"
echo "  ~/.ssh/${KEY_NAME}"
echo
echo "Публичный ключ:"
echo "  ~/.ssh/${KEY_NAME}.pub"
echo
echo "Подключение:"
echo "  ssh -i ~/.ssh/${KEY_NAME} -p ${SSH_PORT} root@SERVER_IP"
echo

