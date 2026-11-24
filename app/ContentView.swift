import SwiftUI

struct ContentView: View {
    @ObservedObject private var session = SessionController.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.inVR {
                VRContainerView()
                    .ignoresSafeArea()
                if session.paused {
                    PauseMenuView()
                } else {
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
