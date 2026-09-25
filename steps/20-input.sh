#!/usr/bin/env bash
# Input collection: current/new SSH port, root pubkey, extra TCP ports.
# Supports CLI: --ssh-port, --pubkey, --pubkey-file, --extra-ports.
# Result is stored in the state file for repeated/partial runs.

detect_current_ssh_port() {
    local p=""
    p="$(sshd_effective_ports | head -n1 || true)"

    if [[ -z "$p" ]]; then
        p="$(
            ss -ltnp 2>/dev/null |
                grep -E 'sshd' |
                sed -nE 's/.*:([0-9]+).*/\1/p' |
                head -n1 || true
        )"
    fi

    if [[ -z "$p" ]]; then
        warn "Could not detect current SSH port, using 22."
        p="22"
    fi

    printf '%s' "$p"
}

prompt_ssh_port() {
    if [[ -n "${CLI_SSH_PORT:-}" ]]; then
        SSH_PORT="$CLI_SSH_PORT"
        if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
            die "Invalid --ssh-port: $SSH_PORT (need 1024-65535)."
        fi
        if [[ "$SSH_PORT" == "$CURRENT_SSH_PORT" ]]; then
            die "--ssh-port matches the current port."
        fi
        if port_in_use "$SSH_PORT"; then
            die "Port $SSH_PORT is already in use."
        fi
        log "New SSH port (CLI): ${SSH_PORT}"
        return 0
    fi

    while true; do
        ask "Enter new SSH port (1024-65535): " SSH_PORT

        if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
            warn "Port must be a number."
            continue
        fi
        if (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
            warn "Port must be in range 1024-65535."
            continue
        fi
        if [[ "$SSH_PORT" == "$CURRENT_SSH_PORT" ]]; then
            warn "New port must differ from the current SSH port."
            continue
        fi
        if port_in_use "$SSH_PORT"; then
            warn "Port ${SSH_PORT} is already in use."
            continue
        fi
        break
    done

    log "New SSH port: ${SSH_PORT}"
}

prompt_pubkey() {
    if [[ -n "${CLI_PUBKEY_FILE:-}" ]]; then
        [[ -f "$CLI_PUBKEY_FILE" ]] || die "Key file not found: $CLI_PUBKEY_FILE"
        SSH_PUBLIC_KEY="$(xargs < "$CLI_PUBKEY_FILE")"
    elif [[ -n "${CLI_PUBKEY:-}" ]]; then
        SSH_PUBLIC_KEY="$(echo "$CLI_PUBKEY" | xargs)"
    else
        local host
        host="$(hostname)"
        KEY_NAME="vps_${host}_root_ed25519"

        echo "Create a new SSH key in a separate terminal:"
        echo
        echo "  ssh-keygen -t ed25519 -f ~/.ssh/${KEY_NAME}"
        echo

        SSH_PUBLIC_KEY=""
        while true; do
            ask "Paste the public key (.pub) content here: " SSH_PUBLIC_KEY
            SSH_PUBLIC_KEY="$(echo "$SSH_PUBLIC_KEY" | xargs)"
            if [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[^[:space:]]+ ]]; then
                break
            fi
            warn "This does not look like a valid SSH public key."
        done
    fi

    if ! [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[^[:space:]]+ ]]; then
        die "Invalid public key."
    fi

    # KEY_NAME is needed by the final report even in --yes mode.
    if [[ -z "${KEY_NAME:-}" ]]; then
        KEY_NAME="vps_$(hostname)_root_ed25519"
    fi

    log "Public SSH key accepted."
}

prompt_extra_ports() {
    local input="${CLI_EXTRA_PORTS:-}"

    if [[ -z "$input" && -z "${CLI_PUBKEY:-}" && -z "${CLI_PUBKEY_FILE:-}" && -z "${CLI_SSH_PORT:-}" ]]; then
        echo "You may specify extra TCP ports, comma-separated."
        echo "Example: 80,443. Press Enter if none are needed."
        echo
        ask "Extra TCP ports: " input
    elif [[ -n "${CLI_EXTRA_PORTS_SET:-}" ]]; then
        : # passed explicitly, even empty — do not ask
    elif [[ "${ASSUME_YES:-0}" == "1" ]]; then
        input=""
    else
        echo "You may specify extra TCP ports, comma-separated."
        echo "Example: 80,443. Press Enter if none are needed."
        echo
        ask "Extra TCP ports: " input
    fi

    EXTRA_PORTS_CLEAN=""

    while true; do
        EXTRA_PORTS_CLEAN=""
        declare -A _seen=()
        local _invalid=""

        if [[ -n "$input" ]]; then
            IFS=',' read -ra PORT_ARRAY <<< "$input"
            local raw PORT
            for raw in "${PORT_ARRAY[@]}"; do
                PORT="$(echo "$raw" | xargs)"
                [[ -z "$PORT" ]] && continue

                if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
                    _invalid="$PORT"
                    break
                fi
                if [[ "$PORT" == "$SSH_PORT" ]]; then
                    warn "Port ${PORT} matches the new SSH port — skipping duplicate."
                    continue
                fi
                if [[ "$PORT" == "$CURRENT_SSH_PORT" ]]; then
                    warn "Port ${PORT} matches the old SSH port — it is open temporarily anyway."
                    continue
                fi
                if [[ -n "${_seen[$PORT]:-}" ]]; then
                    continue
                fi
                _seen[$PORT]=1

                if [[ -n "$EXTRA_PORTS_CLEAN" ]]; then
                    EXTRA_PORTS_CLEAN+=","
                fi
                EXTRA_PORTS_CLEAN+="$PORT"
            done
        fi

        if [[ -n "$_invalid" ]]; then
            # In CLI mode fail fast, in interactive mode ask again.
            if [[ -n "${CLI_EXTRA_PORTS_SET:-}" ]]; then
                die "Invalid port in --extra-ports: ${_invalid}"
            fi
            warn "Invalid port: ${_invalid}. Enter again or press Enter."
            ask "Extra TCP ports: " input
            continue
        fi
        break
    done
}

step_input() {
    step "Parameters"

    if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
        SSH_SERVICE="sshd.service"
    else
        SSH_SERVICE="ssh.service"
    fi

    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet sshd.socket 2>/dev/null; then
        log "Detected ssh.socket. Will switch to ${SSH_SERVICE} at the SSH stage."
    fi

    CURRENT_SSH_PORT="$(detect_current_ssh_port)"
    log "Current SSH port: ${CURRENT_SSH_PORT}"

    prompt_ssh_port
    prompt_pubkey
    prompt_extra_ports

    echo
    echo "Current SSH port:       ${CURRENT_SSH_PORT}"
    echo "New SSH port:           ${SSH_PORT}"
    echo "SSH root:               allowed (key only after final step)"
    echo "Temporary:              both ports + password enabled"
    echo "After confirmation:     new port only, key only"
    echo "Extra TCP ports:        ${EXTRA_PORTS_CLEAN:-none}"
    echo "Fail2ban:               will be enabled"
    echo

    if ! confirm "Continue with setup"; then
        warn "Aborted."
        exit 0
    fi

    save_state
}
