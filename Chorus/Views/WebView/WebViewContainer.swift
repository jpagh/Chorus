import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WebViewHostView {
        let host = WebViewHostView()
        host.setWebView(webView)
        return host
    }

    func updateNSView(_ nsView: WebViewHostView, context: Context) {
        nsView.setWebView(webView)
    }
}

/// Holds the current service's web view, clipped to the content card's
/// rounded corners.
final class WebViewHostView: NSView {
    private weak var currentWebView: WKWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = ChorusCard.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setWebView(_ webView: WKWebView) {
        guard webView !== currentWebView else { return }

        currentWebView?.removeFromSuperview()
        currentWebView = webView

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}
