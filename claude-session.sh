#!/usr/bin/env bash
# Temporary passwordless sudo for a hands-off testing session (e.g. Claude Code in tmux).
#
#   ./claude-session.sh grant [hours]   add the rules (asks for your password); auto-revoked after N hours (default 8)
#   ./claude-session.sh revoke          remove them now (works without a password while a session is active)
#   ./claude-session.sh status
#
# Allowed while active: the GPU hand-over script, reinstalling it and the libvirt hook from this repo,
# restarting libvirtd, starting the display manager, a few read-only diagnostics, and the revoke itself.
# Note: reinstalling root-run scripts from this user-writable repo is effectively root for your account,
# which is why the grant is time-limited.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES=/etc/sudoers.d/t14s-claude-session
REVOKE=/usr/local/libexec/t14s-claude-revoke
TIMER=t14s-claude-revoke
BOOT_UNIT=t14s-claude-revoke-at-boot.service

grant() {
    local hours=${1:-8}
    [[ $hours =~ ^[0-9]+$ && $hours -ge 1 && $hours -le 24 ]] || { echo "hours must be 1-24" >&2; exit 2; }
    [[ $EUID -eq 0 ]] || exec sudo "$0" grant "$hours"
    local user="${SUDO_USER:?run as your normal user}"
    case "$DIR" in *[[:space:],:=\\]*) echo "repo path must not contain spaces , : = or \\" >&2; exit 1 ;; esac

    # Root-owned revoke helper (fixed content, not run from the repo)
    install -D -m 755 -o root -g root /dev/stdin "$REVOKE" <<EOF
#!/bin/sh
rm -f $RULES
systemctl stop $TIMER.timer 2>/dev/null
systemctl disable $BOOT_UNIT 2>/dev/null
logger -t t14s-gpu "claude session sudo rules revoked"
echo "sudo rules revoked"
EOF

    # A session never survives a reboot (clean or crash): revoke early on the next boot.
    install -m 644 -o root -g root /dev/stdin "/etc/systemd/system/$BOOT_UNIT" <<EOF
[Unit]
Description=Revoke t14s-gpu-passthrough temporary sudo rules at boot
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=$REVOKE

[Install]
WantedBy=sysinit.target
EOF
    systemctl daemon-reload
    systemctl enable -q "$BOOT_UNIT"

    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<EOF
# TEMPORARY (t14s-gpu-passthrough claude-session.sh), granted $(date '+%F %T') for ${hours}h
Cmnd_Alias T14S_GPU    = /usr/local/libexec/t14s-gpu-handover
Cmnd_Alias T14S_UPDATE = /usr/bin/install -m 755 -o root -g root $DIR/scripts/gpu-handover.sh /usr/local/libexec/t14s-gpu-handover, \\
                         /usr/bin/install -m 755 -o root -g root $DIR/hooks/qemu.d/t14s-gpu /etc/libvirt/hooks/qemu.d/t14s-gpu
Cmnd_Alias T14S_SVC    = /usr/bin/systemctl try-restart libvirtd.service, /usr/bin/systemctl start display-manager.service
Cmnd_Alias T14S_DIAG   = /usr/bin/dmesg "", /usr/bin/lspci -nnvvv, /usr/bin/ufw status verbose, /usr/bin/nft list ruleset
Cmnd_Alias T14S_END    = $REVOKE ""
$user ALL=(root) NOPASSWD: T14S_GPU, T14S_UPDATE, T14S_SVC, T14S_DIAG, T14S_END
EOF
    visudo -cf "$tmp" >/dev/null
    install -m 440 -o root -g root "$tmp" "$RULES"
    rm -f "$tmp"
    visudo -c >/dev/null

    systemctl stop "$TIMER.timer" 2>/dev/null || true
    systemctl reset-failed "$TIMER.service" 2>/dev/null || true
    systemd-run --quiet --collect --unit="$TIMER" --on-active="${hours}h" --timer-property=AccuracySec=1min "$REVOKE"
    logger -t t14s-gpu "claude session sudo rules granted for ${hours}h"
    echo "Granted for ${hours}h (auto-revoke at $(date -d "+${hours} hours" '+%F %T')). End early: ./claude-session.sh revoke"
}

# /etc/sudoers.d is root-only, so ask sudo itself whether the session rules are in effect
active() { [[ $EUID -eq 0 ]] && [[ -e $RULES ]] || sudo -n -l "$REVOKE" >/dev/null 2>&1; }

revoke() {
    [[ -x $REVOKE ]] || { echo "no session was ever granted"; return 0; }
    if [[ $EUID -eq 0 ]]; then "$REVOKE"
    elif active; then sudo -n "$REVOKE"
    else echo "no active session"; fi
}

status() {
    if active; then
        echo "ACTIVE"
        systemctl list-timers "$TIMER.timer" --no-pager 2>/dev/null | sed -n '1,2p'
    else
        echo "inactive"
    fi
}

case "${1:-status}" in
    grant)  grant "${2:-8}" ;;
    revoke) revoke ;;
    status) status ;;
    *) echo "usage: $0 grant [hours]|revoke|status" >&2; exit 2 ;;
esac
