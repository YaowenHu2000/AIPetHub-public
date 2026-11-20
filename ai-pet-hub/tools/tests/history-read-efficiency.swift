// 完整投影不应重新解压；搜索只需要图片标签，不能为了确认文字生成缩略图。
import Cocoa

func testHistoryReadEfficiency() {
    print("· 历史读取：压缩投影、UTF-8 分行与搜索图片标签")
    let app = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-history-efficiency-" + UUID().uuidString
    app.hooks.sentImagesDir = root + "/aipethub-sent-images/"
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { TestHooks.chatThumbnailRequested = nil; try? fm.removeItem(atPath: root) }
    let packed = root + "/rollout.jsonl.zst", cli = root + "/zstd"
    let question = #"{"type":"event_msg","payload":{"type":"user_message","message":"中文👩🏽‍💻é"}}"#
    let answer = #"{"type":"event_msg","payload":{"type":"agent_message","message":"完整回答"}}"#
    let content = question + "\n\n" + answer + "\n"
    try! "packed".write(toFile: packed, atomically: true, encoding: .utf8)
    try! content.write(toFile: packed + ".plain", atomically: true, encoding: .utf8)
    try! "Decompressed Size: 1 KiB (\(content.utf8.count) B)\n".write(toFile: packed + ".info", atomically: true, encoding: .utf8)
    try! installFakeCLI(at: cli, behavior: "zstd-read")
    app.hooks.cliExecutable = cli
    var projection = CodexStoredHistory()
    projection.byteOffset = Int64(content.utf8.count); projection.nextOrdinal = 3
    let complete = app.codexProjectionTail(path: packed, projection: projection)
    check(complete.tail == nil && complete.error == nil, "完整压缩投影直接使用数据库")
    eq((try? String(contentsOfFile: cli + ".calls", encoding: .utf8)) ?? "", "-lv\n", "完整压缩投影只查长度，不调用解压")
    projection.byteOffset = Int64(question.utf8.count + 1); projection.nextOrdinal = 1
    let newer = app.codexProjectionTail(path: packed, projection: projection)
    eq(newer.tail?.content, content, "压缩投影落后仍解压完整内容以配对镜像")
    eq(newer.tail?.ordinal, 1, "空行仍占原来的 rollout ordinal")
    let events = app.rolloutEvents(content).events
    eq(events.map(\.ordinal), [0, 2], "UTF-8 分行保留空行序号")
    eq(app.codexRolloutTurns(content).messages.map { str($0, "text") }, ["中文👩🏽‍💻é", "完整回答"], "多字节和组合字符逐字保留")
    try! "Decompressed Size: Unknown\n".write(toFile: packed + ".info", atomically: true, encoding: .utf8)
    projection.byteOffset = Int64(content.utf8.count)
    check(app.codexProjectionTail(path: packed, projection: projection).tail != nil, "未知解压长度仍按 ordinal 确认尾部")
    try! fm.removeItem(atPath: packed + ".info")
    check(app.codexProjectionTail(path: packed, projection: projection).tail != nil, "长度探测失败仍解压确认，不能漏尾部")

    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let image = root + "/label-needle.png", history = root + "/history.jsonl"
    try! png.write(to: URL(fileURLWithPath: image))
    let row: [String: Any] = ["type": "user", "message": ["content": image]]
    try! (try! JSONSerialization.data(withJSONObject: row)).write(to: URL(fileURLWithPath: history))
    var thumbnails = 0
    TestHooks.chatThumbnailRequested = { thumbnails += 1 }
    let done = DispatchSemaphore(value: 0)
    var hits: [String] = []
    app.hooks.jsSink = { name, payload in
        if name == "onConversationsSearched", payload["complete"] as? Bool == true {
            hits = payload["ids"] as? [String] ?? []; done.signal()
        }
    }
    app.searchConversations(agent: "claude", query: "label-needle", files: [("labels", history)])
    check(waitSignal(done), "图片标签搜索返回")
    eq(hits, ["labels"], "去掉临时图片路径后仍能搜索短标签")
    eq(thumbnails, 0, "搜索不请求缩略图，包括已有缓存的图片")
    app.hooks.jsSink = nil
    TestHooks.chatThumbnailRequested = nil
    let large = root + "/large.png", broken = root + "/broken.png", link = root + "/link.png", truncated = root + "/truncated.png"
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 700, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let largePNG = bitmap.representation(using: .png, properties: [:])!
    try! largePNG.write(to: URL(fileURLWithPath: large))
    try! largePNG.prefix(40).write(to: URL(fileURLWithPath: truncated))
    try! "broken".write(toFile: broken, atomically: true, encoding: .utf8)
    try! fm.createSymbolicLink(atPath: link, withDestinationPath: image)
    let originals: [[String: Any]] = [
        ["role": "user", "text": image + " " + broken, "imageSources": [["path": image], ["path": image], ["path": root + "/gone.png"], ["path": truncated]]],
        ["role": "bot", "steps": [["kind": "user", "detail": link + " " + large, "imageSources": [["data": png.base64EncodedString(), "ref": "embedded"], ["data": "broken"]]]]],
        ["role": "user", "text": "", "imageSources": Array(repeating: ["data": png.base64EncodedString()], count: 14)]
    ]
    let payload: [String: Any] = ["agent": "claude", "conversationId": "labels", "cwd": root]
    var opened = originals, labels = originals
    app.attachChatImages(&opened, payload: payload)
    thumbnails = 0; TestHooks.chatThumbnailRequested = { thumbnails += 1 }
    app.attachChatImages(&labels, payload: payload, labelsOnly: true)
    eq(thumbnails, 0, "大图、内嵌图、损坏图和软链接的标签检查均不请求缩略图")
    let renderer = ConversationSearchText(app: app)
    eq(renderer.messages(labels), renderer.messages(opened), "图片去重、上限、缺失标签和补充消息与打开会话逐字一致")
    let labelImages = labels.flatMap { message in
        (message["images"] as? [[String: Any]] ?? []) + (message["steps"] as? [[String: Any]] ?? []).flatMap { $0["images"] as? [[String: Any]] ?? [] }
    }
    check(labelImages.allSatisfy { $0["src"] == nil && $0["w"] == nil && $0["h"] == nil }, "搜索的图片信息不生成像素、编码或尺寸载荷")
    // 原路径失效但 rollout 仍有图片时，搜索不能凭文件不存在就多报一条缺图文字。
    app.hooks.codexEnvironment = ["CODEX_HOME": root]
    let cid = UUID().uuidString, missing = root + "/recovered.png"
    try! fm.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
    let recovery: [String: Any] = ["type": "response_item", "payload": ["role": "user", "content": [
        ["type": "input_text", "text": "<image path=\"\(missing)\">"], ["type": "input_image", "image_url": "data:image/png;base64," + png.base64EncodedString()]
    ]]]
    try! (try! JSONSerialization.data(withJSONObject: recovery) + Data([0x0A])).write(to: URL(fileURLWithPath: root + "/sessions/rollout-fixture-" + cid + ".jsonl"))
    var recovered: [[String: Any]] = [["role": "user", "text": "", "imageSources": [["path": missing]]]]
    app.attachChatImages(&recovered, payload: ["agent": "gpt", "conversationId": cid], labelsOnly: true)
    eq(renderer.messages(recovered), [""], "从 rollout 恢复的图片不会被误报为缺失")
    eq(thumbnails, 0, "从 rollout 恢复图片标签也不生成缩略图")

    // 四位的命令输出都经 clip 截到 maxOutput；历史里的输出来自 JSONSerialization（桥接的 NSString），
    // 先数完整段长度会让长会话每次打开都慢上数秒。用同一段内容数一遍长度作参照，负载高时两边一起变慢。
    let clipLine = "2026-11-20 12:00:00 INFO 测试输出 é 👩🏽‍💻\n"
    func bridged(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["c": s])
        return (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["c"] as! String
    }
    let hugeOutput = String(repeating: clipLine, count: 120_000)
    let countCopy = bridged(hugeOutput), clipCopy = bridged(hugeOutput)
    var started = Date()
    _ = countCopy.count
    let countTime = Date().timeIntervalSince(started)
    started = Date()
    let clipped = clip(clipCopy, maxOutput)
    let clipTime = Date().timeIntervalSince(started)
    check(clipTime * 10 < countTime, "截取长输出不先数完整段（截取 \(clipTime) 秒，数一遍 \(countTime) 秒）")
    eq(clipped, String(hugeOutput.prefix(maxOutput)) + "…", "长输出截取结果不变")
    let edge = "ab👩🏽‍💻é"
    eq([0, 1, 3, 4, 5].map { clip(edge, $0) }, ["…", "a…", "ab👩🏽‍💻…", edge, edge], "按字符截取的边界不变：刚好等长不加省略号")
    eq(clip("", 0), "", "空串不加省略号")
}
