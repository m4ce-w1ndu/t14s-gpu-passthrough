#!/usr/bin/env python3
"""Extract GPU VBIOS images from the ACPI VFCT table (same layout amdgpu's kernel driver parses).

Usage: sudo python3 vfct_dump.py [output_dir]
"""
import os
import struct
import sys

SRC = "/sys/firmware/acpi/tables/VFCT"
out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out_dir, exist_ok=True)

data = open(SRC, "rb").read()
if data[:4] != b"VFCT":
    sys.exit("Not a VFCT table")

# ACPI header (36) + TableUUID (16) + VBIOSImageOffset (4) + Lib1ImageOffset (4) + Reserved (16)
(offset,) = struct.unpack_from("<I", data, 36 + 16)
HDR = struct.Struct("<IIIHHHHII")  # bus, dev, fn, vendor, device, ssvid, ssid, revision, length

found = 0
while offset + HDR.size <= len(data):
    bus, dev, fn, ven, did, ssvid, ssid, rev, length = HDR.unpack_from(data, offset)
    start = offset + HDR.size
    if length == 0 or start + length > len(data):
        break
    img = data[start:start + length]
    name = os.path.join(out_dir, f"vbios_{ven:04x}_{did:04x}.bin")
    open(name, "wb").write(img)
    sig_ok = img[:2] == b"\x55\xaa"
    print(f"{bus:02x}:{dev:02x}.{fn} {ven:04x}:{did:04x} (sub {ssvid:04x}:{ssid:04x}) "
          f"{length} bytes -> {name}  ROM signature {'OK' if sig_ok else 'MISSING!'}")
    found += 1
    offset = start + length

if not found:
    sys.exit("No images found in VFCT")
