import WebKit

extension WKWebView {
    /// Xcode 16's generated async bridge force-unwraps a successful nil result.
    /// Use the callback interface so JavaScript `undefined` remains a valid result.
    @MainActor
    @discardableResult
    func evaluateJavaScriptValue(_ script: String) async throws -> Any? {
        let result = JavaScriptEvaluationResult()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            evaluateJavaScript(script) { value, error in
                // WebKit delivers JavaScript completion on the main thread.
                MainActor.assumeIsolated {
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        result.value = value
                        continuation.resume()
                    }
                }
            }
        }
        return result.value
    }
}

@MainActor
private final class JavaScriptEvaluationResult {
    var value: Any?
}
