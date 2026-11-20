// 内置浏览器：预览本地网页、开发服务器、文档预览（DocPreview.swift 负责转换）。
import Cocoa
import WebKit
import PDFKit

// 状态跟随 App 实例，不把全 App 共用的浏览器改成多个浏览器。
private var browserNavigationKey: UInt8 = 0
private var browserGenerationKey: UInt8 = 0
final class BrowserNavigationState {
    var generation = 0
    var navigation: WKNavigation? {
        didSet {
            if let navigation = navigation { objc_setAssociatedObject(navigation, &browserGenerationKey, generation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        }
    }
    // 先让 WebKit 把原始提交送出去。204、下载和用户取消都还需要原表单。
    var pendingForm: WKWebView?
    var finished = false
    // 这一代里地址变过（含同文档换片段、页面脚本 replaceState）：browser_open 的同文档导航据此判断已经发生
    var moved = false
    // 最近一次主框架导航策略是页面脚本自己发起的（location.href、location.replace、meta refresh）：
    // 需要登录的页面常这样整页转到登录页，算同一次打开的延续，browser_open 等跳转后的页面载入完再返回实际落点。
    // 点链接、提交表单、后退前进、刷新和 App 自己发起的导航都不算，照旧开新的一代（等着的 browser_open 报被取代）
    var pageInitiated = false
    var documentTask: DocumentPreviewTask?
    func begin() {
        pendingForm?.navigationDelegate = nil
        pendingForm?.uiDelegate = nil
        pendingForm?.stopLoading()
        pendingForm = nil
        generation += 1
        navigation = nil
        finished = false
        moved = false
    }
}

extension AppDelegate {
    var browserNavigation: BrowserNavigationState {
        if let state = objc_getAssociatedObject(self, &browserNavigationKey) as? BrowserNavigationState { return state }
        let state = BrowserNavigationState()
        objc_setAssociatedObject(self, &browserNavigationKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === browser else { return }
        let pageInitiated = browserNavigation.pageInitiated
        browserNavigation.pageInitiated = false
        if navigation !== browserNavigation.navigation {
            // 已被取代的导航也可能迟到 didStart；不能反过来把新的请求作废。
            if let navigation = navigation, objc_getAssociatedObject(navigation, &browserGenerationKey) != nil { return }
            // 生成文档预览中、新窗口表单待接管时仍按原来的取代处理，不让旧页面的跳转留下它们
            if pageInitiated, docPreviewPending == nil, browserNavigation.pendingForm == nil {
                browserNavigation.navigation = navigation
                browserNavigation.finished = false
                return
            }
            cancelDocumentPreview()
            browserNavigation.begin()
            browserNavigation.navigation = navigation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === browser, navigation === browserNavigation.navigation else { return }
        browserNavigation.finished = true
    }

    // MARK: - 内置浏览器

    func browserView() -> WKWebView {
        if let b = browser { return b }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = (TestHooks.selfTest || UITest.active) ? .nonPersistent() : .default()   // 测试不改平时浏览器的登录状态
        cfg.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"   // 让网站当成 Safari，不给降级页面
        // 记下控制台输出，智能体用 browser_console 读（BrowserTools.swift）
        cfg.userContentController.addUserScript(WKUserScript(source: browserConsoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addUserScript(WKUserScript(source: browserFormTarget, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let b = BrowserWebView(frame: .zero, configuration: cfg)
        installBrowser(b)
        return b
    }

    func installBrowser(_ b: WKWebView) {
        let old = browser
        b.frame = old?.frame ?? .zero
        b.navigationDelegate = self
        b.uiDelegate = self
        b.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { b.isInspectable = true }   // 右键「检查元素」
        b.isHidden = old?.isHidden ?? true
        container.addSubview(b)
        old?.navigationDelegate = nil
        old?.uiDelegate = nil
        old?.removeFromSuperview()
        let push: (WKWebView) -> Void = { [weak self] _ in self?.sendBrowserState() }
        browserKVO = [b.observe(\.url) { [weak self] w, _ in self?.browserNavigation.moved = true; push(w) }, b.observe(\.title) { w, _ in push(w) },
                      b.observe(\.canGoBack) { w, _ in push(w) }, b.observe(\.canGoForward) { w, _ in push(w) },
                      b.observe(\.isLoading) { w, _ in push(w) }]
        browser = b
    }

    /// 告诉网页浏览器现在的样子。显示的是我们自己的页面（生成预览中、打不开、文档预览）时，地址栏显示原来的文件或网址；
    /// file 是正在看的本地文件（预览面板的「在访达中显示」「用默认应用打开」用它）。
    func sendBrowserState() {
        guard let b = browser else { return }
        var url = b.url?.absoluteString ?? ""
        var title = b.title ?? ""
        var loading = b.isLoading || browserNavigation.pendingForm != nil
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
        if webView === browserNavigation.pendingForm {
            let source = browser
            browserNavigation.pendingForm = nil
            installBrowser(webView)
            browserNavigation.navigation = navigation
            if let source { preserveFormSource(source, result: webView) }
        }
        guard webView === browser else { return }
        browserSimulating = nil
        if navigation !== browserErrorNav { browserFailedURL = ""; browserErrorNav = nil }
        notePDF(webView)
        sendBrowserState()
    }

    /// WebKit 显示 PDF 是按原始大小、居中放的：面板宽了两边一大片空白、字很小，而且它的缩放从外面控制不住
    /// （面板一改宽度，同样的缩放值出来的大小就不一样）。所以本地 PDF 换成系统的 PDFKit 来显示，盖在浏览器上面：
    /// 页面始终占满面板宽度，面板拉宽拉窄跟着变，文字照样能选中复制。
    /// 下面的浏览器照常载入这个 PDF，地址栏、前进后退、刷新、智能体的浏览器工具都不受影响。
    func notePDF(_ b: WKWebView) {
        var doc: PDFDocument?
        if browserErrorNav == nil, let u = b.url, u.isFileURL, u.pathExtension.lowercased() == "pdf" { doc = PDFDocument(url: u) }
        guard let doc = doc else { browserPDF?.removeFromSuperview(); browserPDF = nil; return }
        let pv = browserPDF ?? {
            let v = PDFView(frame: b.frame)
            v.displayMode = .singlePageContinuous
            v.displaysPageBreaks = true
            v.backgroundColor = NSColor(red: 0.165, green: 0.157, blue: 0.22, alpha: 1)   // 和 Word 文档预览的底色一样
            container.addSubview(v, positioned: .above, relativeTo: b)
            browserPDF = v
            return v
        }()
        pv.document = doc
        pv.autoScales = true   // 适应宽度
        syncPDF()
    }

    /// PDF 那一层跟着浏览器的位置和显示 / 隐藏走。
    func syncPDF() {
        guard let b = browser, let pv = browserPDF else { return }
        pv.frame = b.frame
        pv.isHidden = b.isHidden
    }

    /// 按网页给的位置（CSS 像素，预览面板里的占位区域）摆放内置浏览器；visible 为 false 就藏起来。
    func placeBrowser(_ body: [String: Any]) {
        guard let b = browser else { return }
        let num = { (k: String) in (body[k] as? NSNumber)?.doubleValue ?? 0 }
        guard body["visible"] as? Bool == true, num("w") > 20, num("h") > 20 else { b.isHidden = true; syncPDF(); return }
        let z = Double(webView.pageZoom)
        b.frame = NSRect(x: num("x") * z, y: num("y") * z, width: num("w") * z, height: num("h") * z)
        b.isHidden = false
        syncPDF()
    }

    /// 本地网页最终载入的地址。写成 file:// 的照原样（查询串、片段都在）；写成路径时 resolvePath 找不到字面文件名才去掉「#片段」，
    /// 那就是锚点，要加回最终地址，否则页面停在开头（browser_open 等待同文档导航也按这个地址比）
    func browserFileURL(_ raw: String, path: String, base: String) -> URL {
        if let url = URL(string: raw), url.isFileURL { return url }
        let fileURL = URL(fileURLWithPath: path)
        guard let hash = raw.firstIndex(of: "#"), resolvePath(String(raw[..<hash]), base: base) == path else { return fileURL }
        return URL(string: fileURL.absoluteString + raw[hash...]) ?? fileURL
    }

    func openInBrowser(_ body: [String: Any]) {
        let b = browserView()
        let failedPage = browserFailedURL.isEmpty ? nil : b.url
        browserFailedURL = ""
        cancelDocumentPreview()
        browserNavigation.begin()
        // 「打不开」错误页是冒充原网址载入的：只换 #片段 时 WebKit 只在错误页里跳片段、不会真的请求，
        // 页面仍是错误页却已没有错误状态。先把地址换成目标再刷新，才是真的重试（成功替换错误页，失败照旧报打不开）
        let load = { [weak self] (url: URL, start: () -> WKNavigation?) in
            guard let self else { return }
            let strip = { (u: URL?) in u.flatMap { self.normalizedURL($0) }.map { String($0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]) } }
            guard let shown = failedPage, url.fragment != nil, strip(shown) == strip(url) else { self.browserNavigation.navigation = start(); return }
            let generation = self.browserNavigation.generation
            b.callAsyncJavaScript("history.replaceState(null, '', u)", arguments: ["u": url.absoluteString], in: nil, in: .defaultClient) { [weak self] _ in
                guard let self, self.browser === b, self.browserNavigation.generation == generation else { return }
                self.browserNavigation.navigation = b.reload()
            }
        }
        if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            load(url) { b.load(URLRequest(url: url)) }
        } else if let raw = body["path"] as? String {
            // 本地网页：允许读取所在工作空间（引用 ../css 之类也能加载），不在工作空间里就只允许它所在的文件夹
            let base = body["base"] as? String ?? ""
            let path = resolvePath(raw, base: base)
            if isPreviewDocument(path) { openDocumentPreview(path); placeBrowser(body); return }
            let fileURL = URL(fileURLWithPath: path)
            let url = browserFileURL(raw, path: path, base: base)
            let ws = validWorkspace(base).map { trimmedPath($0) }
            let root = ws.flatMap { path.hasPrefix($0 + "/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil } ?? fileURL.deletingLastPathComponent()
            load(url) { b.loadFileURL(url, allowingReadAccessTo: root) }
        }
        placeBrowser(body)
    }

    func browserCommand(_ cmd: String) {
        guard let b = browser else { return }
        let failed = URL(string: browserFailedURL)
        let pending = docPreviewPending
        switch cmd {
        case "close":
            cancelDocumentPreview()
            browserNavigation.begin()
            browserKVO.removeAll()
            b.navigationDelegate = nil; b.uiDelegate = nil
            b.stopLoading(); b.removeFromSuperview(); browser = nil
            browserPDF?.removeFromSuperview(); browserPDF = nil
            browserFailedURL = ""; browserErrorNav = nil; browserSimulating = nil
            sendToJS("onBrowserState", ["url":"", "file":"", "title":"", "loading":false, "error":false,
                                        "canGoBack":false, "canGoForward":false])
        case "back", "forward":
            cancelDocumentPreview()
            browserNavigation.begin()
            let back = cmd == "back"
            if !traverseFormHistory(b, item: back ? b.backForwardList.backItem : b.backForwardList.forwardItem) {
                browserNavigation.navigation = back ? b.goBack() : b.goForward()
            }
        case "reload":
            cancelDocumentPreview(); browserNavigation.begin()
            if let origin = documentPreviewOrigin(b.url) ?? pending {
                openDocumentPreview(origin)   // 原文件改过就重新生成
            } else if let u = failed, u.isFileURL, isPreviewDocument(u.path) {
                openDocumentPreview(u.path)
            } else if let u = failed, b.url == u {
                browserNavigation.navigation = b.reload()   // 错误页占着这个网址：真的重新请求，成功就替换掉错误页
            } else if let u = failed {
                browserFailedURL = ""
                if u.isFileURL { browserNavigation.navigation = b.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) } else { browserNavigation.navigation = b.load(URLRequest(url: u)) }
            } else { browserNavigation.navigation = b.reload() }
        case "stop":
            let formPending = browserNavigation.pendingForm != nil
            browserNavigation.begin()
            if formPending { sendBrowserState() }
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

    /// 回答改了文件、看着的网页本身没改：只在页面实际加载过其中某个本地文件（样式、脚本、图片、字体、@import 进来的样式）时刷新。
    /// 按所在文件夹判断的话，改同目录的 README 也会重载、清空用户填了一半的表单，引用上层目录的样式改了却不刷新。
    /// WebKit 不给 file:// 页面读外部样式表的规则，资源计时也不记 file:// 的加载，所以页面只交出 DOM 引用和内联样式，
    /// 样式里的 @import、url() 由这里读文件展开；在 App 自己的脚本世界里取，不受页面脚本改写影响。
    /// <picture> 和 srcset 选图时 img.src 只是备用图，显示的是 currentSrc；两者连同 srcset 里列出的候选都算，
    /// 窗口宽度或深浅色变了换成别的候选时也不会拿到改动前留在缓存里的旧图。
    func reloadBrowserIfUses(_ paths: [String], done: ((Bool) -> Void)? = nil) {
        guard let b = browser, b.url?.isFileURL == true, browserFailedURL.isEmpty, docPreviewPending == nil, documentPreviewOrigin(b.url) == nil else { done?(false); return }
        let js = """
        const urls = [location.href];
        document.querySelectorAll('[src], link[href]').forEach(n => { if (n.src) urls.push(n.src); if (n.href) urls.push(n.href); });
        document.querySelectorAll('img, source[srcset]').forEach(n => {
          if (n.currentSrc) urls.push(n.currentSrc);
          for (const c of (n.getAttribute('srcset') || '').split(',')) { const u = c.trim().split(/\\s+/)[0]; if (u) try { urls.push(new URL(u, document.baseURI).href); } catch (e) {} }
        });
        const styles = [...document.querySelectorAll('style')].map(n => n.textContent).concat([...document.querySelectorAll('[style]')].map(n => n.getAttribute('style')));
        return {urls, styles};
        """
        let target = b.url
        b.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            let norm = { (p: String) in (p as NSString).resolvingSymlinksInPath }
            let found = (try? result.get()) as? [String: Any] ?? [:]
            var used = Set((found["urls"] as? [String] ?? []).compactMap { URL(string: $0) }.filter { $0.isFileURL }.map { norm($0.path) })
            // 样式引用的文件：内联样式相对页面，外部样式相对它自己；层数和文件数设上限，循环 @import 也停得下来
            var queue: [(text: String, base: URL)] = (found["styles"] as? [String] ?? []).compactMap { text in target.map { (text, $0) } }
            var read = Set<String>()
            let pattern = try! NSRegularExpression(pattern: #"url\(\s*['"]?([^'")]+?)['"]?\s*\)|@import\s+['"]([^'"]+)['"]"#)
            func cssFiles() -> [String] { used.filter { $0.lowercased().hasSuffix(".css") && !read.contains($0) } }
            while read.count < 64 {
                if queue.isEmpty, let css = cssFiles().first {
                    read.insert(css)
                    let size = (try? FileManager.default.attributesOfItem(atPath: css)[.size] as? Int) ?? 0
                    if size <= 2_000_000, let text = try? String(contentsOfFile: css, encoding: .utf8) { queue.append((text, URL(fileURLWithPath: css))) }
                    continue
                }
                guard let (text, base) = queue.popLast() else { break }
                for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let r = [1, 2].lazy.compactMap({ Range(m.range(at: $0), in: text) }).first else { continue }
                    let ref = String(text[r]).trimmingCharacters(in: .whitespaces).components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
                    guard !ref.isEmpty, let u = URL(string: ref, relativeTo: base) ?? ref.removingPercentEncoding.flatMap({ URL(fileURLWithPath: $0, relativeTo: base.deletingLastPathComponent()) }),
                          u.absoluteURL.isFileURL else { continue }
                    used.insert(norm(u.absoluteURL.standardizedFileURL.path))
                }
            }
            guard let self = self, self.browser === b, b.url == target, paths.contains(where: { used.contains(norm($0)) }) else { done?(false); return }
            self.browserCommand("reload")
            done?(true)
        }
    }

    /// 打开文档预览：后台转换（通常不到半秒），期间地址栏显示原文件、刷新按钮变成停止；
    /// 超过 0.6 秒面板上才显示「正在生成预览」（网页那边盖住，不往浏览器里载入页面，免得占一条历史）。
    func openDocumentPreview(_ path: String) {
        let b = browserView()
        browserFailedURL = ""
        cancelDocumentPreview()
        browserNavigation.begin()
        let task = DocumentPreviewTask()
        browserNavigation.documentTask = task
        let token = docPreviewToken
        docPreviewPending = path
        docPreviewSlow = false
        sendBrowserState()
        docPreviewQueue.async { [weak self] in
            guard !task.isCancelled else { return }
            let result = makeDocumentPreview(path, task: task)
            DispatchQueue.main.async {
                guard let self = self, token == self.docPreviewToken else { return }   // 期间又打开了别的
                self.docPreviewPending = nil
                self.docPreviewSlow = false
                if let file = result.file {
                    self.browserNavigation.navigation = b.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
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
        browserNavigation.documentTask?.cancel()
        browserNavigation.documentTask = nil
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
        browserNavigation.navigation = browserErrorNav
        browserNavigation.finished = true
        sendBrowserState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if webView === browserNavigation.pendingForm {
            finishPendingBrowserForm()
        } else {
            guard webView === browser, navigation === browserNavigation.navigation else { return }
        }
        if ns.code == NSURLErrorCancelled { return }   // 被新的跳转打断，不算失败
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }   // 「帧加载被中断」：交给系统打开了（下载、文档），不算失败
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? webView.url?.absoluteString ?? ""
        let local = failing.contains("localhost") || failing.contains("127.0.0.1")
        showBrowserError(failing: failing, title: "打不开这个网页", detail: ns.localizedDescription,
                         hint: local ? "如果是本地开发服务器，先确认它已经启动，再点刷新。" : "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // 内置浏览器显示不了的内容（下载文件等）交给系统浏览器
        if webView === browserNavigation.pendingForm,
           let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode, [204, 205].contains(status) {
            finishPendingBrowserForm()
            return .cancel
        }
        if (webView === browser || webView === browserNavigation.pendingForm), !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            if webView === browserNavigation.pendingForm {
                finishPendingBrowserForm()
            }
            NSWorkspace.shared.open(url)
            return .cancel
        }
        if webView === browserNavigation.pendingForm, navigationResponse.isForMainFrame {
            copyFormHistory(to: webView)
        }
        return .allow
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
