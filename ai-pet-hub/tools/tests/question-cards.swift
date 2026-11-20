// QC：三位 CLI 向用户提问时窗口出现作答卡片，答复按各家要的格式交回（Codex、Gemini 按题目 id，Claude 按题目文字）；假 CLI 是 fake-cli.py 的 question。
// 覆盖卡片出现、作答回传、不回答、问题在别处了结后撤卡；Gemini 另测停止时交回 cancel。
import Cocoa

func testQuestionCards() {
    print("· QC：三位提问时的作答卡片")
    let root = NSTemporaryDirectory() + "aipethub-question-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let color = "你最喜欢的颜色是什么？", fruit = "你喜欢哪些水果？"
    let cases = ["claude": ["ask", "deny", "elsewhere"], "gpt": ["ask", "deny", "elsewhere"], "gemini": ["ask", "deny", "elsewhere", "interrupt"]]
    for agent in ["claude", "gpt", "gemini"] {
        for mode in cases[agent]! {
            let label = "QC \(agent)/\(mode)"
            let path = root + "/\(agent)-\(mode)"
            try! installFakeCLI(at: path, behavior: "question")
            try! (mode == "deny" ? "ask" : mode).write(toFile: path + ".mode", atomically: true, encoding: .utf8)
            let app = AppDelegate(), done = DispatchSemaphore(value: 0)
            let calls = JSSink(app).calls
            app.hooks.cliExecutable = path
            app.partialSupport[path] = true
            var req = AskRequest(agent: agent, reqId: 300, prompt: "ask me", model: "model", effort: "low",
                                 permissionMode: agent == "claude" ? "bypassPermissions" : "danger-full-access",
                                 workspace: root, conversationId: "")
            req.browserTools = false
            var result: AgentReply?
            DispatchQueue.global().async {
                result = withTestAsk(app, req.key) {
                    agent == "claude" ? app.runClaude(req) : agent == "gpt" ? app.runCodex(req) : app.runGemini(req)
                }
                done.signal()
            }
            // 假 CLI 收到的、发给提问的那一条答复
            func replies() -> [[String: Any]] {
                ((try? String(contentsOfFile: path + ".log", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { app.jsonObject(String($0)) }.filter { o in
                    switch agent {
                    case "claude": return (o["response"] as? [String: Any])?["request_id"] as? String == "q-1"
                    case "gpt": return (o["id"] as? NSNumber)?.intValue == 0 && o["method"] == nil
                    default: return o["id"] as? String == "q-1" && o["method"] == nil
                    }
                }
            }
            let shown = waitUntil { !calls("onAgentRequest").isEmpty }
            check(shown, "\(label) 提问时窗口出现作答卡片（实际推给网页 \(calls("onAgentRequest").count) 张卡，回答 \(result?.reply ?? "未结束")）")
            let card = calls("onAgentRequest").first ?? [:]
            let rid = card["requestId"] as? String ?? ""
            let questions = card["questions"] as? [[String: Any]] ?? []
            if shown {
                eq(card["kind"] as? String, "question", "\(label) 卡片是提问卡")
                eq(questions.compactMap { $0["question"] as? String }, [color, agent == "gemini" ? color : fruit], "\(label) 题目按顺序带上")
                eq((questions.first?["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String }, ["红色", "蓝色"], "\(label) 第一题的两个选项")
                if agent != "gpt" { eq(questions.last?["multiSelect"] as? Bool, true, "\(label) 第二题是多选") }
            }
            if agent == "gemini" {
                eq(questions.map { $0["isOther"] as? Bool }, [false,true], "Gemini 只有协议支持自填的选择题开放输入")
                eq(questions.map { str($0,"id") }, ["q1","q2"], "B4-22 Gemini 同名题保留表单字段编号")
            }
            switch mode {
            case "ask":
                // Gemini 和 Codex 按编号提交，Claude 的工具协议按题干提交。
                let answers: [String: Any] = agent == "gpt" ? ["color": "蓝色", "fruit": "香蕉"] : agent == "gemini" ? ["q1":"蓝色","q2":"香蕉、梨、橙子、榴莲"] : [color: "蓝色", fruit: "香蕉、橙子、榴莲"]
                app.answerRequest(agent: agent, reqId: req.reqId, requestId: rid, body: ["decision": "allow", "answers": answers, "answerParts":["q2":["selected":["香蕉、梨","橙子"],"custom":"榴莲"]]])
            case "deny":
                app.answerRequest(agent: agent, reqId: req.reqId, requestId: rid, body: ["decision": "deny", "message": "用户没有回答这个问题，请按你自己的判断继续。"])
            case "interrupt":
                app.cancel(agent: agent, reqId: req.reqId)
            default:
                break
            }
            let finished = waitSignal(done)
            if !finished { app.cancel(agent: agent, reqId: req.reqId); _ = waitSignal(done) }
            check(finished, "\(label) 这一轮照常结束")
            check(!shown || calls("onAgentRequestClosed").contains { $0["requestId"] as? String == rid }, "\(label) 卡片撤掉了")
            if mode == "ask" && agent != "gemini" {
                eq(result?.turn?["turnKey"] as? String, agent == "claude" ? "原问编号" : "turn", "改动收尾沿用协议报告的原问编号")
            }
            let got = replies()
            let body: [String: Any] = {
                guard let r = got.first else { return [:] }
                switch agent {
                case "claude": return ((r["response"] as? [String: Any])?["response"] as? [String: Any]) ?? [:]
                default: return r["result"] as? [String: Any] ?? [:]
                }
            }()
            if mode == "elsewhere" {
                eq(got.count, 0, "\(label) 在别处了结的问题不再答复")
                eq(result?.reply, "answered", "\(label) 回答照常收到")
                continue
            }
            eq(got.count, 1, "\(label) 答复只交回一次")
            switch (agent, mode) {
            case ("claude", "ask"):
                eq(body["behavior"] as? String, "allow", "\(label) 作答是允许")
                let input = body["updatedInput"] as? [String: Any]
                eq(input?["answers"] as? [String: String], [color: "蓝色", fruit: "香蕉、橙子、榴莲"], "\(label) 答案按题目填进 updatedInput")
                eq((input?["questions"] as? [Any])?.count, 2, "\(label) 原来的题目一起带回")
            case ("claude", "deny"):
                eq(body["behavior"] as? String, "deny", "\(label) 不回答是拒绝")
                check((body["message"] as? String ?? "").contains("没有回答"), "\(label) 带上说明 \(body)")
            case ("gpt", "ask"):
                let answers = body["answers"] as? [String: [String: [String]]]
                eq(answers ?? [:], ["color": ["answers": ["蓝色"]], "fruit": ["answers": ["香蕉"]]], "\(label) 按题目 ID 交回")
            case ("gpt", "deny"):
                let answers = body["answers"] as? [String: [String: [String]]]
                eq(answers ?? [:], ["color": ["answers": []], "fruit": ["answers": []]], "\(label) 不回答时每题留空")
            case ("gemini", "ask"):
                eq(body["action"] as? String, "accept", "\(label) 作答是 accept")
                let content = body["content"] as? [String: Any] ?? [:]
                eq(content["q1"] as? String, "2", "\(label) 单选交回选项编号")
                eq(content["q2"] as? [String], ["2", "3"], "\(label) 多选交回编号数组")
                eq(content["q2_other"] as? String, "榴莲", "\(label) 自己写的回答放进 _other")
                check(content["q1_other"] == nil, "\(label) 没写的 _other 不带 \(content)")
            case ("gemini", "deny"):
                eq(body["action"] as? String, "decline", "\(label) 不回答是 decline")
            case ("gemini", "interrupt"):
                eq(body["action"] as? String, "cancel", "\(label) 停止时交回 cancel")
            default:
                break
            }
            if mode != "interrupt" { eq(result?.reply, "answered", "\(label) 交回答复后它接着答完") }
        }
    }
    // Claude「先做计划」：计划卡点「批准，直接做完」要真的切到最高权限；CLI 不肯切时要让用户看到，不能撤了卡就当成功。
    for mode in ["plan", "plan-refuse"] {
        let label = "QC claude/\(mode)"
        let path = root + "/claude-\(mode)"
        try! installFakeCLI(at: path, behavior: "question")
        try! mode.write(toFile: path + ".mode", atomically: true, encoding: .utf8)
        let app = AppDelegate(), done = DispatchSemaphore(value: 0)
        let calls = JSSink(app).calls
        app.hooks.cliExecutable = path
        app.partialSupport[path] = true
        var req = AskRequest(agent: "claude", reqId: 301, prompt: "先计划", model: "model", effort: "low",
                             permissionMode: "plan", workspace: root, conversationId: "")
        req.browserTools = false
        var result: AgentReply?
        DispatchQueue.global().async {
            result = withTestAsk(app, req.key) { app.runClaude(req) }
            done.signal()
        }
        let shown = waitUntil { calls("onAgentRequest").contains { $0["kind"] as? String == "plan" } }
        check(shown, "\(label) 出现计划卡")
        let rid = calls("onAgentRequest").first?["requestId"] as? String ?? ""
        app.answerRequest(agent: "claude", reqId: req.reqId, requestId: rid, body: ["decision": "allow", "mode": "bypassPermissions"])
        let finished = waitSignal(done)
        if !finished { app.cancel(agent: "claude", reqId: req.reqId); _ = waitSignal(done) }
        check(finished, "\(label) 这一轮照常结束")
        let argv = (try? Data(contentsOf: URL(fileURLWithPath: path + ".argv"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        let permission = argv.firstIndex(of: "--permission-mode").map { argv.index(after: $0) }.flatMap { $0 < argv.count ? argv[$0] : nil }
        eq(permission, "plan", "\(label) 仍以计划模式启动，计划卡先出现")
        let switched = try? String(contentsOfFile: path + ".switched", encoding: .utf8)
        eq(switched, mode == "plan" ? "yes" : "no", "\(label) CLI 收到切到最高权限的请求，切换结果")
        let notices = (result?.turn?["steps"] as? [[String: Any]] ?? []).filter { str($0, "kind") == "error" }
        if mode == "plan" {
            eq(notices.count, 0, "\(label) 切到最高权限成功，没有失败提示（实际 \(notices.map { str($0, "title") })）")
        } else {
            check(notices.contains { str($0, "title").contains("没能切换") }, "\(label) 切换失败时工作过程里有提示（实际 \(notices.map { str($0, "title") })）")
        }
        eq(result?.reply, "answered", "\(label) 批准后它接着答完")
    }
}
