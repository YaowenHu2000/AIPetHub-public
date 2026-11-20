// Codex 的历史有两个来源（数据库、rollout 文件），记录的外形不同，但「怎么归成一问一答」是同一套，放在这一处：
// 改归组规则只改这里，两个来源（CodexHistory 的数据库读取、CodexRollout）只管把记录喂进来。
import Cocoa

extension AppDelegate {
    /// Codex 历史条目（数据库里是 camelCase，rollout 里是 PascalCase）→ 工作步骤。
    func codexHistoryItem(type: String, obj: [String: Any], turn: TurnBuilder, finalAnswer: inout String, afterAbort: Bool = false) {
        let itemStatus = obj["status"] as? String ?? "completed"
        let stepStatus = ["failed", "declined"].contains(itemStatus) ? "error" : (itemStatus == "completed" ? "ok" : "running")
        switch type {
        case "agentMessage", "AgentMessage":
            let text = trimmed((obj["text"] as? String) ?? textOf(obj["content"]))
            guard !text.isEmpty else { return }
            if obj["phase"] as? String == "final_answer" {
                finalAnswer = finalAnswer.isEmpty ? text : finalAnswer + "\n\n" + text
            } else {
                turn.add(makeStep("text", "说明", detail: text))
            }
        case "reasoning", "Reasoning":
            turn.addThink(trimmed(textOf(obj["summary"] ?? obj["summary_text"])))
        case "commandExecution", "CommandExecution":
            let command = (obj["command"] as? String) ?? ((obj["command"] as? [String])?.last ?? "")
            let exitCode = (obj["exitCode"] as? NSNumber)?.intValue ?? (obj["exit_code"] as? NSNumber)?.intValue ?? 0
            let status = obj["status"] as? String ?? "completed"
            let failed = status == "failed" || status == "declined" || exitCode != 0
            var step = makeStep("command", "运行命令", detail: command, status: failed ? "error" : (status == "completed" ? "ok" : "running"))
            // turn_aborted 后补写的 -1 表示命令没拿到退出码。中断之前就失败的命令保留红色。
            if afterAbort, status == "failed", exitCode == -1 { step["status"] = "interrupted" }
            let output = status == "declined" ? "没有执行：没有得到同意" : trimmed((obj["aggregatedOutput"] as? String) ?? (obj["aggregated_output"] as? String))
            if !output.isEmpty { step["output"] = clip(output, maxOutput) }
            turn.add(step)
        case "fileChange", "FileChange":
            let status = obj["status"] as? String ?? "completed"
            for change in codexChanges(obj["changes"]) {
                var step = fileStep(kind: change.kind, path: change.path)
                if status == "failed" || status == "declined" {
                    step["status"] = "error"
                    step["output"] = status == "declined" ? "没有改：没有得到同意" : "没有改成"
                } else if status != "completed" { step["status"] = "running" }
                turn.add(step)
                if status == "completed" { turn.addFile(change.path, kind: change.kind, diff: change.diff) }
            }
        case "mcpToolCall", "McpToolCall":
            turn.add(makeStep("tool", "调用 \(obj["server"] as? String ?? "") · \(obj["tool"] as? String ?? "")", status: stepStatus))
        case "dynamicToolCall", "DynamicToolCall":
            turn.add(makeStep("tool", "调用 \(obj["tool"] as? String ?? "工具")", status: stepStatus))
        case "webSearch", "WebSearch":
            turn.add(makeStep("web", "联网搜索 \(obj["query"] as? String ?? "")", status: stepStatus))
        case "imageGeneration", "ImageGeneration":
            let path = (obj["savedPath"] as? String) ?? (obj["saved_path"] as? String)
            turn.add(makeStep("tool", "生成图片", path: path, status: stepStatus))
            if let path = path, obj["status"] as? String == "completed" { turn.addFile(path, kind: "create") }
        case "contextCompaction", "ContextCompaction":
            turn.add(makeStep("tool", "压缩上下文"))
        case "imageView", "ImageView":
            turn.add(makeStep("read", "查看图片", path: obj["path"] as? String))
        case "collabAgentToolCall", "CollabAgentToolCall":
            turn.add(makeStep("agent", "协作子代理", status: stepStatus))
        default:
            break
        }
    }

