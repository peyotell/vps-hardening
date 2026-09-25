#!/usr/bin/env bash
# Manual check of the new SSH login + final drop-in (key only, single port).
# This confirm is NOT skipped by --yes: the login must be verified by hand.

step_verify_and_finalize_ssh() {
    step "NEW SSH CONNECTION CHECK"

    [[ -n "${SSH_PORT:-}" ]] || die "SSH_PORT missing. Run the input step first."

    local key_hint="${KEY_NAME:-vps_HOSTNAME_root_ed25519}"

    echo "Open a second terminal on your computer."
    echo
    echo "Run:"
    echo
    echo "  ssh -i ~/.ssh/${key_hint} -p ${SSH_PORT} root@SERVER_IP"
    echo
    echo "Replace SERVER_IP with the VPS IP address."
    echo
    echo "If the connection works, return to this terminal."
    echo

    # Always ask, even with --yes.
    CONFIRM_NO_AUTO_YES=1
    if ! confirm "New SSH login works"; then
        unset CONFIRM_NO_AUTO_YES
        echo
        warn "Stopping setup for safety."
        echo
        echo "Old SSH port ${CURRENT_SSH_PORT} kept."
        echo "Password SSH authentication kept."
        echo "New SSH port ${SSH_PORT} also kept accessible."
        echo "Backup: ${BACKUP_DIR:-not created}"
        echo
        echo "Rerun the script to try again."
        echo
        exit 1
    fi
    unset CONFIRM_NO_AUTO_YES

    log "New SSH login confirmed."

    step "Final SSH config"

    cat > "$SSH_DROPIN" <<EOF
# Managed by vps-hardening
Port ${SSH_PORT}

PubkeyAuthentication yes
PermitRootLogin prohibit-password

PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

    chmod 600 "$SSH_DROPIN"

    sshd -t
    systemctl restart "$SSH_SERVICE"

    assert_sshd_setting "passwordauthentication" "no"
    assert_sshd_setting "pubkeyauthentication" "yes"

    log "Password SSH authentication disabled."

    step_ufw_close_old
    save_state
}
