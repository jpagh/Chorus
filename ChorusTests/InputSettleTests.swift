import AppKit
import WebKit
import XCTest
@testable import Chorus

@MainActor
final class InputSettleTests: XCTestCase {
    func testPageInputAndExitDoNotDelayOtherPages() {
        var time: TimeInterval = 10
        let settle = InputSettle(window: 2, now: { time })
        let first = page(), second = page()
        settle.recordInput(in: first)
        XCTAssertEqual(settle.remainingWait(for: first), 2)
        XCTAssertEqual(settle.remainingWait(for: second), 0)
        time = 11.5
        XCTAssertEqual(settle.remainingWait(for: first), 0.5)
        settle.recordDeparture(in: first)
        XCTAssertEqual(settle.remainingWait(for: first), 2)
        time = 14
        XCTAssertEqual(settle.remainingWait(for: first), 0)
    }

    func testWaitIsBoundedEvenWhenFreshInputArrivesDuringSleep() async {
        var time: TimeInterval = 10
        let view = page()
        var settle: InputSettle!
        settle = InputSettle(window: 2, now: { time }, sleep: { duration in
            time += duration
            settle.recordInput(in: view)
        })
        settle.recordInput(in: view)
        await settle.waitForSettle(in: [view])
        XCTAssertEqual(time, 12, "New input cannot extend one departure forever")
    }

    func testNativeMouseObservationIgnoresChromeAndAttributesPageClicks() throws {
        let view = page()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        content.addSubview(view)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        let settle = InputSettle(window: 2, now: { 10 })
        func click(_ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 100),
                modifierFlags: [], timestamp: 10, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        settle.observe(try click(300))
        XCTAssertEqual(settle.remainingWait(for: view), 0)
        settle.observe(try click(100))
        XCTAssertEqual(settle.remainingWait(for: view), 2)
    }

    func testEventQueueDeliveryReachesTheInstalledMonitor() throws {
        let view = page()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        InputSettle.shared.start()
        NSApp.postEvent(event, atStart: true)
        let delivered = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown,
            until: Date().addingTimeInterval(1), inMode: .default, dequeue: true))
        NSApp.sendEvent(delivered)
        XCTAssertGreaterThan(InputSettle.shared.remainingWait(for: view), 0,
                             "Deliver native input through the monitor, not a tracking-owner shortcut")
    }

    func testKeyboardDepartureShortcutDoesNotCountButCommandSaveDoes() throws {
        let view = page()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))
        let settle = InputSettle(window: 2, now: { 10 })
        func key(_ character: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: 10, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 0))
        }
        settle.observe(try key("r"))
        XCTAssertEqual(settle.remainingWait(for: view), 0)
        settle.observe(try key("s"))
        XCTAssertEqual(settle.remainingWait(for: view), 2)
    }

    private func page() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
