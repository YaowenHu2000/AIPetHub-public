// 离线自测：不需要任何 CLI、会话记录或网络，只喂固定的流式 JSON 给解析器，检查转出来的「步骤 + 正文 + 改动文件」。
// CLI 升级后事件格式变了、或者改解析器时改坏了，这里会先报出来。和 selftest.swift 一起编译：build/selftest parsers
import Foundation

private var failures = 0
private var checks = 0

private func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)（\(file):\(line)）") }
}

private func eq<T: Equatable>(_ got: T, _ want: T, _ what: String, file: String = #fileID, line: Int = #line) {
    check(got == want, "\(what)：应为 \(want)，实际 \(got)", file: file, line: line)
}

private func json(_ s: String) -> [String: Any] {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else {
        fatalError("测试用的 JSON 写错了：\(s)")
    }
    return obj
}

private func str(_ d: [String: Any]?, _ k: String) -> String { d?[k] as? String ?? "" }
private func int(_ d: [String: Any]?, _ k: String) -> Int { d?[k] as? Int ?? -1 }

private func testHelpers() {
    print("· 工具函数")
    eq(lineCount(""), 0, "空串行数")
    eq(lineCount("a\nb"), 2, "两行")
    eq(lineCount("a\nb\n"), 2, "末尾换行不多算一行")
    let d = simpleDiff(old: "x\ny", new: "z")
    eq(d, "@@\n-x\n-y\n+z", "simpleDiff")
    let c = diffCounts("--- a\n+++ b\n@@\n-x\n-y\n+z\n 上下文")
    eq(c.added, 1, "diff 新增行数（不算 +++ 文件头）")
    eq(c.removed, 2, "diff 删除行数（不算 --- 文件头）")
    eq(clip("abcdef", 3), "abc…", "clip")
    eq(codexChangeKind("add"), "create", "Codex 改动类型：字符串")
    eq(codexChangeKind(["type": "delete"]), "delete", "Codex 改动类型：历史记录里的对象")
    eq(codexChangeKind(nil), "edit", "Codex 改动类型：缺省")
}

private func testTurnBuilder() {
    print("· TurnBuilder")
    let t = TurnBuilder()
    var pushed: [(Int, String)] = []
    t.onChange = { i, s in pushed.append((i, s["status"] as? String ?? "")) }
    t.addThink("")
    t.addThink("")
    eq(t.steps.count, 1, "连续的空思考合并成一步")
    t.add(makeStep("command", "运行命令", status: "running"), key: "c1")
    t.update("c1", ["status": "ok"])
    eq(pushed.map { $0.0 }, [0, 1, 1], "每次新增 / 更新都回调，带步骤序号")
    t.add(makeStep("text", "说明", detail: "最终回答"))
    t.addFile("/tmp/a.txt", kind: "edit", diff: "@@\n-a\n+b\n+c")
    t.addFile("/tmp/a.txt", kind: "edit", diff: "@@\n+d")
    let out = t.finish(finalText: "最终回答")
    eq(str(out, "text"), "最终回答", "正文")
    eq((out["steps"] as? [[String: Any]])?.count ?? -1, 2, "和正文相同的最后一段说明从步骤里拿掉")
    let files = out["files"] as? [[String: Any]] ?? []
    eq(files.count, 1, "同一个文件的多次改动合并")
    eq(int(files.first, "added"), 3, "合并后的新增行数")
    eq(int(files.first, "removed"), 1, "合并后的删除行数")

    let t2 = TurnBuilder()
    t2.add(makeStep("read", "读取", status: "running"))
    t2.add(makeStep("text", "说明", detail: "只有这一段"))
    let out2 = t2.finish(finalText: nil)
    eq(str(out2, "text"), "只有这一段", "没有 result 时，最后一段说明就是正文")
    eq(str((out2["steps"] as? [[String: Any]])?.first, "status"), "ok", "结束时还在转圈的步骤收尾成完成")
}

