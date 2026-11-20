// 各家 CLI 的事件流、TurnBuilder 与行切分（畸形和随机输入在 event-parsers-fuzz.swift）；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testHelpers() {
    let lookup = AppDelegate()
    lookup.pathLookupCache["ls"] = ("/不存在的旧目录/ls", Date())
    lookup.hooks.jsSink = { _, _ in }
    lookup.pathLookupCache["cat"] = (nil, Date())
    _ = lookup.handleAppAction("probeAgents", ["agents":[String](), "refresh":true])
    check(lookup.lookupOnPath("cat") != nil, "手动重检应清掉未安装缓存")
    let found = lookup.lookupOnPath("ls")
    check(found.map { FileManager.default.isExecutableFile(atPath: $0) } == true, "B4-16 失效路径重新查找，实际 \(found ?? "无")")
    // 这一轮的结局要交给网页，它据此显示「重试」：Claude 中途崩了、正文只有半句时，只靠正文开头的 ⚠️ 猜不出来（astra 报告）
    eq(responseOutcome(agent: "claude", turn: ["outcome": "failed"]) as? String, "failed", "Claude 的失败结局交给网页")
    eq(responseOutcome(agent: "gpt", turn: ["outcome": "interrupted"]) as? String, "interrupted", "Codex 的结局照旧交给网页")
    // 粘贴：访达里复制的文件从剪贴板取路径（Bridge / AppViews 的 ⌘V）；只有文字或图片数据时不当文件
    let board = NSPasteboard(name: NSPasteboard.Name("aipethub-test-\(UUID().uuidString)"))
    board.clearContents(); board.writeObjects([URL(fileURLWithPath: "/tmp/资料 包.zip") as NSURL, URL(fileURLWithPath: "/tmp/b.txt") as NSURL])
    eq(pastedFilePaths(board), ["/tmp/资料 包.zip", "/tmp/b.txt"], "粘贴访达复制的文件取到路径")
    board.clearContents(); board.setString("只是一段文字", forType: .string)
    eq(pastedFilePaths(board), [], "剪贴板只有文字时不当文件")
    board.releaseGlobally()
    let paste = AppDelegate()
    var pasteError = ""
    paste.hooks.pastedImageDirectory = "/dev/null/不能建立目录"
    paste.hooks.jsSink = { name, value in if name == "onFilesDropped" { pasteError = str(value,"error") } }
    paste.savePastedImage("data:image/png;base64,YQ==")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    paste.hooks.pastedImageDirectory = temporary.path
    var screenshot = ""
    paste.hooks.jsSink = { _, value in screenshot = (value["paths"] as? [String])?.first ?? "" }
    paste.savePastedImage("data:image/png;base64,YQ==")
    _ = paste.handleAppAction("discardPastedImage", ["path":screenshot])
    check(!screenshot.isEmpty && !FileManager.default.fileExists(atPath:screenshot), "B4-18 移除草稿后截图不留在目录中，实际存在 \(FileManager.default.fileExists(atPath:screenshot))")
    check(!pasteError.isEmpty, "B4-17 不能建立截图目录时返回文件系统原因，实际 \(pasteError)")
    print("· 工具函数")
    eq(lineCount(""), 0, "空串行数")
    eq(lineCount("a\nb"), 2, "两行")
    eq(lineCount("a\nb\n"), 2, "末尾换行不多算一行")
    let d = simpleDiff(old: "x\ny", new: "z")
    eq(d, "@@\n-x\n-y\n+z", "simpleDiff")
    let c = diffCounts("--- a\n+++ b\n@@\n-x\n-y\n+z\n 上下文")
    eq(c.added, 1, "diff 新增行数（不算 +++ 文件头）")
    eq(c.removed, 2, "diff 删除行数（不算 --- 文件头）")
    let markdown = diffCounts("--- a/x\r\n+++ b/x\r\n@@ -1,2 +1,2 @@\r\n----\r\n-old\r\n++++\r\n+new\r\n")
    eq([markdown.added,markdown.removed], [2,2], "B3-19 CRLF 补丁的 Markdown 分隔线仍算正文")
    eq(lineCount("a\r\nb\r\n"), 2, "B3-19 CRLF 两行")
    eq(diffCounts(simpleDiff(old:"a\r\nb\r\n", new:"c\r\nd\r\n")).added, 2, "B3-19 CRLF 替换不多算最后一行")
    eq(clip("abcdef", 3), "abc…", "clip")
    eq(codexChangeKind("add"), "create", "Codex 改动类型：字符串")
    eq(codexChangeKind(["type": "delete"]), "delete", "Codex 改动类型：历史记录里的对象")
    eq(codexChangeKind(nil), "edit", "Codex 改动类型：缺省")
}

