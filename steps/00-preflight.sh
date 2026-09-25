#!/usr/bin/env bash
# Preflight: root + Ubuntu 22.04/24.04 (anything else — with confirmation).

step_preflight() {
    step "System check"

    if [[ "$EUID" -ne 0 ]]; then
        die "This script must be run as root."
    fi

    if [[ ! -f /etc/os-release ]]; then
        die "/etc/os-release not found."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "This script targets Ubuntu. Detected: ${PRETTY_NAME:-unknown}"
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04)
            log "Detected Ubuntu ${VERSION_ID} LTS."
            ;;
        *)
            warn "Detected ${PRETTY_NAME:-unknown OS}. Tested on 22.04/24.04."
            if ! confirm "Continue at your own risk"; then
                die "Aborted by user."
            fi
            ;;
    esac

    load_state || true
}
