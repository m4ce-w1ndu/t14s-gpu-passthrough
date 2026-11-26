#!/usr/bin/env bash
# One-time host setup for libvirt system session use as a normal user (Arch/CachyOS).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi
USER_NAME="${SUDO_USER:?run this as your normal user, it will sudo itself}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"

echo "==> Installing packages"
pacman -S --needed --noconfirm libvirt qemu-full virt-manager edk2-ovmf dnsmasq swtpm

echo "==> Adding $USER_NAME to the libvirt group (polkit grants it passwordless qemu:///system)"
usermod -aG libvirt "$USER_NAME"

echo "==> Enabling libvirt"
systemctl enable --now libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket

echo "==> Default NAT network"
virsh -c qemu:///system net-info default >/dev/null 2>&1 || \
    virsh -c qemu:///system net-define /usr/share/libvirt/networks/default.xml
virsh -c qemu:///system net-autostart default
virsh -c qemu:///system net-start default 2>/dev/null || true

echo "==> Fish: default to the system session"
install -D -m 644 -o "$USER_NAME" -g "$(id -gn "$USER_NAME")" \
    "$DIR/fish/libvirt.fish" "$USER_HOME/.config/fish/conf.d/libvirt.fish"

echo
echo "Done. Log out and back in (group change), then check:"
echo "  virsh uri            # -> qemu:///system"
echo "  virsh list --all     # no password prompt"
echo "  virsh net-list       # default: active, autostart yes"
