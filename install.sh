#!/usr/bin/env bash
# Install the GPU hand-over machinery on the host. Run as your normal user; it sudo's itself.
#  - /usr/local/libexec/t14s-gpu-handover       (root-owned hand-over script)
#  - /etc/libvirt/hooks/qemu.d/t14s-gpu         (libvirt hook)
#  - /var/lib/libvirt/vbios/*                   (VBIOS + GOP ROMs, readable by QEMU)
#  - /etc/sudoers.d/t14s-gpu                    (passwordless sudo for the hand-over script ONLY)
#  - user lingering, so tmux/user services survive the desktop being stopped
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi
USER_NAME="${SUDO_USER:?run as your normal user}"

for f in vbios_1002_1638.bin AMDGopDriver.rom; do
    [[ -f $DIR/rom/$f ]] || { echo "missing rom/$f (see README)" >&2; exit 1; }
done

install -D -m 755 -o root -g root "$DIR/scripts/gpu-handover.sh" /usr/local/libexec/t14s-gpu-handover
install -D -m 755 -o root -g root "$DIR/hooks/qemu.d/t14s-gpu"   /etc/libvirt/hooks/qemu.d/t14s-gpu
install -d -m 755 /var/lib/libvirt/vbios
install -m 644 -o root -g root "$DIR/rom/vbios_1002_1638.bin" "$DIR/rom/AMDGopDriver.rom" /var/lib/libvirt/vbios/

tmp=$(mktemp)
cat > "$tmp" <<EOF
# t14s-gpu-passthrough: let $USER_NAME move the iGPU between host and VM without a password
$USER_NAME ALL=(root) NOPASSWD: /usr/local/libexec/t14s-gpu-handover to-vfio, /usr/local/libexec/t14s-gpu-handover to-host, /usr/local/libexec/t14s-gpu-handover roundtrip, /usr/local/libexec/t14s-gpu-handover status
EOF
visudo -cf "$tmp" >/dev/null
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/t14s-gpu
rm -f "$tmp"

loginctl enable-linger "$USER_NAME"

# libvirtd only scans hook directories at startup. Restarting it does not stop running VMs.
systemctl try-restart libvirtd.service

echo "Installed. Check: sudo -n /usr/local/libexec/t14s-gpu-handover status"
