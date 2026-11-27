#!/usr/bin/env bash
# Run a PowerShell command inside the win11 guest via the QEMU guest agent and print its output.
#   tools/guest-ps.sh 'Get-PnpDevice -Class Display'
set -euo pipefail
DOM=${DOM:-win11}
export LIBVIRT_DEFAULT_URI=qemu:///system
cmd=${1:?usage: $0 'powershell command'}

# PowerShell -EncodedCommand takes base64 of UTF-16LE; avoids all quoting issues
enc=$(printf '%s' "$cmd" | iconv -f utf-8 -t utf-16le | base64 -w0)
req=$(python3 -I -c 'import json,sys; print(json.dumps({"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-NonInteractive","-EncodedCommand",sys.argv[1]],"capture-output":True}}))' "$enc")
pid=$(virsh qemu-agent-command "$DOM" "$req" --timeout 10 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')

for _ in $(seq 1 ${TIMEOUT:-120}); do
    st=$(virsh qemu-agent-command "$DOM" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" --timeout 10)
    # output can be large: pass it on stdin, never as an argument
    if printf '%s' "$st" | python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["return"]["exited"] else 1)'; then
        printf '%s' "$st" | python3 -I -c '
import base64, json, sys
r = json.load(sys.stdin)["return"]
for k in ("out-data", "err-data"):
    if r.get(k): sys.stdout.write(base64.b64decode(r[k]).decode("utf-8", "replace"))
sys.exit(r.get("exitcode", 0))'
        exit $?
    fi
    sleep 1
done
echo "timed out waiting for guest command" >&2; exit 124
