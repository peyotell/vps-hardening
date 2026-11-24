echo
echo "==> [2/4] SSH"

install_key() {
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    if grep -qF "$1" /root/.ssh/authorized_keys; then
        echo "Этот ключ уже есть в authorized_keys."
    else
        echo "$1" >> /root/.ssh/authorized_keys
        echo "Ключ добавлен в /root/.ssh/authorized_keys."
    fi
}

if [[ -s /root/.ssh/authorized_keys ]]; then
    echo "В /root/.ssh/authorized_keys уже есть ключей: $(grep -c . /root/.ssh/authorized_keys)"
    add_key=$(ask "Добавить ещё один публичный ключ? [y/N]: " "n")
else
    echo "На сервере нет ни одного ключа. Отключать парольный вход без ключа нельзя —"
    echo "иначе потеряете доступ. Вставьте публичный ключ клиента."
    add_key="y"
fi

if [[ $add_key =~ ^([yY]|[дД])$ ]]; then
    key=$(ask "Публичный ключ одной строкой: ")
    while [[ ! $key =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)[[:space:]] ]]; do
        echo "Строка не похожа на публичный ключ (ожидается 'ssh-ed25519 AAAA...')."
        key=$(ask "Публичный ключ одной строкой: ")
    done
    install_key "$key"
fi

if [[ ! -s /root/.ssh/authorized_keys ]]; then
    echo "Ошибка: нет ни одного ключа, настройка SSH прервана." >&2
    exit 1
fi

mkdir -p /etc/ssh/sshd_config.d
# Файл должен идти по алфавиту раньше 60-cloudimg-settings.conf: sshd берёт первое значение параметра
cat > /etc/ssh/sshd_config.d/00-custom.conf <<EOF
Port $SSH_PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF

sshd -t

if systemctl list-unit-files | grep -q '^ssh\.socket'; then
    systemctl disable --now ssh.socket
    systemctl enable ssh.service
fi
systemctl restart ssh.service

echo "SSH: порт $SSH_PORT, вход только по ключу (root — тоже только по ключу)."
