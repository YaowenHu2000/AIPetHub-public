// Antigravity 会话库（conversations/<id>.db）里的步骤：protobuf，没有 .proto，只按字段号读。
import Foundation

// steps 表里每一步是一段 protobuf，没有 .proto，只按字段号读：
//   step_type 14 = 用户消息：19.2 是原话（桌面版常为空，原话按段在重复的 19.3.1 里），19.9 是附件
//   step_type 15 = 智能体一步：20.1 是说明 / 正式回答，20.3 是思考摘要，20.7 是发起的工具调用
//   step_type 132 = 工具结果：5.4.2 工具名，5.4.3 参数 JSON，140.2.1 输出；4 是状态，31 是错误说明
// 2026-11-17 已按本机 agy 内嵌的 Step / CortexStepStatus / CortexErrorDetails 描述核对字段号。
// 这里的内容是完整的；transcript.jsonl 会把长内容截成「<truncated N bytes>」（transcript_full.jsonl 不截），全文索引要过一阵才建。
/// 按字段号读子消息 / 字符串和状态枚举，不把工具失败猜成成功。
struct PBMessage {
    let bytes: Data

    init(_ data: Data) { bytes = data }

    private func varint(_ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.endIndex {
            let c = bytes[i]
            i += 1
            result |= UInt64(c & 0x7f) << shift
            if c < 0x80 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    var firstVarint: UInt64? {
        var i = bytes.startIndex
        return varint(&i)
    }

    /// 遇到格式不对就停，返回已经读到的部分。
    private func fields() -> (lengths: [(num: Int, value: Data)], integers: [Int: UInt64]) {
        var out: [(num: Int, value: Data)] = []
        var integers: [Int: UInt64] = [:]
        var i = bytes.startIndex
        while i < bytes.endIndex {
            guard let key = varint(&i) else { break }
            let num = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint(&i) else { return (out, integers) }
                integers[num] = value
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(&i), n <= UInt64(bytes.endIndex - i) else { return (out, integers) }
                out.append((num, bytes[i..<(i + Int(n))]))
                i += Int(n)
            default: return (out, integers)
            }
        }
        return (out, integers)
    }

    func lengthFields() -> [(num: Int, value: Data)] { fields().lengths }
    func integer(_ number: Int) -> UInt64? { fields().integers[number] }

    func message(_ path: [Int]) -> PBMessage? {
        var cur = self
        for num in path {
            guard let next = cur.lengthFields().first(where: { $0.num == num }) else { return nil }
            cur = PBMessage(next.value)
        }
        return cur
    }

    func string(_ path: Int...) -> String? {
        guard let m = message(path) else { return nil }
        return String(bytes: m.bytes, encoding: .utf8)
    }
}

// 桌面版的替换参数含未改的上下文；以工具实际返回的补丁为准，不能把整段算成删了重写。
// 补丁是一个从第 1 行起、带着整份文件的 hunk（2026-11-19 本机 754 条全是），diff 只留改动附近，行数仍按整个补丁数。
private func agyRecordedDiff(_ step: PBMessage, path: String) -> String? {
    guard let result = step.message([140,2,6]), result.string(1) == "type.googleapis.com/exa.cortex.core.tools.FileEdit",
          let edit = result.message([2]), edit.string(2) == path, let patch = edit.message([3]) else { return nil }
    let hunks = patch.lengthFields().filter { $0.num == 3 }.map { PBMessage($0.value).lengthFields().filter { $0.num == 3 } }.filter { !$0.isEmpty }
    guard !hunks.isEmpty else { return nil }
    var parts: [String] = []
    for hunk in hunks {
        var ops: [(sign: Character, text: String)] = []
        for (_, bytes) in hunk {
            let line = PBMessage(bytes)
            guard let kind = line.integer(2), let sign: Character = [1:"+",2:"-",3:" "][kind] else { return nil }
            ops.append((sign, line.string(1) ?? ""))
        }
        let part = contextDiff(ops, fromFirstLine: hunks.count == 1)
        if !part.isEmpty { parts.append(part) }
    }
    return parts.joined(separator:"\n")
}

/// 用户步骤 19.9 里的图片附件 → 和其他几位一样的图片来源。2026-11-18 实测：1 是类型，
/// agy acp 收到的图片字节在 2，5 的落盘路径并不存在；桌面版没有 2，原图在 5 指向的文件（6 只是小缩略图）。
/// ref 是「步骤序号#附件序号」，点开原图时按它回库里取（GeminiHistory.swift 的 geminiAttachedImage）。
func agyImageSources(_ pb: PBMessage, step: Int) -> [[String: Any]] {
    let attachments = (pb.message([19])?.lengthFields() ?? []).filter { $0.num == 9 }.map { PBMessage($0.value) }
    return attachments.enumerated().compactMap { k, a in
        let path = a.string(5) ?? ""
        guard (a.string(1) ?? "").hasPrefix("image/") || chatImageExts.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        if let bytes = a.message([2])?.bytes, !bytes.isEmpty { return ["data": bytes.base64EncodedString(), "ref": "\(step)#\(k)"] }
        return path.isEmpty ? nil : ["path": path]
    }
}

/// /compact 这一轮在会话库里留没留下会读成历史条目的东西：直接用下面的 agyDbTurns 读最后一句提问之后的各步，口径和重开时一致。
/// agy 不回报 /compact 的结果，只能回会话库里看。2026-11-18 本机 agy 1.5.11 实测：有对话时 /compact 记成「提问 14 → 压缩 23（状态 3）」；
/// 对着空会话发、或最高权限退回 agy -p（加了 --disable-slash-commands）时当成普通提问作答，留下的是一条回答。
/// 两种都让记录多一条（网页会滤掉 user「/compact」），实时提示都要算；压缩失败（状态 7）或什么都没写时不算。
func agyCompactedAfterLastAsk(_ steps: [(type: Int, payload: Data)]) -> Bool {
    let start = (steps.lastIndex { $0.type == 14 } ?? -1) + 1
    return !agyDbTurns(Array(steps[start...]), cleanUser: { $0 }).isEmpty
}

/// 把会话库 steps 表的各步（按顺序）还原成和其他两位一样的消息列表：用户消息 + 一次回答（步骤、正式回答、改动文件）。
/// steps 表的 idx 从 0 连续（2026-11-18 本机 CLI 和桌面版 60 多个会话库全是如此），所以各步在数组里的位置就是转写里的 step_index；
/// finalStatus 按它给出转写记的最终状态（DONE / ERROR …），只在遇到状态 5 时才问。
func agyDbTurns(_ steps: [(type: Int, payload: Data)], isHeld: () -> Bool? = { nil },
                retryEnded: () -> Bool = { false }, finalStatus: (Int) -> String? = { _ in nil },
                cleanUser: (String) -> String) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var turn: TurnBuilder?
    var retries = AgyRetries()
    var interrupted = false
    var latestError = ""
    var startAt: Double?, endAt: Double?
    // 最近一句提问是不是手动压缩命令。没见过提问时（如 agyCompactedAfterLastAsk 只读最后一句之后）按手动处理。
    var manualCompact = true
    lazy var held = isHeld()
    func flush(atEnd: Bool = false) {
        defer { startAt = nil; endAt = nil }
        guard let t = turn else { return }
        let pending = !retries.isEmpty
        var outcome = interrupted ? "interrupted" : "completed"
        if pending {
            // 新提问或 checkpoint 能确认上一轮已经结束。读到文件末尾时，仍在工作的 agy 可能还会继续重试。
            if atEnd && held != false && !retryEnded() { outcome = "inProgress" }
            else { retries.finish(in: t, recovered: false); outcome = "failed" }
        }
        let notice = outcome == "failed" ? agyFailureNotice(latestError.isEmpty ? "agy 返回了 ERROR" : latestError).text : nil
        var bot = t.finish(finalText: notice, outcome: outcome, includeEnding: !pending)
        if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
            if let startAt, let endAt, endAt > startAt { bot["duration"] = endAt - startAt }
            bot["role"] = "bot"
            out.append(bot)
        }
        turn = nil; retries = AgyRetries(); interrupted = false
    }
    for (index, row) in steps.enumerated() {
        let (type, payload) = row
        let pb = PBMessage(payload)
        let metadata = pb.message([5])
        func timestamp(_ field: Int) -> Double? {
            guard let date = metadata?.message([field]), let seconds = date.integer(1) else { return nil }
            return Double(seconds) + Double(date.integer(2) ?? 0) / 1e9
        }
        if [15, 17, 132].contains(type) {
            let created = timestamp(1)
            if startAt == nil { startAt = created }
            // 工具和回答可能分几步完成；旧记录只有创建时间时用最后一个可用的时间。
            if let last = timestamp(8) ?? timestamp(7) ?? timestamp(6) ?? created { endAt = max(endAt ?? last, last) }
        }
        switch type {
        case 14:
            // 反重力桌面版的长会话常把 19.2 留空、原话按段拆进重复的 19.3.1；没有文字也是一次提问，照样切开上一轮。
            flush()
            startAt = timestamp(1)
            var text = pb.string(19, 2) ?? ""
            if trimmed(text).isEmpty {
                text = (pb.message([19])?.lengthFields() ?? []).filter { $0.num == 3 }.compactMap { PBMessage($0.value).string(1) }.joined()
            }
            manualCompact = ["/compact", "/compress"].contains(trimmed(text))
            let images = agyImageSources(pb, step: index)
            guard !trimmed(text).isEmpty || !images.isEmpty else { continue }
            var user: [String: Any] = ["role": "user", "text": cleanUser(text)]
            user["createdAt"] = startAt
            // 本机补记的开始时间可能早于落库，只有数据库自己的时间能标识同文的新提问。
            user["turnKey"] = startAt
            if !images.isEmpty { user["imageSources"] = images }
            out.append(user)
        case 15:
            interrupted = false
            if turn == nil { turn = TurnBuilder() }
            if !retries.isEmpty, let t = turn { retries.finish(in: t, recovered: true, after: index) }
            if let think = pb.string(20, 3), !trimmed(think).isEmpty { turn?.add(makeStep("think", "思考", detail: think)) }
            if let text = pb.string(20, 1), !trimmed(text).isEmpty { turn?.add(makeStep("text", "说明", detail: text)) }
        case 17:
            if turn == nil { turn = TurnBuilder() }
            let detail = trimmed(pb.string(24, 3, 2) ?? pb.string(24, 3, 1) ?? pb.string(31, 2))
            if retries.isEmpty || !detail.isEmpty { latestError = detail }
            if let t = turn { retries.note(in: t, at: index, detail: detail) }
        case 23 where pb.integer(4) == 3:
            // 手动 /compact、/compress 是一条独立提示；普通提问作答途中 agy 自动压缩，实时只有一张回答卡，
            // 这里也记成这一轮的一步（和 Claude、Codex、DeepSeek 一样），其后的正文、结局和「重试」都归回原问。
            if manualCompact {
                flush()
                out.append(["role": "compact", "text": "已压缩上下文"])
            } else {
                if turn == nil { turn = TurnBuilder() }
                turn?.add(makeStep("tool", "压缩上下文", status: "ok"))
            }
        case 132:
            if turn == nil { turn = TurnBuilder() }
            let name = pb.string(5, 4, 2) ?? "tool"
            let params = (pb.string(5, 4, 3).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            var step = agyToolStep(name: name, params: params)
            // agy 内嵌的 CortexStepStatus 枚举：3 完成，4 无效、6 取消、7 失败、12 中断。
            var recorded = pb.integer(4)
            // 反重力桌面版把已经结束的步骤也留成 5，最终结果只写在转写里；转写读不到或也没结束时照旧按未完成处理。
            if recorded == 5, let final = finalStatus(index).flatMap({ ["DONE": UInt64(3), "ERROR": 7][$0] }) { recorded = final }
            interrupted = recorded == 6 || recorded == 12
            let failed = recorded == 4 || recorded == 7
            var status = interrupted ? "interrupted" : (failed ? "error" : (recorded == nil || recorded == 3 ? "ok" : "running"))
            if status == "running" {
                // agy 在会话打开期间持续持有库。异常退出会留下一条 RUNNING，检查失败时仍保留原状态。
                if held == false { status = "error" }
            }
            if !retries.isEmpty, let t = turn { retries.finish(in: t, recovered: true, after: index) }
            step["status"] = status
            var output = pb.string(140, 2, 1) ?? ""
            if failed || interrupted, let error = [pb.string(31, 1), pb.string(31, 2), pb.string(31, 3)].compactMap({ $0 }).first(where: { !trimmed($0).isEmpty }), !output.contains(error) {
                output = error + (output.isEmpty ? "" : "\n" + output)
            }
            if !trimmed(output).isEmpty { step["output"] = clip(output, maxOutput) }
            turn?.add(step)
            if status == "ok", let path = step["path"] as? String, let kind = step["kind"] as? String, ["edit", "write"].contains(kind) {
                turn?.addFile(path, kind: kind == "write" ? "create" : "edit", diff: agyRecordedDiff(pb,path:path) ?? agyDiff(params))
            }
        default:
            continue
        }
    }
    flush(atEnd: true)
    return out
}
