#!/usr/bin/env python3
"""Print the display paths (connectors/encoders) and key data tables of an AMD ATOM VBIOS.

Usage: python3 atom_info.py rom/vbios_1002_1638.bin
"""
import struct
import sys

CONNECTOR = {0x01: "Single-link DVI-I", 0x02: "Dual-link DVI-I", 0x03: "Single-link DVI-D",
             0x04: "Dual-link DVI-D", 0x05: "VGA", 0x0C: "HDMI-A", 0x0D: "HDMI-B", 0x0E: "LVDS",
             0x13: "DisplayPort", 0x14: "eDP", 0x15: "Mxm", 0x18: "USB-C"}
OBJ_TYPE = {1: "GPU", 2: "Encoder", 3: "Connector", 4: "Router", 5: "Generic"}
DEVICE_TAG = {0x0002: "LCD1", 0x0008: "DFP1", 0x0080: "DFP2", 0x0200: "DFP3", 0x0400: "DFP4",
              0x0800: "DFP5", 0x1000: "DFP6"}
MASTER_DATA = {4: "firmwareinfo", 6: "lcd_info", 8: "smu_info", 12: "gpio_pin_lut", 14: "gfx_info",
               15: "powerplayinfo", 22: "displayobjectinfo", 27: "dce_info", 30: "integratedsysteminfo"}


def objname(oid):
    t, enum, i = (oid >> 12) & 7, (oid >> 8) & 7, oid & 0xFF
    name = CONNECTOR.get(i, f"id {i:#x}") if t == 3 else f"id {i:#x}"
    return f"{OBJ_TYPE.get(t, t)}:{name}#{enum}"


def main():
    rom = open(sys.argv[1], "rb").read()
    assert rom[:2] == b"\x55\xaa", "not a PCI ROM"
    hdr = struct.unpack_from("<H", rom, 0x48)[0]
    assert rom[hdr + 4:hdr + 8] == b"ATOM", "no ATOM header"
    part = rom[struct.unpack_from("<H", rom, hdr + 0x10)[0]:][:40].split(b"\0")[0]  # part number string
    master_data = struct.unpack_from("<H", rom, hdr + 0x20)[0]
    print(f"ATOM ROM header at {hdr:#x}, master data table at {master_data:#x}, part '{part.decode(errors='replace').strip()}'")

    def table(idx):
        return struct.unpack_from("<H", rom, master_data + 4 + idx * 2)[0]

    for idx, name in MASTER_DATA.items():
        off = table(idx)
        if off:
            size, frev, crev = struct.unpack_from("<HBB", rom, off)
            print(f"  {name:22s} @ {off:#06x}  v{frev}.{crev}  {size} bytes")
        else:
            print(f"  {name:22s}   (absent)")

    off = table(22)
    if not off:
        sys.exit("no displayobjectinfo table")
    size, frev, crev = struct.unpack_from("<HBB", rom, off)
    supported, npath = struct.unpack_from("<HB", rom, off + 4)
    tags = [n for b, n in DEVICE_TAG.items() if supported & b]
    print(f"\ndisplayobjectinfo v{frev}.{crev}: supporteddevices={supported:#06x} {tags}, {npath} paths")
    entry = 16 if crev <= 4 else 20
    for i in range(npath):
        p = off + 8 + i * entry
        disp, _, enc, extenc, _, _, tag, prio = struct.unpack_from("<HHHHHHHB", rom, p)
        print(f"  path {i}: {objname(disp):28s} encoder {objname(enc):18s} "
              f"{'ext ' + objname(extenc) if extenc else '':20s} device_tag {tag:#06x} "
              f"({DEVICE_TAG.get(tag, '?')}) priority {prio}")


if __name__ == "__main__":
    main()
