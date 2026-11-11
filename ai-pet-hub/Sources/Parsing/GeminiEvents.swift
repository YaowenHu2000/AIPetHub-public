// Gemini（agy）的事件 → 工作步骤：`agy -p` 的 stream-json（一问一答）和 ACP 的 session/update（交互式）各一套解析器。
import Foundation

final class AgyStreamParser {
    let turn: TurnBuilder
    var conversationId = ""
    var response: String?
    var durationSeconds: Double?
    var denied: [String] = []
    /// result 里的 status（SUCCESS / ERROR …）和出错原因；没收到 result 时 status 是 nil
    var status: String?
    var error = ""
    private var texts: [Int: String] = [:]
    private var lastTextPush: [Int: Date] = [:]
    // 「连接出错，正在重试」那一步：同一轮重试共用一步，恢复后再出错算新的一轮
    private var retryKey: String?
    private var retryIndex = -1
    private var retryCount = 0
    private var retryRounds = 0

    init(turn: TurnBuilder) { self.turn = turn }

    /// 这次运行出错的原因；正常结束返回 nil。两种情况：result 的 status 不是 SUCCESS（最常见的是连不上服务器、
    /// 重试几次后放弃，这时 response 只是出错前最后一段中途说明），或者根本没有 result 就非正常退出了（崩溃、被杀）。
    func failure(exitStatus: Int32, stderr: String) -> String? {
        if status == "SUCCESS" || (status == nil && exitStatus == 0) { return nil }
        if !error.isEmpty { return error }
        // stderr 里「error: …」那一行最清楚（后面还跟着一行 AGY_ERROR 的 JSON）
        let lines = stderr.split(separator: "\n").map { trimmed(String($0)) }.filter { !$0.isEmpty && !$0.hasPrefix("AGY_ERROR:") }
        if let e = lines.last(where: { $0.hasPrefix("error: ") }) { return String(e.dropFirst(7)) }
        if let last = lines.last { return clip(last, 300) }
        return status.map { "agy 返回了 \($0)" } ?? "agy 意外退出（退出码 \(exitStatus)）"
    }

    /// 调用模型失败（多半是网络问题）时 agy 会自动重试，每失败一次来一个 error_message 步骤，里面没有文字。
    /// 以前这些步骤被忽略，重试的那几分钟界面像是卡住了；现在合成一步「连接出错，正在重试」，恢复或放弃时更新它。
    private func noteRetry(_ idx: Int) {
        if retryKey == nil { retryRounds += 1; retryKey = "agy-retry-\(retryRounds)"; retryCount = 0 }
        guard let key = retryKey else { return }
        retryCount += 1
        retryIndex = max(retryIndex, idx)
        let step = makeStep("error", "连接出错，正在重试（第 \(retryCount) 次）",
                            detail: "调用模型的请求失败了（多半是网络问题），agy 会自动重试几次。", status: "running")
        if turn.step(key) == nil { turn.add(step, key: key) } else { turn.update(key, step) }
    }

    /// 重试之后来了新的步骤：连接恢复了。
    private func retryRecovered(_ idx: Int) {
        guard let key = retryKey, idx > retryIndex else { return }
        turn.update(key, ["title": "连接出错 \(retryCount) 次，重试后恢复", "status": "ok"])
        retryKey = nil
    }

    /// 会话 ID 以最先给出的为准：第一条 init 事件就带着（启动后几秒），界面靠它马上认出这个会话。
    /// 之后不再跟着变，免得子代理步骤带的会话 ID 把它换掉（中途停止时就会记成子代理的会话）。
    private func noteConversation(_ value: Any?) {
        if conversationId.isEmpty, let cid = value as? String, !cid.isEmpty { conversationId = cid }
    }

    func feed(_ obj: [String: Any]) {
        noteConversation(obj["conversation_id"])
        switch obj["event"] as? String {
        case "step_update":
            guard let u = obj["step_update"] as? [String: Any] else { return }
            noteConversation(u["conversation_id"])
            step(u)
        case "result":
            guard let r = obj["result"] as? [String: Any] else { return }
            noteConversation(r["conversation_id"])
            response = r["response"] as? String
            status = r["status"] as? String
            error = trimmed(r["error"] as? String)
            if let key = retryKey {
                turn.update(key, status == "SUCCESS" ? ["title": "连接出错 \(retryCount) 次，重试后恢复", "status": "ok"]
                                                     : ["title": "连接出错，重试 \(retryCount) 次后放弃", "status": "error"])
                retryKey = nil
            }
            durationSeconds = (r["duration_seconds"] as? NSNumber)?.doubleValue
            denied = (r["denied_actions"] as? [[String: Any]] ?? []).compactMap { ($0["display_name"] as? String) ?? ($0["action"] as? String) }
            if !denied.isEmpty {
                turn.add(makeStep("denied", "被拒绝的操作", detail: denied.joined(separator: "、") + "（当前权限模式不允许）", status: "error"))
            }
        default:
            break
        }
    }

