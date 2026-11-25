import SwiftUI

struct ContentView: View {
    @ObservedObject private var session = SessionController.shared
    @ObservedObject private var home = XRHome.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.inVR {
                VRContainerView()
                    .ignoresSafeArea()
                // Pause/settings live in the in-VR floating panel (XRHome) in
                // both Phone Mode and goggles — no 2D overlay in session.
                if home.uiState == .scanning {
                    ScanOverlayView()
                } else if home.uiState == .demo {
                    HudOverlay()
                }
            } else {
                HomeView()
            }
        }
        .alert("iios", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}
