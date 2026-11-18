// Antigravity 会话库（conversations/<id>.db）里的步骤：protobuf，没有 .proto，只按字段号读。
import Foundation

// steps 表里每一步是一段 protobuf，没有 .proto，只按字段号读：
//   step_type 14 = 用户消息：19.2 是原话
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

/// 把会话库 steps 表的各步（按顺序）还原成和其他两位一样的消息列表：用户消息 + 一次回答（步骤、正式回答、改动文件）。
func agyDbTurns(_ steps: [(type: Int, payload: Data)], isHeld: () -> Bool? = { nil },
                retryEnded: () -> Bool = { false }, cleanUser: (String) -> String) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var turn: TurnBuilder?
    var retries = AgyRetries()
    var interrupted = false
    var latestError = ""
    lazy var held = isHeld()
    func flush(atEnd: Bool = false) {
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
            bot["role"] = "bot"
            out.append(bot)
        }
        turn = nil; retries = AgyRetries(); interrupted = false
    }
    for (index, row) in steps.enumerated() {
        let (type, payload) = row
        let pb = PBMessage(payload)
        switch type {
        case 14:
            guard let text = pb.string(19, 2), !trimmed(text).isEmpty else { continue }
            flush()
            out.append(["role": "user", "text": cleanUser(text)])
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
            flush()
            out.append(["role": "compact", "text": "已压缩上下文"])
        case 132:
            if turn == nil { turn = TurnBuilder() }
            let name = pb.string(5, 4, 2) ?? "tool"
            let params = (pb.string(5, 4, 3).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            var step = agyToolStep(name: name, params: params)
            // agy 内嵌的 CortexStepStatus 枚举：3 完成，4 无效、6 取消、7 失败、12 中断。
            let recorded = pb.integer(4)
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
                turn?.addFile(path, kind: kind == "write" ? "create" : "edit", diff: agyDiff(params))
            }
        default:
            continue
        }
    }
    flush(atEnd: true)
    return out
}
