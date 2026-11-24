# alvr-client (Phase 2)

Stub. Will implement an ALVR-compatible streaming client:

- control channel + tracking upload (hand-derived controller poses from XRCore)
- VideoToolbox HEVC hardware decode of the PC's stereo video stream
- Metal reprojection into the iios compositor
- works with the stock [ALVR server](https://github.com/alvr-org/ALVR) + SteamVR
  on your PC → full SteamVR library + SteamVR theater mode for 2D games

Design notes live in the Phase 2 section of the main README once implementation
starts.
