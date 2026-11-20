// ME：Claude 和 Codex 转来的 MCP 交互（Codex 的 MCP 工具审批、MCP 服务器自己的表单 / 链接 elicitation）、
// Codex 的额外权限申请、requestUserInput 按题目 id 作答、几种少见回调的兜底答复；假 CLI 是 fake-cli.py 的 mcp。
import Cocoa

func testMCPElicitation() {
    print("· ME：MCP 交互和少见回调")
    let root = NSTemporaryDirectory() + "aipethub-mcp-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    struct Outcome {
        var cards: [[String: Any]] = []
        var closed: [String] = []
        var replies: [[String: Any]] = []   // 假 CLI 收到的、给它那几个请求的答复（Codex 取 result / error，Claude 取 control_response.response）
        var reply: String?
        var opened: [URL] = []
    }
    /// 跑一轮：card 为真时等卡片出现再交给 act 作答（act 可以不答、改成停止）；为假时不该有卡片，直接等这一轮结束。
    func run(_ agent: String, _ mode: String, card: Bool = true, _ act: (AppDelegate, AskRequest, [String: Any]) -> Void = { _, _, _ in }) -> Outcome {
        let label = "ME \(agent)/\(mode)"
        let path = root + "/\(agent)-\(mode)-\(UUID().uuidString.prefix(6))"
        try! installFakeCLI(at: path, behavior: "mcp")
        try! mode.write(toFile: path + ".mode", atomically: true, encoding: .utf8)
        let app = AppDelegate(), lock = NSLock(), done = DispatchSemaphore(value: 0)
        var opened: [URL] = []
        let calls = JSSink(app).calls
        app.hooks.openURL = { url in lock.lock(); opened.append(url); lock.unlock() }
        app.hooks.cliExecutable = path
        app.partialSupport[path] = true
        var req = AskRequest(agent: agent, reqId: 310, prompt: "use the tool", model: "model", effort: "low",
                             permissionMode: agent == "claude" ? "bypassPermissions" : "ask",
                             workspace: root, conversationId: "")
        req.browserTools = false
        var result: AgentReply?
        DispatchQueue.global().async {
            result = withTestAsk(app, req.key) { agent == "claude" ? app.runClaude(req) : app.runCodex(req) }
            done.signal()
        }
        if card {
            let shown = waitUntil { !calls("onAgentRequest").isEmpty }
            check(shown, "\(label) 窗口出现卡片（实际 \(calls("onAgentRequest").count) 张）")
            if let first = calls("onAgentRequest").first { act(app, req, first) }
        }
        let finished = waitSignal(done)
        if !finished { app.cancel(agent: agent, reqId: req.reqId); _ = waitSignal(done) }
        check(finished, "\(label) 这一轮照常结束")
        if !card { eq(calls("onAgentRequest").count, 0, "\(label) 不出卡片") }
        var out = Outcome()
        out.cards = calls("onAgentRequest")
        out.closed = calls("onAgentRequestClosed").compactMap { $0["requestId"] as? String }
        out.reply = result?.reply
        lock.lock(); out.opened = opened; lock.unlock()
        let lines = ((try? String(contentsOfFile: path + ".log", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { app.jsonObject(String($0)) }
        for o in lines {
            if agent == "claude" {
                guard let r = o["response"] as? [String: Any], r["request_id"] as? String == "e-1" else { continue }
                out.replies.append(r)
            } else {
                guard o["method"] == nil, let id = (o["id"] as? NSNumber)?.intValue, id < 10 else { continue }
                out.replies.append(o)
            }
        }
        for c in out.cards { check(out.closed.contains(c["requestId"] as? String ?? "-"), "\(label) 卡片 \(c["requestId"] ?? "") 撤掉了") }
        return out
    }
    func result(_ o: Outcome, _ i: Int = 0) -> [String: Any] { i < o.replies.count ? o.replies[i]["result"] as? [String: Any] ?? [:] : [:] }
    func claudeBody(_ o: Outcome) -> [String: Any] { o.replies.first?["response"] as? [String: Any] ?? [:] }
    func answer(_ app: AppDelegate, _ req: AskRequest, _ card: [String: Any], _ body: [String: Any]) {
        app.answerRequest(agent: req.agent, reqId: req.reqId, requestId: card["requestId"] as? String ?? "", body: body)
    }
    let ids = ["name", "colour", "size", "agree", "count", "tags"]
    let filled: [String: Any] = ["name": "小明", "colour": "蓝色", "size": "大", "agree": "否", "count": "3", "tags": "甲、上、丙"]
    /// 表单卡：每个字段一题，按字段 id 作答；选项题显示标题、交回 const。
    /// Claude 带 property_order，按它排；Codex 不带（它的 schema 字段本来就按名字排序后发出），按字段名排。
    func checkForm(_ label: String, _ card: [String: Any], order: [String]) {
        eq(card["kind"] as? String, "question", "\(label) 表单用提问卡")
        eq(card["message"] as? String, "请填写资料", "\(label) 卡片带上 MCP 的说明")
        let qs = card["questions"] as? [[String: Any]] ?? []
        eq(qs.compactMap { $0["id"] as? String }, order, "\(label) 每个字段一题、按顺序")
        let q: (String) -> [String: Any] = { id in qs.first { $0["id"] as? String == id } ?? [:] }
        let opts: (String) -> [String] = { id in (q(id)["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String } }
        eq(q("name")["question"] as? String, "名字", "\(label) 题目用字段标题")
        eq(q("count")["valueType"] as? String, "integer", "\(label) 数字输入带类型")
        eq(q("count")["required"] as? Bool, false, "\(label) 可选数字允许留空")
        eq(q("name")["isOther"] as? Bool, true, "\(label) 文字题给输入框")
        eq(opts("colour"), ["红色", "蓝色"], "\(label) oneOf 做成选项")
        eq(opts("size"), ["小", "大"], "\(label) enum 用 enumNames 做选项")
        eq(opts("agree"), ["是", "否"], "\(label) 布尔是「是 / 否」")
        eq(opts("tags"), ["甲、上", "乙", "丙"], "\(label) 多选的选项")
        eq(q("tags")["multiSelect"] as? Bool, true, "\(label) 数组字段是多选")
        eq(q("colour")["isOther"] as? Bool, false, "\(label) 选项题不另给输入框")
    }
    func checkContent(_ label: String, _ content: [String: Any]?) {
        let c = content ?? [:]
        eq(c["name"] as? String, "小明", "\(label) 文字字段")
        eq(c["colour"] as? String, "blue", "\(label) 单选交回 const")
        eq(c["size"] as? String, "l", "\(label) enum 交回原值")
        eq(c["agree"] as? Bool, false, "\(label) 布尔交回 false")
        eq((c["count"] as? NSNumber)?.intValue, 3, "\(label) 整数交回数字")
        check(c["count"] is NSNumber && !(c["count"] is String), "\(label) 整数不是字符串 \(c)")
        eq(c["tags"] as? [String], ["a", "c"], "\(label) 多选交回 const 数组")
    }

    // ===== Codex =====
    var o = run("gpt", "tool-approval") { app, req, card in answer(app, req, card, ["decision": "allow"]) }
    let first = o.cards.first ?? [:]
    eq(first["kind"] as? String, "permission", "ME gpt/tool-approval MCP 工具审批用审批卡")
    eq(first["title"] as? String, "运行 MCP 工具 probe.plain_tool", "ME gpt/tool-approval 标题")
    check((first["detail"] as? String ?? "").contains("https://example.com"), "ME gpt/tool-approval 详情带上参数 \(first["detail"] ?? "")")
    eq(result(o)["action"] as? String, "accept", "ME gpt/tool-approval 允许是 accept（实际答复 \(o.replies)）")
    eq((result(o)["content"] as? [String: Any])?.isEmpty, true, "ME gpt/tool-approval 允许时 content 是空对象")
    check(result(o)["_meta"] is NSNull, "ME gpt/tool-approval 允许时 _meta 为 null")
    eq(o.reply, "answered", "ME gpt/tool-approval 允许后它接着答完")

    o = run("gpt", "tool-approval") { app, req, card in answer(app, req, card, ["decision": "allowAll"]) }
    eq(o.cards.count, 1, "ME gpt/tool-approval 这一轮都允许后别的 MCP 工具不再出卡")
    eq(o.replies.count, 2, "ME gpt/tool-approval 两次审批都答了（实际 \(o.replies)）")
    for i in 0..<2 {
        eq(result(o, i)["action"] as? String, "accept", "ME gpt/tool-approval 都允许第 \(i + 1) 次是 accept")
        eq((result(o, i)["_meta"] as? [String: Any])?["persist"] as? String, "session", "ME gpt/tool-approval 都允许第 \(i + 1) 次带 persist session")
    }

    o = run("gpt", "tool-approval") { app, req, card in answer(app, req, card, ["decision": "deny", "message": ""]) }
    eq(result(o)["action"] as? String, "decline", "ME gpt/tool-approval 拒绝是 decline")
    check(result(o)["content"] is NSNull && result(o)["_meta"] is NSNull, "ME gpt/tool-approval 拒绝时 content、_meta 为 null \(result(o))")

    o = run("gpt", "form") { app, req, card in
        checkForm("ME gpt/form", card, order: ids.sorted())
        answer(app, req, card, ["decision": "allow", "answers": filled, "answerParts": ["tags":["selected":["甲、上","丙"]]]])
    }
    eq(result(o)["action"] as? String, "accept", "ME gpt/form 作答是 accept（实际答复 \(o.replies)）")
    checkContent("ME gpt/form", result(o)["content"] as? [String: Any])
    check(result(o)["_meta"] is NSNull, "ME gpt/form _meta 为 null")

    o = run("gpt", "form") { app, req, card in answer(app, req, card, ["decision": "deny", "message": "用户没有回答这个问题"]) }
    eq(result(o)["action"] as? String, "decline", "ME gpt/form 不回答是 decline")
    check(result(o)["content"] is NSNull, "ME gpt/form 不回答时 content 为 null")

    o = run("gpt", "form") { app, req, card in
        var partial = filled; partial["name"] = ""
        answer(app, req, card, ["decision": "allow", "answers": partial])
    }
    eq(result(o)["action"] as? String, "decline", "ME gpt/form 必填项没填时回 decline（实际 \(result(o))）")

    o = run("gpt", "form-interrupt") { app, req, _ in app.cancel(agent: req.agent, reqId: req.reqId) }
    eq(result(o)["action"] as? String, "cancel", "ME gpt/form-interrupt 停止时交回 cancel（实际答复 \(o.replies)）")

    o = run("gpt", "complex", card: false)
    eq(result(o)["action"] as? String, "decline", "ME gpt/complex 认不出的字段直接 decline（实际答复 \(o.replies)）")
    eq(o.reply, "answered", "ME gpt/complex 它接着答完")

    o = run("gpt", "url") { app, req, card in
        eq(card["onceOnly"] as? Bool, true, "MCP 链接确认只允许本次")
        eq(card["kind"] as? String, "permission", "ME gpt/url 链接用审批卡")
        check((card["detail"] as? String ?? "").contains("请登录授权") && (card["detail"] as? String ?? "").contains("https://example.com/auth?x=1"), "ME gpt/url 详情有说明和链接 \(card)")
        answer(app, req, card, ["decision": "allow"])
    }
    eq(o.opened.map(\.absoluteString), ["https://example.com/auth?x=1"], "ME gpt/url 允许时打开链接")
    eq(result(o)["action"] as? String, "accept", "ME gpt/url 允许是 accept（实际答复 \(o.replies)）")

    o = run("gpt", "url") { app, req, card in answer(app, req, card, ["decision": "deny", "message": ""]) }
    eq(o.opened.count, 0, "ME gpt/url 拒绝时不打开链接")
    eq(result(o)["action"] as? String, "decline", "ME gpt/url 拒绝是 decline")

    for (decision, scope) in [("allow", "turn"), ("allowAll", "session")] {
        o = run("gpt", "permissions") { app, req, card in
            eq(card["kind"] as? String, "permission", "ME gpt/permissions 用审批卡")
            eq(card["title"] as? String, "申请额外权限：网络 / 写 /tmp/out", "ME gpt/permissions 标题")
            answer(app, req, card, ["decision": decision])
        }
        let granted = result(o)["permissions"] as? [String: Any]
        eq((granted?["network"] as? [String: Any])?["enabled"] as? Bool, true, "ME gpt/permissions \(decision) 原样给回网络权限（实际答复 \(o.replies)）")
        eq((granted?["fileSystem"] as? [String: Any])?["write"] as? [String], ["/tmp/out"], "ME gpt/permissions \(decision) 原样给回写权限")
        eq(result(o)["scope"] as? String, scope, "ME gpt/permissions \(decision) 的 scope")
    }
    o = run("gpt", "permissions") { app, req, card in answer(app, req, card, ["decision": "deny", "message": ""]) }
    eq((result(o)["permissions"] as? [String: Any])?.isEmpty, true, "ME gpt/permissions 拒绝时不给权限（实际答复 \(o.replies)）")
    eq(result(o)["scope"] as? String, "turn", "ME gpt/permissions 拒绝时 scope turn")

    o = run("gpt", "rui") { app, req, card in
        let qs = card["questions"] as? [[String: Any]] ?? []
        eq(qs.compactMap { $0["id"] as? String }, ["first", "second"], "ME gpt/rui 题目带上 id")
        eq(qs.first?["isOther"] as? Bool, false, "ME gpt/rui isOther 传给网页")
        eq(qs.first?["multiSelect"] as? Bool, true, "ME gpt/rui multiSelect 按实际传")
        eq(qs.last?["isSecret"] as? Bool, true, "ME gpt/rui isSecret 传给网页")
        answer(app, req, card, ["decision": "allow", "answers": ["first": "左、上、右", "second": "口令"], "answerParts":["first":["selected":["左、上","右"]]]])
    }
    let answers = result(o)["answers"] as? [String: [String: [String]]]
    eq(answers ?? [:], ["first": ["answers": ["左、上", "右"]], "second": ["answers": ["口令"]]], "ME gpt/rui 两题文字相同也按 id 各自交回")

    o = run("gpt", "dynamic", card: false)
    let items = result(o)["contentItems"] as? [[String: Any]]
    eq(items?.first?["type"] as? String, "inputText", "ME gpt/dynamic 回一段文字（实际答复 \(o.replies)）")
    eq(items?.first?["text"] as? String, "AIPetHub 没有这个工具", "ME gpt/dynamic 说明没有这个工具")
    eq(result(o)["success"] as? Bool, false, "ME gpt/dynamic success 为 false")
    eq(o.reply, "answered", "ME gpt/dynamic 它接着答完")

    o = run("gpt", "unknown", card: false)
    eq(((o.replies.first?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue, -32601, "ME gpt/unknown 不认识的请求仍回 -32601")

    // ===== Claude =====
    o = run("claude", "form") { app, req, card in
        checkForm("ME claude/form", card, order: ids)
        answer(app, req, card, ["decision": "allow", "answers": filled, "answerParts": ["tags":["selected":["甲、上","丙"]]]])
    }
    eq(o.replies.first?["subtype"] as? String, "success", "ME claude/form 答复是 success（实际 \(o.replies)）")
    eq(claudeBody(o)["action"] as? String, "accept", "ME claude/form 作答是 accept")
    checkContent("ME claude/form", claudeBody(o)["content"] as? [String: Any])
    eq(o.reply, "answered", "ME claude/form 它接着答完")

    o = run("claude", "form") { app, req, card in answer(app, req, card, ["decision": "deny", "message": "用户没有回答这个问题"]) }
    eq(claudeBody(o)["action"] as? String, "decline", "ME claude/form 不回答是 decline（实际 \(o.replies)）")

    o = run("claude", "form-interrupt") { app, req, _ in app.cancel(agent: req.agent, reqId: req.reqId) }
    eq(claudeBody(o)["action"] as? String, "cancel", "ME claude/form-interrupt 停止时交回 cancel（实际 \(o.replies)）")

    o = run("claude", "complex", card: false)
    eq(claudeBody(o)["action"] as? String, "decline", "ME claude/complex 认不出的字段直接 decline（实际 \(o.replies)）")

    o = run("claude", "url") { app, req, card in
        eq(card["kind"] as? String, "permission", "ME claude/url 链接用审批卡")
        check((card["detail"] as? String ?? "").contains("https://example.com/auth?x=1"), "ME claude/url 详情有链接 \(card)")
        answer(app, req, card, ["decision": "allow"])
    }
    eq(o.opened.map(\.absoluteString), ["https://example.com/auth?x=1"], "ME claude/url 允许时打开链接")
    eq(claudeBody(o)["action"] as? String, "accept", "ME claude/url 允许是 accept（实际 \(o.replies)）")

    o = run("claude", "hook", card: false)
    eq(o.replies.first?["subtype"] as? String, "success", "ME claude/hook hook_callback 回 success（实际 \(o.replies)）")
    eq((claudeBody(o)).isEmpty && o.replies.first?["response"] != nil, true, "ME claude/hook 答复是空对象")

    o = run("claude", "unknown", card: false)
    eq(o.replies.first?["subtype"] as? String, "error", "ME claude/unknown 不认识的请求仍回 error")
}
