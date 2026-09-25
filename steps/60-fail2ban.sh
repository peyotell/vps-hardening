#!/usr/bin/env bash
# Fail2ban: sshd jail for the new port + check that the jail is active.

step_fail2ban() {
    step "Fail2ban setup"

    [[ -n "${SSH_PORT:-}" ]] || {
        load_state || true
        [[ -n "${SSH_PORT:-}" ]] || die "SSH_PORT missing. Run the input step or pass --ssh-port first."
    }

    local conf="/etc/fail2ban/jail.d/sshd.local"

    cat > "$conf" <<EOF
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

    fail2ban-client ping >/dev/null
    sleep 2
    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        die "Fail2ban jail 'sshd' is not active. Check: fail2ban-client status"
    fi

    log "Fail2ban configured."
}
