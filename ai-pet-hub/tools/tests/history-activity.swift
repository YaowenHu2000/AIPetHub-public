// 最后一轮的状态必须来自当前会话，即使没有新正文、投影还没追上或只有压缩的记录。
// 失败或停下前久等的一轮，重开的工作时长要算到这一轮结束（testHistoryFailureTail）。
import Cocoa
import SQLite3

func testHistoryActivity() {
    let d = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-history-activity-" + UUID().uuidString
    let sessions = root + "/sessions", db = root + "/state_5.sqlite", projected = root + "/thread_history_1.sqlite"
    try! fm.createDirectory(atPath: sessions, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    d.hooks.codexEnvironment = ["CODEX_HOME": root]
    func sql(_ path: String, _ query: String) {
        var db: OpaquePointer?; sqlite3_open(path, &db)
        check(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK, "会话状态夹具 SQL")
        sqlite3_close(db)
    }
    func event(_ type: String, _ turn: String, extra: [String: Any] = [:]) -> String {
        let payload = extra.merging(["type": type, "turn_id": turn]) { _, b in b }
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-11-17T06:00:00.000Z", "payload": payload]), as: UTF8.self) + "\n"
    }
    func last(_ cid: String) -> Bool? { (d.readCodexConversation(cid: cid)["lastTurn"] as? [String: Any])?["running"] as? Bool }
    let dir = d.home + "/Documents/Codex/2026-11-17/normal"
    sql(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, first_user_message TEXT, cwd TEXT, updated_at INTEGER, archived INTEGER, source TEXT, rollout_path TEXT)")
    for id in ["desktop", "project"] {
        sql(db, "INSERT INTO threads VALUES ('\(id)','title','question','\(dir)',1,0,'cli','')")
    }
    sql(db, "INSERT INTO threads VALUES ('job','title','question','\(dir)',1,0,'exec','')")
    try! Data(#"{"projectless-thread-ids":["desktop"]}"#.utf8).write(to: URL(fileURLWithPath: root + "/.codex-global-state.json"))
    let cid = UUID().uuidString, path = sessions + "/rollout-fixture-" + cid + ".jsonl"
    let meta = #"{"type":"session_meta","payload":{"id":"CID","cwd":"/work","source":"cli"}}"#.replacingOccurrences(of: "CID", with: cid) + "\n"
    let prefix = meta + event("task_started", "one") + event("user_message", "one", extra: ["message": "标题"])
    try! Data(prefix.utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), true, "只有 rollout 的 task_started 表示正在运行")
    // 支持写锁的 Codex 有 thread-writer-locks 目录：写入端正常释放会删锁文件，崩溃只留下没人锁着的文件。
    let locks = root + "/thread-writer-locks", lockFile = locks + "/" + cid + ".lock"
    try! fm.createDirectory(atPath: locks, withIntermediateDirectories: true)
    eq(last(cid), false, "写锁已释放、没有结束事件的 task_started 是崩溃遗留，不算在别处运行")
    fm.createFile(atPath: lockFile, contents: nil)
    eq(last(cid), false, "崩溃留下的锁文件没人锁着，不算在别处运行")
    let holder = open(lockFile, O_RDONLY)
    check(holder >= 0 && flock(holder, LOCK_EX) == 0, "夹具占住 Codex 写锁")
    eq(last(cid), true, "写锁被占时仍在别处运行")
    let ended = prefix + event("turn_aborted", "one")
    try! Data(ended.utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), false, "rollout 中止后立即结束")
    sql(projected, """
        CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_type TEXT,item_json TEXT,created_at_ms INTEGER,completed_at_ms INTEGER,rollout_ordinal INTEGER);
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,error_json TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER);
        CREATE TABLE thread_history_projection_state(thread_id TEXT,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
        INSERT INTO thread_turns VALUES('\(cid)','one','inProgress','null',1794985212,NULL,1);
        INSERT INTO thread_history_projection_state VALUES('\(cid)',\(prefix.utf8.count),3);
        """)
    try! Data(prefix.utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), true, "SQLite 空回合的 inProgress 也传给网页")
    flock(holder, LOCK_UN)
    eq(last(cid), false, "投影里遗留的 inProgress 在写锁释放后不再算在别处运行")
    flock(holder, LOCK_EX)
    try! Data(ended.utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), false, "投影仍在运行时，较新的 rollout 结束优先")
    try! Data((ended + event("task_started", "two")).utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), true, "上一轮已结束，尾部新回合尚无条目时仍显示运行")
    close(holder); try! fm.removeItem(atPath: locks)
    sql(projected, "UPDATE thread_turns SET status='completed' WHERE thread_id='\(cid)'")
    try! fm.removeItem(atPath: path)
    eq(last(cid), false, "仅有数据库也能确认已结束")
    sql(projected, """
        INSERT INTO thread_turns VALUES('overlap','old','completed','null',100,102,1);
        INSERT INTO thread_turns VALUES('overlap','new','inProgress','null',103,NULL,3);
        INSERT INTO thread_items VALUES('overlap','old','agentMessage','{"text":"上一轮的说明"}',104000,104000,4);
        """)
    let overlap = d.readCodexConversation(cid: "overlap")
    eq((overlap["lastTurn"] as? [String: Any])?["running"] as? Bool, true, "上一轮的条目晚到，最后一轮仍按回合表判断")
    let overlapSteps = (overlap["messages"] as? [[String: Any]])?.last?["steps"] as? [[String: Any]]
    eq(str(overlapSteps?.last, "title"), "未完成", "晚到条目不会抢走正在运行的回合标题")
    sql(projected, """
        ALTER TABLE thread_items ADD COLUMN started_at_ms INTEGER;
        INSERT INTO thread_turns VALUES('steered','t','completed','null',1,5,0);
        INSERT INTO thread_items VALUES('steered','t','userMessage','{"content":[{"type":"text","text":"原始问题"}]}',1000,1000,1,NULL);
        INSERT INTO thread_items VALUES('steered','t','userMessage','{"content":[{"type":"text","text":"补充"}]}',2006,2006,18,NULL);
        INSERT INTO thread_items VALUES('steered','t','commandExecution','{"command":"sleep 3"}',5000,5000,21,2000);
        """)
    let ordered = d.codexDbTurns("steered").last?["steps"] as? [[String: Any]]
    eq(ordered?.map { str($0, "kind") }, ["command","user"], "命令已启动 6ms 后补充，历史按实际开始顺序")
    let start: [String: Any] = ["event": ["type": "turn/start", "time": 1000]]
    let user: [String: Any] = ["event": ["type": "user/message", "time": 1100, "data": ["source": ["kind": "user"], "content": [["type": "text", "text": "问题"]]]]]
    let finish: [String: Any] = ["event": ["type": "turn/end", "time": 1500]]
    let metaOnly: [String: Any] = ["event": ["type": "session/title", "time": 9999999]]
    eq(dshTurns([start, user]).map { str($0, "role") }, ["user", "bot"], "DeepSeek 已写提问、还在思考时有本轮的运行标题")
    let emptySteps = dshTurns([start, user, finish, start]).last?["steps"] as? [[String: Any]]
    eq(str(emptySteps?.last, "title"), "未完成", "上一轮已结束时，新的空回合有自己的标题")
    eq(dshLastTurn([start, user, metaOnly])?.updatedAt, 1.1, "改会话标题不能给陈旧的运行回合续期")
    let question: [String:Any] = ["event":["type":"user/message","data":["source":["kind":"user","rpcId":"a"],"content":[["type":"text","text":"原问"]]]]]
    for (rpc, outcome, active) in [("a","failed",false),("a","interrupted",false),("b","failed",true)] {
        let local = [["rpc":rpc,"outcome":outcome,"text":"半句"]]
        eq(dshLastTurn([start,question],endings:local)?.running,active,"DeepSeek 缺结束记录 \(rpc) \(outcome) 的运行状态")
        eq(str(dshTurns([start,question],endings:local).last,"outcome"),active ? "incomplete" : outcome,"DeepSeek 同一调用的正文结局")
    }
    // 压缩和未压缩列表共用历史入口；CLI 的索引里没有这份 rollout。
    try! Data("packed".utf8).write(to: URL(fileURLWithPath: path + ".zst"))
    try! Data(prefix.utf8).write(to: URL(fileURLWithPath: path + ".zst.plain"))
    let cli = root + "/zstd"; try! installFakeCLI(at: cli, behavior: "zstd-read"); d.hooks.cliExecutable = cli
    let done = DispatchSemaphore(value: 0)
    var items: [[String: Any]] = [], projectless: [String] = []
    d.hooks.jsSink = { fn, data in if fn == "onConversationsListed" { items = data["items"] as? [[String: Any]] ?? []; projectless = data["projectlessIds"] as? [String] ?? []; done.signal() } }
    // 侧栏要起一次假 zstd 子进程，机器忙时启动就要好几秒；回调一到就往下走，期限只防卡死，
    // 所以放到产品自己给 zstd 的 30 秒之后。
    d.listCodex(); check(waitSignal(done), "侧栏读取完成")
    eq(items.first { str($0, "id") == cid }?["title"] as? String, "标题", "仅有 .jsonl.zst 的主会话进入侧栏")
    eq(d.codexIds(inWorkspace: "/work"), [cid], "仅有压缩文件的主会话进入项目清单")
    // 删除项目时，侧栏归进「任务会话」的不能跟着归档：清单里标出哪些是 codex exec 派出去的
    var execTasks: [String] = []
    eq(d.codexIds(inWorkspace: dir) { execTasks.append($0) }.sorted(), ["job", "project"], "项目清单含同目录的任务会话")
    eq(execTasks, ["job"], "项目清单标出 codex exec 派出去的任务会话")
    let desktop = items.first { str($0, "id") == "desktop" }, project = items.first { str($0, "id") == "project" }
    eq(projectless, ["desktop"], "归组采用桌面端单独标记的 ID")
    eq(desktop?["cwd"] as? String, dir, "归组不改真实 cwd")
    eq(str(project, "cwd"), dir, "同样目录形状的真实项目保留")
    eq(d.readCodexConversation(cid: "desktop")["cwd"] as? String, dir, "打开后仍使用真实 cwd")
    sql(db, "ALTER TABLE threads DROP COLUMN first_user_message; INSERT INTO threads VALUES ('archived','旧归档','',1,1,'cli',''),('child','旧子线程','',1,0,'{subagent}','')")
    d.listCodex(); check(waitSignal(done), "旧版索引侧栏读取完成")
    eq(items.filter { ["project","archived","child"].contains(str($0,"id")) }.map { str($0,"title") }, ["title"], "旧版索引保留主会话标题并排除归档与子线程")
    check(d.deleteOne(agent: "gpt", cid: cid), "列表中压缩的旧 rollout 仍能归档")
    check(fm.fileExists(atPath: root + "/archived_sessions/" + (path as NSString).lastPathComponent + ".zst"), "旧 rollout 原样归档保留压缩")
}

