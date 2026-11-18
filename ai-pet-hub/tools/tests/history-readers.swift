// 四家历史、终态、Codex 两种来源与重试日志；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testClaudeHistory() {
    print("· Claude 会话记录（历史）")
    let lines = [
        #"{"type":"user","cwd":"/w","timestamp":"2026-11-10T10:00:00.000Z","message":{"role":"user","content":"跑一下测试"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-10T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test","description":"跑测试"}}]}}"#,
        #"{"type":"attachment","timestamp":"2026-11-10T10:00:03.000Z","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"顺便看看 lint"}],"commandMode":"prompt"}}"#,
        #"{"type":"user","timestamp":"2026-11-10T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-11-10T10:00:08.000Z","message":{"content":[{"type":"text","text":"测试和 lint 都过了。"}]}}"#,
        #"{"type":"attachment","attachment":{"type":"something_else"}}"#,
    ]
    let (messages, cwd) = AppDelegate().claudeTurns(Data(lines.joined(separator: "\n").utf8))
    eq(cwd, "/w", "工作目录")
    eq(messages.map { str($0, "role") }, ["user", "bot"], "中途补充的话不拆成另一轮")
    // API 报错的那一轮：记录里是一条带 isApiErrorMessage 的回答。重开时要还原成出错的一轮（带原文、能重试），不能整条消失
    let failedLines = [
        #"{"type":"user","timestamp":"2026-11-10T11:00:00.000Z","message":{"role":"user","content":"你好"}}"#,
        #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-10T11:00:01.000Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 400 bad request"}]}}"#,
    ]
    let failed = AppDelegate().claudeTurns(Data(failedLines.joined(separator: "\n").utf8)).0
    eq(failed.map { str($0, "role") }, ["user", "bot"], "RT API 报错的一轮重开后还在")
    eq(failed.last.map { str($0, "outcome") }, "failed", "RT API 报错的一轮结局是出错")
    check(((failed.last?["steps"] as? [[String: Any]]) ?? []).contains { (str($0, "detail")).contains("API Error: 400") }, "RT 出错步骤带着 CLI 的原始错误")
    // 压缩：手动 /compact 重开后还原成和实时一样的提示；自动压缩是那一轮工作过程里的一步；
    // /compact 命令行、摘要、命令输出这些行不能拿来延长上一轮的结束时间（以前 2 秒的回答重开显示 1 分 55 秒）
    let compactLines = [
        #"{"type":"user","timestamp":"2026-11-10T12:00:00.000Z","message":{"role":"user","content":"你好"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-10T12:00:02.000Z","message":{"content":[{"type":"text","text":"你好！"}]}}"#,
        #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-10T12:01:55.000Z","compactMetadata":{"trigger":"manual"}}"#,
        #"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"2026-11-10T12:01:55.000Z","message":{"role":"user","content":"This session is being continued from a previous conversation"}}"#,
        #"{"type":"user","isMeta":true,"timestamp":"2026-11-10T12:00:10.000Z","message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}"#,
        #"{"type":"user","timestamp":"2026-11-10T12:00:10.000Z","message":{"role":"user","content":"<command-name>/compact</command-name>"}}"#,
        #"{"type":"user","timestamp":"2026-11-10T12:01:56.000Z","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}"#,
        #"{"type":"user","timestamp":"2026-11-10T12:02:00.000Z","message":{"role":"user","content":"接着说"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-10T12:02:01.000Z","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"ls"}}]}}"#,
        #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-10T12:02:30.000Z","compactMetadata":{"trigger":"auto"}}"#,
        #"{"type":"user","isCompactSummary":true,"timestamp":"2026-11-10T12:02:31.000Z","message":{"role":"user","content":"This session is being continued"}}"#,
        #"{"type":"user","timestamp":"2026-11-10T12:02:40.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"a.txt"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-11-10T12:02:45.000Z","message":{"content":[{"type":"text","text":"好了"}]}}"#,
    ]
    let compacted = AppDelegate().claudeTurns(Data(compactLines.joined(separator: "\n").utf8)).0
    eq(compacted.map { str($0, "role") }, ["user", "bot", "compact", "user", "bot"], "CP 手动压缩重开后有提示，位置和实时一样")
    eq(compacted.first { str($0, "role") == "compact" }.map { str($0, "text") }, "前面的对话已经压缩成摘要，腾出了上下文空间。", "CP 提示文字和实时一致")
    eq(compacted[1]["duration"] as? Double, 2, "CP 压缩相关的行不延长上一轮的工作时长")
    check(((compacted.last?["steps"] as? [[String: Any]]) ?? []).contains { str($0, "title") == "压缩上下文" && str($0, "status") == "ok" }, "CP 自动压缩是那一轮工作过程里的一步")
    let steps = messages.last?["steps"] as? [[String: Any]] ?? []
    eq(steps.map { str($0, "kind") }, ["command", "user"], "补充的话是这一轮工作过程里的一步")
    eq(str(steps.last, "detail"), "顺便看看 lint", "补充的内容")
    eq(str(messages.last, "text"), "测试和 lint 都过了。", "回答")

    // 点了停止之后 Claude Code 自己写进记录的中断标记：不是用户的一句话，是这一轮的结局
    let stopped = [
        #"{"type":"user","timestamp":"2026-11-10T10:00:00.000Z","message":{"role":"user","content":"从 1 数到 400"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-10T10:00:02.000Z","message":{"content":[{"type":"text","text":"1\n2\n3"}]}}"#,
        #"{"type":"user","timestamp":"2026-11-10T10:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        #"{"type":"user","timestamp":"2026-11-10T10:00:09.000Z","message":{"role":"user","content":"接着数"}}"#,
        #"{"type":"user","timestamp":"2026-11-10T10:00:10.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
    ]
    let (afterStop, _) = AppDelegate().claudeTurns(Data(stopped.joined(separator: "\n").utf8))
    eq(afterStop.map { str($0, "role") }, ["user", "bot", "user", "bot"], "中断标记不是一句提问")
    check(!afterStop.contains { str($0, "text").contains("Request interrupted") }, "中断标记的原文不显示")
    eq(str((afterStop[1]["steps"] as? [[String: Any]])?.last, "title"), "已中断", "被停下的那一轮标成已中断，已有的正文保留")
    eq(str(afterStop[1], "text"), "1\n2\n3", "被停下之前的正文")
    eq(str((afterStop[3]["steps"] as? [[String: Any]])?.last, "title"), "已中断", "还没出任何内容就停下的那一轮也留一条")

    // 同一个会话被两个进程接着写过：记录分叉了。主线是最后一条记录往上找到头的那条；岔出去的旁支不显示。
    let u = { (n: Int) in String(format: "00000000-0000-0000-0000-%012d", n) }
    let row = { (id: Int, parent: Int?, type: String, text: String) -> String in
        let p = parent.map { "\"\(u($0))\"" } ?? "null"
        let content = type == "user" ? "\"\(text)\"" : "[{\"type\":\"text\",\"text\":\"\(text)\"}]"
        // 字段顺序照真实记录：message 在前，type 紧挨在 uuid 前面（一条回答的 message 可以有好几千字）
        return "{\"parentUuid\":\(p),\"isSidechain\":false,\"message\":{\"role\":\"\(type)\",\"content\":\(content)},\"pad\":\"\(String(repeating: "x", count: 600))\",\"type\":\"\(type)\",\"uuid\":\"\(u(id))\",\"timestamp\":\"2026-11-10T10:00:0\(id).000Z\"}"
    }
    let forked = [
        row(9, nil, "user", "压缩前的一句"), row(10, 9, "assistant", "压缩前的回答"),   // 和主线连不上的更早一段：照常显示
        row(1, nil, "user", "第一问"), row(2, 1, "assistant", "第一答"),
        row(3, 2, "user", "副本里问的"), row(4, 3, "assistant", "副本里答的"),         // 旁支：接在 2 后面，后面没人再接
        row(5, 2, "user", "主线第二问"), row(7, 5, "user", "并行工具的另一条结果"), row(6, 5, "assistant", "主线第二答"),   // 7 也接在 5 后面、不在主线上，但这一支里没有回答：不算旁支
    ]
    let app = AppDelegate()
    let data = Data(forked.joined(separator: "\n").utf8)
    eq(app.claudeSideBranch(data).sorted(), [u(3), u(4)], "接在主线上、自己不在主线上的是旁支")
    let (kept, _) = app.claudeTurns(data)
    eq(kept.map { str($0, "text") }, ["压缩前的一句", "压缩前的回答", "第一问", "第一答", "主线第二问", "并行工具的另一条结果", "主线第二答"], "旁支不显示；更早的段落、没有回答的小岔都照常显示")
    eq(app.claudeSideBranch(Data(lines.joined(separator: "\n").utf8)).count, 0, "没有分叉的记录：什么都不去掉")
}

