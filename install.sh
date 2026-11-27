#!/usr/bin/env bash
# Install the GPU hand-over machinery on the host. Run as your normal user; it sudo's itself.
#  - /usr/local/libexec/t14s-gpu-handover       (root-owned hand-over script)
#  - /etc/libvirt/hooks/qemu.d/t14s-gpu         (libvirt hook)
#  - /var/lib/libvirt/vbios/*                   (VBIOS + GOP ROMs, readable by QEMU)
#  - /etc/sudoers.d/t14s-gpu                    (passwordless sudo for a fixed list of commands, see below)
#  - ufw rules for libvirt's NAT network (if ufw is active)
#  - user lingering, so tmux/user services survive the desktop being stopped
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi
USER_NAME="${SUDO_USER:?run as your normal user}"

for f in vbios_1002_1638.bin AMDGopDriver.rom; do
    [[ -f $DIR/rom/$f ]] || { echo "missing rom/$f (see README)" >&2; exit 1; }
done
case "$DIR" in *[[:space:],:=\\]*) echo "repo path must not contain spaces , : = or \\" >&2; exit 1 ;; esac

echo "==> Hand-over script, libvirt hook, ROMs"
install -D -m 755 -o root -g root "$DIR/scripts/gpu-handover.sh" /usr/local/libexec/t14s-gpu-handover
install -D -m 755 -o root -g root "$DIR/hooks/qemu.d/t14s-gpu"   /etc/libvirt/hooks/qemu.d/t14s-gpu
install -d -m 755 /var/lib/libvirt/vbios
install -m 644 -o root -g root "$DIR/rom/vbios_1002_1638.bin" "$DIR/rom/AMDGopDriver.rom" /var/lib/libvirt/vbios/

echo "==> sudoers"
# Exact commands only. Note: T14S_UPDATE installs root-run scripts from this (user-writable) repo, so it
# is effectively root for $USER_NAME; it exists so the hand-over script can be iterated on during testing.
# Remove /etc/sudoers.d/t14s-gpu (or that alias) once the setup is stable.
tmp=$(mktemp)
cat > "$tmp" <<EOF
# t14s-gpu-passthrough: passwordless commands for $USER_NAME (and Claude Code running as $USER_NAME)
Cmnd_Alias T14S_GPU    = /usr/local/libexec/t14s-gpu-handover
Cmnd_Alias T14S_UPDATE = /usr/bin/install -m 755 -o root -g root $DIR/scripts/gpu-handover.sh /usr/local/libexec/t14s-gpu-handover, \\
                         /usr/bin/install -m 755 -o root -g root $DIR/hooks/qemu.d/t14s-gpu /etc/libvirt/hooks/qemu.d/t14s-gpu
Cmnd_Alias T14S_SVC    = /usr/bin/systemctl try-restart libvirtd.service, /usr/bin/systemctl start display-manager.service
Cmnd_Alias T14S_DIAG   = /usr/bin/dmesg "", /usr/bin/lspci -nnvvv, /usr/bin/ufw status verbose, /usr/bin/nft list ruleset
$USER_NAME ALL=(root) NOPASSWD: T14S_GPU, T14S_UPDATE, T14S_SVC, T14S_DIAG
EOF
visudo -cf "$tmp" >/dev/null
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/t14s-gpu
rm -f "$tmp"
visudo -c >/dev/null

if command -v ufw >/dev/null && systemctl is-active -q ufw; then
    echo "==> ufw: DHCP/DNS to libvirt's dnsmasq and NAT forwarding on virbr0"
    ufw allow in on virbr0 to any port 67 proto udp comment 'libvirt DHCP'
    ufw allow in on virbr0 to any port 53 comment 'libvirt DNS'
    ufw route allow in on virbr0 comment 'libvirt NAT out'
    ufw route allow out on virbr0 comment 'libvirt NAT return'
fi

loginctl enable-linger "$USER_NAME"

# libvirtd only scans hook directories at startup. Restarting it does not stop running VMs.
systemctl try-restart libvirtd.service

echo
echo "Installed. Check: sudo -n /usr/local/libexec/t14s-gpu-handover status"
