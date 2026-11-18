// 离线回归：python3 tools/test-deepseek.py。只起 tools/fixtures/fake-dsh.py，不调用真实 CLI。
import Cocoa

private var deepSeekFailures = 0
private func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { deepSeekFailures += 1 } }
private func wait(_ test: () -> Bool, seconds: Double = 4) -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { if test() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return test()
}
func runDeepSeekTests(_ args: [String]) {
    let mode = args[0], root = args[1]
    let app = AppDelegate(); app.jsSink = { _, _ in }
    let fixture = FileManager.default.currentDirectoryPath + "/tools/fixtures/fake-dsh.py"
    var env = ProcessInfo.processInfo.environment; env["FIXTURE_MODE"] = mode
    let start = Date()
    let error = app.dshServer.ensure(executable: fixture, environment: env, cwd: root)
    check(error == nil, "\(mode): 假服务启动 \(error ?? "成功")")
    defer { app.dshServer.shutdown(); Thread.sleep(forTimeInterval: 0.2) }
    if mode == "stderr" || mode == "early-event" { check(Date().timeIntervalSince(start) < 4, "R02 启动不被日志或事件堵住"); exitAfterCleanup(app); return }
    guard error == nil else { exitAfterCleanup(app); return }
    func req(_ id: Int = 1, model: String = "", prompt: String = "probe", effort: String = "") -> AskRequest {
        AskRequest(agent: "deepseek", reqId: id, prompt: prompt, model: model, effort: effort, permissionMode: "read-only", workspace: root, conversationId: "probe")
    }
    func log() -> String { (try? String(contentsOfFile: root + "/rpc-" + mode + ".jsonl", encoding: .utf8)) ?? "" }
    func event(_ type: String, _ data: [String: Any] = [:]) -> [String: Any] { ["type":"session/event", "event":["type":type, "data":data]] }
    func end(_ live: DeepSeekLiveTurn) { live.receiveForTest(event("turn/end", ["reason":["kind":"completed"]])) }
    if mode == "history-pages" || mode == "history-cursor" {
        app.hooks.cliExecutable = fixture
        func calls() -> [[String: Any]] {
            log().split(separator: "\n").compactMap { app.jsonObject(String($0)) }.filter { $0["method"] as? String == "session.history" }
        }
        if mode == "history-cursor" {
            let history = app.readDeepSeekHistory(cid: "probe", pageLimit: 3)
            check(history.hasMore && history.error != nil, "C1 游标向新走时仍报告还有更早，并明确停止原因")
            check(calls().count == 2, "C1 第二页游标倒退即停止，不耗尽页数或无限循环")
        } else {
            func load(_ cid: String = "probe", limit: Int? = nil) -> [String: Any] {
                if let limit = limit { app.procLock.lock(); app.historyLimits[cid] = limit; app.procLock.unlock() }
                let done = DispatchSemaphore(value: 0); var result: [String: Any] = [:]
                app.jsSink = { name, payload in if name == "onConversationLoaded" { result = payload; done.signal() } }
                app.loadDeepSeek(cid: cid)
                check(done.wait(timeout: .now() + 15) == .success, "C1 历史载入及时返回")
                app.jsSink = { _, _ in }
                return result
            }
            let first = load()
            check(first["hasMore"] as? Bool == true && calls().count == 60, "C1 默认读取60页后如实带出hasMore")
            let context = first["context"] as? [String: Any]
            check(context?["used"] as? Int == 12 && context?["max"] as? Int == 100, "DeepSeek 使用最新页投影的预计输入与上限")
            check((context?["parts"] as? [[String: Any]])?.compactMap { $0["tokens"] as? Int } == [5, 7], "DeepSeek 恢复投影明细")
            let priorCalls = calls().count
            let earlier = load(limit: 5101)
            let messages = earlier["messages"] as? [[String: Any]] ?? []
            check(messages.count == 5101 && messages.first?["text"] as? String == "history-1", "C1 显示更早能越过60页和5000条")
            check(earlier["historyPrepended"] as? Int == 301, "C1 只记录本次追加的旧消息数量，供进行中的回答修正位置")
            check(earlier["hasMore"] as? Bool == false, "C1 到真正开头后才清除hasMore")
            let continuation = Array(calls().dropFirst(priorCalls))
            check(continuation.count == 4 && (continuation.first?["payload"] as? [String: Any])?["beforeSeq"] as? Int == 302, "C1 从已缓存游标续取，不重复最前60页")
            _ = app.dshServer.call("probe.history-total", ["total": 5103])
            let synced = load()
            let syncedMessages = synced["messages"] as? [[String: Any]] ?? []
            check(syncedMessages.count + (synced["omitted"] as? Int ?? 0) == 5103 && syncedMessages.last?["text"] as? String == "history-5103", "C1 同步新消息仍保留已读取的旧历史")
            check(synced["historyPrepended"] as? Int == 0, "C1 同步新尾部不前移进行中回答的位置")
            let other = load("other")
            check((other["messages"] as? [[String: Any]])?.count == 2, "C1 切换会话不会串用分页缓存")
            _ = app.dshServer.call("probe.history-total", ["total": 5101])
            let direct = load(limit: 5101)
            check((direct["messages"] as? [[String: Any]])?.first?["text"] as? String == "history-1", "C1 深处搜索首次打开按显式limit续取到命中")
            for (cid, expected) in [("active", true), ("ended", false)] {
                let state = load(cid)["lastTurn"] as? [String: Any]
                check(state?["running"] as? Bool == expected, "DeepSeek 当前回合按 turn/start、turn/end 明确运行状态")
            }
        }
        exitAfterCleanup(app); return
    }
    if mode == "search" {
        app.hooks.cliExecutable = fixture
        func search(_ query: String, timeout: TimeInterval = 10) -> [String: Any] {
            let done = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]
            app.jsSink = { name, payload in
                if name == "onConversationsSearched", payload["complete"] as? Bool != false {
                    result = payload; done.signal()
                }
            }
            app.searchConversations(agent: "deepseek", query: query)
            check(done.wait(timeout: .now() + timeout) == .success, "A DeepSeek 搜索有最终回调")
            app.jsSink = { _, _ in }
            return result
        }
        check(search("original-visible-needle")["ids"] as? [String] == ["probe"], "A 服务历史正文命中")
        check(search("protocol-only-needle")["ids"] as? [String] == [], "A 协议字段不命中")
        _ = app.dshServer.call("probe.recover")
        check(search("original-visible-needle")["ids"] as? [String] == [], "A 服务会话变更使旧缓存失效")
        check(search("changed-visible-needle")["ids"] as? [String] == ["probe"], "A 服务变更后的正文可搜")
        app.dshServer.shutdown()
        app.hooks.cliExecutable = root + "/missing-dsh"
        let t0 = Date()
        check(!(search("changed-visible-needle", timeout: 40)["unavailable"] as? String ?? "").isEmpty, "A 服务不可用明确报告这一位没搜")
        // dsh 一启动就退出（这里是程序不存在）时立刻报错，不等满 30 秒的端口超时
        check(Date().timeIntervalSince(t0) < 10, "A dsh 起不来时不等满端口超时（\(Int(Date().timeIntervalSince(t0))) 秒）")
        exitAfterCleanup(app); return
    }
    let live = DeepSeekLiveTurn(app: app, req: req(model: mode == "configure-fail" || mode == "effort-fail" ? "bad" : "", prompt: mode == "compact" ? "/compact" : "probe", effort: mode == "effort-fail" ? "max" : ""))
    defer { live.input.abandon() }
    if mode == "fallback" {
        // 兜底时长调成 5 秒，各处留足余量：真等 30 秒又只留一两秒余量的话，慢机器（CI）上会卡不准
        live.idleFallback = 5
        live.receiveForTest(["type":"host/session-status", "running":true])
        live.receiveForTest(["type":"host/session-status", "running":false])
        Thread.sleep(forTimeInterval: 2)
        live.receiveForTest(event("turn/start", ["turn":1]))   // 第 2 秒来了事件：兜底从这里重新算，到第 7 秒
        Thread.sleep(forTimeInterval: 3.5)                      // 第 5.5 秒：原来的 5 秒已过，顺延之后还没到
        check(!live.finishedForTest, "R01 正文/事件使 30 秒兜底顺延")
        check(wait({ live.finishedForTest }, seconds: 15), "R01 静默满 30 秒才兜底结束")
    } else if mode == "transaction" {
        let a = DeepSeekLiveTurn(app:app, req:req(11, model:"model-a", prompt:"probe-a"))
        let b = DeepSeekLiveTurn(app:app, req:req(12, model:"model-b", prompt:"probe-b"))
        let done = DispatchGroup()
        done.enter(); DispatchQueue.global().async { _ = withTestAsk(app, a.req.key) { a.run(ready: { nil }) }; done.leave() }
        check(wait { log().contains("model-a") }, "C-R08 第一轮配置已进入服务")
        done.enter(); DispatchQueue.global().async { _ = withTestAsk(app, b.req.key) { b.run(ready: { nil }) }; done.leave() }
        check(wait { log().contains("probe-a") && log().contains("probe-b") }, "C-R08 两轮提交均完成")
        let rows = log().split(separator:"\n").compactMap { app.jsonObject(String($0)) }
        let prompts = rows.filter { $0["method"] as? String == "session.prompt" }
        check(prompts.count == 2 && prompts.allSatisfy { row in
            let payload = row["payload"] as? [String:Any] ?? [:]
            let text = (payload["content"] as? [[String:Any]])?.last?["text"] as? String ?? ""
            return row["observedModel"] as? String == text.replacingOccurrences(of:"probe-", with:"model-")
        }, "C-R08 每轮 prompt 都使用自己的配置")
        end(a); end(b)
        check(done.wait(timeout:.now()+5) == .success, "C-R08 两轮均可结束")
        a.input.abandon(); b.input.abandon()
    } else if mode == "state" {
        live.receiveForTest(["type":"host/session-status", "running":true])
        live.receiveForTest(["type":"host/session-status", "running":false])
        Thread.sleep(forTimeInterval: 2.2)
        check(!live.finishedForTest, "R01 turn/end 迟到数秒仍等待")
        live.receiveForTest(event("assistant/message", ["turn":1,"step":1,"message":["content":[["type":"text","text":"late answer"]]]]))
        end(live)
        check(live.finishedForTest && live.replyForTest.reply == "late answer", "R01 迟到正文完整且以 turn/end 结束")
        let stopped = DeepSeekLiveTurn(app: app, req: req(2))
        stopped.receiveForTest(["type":"host/session-status","running":true]); stopped.markStopping()
        stopped.receiveForTest(["type":"host/session-status","running":false])
        check(wait({ stopped.finishedForTest }, seconds: 2), "R01 停止后短等待兜底")
        stopped.input.abandon()
        let mux = [event("turn/start", ["turn":1]), event("assistant/message", ["turn":1,"step":1,"message":["content":[["type":"text","text":"complete"]]]]), event("turn/end", ["reason":["kind":"completed"]])]
        let host: [[String:Any]] = [["type":"host/session-status","running":true],["type":"host/session-status","running":false]]
        func order(_ a: Int, _ b: Int, _ frames: [[String:Any]]) {
            if a == mux.count && b == host.count {
                let t = DeepSeekLiveTurn(app: app, req: req(3)); frames.forEach { t.receiveForTest($0) }
                check(t.finishedForTest && t.replyForTest.reply == "complete", "R01 正常/双流交错 \(frames.map { $0["type"]! })")
                t.input.abandon(); return
            }
            if a < mux.count { order(a+1,b,frames+[mux[a]]) }
            if b < host.count { order(a,b+1,frames+[host[b]]) }
        }
        order(0,0,[])
    } else if mode == "slow-approval" {
        live.pending.allowAll("read")
        DispatchQueue.global().async { live.receiveForTest(["type":"approval/requested","approvalId":"a","_rpcId":"r","toolName":"read"]) }
        check(wait { log().contains("client-response") }, "R03 自动批准已在途")
        let at = Date(); live.locked { live.interrupt() }
        check(Date().timeIntervalSince(at) < 0.3, "R03 慢 respond 不阻塞停止锁")
        Thread.sleep(forTimeInterval: 2.1)
    } else if mode == "concurrent-config" {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { app.dshConfigure("probe", req(model:"model-a"), isNew:false); done.signal() }
        check(wait { log().contains("model-a") }, "C-R08 A 配置在途")
        app.dshConfigure("probe", req(model:"model-b"), isNew:false)
        check(done.wait(timeout:.now()+4) == .success, "C-R08 并行配置完成")
        let model = (app.dshServer.call("probe.state").value as? [String:Any])?["model"] as? String
        check(app.dshApplied["probe"]?.hasPrefix((model ?? "missing") + "|") == true, "C-R08 缓存与服务最终配置一致")
        app.dshConfigure("probe", req(model:"model-a"), isNew:false)
        check((app.dshServer.call("probe.state").value as? [String:Any])?["model"] as? String == "model-a", "C-R08 重选 A 确实生效")
    } else {
        let done = DispatchSemaphore(value: 0); var result: AgentReply?
        var states: [String] = []; let stateLock = NSLock()
        app.jsSink = { name, p in if name == "onAgentSteer" { stateLock.lock(); states.append(p["state"] as? String ?? ""); stateLock.unlock() } }
        DispatchQueue.global().async { result = withTestAsk(app, live.req.key) { live.run(ready: { nil }) }; done.signal() }
        if mode == "effort-fail" {   // 模型不认这一档强度：不带强度再设一次，照常提问，不报错
            check(wait { log().contains("session.prompt") }, "强度被拒后不带强度重设，照常提问")
            Thread.sleep(forTimeInterval:0.3); end(live)
            check(done.wait(timeout:.now()+5) == .success, "强度降级后这一轮正常结束")
            check(result?.reply.contains("设置失败") != true, "强度降级不算配置失败")
        } else if ["configure-fail", "permission-fail"].contains(mode) {
            check(wait { log().contains(mode == "permission-fail" ? "/permission" : "session.selectModel") }, "R07 配置失败已触发")
            Thread.sleep(forTimeInterval:0.3); end(live)
            check(done.wait(timeout:.now()+5) == .success, "R07 错误可返回")
            check(!log().contains("session.prompt") && result?.reply.hasPrefix("⚠️") == true, "R07 明确失败阻止提问并提示重试")
            check(app.dshApplied["probe"] == nil, "R07 配置失败不缓存")
            _ = app.dshServer.call("probe.recover")
            app.dshConfigure("probe", req(model:"bad"), isNew:false)
            check(app.dshApplied["probe"]?.hasPrefix("bad|") == true, "R07 故障消除后同设置可重试")
        } else if mode == "compact" {
            check(wait { log().contains("/compact") }, "R06 compact 在途")
            live.locked { live.interrupt() }
            check(done.wait(timeout:.now()+6) == .success && result?.cancelled == true, "R06 停止后的 compact 返回 cancelled")
            check(log().components(separatedBy:"session.cancel").count >= 3, "R06 在途返回补 cancel")
        } else {
            check(wait { log().contains("session.prompt") }, "R04 初始提问已发")
            live.receiveForTest(["type":"host/session-status","running":true])
            if mode == "cancel-attachment" {
                let image = root + "/attachment.png"; try! Data(repeating:65,count:3_000_000).write(to: URL(fileURLWithPath:image))
                live.locked {
                    check(live.steer("late", images:[image], id:"late"), "R04 接受后台附件准备")
                    // 持锁期间先停止，让真正发出的前置检查必然看到单调停止状态。
                    live.interrupt()
                }
            } else {
                check(live.locked { live.steer("late", images:[], id:"late") }, "R04 接受 steer")
                check(wait { log().contains("steer") }, "R04 steer 在途")
                live.locked { live.interrupt() }
            }
            Thread.sleep(forTimeInterval:1.5)
            stateLock.lock(); let sent = states.contains("sent"); stateLock.unlock()
            check(!sent, "R04 停止后不回报 sent")
            if mode == "cancel-attachment" { check(!log().contains("steer"), "R04 附件准备后停止不再提交") }
            else { check(log().components(separatedBy:"session.cancel").count >= 3, "R04 在途 steer 返回补 cancel") }
            end(live); check(done.wait(timeout:.now()+5) == .success && result?.cancelled == true, "R04 本轮取消返回")
        }
    }
    check(testAsksEmpty(app), "DeepSeek 测试拥有的回答记录均已删除")
    exitAfterCleanup(app)
}
private func exitAfterCleanup(_ app: AppDelegate) {
    app.dshServer.shutdown(); Thread.sleep(forTimeInterval: 0.3)
    print("DeepSeek failures=\(deepSeekFailures)"); exit(deepSeekFailures == 0 ? 0 : 1)
}
