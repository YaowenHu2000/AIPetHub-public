// DeepSeek Harness（dsh）的会话事件 → 界面上的工作步骤。回答进行中（网页模式的事件流）和读历史会话用的是同一种事件，共用这一个解析器。
// 事件长什么样见 DeepSeekServer.swift 开头；实测的样例在 tools/parsertest.swift 里。
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
        if !final, let t = lastPush[key], Date().timeIntervalSince(t) < textPushInterval { return }
        lastPush[key] = Date()
        let status = final ? "ok" : "running"
        if turn.step(key) == nil { turn.add(makeStep(kind, kind == "think" ? "思考" : "说明", detail: text, status: status), key: key) }
        else { turn.update(key, ["detail": kind == "text" ? text : clip(text, maxDetail), "status": status]) }
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
        let output = trimmed((view["output"] as? String) ?? textOf(part["content"]))
        var fields: [String: Any] = ["status": failed ? "error" : "ok"]
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

/// 历史会话的全部事件（[{ event, view }]，从早到晚）→ 一问一答的回合，结构和另外几位的一样。
/// 用户自己发的话（source.kind == "user"）开一轮；插件塞进去的上下文说明、工具结果也是 user 角色，不算。
func dshTurns(_ rows: [[String: Any]]) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var parser: DshParser?
    var startAt: Double?, endAt: Double?
    func flush() {
        guard let p = parser else { return }
        var bot = p.turn.finish(finalText: p.response)
        if trimmed(bot["text"] as? String).isEmpty, let e = p.ended, e.kind == "error" { bot["text"] = "⚠️ " + dshReadableError(e.message, code: e.code) }
        if let s = startAt, let e = endAt, e > s { bot["duration"] = (e - s) / 1000 }
        if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
            bot["role"] = "bot"
            out.append(bot)
        }
        parser = nil
        startAt = nil
        endAt = nil
    }
    for row in rows {
        guard let event = row["event"] as? [String: Any] else { continue }
        let data = event["data"] as? [String: Any] ?? [:]
        let time = (event["time"] as? NSNumber)?.doubleValue
        if event["type"] as? String == "user/message" {
            let source = data["source"] as? [String: Any] ?? [:]
            guard source["kind"] as? String == "user" else { continue }
            // 回答中途补充的那句（我们发的时候在调用编号上做了记号）：算在这一轮里，和当时看到的一样是一步「你补充说」
            if let p = parser, (source["rpcId"] as? String ?? "").hasPrefix(dshSteerPrefix) {
                p.turn.add(makeStep("user", "你补充说", detail: dshUserText(data)))
                continue
            }
            flush()
            let text = dshUserText(data)
            if !text.isEmpty { out.append(["role": "user", "text": text]) }
            startAt = time
            continue
        }
        if parser == nil { parser = DshParser(turn: TurnBuilder()) }
        if startAt == nil { startAt = time }
        if let t = time { endAt = t }
        parser?.feed(event, view: row["view"] as? [String: Any])
    }
    flush()
    return out
}

/// 出错信息换成看得懂的话。
func dshReadableError(_ message: String, code: String) -> String {
    let lower = message.lowercased()
    if code == "AUTH" || lower.contains("api key") || lower.contains("authentication") {
        return "DeepSeek 的密钥无效或者没有配置（dsh 的密钥在 ~/.dsh/.credentials.yaml；环境变量里的同名变量会盖过它）。\n\(message)"
    }
    if lower.contains("insufficient") || lower.contains("balance") { return "DeepSeek 账户余额不足。\n\(message)" }
    if lower.contains("rate") && lower.contains("limit") { return "DeepSeek 限流了，稍后再试。\n\(message)" }
    return message.isEmpty ? "DeepSeek 出错了（没有给出原因）" : message
}

/// /compact 的答复 → 给人看的一句话。它答的是一句英文（压缩了多少条、多少 token，或者为什么没压）；格式认不出来就原样附在后面。
func dshCompactReply(_ value: Any?) -> String {
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
    return said.isEmpty ? "前面的对话已经压缩成摘要，腾出了上下文空间。" : "前面的对话已经压缩成摘要，腾出了上下文空间。\n\n\(said)"
}