    private func step(_ u: [String: Any]) {
        let idx = (u["step_index"] as? NSNumber)?.intValue ?? -1
        let key = "agy-\(idx)"
        let state = u["state"] as? String ?? ""
        let type = u["step_type"] as? String
        if type == "agent_response" || type == "tool" { retryRecovered(idx) }
        switch type {
        case "error_message":
            noteRetry(idx)
        case "agent_response":
            if let delta = u["text_delta"] as? String { texts[idx, default: ""] += delta }
            let text = trimmed(texts[idx])
            guard !text.isEmpty else { return }
            let done = state == "DONE"
            if turn.step(key) == nil {
                turn.add(makeStep("text", "说明", detail: text, status: done ? "ok" : "running"), key: key)
                lastTextPush[idx] = Date()
            } else if done || Date().timeIntervalSince(lastTextPush[idx] ?? .distantPast) > textPushInterval {
                turn.update(key, ["detail": text, "status": done ? "ok" : "running"])
                lastTextPush[idx] = Date()
            }
        case "tool":
            let info = u["tool_info"] as? [String: Any] ?? [:]
            let name = (u["tool_name"] as? String) ?? (info["name"] as? String) ?? "tool"
            let params = info["parameters"] as? [String: Any] ?? [:]
            let status = state == "ERROR" ? "error" : (state == "DONE" ? "ok" : "running")
            var step = agyToolStep(name: name, params: params)
            step["status"] = status
            if status == "error", let err = (info["error"] as? [String: Any])?["message"] as? String {
                step["output"] = clip(err, maxOutput)
            }
            if turn.step(key) == nil { turn.add(step, key: key) } else { turn.update(key, step) }
            if status == "ok", let path = step["path"] as? String, let kind = step["kind"] as? String, ["edit", "write"].contains(kind) {
                turn.addFile(path, kind: kind == "write" ? "create" : "edit", diff: agyDiff(params))
            }
        default:
            break
        }
    }
}

/// ACP 的 session/update 通知 → 工作步骤。工具名和参数与 stream-json 的一样（agyToolStep / agyDiff 共用），
/// 回答文字和思考都是一小段一小段给的；文字 / 思考之间隔着别的步骤时各算一段。
final class AcpParser {
    let turn: TurnBuilder
    var sessionId = ""
    var response = ""            // 最后一段回答文字
    var stopReason: String?      // end_turn / cancelled / refusal / max_tokens …
    /// agy 报出它认得的斜杠命令（输入框里打 / 时列出来）
    var onCommands: (([[String: String]]) -> Void)?
    private var segment = 0
    private var current = ""     // 正在长的那一段的 key（"acp-text-N" / "acp-think-N"）
    private var buffer = ""
    private var lastPush = Date.distantPast

    init(turn: TurnBuilder) { self.turn = turn }

    func update(_ u: [String: Any]) {
        switch u["sessionUpdate"] as? String {
        case "agent_message_chunk": chunk("text", (u["content"] as? [String: Any])?["text"] as? String ?? "")
        case "agent_thought_chunk": chunk("think", (u["content"] as? [String: Any])?["text"] as? String ?? "")
        case "available_commands_update":
            let list = (u["availableCommands"] as? [[String: Any]] ?? []).compactMap { c -> [String: String]? in
                guard let name = c["name"] as? String, !name.isEmpty else { return nil }
                return ["name": name, "desc": c["description"] as? String ?? ""]
            }
            if !list.isEmpty { onCommands?(list) }
        case "tool_call", "tool_call_update":
            endSegment()
            guard let id = u["toolCallId"] as? String else { return }
            let key = "acp-\(id)"
            let args = (u["args"] as? [String: Any]) ?? (u["rawInput"] as? [String: Any]) ?? [:]
            let st = u["status"] as? String ?? ""
            var step = agyToolStep(name: u["name"] as? String ?? (u["title"] as? String ?? "tool"), params: args)
            step["status"] = st == "failed" ? "error" : (st == "completed" ? "ok" : "running")
            if st == "failed" {
                let texts = (u["content"] as? [[String: Any]] ?? []).compactMap { ($0["content"] as? [String: Any])?["text"] as? String }
                if !texts.isEmpty { step["output"] = clip(texts.joined(separator: "\n"), maxOutput) }
            }
            let known = turn.step(key)
            if known == nil { turn.add(step, key: key) } else { turn.update(key, step) }
            // 同一步的 completed 可能来不止一次：改动只记一次
            if st == "completed", known?["status"] as? String != "ok",
               let path = step["path"] as? String, let kind = step["kind"] as? String, ["edit", "write"].contains(kind) {
                turn.addFile(path, kind: kind == "write" ? "create" : "edit", diff: agyDiff(args))
            }
        case "plan":
            endSegment()
            let lines = (u["entries"] as? [[String: Any]] ?? []).map { e -> String in
                let st = e["status"] as? String ?? ""
                return (st == "completed" ? "☑ " : (st == "in_progress" ? "▸ " : "☐ ")) + (e["content"] as? String ?? "")
            }
            guard !lines.isEmpty else { return }
            let step = makeStep("todo", "更新计划", detail: lines.joined(separator: "\n"))
            if turn.step("acp-plan") == nil { turn.add(step, key: "acp-plan") } else { turn.update("acp-plan", step) }
        default:
            break
        }
    }

