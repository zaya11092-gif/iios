import Foundation

// WindowsHost — Phase 3 on-device Windows/Steam layer manager.
//
// The heavy lifting (FEXCore x86-64 translation, Wine ARM64EC, DXMT
// D3D->Metal) comes from windows/vendor/* built by windows/build-layer.sh;
// its artifacts land in windows/dist/ and are embedded into the app bundle.
// This class detects the layer, owns the Wine prefix, launches the user's
// configured game executable in-process (Madeira style: everything runs in
// one iOS app process, one thread tree), and reports status to the VR shell.
//
// Until the layer artifacts exist (they are built by the windows-layer CI
// stage / locally on a Mac), every entry point reports `.layerMissing` and
// the VR menu button shows that status instead of launching.
final class WindowsHost {

    static let shared = WindowsHost()

    enum Status: Equatable {
        case layerMissing
        case ready
        case launching
        case failed(String)

        var label: String {
            switch self {
            case .layerMissing: return "no layer"
            case .ready: return "ready"
            case .launching: return "running"
            case .failed(let m): return "err: \(m)"
            }
        }
    }

    private let lock = NSLock()
    private var _status: Status = .layerMissing
    var status: Status {
        lock.withLock { _status }
    }
    var statusText: String { "win: \(status.label)" }

    private init() {
        _status = Self.detectLayer()
    }

    /// The layer is present when the build outputs were embedded at package
    /// time (windows/build-layer.sh -> windows/dist -> app bundle).
    static func detectLayer() -> Status {
        let required = ["dist/fex", "dist/wine", "dist/dxmt"]
        let missing = required.contains { Bundle.main.path(forResource: $0, ofType: nil) == nil }
        return missing ? .layerMissing : .ready
    }

    /// Launches the user's configured executable through the Wine/FEX layer.
    /// The actual FEX+Wine init is provided by the layer's host bridge
    /// (windows/dist); the call below is the documented integration point —
    /// when the layer ships, this invokes its `ios_win_main(exePath)` entry.
    func launch(exePath: String) {
        lock.withLock {
            guard _status == .ready else { return }
            _status = .launching
        }
        guard status == .launching else { return }
        // IOS_LAYER_TODO: call the layer's entry point once windows/dist is
        // built and linked:
        //   ios_win_main(exePath, argv, prefixDir, hostVTable)
        // It threads the FEX CPU context, runs Wine's loader, and the game's
        // frames reach us via the ios_host_vtable (swapchain/submit_frame)
        // and, for OpenXR games, via the openxr_loader.dll shim.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.lock.withLock { self?._status = .failed("layer not linked yet") }
        }
    }

    /// The vtable the OpenXR shim (inside Wine) resolves from the main
    /// executable via GetProcAddress("ios_host_get_vtable"). Exported as a C
    /// symbol below. Populate with XRCore-backed implementations when the
    /// layer links; the table is declared complete so the shim's flow can be
    /// exercised against hello_xr as soon as FEX/Wine run.
    func exportVTable() {}
}

// The symbol the shim looks up. Kept exported (linker-visible) so that once
// the layer is linked the discovery path works without further app changes.
@_cdecl("ios_host_get_vtable")
public func ios_host_get_vtable() -> UnsafeMutableRawPointer? {
    // IOS_LAYER_TODO: return a pointer to a static ios_host_vtable whose
    // function pointers bridge to XRCore (head pose, hand controllers,
    // compositor swapchains). Until the layer lands we return nil — the shim
    // treats a missing vtable as "runtime unavailable" and games report
    // "no OpenXR runtime" instead of misbehaving.
    return nil
}
