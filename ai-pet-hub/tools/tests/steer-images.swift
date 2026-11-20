// 中途补充和普通用户消息共用图片协议；历史、实时回显、缩略图与原图都要保住同一张图。
import Foundation
import Cocoa
import SQLite3

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
    let lines = [
        row(["type": "user", "message": ["content": "提问"]]),
        row(["type": "assistant", "message": ["content": [["type": "text", "text": "正在看"]]]]),
        row(["type": "attachment", "uuid": onlyID, "attachment": ["type": "queued_command", "origin": ["kind": "human"], "prompt": [image]]]),
        row(["type": "attachment", "uuid": mixedID, "attachment": ["type": "queued_command", "origin": ["kind": "human"], "prompt": [["type": "text", "text": "补充图"], image]]]),
        row(["type": "attachment", "uuid": UUID().uuidString, "attachment": ["type": "queued_command", "origin": ["kind": "system"], "prompt": [image]]]),
        row(["type": "assistant", "message": ["content": [["type": "text", "text": "答完了"]]]])
    ].joined(separator: "\n")
    let app = AppDelegate()
    app.hooks.sentImagesDir = dir + "/aipethub-sent-images/"
    app.hooks.jsSink = { _, _ in }
    let mentioned = app.chatImages(sources: [], text: path, base: dir)
    let fromAttachment = app.chatImages(sources: [["path": path]], text: path, base: dir)
    check(mentioned.first?["mentioned"] as? Bool == true && fromAttachment.count == 1 && fromAttachment.first?["mentioned"] as? Bool != true,
          "B3-9 正文路径与真正附件保留来源，实际=\(String(describing: mentioned.first?["mentioned"]))")
    let frozen = app.temporaryImageFile(png, ext:"png", origin:path)!
    let replacement = solidImage(8, 4, rgb:(0,0,1), type:"public.png")!
    for agent in ["claude","gpt","gemini","deepseek"] {
        try! replacement.write(to:URL(fileURLWithPath:path))
        let ask: [String:Any] = ["role":"user","text":"看图","imageSources":[["path":frozen]]]
        let step: [String:Any] = ["kind":"user","detail":"补图","imageSources":[["path":frozen]]]
        // 另一实例只收到同一份磁盘记录，未持有发送方的请求、队列或网页回执。
        let reader = AppDelegate()
        reader.hooks.sentImagesDir = app.hooks.sentImagesDir
        var reopened = [ask]
        reader.attachChatImages(&reopened,payload:["agent":agent,"conversationId":cid,"cwd":dir])
        let fromDisk = (reopened.first?["images"] as? [[String:Any]])?.first ?? [:]
        check(str(fromDisk,"path") == path && reader.fullChatImage(fromDisk) == fullImageDataURL(png),
              "发送图片矩阵 \(agent) 新实例仅凭磁盘记录和副本打开原图")
        var rows: [[String:Any]] = [ask,["role":"bot","steps":[step],"retryUser":ask]]
        app.attachChatImages(&rows,payload:["agent":agent,"conversationId":cid,"cwd":dir])
        let supplement = (rows.last?["steps"] as? [[String:Any]])?.first
        for (entry, message) in [("切回和重开",rows.first),("补充回读",supplement),("分段失败重试",rows.last?["retryUser"] as? [String:Any])] {
            let im = (message?["images"] as? [[String:Any]])?.first ?? [:]
            check(int(im,"w") == 1 && app.fullChatImage(im) == fullImageDataURL(png), "发送图片矩阵 \(agent) \(entry) 缩略图与点开同源，实际原图是覆盖图=\(app.fullChatImage(im) == fullImageDataURL(replacement))")
        }
        try! png.write(to:URL(fileURLWithPath:path))
        var legacy: [[String:Any]] = [["role":"user","text":"旧记录","imageSources":[["path":path]]]]
        app.attachChatImages(&legacy,payload:["agent":agent,"conversationId":cid,"cwd":dir])
        let available = (legacy.first?["images"] as? [[String:Any]])?.first ?? [:]
        try! replacement.write(to:URL(fileURLWithPath:path))
        check(app.fullChatImage(available) == fullImageDataURL(png), "发送图片矩阵 \(agent) 只有路径的旧记录在打开后仍保留当时可读的图")
        // 从网页补充的公共入口进入；在 CLI 收到路径和回报已消费之间替换用户文件。
        let req = AskRequest(agent:agent, reqId:8, prompt:"问", model:"", effort:"", permissionMode:"", workspace:dir, conversationId:cid)
        let live = ClaudeLiveTurn(app:app, req:req, command:("/unused",[],false))
        let delivered = DispatchSemaphore(value:0)
        app.hooks.jsSink = { event, payload in
            if event == "onAgentSteer", str(payload,"state") == "sent" { delivered.signal() }
        }
        try! png.write(to:URL(fileURLWithPath:path))
        withTestAsk(app, req.key) {
            app.registerLive(req.key, live)
            app.steer(agent:agent,reqId:req.reqId,text:"补图",images:[path],steerId:"s")
            check(waitSignal(delivered),"\(agent) 图片补充已送达")
            try! replacement.write(to:URL(fileURLWithPath:path))
            live.locked {
                live.handle(line:#"{"type":"user","isReplay":true}"#)
                live.handle(line:#"{"type":"user","isReplay":true}"#)
            }
        }
        live.input.abandon()
        let echo = (live.builder.steps.last?["images"] as? [[String:Any]])?.first ?? [:]
        check(int(echo,"w") == 1 && app.fullChatImage(echo) == fullImageDataURL(png), "发送图片矩阵 \(agent) 补充实时回显宽度=\(int(echo,"w"))")
        app.hooks.jsSink = { _,_ in }
        if agent != "deepseek" {
            var request = AskRequest(agent:agent, reqId:7, prompt:"正文提及 " + path, model:"", effort:"", permissionMode:"", workspace:dir, conversationId:cid)
            request.images = [frozen]
            var single = [["role":"user","text":request.promptWithImagePaths] as [String:Any]]
            app.attachChatImages(&single,payload:["agent":agent,"conversationId":cid,"cwd":dir])
            let attachments = (single[0]["images"] as? [[String:Any]] ?? []).filter { $0["mentioned"] as? Bool != true }
            check(str(single.first,"text") == request.prompt && attachments.count == 1 && app.fullChatImage(attachments[0]) == fullImageDataURL(png), "发送图片矩阵 \(agent) 单次模式重开只认附图，实际附件=\(attachments.count)")
        }
    }
    // 编辑已发图片后再附同一原图：内容没变要得到发送时那份副本（网页据此去重），改过则是另一份；普通文件原样返回。
    try! png.write(to:URL(fileURLWithPath:path))
    let zip = dir + "/资料.zip"
    try! Data("zip".utf8).write(to:URL(fileURLWithPath:zip))
    let sentCopy = app.sentImagePaths([path])?[path]
    func frozenEdit(_ reqId: Int) -> [String] {
        let done = DispatchSemaphore(value:0)
        var paths = [String]()
        app.hooks.jsSink = { event, payload in
            if event == "onFilesDropped", payload["pasteId"] as? Int == reqId { paths = payload["paths"] as? [String] ?? []; done.signal() }
        }
        app.handleChatImageRequest("editChatImages", ["reqId":reqId,"paths":[path,zip],"refs":[],"freeze":true])
        _ = waitSignal(done)
        app.hooks.jsSink = { _,_ in }
        return paths
    }
    let unchanged = frozenEdit(31)
    try! replacement.write(to:URL(fileURLWithPath:path))
    let changed = frozenEdit(32)
    check(sentCopy != nil && unchanged == [sentCopy!,zip] && changed.count == 2 && changed[0] != sentCopy && changed[1] == zip
          && app.isSentImageFile(changed[0]) && app.sentImageOrigin(changed[0]) == path,
          "编辑后再附同一原图：未改得到发送时的副本、改过得到另一份，实际=\(unchanged) \(changed)")
    try! png.write(to:URL(fileURLWithPath:path))
    // 外部 Codex 的提问可直接内嵌 data URL，没有路径或可单独查询的块编号。
    let inline = codexImageSources([["type":"input_image","image_url":"data:image/png;base64," + png.base64EncodedString()]])
    var inlineRows: [[String:Any]] = [["role":"user","text":"内嵌","imageSources":inline]]
    app.attachChatImages(&inlineRows,payload:["agent":"gpt","conversationId":cid,"cwd":dir])
    let inlineImage = (inlineRows[0]["images"] as? [[String:Any]])?.first ?? [:]
    check(app.fullChatImage(inlineImage) == fullImageDataURL(png) && fm.contents(atPath:str(inlineImage,"snapshot")) == png,
          "发送图片矩阵 外部 Codex 内嵌图可以打开和重试，实际有副本=\(inlineImage["snapshot"] != nil)")
    // 服务记录已有附件编号，即使对象暂时读不到，重试也不能退化成纯文字。
    let missingID = "sha256:" + String(repeating:"3",count:64)
    TestHooks.dshAttachmentRoot = dir + "/objects-fixture"
    let missingSource = dshImageSources(["content":[["type":"image","attachment":["attachmentId":missingID]]]])
    var missingRows: [[String:Any]] = [["role":"user","text":"问","imageSources":missingSource]]
    app.attachChatImages(&missingRows,payload:["agent":"deepseek","conversationId":cid,"cwd":dir])
    let missing = (missingRows.first?["images"] as? [[String:Any]])?.first
    check(missing?["missing"] as? Bool == true && str(missing?["ref"] as? [String:Any],"id") == missingID,
          "发送图片矩阵 DeepSeek 缺失的附件仍占原位置，实际附件数=\(missingSource.count)")
    TestHooks.dshAttachmentRoot = nil
    try! png.write(to: URL(fileURLWithPath:path))
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
        // 查看器的「用默认应用打开」交出同一份内容：记录里的图先落成副本，原路径已被覆盖也不受影响。
        try! replacement.write(to: URL(fileURLWithPath: path))
        for source in [["ref": ref], ["ref": ref.merging(["snapshot": frozen]) { $1 }]] as [[String: Any]] {
            var target: URL?
            app.hooks.openURL = { target = $0 }
            _ = app.handleAppAction("openFile", source)
            waitUntil(runLoop: true) { target != nil }
            check(target.map { fm.contents(atPath: $0.path) == png } == true && target?.path != path,
                  "查看器用默认应用打开发送时的那一份，实际=\(target?.path ?? "未打开")")
        }
        app.hooks.openURL = nil
        try! png.write(to: URL(fileURLWithPath: path))
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
        row(["type": "turn_context", "payload": ["turn_id": "image-turn"]]),
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
    eq(recoveredRef["id"], deletedPath + "#0@image-turn", "恢复图片引用原路径、这一回合里第几次发送和回合")
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

/// 夹具里的一行 JSONL：键排好序，同样的内容每次写出来都一样
private func row(_ value: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self) }

/// 纯色测试图：type 是 UTType 标识（png、heic、tiff…）；这台机器写不出这种格式时返回 nil。
func solidImage(_ w: Int, _ h: Int, rgb: (CGFloat, CGFloat, CGFloat), type: String) -> Data? {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let out = NSMutableData()
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
}

private func imageInfo(_ data: Data?) -> (type: String, w: Int, h: Int)? {
    guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    return (type, (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0, (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
}

/// 假 Codex（cold-retry）记下的 turn/start、turn/steer 输入里的本地图片路径。
private func sentLocalImages(_ lines: [String], method: String) -> [String] {
    lines.compactMap { line -> [String]? in
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], obj["method"] as? String == method,
              let input = (obj["params"] as? [String: Any])?["input"] as? [[String: Any]] else { return nil }
        return input.compactMap { $0["type"] as? String == "localImage" ? $0["path"] as? String : nil }
    }.flatMap { $0 }
}

/// Codex 收到的图片、历史里显示的配图、重试带的图片，都要是当时发出去的那一张。
func testCodexSentImages() {
    print("· Codex 图片：HEIC 转 JPEG、历史按那次发送的图、重试带上只剩记录的图")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-codex-images-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let cli = dir + "/codex", log = cli + ".log"
    try! installFakeCLI(at: cli, behavior: "cold-retry")
    let app = AppDelegate()
    app.hooks.jsSink = { _, _ in }
    app.hooks.cliExecutable = cli
    // 转换、还原出来的临时图片放这次测试自己的目录：真实的系统临时目录里不该多出这次测试的图和 .origin
    let realSent = NSTemporaryDirectory() + "aipethub-sent-images/"
    let realBefore = Set((try? fm.contentsOfDirectory(atPath: realSent)) ?? [])
    app.hooks.sentImagesDir = dir + "/aipethub-sent-images/"
    defer {
        let leaked = Set((try? fm.contentsOfDirectory(atPath: realSent)) ?? []).subtracting(realBefore).filter { name in
            let origin = realSent + (name.hasSuffix(".origin") ? name : name + ".origin")
            return ((try? String(contentsOfFile: origin, encoding: .utf8)) ?? "").hasPrefix(dir)
        }
        eq(leaked.count, 0, "CI2 测试转换、还原的临时图片不留在真实的系统临时目录：实际留下 \(leaked.sorted())")
        leaked.forEach { try? fm.removeItem(atPath: realSent + $0) }
    }
    func codexRequest(_ reqId: Int, images: [String]) -> AskRequest {
        var req = AskRequest(agent: "gpt", reqId: reqId, prompt: "这张图是什么颜色", model: "model", effort: "low",
                             permissionMode: "default", workspace: dir, conversationId: "")
        req.images = images
        req.browserTools = false
        return req
    }
    func logLines() -> [String] { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").components(separatedBy: "\n") }

    // (1) HEIC：Codex 只会收到「图片无法处理」的占位文字，发送前要转成 JPEG（CI 机器写不出 HEIC 时用同样要转换的 TIFF）
    let heicData = solidImage(64, 48, rgb: (1, 0, 0), type: "public.heic")
    let photo = dir + (heicData != nil ? "/photo.heic" : "/photo.tiff")
    try! (heicData ?? solidImage(64, 48, rgb: (1, 0, 0), type: "public.tiff")!).write(to: URL(fileURLWithPath: photo))
    let first = codexRequest(731, images: [photo])
    _ = withTestAsk(app, first.key) { app.runCodex(first) }
    let started = sentLocalImages(logLines(), method: "turn/start")
    let startedInfo = imageInfo(started.first.flatMap { fm.contents(atPath: $0) })
    check(started.count == 1 && startedInfo?.type == "public.jpeg" && startedInfo?.w == 64 && startedInfo?.h == 48,
          "CI 首次提问的 \((photo as NSString).pathExtension) 转成 JPEG 再交给 Codex：实际 \(started) \(String(describing: startedInfo))")

    let steerReq = codexRequest(732, images: [])
    let live = CodexLiveTurn(app: app, req: steerReq, codex: cli, model: "model", effort: "low", sandbox: "read-only")
    live.locked {
        live.handle(line: #"{"method":"thread/started","params":{"thread":{"id":"fixture-thread"}}}"#)
        live.handle(line: #"{"method":"turn/started","params":{"turn":{"id":"fixture-turn"}}}"#)
    }
    // 中途补图在主线程上、拿着这一轮的锁进来：转换（一张大照片零点几秒）要放到后台，不能卡住窗口和这一轮的其他事件
    var convertedOnMain = true, lockFreeWhileConverting = false
    let converting = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    app.hooks.codexImageConverting = {
        convertedOnMain = Thread.isMainThread
        let got = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { live.locked {}; got.signal() }
        lockFreeWhileConverting = waitSignal(got)
        converting.signal()
        _ = waitSignal(release)
    }
    let steered = live.locked { live.steer("补一张", images: [photo], id: "ci-steer") }
    release.signal()
    _ = waitSignal(converting)
    app.hooks.codexImageConverting = nil
    check(!convertedOnMain && lockFreeWhileConverting,
          "CI2 中途补图的 HEIC 转换在后台、不占这一轮的锁：实际在主线程 \(convertedOnMain)、转换时锁空着 \(lockFreeWhileConverting)")
    var steerLine = Data()
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { steerLine = live.input.pipe.fileHandleForReading.availableData; read.signal() }
    _ = waitSignal(read)
    let steerPaths = sentLocalImages(String(decoding: steerLine, as: UTF8.self).components(separatedBy: "\n"), method: "turn/steer")
    let steerInfo = imageInfo(steerPaths.first.flatMap { fm.contents(atPath: $0) })
    check(steered && steerPaths.count == 1 && steerInfo?.type == "public.jpeg", "CI 中途补图的 HEIC 也转成 JPEG：实际 \(steerPaths) \(String(describing: steerInfo))")
    live.input.abandon()

    let broken = dir + "/broken.heic"
    try! "不是图片".write(toFile: broken, atomically: true, encoding: .utf8)
    try? fm.removeItem(atPath: log)
    let bad = codexRequest(733, images: [broken])
    let badReply = withTestAsk(app, bad.key) { app.runCodex(bad) }
    check(!fm.fileExists(atPath: log) && badReply.reply.hasPrefix("⚠️") && badReply.reply.contains("broken.heic"),
          "CI 转换失败时发送前就提示、不启动 Codex：实际 \(badReply.reply) / 启动了 \(fm.fileExists(atPath: log))")

    // (2) 同一路径先后发了红图、蓝图，之后文件又被覆盖：每一轮显示当时发出去的那张
    let codexHome = dir + "/codex-home"
    try! fm.createDirectory(atPath: codexHome + "/sessions", withIntermediateDirectories: true)
    app.hooks.codexEnvironment = ["CODEX_HOME": codexHome]
    defer { app.hooks.codexEnvironment = nil }
    let red = solidImage(96, 96, rgb: (1, 0, 0), type: "public.png")!, blue = solidImage(160, 80, rgb: (0, 0, 1), type: "public.png")!
    let shared = dir + "/same.png", cid = UUID().uuidString
    func turn(_ id: String, image: Data, answer: String, path: String) -> [String] {
        [row(["type": "turn_context", "payload": ["turn_id": id]]),
         row(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "<image name=[Image #1] path=\"\(path)\">"],
            ["type": "input_image", "image_url": "data:image/png;base64," + image.base64EncodedString()],
            ["type": "input_text", "text": "</image>"], ["type": "input_text", "text": "什么颜色"]]]]),
         row(["type": "event_msg", "payload": ["type": "item_completed", "turn_id": id, "item": ["type": "UserMessage", "content": [
            ["type": "localImage", "path": path], ["type": "text", "text": "什么颜色"]]]]]),
         row(["type": "event_msg", "payload": ["type": "item_completed", "turn_id": id, "item": ["type": "AgentMessage", "content": [["type": "text", "text": answer]]]]]),
         row(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": id]])]
    }
    let rollout = (turn("turn-red", image: red, answer: "红色", path: shared) + turn("turn-blue", image: blue, answer: "蓝色", path: shared)).joined(separator: "\n") + "\n"
    try! rollout.write(toFile: codexHome + "/sessions/rollout-fixture-\(cid).jsonl", atomically: true, encoding: .utf8)
    func shownSizes() -> [String] {
        var messages = app.codexRolloutTurns(rollout).messages
        app.attachChatImages(&messages, payload: ["agent": "gpt", "conversationId": cid, "cwd": dir])
        return messages.filter { str($0, "role") == "user" }.map { m in
            (m["images"] as? [[String: Any]] ?? []).map { "\(int($0, "w"))x\(int($0, "h"))" }.joined(separator: ",")
        }
    }
    try! solidImage(200, 50, rgb: (0, 1, 0), type: "public.png")!.write(to: URL(fileURLWithPath: shared))
    eq(shownSizes(), ["96x96", "160x80"], "CI 原路径被覆盖后，历史仍按每次发送时的图显示")
    // 原文件还在时照旧带着路径：查看原图的「在访达中显示」、实时那一轮和历史对位、重试都靠它；点开的原图仍是当时那张
    var kept = app.codexRolloutTurns(rollout).messages
    app.attachChatImages(&kept, payload: ["agent": "gpt", "conversationId": cid, "cwd": dir])
    let keptImages = kept.filter { str($0, "role") == "user" }.compactMap { ($0["images"] as? [[String: Any]])?.first }
    eq(keptImages.map { str($0, "path") }, [shared, shared], "CI 原文件还在时历史配图仍带原路径")
    let keptRef = keptImages.first?["ref"] as? [String: Any] ?? [:]
    eq(app.fullChatImage(["path": shared, "ref": keptRef]), fullImageDataURL(red), "CI 带着路径时点开的原图仍是当时发的红图，不是覆盖后的文件")
    try! fm.removeItem(atPath: shared)
    eq(shownSizes(), ["96x96", "160x80"], "CI 原文件移走后，两轮各自恢复当时那张")
    // HEIC 转成的临时 JPEG：历史里显示原来的照片路径和名字，不是临时文件的哈希名
    let heicCid = UUID().uuidString, sentJPEG = started.first ?? ""
    let heicRollout = turn("turn-heic", image: fm.contents(atPath: sentJPEG) ?? Data(), answer: "红色", path: sentJPEG).joined(separator: "\n") + "\n"
    try! heicRollout.write(toFile: codexHome + "/sessions/rollout-fixture-\(heicCid).jsonl", atomically: true, encoding: .utf8)
    var heicMessages = app.codexRolloutTurns(heicRollout).messages
    app.attachChatImages(&heicMessages, payload: ["agent": "gpt", "conversationId": heicCid, "cwd": dir])
    let heicShown = (heicMessages.first { str($0, "role") == "user" }?["images"] as? [[String: Any]])?.first
    check(str(heicShown, "path") == photo && heicShown?["ref"] != nil, "CI 转换过的照片在历史里仍是原路径：实际 \(String(describing: heicShown?["path"]))")
    eq(str(heicShown, "name").isEmpty ? fileBaseName(str(heicShown, "path")) : str(heicShown, "name"), (photo as NSString).lastPathComponent, "CI 转换过的照片在历史里显示原文件名")
    var opened = app.codexRolloutTurns(rollout).messages
    app.attachChatImages(&opened, payload: ["agent": "gpt", "conversationId": cid, "cwd": dir])
    let firstRef = (opened.first?["images"] as? [[String: Any]])?.first?["ref"] as? [String: Any] ?? [:]
    eq(app.fullChatImage(["ref": firstRef]), fullImageDataURL(red), "CI 第一轮点开的原图也是当时的红图")

    // (3) 原文件已经不在、只剩记录里的图：重试带上 ref，原生取回原图交给发送
    try? fm.removeItem(atPath: log)
    var retry = codexRequest(734, images: [])
    let secondPath = dir + "/second.png"
    try! blue.write(to: URL(fileURLWithPath: secondPath))
    retry.images = [secondPath]
    retry.imageRefs = [firstRef.merging(["index": 0]) { _, new in new }]
    let answered = DispatchSemaphore(value: 0)
    var sentPaths = [String:String](), restoredPaths = [String]()
    app.hooks.jsSink = { name, data in
        if name == "onAgentSentImages" {
            sentPaths = data["paths"] as? [String:String] ?? [:]
            restoredPaths = data["restoredPaths"] as? [String] ?? []
        }
        if name == "onAgentResponse" { answered.signal() }
    }
    app.ask(retry)
    check(waitSignal(answered), "CI 带 ref 的重试有回答")
    app.hooks.jsSink = { _, _ in }
    let retried = sentLocalImages(logLines(), method: "turn/start")
    eq(restoredPaths, Array(retried.prefix(1)), "带记录引用重试后，切回按实际恢复的路径认领附件")
    let frozen = sentPaths[secondPath]
    try! red.write(to:URL(fileURLWithPath:secondPath))
    check(frozen.flatMap { fm.contents(atPath:$0) } == blue && retried.contains(frozen ?? ""), "气泡和模型使用同一份发送时的图片，实际快照=\(frozen ?? "无")")
    if let frozen {
        let shown = app.chatImages(sources:[["path":frozen,"data":blue.base64EncodedString(),"ref":"fixture"]], text:"", base:dir).first
        eq(str(shown,"path"), secondPath, "DeepSeek 用路径提交快照后历史仍显示用户选择的文件")
    }
    let retriedInfo = imageInfo(retried.first.flatMap { fm.contents(atPath: $0) })
    check(retried.count == 2 && retried.last.flatMap(app.sentImageOrigin) == secondPath && retriedInfo?.w == 96 && retriedInfo?.h == 96, "CI 重试把只剩 ref 的图还原成文件交给 Codex：实际 \(retried) \(String(describing: retriedInfo))")
}

/// hunt6 longrun 第 1 条：单次模式的历史只有提问里写的路径，系统清掉临时目录后重开仍要看得到当时那张图。
func testOneShotImagesDurable() {
    print("· 单次模式的附图在临时目录清理后仍能从历史打开（Claude、Codex、Gemini）")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-oneshot-images-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let original = dir + "/original.png", cli = dir + "/cli"
    try! png.write(to: URL(fileURLWithPath: original))
    try! installFakeCLI(at: cli, behavior: "backend")
    let temporary = dir + "/tmp/aipethub-sent-images/", durable = dir + "/support/aipethub-sent-images/"
    for (agent, mode) in [("claude", "claude-unsupported"), ("gpt", "codex-unsupported"), ("gemini", "unsupported")] {
        try! mode.write(toFile: dir + "/mode", atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: temporary)
        let app = AppDelegate()
        app.hooks.cliExecutable = cli
        if let key = app.claudePartialCacheKey(cli) { app.partialSupport[key] = true }
        app.hooks.sentImagesDir = temporary; app.hooks.durableSentImagesDir = durable
        app.hooks.geminiCliDir = dir + "/gemini"; app.hooks.codexEnvironment = ["CODEX_HOME": dir + "/codex"]
        let lock = NSLock(), done = DispatchSemaphore(value: 0)
        var prompt: String?
        app.hooks.cliStarted = { _, proc in
            guard let arg = proc.arguments?.first(where: { $0.contains(AskRequest.imagePathHeader) }) else { return }
            lock.lock(); prompt = arg; lock.unlock()
        }
        app.hooks.jsSink = { name, _ in if name == "onAgentResponse" { done.signal() } }
        var req = AskRequest(agent: agent, reqId: 61, prompt: "看图", model: "model", effort: "low",
                             permissionMode: "bypassPermissions", workspace: dir, conversationId: "", browserTools: false)
        req.images = [original]
        app.ask(req)
        check(waitSignal(done), "\(agent)：单次模式答完")
        lock.lock(); let sent = prompt ?? ""; lock.unlock()
        check(!sent.isEmpty, "\(agent)：走了单次模式，提问带着图片路径")
        // 系统清理临时目录；原图被覆盖，历史必须仍是发送时那张
        try? fm.removeItem(atPath: temporary)
        try! Data("changed".utf8).write(to: URL(fileURLWithPath: original))
        let reader = AppDelegate()
        reader.hooks.sentImagesDir = temporary; reader.hooks.durableSentImagesDir = durable
        var rows: [[String: Any]] = [["role": "user", "text": sent]]
        reader.attachChatImages(&rows, payload: ["agent": agent, "conversationId": "fixture", "cwd": dir])
        let image = (rows[0]["images"] as? [[String: Any]])?.first ?? [:]
        eq(str(rows.first, "text"), "看图", "\(agent)：重开后正文不带附件路径")
        check(image["src"] != nil && image["missing"] == nil && reader.fullChatImage(image) == fullImageDataURL(png),
              "\(agent)：清理临时目录后缩略图和原图仍是发送时那张，实际 \(image.keys.sorted())")
        eq(str(image, "path"), original, "\(agent)：仍显示用户选的原文件")
        try! png.write(to: URL(fileURLWithPath: original))
        // CLI 没落盘提问的失败轮：重开按本机记下的路径补回提问，同样要指向持久副本
        let snapshot = app.sentImagePaths([original])?[original] ?? ""
        app.rememberLocalEnding(req.withImages([snapshot]), cid: "ending-" + agent, text: "", outcome: "failed")
        let saved = app.localEndings(agent: agent, cid: "ending-" + agent).last?["images"] as? [String] ?? []
        check(saved.count == 1 && saved[0].hasPrefix(durable) && fm.contents(atPath: saved[0]) == png,
              "\(agent)：本机记下的失败轮附图放在持久目录，实际 \(saved)")
    }
}

/// hunt6 longrun 第 3 条：快照目录写不进去时，原文件还在的旧附件不能显示成「图片已不在」。
func testUnwritableSnapshotDir() {
    print("· 快照目录不可写：只记路径的旧附件仍显示缩略图（四位）")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-readonly-snapshots-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir + "/aipethub-sent-images", withIntermediateDirectories: true)
    defer { chmod(dir + "/aipethub-sent-images", 0o700); try? fm.removeItem(atPath: dir) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let path = dir + "/legacy.png"
    try! png.write(to: URL(fileURLWithPath: path))
    let app = AppDelegate()
    app.hooks.sentImagesDir = dir + "/aipethub-sent-images/"
    for agent in ["claude", "gpt", "gemini", "deepseek"] {
        for name in (try? fm.contentsOfDirectory(atPath: dir + "/aipethub-sent-images")) ?? [] {
            try? fm.removeItem(atPath: dir + "/aipethub-sent-images/" + name)   // 上一位补上的副本
        }
        chmod(dir + "/aipethub-sent-images", 0o500)
        var rows: [[String: Any]] = [["role": "user", "text": "", "imageSources": [["path": path]]]]
        app.attachChatImages(&rows, payload: ["agent": agent, "conversationId": "photo-" + agent, "cwd": dir])
        let image = (rows[0]["images"] as? [[String: Any]])?.first ?? [:]
        check(image["src"] != nil && image["missing"] == nil && image["snapshot"] == nil && str(image, "path") == path
              && app.fullChatImage(image) == fullImageDataURL(png),
              "\(agent)：存不下副本时照样显示原文件，实际 \(image.keys.sorted())")
        chmod(dir + "/aipethub-sent-images", 0o700)
        var again: [[String: Any]] = [["role": "user", "text": "", "imageSources": [["path": path]]]]
        app.attachChatImages(&again, payload: ["agent": agent, "conversationId": "photo-" + agent, "cwd": dir])
        let frozen = (again[0]["images"] as? [[String: Any]])?.first ?? [:]
        check((frozen["snapshot"] as? String).flatMap { fm.contents(atPath: $0) } == png, "\(agent)：目录恢复可写后补上副本")
    }
    try? fm.removeItem(atPath: path)
    var gone: [[String: Any]] = [["role": "user", "text": "", "imageSources": [["path": path]]]]
    app.attachChatImages(&gone, payload: ["agent": "claude", "conversationId": "photo-gone", "cwd": dir])
    check((gone[0]["images"] as? [[String: Any]])?.first?["missing"] as? Bool == true, "原文件不在时仍标为缺图")
}

private extension AskRequest {
    func withImages(_ paths: [String]) -> AskRequest { var copy = self; copy.images = paths; return copy }
}

/// hunt8 reopen 第 2 条：Claude、Gemini 收到的大图是缩过的，重开历史点开原图仍要是发送时的完整分辨率；完整副本不在了才显示缩过的那份。
func testLargeSentImageOriginals() {
    print("· 发送时缩过的大图：重开历史点开原图是完整副本（Claude、Gemini）")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-large-sent-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    // 噪点图压不小：2100×700 的 PNG 超过 3.5 MB，发送时缩成长边 2000 的 JPEG
    let (w, h) = (2100, 700)
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    arc4random_buf(&pixels, pixels.count)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = NSMutableData(), dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    check(CGImageDestinationFinalize(dest), "大图夹具写成 PNG")
    let big = out as Data, original = dir + "/大图.png"
    try! big.write(to: URL(fileURLWithPath: original))
    let app = AppDelegate()
    app.hooks.sentImagesDir = dir + "/aipethub-sent-images/"
    app.hooks.geminiCliDir = dir + "/antigravity-cli"
    let snapshot = app.sentImagePaths([original])?[original] ?? ""
    let sent = app.attachmentData(snapshot)
    let reduced = sent.flatMap { Data(base64Encoded: $0.base64) } ?? Data()
    check(big.count > 3_500_000 && sent?.mime == "image/jpeg" && fullImageDataURL(reduced) != fullImageDataURL(big), "大图发送时缩成 JPEG")
    // 网页查看原图的来源（messages.js 的 sentImageSource）：有副本时并进记录引用
    func viewed(_ im: [String: Any]) -> String? {
        var ref = im["ref"] as? [String: Any] ?? [:]
        if let copy = im["snapshot"] { ref["snapshot"] = copy }
        return app.fullChatImage(["ref": ref])
    }
    func width(_ url: String?) -> Int {
        url.flatMap { $0.split(separator: ",").last }.flatMap { Data(base64Encoded: String($0)) }.flatMap { chatImageData($0, maxPixels: nil) }.map { int($0, "w") } ?? -1
    }
    let uuid = UUID().uuidString, claudeHistory = dir + "/claude.jsonl"
    let line = row(["type": "user", "uuid": uuid, "message": ["role": "user", "content": [
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": sent?.base64 ?? ""]], ["type": "text", "text": "看图"]]]])
    try! (line + "\n").write(toFile: claudeHistory, atomically: true, encoding: .utf8)
    app.claudeCache["large-claude"] = (0, nil, claudeHistory)
    let agyImage = protoField(9, protoText(1, "image/jpeg") + protoText(5, dir + "/gone/uploaded_media.jpg") + protoField(2, reduced))
    let db = app.geminiConversationDb("large-gemini")
    try! fm.createDirectory(atPath: (db as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! Data().write(to: URL(fileURLWithPath: db))
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    let ask = hex(protoField(19, protoText(2, "看图") + agyImage)), answer = hex(protoField(20, protoText(1, "噪点")))
    _ = app.withSQLite(db, readOnly: false) { h in
        sqlite3_exec(h, "CREATE TABLE steps(idx INTEGER, step_type INTEGER, step_payload BLOB); INSERT INTO steps VALUES (0,14,X'\(ask)'),(1,15,X'\(answer)');", nil, nil, nil)
    }
    func reopened(_ agent: String, _ cid: String) -> [String: Any] {
        var messages = agent == "claude" ? app.claudeTurns(Data(line.utf8)).0 : app.readGeminiConversation(cid: cid)["messages"] as? [[String: Any]] ?? []
        app.attachChatImages(&messages, payload: ["agent": agent, "conversationId": cid, "cwd": dir])
        return (messages.first { str($0, "role") == "user" }?["images"] as? [[String: Any]])?.first ?? [:]
    }
    for (agent, cid) in [("claude", "large-claude"), ("gemini", "large-gemini")] {
        let full = viewed(reopened(agent, cid))
        check(full == fullImageDataURL(big), "\(agent)：重开后点开原图是发送时的完整副本，实际宽 \(width(full))")
    }
    try? fm.removeItem(atPath: snapshot)
    for (agent, cid) in [("claude", "large-claude"), ("gemini", "large-gemini")] {
        let im = reopened(agent, cid), full = viewed(im)
        check(im["snapshot"] == nil && full == fullImageDataURL(reduced), "\(agent)：完整副本不在了照旧显示记录里缩过的那份，实际宽 \(width(full))")
    }
}

/// CI2：Codex 历史配图只在原文件发送后被覆盖、或已不在时才去读 rollout；thread/revert 分段之后每一轮仍对上当时发的那张。
func testCodexImageRecords() {
    print("· Codex 历史配图：原文件没改过不读 rollout，分段后按回合找当时那张")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-codex-records-" + UUID().uuidString
    let home = dir + "/codex-home", day = home + "/sessions/2026/11/18"
    try! fm.createDirectory(atPath: day, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let app = AppDelegate()
    app.hooks.jsSink = { _, _ in }
    app.hooks.codexEnvironment = ["CODEX_HOME": home]
    var reads = 0
    app.hooks.codexRolloutImagesRead = { reads += 1 }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let sentAt = Date().addingTimeInterval(30), stamp = iso.string(from: sentAt)   // 发送在写好文件之后
    // 和真实 Codex 一样：回合开头的 turn_context、带着原图的 response_item、投影用的 item_completed
    func turn(_ id: String, image: Data, path: String, stamp: String = stamp) -> [String] {
        [row(["timestamp": stamp, "type": "turn_context", "payload": ["turn_id": id]]),
         row(["timestamp": stamp, "type": "response_item", "payload": ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "<image name=[Image #1] path=\"\(path)\">"],
            ["type": "input_image", "image_url": "data:image/png;base64," + image.base64EncodedString()],
            ["type": "input_text", "text": "</image>"], ["type": "input_text", "text": "什么颜色"]]]]),
         row(["timestamp": stamp, "type": "event_msg", "payload": ["type": "item_completed", "turn_id": id, "item": ["type": "UserMessage", "content": [
            ["type": "localImage", "path": path], ["type": "text", "text": "什么颜色"]]]]]),
         row(["timestamp": stamp, "type": "event_msg", "payload": ["type": "item_completed", "turn_id": id, "item": ["type": "AgentMessage", "content": [["type": "text", "text": "答"]]]]]),
         row(["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": id]])]
    }
    func lines(_ rows: [String]) -> String { rows.joined(separator: "\n") + "\n" }
    func shown(_ content: String, cid: String) -> [[String: Any]] {
        var messages = app.codexRolloutTurns(content).messages
        app.attachChatImages(&messages, payload: ["agent": "gpt", "conversationId": cid, "cwd": dir])
        return messages.filter { str($0, "role") == "user" }.compactMap { ($0["images"] as? [[String: Any]])?.first }
    }
    func sizes(_ images: [[String: Any]]) -> [String] { images.map { "\(int($0, "w"))x\(int($0, "h"))" } }
    let red = solidImage(96, 96, rgb: (1, 0, 0), type: "public.png")!, blue = solidImage(160, 80, rgb: (0, 0, 1), type: "public.png")!
    let green = solidImage(200, 50, rgb: (0, 1, 0), type: "public.png")!, yellow = solidImage(50, 50, rgb: (1, 1, 0), type: "public.png")!
    let shared = dir + "/same.png", cid = UUID().uuidString.lowercased()
    try! red.write(to: URL(fileURLWithPath: shared))

    // (1) 原文件还在、发送之后没改过：直接用文件，不读整份 rollout（几十 MB 的记录每次打开、同步都要零点几秒）
    let rollout = lines(turn("turn-red", image: red, path: shared))
    try! rollout.write(toFile: day + "/rollout-2026-11-18T00-00-00-\(cid).jsonl", atomically: true, encoding: .utf8)
    var images = shown(rollout, cid: cid)
    eq(reads, 0, "CI2 原文件还在、发送后没改过：打开历史不读 rollout")
    check(str(images.first, "path") == shared && images.first?["ref"] != nil && sizes(images) == ["96x96"],
          "CI2 没改过的原文件直接当配图：实际 \(sizes(images)) path=\(str(images.first, "path")) ref=\(String(describing: images.first?["ref"]))")

    // 编辑可能过很久才按发送；即使打开编辑器时文件仍可校验，也必须交付稳定的字节。
    let editRef = images[0]["ref"] as? [String:Any] ?? [:]
    app.hooks.sentImagesDir = dir + "/aipethub-sent-images/"
    let editPath = app.restoredImagePath(editRef) ?? ""
    // (2) 发送之后同一路径被覆盖：去记录里取当时那张，仍带原路径（在访达中显示、对位），并标出文件已改过（重试按 ref 发当时那张）
    try! green.write(to: URL(fileURLWithPath: shared))
    try! fm.setAttributes([.modificationDate: sentAt.addingTimeInterval(60)], ofItemAtPath: shared)
    check(fm.contents(atPath:editPath) == red, "发送图片矩阵 Codex 打开编辑后覆盖原图：附件仍为红图，实际尺寸 \(String(describing:imageInfo(fm.contents(atPath:editPath))))")
    let opened = images[0], openedRef = opened["ref"] as? [String: Any] ?? [:]
    check(app.fullChatImage(opened) == fullImageDataURL(red), "B2-02 打开历史后覆盖文件，点开仍见红图")
    app.hooks.sentImagesDir = dir + "/aipethub-sent-images/"
    let restored = app.restoredImagePath(openedRef) ?? ""
    check(fm.contents(atPath: restored) == red, "B2-02 重试还原当时的红图，实际路径 \(restored)")
    let copyRollout = lines(turn("retry", image: red, path: restored, stamp: iso.string(from: sentAt.addingTimeInterval(120))))
    eq(sizes(shown(copyRollout, cid: cid)), ["96x96"], "B2-02 重开重试记录时按发送副本取缩略图")
    images = shown(rollout, cid: cid)
    check(sizes(images) == ["96x96"] && str(images.first, "path") == shared && images.first?["ref"] != nil && images.first?["changed"] as? Bool == true,
          "CI2 发送后被覆盖：显示当时的红图、带原路径和 ref、标出改过：实际 \(sizes(images)) changed=\(String(describing: images.first?["changed"]))")
    eq(reads, 1, "CI2 被覆盖时才读 rollout")

    // (2b) 用 mv（或访达拷贝替换、cp -p）换进一个修改时间更早的同名文件：修改时间跟着源文件、早于发送，只有 ctime 是换进来的时刻。
    // 发送时间取一分钟前，换进来的 ctime 才晚得过它；只看修改时间会把绿图当成没改过、重试也发绿图
    let movedPath = dir + "/moved.png", movedCid = UUID().uuidString.lowercased(), staged = dir + "/staged.png"
    let movedRollout = lines(turn("turn-moved", image: red, path: movedPath, stamp: iso.string(from: Date().addingTimeInterval(-60))))
    try! movedRollout.write(toFile: day + "/rollout-2026-11-18T00-00-30-\(movedCid).jsonl", atomically: true, encoding: .utf8)
    try! green.write(to: URL(fileURLWithPath: staged))
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: staged)
    check(rename(staged, movedPath) == 0, "CI2 mv 换进旧文件")
    reads = 0
    images = shown(movedRollout, cid: movedCid)
    check(sizes(images) == ["96x96"] && images.first?["ref"] != nil && images.first?["changed"] as? Bool == true,
          "CI2 mv 换进修改时间更早的文件：仍显示当时的红图、带 ref、标出改过：实际 \(sizes(images)) changed=\(String(describing: images.first?["changed"]))")
    eq(reads, 1, "CI2 mv 换进的文件也去读 rollout")

    let near = dir + "/near.png", nearId = UUID().uuidString.lowercased()
    try! green.write(to: URL(fileURLWithPath: near))
    let nearRows = lines(turn("same-second", image:red, path:near, stamp:iso.string(from:Date().addingTimeInterval(-0.35))))
    try! nearRows.write(toFile:day + "/rollout-fixture-\(nearId).jsonl", atomically:true, encoding:.utf8)
    eq(sizes(shown(nearRows,cid:nearId)), ["96x96"], "发送图片矩阵 外部 Codex 在同一秒内覆盖原路径")

    // (3) thread/revert 之后 rollout_path 指向新的一段（只有回滚点之后的回合），数据库投影仍从第一轮算起：
    // 旧回合 A 发的红图在旧的一段里，被回滚掉的 X 发过黄图，新回合 B 发的蓝图在新的一段里
    let segCid = UUID().uuidString.lowercased(), segment = day + "/rollout-2026-11-18T00-01-00-\(segCid)_\(UUID().uuidString.lowercased()).jsonl"
    let meta = row(["type": "session_meta", "payload": ["id": segCid, "source": "vscode", "cwd": dir]])
    try! lines([meta] + turn("turn-a", image: red, path: shared) + turn("turn-x", image: yellow, path: shared))
        .write(toFile: day + "/rollout-2026-11-18T00-00-00-\(segCid).jsonl", atomically: true, encoding: .utf8)
    let based = row(["type": "session_meta", "payload": ["id": segCid, "source": "vscode", "cwd": dir,
                                                       "history_base": ["thread_id": segCid, "end_ordinal_exclusive": 6]]])
    try! lines([based] + turn("turn-b", image: blue, path: shared)).write(toFile: segment, atomically: true, encoding: .utf8)
    var db: OpaquePointer?
    sqlite3_open(home + "/state_5.sqlite", &db)
    sqlite3_exec(db, "CREATE TABLE threads(id TEXT, rollout_path TEXT); INSERT INTO threads VALUES('\(segCid)', '\(segment)');", nil, nil, nil)
    sqlite3_close(db)
    let projected = lines(turn("turn-a", image: red, path: shared) + turn("turn-b", image: blue, path: shared))
    reads = 0
    images = shown(projected, cid: segCid)
    eq(sizes(images), ["96x96", "160x80"], "CI2 revert 分段后被覆盖：第一轮仍是当时的红图、新一轮是蓝图，不把新一段的图对到旧回合上")
    let firstRef = images.first?["ref"] as? [String: Any] ?? [:]
    eq(app.fullChatImage(["path": shared, "ref": firstRef]), fullImageDataURL(red), "CI2 分段后第一轮点开的原图也是当时的红图")
    eq(reads, 1, "CI2 打开历史读一次记录，点开原图用缓存里取好的那张，不再整份重读")
}
