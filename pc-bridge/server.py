#!/usr/bin/env python3
"""
iios pc-bridge — desktop companion for the Phase 2 streaming path.

Current scope (protocol skeleton):
  * UDP listener on port 9100
  * decodes client hello / 30 Hz pose packets and prints them
  * placeholder video sender — sends a tiny Annex-B HEVC sample header so the
    phone's parameter-set parser can be exercised end to end

Next iterations (see docs/STREAMING.md):
  * capture the SteamVR/game view via the ALVR server driver (or DXGI desktop
    duplication for the 2D-theater mode), hardware-encode HEVC, stream it here
  * inject controller input back into Windows (ViGEm / SendInput)

Run:  python server.py            (Python 3.9+, Windows/Linux/macOS)
"""
import socket
import struct
import sys

PORT = 9100
MAGIC = b"IIOS"

TYPE_HELLO = 0x01
TYPE_POSE = 0x02
TYPE_BYE = 0x03
TYPE_VIDEO = 0x10
TYPE_CONFIG = 0x11


def parse_pose(payload: bytes):
    # head 7f + 2 x (7f + trigger + grip) + 2 button bytes = 25f + 2B
    n = len(payload)
    if n < 100:
        return None
    floats = struct.unpack(f"<{25}f", payload[:100])
    buttons = struct.unpack("<BB", payload[100:102])
    return floats, buttons


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", PORT))
    print(f"[pc-bridge] listening on udp/{PORT} — waiting for the iios app…")

    client = None
    while True:
        data, addr = sock.recvfrom(65536)
        if len(data) < 5 or data[:4] != MAGIC:
            continue
        ptype = data[4]
        payload = data[5:]

        if ptype == TYPE_HELLO:
            client = addr
            name = payload[2:].split(b"\x00")[0].decode(errors="replace")
            print(f"[pc-bridge] hello from {addr}: {name} (proto {struct.unpack('<H', payload[:2])[0]})")
            # reply with a config packet: 2048x2048 stereo @ 60
            cfg = MAGIC + bytes([TYPE_CONFIG]) + struct.pack("<IIB", 2048, 2048, 60)
            sock.sendto(cfg, addr)
        elif ptype == TYPE_POSE:
            parsed = parse_pose(payload)
            if parsed:
                floats, buttons = parsed
                hx, hy, hz = floats[4], floats[5], floats[6]
                sys.stdout.write(f"\r[pose] head=({hx:+.2f},{hy:+.2f},{hz:+.2f}) btn={buttons}   ")
                sys.stdout.flush()
        elif ptype == TYPE_BYE:
            print(f"\n[pc-bridge] {addr} disconnected")
            client = None


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[pc-bridge] bye")
