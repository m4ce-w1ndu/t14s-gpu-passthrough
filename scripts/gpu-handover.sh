#!/usr/bin/env bash
# Move the Cezanne iGPU (05:00.0) + its HDMI audio (05:00.1) between the host (amdgpu) and vfio-pci.
#
#   gpu-handover to-vfio     stop the desktop, release the GPU from amdgpu, bind vfio-pci
#   gpu-handover to-host     bind amdgpu again (GPU recovery if needed), start the desktop
#   gpu-handover roundtrip   to-vfio, wait, to-host  (test A: no VM involved)
#   gpu-handover status
#
# Installed as /usr/local/libexec/t14s-gpu-handover (root-owned). Log: journalctl -t t14s-gpu
set -uo pipefail

GPU=0000:05:00.0
AUD=0000:05:00.1
DEV=/sys/bus/pci/devices
LOGFILE=/var/log/t14s-gpu-handover.log

log() {
    local msg="[$(date '+%F %T')] $*"
    echo "$msg"
    echo "$msg" >> "$LOGFILE"
    logger -t t14s-gpu -- "$*"
    sync "$LOGFILE" 2>/dev/null || true   # make it to disk even if the next step hangs the kernel
}
die() { log "ERROR: $*"; exit 1; }

drv() { [[ -e $DEV/$1/driver ]] && basename "$(readlink -f "$DEV/$1/driver")" || echo none; }

unbind() {
    local d=$1
    if [[ -e $DEV/$d/driver ]]; then
        log "unbind $d from $(drv "$d")"
        echo "$d" > "$DEV/$d/driver/unbind" || die "unbind $d failed"
    fi
}

probe_as() {   # probe_as <dev> <driver|"">   ("" = default kernel match)
    echo "$2" > "$DEV/$1/driver_override"
    echo "$1" > /sys/bus/pci/drivers_probe 2>/dev/null || true
}

gpu_users() { fuser /dev/dri/by-path/pci-$GPU-card /dev/dri/by-path/pci-$GPU-render 2>/dev/null | xargs; }

disable_bus_reset() {
    # The only reset this GPU offers is a secondary bus reset of 00:08.1, which would also hit the
    # PSP (05:00.2), both USB controllers and the audio coprocessor. Make sure nothing ever tries it.
    echo "" > "$DEV/$GPU/reset_method" 2>/dev/null && log "reset_method disabled for $GPU" || true
}

vtcon_unbind() {
    for v in /sys/class/vtconsole/vtcon*; do
        grep -q "frame buffer" "$v/name" 2>/dev/null && [[ $(cat "$v/bind") == 1 ]] && {
            echo 0 > "$v/bind"; echo "$v" >> /run/t14s-gpu-vtcon; log "unbound $(basename "$v")"; }
    done
    return 0
}

vtcon_rebind() {
    [[ -f /run/t14s-gpu-vtcon ]] || return 0
    while read -r v; do echo 1 > "$v/bind" 2>/dev/null && log "rebound $(basename "$v")"; done < /run/t14s-gpu-vtcon
    rm -f /run/t14s-gpu-vtcon
}

