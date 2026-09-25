#!/usr/bin/env bash
# UFW: reset (after backup) + deny incoming / allow outgoing + ports.
# WARNING: reset wipes custom rules (Docker etc.) — backup is in BACKUP_DIR.

step_ufw() {
    step "UFW setup"

    [[ -n "${SSH_PORT:-}" && -n "${CURRENT_SSH_PORT:-}" ]] || die "Ports missing. Run the input step first."

    ufw --force reset

    ufw default deny incoming
    ufw default allow outgoing

    ufw allow "${CURRENT_SSH_PORT}/tcp" comment "Temporary old SSH"
    ufw allow "${SSH_PORT}/tcp" comment "New SSH"

    if [[ -n "${EXTRA_PORTS_CLEAN:-}" ]]; then
        IFS=',' read -ra PORT_ARRAY <<< "$EXTRA_PORTS_CLEAN"
        local PORT
        for PORT in "${PORT_ARRAY[@]}"; do
            ufw allow "${PORT}/tcp" comment "Additional TCP port"
        done
    fi

    ufw --force enable

    log "UFW configured."

    if ! port_in_use "$CURRENT_SSH_PORT"; then
        die "Old SSH port ${CURRENT_SSH_PORT} is not listening."
    fi
    if ! port_in_use "$SSH_PORT"; then
        die "New SSH port ${SSH_PORT} is not listening."
    fi

    log "Both SSH ports are reachable."
}

# Called AFTER manual confirmation of the new SSH login.
step_ufw_close_old() {
    echo
    echo "Closing old SSH port in UFW..."

    # If the old port is also an extra port — keep it (it is still needed).
    if [[ -n "${EXTRA_PORTS_CLEAN:-}" ]]; then
        local p
        IFS=',' read -ra _arr <<< "$EXTRA_PORTS_CLEAN"
        for p in "${_arr[@]}"; do
            if [[ "$p" == "$CURRENT_SSH_PORT" ]]; then
                warn "Old port ${CURRENT_SSH_PORT} is in extra ports — keeping it open."
                return 0
            fi
        done
    fi

    delete_ufw_port_rule "$CURRENT_SSH_PORT"
    log "Old SSH port ${CURRENT_SSH_PORT} closed."
}
