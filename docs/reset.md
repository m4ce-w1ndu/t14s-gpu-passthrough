# Living with the Cezanne reset bug

## Constraints

- **No usable PCI reset.** `05:00.0/reset_method` only offers `bus`, a secondary bus reset of `00:08.1`.
  That bridge also carries the PSP (`05:00.2`), both USB 3.1 controllers, the audio coprocessor and the HD
  audio controller, so the kernel refuses the reset (correctly). The hand-over script also clears
  `reset_method` so nothing ever forces it.
- **vendor-reset is out.** The only Cezanne report uses a local patch on kernel ≤ 6.12. This host runs 7.3,
  and 6.16+ was reported broken.
- The TPM is a discrete ST chip (`STM0125`), not the PSP fTPM, so a misbehaving PSP can't take the LUKS keys
  with it.

## Approach: only clean hand-overs, using code already in the kernel

1. **Host → VM** (`gpu-handover to-vfio`, run by the libvirt hook):
   - stop the display manager and terminate anything still holding the GPU
   - release the GPU from amdgpu, whose clean teardown destroys the PSP rings
   - bind `vfio-pci`
2. **Guest → clean state** (`guest/setup-gpu-tasks.ps1`): Fast Startup off, disable the GPU on shutdown,
   enable it (and kick it once if it shows Code 43) at boot.
3. **VM → host** (`gpu-handover to-host`, run via `systemd-run` after the VM is gone):
   - rebind amdgpu
   - if the kernel logs ring or timeout errors, trigger amdgpu's own recovery (`amdgpu_gpu_recover`, which
     is MODE2 on Cezanne)
   - restart the display manager
4. **Fallback if 2 + 3 aren't enough:** port [amd-igpu-reset-uefi](https://github.com/severnt/amd-igpu-reset-uefi)
   (PSP ring destroy + MODE2 from an option ROM inside OVMF) from Granite Ridge to Cezanne.

## Test plan

Run Claude Code (or your shell) in tmux started from a **TTY login**, not from Konsole. Stopping the desktop
kills everything in the graphical session. `install.sh` enables lingering as an extra safety net. For a hands-off session, `./claude-session.sh grant 4` gives temporary passwordless sudo for the hand-over commands only; `./claude-session.sh revoke` ends it, and it expires on its own.

| Test | Command | Pass if |
|---|---|---|
| A: host round trip, no VM | `sudo /usr/local/libexec/t14s-gpu-handover roundtrip` | Screen goes black for ~10 s, then the login screen comes back |
| B: first VM start | `./vm-mode.sh gpu && virsh start win11` | TianoCore logo **on the built-in panel**, then Windows |
| C: VM restart | shut Windows down from Start, then `virsh start win11` | Windows shows a picture again, no Code 43 |
| D: back to host | after C, the hook returns the GPU | Login screen; `t14s-gpu-handover status` shows amdgpu |

Logs: `/var/log/t14s-gpu-handover.log`, `journalctl -t t14s-gpu`, and `C:\ProgramData\t14s-gpu\gpu.log` in the guest.
If anything freezes, hold the power button. After the reboot, the log file shows the last step that ran.

## Results

**Test A, host round trip: PASS** (2026-11-27, kernel 7.3.6, BIOS 1.37).
- Unbinding amdgpu performs a **MODE2 reset** by itself (`amdgpu: finishing device. MODE2 reset`), so vfio-pci receives a freshly reset GPU.
- Rebinding amdgpu re-initialises cleanly: SMU, DCN 2.1 and DMUB come up, and every ring initialises with no errors. eDP shows as connected.
- Gotcha found and fixed: unbinding the HDMI audio (`snd_hda_intel`) blocks in uninterruptible sleep until PipeWire/WirePlumber close the card. They live in the user's systemd manager, so the script now stops them first and restarts them afterwards.
- Side effect: the backlight comes back at 100%.

**Test B, first passthrough boot: PARTIAL, then host crash.**
- Hand-over to vfio-pci worked. Windows booted and loaded the AMD driver (31.0.21921.11005). It saw the built-in panel by its EDID (`LEB14203N-WJ`), but the **panel stayed black with no backlight**, and no TianoCore logo was shown.
- Restarting the Windows graphics driver (Win+Ctrl+Shift+B) left the GPU in `CM_PROB_FAILED_ADD`.
- After a clean guest shutdown, the hook re-bound amdgpu. The host **hard-froze during "probing amdgpu"**. The forced power-off corrupted the root file system, which needed fsck from a live USB.
- Changes made: the hook now does a **clean reboot** after the VM by default (returning the GPU to the host is opt-in through `/etc/t14s-gpu/return-to-host`), and the temporary sudo rules are revoked at every boot.

**Test B, second attempt: panel WORKS, then the GPU dies about 20 s after boot.**
- With no driver restart in the guest, the built-in panel lit up (backlight first, then the Windows login screen). Windows reports the panel as internal (`tech=0x80000000`) with a 101-level brightness interface. There is no TianoCore/boot logo: the GOP doesn't drive eDP, so the first image comes from the Windows AMD driver.
- Both sessions crash the same way (`C:\Windows\LiveKernelReports\WATCHDOG`): `0x141` VIDEO_ENGINE_TIMEOUT at about +20 s and about +50 s, then `0x1B0` (TDR recovery failed, `C0000001`), and the device ends in code 31. TDR recovery needs a GPU reset, which this iGPU can't do inside the VM.
- Host side: interrupts reach the guest (MSI-X vector 0), and there are no AMD-Vi/IOMMU faults. The interrupt count freezes once the device dies.
- Next: `TdrDelay=60`/`TdrDdiDelay=60` set in the guest, to tell a slow engine apart from a hung one.
- Touchpad (I2C HID, absolute multitouch) does not work over evdev into virtio mouse/keyboard. Keyboard and TrackPoint work.

**Test B, third attempt (TdrDelay=60): GPU survives, panel black with backlight on.**
- The first 80 s show about 31,000 MSI-X interrupts/s from the GPU (an error/retry storm, not normal work). One `0x141` engine timeout at +82 s is recovered (an engine-level reset, no PCI reset needed). After that it settles at about 60 interrupts/s (vblank), with status OK at 1920×1080@60.
- Windows renders the lock screen to the internal panel (`LogonUI`/`dwm` running, panel active, brightness 75) but the panel shows black with the backlight on. Suspected cause: Panel Self-Refresh. The driver's own key `…\Class\{4d36e968…}\0001` has `DalPSRFeatureEnable=1`; it is now set to 0.

**Test C, restart inside Windows: FAIL.** The VM hangs in OVMF during POST (one vCPU spinning at `0x7b1…`, the rest halted), and Windows never starts. With no GPU reset between guest boots, the firmware meets a dirty GPU. Prime suspect: the AMD GOP option ROM, which also never lit the panel. Next run: no GOP ROM.

**Test B, fourth attempt (no GOP option ROM): FAIL, Code 43.** Without the GOP, the Windows driver can't start the GPU (`CM_PROB_FAILED_POST_START`, problem code 0x2B = 43), there are no interrupts, and the backlight stays off. **The GOP's pre-OS initialisation is required** even though it shows nothing on eDP. The GOP ROM is restored.
