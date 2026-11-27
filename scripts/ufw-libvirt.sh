#!/usr/bin/env bash
# ufw rules for libvirt's default NAT network (virbr0, 192.168.122.0/24).
# ufw's default DROP policy blocks the guest's DHCP and DNS (to libvirt's dnsmasq on the host) and
# the forwarding from virbr0 out to the internet. These rules open exactly that, only on virbr0.
#
#   scripts/ufw-libvirt.sh apply    add the rules (safe to repeat; ufw skips existing ones)
#   scripts/ufw-libvirt.sh remove   delete them again
#   scripts/ufw-libvirt.sh status   show the rules that mention virbr0
set -euo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi
command -v ufw >/dev/null || { echo "ufw is not installed" >&2; exit 1; }

RULES=(
    "allow in on virbr0 to any port 67 proto udp comment 'libvirt DHCP'"
    "allow in on virbr0 to any port 53 comment 'libvirt DNS'"
    "route allow in on virbr0 comment 'libvirt NAT out'"
    "route allow out on virbr0 comment 'libvirt NAT return'"
)

case "${1:-status}" in
    apply)
        for r in "${RULES[@]}"; do eval "ufw $r"; done
        ufw status verbose | grep -i virbr0
        ;;
    remove)
        for r in "${RULES[@]}"; do
            r=${r% comment *}                     # delete matches on the rule, not the comment
            if [[ $r == route* ]]; then eval "ufw route delete ${r#route }"; else eval "ufw delete $r"; fi
        done
        ;;
    status)
        systemctl is-active -q ufw && echo "ufw: active" || echo "ufw: inactive"
        ufw status verbose | grep -i virbr0 || echo "(no virbr0 rules)"
        ;;
    *) echo "usage: $0 apply|remove|status" >&2; exit 2 ;;
esac
