#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# VPS Hardening for Ubuntu 24.04
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

trap 'die "Скрипт завершился с ошибкой на строке $LINENO."' ERR

# ============================================================
# Interactive input from real terminal
# ============================================================

ask() {
    local prompt="$1"
    local default="${2:-}"
    local answer=""

    if [[ -n "${default}" ]]; then
        printf "%s [%s]: " "${prompt}" "${default}" > /dev/tty
    else
        printf "%s: " "${prompt}" > /dev/tty
    fi

    read -r answer < /dev/tty || true

    if [[ -n "${answer}" ]]; then
        echo "${answer}"
    else
        echo "${default}"
    fi
}

confirm() {
    local prompt="$1"
    local answer=""

    while true; do
        printf "%s [y/N]: " "${prompt}" > /dev/tty
        read -r answer < /dev/tty || true

        case "${answer}" in
            y|Y|yes|YES|д|Д|да|ДА)
                return 0
                ;;
            n|N|no|NO|н|Н|нет|НЕТ|"")
                return 1
                ;;
            *)
                echo "Введите y или n." > /dev/tty
                ;;
        esac
    done
}

# ============================================================
# Root check
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "Запусти скрипт от root."
fi

# ============================================================
# Ubuntu check
# ============================================================

if [[ ! -r /etc/os-release ]]; then
    die "Не найден /etc/os-release."
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    die "Поддерживается только Ubuntu."
fi

if [[ "${VERSION_ID}" != "24.04" ]]; then
    die "Поддерживается Ubuntu 24.04 LTS. Обнаружено: ${PRETTY_NAME}"
fi

log "Обнаружена Ubuntu 24.04 LTS."

HOSTNAME_VALUE="$(hostname)"

# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo " VPS Hardening"
echo "============================================================"
echo
echo "Hostname: ${HOSTNAME_VALUE}"
echo
echo "ВНИМАНИЕ:"
echo
echo "  1. НЕ закрывай текущую SSH-сессию."
echo "  2. Старый SSH-порт временно останется рабочим."
echo "  3. Новый SSH-порт будет работать одновременно со старым."
echo "  4. Новый SSH-вход будет проверен во втором терминале."
echo "  5. Только после успешной проверки парольная"
echo "     авторизация и старый порт будут отключены."
echo
echo "Продолжаю..."
sleep 2

# ============================================================
# Packages
# ============================================================

echo
echo "============================================================"
echo " Обновление системы"
echo "============================================================"
echo

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    openssh-server \
    ufw \
    fail2ban \
    unattended-upgrades

apt-get full-upgrade -y

log "Система обновлена."

# ============================================================
# SSH socket/service
# ============================================================

echo
echo "============================================================"
echo " Проверка SSH"
echo "============================================================"
echo

if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    warn "Обнаружен ssh.socket."

    systemctl disable --now ssh.socket

    systemctl enable ssh.service
    systemctl start ssh.service

    log "Переключено с ssh.socket на ssh.service."
else
    systemctl enable ssh.service
    systemctl start ssh.service
fi

SSH_SERVICE="ssh.service"

# ============================================================
# Current SSH port
# ============================================================

CURRENT_SSH_PORT="$(
    ss -ltnp 2>/dev/null |
        grep -E 'sshd' |
        sed -n 's/.*:\([0-9]\+\)[[:space:]].*sshd.*/\1/p' |
        head -n1
)"

if [[ -z "${CURRENT_SSH_PORT}" ]]; then
    CURRENT_SSH_PORT="$(
        ss -ltnp 2>/dev/null |
            awk '
                /sshd/ {
                    addr=$4
                    sub(/^.*:/, "", addr)
                    if (addr ~ /^[0-9]+$/) {
                        print addr
                        exit
                    }
                }
            '
    )"
fi

if [[ -z "${CURRENT_SSH_PORT}" ]]; then
    die "Не удалось определить текущий SSH-порт."
fi

log "Текущий SSH-порт: ${CURRENT_SSH_PORT}"

# ============================================================
# New SSH port
# ============================================================

