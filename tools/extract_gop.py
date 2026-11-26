#!/usr/bin/env python3
"""Find a DXE driver by UI name inside a UEFI firmware image and save its PE32 body.

Pure stdlib: walks firmware volumes (_FVH), FFS files and sections, decompressing
LZMA GUID-defined sections and recursing into nested volumes.

Usage: python3 extract_gop.py FIRMWARE.FL1 OUT.efi [UI_NAME]   (default UI_NAME: AMDGopDriver)
"""
import lzma
import struct
import sys
import uuid

LZMA_GUID = uuid.UUID("EE4E5898-3914-4259-9D6E-DC7BD79403CF")
LZMAF86_GUID = uuid.UUID("D42AE6BD-1352-4BFB-909A-CA72A6EAE889")

SEC_COMPRESSION, SEC_GUID_DEFINED = 0x01, 0x02
SEC_PE32, SEC_UI, SEC_FV_IMAGE = 0x10, 0x15, 0x17

found = []   # (ui_name, file_guid, pe32_bytes)
seen_fv = set()


def align(x, a):
    return (x + a - 1) & ~(a - 1)


def lzma_decode(blob):
    return lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(blob)


def parse_sections(data, file_guid, depth):
    ui, pe = None, None
    off = 0
    while off + 4 <= len(data):
        size = int.from_bytes(data[off:off + 3], "little")
        stype = data[off + 3]
        hdr = 4
        if size == 0xFFFFFF:
            size = struct.unpack_from("<I", data, off + 4)[0]
            hdr = 8
        if size < hdr or off + size > len(data):
            break
        body = data[off + hdr:off + size]
        if stype == SEC_UI:
            ui = body.decode("utf-16-le", "ignore").rstrip("\0")
        elif stype == SEC_PE32:
            pe = body
        elif stype == SEC_FV_IMAGE:
            scan(body, depth + 1)
        elif stype == SEC_GUID_DEFINED:
            g = uuid.UUID(bytes_le=bytes(body[:16]))
            data_off = struct.unpack_from("<H", body, 16)[0] - hdr
            payload = body[data_off:]
            if g in (LZMA_GUID, LZMAF86_GUID):
                try:
                    dec = lzma_decode(payload)
                    if g == LZMAF86_GUID:
                        print(f"  warn: LZMA+x86 BCJ section in {file_guid}, PE32 inside would need BCJ decode")
                    ui2, pe2 = parse_sections(dec, file_guid, depth + 1)
                    ui, pe = ui or ui2, pe or pe2
                except lzma.LZMAError as e:
                    print(f"  warn: LZMA failed in {file_guid}: {e}")
            else:
                ui2, pe2 = parse_sections(payload, file_guid, depth + 1)
                ui, pe = ui or ui2, pe or pe2
        elif stype == SEC_COMPRESSION:
            ctype = body[4]
            if ctype == 0:
                ui2, pe2 = parse_sections(body[5:], file_guid, depth + 1)
                ui, pe = ui or ui2, pe or pe2
            else:
                print(f"  warn: EFI/Tiano-compressed section in {file_guid} not supported")
        off = align(off + size, 4)
    return ui, pe


def parse_fv(data, base, depth):
    fv_len = struct.unpack_from("<Q", data, base + 32)[0]
    hdr_len, _, ext_off = struct.unpack_from("<HHH", data, base + 48)
    if fv_len < hdr_len or base + fv_len > len(data) or hdr_len < 0x48:
        return
    fv = data[base:base + fv_len]
    off = hdr_len
    if ext_off:
        ext_size = struct.unpack_from("<I", fv, ext_off + 16)[0]
        off = ext_off + ext_size
    off = align(off, 8)
    while off + 24 <= len(fv):
        if fv[off:off + 24] == b"\xff" * 24:
            break
        guid = uuid.UUID(bytes_le=bytes(fv[off:off + 16]))
        ftype, attrs = fv[off + 18], fv[off + 19]
        size = int.from_bytes(fv[off + 20:off + 23], "little")
        hdr = 24
        if attrs & 0x01:  # FFS_ATTRIB_LARGE_FILE
            size = struct.unpack_from("<Q", fv, off + 24)[0]
            hdr = 32
        if size < hdr or off + size > len(fv):
            break
        body = fv[off + hdr:off + size]
        if ftype not in (0x00, 0x01, 0xF0):  # skip all/raw/pad
            ui, pe = parse_sections(body, guid, depth)
            if ui:
                found.append((ui, guid, pe))
        elif ftype == 0x01 and b"_FVH" in body:
            scan(body, depth + 1)
        off = align(off + size, 8)


def scan(data, depth=0):
    data = memoryview(bytes(data))
    raw = data.tobytes()
    pos = raw.find(b"_FVH")
    while pos != -1:
        base = pos - 40
        key = (hash(raw[max(base, 0):base + 64]), len(raw), base)
        if base >= 0 and key not in seen_fv:
            seen_fv.add(key)
            parse_fv(raw, base, depth)
        pos = raw.find(b"_FVH", pos + 4)


def main():
    src, out = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else "AMDGopDriver"
    scan(open(src, "rb").read())
    print(f"{len(found)} named modules found")
    hits = [f for f in found if name.lower() in f[0].lower()]
    for ui, guid, pe in hits:
        print(f"match: {ui!r} {guid} PE32={'%d bytes' % len(pe) if pe else 'none'}")
    hits = [h for h in hits if h[2]]
    if not hits:
        gops = sorted({u for u, _, _ in found if "gop" in u.lower() or "vbios" in u.lower()})
        sys.exit(f"no PE32 for {name!r}; GOP/VBIOS-like names seen: {gops}")
    ui, guid, pe = hits[0]
    if pe[:2] != b"MZ":
        sys.exit("extracted body is not a PE image")
    open(out, "wb").write(pe)
    print(f"wrote {out} ({len(pe)} bytes) from {ui!r} {guid}")


if __name__ == "__main__":
    main()
