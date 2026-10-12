import Foundation

enum UserAgentProvider {
    /// Default browser identity for every service without an explicit override.
    /// Inboxes, popups, badge polling and floating drafts use the same default.
    /// The Version token identifies the browser to sites; it does not change
    /// the installed WebKit engine. Validate provider behavior before each bump.
    static let safariDefault = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"

    /// Mobile Safari (iOS) user agent used by a service's "Mobile view" toggle,
    /// so sites serve their phone/tablet web layout instead of the desktop one.
    /// Keep the iOS and `Version/N` tokens roughly current when bumping
    /// `safariDefault`.
    static let mobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}
