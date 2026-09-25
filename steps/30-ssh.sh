#!/usr/bin/env bash
# SSH: backup, root key install, temporary 2-port drop-in.
# Idempotent: a rerun overwrites the drop-in and key (no duplicates).

step_backup() {
    step "Backup"

    BACKUP_DIR="/root/vps-hardening-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    cp -a /etc/ssh "$BACKUP_DIR/ssh"
    cp -a /etc/ufw "$BACKUP_DIR/ufw" 2>/dev/null || true
    cp -a /etc/fail2ban "$BACKUP_DIR/fail2ban" 2>/dev/null || true
    cp -a /etc/default/ufw "$BACKUP_DIR/ufw-default" 2>/dev/null || true
    ufw --numeric status numbered > "$BACKUP_DIR/ufw-status.txt" 2>/dev/null || true

    log "Backup: ${BACKUP_DIR}"
    save_state
}

step_ssh_key() {
    step "SSH key install"

    [[ -n "${SSH_PUBLIC_KEY:-}" ]] || die "SSH_PUBLIC_KEY is empty. Run the input step first."

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    if ! grep -Fqx "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys; then
        echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    fi

    chown -R root:root /root/.ssh
    log "SSH public key installed."
}

step_ssh_temp() {
    step "Temporary SSH config"

    [[ -n "${SSH_PORT:-}" && -n "${CURRENT_SSH_PORT:-}" ]] || die "Ports missing. Run the input step first."
    [[ -n "${SSH_SERVICE:-}" ]] || SSH_SERVICE="ssh.service"

    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet sshd.socket 2>/dev/null; then
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl disable --now sshd.socket 2>/dev/null || true
        systemctl mask ssh.socket 2>/dev/null || true
        systemctl mask sshd.socket 2>/dev/null || true
    fi
    systemctl enable --now "$SSH_SERVICE"

    SSH_DROPIN="/etc/ssh/sshd_config.d/99-vps-hardening.conf"
    rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf

    neutralize_main_sshd_config

    cat > "$SSH_DROPIN" <<EOF
# Managed by vps-hardening
Port ${CURRENT_SSH_PORT}
Port ${SSH_PORT}

PubkeyAuthentication yes
PermitRootLogin prohibit-password

# Temporarily keep password authentication.
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF

    chmod 600 "$SSH_DROPIN"

    sshd -t
    systemctl restart "$SSH_SERVICE"

    assert_sshd_setting "passwordauthentication" "yes"
    if ! sshd_effective_ports | grep -qx "$SSH_PORT"; then
        die "New SSH port ${SSH_PORT} was not applied in sshd -T."
    fi

    log "SSH temporarily listens on old and new ports."
}
