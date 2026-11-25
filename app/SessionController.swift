import ARKit
import Combine
import Foundation

// Coordinates the shell <-> runtime lifecycle.
@MainActor
final class SessionController: ObservableObject {

    static let shared = SessionController()

    @Published var inVR = false
    @Published var paused = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: .xrcPauseToggled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.paused = XRCore.shared.paused
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .xrcSessionEnded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.inVR else { return }
                self.exitVR(reason: "Session ended (tracking lost or camera error).")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .xrcExitRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.exitVR()
            }
            .store(in: &cancellables)
    }

    var deviceSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func enterVR() {
        guard deviceSupported else {
            errorMessage = "ARKit world tracking is not supported on this device."
            return
        }
        paused = false
        inVR = true
    }

    func resume() {
        XRCore.shared.setPaused(false)
        paused = false
    }

    func pause() {
        XRCore.shared.setPaused(true)
    }

    func exitVR(reason: String? = nil) {
        XRHome.shared.shutdown()
        PCBridge.shared.disconnect()
        XRCore.shared.endSession()
        inVR = false
        paused = false
        if let reason = reason { errorMessage = reason }
    }
}