    func codexChanges(_ raw: Any?) -> [(path: String, kind: String, diff: String?)] {
        if let list = raw as? [[String: Any]] {
            return list.compactMap { c in
                guard let path = c["path"] as? String else { return nil }
                return (path, codexChangeKind(c["kind"]), (c["diff"] as? String) ?? (c["unified_diff"] as? String))
            }
        }
        if let map = raw as? [String: Any] {
            return map.map { path, value in
                let d = value as? [String: Any] ?? [:]
                return (path, codexChangeKind(d["type"] ?? d["kind"]), (d["unified_diff"] as? String) ?? (d["diff"] as? String))
            }
        }
        return []
    }
}

/// Codex 的历史有两个来源（数据库、rollout 文件），记录的外形不同，但「怎么归成一问一答」是同一套：
/// 用户消息开一轮；同一个回合里再来的用户消息是中途补充，算这一轮里的一步「你补充说」；回合身份变了就收尾。
/// 两个来源只管把记录喂进来，这样改归组的规则只用改这一处。
final class CodexTurnGrouper {
    /// 收尾时这一轮的结局由来源决定（数据库查回合表，rollout 看结束事件）
    typealias Ending = (_ turnId: String, _ turn: TurnBuilder, _ finalAnswer: String) -> (outcome: String, error: String?, completed: Bool)
    private unowned let app: AppDelegate
    private let cid: String
    private let ticksPerSecond: Double   // 时间戳的单位：数据库是毫秒，rollout 是秒
    private let ending: Ending
    private(set) var out: [[String: Any]] = []
    private(set) var turn: TurnBuilder?
    private(set) var turnId = ""
    private var acceptsSteers = false
    private var finalAnswer = ""
    private var stepTimes: [Double] = []
    private var needsOrder = false
    private var start: Double?
    private var end: Double?
    private lazy var knownEndings = app.codexKnownEndings()   // 每次解析只读一遍，不在每轮收尾时读
    private lazy var execEndings = knownEndings.values.filter { $0["prompt"] != nil && $0["cid"] as? String == cid }
    private var imageSends: [String: Int] = [:]   // 「回合|附图路径」→ 这一回合里已经发过几次
    private var asked = false      // 这一轮由一句提问开头（/compact 的回合没有提问）
    private var compactions = 0    // 这一轮里的压缩条目数

    init(app: AppDelegate, cid: String, ticksPerSecond: Double, ending: @escaping Ending) {
        self.app = app
        self.cid = cid
        self.ticksPerSecond = ticksPerSecond
        self.ending = ending
    }

    /// 这条记录属于别的回合：把手头这一轮收尾。没有回合身份的旧记录不靠它分轮。
    func enter(_ id: String) {
        if !id.isEmpty, !turnId.isEmpty, id != turnId { flush() }
    }

    /// 还没有开着的一轮就开一轮（回答先于提问出现、或只有结束事件的回合）
    func begin(_ id: String, at: Double?) {
        guard turn == nil else { return }
        turn = TurnBuilder(); turnId = id; acceptsSteers = true; start = at
    }

    func touch(_ at: Double?) {
        if let at = at { end = max(end ?? at, at) }
    }

    /// 这一轮已经结束：之后同一回合再来的用户消息不算补充（晚落盘的命令结果仍然算这一轮的）
    func closeToSteers() { acceptsSteers = false }

    func userMessage(_ content: Any?, turnId id: String, at: Double?, completed: Double?) {
        var images = codexImageSources(content)
        // 这一回合里同一路径第几次发送、什么时候发的：文件发送之后被覆盖时，按它去 rollout 里找当时那张（codexRolloutImages）。
        // 按回合计数而不是从第一轮数起：thread/revert 后最新的 rollout 只有回滚点之后的回合
        for k in images.indices {
            guard let p = images[k]["path"] as? String else { continue }
            images[k]["send"] = imageSends["\(id)|\(p)", default: 0]
            images[k]["turn"] = id
            if let t = at ?? completed { images[k]["at"] = t / ticksPerSecond }
            imageSends["\(id)|\(p)", default: 0] += 1
        }
        var text = stripCodexAttachmentHeader(app.stripPersonaPrefix(app.textBlocks(content)), images: images)
        if let blocks = content as? [[String:Any]], let skill = blocks.first(where: { ($0["type"] as? String)?.lowercased() == "skill" }),
           let name = skill["name"] as? String, !name.isEmpty {
            text = "/" + name + (text.isEmpty ? "" : " " + text)
        }
        guard !text.isEmpty || !images.isEmpty else { return }
        if let t = turn, acceptsSteers, !id.isEmpty, id == turnId {
            var step = makeStep("user", "你补充说", detail: text)
            if !images.isEmpty { step["imageSources"] = images }
            t.add(step)
            stampSteps(at)
            touch(completed)
            return
        }
        user(text: text, turnId: id, at: at, images: images)
    }

