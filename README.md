# t14s-gpu-passthrough

A Windows 11 KVM/libvirt VM on a **Lenovo ThinkPad T14s Gen 2a** (Ryzen 7 PRO 5850U), working toward
**single iGPU passthrough** of the integrated Radeon Vega 8 (Cezanne, `1002:1638`).

> **Status: experimental.** Stage 1 (a tuned VM with emulated display) is set up. Stage 2 (iGPU passthrough) is
> not done yet. Expect problems on this hardware:
> - **Reset bug:** Cezanne iGPUs usually can't be reset. Plan on rebooting the host after each passthrough session.
>   `vendor-reset` doesn't support this chip.
> - **Code 43:** the Windows AMD driver needs the VBIOS plus the AMD GOP driver, passed in as ROM files.
> - **Built-in screen:** the laptop panel (eDP) may stay dark in the guest. Test with an external monitor first.

## Layout

| Path | Purpose |
|---|---|
| `host-setup.sh` | One-time host setup on Arch/CachyOS: packages, `libvirt` group, default network, fish config |
| `fish/libvirt.fish` | Sets `LIBVIRT_DEFAULT_URI=qemu:///system` so `virsh` uses the system instance |
| `dump-vbios.sh` | Dumps the iGPU VBIOS from the ACPI VFCT table into `rom/` |
| `tools/vfct_dump.py` | VFCT table parser (Python standard library only) |
| `tools/extract_gop.py` | Pulls a DXE driver by name out of a UEFI firmware image (FV/FFS/LZMA walker, standard library only) |
| `tools/efirom.py` | Wraps an EFI driver into a PCI option ROM, like edk2's `EfiRom` |
| `vm/win11.xml` | libvirt domain definition |

## ROM files are not in this repo

The VBIOS and the GOP driver are proprietary AMD/Lenovo firmware, so `rom/` is gitignored. Regenerate them on
your own machine:

```sh
./dump-vbios.sh                                   # -> rom/vbios_1002_1638.bin

# GOP: from Lenovo's "BIOS Update (Bootable CD)" ISO for the T14s Gen 2a.
# The ISO uses hard-disk emulation: carve the boot image out, then open it with 7z.
# Its FLASH/R1NETxxW/$0AR1N00.FL1 file is the firmware image.
python3 tools/extract_gop.py '$0AR1N00.FL1' rom/AMDGopDriver.efi AMDGenericGop
python3 tools/efirom.py 1002 1638 rom/AMDGopDriver.efi rom/AMDGopDriver.rom
```

In BIOS 1.39 (R1NET69W) the driver is named `AMDGenericGop` and reports "AMD GOP X64 Release Driver Rev.2.24.0.17.10".

## VM

The guest gets **6 vCPUs (3 cores × 2 threads)** pinned to host cores 5–7 (CPUs 10–15). QEMU's emulator threads
run on core 4, and cores 0–3 are left for the host. CPU mode is `host-passthrough` with `topoext` and Hyper-V
enlightenments. The VM has 6 GiB RAM, a 128 GiB thin-provisioned qcow2 disk on virtio, a virtio NIC, TPM 2.0
(swtpm), and Secure Boot–capable OVMF. Arch ships no Microsoft keys, so the VM runs with keys not enrolled.

```sh
./host-setup.sh                 # then log out and back in
virsh pool-define-as default dir --target /var/lib/libvirt/images && virsh pool-start default && virsh pool-autostart default
virsh vol-create-as default win11.qcow2 128G --format qcow2
# Upload the Windows ISO and virtio-win.iso into the pool as win11-install.iso / virtio-win.iso
# (create each volume with vol-create-as first, then fill it with vol-upload).
virsh define vm/win11.xml && virsh start win11
virt-manager --connect qemu:///system --show-domain-console win11
```

During Windows setup, click **Load driver** and pick `viostor\w11\amd64` from the virtio-win CD so the disk shows up.
Once Windows is installed, run `virtio-win-guest-tools.exe` from the same CD.
