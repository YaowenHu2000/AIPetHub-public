// DeepSeek Harness（dsh）的会话事件 → 界面上的工作步骤。回答进行中（网页模式的事件流）和读历史会话用的是同一种事件，共用这一个解析器。
// 事件长什么样见 DeepSeekServer.swift 开头；实测录下的一轮在 tools/fixtures/dsh-turn.jsonl，由 tools/tests/event-parsers.swift 读。
//
// 实时与历史都由 `DshParser.finishedTurn` 解释同一组结束事件，未知结束原因保留为未完成。
// 没有结束事件的一轮按本机记下的结束时刻算工作时长。
import Foundation

/// 一轮回答的解析：把事件一条条喂进来，步骤记进 TurnBuilder。
final class DshParser {
    let turn: TurnBuilder
    /// 这一轮里最后一段正文（最后一条带文字的 assistant/message）：就是正式回答
    private(set) var response = ""
    /// 这一轮怎么结束的（turn/end 的 reason）：kind = completed / error / aborted / max-tokens …
    private(set) var ended: (kind: String, message: String, code: String)?
    private(set) var started = false
    /// 模型那边报的错（finish 的 reason 是 error 时）：turn/end 没来的话用它
    private(set) var failure = ""

    private var texts: [String: String] = [:]
    private var pendingText = Set<String>()
    private var lastPush: [String: Date] = [:]
    private var streamed = Set<String>()                       // 有流式增量的「轮.步」：它的 assistant/message 不用再补一遍
    private var calls: [String: (kind: String, path: String, diffs: [[String: Any]])] = [:]

    init(turn: TurnBuilder) { self.turn = turn }

    /// 这一轮结束了，但还有一句中途补充的话没被它看到：它会接着再开一轮来处理，当成同一次回答继续等。
    func reopen() { ended = nil }

