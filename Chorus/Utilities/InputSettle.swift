import AppKit
import WebKit

/// Gives recent input on a particular page a bounded chance to finish.
/// App chrome and other pages never refresh that page's grace period.
@MainActor
final class InputSettle {
    static let shared = InputSettle()
    static let settleWindow: TimeInterval = 2.2

    private struct Entry {
        weak var page: WKWebView?
        var timestamp: TimeInterval
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private let window: TimeInterval

    init(
        window: TimeInterval = 2.2,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.window = window
        self.now = now
        self.sleep = sleep
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }

    /// Used by the native event monitor; hit-testing attributes mouse input
    /// to the page, while keyboard input follows the actual first responder.
    func observe(_ event: NSEvent) {
        guard let window = event.window else { return }
        let target: NSView?
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == .command,
               ["h", "q", "r", "[", "]"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                return
            }
            target = window.firstResponder as? NSView
        } else {
            guard let content = window.contentView else { return }
            target = content.hitTest(content.convert(event.locationInWindow, from: nil))
        }
        var view = target
        while let current = view {
            if let page = current as? WKWebView {
                recordInput(in: page)
                return
            }
            view = current.superview
        }
    }

    func recordInput(in page: WKWebView) {
        entries = entries.filter { $0.value.page != nil }
        entries[ObjectIdentifier(page)] = Entry(page: page, timestamp: now())
    }

    /// An exit can itself start page work; remember it across hide/switch/quit.
    func recordDeparture(in page: WKWebView) {
        recordInput(in: page)
    }

    func remainingWait(for page: WKWebView) -> TimeInterval {
        guard let entry = entries[ObjectIdentifier(page)], entry.page === page else { return 0 }
        return max(0, window - (now() - entry.timestamp))
    }

    func waitForSettle(in pages: [WKWebView]) async {
        let deadline = now() + window
        while !Task.isCancelled {
            let remaining = min(pages.map { remainingWait(for: $0) }.max() ?? 0, deadline - now())
            guard remaining > 0 else { return }
            do { try await sleep(remaining) } catch { return }
        }
    }

    nonisolated static func remainingWait(since lastInput: Date, now: Date, window: TimeInterval) -> TimeInterval {
        max(0, window - now.timeIntervalSince(lastInput))
    }
}
