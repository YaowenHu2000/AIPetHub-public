// 一轮回答的统一模型：工作步骤 + 正文 + 改动的文件。各家 CLI 的事件都转换成它。
import Foundation

let outputLimitHint = "这一轮达到输出上限，没有写完。可以发一句「继续」。"

// 把四位 CLI 的实时事件和历史记录统一成「一次回答」：工作步骤 + 正式回答 + 改动的文件。
// 网页据此显示可折叠的「已工作 N 秒」、正文和文件卡片（参考反重力）。
let maxDetail = 2000

let maxOutput = 1500

let maxDiff = 60_000

/// 正在写的回答多久往界面推一次。界面只重画最后还在变的那一截（见 markdown.js 的 streamSplit），推得密也不费事；
/// 以前是 0.25–0.4 秒一次，字是一小撮一小撮蹦出来的。
let textPushInterval = 0.07

/// 只走前 n 个字符就判断是否超长：历史里的长输出多是桥接的 NSString，先 count 整段会让 Claude 长会话每次打开都慢上数秒。
func clip(_ s: String, _ n: Int) -> String {
    let head = s.prefix(n)
    return head.endIndex == s.endIndex ? s : String(head) + "…"
}

func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

func fileBaseName(_ p: String) -> String { (p as NSString).lastPathComponent }

func lineCount(_ s: String) -> Int {
    guard !s.isEmpty else { return 0 }
    return s.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (s.utf8.last == 10 ? 0 : 1)
}

private func patchLines(_ text: String) -> [Substring] {
    guard !text.isEmpty else { return [] }
    let lf = text.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = lf.split(separator: "\n", omittingEmptySubsequences: false)
    if lf.hasSuffix("\n") { lines.removeLast() }
    return lines
}

func diffCounts(_ diff: String) -> (added: Int, removed: Int) {
    var added = 0, removed = 0, oldLeft = 0, newLeft = 0
    func span(_ field: Substring) -> Int { field.split(separator: ",").dropFirst().first.flatMap { Int($0) } ?? 1 }
    for line in patchLines(diff) {
        if line.hasPrefix("@@") {
            let fields = line.split(separator: " ", maxSplits: 3)
            if fields.count >= 3, fields[1].hasPrefix("-"), fields[2].hasPrefix("+") {
                oldLeft = span(fields[1]); newLeft = span(fields[2])
            } else { oldLeft = Int.max; newLeft = Int.max }
            continue
        }
        if line.hasPrefix("diff --git ") { oldLeft = 0; newLeft = 0; continue }
        // hunk 里的 --- 和 +++ 可以是 Markdown 正文；只有段外的文件头才跳过。
        if oldLeft == 0 && newLeft == 0 && (line.hasPrefix("--- ") || line.hasPrefix("+++ ")) { continue }
        switch line.first {
        case "+": added += 1; if newLeft > 0 { newLeft -= 1 }
        case "-": removed += 1; if oldLeft > 0 { oldLeft -= 1 }
        case " ":
            if oldLeft > 0 { oldLeft -= 1 }
            if newLeft > 0 { newLeft -= 1 }
        default: break
        }
    }
    return (added, removed)
}

/// 没有现成 diff 时，用「旧内容全删、新内容全加」表示一次替换；每段以 @@ 开头，前端据此逐段定位到文件里。
func simpleDiff(old: String, new: String) -> String {
    (["@@"] + patchLines(old).map { "-" + $0 } + patchLines(new).map { "+" + $0 }).joined(separator: "\n")
}

