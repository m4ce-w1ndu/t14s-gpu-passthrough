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
