import AppKit
import WebKit

/// Ends the page's hover state before its view disappears. This must go through
/// AppKit: dispatching a DOM mouseout does not clear WebKit's hit-test state.
@MainActor
enum WebViewDeparture {
    /// Bounded time for work started by a native hover exit. Neither this
    /// grace period nor the input wait confirms a provider's server save.
    private static let exitWorkGrace: TimeInterval = 0.5
    private static var hideTask: Task<Void, Never>?
    private static var hideGeneration = UUID()
    private static var unhideObserver: NSObjectProtocol?

    private static func cancelPendingHide() {
        hideGeneration = UUID()
        hideTask?.cancel()
        hideTask = nil
    }

    /// All hide entry points share this policy, including popups. Hiding
    /// itself is never delayed: the app hides first, then a background task
    /// gives recent input a bounded grace period before sending a native exit.
    /// Returning cancels the pending exit.
    static func hideApplication() {
        var webViews: [WKWebView] = []
        @MainActor func visit(_ view: NSView) {
            if let webView = view as? WKWebView {
                webViews.append(webView)
            } else {
                for subview in view.subviews { visit(subview) }
            }
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView { visit(content) }
        }
        if unhideObserver == nil {
            unhideObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willUnhideNotification, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated { cancelPendingHide() }
            }
        }
        cancelPendingHide()
        let generation = hideGeneration
        NSApp.hide(nil)
        hideTask = Task { @MainActor in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Let recently started page work finish after Hide"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            await InputSettle.shared.waitForSettle(in: webViews)
            guard !Task.isCancelled, generation == hideGeneration, NSApp.isHidden else { return }
            hideTask = nil
            for webView in webViews
                where webView.window != nil && !webView.isHiddenOrHasHiddenAncestor
            {
                endHover(in: webView)
            }
        }
    }

    /// Let hover work run while visible, then release the pinned visibility
    /// override so pages such as WhatsApp can save their session. The release
    /// and storage round trips are bounded; neither confirms a server write.
    static func prepareForQuit(in webViews: [WKWebView]) async {
        guard !webViews.isEmpty else { return }
        await prepareForDestruction(in: webViews)
        guard !Task.isCancelled else { return }
        await withDeadline(seconds: 0.3, fallback: ()) {
            let releases = webViews.map { webView in
                Task { @MainActor in
                    _ = try? await webView.evaluateJavaScriptValue(UserScriptManager.quitReleaseJS)
                }
            }
            for release in releases { await release.value }
        }
        try? await Task.sleep(for: .milliseconds(250))
        var seen = Set<ObjectIdentifier>()
        let stores = webViews.map { $0.configuration.websiteDataStore }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
        await withDeadline(seconds: 0.5, fallback: ()) {
            let flushes = stores.map { store in
                Task { @MainActor in
                    _ = await store.dataRecords(ofTypes: [
                        WKWebsiteDataTypeLocalStorage,
                        WKWebsiteDataTypeIndexedDBDatabases,
                    ])
                }
            }
            for flush in flushes { await flush.value }
        }
    }

    /// Reload, quit, and switch-detach destroy or shelve page state. Waits out
    /// recently started work FIRST, then clears hover, then gives
    /// exit-triggered saves a short bounded window. Sending the exit before
    /// the wait risks cancelling a click whose request the page has not
    /// dispatched yet; the trailing window preserves mouseout-driven saves.
    /// Limits App Nap during the grace period; this does not force site dispatch.
    /// Switching shows the new page while this settles the outgoing view
    /// before it is detached.
    static func prepareForDestruction(in webViews: [WKWebView]) async {
        guard !Task.isCancelled else { return }
        // Limit App Nap while allowing idle system sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Let recently started page work finish before destruction"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        await InputSettle.shared.waitForSettle(in: webViews)
        guard !Task.isCancelled else { return }
        let attached = webViews.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        let hadHover = await withDeadline(seconds: 0.2, fallback: true) {
            for webView in attached {
                // :root makes this work in quirks mode too, where a bare
                // :hover selector can report false despite a hovered element.
                let result = try? await webView.evaluateJavaScriptValue("document.documentElement.matches(':root:hover')")
                if result as? Bool != false { return true }
            }
            return false
        }
        guard !Task.isCancelled else { return }
        guard hadHover else { return }
        for webView in attached { endHover(in: webView) }
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(exitWorkGrace))
    }

    static func endHover(in webView: WKWebView) {
        guard let window = webView.window,
              !webView.isHiddenOrHasHiddenAncestor,
              let event = NSEvent.enterExitEvent(
                with: .mouseExited,
                location: webView.convert(NSPoint(x: webView.bounds.minX - 1, y: webView.bounds.minY - 1), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil
              ) else {
            return
        }

        // Modern WKWebView delegates tracking to an owner rather than handling
        // mouseExited itself. Use the public tracking interface, not a private
        // WebKit selector, and avoid sending twice to an owner with two areas.
        var notified = Set<ObjectIdentifier>()
        @MainActor func sendExit(in view: NSView) {
            for area in view.trackingAreas where area.options.contains(.mouseMoved) {
                guard let owner = area.owner as? NSObject,
                      owner.responds(to: #selector(NSResponder.mouseExited(with:))),
                      notified.insert(ObjectIdentifier(owner)).inserted else { continue }
                owner.perform(#selector(NSResponder.mouseExited(with:)), with: event)
            }
            for subview in view.subviews { sendExit(in: subview) }
        }
        sendExit(in: webView)
        if !notified.isEmpty { InputSettle.shared.recordDeparture(in: webView) }
    }
}
