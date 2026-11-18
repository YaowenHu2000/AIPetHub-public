// Codex 升级前后的格式可以落在同一份 rollout，不能因后面有新格式就丢掉前面的历史。
import Foundation
import SQLite3

func testCodexConfiguredHome() {
    print("· Codex 历史沿用 CLI 的 CODEX_HOME")
    let app = AppDelegate()
    let configured = NSTemporaryDirectory() + "aipethub-codex-home-" + UUID().uuidString + "/with space"
    app.hooks.codexEnvironment = ["CODEX_HOME": configured]
    eq(app.codexHome, configured, "显式 CODEX_HOME 不再读默认目录")
    app.hooks.codexEnvironment = ["CODEX_HOME": "~/codex-fixture"]
    eq(app.codexHome, app.home + "/codex-fixture", "CODEX_HOME 的主目录写法标准化")
    app.hooks.codexEnvironment = ["CODEX_HOME": ""]
    eq(app.codexHome, app.home + "/.codex", "空 CODEX_HOME 使用默认目录")
    app.hooks.codexEnvironment = [:]
    eq(app.codexHome, app.home + "/.codex", "未设置 CODEX_HOME 保持默认行为")
}

func testCodexProjectionFreshness() {
    print("· Codex 投影游标：保留数据库前缀并接入 rollout 新事件")
    let app = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-codex-projection-" + UUID().uuidString
    try! fm.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    app.hooks.codexEnvironment = ["CODEX_HOME": root]
    let cid = UUID().uuidString, path = root + "/sessions/rollout-fixture-" + cid + ".jsonl"
    let state = root + "/state_5.sqlite", database = root + "/thread_history_1.sqlite"
    func encoded(_ obj: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: .sortedKeys), as: UTF8.self) }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    func exec(_ file: String, _ sql: String) {
        var db: OpaquePointer?; sqlite3_open(file, &db)
        check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Codex 投影夹具 SQL 执行成功")
        sqlite3_close(db)
    }
    func item(_ kind: String, _ id: String, _ text: String = "") -> [String: Any] {
        ["type": kind, "id": id, "phase": "final_answer", "content": [["type": "text", "text": text]]]
    }
    func event(_ obj: [String: Any], turn: String = "first") -> String {
        encoded(["type": "event_msg", "timestamp": "2026-11-17T00:00:01.000Z", "payload": ["type": "item_completed", "turn_id": turn, "item": obj]]) + "\n"
    }
    let question = item("UserMessage", "u1", "第一问"), answer = item("AgentMessage", "a1", "第一答")
    let tool: [String: Any] = ["type": "CommandExecution", "id": "tool", "command": ["echo cached"], "exit_code": 0]
    let end = encoded(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "first"]]) + "\n"
    let prefix = encoded(["type": "session_meta", "payload": ["id": cid, "source": "cli", "cwd": root]]) + "\n"
        + event(question) + event(tool) + event(answer) + end
    let full = prefix + event(item("UserMessage", "u2", "第二问"), turn: "second") + event(item("AgentMessage", "a2", "第二答"), turn: "second")
        + encoded(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "second"]]) + "\n"
    exec(state, "CREATE TABLE threads(id TEXT,cwd TEXT,rollout_path TEXT); INSERT INTO threads VALUES(\(quote(cid)),\(quote(root)),\(quote(path)));")
    exec(database, """
        CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,created_at_ms INTEGER,completed_at_ms INTEGER,rollout_ordinal INTEGER,updated_at_ordinal INTEGER);
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,error_json TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER,rollout_end_ordinal INTEGER);
        CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES(\(quote(cid)),'first','completed','null',0,1000,1,4);
        INSERT INTO thread_history_projection_state VALUES(\(quote(cid)),\(prefix.utf8.count),5);
        """)
    exec(database, """
        INSERT INTO thread_turns VALUES('time-test','empty','inProgress','null',1794985212,NULL,1,NULL);
        INSERT INTO thread_turns VALUES('time-test','ended','failed','null',1794985300,1794985307,2,3);
        """)
    let placeholders = app.readCodexProjection("time-test").items
    eq(placeholders.map(\.created), [1794985212000, 1794985300000], "空回合的秒级开始时间统一为毫秒")
    eq(placeholders.map(\.completed), [1794985212000, 1794985307000], "空回合结束时间统一为毫秒，NULL 退回开始")
    for (index, original) in [question, tool, answer].enumerated() {
        var obj = original
        if index == 1 { obj["aggregatedOutput"] = "数据库保留的工具输出"; obj["status"] = "completed" }
        let kind = original["type"] as! String
        exec(database, "INSERT INTO thread_items VALUES(\(quote(cid)),'first',\(quote(original["id"] as! String)),\(quote(kind.prefix(1).lowercased() + kind.dropFirst())),\(quote(encoded(obj))),0,1000,\(index + 1),\(index + 1));")
    }
    func write(_ content: String) { try! content.write(toFile: path, atomically: true, encoding: .utf8) }
    func load() -> [[String: Any]] { app.readCodexConversation(cid: cid)["messages"] as? [[String: Any]] ?? [] }
    func output(_ messages: [[String: Any]]) -> String {
        messages.flatMap { $0["steps"] as? [[String: Any]] ?? [] }.first { str($0, "kind") == "command" }?["output"] as? String ?? ""
    }
    write(full)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: path)
    let newer = load()
    eq(newer.map { str($0, "text") }, ["第一问", "第一答", "第二问", "第二答"], "D1 非空投影落后也读到新回合，文件mtime不参与猜测")
    eq(output(newer), "数据库保留的工具输出", "D1 接尾部不丢数据库前缀里的工具字段")
    // 整个竞态期间保留一个 writer，避免最后一个连接退出后 WAL 被检查点回主文件。
    var writer: OpaquePointer?
    check(sqlite3_open(database, &writer) == SQLITE_OK, "D1 WAL writer 保持连接")
    defer { sqlite3_close(writer) }
    check(sqlite3_exec(writer, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK, "D1 竞态夹具启用 WAL")
    func advanceProjection() {
        app.hooks.codexProjectionRead = nil
        for (ordinal, obj) in [(5, item("UserMessage", "u2", "第二问")), (6, item("AgentMessage", "a2", "第二答"))] {
            let kind = obj["type"] as! String
            exec(database, "INSERT INTO thread_items VALUES(\(quote(cid)),'second',\(quote(obj["id"] as! String)),\(quote(kind.prefix(1).lowercased() + kind.dropFirst())),\(quote(encoded(obj))),1000,2000,\(ordinal),\(ordinal));")
        }
        exec(database, "INSERT INTO thread_turns VALUES(\(quote(cid)),'second','completed','null',1000,2000,5,7); UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(full.utf8.count),next_rollout_ordinal=8;")
    }
    func resetProjection() {
        exec(database, "DELETE FROM thread_items WHERE turn_id='second'; DELETE FROM thread_turns WHERE turn_id='second'; UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(prefix.utf8.count),next_rollout_ordinal=5;")
    }
    let initialMode = app.withReadableSQLite(database) { sqlite3_uri_boolean(sqlite3_db_filename($0, "main"), "immutable", 0) }
    eq(initialMode, 1, "D1 WAL刚启用但辅助文件未建立，夹具确实走immutable回退")
    app.hooks.codexProjectionRead = advanceProjection
    eq(load().map { str($0, "text") }, ["第一问", "第一答", "第二问", "第二答"], "D1 immutable回退也不让晚到的游标掩盖旧条目")
    resetProjection()
    let walMode = app.withReadableSQLite(database) { sqlite3_uri_boolean(sqlite3_db_filename($0, "main"), "immutable", 0) }
    eq(walMode, 0, "D1 写入建立WAL后使用普通只读连接")
    app.hooks.codexProjectionRead = advanceProjection
    eq(load().map { str($0, "text") }, ["第一问", "第一答", "第二问", "第二答"], "D1 读取条目后CLI推进游标，仍从同一WAL快照补足新回合")
    app.hooks.codexProjectionRead = nil
    resetProjection()
    func legacy(_ type: String, _ text: String) -> String {
        encoded(["type": "event_msg", "payload": ["type": type, "turn_id": "first", "message": text]]) + "\n"
    }
    let modernPrefix = String(prefix.dropLast(end.count))
    exec(database, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(modernPrefix.utf8.count),next_rollout_ordinal=4;")
    write(modernPrefix + legacy("user_message", "第一问") + legacy("agent_message", "第一答") + end)
    eq(load().map { str($0, "text") }, ["第一问", "第一答"], "D1/C2 modern在投影前缀、legacy在尾部时镜像只出现一次")
    eq(output(load()), "数据库保留的工具输出", "D1/C2 跨游标去重仍保留数据库工具字段")
    let legacyPrefix = encoded(["type": "session_meta", "payload": ["id": cid, "source": "cli", "cwd": root]]) + "\n"
        + legacy("user_message", "第一问") + event(tool) + legacy("agent_message", "第一答")
    exec(database, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(legacyPrefix.utf8.count),next_rollout_ordinal=4;")
    write(legacyPrefix + event(question) + event(answer) + end)
    let reverseMirror = load()
    eq(reverseMirror.map { str($0, "text") }, ["第一问", "第一答"], "D1/C2 legacy在投影前缀、modern在尾部也只保留一份正文")
    eq(reverseMirror.flatMap { $0["steps"] as? [[String: Any]] ?? [] }.map { str($0, "kind") }, ["command"], "D1/C2 较早镜像位置保留，工具仍在提问之后且不多出补充")
    exec(database, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(prefix.utf8.count),next_rollout_ordinal=5;")
    let started = encoded(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "second"]]) + "\n"
    write(prefix + started + event(item("UserMessage", "u2", "第二问"), turn: "second") + event(item("AgentMessage", "a2", "第二答"), turn: "second"))
    exec(database, "INSERT INTO thread_turns VALUES(\(quote(cid)),'second','inProgress','null',1000,NULL,5,NULL); UPDATE thread_history_projection_state SET next_rollout_byte_offset=\((prefix + started).utf8.count),next_rollout_ordinal=6;")
    eq(load().map { str($0, "text") }, ["第一问", "第一答", "第二问", "第二答"], "D1 数据库先记空回合、尾部才有提问时不误当成中途补充")
    resetProjection()
    let protocolOnly = prefix + encoded(["type": "event_msg", "payload": ["type": "token_count", "info": "protocol-only"]]) + "\n"
    write(protocolOnly)
    eq(output(load()), "数据库保留的工具输出", "D1 rollout只多协议事件时保留数据库内容")
    let update: [String: Any] = ["type": "CommandExecution", "id": "tool", "aggregated_output": "新的失败结果", "exit_code": 7]
    write(prefix + event(update) + encoded(["type": "event_msg", "payload": ["type": "turn_failed", "turn_id": "first", "error": ["message": "fixture update failure"]]]) + "\n")
    let updated = load(), commands = load().flatMap { $0["steps"] as? [[String: Any]] ?? [] }.filter { str($0, "kind") == "command" }
    eq(commands.count, 1, "D1 同item更新覆盖原步骤，不重复追加")
    eq(output(updated), "新的失败结果", "D1 rollout新snake_case结果覆盖数据库旧camelCase字段")
    eq(str(commands.first, "detail"), "echo cached", "D1 更新未带的工具命令仍从数据库保留")
    eq(str(commands.first, "status"), "error", "D1 同轮最新工具失败状态生效")
    write(full)
    exec(database, "DROP TABLE thread_history_projection_state;")
    let oldSchema = load()
    eq(oldSchema.map { str($0, "text") }, ["第一问", "第一答", "第二问", "第二答"], "D1 旧库无投影表仍按条目/回合ordinal接尾部")
    eq(output(oldSchema), "数据库保留的工具输出", "D1 无投影表也不覆盖数据库既有工具字段")
    exec(database, "CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER); INSERT INTO thread_history_projection_state VALUES(\(quote(cid)),\(full.utf8.count),8);")
    eq(load().map { str($0, "text") }, ["第一问", "第一答"], "D1 投影游标已追上时继续使用数据库")
    exec(database, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=\(prefix.utf8.count),next_rollout_ordinal=5;")
    try! fm.removeItem(atPath: path)
    try! "compressed fixture".write(toFile: path + ".zst", atomically: true, encoding: .utf8)
    try! full.write(toFile: path + ".zst.plain", atomically: true, encoding: .utf8)
    let cli = root + "/zstd"; try! installFakeCLI(at: cli, behavior: "zstd-read"); app.hooks.cliExecutable = cli
    eq(load().map { str($0, "text") }, ["第一问", "第一答", "第二问", "第二答"], "D1 压缩rollout用解压后的ordinal/字节进度，不拿压缩大小比较")
    try! fm.removeItem(atPath: path + ".zst")
    eq(load().map { str($0, "text") }, ["第一问", "第一答"], "D1 只有数据库时保持可读")
}

func testCodexMixedHistory() {
    print("· Codex 混合 rollout：顺序、镜像去重与真实重复")
    let app = AppDelegate()
    func event(_ payload: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": payload], options: .sortedKeys), as: UTF8.self)
    }
    func old(_ role: String, _ text: String, _ id: String = "") -> String {
        event(["type": role == "user" ? "user_message" : "agent_message", "message": text, "turn_id": id])
    }
    func item(_ role: String, _ text: String, _ id: String) -> String {
        event(["type": "item_completed", "turn_id": id, "item": ["type": role == "user" ? "UserMessage" : "AgentMessage", "phase": "final_answer", "content": [["type": "text", "text": text]]]])
    }
    func texts(_ rows: [String]) -> [String] { app.codexRolloutTurns(rows.joined(separator: "\n")).messages.map { str($0, "text") } }
    let oldTurn = [old("user", "旧提问"), old("bot", "旧回答")]
    let newTurn = [item("user", "新提问", "new"), item("bot", "新回答", "new")]
    eq(texts(oldTurn + newTurn), ["旧提问", "旧回答", "新提问", "新回答"], "旧格式在新格式之前仍保留")
    eq(texts(newTurn + oldTurn), ["新提问", "新回答", "旧提问", "旧回答"], "新格式后面的旧格式仍按顺序显示")
    let start = event(["type": "task_started", "turn_id": "mirror"])
    let end = event(["type": "task_complete", "turn_id": "mirror"])
    let legacyMirror = [old("user", "同问", "mirror"), old("bot", "同答", "mirror")]
    let modernMirror = [item("user", "同问", "mirror"), item("bot", "同答", "mirror")]
    eq(texts([start] + legacyMirror + modernMirror + [end]), ["同问", "同答"], "同一回合整段双写只显示一次")
    eq(texts([start] + modernMirror + legacyMirror + [end]), ["同问", "同答"], "镜像记录倒序也不重复")
    let wrapped = "旧版角色提示\n<USER_REQUEST>同问</USER_REQUEST>"
    eq(texts([start, old("user", wrapped, "mirror"), item("user", wrapped, "mirror"), item("bot", "同答", "mirror"), end]),
       ["同问", "同答"], "同轮双写带既有角色包装时按相同正文去重")
    let repeated = [old("user", "同问"), old("bot", "同答"), item("user", "同问", "later"), item("bot", "同答", "later")]
    eq(texts(repeated), ["同问", "同答", "同问", "同答"], "没有同轮证据的相同内容属于真实重复")
    let supplement = event(["type": "item_completed", "turn_id": "mirror", "item": ["type": "UserMessage", "content": [["type": "localImage", "path": "/fixture/steer.png"]]]])
    let command = event(["type": "item_completed", "turn_id": "mirror", "item": ["type": "CommandExecution", "command": ["echo", "done"], "exit_code": 0]])
    let mixed = [start, old("user", "同问", "mirror"), command, item("user", "同问", "mirror"), supplement, old("bot", "同答", "mirror"), item("bot", "同答", "mirror"), end]
    let result = app.codexRolloutTurns(mixed.joined(separator: "\n")).messages
    eq(result.map { str($0, "role") }, ["user", "bot"], "镜像提问不把夹在中间的工具拆成额外回合")
    let steps = result.last?["steps"] as? [[String: Any]] ?? []
    eq(steps.map { str($0, "kind") }, ["command", "user"], "工具和补充的原有顺序保留")
    eq((steps.last?["imageSources"] as? [[String: Any]])?.first?["path"] as? String, "/fixture/steer.png", "镜像合并仍保留补充图片")
    let summary = app.rolloutMessages((oldTurn + newTurn).joined(separator: "\n")).messages
    eq(summary.first?["text"], "旧提问", "列表摘要仍取真正最早的提问")
}
