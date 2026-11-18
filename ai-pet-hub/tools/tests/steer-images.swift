// 中途补充和普通用户消息共用图片协议；历史、实时回显、缩略图与原图都要保住同一张图。
import Foundation
import Cocoa

func testSteerImages() {
    print("· 中途补充的图片：历史、实时、缩略图与原图")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-steer-images-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let path = dir + "/image.png"
    try! png.write(to: URL(fileURLWithPath: path))
    let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
    let onlyID = UUID().uuidString, mixedID = UUID().uuidString, cid = UUID().uuidString
    func row(_ value: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self) }
    let lines = [
        row(["type": "user", "message": ["content": "提问"]]),
        row(["type": "assistant", "message": ["content": [["type": "text", "text": "正在看"]]]]),
        row(["type": "attachment", "uuid": onlyID, "attachment": ["type": "queued_command", "origin": ["kind": "human"], "prompt": [image]]]),
        row(["type": "attachment", "uuid": mixedID, "attachment": ["type": "queued_command", "origin": ["kind": "human"], "prompt": [["type": "text", "text": "补充图"], image]]]),
        row(["type": "attachment", "uuid": UUID().uuidString, "attachment": ["type": "queued_command", "origin": ["kind": "system"], "prompt": [image]]]),
        row(["type": "assistant", "message": ["content": [["type": "text", "text": "答完了"]]]])
    ].joined(separator: "\n")
    let app = AppDelegate()
    app.jsSink = { _, _ in }
    let history = dir + "/history.jsonl"
    try! lines.write(toFile: history, atomically: true, encoding: .utf8)
    app.claudeCache[cid] = (0, nil, history)
    var messages = app.claudeTurns(Data(lines.utf8)).0
    let userSteps = (messages.last?["steps"] as? [[String: Any]] ?? []).filter { str($0, "kind") == "user" }
    eq(userSteps.map { str($0, "detail") }, ["", "补充图"], "Claude 纯图补充不消失、不加占位，系统附件仍排除")
    eq(userSteps.flatMap { $0["imageSources"] as? [[String: Any]] ?? [] }.compactMap { $0["ref"] as? String },
       [onlyID + "#0", mixedID + "#1"], "Claude 补充沿用行 UUID 和原内容块序号")
    app.attachChatImages(&messages, payload: ["agent": "claude", "conversationId": cid, "cwd": dir])
    let attached = (messages.last?["steps"] as? [[String: Any]] ?? []).filter { str($0, "kind") == "user" }
    let thumbs = attached.flatMap { $0["images"] as? [[String: Any]] ?? [] }
    eq(thumbs.count, 2, "Claude 两种补充都生成缩略图")
    check(attached.allSatisfy { $0["imageSources"] == nil }, "原始 base64 不随步骤发到页面")
    if let thumb = thumbs.first {
        let ref = thumb["ref"] as? [String: String] ?? [:]
        eq(ref, ["agent": "claude", "conversationId": cid, "id": onlyID + "#0"], "补充图片沿用原图引用字段")
        eq(app.fullChatImage(["ref": ref]), fullImageDataURL(png), "Claude 从 queued_command 原记录打开原图")
    }
    let localStep: [String: Any] = ["kind": "user", "detail": "", "imageSources": [["path": path]]]
    var codex: [[String: Any]] = [["role": "bot", "steps": [localStep]]]
    app.attachChatImages(&codex, payload: ["agent": "gpt", "conversationId": cid, "cwd": dir])
    let codexStep = (codex.first?["steps"] as? [[String: Any]])?.first
    let codexThumb = (codexStep?["images"] as? [[String: Any]])?.first
    eq(str(codexThumb, "path"), path, "Codex 补充的本地图片走同一缩略图机制")
    check(codexStep?["imageSources"] == nil, "Codex 步骤也不保留原始来源字段")
    eq(app.fullChatImage(["path": path]), fullImageDataURL(png), "Codex 补充可以读取本地原图")

    let recoverID = UUID().uuidString, deletedPath = dir + "/removed.png"
    let codexHome = dir + "/codex"
    try! fm.createDirectory(atPath: codexHome + "/sessions", withIntermediateDirectories: true)
    app.hooks.codexEnvironment = ["CODEX_HOME": codexHome]
    func codexItem(_ type: String, _ content: [[String: Any]]) -> String {
        row(["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "image-turn", "item": ["type": type, "content": content]]])
    }
    let recoveredHistory = [
        codexItem("UserMessage", [["type": "text", "text": "提问"]]),
        codexItem("UserMessage", [["type": "localImage", "path": deletedPath]]),
        codexItem("AgentMessage", [["type": "text", "text": "回答"]]),
        row(["type": "response_item", "payload": ["role": "user", "content": [
            ["type": "input_text", "text": "<image path=\"\(deletedPath)\">"],
            ["type": "input_image", "image_url": "data:image/png;base64," + png.base64EncodedString()]
        ]]])
    ].joined(separator: "\n")
    try! (recoveredHistory + "\n").write(toFile: codexHome + "/sessions/rollout-fixture-\(recoverID).jsonl", atomically: true, encoding: .utf8)
    var restored = app.codexRolloutTurns(recoveredHistory).messages
    app.attachChatImages(&restored, payload: ["agent": "gpt", "conversationId": recoverID, "cwd": dir])
    let restoredStep = (restored.last?["steps"] as? [[String: Any]])?.first
    let restoredImage = (restoredStep?["images"] as? [[String: Any]])?.first
    check(!str(restoredImage, "src").isEmpty && restoredImage?["missing"] == nil, "Codex 补充的原文件已删除时从 rollout 恢复缩略图")
    let recoveredRef = restoredImage?["ref"] as? [String: String] ?? [:]
    eq(recoveredRef["id"], deletedPath, "恢复图片保留原路径作为引用")
    eq(app.fullChatImage(["ref": recoveredRef]), fullImageDataURL(png), "Codex 恢复的补充缩略图可以打开原图")
    app.hooks.codexEnvironment = nil

    var req = AskRequest(agent: "claude", reqId: 711, prompt: "提问", model: "model", effort: "low", permissionMode: "default", workspace: dir, conversationId: "")
    req.browserTools = false
    let claude = ClaudeLiveTurn(app: app, req: req, command: ("/unused", [], false))
    check(claude.steer("", images: [path], id: "claude-image"), "Claude 发送纯图片补充")
    claude.handle(line: #"{"type":"user","isReplay":true}"#)
    claude.handle(line: #"{"type":"user","isReplay":true}"#)
    claude.input.close()
    eq((claude.builder.steps.last?["images"] as? [[String: Any]])?.compactMap { $0["path"] as? String }, [path], "Claude 实时回显仍带原图片路径")
    eq(str(claude.builder.steps.last, "detail"), "", "Claude 实时纯图没有占位文字")

    let cli = dir + "/cli"
    try! installFakeCLI(at: cli, behavior: "backend")
    req = AskRequest(agent: "gpt", reqId: 712, prompt: "提问", model: "model", effort: "low", permissionMode: "default", workspace: dir, conversationId: "")
    req.browserTools = false
    let codexLive = CodexLiveTurn(app: app, req: req, codex: cli, model: "model", effort: "low", sandbox: "read-only")
    app.hooks.cliStarted = { _, _ in
        codexLive.locked {
            codexLive.handle(line: #"{"method":"thread/started","params":{"thread":{"id":"fixture-thread"}}}"#)
            codexLive.handle(line: #"{"method":"turn/started","params":{"turn":{"id":"fixture-turn"}}}"#)
            codexLive.handle(line: #"{"method":"item/completed","params":{"item":{"type":"userMessage","id":"first","content":[{"type":"text","text":"提问"}]}}}"#)
            check(codexLive.steer("补充图", images: [path], id: "codex-image"), "Codex 发送图文补充")
            codexLive.handle(line: #"{"method":"item/completed","params":{"item":{"type":"userMessage","id":"steer","content":[{"type":"text","text":"补充图"}]}}}"#)
            codexLive.handle(line: #"{"method":"turn/completed","params":{"turn":{"id":"fixture-turn","status":"completed"}}}"#)
        }
    }
    _ = withTestAsk(app, req.key) { codexLive.run() }
    app.hooks.cliStarted = nil
    eq((codexLive.builder.steps.last?["images"] as? [[String: Any]])?.compactMap { $0["path"] as? String }, [path], "Codex 实时确认补充仍带图片")
    eq(str(codexLive.builder.steps.last, "detail"), "补充图", "Codex 实时补充文字不变")
}
