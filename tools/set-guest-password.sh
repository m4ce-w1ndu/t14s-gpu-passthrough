#!/usr/bin/env bash
# Set a local Windows account's password from the host, through the QEMU guest agent.
# The password is read hidden from this terminal (paste with Ctrl+Shift+V) and never echoed or logged.
#   tools/set-guest-password.sh Admin
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
DOM=${DOM:-win11}
user=${1:?usage: $0 <windows-local-user>}

[[ -t 0 ]] || { echo "run this in a real terminal (it needs to read the password hidden)" >&2; exit 1; }
virsh qemu-agent-command "$DOM" '{"execute":"guest-ping"}' --timeout 5 >/dev/null \
    || { echo "guest agent not reachable: is $DOM running?" >&2; exit 1; }

read -rsp "New password for $user: " pw1; echo
read -rsp "Repeat: " pw2; echo
[[ -n $pw1 ]] || { echo "empty password refused" >&2; exit 1; }
[[ $pw1 == "$pw2" ]] || { echo "passwords differ" >&2; exit 1; }

virsh set-user-password "$DOM" "$user" "$pw1" >/dev/null
unset pw1 pw2
echo "Password for $user set."
