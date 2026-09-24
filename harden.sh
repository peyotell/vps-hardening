#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Ubuntu 24.04 VPS Hardening
# ============================================================

SCRIPT_NAME="VPS Hardening"
SSH_HARDENING_CONFIG="/etc/ssh/sshd_config.d/99-vps-hardening.conf"
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
# Cleanup on error
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
# Current SSH configuration
# ------------------------------------------------------------

CURRENT_SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"

if [[ -z "${CURRENT_SSH_PORT}" ]]; then
    CURRENT_SSH_PORT="22"
fi

HOSTNAME_VALUE="$(hostname -s)"

echo
echo "============================================================"
echo " ${SCRIPT_NAME}"
echo "============================================================"
echo
echo "Hostname:       ${HOSTNAME_VALUE}"
echo "Current SSH:    ${CURRENT_SSH_PORT}"
echo
echo "Внимание:"
echo "  - не закрывай текущую SSH-сессию до окончания проверки;"
echo "  - после изменения SSH открой второй терминал;"
echo "  - убедись, что новый SSH-вход работает;"
echo "  - только после этого парольная авторизация будет отключена."
echo

read -rp "Продолжить? [y/N]: " CONFIRM

if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ------------------------------------------------------------
# Ask for SSH port
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "Новый SSH-порт"
echo "------------------------------------------------------------"

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
# SSH public key instructions
# ------------------------------------------------------------

KEY_NAME="vps_${HOSTNAME_VALUE}_root_ed25519"

echo
echo "------------------------------------------------------------"
echo "SSH public key"
echo "------------------------------------------------------------"

echo
echo "Теперь открой ВТОРОЙ терминал НА СВОЁМ КОМПЬЮТЕРЕ."
echo
echo "Скрипт предлагает отдельное имя ключа:"
echo
echo "  ~/.ssh/${KEY_NAME}"
echo
echo "Это позволит не путать его с другими SSH-ключами."
echo
echo "Во втором терминале выполни:"
echo
echo "  ssh-keygen -t ed25519 -f ~/.ssh/${KEY_NAME}"
echo
echo "Если файл уже существует, НЕ перезаписывай его."
echo "В этом случае используй другое имя, например:"
echo
echo "  ~/.ssh/${KEY_NAME}_2"
echo
echo "После создания ключа выполни:"
echo
echo "  cat ~/.ssh/${KEY_NAME}.pub"
echo
echo "и вставь сюда ВСЮ строку, начинающуюся с ssh-ed25519."
echo

read -rp "Нажми Enter, когда ключ будет готов..."

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
        warning "RSA-ключ принят, но для нового ключа лучше использовать Ed25519."
        break
    fi

    warning "Похоже, это не корректный SSH public key."
    echo "Ожидаемый формат:"
    echo "ssh-ed25519 AAAA... optional-comment"
done

success "SSH public key принят."

# ------------------------------------------------------------
# Ask for additional public TCP ports
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "Дополнительные TCP-порты"
echo "------------------------------------------------------------"

echo "Текущие TCP-порты, которые слушают сервисы:"
echo

ss -ltnp | sed '1d' || true

echo
echo "Укажи порты, которые должны быть доступны ИЗ ИНТЕРНЕТА."
echo
echo "Например:"
echo "  80 443"
echo
echo "Если дополнительных портов нет — просто нажми Enter."
echo
echo "Не добавляй сюда PostgreSQL (5432), Redis (6379) и"
echo "другие внутренние сервисы, если они не должны быть"
echo "доступны напрямую из Интернета."
echo

read -rp "Дополнительные TCP-порты: " ADDITIONAL_PORTS

# ------------------------------------------------------------
# Confirmation
# ------------------------------------------------------------

echo
echo "============================================================"
echo "Проверь настройки"
echo "============================================================"
echo
echo "SSH port:                 ${CURRENT_SSH_PORT} -> ${SSH_PORT}"
echo "Root SSH login:           разрешён по ключу"
echo "Password authentication:  будет отключена ПОСЛЕ проверки"
echo "Public key:               ${SSH_PUBLIC_KEY%% *} ..."
echo "Additional TCP ports:     ${ADDITIONAL_PORTS:-нет}"
echo "UFW:                      включить"
echo "Fail2ban:                 включить"
echo "Automatic updates:        включить"
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

