// GG：Gemini（agy 1.5.11）和另外几位对齐的两处：删除会话时连 agy 另存的文件一起移走；回答进行中能补充一句。
// 补充用的假 CLI 是 fake-cli.py 的 steer（帧格式照实测抓包）。
import Cocoa

/// 删除 Gemini 会话：除了 conversations/<id>.db 和 brain/<id>，agy 还另存了 conversations/<id>.pb 和 annotations/<id>.pbtxt，
/// 桌面版另有 chapter_titles/<id>.pb；留着的话 agy 的 session/list、/resume 还会列出这个会话。别的会话的文件不能动。
func testGGGeminiDeleteLeftovers() {
    print("· GG：删除 Gemini 会话时连 agy 另存的文件一起移走")
    let fm = FileManager.default, d = AppDelegate()
    let root = NSTemporaryDirectory() + "aipethub-gg-delete-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: root) }
    d.hooks.geminiCliDir = root + "/antigravity-cli"
    d.hooks.geminiDesktopRunning = { false }   // 模拟桌面版已退出：桌面会话也可以删
    func files(_ store: GeminiStore, _ id: String) -> [String] {
        ["/conversations/\(id).db", "/conversations/\(id).pb", "/annotations/\(id).pbtxt", "/chapter_titles/\(id).pb", "/brain/\(id)/note.md"].map { store.root + $0 }
    }
    for key in ["gg-cli", "desktop:gg-desktop"] {
        let store = d.geminiStore(key), id = geminiRawId(key), other = id + "-other"
        for path in files(store, id) + files(store, other) {
            try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try! Data("x".utf8).write(to: URL(fileURLWithPath: path))
        }
        var deleted: [String: Any]?
        d.hooks.jsSink = { fn, data in if fn == "onConversationDeleted" { deleted = data } }
        d.deleteConversation(agent: "gemini", cid: key)
        d.geminiQueue.sync {}; d.geminiQueue.sync {}
        eq(deleted?["ok"] as? Bool, true, "GG \(key) 删除成功（reason：\(str(deleted, "reason"))）")
        let left = files(store, id).filter { fm.fileExists(atPath: $0) }.map { $0.replacingOccurrences(of: store.root, with: "") }
        eq(left, [], "GG \(key) 这个会话的文件都移走了")
        eq(files(store, other).filter { !fm.fileExists(atPath: $0) }, [], "GG \(key) 别的会话的文件原样不动")
    }
}

