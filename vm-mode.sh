#!/usr/bin/env bash
# Switch the win11 domain between the emulated-display config and the iGPU passthrough config.
# Both share name, UUID, disk, NVRAM and TPM state.   Usage: ./vm-mode.sh gpu|emulated|show
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIBVIRT_DEFAULT_URI=qemu:///system

current() { virsh dumpxml --inactive win11 | grep -q "<hostdev" && echo gpu || echo emulated; }

case "${1:-show}" in
    show) echo "win11 is defined in '$(current)' mode, state: $(virsh domstate win11)" ;;
    gpu|emulated)
        [[ $(virsh domstate win11) == "shut off" ]] || { echo "win11 must be shut off first" >&2; exit 1; }
        xml="$DIR/vm/win11.xml"; [[ $1 == gpu ]] && xml="$DIR/vm/win11-gpu.xml"
        virsh define "$xml" >/dev/null
        echo "win11 now in '$(current)' mode"
        ;;
    *) echo "usage: $0 gpu|emulated|show" >&2; exit 2 ;;
esac
