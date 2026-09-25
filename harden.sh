#!/usr/bin/env bash
# VPS Hardening — orchestrator.
# Root only, no extra user is created.
# Keep the current SSH session open until setup is done.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
enable_err_trap

# --- CLI ---
ASSUME_YES=0
ONLY=""
SKIP=""
CLI_SSH_PORT=""
CLI_PUBKEY=""
CLI_PUBKEY_FILE=""
CLI_EXTRA_PORTS=""
CLI_EXTRA_PORTS_SET=""

usage() {
    cat <<EOF
Usage: sudo ./harden.sh [options]

Options:
  --ssh-port PORT        new SSH port (1024-65535), no prompt
  --pubkey "ssh-ed..."   public key as a string
  --pubkey-file PATH     file with the public key
  --extra-ports 80,443   extra TCP ports (empty = none)
  --yes                  skip confirmations (except the SSH login check)
  --only a,b,c           run only steps: preflight,apt,input,backup,ssh-key,ssh-temp,ufw,finalize,fail2ban,report
  --skip a,b             skip steps
  -h, --help             help

Examples:
  sudo ./harden.sh
  sudo ./harden.sh --ssh-port 22222 --pubkey-file ~/.ssh/id_ed25519.pub --extra-ports 80,443 --yes
  sudo ./harden.sh --only fail2ban,report
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-port) CLI_SSH_PORT="${2:-}"; shift 2 ;;
        --pubkey) CLI_PUBKEY="${2:-}"; shift 2 ;;
        --pubkey-file) CLI_PUBKEY_FILE="${2:-}"; shift 2 ;;
        --extra-ports) CLI_EXTRA_PORTS="${2:-}"; CLI_EXTRA_PORTS_SET=1; shift 2 ;;
        --yes) ASSUME_YES=1; shift ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --skip) SKIP="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

export ASSUME_YES CLI_SSH_PORT CLI_PUBKEY CLI_PUBKEY_FILE CLI_EXTRA_PORTS CLI_EXTRA_PORTS_SET

# --- Source steps ---
for f in \
    "$SCRIPT_DIR/steps/00-preflight.sh" \
    "$SCRIPT_DIR/steps/10-apt.sh" \
    "$SCRIPT_DIR/steps/20-input.sh" \
    "$SCRIPT_DIR/steps/30-ssh.sh" \
    "$SCRIPT_DIR/steps/40-ufw.sh" \
    "$SCRIPT_DIR/steps/50-finalize-ssh.sh" \
    "$SCRIPT_DIR/steps/60-fail2ban.sh" \
    "$SCRIPT_DIR/steps/70-report.sh"
do
    # shellcheck disable=SC1090
    source "$f"
done

should_run() {
    local name="$1"
    if [[ -n "$SKIP" && ",$SKIP," == *",$name,"* ]]; then
        return 1
    fi
    if [[ -n "$ONLY" && ",$ONLY," != *",$name,"* ]]; then
        return 1
    fi
    return 0
}

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
log "Starting vps-hardening. Log: $LOG_FILE"

# A partial run (--only) picks up ports from the previous full run.
if [[ -n "$ONLY" ]]; then
    load_state || true
fi

should_run preflight && step_preflight
should_run apt && step_apt
should_run input && step_input
should_run backup && step_backup
should_run ssh-key && step_ssh_key
should_run ssh-temp && step_ssh_temp
should_run ufw && step_ufw
should_run finalize && step_verify_and_finalize_ssh
should_run fail2ban && step_fail2ban
should_run report && step_report

log "Done."