cp -a /etc/ssh "${BACKUP_DIR}/ssh"
cp -a /etc/ufw "${BACKUP_DIR}/ufw" 2>/dev/null || true
cp -a /etc/fail2ban "${BACKUP_DIR}/fail2ban" 2>/dev/null || true

success "Backup создан: ${BACKUP_DIR}"

# ------------------------------------------------------------
# System update
# ------------------------------------------------------------

info "Обновляем список пакетов..."

apt-get update

info "Обновляем систему..."

DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::="--force-confold" \
    full-upgrade -y

success "Система обновлена."

# ------------------------------------------------------------
# Install required packages
# ------------------------------------------------------------

info "Устанавливаем необходимые пакеты..."

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-server \
    ufw \
    fail2ban \
    unattended-upgrades

success "Необходимые пакеты установлены."

# ------------------------------------------------------------
# SSH authorized_keys
# ------------------------------------------------------------

info "Настраиваем root authorized_keys..."

mkdir -p /root/.ssh
chmod 700 /root/.ssh

touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if ! grep -Fqx "${SSH_PUBLIC_KEY}" /root/.ssh/authorized_keys; then
    echo "${SSH_PUBLIC_KEY}" >> /root/.ssh/authorized_keys
    success "Public key добавлен в /root/.ssh/authorized_keys."
else
    success "Public key уже существует в authorized_keys."
fi

# ------------------------------------------------------------
# SSH configuration
# ------------------------------------------------------------

info "Создаём SSH hardening configuration..."

cat > "${SSH_HARDENING_CONFIG}" <<EOF
# Managed by VPS Hardening script
# Created: $(date)

Port ${SSH_PORT}

PubkeyAuthentication yes

# Root login is allowed ONLY using public key authentication.
PermitRootLogin prohibit-password

# Password authentication will be disabled after manual verification.
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
    error "Backup находится здесь: ${BACKUP_DIR}"
    exit 1
fi

success "Конфигурация SSH корректна."

# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

info "Настраиваем UFW..."

ufw default deny incoming
ufw default allow outgoing

# Allow new SSH port.
ufw allow "${SSH_PORT}/tcp" comment 'SSH'

# Additional user-defined ports.
if [[ -n "${ADDITIONAL_PORTS}" ]]; then
    for PORT in ${ADDITIONAL_PORTS}; do

        if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
            warning "Пропускаю некорректный порт: ${PORT}"
            continue
        fi

        if (( PORT < 1 || PORT > 65535 )); then
            warning "Пропускаю некорректный порт: ${PORT}"
            continue
        fi

        ufw allow "${PORT}/tcp" comment 'User requested'
    done
fi

# ------------------------------------------------------------
# Enable UFW
# ------------------------------------------------------------

if ufw status | grep -q "Status: active"; then
    success "UFW уже был активен."
else
    echo
    warning "Сейчас будет включён UFW."
    echo "Новый SSH-порт ${SSH_PORT}/tcp уже разрешён."
    echo

    ufw --force enable
fi

success "UFW настроен."

# ------------------------------------------------------------
# Reload SSH
# ------------------------------------------------------------

info "Перезагружаем SSH..."

systemctl reload ssh

success "SSH перезагружен."

# ------------------------------------------------------------
# Manual SSH verification
# ------------------------------------------------------------

