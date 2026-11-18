// Gemini（Antigravity CLI）的历史会话：读每个会话自己的数据库，读不到时退回全文索引和 transcript。
import Cocoa
import SQLite3

extension AppDelegate {
    /// 会话的文字记录。transcript.jsonl 会把长内容截成「<truncated N bytes>」，旁边的 transcript_full.jsonl 是完整的，有就用它。
    func geminiTranscriptPath(_ cid: String) -> String {
        let logs = "\(geminiStore(cid).brain)/\(geminiRawId(cid))/.system_generated/logs"
        let full = "\(logs)/transcript_full.jsonl"
        return fm.fileExists(atPath: full) ? full : "\(logs)/transcript.jsonl"
    }

    func geminiMessages(_ content: String) -> [[String: String]] {
        var messages: [[String: String]] = []
        for line in content.utf8.split(separator: 0x0A) {
            guard let obj = jsonObject(Data(line)), let type = obj["type"] as? String,
                  let text = obj["content"] as? String else { continue }
            if type == "USER_INPUT" {
                let cleaned = stripPersonaPrefix(text)
                if !cleaned.isEmpty { messages.append(["role": "user", "text": cleaned]) }
            } else if type == "PLANNER_RESPONSE" {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { messages.append(["role": "bot", "text": trimmed]) }
            }
        }
        return messages
    }

    /// workspace_uris 形如 ["file:///Users/x/proj"]，取第一个转成路径。
    func firstWorkspacePath(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              let first = uris.first else { return "" }
        if first.hasPrefix("file://"), let url = URL(string: first) { return url.path }
        return first
    }

