#!/usr/bin/env bash
# System update + install openssh-server, ufw, fail2ban.

step_apt() {
    step "System update"

    wait_for_apt
    apt-get update

    wait_for_apt
    apt-get install -y openssh-server ufw fail2ban

    wait_for_apt
    apt-get full-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    log "System updated."
}
