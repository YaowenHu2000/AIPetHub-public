// 界面所在的 WebView 只显示界面本身：别的跳转一律拦下；网页进程崩溃时重新载入。
import Cocoa
import WebKit

extension AppDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if webView === browser {
            if let sim = browserSimulating, sim == url { browserSimulating = nil; return .allow }   // 我们自己的错误页
            // 本地网页里链到的 Word、PPT 之类（以及后退、刷新回到它们）：转成预览再显示
            if url.isFileURL, navigationAction.targetFrame?.isMainFrame != false, isPreviewDocument(url.path), documentPreviewOrigin(url) == nil {
                DispatchQueue.main.async { self.openDocumentPreview(url.path) }
                return .cancel
            }
            // 内置浏览器：网页随便浏览；mailto: 之类交给系统
            if ["http", "https", "file", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
        let root = indexURL.deletingLastPathComponent().standardizedFileURL.path
        if url.isFileURL && url.standardizedFileURL.path.hasPrefix(root) { return .allow }
        if url.scheme == "about" { return .allow }
        // 其他导航（拖进来的文件、意外的跳转）一律拦下；用户点的网址交给浏览器
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    /// 网页进程崩溃（比如内存不够）时重新载入，不留一个空白窗口。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === browser { webView.reload(); return }
        browser?.isHidden = true
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }
}