echo
echo "============================================================"
echo " ОБЯЗАТЕЛЬНАЯ ПРОВЕРКА SSH"
echo "============================================================"
echo
echo "НЕ ЗАКРЫВАЙ ЭТОТ ТЕРМИНАЛ."
echo
echo "Теперь во ВТОРОМ терминале НА ТВОЁМ КОМПЬЮТЕРЕ выполни:"
echo
echo "  ssh -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Если ключ имеет нестандартное имя, используй:"
echo
echo "  ssh -i ~/.ssh/${KEY_NAME} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Ты ДОЛЖЕН успешно войти на сервер."
echo
echo "Проверить можно командой:"
echo
echo "  echo \$SSH_CONNECTION"
echo
echo "Если вход НЕ работает — НЕ продолжай."
echo "Используй текущую SSH-сессию для исправления проблемы."
echo

read -rp "Новый SSH-вход успешно работает? [y/N]: " SSH_TEST

if [[ ! "${SSH_TEST}" =~ ^[Yy]$ ]]; then
    warning "Парольная авторизация НЕ будет отключена."
    warning "Текущая SSH-сессия сохранена."
    echo
    echo "Проверь конфигурацию вручную."
    echo
    exit 1
fi

success "Новый SSH-вход подтверждён."

# ------------------------------------------------------------
# Disable password authentication
# ------------------------------------------------------------

info "Отключаем парольную SSH-аутентификацию..."

cat > "${SSH_HARDENING_CONFIG}" <<EOF
# Managed by VPS Hardening script
# Created: $(date)

Port ${SSH_PORT}

PubkeyAuthentication yes

# Root login is allowed only with public key authentication.
PermitRootLogin prohibit-password

PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

chmod 600 "${SSH_HARDENING_CONFIG}"

if ! sshd -t; then
    error "Новая SSH-конфигурация некорректна."
    error "Password authentication НЕ будет отключена."
    exit 1
fi

systemctl reload ssh

success "Password authentication отключена."

# ------------------------------------------------------------
# Fail2ban
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

if systemctl is-active --quiet fail2ban; then
    success "Fail2ban запущен."
else
    warning "Fail2ban не запустился. Проверь: systemctl status fail2ban"
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
# Final status
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo " VPS HARDENING ЗАВЕРШЁН"
echo "============================================================"
echo

echo "Система:"
echo "  OS:              ${PRETTY_NAME}"

echo
echo "SSH:"
echo "  Старый порт:     ${CURRENT_SSH_PORT}"
echo "  Новый порт:      ${SSH_PORT}"
echo "  Root login:      только SSH public key"
echo "  Password auth:   отключена"
echo "  Public key:      установлен"

echo
echo "Firewall:"
echo "  UFW:             $(ufw status | head -n 1)"
echo
ufw status numbered

echo
echo "Fail2ban:"
systemctl is-active fail2ban || true

echo
echo "SSH listening:"
ss -ltnp | grep sshd || true

echo
echo "Открытые TCP-порты:"
ss -ltnp

echo
echo "SSH effective configuration:"
sshd -T | grep -E \
    '^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication) '

echo
echo "Backup:"
echo "  ${BACKUP_DIR}"

echo
echo "============================================================"
echo " ДАННЫЕ ДЛЯ СОХРАНЕНИЯ"
echo "============================================================"
echo
echo "Server:            $(hostname -f 2>/dev/null || hostname)"
echo "SSH user:          root"
echo "SSH port:          ${SSH_PORT}"
echo "SSH command:"
echo "  ssh -p ${SSH_PORT} root@SERVER_IP"
echo
echo "Если ключ имеет нестандартное имя:"
echo "  ssh -i ~/.ssh/${KEY_NAME} -p ${SSH_PORT} root@SERVER_IP"
echo
echo "SSH public key:"
echo "  ${SSH_PUBLIC_KEY}"
echo
echo "Backup:"
echo "  ${BACKUP_DIR}"
echo
echo "Проверка Fail2ban:"
echo "  sudo fail2ban-client status sshd"
echo
echo "Проверка UFW:"
echo "  sudo ufw status numbered"
echo
echo "Проверка SSH:"
echo "  sudo sshd -T"
echo
echo "============================================================"
echo
warning "НЕ ЗАБУДЬ СОХРАНИТЬ SSH PRIVATE KEY."
warning "Без него войти на сервер после отключения пароля будет нельзя."
echo
