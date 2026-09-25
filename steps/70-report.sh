#!/usr/bin/env bash
# Final report: sshd -T, ports, ufw, fail2ban.

step_report() {
    step "Final check"

    echo
    echo "--- OS ---"
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
    fail2ban-client status sshd || true

    echo
    echo "--- SSH service ---"
    systemctl --no-pager --full status "${SSH_SERVICE:-ssh.service}" || true

    echo
    echo "============================================================"
    echo " DONE"
    echo "============================================================"
    echo

    echo "SSH port:          ${SSH_PORT:-?}"
    echo "Root SSH:          allowed (key only)"
    echo "Auth:              SSH key"
    echo "SSH password:      disabled"
    echo "UFW:               enabled"
    echo "Fail2ban:          enabled"
    echo
    echo "Backup:"
    echo "  ${BACKUP_DIR:-see /root/vps-hardening-backup-*}"
    echo
    echo "Local key:"
    echo "  ~/.ssh/${KEY_NAME:-vps_HOSTNAME_root_ed25519}"
    echo
    echo "Connect:"
    echo "  ssh -i ~/.ssh/${KEY_NAME:-KEY} -p ${SSH_PORT:-PORT} root@SERVER_IP"
    echo
}