private func testClaude() {
    print("· Claude Code 流式事件")
    let t = TurnBuilder()
    let p = ClaudeStreamParser(turn: t)
    let lines = [
        #"{"type":"system","subtype":"init","session_id":"sess-1"}"#,
        #"{"type":"assistant","session_id":"sess-1","message":{"id":"m1","content":[{"type":"thinking","thinking":"先看看文件"},{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"/w/a.swift"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"文件内容"}]}}"#,
        #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"tu2","name":"Edit","input":{"file_path":"/w/a.swift","old_string":"旧一\n旧二","new_string":"新"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","content":"The file has been updated"}]}}"#,
        #"{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"tu3","name":"Write","input":{"file_path":"/w/new.md","content":"一\n二\n"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu3","content":"File created successfully at: /w/new.md"}]}}"#,
        #"{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"tu4","name":"Bash","input":{"command":"false","description":"跑测试"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu4","is_error":true,"content":[{"type":"text","text":"exit 1"}]}]}}"#,
        #"{"type":"assistant","message":{"id":"m5","content":[{"type":"tool_use","id":"tu5","name":"mcp__docs__search","input":{}}]}}"#,
        #"{"type":"assistant","message":{"id":"m6","content":[{"type":"text","text":"改好了。"}]}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"改好了。","duration_ms":1234,"session_id":"sess-1"}"#,
    ]
    lines.forEach { p.feed(json($0)) }
    eq(p.sessionId, "sess-1", "会话 ID")
    eq(p.result ?? "", "改好了。", "result")
    eq(p.isError, false, "is_error")
    eq(p.durationMs ?? 0, 1234, "用时")
    let kinds = t.steps.map { str($0, "kind") }
    eq(kinds, ["think", "read", "edit", "write", "command", "tool", "text"], "步骤种类和顺序")
    eq(str(t.step("tu1"), "status"), "ok", "读取完成")
    eq(str(t.step("tu1"), "path"), "/w/a.swift", "读取的路径")
    eq(int(t.step("tu2"), "added"), 1, "Edit 新增行数")
    eq(int(t.step("tu2"), "removed"), 2, "Edit 删除行数")
    eq(str(t.step("tu3"), "title"), "新建 new.md", "Write 返回 created 时标题改成新建")
    eq(str(t.step("tu4"), "status"), "error", "命令失败")
    eq(str(t.step("tu4"), "output"), "exit 1", "失败时带上输出")
    eq(str(t.step("tu4"), "title"), "跑测试", "命令用 description 当标题")
    eq(str(t.step("tu5"), "title"), "调用 docs · search", "MCP 工具名")
    let out = t.finish(finalText: p.result)
    let files = out["files"] as? [[String: Any]] ?? []
    eq(files.map { str($0, "path") }, ["/w/a.swift", "/w/new.md"], "改动的文件")
    eq(files.map { str($0, "kind") }, ["edit", "create"], "改动类型")
    eq((out["steps"] as? [[String: Any]])?.count ?? -1, 6, "正文不重复出现在步骤里")

    // 逐字输出（--include-partial-messages）：流式显示过的文字块，完整消息到了以后更新同一步，不重复添加
    let t2 = TurnBuilder()
    let p2 = ClaudeStreamParser(turn: t2)
    [
        #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start","message":{"id":"mA"}}}"#,
        #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}"#,
        #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你"}}}"#,
        #"{"type":"stream_event","parent_tool_use_id":"tuX","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"子代理的话"}}}"#,
        #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"好"}}}"#,
        #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_stop","index":0}}"#,
    ].forEach { p2.feed(json($0)) }
    eq(t2.steps.count, 1, "流式文字是一步")
    eq(str(t2.steps.first, "detail"), "你好", "流式文字拼起来，子代理的不算")
    eq(str(t2.steps.first, "status"), "ok", "块结束后不再转圈")
    p2.feed(json(#"{"type":"assistant","message":{"id":"mA","content":[{"type":"text","text":"你好！"}]}}"#))
    eq(t2.steps.count, 1, "完整消息到了不重复添加")
    eq(str(t2.steps.first, "detail"), "你好！", "用完整内容更新")
}

private func testCodex() {
    print("· Codex exec --json 事件")
    let t = TurnBuilder()
    let p = CodexStreamParser(turn: t)
    [
        #"{"type":"thread.started","thread_id":"th-1"}"#,
        #"{"type":"item.started","item":{"id":"r1","type":"reasoning","text":""}}"#,
        #"{"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"想清楚了"}}"#,
        #"{"type":"item.started","item":{"id":"c1","type":"command_execution","command":"ls"}}"#,
        #"{"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"ls","aggregated_output":"a\nb\n","exit_code":0,"status":"completed"}}"#,
        #"{"type":"item.completed","item":{"id":"c2","type":"command_execution","command":"false","aggregated_output":"","exit_code":1,"status":"failed"}}"#,
        #"{"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[{"path":"/w/a.py","kind":"update","diff":"@@\n-x\n+y"},{"path":"/w/b.py","kind":"add"}]}}"#,
        #"{"type":"item.started","item":{"id":"w1","type":"web_search","query":"swift"}}"#,
        #"{"type":"item.completed","item":{"id":"w1","type":"web_search","query":"swift"}}"#,
        #"{"type":"item.completed","item":{"id":"t1","type":"todo_list","items":[{"text":"第一步","completed":true},{"text":"第二步","completed":false}]}}"#,
        #"{"type":"item.started","item":{"id":"a1","type":"agent_message","text":"半句"}}"#,
        #"{"type":"item.completed","item":{"id":"a1","type":"agent_message","text":"做完了。"}}"#,
    ].forEach { p.feed(json($0)) }
    eq(p.threadId, "th-1", "会话 ID")
    eq(p.lastAgentMessage, "做完了。", "最后的回答")
    eq(t.steps.map { str($0, "kind") }, ["think", "command", "command", "edit", "write", "web", "todo", "text"], "步骤种类和顺序（新建文件的步骤图标用 write）")
    eq(str(t.step("r1"), "detail"), "想清楚了", "思考完成后填上内容")
    eq(str(t.step("r1"), "status"), "ok", "思考不再转圈")
    eq(str(t.step("c1"), "output"), "a\nb", "命令输出")
    eq(str(t.step("c2"), "status"), "error", "退出码非 0 算失败")
    eq(str(t.step("w1"), "status"), "ok", "搜索完成")
    eq(str(t.step("t1"), "detail"), "☑ 第一步\n☐ 第二步", "计划")
    let out = t.finish(finalText: p.lastAgentMessage)
    let files = out["files"] as? [[String: Any]] ?? []
    eq(files.map { str($0, "kind") }, ["edit", "create"], "改动类型")
    eq(int(files.first, "added"), 1, "diff 新增")
    eq(str(out, "text"), "做完了。", "正文")

    let t2 = TurnBuilder()
    let p2 = CodexStreamParser(turn: t2)
    p2.feed(json(#"{"type":"error","message":"{\"error\":{\"message\":\"额度用完了\",\"code\":\"rate_limit\"}}"}"#))
    p2.feed(json(#"{"type":"turn.failed","error":{"message":"普通报错"}}"#))
    eq(p2.errors, ["额度用完了（rate_limit）", "普通报错"], "错误信息：取出接口 JSON 里的 message 和错误码")
    eq(str(t2.steps.last, "status"), "error", "失败的一轮有出错步骤")
}

private func testAgy() {
    print("· Gemini（agy）stream-json 事件")
    let t = TurnBuilder()
    let p = AgyStreamParser(turn: t)
    [
        #"{"event":"init","conversation_id":"conv-1"}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"sub-9","step_index":1,"step_type":"tool","state":"RUNNING","tool_name":"view_file","tool_info":{"parameters":{"AbsolutePath":"file:///w/a.py"}}}}"#,
        #"{"event":"step_update","step_update":{"step_index":1,"step_type":"tool","state":"DONE","tool_name":"view_file","tool_info":{"parameters":{"AbsolutePath":"file:///w/a.py"}}}}"#,
        #"{"event":"step_update","step_update":{"step_index":2,"step_type":"tool","state":"DONE","tool_name":"replace_file_content","tool_info":{"parameters":{"TargetFile":"/w/a.py","ReplacementChunks":[{"TargetContent":"x","ReplacementContent":"y\nz"}]}}}}"#,
        #"{"event":"step_update","step_update":{"step_index":3,"step_type":"tool","state":"DONE","tool_name":"write_to_file","tool_info":{"parameters":{"TargetFile":"/w/new.md","CodeContent":"一\n二"}}}}"#,
        #"{"event":"step_update","step_update":{"step_index":4,"step_type":"tool","state":"ERROR","tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"false"},"error":{"message":"退出码 1"}}}}"#,
        #"{"event":"step_update","step_update":{"step_index":5,"step_type":"tool","state":"DONE","tool_name":"search_web","tool_info":{"parameters":{"Query":"swift"}}}}"#,
        #"{"event":"step_update","step_update":{"step_index":6,"step_type":"error_message","state":"DONE"}}"#,
        #"{"event":"step_update","step_update":{"step_index":7,"step_type":"error_message","state":"DONE"}}"#,
        #"{"event":"step_update","step_update":{"step_index":8,"step_type":"agent_response","state":"RUNNING","text_delta":"改"}}"#,
        #"{"event":"step_update","step_update":{"step_index":8,"step_type":"agent_response","state":"DONE","text_delta":"好了。"}}"#,
        #"{"event":"result","result":{"conversation_id":"conv-1","status":"SUCCESS","response":"改好了。","duration_seconds":12.5,"denied_actions":[{"display_name":"删除文件"}]}}"#,
    ].forEach { p.feed(json($0)) }
    eq(p.conversationId, "conv-1", "会话 ID 以最先给出的为准，不被子代理的换掉")
    eq(p.response ?? "", "改好了。", "回答")
    eq(p.status ?? "", "SUCCESS", "状态")
    eq(p.durationSeconds ?? 0, 12.5, "用时")
    eq(p.denied, ["删除文件"], "被拒绝的操作")
    eq(t.steps.map { str($0, "kind") }, ["read", "edit", "write", "command", "web", "error", "text", "denied"], "步骤种类和顺序")
    eq(str(t.step("agy-1"), "path"), "/w/a.py", "file:// 路径还原")
    eq(str(t.step("agy-1"), "status"), "ok", "同一步的后续事件更新原来那一步")
    eq(str(t.step("agy-4"), "status"), "error", "命令失败")
    eq(str(t.step("agy-4"), "output"), "退出码 1", "失败原因")
    eq(str(t.step("agy-4"), "detail"), "false", "命令内容")
    eq(str(t.step("agy-5"), "title"), "联网搜索 swift", "联网搜索")
    eq(str(t.step("agy-retry-1"), "title"), "连接出错 2 次，重试后恢复", "连续的重试合成一步，恢复后更新")
    eq(str(t.step("agy-retry-1"), "status"), "ok", "重试恢复")
    eq(str(t.step("agy-8"), "detail"), "改好了。", "流式文字拼起来")
    let out = t.finish(finalText: p.response)
    let files = out["files"] as? [[String: Any]] ?? []
    eq(files.map { str($0, "path") }, ["/w/a.py", "/w/new.md"], "改动的文件")
    eq(files.map { str($0, "kind") }, ["edit", "create"], "改动类型")
    eq(int(files.first, "added"), 2, "替换块新增行数")
    eq(int(files.first, "removed"), 1, "替换块删除行数")
    check(p.failure(exitStatus: 0, stderr: "") == nil, "正常结束没有出错原因")

    // 连不上、重试后放弃：result 的 status 不是 SUCCESS
    let t2 = TurnBuilder()
    let p2 = AgyStreamParser(turn: t2)
    p2.feed(json(#"{"event":"step_update","step_update":{"step_index":1,"step_type":"error_message","state":"DONE"}}"#))
    p2.feed(json(#"{"event":"result","result":{"status":"ERROR","error":"连不上服务器","response":""}}"#))
    eq(str(t2.step("agy-retry-1"), "status"), "error", "重试后放弃")
    eq(p2.failure(exitStatus: 1, stderr: "") ?? "", "连不上服务器", "出错原因取 result 里的 error")
    // 没有 result 就退出了：从 stderr 里找「error: …」那一行
    let p3 = AgyStreamParser(turn: TurnBuilder())
    eq(p3.failure(exitStatus: 2, stderr: "warn: x\nerror: 没登录\nAGY_ERROR: {}\n") ?? "", "没登录", "出错原因取 stderr 的 error 行")
    eq(p3.failure(exitStatus: 9, stderr: "") ?? "", "agy 意外退出（退出码 9）", "什么都没有时报退出码")
}

private func testCodexApp() {
    print("· Codex app-server 通知（交互式）")
    let t = TurnBuilder()
    let p = CodexAppParser(turn: t)
    var userTexts: [String] = []
    p.onUserMessage = { userTexts.append($0) }
    let events: [(String, String)] = [
        ("thread/started", #"{"thread":{"id":"th-9"}}"#),
        ("turn/started", #"{"turn":{"id":"turn-1"}}"#),
        ("item/completed", #"{"item":{"type":"userMessage","id":"u1","content":[{"type":"text","text":"提问"}]}}"#),
        ("item/started", #"{"item":{"type":"reasoning","id":"r1","summary":[],"content":[]}}"#),
        ("item/completed", #"{"item":{"type":"reasoning","id":"r1","summary":["想好了"],"content":[]}}"#),
        ("item/started", #"{"item":{"type":"commandExecution","id":"c1","command":"/bin/zsh -lc 'echo it'\\''s > a.txt'","status":"inProgress"}}"#),
        ("item/completed", #"{"item":{"type":"commandExecution","id":"c1","command":"/bin/zsh -lc 'echo it'\\''s > a.txt'","status":"completed","aggregatedOutput":"ok\n","exitCode":0}}"#),
        ("item/completed", #"{"item":{"type":"commandExecution","id":"c2","command":"rm -rf x","status":"declined","aggregatedOutput":null,"exitCode":null}}"#),
        ("item/started", #"{"item":{"type":"fileChange","id":"f1","status":"inProgress","changes":[{"path":"/w/a.py","kind":{"type":"update","move_path":null},"diff":"@@\n-x\n+y\n+z"},{"path":"/w/b.py","kind":{"type":"add"},"diff":"+new"}]}}"#),
        ("item/completed", #"{"item":{"type":"fileChange","id":"f1","status":"completed","changes":[{"path":"/w/a.py","kind":{"type":"update","move_path":null},"diff":"@@\n-x\n+y\n+z"},{"path":"/w/b.py","kind":{"type":"add"},"diff":"+new"}]}}"#),
        ("item/completed", #"{"item":{"type":"fileChange","id":"f2","status":"declined","changes":[{"path":"/w/c.py","kind":{"type":"delete"},"diff":""}]}}"#),
        ("item/completed", #"{"item":{"type":"userMessage","id":"u2","content":[{"type":"text","text":"补充一句"}]}}"#),
        ("turn/plan/updated", #"{"plan":[{"step":"第一步","status":"completed"},{"step":"第二步","status":"inProgress"},{"step":"第三步","status":"pending"}]}"#),
        ("item/started", #"{"item":{"type":"agentMessage","id":"m1","text":"","phase":"final_answer"}}"#),
        ("item/agentMessage/delta", #"{"itemId":"m1","delta":"做"}"#),
        ("item/agentMessage/delta", #"{"itemId":"m1","delta":"完了"}"#),
        ("item/completed", #"{"item":{"type":"agentMessage","id":"m1","text":"做完了。","phase":"final_answer"}}"#),
        ("error", #"{"error":{"message":"断了一下"},"willRetry":true}"#),
        ("turn/completed", #"{"turn":{"id":"turn-1","status":"completed","error":null}}"#),
    ]
    events.forEach { p.notify($0.0, json($0.1)) }
    eq(p.threadId, "th-9", "会话 ID")
    eq(p.turnId, "turn-1", "回合 ID（中途补充、停止要用）")
    eq(p.status ?? "", "completed", "回合状态")
    eq(userTexts, ["提问", "补充一句"], "用户的话轮到时回调（提问本身 + 中途补充）")
    eq(t.steps.map { str($0, "kind") }, ["think", "command", "command", "edit", "write", "delete", "todo", "text", "error"], "步骤种类和顺序（自动重试也记成一步）")
    eq(str(t.step("retry"), "title"), "连接中断，正在重试", "自动重试显示成一步，不再什么都不显示")
    eq(str(t.step("r1"), "detail"), "想好了", "思考摘要")
    eq(str(t.step("c1"), "detail"), "echo it's > a.txt", "命令去掉外面包的那层 shell")
    eq(str(t.step("c1"), "output"), "ok", "命令输出")
    eq(str(t.step("c2"), "status"), "error", "没被同意的命令标成失败")
    eq(str(t.step("f2-0"), "status"), "error", "没被同意的改动标成失败")
    eq(p.changes["f1"]?.count ?? 0, 2, "改动内容记着（审批时给用户看）")
    eq(str(t.step("plan"), "detail"), "☑ 第一步\n▸ 第二步\n☐ 第三步", "计划")
    eq(str(t.step("m1"), "detail"), "做完了。", "回答文字：逐字拼起来，写完用完整内容")
    eq(p.lastAgentMessage, "做完了。", "最后的回答")
    eq(p.errors, [String](), "会自动重试的错误不算出错")
    let out = t.finish(finalText: p.lastAgentMessage)
    let files = out["files"] as? [[String: Any]] ?? []
    eq(files.map { str($0, "path") }, ["/w/a.py", "/w/b.py"], "改动的文件（没被同意的不算）")
    eq(int(files.first, "added"), 2, "实时事件带 diff：新增行数")
    eq(int(files.first, "removed"), 1, "删除行数")

    let p2 = CodexAppParser(turn: TurnBuilder())
    p2.notify("error", json(#"{"error":{"message":"{\"error\":{\"message\":\"额度用完了\",\"code\":\"rate_limit\"}}"},"willRetry":false}"#))
    p2.notify("turn/completed", json(#"{"turn":{"id":"t","status":"failed","error":{"message":"普通报错"}}}"#))
    eq(p2.errors, ["额度用完了（rate_limit）", "普通报错"], "出错信息")
    eq(p2.status ?? "", "failed", "失败的回合")
    eq(unwrapShell("ls -la"), "ls -la", "没包 shell 的命令原样")
}

private func testAcp() {
    print("· Gemini ACP 通知（交互式）")
    let t = TurnBuilder()
    let p = AcpParser(turn: t)
    var commands: [[String: String]] = []
    p.onCommands = { commands = $0 }
    [
        #"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"compact","description":"压缩上下文"},{"name":"goal","description":"一直做到目标完成"}]}"#,
        #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"提问"}}"#,
        #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"先想"}}"#,
        #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"一下"}}"#,
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"我先看看文件。"}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"c1","name":"view_file","args":{"AbsolutePath":"/w/a.py"},"status":"in_progress"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"c1","name":"view_file","args":{"AbsolutePath":"/w/a.py"},"status":"completed"}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"c2","name":"replace_file_content","args":{"TargetFile":"/w/a.py","TargetContent":"x","ReplacementContent":"y"},"status":"pending"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"c2","name":"replace_file_content","args":{"TargetFile":"/w/a.py","TargetContent":"x","ReplacementContent":"y"},"status":"completed"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"c2","name":"replace_file_content","args":{"TargetFile":"/w/a.py","TargetContent":"x","ReplacementContent":"y"},"status":"completed"}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"c3","name":"run_command","args":{"CommandLine":"false"},"status":"in_progress"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"c3","name":"run_command","args":{"CommandLine":"false"},"status":"failed","content":[{"type":"content","content":{"type":"text","text":"退出码 1"}}]}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"c4","name":"mcp_aipethub-browser_browser_open","args":{"url":"http://localhost:3000"},"status":"completed"}"#,
        #"{"sessionUpdate":"plan","entries":[{"content":"甲","status":"completed"},{"content":"乙","status":"pending"}]}"#,
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"改"}}"#,
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"好了。"}}"#,
    ].forEach { p.update(json($0)) }
    p.finish(stopReason: "end_turn")
    eq(commands.map { $0["name"] ?? "" }, ["compact", "goal"], "它认得的斜杠命令")
    eq(t.steps.map { str($0, "kind") }, ["think", "text", "read", "edit", "command", "tool", "todo", "text"], "步骤种类和顺序")
    eq(str(t.steps.first, "detail"), "先想一下", "思考内容拼起来")
    eq(str(t.steps[1], "detail"), "我先看看文件。", "工具之前的那段说明单独一步")
    eq(str(t.step("acp-c1"), "status"), "ok", "读文件完成")
    eq(str(t.step("acp-c3"), "status"), "error", "命令失败")
    eq(str(t.step("acp-c3"), "output"), "退出码 1", "失败原因")
    eq(str(t.step("acp-c4"), "title"), "调用 mcp_aipethub-browser_browser_open", "外接工具直接显示名字，不按字眼猜成「读取网页」")
    eq(str(t.step("acp-plan"), "detail"), "☑ 甲\n☐ 乙", "计划")
    eq(p.response, "改好了。", "最后一段文字是回答")
    eq(str(t.steps.last, "status"), "ok", "写完后不再转圈")
    eq(p.stopReason ?? "", "end_turn", "结束原因")
    let out = t.finish(finalText: p.response)
    let files = out["files"] as? [[String: Any]] ?? []
    eq(files.count, 1, "改动的文件")
    eq(int(files.first, "added"), 1, "completed 来两次，改动只记一次")
    eq(str(out, "text"), "改好了。", "正文")
}

private func testClaudeHistory() {
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
    let steps = messages.last?["steps"] as? [[String: Any]] ?? []
    eq(steps.map { str($0, "kind") }, ["command", "user"], "补充的话是这一轮工作过程里的一步")
    eq(str(steps.last, "detail"), "顺便看看 lint", "补充的内容")
    eq(str(messages.last, "text"), "测试和 lint 都过了。", "回答")

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

private func testDsh() {
    print("· DeepSeek（dsh）会话事件")
    // tools/fixtures/dsh-turn.jsonl：从 dsh 0.1.0-rc.7 的事件流里录下来的一轮（思考 → bash → 读文件 → 改文件 → 回答）
    guard let raw = try? String(contentsOfFile: "tools/fixtures/dsh-turn.jsonl", encoding: .utf8) else { eq("没找到", "tools/fixtures/dsh-turn.jsonl", "样例文件"); return }
    let rows = raw.split(separator: "\n").compactMap { json(String($0)) as [String: Any]? }
    // 回答进行中：逐条喂
    let t = TurnBuilder()
    let p = DshParser(turn: t)
    for r in rows where (r["event"] as? [String: Any])?["type"] as? String != "user/message" {
        p.feed(r["event"] as? [String: Any] ?? [:], view: r["view"] as? [String: Any])
    }
    eq(p.ended?.kind ?? "", "completed", "这一轮正常结束")
    eq(p.started, true, "看到了这一轮开始")
    let built = t.finish(finalText: p.response)
    let steps = built["steps"] as? [[String: Any]] ?? []
    eq(steps.map { str($0, "kind") }, ["think", "command", "think", "read", "edit"], "步骤种类和顺序（最后一段正文是回答，不留在步骤里）")
    eq(str(steps[1], "detail"), "echo hi > a.txt", "命令")
    eq(str(steps[1], "title"), "Write hi to a.txt", "命令的说明当标题")
    eq(str(steps[3], "path"), "/tmp/w/a.txt", "读的是哪个文件")
    eq(steps.map { str($0, "status") }, ["ok", "ok", "ok", "ok", "ok"], "都做完了")
    eq((built["text"] as? String ?? "").hasPrefix("已完成"), true, "正式回答")
    let files = built["files"] as? [[String: Any]] ?? []
    eq(files.map { str($0, "path") }, ["/tmp/w/a.txt"], "改动的文件")
    eq(str(files.first, "diff").contains("-hi") && str(files.first, "diff").contains("+ho"), true, "改了哪里")
    // 读历史：同一批事件拼成一问一答
    let turns = dshTurns(rows)
    eq(turns.map { str($0, "role") }, ["user", "bot"], "一问一答")
    eq(str(turns.first, "text").hasPrefix("用 bash 执行"), true, "提问")
    eq(((turns.last?["steps"] as? [[String: Any]]) ?? []).count, 5, "历史里的步骤和进行中看到的一样")
    eq((turns.last?["duration"] as? Double ?? 0) > 1, true, "这一轮花了多久")
    // 没有流式增量（只有定稿的消息）也能拼出思考和回答
    let noChunks = rows.filter { (($0["event"] as? [String: Any])?["type"] as? String) != "assistant/chunk" }
    let plain = dshTurns(noChunks)
    eq(((plain.last?["steps"] as? [[String: Any]]) ?? []).map { str($0, "kind") }, ["think", "command", "think", "read", "edit"], "没有增量时从定稿的消息里补")
    eq(str(plain.last, "text").hasPrefix("已完成"), true, "回答一样")
    // 回答中途补充的话：读历史时算在那一轮里，不另起一轮
    var steered = rows
    steered.insert(json(#"{"event":{"type":"user/message","seq":120,"time":1794398191000,"data":{"content":[{"type":"text","text":"顺便看看 lint"}],"source":{"kind":"user","rpcId":"aph-steer-s1"},"role":"user"}}}"#), at: rows.count / 2)
    let st = dshTurns(steered)
    eq(st.map { str($0, "role") }, ["user", "bot"], "补充的话不拆成另一轮")
    eq(((st.last?["steps"] as? [[String: Any]]) ?? []).contains { str($0, "kind") == "user" && str($0, "detail") == "顺便看看 lint" }, true, "补充的话是这一轮里的一步")
    // 出错
    let bad = DshParser(turn: TurnBuilder())
    bad.feed(json(#"{"type":"turn/end","seq":15,"data":{"turn":1,"reason":{"kind":"error","error":{"message":"Authentication Fails","code":"AUTH","status":401}}}}"#))
    eq(bad.ended?.kind ?? "", "error", "出错的一轮")
    eq(dshReadableError(bad.ended?.message ?? "", code: bad.ended?.code ?? "").contains("密钥"), true, "密钥不对时说人话")
    eq(str(dshToolStep(name: "web_search", args: ["query": "天气"], view: [:]), "kind"), "web", "联网搜索")
    eq(str(dshToolStep(name: "mystery", args: [:], view: ["card": "terminal", "title": "ls"]), "kind"), "command", "名字不认识时看卡片种类")
}

private func testLineSplitter() {
    print("· 按行切分子进程输出")
    let s = LineSplitter()
    var lines = s.feed(Data("{\"a\":1}\n{\"b\"".utf8))
    eq(lines, ["{\"a\":1}"], "半行先留着")
    lines = s.feed(Data(":2}\n".utf8))
    eq(lines, ["{\"b\":2}"], "下一块到了拼成整行")
    // 一个汉字的 UTF-8 字节被切在两块里，不能变成乱码
    let bytes = Array("好\n".utf8)
    lines = s.feed(Data(bytes[0..<2])) + s.feed(Data(bytes[2...]))
    eq(lines, ["好"], "多字节字符跨块")
    _ = s.feed(Data("尾巴".utf8))
    eq(s.flush() ?? "", "尾巴", "结束时把没有换行的最后一行交出来")
}

/// 主动压缩上下文（/compact）：各家的结果怎么变成这一轮的回答；Gemini 报的上下文用量。
private func testCompact() {
    print("· 压缩上下文")
    let t = TurnBuilder()
    let p = ClaudeStreamParser(turn: t)
    p.feed(json(#"{"type":"system","subtype":"status","status":"compacting","session_id":"s1"}"#))
    eq(str(t.steps.first, "title"), "压缩上下文", "Claude：正在压缩是一步")
    eq(str(t.steps.first, "status"), "running", "Claude：这一步在转")
    p.feed(json(#"{"type":"system","subtype":"status","status":null,"compact_result":"success","session_id":"s1"}"#))
    eq(str(t.steps.first, "status"), "ok", "Claude：压完了这一步是好的")
    eq(p.compactNote ?? "", "前面的对话已经压缩成摘要，腾出了上下文空间。", "Claude：压完了的那句话")
    eq(t.steps.count, 1, "Claude：只有一步")
    let t2 = TurnBuilder()
    let p2 = ClaudeStreamParser(turn: t2)
    p2.feed(json(#"{"type":"system","subtype":"status","status":"compacting"}"#))
    p2.feed(json(#"{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"Not enough messages to compact."}"#))
    eq(str(t2.steps.first, "status"), "error", "Claude：没压成这一步是失败的")
    eq(p2.compactNote ?? "", "没有压缩：对话还太短，没有可以压缩的内容。", "Claude：对话太短的那句话")
    eq(dshCompactReply("No compactable history yet."), "还没有可以压缩的历史：对话还太短。", "dsh：没有可压缩的")
    eq(dshCompactReply(["text": "Compaction could not produce a useful summary. The conversation is unchanged; the attempt is recorded in the session log."]).hasPrefix("没有压缩"), true, "dsh：摘要没用不算出错")
    eq(dshCompactReply(["result": ["message": "Compacted 12 items (~3400 tokens)."]]), "前面的对话已经压缩成摘要，腾出了上下文空间。\n\nCompacted 12 items (~3400 tokens).", "dsh：压完了，原话附在后面")
    eq(dshCompactReply(nil), "前面的对话已经压缩成摘要，腾出了上下文空间。", "dsh：没有答复文字")
    let a = AcpParser(turn: TurnBuilder())
    var got = [0, 0]
    a.onUsage = { got = [$0, $1] }
    a.update(json(#"{"sessionUpdate":"usage_update","used":5300,"size":1000000}"#))
    eq(got, [5300, 1000000], "Gemini：usage_update 报出已用和总量")
}

func runParserTests() -> Never {
    testHelpers()
    testTurnBuilder()
    testClaude()
    testCodex()
    testAgy()
    testClaudeHistory()
    testCodexApp()
    testAcp()
    testDsh()
    testCompact()
    testLineSplitter()
    print(failures == 0 ? "全部通过（\(checks) 项）" : "\(failures) / \(checks) 项没通过")
    exit(failures == 0 ? 0 : 1)
}
