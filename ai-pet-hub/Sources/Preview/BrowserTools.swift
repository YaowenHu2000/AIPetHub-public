// 让智能体看得到内置浏览器：打开网页、截图、读控制台、读页面文字、在页面里跑脚本。
// 做法是标准的 MCP 工具（三个 CLI 都支持），不往提问里加任何文字：
//   · AIPetHub 自己的可执行文件带 `--mcp-browser <端口名>` 启动时，就是一个 stdio 的 MCP 服务器（不开窗口），由 CLI 拉起来；
//   · 它通过 CFMessagePort 找到正在运行的 AIPetHub，让窗口里的内置浏览器干活，把结果交回给 CLI。
// 每次提问时把这个服务器告诉 CLI（Claude：--mcp-config；Codex：thread/start 的 config.mcp_servers）。Gemini 的 agy -p 没有按次传 MCP 的参数，没接。
import Cocoa
import WebKit

let browserToolList: [[String: Any]] = [
    ["name": "browser_open",
     "description": "在 AIPetHub 的内置浏览器里打开一个地址（http/https 网址、localhost 开发服务器、或本机 HTML 文件的绝对路径），等页面载入后返回最终地址和标题。用户能在窗口右侧看到同一个页面。",
     "inputSchema": ["type": "object", "properties": ["url": ["type": "string", "description": "网址，或本机文件的绝对路径"]], "required": ["url"]]],
    ["name": "browser_screenshot",
     "description": "给内置浏览器当前显示的页面截一张图，用来确认页面实际渲染出来的样子。",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "browser_console",
     "description": "读取内置浏览器当前页面的控制台输出（log / warn / error）和没接住的脚本错误，从这次载入开始算。",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "browser_text",
     "description": "读取内置浏览器当前页面上看得见的文字，以及地址和标题。",
     "inputSchema": ["type": "object", "properties": [String: Any]()]],
    ["name": "browser_eval",
     "description": "在内置浏览器当前页面里执行一段 JavaScript（当作 async 函数体，可以用 await，用 return 返回结果），返回 JSON。可以用来点按钮、填表单、读 DOM。",
     "inputSchema": ["type": "object", "properties": ["script": ["type": "string", "description": "函数体，例如 document.querySelector('button').click(); return document.title;"]], "required": ["script"]]],
]

/// 载入每个页面前注入：把控制台输出和没接住的错误记下来，供 browser_console 读。
let browserConsoleHook = """
(() => {
  if (window.__hubConsole) return;
  const buf = window.__hubConsole = [];
  const put = (level, args) => { try { buf.push(level + ': ' + args.map(a => { try { return typeof a === 'string' ? a : (a instanceof Error ? (a.stack || a.message) : JSON.stringify(a)); } catch (e) { return String(a); } }).join(' ')); if (buf.length > 300) buf.shift(); } catch (e) {} };
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const orig = console[level];
    console[level] = function (...args) { put(level, args); return orig.apply(this, args); };
  }
  window.addEventListener('error', e => put('uncaught', [e.message + (e.filename ? ' (' + e.filename + ':' + e.lineno + ')' : '')]));
  window.addEventListener('unhandledrejection', e => put('unhandledrejection', [e.reason]));
})();
"""

