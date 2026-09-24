#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Ubuntu 24.04 VPS Hardening
# ============================================================

SCRIPT_NAME="VPS Hardening"

# 00- prefix is intentional:
# sshd uses the first value it encounters for most directives.
SSH_HARDENING_CONFIG="/etc/ssh/sshd_config.d/00-vps-hardening.conf"

FAIL2BAN_CONFIG="/etc/fail2ban/jail.d/sshd-vps-hardening.local"

BACKUP_DIR="/root/vps-hardening-backup-$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

die() {
    error "$1"
    exit 1
}

# ------------------------------------------------------------
# Error handler
# ------------------------------------------------------------

trap 'error "Скрипт завершился с ошибкой на строке $LINENO."' ERR

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Запусти скрипт от root: sudo ./harden.sh"
fi

# ------------------------------------------------------------
# OS check
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    die "Не удалось определить операционную систему."
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" ]]; then
    die "Этот скрипт рассчитан на Ubuntu 24.04 LTS. Обнаружено: ${PRETTY_NAME}"
fi

success "Обнаружена Ubuntu 24.04 LTS."

# ------------------------------------------------------------
# Basic information
# ------------------------------------------------------------

HOSTNAME_VALUE="$(hostname -s)"

echo
echo "============================================================"
echo " ${SCRIPT_NAME}"
echo "============================================================"
echo
echo "Hostname: ${HOSTNAME_VALUE}"
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

read -rp "Продолжить? [y/N]: " CONFIRM

if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ------------------------------------------------------------
# Install/update package information
# ------------------------------------------------------------

info "Обновляем список пакетов..."

apt-get update

info "Устанавливаем необходимые пакеты..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server \
    ufw \
    fail2ban \
    unattended-upgrades

success "Необходимые пакеты установлены."

# ------------------------------------------------------------
# Detect current SSH port
# ------------------------------------------------------------

info "Определяем текущий SSH-порт..."

CURRENT_SSH_PORT="$(
    ss -ltnp 2>/dev/null |
        awk '
            /sshd/ {
                n = split($4, parts, ":")
                port = parts[n]

                if (port ~ /^[0-9]+$/) {
                    print port
                    exit
                }
            }
        '
)"

if [[ -z "${CURRENT_SSH_PORT}" ]]; then
    CURRENT_SSH_PORT="22"
    warning "Не удалось определить порт sshd. Используем 22."
fi

success "Текущий SSH-порт: ${CURRENT_SSH_PORT}"

# ------------------------------------------------------------
# Detect SSH service
# ------------------------------------------------------------

if systemctl is-active --quiet ssh.service; then
    SSH_SERVICE="ssh.service"
elif systemctl is-active --quiet sshd.service; then
    SSH_SERVICE="sshd.service"
else
    die "SSH service не запущен."
fi

success "SSH service: ${SSH_SERVICE}"

# ------------------------------------------------------------
# Ask for new SSH port
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "Новый SSH-порт"
echo "------------------------------------------------------------"
echo