    func user(text: String, turnId id: String = "", at: Double? = nil, images: [[String: Any]] = []) {
        flush()
        var row: [String: Any] = ["role": "user", "text": text]
        if !images.isEmpty { row["imageSources"] = images }
        if !id.isEmpty { row["turnKey"] = id }
        if let at, at > 0 { row["createdAt"] = at / ticksPerSecond }
        out.append(row)
        turn = TurnBuilder(); turnId = id; acceptsSteers = true; start = at; end = at; asked = true
    }

    func item(type: String, obj: [String: Any], turnId id: String, at: Double?, completed: Double?, afterAbort: Bool = false) {
        begin(id, at: at)
        touch(completed)
        if ["contextCompaction", "ContextCompaction"].contains(type) { compactions += 1 }
        if let t = turn { app.codexHistoryItem(type: type, obj: obj, turn: t, finalAnswer: &finalAnswer, afterAbort: afterAbort) }
        stampSteps(at)
    }

    /// 命令在完成时才入库，开始时间可能早于已记录的补充。只在本轮出现倒序时排序，同时间保留原序。
    func stampSteps(_ at: Double?) {
        guard let count = turn?.steps.count, stepTimes.count < count else { return }
        let time = at ?? stepTimes.last ?? 0
        if let last = stepTimes.last, time < last { needsOrder = true }
        stepTimes.append(contentsOf: repeatElement(time, count: count - stepTimes.count))
    }

    func flush() {
        guard let t = turn else { return }
        let disk = ending(turnId, t, finalAnswer)
        var outcome = disk.outcome, reason = disk.error
        var known: [String:Any]?
        if !disk.completed {
            known = knownEndings[turnId]
            // exec 的回包没有轮次编号。同一线程里只有本次调用期间落盘的原问才能认领该结局。
            if known == nil, asked, let start, let prompt = out.last?["text"] as? String {
                let at = start / ticksPerSecond
                known = execEndings.first { row in
                    row["prompt"] as? String == prompt && at >= (row["start"] as? Double ?? .infinity) - 0.001 &&
                        at <= (row["at"] as? Double ?? 0) + 0.001
                }
            }
            if let saved = known?["outcome"] as? String {
                // CLI 崩溃没写结束时刻：按本机收尾的时刻算工作时长，和实时一样
                if let at = known?["at"] as? Double { touch(at * ticksPerSecond) }
                if outcome == "incomplete" || outcome == "completed" { outcome = saved; reason = known?["error"] as? String }
                let body = trimmed(known?["text"] as? String)
                if !body.isEmpty {
                    let recorded = finalAnswer.isEmpty ? trimmed(t.steps.last { $0["kind"] as? String == "text" }?["detail"] as? String) : finalAnswer
                    finalAnswer = restoredEndingText(recorded:recorded, saved:body)
                }
            }
        }
        let order = needsOrder ? stepTimes.indices.sorted {
            stepTimes[$0] == stepTimes[$1] ? $0 < $1 : stepTimes[$0] < stepTimes[$1]
        } : nil
        var bot = t.finish(finalText: finalAnswer, outcome: outcome, error: reason, stepOrder: order)
        if let known { bot["localEndingTurn"] = turnId; bot["endingReqId"] = known["reqId"] }
        if !asked, outcome != "completed", known?["compact"] as? Bool == true { bot["retryPrompt"] = "/compact" }
        stepTimes.removeAll(keepingCapacity: true); needsOrder = false
        if let s = start, let e = end, e > s { bot["duration"] = (e - s) / ticksPerSecond }
        let steps = (bot["steps"] as? [Any]) ?? []
        if !asked, compactions > 0, steps.count == compactions, outcome == "completed", trimmed(bot["text"] as? String).isEmpty {
            // /compact 的回合没有提问、只有压缩条目：实时那边收成一条压缩提示（网页 native-callbacks.js），
            // 历史也记成同一条，切回来对账时条目对得上，不会在提示下面再多出一轮只有「压缩上下文」的回答
            out.append(["role": "compact", "text": codexCompactNote])
        } else if !trimmed(bot["text"] as? String).isEmpty || !steps.isEmpty {
            bot["role"] = "bot"
            out.append(bot)
        }
        turn = nil; turnId = ""; acceptsSteers = false; finalAnswer = ""; asked = false; compactions = 0
    }
}
