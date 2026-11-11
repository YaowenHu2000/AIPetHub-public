// Claude Code 的 stream-json 事件 → 工作步骤（实时输出和会话记录共用）。
import Foundation

struct PendingFile {
    let path: String
    let kind: String
    let diff: String
}

func claudeToolStep(name: String, input: [String: Any]) -> ([String: Any], PendingFile?) {
    let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
    switch name {
    case "Bash":
        let desc = trimmed(input["description"] as? String)
        return (makeStep("command", desc.isEmpty ? "运行命令" : desc, detail: input["command"] as? String, status: "running"), nil)
    case "Read":
        return (makeStep("read", "读取 \(fileBaseName(path))", path: path, status: "running"), nil)
    case "Edit", "MultiEdit", "NotebookEdit":
        var diff: String
        if name == "MultiEdit" {
            let edits = input["edits"] as? [[String: Any]] ?? []
            diff = edits.map { simpleDiff(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "") }
                .joined(separator: "\n")
        } else if name == "NotebookEdit" {
            diff = simpleDiff(old: "", new: input["new_source"] as? String ?? "")
        } else {
            diff = simpleDiff(old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? "")
        }
        var step = makeStep("edit", "修改 \(fileBaseName(path))", path: path, status: "running")
        let c = diffCounts(diff)
        step["added"] = c.added
        step["removed"] = c.removed
        return (step, PendingFile(path: path, kind: "edit", diff: diff))
    case "Write":
        let content = input["content"] as? String ?? ""
        var step = makeStep("write", "写入 \(fileBaseName(path))", path: path, status: "running")
        step["added"] = lineCount(content)
        return (step, PendingFile(path: path, kind: "write", diff: simpleDiff(old: "", new: content)))
    case "Glob":
        return (makeStep("search", "查找文件 \(input["pattern"] as? String ?? "")", detail: input["path"] as? String, status: "running"), nil)
    case "Grep":
        return (makeStep("search", "搜索 \(input["pattern"] as? String ?? "")", detail: input["path"] as? String, status: "running"), nil)
    case "LS":
        let dir = input["path"] as? String ?? ""
        return (makeStep("list", "查看目录 \(fileBaseName(dir))", path: dir, status: "running"), nil)
    case "WebFetch":
        return (makeStep("web", "读取网页", detail: input["url"] as? String, status: "running"), nil)
    case "WebSearch":
        return (makeStep("web", "联网搜索 \(input["query"] as? String ?? "")", status: "running"), nil)
    case "TodoWrite":
        let todos = (input["todos"] as? [[String: Any]] ?? []).map { t -> String in
            let mark = (t["status"] as? String) == "completed" ? "☑" : ((t["status"] as? String) == "in_progress" ? "▸" : "☐")
            return "\(mark) \(t["content"] as? String ?? "")"
        }
        return (makeStep("todo", "更新待办", detail: todos.joined(separator: "\n"), status: "running"), nil)
    case "Workflow":   // 多智能体工作流（Ultracode 档会用）：标题用脚本里写的那句说明
        let script = input["script"] as? String ?? ""
        var what = input["name"] as? String ?? ""
        if let r = script.range(of: #"description:\s*['"`]([^'"`]+)"#, options: .regularExpression) {
            what = String(script[r]).replacingOccurrences(of: #"^description:\s*['"`]"#, with: "", options: .regularExpression)
        }
        return (makeStep("agent", what.isEmpty ? "启动多智能体工作流" : "多智能体工作流：\(clip(what, 60))", status: "running"), nil)
    case "Task", "Agent":
        return (makeStep("agent", "子任务：\(input["description"] as? String ?? "")", detail: input["prompt"] as? String, status: "running"), nil)
    default:
        let pretty = name.hasPrefix("mcp__") ? String(name.dropFirst(5)).replacingOccurrences(of: "__", with: " · ") : name
        return (makeStep("tool", "调用 \(pretty)", status: "running"), nil)
    }
}

func claudeBlock(_ block: [String: Any], turn: TurnBuilder, pending: inout [String: PendingFile]) {
    switch block["type"] as? String {
    case "thinking":
        turn.addThink(trimmed(block["thinking"] as? String))
    case "text":
        let t = trimmed(block["text"] as? String)
        if !t.isEmpty { turn.add(makeStep("text", "说明", detail: t)) }
    case "tool_use":
        let id = block["id"] as? String ?? UUID().uuidString
        let (step, file) = claudeToolStep(name: block["name"] as? String ?? "工具", input: block["input"] as? [String: Any] ?? [:])
        turn.add(step, key: id)
        if let f = file { pending[id] = f }
    default:
        break
    }
}

func claudeToolResult(_ block: [String: Any], turn: TurnBuilder, pending: inout [String: PendingFile]) {
    guard let id = block["tool_use_id"] as? String else { return }
    let isError = (block["is_error"] as? Bool) == true
    let text = textOf(block["content"])
    var fields: [String: Any] = ["status": isError ? "error" : "ok"]
    if let kind = turn.step(id)?["kind"] as? String, isError || ["command", "search", "web", "tool", "agent"].contains(kind), !text.isEmpty {
        fields["output"] = clip(text, maxOutput)
    }
    turn.update(id, fields)
    if let f = pending.removeValue(forKey: id), !isError {
        let created = f.kind == "write" && text.contains("created")
        turn.addFile(f.path, kind: created ? "create" : "edit", diff: f.diff)
        if created { turn.update(id, ["title": "新建 \(fileBaseName(f.path))"]) }
    }
}

final class ClaudeStreamParser {
    let turn: TurnBuilder
    var sessionId = ""
    var result: String?
    var isError = false
    var subtype = ""
    var durationMs: Double?
    private var pending: [String: PendingFile] = [:]
    // --include-partial-messages：回答文字边生成边推给界面（Claude 不给思考内容，思考仍然只是一步占位）
    private var currentMessage = ""
    private var blockKeys: [Int: String] = [:]            // 当前消息里 content block 的 index → 步骤 key
    private var streamedText: [String: [String]] = [:]    // 消息 ID → 按顺序流式显示过的文字块 key
    private var partialText: [String: String] = [:]
    private var lastPush: [String: Date] = [:]

    init(turn: TurnBuilder) { self.turn = turn }

    func feed(_ obj: [String: Any]) {
        if let sid = obj["session_id"] as? String, !sid.isEmpty { sessionId = sid }
        let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch obj["type"] as? String {
        case "stream_event":
            // 只流式显示主对话的文字；子代理（parent_tool_use_id 不为空）的中间文字不推
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return }
            if let e = obj["event"] as? [String: Any] { partial(e) }
        case "assistant":
            let msgId = (obj["message"] as? [String: Any])?["id"] as? String ?? ""
            for block in blocks {
                // 流式时已经显示过的文字块：用完整内容更新那一步，不重复添加
                if block["type"] as? String == "text", var keys = streamedText[msgId], !keys.isEmpty {
                    let key = keys.removeFirst()
                    streamedText[msgId] = keys
                    let text = trimmed(block["text"] as? String)
                    if !text.isEmpty {
                        partialText[key] = text
                        if turn.step(key) == nil { turn.add(makeStep("text", "说明", detail: text), key: key) }
                        else { turn.update(key, ["detail": text, "status": "ok"]) }
                    }
                    continue
                }
                claudeBlock(block, turn: turn, pending: &pending)
            }
        case "user":
            blocks.filter { $0["type"] as? String == "tool_result" }.forEach { claudeToolResult($0, turn: turn, pending: &pending) }
        case "result":
            result = obj["result"] as? String
            isError = (obj["is_error"] as? Bool) == true
            subtype = obj["subtype"] as? String ?? ""
            durationMs = (obj["duration_ms"] as? NSNumber)?.doubleValue
        default:
            break
        }
    }

    private func partial(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "message_start":
            currentMessage = ((e["message"] as? [String: Any])?["id"] as? String) ?? UUID().uuidString
            blockKeys = [:]
        case "content_block_start":
            guard let i = (e["index"] as? NSNumber)?.intValue,
                  (e["content_block"] as? [String: Any])?["type"] as? String == "text" else { return }
            let key = "partial-\(currentMessage)-\(i)"
            blockKeys[i] = key
            streamedText[currentMessage, default: []].append(key)
            partialText[key] = ""
        case "content_block_delta":
            guard let i = (e["index"] as? NSNumber)?.intValue, let key = blockKeys[i],
                  let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                  let text = d["text"] as? String else { return }
            partialText[key, default: ""] += text
            push(key, final: false)
        case "content_block_stop":
            if let i = (e["index"] as? NSNumber)?.intValue, let key = blockKeys[i] { push(key, final: true) }
        default:
            break
        }
    }

    /// 文字隔一小会儿推一次（块结束时一定推），界面上逐渐长出来。
    private func push(_ key: String, final: Bool) {
        let text = trimmed(partialText[key])
        guard !text.isEmpty else { return }
        if !final, let t = lastPush[key], Date().timeIntervalSince(t) < textPushInterval { return }
        lastPush[key] = Date()
        let status = final ? "ok" : "running"
        if turn.step(key) == nil { turn.add(makeStep("text", "说明", detail: text, status: status), key: key) }
        else { turn.update(key, ["detail": text, "status": status]) }
    }
}
