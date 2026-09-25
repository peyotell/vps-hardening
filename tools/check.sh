#!/usr/bin/env bash
# Quick check: syntax of all scripts + step presence in the orchestrator.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

fail=0
for f in harden.sh rollback.sh lib/*.sh steps/*.sh; do
    if bash -n "$f"; then
        echo "OK syntax: $f"
    else
        echo "FAIL syntax: $f"
        fail=1
    fi
done

for fn in step_preflight step_apt step_input step_backup step_ssh_key step_ssh_temp step_ufw step_verify_and_finalize_ssh step_fail2ban step_report; do
    if grep -rq "$fn" steps/ harden.sh; then
        echo "OK step: $fn"
    else
        echo "FAIL step missing: $fn"
        fail=1
    fi
done

exit "$fail"
