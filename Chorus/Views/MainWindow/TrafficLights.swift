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
/// window or appearance), so this listens for those, and for the close
/// button's own frame changing, and moves them again after AppKit's pass.
/// Window tabs are off, because a tab bar would sit where the taller title
/// bar now is.
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
        /// AppKit's own spacing, read before the first move, since a moved
        /// button no longer tells us where AppKit wanted it. Kept only once it
        /// is a real distance: frames read before the first layout are zero.
        private var nativePitch: CGFloat?
        /// Between entering and leaving full screen, AppKit owns the buttons.
        private var isInFullScreenTransition = false
        private var isRepositionScheduled = false

        init(bandHeight: CGFloat) {
            self.bandHeight = bandHeight
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Takes no clicks: it fills the window behind everything.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.tabbingMode = .disallowed

            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification
            ]
            observers = names.map { name in
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleReposition() }
                }
            }
            observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isInFullScreenTransition = true }
            })
            observers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isInFullScreenTransition = true }
            })
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isInFullScreenTransition = false
                        self?.scheduleReposition()
                    }
                })
            }
            // Any title-bar pass that moves the close button, whatever caused
            // it. Our own move posts this too, and then finds nothing to do.
            if let close = window.standardWindowButton(.closeButton) {
                close.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleReposition() }
                })
            }
            scheduleReposition()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            scheduleReposition()
        }

        /// After AppKit's own pass, so ours is the one that lands. Several
        /// triggers in one turn of the run loop make one move.
        func scheduleReposition() {
            guard !isRepositionScheduled else { return }
            isRepositionScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.isRepositionScheduled = false
                self?.reposition()
            }
        }

        private func reposition() {
            guard let window,
                  // Full screen hides the lights in a menu-bar strip of their own.
                  !window.styleMask.contains(.fullScreen),
                  !isInFullScreenTransition,
                  let close = window.standardWindowButton(.closeButton),
                  let minimize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview
            else { return }

            let pitch = nativePitch ?? (minimize.frame.minX - close.frame.minX)
            guard pitch > 0, close.frame.width > 0 else { return }
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
