// 一轮回答的统一模型：工作步骤 + 正文 + 改动的文件。各家 CLI 的事件都转换成它。
import Foundation

// 把三个 CLI 的实时事件和历史记录统一成「一次回答」：工作步骤 + 正式回答 + 改动的文件。
// 网页据此显示可折叠的「已工作 N 秒」、正文和文件卡片（参考反重力）。
let maxDetail = 2000

let maxOutput = 1500

let maxDiff = 60_000

/// 正在写的回答多久往界面推一次。界面只重画最后还在变的那一截（见 markdown.js 的 streamSplit），推得密也不费事；
/// 以前是 0.25–0.4 秒一次，字是一小撮一小撮蹦出来的。
let textPushInterval = 0.07

func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

func fileBaseName(_ p: String) -> String { (p as NSString).lastPathComponent }

func lineCount(_ s: String) -> Int {
    if s.isEmpty { return 0 }
    let n = s.split(separator: "\n", omittingEmptySubsequences: false).count
    return s.hasSuffix("\n") ? n - 1 : n
}

func diffCounts(_ diff: String) -> (added: Int, removed: Int) {
    var added = 0, removed = 0
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
        if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
    }
    return (added, removed)
}

/// 没有现成 diff 时，用「旧内容全删、新内容全加」表示一次替换；每段以 @@ 开头，前端据此逐段定位到文件里。
func simpleDiff(old: String, new: String) -> String {
    var out: [String] = ["@@"]
    if !old.isEmpty { out += old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 } }
    if !new.isEmpty { out += new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 } }
    return out.joined(separator: "\n")
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