extension AppDelegate {
    /// 启动时：开一个本机端口等 MCP 服务器来找。端口名带进程号，同时开着两个 AIPetHub 也不会串。
    func setupBrowserTools() {
        let name = "com.aipethub.browser.\(getpid())"
        var ctx = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, { _, msgid, data, info in
            guard let info = info else { return nil }
            let me = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            return Unmanaged.passRetained(me.browserPortMessage(msgid, (data as Data?) ?? Data()) as CFData)
        }, &ctx, nil) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, port, 0), .commonModes)
        browserPortName = name
    }

    /// 给 CLI 的 MCP 服务器配置：命令就是 AIPetHub 自己。没打包成 App（自测程序）时没有。
    func browserMCP(_ req: AskRequest) -> (command: String, args: [String])? {
        guard req.browserTools, let name = browserPortName, let exe = Bundle.main.executablePath,
              Bundle.main.bundleIdentifier != nil else { return nil }
        return (exe, ["--mcp-browser", name])
    }

    /// 端口上来的消息（主线程）。1：开始一件事，回它的编号；2：问结果，没好就回空。
    /// 浏览器的操作都是异步的，不能在这里等，所以分成两步。
    func browserPortMessage(_ msgid: Int32, _ data: Data) -> Data {
        if msgid == 2 {
            let id = String(decoding: data, as: UTF8.self)
            guard let done = browserJobs[id], let result = done else { return Data() }
            browserJobs[id] = nil
            return result
        }
        guard let req = jsonObject(data), let tool = req["tool"] as? String else { return Data() }
        let id = UUID().uuidString
        browserJobs[id] = .some(nil)
        browserTool(tool, req["args"] as? [String: Any] ?? [:]) { [weak self] result in
            self?.browserJobs[id] = .some((try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8))
        }
        return Data(id.utf8)
    }

    private func pageInfo(_ b: WKWebView) -> String {
        "地址：\(b.url?.absoluteString ?? "（空）")\n标题：\(b.title ?? "")"
    }

    /// 内置浏览器现在显示着吗（面板开着、当前标签是浏览器）。
    private var browserShowing: Bool {
        guard let b = browser else { return false }
        return !b.isHidden && b.frame.width > 10 && b.frame.height > 10
    }

    /// 没显示就让网页把浏览器标签切出来，等它摆好位置。
    private func showBrowser(_ then: @escaping () -> Void) {
        if browserShowing { then(); return }
        sendToJS("onBrowserToolOpen", ["url": ""])
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            tries += 1
            if self?.browserShowing == true || tries > 15 { t.invalidate(); then() }
        }
    }

    /// 等页面载入完（最多 20 秒）。
    private func whenLoaded(_ then: @escaping (WKWebView?) -> Void) {
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            ticks += 1
            let b = self?.browser
            if ticks >= 3, let b = b, !b.isLoading, b.url != nil, self?.docPreviewPending == nil { t.invalidate(); then(b) }
            else if ticks > 80 { t.invalidate(); then(b) }
        }
    }

    func browserTool(_ tool: String, _ args: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        let fail = { (m: String) in done(["text": m, "error": true]) }
        switch tool {
        case "browser_open":
            let url = trimmed(args["url"] as? String)
            guard !url.isEmpty else { fail("要给一个地址"); return }
            sendToJS("onBrowserToolOpen", ["url": url])   // 让网页切到浏览器标签并打开（和用户在地址栏输入走同一条路）
            whenLoaded { [weak self] b in
                guard let self = self, let b = b else { fail("内置浏览器没有打开"); return }
                if !self.browserFailedURL.isEmpty { fail("打不开 \(self.browserFailedURL)：\(self.browserFailedTitle)"); return }
                done(["text": "已打开。\n" + self.pageInfo(b)])
            }
        case "browser_screenshot":
            showBrowser { [weak self] in
                guard let self = self, let b = self.browser, self.browserShowing else { fail("内置浏览器还没有打开页面，先用 browser_open"); return }
                let cfg = WKSnapshotConfiguration()
                if b.bounds.width > 1280 { cfg.snapshotWidth = 1280 }
                b.takeSnapshot(with: cfg) { image, error in
                    guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { fail("截图失败：\(error?.localizedDescription ?? "")"); return }
                    var data = rep.representation(using: .png, properties: [:]) ?? Data()
                    var mime = "image/png"
                    if data.count > 1_500_000, let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) { data = jpg; mime = "image/jpeg" }
                    done(["text": self.pageInfo(b), "image": data.base64EncodedString(), "mime": mime])
                }
            }
        case "browser_console", "browser_text", "browser_eval":
            guard let b = browser, b.url != nil else { fail("内置浏览器还没有打开页面，先用 browser_open"); return }
            let body: String
            switch tool {
            case "browser_console": body = "return (window.__hubConsole || []).join('\\n');"
            case "browser_text": body = "return (document.body ? document.body.innerText : '').slice(0, 20000);"
            default: body = "const __r = await (async () => { \(args["script"] as? String ?? "") })(); return __r === undefined ? 'undefined' : JSON.stringify(__r, null, 2);"
            }
            b.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let value):
                    let text = value as? String ?? "\(value)"
                    switch tool {
                    case "browser_console": done(["text": text.isEmpty ? "控制台没有输出。\n" + self.pageInfo(b) : clip(text, 20_000)])
                    case "browser_text": done(["text": self.pageInfo(b) + "\n\n" + text])
                    default: done(["text": clip(text, 20_000)])
                    }
                case .failure(let error):
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    fail("脚本出错：\(detail ?? error.localizedDescription)")
                }
            }
        default:
            fail("没有这个工具：\(tool)")
        }
    }
}

// MARK: - `AIPetHub --mcp-browser <端口名>`：stdio 的 MCP 服务器

func runBrowserMCP(_ portName: String) -> Never {
    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }
    /// 让正在运行的 AIPetHub 做一件事，等结果（最多 45 秒）。
    func callApp(_ tool: String, _ args: [String: Any]) -> [String: Any] {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString) else { return ["text": "AIPetHub 没有在运行，用不了内置浏览器", "error": true] }
        func request(_ msgid: Int32, _ payload: Data) -> Data? {
            var reply: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(remote, msgid, payload as CFData, 5, 5, CFRunLoopMode.defaultMode.rawValue, &reply)
            guard status == kCFMessagePortSuccess, let r = reply?.takeRetainedValue() else { return nil }
            return r as Data
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["tool": tool, "args": args]),
              let id = request(1, payload), !id.isEmpty else { return ["text": "连不上 AIPetHub", "error": true] }
        for _ in 0..<225 {
            usleep(200_000)
            if let data = request(2, id), !data.isEmpty {
                return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? ["text": "结果读不出来", "error": true]
            }
        }
        return ["text": "等了 45 秒还没有结果", "error": true]
    }

    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = msg["method"] as? String else { continue }
        guard let id = msg["id"] else { continue }   // 通知（notifications/initialized 等）不用回
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            send(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "aipethub-browser", "version": "1.0"]]])
        case "ping":
            send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        case "tools/list":
            send(["jsonrpc": "2.0", "id": id, "result": ["tools": browserToolList]])
        case "tools/call":
            let r = callApp(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            var content: [[String: Any]] = [["type": "text", "text": r["text"] as? String ?? ""]]
            if let image = r["image"] as? String { content.append(["type": "image", "data": image, "mimeType": r["mime"] as? String ?? "image/png"]) }
            send(["jsonrpc": "2.0", "id": id, "result": ["content": content, "isError": (r["error"] as? Bool) == true]])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "不支持：\(method)"]])
        }
    }
    exit(0)
}
