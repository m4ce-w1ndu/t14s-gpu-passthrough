# t14s-gpu-passthrough

Windows 11 VM on a ThinkPad T14s Gen 2a (Ryzen 7 PRO 5850U, Cezanne iGPU `1002:1638`), working toward single
iGPU passthrough. **Read `docs/reset.md` first**: it holds every test run, its result and the current status.

## Safety rules (learned the hard way)

- **Never re-bind amdgpu to the iGPU after a guest has used it.** It hard-froze the host once, and the forced
  power-off corrupted the root file system. After a passthrough VM ends, the libvirt hook does a *clean host
  reboot*. Returning the GPU to the host is opt-in via `/etc/t14s-gpu/return-to-host`; don't create that file
  unless the user explicitly decides to test it.
- **Never restart the Windows graphics driver** (Win+Ctrl+Shift+B, disable/enable from the host side while it
  runs). The iGPU can't be reset in the VM, so the device dies (code 31/43).
- **Never force the PCI bus reset** of `05:00.0`. It is shared with the PSP (`05:00.2`), both USB 3.1
  controllers and the audio coprocessor.
- The laptop has **no SysRq key**. A freeze means a power-button reset, so think before any step that touches the
  GPU from the host.

## How things are run

- The VM `win11` lives on `qemu:///system`. Always pass `-c qemu:///system` (or export `LIBVIRT_DEFAULT_URI`):
  Claude's shell is zsh, and the fish config that sets it doesn't apply there.
- One domain, two configs with the same UUID/TPM/NVRAM: `vm/win11.xml` (emulated display, the daily driver for
  now) and `vm/win11-gpu.xml` (passthrough). Switch with `./vm-mode.sh emulated|gpu|show`.
- Daily use without passthrough: `./win11-rdp.sh` (FreeRDP, AVC444, dynamic resolution).
- Inside the guest: `tools/guest-ps.sh '<powershell>'` runs commands through the QEMU guest agent. This works
  even when the guest display is dark.
- GPU tests stop the desktop, so they are run from tmux on a **TTY login** (Ctrl+Alt+F3) with Remote Control. The
  user grants temporary passwordless sudo with `./claude-session.sh grant 4` in a separate tmux window (sudo needs
  a real terminal). It is revoked automatically at every boot.
- Launch anything that may hang or kill the session detached (`setsid -f … > logfile`) and poll the log.
- Installed copies must match the repo: `/usr/local/libexec/t14s-gpu-handover` ← `scripts/gpu-handover.sh`,
  `/etc/libvirt/hooks/qemu.d/t14s-gpu` ← `hooks/qemu.d/t14s-gpu` (reinstall with the exact `install` commands
  allowed by the sudo session).
- Commit and push after each meaningful step; record every test in `docs/reset.md`.
