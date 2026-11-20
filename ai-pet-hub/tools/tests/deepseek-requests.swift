// 离线回归 DG：DeepSeek 要人答的请求。python3 tools/test-deepseek.py 的 dg-* 场景，只起 tools/fixtures/fake-dsh.py。
// 计划评审用计划卡、dsh 自己开的回合里的提问和审批、答复的回执、事件流单条断开、本轮事件从哪一句开始算。
import Cocoa

func runDeepSeekRequestTests(_ app: AppDelegate, mode: String, root: String) {
    let calls = JSSink(app).calls
    func cards(_ id: String, reqId: Int? = nil) -> [[String: Any]] {
        calls("onAgentRequest").filter { $0["requestId"] as? String == id && (reqId == nil || $0["reqId"] as? Int == reqId) }
    }
    func closed(_ id: String, reqId: Int) -> Bool {
        calls("onAgentRequestClosed").contains { $0["requestId"] as? String == id && $0["reqId"] as? Int == reqId }
    }
    func rows() -> [[String: Any]] {
        ((try? String(contentsOfFile: root + "/rpc-" + mode + ".jsonl", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { app.jsonObject(String($0)) }
    }
    func responses(_ rpcId: String) -> [[String: Any]] { rows().filter { $0["type"] as? String == "client-response" && $0["rpcId"] as? String == rpcId } }
    func receipts(_ rpcId: String) -> [[String: Any]] { rows().filter { $0["rpcId"] as? String == rpcId }.compactMap { $0["receipt"] as? [String: Any] } }
    func answers(_ row: [String: Any]?) -> [[String: Any]] {
        (((row?["result"] as? [String: Any])?["value"] as? [String: Any])?["answer"] as? [String: Any])?["answers"] as? [[String: Any]] ?? []
    }
    /// 起一轮（在后台跑），返回这一轮和取结果的函数（5 秒内没结束就替它收尾，免得卡住，结果记为 nil）。
    func start(_ reqId: Int, _ prompt: String) -> (DeepSeekLiveTurn, () -> AgentReply?) {
        let live = DeepSeekLiveTurn(app: app, req: AskRequest(agent: "deepseek", reqId: reqId, prompt: prompt, model: "", effort: "",
                                                              permissionMode: "read-only", workspace: root, conversationId: "probe"))
        let done = DispatchSemaphore(value: 0); var result: AgentReply?
        DispatchQueue.global().async { result = withTestAsk(app, live.req.key) { live.run(ready: { nil }) }; done.signal() }
        return (live, {
            defer { live.input.abandon() }
            if waitSignal(done) { return result }
            live.receiveForTest(["type": "session/event", "event": ["type": "turn/end", "data": ["reason": ["kind": "completed"]]]])
            _ = waitSignal(done); return nil
        })
    }
    let fmt: [String: Any] = ["id": "fmt", "question": "导出成哪种格式？", "options": [["label": "PDF"], ["label": "PNG"]]]

    switch mode {
    case "dg-gap-complete", "dg-gap-limit", "dg-gap-missing":
        app.hooks.cliExecutable = FileManager.default.currentDirectoryPath + "/tools/fixtures/fake-dsh.py"
        app.hooks.dshIdleFinishScheduled = { _, expire in expire() }
        let (_, finish) = start(77, "重连")
        check(waitUntil { calls("onAgentStep").contains { str($0["step"] as? [String: Any], "detail") == "半截" } }, "B8 本轮半截正文已到")
        _ = app.dshServer.call("probe.drop-mux")
        let reply = finish()
        let expected = mode == "dg-gap-limit" ? "failed" : (mode == "dg-gap-missing" ? "incomplete" : "completed")
        check(reply?.reply == "完整正文" && str(reply?.turn, "outcome") == expected,
              "B8 重连按本轮调用编号补齐正文和结局，实际 \(reply?.reply ?? "无") / \(str(reply?.turn, "outcome"))")
    case "dg-gap-running":
        app.hooks.cliExecutable = FileManager.default.currentDirectoryPath + "/tools/fixtures/fake-dsh.py"
        let checked = DispatchSemaphore(value: 0)
        app.hooks.dshGapChecked = { checked.signal() }
        app.hooks.dshIdleFinishScheduled = { _, expire in expire() }
        let (live, finish) = start(78, "慢回合")
        check(waitUntil { calls("onAgentStep").contains { str($0["step"] as? [String: Any], "detail") == "半截" } }, "慢回合已收到半截正文")
        live.receiveForTest(["type":"host/session-status", "running":true])
        _ = app.dshServer.call("probe.drop-mux")
        check(waitSignal(checked), "正文流重连并完成历史核对")
        let premature = live.finishedForTest
        _ = app.dshServer.call("probe.recover")
        live.receiveForTest(["type":"_streamReady"])
        let reply = finish()
        check(!premature && str(reply?.turn, "outcome") == "completed", "只断正文流时保留慢回合，提前结束=\(premature)，结局=\(str(reply?.turn,"outcome"))")
    case "dg-plan":
        // exit_plan_mode 交来的计划评审（question/requested 带 intent.kind=plan-review）：用计划卡显示计划正文，不再盲批
        for (n, decision) in [(1, "allow"), (2, "deny"), (3, "stop")] {
            let (live, finish) = start(40 + n, "plan-\(n)")
            let id = "dshq-q-plan-\(n)"
            check(waitUntil({ !cards(id).isEmpty }), "DG1 第 \(n) 轮计划评审出现卡片")
            let card = cards(id).first ?? [:]
            check(card["kind"] as? String == "plan" && (card["plan"] as? String ?? "").contains("# 计划") && (card["plan"] as? String ?? "").contains("先写测试"),
                  "DG1 计划评审用计划卡、带上整份计划（kind=\(card["kind"] ?? "无")，plan=\(card["plan"] ?? "无")）")
            switch decision {
            case "allow":
                app.answerRequest(agent: "deepseek", reqId: live.req.reqId, requestId: id, body: ["decision": "allow", "mode": "bypassPermissions"])
                let reply = finish()
                let given = answers(responses("q-plan-1").last)
                check(given.count == 1 && given.first?["id"] as? String == "plan-review" && given.first?["selected"] as? [String] == ["Approve"] && given.first?["custom"] == nil,
                      "DG1 批准回 selected:[intent.approve]（\(given)）")
                check(reply?.reply == "approved" && closed(id, reqId: live.req.reqId), "DG1 批准后撤卡、这一轮照常结束（\(reply?.reply ?? "没结束")）")
            case "deny":
                app.answerRequest(agent: "deepseek", reqId: live.req.reqId, requestId: id, body: ["decision": "deny", "message": "先加一步回归测试"])
                let reply = finish()
                let given = answers(responses("q-plan-2").last)
                check(given.first?["selected"] as? [String] == [] && given.first?["custom"] as? String == "先加一步回归测试",
                      "DG1 「先改计划」回 custom 附上修改意见（\(given)）")
                check(reply?.reply == "feedback: 先加一步回归测试", "DG1 模型拿到修改意见（\(reply?.reply ?? "没结束")）")
            default:
                // 停止时等着的提问以 cancelled 作答：error 必须带 details，否则 dsh 回 bad-response、模型一直等
                live.locked { live.interrupt() }
                check(waitUntil({ !receipts("q-plan-3").isEmpty }), "DG1 停止时把评审以 cancelled 交回")
                let error = (responses("q-plan-3").last?["result"] as? [String: Any])?["error"] as? [String: Any]
                check(error?["code"] as? String == "cancelled" && error?["details"] as? [String: Any] != nil && error?["message"] is String
                      && receipts("q-plan-3").last?["accepted"] as? Bool == true,
                      "DG1 cancelled 的格式是 {ok:false,error:{code,message,details:{}}} 且被收下（\(error ?? [:])，回执 \(receipts("q-plan-3"))）")
                _ = finish()
            }
        }
    case "dg-receipt":
        // /api/respond 的回执：bad-response 时退成只带 custom 再交一次，还不收就把卡片重新摆出来；not-pending 时撤卡
        let (live, finish) = start(51, "receipt")
        check(waitUntil({ !cards("dshq-q-bad1").isEmpty }), "DG3 第一个提问出现卡片")
        app.answerRequest(agent: "deepseek", reqId: 51, requestId: "dshq-q-bad1", body: ["decision": "allow", "answers": ["导出成哪种格式？": "PDF"]])
        check(waitUntil({ receipts("q-bad1").count >= 2 }), "DG3 被拒（bad-response）后再交一次（回执 \(receipts("q-bad1"))）")
        let retry = answers(responses("q-bad1").last)
        check(retry.first?["selected"] as? [String] == [] && retry.first?["custom"] as? String == "PDF" && receipts("q-bad1").last?["accepted"] as? Bool == true,
              "DG3 第二次只带用户写的话（custom）、被收下（\(retry)）")
        check(waitUntil({ !cards("dshq-q-bad").isEmpty }), "DG3 第二个提问出现卡片")
        app.answerRequest(agent: "deepseek", reqId: 51, requestId: "dshq-q-bad", body: ["decision": "allow", "answers": ["再选一次？": "PNG"]])
        check(waitUntil({ cards("dshq-q-bad").count == 2 }), "DG3 两次都被拒时卡片重新摆出来（出现 \(cards("dshq-q-bad").count) 次，回执 \(receipts("q-bad"))）")
        let retriedParts = cards("dshq-q-bad").last?["answerParts"] as? [String:[String:Any]]
        check(retriedParts?["fmt"]?["selected"] as? [String] == ["PNG"], "本地回合重摆卡保留选择，实际 \(retriedParts ?? [:])")
        // 在别处答过、了结帧又没收到：交回去是 not-pending，撤卡、不再摆出来
        _ = app.dshServer.call("probe.forget", ["rpcId": "q-bad"])
        let before = cards("dshq-q-bad").count, closes = calls("onAgentRequestClosed").filter { $0["requestId"] as? String == "dshq-q-bad" }.count
        app.answerRequest(agent: "deepseek", reqId: 51, requestId: "dshq-q-bad", body: ["decision": "allow", "answers": ["再选一次？": "PNG"]])
        check(waitUntil({ receipts("q-bad").last?["reason"] as? String == "not-pending" }), "DG3 已在别处答过时回执是 not-pending")
        check(waitUntil { calls("onAgentRequestClosed").filter { $0["requestId"] as? String == "dshq-q-bad" }.count > closes }, "DG3 not-pending 时撤卡")
        check(cards("dshq-q-bad").count == before, "DG3 not-pending 时撤卡后不再摆出来（出现 \(cards("dshq-q-bad").count - before) 次）")
        live.receiveForTest(["type": "session/event", "event": ["type": "turn/end", "data": ["reason": ["kind": "completed"]]]])
        _ = finish()
    case "dg-stream":
        // 事件流内部出错（stream/error 后关掉那条 socket），dsh 进程还活着：只重连那条流，不结束服务
        let pid = (try? String(contentsOfFile: root + "/fake-dg-stream.pid", encoding: .utf8)) ?? ""
        var got: [String] = []; let gotLock = NSLock()
        let token = app.dshServer.listen("probe") { f in
            if f["type"] as? String == "question/requested" { gotLock.lock(); got.append(f["_rpcId"] as? String ?? ""); gotLock.unlock() }
        }
        func seen() -> [String] { gotLock.lock(); defer { gotLock.unlock() }; return got }
        // hunt6 longrun 第 5 条：每次都重连成功、其间没有新事件的断流不算「连续失败」，第六次也不能停掉健康的服务
        TestHooks.dshReconnectWait = { _, delay in min(delay, 0.05) }   // 连续断开会退避（见 dg-flap），这里不用真等
        defer { TestHooks.dshReconnectWait = nil }
        var readies = 0
        let readyToken = app.dshServer.listen("probe") { f in
            if f["type"] as? String == "_streamReady" { gotLock.lock(); readies += 1; gotLock.unlock() }
        }
        func readyCount() -> Int { gotLock.lock(); defer { gotLock.unlock() }; return readies }
        for round in 1...7 {
            let before = readyCount()
            _ = app.dshServer.call("probe.drop-mux")
            check(waitUntil({ readyCount() > before || !app.dshServer.isRunning }) && app.dshServer.isRunning,
                  "DG4 第 \(round) 次断流后重连成功、服务照常在跑")
        }
        let still = (try? String(contentsOfFile: root + "/fake-dg-stream.pid", encoding: .utf8)) ?? ""
        check(still == pid, "DG4 多次断流后仍是原来的 dsh")
        app.dshServer.unlisten("probe", readyToken)
        _ = app.dshServer.call("probe.request", ["rpcId": "q-s", "frame": ["type": "question/requested", "sessionId": "probe", "questions": [fmt]]])
        check(waitUntil({ seen() == ["q-s"] }), "DG4 断开前的提问已到")
        _ = app.dshServer.call("probe.drop-mux")
        Thread.sleep(forTimeInterval: 1.5)
        let now = (try? String(contentsOfFile: root + "/fake-dg-stream.pid", encoding: .utf8)) ?? ""
        check(app.dshServer.isRunning && now == pid, "DG4 一条事件流断了、dsh 还活着时服务照常在跑（在跑 \(app.dshServer.isRunning)）")
        _ = app.dshServer.call("probe.request", ["rpcId": "q-s2", "frame": ["type": "question/requested", "sessionId": "probe", "questions": [fmt]]])
        check(waitUntil({ seen().contains("q-s2") }), "DG4 重连后新的事件照常收到（\(seen())）")
        check(seen().filter { $0 == "q-s" }.count == 1, "DG4 重连时 dsh 重放的旧提问不再交第二次（\(seen())）")
        app.dshServer.unlisten("probe", token)
    case "dg-flap":
        // 正文流连得上、马上又断：重连间隔要指数退避（0.3 → 0.6 → … 封顶 5 秒），服务照常在跑；
        // 稳定一段时间或收到业务帧后退避回到 0.3 秒。实际只等很短，间隔由钩子记下
        let pid = (try? String(contentsOfFile: root + "/fake-dg-flap.pid", encoding: .utf8)) ?? ""
        var delays: [Double] = [], readies = 0, got: [String] = []
        let lock = NSLock()
        TestHooks.dshReconnectWait = { name, delay in
            if name == "events.mux" { lock.lock(); delays.append(delay); lock.unlock() }
            return 0.02
        }
        TestHooks.dshStreamStableAfter = 1
        let token = app.dshServer.listen("probe") { f in
            lock.lock(); defer { lock.unlock() }
            if f["type"] as? String == "_streamReady" { readies += 1 }
            if f["type"] as? String == "question/requested" { got.append(f["_rpcId"] as? String ?? "") }
        }
        func snapshot() -> (delays: [Double], readies: Int, got: [String]) { lock.lock(); defer { lock.unlock() }; return (delays, readies, got) }
        _ = app.dshServer.call("probe.flap", ["times": 12])
        _ = app.dshServer.call("probe.drop-mux")
        check(waitUntil({ snapshot().delays.count >= 13 && snapshot().readies >= 13 }), "DG5 连上马上断 12 次后重新连稳（间隔 \(snapshot().delays)，重连成功 \(snapshot().readies) 次）")
        let grown = snapshot().delays
        let expected = (0..<13).map { min(0.3 * pow(2, Double($0)), 5) }
        check(grown.count == 13 && zip(grown, expected).allSatisfy { abs($0 - $1) < 0.001 }, "DG5 重连间隔指数增长并封顶 5 秒，实际 \(grown)")
        let now = (try? String(contentsOfFile: root + "/fake-dg-flap.pid", encoding: .utf8)) ?? ""
        check(app.dshServer.isRunning && now == pid, "DG5 反复断开期间服务没被停（在跑 \(app.dshServer.isRunning)）")
        // 连稳超过 1 秒（测试里的稳定门槛）再断：退避回到起点
        Thread.sleep(forTimeInterval: 1.3)
        _ = app.dshServer.call("probe.drop-mux")
        check(waitUntil({ snapshot().delays.count == 14 && snapshot().readies >= 14 }), "DG5 稳定后断开照常重连")
        check(snapshot().delays.last.map { abs($0 - 0.3) < 0.001 } == true, "DG5 连稳一段时间后退避回到 0.3 秒，实际 \(snapshot().delays.last ?? -1)")
        // 再抖几次把间隔推高，然后收到一帧业务事件：退避同样回到起点
        TestHooks.dshStreamStableAfter = 100
        _ = app.dshServer.call("probe.flap", ["times": 3])
        _ = app.dshServer.call("probe.drop-mux")
        check(waitUntil({ snapshot().delays.count == 18 && snapshot().readies >= 18 }), "DG5 再抖 3 次后连稳（间隔 \(snapshot().delays)）")
        check(snapshot().delays.last.map { $0 > 1 } == true, "DG5 第二轮抖动间隔又涨上去，实际 \(snapshot().delays.last ?? -1)")
        _ = app.dshServer.call("probe.request", ["rpcId": "q-f", "frame": ["type": "question/requested", "sessionId": "probe", "questions": [fmt]]])
        check(waitUntil({ snapshot().got.contains("q-f") }), "DG5 业务帧到达")
        _ = app.dshServer.call("probe.drop-mux")
        check(waitUntil({ snapshot().delays.count == 19 }), "DG5 收到业务帧后断开照常重连")
        check(snapshot().delays.last.map { abs($0 - 0.3) < 0.001 } == true, "DG5 收到业务帧后退避回到 0.3 秒，实际 \(snapshot().delays.last ?? -1)")
        // q-f 还没答：dsh 每次重连都先推 probe 的 session/subscribed、再重放它。这些快照帧不算流在正常送事件，退避照样涨
        check(waitUntil({ snapshot().readies >= 19 }), "DG5 收到业务帧后重新连上")
        _ = app.dshServer.call("probe.flap", ["times": 4])
        _ = app.dshServer.call("probe.drop-mux")
        check(waitUntil({ snapshot().delays.count == 24 && snapshot().readies >= 24 }), "DG5 有待答提问时抖 4 次后连稳（间隔 \(snapshot().delays)）")
        let replayed = Array(snapshot().delays.suffix(5))
        check(zip(replayed, [0.6, 1.2, 2.4, 4.8, 5]).allSatisfy { abs($0 - $1) < 0.001 } && replayed.count == 5, "DG5 重连时 dsh 先推的 session/subscribed 和重放的待答提问不清零退避，实际 \(replayed)")
        check(snapshot().got.filter { $0 == "q-f" }.count == 1, "DG5 重放的待答提问只交一次（\(snapshot().got)）")
        check(app.dshServer.isRunning, "DG5 结束时服务仍在跑")
        app.dshServer.unlisten("probe", token)
        TestHooks.dshReconnectWait = nil; TestHooks.dshStreamStableAfter = nil
    case "dg-unattended":
        // dsh 自己开的一轮（后台任务唤醒、子智能体回报）里来问，App 没有回合在听：提示用户，点开会话弹卡，答复按 rpcId 交回
        _ = app.dshServer.call("probe.request", ["rpcId": "q-w", "frame": ["type": "question/requested", "sessionId": "probe", "questions": [fmt]]])
        check(waitUntil({ !cards("dshq-q-w", reqId: 0).isEmpty }), "DG2 没有回合在听时也把提问交给网页（\(calls("onAgentRequest"))）")
        let card = cards("dshq-q-w", reqId: 0).first ?? [:]
        check(card["conversationId"] as? String == "probe" && card["kind"] as? String == "question", "DG2 卡片带着会话编号，网页据此标「在等你回答」（\(card)）")
        check(awaitCallback(app, "onConversationLoaded") { app.loadDeepSeek(cid: "probe") } != nil, "DG2 点开会话及时载入")
        check(waitUntil({ cards("dshq-q-w", reqId: 0).count == 2 }), "DG2 点开会话后照常弹卡（出现 \(cards("dshq-q-w", reqId: 0).count) 次）")
        app.answerRequest(agent: "deepseek", reqId: 0, requestId: "dshq-q-w", body: ["decision": "allow", "answers": ["导出成哪种格式？": "PNG"]])
        check(waitUntil { str(cards("dshq-q-w", reqId: 0).last, "message").contains("503") }, "HTTP 503 后原卡可重试，实际出卡 \(cards("dshq-q-w", reqId: 0).count) 次")
        app.answerRequest(agent: "deepseek", reqId: 0, requestId: "dshq-q-w", body: ["decision": "allow", "answers": ["导出成哪种格式？": "PNG"]])
        let restoredParts = cards("dshq-q-w", reqId:0).last?["answerParts"] as? [String:[String:Any]]
        check(restoredParts?["fmt"]?["selected"] as? [String] == ["PNG"], "后台卡重摆保留选择，实际 \(restoredParts ?? [:])")
        check(waitUntil({ receipts("q-w").last?["accepted"] as? Bool == true }), "DG2 答复按记下的 rpcId 交回、被收下（\(responses("q-w"))）")
        check(answers(responses("q-w").last).first?["selected"] as? [String] == ["PNG"], "DG2 交回的是用户选的答案")
        check(waitUntil({ closed("dshq-q-w", reqId: 0) }), "DG2 答完撤卡")
        // 审批同理；之后用户在这个会话里发一句：开始听的回合接过挂着的审批，原来的提示撤掉
        _ = app.dshServer.call("probe.request", ["rpcId": "r-a", "frame": ["type": "approval/requested", "sessionId": "probe", "approvalId": "a-1",
                                                                            "toolName": "bash", "reason": "escalate sandbox to workspace-write: touch x"]])
        check(waitUntil({ !cards("dsh-a-1", reqId: 0).isEmpty }), "DG2 没有回合在听时审批也交给网页")
        check(cards("dsh-a-1", reqId: 0).first?["kind"] as? String == "permission" && (cards("dsh-a-1", reqId: 0).first?["detail"] as? String ?? "").contains("touch x"),
              "DG2 审批卡带原因")
        let (live, finish) = start(61, "after-wakeup")
        check(waitUntil({ !cards("dsh-a-1", reqId: 61).isEmpty }), "DG2 开始听这个会话的回合补上挂着的审批")
        check(closed("dsh-a-1", reqId: 0), "DG2 回合接过后撤掉没人听时的那张")
        app.answerRequest(agent: "deepseek", reqId: 61, requestId: "dsh-a-1", body: ["decision": "allow"])
        let reply = finish()
        let outcome = ((responses("r-a").last?["result"] as? [String: Any])?["value"] as? [String: Any])?["outcome"] as? String
        check(outcome == "allowed-once" && reply?.reply == "own answer", "DG2 审批交回后这一轮照常答完（\(outcome ?? "没交")，\(reply?.reply ?? "没结束")）")
        _ = live
        // 回合在听时来的提问，回合结束了 dsh 还在等：交回给「没人听」的提示，不悄悄挂着
        let token = app.dshServer.listen("probe") { _ in }
        _ = app.dshServer.call("probe.request", ["rpcId": "q-left", "frame": ["type": "question/requested", "sessionId": "probe", "questions": [fmt]]])
        check(waitUntil({ app.dshServer.waitingRequest("dshq-q-left") != nil }) && cards("dshq-q-left", reqId: 0).isEmpty, "DG2 有回合在听时不另外提示")
        app.dshServer.unlisten("probe", token)
        check(waitUntil({ !cards("dshq-q-left", reqId: 0).isEmpty }), "DG2 回合不听了、dsh 还在等时交给网页提示")
    case "dg-own-turn":
        // 这句话排在 dsh 自己开的一轮后面：那一轮的事件和 turn/end 不是这句话的回答，看到带本句调用编号的 user/message 才开始算
        let (_, finish) = start(71, "own")
        let reply = finish()
        let prompt = rows().first { $0["method"] as? String == "session.prompt" }
        check((prompt?["rpcId"] as? String ?? "").hasPrefix(dshAskPrefix), "DG5 提问用自己指定的调用编号发（\(prompt?["rpcId"] ?? "无")）")
        check(reply?.reply == "own answer", "DG5 这一轮的回答是这句话的，不是 dsh 自己开的那一轮的（\(reply?.reply ?? "没结束")）")
    default:
        check(false, "未知的 DG 场景 \(mode)")
    }
    check(testAsksEmpty(app), "DeepSeek 测试拥有的回答记录均已删除")
}
