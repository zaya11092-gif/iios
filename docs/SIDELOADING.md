# Sideloading

The `.ipa` built by CI is unsigned. Sign it with your own Apple ID and install
on the iPhone.

## Tools (all run on Windows)

| Tool | JIT support | Notes |
|------|-------------|-------|
| [AltStore](https://altstore.io) / [SideStore](https://sidestore.io) | via AltJIT/StikDebug | recommended; auto-refresh free certs over Wi-Fi |
| [Sideloadly](https://sideloadly.io) | needs separate JIT enabler | simplest signing path |
| [Plume](https://github.com/PlumeApp/Plume) | — | alternative |

Free Apple ID certs expire every **7 days** and are limited to **3 apps** —
use AltStore/SideStore so refreshes are automatic. Paid dev accounts last
1 year.

## Steps (SideStore example)

1. Install SideStore on the iPhone (its docs cover the one-time pairing step).
2. Open SideStore on the PC companion → **+** → pick `iios-unsigned.ipa`.
3. Sign with your Apple ID when prompted.
4. On the phone: Settings → General → VPN & Device Management → trust your
   developer profile.
5. Launch iios, allow camera access.

## JIT (not needed yet)

Phases 1–2 (ARKit / Vision / Metal / streaming) do **not** need JIT.
Phase 3 (FEX x86 translation) does. Enable it with StikDebug or the built-in
StikJIT helper the same way Madeira does — see
[Madeira's docs](https://github.com/willfaust/madeira) when Phase 3 lands.
