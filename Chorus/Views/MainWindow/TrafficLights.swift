import SwiftUI
import AppKit

/// Where the window's three traffic lights sit in the 52 point band.
///
/// A hidden title bar leaves them in its own 28 point strip, 16 points down,
/// which is 10 points above the centre line of everything else in the band.
/// A real toolbar would centre them, but a toolbar's view takes the clicks in
/// the band, and the bar layouts keep their tabs there. So the lights are moved
/// instead, the way Electron's `trafficLightPosition` does it: the title bar's
/// container grows to the band's height and the buttons move within it.
enum TrafficLightsLayout {
    /// The first light's centre sits this far in from the left, which is the
    /// band's half-height, so it is as far from the side as from the top.
    static func leadingCentre(bandHeight: CGFloat) -> CGFloat {
        bandHeight / 2
    }

    /// Origins for the three buttons, left to right, in the title bar's own
    /// coordinates (y up). `pitch` is the distance from one button's left edge
    /// to the next, taken from AppKit's own layout rather than hardcoded.
    static func origins(bandHeight: CGFloat, buttonSize: CGSize, pitch: CGFloat) -> [CGPoint] {
        let x = leadingCentre(bandHeight: bandHeight) - buttonSize.width / 2
        let y = (bandHeight - buttonSize.height) / 2
        return (0..<3).map { CGPoint(x: x + CGFloat($0) * pitch, y: y) }
    }
}

/// Keeps the traffic lights centred in the band. AppKit puts them back on
/// every title-bar layout pass (a resize, leaving full screen, a change of key
/// window or appearance), so this listens for those and moves them again.
struct TrafficLightsPositioner: NSViewRepresentable {
    let bandHeight: CGFloat

    func makeNSView(context: Context) -> PositionerView {
        PositionerView(bandHeight: bandHeight)
    }

    func updateNSView(_ nsView: PositionerView, context: Context) {
        nsView.bandHeight = bandHeight
        nsView.scheduleReposition()
    }

    final class PositionerView: NSView {
        var bandHeight: CGFloat
        private var observers: [NSObjectProtocol] = []
        /// AppKit's own spacing, read once before the first move, since a moved
        /// button no longer tells us where AppKit wanted it.
        private var nativePitch: CGFloat?

        init(bandHeight: CGFloat) {
            self.bandHeight = bandHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeScreenNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reposition() }
                }
            }
            scheduleReposition()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            scheduleReposition()
        }

        /// After AppKit's own pass, so ours is the one that lands.
        func scheduleReposition() {
            DispatchQueue.main.async { [weak self] in
                self?.reposition()
            }
        }

        private func reposition() {
            guard let window,
                  // Full screen hides the lights in a menu-bar strip of their own.
                  !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview
            else { return }

            let pitch = nativePitch ?? (minimize.frame.minX - close.frame.minX)
            nativePitch = pitch

            var containerFrame = container.frame
            containerFrame.size.height = bandHeight
            containerFrame.origin.y = window.frame.height - bandHeight
            if container.frame != containerFrame {
                container.frame = containerFrame
            }
            var titlebarFrame = titlebar.frame
            titlebarFrame.size.height = bandHeight
            titlebarFrame.origin.y = 0
            if titlebar.frame != titlebarFrame {
                titlebar.frame = titlebarFrame
            }

            let origins = TrafficLightsLayout.origins(
                bandHeight: bandHeight,
                buttonSize: close.frame.size,
                pitch: pitch
            )
            for (button, origin) in zip([close, minimize, zoom], origins) where button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }
}