    /// 这一轮结束（session/prompt 的答复）。
    func finish(stopReason: String?) {
        endSegment()
        self.stopReason = stopReason
    }

    private func chunk(_ kind: String, _ text: String) {
        guard !text.isEmpty else { return }
        if !current.hasPrefix("acp-\(kind)-") {
            endSegment()
            segment += 1
            current = "acp-\(kind)-\(segment)"
        }
        buffer += text
        push(final: false)
    }

    private func endSegment() {
        guard !current.isEmpty else { return }
        push(final: true)
        if current.hasPrefix("acp-text-"), !trimmed(buffer).isEmpty { response = trimmed(buffer) }
        current = ""
        buffer = ""
    }

    private func push(final: Bool) {
        let text = trimmed(buffer)
        guard !text.isEmpty else { return }
        if !final, turn.step(current) != nil, Date().timeIntervalSince(lastPush) < textPushInterval { return }
        lastPush = Date()
        let think = current.hasPrefix("acp-think-")
        let step = makeStep(think ? "think" : "text", think ? "思考" : "说明", detail: text, status: final ? "ok" : "running")
        if turn.step(current) == nil { turn.add(step, key: current) } else { turn.update(current, step) }
    }
}

let agyPathKeys = ["AbsolutePath", "TargetFile", "Path", "FilePath", "File", "DirectoryPath", "SearchPath", "SearchDirectory"]

func agyToolStep(name: String, params: [String: Any]) -> [String: Any] {
    var path = ""
    for k in agyPathKeys { if let p = params[k] as? String, !p.isEmpty { path = p; break } }
    if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
    let lower = name.lowercased()
    // 外接的 MCP 工具（比如内置浏览器的 browser_open）：直接显示工具名，不按名字里的字眼猜
    if lower.contains("mcp") || lower.contains("browser_") { return makeStep("tool", "调用 \(name)") }
    if lower.contains("command") {
        return makeStep("command", "运行命令", detail: (params["CommandLine"] as? String) ?? (params["Command"] as? String))
    }
    if lower.contains("list_dir") { return makeStep("list", "查看目录 \(fileBaseName(path))", path: path) }
    if (lower.contains("read") || lower.contains("view")) && (lower.contains("file") || lower.contains("code")) {
        return makeStep("read", "读取 \(fileBaseName(path))", path: path)
    }
    if lower.contains("write") || lower.contains("create_file") { return makeStep("write", "写入 \(fileBaseName(path))", path: path) }
    if lower.contains("replace") || lower.contains("edit") { return makeStep("edit", "修改 \(fileBaseName(path))", path: path) }
    if lower.contains("grep") || lower.contains("search") || lower.contains("find") {
        let q = (params["Query"] as? String) ?? (params["Pattern"] as? String) ?? (params["SearchTerm"] as? String) ?? ""
        return makeStep(lower.contains("web") ? "web" : "search", lower.contains("web") ? "联网搜索 \(q)" : "搜索 \(q)", detail: path)
    }
    if lower.contains("url") || lower.contains("browser") { return makeStep("web", "读取网页", detail: params["Url"] as? String) }
    return makeStep("tool", "调用 \(name)", path: path)
}

/// agy 改文件的参数里通常带原文 / 新文，尽量还原成 diff。
func agyDiff(_ params: [String: Any]) -> String? {
    if let content = params["CodeContent"] as? String { return simpleDiff(old: "", new: content) }
    if let chunks = params["ReplacementChunks"] as? [[String: Any]] {
        return chunks.map { simpleDiff(old: $0["TargetContent"] as? String ?? "", new: $0["ReplacementContent"] as? String ?? "") }
            .joined(separator: "\n")
    }
    if let target = params["TargetContent"] as? String {
        return simpleDiff(old: target, new: params["ReplacementContent"] as? String ?? "")
    }
    return nil
}
