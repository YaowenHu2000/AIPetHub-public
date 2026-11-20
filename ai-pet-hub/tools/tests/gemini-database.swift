// 反重力桌面版写的会话库和 agy CLI 不完全一样：原话拆成文本块、已结束的步骤留着状态 5、图片附件跟在用户步骤里。
// 夹具全是合成的，形状按 2026-11-18 对本机桌面会话只读副本和一次真实 agy acp 发图的实测。
import Foundation
import SQLite3

func testGeminiDatabaseHistory() {
    print("· Gemini 会话库：桌面版文本块提问、状态 5 的最终结果、图片附件")
    func chunks(_ parts: String...) -> Data { protoField(19, parts.map { protoField(3, protoText(1, $0)) }.reduce(Data(), +)) }
    func answer(_ s: String) -> Data { protoField(20, protoText(1, s)) }
    func tool(_ status: Int) -> Data {
        protoVarint(4 * 8) + protoVarint(status)
            + protoField(5, protoField(4, protoText(2, "write_to_file") + protoText(3, #"{"TargetFile":"/tmp/gd.txt","CodeContent":"new"}"#)))
            + (status == 7 ? protoField(31, protoText(2, "写入被拒绝")) : Data())
    }
    func roles(_ m: [[String: Any]]) -> [String] { m.map { str($0, "role") } }

    // GD1：19.2 为空时原话在重复的 19.3.1 里；每次提问都要切开上一轮。
    let desktopTurns = agyDbTurns([
        (14, chunks("第一问", "\n", "\n", "补一句")), (15, answer("答一")),
        (14, chunks("第二问")), (15, answer("答二")),
        (14, protoField(19, protoText(2, "第三问") + protoField(3, protoText(1, "第三问")))), (15, answer("答三"))
    ], cleanUser: { $0 })
    eq(roles(desktopTurns), ["user", "bot", "user", "bot", "user", "bot"], "GD1 桌面版每次提问各成一轮")
    eq(desktopTurns.filter { str($0, "role") == "user" }.map { str($0, "text") }, ["第一问\n\n补一句", "第二问", "第三问"],
       "GD1 19.2 为空时按序拼回 19.3.1 文本块，19.2 有字时照旧只用它")
    eq(desktopTurns.filter { str($0, "role") == "bot" }.map { str($0, "text") }, ["答一", "答二", "答三"], "GD1 各轮回答不挤在一起")
    let timed = agyDbTurns([(14,protoField(5,protoField(1,protoVarint(8) + protoVarint(1000))) + chunks("继续"))], cleanUser: { $0 })
    eq(timed.first?["turnKey"] as? Double, 1000, "同步沿用 Gemini 用户步骤的创建时间")
    let blank = agyDbTurns([(15, answer("甲")), (14, protoField(19, Data())), (15, answer("乙"))], cleanUser: { $0 })
    eq(blank.map { str($0, "text") }, ["甲", "乙"], "GD1 没有文字的用户步骤也划分轮次")

    // GD2：桌面版把结束了的步骤也记成 5，最终状态要按步骤序号看转写。
    func toolStatus(_ status: Int, final: String?, held: Bool = false) -> String {
        let m = agyDbTurns([(14, chunks("改")), (132, tool(status))], isHeld: { held },
                           finalStatus: { $0 == 1 ? final : nil }, cleanUser: { $0 }).last
        return str((m?["steps"] as? [[String: Any]])?.first { str($0, "kind") == "write" }, "status")
    }
    eq(toolStatus(5, final: "DONE"), "ok", "GD2 状态 5 而转写为 DONE 的步骤是成功")
    eq(toolStatus(5, final: "ERROR"), "error", "GD2 转写为 ERROR 的仍是失败")
    eq(toolStatus(5, final: nil), "error", "GD2 读不到转写时保持原来的判断（没人持库就是失败）")
    eq(toolStatus(5, final: "RUNNING", held: true), "running", "GD2 转写也没结束时保持原来的判断")
    eq(toolStatus(7, final: "DONE"), "error", "GD2 只有状态 5 才看转写，库里明确的 ERROR 保留")

    let fm = FileManager.default, app = AppDelegate()
    let root = NSTemporaryDirectory() + "aipethub-gd-" + UUID().uuidString
    app.hooks.sentImagesDir = root + "/aipethub-sent-images/"
    app.hooks.geminiCliDir = root + "/antigravity-cli"
    defer { try? fm.removeItem(atPath: root) }
    func store(_ cid: String, _ steps: [(Int, Data)], transcript: [[String: Any]]? = nil) {
        let db = app.geminiConversationDb(cid)
        try! fm.createDirectory(atPath: (db as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! Data().write(to: URL(fileURLWithPath: db))   // withSQLite 只打开已有文件
        let values = steps.enumerated().map { i, s in "(\(i),\(s.0),X'\(s.1.map { String(format: "%02x", $0) }.joined())')" }
        _ = app.withSQLite(db, readOnly: false) { h in
            sqlite3_exec(h, "CREATE TABLE steps(idx INTEGER, step_type INTEGER, step_payload BLOB); INSERT INTO steps VALUES \(values.joined(separator: ","));", nil, nil, nil)
        }
        guard let transcript else { return }
        let logs = "\(app.geminiStore(cid).brain)/\(geminiRawId(cid))/.system_generated/logs"
        try! fm.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let lines = transcript.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try! (lines.joined(separator: "\n") + "\n").write(toFile: logs + "/transcript_full.jsonl", atomically: true, encoding: .utf8)
    }
    let cli = root + "/fixture"
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    try! installFakeCLI(at: cli, behavior: "backend")
    app.hooks.cliExecutable = cli
    let cid = "fixture-session"
    let changes = [("edit_file", ".gitignore", ["Target":"old", "Replacement":"new\nextra"]),
                   ("write_file", "licensed_tools/README.md", ["Content":"a\nb\n"]),
                   ("write_file", "Makefile", ["Content":"all:\n\techo ok\n"])]
    let cardId = "desktop:fixture-file-changes"
    let live = TurnBuilder(), parser = AcpParser(turn:live)
    var cardSteps = [(14, chunks("改文件"))]
    for (name, path, args) in changes {
        let params = args.merging(["Path":root + "/" + path]) { _, new in new }
        parser.update(["sessionUpdate":"tool_call", "toolCallId":path, "name":name, "rawInput":params, "status":"completed"])
        let json = String(decoding:try! JSONSerialization.data(withJSONObject:params), as:UTF8.self)
        cardSteps.append((132, protoVarint(32) + protoVarint(3) + protoField(5, protoField(4, protoText(2,name) + protoText(3,json)))))
    }
    store(cardId,cardSteps + [(15,answer("完成"))])
    let reopened = AppDelegate(); reopened.hooks.geminiCliDir = app.hooks.geminiCliDir
    for (stage, turn) in [("实时",live.finish(finalText:"完成")), ("切回",(app.readGeminiConversation(cid:cardId)["messages"] as? [[String:Any]])?.last ?? [:]),
                          ("重开",(reopened.readGeminiConversation(cid:cardId)["messages"] as? [[String:Any]])?.last ?? [:])] {
        eq((turn["files"] as? [[String:Any]])?.map { "\($0["added"] ?? "?")/\($0["removed"] ?? "?")" }, ["2/1","2/0","2/0"], "Gemini \(stage)读出 edit_file/write_file 的行数")
    }
    let hunk = [(3,"上下文"),(2,"旧"),(1,"新")].map { protoField(3,protoText(1,$0.1) + protoVarint(16) + protoVarint($0.0)) }.reduce(Data(),+)
    let edit = protoText(2,root + "/.gitignore") + protoField(3,protoField(3,hunk))
    let typed = protoText(1,"type.googleapis.com/exa.cortex.core.tools.FileEdit") + protoField(2,edit)
    let recorded = agyDbTurns([cardSteps[0], (132,cardSteps[1].1 + protoField(140,protoField(2,protoField(6,typed))))],cleanUser:{ $0 })
    eq((recorded.last?["files"] as? [[String:Any]])?.first?["diff"] as? String,"@@ -1,2 +1,2 @@\n 上下文\n-旧\n+新","桌面实际补丁优先于请求参数，未改的行不算增删")
    // 桌面版的补丁把整份文件当上下文（2026-11-19 本机 754 条 FileEdit 都是一个从第 1 行起的整份文件 hunk）：
    // 行数照补丁全量数，diff 只留改动前后 3 行；大文件改在后部、同一轮又改了一次，改动行也都看得到。
    func fileEdit(_ lines: [(Int, String)], call: Data) -> Data {
        let hunk = lines.map { protoField(3, protoText(1, $0.1) + protoVarint(16) + protoVarint($0.0)) }.reduce(Data(), +)
        let typed = protoText(1, "type.googleapis.com/exa.cortex.core.tools.FileEdit") + protoField(2, protoText(2, root + "/.gitignore") + protoField(3, protoField(3, hunk)))
        return call + protoField(140, protoField(2, protoField(6, typed)))
    }
    let pad = String(repeating: "内容", count: 30)   // 一千多行、六万字以上：修复前整份文件做上下文会截到看不见后部的改动
    var whole = (1...1200).map { (3, "第\($0)行" + pad) }
    whole[1099...1099] = [(2, "第1100行" + pad), (1, "改1100行"), (1, "加一行")]
    whole[49] = (1, "改50行")
    whole.insert((2, "第50行" + pad), at: 49)
    var again = whole.filter { $0.0 != 2 }.map { (3, $0.1) }
    again[1150...1150] = [(2, again[1150].1), (1, "又改一行")]
    let bigFile = (agyDbTurns([cardSteps[0], (132, fileEdit(whole, call: cardSteps[1].1)), (132, fileEdit(again, call: cardSteps[1].1))], cleanUser: { $0 }).last?["files"] as? [[String: Any]])?.first
    eq("\(bigFile?["added"] ?? "?")/\(bigFile?["removed"] ?? "?")", "4/3", "桌面整份文件的补丁照全量数增删行")
    eq(bigFile?["truncated"] as? Bool, nil, "桌面整份文件的补丁只留改动附近，不会截断")
    let context = { (from: Int, to: Int) in (from...to).map { " 第\($0)行" + pad } }
    let firstEdit = ["@@ -47,7 +47,7 @@"] + context(47, 49) + ["-第50行" + pad, "+改50行"] + context(51, 53)
        + ["@@ -1097,7 +1097,8 @@"] + context(1097, 1099) + ["-第1100行" + pad, "+改1100行", "+加一行"] + context(1101, 1103)
    let secondEdit = ["@@ -1148,7 +1148,7 @@"] + context(1147, 1149) + ["-第1150行" + pad, "+又改一行"] + context(1151, 1153)
    eq(bigFile?["diff"] as? String, (firstEdit + secondEdit).joined(separator: "\n"), "桌面整份文件的补丁按 @@ 分段，只带改动前后 3 行上下文")
    // 实时只有 Target/Replacement（agy 的工具说明要求 Target 在文件里唯一，常带着没改的行），重开读到的是实际补丁：
    // 两边的增删行数要一样，实时也不能退回 +0 −0。
    do {
        let excerptCid = "desktop:fixture-excerpt"
        let params: [String: Any] = ["Path": root + "/.gitignore", "Target": "上一行\n旧\n下一行", "Replacement": "上一行\n新\n加的\n下一行"]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let call = protoVarint(32) + protoVarint(3) + protoField(5, protoField(4, protoText(2, "edit_file") + protoText(3, json)))
        let file = (1...8).map { (3, "第\($0)行") } + [(3, "上一行"), (2, "旧"), (1, "新"), (1, "加的"), (3, "下一行")] + (12...20).map { (3, "第\($0)行") }
        store(excerptCid, [cardSteps[0], (132, fileEdit(file, call: call)), (15, answer("完成"))])
        let excerptLive = TurnBuilder(), excerptAcp = AcpParser(turn: excerptLive)
        excerptAcp.update(["sessionUpdate": "tool_call", "toolCallId": "excerpt", "name": "edit_file", "rawInput": params, "status": "completed"])
        let streamLive = TurnBuilder(), stream = AgyStreamParser(turn: streamLive)
        stream.feed(["event": "step_update", "step_update": ["step_index": 2, "step_type": "tool", "state": "DONE", "tool_name": "edit_file", "tool_info": ["parameters": params]]])
        let cold = AppDelegate(); cold.hooks.geminiCliDir = app.hooks.geminiCliDir
        for (stage, turn) in [("实时 acp", excerptLive.finish(finalText: "完成")), ("实时 stream-json", streamLive.finish(finalText: "完成")),
                              ("切回", (app.readGeminiConversation(cid: excerptCid)["messages"] as? [[String: Any]])?.last ?? [:]),
                              ("重开", (cold.readGeminiConversation(cid: excerptCid)["messages"] as? [[String: Any]])?.last ?? [:])] {
            let f = (turn["files"] as? [[String: Any]])?.first
            eq("\(f?["added"] ?? "?")/\(f?["removed"] ?? "?")", "2/1", "Gemini \(stage) edit_file 带着没改的上下文时只算真正增删的行")
        }
        eq((excerptLive.finish(finalText: "完成")["files"] as? [[String: Any]])?.first?["diff"] as? String, "@@\n 上一行\n-旧\n+新\n+加的\n 下一行",
           "Gemini 实时 edit_file 逐行比对出改动，没改的行留作上下文")
        // 实时不知道这段在第几行，网页靠整段内容找位置：离改动远的锚点行（让 Target 在文件里唯一的那行）不能裁掉，
        // 否则文件里另一段同样结构的地方会被当成改动处。
        let anchored = lineDiff(old: "server_b:\n  host: y\n  user: u\n  port: 80\n  timeout: 30\n  retries: 3",
                                new: "server_b:\n  host: y\n  user: u\n  port: 80\n  timeout: 30")
        eq(anchored, "@@\n server_b:\n   host: y\n   user: u\n   port: 80\n   timeout: 30\n-  retries: 3",
           "Gemini 实时逐行比对保留整段原文做上下文，锚点行还在")
        eq(diffCounts(anchored).added + diffCounts(anchored).removed, 1, "保留上下文不影响增删行数")
    }
    func exerciseEnding(_ mode: String, body: Bool) {
        try! mode.write(toFile: root + "/mode", atomically:true, encoding:.utf8)
        app.hooks.localEndings = []
        let req = AskRequest(agent:"gemini", reqId:89, prompt:"同一句", model:"fixture", effort:"low", permissionMode:"default", workspace:root, conversationId:cid, browserTools:false)
        let prior: [(Int,Data)] = [(14,chunks("同一句")), (15,answer("上一轮"))]
        store(cid, prior)
        app.hooks.jsSink = { name, _ in
            if (mode == "wait-for-cancel" && name == "onAgentStep") || (mode == "early-stop" && name == "onAgentRequest") {
                DispatchQueue.global().async { app.cancel(agent:"gemini",reqId:req.reqId) }
            }
        }
        let result = withTestAsk(app, req.key) { app.runGemini(req) }
        store(cid, prior + [(14,chunks("同一句"))] + (body ? [(15,answer("fixture-"))] : []))
        let history = app.readGeminiConversation(cid:cid)
        eq((history["lastTurn"] as? [String:Any])?["running"] as? Bool,false,"Gemini 本机 \(mode) 已经收尾")
        let messages = history["messages"] as? [[String:Any]] ?? []
        eq(str(messages.last,"outcome"), ["wait-for-cancel","early-stop"].contains(mode) ? "interrupted" : "failed", "B2 Gemini \(mode) 重开保留本轮结局")
        eq(str(messages.last,"text"), result.reply, "B2 Gemini 重开保留已显示的回答")
        eq(str(messages[1],"outcome"), "completed", "B2 Gemini 前一轮同句保持完成")
        if body {
            let real = result.turn?["steps"] as? [[String:Any]] ?? []
            let shown = messages.last?["steps"] as? [[String:Any]] ?? []
            eq(shown.map { str($0,"detail") }, real.map { str($0,"detail") }, "重开 \(mode) 保留实时工作过程和结束原因")
            check((messages.last?["duration"] as? Double ?? 0) > 0, "重开 \(mode) 保留工作时长")
        }
        if body && !result.reply.isEmpty {
            let extended = result.reply + " 后写入"
            store(cid, prior + [(14,chunks("同一句")), (15,answer(extended))])
            let rows = app.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]] ?? []
            eq(str(rows.last,"text"),extended,"Gemini 同轮较长的落盘正文不应被本机前缀截断")
        }
        if mode == "text-error" {
            // 正文写到一半上游断开：已显示的正文还是回答（拷贝回答拿到的是它），原因放进末尾的「出错」步骤，照样能重试
            eq(result.reply, "fixture-", "Gemini 正文后出错保留已显示的正文，不换成出错提示")
            eq(str(result.turn, "outcome"), "failed", "Gemini 正文后出错仍是失败，可重试")
            let ending = (result.turn?["steps"] as? [[String:Any]])?.last
            check(str(ending, "title") == "出错" && str(ending, "detail").contains("upstream connection reset"), "Gemini 正文后出错，原因在出错步骤里，实际=\(ending ?? [:])")
        }
        if mode == "drop" {
            check(result.reply.hasPrefix("⚠️ agy 中途出错"), "Gemini 工具进行中出错，正文仍是出错提示，实际=\(result.reply)")
        }
        if mode == "early-crash" {
            check(result.reply.contains("ENOSPC"), "Gemini 异常退出显示标准错误，实际=\(result.reply)")
            let later = Int(Date().timeIntervalSince1970) + 2
            let stamp = protoField(5, protoField(1, protoVarint(8) + protoVarint(later)))
            store(cid, prior + [(14,stamp + chunks("同一句")), (15,answer("重试成功"))])
            let reopened = app.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]] ?? []
            eq(reopened.filter { str($0,"role") == "bot" }.map { str($0,"outcome") }, ["completed","failed","completed"], "R3 同文重试按落库时间分清两轮")
            eq(str(reopened.last,"text"), "重试成功", "R3 旧错误不覆盖后来落盘的成功回答")
        }
        app.hooks.jsSink = { _, _ in }
    }
    let split = "split-steer"
    store(split, [(14,chunks("原问")), (15,answer("先检查")), (14,chunks("补充要求"))])
    let splitReq = AskRequest(agent:"gemini",reqId:1,prompt:"原问",model:"",effort:"",permissionMode:"",workspace:root,conversationId:split)
    app.rememberLocalEnding(splitReq,cid:split,text:"补充后的半段",outcome:"interrupted",position:0,
                            steps:[makeStep("user","你补充说",detail:"补充要求")])
    let splitRows = app.readGeminiConversation(cid:split)["messages"] as? [[String:Any]] ?? []
    eq(splitRows.map { str($0,"text") },["原问","先检查","补充要求","补充后的半段"],"Gemini 补充拆段后正文归到补充后")
    eq(str(splitRows.last,"outcome"),"interrupted","拆段末尾保留中断结局")
    exerciseEnding("wait-for-cancel", body:true)
    exerciseEnding("drop", body:true)
    exerciseEnding("text-error", body:true)
    exerciseEnding("early-crash", body:false)
    exerciseEnding("early-stop", body:false)
    // 停止时没有 prompt 的答复，正在写的那段正文只在流里：实时和重开都要以它为正文，不能退回工具前的引言。
    do {
        try! "tool-wait-cancel".write(toFile: root + "/mode", atomically:true, encoding:.utf8)
        let kept = app.hooks.localEndings
        defer { app.hooks.localEndings = kept }   // 下面的转写用例接着用 early-stop 的补记
        app.hooks.localEndings = []
        let req = AskRequest(agent:"gemini", reqId:91, prompt:"查文件", model:"fixture", effort:"low", permissionMode:"default", workspace:root, conversationId:cid, browserTools:false)
        let prior: [(Int,Data)] = [(14,chunks("同一句")), (15,answer("上一轮"))]
        store(cid, prior)
        app.hooks.jsSink = { name, data in
            if name == "onAgentStep", str(data["step"] as? [String:Any], "detail") == "真正的答案写到这里" {
                DispatchQueue.global().async { app.cancel(agent:"gemini",reqId:req.reqId) }
            }
        }
        let result = withTestAsk(app, req.key) { app.runGemini(req) }
        app.hooks.jsSink = { _, _ in }
        eq(result.reply, "真正的答案写到这里", "Gemini 工具后写到一半停止，实时正文是正在写的那段")
        let command = protoVarint(32) + protoVarint(3) + protoField(5, protoField(4, protoText(2,"run_command") + protoText(3,#"{"CommandLine":"cat notes.txt"}"#)))
        store(cid, prior + [(14,chunks("查文件")), (15,answer("先检查文件。")), (132,command), (15,answer("真正的答案写到这里"))])
        let cold = AppDelegate(); cold.hooks.geminiCliDir = app.hooks.geminiCliDir; cold.hooks.localEndings = app.hooks.localEndings
        for (stage, reader) in [("切回", app), ("重开", cold)] {
            let last = (reader.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]])?.last
            eq(str(last,"text"), "真正的答案写到这里", "Gemini 工具后停止，\(stage)正文不变成工具前的引言")
            eq(str(last,"outcome"), "interrupted", "Gemini 工具后停止，\(stage)保留中断")
        }
    }
    // 库里只落了命令、没落计划：补回的计划要按实时顺序插在命令前，命令不能再列一次。
    do {
        let planCid = "plan-stop"
        let command = protoVarint(32) + protoVarint(3) + protoField(5, protoField(4, protoText(2,"run_command") + protoText(3,#"{"CommandLine":"cat notes.txt"}"#)))
        store(planCid, [(14,chunks("查文件")), (132,command)])
        let live = TurnBuilder(), acp = AcpParser(turn:live)
        acp.update(["sessionUpdate":"plan", "entries":[["content":"读文件", "status":"in_progress"]]])
        acp.update(["sessionUpdate":"tool_call", "toolCallId":"r1", "name":"run_command", "status":"completed", "rawInput":["CommandLine":"cat notes.txt"]])
        acp.finish(stopReason:"cancelled")
        let shown = live.finish(finalText:acp.response, outcome:"interrupted")
        let planReq = AskRequest(agent:"gemini", reqId:92, prompt:"查文件", model:"", effort:"", permissionMode:"", workspace:root, conversationId:planCid)
        let kept = app.hooks.localEndings
        defer { app.hooks.localEndings = kept }
        app.hooks.localEndings = []
        app.rememberLocalEnding(planReq, cid:planCid, text:"", outcome:"interrupted", position:0, steps:shown["steps"] as? [[String:Any]])
        let last = (app.readGeminiConversation(cid:planCid)["messages"] as? [[String:Any]])?.last
        eq((last?["steps"] as? [[String:Any]] ?? []).map { str($0,"kind") }, (shown["steps"] as? [[String:Any]] ?? []).map { str($0,"kind") },
           "Gemini 更新计划、运行命令后停止，重开步骤和实时一样，命令只列一次")
    }
    try! fm.removeItem(atPath: app.geminiConversationDb(cid))
    let transcriptPath = app.geminiTranscriptPath(cid)
    try! fm.createDirectory(atPath: (transcriptPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let transcriptRows = [["type":"USER_INPUT","content":"同一句"], ["type":"PLANNER_RESPONSE","content":"上一轮"],
                          ["type":"USER_INPUT","content":"同一句"]]
    let transcriptText = transcriptRows.map { String(decoding: try! JSONSerialization.data(withJSONObject:$0), as:UTF8.self) }.joined(separator:"\n")
    try! transcriptText.write(toFile:transcriptPath, atomically:true, encoding:.utf8)
    let fallback = app.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]] ?? []
    eq(fallback.map { str($0,"role") }, ["user","bot","user","bot"], "B2-09 只有转写时也补回停下的一轮")
    eq(str(fallback.last,"outcome"), "interrupted", "B2-09 转写同样保留停止结局")
    app.hooks.localEndings = []
    let next = AskRequest(agent:"gemini", reqId:90, prompt:"转写后再问", model:"fixture", effort:"low", permissionMode:"default", workspace:root, conversationId:cid, browserTools:false)
    try! "early-crash".write(toFile:root + "/mode", atomically:true, encoding:.utf8)
    _ = withTestAsk(app, next.key) { app.runGemini(next) }
    let afterTranscript = app.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]] ?? []
    eq(str(afterTranscript.last,"outcome"), "failed", "B2-09 只有转写时也按已有提问数定位下一轮")
    _ = withTestAsk(app, next.key) { app.runGemini(next) }
    let twice = app.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]] ?? []
    eq(twice.filter { str($0,"outcome") == "failed" }.count, 2, "R3 只有转写时连续两次未落盘的失败各占一轮")
    let success = transcriptText + "\n" + #"{"type":"USER_INPUT","content":"转写后再问"}"# + "\n" + #"{"type":"PLANNER_RESPONSE","content":"新回答"}"#
    try! success.write(toFile:transcriptPath, atomically:true, encoding:.utf8)
    let retried = app.readGeminiConversation(cid:cid)["messages"] as? [[String:Any]] ?? []
    eq(str(retried.last,"text"),"新回答","转写中的同文成功回答保留在失败记录之后")
    var reads = 0
    app.hooks.geminiTranscriptRead = { reads += 1 }
    func statuses(_ cid: String) -> [String] {
        let messages = app.readGeminiConversation(cid: cid)["messages"] as? [[String: Any]] ?? []
        return messages.flatMap { ($0["steps"] as? [[String: Any]] ?? []).filter { str($0, "kind") == "write" }.map { str($0, "status") } }
    }
    let log: [[String: Any]] = [["step_index": 0, "type": "USER_INPUT", "status": "DONE"],
                                ["step_index": 1, "type": "GENERIC", "status": "DONE"],
                                ["step_index": 2, "type": "GENERIC", "status": "ERROR"],
                                ["step_index": 3, "type": "GENERIC", "status": "DONE"],
                                ["step_index": 4, "type": "PLANNER_RESPONSE", "status": "DONE"]]
    store("desktop:gd-status", [(14, chunks("改")), (132, tool(5)), (132, tool(5)), (132, tool(3)), (15, answer("好了"))], transcript: log)
    eq(statuses("desktop:gd-status"), ["ok", "error", "ok"], "GD2 重开历史按转写的步骤序号取最终状态")
    eq(reads, 1, "GD2 多个状态 5 的步骤只读一次转写")
    reads = 0
    store("gd-plain", [(14, chunks("改")), (132, tool(3)), (15, answer("好了"))], transcript: log)
    eq(statuses("gd-plain"), ["ok"], "GD2 没有状态 5 时结果不变")
    eq(reads, 0, "GD2 没有状态 5 的步骤就不读转写")

    // GD3：19.9 是附件：1 类型、2 agy 收到的图片字节、5 落盘路径（ACP 发的图这个文件并不存在）。
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    let image = protoField(9, protoText(1, "image/png") + protoText(5, root + "/gone/uploaded_media.png") + protoField(2, png))
    let note = protoField(9, protoText(1, "text/markdown") + protoText(5, root + "/note.md") + protoField(2, Data("# 笔记".utf8)))
    for cid in ["gd-image", "desktop:gd-image"] {
        store(cid, [(14, chunks("看")), (15, answer("先问")), (14, protoField(19, protoText(2, "什么颜色") + note + image)), (15, answer("红色"))])
        var messages = app.readGeminiConversation(cid: cid)["messages"] as? [[String: Any]] ?? []
        app.attachChatImages(&messages, payload: ["agent": "gemini", "conversationId": cid, "cwd": root])
        let user = messages.last { str($0, "role") == "user" }
        let images = user?["images"] as? [[String: Any]] ?? []
        eq(images.count, 1, "GD3 \(cid) 重开历史后图片还在（非图片附件不算）")
        eq(str(user, "text"), "什么颜色", "GD3 \(cid) 文字照旧")
        check(images.first?["src"] as? String != nil, "GD3 \(cid) 生成缩略图")
        eq(images.first.flatMap { $0["ref"] }.flatMap { app.fullChatImage(["ref": $0]) }, fullImageDataURL(png), "GD3 \(cid) 原图按会话和步骤从库里取回")
    }
    // 桌面版的 19.9 不带原图字节，原图在 19.9.5 指向的文件里（19.9.6 只是小缩略图）。
    let saved = root + "/uploaded.png"
    try! png.write(to: URL(fileURLWithPath: saved))
    store("desktop:gd-file", [(14, protoField(19, protoField(3, protoText(1, "看图")) + protoField(9, protoText(1, "image/png") + protoText(5, saved) + protoField(6, png)))), (15, answer("看到了"))])
    var fileMessages = app.readGeminiConversation(cid: "desktop:gd-file")["messages"] as? [[String: Any]] ?? []
    app.attachChatImages(&fileMessages, payload: ["agent": "gemini", "conversationId": "desktop:gd-file", "cwd": root])
    eq((fileMessages.first?["images"] as? [[String: Any]])?.first?["path"] as? String, saved, "GD3 没有图片字节时用落盘路径的原图")

    // GD4：/compact 这一轮压没压成按会话库判断，和重开时读出的压缩提示同一口径（2026-11-18 agy 1.5.11 实测：提问 14 → 压缩 23，状态 3）
    let compactStep = protoVarint(4 * 8) + protoVarint(3)
    func compacted(_ cid: String, _ steps: [(Int, Data)], prompt: String = "/compact") -> Bool? {
        store(cid, steps)
        let req = AskRequest(agent: "gemini", reqId: 1, prompt: prompt, model: "", effort: "low", permissionMode: "default", workspace: root, conversationId: cid)
        return app.geminiNoteCompacted(req, AgentReply(reply: "已经让它压缩前面的对话", conversationId: cid, turn: ["steps": [Any]()])).turn?["compacted"] as? Bool
    }
    let before: [(Int, Data)] = [(14, chunks("开始")), (15, answer("好"))]
    eq(compacted("gd-compact-done", before + [(14, chunks("/compact")), (23, compactStep)]), true, "GD4 压成了：这一轮记下了状态 3 的压缩")
    eq(roles(app.readGeminiConversation(cid: "gd-compact-done")["messages"] as? [[String: Any]] ?? []).last, "compact", "GD4 重开时同一步读成一条压缩提示")
    // agy 把 /compact 当普通提问作答（新对话第一句、或最高权限退回 agy -p 加了 --disable-slash-commands）：
    // 重开时网页滤掉 user「/compact」，那条回答仍是一条历史条目，实时提示也得算一条，否则页面比记录少一条
    eq(compacted("gd-compact-answered", before + [(14, chunks("/compact")), (15, answer("一段摘要"))]), true, "GD4 当成普通提问作答：记录里多一条回答，照样计数")
    eq(roles(app.readGeminiConversation(cid: "gd-compact-answered")["messages"] as? [[String: Any]] ?? []).suffix(2), ["user", "bot"], "GD4 作答那一轮重开读成提问加回答")
    eq(compacted("gd-compact-first", [(14, chunks("/compact")), (15, answer("没什么可压缩的"))]), true, "GD4 新对话第一句就发 /compact：同上")
    eq(compacted("gd-compact-tool", before + [(14, chunks("/compact")), (132, tool(3))]), true, "GD4 作答只用了工具也是一条回答")
    eq(compacted("gd-compact-old", [(14, chunks("开始")), (23, compactStep), (14, chunks("/compact"))]), false,
       "GD4 更早的压缩不算这一轮的")
    eq(compacted("gd-compact-failed", before + [(14, chunks("/compact")), (23, protoVarint(4 * 8) + protoVarint(7))]), false, "GD4 压缩步骤失败、记录里什么都没有：不算")
    eq(compacted("gd-compact-empty", before + [(14, chunks("/compact"))]), false, "GD4 什么都没写：不算")
    eq(compacted("gd-compact-plain", before + [(23, compactStep)], prompt: "继续"), nil, "GD4 不是压缩命令不看会话库")
    // GD4：普通提问作答途中 agy 自动压缩（本机真实记录：提问 14 → 若干步 → 压缩 23 → 接着作答），实时只有一张回答卡；
    // 重开也要是一张，压缩记成工作过程里的一步，后半段失败时这张卡前面紧挨原问，「重试」才找得到它。
    let autoDone = agyDbTurns([(14, chunks("做长任务")), (15, answer("先看看")), (132, tool(3)), (23, compactStep), (15, answer("做完了"))], cleanUser: { $0 })
    eq(roles(autoDone), ["user", "bot"], "GD4 回答中自动压缩：重开仍是一问一答")
    eq(str(autoDone.last, "text"), "做完了", "GD4 自动压缩后的正文是这一轮的回答")
    eq((autoDone.last?["steps"] as? [[String: Any]] ?? []).map { str($0, "title") }, ["说明", "写入 gd.txt", "压缩上下文"], "GD4 自动压缩按位置记成一步")
    let autoFailed = agyDbTurns([(14, chunks("做长任务")), (15, answer("先看看")), (23, compactStep),
                                 (17, protoField(24, protoField(3, protoText(2, "API error"))))], isHeld: { false }, cleanUser: { $0 })
    eq(roles(autoFailed), ["user", "bot"], "GD4 自动压缩后出错：不拆出第二张回答卡")
    eq(str(autoFailed.last, "outcome"), "failed", "GD4 自动压缩后出错：结局仍是失败，可重试原问")
    let autoFirst = agyDbTurns([(14, chunks("做长任务")), (23, compactStep), (15, answer("做完了"))], cleanUser: { $0 })
    eq(roles(autoFirst), ["user", "bot"], "GD4 提问后先自动压缩再作答：同一轮")
    for manual in ["/compact", " /compress\n"] {
        eq(roles(agyDbTurns(before + [(14, chunks(manual)), (23, compactStep)], cleanUser: { $0 })), ["user", "bot", "user", "compact"],
           "GD4 手动 \(trimmed(manual)) 仍是独立的压缩提示")
    }

    // GD5：agy 建 <id>.db 被别的进程挡住时照样建会话，内容改写进加密的 .pb，之后续聊又写回 .db，同一段会话被拆成两半。
    func lockedRun(_ mode: String) -> (reply: AgentReply, sessions: [String], prompts: [String]) {
        try! mode.write(toFile: root + "/mode", atomically: true, encoding: .utf8)
        for f in [cli + ".sessions", cli + ".prompts"] { try? fm.removeItem(atPath: f) }
        let req = AskRequest(agent:"gemini", reqId:90, prompt:"新问题", model:"fixture", effort:"low", permissionMode:"default", workspace:root, conversationId:"", browserTools:false)
        let result = withTestAsk(app, req.key) { app.runGemini(req) }
        let lines = { (p: String) in ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        return (result, lines(cli + ".sessions"), lines(cli + ".prompts"))
    }
    let locked = lockedRun("store-locked")
    eq(locked.sessions, ["locked-0", "fixture-session"], "GD5 建库被挡的新会话换一个重建")
    eq(locked.prompts, ["fixture-session"], "GD5 提问只发给建库成功的会话")
    eq(locked.reply.conversationId, "fixture-session", "GD5 App 记下的是重建的会话")
    check(!fm.fileExists(atPath: app.geminiStore("").database("locked-0")), "GD5 被挡下的空库删掉，不在目录里留空会话")
    let stuck = lockedRun("store-locked-always")
    eq(stuck.sessions, ["locked-0", "locked-1", "locked-2"], "GD5 一直被挡时最多重建两次")
    eq(stuck.prompts, ["locked-2"], "GD5 重建用完仍照常提问，不让用户白等")
    check(fm.fileExists(atPath: app.geminiStore("").database("locked-2")), "GD5 正在用的会话库不删")

    // GD6：agy 的日志从不清理、进程号会复用（2026-11-19 本机已有 15 个进程号各两份，目录顺序常先给旧的）：只认这个进程自己的那份。
    do {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try! sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let pid = sleeper.processIdentifier, dir = app.hooks.geminiCliDir! + "/log"
        try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let started = Date(timeIntervalSince1970: Double(processStartTime(pid) ?? 0) / 1_000_000)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        func write(_ name: String, failed sid: String, created: Date? = nil) {
            let line = "E1119 00:00:00.000000      44 errorreport.go:285] failed to create persistent trajectory in store 1: open backend \(root)/conversations/\(sid).db: trajectory db schema init: database is locked\n"
            try! line.write(toFile: dir + "/" + name, atomically: false, encoding: .utf8)
            if let created { try! fm.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: dir + "/" + name) }
        }
        let current = "acp-server-\(stamp.string(from: started))-\(pid).log"
        write(current, failed: "reused-new")
        // 同号的旧日志一份份加，直到目录顺序先给出旧的那份。APFS 的目录顺序按名字的哈希排，当前那份排第一的概率约是 1/份数，
        // 上限给到 300 份，夹具前提落空的概率才压到千分之几以下（原先 28 份时整套测试偶尔在这里失败）
        var n = 0
        repeat {
            n += 1
            write("acp-server-20261001_\(String(format: "%06d", n))-\(pid).log", failed: "reused-old", created: started - Double(3_600 * (400 - n)))
        } while (try! fm.contentsOfDirectory(atPath: dir)).first(where: { $0.hasSuffix("-\(pid).log") }) == current && n < 300
        check((try! fm.contentsOfDirectory(atPath: dir)).first(where: { $0.hasSuffix("-\(pid).log") }) != current, "GD6 夹具：目录顺序里同号的旧日志排在前面")
        check(app.geminiStoreFailed("reused-new", pid: pid), "GD6 同号有多份日志时认这个进程自己的那份")
        check(!app.geminiStoreFailed("reused-old", pid: pid), "GD6 同号旧日志里的失败不算这个进程的")
        // 日志名的时区和 App 不同、按启动时刻试不中：按创建时刻认，旧的照样不算
        try! fm.removeItem(atPath: dir + "/" + current)
        write("acp-server-20260101_000000-\(pid).log", failed: "reused-zone")
        check(app.geminiStoreFailed("reused-zone", pid: pid), "GD6 日志名的时刻对不上时按创建时刻认出这个进程的日志")
        check(!app.geminiStoreFailed("reused-old", pid: pid), "GD6 按创建时刻认时旧日志也不算")
    }
}
