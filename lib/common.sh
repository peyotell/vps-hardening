#!/usr/bin/env bash
# Shared helpers: logging, input, trap, sshd/ufw/apt utilities.
# Sourced via: source lib/common.sh

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="${LOG_FILE:-/var/log/vps-hardening.log}"
STATE_FILE="${STATE_FILE:-/var/lib/vps-hardening/state.env}"

log() {
    echo -e "${GREEN}[ OK ]${NC} $*" >&2
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%F %T')] [OK] $*" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%F %T')] [WARN] $*" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%F %T')] [ERROR] $*" >> "$LOG_FILE" 2>/dev/null || true
    exit 1
}

step() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
    echo
}

ask() {
    local prompt="$1"
    local __resultvar="$2"
    local value=""

    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf "%s" "$prompt" > /dev/tty
        IFS= read -r value < /dev/tty
    else
        printf "%s" "$prompt"
        IFS= read -r value
    fi

    printf -v "$__resultvar" '%s' "$value"
}

confirm() {
    local prompt="$1"
    local answer=""

    # --yes: answer "yes" to all prompts except the manual SSH check.
    if [[ "${ASSUME_YES:-0}" == "1" && "${CONFIRM_NO_AUTO_YES:-0}" != "1" ]]; then
        return 0
    fi

    if [[ -r /dev/tty && -w /dev/tty ]]; then
        printf "%s [y/N]: " "$prompt" > /dev/tty
        IFS= read -r answer < /dev/tty
    else
        printf "%s [y/N]: " "$prompt"
        IFS= read -r answer
    fi

    [[ "$answer" =~ ^[Yy]$ ]]
}

on_error() {
    local line="$1"
    local command="$2"
    echo
    echo -e "${RED}[ERROR]${NC} Command failed."
    echo "Line: $line"
    echo "Command: $command"
    echo "Log: ${LOG_FILE:--}"
    echo
    exit 1
}

# Installed once by the orchestrator, not in every module.
enable_err_trap() {
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
}

port_in_use() {
    local port="$1"
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
}

trim() {
    echo "${1:-}" | xargs 2>/dev/null || printf '%s' "${1:-}"
}

is_single_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# Fail fast with the offending value instead of a cryptic `sshd -t` error.
# Usage: validate_sshd_ports "current" "$CURRENT_SSH_PORT" "new" "$SSH_PORT"
validate_sshd_ports() {
    local label1="$1" value1="$2" label2="${3:-}" value2="${4:-}"

    if ! is_single_port "$value1"; then
        die "Invalid ${label1} SSH port: '${value1}' (need a single number 1-65535, no commas/spaces)."
    fi
    if [[ -n "$label2" ]] && ! is_single_port "$value2"; then
        die "Invalid ${label2} SSH port: '${value2}' (need a single number 1-65535, no commas/spaces)."
    fi
}

# sshd -t and `systemctl restart ssh*` require the privilege separation
# directory. On some systems (containers, cleaned /run) it is missing,
# which fails with "Missing privilege separation directory: /run/sshd".
ensure_sshd_runtime_dir() {
    if [[ ! -d /run/sshd ]]; then
        mkdir -p /run/sshd
        chmod 755 /run/sshd
    fi
}

# Run `sshd -t`; on failure dump the drop-in so the bad line is visible.
check_sshd_config() {
    local dropin="${1:-/etc/ssh/sshd_config.d/99-vps-hardening.conf}"
    local out=""

    ensure_sshd_runtime_dir

    if out="$(sshd -t 2>&1)"; then
        return 0
    fi

    echo "--- ${dropin} ---"
    cat "$dropin" 2>/dev/null || echo "(drop-in not found: $dropin)"
    echo "--- sshd -t output ---"
    echo "$out"
    die "sshd -t failed. Fix the drop-in above and rerun."
}

sshd_effective_ports() {
    sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
}

assert_sshd_setting() {
    local key="$1"
    local expected="$2"
    local actual=""

    actual="$(sshd -T 2>/dev/null | awk -v k="$key" '$1 == k {print $2}' | head -n1)"

    if [[ "$actual" != "$expected" ]]; then
        die "sshd: expected '$key $expected', got '$key $actual'. Check /etc/ssh/sshd_config and drop-ins."
    fi
}

