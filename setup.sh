#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ask() {
    local prompt="$1" default="${2:-}" reply=""
    if (: </dev/tty) 2>/dev/null; then
        read -rp "$prompt" reply </dev/tty || true
    else
        read -rp "$prompt" reply || true
    fi
    printf '%s' "${reply:-$default}"
}

detect_ip() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null) \
            || ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) \
            || ip=""
    fi
    [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

valid_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=. o
    for o in $1; do
        (( 10#$o <= 255 )) || return 1
    done
}

port_in_use() {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "Ошибка: запустите от root — sudo bash setup.sh" >&2
        exit 1
    fi

    echo "=== Базовая настройка VPS (Ubuntu 24.04) ==="
    echo

    local detected_ip
    detected_ip=$(detect_ip)
    SERVER_IP=$(ask "IP сервера [${detected_ip:-не определён}]: " "$detected_ip")
    while ! valid_ipv4 "$SERVER_IP"; do
        SERVER_IP=$(ask "Введите корректный IPv4 сервера: ")
    done

    local default_port
    default_port=$(shuf -i 20000-65000 -n 1)
    while true; do
        SSH_PORT=$(ask "Порт SSH [Enter — $default_port]: " "$default_port")
        if ! [[ $SSH_PORT =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
            echo "Порт должен быть числом от 1024 до 65535."
            continue
        fi
        if port_in_use "$SSH_PORT"; then
            echo "Порт $SSH_PORT уже занят другим сервисом."
            continue
        fi
        break
    done

    while true; do
        EXTRA_TCP_PORTS=$(ask "Дополнительные TCP-порты через пробел [443, '-' — без них]: " "443")
        [[ $EXTRA_TCP_PORTS == "-" ]] && EXTRA_TCP_PORTS="" && break
        [[ $EXTRA_TCP_PORTS =~ ^([0-9]{1,5}( +[0-9]{1,5})*)?$ ]] && break
        echo "Введите порты числами через пробел, например: 443 80"
    done

    echo
    echo "Параметры настройки:"
    echo "  IP сервера:      $SERVER_IP"
    echo "  Порт SSH:        $SSH_PORT"
    echo "  Доп. TCP-порты:  ${EXTRA_TCP_PORTS:-нет}"
    echo
    local confirm
    confirm=$(ask "Начать настройку? [y/N]: " "n")
    [[ $confirm =~ ^([yY]|[дД])$ ]] || { echo "Отменено."; exit 0; }

    export SERVER_IP SSH_PORT EXTRA_TCP_PORTS

    source "$SCRIPT_DIR/modules/update.sh"
    source "$SCRIPT_DIR/modules/ssh.sh"
    source "$SCRIPT_DIR/modules/ufw.sh"
    source "$SCRIPT_DIR/modules/fail2ban.sh"

    cat <<EOF

==================================================
Настройка завершена!

Проверьте в НОВОМ окне терминала (эту сессию не закрывайте):

1. Вход по ключу — должен работать:
   ssh -i ~/.ssh/name_vps root@$SERVER_IP -p $SSH_PORT

2. Вход по паролю — должен быть отклонён:
   ssh -o PubkeyAuthentication=no root@$SERVER_IP -p $SSH_PORT
   (ожидаемый ответ: Permission denied (publickey))

Если fail2ban случайно забанит ваш IP:
   sudo fail2ban-client set sshd unbanip ВАШ_IP
==================================================
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
