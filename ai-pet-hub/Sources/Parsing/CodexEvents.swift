// Codex 的事件 → 工作步骤：`codex exec --json`（一问一答）和 app-server 的通知（交互式）各一套解析器。
import Foundation

final class CodexStreamParser {
    let turn: TurnBuilder
    var threadId = ""
    var lastAgentMessage = ""
    var errors: [String] = []

    init(turn: TurnBuilder) { self.turn = turn }

    func feed(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "thread.started":
            if let tid = obj["thread_id"] as? String, !tid.isEmpty { threadId = tid }
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return }
            handle(item, completed: obj["type"] as? String == "item.completed")
        case "turn.failed":
            let msg = readableError(((obj["error"] as? [String: Any])?["message"] as? String) ?? "本轮失败")
            if !errors.contains(msg) { errors.append(msg) }
            turn.add(makeStep("error", "出错", detail: msg, status: "error"))
        case "error":
            if let raw = obj["message"] as? String {
                let msg = readableError(raw)
                if !errors.contains(msg) { errors.append(msg) }
            }
        default:
            break
        }
    }

    private func readableError(_ raw: String) -> String { codexReadableError(raw) }

    private func handle(_ item: [String: Any], completed: Bool) {
        let id = item["id"] as? String ?? UUID().uuidString
        switch item["type"] as? String {
        case "agent_message":
            guard completed else { return }
            let t = trimmed(item["text"] as? String)
            if !t.isEmpty { lastAgentMessage = t; turn.add(makeStep("text", "说明", detail: t), key: id) }
        case "reasoning":
            let detail = trimmed(item["text"] as? String)
            if completed {
                if turn.step(id) == nil { turn.addThink(detail) }
                else { turn.update(id, makeStep("think", "思考", detail: detail, status: "ok")) }
            } else if turn.step(id) == nil {
                turn.add(makeStep("think", "思考", detail: detail, status: "running"), key: id)
            }
        case "command_execution":
            let status = completed ? ((item["status"] as? String) == "failed" || ((item["exit_code"] as? NSNumber)?.intValue ?? 0) != 0 ? "error" : "ok") : "running"
            var step = makeStep("command", "运行命令", detail: item["command"] as? String, status: status)
            let out = trimmed(item["aggregated_output"] as? String)
            if completed, !out.isEmpty { step["output"] = clip(out, maxOutput) }
            if turn.step(id) == nil { turn.add(step, key: id) } else { turn.update(id, step) }
        case "file_change":
            guard completed else { return }
            for (i, change) in (item["changes"] as? [[String: Any]] ?? []).enumerated() {
                let path = change["path"] as? String ?? ""
                let kind = codexChangeKind(change["kind"])
                turn.add(fileStep(kind: kind, path: path), key: "\(id)-\(i)")
                turn.addFile(path, kind: kind, diff: change["diff"] as? String)
            }
        case "mcp_tool_call":
            let status = completed ? ((item["status"] as? String) == "failed" ? "error" : "ok") : "running"
            let step = makeStep("tool", "调用 \(item["server"] as? String ?? "") · \(item["tool"] as? String ?? "")", status: status)
            if turn.step(id) == nil { turn.add(step, key: id) } else { turn.update(id, step) }
        case "web_search":
            let step = makeStep("web", "联网搜索 \(item["query"] as? String ?? "")", status: completed ? "ok" : "running")
            if turn.step(id) == nil { turn.add(step, key: id) } else { turn.update(id, step) }
        case "todo_list":
            if completed {
                let lines = (item["items"] as? [[String: Any]] ?? []).map { ((($0["completed"] as? Bool) ?? false) ? "☑ " : "☐ ") + ($0["text"] as? String ?? "") }
                turn.add(makeStep("todo", "更新计划", detail: lines.joined(separator: "\n")), key: id)
            }
        case "error":
            if completed { turn.add(makeStep("error", "出错", detail: item["message"] as? String, status: "error"), key: id) }
        default:
            break
        }
    }
}

