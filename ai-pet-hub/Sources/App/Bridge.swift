// 网页 ↔ 原生的消息桥：网页发来的每个动作在这里分发；原生调网页的函数走 sendToJS。
import Cocoa
import WebKit

extension AppDelegate {
    /// 粘贴的截图存成文件（插入路径后 CLI 就能读到），放在 ~/Library/Application Support/AIPetHub/粘贴的图片。
    func savePastedImage(_ dataURL: String) {
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return }
        let ext = dataURL.hasPrefix("data:image/jpeg") ? "jpg" : "png"
        let dir = "\(home)/Library/Application Support/AIPetHub/粘贴的图片"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var path = "\(dir)/截图-\(stamp.string(from: Date())).\(ext)"
        var n = 2
        while fm.fileExists(atPath: path) { path = "\(dir)/截图-\(stamp.string(from: Date()))-\(n).\(ext)"; n += 1 }
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return }
        sendToJS("onFilesDropped", ["paths": [path], "pasted": true])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if handleAppAction(action, body) { return }
        guard let agent = body["agent"] as? String, validAgents.contains(agent) else { return }
        handleAgentAction(action, agent: agent, body)
    }

    /// 和哪一位无关的动作：窗口、文件、内置浏览器、剪贴板。返回 false = 不是这一类。
    private func handleAppAction(_ action: String, _ body: [String: Any]) -> Bool {
        switch action {
        case "startWindowDrag":
            beginWindowDrag()
            return true
        case "zoomWindow":
            window.zoom(nil)
            return true
        case "openFolder":
            if let path = body["path"] as? String, isDirectory(path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            return true
        case "readFile":
            if let path = body["path"] as? String, let reqId = (body["reqId"] as? NSNumber)?.intValue {
                readFileForPreview(path: path, base: body["base"] as? String ?? "", reqId: reqId)
            }
            return true
        case "revealFile", "openFile":
            if let path = body["path"] as? String {
                let resolved = resolvePath(path, base: body["base"] as? String ?? "")
                guard fm.fileExists(atPath: resolved) else { return true }
                let url = URL(fileURLWithPath: resolved)
                if action == "revealFile" { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
            }
            return true
        case "openURL":
            if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return true
        case "checkFiles":   // 回答里的文件标签：只给真实存在的文件
            if let reqId = (body["reqId"] as? NSNumber)?.intValue, let paths = body["paths"] as? [String] {
                let base = body["base"] as? String ?? ""
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    var exists: [String: Bool] = [:]
                    for raw in paths.prefix(500) {
                        var isDir: ObjCBool = false
                        exists[raw] = fm.fileExists(atPath: resolvePath(raw, base: base), isDirectory: &isDir) && !isDir.boolValue
                    }
                    sendToJS("onFilesChecked", ["reqId": reqId, "exists": exists])
                }
            }
            return true
        case "browserOpen":
            openInBrowser(body)
            return true
        case "browserRect":
            placeBrowser(body)
            return true
        case "browserCommand":
            browserCommand(body["cmd"] as? String ?? "")
            return true
        case "savePastedImage":
            if let data = body["data"] as? String, data.count < 40_000_000 { savePastedImage(data) }
            return true
        case "chatThumbs", "chatImage":   // 对话里的图片：缩略图、点开看原图（ChatImages.swift）
            handleChatImageRequest(action, body)
            return true
        case "pageReady":   // 页面脚本都载入了：把窗口现在的状态（全屏、在不在前台）告诉它
            syncWindowStateToPage()
            return true
        case "checkSessionLive":   // 打开着的会话是不是正开在别的程序里（ClaudeSessions.swift）
            checkSessionLive(agent: body["agent"] as? String ?? "", cid: body["conversationId"] as? String ?? "")
            return true
        case "probeAgents":   // 这几位的 CLI 装没装（AgentSetup.swift）
            probeAgents(body["agents"] as? [String] ?? [])
            return true
        case "verifyAgent":   // 添加之前真的让它答一句话
            if let agent = body["agent"] as? String { verifyAgent(agent) }
            return true
        case "setEnabledAgents":   // 界面上现在启用着哪几位
            if let list = body["agents"] as? [String] { enabledAgents = Set(list) }
            return true
        case "haptic":   // 滑杆过一档：触控板轻轻一下
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return true
        case "loadUsage":   // 模型菜单打开时：问这一位的剩余用量
            if let agent = body["agent"] as? String { loadUsage(agent: agent, force: body["force"] as? Bool ?? false) }
            return true
        case "listFiles":   // 输入框里 @：按名字找工作空间里的文件
            if let reqId = (body["reqId"] as? NSNumber)?.intValue {
                listFiles(workspace: body["workspace"] as? String ?? "", query: body["query"] as? String ?? "", reqId: reqId)
            }
            return true
        case "testSnapshot":   // 自动化测试：存一张界面截图
            if let path = body["path"] as? String { uiTestSnapshot(path) }
            return true
        case "testWindowShot":   // 自动化测试（真实窗口模式）：把整个窗口截下来
            if let path = body["path"] as? String { uiTestWindowShot(path) }
            return true
        case "testClick":   // 自动化测试：在这个位置真的点一下
            if let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue { uiTestClick(x: x, y: y) }
            return true
        case "testResize":   // 自动化测试：改窗口大小
            if let w = (body["width"] as? NSNumber)?.doubleValue, let h = (body["height"] as? NSNumber)?.doubleValue { uiTestResize(width: w, height: h) }
            return true
        case "testChrome":   // 自动化测试：红绿灯在哪
            uiTestChrome()
            return true
        case "copyText":   // 代码块、回答上的「拷贝」按钮
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return true
        default:
            return false
        }
    }

    /// 针对某一位的动作：历史会话、提问、停止、中途补充、答复请求、预热。
    private func handleAgentAction(_ action: String, agent: String, _ body: [String: Any]) {
        let reqId = (body["reqId"] as? NSNumber)?.intValue
        switch action {
        case "pickWorkspace":
            pickWorkspace(agent: agent)
        case "listConversations":
            listConversations(agent: agent)
        case "loadConversation":
            if let cid = body["conversationId"] as? String, isSafeId(cid) {
                if let limit = (body["limit"] as? NSNumber)?.intValue, limit > 0 {
                    procLock.lock(); historyLimits[cid] = min(limit, 5000); procLock.unlock()
                }
                loadConversation(agent: agent, cid: cid)
            }
        case "searchConversations":   // ⌘F：在会话正文里找（ConversationSearch.swift）
            searchConversations(agent: agent, query: body["query"] as? String ?? "")
        case "deleteConversation":
            if let cid = body["conversationId"] as? String, isSafeId(cid) {
                deleteConversation(agent: agent, cid: cid)
            }
        case "deleteConversations":
            let ids = (body["conversationIds"] as? [String] ?? []).filter { isSafeId($0) }
            if !ids.isEmpty { deleteConversations(agent: agent, ids: ids) }
        case "projectConversations":
            if let workspace = body["workspace"] as? String, !workspace.isEmpty {
                projectConversations(agent: agent, workspace: workspace)
            }
        case "askAgent":
            if let reqId = reqId, body["prompt"] is String { ask(askRequest(agent: agent, reqId: reqId, body)) }
        case "cancelAgent":
            cancel(agent: agent, reqId: reqId)
        case "prewarmAgent":   // 用户开始打字 / 上一轮刚答完：按现在的设置把 CLI 先起好（Prewarm.swift）
            prewarm(askRequest(agent: agent, reqId: 0, body))
        case "steerAgent":   // 回答进行中又发来一句（可以带图片）
            if let reqId = reqId, let text = body["text"] as? String, let sid = body["steerId"] as? String {
                let images = (body["images"] as? [String] ?? []).filter { isAttachableImage($0) }
                steer(agent: agent, reqId: reqId, text: text, images: images, steerId: sid)
            }
        case "answerAgentRequest":   // 审批 / 提问 / 计划 的答复
            if let reqId = reqId, let rid = body["requestId"] as? String {
                answerRequest(agent: agent, reqId: reqId, requestId: rid, body: body)
            }
        default:
            break
        }
    }

    /// 网页发来的提问 / 预热参数 → AskRequest。会话 ID、图片都在这里校验。
    private func askRequest(agent: String, reqId: Int, _ body: [String: Any]) -> AskRequest {
        let convId = body["conversationId"] as? String ?? ""
        return AskRequest(
            agent: agent, reqId: reqId, prompt: body["prompt"] as? String ?? "",
            model: body["model"] as? String ?? "", effort: body["effort"] as? String ?? "",
            permissionMode: body["permissionMode"] as? String ?? "", workspace: body["workspace"] as? String ?? "",
            conversationId: isSafeId(convId) ? convId : "",
            images: (body["images"] as? [String] ?? []).filter { isAttachableImage($0) },
            browserTools: body["browserTools"] as? Bool ?? true,
            fast: body["fast"] as? Bool ?? false)
    }

    func sendToJS(_ fn: String, _ payload: [String: Any]) {
        if let sink = jsSink { sink(fn, payload); return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("window.\(fn) && window.\(fn)(\(json));", completionHandler: nil)
        }
    }

    /// 顶栏是网页画的，WKWebView 不会帮忙拖窗口，这里跟随鼠标移动窗口直到松开左键。
    func beginWindowDrag() {
        guard dragTimer == nil, (NSEvent.pressedMouseButtons & 1) != 0 else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if (NSEvent.pressedMouseButtons & 1) == 0 {
                t.invalidate()
                self.dragTimer = nil
                return
            }
            let now = NSEvent.mouseLocation
            var origin = NSPoint(x: self.dragStartOrigin.x + now.x - self.dragStartMouse.x,
                                 y: self.dragStartOrigin.y + now.y - self.dragStartMouse.y)
            let screen = NSScreen.screens.first { NSMouseInRect(now, $0.frame, false) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                origin.y = min(origin.y, visible.maxY - self.window.frame.height)
            }
            self.window.setFrameOrigin(origin)
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pickWorkspace(agent: String) {
        let panel = NSOpenPanel()
        panel.message = "选择工作空间目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.sendToJS("onWorkspacePicked", ["agent": agent, "path": url.path])
        }
    }
}
