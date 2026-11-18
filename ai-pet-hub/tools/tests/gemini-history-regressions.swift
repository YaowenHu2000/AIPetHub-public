// Gemini 库内状态来自 agy 内嵌 protobuf schema；跨会话步号相同也必须独立还原。
import Foundation
import SQLite3

func testGeminiHistoryRegressions() {
    testGeminiDesktopIndex()
    testGeminiDesktopHistory()
    print("· Gemini 工具结果状态与子会话步骤隔离")
    func varint(_ value: Int) -> Data {
        var value = value, data = Data()
        repeat { let byte = value & 127; value >>= 7; data.append(UInt8(byte | (value == 0 ? 0 : 128))) } while value > 0
        return data
    }
    func field(_ number: Int, _ data: Data) -> Data { varint(number * 8 + 2) + varint(data.count) + data }
    func text(_ number: Int, _ value: String) -> Data { field(number, Data(value.utf8)) }
    func tool(_ status: Int, error: String = "") -> Data {
        var data = varint(4 * 8) + varint(status)
        data += field(5, field(4, text(2, "write_to_file") + text(3, #"{"TargetFile":"/tmp/fixture.txt","CodeContent":"new"}"#)))
        data += field(140, field(2, text(1, "工具输出")))
        if !error.isEmpty { data += field(31, text(2, error)) }
        return data
    }
    let recordedError = field(24, field(3, text(2, "API error (attempt 1)")))
    let question = field(19, text(2, "问题"))
    let onlyError = agyDbTurns([(14, question), (17, recordedError)], cleanUser: { $0 })
    eq(onlyError.map { str($0, "role") }, ["user", "bot"], "只有 ERROR_MESSAGE 的一轮也要还原")
    let recovered = agyDbTurns([(14, question), (17, recordedError), (15, field(20, text(1, "OK")))], cleanUser: { $0 }).last
    eq(str((recovered?["steps"] as? [[String: Any]])?.first, "detail"), "API error (attempt 1)", "随后成功仍保留原始错误说明")
    eq(str(recovered, "text"), "OK", "重试成功保留回答")
    let nextError = field(24, field(3, text(2, "API error (attempt 2)")))
    let retriesOnly = [(14, question), (17, recordedError), (17, nextError)]
    func retrySteps(_ message: [String: Any]?) -> [[String: Any]] {
        (message?["steps"] as? [[String: Any]] ?? []).filter { str($0, "kind") == "error" }
    }
    let closed = agyDbTurns(retriesOnly, isHeld: { false }, cleanUser: { $0 }).last
    eq(str(closed, "outcome"), "failed", "连续出错后放弃是本轮的失败原因")
    eq(retrySteps(closed).map { str($0, "title") }, ["连接出错，重试 2 次后放弃"], "放弃时只留同一步，不重复添加通用错误")
    check(["attempt 1", "attempt 2"].allSatisfy { str(retrySteps(closed).first, "detail").contains($0) }, "连续重试的原始说明留在详情中")
    eq(str(retrySteps(closed).first, "status"), "error", "放弃的重试显示失败")
    let longFirst = field(24, field(3, text(2, String(repeating: "x", count: maxDetail))))
    let finalReason = agyDbTurns([(17, longFirst), (17, nextError)], cleanUser: { $0 }).last
    check(str(retrySteps(finalReason).first, "detail").contains("attempt 2"), "详情达到上限仍保留最终失败原因")
    let active = agyDbTurns(retriesOnly, isHeld: { true }, cleanUser: { $0 }).last
    eq(retrySteps(active).map { str($0, "title") }, ["连接出错，正在重试（第 2 次）"], "仍在重试时保留实时标题")
    eq(str(retrySteps(active).first, "status"), "running", "仍持库时不提前报放弃")
    let separated = agyDbTurns(retriesOnly + [(132, tool(7)), (17, recordedError), (15, field(20, text(1, "OK")))], cleanUser: { $0 }).last
    eq(retrySteps(separated).map { str($0, "title") }, ["连接出错 2 次，重试后恢复", "连接出错 1 次，重试后恢复"], "新工具说明连接已恢复，再次出错另起一组")
    eq(retrySteps(separated).map { str($0, "status") }, ["ok", "ok"], "恢复后两组状态和实时一致")
    eq(str((separated?["steps"] as? [[String: Any]])?.first { str($0,"kind") == "write" }, "status"), "error", "工具本身的错误保持独立")
    let twoTurns = agyDbTurns(retriesOnly + [(14, question), (15, field(20, text(1, "OK")))], isHeld: { true }, cleanUser: { $0 })
    eq(str(twoTurns[1], "outcome"), "failed", "后面另起一轮不能让上一轮的重试继续转圈")
    // 空闲的 ACP 客户端也会持库。只有覆盖本条错误的空闲摘要能证明这组重试已经结束。
    let app = AppDelegate(), fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    app.hooks.geminiCliDir = root.path
    try! fm.createDirectory(at: root.appendingPathComponent("conversations"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let cli = root.appendingPathComponent("fixture").path
    try! installFakeCLI(at: cli, behavior: "backend")
    try! "retry-abandoned".write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    app.hooks.cliExecutable = cli
    app.jsSink = { _, _ in }
    let ask = AskRequest(agent: "gemini", reqId: 72, prompt: "test", model: "fixture", effort: "low",
                         permissionMode: "default", workspace: root.path, conversationId: "", browserTools: false)
    let reply = withTestAsk(app, ask.key) { app.runGemini(ask) }
    let failedHistory = agyDbTurns([(14, question), (15, field(20, text(1, "先检查")))] + Array(retriesOnly.dropFirst()),
                                   isHeld: { false }, cleanUser: { $0 }).last
    eq(retrySteps(reply.turn).map { str($0, "title") }, retrySteps(failedHistory).map { str($0, "title") }, "agy -p 放弃后只留同一个失败步骤")
    check(str(retrySteps(reply.turn).first, "detail").contains("API error (attempt 2)"), "实时放弃详情也保留 result 的原始原因")
    eq(str(failedHistory, "text"), reply.reply, "历史放弃保留与实时相同的可重试提示，不把中途说明冒充回答")
    check((failedHistory?["steps"] as? [[String: Any]] ?? []).contains { str($0, "detail") == "先检查" }, "出错前的说明仍在工作步骤里")
    let db = app.geminiConversationDb("test")
    for path in [db, root.appendingPathComponent("conversation_summaries.db").path] { try! Data().write(to: URL(fileURLWithPath: path)) }
    _ = app.withSQLite(db, readOnly: false) { handle in
        let hex = recordedError.map { String(format: "%02x", $0) }.joined()
        sqlite3_exec(handle, "CREATE TABLE steps(idx INTEGER, step_type INTEGER, step_payload BLOB); INSERT INTO steps VALUES(0,17,X'\(hex)');", nil, nil, nil)
    }
    _ = app.withSQLite(root.appendingPathComponent("conversation_summaries.db").path, readOnly: false) { handle in
        sqlite3_exec(handle, "CREATE TABLE conversation_summaries(conversation_id TEXT,workspace_uris TEXT,status TEXT,not_fully_idle INT,step_count INT); INSERT INTO conversation_summaries VALUES('test','[]','CASCADE_RUN_STATUS_IDLE',0,0);", nil, nil, nil)
    }
    let holder = Process(), ready = Pipe(), release = Pipe()
    holder.executableURL = root.appendingPathComponent("agy")
    try! fm.copyItem(atPath: CommandLine.arguments[0], toPath: holder.executableURL!.path)
    holder.arguments = ["hold-session-file", db]; holder.standardOutput = ready; holder.standardInput = release
    try! holder.run()
    defer { release.fileHandleForWriting.closeFile(); holder.waitUntilExit() }
    eq(ready.fileHandleForReading.availableData, Data("ready".utf8), "模拟 agy 已持有会话库")
    func storedRetry() -> String {
        let last = (app.readGeminiConversation(cid: "test")["messages"] as? [[String: Any]])?.last
        return str(retrySteps(last).first, "status")
    }
    eq(storedRetry(), "running", "落后的空闲摘要不能结束新重试")
    _ = app.withSQLite(root.appendingPathComponent("conversation_summaries.db").path, readOnly: false) { handle in
        sqlite3_exec(handle, "UPDATE conversation_summaries SET step_count=1", nil, nil, nil)
    }
    eq(storedRetry(), "error", "持库客户端已经空闲时显示已放弃")
    let checkpoint = agyDbTurns([(14, field(19, text(2, "/compact"))), (23, varint(32) + varint(3))], cleanUser: { $0 })
    eq(str(checkpoint.last, "role"), "compact", "完成的 checkpoint 在原位置显示压缩提示")
    check(!agyDbTurns([(23, varint(32) + varint(7))], cleanUser: { $0 }).contains { str($0, "role") == "compact" }, "失败的 checkpoint 不报成功")
    let acp = AcpParser(turn: TurnBuilder())
    acp.update(["sessionUpdate":"tool_call", "toolCallId":"c", "title":"run_command", "rawInput":["CommandLine":"printf SUN"], "status":"in_progress"])
    acp.update(["sessionUpdate":"tool_call_update", "toolCallId":"c", "status":"completed", "content":[["type":"content","content":["type":"text","text":"SUN"]]]])
    eq(str(acp.turn.steps.first, "output"), "SUN", "ACP 成功命令实时带回输出")

    let failed = agyDbTurns([(132, tool(7, error: "写入被拒绝"))], cleanUser: { $0 }).first
    let failedStep = (failed?["steps"] as? [[String: Any]])?.first
    eq(str(failedStep, "status"), "error", "protobuf 字段 4 的 ERROR=7 不能标成成功")
    check(str(failedStep, "output").contains("写入被拒绝"), "从字段 31.2 保留明确错误原因")
    eq((failed?["files"] as? [[String: Any]] ?? []).count, 0, "失败的写工具不能声称改了文件")
    let done = agyDbTurns([(132, tool(3))], cleanUser: { $0 }).first
    eq(str((done?["steps"] as? [[String: Any]])?.first, "status"), "ok", "DONE=3 仍显示成功")
    eq((done?["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }, ["/tmp/fixture.txt"], "成功写入保留改动卡片")
    let pending = agyDbTurns([(132, tool(2))], cleanUser: { $0 }).first
    eq(str((pending?["steps"] as? [[String: Any]])?.first, "status"), "running", "RUNNING=2 不提前标成成功")
    eq((pending?["files"] as? [[String: Any]] ?? []).count, 0, "尚未完成的写工具不声称改动已完成")
    for held in [false, true] {
        let message = agyDbTurns([(132, tool(2))], isHeld: { held }, cleanUser: { $0 }).first
        eq(str((message?["steps"] as? [[String: Any]])?.first, "status"), held ? "running" : "error", "重开未完成工具时核对 agy 是否仍在持库")
    }
    let canceled = agyDbTurns([(132, tool(6))], cleanUser: { $0 }).first
    eq(str((canceled?["steps"] as? [[String: Any]])?.first, "status"), "interrupted", "CANCELED=6 和实时停止的工具同色")
    eq(str((canceled?["steps"] as? [[String: Any]])?.last, "title"), "已中断", "重开被停止的 agy 回合也有末尾说明")
    let resumed = agyDbTurns([(132, tool(12)), (15, field(20, text(1, "OK")))], cleanUser: { $0 }).first
    eq(str(resumed, "outcome"), "completed", "一个工具中断后仍继续回答，不把整轮算成中断")

    let turn = TurnBuilder(), parser = AgyStreamParser(turn: TurnBuilder())
    let p = AgyStreamParser(turn: turn)
    p.feed(["event": "init", "conversation_id": "main"])
    func update(_ cid: String, _ index: Int, _ type: String, _ fields: [String: Any] = [:], outer: Bool = false) {
        var step: [String: Any] = ["step_index": index, "step_type": type, "state": "DONE"]
        fields.forEach { step[$0.key] = $0.value }
        var event: [String: Any] = ["event": "step_update"]
        if outer { event["conversation_id"] = cid } else { step["conversation_id"] = cid }
        event["step_update"] = step
        p.feed(event)
    }
    update("main", 1, "agent_response", ["state": "RUNNING", "text_delta": "主"])
    update("child", 1, "agent_response", ["state": "RUNNING", "text_delta": "子"], outer: true)
    update("main", 1, "agent_response", ["text_delta": "回答"])
    update("child", 1, "agent_response", ["text_delta": "回答"])
    eq(turn.steps.filter { str($0, "kind") == "text" }.map { str($0, "detail") }, ["主回答", "子回答"], "同编号的正文缓冲与节流状态按会话分开")
    update("main", 2, "tool", ["tool_name": "view_file", "tool_info": ["parameters": ["AbsolutePath": "/tmp/main.swift"]]])
    update("child", 2, "tool", ["state": "ERROR", "tool_name": "view_file", "tool_info": ["parameters": ["AbsolutePath": "/tmp/child.swift"], "error": ["message": "子任务失败"]]])
    eq(turn.steps.filter { str($0, "kind") == "read" }.map { [str($0, "path"), str($0, "status")] },
       [["/tmp/main.swift", "ok"], ["/tmp/child.swift", "error"]], "同编号的工具不会被子会话覆盖")
    update("main", 5, "tool", ["tool_name": "run_command", "state": "CANCELED"])
    update("main", 6, "tool", ["tool_name": "run_command", "state": "INTERRUPTED"])
    eq(turn.steps.suffix(2).map { str($0, "status") }, ["interrupted", "interrupted"], "agy 单次模式同样识别明确取消的工具")
    update("main", 3, "error_message")
    update("child", 3, "error_message")
    update("child", 4, "agent_response", ["text_delta": "子恢复"])
    let retries = turn.steps.filter { str($0, "kind") == "error" }
    eq(retries.map { str($0, "status") }, ["running", "ok"], "子会话恢复不改变主会话重试")
    p.feed(["event": "result", "result": ["conversation_id": "main", "status": "ERROR", "error": "主任务失败"]])
    eq(turn.steps.filter { str($0, "kind") == "error" }.map { str($0, "status") }, ["error", "ok"], "主会话结果只收尾自己的重试")
    eq(p.conversationId, "main", "事件隔离后会话身份仍以最先 init 为准")
    parser.feed(["event": "step_update", "step_update": ["step_index": 1, "step_type": "agent_response", "state": "DONE", "text_delta": "旧流"]])
    eq(str(parser.turn.step("agy-1"), "detail"), "旧流", "不带会话 ID 的旧流继续可读")
}

// 两个来源复用相同的原始 ID，能同时检验列表、搜索和写入是否串库。
private func testGeminiDesktopHistory() {
    let d = AppDelegate(), fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let cli = root + "/antigravity-cli", desktop = root + "/antigravity"
    d.hooks.geminiCliDir = cli
    d.hooks.geminiDesktopRunning = { true }
    defer { try? fm.removeItem(atPath: root) }
    for dir in [cli, desktop] {
        try! fm.createDirectory(atPath: dir + "/conversations", withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(dir + "/conversation_summaries.db", &db)
        sqlite3_exec(db, """
            CREATE TABLE conversation_summaries(conversation_id TEXT,title TEXT,preview TEXT,last_modified_time TEXT,workspace_uris TEXT,nesting_depth INT,parent_conversation_id TEXT);
            INSERT INTO conversation_summaries VALUES('both','\(dir)','',CURRENT_TIMESTAMP,'["file:///fixture"]',0,'');
            """, nil, nil, nil)
        sqlite3_close(db)
        sqlite3_open(dir + "/conversations/both.db", &db)
        sqlite3_exec(db, "CREATE TABLE steps(idx INT,step_type INT,step_payload BLOB)", nil, nil, nil)
        sqlite3_close(db)
        let logs = dir + "/brain/both/.system_generated/logs"
        try! fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try! "{\"type\":\"USER_INPUT\",\"content\":\"\(dir)\"}\n".write(toFile: logs + "/transcript.jsonl", atomically: true, encoding: .utf8)
    }
    func listed() -> [String] {
        var ids: [String] = []
        d.jsSink = { fn, data in
            if fn == "onConversationsListed" { ids = (data["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
        }
        d.listGemini(); d.geminiQueue.sync {}
        return ids.sorted()
    }
    // 摘要文件里会留下已归档的行，列表限额应只统计仍有会话库的记录。
    _ = d.withSQLite(desktop + "/conversation_summaries.db", readOnly: false) { db in
        sqlite3_exec(db, """
            INSERT INTO conversation_summaries VALUES('older','older','','2020-01-01','[]',0,'');
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<321)
            INSERT INTO conversation_summaries SELECT 'gone-'||i,'','','2099-01-01','[]',0,'' FROM n;
            """, nil, nil, nil)
    }
    let older = desktop + "/conversations/older.db"
    try! Data().write(to: URL(fileURLWithPath: older))
    check(listed().contains("desktop:older"), "陈旧摘要不能挤掉可打开的桌面会话")
    try! fm.removeItem(atPath: older)
    let key = "desktop:both"
    eq(listed(), ["both", key], "同 ID 的两个独立库都可打开")
    eq(d.geminiIds(inWorkspace: "/fixture").sorted(), ["both", key], "项目枚举保留来源")
    eq(d.searchSources(agent: "gemini", files: nil).sources.map(\.cid).sorted(), ["both", key], "正文搜索覆盖两份历史")
    let found = d.searchSources(agent: "gemini", files: nil).sources
    for entry in found {
        let loaded = d.searchHistory(entry, agent: "gemini", explicit: false)
        eq(str(loaded.messages.first, "text"), entry.cid == key ? desktop : cli, "搜索命中的正文来自所选库")
    }
    let history = d.readGeminiConversation(cid: key)
    eq(str((history["messages"] as? [[String: Any]])?.first, "text"), desktop, "桌面转写只从桌面目录回退")
    let req = AskRequest(agent: "gemini", reqId: 9, prompt: "test", model: "fixture", effort: "low", permissionMode: "default", workspace: root, conversationId: key)
    eq(d.acpArgs(req), ["acp", "--app-data-dir", "antigravity"], "预热和冷启动选择桌面目录")
    eq(d.acpSessionParams(req)["sessionId"] as? String, "both", "ACP 收到原始 ID")
    eq(d.conversationFile(agent: "gemini", cid: key), desktop + "/conversations/both.db", "预热指纹跟随来源")
    let fake = root + "/cli"
    try! installFakeCLI(at: fake, behavior: "backend"); d.hooks.cliExecutable = fake
    func request(_ cid: String) -> AskRequest {
        AskRequest(agent: "gemini", reqId: 10, prompt: "test", model: "fixture", effort: "low",
                   permissionMode: "default", workspace: root, conversationId: cid, browserTools: false)
    }
    for running: Bool? in [true, nil, false] {
        d.hooks.geminiDesktopRunning = { running }
        let blocked = running != false
        let ask = request("desktop:fixture-session")
        let db = d.geminiConversationDb(ask.conversationId)
        try! Data().write(to: URL(fileURLWithPath: db))
        let sent = withTestAsk(d, ask.key) { d.runGemini(ask) }
        if blocked {
            check(sent.reply.hasPrefix("⚠️") && sent.reply.contains("覆盖") && sent.conversationId == ask.conversationId,
                  "桌面仍可能缓存会话时拦住发送并解释覆盖风险")
        } else { eq(sent.reply, "fixture-ok", "桌面退出后照常通过 ACP 续聊") }
        var live: [String: Any]?
        d.jsSink = { fn, data in if fn == "onSessionLive" { live = data } }
        d.checkSessionLive(agent: "gemini", cid: key)
        let until = Date().addingTimeInterval(3)
        while live == nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        eq(live?["live"] as? Bool, blocked, "输入框提示随桌面运行状态更新")
        if blocked { eq(str(live, "status"), "readOnly", "没有持库也能区分桌面只读提示") }
        var deleted: [String: Any]?
        d.jsSink = { fn, data in if fn == "onConversationDeleted" { deleted = data } }
        d.deleteConversation(agent: "gemini", cid: ask.conversationId)
        d.geminiQueue.sync {}; d.geminiQueue.sync {}
        eq(deleted?["ok"] as? Bool, !blocked, "桌面版开着（或查不清）时不能从 App 删，关着时可以")
        eq(fm.fileExists(atPath: db), blocked, "拦住删除时保留桌面数据库，允许时挪走")
        if blocked {
            check(str(deleted, "reason").contains("先退出反重力"), "单条删除提示先退出反重力")
            let local = "fixture-session"
            try! Data().write(to: URL(fileURLWithPath: d.geminiConversationDb(local)))
            let localAsk = request(local)
            let localReply = withTestAsk(d, localAsk.key) { d.runGemini(localAsk) }
            eq(localReply.reply, "fixture-ok", "同 ID 的 CLI 会话照常续聊")
            d.jsSink = { fn, data in if fn == "onConversationsDeleted" { deleted = data } }
            d.deleteConversations(agent: "gemini", ids: ["desktop:" + local, local])
            d.geminiQueue.sync {}; d.geminiQueue.sync {}
            eq(deleted?["deleted"] as? [String], [local], "批量删除仍能删除同 ID 的 CLI 库")
            eq(deleted?["failed"] as? [String], ["desktop:" + local], "批量删除保留只读会话")
            check(str(deleted, "reason").contains("先退出反重力") && fm.fileExists(atPath: db), "批量删除也提示先退出反重力")
        }
    }
    try? fm.removeItem(atPath: d.geminiConversationDb("desktop:fixture-session"))   // App 删不掉桌面会话了，测试自己清掉夹具
    try! "unsupported".write(toFile: root + "/mode", atomically: true, encoding: .utf8)
    let reply = withTestAsk(d, req.key) { d.runGemini(req) }
    check(reply.reply.contains("ACP") && reply.conversationId == key, "桌面 ACP 不可用时不能退回 CLI 默认目录")
    let binary = root + "/Antigravity.app/Contents/Resources/bin/language_server"
    try! fm.createDirectory(atPath: (binary as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! fm.copyItem(atPath: CommandLine.arguments[0], toPath: binary)
    let p = Process(), ready = Pipe(), release = Pipe()
    p.executableURL = URL(fileURLWithPath: binary); p.arguments = ["hold-session-file", desktop + "/conversations/both.db"]
    p.standardOutput = ready; p.standardInput = release; try! p.run()
    eq(ready.fileHandleForReading.availableData, Data("ready".utf8), "桌面测试进程已持库")
    check(d.geminiResumeBlock(key) != nil && d.geminiResumeBlock("both") == nil, "只拦截桌面正在持有的同一份库")
    check(!d.deleteOne(agent: "gemini", cid: key), "持库时禁止删除")
    release.fileHandleForWriting.closeFile(); p.waitUntilExit()
    check(d.deleteOne(agent: "gemini", cid: key), "桌面版关着、库也释放后，桌面会话可以删除")
    check(fm.fileExists(atPath: cli + "/conversations/both.db"), "删除桌面记录保留同 ID 的 CLI 记录")
    // 模拟单库多入口，再次列出时应合并。
    let alias = desktop + "/conversations/both.db"
    if fm.fileExists(atPath: alias) { try! fm.removeItem(atPath: alias) }
    try! fm.createSymbolicLink(atPath: alias, withDestinationPath: cli + "/conversations/both.db")
    eq(listed(), ["both"], "同一文件只列一次")
    eq(d.searchSources(agent: "gemini", files: nil).sources.map(\.cid), ["both"], "共享库只搜索一次")
    check(d.deleteOne(agent: "gemini", cid: "both"), "共享库和链接一起进入废纸篓")
    check(!fm.fileExists(atPath: cli + "/conversations/both.db") && (try? fm.destinationOfSymbolicLink(atPath: alias)) == nil,
          "共享会话删除后不留真库或悬空链接")
}


/// 桌面版关着时从 App 删除：把这个 ID 从它的三份索引里删干净，别的会话和其余字节原样不动，并留备份。
func testGeminiDesktopIndex() {
    print("· 反重力桌面版索引：关着时删除连索引一起清")
    let fm = FileManager.default, d = AppDelegate()
    let root = NSTemporaryDirectory() + "aipethub-desktop-index-" + UUID().uuidString
    let backups = URL(fileURLWithPath: root + "-backup")
    defer { try? fm.removeItem(atPath: root); try? fm.removeItem(at: backups) }
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    TestHooks.geminiIndexBackupRoot = backups
    defer { TestHooks.geminiIndexBackupRoot = nil }
    func varint(_ value: Int) -> Data {
        var value = value, data = Data()
        repeat { let byte = value & 127; value >>= 7; data.append(UInt8(byte | (value == 0 ? 0 : 128))) } while value > 0
        return data
    }
    func field(_ number: Int, _ data: Data) -> Data { varint(number * 8 + 2) + varint(data.count) + data }
    func entry(_ map: Int, _ id: String, _ summary: String) -> Data { field(map, field(1, Data(id.utf8)) + field(2, Data(summary.utf8))) }
    let gone = "11111111-1111-4111-8111-111111111111", kept = "22222222-2222-4222-8222-222222222222"
    let agyhub = entry(1, kept, "留下") + entry(1, gone, "删掉") + entry(2, gone, "删掉") + entry(2, kept, "留下")
    let jetbox = entry(1, gone, "删掉") + entry(1, kept, "留下")
    try! agyhub.write(to: URL(fileURLWithPath: root + "/agyhub_summaries_proto.pb"))
    try! jetbox.write(to: URL(fileURLWithPath: root + "/jetbox_summaries_proto.pb"))
    var db: OpaquePointer?
    sqlite3_open(root + "/conversation_summaries.db", &db)
    sqlite3_exec(db, "CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text); INSERT INTO conversation_summaries VALUES ('\(gone)','x'),('\(kept)','y');", nil, nil, nil)
    sqlite3_close(db)

    check(d.removeFromDesktopIndex(gone, root: root), "IDX 删除成功")
    eq(fm.contents(atPath: root + "/agyhub_summaries_proto.pb"), entry(1, kept, "留下") + entry(2, kept, "留下"), "IDX agyhub 两张表都只删掉这个 ID，其余字节不变")
    eq(fm.contents(atPath: root + "/jetbox_summaries_proto.pb"), entry(1, kept, "留下"), "IDX jetbox 只删掉这个 ID")
    var rows: [String] = []
    _ = d.withSQLite(root + "/conversation_summaries.db", readOnly: true) { db in
        d.queryRows(db, "SELECT conversation_id FROM conversation_summaries", []) { rows.append(d.columnText($0, 0)) }
    }
    eq(rows, [kept], "IDX 摘要库只删掉这一行")
    let backup = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil))?.first
    check(backup.map { fm.contents(atPath: $0.appendingPathComponent("agyhub_summaries_proto.pb").path) == agyhub } ?? false, "IDX 改之前留了完整备份")
    // 不认识的结构：宁可不改
    try! Data([0x08, 0x01]).write(to: URL(fileURLWithPath: root + "/jetbox_summaries_proto.pb"))
    check(!d.removeFromDesktopIndex(kept, root: root), "IDX 结构不认识时不改")
    eq(fm.contents(atPath: root + "/agyhub_summaries_proto.pb"), entry(1, kept, "留下") + entry(2, kept, "留下"), "IDX 不改时别的索引也不动")
}