    func feed(_ event: [String: Any], view: [String: Any]? = nil) {
        let data = event["data"] as? [String: Any] ?? [:]
        let at = "\(data["turn"] ?? 0).\(data["step"] ?? 0)"
        switch event["type"] as? String {
        case "turn/start":
            started = true
        case "compaction/start", "compaction/summary", "compaction/end":
            guard let id = data["compactionId"] as? String else { return }
            let key = "compact:" + id
            if event["type"] as? String == "compaction/start", data["turn"] is Int {
                turn.add(makeStep("tool", "压缩上下文", status: "running"), key: key)
            } else if turn.step(key) != nil {
                if let summary = data["summary"] as? String { turn.update(key, ["detail":clip(summary, maxDetail)]) }
                if event["type"] as? String == "compaction/end" {
                    turn.update(key, ["status":data["error"] == nil ? "ok" : "error"])
                }
            }
        case "assistant/chunk":
            chunk(data["chunk"] as? [String: Any] ?? [:], at: at)
        case "assistant/message":
            message((data["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? [], at: at)
        case "tool/call":
            toolCall(data, view: (view?["view"] as? [String: Any]) ?? [:])
        case "tool/result":
            toolResult(data, view: (view?["view"] as? [String: Any]) ?? [:])
        case "turn/end":
            let reason = data["reason"] as? [String: Any] ?? [:]
            let err = reason["error"] as? [String: Any] ?? [:]
            ended = (reason["kind"] as? String ?? "completed", err["message"] as? String ?? "", "\(err["code"] ?? "")")
        default:
            break   // 请求头、标题、用量投影、审批记录等：不是工作步骤
        }
    }

    // MARK: 流式增量

    private func chunk(_ c: [String: Any], at: String) {
        let key = "\(at).\(c["index"] ?? 0)"
        switch c["type"] as? String {
        case "block-start":
            streamed.insert(at)
            if c["blockType"] as? String == "reasoning" { turn.add(makeStep("think", "思考", status: "running"), key: "r" + key) }
        case "reasoning-delta":
            texts["r" + key, default: ""] += c["text"] as? String ?? ""
            push("r" + key, kind: "think", final: false)
        case "text-delta":
            response = ""   // 新正文尚未定稿时，上一条定稿不能盖过本段。
            texts["t" + key, default: ""] += c["text"] as? String ?? ""
            push("t" + key, kind: "text", final: false)
        case "block-end":
            let block = c["block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "reasoning":
                texts["r" + key] = block["text"] as? String ?? texts["r" + key] ?? ""
                push("r" + key, kind: "think", final: true)
                if turn.step("r" + key) != nil { turn.update("r" + key, ["status": "ok"]) }   // 没有内容的思考：也收尾
            case "text":
                texts["t" + key] = block["text"] as? String ?? texts["t" + key] ?? ""
                push("t" + key, kind: "text", final: true)
            default:
                break   // 工具调用的参数：等 tool/call 一次给全
            }
        case "finish":
            let reason = c["reason"] as? [String: Any] ?? [:]
            if reason["kind"] as? String == "error" { failure = (reason["failure"] as? [String: Any])?["message"] as? String ?? "模型请求失败" }
        default:
            break
        }
    }

    /// 正在写的思考 / 正文：隔一小会儿推一次（每个字都推的话界面忙不过来）。
    private func push(_ key: String, kind: String, final: Bool) {
        let text = trimmed(texts[key])
        guard !text.isEmpty else { return }
        let now = TestHooks.dshPushNow?() ?? Date()
        if !final, let t = lastPush[key], now.timeIntervalSince(t) < textPushInterval {
            pendingText.insert(key)
            return
        }
        pendingText.remove(key)
        lastPush[key] = now
        let status = final ? "ok" : "running"
        if turn.step(key) == nil { turn.add(makeStep(kind, kind == "think" ? "思考" : "说明", detail: text, status: status), key: key) }
        else { turn.update(key, ["detail": kind == "text" ? text : clip(text, maxDetail), "status": status]) }
    }

    /// 中断后可能没有 block-end；在构造最终回答前补齐节流期间积累的字，状态仍交给回合结局决定。
    func flushPendingText() {
        for key in pendingText {
            let text = trimmed(texts[key])
            turn.update(key, ["detail": key.hasPrefix("t") ? text : clip(text, maxDetail)])
        }
        pendingText.removeAll()
    }

    /// 实时和回放消费的是同一种事件。先刷新最后一块正文，再用同一条结束记录决定原因和结局。
    func finishedTurn(stopped: Bool = false, problem: String? = nil, refused: Bool = false,
                      local: [String:Any]? = nil, expectsAnswer: Bool = true) -> [String:Any] {
        flushPendingText()
        var text = response.isEmpty ? trimmed(turn.steps.last { $0["kind"] as? String == "text" }?["detail"] as? String) : response
        var outcome: String
        var reason: String?
        switch ended?.kind {
        case _ where stopped, "aborted", "interrupted": outcome = "interrupted"
        case "completed": outcome = "completed"
        case "max-tokens": outcome = "failed"; reason = dshMaxTokensHint
        case "blocked": outcome = "failed"; reason = ended?.message.isEmpty == false ? ended?.message : "DeepSeek 阻止了本轮继续执行（blocked）。"
        case "error": outcome = "failed"; reason = dshReadableError(trimmed(ended?.message).isEmpty ? failure : trimmed(ended?.message), code:ended?.code ?? "")
        case nil where problem != nil || !failure.isEmpty:
            outcome = "failed"; reason = problem ?? dshReadableError(failure, code:"")
        default:
            outcome = "incomplete"
            if let kind = ended?.kind { reason = "这一轮提前结束了（\(kind)）。" }
        }
        var endingReqId: Int?
        // 服务重启可能合成中断。只准同一调用的本机结局补上缺口，后续写全的成功仍以服务为准。
        if let local, outcome == "incomplete" || outcome == "interrupted" {
            outcome = local["outcome"] as? String ?? "failed"
            reason = local["reason"] as? String
            endingReqId = local["reqId"] as? Int
            text = restoredEndingText(recorded:text, saved:trimmed(local["text"] as? String))
        }
        var includeEnding = true
        if text.isEmpty {
            if let reason, outcome == "failed" || outcome == "incomplete" {
                text = turn.isEmpty ? "⚠️ DeepSeek 出错：\(reason)" : "⚠️ DeepSeek 中途出错，这次没有做完：\(reason)\n\n会话和已经做完的步骤都还在：可以点「重试」，或者发一句「继续」让它接着做。"
                includeEnding = false
            } else if outcome == "completed" {
                if refused { text = "你没有同意它要做的操作，它就停在这里了。想让它换个做法，直接告诉它。" }
                else if expectsAnswer && turn.isEmpty { text = "⚠️ DeepSeek 这一轮没有给出任何内容。"; outcome = "failed"; includeEnding = false }
            }
        }
        var bot = turn.finish(finalText:text, outcome:outcome, error:reason, includeEnding:includeEnding)
        bot["endingReqId"] = endingReqId
        return bot
    }

    /// 这一步定稿的助手消息。正文记成「目前为止的正式回答」；读历史时没有流式增量，思考和说明从这里补。
    private func message(_ content: [[String: Any]], at: String) {
        let text = trimmed(content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        if !text.isEmpty { response = text }
        guard !streamed.contains(at) else { return }
        for (i, block) in content.enumerated() {
            let body = trimmed(block["text"] as? String)
            guard !body.isEmpty else { continue }
            switch block["type"] as? String {
            case "reasoning": turn.add(makeStep("think", "思考", detail: body), key: "r\(at).\(i)")
            case "text": turn.add(makeStep("text", "说明", detail: body), key: "t\(at).\(i)")
            default: break
            }
        }
    }

    // MARK: 工具

    private func toolCall(_ data: [String: Any], view: [String: Any]) {
        let id = data["callId"] as? String ?? UUID().uuidString
        let name = data["name"] as? String ?? "tool"
        let args = (data["arguments"] as? String).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let diffs = view["diffs"] as? [[String: Any]] ?? []
        var step = dshToolStep(name: name, args: args, view: view)
        step["status"] = "running"
        calls[id] = (step["kind"] as? String ?? "tool", step["path"] as? String ?? "", diffs)
        if turn.step(id) == nil { turn.add(step, key: id) } else { turn.update(id, step) }
    }

    private func toolResult(_ data: [String: Any], view: [String: Any]) {
        let msg = data["message"] as? [String: Any] ?? [:]
        let part = (msg["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "tool-result" } ?? [:]
        let id = (msg["source"] as? [String: Any])?["callId"] as? String ?? part["toolCallId"] as? String ?? ""
        guard turn.step(id) != nil else { return }
        let failed = part["isError"] as? Bool ?? false
        // 用户停止时 dsh 给运行中的工具回 isError 加结构化的 ABORTED（文字只是 Error: tool call aborted）；
        // 按中断记，重开历史才和实时看到的一样，不会把被停下的命令标成失败。
        let aborted = failed && (data["error"] as? [String: Any])?["code"] as? String == "ABORTED"
        let output = trimmed((view["output"] as? String) ?? textOf(part["content"]))
        var fields: [String: Any] = ["status": aborted ? "interrupted" : (failed ? "error" : "ok")]
        let call = calls[id]
        if call?.kind == "command" || failed {
            if !output.isEmpty, output != "(no output)" { fields["output"] = clip(output, maxOutput) }
        }
        turn.update(id, fields)
        // 改成了的文件进「改动」卡片；改了哪里用工具报的新旧文字算
        if !failed, let c = call, ["edit", "write"].contains(c.kind) {
            let diffs = c.diffs.isEmpty ? ((data["meta"] as? [String: Any])?["diffs"] as? [[String: Any]] ?? []) : c.diffs
            if diffs.isEmpty, !c.path.isEmpty { turn.addFile(c.path, kind: c.kind == "write" ? "create" : "edit") }
            for d in diffs {
                let old = d["oldText"] as? String ?? "", new = d["newText"] as? String ?? ""
                turn.addFile(d["path"] as? String ?? c.path, kind: c.kind == "write" && old.isEmpty ? "create" : "edit", diff: simpleDiff(old: old, new: new))
            }
        }
    }
}

/// 一次工具调用 → 界面上的一步。工具名随 dsh 的预设会变，所以名字认不出时再看它给界面准备的卡片种类（view.card）。
func dshToolStep(name: String, args: [String: Any], view: [String: Any]) -> [String: Any] {
    let lower = name.lowercased(), card = view["card"] as? String ?? ""
    let path = (args["path"] as? String) ?? (args["file_path"] as? String) ?? (args["filePath"] as? String)
        ?? ((view["locations"] as? [[String: Any]])?.first?["path"] as? String) ?? ""
    let describe = trimmed((args["description"] as? String) ?? (view["description"] as? String))
    if lower == "bash" || lower == "pwsh" || lower.contains("shell") || card == "terminal" {
        return makeStep("command", describe.isEmpty ? "运行命令" : describe, detail: (args["command"] as? String) ?? (view["title"] as? String))
    }
    if lower.contains("todo") {
        let items = (args["todos"] as? [[String: Any]]) ?? (args["items"] as? [[String: Any]]) ?? []
        let lines = items.map { t -> String in
            let st = t["status"] as? String ?? ""
            return (st == "completed" ? "☑ " : (st == "in_progress" ? "▸ " : "☐ ")) + ((t["content"] as? String) ?? (t["text"] as? String) ?? "")
        }
        return makeStep("todo", "更新计划", detail: lines.joined(separator: "\n"))
    }
    if lower.contains("search") && (lower.contains("web") || args["query"] != nil) && !lower.contains("file") {
        return makeStep("web", "联网搜索 \((args["query"] as? String) ?? "")")
    }
    if lower.contains("fetch") || lower.contains("web") || args["url"] != nil { return makeStep("web", "读取网页", detail: args["url"] as? String) }
    if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || lower.contains("find") {
        return makeStep("search", "搜索 \((args["pattern"] as? String) ?? (args["query"] as? String) ?? "")", path: path)
    }
    if lower == "ls" || lower.contains("list") { return makeStep("list", "列出 \(fileBaseName(path))", path: path) }
    if lower == "write" || lower.contains("create") { return makeStep("write", "写入 \(fileBaseName(path))", path: path) }
    if lower.contains("edit") || lower.contains("replace") || card == "diff" { return makeStep("edit", "修改 \(fileBaseName(path))", path: path) }
    if lower == "read" || lower.contains("read") || card == "read" { return makeStep("read", "读取 \(fileBaseName(path))", path: path) }
    if lower.contains("subagent") || lower.contains("agent") { return makeStep("agent", describe.isEmpty ? "子智能体" : describe, detail: args["prompt"] as? String) }
    return makeStep("tool", "调用 \(name)", detail: describe.isEmpty ? (view["title"] as? String) : describe, path: path)
}

/// 中途补充的话发出去时调用编号的开头：读历史时靠它认出「这句是插在一轮中间的」。
let dshSteerPrefix = "aph-steer-"

/// 用户消息里的文字（图片等别的块不算）。
func dshUserText(_ data: [String: Any]) -> String {
    trimmed((data["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n"))
}

/// 调用编号由 App 生成，快照与原文件分开保存，覆盖同名截图后重试仍能取回当时的字节。
func dshFallbackImageURL(_ id: String) -> URL? {
    guard let prefix = [dshAskPrefix, dshSteerPrefix].first(where: { id.hasPrefix($0) }) else { return nil }
    let parts = id.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, UUID(uuidString:String(parts[0])) != nil, let index = Int(parts[1]), index >= 0 else { return nil }
    let root = TestHooks.dshAttachmentRoot ?? NSHomeDirectory() + "/Library/Application Support/AIPetHub"
    return URL(fileURLWithPath:root).appendingPathComponent("DeepSeek附件").appendingPathComponent(id)
}

private func dshFallbackAttachments(_ data: [String: Any], rpc: String) -> (String, [[String: Any]])? {
    guard rpc.hasPrefix(dshAskPrefix) || rpc.hasPrefix(dshSteerPrefix), let mark = rpc.range(of: ":files:"),
          let blocks = data["content"] as? [[String: Any]], blocks.count == 1,
          blocks[0]["type"] as? String == "text", let raw = blocks[0]["text"] as? String else { return nil }
    var bytes = raw.utf8[...], paths: [[String: Any]] = []
    for size in rpc[mark.upperBound...].split(separator: ".").reversed() {
        guard let n = Int(size), n > 0, n < bytes.count else { return nil }
        let path = String(decoding: bytes.suffix(n), as: UTF8.self)
        bytes = bytes.dropLast(n)
        guard path.hasPrefix("/"), bytes.last == 10 else { return nil }
        bytes = bytes.dropLast()
        paths.append(["path":path])
    }
    guard !paths.isEmpty, bytes.last == 10 else { return nil }
    let attachments = paths.reversed().enumerated().map { index, path -> [String:Any] in
        let id = String(rpc[..<mark.lowerBound]) + "." + String(index)
        guard let url = dshFallbackImageURL(id), let image = try? Data(contentsOf:url) else { return path }
        return ["path":path["path"] ?? "", "data":image.base64EncodedString(), "ref":id]
    }
    return (String(decoding: bytes.dropLast(), as: UTF8.self), attachments)
}

/// dsh 的对象路径由附件编号确定；对象暂时缺失时仍保留该编号，下一次读取可以重新恢复。
func dshAttachmentPath(_ id: String) -> String? {
    guard id.hasPrefix("sha256:") else { return nil }
    let hash = String(id.dropFirst(7))
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
    let root = TestHooks.dshAttachmentRoot ?? DshServer.dataRoot + "/attachments/v1"
    return "\(root)/objects/\(hash.prefix(2))/\(hash)"
}

/// 用户消息里的图片 → 和 Claude 一样的图片来源（内嵌数据 + 找原图用的附件编号），交给 attachChatImages 生成缩略图。
func dshImageSources(_ data: [String: Any]) -> [[String: Any]] {
    (data["content"] as? [[String: Any]] ?? []).compactMap { b in
        guard b["type"] as? String == "image", let id = (b["attachment"] as? [String: Any])?["attachmentId"] as? String,
              let path = dshAttachmentPath(id) else { return nil }
        guard let bytes = FileManager.default.contents(atPath:path) else { return ["ref":id,"missing":true] }
        return ["data": bytes.base64EncodedString(), "ref": id]
    }
}

/// dsh 的回合边界也在历史事件中。分页窗口从末尾读取，因此不必等到最早一页。
func dshLastTurn(_ rows: [[String: Any]], endings: [[String:Any]] = []) -> HistoryTurnActivity? {
    var latest = 0.0, stopped = false
    for row in rows.reversed() {
        guard let event = row["event"] as? [String: Any] else { continue }
        let at = ((event["time"] as? NSNumber)?.doubleValue ?? 0) / 1000
        switch event["type"] as? String {
        case "turn/end": return HistoryTurnActivity(running: false, startedAt: 0, updatedAt: at)
        case "turn/start": return HistoryTurnActivity(running: !stopped, startedAt: at, updatedAt: max(at, latest))
        case "user/message":
            let source = (event["data"] as? [String:Any])?["source"] as? [String:Any]
            if let rpc = source?["rpcId"] as? String, endings.contains(where: { $0["rpc"] as? String == rpc }) { stopped = true }
            latest = max(latest, at)
        case "assistant/chunk", "assistant/message", "tool/call", "tool/result":
            latest = max(latest, at)
        default: continue
        }
    }
    return nil
}

/// 历史会话的全部事件（[{ event, view }]，从早到晚）→ 一问一答的回合，结构和另外几位的一样。
/// 用户自己发的话（source.kind == "user"）开一轮；插件塞进去的上下文说明、工具结果也是 user 角色，不算。
func dshTurns(_ rows: [[String: Any]], endings: [[String: Any]] = [], hasMore: Bool = false) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var parser: DshParser?, local: [String: Any]?, retryUser: [String:Any]?
    var startAt: Double?, endAt: Double?, currentTurn: Int?
    func flush() {
        defer { local = nil; retryUser = nil }
        guard let p = parser else { return }
        // turn/start 会早于本轮 user/message；这段开场和纯元数据都不是上一轮未完成的回答。
        if local == nil && p.turn.isEmpty && p.ended == nil && p.failure.isEmpty && !p.started {
            parser = nil; startAt = nil; endAt = nil
            return
        }
        var bot = p.finishedTurn(local:local, expectsAnswer:out.last?["role"] as? String == "user" || retryUser != nil)
        // 服务退出没写结束事件：失败前的等待只有本机记下的结束时刻知道，和实时一样算到那里
        if p.ended == nil, let e = local?["end"] as? Double { endAt = max(endAt ?? 0, e * 1000) }
        if let s = startAt, let e = endAt, e > s { bot["duration"] = (e - s) / 1000 }
        if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
            bot["role"] = "bot"
            if bot["outcome"] as? String != "completed" { bot["retryUser"] = retryUser }
            out.append(bot)
        }
        parser = nil
        startAt = nil
        endAt = nil
    }
    // /compact 没有模型回合编号，按命令开始时刻放回相邻事件之间。旧页尚未载入时不提前显示。
    let oldest = (rows.first?["event"] as? [String:Any])?["time"] as? Double ?? 0
    let commands = endings.filter { row in
        trimmed(row["prompt"] as? String) == "/compact" && row["rpc"] == nil &&
            (!hasMore || (row["start"] as? Double ?? 0) * 1000 >= oldest)
    }.sorted { ($0["start"] as? Double ?? 0) < ($1["start"] as? Double ?? 0) }
    var command = 0
    func insertCommands(until time: Double) {
        while command < commands.count, (commands[command]["start"] as? Double ?? 0) * 1000 <= time {
            flush()
            let row = commands[command]
            var bot: [String:Any] = ["role":"bot","text":row["text"] ?? "", "outcome":row["outcome"] ?? "failed","retryPrompt":"/compact"]
            bot["endingReqId"] = row["reqId"]
            out.append(bot)
            command += 1
        }
    }
    for row in rows {
        guard let event = row["event"] as? [String: Any] else { continue }
        let data = event["data"] as? [String: Any] ?? [:]
        let time = (event["time"] as? NSNumber)?.doubleValue
        if let time { insertCommands(until:time) }
        if event["type"] as? String == "compaction/end", data["turn"] is NSNull {
            if data["error"] == nil {
                flush()
                out.append(["role":"compact", "text":"前面的对话已经压缩成摘要，腾出了上下文空间。"])
            }
            continue
        }
        // 停止或崩溃可能让上一轮缺结束事件：换了回合编号就先收好有内容或有本机结局的上一轮，
        // 否则它会被当成新一轮的开场（结局丢掉），或吃进新一轮的时间戳。
        let number = data["turn"] as? Int
        if event["type"] as? String == "turn/start", let p = parser,
           p.ended != nil || (number != nil && currentTurn != nil && number != currentTurn && (local != nil || !p.turn.isEmpty || !p.failure.isEmpty)) {
            flush()
        }
        if let number { currentTurn = number }
        if event["type"] as? String == "user/message" {
            let source = data["source"] as? [String: Any] ?? [:]
            guard source["kind"] as? String == "user" else { continue }
            // 回答中途补充的那句（我们发的时候在调用编号上做了记号）：算在这一轮里，和当时看到的一样是一步「你补充说」
            let fallback = dshFallbackAttachments(data, rpc: source["rpcId"] as? String ?? "")
            let images = fallback?.1 ?? dshImageSources(data)
            if let p = parser, (source["rpcId"] as? String ?? "").hasPrefix(dshSteerPrefix) {
                if p.turn.isEmpty, p.started, out.last?["role"] as? String == "bot" {
                    retryUser = out.last { $0["role"] as? String == "user" }
                    local = endings.last { $0["rpc"] != nil && $0["rpc"] as? String == source["rpcId"] as? String }
                }
                var step = makeStep("user", "你补充说", detail: fallback?.0 ?? dshUserText(data))
                if !images.isEmpty { step["imageSources"] = images }
                p.turn.add(step)
                continue
            }
            // start 先于提问落盘。在第一步助手输出到来前，这个空解析器就是本轮的运行标题。
            let opening = parser.map { $0.started && $0.turn.isEmpty && $0.ended == nil && $0.failure.isEmpty } ?? false
            if !opening { flush() }
            if let rpc = source["rpcId"] as? String {
                local = endings.last { $0["rpc"] as? String == rpc }
                if local != nil && parser == nil { parser = DshParser(turn: TurnBuilder()) }
            }
            let text = fallback?.0 ?? dshUserText(data)
            let attachments = images
            if !text.isEmpty || !attachments.isEmpty {   // 只发了图片也算一句
                out.append(attachments.isEmpty ? ["role": "user", "text": text] : ["role": "user", "text": text, "imageSources": attachments])
                out[out.count - 1]["turnKey"] = source["rpcId"]
                if let time { out[out.count - 1]["createdAt"] = time / 1000 }
            }
            startAt = time
            continue
        }
        if parser == nil { parser = DshParser(turn: TurnBuilder()) }
        if startAt == nil { startAt = time }
        if parser?.ended == nil, let t = time { endAt = t }
        parser?.feed(event, view: row["view"] as? [String: Any])
    }
    flush()
    insertCommands(until:.infinity)
    return out
}

/// 一轮以输出上限（turn/end 的 max-tokens）结束时的说明：实时和重开历史共用，两边看到的一样。
let dshMaxTokensHint = "这一轮的输出到上限了，没有写完。发一句「继续」可以让它接着写。"

/// 出错信息换成看得懂的话。
func dshReadableError(_ message: String, code: String) -> String {
    let lower = message.lowercased()
    if code == "AUTH" || lower.contains("api key") || lower.contains("authentication") {
        return "DeepSeek 的密钥无效或者没有配置（dsh 的密钥在 \(DshServer.dataRoot)/.credentials.yaml；环境变量里的同名变量会盖过它）。\n\(message)"
    }
    if lower.contains("insufficient") || lower.contains("balance") { return "DeepSeek 账户余额不足。\n\(message)" }
    if lower.contains("rate") && lower.contains("limit") { return "DeepSeek 限流了，稍后再试。\n\(message)" }
    return message.isEmpty ? "DeepSeek 出错了（没有给出原因）" : message
}

/// 命令调用成功只表示服务收到请求，权限或压缩命令自身仍可能拒绝执行。
func dshCommandError(_ value: Any?) -> String? {
    guard let result = (value as? [String: Any])?["result"] as? [String: Any] else { return nil }
    let message = result["text"] as? String ?? result["message"] as? String ?? ""
    if result["kind"] as? String == "error" || message.hasPrefix("Compaction cancelled") {
        return message.isEmpty ? "dsh 拒绝了命令" : message
    }
    return nil
}

/// /compact 的答复 → 给人看的一句话。它答的是一句英文（压缩了多少条、多少 token，或者为什么没压）；格式认不出来就原样附在后面。
func dshCompactReply(_ value: Any?, failed: Bool = false) -> String {
    func text(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let d = v as? [String: Any] {
            for k in ["text", "message", "output", "result", "value", "content"] { if let t = text(d[k]) { return t } }
        }
        if let a = v as? [Any] { return a.compactMap { text($0) }.first }
        return nil
    }
    let said = (text(value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if said.hasPrefix("No compactable history") { return "还没有可以压缩的历史：对话还太短。" }
    if said.hasPrefix("Compaction is unavailable") { return "⚠️ 现在压缩不了：它正在压缩，或者还在回答。等它停下来再试。" }
    if said.hasPrefix("Compaction could not produce a useful summary") { return "没有压缩：没能得到一份有用的摘要（多半是对话还太短），对话没有变。" }
    if said.contains("unchanged") { return "⚠️ 这次没有压缩成功，对话没有变。\n\n\(said)" }
    if said.hasPrefix("Compaction did not finish") || said.hasPrefix("Compaction finished, but") { return "⚠️ 压缩没有干净地完成。\n\n\(said)" }
    if failed { return "⚠️ 没能压缩上下文：" + said }
    return said.isEmpty ? "前面的对话已经压缩成摘要，腾出了上下文空间。" : "前面的对话已经压缩成摘要，腾出了上下文空间。\n\n\(said)"
}