/// 最后一条进展之后又等了几分钟才失败或被停下：重开显示的「已工作」要算到这一轮结束（实时就是这么算的），
/// 不能停在最后一条进展；正常完成的轮次保持原来的算法。时刻取自一轮真实 Codex 失败（11 分 43 秒，最后进展在第 21 秒）。
func testHistoryFailureTail() {
    print("· 失败前久等的一轮：重开的工作时长算到这一轮结束")
    let app = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-failure-tail-" + UUID().uuidString
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let base = 1_700_000_000.0, cid = "a0000000-0000-4000-8000-000000000009"
    func seconds(_ rows: [[String: Any]]) -> Double {
        ((rows.last { str($0, "role") == "bot" }?["duration"] as? Double ?? 0) * 1000).rounded() / 1000
    }
    // Codex：回合表记着结束时刻和时长；条目只到第 24 秒的一条说明
    let database = root + "/thread_history_1.sqlite"
    var db: OpaquePointer?; sqlite3_open(database, &db)
    func sql(_ query: String) { check(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK, "回合时长夹具 SQL") }
    sql("""
        CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,started_at_ms INTEGER,completed_at_ms INTEGER);
        CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,error_json TEXT,started_at INTEGER,completed_at INTEGER,duration_ms INTEGER,rollout_end_ordinal INTEGER);
        """)
    func turn(_ id: String, _ ordinal: Int, _ status: String, start: Int, end: Int?, ms: Int?, items: [(Int, String, String)]) {
        sql("INSERT INTO thread_turns VALUES('\(cid)','\(id)',\(ordinal * 10),'\(status)','{\"message\":\"connection lost\"}',\(Int(base) + start),\(end.map { "\(Int(base) + $0)" } ?? "NULL"),\(ms.map(String.init) ?? "NULL"),\(ordinal * 10 + 9));")
        for (i, (at, kind, text)) in items.enumerated() {
            let object: [String: Any] = kind == "userMessage" ? ["type": kind, "id": "\(id)-\(i)", "content": [["type": "text", "text": text]]]
                : ["type": kind, "id": "\(id)-\(i)", "phase": text == "答完了" ? "final_answer" : "commentary", "text": text]
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let ms = Int(base) * 1000 + at
            sql("INSERT INTO thread_items VALUES('\(cid)','\(id)','\(id)-\(i)',\(ordinal * 10 + 1 + i),\(ms),'\(json)','\(kind)',\(ms),\(ms));")
        }
    }
    turn("failed", 0, "failed", start: 0, end: 703, ms: 702_587, items: [(2_706, "userMessage", "查一下文件"), (24_047, "agentMessage", "正在检查")])
    turn("done", 1, "completed", start: 800, end: 812, ms: 12_400, items: [(800_000, "userMessage", "再看看"), (810_000, "agentMessage", "答完了")])
    turn("stopped", 2, "interrupted", start: 900, end: 960, ms: 60_300, items: [(900_000, "userMessage", "数到一万"), (905_000, "agentMessage", "开始数")])
    turn("crashed", 3, "inProgress", start: 1000, end: nil, ms: nil, items: [(1_000_000, "userMessage", "接着查"), (1_004_000, "agentMessage", "在查")])
    sqlite3_close(db)
    app.hooks.codexKnownEndings = ["crashed": ["cid": cid, "outcome": "failed", "text": "在查", "error": "Codex 退出了", "at": base + 1090]]
    let codex = app.codexDbTurns(cid, databasePath: database).filter { str($0, "role") == "bot" }
    eq(codex.map { str($0, "outcome") }, ["failed", "completed", "interrupted", "failed"], "Codex 四轮的结局不变")
    eq(codex.map { seconds([$0]) }, [700.294, 10, 60.3, 90], "Codex 失败、停止、崩溃的一轮算到结束；正常完成的一轮仍到最后一条回答")
    let rollout = [
        ["type": "event_msg", "timestamp": "2023-11-14T22:13:20.000Z", "payload": ["type": "task_started", "turn_id": "failed"]],
        ["type": "event_msg", "timestamp": "2023-11-14T22:13:22.706Z", "payload": ["type": "item_completed", "turn_id": "failed", "item": ["type": "UserMessage", "id": "u", "content": [["type": "text", "text": "查一下文件"]]]]],
        ["type": "event_msg", "timestamp": "2023-11-14T22:13:44.047Z", "payload": ["type": "item_completed", "turn_id": "failed", "item": ["type": "AgentMessage", "id": "a", "content": [["type": "text", "text": "正在检查"]]]]],
        ["type": "event_msg", "timestamp": "2023-11-14T22:25:03.000Z", "payload": ["type": "turn_failed", "turn_id": "failed", "error": ["message": "connection lost"]]],
    ].map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
    eq(seconds(app.codexRolloutTurns(rollout).messages), 700.294, "Codex 只有 rollout 时同样算到结束事件")

    // Claude：记录只到第 24 秒的一段正文，本机记着 703 秒时失败
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func stamp(_ offset: Double) -> String { iso.string(from: Date(timeIntervalSince1970: base + offset)) }
    func jsonl(_ rows: [[String: Any]]) -> Data {
        Data(rows.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n").utf8)
    }
    let ending: [String: Any] = ["agent": "claude", "cid": cid, "position": 0, "prompt": "查一下文件", "text": "正在检查", "start": base,
                                 "end": base + 703, "outcome": "failed", "reason": "connection lost", "reqId": 71]
    let question: [String: Any] = ["type": "user", "timestamp": stamp(2.706), "message": ["content": "查一下文件"]]
    let progress: [String: Any] = ["type": "assistant", "timestamp": stamp(24.047), "message": ["content": [["type": "text", "text": "正在检查"]]]]
    app.hooks.localEndings = [ending]
    let claude = app.claudeTurns(jsonl([question, progress]), cid: cid).0
    eq(claude.last.map { str($0, "outcome") }, "failed", "Claude 本机结局仍认领这一轮")
    eq(seconds(claude), 700.294, "Claude 算到本机记下的失败时刻")
    eq(seconds(app.claudeTurns(jsonl([question]), cid: cid).0), 700.294, "Claude 记录里只有提问时也算到失败时刻")
    eq(seconds(app.claudeTurns(Data(), cid: cid).0), 703, "Claude 记录里连提问都没有时按本机记下的起止")
    app.hooks.localEndings = []
    eq(seconds(app.claudeTurns(jsonl([question, progress]), cid: cid).0), 21.341, "Claude 没有本机结局时仍按记录")

    // Gemini 本来就用本机结局的起止，作为参照
    app.hooks.geminiCliDir = root + "/gemini"
    var gemini = ending; gemini["agent"] = "gemini"
    app.hooks.localEndings = [gemini]
    eq(seconds(app.readGeminiConversation(cid: cid)["messages"] as? [[String: Any]] ?? []), 703, "Gemini 用本机结局的起止")
    app.hooks.localEndings = []

    // DeepSeek：服务退出、没写结束事件时用本机结局补足；有结束事件的照旧按结束事件
    func event(_ type: String, _ at: Double, _ data: [String: Any]) -> [String: Any] { ["event": ["type": type, "time": (base + at) * 1000, "data": data]] }
    let rows = [event("turn/start", 0, ["turn": 1]),
                event("user/message", 2.706, ["turn": 1, "content": [["type": "text", "text": "查一下文件"]], "source": ["kind": "user", "rpcId": "aph-ask-test"]]),
                event("assistant/message", 24.047, ["turn": 1, "step": 1, "message": ["content": [["type": "text", "text": "正在检查"]]]])]
    let ended = rows + [event("turn/end", 703, ["turn": 1, "reason": ["kind": "error", "error": ["message": "connection lost"]]])]
    var deepseek = ending; deepseek["agent"] = "deepseek"; deepseek["rpc"] = "aph-ask-test"; deepseek["end"] = base + 703.5
    eq(seconds(dshTurns(rows, endings: [deepseek])), 700.794, "DeepSeek 服务退出时算到本机记下的失败时刻")
    eq(seconds(dshTurns(ended)), 700.294, "DeepSeek 有结束事件时按结束事件")
    eq(seconds(dshTurns(ended, endings: [deepseek])), 700.294, "DeepSeek 有结束事件时不被本机结局改写")
    eq(seconds(dshTurns(rows)), 21.341, "DeepSeek 没有本机结局时仍按记录")
}
