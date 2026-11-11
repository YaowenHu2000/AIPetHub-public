// Antigravity 会话库（conversations/<id>.db）里的步骤：protobuf，没有 .proto，只按字段号读。
import Foundation

// steps 表里每一步是一段 protobuf，没有 .proto，只按字段号读：
//   step_type 14 = 用户消息：19.2 是原话
//   step_type 15 = 智能体一步：20.1 是说明 / 正式回答，20.3 是思考摘要，20.7 是发起的工具调用
//   step_type 132 = 工具结果：5.4.2 工具名，5.4.3 参数 JSON，140.2.1 输出
// 这里的内容是完整的；transcript.jsonl 会把长内容截成「<truncated N bytes>」，全文索引要过一阵才建。
/// 极简 protobuf 读取：只取长度型字段（子消息和字符串都是这种）。
struct PBMessage {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    /// 这一层的长度型字段（按出现顺序）；遇到格式不对就停，返回已经读到的部分。
    func lengthFields() -> [(num: Int, value: [UInt8])] {
        var out: [(num: Int, value: [UInt8])] = []
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count {
                let c = bytes[i]
                i += 1
                result |= UInt64(c & 0x7f) << shift
                if c < 0x80 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { break }
            let num = Int(key >> 3)
            switch key & 7 {
            case 0: guard varint() != nil else { return out }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), n <= UInt64(bytes.count - i) else { return out }
                out.append((num, Array(bytes[i..<(i + Int(n))])))
                i += Int(n)
            default: return out
            }
        }
        return out
    }

    func message(_ path: [Int]) -> PBMessage? {
        var cur = self
        for num in path {
            guard let next = cur.lengthFields().first(where: { $0.num == num }) else { return nil }
            cur = PBMessage(bytes: next.value)
        }
        return cur
    }

    func string(_ path: Int...) -> String? {
        guard let m = message(path) else { return nil }
        return String(bytes: m.bytes, encoding: .utf8)
    }
}

/// 把会话库 steps 表的各步（按顺序）还原成和其他两位一样的消息列表：用户消息 + 一次回答（步骤、正式回答、改动文件）。
func agyDbTurns(_ steps: [(type: Int, payload: Data)], cleanUser: (String) -> String) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var turn: TurnBuilder?
    func flush() {
        guard let t = turn else { return }
        var bot = t.finish(finalText: nil)
        if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
            bot["role"] = "bot"
            out.append(bot)
        }
        turn = nil
    }
    for (type, payload) in steps {
        let pb = PBMessage(payload)
        switch type {
        case 14:
            guard let text = pb.string(19, 2), !trimmed(text).isEmpty else { continue }
            flush()
            out.append(["role": "user", "text": cleanUser(text)])
        case 15:
            if turn == nil { turn = TurnBuilder() }
            if let think = pb.string(20, 3), !trimmed(think).isEmpty { turn?.add(makeStep("think", "思考", detail: think)) }
            if let text = pb.string(20, 1), !trimmed(text).isEmpty { turn?.add(makeStep("text", "说明", detail: text)) }
        case 132:
            if turn == nil { turn = TurnBuilder() }
            let name = pb.string(5, 4, 2) ?? "tool"
            let params = (pb.string(5, 4, 3).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            var step = agyToolStep(name: name, params: params)
            if let output = pb.string(140, 2, 1), !trimmed(output).isEmpty { step["output"] = clip(output, maxOutput) }
            turn?.add(step)
            if let path = step["path"] as? String, let kind = step["kind"] as? String, ["edit", "write"].contains(kind) {
                turn?.addFile(path, kind: kind == "write" ? "create" : "edit", diff: agyDiff(params))
            }
        default:
            continue
        }
    }
    flush()
    return out
}
