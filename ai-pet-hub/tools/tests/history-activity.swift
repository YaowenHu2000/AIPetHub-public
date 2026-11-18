// 最后一轮的状态必须来自当前会话，即使没有新正文、投影还没追上或只有压缩的记录。
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
    try! Data(#"{"projectless-thread-ids":["desktop"]}"#.utf8).write(to: URL(fileURLWithPath: root + "/.codex-global-state.json"))
    let cid = UUID().uuidString, path = sessions + "/rollout-fixture-" + cid + ".jsonl"
    let meta = #"{"type":"session_meta","payload":{"id":"CID","cwd":"/work","source":"cli"}}"#.replacingOccurrences(of: "CID", with: cid) + "\n"
    let prefix = meta + event("task_started", "one") + event("user_message", "one", extra: ["message": "标题"])
    try! Data(prefix.utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), true, "只有 rollout 的 task_started 表示正在运行")
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
    try! Data(ended.utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), false, "投影仍在运行时，较新的 rollout 结束优先")
    try! Data((ended + event("task_started", "two")).utf8).write(to: URL(fileURLWithPath: path))
    eq(last(cid), true, "上一轮已结束，尾部新回合尚无条目时仍显示运行")
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
    // 压缩和未压缩列表共用历史入口；CLI 的索引里没有这份 rollout。
    try! Data("packed".utf8).write(to: URL(fileURLWithPath: path + ".zst"))
    try! Data(prefix.utf8).write(to: URL(fileURLWithPath: path + ".zst.plain"))
    let cli = root + "/zstd"; try! installFakeCLI(at: cli, behavior: "zstd-read"); d.hooks.cliExecutable = cli
    let done = DispatchSemaphore(value: 0)
    var items: [[String: Any]] = [], projectless: [String] = []
    d.jsSink = { fn, data in if fn == "onConversationsListed" { items = data["items"] as? [[String: Any]] ?? []; projectless = data["projectlessIds"] as? [String] ?? []; done.signal() } }
    d.listCodex(); check(done.wait(timeout: .now() + 5) == .success, "侧栏读取完成")
    eq(items.first { str($0, "id") == cid }?["title"] as? String, "标题", "仅有 .jsonl.zst 的主会话进入侧栏")
    eq(d.codexIds(inWorkspace: "/work"), [cid], "仅有压缩文件的主会话进入项目清单")
    let desktop = items.first { str($0, "id") == "desktop" }, project = items.first { str($0, "id") == "project" }
    eq(projectless, ["desktop"], "归组采用桌面端单独标记的 ID")
    eq(desktop?["cwd"] as? String, dir, "归组不改真实 cwd")
    eq(str(project, "cwd"), dir, "同样目录形状的真实项目保留")
    eq(d.readCodexConversation(cid: "desktop")["cwd"] as? String, dir, "打开后仍使用真实 cwd")
    check(d.deleteOne(agent: "gpt", cid: cid), "列表中压缩的旧 rollout 仍能归档")
    check(fm.fileExists(atPath: root + "/archived_sessions/" + (path as NSString).lastPathComponent + ".zst"), "旧 rollout 原样归档保留压缩")
}
