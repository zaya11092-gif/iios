# PC streaming — SteamVR from your gaming PC (Phase 2)

Status: **transport skeleton working, video pipeline in progress.** This is
the same architectural slot Quest uses for PCVR: the phone is a tracked
client; the PC renders.

## Architecture

```
iPhone (iios app)                      Gaming PC (pc-bridge / ALVR server)
┌──────────────────────┐   UDP Wi-Fi   ┌──────────────────────────────┐
│ XRCore head+hand pose│ ──30 Hz──────▶│ driver: OpenXR/SteamVR hmd   │
│ VideoToolbox HEVC dec│ ◀──HEVC───────│ + controllers from poses     │
│ compositor + timewarp│               │ encoder: NVENC/AMF/QSV HEVC  │
└──────────────────────┘               └──────────────────────────────┘
```

## Wire protocol (pc-bridge, little-endian)

Every packet starts with the ASCII magic `IIOS` + 1 type byte.

| Dir | Type | Name | Payload |
|-----|------|------|---------|
| → | 0x01 | hello | u16 protoVersion, null-terminated device name |
| → | 0x02 | pose | head pos+quat (7f), L/R controller pos+quat+trigger+grip (9f each), 2 button bytes |
| → | 0x03 | bye | — |
| ← | 0x10 | video | u32 frameIndex, u32 bytes, HEVC chunk (Annex-B; first frame carries VPS/SPS/PPS) |
| ← | 0x11 | config | u32 width, u32 height, u8 fps |

Hand-derived controller poses stream exactly like Touch controllers: the PC
driver publishes them as standard SteamVR input — games see controllers, not
hands.

## Road to full SteamVR

1. **pc-bridge video path** — capture the game view and encode HEVC
   (NVENC/AMF/QSV) and stream it. Two options, both planned:
   - *Theater mode first*: DXGI desktop-duplication capture of any 2D Steam
     game displayed on the big VR panel; input via controller-pose→XInput
     mapping (ViGEmBus). No driver needed, works day one.
   - *True VR*: integrate the open-source [ALVR](https://github.com/alvr-org/ALVR)
     server driver (GPL) so SteamVR renders stereo views for our head pose —
     the same driver real ALVR clients (Quest, Pico) use. iios becomes
     effectively an ALVR client with hand-derived input.
2. **On-device Steam (Phase 3)** — the [Madeira](https://github.com/willfaust/madeira)
   stack (FEX-Emu + Wine ARM64EC + DXMT) runs x86 Windows games locally for
   titles light enough for an A16; the OpenXR shim feeds our compositor.

## Running the skeleton today

```bash
# on the gaming PC
python pc-bridge/server.py          # listens on udp/9100
```

In iios: Settings → PC streaming → set your PC's LAN IP, enter VR →
PC Stream panel. The console prints live head/hand poses; the panel shows
connection status.
