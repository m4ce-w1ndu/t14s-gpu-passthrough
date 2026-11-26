#!/usr/bin/env bash
# Dump the iGPU VBIOS from the ACPI VFCT table into ./rom, owned by the invoking user.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/rom"

# Re-run as root if needed (VFCT is root-readable only)
if [[ $EUID -ne 0 ]]; then
    exec sudo --preserve-env=HOME "$0" "$@"
fi

OWNER="${SUDO_USER:-root}"
mkdir -p "$OUT"

python3 "$DIR/tools/vfct_dump.py" "$OUT"

chown -R "$OWNER:$(id -gn "$OWNER")" "$OUT"

echo
echo "Files in $OUT:"
for f in "$OUT"/*.bin; do
    [[ -e $f ]] || continue
    printf '  %s  %s bytes  sha256 %s\n' "$(basename "$f")" "$(stat -c %s "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
done
