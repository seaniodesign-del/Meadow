import SwiftUI
import MetalKit

/// Wraps MTKView for use in SwiftUI.
/// MTKView drives its own render loop (isPaused = false), calling draw(in:)
/// on the main thread at the display's native refresh rate.
struct MetalView: UIViewRepresentable {
    let viewModel: GrassFieldViewModel

    func makeCoordinator() -> GrassRenderer {
        GrassRenderer(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> TouchMTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        let view = TouchMTKView()
        view.device                  = device
        view.colorPixelFormat        = .bgra8Unorm
        // Deep dark green ground — any exposed soil between blade roots reads as
        // shadow depth, not void, matching the reference's dark-but-green look.
        view.clearColor              = MTLClearColorMake(0.016, 0.051, 0.008, 1.0)  // #040d02 near-black ground
        view.backgroundColor         = UIColor(red: 0.016, green: 0.051, blue: 0.008, alpha: 1)
        view.isOpaque                = true
        view.framebufferOnly         = false
        view.isMultipleTouchEnabled  = true
        view.isPaused                = false          // MTKView drives its own loop
        view.enableSetNeedsDisplay   = false          // timer-based, not event-based
        view.preferredFramesPerSecond = 0             // auto-selects 60 or 120 (ProMotion)
        view.autoResizeDrawable      = true

        let renderer = context.coordinator
        view.delegate       = renderer
        view.touchForwarder = renderer
        renderer.setup(device: device, view: view)

        return view
    }

    func updateUIView(_ uiView: TouchMTKView, context: Context) {}
}

// MARK: - Touch forwarding protocol

@MainActor
protocol TouchForwarder: AnyObject {
    func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?)
    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?)
    func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?)
    func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?)
}

// MARK: - MTKView subclass that forwards UIKit touch events

final class TouchMTKView: MTKView {
    weak var touchForwarder: TouchForwarder?

    /// Re-arm the display link the moment the view enters a real window.
    /// MTKView's internal CADisplayLink only starts reliably once the view
    /// is in the window hierarchy; setting isPaused = false in makeUIView
    /// (before layout) can be silently ignored on iOS 26.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            isPaused = false
            enableSetNeedsDisplay = false
        }
    }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        touchForwarder?.touchesBegan(t, with: e)
    }
    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        touchForwarder?.touchesMoved(t, with: e)
    }
    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        touchForwarder?.touchesEnded(t, with: e)
    }
    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        touchForwarder?.touchesCancelled(t, with: e)
    }
}