echo
echo "============================================================"
echo " Новый SSH-порт"
echo "============================================================"
echo
echo "Можно использовать, например, 2222 или 22022."
echo

while true; do
    SSH_PORT="$(ask "Новый SSH-порт")"

    if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]]; then
        echo "Порт должен быть числом."
        continue
    fi

    if (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
        echo "Порт должен быть в диапазоне 1024-65535."
        continue
    fi

    if [[ "${SSH_PORT}" == "${CURRENT_SSH_PORT}" ]]; then
        echo "Новый порт должен отличаться от текущего."
        continue
    fi

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${SSH_PORT}$"; then
        echo "Порт ${SSH_PORT} уже занят."
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

DEFAULT_KEY_NAME="vps_${HOSTNAME_VALUE}_root_ed25519"

echo "На своём компьютере во втором терминале создай НОВЫЙ ключ:"
echo
echo "  ssh-keygen -t ed25519 -f ~/.ssh/${DEFAULT_KEY_NAME}"
echo
echo "Если такой файл уже существует — используй другое имя."
echo

KEY_NAME="$(ask "Имя ключа без ~/.ssh/" "${DEFAULT_KEY_NAME}")"

if [[ ! "${KEY_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Недопустимое имя ключа."
fi

KEY_PATH="~/.ssh/${KEY_NAME}"
PUBLIC_KEY_PATH="${KEY_PATH}.pub"

echo
echo "После создания ключа выполни на своём компьютере:"
echo
echo "  cat ${PUBLIC_KEY_PATH}"
echo
echo "И вставь сюда одну строку public key."
echo

while true; do
    SSH_PUBLIC_KEY="$(ask "SSH public key")"

    # trim
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY#"${SSH_PUBLIC_KEY%%[![:space:]]*}"}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY%"${SSH_PUBLIC_KEY##*[![:space:]]}"}"

    if [[ "${SSH_PUBLIC_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
        break
    fi

    echo
    echo "Некорректный SSH public key."
    echo "Пример:"
    echo
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
    echo
done

log "SSH public key принят."

# ============================================================
# Additional ports
# ============================================================

echo
echo "============================================================"
echo " Дополнительные TCP-порты"
echo "============================================================"
echo
echo "Например: 80,443"
echo "Если не нужны — просто нажми Enter."
echo

ADDITIONAL_PORTS_RAW="$(ask "Дополнительные TCP-порты")"

ADDITIONAL_PORTS=()

if [[ -n "${ADDITIONAL_PORTS_RAW}" ]]; then

    IFS=',' read -ra PORT_LIST <<< "${ADDITIONAL_PORTS_RAW}"

    for port in "${PORT_LIST[@]}"; do

        port="$(echo "${port}" | xargs)"

        if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
            die "Некорректный порт: ${port}"
        fi

        if (( port < 1 || port > 65535 )); then
            die "Порт вне диапазона 1-65535: ${port}"
        fi

        if [[ "${port}" == "${CURRENT_SSH_PORT}" ]]; then
            die "Старый SSH-порт не нужно добавлять сюда."
        fi

        if [[ "${port}" == "${SSH_PORT}" ]]; then
            die "Новый SSH-порт не нужно добавлять сюда."
        fi

        ADDITIONAL_PORTS+=("${port}")
    done
fi

# ============================================================
# Summary
# ============================================================

echo
echo "============================================================"
echo " Параметры"
echo "============================================================"
echo
echo "Hostname:          ${HOSTNAME_VALUE}"
echo "Старый SSH-порт:   ${CURRENT_SSH_PORT}"
echo "Новый SSH-порт:    ${SSH_PORT}"
echo "Root SSH:          разрешён через ключ"
echo "Пароль SSH:        будет отключён после проверки"
echo "Ключ:              ${KEY_PATH}"
echo "Доп. TCP-порты:    ${ADDITIONAL_PORTS_RAW:-нет}"
echo

if ! confirm "Начать настройку"; then
    echo "Отменено."
    exit 0
fi

# ============================================================
# Backup
# ============================================================

BACKUP_ROOT="/root/vps-hardening-backup-$(date +%Y%m%d-%H%M%S)"

echo
echo "Создаю backup..."

mkdir -p "${BACKUP_ROOT}"

cp -a /etc/ssh "${BACKUP_ROOT}/ssh"
cp -a /etc/ufw "${BACKUP_ROOT}/ufw"
cp -a /etc/fail2ban "${BACKUP_ROOT}/fail2ban"

log "Backup: ${BACKUP_ROOT}"

# ============================================================
# SSH authorized_keys
# ============================================================

echo
echo "Устанавливаю SSH public key..."

mkdir -p /root/.ssh

chmod 700 /root/.ssh

touch /root/.ssh/authorized_keys

chmod 600 /root/.ssh/authorized_keys

chown -R root:root /root/.ssh

if ! grep -Fqx "${SSH_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
    echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
fi

log "SSH public key установлен."

# ============================================================
# Temporary SSH config
# ============================================================

CONFIG_FILE="/etc/ssh/sshd_config.d/00-vps-hardening.conf"

echo
echo "Создаю временную SSH-конфигурацию..."

cat > "${CONFIG_FILE}" <<EOF
# Managed by VPS Hardening

Port ${CURRENT_SSH_PORT}
Port ${SSH_PORT}

PubkeyAuthentication yes

PermitRootLogin prohibit-password

PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

chmod 644 "${CONFIG_FILE}"

# Validate
sshd -t

log "SSH-конфигурация корректна."

# ============================================================
# UFW
# ============================================================

echo
echo "============================================================"
echo " UFW"
echo "============================================================"
echo

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# Старый порт оставляем.
ufw allow "${CURRENT_SSH_PORT}/tcp" comment "Temporary old SSH"

# Новый порт добавляем.
ufw allow "${SSH_PORT}/tcp" comment "New SSH"

for port in "${ADDITIONAL_PORTS[@]}"; do
    ufw allow "${port}/tcp" comment "Additional TCP"
done

ufw --force enable

log "UFW включён."

# ============================================================
# Restart SSH
# ============================================================

echo
echo "Перезапускаю SSH..."

systemctl restart "${SSH_SERVICE}"

sleep 2

# ============================================================
# Verify ports
# ============================================================

if ! ss -ltn | grep -Eq ":${CURRENT_SSH_PORT}[[:space:]]"; then
    die "Старый SSH-порт ${CURRENT_SSH_PORT} не слушается."
fi

if ! ss -ltn | grep -Eq ":${SSH_PORT}[[:space:]]"; then
    die "Новый SSH-порт ${SSH_PORT} не слушается."
fi

log "Старый SSH-порт ${CURRENT_SSH_PORT} работает."
log "Новый SSH-порт ${SSH_PORT} работает."

# ============================================================
# Manual test
# ============================================================

echo
echo
echo "============================================================"
echo " ПРОВЕРКА НОВОГО SSH"
echo "============================================================"
echo
echo "НЕ ЗАКРЫВАЙ ЭТУ SSH-СЕССИЮ!"
echo
echo "Открой ВТОРОЙ терминал на своём компьютере."
echo
echo "Выполни:"
echo
echo "  ssh -i ${KEY_PATH} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Если подключение успешно, во втором терминале выполни:"
echo
echo "  echo 'NEW SSH CONNECTION OK'"
echo
echo "После этого вернись сюда."
echo

if ! confirm "Новый SSH-вход успешно работает"; then

    echo
    warn "Финальная блокировка НЕ выполнена."
    echo
    echo "Старый SSH-порт остаётся доступным."
    echo "Парольная авторизация пока не отключена."
    echo
    echo "Скрипт завершён безопасно."

    exit 0
fi

# ============================================================
# FINAL SSH CONFIG
# ============================================================

echo
echo "============================================================"
echo " Финальная SSH-настройка"
echo "============================================================"
echo

cat > "${CONFIG_FILE}" <<EOF
# Managed by VPS Hardening

Port ${SSH_PORT}

PubkeyAuthentication yes

PermitRootLogin prohibit-password

PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

chmod 644 "${CONFIG_FILE}"

sshd -t

systemctl restart "${SSH_SERVICE}"

sleep 2

if ! ss -ltn | grep -Eq ":${SSH_PORT}[[:space:]]"; then
    die "Новый SSH-порт не слушается после финального перезапуска."
fi

log "PasswordAuthentication отключён."
log "Root SSH через public key разрешён."
log "SSH работает на порту ${SSH_PORT}."

# ============================================================
# Remove old UFW rule
# ============================================================

echo
echo "Удаляю старый SSH-порт из UFW..."

ufw delete allow "${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true

log "Старый SSH-порт ${CURRENT_SSH_PORT} удалён из UFW."

# ============================================================
# Fail2ban
# ============================================================

echo
echo "============================================================"
echo " Fail2ban"
echo "============================================================"
echo

mkdir -p /etc/fail2ban/jail.d

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban

sleep 2

if systemctl is-active --quiet fail2ban; then
    log "Fail2ban работает."
else
    warn "Fail2ban не запустился."
fi

# ============================================================
# Unattended upgrades
# ============================================================

echo
echo "============================================================"
echo " Автоматические обновления"
echo "============================================================"
echo

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable apt-daily.timer 2>/dev/null || true
systemctl enable apt-daily-upgrade.timer 2>/dev/null || true

log "Автоматические обновления включены."

# ============================================================
# Final diagnostics
# ============================================================

echo
echo "============================================================"
echo " ФИНАЛЬНАЯ ПРОВЕРКА"
echo "============================================================"
echo

echo "----- OS -----"
echo "${PRETTY_NAME}"

echo
echo "----- Hostname -----"
echo "${HOSTNAME_VALUE}"

echo
echo "----- SSH -----"
echo "Service:              ${SSH_SERVICE}"
echo "Port:                 ${SSH_PORT}"
echo "Root login:           prohibit-password"
echo "Password auth:        disabled"
echo "Public key auth:      enabled"

echo
echo "----- Listening ports -----"
ss -ltnp

echo
echo "----- UFW -----"
ufw status verbose

echo
echo "----- Fail2ban -----"
fail2ban-client status || true

echo
echo "----- Effective SSH config -----"

if sshd -T >/tmp/sshd-effective.txt 2>/dev/null; then
    grep -E \
        '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) ' \
        /tmp/sshd-effective.txt || true
fi

rm -f /tmp/sshd-effective.txt

echo
echo "----- Services -----"
systemctl is-active "${SSH_SERVICE}" || true
systemctl is-active fail2ban || true

# ============================================================
# Final information
# ============================================================

echo
echo "============================================================"
echo " ГОТОВО"
echo "============================================================"
echo
echo "Hostname:"
echo "  ${HOSTNAME_VALUE}"
echo
echo "SSH:"
echo "  Port:          ${SSH_PORT}"
echo "  Root:          public key"
echo "  Password:      OFF"
echo
echo "Подключение:"
echo
echo "  ssh -i ${KEY_PATH} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Локальный ключ:"
echo
echo "  ${KEY_PATH}"
echo
echo "Public key:"
echo
echo "  ${PUBLIC_KEY_PATH}"
echo
echo "UFW:"
echo "  Incoming:      DENY"
echo "  Outgoing:      ALLOW"
echo "  SSH:           ${SSH_PORT}/tcp"

if [[ "${#ADDITIONAL_PORTS[@]}" -gt 0 ]]; then
    echo
    echo "Дополнительные TCP-порты:"
    for port in "${ADDITIONAL_PORTS[@]}"; do
        echo "  ${port}/tcp"
    done
fi

echo
echo "Fail2ban:"
echo "  SSH jail:      enabled"
echo "  Max retry:     5"
echo "  Find time:     10m"
echo "  Ban time:      1h"
echo
echo "Backup:"
echo "  ${BACKUP_ROOT}"
echo
echo "============================================================"
echo " СОХРАНИ ЭТИ ДАННЫЕ"
echo "============================================================"
echo
echo "SSH port: ${SSH_PORT}"
echo "SSH command: ssh -i ${KEY_PATH} -p ${SSH_PORT} root@SERVER_IP"
echo "Backup: ${BACKUP_ROOT}"
echo