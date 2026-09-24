#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="VPS Hardening"
CONFIG_FILE="/etc/ssh/sshd_config.d/00-vps-hardening.conf"
BACKUP_ROOT="/root/vps-hardening-backup-$(date +%Y%m%d-%H%M%S)"

# ============================================================
# Colors / output
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
# Interactive input
# ============================================================

ask() {
    local prompt="$1"
    local default="${2:-}"
    local answer=""

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer < /dev/tty || true
        echo "${answer:-$default}"
    else
        read -r -p "$prompt: " answer < /dev/tty || true
        echo "$answer"
    fi
}

confirm() {
    local answer=""

    while true; do
        read -r -p "$1 [y/N]: " answer < /dev/tty || true

        case "$answer" in
            y|Y|yes|YES|д|Д|да|ДА)
                return 0
                ;;
            n|N|no|NO|н|Н|нет|НЕТ|"")
                return 1
                ;;
            *)
                echo "Введите y или n."
                ;;
        esac
    done
}

pause() {
    echo
    read -r -p "Нажми Enter для продолжения..." _ < /dev/tty || true
}

# ============================================================
# Root
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    die "Запусти скрипт от root: sudo bash harden.sh"
fi

# ============================================================
# OS check
# ============================================================

if [[ ! -r /etc/os-release ]]; then
    die "Не найден /etc/os-release."
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    die "Поддерживается только Ubuntu."
fi

if [[ "${VERSION_ID}" != "24.04" ]]; then
    die "Ожидалась Ubuntu 24.04 LTS, обнаружена ${PRETTY_NAME}."
fi

log "Обнаружена Ubuntu 24.04 LTS."

# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo " $SCRIPT_NAME"
echo "============================================================"
echo
echo "Hostname: $(hostname)"
echo
echo "ВНИМАНИЕ:"
echo
echo "  1. Не закрывай текущую SSH-сессию."
echo "  2. Скрипт временно оставит старый SSH-порт рабочим."
echo "  3. Новый SSH-порт будет работать одновременно со старым."
echo "  4. Ты проверишь новый вход во втором терминале."
echo "  5. Только после успешной проверки старый порт"
echo "     и парольная авторизация будут отключены."
echo

if ! confirm "Продолжить?"; then
    echo "Отменено."
    exit 0
fi

# ============================================================
# Basic variables
# ============================================================

HOSTNAME_VALUE="$(hostname)"

# ============================================================
# Package installation / updates
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
# Normalize SSH socket/service
# ============================================================

echo
echo "============================================================"
echo " Проверка SSH"
echo "============================================================"
echo

# Ubuntu может использовать ssh.socket.
# Для нашего сценария проще использовать обычный ssh.service.

if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    warn "Обнаружен активный ssh.socket."

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
# Detect current SSH port
# ============================================================

CURRENT_SSH_PORT="$(
    ss -ltnp 2>/dev/null |
        grep -E 'sshd|/sshd' |
        sed -n 's/.*:\([0-9]\+\) .*sshd.*/\1/p' |
        head -n1
)"

if [[ -z "${CURRENT_SSH_PORT}" ]]; then
    CURRENT_SSH_PORT="$(
        ss -ltn 2>/dev/null |
            awk '$4 ~ /:[0-9]+$/ {
                sub(/^.*:/, "", $4);
                if ($4 ~ /^[0-9]+$/) {
                    print $4;
                    exit
                }
            }'
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
echo "Выбери новый SSH-порт."
echo "Рекомендуется использовать порт выше 1024, например 2222, 22022 и т.п."
echo

