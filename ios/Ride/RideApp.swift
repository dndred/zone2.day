import AppKit
import SwiftUI

/// zone2 Ride (Mac): a small overlay above all windows (and full-screen video) with power, heart
/// rate and cadence from the trainer and HeartCast; records the ride (docs/11-trainer.md).
@main
struct RideApp: App {
    @State private var model = RideModel()

    var body: some Scene {
        Window("zone2 Ride", id: "ride") {
            OverlayView(model: model)
                .background(FloatingWindow())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

/// Puts the hosting window above everything, on every Space including full-screen ones.
private struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isMovableByWindowBackground = true
            w.titlebarAppearsTransparent = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hidesOnDeactivate = false
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
