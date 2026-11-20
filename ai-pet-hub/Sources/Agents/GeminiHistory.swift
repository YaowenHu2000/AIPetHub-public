// Gemini（Antigravity CLI）的历史会话：读每个会话自己的数据库，读不到时退回全文索引和 transcript。
//
// Gemini 重开时按数据库提问时间与本机失败时间核对，同文重试的成功回答保留在原失败轮之后。
// 仅有文字投影时，保留无法确认属于失败轮的回答。
//
// Gemini 按会话和提问位置记停止或失败，重开时补回最近工作步骤、结束说明和时长。
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
                if let reason = historyAccessError(store.brain,mode:R_OK | X_OK) ?? historyAccessError(store.root + "/conversations",mode:R_OK | X_OK) ?? historyAccessError(store.summaries) {
                    sendToJS("onConversationsListed",["agent":"gemini","unavailable":reason]); return
                }
                var readError: String?
                appendGeminiHistory(store, items: &items, seen: &seen, onError:{ readError = $0 })
                if let readError { sendToJS("onConversationsListed",["agent":"gemini","unavailable":readError]); return }
            }
            items += localFirstItems("gemini", excluding:seen)
            items.sort { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
            sendToJS("onConversationsListed", ["agent": "gemini", "items": Array(items.prefix(historyListLimit))])
        }
    }

    /// 同一次 CLI 启动要既新建该会话，又以 print 模式向它发问；只续写旧会话不能改变来源。
    private func noteGeminiScripts(_ store: GeminiStore) {
        guard !store.desktop else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let logs = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: store.root + "/log"), includingPropertiesForKeys: Array(keys))) ?? []
        for log in logs where log.lastPathComponent.hasPrefix("cli-") && log.pathExtension == "log" {
            guard let attrs = try? log.resourceValues(forKeys: keys), let mtime = attrs.contentModificationDate, let size = attrs.fileSize else { continue }
            if let cached = geminiLaunchLogs[log.path], cached.mtime == mtime, cached.size == size {
                continue
            }
            guard let data = try? Data(contentsOf: log, options: .mappedIfSafe) else { continue }
            var id: String?
            if data.range(of: Data("] Print mode: conversation=".utf8)) != nil {
                let content = String(decoding: data, as: UTF8.self)
                let prefix = #"(?m)^I\d{4} +[\d:.]+ +\d+ "#
                if let created = content.range(of: prefix + #"server\.go:\d+\] Created conversation [\w-]+ "#, options: .regularExpression),
                   let candidate = content[created].split(separator: " ").last,
                   content.range(of: prefix + #"session\.go:\d+\] Print mode: conversation="# + NSRegularExpression.escapedPattern(for: String(candidate)) + ", sending message", options: .regularExpression) != nil {
                    id = String(candidate)
                }
            }
            geminiLaunchLogs[log.path] = (mtime, size)
            if let id {
                // 启动日志清理后仍需在删除项目时认出这个脚本会话。
                UserDefaults.standard.set(true, forKey: store.root + ".geminiScript." + id)
            }
        }
    }

    private func geminiScript(_ id: String, in store: GeminiStore) -> Bool {
        !store.desktop && UserDefaults.standard.bool(forKey: store.root + ".geminiScript." + id)
            && !UserDefaults.standard.bool(forKey: "geminiPrintFromHub." + id)
    }

    @discardableResult
    func appendGeminiHistory(_ store: GeminiStore, items: inout [[String: Any]], seen: inout Set<String>, onError: (String) -> Void = { _ in }) -> Set<String> {
        var nested = Set<String>()
        noteGeminiScripts(store)
        let firstIndex = items.count
        defer {
            for i in firstIndex..<items.count {
                if let cid = items[i]["id"] as? String, geminiScript(geminiRawId(cid), in: store) { items[i]["task"] = true }
            }
        }
        _ = withReadableSQLite(store.summaries) { db in
            queryRows(db, "SELECT conversation_id FROM conversation_summaries WHERE nesting_depth > 0 OR parent_conversation_id != ''") { row in
                let key = geminiKey(columnText(row, 0), in: store)
                nested.insert(key); seen.insert(key)
            }
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
            guard let mtime = modificationDate(path) else {
                if let reason = historyAccessError(path) { onError(reason) }
                continue
            }
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
                geminiCache[cid] = (ts, item)
            }
            if let item = item { items.append(item) }
        }
        return nested
    }

    /// 摘要库里工作空间是 target 的全部会话（brain 兜底的旧会话没有工作空间，不会匹配）。
    func geminiIds(inWorkspace target: String, onTask: (String) -> Void = { _ in }) -> [String] {
        var ids = Set<String>()
        for store in geminiStores {
            noteGeminiScripts(store)
            _ = withReadableSQLite(store.summaries) { db in
                let sql = """
                    SELECT conversation_id, workspace_uris FROM conversation_summaries
                    WHERE nesting_depth = 0 AND parent_conversation_id = '';
                    """
                queryRows(db, sql) { s in
                    let cid = columnText(s, 0)
                    guard isSafeId(cid), fm.fileExists(atPath: store.database(cid)),
                          trimmedPath(firstWorkspacePath(columnText(s, 1))) == target else { return }
                    let key = geminiKey(cid, in: store)
                    ids.insert(key)
                    if geminiScript(cid, in: store) { onTask(key) }
                }
            }
        }
        for item in localFirstItems("gemini", excluding:ids) where trimmedPath(item["cwd"] as? String ?? "") == target {
            if let cid = item["id"] as? String, !fm.fileExists(atPath:geminiConversationDb(cid)) { ids.insert(cid) }
        }
        return Array(ids)
    }

    /// 从 agy 的全文索引还原对话：user_body / agent_body 按每步的字节偏移切开，再按步序合并。
    func geminiIndexedConversation(cid: String) -> (messages: [[String: String]], cwd: String) {
        var parts: [(step: Int, role: String, text: String)] = []
        var cwd = ""
        let store = geminiStore(cid)
        _ = withReadableSQLite(store.summaries) { db in
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
    func readGeminiConversation(cid: String, databasePath: String? = nil, rememberSource: Bool = false) -> [String: Any] {
        if databasePath == nil, geminiSourceMissing(cid, remember:rememberSource) {
            return ["agent":"gemini","conversationId":cid,"cwd":"","missing":true,"messages":[]]
        }
        let rows = geminiDbSteps(cid: cid, databasePath: databasePath)
        var finals: [Int: String]?   // 长会话的转写有好几 MB：有状态 5 的步骤才读，而且只读一次
        var messages = agyDbTurns(rows, isHeld: { self.geminiSessionHeld(cid, includingOwn: true, databasePath: databasePath, fresh: false, confirm: false) },
                                retryEnded: { self.geminiRetryEnded(cid: cid, stepCount: rows.count) },
                                finalStatus: { index in
                                    if finals == nil { finals = self.geminiTranscriptStatuses(cid) }
                                    return finals?[index]
                                },
                                cleanUser: { self.stripPersonaPrefix($0) })
        let endings = localEndings(agent: "gemini", cid: cid)
        let cwd: String
        var exists = true, readError: String?, textOnly = false
        if messages.contains(where: { ["bot", "compact"].contains($0["role"] as? String ?? "") }) {
            cwd = geminiCwd(cid: cid)
        } else {
            var (texts, indexedCwd) = geminiIndexedConversation(cid: cid)
            cwd = indexedCwd.isEmpty ? endings.first?["newWorkspace"] as? String ?? "" : indexedCwd
            let path = geminiTranscriptPath(cid)
            var transcript: String?
            if fm.fileExists(atPath: path) {
                do { transcript = try String(contentsOfFile: path, encoding: .utf8) }
                catch { if texts.isEmpty { readError = error.localizedDescription } }
            }
            if texts.isEmpty, let content = transcript {
                texts = geminiMessages(content).map { m in
                    var m = m
                    m["text"] = m["text"]?.replacingOccurrences(of: "<truncated (\\d+) bytes>",
                                                                with: "（……Antigravity 的记录在这里省略了 $1 字节……）",
                                                                options: .regularExpression)
                    return m
                }
            }
            let db = databasePath ?? geminiConversationDb(cid)
            if texts.isEmpty && transcript == nil && readError == nil {
                readError = historyAccessError(path) ?? historyAccessError(db)
            }
            exists = fm.fileExists(atPath: db) || transcript != nil || readError != nil
            if texts.isEmpty, readError == nil, fm.fileExists(atPath: db), withReadableSQLite(db, { _ in true }) == nil {
                readError = "Gemini 会话数据库无法读取"
            }
            if !texts.isEmpty || endings.isEmpty { messages = textTurns(texts); textOnly = true }
        }
        var localTail = false
        if !endings.isEmpty {
            var insertedPositions: [Int] = []
            for row in endings {
                let questions = messages.indices.filter { messages[$0]["role"] as? String == "user" }
                guard let pos = row["position"] as? Int, pos >= 0, pos <= questions.count,
                      let prompt = row["prompt"] as? String, let outcome = row["outcome"] as? String else { continue }
                // 没有 steps 库时，发送端按已补入历史的提问计数，序号已含前面的本机失败轮。
                let shifted = textOnly ? pos : pos + insertedPositions.filter { $0 <= pos }.count
                var at = shifted < questions.count ? questions[shifted] : messages.count
                // 首次失败未落盘时，稍后的同文重试会占同一个序号。失败轮插在它前面。
                let later = at < messages.count && (messages[at]["createdAt"] as? Double ?? 0) > (row["end"] as? Double ?? .infinity)
                // 纯文字投影没有提问时间，已有回答时单列失败轮，保留原记录。
                if !later, at < messages.count { restorePathAttachments(&messages[at], textKey:"text", ending:row) }
                let distinctAnswer = textOnly && messages.indices.contains(at + 1) && messages[at]["text"] as? String == prompt
                    && messages[at + 1]["role"] as? String == "bot"
                if at == messages.count || later || distinctAnswer {
                    let images = (row["images"] as? [String] ?? []).map { ["path": $0] }
                    var user: [String: Any] = ["role":"user", "text":prompt, "imageSources":images]
                    user["createdAt"] = row["start"]
                    messages.insert(user, at: at)
                    insertedPositions.append(pos)
                }
                guard messages[at]["text"] as? String == prompt else { continue }
                let original = at
                var saved = row["steps"] as? [[String:Any]] ?? []
                // agy 有时把补充另存为用户提问。只接上本轮确实消费过、且在结束前落盘的连续补充。
                for (index, step) in saved.enumerated() where step["kind"] as? String == "user" {
                    guard let next = questions.first(where: { $0 > at }),
                          messages[next]["text"] as? String == step["detail"] as? String,
                          (messages[next]["createdAt"] as? Double ?? 0) <= (row["end"] as? Double ?? .infinity) else { continue }
                    at = next
                    saved = Array((row["steps"] as? [[String:Any]] ?? []).dropFirst(index + 1))
                }
                if !messages.indices.contains(at + 1) || messages[at + 1]["role"] as? String != "bot" {
                    var bot = TurnBuilder().finish(finalText: row["text"] as? String, outcome: outcome)
                    bot["role"] = "bot"
                    messages.insert(bot, at: at + 1)
                }
                if at != original { messages[at + 1]["retryUser"] = messages[original] }
                if !saved.isEmpty {
                    var steps = messages[at + 1]["steps"] as? [[String: Any]] ?? []
                    if steps.last?["kind"] as? String == "error" && ["已中断","出错","未完成"].contains(steps.last?["title"] as? String ?? "") { steps.removeLast() }
                    var cursor = 0
                    for step in saved {
                        if let present = steps[cursor...].firstIndex(where: { existing in
                            ["kind","title","detail"].allSatisfy { existing[$0] as? String == step[$0] as? String }
                        }) {
                            cursor = present + 1
                        } else {
                            // 库里缺的步骤插在当前位置：后面库里已有的步骤还要参与匹配，不然会再列一次。
                            steps.insert(step, at: cursor); cursor += 1
                        }
                    }
                    messages[at + 1]["steps"] = steps
                }
                if let start = row["start"] as? Double, let end = row["end"] as? Double, end > start {
                    messages[at + 1]["duration"] = max(messages[at + 1]["duration"] as? Double ?? 0, end - start)
                }
                if at + 1 == messages.count - 1 { localTail = true }
                messages[at + 1]["outcome"] = outcome
                messages[at + 1]["endingReqId"] = row["reqId"]
                messages[at + 1]["text"] = restoredEndingText(recorded:trimmed(messages[at + 1]["text"] as? String), saved:trimmed(row["text"] as? String))
            }
        }
        var result: [String: Any] = ["messages": messages, "agent": "gemini", "conversationId": cid, "cwd": cwd, "missing": !exists && messages.isEmpty]
        if localTail || (!rows.isEmpty && geminiRetryEnded(cid:cid,stepCount:rows.count)) { result["lastTurn"] = ["running":false] }
        result["historyError"] = readError
        return result
    }

    func loadGemini(cid: String, reqId: Int? = nil) {
        geminiQueue.async { [self] in
            let readAt = historyReadAt()
            var payload = readGeminiConversation(cid: cid, rememberSource:true)
            payload["context"] = geminiHistoryContext(cid)
            payload["readAt"] = readAt
            sendToJS("onConversationLoaded", recentHistory(payload["messages"] as? [[String: Any]] ?? [], into: payload, reqId: reqId))
        }
    }

    /// 压缩命令这一轮：会话库里留没留下重开时会读成历史条目的一步（压成了的压缩，或 agy 当普通提问作答的回答），网页据此决定实时那条提示算不算历史条目。
    /// 在本轮的 agy 退出之后读，这时它已经写完了。
    func geminiNoteCompacted(_ req: AskRequest, _ reply: AgentReply) -> AgentReply {
        let said = req.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said == "/compact" || said == "/compress", !reply.cancelled, !reply.conversationId.isEmpty, var turn = reply.turn else { return reply }
        turn["compacted"] = agyCompactedAfterLastAsk(geminiDbSteps(cid: reply.conversationId))
        var out = reply
        out.turn = turn
        return out
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

    /// 转写里每步的最终状态（step_index → DONE / ERROR / RUNNING）。读不到时为空，调用方保持原来的判断。
    private func geminiTranscriptStatuses(_ cid: String) -> [Int: String] {
        hooks.geminiTranscriptRead?()
        guard let data = fm.contents(atPath: geminiTranscriptPath(cid)) else { return [:] }
        var out: [Int: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let obj = jsonObject(Data(line)), let index = obj["step_index"] as? Int, let status = obj["status"] as? String else { continue }
            out[index] = status
        }
        return out
    }

    /// 历史里 Gemini 图片的原图：id 是「步骤序号#附件序号」（agyImageSources），只读那一步。
    func geminiAttachedImage(cid: String, id: String) -> Data? {
        let parts = id.split(separator: "#")
        guard parts.count == 2, let step = Int(parts[0]), step >= 0 else { return nil }
        var source: [String: Any]?
        _ = withReadableSQLite(geminiConversationDb(cid)) { db in
            queryRows(db, "SELECT step_payload FROM steps ORDER BY idx LIMIT 1 OFFSET \(step);") { s in
                guard let blob = sqlite3_column_blob(s, 0) else { return }
                let payload = PBMessage(Data(bytes: blob, count: Int(sqlite3_column_bytes(s, 0))))
                source = agyImageSources(payload, step: step).first { $0["ref"] as? String == id }
            }
        }
        return (source?["data"] as? String).flatMap { Data(base64Encoded: $0) }
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