/// 逐行的增删序列（" " 未改、"-" 删、"+" 加）→ 只带改动前后 3 行上下文、像 git diff 一样按 @@ 分段的 diff。
/// 上下文是整份文件时，预览不必带整份文件，截到长度上限后也还看得到改动；增删行数和整份序列一样。
/// fromFirstLine：序列从文件第 1 行开始时写上行号，网页先按行号找位置；只是文件里的一段时写裸 @@，网页按内容找。
func contextDiff(_ ops: [(sign: Character, text: String)], fromFirstLine: Bool, context: Int = 3) -> String {
    var ranges: [Range<Int>] = []
    for i in ops.indices where ops[i].sign != " " {
        let lo = max(0, i - context), hi = min(ops.count, i + context + 1)
        if let last = ranges.last, lo <= last.upperBound { ranges[ranges.count - 1] = last.lowerBound..<hi } else { ranges.append(lo..<hi) }
    }
    var out: [String] = [], old = 0, new = 0, at = 0
    for range in ranges {
        old += range.lowerBound - at; new += range.lowerBound - at   // 两段之间都是未改的行
        let part = ops[range]
        let oldCount = part.filter { $0.sign != "+" }.count, newCount = part.filter { $0.sign != "-" }.count
        out.append(fromFirstLine ? "@@ -\(oldCount == 0 ? old : old + 1),\(oldCount) +\(newCount == 0 ? new : new + 1),\(newCount) @@" : "@@")
        out += part.map { String($0.sign) + $0.text }
        old += oldCount; new += newCount; at = range.upperBound
    }
    return out.joined(separator: "\n")
}

/// 文件里的一段原文换成新文，逐行比对（最少增删）出真正改了的行，没改的留作上下文；不知道这段在第几行，用裸 @@。
/// 原文为了在文件里唯一常带着没改的行，整段算成删了重写会把它们同时记成增删。
/// 整段原文都留作上下文、不裁到 3 行：网页只能靠内容找位置，离改动远的那行往往正是让这段唯一的锚点，裁掉会标到别处同样的结构上。
func lineDiff(old: String, new: String) -> String {
    let a = patchLines(old).map(String.init), b = patchLines(new).map(String.init)
    var removed = Set<Int>(), inserted = Set<Int>()
    for change in b.difference(from: a) {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    var ops: [(sign: Character, text: String)] = [], i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, removed.contains(i) { ops.append(("-", a[i])); i += 1 }
        else if j < b.count, inserted.contains(j) { ops.append(("+", b[j])); j += 1 }
        else if i < a.count, j < b.count { ops.append((" ", b[j])); i += 1; j += 1 }
        else { break }
    }
    return contextDiff(ops, fromFirstLine: false, context: ops.count)
}

func makeStep(_ kind: String, _ title: String, detail: String? = nil, path: String? = nil, status: String = "ok") -> [String: Any] {
    var step: [String: Any] = ["kind": kind, "title": title, "status": status]
    // 正文和用户原话不能丢；工具说明仍限制长度
    if let d = detail, !d.isEmpty { step["detail"] = ["text", "user"].contains(kind) ? d : clip(d, maxDetail) }
    if let p = path, !p.isEmpty { step["path"] = p }
    return step
}