    /// agy 自己的会话摘要库：每个会话的标题、工作空间、时间。
    func listGemini() {
        geminiQueue.async { [self] in
            var items: [[String: Any]] = []
            var seen = Set<String>()
            for store in geminiStores {
                appendGeminiHistory(store, items: &items, seen: &seen)
            }
            items.sort { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
            sendToJS("onConversationsListed", ["agent": "gemini", "items": Array(items.prefix(historyListLimit))])
        }
    }

    private func appendGeminiHistory(_ store: GeminiStore, items: inout [[String: Any]], seen: inout Set<String>) {
        _ = withReadableSQLite(store.summaries) { db in
            let sql = """
                SELECT conversation_id, title, preview, CAST(strftime('%s', last_modified_time) AS INTEGER), workspace_uris
                FROM conversation_summaries WHERE nesting_depth = 0 AND parent_conversation_id = ''
                ORDER BY last_modified_time DESC;
                """
            queryRows(db, sql) { s in
                let id = columnText(s, 0)
                guard isSafeId(id), fm.fileExists(atPath: store.database(id)) else { return }
                let cid = geminiKey(id, in: store)
                guard seen.insert(cid).inserted else { return }
                let title = columnText(s, 1).trimmingCharacters(in: .whitespacesAndNewlines)
                let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 3)))
                items.append(["id": cid,
                              "title": titleFrom(title.isEmpty ? stripPersonaPrefix(columnText(s, 2)) : title, fallbackId: id),
                              "time": timeLabel(date), "timestamp": date.timeIntervalSince1970,
                              "cwd": firstWorkspacePath(columnText(s, 4))])
            }
        }

        // 摘要库里没有的旧会话：退回读 brain 目录下的转写
        for id in (try? fm.contentsOfDirectory(atPath: store.brain)) ?? [] where isSafeId(id) {
            let cid = geminiKey(id, in: store)
            guard !seen.contains(cid) else { continue }
            let path = geminiTranscriptPath(cid)
            guard let mtime = modificationDate(path) else { continue }
            seen.insert(cid)
            let ts = mtime.timeIntervalSince1970
            if let cached = geminiCache[cid], abs(cached.mtime - ts) < 0.001 {
                if let item = cached.item { items.append(item) }
                continue
            }
            var item: [String: Any]?
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let messages = geminiMessages(content)
                if let firstUser = messages.first(where: { $0["role"] == "user" })?["text"] {
                    item = ["id": cid, "title": titleFrom(firstUser, fallbackId: id),
                            "time": timeLabel(mtime), "timestamp": ts, "cwd": ""]
                }
            }
            geminiCache[cid] = (ts, item)
            if let item = item { items.append(item) }
        }
    }

    /// 摘要库里工作空间是 target 的全部会话（brain 兜底的旧会话没有工作空间，不会匹配）。
    func geminiIds(inWorkspace target: String) -> [String] {
        var ids = Set<String>()
        for store in geminiStores {
            _ = withReadableSQLite(store.summaries) { db in
                let sql = """
                    SELECT conversation_id, workspace_uris FROM conversation_summaries
                    WHERE nesting_depth = 0 AND parent_conversation_id = '';
                    """
                queryRows(db, sql) { s in
                    let cid = columnText(s, 0)
                    guard isSafeId(cid), fm.fileExists(atPath: store.database(cid)),
                          trimmedPath(firstWorkspacePath(columnText(s, 1))) == target else { return }
                    ids.insert(geminiKey(cid, in: store))
                }
            }
        }
        return Array(ids)
    }

    /// 从 agy 的全文索引还原对话：user_body / agent_body 按每步的字节偏移切开，再按步序合并。
    func geminiIndexedConversation(cid: String) -> (messages: [[String: String]], cwd: String) {
        var parts: [(step: Int, role: String, text: String)] = []
        var cwd = ""
        _ = withReadableSQLite(geminiStore(cid).summaries) { db in
            queryRows(db, "SELECT workspace_uris FROM conversation_summaries WHERE conversation_id = ? LIMIT 1;", [geminiRawId(cid)]) { s in
                cwd = firstWorkspacePath(columnText(s, 0))
            }
            let sql = """
                SELECT user_step_byte_offsets, agent_step_byte_offsets, user_body, agent_body
                FROM conversations_fts WHERE conversation_id = ? AND chunk_index >= 0 ORDER BY chunk_index;
                """
            queryRows(db, sql, [geminiRawId(cid)]) { s in
                for (role, offsetCol, bodyCol) in [("user", Int32(0), Int32(2)), ("bot", Int32(1), Int32(3))] {
                    guard let data = columnText(s, offsetCol).data(using: .utf8),
                          let offsets = (try? JSONSerialization.jsonObject(with: data)) as? [[Int]] else { continue }
                    let body = Data(columnText(s, bodyCol).utf8)
                    for (i, pair) in offsets.enumerated() where pair.count == 2 {
                        let start = pair[1]
                        let end = i + 1 < offsets.count && offsets[i + 1].count == 2 ? offsets[i + 1][1] : body.count
                        guard start >= 0, start <= end, end <= body.count else { continue }
                        let raw = String(decoding: body[start..<end], as: UTF8.self)
                        let text = role == "user" ? stripPersonaPrefix(raw) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { parts.append((pair[0], role, text)) }
                    }
                }
            }
        }
        parts.sort { $0.step < $1.step }
        return (parts.map { ["role": $0.role, "text": $0.text] }, cwd)
    }

    /// 搜索和打开会话必须使用相同的数据库 / 索引 / transcript 回退顺序。
    func readGeminiConversation(cid: String, databasePath: String? = nil) -> [String: Any] {
        let rows = geminiDbSteps(cid: cid, databasePath: databasePath)
        let fromDb = agyDbTurns(rows, isHeld: { self.geminiSessionHeld(cid, includingOwn: true, databasePath: databasePath) },
                                retryEnded: { self.geminiRetryEnded(cid: cid, stepCount: rows.count) },
                                cleanUser: { self.stripPersonaPrefix($0) })
        if fromDb.contains(where: { ["bot", "compact"].contains($0["role"] as? String ?? "") }) {
            return ["messages": fromDb, "agent": "gemini", "conversationId": cid, "cwd": geminiCwd(cid: cid), "missing": false]
        }
        var (texts, cwd) = geminiIndexedConversation(cid: cid)
        let transcript = try? String(contentsOfFile: geminiTranscriptPath(cid), encoding: .utf8)
        if texts.isEmpty, let content = transcript {
            texts = geminiMessages(content).map { m in
                var m = m
                m["text"] = m["text"]?.replacingOccurrences(of: "<truncated (\\d+) bytes>",
                                                            with: "（……Antigravity 的记录在这里省略了 $1 字节……）",
                                                            options: .regularExpression)
                return m
            }
        }
        let exists = fm.fileExists(atPath: databasePath ?? geminiConversationDb(cid)) || transcript != nil
        return ["messages": textTurns(texts), "agent": "gemini", "conversationId": cid, "cwd": cwd, "missing": !exists]
    }

    func loadGemini(cid: String, reqId: Int? = nil) {
        geminiQueue.async { [self] in
            var payload = readGeminiConversation(cid: cid)
            payload["context"] = geminiHistoryContext(cid)
            sendToJS("onConversationLoaded", recentHistory(payload["messages"] as? [[String: Any]] ?? [], into: payload, reqId: reqId))
        }
    }

    /// 会话库 steps 表的全部步骤（按顺序）。
    func geminiDbSteps(cid: String, databasePath: String? = nil) -> [(type: Int, payload: Data)] {
        var rows: [(type: Int, payload: Data)] = []
        _ = withReadableSQLite(databasePath ?? geminiConversationDb(cid)) { db in
            queryRows(db, "SELECT step_type, step_payload FROM steps ORDER BY idx;") { s in
                guard let blob = sqlite3_column_blob(s, 1) else { return }
                rows.append((Int(sqlite3_column_int64(s, 0)), Data(bytes: blob, count: Int(sqlite3_column_bytes(s, 1)))))
            }
        }
        return rows
    }

    /// 空闲的 agy 也会持库。仅在尾部还有重试时核对摘要步数，旧摘要的 idle 不能结束新的重试。
    private func geminiRetryEnded(cid: String, stepCount: Int) -> Bool {
        withReadableSQLite(geminiStore(cid).summaries) { db in
            var idle = false
            queryRows(db, "SELECT 1 FROM conversation_summaries WHERE conversation_id=? AND step_count=? AND status='CASCADE_RUN_STATUS_IDLE' AND not_fully_idle=0",
                      [geminiRawId(cid), String(stepCount)]) { _ in idle = true }
            return idle
        } ?? false
    }

    func geminiCwd(cid: String) -> String {
        var cwd = ""
        _ = withReadableSQLite(geminiStore(cid).summaries) { db in
            queryRows(db, "SELECT workspace_uris FROM conversation_summaries WHERE conversation_id = ? LIMIT 1;", [geminiRawId(cid)]) { s in
                cwd = firstWorkspacePath(columnText(s, 0))
            }
        }
        return cwd
    }
}
