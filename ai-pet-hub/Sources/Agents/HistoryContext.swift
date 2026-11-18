// 历史只提供记录当时的窗口。保留用量记录自己的时间，标题、工具输出等后续写入不能让它盖过实时明细。
import Foundation
import SQLite3

func contextTime(_ timestamp: String?) -> Double? {
    guard let timestamp else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions.insert(.withFractionalSeconds)
    let date = iso.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    return date.map { ($0.timeIntervalSince1970 * 1000).rounded() }
}

func claudeHistoryContext(_ message: [String: Any], timestamp: String?) -> [String: Any]? {
    guard let usage = message["usage"] as? [String: Any] else { return nil }
    let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
        .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
    guard used > 0 else { return nil }
    // Claude CLI 的原生百万窗口型号。旧型号的长窗口开关未必随回答保存，只能按默认值估算。
    let model = (message["model"] as? String ?? "").lowercased()
    let million = model.contains("[1m]") || used > 200_000 ||
        ["opus-4-7", "opus-4-8", "opus-5", "sonnet-5", "haiku-5-5", "fable-5", "mythos-5"].contains(where: model.contains)
    var result: [String: Any] = ["used": used, "max": million ? 1_000_000 : 200_000, "estimated": true]
    result["at"] = contextTime(timestamp)
    return result
}

func codexContextTokens(total: Int, input: Int, cachedInput: Int, output: Int) -> (used: Int, parts: [[String: Any]]) {
    let cached = min(input, cachedInput)
    let parts = [("cached_input", "Cached input", cached), ("new_input", "New input", input - cached),
                 ("output", "Output", output)].filter { $0.2 > 0 }.map { ["id": $0.0, "name": $0.1, "tokens": $0.2] }
    return (total > 0 ? total : input + output, parts)
}

func deepSeekContextParts(_ breakdown: [String: Any]) -> [[String: Any]] {
    [("system", "System prompt", "systemTokens"), ("tools", "Tools", "toolsTokens"), ("messages", "Messages", "messageTokens")]
        .compactMap { id, name, key in
            guard let tokens = breakdown[key] as? Int, tokens > 0 else { return nil }
            return ["id": id, "name": name, "tokens": tokens]
        }
}

extension AppDelegate {
    /// 从尾部按字节找候选，只解码命中的 JSON；截断行、限额通知和正文引用都不算用量。
    func codexHistoryContext(_ data: Data) -> [String: Any]? {
        var end = data.endIndex
        let marker = Data("\"token_count\"".utf8)
        while let match = data.range(of: marker, options: .backwards, in: data.startIndex..<end) {
            let start = data[..<match.lowerBound].lastIndex(of: 10).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[match.upperBound..<end].firstIndex(of: 10) ?? end
            let line = data[start..<lineEnd]
            end = start
            guard let row = jsonObject(line), row["type"] as? String == "event_msg",
                  let payload = row["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any], let window = info["model_context_window"] as? Int, window > 0,
                  let usage = info["last_token_usage"] as? [String: Any],
                  usage["total_tokens"] is Int || usage["input_tokens"] is Int else { continue }
            let tokens = codexContextTokens(total: usage["total_tokens"] as? Int ?? 0, input: usage["input_tokens"] as? Int ?? 0,
                                            cachedInput: usage["cached_input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0)
            var result: [String: Any] = ["used": tokens.used, "max": window, "parts": tokens.parts]
            result["at"] = contextTime(row["timestamp"] as? String)
            return result
        }
        return nil
    }

    func codexHistoryContext(_ content: String) -> [String: Any]? {
        var content = content
        return content.withUTF8 { bytes in
            guard let address = bytes.baseAddress else { return nil }
            return codexHistoryContext(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: address), count: bytes.count, deallocator: .none))
        }
    }

    /// 完整的压缩投影可以马上显示正文。只有这种情况才需要另行解压，重复打开或后台同步复用结果。
    func loadPackedContext(_ path: String, cid: String) {
        packedContextQueue.async { [self] in
            guard let stamp = modificationDate(path) else { return }
            if packedContextCache[path]?.stamp != stamp {
                guard let content = readRollout(path) else { return }
                packedContextCache[path] = (stamp, codexHistoryContext(content))
            }
            if var data = packedContextCache[path]?.context {
                data["agent"] = "gpt"; data["conversationId"] = cid; data["history"] = true
                sendToJS("onAgentContext", data)
            }
        }
    }

    func geminiHistoryContext(_ cid: String) -> [String: Any]? {
        withReadableSQLite(geminiConversationDb(cid)) { db -> [String: Any]? in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT data, idx FROM gen_metadata ORDER BY idx DESC", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let gen = PBMessage(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blob), count: Int(sqlite3_column_bytes(stmt, 0)), deallocator: .none))
                // agy 内嵌的 ContextWindowMetadata 同时给出 estimated_tokens_used 和 max_context_tokens。
                guard let start = gen.message([1, 9]), let window = start.message([10]),
                      let used = window.integer(1).flatMap(Int32.init(exactly:)), used >= 0,
                      let max = window.integer(4).flatMap(Int32.init(exactly:)), max > 0 else { continue }
                var result: [String: Any] = ["used": Int(used), "max": Int(max), "estimated": true, "seq": sqlite3_column_int64(stmt, 1)]
                var created = start.message([4])
                if created == nil, let step = gen.message([2])?.firstVarint {
                    // 有的版本只在对应 step 的 metadata 里保留生成时间。用本轮的步号，避免混入后来写的步骤。
                    queryRows(db, "SELECT metadata FROM steps WHERE idx=?", [String(step)]) { row in
                        if let ptr = sqlite3_column_blob(row, 0) {
                            created = PBMessage(Data(bytes: ptr, count: Int(sqlite3_column_bytes(row, 0)))).message([1])
                        }
                    }
                }
                if let seconds = created?.integer(1) {
                    result["at"] = Double(seconds) * 1000 + Double(created?.integer(2) ?? 0) / 1_000_000
                }
                return result
            }
            return nil
        } ?? nil
    }
}
