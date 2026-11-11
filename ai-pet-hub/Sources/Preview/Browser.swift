// 内置浏览器：预览本地网页、开发服务器、文档预览（DocPreview.swift 负责转换）。
import Cocoa
import WebKit

extension AppDelegate {
    // MARK: - 内置浏览器

    func browserView() -> WKWebView {
        if let b = browser { return b }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // 独立保存登录状态、localStorage，和 App 界面分开
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"   // 让网站当成 Safari，不给降级页面
        // 记下控制台输出，智能体用 browser_console 读（BrowserTools.swift）
        cfg.userContentController.addUserScript(WKUserScript(source: browserConsoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let b = BrowserWebView(frame: .zero, configuration: cfg)
        b.navigationDelegate = self
        b.uiDelegate = self
        b.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { b.isInspectable = true }   // 右键「检查元素」
        b.isHidden = true
        container.addSubview(b)
        let push: (WKWebView) -> Void = { [weak self] _ in self?.sendBrowserState() }
        browserKVO = [b.observe(\.url) { w, _ in push(w) }, b.observe(\.title) { w, _ in push(w) },
                      b.observe(\.canGoBack) { w, _ in push(w) }, b.observe(\.canGoForward) { w, _ in push(w) },
                      b.observe(\.isLoading) { w, _ in push(w) }]
        browser = b
        return b
    }

    /// 告诉网页浏览器现在的样子。显示的是我们自己的页面（生成预览中、打不开、文档预览）时，地址栏显示原来的文件或网址；
    /// file 是正在看的本地文件（预览面板的「在访达中显示」「用默认应用打开」用它）。
    func sendBrowserState() {
        guard let b = browser else { return }
        var url = b.url?.absoluteString ?? ""
        var title = b.title ?? ""
        var loading = b.isLoading
        var file = b.url?.isFileURL == true ? b.url!.path : ""
        var error = false
        let blank = url.isEmpty || url == "about:blank"
        if let p = docPreviewPending {
            url = URL(fileURLWithPath: p).absoluteString; title = "正在生成预览…"; loading = true; file = p
        } else if !browserFailedURL.isEmpty, blank || url == browserFailedURL {
            url = browserFailedURL; title = browserFailedTitle; error = true
            file = URL(string: browserFailedURL).flatMap { $0.isFileURL ? $0.path : nil } ?? ""
        } else if let origin = documentPreviewOrigin(b.url) {
            url = URL(fileURLWithPath: origin).absoluteString; title = (origin as NSString).lastPathComponent; file = origin
        }
        sendToJS("onBrowserState", [
            "url": url, "title": title, "file": file, "slow": docPreviewPending != nil && docPreviewSlow,
            "canGoBack": b.canGoBack, "canGoForward": b.canGoForward, "loading": loading, "error": error,
        ])
    }

    /// 浏览器里有一次导航真的载入了：不是我们的错误页就清掉错误状态。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === browser else { return }
        browserSimulating = nil
        if navigation !== browserErrorNav { browserFailedURL = ""; browserErrorNav = nil }
        sendBrowserState()
    }

    /// 按网页给的位置（CSS 像素，预览面板里的占位区域）摆放内置浏览器；visible 为 false 就藏起来。
    func placeBrowser(_ body: [String: Any]) {
        guard let b = browser else { return }
        let num = { (k: String) in (body[k] as? NSNumber)?.doubleValue ?? 0 }
        guard body["visible"] as? Bool == true, num("w") > 20, num("h") > 20 else { b.isHidden = true; return }
        let z = Double(webView.pageZoom)
        b.frame = NSRect(x: num("x") * z, y: num("y") * z, width: num("w") * z, height: num("h") * z)
        b.isHidden = false
    }

    func openInBrowser(_ body: [String: Any]) {
        let b = browserView()
        browserFailedURL = ""
        cancelDocumentPreview()
        if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            b.load(URLRequest(url: url))
        } else if let raw = body["path"] as? String {
            // 本地网页：允许读取所在工作空间（引用 ../css 之类也能加载），不在工作空间里就只允许它所在的文件夹
            let base = body["base"] as? String ?? ""
            let path = resolvePath(raw, base: base)
            if isPreviewDocument(path) { openDocumentPreview(path); placeBrowser(body); return }
            let url = URL(fileURLWithPath: path)
            let ws = validWorkspace(base).map { trimmedPath($0) }
            let root = ws.flatMap { path.hasPrefix($0 + "/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil } ?? url.deletingLastPathComponent()
            b.loadFileURL(url, allowingReadAccessTo: root)
        }
        placeBrowser(body)
    }

    func browserCommand(_ cmd: String) {
        guard let b = browser else { return }
        let failed = URL(string: browserFailedURL)
        switch cmd {
        case "back": cancelDocumentPreview(); b.goBack()
        case "forward": cancelDocumentPreview(); b.goForward()
        case "reload":
            if let origin = documentPreviewOrigin(b.url) ?? docPreviewPending {
                openDocumentPreview(origin)   // 原文件改过就重新生成
            } else if let u = failed, u.isFileURL, isPreviewDocument(u.path) {
                openDocumentPreview(u.path)
            } else if let u = failed, b.url == u {
                b.reload()   // 错误页占着这个网址：真的重新请求，成功就替换掉错误页
            } else if let u = failed {
                browserFailedURL = ""
                if u.isFileURL { b.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) } else { b.load(URLRequest(url: u)) }
            } else { b.reload() }
        case "stop":
            // 生成预览中：不再显示它，留在原来的页面
            if docPreviewPending != nil { cancelDocumentPreview(); sendBrowserState() } else { b.stopLoading() }
        case "external":
            // 文档预览打开原文件（用 Word、Keynote 之类）；网页用系统浏览器
            if let p = documentPreviewOrigin(b.url) ?? docPreviewPending {
                NSWorkspace.shared.open(URL(fileURLWithPath: p)); return
            }
            let target = failed ?? b.url
            if let u = target, ["http", "https", "file"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
        default: break
        }
    }

    /// 打开文档预览：后台转换（通常不到半秒），期间地址栏显示原文件、刷新按钮变成停止；
    /// 超过 0.6 秒面板上才显示「正在生成预览」（网页那边盖住，不往浏览器里载入页面，免得占一条历史）。
    func openDocumentPreview(_ path: String) {
        let b = browserView()
        browserFailedURL = ""
        docPreviewToken += 1
        let token = docPreviewToken
        docPreviewPending = path
        docPreviewSlow = false
        sendBrowserState()
        docPreviewQueue.async { [weak self] in
            let result = makeDocumentPreview(path)
            DispatchQueue.main.async {
                guard let self = self, token == self.docPreviewToken else { return }   // 期间又打开了别的
                self.docPreviewPending = nil
                self.docPreviewSlow = false
                if let file = result.file {
                    b.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
                } else {
                    self.showBrowserError(failing: URL(fileURLWithPath: path).absoluteString, title: "无法预览这个文件",
                                          detail: result.error, hint: "可以点右上角「用默认应用打开」。", tabTitle: "无法预览")
                }
                self.sendBrowserState()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, token == self.docPreviewToken, self.docPreviewPending != nil else { return }
            self.docPreviewSlow = true
            self.sendBrowserState()
        }
    }

    func cancelDocumentPreview() {
        docPreviewToken += 1
        docPreviewPending = nil
        docPreviewSlow = false
    }

    /// 浏览器里显示我们自己的错误页；地址栏仍显示原来的网址或文件，刷新会真的重试。
    /// 用 loadSimulatedRequest「冒充」那个网址：错误页占自己的一条历史（loadHTMLString 会顶掉上一页，后退就回不去了）。
    func showBrowserError(failing: String, title: String, detail: String, hint: String = "", tabTitle: String = "打不开") {
        guard let b = browser else { return }
        let esc = { (t: String) in t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let shown = URL(string: failing).flatMap { $0.isFileURL ? $0.path : nil } ?? failing
        let hintHTML = hint.isEmpty ? "" : "<div style='color:#8e7cf0;margin-top:14px'>\(esc(hint))</div>"
        let page = "<html><head><meta charset=\"utf-8\"><title>\(esc(tabTitle))</title></head><body style=\"margin:0;background:#161427;color:#f1eefb;font:14px -apple-system,'PingFang SC';display:flex;align-items:center;justify-content:center;height:100vh\">"
            + "<div style=\"max-width:440px;padding:24px\"><div style=\"font-size:17px;font-weight:600;margin-bottom:8px\">\(esc(title))</div>"
            + "<div style=\"color:#aaa3c8;word-break:break-all;margin-bottom:12px\">\(esc(shown))</div><div style=\"color:#d6d1ee\">\(esc(detail))</div>\(hintHTML)</div></body></html>"
        let alreadyShowing = browserErrorNav != nil && b.url?.absoluteString == failing   // 刷新又失败：错误页还在，不再多占一条历史
        browserFailedURL = failing
        browserFailedTitle = tabTitle
        if !alreadyShowing {
            if #available(macOS 12.0, *), let u = URL(string: failing), ["http", "https", "file"].contains(u.scheme?.lowercased() ?? "") {
                browserSimulating = u
                browserErrorNav = b.loadSimulatedRequest(URLRequest(url: u), responseHTML: page)
            } else {
                browserErrorNav = b.loadHTMLString(page, baseURL: nil)
            }
        }
        sendBrowserState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === browser else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }   // 被新的跳转打断，不算失败
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }   // 「帧加载被中断」：交给系统打开了（下载、文档），不算失败
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? webView.url?.absoluteString ?? ""
        let local = failing.contains("localhost") || failing.contains("127.0.0.1")
        showBrowserError(failing: failing, title: "打不开这个网页", detail: ns.localizedDescription,
                         hint: local ? "如果是本地开发服务器，先确认它已经启动，再点刷新。" : "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // 内置浏览器显示不了的内容（下载文件等）交给系统浏览器
        if webView === browser, !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    /// 网页里的 target="_blank" 链接：在同一个内置浏览器里打开。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if webView === browser, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
