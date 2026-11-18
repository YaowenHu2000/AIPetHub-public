// 用同一条打开会话的消息桥验证记录补数，夹具只放在临时目录。
import Foundation
import SQLite3

func testHistoryContext() {
    let app = AppDelegate(), fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func context(_ agent: String, _ cid: String) -> [String: Any]? {
        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        app.jsSink = { name, row in
            if name == "onConversationLoaded" { result = row["context"] as? [String: Any]; done.signal() }
        }
        app.loadConversation(agent: agent, cid: cid)
        // 回包一到就往下走；期限只防卡死。压缩记录要经 python 写的假 zstd 跑好几次，机器很忙时 5 秒会偶发来不及。
        // 20 秒仍短于 App 给 zstd 的 30 秒超时，等到超时才回包的情况照样判失败
        check(done.wait(timeout: .now() + 20) == .success, "打开历史及时返回")
        app.jsSink = nil
        return result
    }

    let file = root.appendingPathComponent("claude.jsonl")
    let answer = #"{"type":"assistant","timestamp":"2026-11-10T12:00:00.123Z","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":80,"cache_creation_input_tokens":10}}}"#
    let side = answer.replacingOccurrences(of: "{\"type\"", with: "{\"isSidechain\":true,\"type\"").replacingOccurrences(of: "80", with: "800")
    try! (answer + "\n" + side + "\n{\"type\":").write(to: file, atomically: true, encoding: .utf8)
    app.claudeCache["c"] = (0, nil, file.path)
    let claude = context("claude", "c")
    eq(int(claude, "used"), 97, "Claude 只统计主会话最后一次请求的四项用量")
    eq(int(claude, "max"), 200_000, "Claude Haiku 4.5 的默认窗口")
    eq(claude?["estimated"] as? Bool, true, "Claude 历史总数标估算")
    eq(claude?["at"] as? Double, 1794312000123, "新旧按回答时间判断")
    try! answer.replacingOccurrences(of: "claude-haiku-4-5", with: "claude-opus-5-5").write(to: file, atomically: true, encoding: .utf8)
    eq(int(context("claude", "c"), "max"), 1_000_000, "原生百万窗口不要求模型名带后缀")

    let sessions = root.appendingPathComponent("sessions")
    try! fm.createDirectory(at: sessions, withIntermediateDirectories: true)
    app.hooks.codexEnvironment = ["CODEX_HOME": root.path]
    let usage = #"{"timestamp":"2026-11-10T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":12,"input_tokens":9,"cached_input_tokens":7,"output_tokens":3},"model_context_window":1000}}}"#
    let rollout = usage.replacingOccurrences(of: "12,\"input", with: "99,\"input") + "\n" + usage + "\n" + #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"# + "\n"
    for packed in [false, true] {
        let id = packed ? "packed" : "plain"
        let path = sessions.appendingPathComponent("rollout-" + id + ".jsonl" + (packed ? ".zst" : "")).path
        if packed {
            let cli = root.appendingPathComponent("zstd").path
            try! installFakeCLI(at: cli, behavior: "zstd-read")
            app.hooks.cliExecutable = cli
            try! Data().write(to: URL(fileURLWithPath: path))
        }
        try! rollout.write(toFile: path + (packed ? ".plain" : ""), atomically: true, encoding: .utf8)
        let codex = context("gpt", id)
        eq(int(codex, "used"), 12, "Codex 最后一条有效用量 " + id)
        eq(int(codex, "max"), 1000, "Codex 同一事件的上限")
        eq((codex?["parts"] as? [[String: Any]])?.compactMap { $0["tokens"] as? Int }, [7, 2, 3], "Codex 缓存 / 新输入 / 输出")
    }

    app.hooks.geminiCliDir = root.appendingPathComponent("antigravity-cli").path
    for (index, store) in app.geminiStores.enumerated() {
        try! fm.createDirectory(atPath: store.root + "/conversations", withIntermediateDirectories: true)
        let path = store.database("same")
        fm.createFile(atPath: path, contents: nil)
        _ = app.withSQLite(path, readOnly: false) { db in
            // gen_metadata → chat_model → chat_start_metadata → context_window_metadata。
            let hex = index == 0 ? "0a084a065204080a2064" : "0a084a06520408142064"
            sqlite3_exec(db, "CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB); INSERT INTO gen_metadata VALUES(1,X'\(hex)');", nil, nil, nil)
        }
        let gemini = context("gemini", store.key("same"))
        eq(int(gemini, "used"), (index + 1) * 10, "两套 Gemini 会话库按来源补数")
        eq(int(gemini, "max"), 100, "Gemini 使用同条生成记录的上限")
        eq(gemini?["estimated"] as? Bool, true, "Gemini 记录标为估算")
    }
}
