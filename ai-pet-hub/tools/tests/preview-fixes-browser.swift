// 夹具和三段的分工见 preview-fixes.swift。
import Cocoa
import WebKit
import PDFKit
import SQLite3

func runPreviewBrowserTests(_ f: PreviewFixture) {
    let (d, fm, dir) = (f.d, f.fm, f.dir), write = f.write, reply = f.reply
    write("mixed.jsonl", #"{"type":"user","message":{"role":"user","content":"aBcDeF"}}"#)
    let found = reply("onConversationsSearched") { d.searchConversations(agent: "claude", query: "abcdef", files: [("mixed", dir + "/mixed.jsonl")]) }
    check(found["ids"] as? [String] == ["mixed"], "N04 任意英文大小写")
    var db: OpaquePointer?
    check(sqlite3_open((dir + "/wal.db"), &db) == SQLITE_OK, "WAL 夹具打开")
    sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE steps(idx INTEGER, step_type INTEGER, step_payload BLOB); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    sqlite3_exec(db, "INSERT INTO steps VALUES(0,14,X'9a010f120d57614c4f6e6c794e6565646c65'); INSERT INTO steps VALUES(1,15,X'a201080a06616e73776572');", nil, nil, nil)
    let wal = reply("onConversationsSearched") { d.searchConversations(agent: "gemini", query: "walonlyneedle", files: [("wal", dir + "/wal.db")]) }
    check(wal["ids"] as? [String] == ["wal"], "N06 搜到尚未 checkpoint 的 WAL")
    sqlite3_exec(db, "DELETE FROM steps;", nil, nil, nil)
    let deleted = reply("onConversationsSearched") { d.searchConversations(agent: "gemini", query: "walonlyneedle", files: [("wal", dir + "/wal.db")]) }
    check(deleted["ids"] as? [String] == [], "N06 已删除内容不命中")
    sqlite3_close(db)

    write("large.txt", String(repeating: "a", count: 400_001))
    try! fm.createSymbolicLink(atPath: dir + "/alias.txt", withDestinationPath: "large.txt")
    let file = reply("onFileRead") { d.readFileForPreview(path: dir + "/alias.txt", base: "", reqId: 1) }
    check(file["size"] as? Int == 400_001 && file["truncated"] as? Bool == true && file["path"] as? String == dir + "/alias.txt", "N07 链接目标大小和截断，保留原路径")
    write("large.png", String(repeating: "a", count: 8_000_001))
    try! fm.createSymbolicLink(atPath: dir + "/alias.png", withDestinationPath: "large.png")
    let largeImage = reply("onFileRead") { d.readFileForPreview(path: dir + "/alias.png", base: "", reqId: 2) }
    check(largeImage["error"] as? String == "图片太大，无法预览", "N07 链接图片大小限制")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    try! png.write(to: URL(fileURLWithPath: dir + "/small.png"))
    try! fm.createSymbolicLink(atPath: dir + "/thumb.png", withDestinationPath: "small.png")
    check(chatThumbnail(path: dir + "/thumb.png") != nil, "N07 符号链接缩略图")

    d.fileListCache["expired"] = (Date(timeIntervalSinceNow: -30), ["old"])
    for i in 0..<12 {
        let ws = dir + "/ws\(i)"; try! fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
        _ = reply("onFilesListed") { d.listFiles(workspace: ws, query: "", reqId: i) }
    }
    check(d.fileListCache.count <= 8 && d.fileListCache["expired"] == nil, "C-N09 缓存有上限且清除过期项")

    d.container = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
    let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
    d.webView = HubWebView(frame: d.container.frame, configuration: cfg)
    write("A.html", "<title>A</title>A"); write("B.html", "<title>B</title>B")
    d.hooks.jsSink = { name, payload in
        // 复现真实前端：有 URL 才导航，空 URL 只切出面板。
        if name == "onBrowserToolOpen", let url = payload["url"] as? String, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.openInBrowser(["path": url]) }
    }
    var first: [String: Any]?, second: [String: Any]?
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { first = $0 }
    d.browserTool("browser_open", ["url": dir + "/B.html"]) { second = $0 }
    check(waitUntil(runLoop: true) { first != nil && second != nil }, "N01 两个请求均返回")
    check(first?["error"] as? Bool == true && (first?["text"] as? String ?? "").contains("取代"), "N01 A 明确报告被替代")
    check(second?["error"] as? Bool != true && (second?["text"] as? String ?? "").contains("B.html"), "N01 B 成功绑定自己的页面")
    let route = URL(fileURLWithPath:dir + "/A.html").absoluteString + "?tab=logs#/settings"
    var routed: [String:Any]?
    d.browserTool("browser_open",["url":route]) { routed = $0 }
    check(waitUntil(runLoop: true) { routed != nil } && d.browser?.url?.absoluteString.hasSuffix("?tab=logs#/settings") == true,
          "本地网页导航保留查询串和路由，实际=\(d.browser?.url?.absoluteString ?? "")")
    let pdf = PDFDocument()
    for (i, color) in [NSColor.red, NSColor.blue].enumerated() {
        let page = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            color.setFill(); rect.fill(); return true
        }
        pdf.insert(PDFPage(image: page)!, at: i)
    }
    let pdfURL = URL(fileURLWithPath: dir + "/colors.pdf")
    check(pdf.write(to: pdfURL), "PDF 夹具已写入")
    d.openInBrowser(["path":pdfURL.path, "visible":true, "w":300, "h":300])
    check(waitUntil(runLoop: true) { d.browserNavigation.finished && d.browserPDF?.document?.pageCount == 2 }, "PDF 两页载入")
    if let view = d.browserPDF, let page = view.document?.page(at: 1) {
        view.displayMode = .singlePage; view.go(to: page); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    var shot: [String: Any]?
    d.browserTool("browser_screenshot", [:]) { shot = $0 }
    _ = waitUntil(runLoop: true) { shot != nil }
    let rep = (shot?["image"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSBitmapImageRep(data: $0) }
    let color = rep.flatMap { $0.colorAt(x:$0.pixelsWide/2, y:$0.pixelsHigh/2)?.usingColorSpace(.deviceRGB) }
    // GitHub 的 macOS 机器没有真实显示环境，PDFView 画不出页面内容，截图整张是白的（本机正常）。
    // 只在那种环境里、且截到的确实是空白时跳过颜色判断；截成红色（停在第一页）仍判失败，本机始终严格判。
    let blank = color.map { $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9 } ?? false
    if blank && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
        print("  CI 无界面环境画不出 PDF 页面，跳过 B4-13 截图颜色判断")
    } else {
        check((color?.blueComponent ?? 0) > 0.8 && (color?.redComponent ?? 1) < 0.2,
              "B4-13 PDF 第二页截图中心应为蓝色，实际 \(String(describing: color))")
    }
    let readerURL = URL(fileURLWithPath:dir + "/reader.pdf")
    let label = NSTextField(labelWithString:"SELENIUM READER 2247")
    label.frame = NSRect(x:0,y:0,width:300,height:40)
    try! label.dataWithPDF(inside:label.bounds).write(to:readerURL)
    d.openInBrowser(["path":readerURL.path,"visible":true,"w":300,"h":300])
    check(waitUntil(runLoop: true) { d.browserNavigation.finished && d.browserPDF?.document?.string?.contains("SELENIUM READER") == true }, "PDF 夹具文字层已显示")
    var reader: [String: Any]?
    d.browserTool("browser_text",[:]) { reader = $0 }
    check(waitUntil(runLoop: true) { reader != nil } && str(reader,"text").contains("SELENIUM READER 2247"), "PDF 浏览工具读出文字层，实际 \(str(reader,"text"))")
    d.placeBrowser(["visible":false])
    reader = nil
    d.browserTool("browser_text",[:]) { reader = $0 }
    check(waitUntil(runLoop: true) { reader != nil } && str(reader,"text").contains("SELENIUM READER 2247"), "隐藏 PDF 标签仍读到正文，实际 \(str(reader,"text"))")
    d.browserCommand("close")
    check(d.browser == nil && d.browserPDF == nil, "B4-19 关闭后释放网页和 PDF 视图，实际仍持有网页 \(d.browser != nil)")
    // hunt6 uncovered 第 2 条：关掉浏览器后截图要立即失败，不能再切出一个空的「网页预览」标签、等 3 秒才报错
    let sink = d.hooks.jsSink
    var reopened = 0
    d.hooks.jsSink = { name, payload in if name == "onBrowserToolOpen" { reopened += 1 }; sink?(name, payload) }
    var closedShot: [String: Any]?
    d.browserTool("browser_screenshot", [:]) { closedShot = $0 }
    check(closedShot?["error"] as? Bool == true && str(closedShot, "text").contains("browser_open"), "关闭后截图当场失败，实际 \(String(describing: closedShot))")
    _ = waitUntil(runLoop: true) { closedShot != nil }
    check(reopened == 0, "关闭后截图不切出空的浏览器标签，实际切了 \(reopened) 次")
    check(d.browser == nil, "关闭后截图不新建浏览器")
    d.hooks.jsSink = sink
    var userReplaced: [String: Any]?
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { userReplaced = $0 }
    d.openInBrowser(["path": dir + "/B.html"])
    check(waitUntil(runLoop: true) { userReplaced != nil } && userReplaced?["error"] as? Bool == true, "N01 用户导航取代工具请求")
    var sameFirst: [String: Any]?, sameLast: [String: Any]?
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { sameFirst = $0 }
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { sameLast = $0 }
    check(waitUntil(runLoop: true) { sameFirst != nil && sameLast != nil } && sameFirst?["error"] as? Bool == true && sameLast?["error"] as? Bool != true, "N01 同 URL 的不同导航也区分代次")
    d.hooks.jsSink = nil

    // hunt7 uncovered 第 1 条：回答改了文件、网页本身没改时，按页面实际加载的本地资源决定刷新。
    // 同目录的 README 改了不刷新（用户填了一半的表单不被清空）；上层目录、经 @import 引入的样式改了要刷新。
    try! fm.createDirectory(atPath: dir + "/site/pages", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: dir + "/site/assets", withIntermediateDirectories: true)
    write("site/assets/styles.css", "@import url('deep.css'); @media screen { body { background: url(\"img/bg.png\") } }")
    write("site/assets/deep.css", "input { color: blue }")
    write("site/pages/index.html", #"<link rel="stylesheet" href="../assets/styles.css"><input id="q">"#)
    write("site/pages/README.md", "说明")
    d.openInBrowser(["path": dir + "/site/pages/index.html", "base": dir + "/site"])
    check(waitUntil(runLoop: true) { d.browserNavigation.finished }, "资源刷新夹具载入")
    func typed() -> String? {
        var value: String?, done = false
        d.browser?.evaluateJavaScript("document.getElementById('q').value") { r, _ in value = r as? String; done = true }
        _ = waitUntil(runLoop: true) { done }
        return value
    }
    func reloadIfUses(_ paths: [String]) -> Bool? {
        var reloaded: Bool?
        d.reloadBrowserIfUses(paths) { reloaded = $0 }
        _ = waitUntil(runLoop: true) { reloaded != nil }
        return reloaded
    }
    d.browser?.evaluateJavaScript("document.getElementById('q').value = '填了一半'", completionHandler: nil)
    check(waitUntil(runLoop: true) { typed() == "填了一半" }, "资源刷新夹具填好表单")
    let readme = reloadIfUses([dir + "/site/pages/README.md"])
    check(readme == false && typed() == "填了一半", "同目录 README 改了不刷新网页，实际刷新=\(String(describing: readme)) 表单=\(String(describing: typed()))")
    let deep = reloadIfUses([dir + "/site/pages/README.md", dir + "/site/assets/deep.css"])
    check(deep == true && waitUntil(runLoop: true) { d.browserNavigation.finished && typed() == "" }, "上层目录经 @import 引入的样式改了就刷新，实际刷新=\(String(describing: deep))")
    let bg = reloadIfUses([dir + "/site/assets/img/bg.png"])
    check(bg == true, "样式表里 url() 引用的图片改了也刷新，实际刷新=\(String(describing: bg))")
    // hunt8 recheck 第 1 条：<picture>/srcset 选图时 img.src 指向备用图，页面实际显示的是 currentSrc 那张；
    // 显示的那张、备用图、没选中的候选改了都刷新，同目录 README 改了仍不刷新
    let svg = { (w: Int) in #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(w)" height="10"/>"# }
    for name in ["cover.svg", "fallback.svg", "huge.svg", "lo.svg", "hi.svg", "plain.svg"] { write("site/pages/" + name, svg(40)) }
    write("site/pages/pic.html", """
    <picture><source media="(min-width: 99999px)" srcset="huge.svg"><source srcset="cover.svg" type="image/svg+xml"><img id="p" src="fallback.svg"></picture>
    <img id="s" src="plain.svg" srcset="lo.svg 1x, hi.svg 2x"><input id="q">
    """)
    d.openInBrowser(["path": dir + "/site/pages/pic.html", "base": dir + "/site"])
    check(waitUntil(runLoop: true) { d.browserNavigation.finished && d.browser?.isLoading == false }, "响应式图片夹具载入")
    var shown = ""
    _ = waitUntil(runLoop: true) {
        d.browser?.evaluateJavaScript("document.getElementById('p').currentSrc.split('/').pop()") { r, _ in shown = r as? String ?? "" }
        return shown == "cover.svg"
    }
    check(shown == "cover.svg", "夹具里 WebKit 实际显示 picture 选中的 cover.svg，实际=\(shown)")
    for (file, expected) in [("cover.svg", true), ("fallback.svg", true), ("huge.svg", true), ("lo.svg", true), ("hi.svg", true), ("plain.svg", true), ("README.md", false)] {
        _ = waitUntil(runLoop: true) { d.browserNavigation.finished && d.browser?.isLoading == false }
        let got = reloadIfUses([dir + "/site/pages/" + file])
        check(got == expected, "响应式图片页改了 \(file)：应\(expected ? "" : "不")刷新，实际刷新=\(String(describing: got))")
    }

    // 开发服务器的地址（localhost:端口/index.html）要按网址打开，不能因为 .html 后缀当成工作目录下的文件
    write("index.html", #"<title>dev</title><form method="post" action="/submitted"><input name="answer" value="alpha"></form>"#)
    write("foreign.html", #"<iframe name="remoteResult" srcdoc="ready"></iframe>"#)
    let freePort: () -> Int = {   // 让系统挑一个空闲端口再交给测试服务器
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0 } }
        return Int(UInt16(bigEndian: a.sin_port))
    }
    let port = freePort()
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.currentDirectoryURL = URL(fileURLWithPath: dir)
    server.arguments = ["-c", """
    from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
    from pathlib import Path
    import sys
    import json, time
    from email import policy
    from email.parser import BytesParser
    from urllib.parse import parse_qs, urlsplit
    receipts = {}
    class Handler(SimpleHTTPRequestHandler):
        def matrix(self):
            url = urlsplit(self.path)
            key = url.path.split('/')[-1]
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            arrival = time.time()
            content = self.headers.get('Content-Type', '')
            fields = {}
            file = ''
            if self.command == 'GET':
                fmt, fields = 'GET', parse_qs(url.query)
            elif content.startswith('multipart/form-data'):
                fmt = 'file'
                msg = BytesParser(policy=policy.default).parsebytes(('Content-Type: '+content+'\\r\\n\\r\\n').encode()+body)
                for part in msg.iter_parts():
                    name = part.get_param('name', header='Content-Disposition')
                    if part.get_filename():
                        file = part.get_filename()+':'+part.get_payload(decode=True).hex()
                    else:
                        fields.setdefault(name, []).append(part.get_content())
            elif content.startswith('text/plain'):
                fmt = 'plain'
                for line in body.decode().splitlines():
                    name, value = line.split('=', 1)
                    fields.setdefault(name, []).append(value)
            else:
                fmt, fields = content, parse_qs(body.decode())
                if fmt == 'application/x-www-form-urlencoded': fmt = 'url'
            receipts[key] = dict(raw=body.hex() if fmt == 'plain' else '', format=fmt, answer=fields.get('answer'), button=fields.get('button')==['go'],
                                 image=[fields.get('button.x'),fields.get('button.y')],
                                 file=file, bytes=len(body), arrival=arrival, count=receipts.get(key, {}).get('count',0)+1)
            self.send_response(200)
            self.send_header('Content-Type','text/html')
            self.end_headers()
            self.wfile.write(("<script>fetch('/landed/"+key+"?'+(self===top?'top':window.name))</script>").encode())

        def received(self):
            if self.path.startswith('/matrix/'): return self.matrix()
            if self.path == '/form-source':
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                with Path('source-posts').open('a') as hits: hits.write('P')
                self.send_response(200)
                self.send_header('Content-Type','text/html')
                self.end_headers()
                self.wfile.write(Path('index.html').read_bytes())
                return
            if self.path == '/no-content':
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                Path('no-content').write_bytes(body)
                self.send_response(204)
                self.end_headers()
                return
            body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
            if self.path == '/submitted' and Path('source-posts').exists():
                with Path('result-requests').open('a') as hits: hits.write(self.command+' ')
            Path('receipt').write_text(self.command + ' ' + body)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(b'ok')
        def do_GET(self):
            if self.path.startswith('/landed/'):
                url = urlsplit(self.path)
                key = url.path.split('/')[-1]
                Path('matrix-'+key).write_text(json.dumps(dict(receipts[key], frame=url.query)))
                self.send_response(204)
                self.end_headers()
            elif self.path.startswith('/matrix/'): self.matrix()
            elif self.path == '/submitted': self.received()
            else: super().do_GET()
        do_POST = received
    ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
    """, String(port)]
    server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
    try! server.run()
    check(waitUntil(runLoop: true) { (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/index.html")!)) != nil }, "MS 测试服务器起好")
    var devOpen: [String: Any]?
    d.browserTool("browser_open", ["url": "localhost:\(port)/index.html"]) { devOpen = $0 }
    check(waitUntil(runLoop: true) { devOpen != nil } && devOpen?["error"] as? Bool != true && d.browser?.url?.absoluteString == "http://localhost:\(port)/index.html",
          "MS browser_open 把 localhost:端口/index.html 按网址打开（实际：\(devOpen?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")）")
    // hunt8 uncovered 第 2 条：同一文档只换 #片段（#/settings 这类路由）不会有整页载入完成的回调，到了目标地址就该返回成功，不能等满 20 秒报超时。
    // 换片段、片段再换、同一片段再开、去掉片段（整页载入）都要很快成功；本地文件同样
    let fileA = URL(fileURLWithPath: dir + "/A.html").absoluteString
    for url in ["http://localhost:\(port)/index.html#/settings", "http://localhost:\(port)/index.html#/about", "http://localhost:\(port)/index.html#/about",
                "http://localhost:\(port)/index.html", fileA, fileA + "#/settings", fileA + "#/about",
                "http://localhost:\(port)/#/a", "http://localhost:\(port)#/b"] {
        var opened: [String: Any]?
        let started = Date()
        d.browserTool("browser_open", ["url": url]) { opened = $0 }
        _ = waitUntil(runLoop: true) { opened != nil }
        let seconds = Date().timeIntervalSince(started)
        // 没写根路径的 host:端口#片段，WebKit 显示时补上「/」
        check(opened?["error"] as? Bool != true && seconds < 5 && d.browser?.url?.absoluteString == url.replacingOccurrences(of: "\(port)#", with: "\(port)/#"),
              "browser_open 打开 \(url) 很快成功，实际 \(String(format: "%.2f", seconds)) 秒：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
    }
    // hunt9 recheck 第 1 条：网站把 #/private 自动转到 #/login，同文档导航已发生、只是没停在请求的片段上，登录页显示了就该返回实际落点；
    // 已在登录页再开一次 #/private（转一圈回到原地址）同样；本地网页同样
    write("route.html", "<script>function draw() { if (location.hash === '#/private') history.replaceState(null, '', '#/login'); document.title = location.hash || 'home' } draw(); addEventListener('hashchange', draw)</script>")
    for base in ["http://localhost:\(port)/route.html", URL(fileURLWithPath: dir + "/route.html").absoluteString] {
        for (url, landed) in [(base, base), (base + "#/private", base + "#/login"), (base + "#/private", base + "#/login")] {
            var opened: [String: Any]?
            let started = Date()
            d.browserTool("browser_open", ["url": url]) { opened = $0 }
            _ = waitUntil(runLoop: true) { opened != nil }
            let seconds = Date().timeIntervalSince(started)
            check(opened?["error"] as? Bool != true && seconds < 5 && d.browser?.url?.absoluteString == landed && str(opened, "text").contains("地址：" + landed),
                  "browser_open 打开 \(url) 被页面转到 \(landed) 也很快返回实际落点，实际 \(String(format: "%.2f", seconds)) 秒：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
        }
    }
    // hunt10 recheck 不建议修第 1 条：需要登录的页面用脚本整页跳转（location.href、location.replace、meta refresh）到登录页，
    // 是这次打开的延续：等登录页载入完返回实际落点，不能 0.26 秒就报「已被其它导航取代」；网址和本地文件同样
    write("login.html", "<title>login</title>login")
    write("jump-href.html", "<script>location.href = 'login.html'</script>")
    write("jump-replace.html", "<script>location.replace('login.html')</script>")
    write("jump-meta.html", "<meta http-equiv=\"refresh\" content=\"0;url=login.html\">")
    write("gate.html", "<title>gate</title><script>addEventListener('hashchange', () => { if (location.hash === '#enter') location.href = 'login.html' })</script>")
    for base in ["http://localhost:\(port)/", URL(fileURLWithPath: dir, isDirectory: true).absoluteString] {
        for page in ["jump-href.html", "jump-replace.html", "jump-meta.html"] {
            var opened: [String: Any]?
            d.browserTool("browser_open", ["url": base + page]) { opened = $0 }
            _ = waitUntil(runLoop: true) { opened != nil }
            check(opened?["error"] as? Bool != true && d.browser?.url?.absoluteString == base + "login.html" && str(opened, "text").contains("地址：" + base + "login.html"),
                  "browser_open 打开 \(base + page) 被页面脚本转到登录页，返回登录页，实际：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
        }
        // 同一文档换片段后由页面脚本整页转到登录页（#/private 这类路由要登录）同样
        for (url, landed) in [(base + "gate.html", base + "gate.html"), (base + "gate.html#enter", base + "login.html")] {
            var opened: [String: Any]?
            d.browserTool("browser_open", ["url": url]) { opened = $0 }
            _ = waitUntil(runLoop: true) { opened != nil }
            check(opened?["error"] as? Bool != true && d.browser?.url?.absoluteString == landed && str(opened, "text").contains("地址：" + landed),
                  "browser_open 打开 \(url) 落在 \(landed)，实际：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
        }
        // 页面还在自己跳转时又来一次 browser_open：前一次照旧报被取代，后一次落在自己的页面
        var jumping: [String: Any]?, replacing: [String: Any]?
        d.browserTool("browser_open", ["url": base + "jump-href.html"]) { jumping = $0 }
        d.browserTool("browser_open", ["url": base + "B.html"]) { replacing = $0 }
        _ = waitUntil(runLoop: true) { jumping != nil && replacing != nil }
        check(jumping?["error"] as? Bool == true && str(jumping, "text").contains("取代") && replacing?["error"] as? Bool != true && d.browser?.url?.absoluteString == base + "B.html",
              "跳转中被另一次 browser_open 取代，实际：\(jumping?["text"] ?? "无回包") / \(replacing?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
    }
    // hunt9 recheck 第 2 条：传本地绝对路径带 #锚点（不是 file:// 网址）时，锚点要留在最终地址里：从别的页面整页打开、同一页只换锚点都要到；
    // 文件名里本来就有「#」时仍按字面文件名打开，不当成锚点
    write("hash#1.html", "<title>literal</title>literal")
    let fileB = URL(fileURLWithPath: dir + "/B.html").absoluteString
    for (url, landed) in [(dir + "/B.html", fileB), (dir + "/A.html#details", fileA + "#details"), (dir + "/A.html#more", fileA + "#more"),
                          (dir + "/hash#1.html", URL(fileURLWithPath: dir + "/hash#1.html").absoluteString), (dir + "/A.html#中文", fileA + "#%E4%B8%AD%E6%96%87")] {
        var opened: [String: Any]?
        let started = Date()
        d.browserTool("browser_open", ["url": url]) { opened = $0 }
        _ = waitUntil(runLoop: true) { opened != nil }
        let seconds = Date().timeIntervalSince(started)
        check(opened?["error"] as? Bool != true && seconds < 5 && d.browser?.url?.absoluteString == landed,
              "browser_open 打开本地路径 \(url) 很快落在 \(landed)，实际 \(String(format: "%.2f", seconds)) 秒：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
    }
    // 第八轮审查：打开前显示的是「打不开」错误页时，只换 #片段 也要真的再请求一次，仍打不开就如实报错，不能返回「已打开」
    let dead = "http://127.0.0.1:\(freePort())/route.html"
    for url in [dead, dead + "#/private"] {
        var opened: [String: Any]?
        d.browserTool("browser_open", ["url": url]) { opened = $0 }
        _ = waitUntil(runLoop: true) { opened != nil }
        check(opened?["error"] as? Bool == true && str(opened, "text").contains("打不开 " + url),
              "错误页上 browser_open 打开 \(url) 如实报打不开，实际：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
    }
    // 重试能成功时（文件刚生成好）换掉错误页、停在请求的片段上，错误状态清掉
    let late = URL(fileURLWithPath: dir + "/late.html").absoluteString
    for (url, ok) in [(late, false), (late + "#/ready", true)] {
        if ok { write("late.html", "<title>late</title>ready") }
        var opened: [String: Any]?
        d.browserTool("browser_open", ["url": url]) { opened = $0 }
        _ = waitUntil(runLoop: true) { opened != nil }
        check((opened?["error"] as? Bool == true) != ok && (!ok || (d.browser?.url?.absoluteString == url && d.browser?.title == "late" && d.browserFailedURL.isEmpty)),
              "错误页上 browser_open 打开 \(url) 应\(ok ? "成功" : "报打不开")，实际：\(opened?["text"] ?? "无回包")，地址 \(d.browser?.url?.absoluteString ?? "")")
    }
    for target in ["_self", "_blank"] {
        var opened: [String: Any]?
        d.browserTool("browser_open", ["url": "http://localhost:\(port)/index.html?target=\(target)"]) { opened = $0 }
        check(waitUntil(runLoop: true) { opened != nil }, "B9 表单页已就绪")
        try? fm.removeItem(atPath: dir + "/receipt")
        d.browser?.evaluateJavaScript("document.forms[0].target='\(target)'; document.forms[0].requestSubmit()")
        var receipt = ""
        check(waitUntil(runLoop: true) { receipt = (try? String(contentsOfFile: dir + "/receipt", encoding: .utf8)) ?? ""; return !receipt.isEmpty },
              "B9 服务器实际收到 \(target) 提交")
        check(receipt == "POST answer=alpha", "B9 \(target) 提交保留字段，服务端收到「\(receipt)」")
    }
    for (method, target) in [("requestSubmit","_blank"),("submit","_blank"),("requestSubmit","reportWindow"),("submit","reportWindow"),("submit","sameElement"),("requestSubmit","namedControl"),("submit","existingFrame"),("submit","nestedFrame")] {
        var opened: [String: Any]?
        d.browserTool("browser_open", ["url": "http://localhost:\(port)/index.html?upload=\(method)"]) { opened = $0 }
        check(waitUntil(runLoop: true) { opened != nil }, "上传表单已就绪")
        try? fm.removeItem(atPath: dir + "/receipt")
        d.browser?.evaluateJavaScript("""
        const f=document.forms[0], file=document.createElement('input'), dt=new DataTransfer();
        if ('\(target)'==='existingFrame') { const frame=document.createElement('iframe'); frame.name='existingFrame'; document.body.append(frame); }
        if ('\(target)'==='nestedFrame') {
          const outer=document.createElement('iframe'); document.body.append(outer);
          const inner=outer.contentDocument.createElement('iframe'); inner.name='nestedFrame'; outer.contentDocument.body.append(inner);
        }
        f.enctype='multipart/form-data'; f.target='\(target)'; file.type='file'; file.name='attachment';
        if ('\(target)'==='sameElement') { const el=document.createElement('div'); el.id='sameElement'; document.body.append(el); }
        if ('\(target)'==='namedControl') { const el=document.createElement('input'); el.name='target'; f.append(el); }
        dt.items.add(new File(['临时附件正文'],'test.txt')); file.files=dt.files; f.append(file); f.\(method)();
        """)
        var receipt = ""
        check(waitUntil(runLoop: true) { receipt = (try? String(contentsOfFile: dir + "/receipt", encoding: .utf8)) ?? ""; return !receipt.isEmpty } &&
              ["alpha","test.txt","临时附件正文"].allSatisfy(receipt.contains),
              "具名结果窗口上传保留表单和附件 \(method) \(target)，服务端收到 \(receipt.utf8.count) 字节含方法名")
        if ["existingFrame", "nestedFrame"].contains(target) {
            var navigated = false
            let probe = target == "existingFrame" ? "frames[0]" : "frames[0]?.frames[0]"
            check(waitUntil(runLoop: true) {
                d.browser?.evaluateJavaScript("\(probe)?.location.pathname === '/submitted'") { value, _ in navigated = value as? Bool == true }
                return navigated
            }, "已有框架 \(target) 收到提交并保留顶层页面")
        }
    }
    // 每行都在真实 WebKit 提交，服务器核对线上编码，结果页回报实际落在哪一层。
    // 子框架中的空覆盖、同名字段和提交事件末尾的改写，仅检查 HTTP 方法会漏判。
    var formCases: [(String, String, String, String, String)] = [
        // 场景、线上格式、页面准备、触发方式、结果框架。
        ("GET / base", "GET", "base('_blank');", "b.click()", "top"),
        ("普通 POST / 具名", "url", "f.target='report';", "f.requestSubmit(b)", "top"),
        ("纯文本 / 按钮覆盖", "plain", "f.target='_self'; b.formTarget='_BlAnK';", "b.click()", "top"),
        ("按钮覆盖方法", "url", "f.method='get'; b.formMethod='post'; b.formTarget='result';", "f.requestSubmit(b)", "top"),
        ("按钮覆盖编码", "file", "f.enctype='text/plain'; b.setAttribute('formenctype','MULTIPART/FORM-DATA'); b.formTarget='report';", "f.requestSubmit(b)", "top"),
        ("base 具名", "file", "base('report');", "f.submit()", "top"),
        ("提交事件改目标", "file", "f.onsubmit=()=>{b.formTarget='lateReport'};", "b.click()", "top"),
        ("遮蔽 DOM 方法", "file", "f.target='report'; field('getAttribute','x'); field('target','y');", "f.requestSubmit(b)", "top"),
        ("封闭影子树", "file", "f.target='_blank'; doc.body.appendChild(doc.createElement('div')).attachShadow({mode:'closed'}).append(f);", "b.click()", "top"),
        ("子页 / 新窗口", "file", "f.target='_blank';", "f.submit()", "top"),
        ("子页 / 空表单覆盖 base", "file", "base('_blank'); f.target='';", "f.submit()", "source"),
        ("子页 / 空按钮覆盖表单", "file", "f.target='_blank'; b.formTarget='';", "b.click()", "source"),
        ("子页 / self", "plain", "f.target='_SeLf';", "f.requestSubmit()", "source"),
        ("子页 / parent", "url", "f.target='_PaReNt';", "f.submit()", "parent"),
        ("子页 / top", "GET", "b.formTarget='_ToP';", "b.click()", "top"),
        ("子页 / 同级具名", "file", "f.target='sibling';", "f.requestSubmit(b)", "sibling"),
        ("页面监听 formdata 改目标", "file", "document.addEventListener('formdata',()=>{b.formTarget='pageReport'});", "b.click()", "top"),
        ("页面截住事件", "file", "f.target='_blank'; f.addEventListener('formdata', e=>e.stopImmediatePropagation());", "b.click()", "top"),
        ("有子框架的顶页 / 新具名", "file", "frame(doc,'unrelated'); f.target='otherReport';", "f.submit()", "top"),
        ("按钮在表单外", "file", "f.id='owner'; doc.body.append(b); b.setAttribute('form','owner'); b.formTarget='report';", "b.click()", "top"),
        ("formdata 时改目标", "file", "f.onformdata=()=>{f.target='lastTarget'};", "f.submit()", "top"),
        ("子页 / 缺省", "file", "", "f.requestSubmit()", "source"),
        ("控件遮住 DOM 读取与监听", "file", "f.target='report'; for (const key of ['getAttribute','setAttribute','removeAttribute','addEventListener','ownerDocument','enctype','action']) field(key,'x');", "f.requestSubmit(b)", "top"),
        ("子页 / base 具名框架", "file", "base('sibling');", "f.submit()", "sibling"),
        ("跨源嵌套具名", "file", "await foreign(); f.target='remoteResult';", "f.submit()", "remoteResult"),
        ("跨源框架旁的新具名", "file", "await foreign(); f.target='otherReport';", "b.click()", "top"),
        ("方法覆盖编码对照 / 原页", "plain", "f.method='get'; b.formMethod='post'; b.formTarget='_self';", "f.requestSubmit(b)", "top"),
        ("方法覆盖编码对照 / 新窗口", "plain", "f.method='get'; b.formMethod='post'; b.formTarget='_blank';", "f.requestSubmit(b)", "top"),
        ("已命名顶页", "file", "top.name='report'; f.target='report';", "f.submit()", "top"),
        ("输入型提交按钮", "file", "b.remove(); b=field('button','go'); b.type='submit'; b.formTarget='_blank';", "b.click()", "top"),
        ("键盘回车", "url", "f.target='_blank'; f.querySelector('[name=answer]').focus();", "Enter", "top"),
        ("图片提交坐标", "file", "b.remove(); b=field('button','go'); b.type='image'; b.formTarget='imageReport';", "b.click()", "top")
    ]
    let destinations = [
        ("新窗口", "f.target='_blank';", "f.submit()", "top"),
        ("新具名", "b.formTarget='report';", "f.requestSubmit(b)", "top"),
        ("base 目标", "base('report');", "b.click()", "top"),
        ("子页 / self", "f.target='_self';", "f.requestSubmit()", "source"),
        ("子页 / parent", "f.target='_parent';", "f.submit()", "parent"),
        ("子页 / top", "f.target='_top';", "b.click()", "top"),
        ("子页 / 同级", "f.target='sibling';", "f.requestSubmit(b)", "sibling"),
        ("子页 / 空覆盖", "base('_blank'); f.target='';", "f.submit()", "source")
    ]
    for (label, setup, trigger, target) in destinations {
        for format in ["GET", "url", "plain", "file"] {
            formCases.append((label + " × " + format, format, setup, trigger, target))
        }
    }
    var originalEncoding: String?
    var submitTimes: [Double] = []
    for (index, row) in formCases.enumerated() {
        let (label, format, setup, trigger, destination) = row
        let source = "http://localhost:\(port)/index.html?case=\(index)"
        d.openInBrowser(["url": source])
        check(waitUntil(runLoop: true) { d.browserNavigation.finished && d.browser?.url?.absoluteString == source }, "\(label) 表单页就绪")
        let script = """
        await (async () => {
          window.name=''; window.opener=null;
          function foreign() {
            return new Promise(resolve => {
              const outer=document.createElement('iframe'); outer.onload=resolve;
              outer.src='http://127.0.0.1:\(port)/foreign.html'; document.body.append(outer);
            });
          }
          function frame(doc, name) {
            const child = doc.createElement('iframe'); child.name=name; doc.body.append(child); return child.contentDocument;
          }
          let doc = document;
          if (\(label.hasPrefix("子页"))) {
            const parentDoc = frame(document, 'parent');
            doc = frame(parentDoc, 'source'); frame(parentDoc, 'sibling');
          }
          const f = doc.createElement('form');
          let b = doc.createElement('button');
          doc.body.append(f); f.append(b); b.name='button'; b.value='go';
          const base = value => { const el=doc.createElement('base'); el.target=value; doc.head.append(el); };
          const field = (name,value) => { const el=doc.createElement('input'); el.name=name; el.value=value; f.append(el); return el; };
          field('answer','a b'); field('answer','two');
          f.action='/matrix/\(index)'; f.method='\(format == "GET" ? "get" : "post")';
          f.enctype='\(["plain":"text/plain","file":"multipart/form-data"][format] ?? "application/x-www-form-urlencoded")';
          if ('\(format)' === 'file') {
            const input=field('attachment',''); input.type='file';
            const dt=new DataTransfer(); dt.items.add(new File([new Uint8Array([0, 10, 255, 42])], 'test.bin'));
            input.files=dt.files;
          }
          \(setup)
          window.submitCase = () => { \(trigger == "Enter" ? "" : trigger) };
        })()
        """
        var prepared = false, scriptError: Error?
        d.browser?.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result { scriptError = error }
            prepared = true
        }
        guard waitUntil(runLoop: true, { prepared }), scriptError == nil else { check(false, "\(label) 构建表单失败：\(String(describing: scriptError))"); continue }
        let start = Date().timeIntervalSince1970
        if trigger == "Enter" {
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            else { check(false, "无法生成回车按键"); continue }
            d.browser?.keyDown(with: key)
        } else {
            d.browserTool("browser_eval", ["script": "window.submitCase()"]) { result in
                if result["error"] as? Bool == true {
                    scriptError = NSError(domain: "browser_eval", code: 1, userInfo: [NSLocalizedDescriptionKey: str(result, "text")])
                }
            }
        }
        let receiptPath = dir + "/matrix-\(index)"
        var record: [String: Any]?
        let landed = waitUntil(runLoop: true) {
            if let data = fm.contents(atPath: receiptPath), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                record = result
            }
            return record != nil || scriptError != nil
        }
        guard landed, let r = record else { check(false, "\(label) 无回执：\(String(describing: scriptError))"); continue }
        let actual = "\(r["format"] ?? "?") \(r["bytes"] ?? "?") 字节 \(r["frame"] ?? "?")"
        check(r["format"] as? String == format && r["frame"] as? String == destination, "\(label) 格式与落点：\(actual)")
        if label.hasPrefix("方法覆盖编码对照") {
            // 不同系统 WebKit 对按钮覆盖方法后的编码可能不同，要求新窗口与同页逐字节一致。
            let raw = r["raw"] as? String ?? ""
            if label.hasSuffix("原页") { originalEncoding = raw }
            check(!raw.isEmpty && raw == originalEncoding && r["count"] as? Int == 1, "\(label) 与同页正文一致：\(raw)")
        } else {
            let includesButton = label != "图片提交坐标" && (trigger.contains("(b)") || ["b.click()", "Enter"].contains(trigger))
            check(r["answer"] as? [String] == ["a b","two"] &&
                  r["button"] as? Bool == includesButton && r["count"] as? Int == 1, "\(label) 字段：\(r)")
        }
        if label == "图片提交坐标" { check(r["image"] as? [[String]] == [["0"], ["0"]], "图片提交保留点击坐标") }
        if format == "file" { check(r["file"] as? String == "test.bin:000aff2a", "\(label) 文件：\(actual)") }
        if destination == "top", ["按钮覆盖编码","封闭影子树","普通 POST / 具名","页面截住事件","有子框架的顶页 / 新具名"].contains(label) {
            _ = waitUntil(runLoop: true) { d.browser?.url?.path == "/matrix/\(index)" && d.browserNavigation.finished }
            check(d.browser?.backForwardList.backItem?.url.absoluteString == source, "\(label) 后退返回原表单：\(d.browser?.backForwardList.backItem?.url.absoluteString ?? "无")")
        }
        if let arrived = r["arrival"] as? Double { submitTimes.append((arrived - start) * 1000) }
    }
    print("表单从触发到服务器收件（毫秒，矩阵顺序）：\(submitTimes.map { Double(Int($0 * 10)) / 10 })")
    // 204 已经收下文件却没有结果页；替换面板会使用户丢失仍在编辑的来源页。
    let originalURL = "http://localhost:\(port)/index.html?no-content"
    d.openInBrowser(["url": originalURL])
    check(waitUntil(runLoop: true) { d.browserNavigation.finished && d.browser?.url?.absoluteString == originalURL }, "204 来源页就绪")
    let originalBrowser = d.browser.map(ObjectIdentifier.init)
    var loading: Bool?
    d.hooks.jsSink = { name, state in
        if name == "onBrowserState" { loading = state["loading"] as? Bool }
    }
    d.browser?.evaluateJavaScript("""
      const f=document.forms[0], file=document.createElement('input'), dt=new DataTransfer();
      f.action='/no-content'; f.enctype='multipart/form-data'; f.target='_blank';
      f.addEventListener('formdata', e=>e.stopImmediatePropagation());
      file.type='file'; file.name='file'; dt.items.add(new File(['keep-204'],'keep.txt'));
      file.files=dt.files; f.append(file); f.requestSubmit();
    """)
    check(waitUntil(runLoop: true) {
        guard let body = try? String(contentsOfFile: dir + "/no-content", encoding: .utf8) else { return false }
        d.sendBrowserState()
        return body.contains("keep-204") && loading == false
    } && d.browser.map(ObjectIdentifier.init) == originalBrowser && d.browser?.url?.absoluteString == originalURL, "204 保留来源页且服务器收到文件")
    d.hooks.jsSink = nil
    var noNavigation: [String: Any]?
    d.browserTool("browser_eval", ["script": """
      const f=document.createElement('form'), b=document.createElement('button'), input=document.createElement('input');
      document.body.append(f); f.target='_blank'; f.method='post'; f.action='/should-not-submit'; f.append(b,input);
      input.required=true;
      let submits=0;
      f.addEventListener('submit', e=>{ submits++; new FormData(f); e.preventDefault(); });
      f.requestSubmit(b);
      const invalid=submits===0 && f.target==='_blank';
      input.value='ok'; f.requestSubmit(b);
      const canceled=submits===1 && f.target==='_blank';
      const dialog=document.createElement('dialog'), df=document.createElement('form');
      df.method='dialog'; df.target='_blank'; dialog.append(df); document.body.append(dialog);
      dialog.showModal(); df.requestSubmit();
      return invalid && canceled && !dialog.open && df.target==='_blank';
    """]) { noNavigation = $0 }
    check(waitUntil(runLoop: true) { noNavigation != nil } && str(noNavigation ?? [:],"text") == "true" && d.browser?.url?.absoluteString == originalURL,
          "校验失败、页面取消、构造 FormData 和关闭对话框都保留原页和目标")

    d.browser?.evaluateJavaScript("const stage=document.createElement('form'); stage.method='post'; stage.action='/form-source'; document.body.append(stage); stage.submit()")
    check(waitUntil(runLoop: true) { d.browser?.url?.path == "/form-source" && d.browserNavigation.finished }, "先由 POST 进入表单页")
    try? fm.removeItem(atPath: dir + "/receipt")
    d.browser?.evaluateJavaScript("""
      const f=document.forms[0], input=document.createElement('input'), dt=new DataTransfer();
      f.target='_blank'; f.enctype='multipart/form-data'; input.type='file'; input.name='attachment';
      dt.items.add(new File(['original-file'],'stage.txt')); input.files=dt.files; f.append(input);
      window.addEventListener('formdata', e=>e.stopImmediatePropagation(), true); f.requestSubmit();
    """)
    check(waitUntil(runLoop: true) { d.browser?.url?.path == "/submitted" && d.browserNavigation.finished } &&
          (try? String(contentsOfFile: dir + "/receipt", encoding: .utf8))?.contains("original-file") == true &&
          (try? String(contentsOfFile: dir + "/source-posts", encoding: .utf8)) == "P" &&
          d.browser?.backForwardList.backItem?.url.path == "/form-source", "移交结果时来源 POST 只发一次，仍能后退到表单页")
    d.browserCommand("back")
    check(waitUntil(runLoop: true) { d.browser?.url?.path == "/form-source" && d.browserNavigation.finished } && d.browser?.canGoForward == true,
          "浏览器后退按钮回到 POST 来源页，保留前进记录")
    check((try? String(contentsOfFile: dir + "/source-posts", encoding: .utf8)) == "P", "后退到来源页不会再发来源 POST")
    d.browserCommand("forward")
    check(waitUntil(runLoop: true) { d.browser?.url?.path == "/submitted" && d.browserNavigation.finished }, "前进回到上传结果页")
    d.browser?.evaluateJavaScript("history.back()")
    check(waitUntil(runLoop: true) { d.browser?.url?.path == "/form-source" && d.browserNavigation.finished }, "网页后退回到原表单")
    d.browser?.evaluateJavaScript("history.forward()")
    check(waitUntil(runLoop: true) { d.browser?.url?.path == "/submitted" && d.browserNavigation.finished } &&
          (try? String(contentsOfFile: dir + "/source-posts", encoding: .utf8)) == "P" &&
          (try? String(contentsOfFile: dir + "/result-requests", encoding: .utf8)) == "POST ",
          "网页前进回到结果，两张页面各提交一次")
    server.terminate(); server.waitUntilExit()
}
