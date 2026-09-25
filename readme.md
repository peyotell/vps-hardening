# vps-hardening

Initial VPS hardening on Ubuntu (22.04 / 24.04, others — with confirmation):
system update, SSH key for root, SSH port change, password auth disabled,
UFW, Fail2ban. No extra user is created, everything runs as root.

## Layout

```text
harden.sh              orchestrator (CLI: --yes/--only/--skip)
lib/common.sh          logging, input, sshd/ufw/apt helpers, state file
steps/00-preflight.sh  root + Ubuntu check
steps/10-apt.sh        update + install + full-upgrade
steps/20-input.sh      prompts: ports, pubkey, extra ports
steps/30-ssh.sh        backup, root key, temporary sshd on 2 ports
steps/40-ufw.sh        ufw reset + rules + port checks
steps/50-finalize-ssh.sh  manual SSH check + final (key only)
steps/60-fail2ban.sh   sshd jail + check
steps/70-report.sh     final diagnostics
rollback.sh            rollback from /root/vps-hardening-backup-*
tools/check.sh         syntax check for all scripts
```

State between runs: `/var/lib/vps-hardening/state.env`.
Log: `/var/log/vps-hardening.log`. Backups: `/root/vps-hardening-backup-*`.

## Run

Do not run via `curl | bash` — the script is interactive.
Keep the current SSH session open until setup is done.

```bash
# easiest: clone the whole repo, since lib/ and steps/ are needed
git clone https://github.com/peyotell/vps-hardening.git
cd vps-hardening
sudo ./harden.sh
```

Non-interactive (except the manual SSH login check — always asked):

```bash
sudo ./harden.sh --ssh-port 22222 --pubkey-file ~/.ssh/id_ed25519.pub --extra-ports 80,443 --yes
```

Partial run / skip steps:

```bash
sudo ./harden.sh --only fail2ban,report
sudo ./harden.sh --skip apt
./tools/check.sh
```

## Rollback

```bash
sudo ./rollback.sh                 # lists backups and asks which one
sudo ./rollback.sh /root/vps-hardening-backup-YYYYMMDD-HHMMSS
```

## How it works

1. Backup of `/etc/ssh`, `/etc/ufw`, `/etc/fail2ban` before changes.
2. Key is appended to `/root/.ssh/authorized_keys` (no duplicates).
3. Temporary sshd drop-in `99-vps-hardening.conf` listens on old + new ports,
   the main `sshd_config` is neutralized (on Ubuntu `Include` is at the top,
   otherwise the drop-in gets overridden), result verified via `sshd -T`.
4. UFW: `deny incoming / allow outgoing`, both SSH ports + extras opened.
5. Manual check of the new SSH login in a second terminal. Without
   confirmation — stop with ports left open (fail-open), final step skipped.
6. Final: new port only + `PasswordAuthentication no`, old port
   removed from UFW by rule number, Fail2ban `sshd` jail enabled.
