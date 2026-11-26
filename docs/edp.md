# Built-in panel (eDP) in the guest: investigation

Findings from the host running BIOS 1.37 with amdgpu loaded.

## What the hardware tells us

| Check | Result | Meaning for passthrough |
|---|---|---|
| eDP wiring | `card1-eDP-1` hangs off the iGPU `05:00.0`. There is no MUX and no other GPU. | Whoever owns the iGPU owns the panel. |
| VBIOS display paths (`tools/atom_info.py`) | Path 0 = **eDP → UNIPHY, device tag LCD1**, plus HDMI-A and 2× DP (USB-C) | The Lenovo-patched VFCT VBIOS describes the internal panel, so the Windows driver can see it. |
| Backlight | `amdgpu_bl1`, type `raw`, range 0–65535 | Brightness is PWM driven by the GPU, not ACPI or the EC. Windows' slider should work. The Fn keys won't, because the host EC and `thinkpad_acpi` handle them. |
| EDID | amdgpu: *"Using ACPI provided EDID for eDP-1"*. Valid 128-byte EDID 1.4, `LEN 40ad`, "LEB14203N-WJ", 31×17 cm | The firmware supplies the EDID through ACPI `_DDC` on `\_SB_.PCI0.GP17.VGA_`. The guest has no such method, so Windows will read the panel's own EDID over DP-AUX. If that EDID turns out to be wrong, `_DDC` can be recreated in a guest SSDT. |
| ACPI GPU node | `\_SB_.PCI0.GP17.VGA_` (holds the AMD ATIF/ATCS methods) | Missing in the guest. Normally not fatal for display output, but it's the first thing to recreate in an SSDT if the panel stays black. |
| Privacy screen | `privacy_screen-thinkpad_acpi`, currently disabled | Controlled by the EC. It stays in whatever state the host left it. |

## The real risk: GPU state handed over by the host

eDP output depends on the GOP and driver running the panel power-up sequence (VDD → link training →
backlight enable) from a clean state. Unbinding amdgpu at runtime switches the panel off and leaves the
GPU uninitialised. On top of that, Cezanne has no working reset, so the guest inherits whatever state
amdgpu left behind. That is the most likely reason the panel would stay black.

## Plan

1. **Dedicated "passthrough" boot entry.** Use `vfio-pci.ids=1002:1638,1002:1637` and
   `initcall_blacklist=sysfb_init`, and load vfio-pci before amdgpu. amdgpu then never touches the iGPU: only
   the firmware GOP has initialised it, which is the same state Windows gets on bare metal. The host runs
   headless (LUKS unlocks via TPM2, so no display is needed to boot) and is managed over SSH. The normal
   boot entry stays unchanged.
2. **Input:** pass the built-in keyboard and TrackPoint/touchpad through to the guest with QEMU `input-linux`
   (evdev).
3. **VM:** `05:00.0` with `rom/vbios_1002_1638.bin` and `05:00.1` with `rom/AMDGopDriver.rom` go into one
   multifunction guest slot. The emulated video device is removed.
4. **First signal to watch:** the OVMF/TianoCore boot logo appearing **on the internal panel**. If it does,
   the GOP drives eDP and the Windows driver very likely will too. If only HDMI lights up, move on to a guest
   SSDT (`_DDC` EDID, then ATIF) injected with `-acpitable`.
