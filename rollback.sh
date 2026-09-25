#!/usr/bin/env bash
# Roll back vps-hardening from a /root/vps-hardening-backup-* backup.
# Restores /etc/ssh, /etc/ufw, /etc/fail2ban and restarts services.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

BACKUP="${1:-}"

if [[ -z "$BACKUP" ]]; then
    echo "Available backups:"
    ls -d /root/vps-hardening-backup-* 2>/dev/null || die "No backups found."
    echo
    ask "Enter backup path: " BACKUP
fi

[[ -d "$BACKUP" ]] || die "No such directory: $BACKUP"
[[ -d "$BACKUP/ssh" ]] || die "No ssh/ in backup: $BACKUP"

echo "Will restore from: $BACKUP"
echo "  /etc/ssh <- $BACKUP/ssh"
[[ -d "$BACKUP/ufw" ]] && echo "  /etc/ufw <- $BACKUP/ufw"
[[ -d "$BACKUP/fail2ban" ]] && echo "  /etc/fail2ban <- $BACKUP/fail2ban"
echo

confirm "Continue with rollback" || { warn "Aborted."; exit 0; }

cp -a /etc/ssh "/etc/ssh.pre-rollback-$(date +%Y%m%d-%H%M%S)"
cp -a "$BACKUP/ssh/." /etc/ssh/
rm -f /etc/ssh/sshd_config.d/99-vps-hardening.conf /etc/ssh/sshd_config.d/00-vps-hardening.conf

if [[ -d "$BACKUP/ufw" ]]; then
    cp -a "$BACKUP/ufw/." /etc/ufw/ 2>/dev/null || true
fi
if [[ -f "$BACKUP/ufw-default" ]]; then
    cp -a "$BACKUP/ufw-default" /etc/default/ufw
fi
if [[ -d "$BACKUP/fail2ban" ]]; then
    cp -a "$BACKUP/fail2ban/." /etc/fail2ban/ 2>/dev/null || true
fi
rm -f /etc/fail2ban/jail.d/sshd.local

ensure_sshd_runtime_dir
sshd -t

if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    SVC="sshd.service"
else
    SVC="ssh.service"
fi
systemctl unmask ssh.socket sshd.socket 2>/dev/null || true
systemctl daemon-reload

# If the backup had socket-activation overrides, the system originally
# ran via ssh.socket — restore that mode instead of the classic service.
if [[ -d "$BACKUP/ssh.socket.d" || -f "$BACKUP/ssh.service.d/00-socket.conf" ]]; then
    rm -f /etc/systemd/system/ssh.service.d/00-socket.conf
    cp -a "$BACKUP/ssh.socket.d/." /etc/systemd/system/ssh.socket.d/ 2>/dev/null || true
    cp -a "$BACKUP/ssh.service.d/." /etc/systemd/system/ssh.service.d/ 2>/dev/null || true
    systemctl daemon-reload
    systemctl disable --now "$SVC" 2>/dev/null || true
    systemctl enable --now ssh.socket 2>/dev/null || systemctl enable --now sshd.socket 2>/dev/null || true
    log "Restored socket activation mode."
else
    systemctl restart "$SVC" || systemctl restart ssh || true
fi

ufw --force enable 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

log "Rollback done. Check: sshd -T; ufw status verbose; fail2ban-client status"
warn "If the SSH port was changed — connect to the OLD port from the backup."
