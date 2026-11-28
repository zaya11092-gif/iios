using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace iios
{
    // Runtime bridge for the SteamVR backend (Phase 3). The native half
    // (IiosNative.mm, force-linked into UnityFramework) launches the
    // FEX/Wine/DXMT layer and reports when a SteamVR session is live. While
    // active, the shell swaps the passthrough view for the SteamVR view.
    public static class IiosSteamVR
    {
        [DllImport("__Internal", EntryPoint = "iios_launch_steamvr")]
        public static extern void Launch();

        [DllImport("__Internal", EntryPoint = "iios_steamvr_active")]
        public static extern int IsActive();

        [DllImport("__Internal", EntryPoint = "iios_steamvr_stop")]
        public static extern void Stop();

        /// Convenience: raises the in-VR hand menu / switches what the eyes see.
        public static void Toggle()
        {
            if (IsActive() != 0)
                Stop();
            else
                Launch();
        }
    }
}