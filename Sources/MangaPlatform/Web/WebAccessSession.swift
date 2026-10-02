import Foundation
import WebKit
import MangaCore
@MainActor public final class WebAccessSession: NSObject, WKNavigationDelegate {
    public let source: Source
    public let webView: WKWebView
    private let contexts: AccessContextStore
    private let lifecycle = RenderLifecycle()
    private var navigation: WKNavigation?
    private var token: UUID?
    private var timeout: Task<Void, Never>?
    public init(source: Source, contexts: AccessContextStore) {
        self.source = source; self.contexts = contexts
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(); webView.navigationDelegate = self
    }
    public func open(_ url: URL) throws {
        guard WebAccessPolicy.permits(url, source: source) else { throw MangaError.invalidURL }
        webView.load(URLRequest(url: url))
    }
    public func render(url: URL, interactive: Bool) async throws -> RenderedPage {
        guard WebAccessPolicy.permits(url, source: source) else { throw MangaError.invalidURL }
        lifecycle.cancel(); timeout?.cancel(); webView.stopLoading()
        let token = UUID(); self.token = token
        navigation = webView.load(URLRequest(url: url))
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(interactive ? 60 : 12)) } catch { return }
            self?.lifecycle.finish(token: token, result: .failure(MangaError.timedOut))
        }
        do {
            let page = try await lifecycle.wait(token: token)
            timeout?.cancel(); return page
        } catch { timeout?.cancel(); webView.stopLoading(); throw error }
    }
    public func snapshot() async throws -> RenderedPage {
        guard let url = webView.url, WebAccessPolicy.permits(url, source: source) else { throw MangaError.invalidURL }
        let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let host = url.host?.lowercased() ?? ""
            return (host == domain || host.hasSuffix("." + domain)) && (!cookie.isSecure || url.scheme == "https") && url.path.hasPrefix(cookie.path) && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        let headers = HTTPCookie.requestHeaderFields(with: matching)
        let context = try await contexts.register(sourceID: source.id, originURL: url, headers: headers)
        return RenderedPage(url: url, html: html, accessContextID: context)
    }
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, WebOrigin(url) != nil else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false && !WebAccessPolicy.permits(url, source: source) { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let token, navigation === self.navigation else { return }
        Task { @MainActor in
            do { let page = try await snapshot(); lifecycle.finish(token: token, result: .success(page)) }
            catch { lifecycle.finish(token: token, result: .failure(error)) }
        }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(navigation, error) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(navigation, error) }
    private func fail(_ navigation: WKNavigation?, _ error: Error) {
        guard let token, navigation === self.navigation else { return }
        let mapped: Error = (error as? URLError).map { $0.code == .cancelled ? (CancellationError() as Error) : (NetworkErrorMapper.map($0) as Error) } ?? error
        lifecycle.finish(token: token, result: .failure(mapped))
    }
}
