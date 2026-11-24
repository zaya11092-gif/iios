# Limitations — read before judging the experience

Honest list of what a base iPhone 15 can and cannot do here. No marketing.

## Hardware

- **60 Hz panel.** Real headsets run 90–120 Hz. Expect visible judder on fast
  head motion even with timewarp. Do not push demo speed until you've tested
  comfort.
- **Monoscopic passthrough.** One rear camera → the passthrough image has no
  depth. It is a video window, not stereo vision.
- **Hand tracking ~30 Hz.** Vision hand pose runs at roughly half the AR rate
  with one to two extra frames of latency. Fine for slicing cubes and menus,
  marginal for twitch gameplay. There are no physical buttons — triggers are
  pinch-distance estimates.
- **No real depth from hands.** Distance is inferred from apparent hand span
  (monocular pinhole estimate). Positions are approximate; the saber tip is
  more trustworthy than the wrist position.
- **A16 GPU ≈ Switch-class.** On-device heavy VR games will be single-digit
  FPS even through the Phase 3 translation stack. Demanding titles are a
  streaming job (Phase 2), same as Quest PCVR.

## Software / architecture

- **Monado is not ported to iOS.** XRCore reimplements the *architecture*
  (compositor / spaces / actions), not the Monado codebase.
- **SteamVR never runs on the phone.** It is a Windows, PC-GPU application.
  On-device VR games (Phase 3) work through a custom OpenXR shim that
  replaces SteamVR inside Wine; games that hard-depend on SteamVR-specific
  OpenVR calls may not work — those fall back to streaming.
- **ARKit ≠ inside-out cameras.** SLAM quality is phone-grade: good in
  feature-rich rooms, drifts in dark/featureless spaces, no guardian-style
  boundary safety. Keep the play area clear.
- **Timewarp is rotational-only.** Positional error on fast translation is
  not compensated.

## Calibration

Hand-tracking ray direction, Vision orientation, and lens distortion are all
parameterized in Settings with a live joint-overlay debug mode. First device
session: enable *Debug → show joints*, hold your palms up, and verify the
green circles sit on your joints; fix flips/orientation first, then tune
pinch thresholds.
