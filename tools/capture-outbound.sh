#!/bin/bash
# macOS: capture outbound packets across network changes, with PKTAP metadata.
set -u
if [[ ${EUID} -ne 0 ]]; then
    echo "Run with sudo: sudo /bin/bash \"$0\" [output-directory]" >&2
    exit 1
fi
umask 077
base="$(cd "$(dirname "$0")/.." && pwd)/captures"
if [[ $# -eq 0 && ! -d "$base" ]]; then
    mkdir -p "$base" || exit 1
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown "$SUDO_UID:$SUDO_GID" "$base" || exit 1
    fi
fi
out="${1:-$base/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$out" || exit 1
out="$(cd "$out" && pwd)"
capture_pid=""
snapshot_pid=""
finish() {
    trap '' INT TERM HUP
    [[ -n "$capture_pid" ]] && kill -INT "$capture_pid" 2>/dev/null
    [[ -n "$snapshot_pid" ]] && kill "$snapshot_pid" 2>/dev/null
    [[ -n "$capture_pid" ]] && wait "$capture_pid" 2>/dev/null
    [[ -n "$snapshot_pid" ]] && wait "$snapshot_pid" 2>/dev/null
    echo "Stopped $(date -u +%FT%TZ)" >> "$out/events.log"
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -R "$SUDO_UID:$SUDO_GID" "$out"
    fi
    echo "Capture saved: $out"
    echo "Check tcpdump.log for kernel drop counts."
    exit 0
}
trap finish INT TERM
# Closing a terminal should not terminate the capture; stop with Ctrl-C or SIGTERM.
trap '' HUP
echo "Started $(date -u +%FT%TZ)" > "$out/events.log"
echo "Capturing ALL outbound protocols on ALL interfaces, including tunnels and loopback."
echo "Output: $out"
echo "Switch Wi-Fi/hotspot freely. Stop with Ctrl-C after returning to hotspot."
echo "No capture files are overwritten or automatically deleted."
(
    while true; do
        date -u +%FT%TZ
        /sbin/ifconfig -a
        /usr/sbin/netstat -ibn
        /bin/ps -axo pid,ppid,comm
        /usr/sbin/lsof -nP -i
        sleep 10
    done
) >> "$out/network-process-snapshots.log" 2>&1 &
snapshot_pid=$!
attempt=0
while true; do
    attempt=$((attempt + 1))
    echo "Capture attempt $attempt $(date -u +%FT%TZ)" >> "$out/events.log"
    # PKTAP retains interface, direction and available process metadata.
    # No address/port filter: catches ARP, IPv4, IPv6, multicast and broadcast.
    # Full snaplen; 32 MiB capture buffer; flush packets promptly; rotate at
    # 256 MB without a ring limit, so earlier evidence is never overwritten.
    /usr/sbin/tcpdump -i pktap,all -Q out -n -s 0 -B 32768 -U \
        -C 256 -w "$out/outbound-$attempt.pcapng" \
        >> "$out/tcpdump.log" 2>&1 &
    capture_pid=$!
    wait "$capture_pid"
    result=$?
    capture_pid=""
    echo "tcpdump exited $result $(date -u +%FT%TZ); retrying in 2 seconds" >> "$out/events.log"
    sleep 2
done
