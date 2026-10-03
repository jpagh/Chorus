import AppKit
import ApplicationServices

/// Mac apps in the rail. macOS cannot put another app's window inside Chorus,
/// so a Mac-app service is a launcher: selecting it opens or brings forward the
/// app, and its rail badge copies the app's Dock badge.
///
/// The app is stored in the service's `url` as `chorus-app://<bundle id>`, so a
/// Mac-app service needs no new stored property and no schema version.
enum NativeApp {
    static let scheme = "chorus-app"

    static func serviceURL(forBundleID bundleID: String) -> String {
        "\(scheme)://\(bundleID)"
    }

    /// The bundle id a service URL names, or nil for an ordinary web service.
    static func bundleID(fromServiceURL urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == scheme,
              let host = components.host, !host.isEmpty
        else { return nil }
        return host
    }

    static func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Opens the app, or brings it forward if it runs. `openApplication` on a
    /// running app also sends it a reopen event, so an app whose window was
    /// closed shows it again, which `activate()` alone does not do.
    @MainActor
    static func open(bundleID: String) {
        guard let url = appURL(bundleID: bundleID) else {
            AppLogger.webView.error("No app installed with bundle id \(bundleID)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                AppLogger.webView.error("Failed to open \(bundleID): \(error.localizedDescription)")
            }
        }
    }

    /// The app's name as Finder shows it, without ".app".
    static func displayName(of appURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: appURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The app's icon as PNG, for the service's `customIconData`.
    static func iconPNG(of appURL: URL, size: CGFloat = 128) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Reads a Dock badge string as a count: digits are the count, any other
    /// non-empty badge (a dot, "!") counts as one, and no badge is zero.
    static func badgeCount(fromDockLabel label: String?) -> Int {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return 0
        }
        let digits = label.filter(\.isNumber)
        return Int(digits) ?? 1
    }
}

/// Copies Mac apps' Dock badges onto their rail icons. The Dock publishes each
/// item's badge as `AXStatusLabel` through the Accessibility API, so this needs
/// Chorus to be trusted under Privacy & Security › Accessibility. Untrusted, it
/// reads nothing and the badges stay blank.
@MainActor
final class NativeAppBadgeReader {
    struct Target {
        let id: UUID
        let bundleID: String
    }

    /// The Mac-app services to read, fetched fresh each tick.
    var targetsProvider: () -> [Target] = { [] }
    /// Hands a count to the badge manager.
    var onCount: (UUID, Int) -> Void = { _, _ in }

    private var timer: Timer?
    private var promptedForTrust = false

    func start(interval: TimeInterval = 3) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's Accessibility prompt, once per launch.
    func requestTrustIfNeeded() {
        guard !promptedForTrust, !Self.isTrusted else { return }
        promptedForTrust = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func tick() {
        let targets = targetsProvider()
        guard !targets.isEmpty else { return }
        guard Self.isTrusted else {
            requestTrustIfNeeded()
            return
        }
        let labels = Self.dockBadgeLabels()
        for target in targets {
            onCount(target.id, NativeApp.badgeCount(fromDockLabel: labels[target.bundleID.lowercased()]))
        }
    }

    /// The Dock's badge label for each app in it, keyed by lowercased bundle id.
    /// An app that is not in the Dock (not running, not kept there) is missing.
    static func dockBadgeLabels() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let url = attribute(item, kAXURLAttribute) as? URL,
                      let bundleID = Bundle(url: url)?.bundleIdentifier
                else { continue }
                if let label = attribute(item, "AXStatusLabel") as? String {
                    result[bundleID.lowercased()] = label
                }
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

/// Holds a Mac app's window over the service area while that app is selected,
/// so it looks like a tab. It is still the app's own window: Chorus moves and
/// sizes it through the Accessibility API, and hides the app when you switch
/// to another service. Without Accessibility trust it only opens the app.
@MainActor
final class NativeAppDocker {
    static let shared = NativeAppDocker()

    /// The app being held in place, or nil when a web service is selected.
    private(set) var dockedBundleID: String?
    /// The service area in Cocoa screen coordinates (origin bottom left).
    private var targetRect: CGRect?
    private var placeTask: Task<Void, Never>?
    /// True while Chorus's window is minimized, closed or hidden, so the app is
    /// hidden with it and comes back when Chorus does.
    private var isSuspended = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chorusBecameActive() }
            },
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
    }

    /// A click on a Mac-app service that is already selected changes nothing,
    /// so the selection observer never fires; bring the app forward here.
    static func reselect(_ service: ServiceInstance, wasSelected: Bool) {
        guard wasSelected, let bundleID = service.nativeAppBundleID else { return }
        shared.dock(bundleID: bundleID)
    }

    /// When you come back to Chorus with a Mac app selected, put the app back
    /// in front, as a tab would be. A click on Chorus's own controls (the rail,
    /// the toolbar) is left alone, or you could never pick another service.
    private func chorusBecameActive() {
        guard let bundleID = dockedBundleID, !isSuspended else { return }
        if NSEvent.pressedMouseButtons != 0 {
            guard let targetRect, targetRect.contains(NSEvent.mouseLocation) else { return }
        }
        dock(bundleID: bundleID)
    }

    /// Hides the docked app while Chorus's window is out of sight, keeping it
    /// docked so `resume` can bring it back.
    func suspend() {
        guard let bundleID = dockedBundleID, !isSuspended else { return }
        isSuspended = true
        placeTask?.cancel()
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.hide()
    }

    /// Brings the docked app back after `suspend`, without taking focus from
    /// Chorus: the app is shown and placed, and stays behind until selected.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        guard let bundleID = dockedBundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.unhide()
        _ = place()
    }

    /// Opens the app and, once it has a window, lays it over the service area.
    /// A cold launch takes a moment to make its window, so this waits for one.
    func dock(bundleID: String) {
        dockedBundleID = bundleID
        isSuspended = false
        NativeApp.open(bundleID: bundleID)
        placeTask?.cancel()
        placeTask = Task { @MainActor [weak self] in
            for _ in 0..<50 {
                guard let self, !Task.isCancelled, self.dockedBundleID == bundleID else { return }
                if self.place() { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Hides the docked app, if any, and stops following the service area.
    func undock() {
        placeTask?.cancel()
        isSuspended = false
        guard let bundleID = dockedBundleID else { return }
        dockedBundleID = nil
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.hide()
    }

    /// Records where the service area is now and moves the docked window there.
    func updateTarget(_ rect: CGRect) {
        guard rect != targetRect else { return }
        targetRect = rect
        if dockedBundleID != nil { _ = place() }
    }

    /// Moves and sizes the docked app's window. False if there is nothing to
    /// place yet: no trust, no running app, or no window.
    @discardableResult
    private func place() -> Bool {
        guard AXIsProcessTrusted(),
              let bundleID = dockedBundleID,
              let rect = targetRect, rect.width > 0, rect.height > 0,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let window = Self.mainWindow(of: app.processIdentifier),
              let primary = NSScreen.screens.first
        else { return false }
        // Accessibility uses a top-left origin on the primary screen.
        var origin = CGPoint(x: rect.minX, y: primary.frame.maxY - rect.maxY)
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let dimensions = AXValueCreate(.cgSize, &size)
        else { return false }
        // Position, size, then position again: a window moved onto another
        // screen can have its size clamped by the screen it started on.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        return true
    }

    private static func mainWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success
        else { return nil }
        return (windows as? [AXUIElement])?.first
    }
}