to_vfio() {
    [[ $(drv $GPU) == vfio-pci ]] && { log "GPU already on vfio-pci"; return 0; }
    log "=== to-vfio: gpu=$(drv $GPU) audio=$(drv $AUD)"
    disable_bus_reset

    if systemctl is-active -q display-manager.service; then
        log "stopping display-manager"
        systemctl stop display-manager.service
        touch /run/t14s-gpu-dm-was-active
    fi

    # Anything still holding the GPU (apps left in the user manager, etc.) has to go.
    for i in $(seq 1 15); do [[ -z $(gpu_users) ]] && break; sleep 1; done
    if [[ -n $(gpu_users) ]]; then
        log "GPU still in use by: $(gpu_users) -> SIGTERM"
        fuser -k -TERM /dev/dri/by-path/pci-$GPU-card /dev/dri/by-path/pci-$GPU-render 2>/dev/null
        sleep 5
        [[ -n $(gpu_users) ]] && { log "-> SIGKILL $(gpu_users)"; fuser -k -KILL /dev/dri/by-path/pci-$GPU-card /dev/dri/by-path/pci-$GPU-render 2>/dev/null; sleep 2; }
    fi

    vtcon_unbind
    modprobe vfio-pci || die "modprobe vfio-pci failed"
    unbind $AUD
    log "releasing GPU from amdgpu (if the system freezes here, amdgpu teardown hung)"
    unbind $GPU
    probe_as $GPU vfio-pci
    probe_as $AUD vfio-pci
    [[ $(drv $GPU) == vfio-pci && $(drv $AUD) == vfio-pci ]] || die "vfio bind failed: gpu=$(drv $GPU) audio=$(drv $AUD)"
    log "=== GPU on vfio-pci"
}

amdgpu_debugfs() {
    for d in /sys/kernel/debug/dri/*/; do
        grep -qs "dev=$GPU" "$d/name" && { echo "${d%/}"; return; }
    done
}

to_host() {
    log "=== to-host: gpu=$(drv $GPU) audio=$(drv $AUD)"
    [[ $(drv $GPU) == vfio-pci ]] && unbind $GPU
    [[ $(drv $AUD) == vfio-pci ]] && unbind $AUD
    local since; since=$(date '+%F %T')
    log "probing amdgpu"
    probe_as $GPU ""
    probe_as $AUD ""

    for i in $(seq 1 20); do ls "$DEV/$GPU/drm" 2>/dev/null | grep -q '^card' && break; sleep 1; done
    if [[ $(drv $GPU) != amdgpu ]]; then
        log "amdgpu did not bind (driver=$(drv $GPU)); kernel says:"
        journalctl -k --since "$since" --no-pager | grep -i amdgpu | tail -20 | while read -r l; do log "  $l"; done
        die "GPU not returned to host; a reboot is needed"
    fi

    if journalctl -k --since "$since" --no-pager | grep -qiE 'amdgpu.*(ring .* test failed|failed|timeout|hang)'; then
        log "amdgpu reported errors on init -> requesting GPU recovery (MODE2)"
        local dbg; dbg=$(amdgpu_debugfs)
        if [[ -n $dbg && -e $dbg/amdgpu_gpu_recover ]]; then
            cat "$dbg/amdgpu_gpu_recover" >/dev/null 2>&1
            sleep 3
            log "recovery done; kernel says:"
            journalctl -k --since "$since" --no-pager | grep -iE 'amdgpu.*(reset|recover|mode2)' | tail -10 | while read -r l; do log "  $l"; done
        else
            log "no amdgpu debugfs recover entry found"
        fi
    fi

    vtcon_rebind
    if [[ -f /run/t14s-gpu-dm-was-active ]]; then
        rm -f /run/t14s-gpu-dm-was-active
        log "starting display-manager"
        systemctl start display-manager.service
    fi
    log "=== GPU back on $(drv $GPU), audio on $(drv $AUD)"
}

status() {
    echo "gpu   $GPU  driver=$(drv $GPU)  reset_method='$(cat $DEV/$GPU/reset_method 2>/dev/null)'"
    echo "audio $AUD  driver=$(drv $AUD)"
    echo "display-manager: $(systemctl is-active display-manager.service)"
    echo "GPU users: $(gpu_users)"
    echo "win11: $(virsh -c qemu:///system domstate win11 2>/dev/null)"
    echo "--- last log lines"; tail -n 8 "$LOGFILE" 2>/dev/null
}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
case "${1:-}" in
    to-vfio)   to_vfio ;;
    to-host)   to_host ;;
    roundtrip) to_vfio && { log "holding on vfio-pci for 10 s"; sleep 10; to_host; } ;;
    status)    status ;;
    *) echo "usage: $0 to-vfio|to-host|roundtrip|status" >&2; exit 2 ;;
esac