while true; do
    SSH_PORT="$(ask "Новый SSH-порт")"

    if [[ ! "${SSH_PORT}" =~ ^[0-9]+$ ]]; then
        echo "Порт должен быть числом."
        continue
    fi

    if (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
        echo "Используй порт от 1024 до 65535."
        continue
    fi

    if [[ "${SSH_PORT}" == "${CURRENT_SSH_PORT}" ]]; then
        echo "Новый порт должен отличаться от текущего."
        continue
    fi

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${SSH_PORT}$"; then
        echo "Этот порт уже занят."
        continue
    fi

    break
done

log "Новый SSH-порт: ${SSH_PORT}"

# ============================================================
# SSH key name
# ============================================================

DEFAULT_KEY_NAME="vps_${HOSTNAME_VALUE}_root_ed25519"

echo
echo "============================================================"
echo " SSH-ключ"
echo "============================================================"
echo
echo "Создай новый ключ на СВОЁМ компьютере во втором терминале."
echo
echo "Например:"
echo
echo "  ssh-keygen -t ed25519 -f ~/.ssh/${DEFAULT_KEY_NAME}"
echo
echo "Если такой файл уже существует — выбери другое имя."
echo
echo "После создания выполни:"
echo
echo "  cat ~/.ssh/${DEFAULT_KEY_NAME}.pub"
echo
echo "И вставь сюда содержимое .pub-файла."
echo

KEY_NAME="$(ask "Имя ключа без ~/.ssh/ [${DEFAULT_KEY_NAME}]" "${DEFAULT_KEY_NAME}")"

if [[ ! "${KEY_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Недопустимое имя ключа."
fi

KEY_PATH_DISPLAY="~/.ssh/${KEY_NAME}"
KEY_PUBLIC_PATH_DISPLAY="${KEY_PATH_DISPLAY}.pub"

echo
echo "На локальном компьютере выполни:"
echo
echo "  ssh-keygen -t ed25519 -f ${KEY_PATH_DISPLAY}"
echo
echo "Затем:"
echo
echo "  cat ${KEY_PUBLIC_PATH_DISPLAY}"
echo

while true; do
    SSH_PUBLIC_KEY="$(ask "Вставь SSH public key")"

    # trim leading/trailing whitespace without changing internal spaces
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY#"${SSH_PUBLIC_KEY%%[![:space:]]*}"}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY%"${SSH_PUBLIC_KEY##*[![:space:]]}"}"

    if [[ "${SSH_PUBLIC_KEY}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
        break
    fi

    echo
    echo "Похоже, это невалидный SSH public key."
    echo "Ожидается строка вида:"
    echo
    echo "  ssh-ed25519 AAAA..."
    echo
done

log "SSH public key принят."

# ============================================================
# Additional TCP ports
# ============================================================

echo
echo "============================================================"
echo " Дополнительные TCP-порты"
echo "============================================================"
echo
echo "Например:"
echo "  80,443"
echo
echo "Если дополнительные порты не нужны — оставь пустым."
echo

ADDITIONAL_PORTS_RAW="$(ask "Дополнительные TCP-порты")"

ADDITIONAL_PORTS=()

if [[ -n "${ADDITIONAL_PORTS_RAW}" ]]; then
    IFS=',' read -ra PORT_LIST <<< "${ADDITIONAL_PORTS_RAW}"

    for port in "${PORT_LIST[@]}"; do
        port="$(echo "${port}" | xargs)"

        if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
            die "Некорректный TCP-порт: ${port}"
        fi

        if (( port < 1 || port > 65535 )); then
            die "Порт вне диапазона 1-65535: ${port}"
        fi

        if [[ "${port}" == "${CURRENT_SSH_PORT}" || "${port}" == "${SSH_PORT}" ]]; then
            die "SSH-порт не нужно добавлять в список дополнительных портов."
        fi

        ADDITIONAL_PORTS+=("${port}")
    done
fi

# ============================================================
# Summary / confirmation
# ============================================================

echo
echo "============================================================"
echo " Параметры"
echo "============================================================"
echo
echo "Hostname:             ${HOSTNAME_VALUE}"
echo "Старый SSH-порт:      ${CURRENT_SSH_PORT}"
echo "Новый SSH-порт:       ${SSH_PORT}"
echo "Root SSH:             разрешён"
echo "Пароль SSH:           будет отключён после проверки"
echo "SSH key:              ${KEY_PATH_DISPLAY}"
echo "Доп. TCP-порты:       ${ADDITIONAL_PORTS_RAW:-нет}"
echo

if ! confirm "Начать настройку?"; then
    echo "Отменено."
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

mkdir -p "${BACKUP_ROOT}"

cp -a /etc/ssh "${BACKUP_ROOT}/ssh"
cp -a /etc/ufw "${BACKUP_ROOT}/ufw"
cp -a /etc/fail2ban "${BACKUP_ROOT}/fail2ban"

log "Backup: ${BACKUP_ROOT}"

# ============================================================
# Authorized keys
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
chown -R root:root /root/.ssh

if ! grep -Fqx "${SSH_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
    echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
fi

log "SSH public key установлен."

# ============================================================
# Temporary SSH configuration
# ============================================================

echo
echo "============================================================"
echo " Временная SSH-конфигурация"
echo "============================================================"
echo

cat > "${CONFIG_FILE}" <<EOF
# Managed by VPS Hardening
# Temporary configuration

Port ${CURRENT_SSH_PORT}
Port ${SSH_PORT}

PubkeyAuthentication yes
PermitRootLogin prohibit-password

# Password remains globally enabled temporarily,
# but root password login is blocked by PermitRootLogin.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

chmod 644 "${CONFIG_FILE}"

# Validate before restart.
sshd -t

log "SSH-конфигурация прошла проверку."

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

# IMPORTANT:
# Keep BOTH ports available until the new SSH login is tested.
ufw allow "${CURRENT_SSH_PORT}/tcp" comment "Temporary old SSH"
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
# Verify both ports
# ============================================================

echo
echo "Проверка SSH-портов..."

if ! ss -ltn | grep -Eq ":${CURRENT_SSH_PORT}[[:space:]]"; then
    die "Старый SSH-порт ${CURRENT_SSH_PORT} не слушается."
fi

if ! ss -ltn | grep -Eq ":${SSH_PORT}[[:space:]]"; then
    die "Новый SSH-порт ${SSH_PORT} не слушается."
fi

log "Старый порт ${CURRENT_SSH_PORT} работает."
log "Новый порт ${SSH_PORT} работает."

# ============================================================
# Manual SSH test
# ============================================================

echo
echo "============================================================"
echo " ПРОВЕРКА НОВОГО SSH-ПОДКЛЮЧЕНИЯ"
echo "============================================================"
echo
echo "НЕ ЗАКРЫВАЙ ЭТУ СЕССИЮ."
echo
echo "Открой второй терминал на своём компьютере."
echo
echo "Выполни:"
echo
echo "  ssh -i ${KEY_PATH_DISPLAY} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "После успешного входа выполни во втором терминале:"
echo
echo "  echo 'NEW SSH CONNECTION OK'"
echo
echo "Если всё работает — вернись сюда."
echo

if ! confirm "Новый SSH-вход успешно проверен?"; then
    echo
    warn "Оставляю старый порт и парольную конфигурацию."
    echo
    echo "Текущий SSH-порт: ${CURRENT_SSH_PORT}"
    echo "Новый SSH-порт:   ${SSH_PORT}"
    echo
    echo "Скрипт остановлен безопасно."
    exit 0
fi

# ============================================================
# Final SSH hardening
# ============================================================

echo
echo "============================================================"
echo " Финальная SSH-конфигурация"
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

# Verify final SSH port.
if ! ss -ltn | grep -Eq ":${SSH_PORT}[[:space:]]"; then
    die "После финального перезапуска SSH новый порт не слушается."
fi

log "Парольная SSH-аутентификация отключена."
log "Root SSH через public key оставлен."
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
echo " Настройка Fail2ban"
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
    warn "Fail2ban не запустился. Проверь: systemctl status fail2ban"
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
# Final verification
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
echo "SSH service:          ${SSH_SERVICE}"
echo "SSH port:             ${SSH_PORT}"
echo "Root login:           prohibit-password"
echo "Password auth:        disabled"
echo "Public key auth:      enabled"
echo "Private key (local):  ${KEY_PATH_DISPLAY}"

echo
echo "----- Listening ports -----"
ss -ltnp | grep -E 'sshd|:80 |:443 |:36028 ' || true

echo
echo "----- UFW -----"
ufw status verbose
echo
ufw status numbered

echo
echo "----- Fail2ban -----"
fail2ban-client status || true

echo
echo "----- SSH effective config -----"

if sshd -T >/tmp/vps-hardening-sshd-test.txt 2>/dev/null; then
    grep -E '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) ' \
        /tmp/vps-hardening-sshd-test.txt || true
else
    warn "Не удалось получить полный sshd -T вывод."
fi

rm -f /tmp/vps-hardening-sshd-test.txt

echo
echo "----- Services -----"
systemctl is-active "${SSH_SERVICE}" || true
systemctl is-active ufw || true
systemctl is-active fail2ban || true

# ============================================================
# Final information
# ============================================================

echo
echo "============================================================"
echo " ГОТОВО"
echo "============================================================"
echo
echo "Сервер:              ${HOSTNAME_VALUE}"
echo
echo "SSH:"
echo "  Порт:              ${SSH_PORT}"
echo "  Root:              public key"
echo "  Password auth:     OFF"
echo
echo "Подключение:"
echo
echo "  ssh -i ${KEY_PATH_DISPLAY} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Локальный ключ:"
echo
echo "  ${KEY_PATH_DISPLAY}"
echo
echo "Публичный ключ:"
echo
echo "  ${KEY_PUBLIC_PATH_DISPLAY}"
echo
echo "UFW:"
echo "  Incoming:          DENY by default"
echo "  Outgoing:          ALLOW by default"
echo "  SSH:               ${SSH_PORT}/tcp"
echo

if [[ "${#ADDITIONAL_PORTS[@]}" -gt 0 ]]; then
    echo "Дополнительные TCP-порты:"
    for port in "${ADDITIONAL_PORTS[@]}"; do
        echo "  ${port}/tcp"
    done
else
    echo "Дополнительные TCP-порты: нет"
fi

echo
echo "Fail2ban:"
echo "  SSH jail:          enabled"
echo "  Max retry:         5"
echo "  Find time:         10m"
echo "  Ban time:          1h"
echo
echo "Автоматические обновления: enabled"
echo
echo "Backup:"
echo "  ${BACKUP_ROOT}"
echo
echo "============================================================"
echo " СОХРАНИ ЭТИ ДАННЫЕ"
echo "============================================================"
echo
echo "SSH port: ${SSH_PORT}"
echo "SSH command: ssh -i ${KEY_PATH_DISPLAY} -p ${SSH_PORT} root@SERVER_IP"
echo "Backup: ${BACKUP_ROOT}"
echo