/// 回答进行中补充一句：agy 收下后用 end_turn 答复上一条 prompt，这一轮接着跑；等审批或提问时被拒，留在网页的队列里。
func testGGGeminiSteer() {
    print("· GG：Gemini 回答进行中补充一句")
    let root = NSTemporaryDirectory() + "aipethub-gg-steer-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let image = root + "/steer.png"
    try! png.write(to: URL(fileURLWithPath: image))
    for mode in ["steer 1", "steer 2", "permission", "question", "cancel"] {
        let label = "GG \(mode)"
        let path = root + "/agy-" + mode.replacingOccurrences(of: " ", with: "-")
        try! installFakeCLI(at: path, behavior: "steer")
        try! mode.write(toFile: path + ".mode", atomically: true, encoding: .utf8)
        let app = AppDelegate(), done = DispatchSemaphore(value: 0)
        let calls = JSSink(app).calls
        app.hooks.cliExecutable = path
        app.hooks.sentImagesDir = root + "/aipethub-sent-images/"
        var req = AskRequest(agent: "gemini", reqId: 400, prompt: "run sleep", model: "model", effort: "low",
                             permissionMode: ["permission", "question"].contains(mode) ? "default" : "danger-full-access",
                             workspace: root, conversationId: "")
        req.browserTools = false
        var result: AgentReply?
        DispatchQueue.global().async {
            result = withTestAsk(app, req.key) { app.runGemini(req) }
            done.signal()
        }
        func states(_ sid: String) -> [String] { calls("onAgentSteer").filter { $0["steerId"] as? String == sid }.compactMap { $0["state"] as? String } }
        // 假 CLI 收到的 session/prompt：第一条是提问，后面的是补充
        func prompts() -> [[String: Any]] {
            ((try? String(contentsOfFile: path + ".log", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { app.jsonObject(String($0)) }
                .filter { $0["method"] as? String == "session/prompt" }
        }
        let blocked = ["permission", "question"].contains(mode)
        // 命令开始跑了（审批 / 提问的模式等卡片出来）：这时这一轮已经在进行中
        let ready = waitUntil { blocked ? !calls("onAgentRequest").isEmpty : prompts().count == 1 && !calls("onAgentStep").isEmpty }
        check(ready, "\(label) 这一轮开始了（回答 \(result?.reply ?? "未结束")）")
        app.steer(agent: "gemini", reqId: req.reqId, text: "补充一", images: mode == "steer 1" ? [image] : [], steerId: "s1")
        if mode == "steer 2" { app.steer(agent: "gemini", reqId: req.reqId, text: "补充二", images: [], steerId: "s2") }
        switch mode {
        case "permission", "question":
            check(waitUntil { states("s1").contains("rejected") }, "\(label) 等审批或提问时补充被拒、留在队列（实际 \(states("s1"))）")
            let rid = calls("onAgentRequest").first?["requestId"] as? String ?? ""
            app.answerRequest(agent: "gemini", reqId: req.reqId, requestId: rid,
                              body: mode == "question" ? ["decision": "allow", "answers": ["颜色？": "蓝色"]] : ["decision": "allow"])
        case "cancel":
            check(waitUntil { states("s1").contains("consumed") }, "\(label) 补充先被收下（实际 \(states("s1"))）")
            app.cancel(agent: "gemini", reqId: req.reqId)
        default:
            break
        }
        let finished = waitSignal(done)
        if !finished { app.cancel(agent: "gemini", reqId: req.reqId); _ = waitSignal(done) }
        check(finished, "\(label) 这一轮照常结束")
        let userSteps = ((result?.turn?["steps"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == "user" }
        switch mode {
        case "steer 1":
            eq(states("s1"), ["sent", "consumed"], "\(label) 补充先送出、再被收下")
            let steer = prompts().dropFirst().first?["params"] as? [String: Any]
            eq(steer?["sessionId"] as? String, "session", "\(label) 补充发给同一个会话")
            eq((steer?["prompt"] as? [[String: Any]])?.compactMap { $0["type"] as? String }, ["image", "text"], "\(label) 图片放在文字前面一起发")
            eq(userSteps.compactMap { $0["detail"] as? String }, ["补充一"], "\(label) 工作过程里有「你补充说」那一步")
            eq((userSteps.first?["images"] as? [Any])?.count, 1, "\(label) 补充的图片带缩略图")
            eq(result?.reply, "DONE 补充一", "\(label) 这一轮的回答接着补充答完")
            check(result?.cancelled != true && !(result?.reply ?? "").hasPrefix("⚠️"), "\(label) 上一条 prompt 的 end_turn 不算这一轮结束")
        case "steer 2":
            eq(states("s1") + states("s2"), ["sent", "consumed", "sent", "consumed"], "\(label) 两句补充都被收下")
            eq(userSteps.compactMap { $0["detail"] as? String }, ["补充一", "补充二"], "\(label) 两步「你补充说」按顺序")
            eq(result?.reply, "DONE 补充一 补充二", "\(label) 由最后一条 prompt 的答复结束")
        case "permission", "question":
            eq(states("s1"), ["sent", "rejected"], "\(label) 送出后被 agy 拒收，不记成收下")
            eq(userSteps.count, 0, "\(label) 工作过程里没有被拒的补充")
            eq(result?.reply, "DONE", "\(label) 原来那一轮照常答完")
        default:
            eq(result?.cancelled, true, "\(label) 补充之后停止，按最新的 prompt 记为已停止")
        }
    }
}