func testCodexHistory() {
    print("· Codex 历史里的同回合补充（SQLite / rollout）")
    let d = AppDelegate()
    let path = NSTemporaryDirectory() + "aipethub-codex-history-" + UUID().uuidString + ".sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try! Data().write(to: URL(fileURLWithPath: path))
    let question = json(#"{"type":"UserMessage","content":[{"type":"text","text":"提问"}]}"#)
    let answer = json(#"{"type":"AgentMessage","content":[{"type":"Text","text":"回答"}],"phase":"final_answer"}"#)
    let supplements = [
        json(#"{"type":"UserMessage","content":[{"type":"text","text":"补充"}]}"#),
        json(#"{"type":"UserMessage","content":[{"type":"text","text":"补充"},{"type":"localImage","path":"/tmp/a.png"}]}"#),
        json(#"{"type":"UserMessage","content":[{"type":"localImage","path":"/tmp/a.png"}]}"#)
    ]
    func encoded(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj, options: .sortedKeys), encoding: .utf8)!
    }
    func rollout(_ items: [[String: Any]], ids: [String?]) -> String {
        items.enumerated().map { i, item in
            var payload: [String: Any] = ["type": "item_completed", "item": item]
            payload["turn_id"] = ids[i]
            return encoded(["type": "event_msg", "timestamp": "2026-11-17T00:00:0\(i * 2).000Z", "payload": payload])
        }.joined(separator: "\n")
    }
    func database(_ items: [[String: Any]], ids: [String?], hasColumn: Bool = true) -> [[String: Any]] {
        _ = d.withSQLite(path, readOnly: false) { db in
            let schema = "DROP TABLE IF EXISTS thread_items; CREATE TABLE thread_items (thread_id TEXT, item_type TEXT, item_json TEXT, created_at_ms INTEGER, completed_at_ms INTEGER, rollout_ordinal INTEGER\(hasColumn ? ", turn_id TEXT" : ""));"
            check(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "建立临时 SQLite 夹具")
            for (i, item) in items.enumerated() {
                let type = item["type"] as! String
                let camel = type.prefix(1).lowercased() + type.dropFirst()
                let id = ids[i].map { "'\($0)'" } ?? "NULL"
                let sql = "INSERT INTO thread_items VALUES ('fixture', '\(camel)', '\(encoded(item).replacingOccurrences(of: "'", with: "''"))', \(i * 2000), \(i * 2000), \(i)\(hasColumn ? ", \(id)" : ""));"
                check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "写入临时 SQLite 条目")
            }
        }
        return d.codexDbTurns("fixture", databasePath: path)
    }
    func verify(_ messages: [[String: Any]], detail: String, hasImage: Bool, source: String) {
        eq(messages.map { str($0, "role") }, ["user", "bot"], "\(source)：一问一答")
        eq(str(messages.last, "text"), "回答", "\(source)：最终回答不变")
        let steps = messages.last?["steps"] as? [[String: Any]] ?? []
        eq(steps.map { str($0, "title") }, ["你补充说"], "\(source)：补充留在工作过程")
        eq(str(steps.first, "kind"), "user", "\(source)：沿用 user 步骤")
        eq(str(steps.first, "detail"), detail, "\(source)：补充文字，纯图片不加占位")
        eq((steps.first?["imageSources"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }, hasImage ? ["/tmp/a.png"] : [], "\(source)：补充沿用用户消息的图片来源字段")
        eq(messages.last?["duration"] as? Double, 4, "\(source)：补充不重置开始时间")
    }
    for (i, supplement) in supplements.enumerated() {
        let items = [question, supplement, answer], ids: [String?] = ["t1", "t1", "t1"]
        let db = database(items, ids: ids)
        let roll = d.codexRolloutTurns(rollout(items, ids: ids)).messages
        verify(db, detail: i == 2 ? "" : "补充", hasImage: i != 0, source: "SQLite \(i)")
        verify(roll, detail: i == 2 ? "" : "补充", hasImage: i != 0, source: "rollout \(i)")
        eq(encoded(["messages": db]), encoded(["messages": roll]), "两条历史来源输出完全一致")
    }
    let items = [question, supplements[0], answer]
    for ids: [String?] in [[nil, nil, nil], ["", "", ""], ["t1", "t2", "t2"], ["t1", nil, "t1"]] {
        for messages in [database(items, ids: ids), d.codexRolloutTurns(rollout(items, ids: ids)).messages] {
            eq(messages.map { str($0, "role") }, ["user", "user", "bot"], "缺少身份或不同 turn：仍按原行为拆开")
            eq(messages.last?["duration"] as? Double, 2, "拆开的回合沿用原时长")
        }
    }
    eq(database(items, ids: [nil, nil, nil], hasColumn: false).map { str($0, "role") }, ["user", "user", "bot"], "旧 SQLite 没有 turn_id 列也能读取")
    let complete = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#
    let abort = #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1"}}"#
    let next = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#
    let lateCommand = json(#"{"type":"CommandExecution","command":["echo done"],"exit_code":0}"#)
    let late = rollout([question, answer], ids: ["t1", "t1"]) + "\n" + complete + "\n" + rollout([lateCommand], ids: ["t1"])
    let lateMessages = d.codexRolloutTurns(late).messages
    eq(lateMessages.map { str($0, "role") }, ["user", "bot"], "结束标记后的同轮命令结果仍留在原回答")
    eq((lateMessages.last?["steps"] as? [[String: Any]])?.map { str($0, "kind") }, ["command"], "保留晚于 task_complete 落盘的命令")
    for boundary in [complete, abort, next] {
        let content = rollout([question, answer], ids: ["t1", "t1"]) + "\n" + boundary + "\n" + rollout([question, answer], ids: ["t1", "t1"])
        eq(d.codexRolloutTurns(content).messages.map { str($0, "role") }, ["user", "bot", "user", "bot"], "rollout 开始 / 结束边界后不再视作上一轮补充")
    }
    let legacy = #"""
{"type":"event_msg","payload":{"type":"user_message","message":"提问"}}
{"type":"event_msg","payload":{"type":"user_message","message":"补充"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"回答"}}
"""#
    eq(d.codexRolloutTurns(legacy).messages.map { str($0, "role") }, ["user", "user", "bot"], "旧 user_message 格式不猜回合")
}

func testCodexRetryLogs() {
    print("· Codex 内部重试日志（只读、格式退化）")
    let d = AppDelegate(), fm = FileManager.default
    let path = NSTemporaryDirectory() + "aipethub-retry-" + UUID().uuidString + ".sqlite"
    defer { try? fm.removeItem(atPath: path) }
    let since = Date(timeIntervalSince1970: 1000.25)
    func read(_ thread: String = "fixture", _ start: Date? = nil, _ pid: pid_t? = nil) -> CodexRetryRecord? {
        d.codexLatestRetry(threadId: thread, since: start ?? since, processID: pid, databasePath: path)
    }
    check(read() == nil && !fm.fileExists(atPath: path), "不存在的库返回 nil，不创建文件")
    try! Data().write(to: URL(fileURLWithPath: path))
    func sql(_ statement: String) {
        _ = d.withSQLite(path, readOnly: false) { db in
            check(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "执行日志夹具 SQL")
        }
    }
    let fields = ["id INTEGER PRIMARY KEY AUTOINCREMENT", "ts INTEGER NOT NULL", "ts_nanos INTEGER NOT NULL",
                  "level TEXT NOT NULL", "target TEXT NOT NULL", "feedback_log_body TEXT", "module_path TEXT",
                  "file TEXT", "line INTEGER", "thread_id TEXT", "process_uuid TEXT", "estimated_bytes INTEGER NOT NULL DEFAULT 0"]
    func schema(_ omitted: String? = nil) {
        sql("DROP TABLE IF EXISTS logs; CREATE TABLE logs (" + fields.filter { !$0.hasPrefix((omitted ?? "NONE") + " ") }.joined(separator: ",") + ");")
        if omitted == nil {
            sql("CREATE INDEX idx_logs_ts ON logs(ts DESC, ts_nanos DESC, id DESC); CREATE INDEX idx_logs_thread_id ON logs(thread_id); CREATE INDEX idx_logs_thread_id_ts ON logs(thread_id, ts DESC, ts_nanos DESC, id DESC); CREATE INDEX idx_logs_process_uuid_threadless_ts ON logs(process_uuid, ts DESC, ts_nanos DESC, id DESC) WHERE thread_id IS NULL;")
        }
    }
    func insert(id: Int = 1, thread: String = "fixture", pid: Int = 7, ts: Int = 1000, nanos: Int = 500_000_000,
                target: String = "codex_core::responses_retry", body: String? = nil, wait: String = "486.999850458", code: String = "429") {
        let message = body ?? "session_loop{thread_id=\(thread)}: stream disconnected - retrying sampling request (1/10 in \(wait)s)... turn_id=t retries=1 max_retries=10 sampling_error=exceeded retry limit, last status: \(code) Too Many Requests"
        sql("INSERT INTO logs (id,ts,ts_nanos,level,target,feedback_log_body,thread_id,process_uuid) VALUES (\(id),\(ts),\(nanos),'WARN','\(target)','\(message.replacingOccurrences(of: "'", with: "''"))','\(thread)','pid:\(pid):uuid');")
    }
    sql("CREATE TABLE unrelated (id INTEGER);")
    check(read() == nil, "缺 logs 表返回 nil")
    for column in ["id", "ts", "ts_nanos", "level", "target", "feedback_log_body", "thread_id", "process_uuid"] {
        schema(column); check(read() == nil, "缺 \(column) 列返回 nil")
    }
    schema(); insert()
    let first = read()
    eq(first?.statusCode, 429, "明确识别 429")
    eq(first?.waitSeconds, 486.999850458, "读取计划等待小数秒")
    eq(first?.recordedAt, Date(timeIntervalSince1970: 1000.5), "读取秒及纳秒时间")
    check(first?.message.contains("sampling_error=") == true, "保留原始消息")
    check(read("fixture", Date(timeIntervalSince1970: 1000.6)) == nil, "同秒但早于起始时间的记录不认")
    check(read("fixture", Date(timeIntervalSince1970: 1000.5)) == nil, "等于起始时间不认")
    check(read("another") == nil, "别的 thread 不认")
    check(read("fixture", nil, 8) == nil && read("fixture", nil, 7) != nil, "按 process_uuid 的 PID 限定进程")
    insert(id: 2, thread: "another", ts: 1001)
    eq(read()?.id, 1, "新一些的别的 thread 记录不干扰")
    insert(id: 5, ts: 1001, body: "ordinary warning 429")
    eq(read()?.id, 1, "一般警告既不冒充重试，也不遮住最新的重试记录")
    insert(id: 3, nanos: 600_000_000, wait: "105.999886916")
    eq(read()?.id, 3, "同秒按纳秒选最新")
    insert(id: 4, nanos: 600_000_000, wait: "537.999795459", code: "503")
    eq(read()?.waitSeconds, 537.999795459, "同纳秒按 id 选最新")
    eq(read()?.statusCode, 503, "识别非 429 状态码")
    for (target, body) in [("codex_core::responses_retry", "ordinary warning 429 wait 8s"),
                           ("other::warning", "stream disconnected - retrying sampling request (1/10 in 8s)... sampling_error=last status: 429"),
                           ("codex_core::responses_retry", "stream disconnected - retrying sampling request (1/10 in nans)... sampling_error=last status: 429"),
                           ("codex_core::responses_retry", "损坏或未知格式") ] {
        schema(); insert(target: target, body: body)
        check(read() == nil, "普通警告、目标不匹配、损坏等待值或未知格式不认")
    }
    schema(); insert(nanos: -1)
    check(read() == nil, "损坏时间不认")
    // 锁住日志库不能阻塞回答；只限制可选查询，不限制 CLI 回答。
    schema(); insert()
    _ = d.withSQLite(path, readOnly: false) { db in
        sqlite3_exec(db, "BEGIN EXCLUSIVE;", nil, nil, nil)
        let began = Date()
        _ = read()
        check(Date().timeIntervalSince(began) < 0.5, "日志忙时迅速退化")
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
    }
    try? fm.removeItem(atPath: path)
    try! Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))
    check(read() == nil, "损坏 SQLite 返回 nil，不崩溃")

    let t = TurnBuilder(), parser = CodexAppParser(turn: TurnBuilder())
    let p = CodexAppParser(turn: t)
    func record(_ seconds: Double, _ code: Int? = 429) -> CodexRetryRecord {
        CodexRetryRecord(id: 1, statusCode: code, waitSeconds: seconds, recordedAt: since, message: "原始警告")
    }
    for (seconds, unit) in [(487.0, "8 分钟"), (106.0, "2 分钟"), (538.0, "9 分钟"), (7.0, "7 秒"), (7200.0, "2 小时")] {
        p.noteRetry(record(seconds))
        check(str(t.step("retry"), "title").contains(unit), "等待 \(seconds) 秒使用易读单位")
    }
    p.noteRetry(record(10, 503))
    eq(str(t.step("retry"), "title"), "连接中断，正在重试", "其它状态码沿用连接重试标题")
    eq(str(t.step("retry"), "detail"), "原始警告", "detail 是原文")
    p.notify("error", ["willRetry": true, "error": ["message": "Reconnecting... 2/10"]])
    p.noteRetry(record(487))
    eq(t.steps.count, 1, "通知与日志共用 retry key，双向更新不新增步骤")
    parser.notify("error", ["willRetry": true, "error": ["message": "Reconnecting..."]])
    for method in ["item/agentMessage/delta", "turn/completed"] {
        let params: [String: Any] = method == "turn/completed" ? ["turn": ["status": "completed"]] : ["itemId": "m", "delta": "恢复"]
        p.notify(method, params); parser.notify(method, params)
    }
    eq(str(t.step("retry"), "status"), str(parser.turn.step("retry"), "status"), "恢复和结束后完全沿用旧重试的状态")
    eq(str(t.step("retry"), "status"), "error", "记录现有行为：恢复后仍保留红色错误样式，不顺手修改")
}

/// 显式运行，不属于离线套件；使用上次现场日志验证同一个读取函数，不发 API 请求。
func verifyCodexRetryRealLogs() {
    let d = AppDelegate()
    let samples: [(String, Double, pid_t, Int)] = [
        ("01a1e8e4-d54e-7f51-8d76-17064fe90964", 1794908676, 3659, 487),
        ("01a1e8e9-a66c-7192-a5ea-f111c7d6ae3c", 1794908992, 10032, 106),
        ("01a1e8e2-f794-7711-a40d-4d7b8acf6fa7", 1794908625, 2593, 538)
    ]
    var passed = true
    for (thread, ts, pid, expected) in samples {
        let result = d.codexLatestRetry(threadId: thread, since: Date(timeIntervalSince1970: ts), processID: pid)
        let ok = result?.statusCode == 429 && result?.waitSeconds.rounded() == Double(expected)
        passed = passed && ok
        print("\(ok ? "✓" : "✗") thread=\(thread) pid=\(pid) id=\(result?.id ?? -1) status=\(result?.statusCode ?? -1) wait=\(result?.waitSeconds ?? -1)s expected≈\(expected)s")
    }
    exit(passed ? 0 : 1)
}

func testAssignedHistoryFixes() {
    print("· W4 回归：R05 / H01 H04 H05 H07–H12 H15 H16")
    let d = AppDelegate(), fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-w4-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    func steps(_ bot: [String: Any]?) -> [[String: Any]] { bot?["steps"] as? [[String: Any]] ?? [] }
    func hasError(_ bot: [String: Any]?) -> Bool { steps(bot).contains { str($0, "kind") == "error" } }
    func encode(_ obj: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: obj, options: .sortedKeys), encoding: .utf8)! }
    let req = AskRequest(agent: "claude", reqId: 4001, prompt: "fixture", model: "", effort: "low", permissionMode: "default", workspace: dir, conversationId: "")
    for cancelled in [false, true] {
        let t = TurnBuilder(), p: ClaudeStreamParser
        p = ClaudeStreamParser(turn: t)
        p.feed(json(#"{"type":"assistant","message":{"content":[{"type":"text","text":"已有正文"},{"type":"tool_use","id":"c","name":"Bash","input":{"command":"fixture"}}]}}"#))
        let r = d.claudeReply(req, res: CLIResult(out: "raw json", err: "fatal fixture tail", status: 42, cancelled: cancelled), parser: p, turn: t)
        eq(r.reply, "已有正文", "R05 Claude 保留正文")
        check(hasError(r.turn), "R05 Claude 非正常终态有说明（cancelled=\(cancelled)）")
        check(steps(r.turn).last.map { str($0, "detail").contains(cancelled ? "中断" : "fatal fixture tail") } ?? false, "R05 Claude 显示终态原因")
        eq(str(steps(r.turn).first, "status"), cancelled ? "interrupted" : "error", "R05 Claude 区分主动停止与失败")
    }
    let cli = dir + "/cli.py"
    try! installFakeCLI(at: cli, behavior: "terminal")
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    d.hooks.cliExecutable = cli
    for mode in ["live", "exec", "completed"] {
        try! mode.write(toFile: dir + "/mode", atomically: true, encoding: .utf8)
        let r = withTestAsk(d, "gpt#4002") { d.runCodex(AskRequest(agent: "gpt", reqId: 4002, prompt: "fixture", model: "fixture", effort: "low", permissionMode: "read-only", workspace: dir, conversationId: "", browserTools: false)) }
        eq(r.turn?["outcome"] as? String, mode == "completed" ? "completed" : "failed", "Codex 保留正文时也明确回报可重试的失败")
        eq(r.reply, "已有正文", "R05 Codex \(mode) 保留正文")
        if mode == "completed" {
            check(!hasError(r.turn), "R05 已有完成事件不因随后非零退出误报失败")
        } else {
            check(hasError(r.turn), "R05 Codex \(mode) 非零退出有错误步骤")
            check(str(steps(r.turn).last, "detail").contains("fatal fixture tail"), "R05 Codex \(mode) 保留 stderr 尾部")
            eq(str(steps(r.turn).first, "status"), "error", "R05 Codex \(mode) 未完成工具标错误")
        }
        check(d.runningPid("gpt#4002") == nil, "R05 假 CLI 已回收")
    }
    let unfinished = #"{"type":"assistant","message":{"content":[{"type":"text","text":"已有正文"},{"type":"tool_use","id":"read","name":"Read","input":{"file_path":"/fixture/a"}}]}}"#
    let claude = d.claudeTurns(Data(unfinished.utf8)).0.last
    eq(str(steps(claude).first, "status"), "running", "H01 Claude 未返回工具保持未完成")
    check(hasError(claude), "H01 Claude 未写完的历史有末尾说明")
    let rows: [[String: Any]] = [
        ["event": ["type": "assistant/message", "data": ["message": ["content": [["type": "text", "text": "已有正文"]]]]]],
        ["event": ["type": "turn/end", "data": ["reason": ["kind": "error", "error": ["message": "fixture error"]]]]]
    ]
    let deepseek = dshTurns(rows).last
    eq(str(deepseek, "text"), "已有正文", "H01 DeepSeek 保留正文")
    check(hasError(deepseek) && str(steps(deepseek).last, "detail").contains("fixture error"), "H01 DeepSeek 正文不能遮掉错误")
    check(dshTurns([["event": ["type": "session/title", "data": ["title": "标题"]]]]).isEmpty, "H01 DeepSeek 元数据不生成未完成回合")
    for outcome in ["completed", "failed", "interrupted", "incomplete"] {
        let turn = TurnBuilder()
        turn.add(makeStep("command", "未返回", status: "running"))
        turn.add(makeStep("read", "已返回", status: "ok"))
        turn.add(makeStep("text", "说明", detail: "正文"))
        let bot = turn.finish(finalText: nil, outcome: outcome)
        eq(str(bot, "text"), "正文", "终态 \(outcome) 保留正文")
        eq(str(steps(bot).first, "status"), outcome == "interrupted" ? "interrupted" : (outcome == "failed" ? "error" : "running"), "终态 \(outcome) 不伪造工具成功")
        eq(str(steps(bot)[1], "status"), "ok", "终态 \(outcome) 已完成步骤保持成功")
        if outcome == "interrupted" { eq(str(steps(bot).last, "status"), "interrupted", "末尾已中断也使用中性色") }
        eq(hasError(bot), outcome != "completed", "终态 \(outcome) 末尾说明")
    }
    for terminal in ["turn_failed", "turn_aborted", "task_complete"] {
        let end = encode(["type": "event_msg", "payload": ["type": terminal, "turn_id": "fixture", "error": ["message": "rollout failure"]]])
        let item = encode(["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "fixture", "item": ["type": "AgentMessage", "content": [["text": "已有正文"]]]]])
        let legacy = encode(["type": "event_msg", "payload": ["type": "agent_message", "message": "已有正文"]])
        for content in [item, legacy] {
            let bot = d.codexRolloutTurns(content + "\n" + end).messages.last
            eq(str(bot, "text"), "已有正文", "H01 rollout \(terminal) 新旧格式保留正文")
            eq(hasError(bot), terminal != "task_complete", "H01 rollout \(terminal) 终态说明")
        }
        if terminal == "turn_failed" {
            let bot = d.codexRolloutTurns(end).messages.last
            check(hasError(bot) && str(steps(bot).last, "detail").contains("rollout failure"), "H01 rollout 无 item 失败仍显示")
        }
    }
    let dbPath = dir + "/history.sqlite"
    try! Data().write(to: URL(fileURLWithPath: dbPath))
    _ = d.withSQLite(dbPath, readOnly: false) { db in
        let sql = """
        CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT, error_json TEXT, started_at INTEGER, completed_at INTEGER);
        CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_type TEXT, item_json TEXT, created_at_ms INTEGER, completed_at_ms INTEGER, rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES ('fixture','failed',1,'failed','{"message":"fixture failure"}',1000,2000);
        INSERT INTO thread_turns VALUES ('fixture','empty',3,'failed','{"message":"empty failure"}',3000,4000);
        INSERT INTO thread_turns VALUES ('fixture','stopped',4,'interrupted',NULL,4000,5000);
        INSERT INTO thread_turns VALUES ('fixture','pending',6,'inProgress',NULL,6000,NULL);
        INSERT INTO thread_turns VALUES ('fixture','done',8,'completed',NULL,8000,9000);
        INSERT INTO thread_items VALUES ('fixture','failed','agentMessage','{"text":"已有正文"}',1000,2000,2);
        INSERT INTO thread_items VALUES ('fixture','stopped','commandExecution','{"command":"fixture","status":"inProgress"}',4000,NULL,5);
        INSERT INTO thread_items VALUES ('fixture','pending','commandExecution','{"command":"fixture","status":"inProgress"}',6000,NULL,7);
        INSERT INTO thread_items VALUES ('fixture','done','agentMessage','{"text":"正常回答"}',8000,9000,9);
        """
        check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "H01 建立终态数据库夹具")
    }
    let history = d.codexDbTurns("fixture", databasePath: dbPath)
    eq(history.count, 5, "H01 无 item 的失败轮仍显示，按回合顺序读取")
    check(history.contains { str(steps($0).last, "detail").contains("empty failure") }, "H01 无 item 的失败原因保留")
    check(history.contains { str($0, "text") == "已有正文" && str(steps($0).last, "detail").contains("fixture failure") }, "H01 Codex 正文与失败原因共存")
    check(history.contains { str(steps($0).last, "detail").contains("中断") && str(steps($0).first, "status") == "interrupted" }, "H01 Codex 中断保留工具未完成")
    check(history.contains { str(steps($0).last, "detail").contains("写完") }, "H01 Codex inProgress 有记录未写完说明")
    check(history.last.map { !hasError($0) } ?? false, "H01 正常完成不追加错误")
    // 真实 rollout 在 turn_aborted 后补落命令结果，exit_code=-1 表示没有正常退出码。
    let commands = [-1, 23].map { code in
        encode(["type":"event_msg", "payload":["type":"item_completed", "turn_id":"t", "item":["type":"CommandExecution", "command":"sleep 15", "status":"failed", "exit_code":code]]])
    }
    for (event, expected) in [("turn_aborted", "interrupted"), ("turn_failed", "error")] {
        let end = encode(["type":"event_msg","payload":["type":event,"turn_id":"t"]])
        let bot = d.codexRolloutTurns([commands[0], commands[1], end, commands[0]].joined(separator:"\n")).messages.last
        eq(steps(bot).filter { str($0, "kind") == "command" }.map { str($0, "status") }, ["error", "error", expected], "Codex 停止时只中和被打断的命令，崩溃保留错误")
    }
    _ = d.withSQLite(dbPath, readOnly: false) { db in
        let sql = """
        ALTER TABLE thread_turns ADD COLUMN rollout_end_ordinal INTEGER;
        UPDATE thread_turns SET rollout_end_ordinal=8 WHERE turn_id='stopped';
        INSERT INTO thread_items VALUES ('fixture','stopped','commandExecution','{"status":"failed","exitCode":-1}',4010,4100,6);
        INSERT INTO thread_items VALUES ('fixture','stopped','commandExecution','{"status":"failed","exitCode":-1}',4200,5000,9);
        ALTER TABLE thread_items ADD COLUMN updated_at_ordinal INTEGER;
        INSERT INTO thread_items VALUES ('fixture','stopped','commandExecution','{"status":"failed","exitCode":-1}',4300,5000,7,10);
        """
        check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "投影包含中断前后两个无退出码的命令")
    }
    let interrupted = d.readCodexProjection("fixture", databasePath: dbPath)
    let sameTurn = CodexStoredHistory(items: interrupted.items.filter { $0.turnId == "stopped" }, endings: interrupted.endings)
    eq(steps(d.codexProjectedTurns(sameTurn).first).filter { str($0, "kind") == "command" }.map { str($0, "status") },
       ["interrupted", "error", "interrupted", "interrupted"], "SQLite 按结果更新序号区分已失败和被打断的命令")
    let deepTurn = DeepSeekLiveTurn(app: d, req: req)
    deepTurn.builder.add(makeStep("command", "运行命令", status: "running"))
    deepTurn.builder.add(makeStep("tool", "已失败", status: "error"), key: "earlier")
    deepTurn.builder.add(makeStep("tool", "等待取消回执", status: "running"), key: "late")
    deepTurn.markStopping()
    deepTurn.builder.update("late", ["status": "error", "output": "terminated"])
    eq(str(deepTurn.builder.step("late"), "status"), "interrupted", "停止后 CLI 才报 failed 的工具也不闪红")
    eq(steps(deepTurn.replyForTest.turn).map { str($0, "status") }, ["interrupted","error","interrupted","interrupted"], "DeepSeek 实时停止和历史使用同一终态")
    deepTurn.input.abandon()
    for status in ["declined", "failed", "completed"] {
        let t = TurnBuilder(); var final = ""
        d.codexHistoryItem(type: "commandExecution", obj: ["command": "echo fixture", "status": status], turn: t, finalAnswer: &final)
        d.codexHistoryItem(type: "fileChange", obj: ["status": status, "changes": [["path": "/fixture/a", "kind": "add", "diff": "+a"]]], turn: t, finalAnswer: &final)
        eq(t.steps.map { str($0, "status") }, Array(repeating: status == "completed" ? "ok" : "error", count: 2), "H04 \(status) 命令/文件状态一致")
        eq((t.finish(finalText: nil)["files"] as? [Any])?.count, status == "completed" ? 1 : 0, "H04 只有完成改动登记卡片")
        if status == "declined" { check(t.steps.allSatisfy { str($0, "output").contains("没有得到同意") }, "H04 拒绝原因与实时一致") }
    }
    for type in ["mcpToolCall", "dynamicToolCall", "webSearch", "imageGeneration", "collabAgentToolCall"] {
        let turn = TurnBuilder(); var final = ""
        d.codexHistoryItem(type: type, obj: ["status": "inProgress"], turn: turn, finalAnswer: &final)
        eq(str(turn.steps.first, "status"), "running", "H01 \(type) 没有结果不标成功")
    }
    let pasted = "前文<pasted_content id=\"1\">保留全文\n第二行</pasted_content>后文"
    let obj: [String: Any] = ["type": "user", "message": ["content": pasted]]
    eq(d.claudeDisplayText(obj), "前文保留全文\n第二行后文", "H05 只去包装，正文保留")
    let file = dir + "/claude.jsonl"
    try! (encode(obj) + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    check(!(d.claudeSummary(path: file, cid: "fixture", mtime: Date())?["title"] as? String ?? "").contains("pasted_content"), "H05 回退标题也去包装")
    let queued = encode(["type": "attachment", "attachment": ["type": "queued_command", "prompt": "<pasted_content id=\"2\">补充正文</pasted_content>"]])
    let queuedBot = d.claudeTurns(Data((unfinished + "\n" + queued).utf8)).0.last
    check(steps(queuedBot).contains { str($0, "kind") == "user" && str($0, "detail") == "补充正文" }, "H05 补充里的粘贴包装去掉，用户原话保留")
    let long = String(repeating: "补充内容", count: 800)
    check(makeStep("user", "你补充说", detail: long)["detail"] as? String == long, "H07 用户补充全文不截断")
    eq((makeStep("tool", "工具", detail: long)["detail"] as? String)?.count, maxDetail + 1, "H07 工具输出仍截断")
    let t = TurnBuilder(), p = ClaudeStreamParser(turn: TurnBuilder())
    p.feed(json(#"{"type":"assistant","parent_tool_use_id":"child","message":{"content":[{"type":"text","text":"子代理正文"},{"type":"tool_use","id":"child-tool","name":"Bash","input":{}}]}}"#))
    check(p.turn.isEmpty, "H08 完整子代理 assistant 不混入主回答")
    let main = ClaudeStreamParser(turn: t)
    main.feed(json(#"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"main","name":"Bash","input":{}}]}}"#))
    main.feed(json(#"{"type":"user","parent_tool_use_id":"child","message":{"content":[{"type":"tool_result","tool_use_id":"main","content":"错误归属"}]}}"#))
    eq(str(t.step("main"), "status"), "running", "H08 子代理 user 不能更新主工具")
    main.feed(json(#"{"type":"user","parent_tool_use_id":"","message":{"content":[{"type":"tool_result","tool_use_id":"main","content":"真正结果"}]}}"#))
    eq(str(t.step("main"), "status"), "ok", "H08 空 parent 仍为主事件")
    for type in ["imageGeneration", "ImageGeneration"] {
        let t = TurnBuilder(); var final = ""
        d.codexHistoryItem(type: type, obj: ["status": "completed", "savedPath": "/fixture/generated.png"], turn: t, finalAnswer: &final)
        eq(str(t.steps.first, "path"), "/fixture/generated.png", "H09 生成图步骤保留路径")
        eq((t.finish(finalText: nil)["files"] as? [[String: Any]])?.first?["path"] as? String, "/fixture/generated.png", "H09 生成图可从文件卡打开")
    }
    for type in ["contextCompaction", "ContextCompaction"] {
        let t = TurnBuilder(); var final = ""
        d.codexHistoryItem(type: type, obj: [:], turn: t, finalAnswer: &final)
        eq(str(t.steps.first, "title"), "压缩上下文", "H10 压缩历史显示步骤")
    }
    let acpTurn = TurnBuilder(), acp: AcpParser
    acp = AcpParser(turn: acpTurn)
    acp.update(["sessionUpdate": "tool_call", "toolCallId": "edit", "name": "replace_file_content", "rawInput": ["TargetFile": "/fixture/a", "TargetContent": "old", "ReplacementContent": "new"], "status": "in_progress"])
    acp.update(["sessionUpdate": "tool_call_update", "toolCallId": "edit", "status": "completed"])
    eq(str(acpTurn.step("acp-edit"), "kind"), "edit", "H11 稀疏 completed 保留工具类别")
    eq((acpTurn.finish(finalText: nil)["files"] as? [[String: Any]])?.first?["added"] as? Int, 1, "H11 稀疏 completed 保留参数与 diff")
    acp.update(["sessionUpdate": "tool_call_update", "toolCallId": "edit", "content": []])
    eq(str(acpTurn.step("acp-edit"), "status"), "ok", "H11 content-only 不回退完成状态")
    eq((acpTurn.finish(finalText: nil)["files"] as? [Any])?.count, 1, "H11 不重复登记文件")
    acp.update(["sessionUpdate": "tool_call_update", "toolCallId": "edit", "status": "in_progress"])
    eq(str(acpTurn.step("acp-edit"), "status"), "ok", "H11 完成后迟到的进行中通知不倒退")
    d.historyLimits["fixture"] = 5000
    let page = d.recentHistory(Array(repeating: ["role": "bot", "text": "a"], count: 5001), into: ["conversationId": "fixture"])
    eq(page["omitted"] as? Int, 1, "H12 搜索深处历史后仍能继续显示更早")
    d.historyLimits["fixture"] = 300
    eq(d.recentHistory(Array(repeating: ["role": "bot", "text": "a"], count: 501), into: ["conversationId": "fixture"])["omitted"] as? Int, 201, "H12 上限之前分页不变")
    let imageOnly = #"{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGVsbG8="}}]}}"#
    try! (imageOnly + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    eq(d.claudeSummary(path: file, cid: "fixture", mtime: Date())?["title"] as? String, "图片对话", "H15 纯图无标题会话进入列表")
    // 任务会话：别的工具派出去的 claude -p（sdk-cli）在分界时间之后开始的才算；App 自己的（aipethub）和交互式的不算
    d.hooks.claudeTaskSince = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")
    func claudeTask(_ entrypoint: String, _ ts: String) -> Bool {
        let line = #"{"type":"user","entrypoint":"\#(entrypoint)","timestamp":"\#(ts)","message":{"content":"派出去的活"}}"#
        try! (line + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        return d.claudeSummary(path: file, cid: "fixture", mtime: Date())?["task"] as? Bool == true
    }
    check(claudeTask("sdk-cli", "2026-11-18T13:00:00.000Z"), "T01 分界之后的 sdk-cli 会话是任务会话")
    check(!claudeTask("sdk-cli", "2026-11-18T11:00:00.000Z"), "T01 分界之前的 sdk-cli 会话不动（分不清是不是 App 的）")
    check(!claudeTask("aipethub", "2026-11-18T13:00:00.000Z"), "T01 App 自己的会话不是任务会话")
    check(!claudeTask("claude-desktop", "2026-11-18T13:00:00.000Z") && !claudeTask("cli", "2026-11-18T13:00:00.000Z"), "T01 交互式会话不是任务会话")
    d.hooks.claudeTaskSince = nil
    func codexTask(_ source: String) -> Bool {
        let rows = [#"{"type":"session_meta","payload":{"id":"01a1ffff-0000-7000-8000-000000000001","cwd":"/fixture","source":"\#(source)"}}"#,
                    #"{"type":"event_msg","payload":{"type":"user_message","message":"派出去的活"}}"#]
        let path = dir + "/rollout-task.jsonl"
        try! (rows.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return d.rolloutSummary(path: path, mtime: Date())?["task"] as? Bool == true
    }
    check(codexTask("exec") && !codexTask("cli") && !codexTask("vscode"), "T02 codex exec 的会话是任务会话，交互式的不是")
    let prefix = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"完整消息\"}}\n"
    let rolloutFile = dir + "/rollout.jsonl"
    try! (Data(prefix.utf8) + Data([0x7B, 0x22, 0xE4, 0xB8])).write(to: URL(fileURLWithPath: rolloutFile))
    eq(d.readRollout(rolloutFile), prefix, "H16 跳过不完整 UTF8 尾行，保留完整前缀")
    try! (prefix + "{\"type\":\"unfinished\"}").write(toFile: rolloutFile, atomically: true, encoding: .utf8)
    eq(d.readRollout(rolloutFile), prefix, "H16 没有换行的尾部暂不读取")
    try! (prefix + prefix).write(toFile: rolloutFile, atomically: true, encoding: .utf8)
    eq(d.readRollout(rolloutFile), prefix + prefix, "H16 完整多字节行正常读取")
}