/// Codex 把命令包在一层 shell 里（/bin/zsh -lc '…'）：显示时只留里面那句。
func unwrapShell(_ command: String) -> String {
    guard let r = command.range(of: #"^(/bin/|/usr/bin/)?(zsh|bash|sh) -l?c '"#, options: .regularExpression), command.hasSuffix("'") else { return command }
    return String(command[r.upperBound...].dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
}

/// app-server 的通知 → 工作步骤。和 exec --json 是两套格式（这里是驼峰命名、回答文字逐字给、文件改动带 diff）。
final class CodexAppParser {
    let turn: TurnBuilder
    var threadId = ""
    var turnId = ""
    var lastAgentMessage = ""
    var errors: [String] = []
    /// turn/completed 里的状态：completed / interrupted / failed；回合还没结束是 nil
    var status: String?
    /// 用户的话轮到了（提问本身，以及中途补充的每一句）
    var onUserMessage: ((String) -> Void)?
    /// 这一轮压缩过上下文（/compact）
    var compacted = false
    /// 文件改动条目的内容（审批时要给用户看）：条目 ID → [(路径, 类型, diff)]
    private(set) var changes: [String: [(path: String, kind: String, diff: String)]] = [:]
    private var texts: [String: String] = [:]
    private var lastPush: [String: Date] = [:]

    init(turn: TurnBuilder) { self.turn = turn }

    func notify(_ method: String, _ p: [String: Any]) {
        switch method {
        case "thread/started":
            if let id = (p["thread"] as? [String: Any])?["id"] as? String, !id.isEmpty { threadId = id }
        case "turn/started":
            if let id = (p["turn"] as? [String: Any])?["id"] as? String, !id.isEmpty { turnId = id }
        case "item/started", "item/completed":
            if let item = p["item"] as? [String: Any] { handle(item, completed: method == "item/completed") }
        case "item/agentMessage/delta":
            guard let id = p["itemId"] as? String, let delta = p["delta"] as? String else { return }
            texts[id, default: ""] += delta
            pushText(id, final: false)
        case "turn/plan/updated":
            let lines = (p["plan"] as? [[String: Any]] ?? []).map { s -> String in
                let st = s["status"] as? String ?? ""
                return (st == "completed" ? "☑ " : (st == "inProgress" ? "▸ " : "☐ ")) + (s["step"] as? String ?? "")
            }
            guard !lines.isEmpty else { return }
            let step = makeStep("todo", "更新计划", detail: lines.joined(separator: "\n"))
            if turn.step("plan") == nil { turn.add(step, key: "plan") } else { turn.update("plan", step) }
        case "error":
            let e = p["error"] as? [String: Any] ?? [:]
            if (p["willRetry"] as? Bool) == true { noteRetry(e) }
            else if let m = e["message"] as? String { note(error: m) }
        case "turn/completed":
            let t = p["turn"] as? [String: Any] ?? [:]
            status = t["status"] as? String ?? "completed"
            if let m = (t["error"] as? [String: Any])?["message"] as? String { note(error: m) }
        default:
            break
        }
    }

    /// 它在自动重试（界面上原本什么都不显示，看起来就像一直在想）：记成一步，写明第几次、为什么。
    /// 最常见的是所选模型满载——这时它每次要等 5 分钟左右才再试，不如停下来换个模型。
    private func noteRetry(_ e: [String: Any]) {
        let message = e["message"] as? String ?? ""                       // "Reconnecting... 2/10"
        let why = codexReadableError(e["additionalDetails"] as? String ?? "")
        let count = message.range(of: "[0-9]+/[0-9]+", options: .regularExpression).map { "（第 \(message[$0]) 次）" } ?? ""
        let busy = why.lowercased().contains("at capacity")
        var detail = busy ? "所选模型现在满载。Codex 每次要等 5 分钟左右才再试，可以点停止、换一个模型再发。" : "连接断了，Codex 正在自动重连。"
        if !why.isEmpty { detail += "\n" + why }
        let step = makeStep("error", (busy ? "模型满载，等待重试" : "连接中断，正在重试") + count, detail: detail, status: "error")
        if turn.step("retry") == nil { turn.add(step, key: "retry") } else { turn.update("retry", step) }
    }

    private func note(error raw: String) {
        let msg = codexReadableError(raw)
        if !errors.contains(msg) { errors.append(msg) }
    }

    /// 回答文字隔一小会儿推一次（写完时一定推）。
    private func pushText(_ id: String, final: Bool) {
        let text = trimmed(texts[id])
        guard !text.isEmpty else { return }
        if !final, let t = lastPush[id], Date().timeIntervalSince(t) < textPushInterval { return }
        lastPush[id] = Date()
        let status = final ? "ok" : "running"
        if turn.step(id) == nil { turn.add(makeStep("text", "说明", detail: text, status: status), key: id) }
        else { turn.update(id, ["detail": text, "status": status]) }
    }

    private func handle(_ item: [String: Any], completed: Bool) {
        let id = item["id"] as? String ?? UUID().uuidString
        let put = { (step: [String: Any]) in
            if self.turn.step(id) == nil { self.turn.add(step, key: id) } else { self.turn.update(id, step) }
        }
        switch item["type"] as? String {
        case "userMessage":
            guard completed else { return }
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            onUserMessage?(text)
        case "agentMessage":
            if completed {
                texts[id] = item["text"] as? String ?? texts[id] ?? ""
                if !trimmed(texts[id]).isEmpty { lastAgentMessage = trimmed(texts[id]) }
                pushText(id, final: true)
            }
        case "reasoning":
            let parts = (item["summary"] as? [String] ?? []) + (item["content"] as? [String] ?? [])
            let detail = trimmed(parts.joined(separator: "\n\n"))
            if completed {
                if turn.step(id) == nil { turn.addThink(detail) }
                else { turn.update(id, makeStep("think", "思考", detail: detail, status: "ok")) }
            } else if turn.step(id) == nil {
                turn.add(makeStep("think", "思考", detail: detail, status: "running"), key: id)
            }
        case "commandExecution":
            let st = item["status"] as? String ?? ""
            let failed = st == "failed" || st == "declined" || ((item["exitCode"] as? NSNumber)?.intValue ?? 0) != 0
            var step = makeStep("command", "运行命令", detail: unwrapShell(item["command"] as? String ?? ""),
                                status: completed ? (failed ? "error" : "ok") : "running")
            let out = st == "declined" ? "没有执行：没有得到同意" : trimmed(item["aggregatedOutput"] as? String)
            if completed, !out.isEmpty { step["output"] = clip(out, maxOutput) }
            put(step)
        case "fileChange":
            let list = (item["changes"] as? [[String: Any]] ?? []).map {
                (path: $0["path"] as? String ?? "", kind: codexChangeKind($0["kind"]), diff: $0["diff"] as? String ?? "")
            }
            changes[id] = list
            guard completed else { return }
            let st = item["status"] as? String ?? "completed"
            for (i, c) in list.enumerated() {
                var step = fileStep(kind: c.kind, path: c.path)
                if st != "completed" {
                    step["status"] = "error"
                    step["output"] = st == "declined" ? "没有改：没有得到同意" : "没有改成"
                }
                turn.add(step, key: "\(id)-\(i)")
                if st == "completed" { turn.addFile(c.path, kind: c.kind, diff: c.diff.isEmpty ? nil : c.diff) }
            }
        case "mcpToolCall":
            let st = item["status"] as? String ?? ""
            put(makeStep("tool", "调用 \(item["server"] as? String ?? "") · \(item["tool"] as? String ?? "")",
                         status: completed ? (st == "failed" ? "error" : "ok") : "running"))
        case "webSearch":
            put(makeStep("web", "联网搜索 \(item["query"] as? String ?? "")", status: completed ? "ok" : "running"))
        case "plan":
            if completed, !trimmed(item["text"] as? String).isEmpty { turn.add(makeStep("todo", "计划", detail: trimmed(item["text"] as? String)), key: id) }
        case "collabAgentToolCall":
            put(makeStep("agent", "子任务", detail: item["prompt"] as? String, status: completed ? "ok" : "running"))
        case "contextCompaction":   // /compact：把前面的对话压缩成摘要
            compacted = true
            put(makeStep("tool", "压缩上下文", status: completed ? "ok" : "running"))
        default:
            break
        }
    }
}

/// Codex 的错误常把接口返回的 JSON 原样塞在 message 里：取出其中的 error.message（再附上错误码）。
func codexReadableError(_ raw: String) -> String {
    guard raw.hasPrefix("{"), let data = raw.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return raw }
    let inner = obj["error"] as? [String: Any]
    guard let message = (inner?["message"] as? String) ?? (obj["message"] as? String), !message.isEmpty else { return raw }
    if let code = (inner?["code"] as? String) ?? (inner?["type"] as? String) { return "\(message)（\(code)）" }
    return message
}

/// Codex 的改动类型：exec 事件里是字符串，历史记录里是 {"type": "update"}。
func codexChangeKind(_ raw: Any?) -> String {
    let t = (raw as? String) ?? ((raw as? [String: Any])?["type"] as? String) ?? "update"
    switch t {
    case "add", "create": return "create"
    case "delete", "remove": return "delete"
    default: return "edit"
    }
}

func fileStep(kind: String, path: String) -> [String: Any] {
    let verb = kind == "create" ? "新建" : (kind == "delete" ? "删除" : "修改")
    return makeStep(kind == "create" ? "write" : (kind == "delete" ? "delete" : "edit"), "\(verb) \(fileBaseName(path))", path: path)
}