# The main sshd_config on Ubuntu has the Include directive at the top,
# so its values override sshd_config.d/*.conf.
# Comment out conflicting directives so the 99-* drop-in takes effect.
neutralize_main_sshd_config() {
    local main="/etc/ssh/sshd_config"
    [[ -f "$main" ]] || return 0

    cp -a "$main" "${main}.bak-$(date +%Y%m%d-%H%M%S)"

    sed -i -E \
        -e 's/^[[:space:]]*Port[[:space:]]+/#Port /' \
        -e 's/^[[:space:]]*PasswordAuthentication[[:space:]]+/#PasswordAuthentication /' \
        -e 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+/#KbdInteractiveAuthentication /' \
        -e 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+/#ChallengeResponseAuthentication /' \
        -e 's/^[[:space:]]*PermitRootLogin[[:space:]]+/#PermitRootLogin /' \
        -e 's/^[[:space:]]*PubkeyAuthentication[[:space:]]+/#PubkeyAuthentication /' \
        "$main"
}

# Switch from systemd socket activation (Ubuntu default since 22.10,
# still default on 26.04) to the classic service so that the Port
# directive in sshd_config is actually honored. The 00-socket.conf
# drop-in must be removed or it forces socket mode back even with
# the service enabled; daemon-reload is required afterwards.
disable_ssh_socket_activation() {
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl disable --now sshd.socket 2>/dev/null || true
    systemctl mask ssh.socket 2>/dev/null || true
    systemctl mask sshd.socket 2>/dev/null || true
    rm -f /etc/systemd/system/ssh.service.d/00-socket.conf
    systemctl daemon-reload
}

delete_ufw_port_rule() {    local port="$1"
    local numbers=""

    numbers="$(ufw --numeric status numbered 2>/dev/null \
        | grep -E "\b${port}/tcp\b" \
        | grep -oE '^\[[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+' \
        | sort -rn || true)"

    if [[ -z "$numbers" ]]; then
        return 0
    fi

    local n
    for n in $numbers; do
        echo "y" | ufw delete "$n" >/dev/null 2>&1 || true
    done
}

wait_for_apt() {
    local timeout=120
    local elapsed=0

    log "Checking APT/dpkg availability..."

    if ! command -v fuser >/dev/null 2>&1; then
        log "fuser not found — skipping lock check."
        return 0
    fi

    while \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 ||
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    do
        if (( elapsed >= timeout )); then
            die "APT/dpkg has been busy for more than 2 minutes."
        fi

        if (( elapsed == 0 )); then
            warn "APT/dpkg is busy with another process. Waiting up to 2 minutes..."
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    log "APT/dpkg is free."
}

# State between runs: allows e.g. --only fail2ban after a full run.
save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" <<EOF
# Managed by vps-hardening. Do not edit manually unless needed.
CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-}"
SSH_PORT="${SSH_PORT:-}"
EXTRA_PORTS_CLEAN="${EXTRA_PORTS_CLEAN:-}"
SSH_SERVICE="${SSH_SERVICE:-}"
BACKUP_DIR="${BACKUP_DIR:-}"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    sanitize_state || true
}

# Self-heal a state file poisoned by an older buggy run
# (e.g. CURRENT_SSH_PORT containing a warn message instead of a number).
sanitize_state() {
    if [[ -n "${CURRENT_SSH_PORT:-}" ]]; then
        CURRENT_SSH_PORT="$(trim "$CURRENT_SSH_PORT")"
        if ! is_single_port "$CURRENT_SSH_PORT"; then
            warn "Ignoring invalid CURRENT_SSH_PORT from state: '${CURRENT_SSH_PORT}'"
            CURRENT_SSH_PORT=""
        fi
    fi
    if [[ -n "${SSH_PORT:-}" ]]; then
        SSH_PORT="$(trim "$SSH_PORT")"
        if ! is_single_port "$SSH_PORT"; then
            warn "Ignoring invalid SSH_PORT from state: '${SSH_PORT}'"
            SSH_PORT=""
        fi
    fi
    if [[ -n "${EXTRA_PORTS_CLEAN:-}" ]]; then
        local clean="" p
        local -a _arr=()
        IFS=',' read -ra _arr <<< "$EXTRA_PORTS_CLEAN"
        for p in "${_arr[@]}"; do
            p="$(trim "$p")"
            [[ -z "$p" ]] && continue
            is_single_port "$p" || continue
            if [[ -n "$clean" ]]; then
                clean+=","
            fi
            clean+="$p"
        done
        EXTRA_PORTS_CLEAN="$clean"
    fi
}
