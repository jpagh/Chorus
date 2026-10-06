import AppKit
import WebKit

/// Owns a floating draft with its own controller and browser delegates,
/// using the account's store and settings without replacing its inbox.
@MainActor
final class MailComposeWindowSession: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let webView: WKWebView
    private let coordinator: WebViewCoordinator
    private let messageHandler: MailComposeMessageHandler
    private let onClose: () -> Void
    private let allowedOrigin: Origin
    private var isFinished = false
    private var isLocked = false
    private var lockedWindows: [NSWindow] = []
    private var focusTask: Task<Void, Never>?

    init(
        dataStore: WKWebsiteDataStore,
        userAgent: String,
        title: String,
        url: URL,
        configuration: WKWebViewConfiguration? = nil,
        coordinator: WebViewCoordinator? = nil,
        loadPage: (WKWebView, URL) -> Void = { view, url in view.load(URLRequest(url: url)) },
        onMailRequest: ((URL) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true
        let controller = configuration.userContentController
        let messageHandler = MailComposeMessageHandler()
        controller.add(messageHandler, name: "chorusMailComposer")
        controller.addUserScript(WKUserScript(
            source: UserScriptManager.makeWindowCloseInterceptionScript(handlerName: "chorusMailComposer"),
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        let coordinator = coordinator ?? WebViewCoordinator()
        // Child working pages need their own windows here: there is no tab strip
        // in a floating composer, and closing a draft must not reload the inbox.
        coordinator.opensServiceTabs = false
        coordinator.fallbackURL = url
        coordinator.onNavigationFinished = nil
        coordinator.onHealthEvent = nil
        coordinator.onTabOpened = nil
        coordinator.onTabClosed = nil
        coordinator.servicePage = { [weak webView] in webView }
        if let onMailRequest {
            coordinator.systemLinkHandler = { url in
                if url.scheme?.lowercased() == "mailto" { onMailRequest(url) }
                else { WebViewCoordinator.openExternally(url) }
            }
        }
        self.webView = webView
        self.coordinator = coordinator
        self.messageHandler = messageHandler
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        self.onClose = onClose
        allowedOrigin = Origin(scheme: url.scheme ?? "https", host: url.host ?? "", port: url.port)
        super.init()
        messageHandler.onMessage = { [weak self] message in self?.handleMessage(message) }
        coordinator.onRootClosed = { [weak self] in self?.finish(closeWindow: true) }
        webView.uiDelegate = coordinator
        webView.navigationDelegate = coordinator
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = webView
        window.center()
        loadPage(webView, url)
    }

    func show() {
        guard !isFinished, !isLocked else { return }
        cancelPendingFocus()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        focusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.isFinished, !self.isLocked, NSApp.isActive else { return }
            self.window.makeKeyAndOrderFront(nil)
        }
    }

    func cancelPendingFocus() {
        focusTask?.cancel()
        focusTask = nil
    }

    private var ownedWindows: [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        func descendants(_ window: NSWindow) -> [NSWindow] {
            guard seen.insert(ObjectIdentifier(window)).inserted else { return [] }
            return [window] + (window.childWindows ?? []).flatMap(descendants)
        }
        return ([window] + coordinator.auxiliaryWindows + [webView.window].compactMap { $0 }).flatMap(descendants)
    }

    /// Hide drafts and all owned dialogs/popups, but keep their state alive.
    func setLocked(_ locked: Bool) {
        guard !isFinished, isLocked != locked else { return }
        isLocked = locked
        coordinator.isBrowserLocked = locked
        cancelPendingFocus()
        if locked {
            lockedWindows = ownedWindows.filter(\.isVisible)
            for window in ownedWindows {
                window.contentView?.setAccessibilityHidden(true)
                window.orderOut(nil)
            }
        } else {
            let live = Set(ownedWindows.map(ObjectIdentifier.init))
            for window in ownedWindows { window.contentView?.setAccessibilityHidden(false) }
            for window in lockedWindows where live.contains(ObjectIdentifier(window)) {
                window.orderFront(nil)
            }
            lockedWindows.removeAll()
        }
    }

    private func handleMessage(_ message: WKScriptMessage) {
        guard !isFinished, message.webView === webView,
              message.name == "chorusMailComposer",
              let body = message.body as? [String: Any], body["windowClose"] as? Bool == true else { return }
        let origin = message.frameInfo.securityOrigin
        let frameOrigin = Origin(scheme: origin.protocol, host: origin.host, port: origin.port == 0 ? nil : origin.port)
        guard message.frameInfo.isMainFrame || frameOrigin == allowedOrigin else { return }
        finish(closeWindow: true)
    }

    func windowWillClose(_ notification: Notification) { finish(closeWindow: false) }

    private func finish(closeWindow: Bool) {
        guard !isFinished else { return }
        isFinished = true
        cancelPendingFocus()
        coordinator.onRootClosed = nil
        coordinator.systemLinkHandler = nil
        coordinator.servicePage = nil
        coordinator.closeAuxiliaryWindows()
        lockedWindows.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chorusMailComposer")
        webView.configuration.userContentController.removeAllUserScripts()
        messageHandler.onMessage = nil
        webView.stopLoading()
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        window.delegate = nil
        if closeWindow { window.close() }
        window.contentView = nil
        onClose()
    }
}

private final class MailComposeMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    var onMessage: (@MainActor (WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { onMessage?(message) }
    }
}