while true; do
    read -rp "Новый SSH-порт [22222]: " SSH_PORT

    SSH_PORT="${SSH_PORT:-22222}"

    if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]]; then
        warning "Порт должен быть числом."
        continue
    fi

    if (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
        warning "Используй порт от 1024 до 65535."
        continue
    fi

    if [[ "${SSH_PORT}" == "${CURRENT_SSH_PORT}" ]]; then
        warning "Новый порт совпадает с текущим SSH-портом."
        continue
    fi

    if ss -ltn | awk '{print $4}' | grep -Eq ":${SSH_PORT}$"; then
        warning "Порт ${SSH_PORT} уже используется."
        continue
    fi

    break
done

success "Новый SSH-порт: ${SSH_PORT}"

# ------------------------------------------------------------
# SSH key instructions
# ------------------------------------------------------------

KEY_NAME="vps_${HOSTNAME_VALUE}_root_ed25519"

echo
echo "------------------------------------------------------------"
echo "SSH public key"
echo "------------------------------------------------------------"
echo

echo "Теперь открой ВТОРОЙ терминал НА СВОЁМ КОМПЬЮТЕРЕ."
echo
echo "Рекомендуемое имя ключа:"
echo
echo "  ~/.ssh/${KEY_NAME}"
echo
echo "Если такой файл уже существует, НЕ перезаписывай его."
echo "Используй другое имя, например:"
echo
echo "  ~/.ssh/${KEY_NAME}_2"
echo
echo "Создание ключа:"
echo
echo "  ssh-keygen -t ed25519 -f ~/.ssh/${KEY_NAME}"
echo
echo "Можно задать passphrase для приватного ключа."
echo
echo "После создания выполни:"
echo
echo "  cat ~/.ssh/${KEY_NAME}.pub"
echo
echo "и вставь сюда всю строку public key."
echo

read -rp "Нажми Enter, когда public key будет готов..."

# ------------------------------------------------------------
# Ask for public key
# ------------------------------------------------------------

while true; do

    echo
    read -rp "Вставь SSH public key: " SSH_PUBLIC_KEY

    SSH_PUBLIC_KEY="$(echo "${SSH_PUBLIC_KEY}" | xargs)"

    if [[ "${SSH_PUBLIC_KEY}" =~ ^ssh-ed25519[[:space:]][^[:space:]]+([[:space:]].*)?$ ]]; then
        break
    fi

    if [[ "${SSH_PUBLIC_KEY}" =~ ^ecdsa-sha2-nistp256[[:space:]][^[:space:]]+([[:space:]].*)?$ ]]; then
        break
    fi

    if [[ "${SSH_PUBLIC_KEY}" =~ ^ssh-rsa[[:space:]][^[:space:]]+([[:space:]].*)?$ ]]; then
        warning "RSA-ключ принят."
        warning "Для нового ключа предпочтителен Ed25519."
        break
    fi

    warning "Не удалось распознать SSH public key."
    echo
    echo "Пример:"
    echo
    echo "ssh-ed25519 AAAA... comment"
    echo
done

success "SSH public key принят."

# ------------------------------------------------------------
# Ask for additional ports
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "Дополнительные TCP-порты"
echo "------------------------------------------------------------"
echo

echo "Сейчас слушают:"
echo

ss -ltnp || true

echo
echo "Укажи порты, которые должны быть доступны"
echo "ИЗ ИНТЕРНЕТА."
echo
echo "Например:"
echo
echo "  80 443"
echo
echo "Если дополнительных портов нет — Enter."
echo
echo "Не открывай PostgreSQL, Redis и другие внутренние"
echo "сервисы без необходимости."
echo

read -rp "Дополнительные TCP-порты: " ADDITIONAL_PORTS

# ------------------------------------------------------------
# Configuration summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Проверь настройки"
echo "============================================================"
echo
echo "Current SSH port:        ${CURRENT_SSH_PORT}"
echo "New SSH port:            ${SSH_PORT}"
echo "Root login:              разрешён"
echo "Root authentication:     public key"
echo "Password auth:           отключится после проверки"
echo "Additional TCP ports:    ${ADDITIONAL_PORTS:-нет}"
echo "UFW:                     включить"
echo "Fail2ban:                включить"
echo "Automatic updates:       включить"
echo
echo "============================================================"
echo

read -rp "Все правильно? [y/N]: " CONFIRM

if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

info "Создаём резервную копию конфигурации..."

mkdir -p "${BACKUP_DIR}"

if [[ -d /etc/ssh ]]; then
    cp -a /etc/ssh "${BACKUP_DIR}/ssh"
fi

if [[ -d /etc/ufw ]]; then
    cp -a /etc/ufw "${BACKUP_DIR}/ufw"
fi

if [[ -d /etc/fail2ban ]]; then
    cp -a /etc/fail2ban "${BACKUP_DIR}/fail2ban"
fi

success "Backup создан:"
echo "  ${BACKUP_DIR}"

# ------------------------------------------------------------
# System upgrade
# ------------------------------------------------------------

info "Обновляем систему..."

DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::="--force-confold" \
    full-upgrade -y

success "Система обновлена."

# ------------------------------------------------------------
# Configure authorized_keys
# ------------------------------------------------------------

info "Настраиваем /root/.ssh/authorized_keys..."

mkdir -p /root/.ssh

chmod 700 /root/.ssh

touch /root/.ssh/authorized_keys

chmod 600 /root/.ssh/authorized_keys

if grep -Fqx "${SSH_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
    success "Public key уже существует."
else
    echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
    success "Public key добавлен."
fi

# ------------------------------------------------------------
# Create temporary SSH configuration
# ------------------------------------------------------------

info "Настраиваем SSH."

cat > "${SSH_HARDENING_CONFIG}" <<EOF
# ============================================================
# Managed by VPS Hardening
# ============================================================

# Temporary transition:
# both old and new SSH ports are active until manual verification.

Port ${CURRENT_SSH_PORT}
Port ${SSH_PORT}

PubkeyAuthentication yes

# Root login is allowed only with public key authentication.
PermitRootLogin prohibit-password

# Password authentication remains temporarily enabled.
# It will be disabled after manual verification.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

chmod 600 "${SSH_HARDENING_CONFIG}"

# ------------------------------------------------------------
# Validate SSH configuration
# ------------------------------------------------------------

info "Проверяем конфигурацию SSH..."

if ! sshd -t; then
    error "Конфигурация SSH содержит ошибку."
    error "Backup: ${BACKUP_DIR}"
    exit 1
fi

success "Конфигурация SSH корректна."

# ------------------------------------------------------------
# Configure UFW
# ------------------------------------------------------------

info "Настраиваем UFW..."

ufw default deny incoming
ufw default allow outgoing

# Keep current SSH port available during transition.
ufw allow "${CURRENT_SSH_PORT}/tcp" comment 'Temporary old SSH'

# Allow new SSH port.
ufw allow "${SSH_PORT}/tcp" comment 'SSH new port'

# Additional ports.
if [[ -n "${ADDITIONAL_PORTS}" ]]; then

    for PORT in ${ADDITIONAL_PORTS}; do

        if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
            warning "Некорректный порт пропущен: ${PORT}"
            continue
        fi

        if (( PORT < 1 || PORT > 65535 )); then
            warning "Порт вне диапазона пропущен: ${PORT}"
            continue
        fi

        if [[ "${PORT}" == "${CURRENT_SSH_PORT}" ||
              "${PORT}" == "${SSH_PORT}" ]]; then
            continue
        fi

        ufw allow "${PORT}/tcp" comment 'User requested'
    done

fi

# ------------------------------------------------------------
# Enable UFW
# ------------------------------------------------------------

if ufw status | grep -q "Status: active"; then
    success "UFW уже активен."
else
    info "Включаем UFW..."
    ufw --force enable
    success "UFW включён."
fi

# ------------------------------------------------------------
# SSH service / socket handling
# ------------------------------------------------------------

if systemctl is-active --quiet ssh.socket; then

    warning "Обнаружен ssh.socket."

    systemctl disable --now ssh.socket
    systemctl enable ssh.service

    success "Переходим на обычный ssh.service."

fi

# ------------------------------------------------------------
# Restart SSH
# ------------------------------------------------------------

info "Перезапускаем SSH..."

systemctl restart "${SSH_SERVICE}"

sleep 1

if ! systemctl is-active --quiet "${SSH_SERVICE}"; then
    error "SSH service не запустился."
    error "НЕ закрывай текущую SSH-сессию."
    error "Backup: ${BACKUP_DIR}"
    exit 1
fi

success "SSH перезапущен."

# ------------------------------------------------------------
# Verify both ports locally
# ------------------------------------------------------------

info "Проверяем SSH-порты..."

if ! ss -ltn | grep -Eq ":${CURRENT_SSH_PORT}[[:space:]]"; then
    warning "Старый SSH-порт ${CURRENT_SSH_PORT} не обнаружен."
fi

if ! ss -ltn | grep -Eq ":${SSH_PORT}[[:space:]]"; then
    error "Новый SSH-порт ${SSH_PORT} не слушается."
    error "НЕ закрывай текущую SSH-сессию."
    exit 1
fi

success "Новый SSH-порт ${SSH_PORT} слушается."

# ------------------------------------------------------------
# Manual verification
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo " ОБЯЗАТЕЛЬНАЯ ПРОВЕРКА SSH"
echo "============================================================"
echo
echo "ТЕКУЩИЙ ТЕРМИНАЛ НЕ ЗАКРЫВАЙ."
echo
echo "Открой ВТОРОЙ терминал на своём компьютере."
echo
echo "Выполни:"
echo
echo "  ssh -i ~/.ssh/${KEY_NAME} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Если ты использовал другое имя ключа — укажи его вместо"
echo "${KEY_NAME}."
echo
echo "В новом терминале должен произойти вход БЕЗ пароля"
echo "пользователя root."
echo
echo "После входа выполни:"
echo
echo "  echo \$SSH_CONNECTION"
echo
echo "Убедись, что подключение действительно произошло"
echo "через новый SSH-порт."
echo
echo "Если вход НЕ работает:"
echo
echo "  НЕ вводи y."
echo "  Оставь этот терминал открытым."
echo "  Исправь проблему здесь."
echo
echo "============================================================"
echo

read -rp "Новый SSH-вход по ключу успешно работает? [y/N]: " SSH_TEST

if [[ ! "${SSH_TEST}" =~ ^[Yy]$ ]]; then

    warning "Финальный этап НЕ выполнен."

    echo
    echo "Парольная авторизация остаётся включённой."
    echo "Старый SSH-порт остаётся разрешённым."
    echo
    echo "Текущая конфигурация безопасна для дальнейшей диагностики."
    echo
    echo "Backup:"
    echo "  ${BACKUP_DIR}"
    echo

    exit 1
fi

success "Новый SSH-вход подтверждён."

# ------------------------------------------------------------
# Final SSH configuration
# ------------------------------------------------------------

info "Переключаем SSH на окончательную конфигурацию..."

cat > "${SSH_HARDENING_CONFIG}" <<EOF
# ============================================================
# Managed by VPS Hardening
# ============================================================

Port ${SSH_PORT}

PubkeyAuthentication yes

# Root login is allowed only with public key authentication.
PermitRootLogin prohibit-password

PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

chmod 600 "${SSH_HARDENING_CONFIG}"

# ------------------------------------------------------------
# Validate final SSH configuration
# ------------------------------------------------------------

if ! sshd -t; then
    error "Финальная конфигурация SSH содержит ошибку."
    error "Старый SSH-порт пока НЕ удалён из UFW."
    error "Backup: ${BACKUP_DIR}"
    exit 1
fi

success "Финальная конфигурация SSH корректна."

# ------------------------------------------------------------
# Restart SSH with final configuration
# ------------------------------------------------------------

info "Перезапускаем SSH с финальной конфигурацией..."

systemctl restart "${SSH_SERVICE}"

sleep 1

if ! systemctl is-active --quiet "${SSH_SERVICE}"; then
    error "SSH service не запустился с финальной конфигурацией."
    error "НЕ закрывай текущую SSH-сессию."
    error "Backup: ${BACKUP_DIR}"
    exit 1
fi

success "Финальная SSH-конфигурация активна."

# ------------------------------------------------------------
# Remove old SSH port from UFW
# ------------------------------------------------------------

info "Удаляем старый SSH-порт из UFW..."

if ufw status | grep -Eq "^${CURRENT_SSH_PORT}/tcp"; then
    ufw delete allow "${CURRENT_SSH_PORT}/tcp" || true
fi

# Also try to remove the named temporary rule.
ufw delete allow "${CURRENT_SSH_PORT}/tcp" comment 'Temporary old SSH' 2>/dev/null || true

success "Старый SSH-порт больше не разрешён через UFW."

# ------------------------------------------------------------
# Configure Fail2ban
# ------------------------------------------------------------

info "Настраиваем Fail2ban..."

mkdir -p "$(dirname "${FAIL2BAN_CONFIG}")"

cat > "${FAIL2BAN_CONFIG}" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

chmod 644 "${FAIL2BAN_CONFIG}"

systemctl enable fail2ban
systemctl restart fail2ban

sleep 1

if systemctl is-active --quiet fail2ban; then
    success "Fail2ban запущен."
else
    warning "Fail2ban не запустился."
    warning "Проверь: systemctl status fail2ban"
fi

# ------------------------------------------------------------
# Automatic updates
# ------------------------------------------------------------

info "Настраиваем автоматические обновления..."

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable apt-daily.timer
systemctl enable apt-daily-upgrade.timer

success "Автоматические обновления включены."

# ------------------------------------------------------------
# Final diagnostics
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo " VPS HARDENING ЗАВЕРШЁН"
echo "============================================================"
echo

echo "SYSTEM"
echo "------------------------------------------------------------"
echo "OS:              ${PRETTY_NAME}"
echo "Hostname:        ${HOSTNAME_VALUE}"
echo

echo "SSH"
echo "------------------------------------------------------------"
echo "Old port:        ${CURRENT_SSH_PORT}"
echo "New port:        ${SSH_PORT}"
echo "User:            root"
echo "Root login:      public key only"
echo "Password auth:   disabled"
echo "Public key:      installed"
echo

echo "UFW"
echo "------------------------------------------------------------"
ufw status verbose
echo

echo "UFW numbered rules"
echo "------------------------------------------------------------"
ufw status numbered
echo

echo "LISTENING TCP PORTS"
echo "------------------------------------------------------------"
ss -ltnp
echo

echo "FAIL2BAN"
echo "------------------------------------------------------------"

if systemctl is-active --quiet fail2ban; then
    echo "Service: active"
    fail2ban-client status sshd 2>/dev/null || true
else
    echo "Service: inactive"
fi

echo

echo "SSH EFFECTIVE CONFIGURATION"
echo "------------------------------------------------------------"

if SSH_CONFIG="$(sshd -T 2>&1)"; then

    echo "${SSH_CONFIG}" |
        grep -E \
        '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '

else

    warning "Не удалось получить effective SSH configuration."
    echo "${SSH_CONFIG}"
fi

echo

echo "SERVICES"
echo "------------------------------------------------------------"
echo "SSH:"
systemctl is-active "${SSH_SERVICE}" || true

echo "UFW:"
ufw status | head -n 1

echo "Fail2ban:"
systemctl is-active fail2ban || true

echo

echo "BACKUP"
echo "------------------------------------------------------------"
echo "${BACKUP_DIR}"

echo

echo "============================================================"
echo " ДАННЫЕ ДЛЯ СОХРАНЕНИЯ"
echo "============================================================"
echo

echo "Server:"
echo "  ${HOSTNAME_VALUE}"

echo

echo "SSH user:"
echo "  root"

echo

echo "SSH port:"
echo "  ${SSH_PORT}"

echo

echo "SSH command:"
echo "  ssh -p ${SSH_PORT} root@SERVER_IP"

echo

echo "SSH command with explicit key:"
echo "  ssh -i ~/.ssh/${KEY_NAME} -p ${SSH_PORT} root@SERVER_IP"

echo

echo "SSH private key:"
echo "  ~/.ssh/${KEY_NAME}"

echo

echo "SSH public key:"
echo "  ~/.ssh/${KEY_NAME}.pub"

echo

echo "Fail2ban:"
echo "  sudo fail2ban-client status sshd"

echo

echo "UFW:"
echo "  sudo ufw status numbered"

echo

echo "SSH configuration:"
echo "  sudo sshd -t"

echo

echo "SSH logs:"
echo "  sudo journalctl -u ssh.service -n 50"

echo

echo "Backup:"
echo "  ${BACKUP_DIR}"

echo
echo "============================================================"
echo
warning "СОХРАНИ ПРИВАТНЫЙ SSH-КЛЮЧ."
warning "Без него войти на сервер после отключения пароля будет нельзя."
echo
success "Готово."