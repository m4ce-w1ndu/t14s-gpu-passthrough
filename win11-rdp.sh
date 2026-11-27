#!/usr/bin/env bash
# Open the win11 VM over RDP (much smoother than the SPICE console while there is no GPU passthrough):
# H.264/AVC444 graphics, window resizes the Windows resolution, audio, clipboard.
#
#   ./win11-rdp.sh            windowed
#   ./win11-rdp.sh -f         fullscreen (toggle with Ctrl+Alt+Enter)
#   RDP_USER=you@example.com ./win11-rdp.sh   skip the username prompt
#
# Needs: freerdp (sudo pacman -S freerdp). Sign in with the Microsoft account e-mail + password
# (not the Windows Hello PIN).
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
DOM=win11

client=$(command -v sdl-freerdp3 || command -v xfreerdp3 || true)
[[ -n $client ]] || { echo "FreeRDP not found: sudo pacman -S freerdp" >&2; exit 1; }

if virsh dumpxml --inactive "$DOM" | grep -q "<hostdev"; then
    echo "$DOM is in GPU passthrough mode; RDP is for the emulated mode (./vm-mode.sh emulated)" >&2; exit 1
fi
if [[ $(virsh domstate "$DOM") != running ]]; then
    echo "starting $DOM..."; virsh start "$DOM" >/dev/null
fi

ip=""
for _ in $(seq 1 90); do
    ip=$(virsh domifaddr "$DOM" --source agent 2>/dev/null | awk '$4 ~ /^192\.168\.122\./ {sub("/.*","",$4); print $4; exit}')
    [[ -z $ip ]] && ip=$(virsh domifaddr "$DOM" --source lease 2>/dev/null | awk '$4 ~ /^192\.168\.122\./ {sub("/.*","",$4); print $4; exit}')
    [[ -n $ip ]] && timeout 1 bash -c "</dev/tcp/$ip/3389" 2>/dev/null && break
    sleep 2
done
[[ -n $ip ]] || { echo "could not find the VM's IP / RDP port" >&2; exit 1; }
echo "connecting to $ip with $(basename "$client")"

args=(
    "/v:$ip" /cert:tofu
    /dynamic-resolution /gfx:AVC444 /network:lan
    /sound:sys:pulse +clipboard
    /scale-desktop:100
)
[[ -n ${RDP_USER:-} ]] && args+=("/u:$RDP_USER")
[[ ${1:-} == -f ]] && args+=(/f)

exec "$client" "${args[@]}"
