#!/usr/bin/env bash
# Install the GPU hand-over machinery on the host. Run as your normal user; it sudo's itself.
#  - /usr/local/libexec/t14s-gpu-handover       (root-owned hand-over script)
#  - /etc/libvirt/hooks/qemu.d/t14s-gpu         (libvirt hook)
#  - /var/lib/libvirt/vbios/*                   (VBIOS + GOP ROMs, readable by QEMU)
#  - ufw rules for libvirt's NAT network (if ufw is active)
#  - user lingering, so tmux/user services survive the desktop being stopped
#  No sudoers rules: for a hands-off test session use ./claude-session.sh grant|revoke
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

if command -v ufw >/dev/null && systemctl is-active -q ufw; then
    echo "==> ufw: libvirt NAT rules on virbr0"
    "$DIR/scripts/ufw-libvirt.sh" apply
fi

rm -f /etc/sudoers.d/t14s-gpu   # permanent rule from earlier versions

loginctl enable-linger "$USER_NAME"

# libvirtd only scans hook directories at startup. Restarting it does not stop running VMs.
systemctl try-restart libvirtd.service

echo
echo "Installed. For a hands-off test session: ./claude-session.sh grant [hours]"