func textOf(_ content: Any?) -> String {
    if let s = content as? String { return s }
    if let blocks = content as? [[String: Any]] {
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    if let strings = content as? [String] { return strings.joined(separator: "\n") }
    return ""
}

/// 只在来源已认领同一次异常结束后使用。CLI 可能晚写全正文，也可能只留下工具前的说明。
func restoredEndingText(recorded: String, saved: String) -> String {
    if saved.isEmpty || recorded.hasPrefix(saved) { return recorded }
    // 最近结局的备份有字数上限，截断符也要从前缀比较里去掉。
    if saved.hasSuffix("…"), saved.count == endingTextLimit + 1, recorded.hasPrefix(saved.dropLast()) { return recorded }
    return saved
}

let endingTextLimit = 50_000

final class TurnBuilder {
    private(set) var steps: [[String: Any]] = []
    private var keyIndex: [String: Int] = [:]
    private var files: [String: [String: Any]] = [:]
    private var fileOrder: [String] = []
    /// 实时模式下每次新增 / 更新步骤都回调（用于推给网页）。
    var onChange: ((Int, [String: Any]) -> Void)?

    @discardableResult
    func add(_ step: [String: Any], key: String? = nil) -> Int {
        steps.append(step)
        let i = steps.count - 1
        if let key = key { keyIndex[key] = i }
        onChange?(i, step)
        return i
    }

    /// 连续的、看不到内容的「思考」合并成一步。
    func addThink(_ detail: String) {
        if detail.isEmpty, let last = steps.last, last["kind"] as? String == "think", last["detail"] == nil { return }
        add(makeStep("think", "思考", detail: detail))
    }

    func step(_ key: String) -> [String: Any]? { keyIndex[key].map { steps[$0] } }

    func update(_ key: String, _ fields: [String: Any]) {
        guard let i = keyIndex[key] else { return }
        let interrupted = steps[i]["status"] as? String == "interrupted"
        fields.forEach { steps[i][$0.key] = $0.value }
        // 有的 CLI 把取消回执也报成 failed。保留输出和真正完成的结果，避免已停止的工具又变红或转圈。
        if interrupted, let status = fields["status"] as? String, status == "error" || status == "running" {
            steps[i]["status"] = "interrupted"
        }
        onChange?(i, steps[i])
    }

    func interruptRunningTools() {
        for i in steps.indices where steps[i]["status"] as? String == "running" {
            if ["text", "think", "error"].contains(steps[i]["kind"] as? String ?? "") { continue }
            steps[i]["status"] = "interrupted"
            onChange?(i, steps[i])
        }
    }

    func addFile(_ path: String, kind: String, diff: String? = nil) {
        guard !path.isEmpty else { return }
        var f = files[path] ?? ["path": path, "kind": kind, "added": 0, "removed": 0]
        if files[path] == nil { fileOrder.append(path) }
        if let d = diff, !d.isEmpty {
            let c = diffCounts(d)
            f["added"] = (f["added"] as? Int ?? 0) + c.added
            f["removed"] = (f["removed"] as? Int ?? 0) + c.removed
            let joined = ((f["diff"] as? String).map { $0 + "\n" } ?? "") + d
            if joined.count > maxDiff { f["truncated"] = true }
            f["diff"] = joined.count > maxDiff ? String(joined.prefix(maxDiff)) : joined
        }
        if kind == "create" || kind == "delete" { f["kind"] = kind }
        files[path] = f
    }

    var isEmpty: Bool { steps.isEmpty && files.isEmpty }

    /// 最后一段说明文字就是正式回答；和 finalText 相同就从步骤里拿掉。
    /// outcome：completed / failed / interrupted / incomplete；非正常结局保留正文并附上原因。
    func finish(finalText: String?, outcome: String = "completed", error: String? = nil, stepOrder: [Int]? = nil, includeEnding: Bool = true) -> [String: Any] {
        var final = trimmed(finalText)
        var out = stepOrder?.map { steps[$0] } ?? steps
        if let i = out.lastIndex(where: { $0["kind"] as? String == "text" }) {
            let t = trimmed(out[i]["detail"] as? String)
            if final.isEmpty { final = t; out.remove(at: i) } else if t == final { out.remove(at: i) }
        }
        if outcome == "interrupted" {
            // 只改 CLI 明确写成取消的工具回执，保留同轮更早的普通命令错误。
            let cancelled = ["interrupted by user", "error: interrupted by user", "tool use was interrupted by a message from the user",
                             "[request interrupted by user for tool use]", "tool call aborted before dispatch"]
            for j in out.indices where out[j]["status"] as? String == "error" {
                let receipt = trimmed(out[j]["output"] as? String).lowercased()
                if cancelled.contains(receipt) || receipt.hasSuffix("<error>command was aborted before completion</error>") {
                    out[j]["status"] = "interrupted"
                }
            }
        }
        // 进程结束不代表工具成功；只有工具结果才能把它变成 ok。
        for j in out.indices where out[j]["status"] as? String == "running" {
            if outcome == "interrupted" { out[j]["status"] = "interrupted" }
            else if outcome == "failed" { out[j]["status"] = "error" }
            else if outcome == "completed", ["text", "think"].contains(out[j]["kind"] as? String ?? "") { out[j]["status"] = "ok" }
        }
        if includeEnding, outcome != "completed" {
            let title = outcome == "failed" ? "出错" : (outcome == "interrupted" ? "已中断" : "未完成")
            let fallback = outcome == "failed" ? "这一轮出错了。" : (outcome == "interrupted" ? "这一轮已中断。" : "记录到这里就断了，这一轮还没写完。")
            let ending = makeStep("error", title, detail: trimmed(error).isEmpty ? fallback : error, status: outcome == "interrupted" ? "interrupted" : "error")
            // 解析器可能已经实时展示了同一个终态错误，收尾时不重复列两次。
            if out.last?["kind"] as? String == "error", out.last?["detail"] as? String == ending["detail"] as? String { out.removeLast() }
            out.append(ending)
        }
        return ["outcome": outcome, "text": final, "steps": out, "files": fileOrder.compactMap { files[$0] }]
    }
}
