#!/usr/bin/env python3
"""Wrap an EFI driver into an uncompressed PCI option ROM (like edk2 `EfiRom -f VID -i DID -e`).

Usage: python3 efirom.py VENDOR_ID DEVICE_ID IN.efi OUT.rom    (ids in hex, e.g. 1002 1638)
"""
import struct
import sys

ROM_HDR = struct.Struct("<HHIHHH8sHH")          # EFI_PCI_EXPANSION_ROM_HEADER, 0x1A packed (0x1C padded in C)
PCIR = struct.Struct("<4sHHHHB3sHHBBHHH")       # PCI 3.0 data structure, 0x1C


def main():
    vid, did = int(sys.argv[1], 16), int(sys.argv[2], 16)
    efi = open(sys.argv[3], "rb").read()

    if efi[:2] != b"MZ":
        sys.exit("input is not a PE image")
    pe = struct.unpack_from("<I", efi, 0x3C)[0]
    if efi[pe:pe + 4] != b"PE\0\0":
        sys.exit("bad PE header")
    machine = struct.unpack_from("<H", efi, pe + 4)[0]
    subsystem = struct.unpack_from("<H", efi, pe + 24 + 68)[0]   # OptionalHeader.Subsystem
    if subsystem not in (10, 11, 12):
        sys.exit(f"PE subsystem {subsystem} is not an EFI application/driver")

    pcir_off = (ROM_HDR.size + 3) & ~3        # 0x1C: sizeof() in C is padded; PCIR must be DWORD aligned
    img_off = (pcir_off + PCIR.size + 0xF) & ~0xF
    total = (img_off + len(efi) + 511) & ~511
    blocks = total // 512
    if blocks > 0xFFFF:
        sys.exit("image too large")

    rom = bytearray(total)
    ROM_HDR.pack_into(rom, 0, 0xAA55, blocks, 0x0EF1, subsystem, machine, 0,
                      b"\0" * 8, img_off, pcir_off)
    PCIR.pack_into(rom, pcir_off,b"PCIR", vid, did, 0, PCIR.size, 3,
                   b"\0\0\0", blocks, 0, 0x03, 0x80, 0, 0, 0)  # code type 3 = EFI, last image
    rom[img_off:img_off + len(efi)] = efi
    open(sys.argv[4], "wb").write(rom)
    print(f"wrote {sys.argv[4]}: {total} bytes, {vid:04x}:{did:04x}, machine {machine:#x}, "
          f"subsystem {subsystem}, image at {img_off:#x}")


if __name__ == "__main__":
    main()