func testTurnBuilder() {
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
    eq(str((out2["steps"] as? [[String: Any]])?.first, "status"), "running", "没有工具结果的步骤不能当成成功")
}

func testClaude() {
    print("· Claude Code 流式事件")
    let capped = TurnBuilder(), cp = ClaudeStreamParser(turn: capped)
    cp.feed(json(#"{"type":"result","subtype":"success","is_error":false,"stop_reason":"max_tokens","result":"已有正文"}"#))
    let req = AskRequest(agent:"claude", reqId:1, prompt:"test", model:"", effort:"", permissionMode:"", workspace:"", conversationId:"")
    let failed = TurnBuilder(), fp = ClaudeStreamParser(turn: failed)
    fp.feed(json(#"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["第一处错误","第二处错误"]}"#))
    let errorReply = AppDelegate().claudeReply(req, res: CLIResult(out:"", err:"", status:1, cancelled:false), parser:fp, turn:failed)
    check(errorReply.reply.contains("第一处错误") && errorReply.reply.contains("第二处错误"), "B3-12 显示 Claude 所有错误明细，实际=\(errorReply.reply)")
    let r = AppDelegate().claudeReply(req, res: CLIResult(out:"", err:"", status:0, cancelled:false), parser:cp, turn:capped)
    eq(r.reply, "已有正文", "B5 Claude 输出上限保留正文")
    eq(str(r.turn, "outcome"), "failed", "B5 Claude 最终停止原因优先于 success")
    check(str((r.turn?["steps"] as? [[String: Any]])?.last, "detail").contains("输出上限"), "B5 Claude 结束步骤说明上限")
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

func testCodex() {
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

func testAgy() {
    print("· Gemini（agy）stream-json 事件")
    let t = TurnBuilder()
    let p = AgyStreamParser(turn: t)
    [
        #"{"event":"init","conversation_id":"conv-1"}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conv-1","step_index":1,"step_type":"tool","state":"RUNNING","tool_name":"view_file","tool_info":{"parameters":{"AbsolutePath":"file:///w/a.py"}}}}"#,
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

func testCodexApp() {
    print("· Codex app-server 通知（交互式）")
    let t = TurnBuilder()
    let limited = CodexAppParser(turn: TurnBuilder())
    limited.notify("turn/completed", json(#"{"turn":{"status":"failed","error":{"message":"Incomplete response returned, reason: max_output_tokens"}}}"#))
    eq(limited.status, "failed", "B5 Codex 输出上限仍按失败收尾")
    check(limited.errors.last?.contains("输出上限") == true, "B5 Codex 明确显示输出上限")
    let app = AppDelegate(), input = LiveInput()
    let req = AskRequest(agent: "gpt", reqId: 1, prompt: "继续", model: "model", effort: "low",
                         permissionMode: "default", workspace: "", conversationId: "thread", browserTools: false)
    app.codexOpenThread(req, input, model: req.model, effort: req.effort, sandbox: "read-only")
    input.close()
    let request = app.jsonObject(String(decoding: input.pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    eq((request?["params"] as? [String: Any])?["excludeTurns"] as? Bool, true, "B4 续问不回传历史回合")
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

func testAcp() {
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

func testDsh() {
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
    let manual: [String: Any] = ["type":"compaction/end", "data":["turn":NSNull(), "compactionId":"manual"]]
    let failed: [String: Any] = ["type":"compaction/end", "data":["turn":NSNull(), "error":"failed"]]
    eq(dshTurns(rows + [["event":failed], ["event":manual]]).map { str($0, "role") }, ["user","bot","compact"], "B4-2 手动压缩只保留成功提示")
    let autoBuilder = TurnBuilder(), compactID = "auto"
    let auto = DshParser(turn: autoBuilder)
    for (type, fields) in [("start", ["turn": 1] as [String:Any]), ("summary", ["summary":"压缩后的摘要"]), ("end", ["turn":1])] {
        auto.feed(["type":"compaction/" + type, "data":fields.merging(["compactionId":compactID]) { a, _ in a }])
        eq(str(autoBuilder.steps.last, "status"), type == "end" ? "ok" : "running", "B4-3 自动压缩阶段 " + type)
    }
    eq(autoBuilder.steps.map { str($0, "detail") }, ["压缩后的摘要"], "B4-3 三个事件合为一步")
    let myRpc = "aph-ask-工具"
    let ownRows: [[String:Any]] = [
        ["event":["type":"user/message","time":23150,"data":["source":["kind":"user","rpcId":myRpc],"content":[["type":"text","text":"提问"]]]]],
        ["event":["type":"assistant/message","data":["message":["content":[["type":"text","text":"工具前说明"]]]]]],
        ["event":["type":"turn/end","data":["reason":["kind":"aborted"]]]]
    ]
    eq(dshTurns(ownRows).first?["createdAt"] as? Double, 23.15, "首次对账使用 DeepSeek 提问事件的秒时间")
    eq(str(dshTurns(ownRows).first, "turnKey"), myRpc, "同步认领 DeepSeek 原提问调用编号")
    let crash = dshTurns(ownRows,endings:[["rpc":myRpc,"text":"工具后正文","reason":"服务退出"]]).last
    eq(str(crash,"text"),"工具后正文","DeepSeek 工具前说明不能顶替同一调用的末段")
    // 上一轮缺结束事件：下一轮的 turn/start 先收好上一轮，结局不丢，两问之间的空闲也不算工作时长。
    func framed(_ turn: Int, _ type: String, _ time: Double, _ data: [String:Any] = [:]) -> [String:Any] {
        ["event":["type":type, "time":time, "data":data.merging(["turn":turn]) { a, _ in a }]]
    }
    func asked(_ i: Int, _ time: Double) -> [String:Any] {
        framed(i, "user/message", time, ["source":["kind":"user","rpcId":"q\(i)"], "content":[["type":"text","text":"问\(i)"]]])
    }
    func answered(_ i: Int, _ time: Double) -> [String:Any] {
        framed(i, "assistant/message", time, ["message":["content":[["type":"text","text":"答\(i)"]]]])
    }
    let later = [framed(2,"turn/start",3_601_000), asked(2,3_601_000), answered(2,3_602_000), framed(2,"turn/end",3_603_000,["reason":["kind":"completed"]])]
    for hasText in [false, true] {
        let earlier = [framed(1,"turn/start",1000), asked(1,1000)] + (hasText ? [answered(1,3000)] : [])
        let ending: [String:Any] = ["rpc":"q1","reqId":71,"text":hasText ? "答1" : "","outcome":"interrupted","start":1.0,"end":3.0]
        let alone = dshTurns(earlier, endings:[ending]), continued = dshTurns(earlier + later, endings:[ending])
        eq(continued.map { str($0,"role") }, ["user","bot","user","bot"], "DeepSeek 上一轮缺结束事件（正文=\(hasText)）再问一句仍各成一轮")
        eq(continued.prefix(2).map { "\(str($0,"text"))|\(str($0,"outcome"))|\($0["duration"] as? Double ?? 0)" },
           alone.map { "\(str($0,"text"))|\(str($0,"outcome"))|\($0["duration"] as? Double ?? 0)" },
           "DeepSeek 上一轮缺结束事件（正文=\(hasText)）再问一句不改变上一轮的结局和时长")
    }
    let titled = dshTurns(rows + [["event":["type":"session/title", "time":1999999999000]]])
    eq(titled.last?["duration"] as? Double, dshTurns(rows).last?["duration"] as? Double, "B4-7 DeepSeek 标题不延长工作时长")
    for (receipt, expected) in [("tool call aborted before dispatch","interrupted"),("permission denied","error")] {
        let stoppedJSON = raw.replacingOccurrences(of:"(no output)",with:receipt)
            .replacingOccurrences(of:"\"isError\":false",with:"\"isError\":true")
            .replacingOccurrences(of:"\"kind\":\"completed\"",with:"\"kind\":\"aborted\"")
        let stoppedRows = stoppedJSON.split(separator:"\n").compactMap { json(String($0)) as [String:Any]? }
        let steps = dshTurns(stoppedRows).last?["steps"] as? [[String:Any]]
        eq(str(steps?.first { str($0,"kind") == "command" },"status"),expected,"DeepSeek 重开用户取消的命令并保留真实失败")
    }
    // 真实 dsh 停止运行中的命令：回执文字是 Error: tool call aborted，isError 为真，同时带结构化的 ABORTED。
    // 同轮读文件的真实失败、改文件的成功要各自保留。
    let abortedJSON = raw.replacingOccurrences(of: #"{"type":"text","text":"(no output)"}],"isError":false}],"role":"user","id":"79a04147-b39c-48a4-983e-528d23b3f83e"}"#,
                                               with: #"{"type":"text","text":"Error: tool call aborted"}],"isError":true}],"role":"user","id":"79a04147-b39c-48a4-983e-528d23b3f83e"},"error":{"name":"AbortError","code":"ABORTED"}"#)
        .replacingOccurrences(of: #""view":{"card":"terminal","output":"(no output)","exitCode":0}"#, with: #""view":{"card":"terminal"}"#)
        .replacingOccurrences(of: #"(End of file - total 1 lines)\n</content>"}],"isError":false"#, with: #"permission denied"}],"isError":true"#)
        .replacingOccurrences(of: "\"kind\":\"completed\"", with: "\"kind\":\"aborted\"")
    check(abortedJSON.contains("ABORTED") && abortedJSON.contains("permission denied"), "DeepSeek ABORTED 夹具替换生效")
    let abortedSteps = (dshTurns(abortedJSON.split(separator: "\n").compactMap { json(String($0)) as [String: Any]? }).last?["steps"] as? [[String: Any]] ?? [])
        .filter { ["command", "read", "edit"].contains(str($0, "kind")) }
    eq(abortedSteps.map { "\(str($0, "kind")):\(str($0, "status"))" }, ["command:interrupted", "read:error", "edit:ok"],
       "DeepSeek 重开被停止的命令（结构化 ABORTED）仍是中断，同轮其他步骤保留各自结果")
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
    // 带图片的提问：dsh 只在事件里记附件编号，图片本身在附件目录；重开历史要有缩略图、能点开原图
    let fm = FileManager.default
    let attachRoot = NSTemporaryDirectory() + "aipethub-dsh-attachments-" + UUID().uuidString
    defer { try? fm.removeItem(atPath: attachRoot); TestHooks.dshAttachmentRoot = nil }
    TestHooks.dshAttachmentRoot = attachRoot
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let sha = String(repeating: "ab", count: 32)
    try! fm.createDirectory(atPath: "\(attachRoot)/objects/ab", withIntermediateDirectories: true)
    try! png.write(to: URL(fileURLWithPath: "\(attachRoot)/objects/ab/\(sha)"))
    let imageBlock: [String: Any] = ["type": "image", "attachment": ["attachmentId": "sha256:\(sha)", "mediaType": "image/png", "bytes": png.count, "width": 1, "height": 1]]
    func dshUser(_ content: [[String: Any]], rpc: String? = nil) -> [String: Any] {
        var source: [String: Any] = ["kind": "user"]
        source["rpcId"] = rpc
        return ["event": ["type": "user/message", "seq": 1, "time": 1794398190000, "data": ["role": "user", "source": source, "content": content]]]
    }
    let steerRpc = dshSteerPrefix + "next"
    let nextRows = rows + [["event":["type":"turn/start","data":["turn":2]]],
                           dshUser([["type":"text","text":"补充要求"]],rpc:steerRpc)]
    let nextTurns = dshTurns(nextRows,endings:[["rpc":steerRpc,"text":"补充后的半段","outcome":"failed"]])
    eq([str(nextTurns.last,"text"),str(nextTurns.last,"outcome")],["补充后的半段","failed"],"DeepSeek 新轮接收补充时补回对应崩溃正文")
    let tick = Date()
    TestHooks.dshPushNow = { tick }
    for reason in ["aborted","interrupted"] {
        var events = [dshUser([["type":"text","text":"数数"]])]
        for text in ["一","二"] {
            events.append(["event":["type":"assistant/chunk","data":["chunk":["type":"text-delta","text":text]]]])
        }
        events.append(["event":["type":"turn/end","data":["reason":["kind":reason]]]])
        let bot = dshTurns(events).last
        eq(str(bot,"text"), "一二", "B2-10 \(reason) 节流窗口内最后一段正文保留")
        eq(str(bot,"outcome"), "interrupted", "B2-10 \(reason) 可重试")
    }
    TestHooks.dshPushNow = nil
    var pictured = rows.filter { (($0["event"] as? [String: Any])?["type"] as? String) != "user/message" }
    pictured.insert(dshUser([imageBlock, ["type": "text", "text": "请看这张图片。"]]), at: 0)
    pictured.insert(dshUser([imageBlock], rpc: "aph-steer-s2"), at: pictured.count / 2)
    var withImages = dshTurns(pictured)
    eq(withImages.map { str($0, "role") }, ["user", "bot"], "DS01 带图片的提问仍是一问一答")
    eq(str(withImages.first, "text"), "请看这张图片。", "DS01 图片块不混进提问文字")
    eq((withImages.first?["imageSources"] as? [[String: Any]])?.compactMap { $0["ref"] as? String }, ["sha256:\(sha)"], "DS01 提问带上图片来源（附件编号）")
    let dsAsked = AppDelegate()
    dsAsked.hooks.jsSink = { _, _ in }
    dsAsked.attachChatImages(&withImages, payload: ["agent": "deepseek", "conversationId": "session-fixture", "cwd": "/tmp"])
    let dsThumb = (withImages.first?["images"] as? [[String: Any]])?.first
    check((dsThumb?["src"] as? String ?? "").hasPrefix("data:image/"), "DS01 重开历史有缩略图")
    check(withImages.first?["imageSources"] == nil, "DS01 原始数据不随消息发到页面")
    let dsSteer = ((withImages.last?["steps"] as? [[String: Any]]) ?? []).first { str($0, "kind") == "user" }
    eq((dsSteer?["images"] as? [[String: Any]])?.count, 1, "DS01 中途补充的纯图也有缩略图")
    let dsFull = dsThumb.flatMap { dsAsked.fullChatImage(["ref": $0["ref"] ?? [:]]) }
    check((dsFull ?? "").hasPrefix("data:image/"), "DS01 点开能看原图")
    // 出错
    let bad = DshParser(turn: TurnBuilder())
    bad.feed(json(#"{"type":"turn/end","seq":15,"data":{"turn":1,"reason":{"kind":"error","error":{"message":"Authentication Fails","code":"AUTH","status":401}}}}"#))
    eq(bad.ended?.kind ?? "", "error", "出错的一轮")
    eq(dshReadableError(bad.ended?.message ?? "", code: bad.ended?.code ?? "").contains("密钥"), true, "密钥不对时说人话")
    // DR1：提问卡的答复换成 dsh 会收的格式（选项标签进 selected，自己写的进 custom，单选不同时带两样）
    let qs: [[String: Any]] = [["id": "m", "question": "多选？", "multiSelect": true, "options": [["label": "甲"], ["label": "乙"]]],
                               ["id": "s", "question": "单选？", "options": [["label": "丙"]]]]
    let same = [["id":"left","question":"选哪个？"], ["id":"right","question":"选哪个？"]]
    let card = dshCard(["type":"question/requested","questions":same])
    eq((card.fields["questions"] as? [[String:Any]])?.map { str($0,"id") }, ["left","right"], "B4-22 DeepSeek 同名题保留原编号")
    eq(dshQuestionAnswers(same, ["answers":["left":"甲","right":"乙"]]).map { str($0,"custom") }, ["甲","乙"], "B4-22 DeepSeek 同名题各自取答案")
    let picked = dshQuestionAnswers(qs, ["decision": "allow", "answers": ["多选？": "甲、乙、别的", "单选？": "自己写的"]])
    eq(picked.map { ($0["selected"] as? [String]) ?? [] }, [["甲", "乙"], []], "DR1 选项标签进 selected")
    eq(picked.map { $0["custom"] as? String ?? "" }, ["别的", "自己写的"], "DR1 自己写的进 custom")
    let separated = dshQuestionAnswers([["id":"m", "multiSelect":true, "options":[["label":"甲、乙"],["label":"丙"]]]],
        ["answers":["m":"甲、乙、丙、手写、补充"], "answerParts":["m":["selected":["甲、乙","丙"], "custom":"手写、补充"]]])
    eq(separated.first?["selected"] as? [String], ["甲、乙","丙"], "R3 DeepSeek 多选保留含顿号的完整选项")
    eq(separated.first?["custom"] as? String, "手写、补充", "R3 DeepSeek 自填不混入选项")
    let skipped = dshQuestionAnswers(qs, ["decision": "deny", "message": "按你的判断"])
    eq(skipped.map { $0["custom"] as? String ?? "" }, ["按你的判断", "按你的判断"], "DR1 不回答时把说明交给模型")
    // DR3：先写出正文、再以输出上限结束的一轮，重开历史要和实时一致：正文留着、结局 failed（有「重试」）、原因在结束步骤
    let capped = dshTurns([dshUser([["type": "text", "text": "写长一点"]]),
                           ["event": ["type": "assistant/message", "data": ["turn": 1, "step": 1, "message": ["content": [["type": "text", "text": "begin OK"]]]]]],
                           ["event": ["type": "turn/end", "data": ["turn": 1, "reason": ["kind": "max-tokens"]]]]])
    eq(str(capped.last, "text"), "begin OK", "DR3 历史里输出到上限的一轮正文留着")
    eq(str(capped.last, "outcome"), "failed", "DR3 历史里输出到上限算 failed，和实时一样给「重试」")
    eq(str((capped.last?["steps"] as? [[String: Any]])?.last, "detail").contains("上限"), true, "DR3 历史的结束步骤写明是输出到上限")
    eq(str(dshToolStep(name: "web_search", args: ["query": "天气"], view: [:]), "kind"), "web", "联网搜索")
    eq(str(dshToolStep(name: "mystery", args: [:], view: ["card": "terminal", "title": "ls"]), "kind"), "command", "名字不认识时看卡片种类")
}

func testLineSplitter() {
    print("· 按行切分子进程输出")
    let s = LineSplitter()
    let chunk = Data(repeating: 97, count: 8192)
    let started = ProcessInfo.processInfo.systemUptime
    for _ in 0..<1024 { _ = s.feed(chunk) }
    let large = s.feed(Data("\n".utf8))
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    print(String(format: "B4 8 MiB 单行分 1024 块读取：%.4f 秒", elapsed))
    check(elapsed < 3, "B4 分块读取大回包不反复扫描前缀")
    eq(large.first?.utf8.count, 8 << 20, "B4 大回包完整读出")
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
func testCompact() {
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
    eq(p.compacted, true, "Claude：压成了，记录里会多一条压缩提示")
    let p3 = ClaudeStreamParser(turn: TurnBuilder())
    p3.feed(json(#"{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual"}}"#))
    eq(p3.compacted, true, "Claude：只报 compact_boundary 的版本也算压成了")
    let t2 = TurnBuilder()
    let p2 = ClaudeStreamParser(turn: t2)
    p2.feed(json(#"{"type":"system","subtype":"status","status":"compacting"}"#))
    p2.feed(json(#"{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"Not enough messages to compact."}"#))
    eq(str(t2.steps.first, "status"), "error", "Claude：没压成这一步是失败的")
    eq(p2.compactNote ?? "", "没有压缩：对话还太短，没有可以压缩的内容。", "Claude：对话太短的那句话")
    eq(p2.compacted, false, "Claude：没压成，记录里没有压缩提示（2026-11-18 claude 2.1.322 实测没有 compact_boundary）")
    // 交给网页的回答里带着它（AskFlow 原样转成 onAgentResponse 的 compacted）
    let app = AppDelegate(), ok = CLIResult(out: "", err: "", status: 0, cancelled: false)
    let compactReq = AskRequest(agent: "claude", reqId: 1, prompt: "/compact", model: "", effort: "low", permissionMode: "default", workspace: "", conversationId: "s1")
    eq(app.claudeReply(compactReq, res: ok, parser: p, turn: t).turn?["compacted"] as? Bool, true, "Claude：压成了的回答带 compacted=true")
    eq(app.claudeReply(compactReq, res: ok, parser: p2, turn: t2).turn?["compacted"] as? Bool, false, "Claude：没压成的回答带 compacted=false")
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

