// 网页 ↔ 原生的消息桥：网页发来的每个动作在这里分发；原生调网页的函数走 sendToJS。
//
// 网页进程单独重载时，原生桥在 `pageReady` 补发活动请求的原编号、最新步骤和尚未作答的卡片，网页用它们接回停止和作答操作。
import Cocoa
import WebKit

extension AppDelegate {
    private var pastedImageDirectory: String {
        hooks.pastedImageDirectory ?? "\(home)/Library/Application Support/AIPetHub/粘贴的图片"
    }

    /// 粘贴的截图存成文件（插入路径后 CLI 就能读到），放在 ~/Library/Application Support/AIPetHub/粘贴的图片。
    func savePastedImage(_ dataURL: String, pasteId: Int? = nil) {
        var receipt: [String: Any] = ["pasted": true]
        receipt["pasteId"] = pasteId
        guard let comma = dataURL.firstIndex(of: ","), dataURL.hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            receipt["error"] = "截图数据无法读取"
            sendToJS("onFilesDropped", receipt)
            return
        }
        let ext = dataURL.hasPrefix("data:image/jpeg") ? "jpg" : "png"
        let dir = pastedImageDirectory
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        var path = "\(dir)/截图-\(stamp.string(from: Date())).\(ext)"
        var n = 2
        while fm.fileExists(atPath: path) { path = "\(dir)/截图-\(stamp.string(from: Date()))-\(n).\(ext)"; n += 1 }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        } catch {
            receipt["error"] = error.localizedDescription
            sendToJS("onFilesDropped", receipt)
            return
        }
        receipt["paths"] = [path]
        sendToJS("onFilesDropped", receipt)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if handleAppAction(action, body) { return }
        guard let agent = body["agent"] as? String, validAgents.contains(agent) else { return }
        handleAgentAction(action, agent: agent, body)
    }

    /// 和哪一位无关的动作：窗口、文件、内置浏览器、剪贴板。返回 false = 不是这一类。
    func handleAppAction(_ action: String, _ body: [String: Any]) -> Bool {
        switch action {
        case "pickAttachments":   // 📎：选要附上的文件（可多选）
            let panel = NSOpenPanel()
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            panel.prompt = "附上"
            panel.beginSheetModal(for: window) { [weak self] response in
                var receipt: [String: Any] = ["paths": response == .OK ? panel.urls.map(\.path) : []]
                receipt["pasteId"] = body["pasteId"]
                self?.sendToJS("onFilesDropped", receipt)
            }
            return true
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
            let open = { (url: URL) in if let hook = self.hooks.openURL { hook(url) } else { NSWorkspace.shared.open(url) } }
            if action == "openFile", let ref = body["ref"] as? [String: Any] {
                // 图片查看器看的是发送时那一份；只存在会话记录里的，先落成同样的副本再交给默认应用。
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    guard let path = restoredImagePath(ref) else { return }
                    DispatchQueue.main.async { open(URL(fileURLWithPath: path)) }
                }
            } else if let path = body["path"] as? String {
                let resolved = resolvePath(path, base: body["base"] as? String ?? "")
                guard fm.fileExists(atPath: resolved) else { return true }
                let url = URL(fileURLWithPath: resolved)
                if action == "revealFile" { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { open(url) }
            }
            return true
        case "openURL":
            if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return true
        case "checkFiles":   // 回答里的文件标签：只给真实存在的文件；只写了文件名的，也到回答里提到过的文件夹里找
            if let reqId = (body["reqId"] as? NSNumber)?.intValue, let items = body["items"] as? [[String: Any]] {
                let base = body["base"] as? String ?? ""
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    var found: [String: Any] = [:]
                    for item in items.prefix(800) {
                        guard let key = item["key"] as? String, let paths = item["paths"] as? [String] else { continue }
                        let dirs = (item["dirs"] as? [String] ?? []).map { resolvePath($0, base: base) }
                        search: for (index, raw) in paths.enumerated() {
                            for dir in [base] + dirs {
                                let p = resolvePath(raw, base: dir)
                                var isDir: ObjCBool = false
                                if fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue {
                                    found[key] = ["path": p, "index": index]
                                    break search
                                }
                            }
                        }
                    }
                    sendToJS("onFilesChecked", ["reqId": reqId, "found": found])
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
        case "browserReloadIfUses":
            reloadBrowserIfUses(body["paths"] as? [String] ?? [])
            return true
        case "discardPastedImage":
            if let path = body["path"] as? String {
                let name = (path as NSString).lastPathComponent
                if path == pastedImageDirectory + "/" + name,
                   name.range(of: #"^截图-\d{8}-\d{6}(-\d+)?\.(png|jpg)$"#, options: .regularExpression) != nil {
                    try? fm.removeItem(atPath: path)
                }
            }
            return true
        case "savePastedImage":
            if let data = body["data"] as? String, data.count < 40_000_000 { savePastedImage(data, pasteId: body["pasteId"] as? Int) }
            else { sendToJS("onFilesDropped", ["pasted":true, "error":"截图过大或数据为空", "pasteId":body["pasteId"] ?? NSNull()]) }
            return true
        case "chatThumbs", "chatImage", "editChatImages":   // 对话里的图片：缩略图、点开看原图（ChatImages.swift）
            handleChatImageRequest(action, body)
            return true
        case "pageReady":   // 页面脚本都载入了：把窗口现在的状态（全屏、在不在前台）告诉它
            syncWindowStateToPage()
            for turn in pageTurns.values {
                var data = turn.request
                data["steps"] = turn.steps.sorted { $0.key < $1.key }.map(\.value)
                data["cards"] = turn.cards
                data["queue"] = turn.queue
                // 同一主队列里立即投递，否则随后已撤的卡可能在撤卡回调之后才出现。
                if let bytes = try? JSONSerialization.data(withJSONObject: data),
                   let json = String(data: bytes, encoding: .utf8) {
                    webView.evaluateJavaScript("window.onRestoreActiveTurn?.(\(json))", completionHandler: nil)
                }
            }
            return true
        case "checkSessionLive":   // 打开着的会话是不是正开在别的程序里（ClaudeSessions.swift）
            checkSessionLive(agent: body["agent"] as? String ?? "", cid: body["conversationId"] as? String ?? "")
            return true
        case "probeAgents":   // 这几位的 CLI 装没装（AgentSetup.swift）
            probeAgents(body["agents"] as? [String] ?? [], refresh: body["refresh"] as? Bool == true)
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
        case "testHoldHistory":
            if UITest.active { hooks.heldHistoryReplies = [] }
            return true
        case "testReleaseHistory":
            if UITest.active {
                let replies = hooks.heldHistoryReplies ?? []
                hooks.heldHistoryReplies = nil
                replies.forEach { $0() }
                sendToJS("onTestHistoryReleased", [:])
            }
            return true
        case "testWarmState":   // 窗口测试：预热进程握手到哪一步、接手过几次。agy 握手的答复不带命令和模型，网页收不到任何回调，只能问原生
            if UITest.active, let agent = body["agent"] as? String {
                procLock.lock(); let warm = warmProcs[agent]; let adopted = warmAdopted; procLock.unlock()
                let stage = warm?.withWarmLock { warm?.stage ?? -1 } ?? -1
                sendToJS("onTestWarmState", ["agent": agent, "running": warm?.proc.isRunning == true, "stage": stage, "adopted": adopted])
            }
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
        if let reqId, action == "askAgent" || action == "steerAgent" {
            let missing = (body["images"] as? [String] ?? []).filter { !isAttachableImage($0) }
            if !missing.isEmpty {
                let reason = "⚠️ 图片「" + missing.map(fileBaseName).joined(separator: "、") + "」无法读取，这句话没有发送。"
                if action == "askAgent" {
                    rejectUnsentAsk(askRequest(agent: agent, reqId: reqId, body), reason: reason)
                } else {
                    sendToJS("onAgentSteer", ["agent":agent, "reqId":reqId, "steerId":body["steerId"] ?? "",
                                              "state":"rejected", "reason":reason, "restoreDraft":true])
                }
                return
            }
        }
        switch action {
        case "pickWorkspace":
            pickWorkspace(agent: agent)
        case "listConversations":
            listConversations(agent: agent)
        case "loadConversation":
            if let cid = body["conversationId"] as? String, validConversationId(cid, agent: agent) {
                if agent == "deepseek", body["unreadProbe"] as? Bool == true, let reqId = body["reqId"] as? Int {
                    // 背景存在性检查只读服务的第一页，不能替换眼前会话的分页窗口。
                    deepseekQueue.async { [self] in
                        let missing = readDeepSeekHistory(cid:cid, pageLimit:1).missing
                        sendToJS("onConversationLoaded", ["agent":agent,"conversationId":cid,"reqId":reqId,"missing":missing])
                    }
                    return
                }
                if let limit = (body["limit"] as? NSNumber)?.intValue, limit > 0 {
                    procLock.lock(); historyLimits[cid] = limit; procLock.unlock()
                }
                if agent == "deepseek", body["searchHit"] as? Bool == true {
                    procLock.lock(); historySearchOpens.insert(cid); procLock.unlock()
                }
                loadConversation(agent: agent, cid: cid, reqId: (body["reqId"] as? NSNumber)?.intValue)
            }
        case "searchConversations":   // ⌘F：在会话正文里找（ConversationSearch.swift）
            searchConversations(agent: agent, query: body["query"] as? String ?? "", reqId:reqId)
        case "deleteConversation":
            if let cid = body["conversationId"] as? String, validConversationId(cid, agent: agent) {
                deleteConversation(agent: agent, cid: cid)
            }
        case "deleteConversations":
            let ids = (body["conversationIds"] as? [String] ?? []).filter { validConversationId($0, agent: agent) }
            if !ids.isEmpty { deleteConversations(agent: agent, ids: ids, reqId:reqId) }
        case "taskGroupChanged":   // 右键移进移出「任务会话」：告诉其他实例（Conversations.swift）
            if let cid = body["conversationId"] as? String, !cid.isEmpty {
                notifyTaskGroupChanged(agent: agent, cid: cid, task: body["task"] as? Bool)
            }
        case "projectConversations":
            if let workspace = body["workspace"] as? String, !workspace.isEmpty {
                projectConversations(agent: agent, workspace: workspace)
            }
        case "askAgent":
            if let reqId, body["prompt"] is String {
                let req = askRequest(agent: agent, reqId: reqId, body)
                var data = body
                data["since"] = Date().timeIntervalSince1970 * 1000
                pageTurns[req.key] = PageTurn(request: data)
                ask(req)
            }
        case "cancelAgent":
            cancel(agent: agent, reqId: reqId)
        case "prewarmAgent":   // 用户开始打字 / 上一轮刚答完：按现在的设置把 CLI 先起好（Prewarm.swift）
            prewarm(askRequest(agent: agent, reqId: 0, body), typing: body["typing"] as? Bool == true)
        case "steerAgent":   // 回答进行中又发来一句（可以带图片）
            if let reqId = reqId, let text = body["text"] as? String, let sid = body["steerId"] as? String {
                let images = body["images"] as? [String] ?? []
                pageTurns["\(agent)#\(reqId)"]?.queue.append(body)
                steer(agent: agent, reqId: reqId, text: text, images: images, steerId: sid)
            }
        case "queueOrder":
            guard let reqId, let ids = body["ids"] as? [String] else { break }
            let key = "\(agent)#\(reqId)"
            pageTurns[key]?.request["returnedQueue"] = body["returnedQueue"]
            if let queue = pageTurns[key]?.queue {
                pageTurns[key]?.queue = ids.compactMap { id in
                    guard var item = queue.first(where: { $0["steerId"] as? String == id }) else { return nil }
                    item["jump"] = body["jump"] as? String == id
                    return item
                }
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
            conversationId: validConversationId(convId, agent: agent) ? convId : "",
            images: body["images"] as? [String] ?? [],
            imageRefs: body["imageRefs"] as? [[String: Any]] ?? [],
            browserTools: body["browserTools"] as? Bool ?? true,
            fast: body["fast"] as? Bool ?? false)
    }

    func sendToJS(_ fn: String, _ payload: [String: Any]) {
        if let sink = hooks.jsSink { sink(fn, payload); return }
        // 字段按名字排好序再发：字典里字段的先后每次都可能不一样，网页那边拿整段内容比「变没变」时会被顺序骗到
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let agent = payload["agent"] as? String, let rid = payload["reqId"] as? Int {
                let key = "\(agent)#\(rid)"
                switch fn {
                case "onAgentResponse": self.pageTurns[key] = nil
                case "onAgentStep":
                    if let i = payload["index"] as? Int { self.pageTurns[key]?.steps[i] = payload }
                case "onAgentSteer":
                    if let i = self.pageTurns[key]?.queue.firstIndex(where: { $0["steerId"] as? String == payload["steerId"] as? String }) {
                        if payload["restoreDraft"] as? Bool == true || (payload["state"] as? String == "consumed" && self.pageTurns[key]?.queue[i]["jump"] as? Bool != true) {
                            self.pageTurns[key]?.queue.remove(at: i)
                        } else {
                            self.pageTurns[key]?.queue[i]["state"] = payload["state"]
                        }
                    }
                case "onAgentSentImages":
                    // 补充可能重新排队多次，原文件名仍由草稿持有；新回执的键则是上一次交付的副本。
                    func recordCopies(_ request: inout [String:Any]) {
                        let copies = payload["paths"] as? [String:String] ?? [:]
                        var sent = request["sentPaths"] as? [String:String] ?? [:]
                        for path in request["sourceImages"] as? [String] ?? request["images"] as? [String] ?? [] {
                            if let copy = copies[sent[path] ?? path] { sent[path] = copy }
                        }
                        request["sentPaths"] = sent
                    }
                    if let sid = payload["steerId"] as? String {
                        if var turn = self.pageTurns[key], let i = turn.queue.firstIndex(where:{ $0["steerId"] as? String == sid }) {
                            recordCopies(&turn.queue[i])
                            self.pageTurns[key] = turn
                        }
                    } else if var turn = self.pageTurns[key] {
                        recordCopies(&turn.request)
                        turn.request["restoredPaths"] = payload["restoredPaths"]
                        self.pageTurns[key] = turn
                    }
                case "onAgentImageKeys": self.pageTurns[key]?.request["imageKeys"] = payload["keys"]
                case "onAgentConversation": self.pageTurns[key]?.request["conversationId"] = payload["conversationId"]
                case "onAgentRequest", "onAgentRequestClosed":
                    self.pageTurns[key]?.cards.removeAll { $0["requestId"] as? String == payload["requestId"] as? String }
                    if fn == "onAgentRequest" { self.pageTurns[key]?.cards.append(payload) }
                default: break
                }
            }
            let deliver: () -> Void = { [weak self] in
                self?.webView.evaluateJavaScript("window.\(fn) && window.\(fn)(\(json));", completionHandler: nil)
            }
            if fn == "onConversationLoaded", self.hooks.heldHistoryReplies != nil {
                self.hooks.heldHistoryReplies?.append(deliver)
                self.sendToJS("onTestHistoryHeld", ["reqId": payload["reqId"] ?? 0])
            } else { deliver() }
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
