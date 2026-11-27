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

gpu_users() { fuser /dev/dri/by-path/pci-$GPU-card /dev/dri/by-path/pci-$GPU-render 2>/dev/null | xargs -n1 | sort -un | xargs; }

# Only user processes may be signalled. PID 1 and systemd-logind keep the session's DRM fds in their
# fd store; SIGTERM to PID 1 would make systemd re-execute. They let go once the session has ended.
user_gpu_users() {
    local p out=()
    for p in $(gpu_users); do grep -qs '/user.slice/' "/proc/$p/cgroup" && out+=("$p"); done
    echo "${out[*]}"
}

AUDIO_UNITS="pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service"

# Unbinding snd_hda_intel blocks (uninterruptibly) until every open fd on the card is closed, and
# PipeWire/WirePlumber run in the per-user manager, outside the graphical session. Stop them first.
stop_audio_users() {
    local unit uid user
    for unit in $(systemctl list-units --plain --no-legend --state=active 'user@*.service' | awk '{print $1}'); do
        uid=${unit#user@}; uid=${uid%.service}
        user=$(id -nu "$uid" 2>/dev/null) || continue
        if systemctl --user -M "$user@" is-active -q pipewire.service pipewire.socket 2>/dev/null; then
            log "stopping PipeWire/WirePlumber for $user"
            timeout 20 systemctl --user -M "$user@" stop $AUDIO_UNITS 2>/dev/null
            grep -qx "$user" /run/t14s-gpu-audio-users 2>/dev/null || echo "$user" >> /run/t14s-gpu-audio-users
        fi
    done
    return 0
}

start_audio_users() {
    [[ -f /run/t14s-gpu-audio-users ]] || return 0
    local user
    while read -r user; do
        log "starting PipeWire/WirePlumber for $user"
        systemctl --user -M "$user@" start pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true
    done < /run/t14s-gpu-audio-users
    rm -f /run/t14s-gpu-audio-users
}

describe() { local p; for p in "$@"; do printf '%s(%s) ' "$p" "$(ps -o comm= -p "$p" 2>/dev/null)"; done; }

stop_graphical_sessions() {
    # Plasma runs inside the per-user systemd manager (kept alive by lingering), not only in the login
    # session, so stop each user's graphical session explicitly.
    local unit uid user
    for unit in $(systemctl list-units --plain --no-legend --state=active 'user@*.service' | awk '{print $1}'); do
        uid=${unit#user@}; uid=${uid%.service}
        user=$(id -nu "$uid" 2>/dev/null) || continue
        if systemctl --user -M "$user@" is-active -q graphical-session.target 2>/dev/null; then
            log "stopping graphical-session.target for $user"
            timeout 30 systemctl --user -M "$user@" stop graphical-session.target || log "graphical-session.target stop for $user timed out"
        fi
    done
}

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

    stop_graphical_sessions

    # Anything in user.slice still holding the GPU (apps left in the user manager) has to go.
    local users
    for i in $(seq 1 15); do [[ -z $(user_gpu_users) ]] && break; sleep 1; done
    users=$(user_gpu_users)
    if [[ -n $users ]]; then
        log "GPU still in use by: $(describe $users)-> SIGTERM"
        kill -TERM $users 2>/dev/null
        for i in $(seq 1 10); do [[ -z $(user_gpu_users) ]] && break; sleep 1; done
        users=$(user_gpu_users)
        [[ -n $users ]] && { log "-> SIGKILL $(describe $users)"; kill -KILL $users 2>/dev/null; sleep 2; }
    fi
    # System holders (PID 1 / logind fd store) should drop their copies now the session is gone
    for i in $(seq 1 10); do [[ -z $(gpu_users) ]] && break; sleep 1; done
    [[ -n $(gpu_users) ]] && log "still open by system processes: $(describe $(gpu_users))(continuing; DRM handles open fds on unbind)"

    vtcon_unbind
    # Keep both functions out of D3cold, and stop vfio-pci from putting the idle device into D3:
    # an APU iGPU coming back from D3 is a known trigger for hangs when it is reclaimed.
    echo 0 > "$DEV/$GPU/d3cold_allowed"; echo 0 > "$DEV/$AUD/d3cold_allowed"
    modprobe vfio-pci disable_idle_d3=1 || die "modprobe vfio-pci failed"
    echo Y > /sys/module/vfio_pci/parameters/disable_idle_d3 2>/dev/null || true
    log "d3cold disabled, vfio-pci disable_idle_d3=$(cat /sys/module/vfio_pci/parameters/disable_idle_d3 2>/dev/null)"
    [[ $(drv $AUD) == snd_hda_intel ]] && stop_audio_users
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
    echo 0 > "$DEV/$GPU/d3cold_allowed"; echo 0 > "$DEV/$AUD/d3cold_allowed"
    sleep 2
    local since; since=$(date '+%F %T')
    # Re-binding amdgpu after a guest is the step that hard-froze the host once. Make sure the
    # journal and all file systems are on disk first, so a freeze can't corrupt anything.
    log "power state before probe: gpu=$(cat $DEV/$GPU/power_state 2>/dev/null) audio=$(cat $DEV/$AUD/power_state 2>/dev/null)"
    journalctl --sync 2>/dev/null; sync
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
    start_audio_users
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
