using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace iios
{
    // P/Invoke bridge into the iios native layer (linked into UnityFramework
    // by the post-export injection). The native side implements the same ABI
    // as windows/host-bridge/ios_bridge.h — one C contract, two consumers:
    // the OpenXR shim (SteamVR path) and Unity (this file).
    public static class IiosNativeBridge
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct IiosPose
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
            public float[] pos;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
            public float[] quat; // x, y, z, w
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IiosController
        {
            public IiosPose pose;
            public uint buttons;      // bit0 trigger, bit1 grip, bit2 primary, bit3 menu
            public float trigger;
            public float grip;
            public byte tracked;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
            public byte[] reserved;
        }

        // Exported from the injected native sources (IiosNative.mm / .c).
        [DllImport("__Internal", EntryPoint = "iios_head_pose")]
        public static extern void HeadPose(double t, ref IiosPose outPose);

        [DllImport("__Internal", EntryPoint = "iios_controller")]
        public static extern void Controller(int hand, double t, ref IiosController outController);

        [DllImport("__Internal", EntryPoint = "iios_submit_frame")]
        public static extern int SubmitFrame(double displayTime);

        [DllImport("__Internal", EntryPoint = "iios_is_tracked")]
        public static extern int IsTracked();

        /// Convenience: Unity quaternion from the native pose.
        public static Quaternion ToUnityQuaternion(IiosPose p)
        {
            return new Quaternion(p.quat[0], p.quat[1], p.quat[2], p.quat[3]);
        }

        public static Vector3 ToUnityPosition(IiosPose p)
        {
            return new Vector3(p.pos[0], p.pos[1], p.pos[2]);
        }
    }
}
