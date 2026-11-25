import MetalKit
import SwiftUI
import UIKit

// SwiftUI bridge to the full-screen Metal view that hosts the XR session.
struct VRContainerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> VRViewController {
        VRViewController()
    }

    func updateUIViewController(_ uiViewController: VRViewController, context: Context) {}
}

final class VRViewController: UIViewController {

    private var metalView: MTKView!

    override func viewDidLoad() {
        super.viewDidLoad()
        metalView = MTKView(frame: view.bounds, device: nil)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(metalView)
        XRCore.shared.attachView(metalView)
        XRCore.shared.beginSession(view: metalView)
        XRHome.shared.sessionDidStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        XRCore.shared.endSession()
    }
}
