// 离线回归：python3 tools/test-deepseek.py。只起 tools/fixtures/fake-dsh.py，不调用真实 CLI。
import Cocoa

func runDeepSeekTests(_ args: [String]) {
    let mode = args[0], root = args[1]
    let app = AppDelegate(); app.hooks.jsSink = { _, _ in }
    let fixture = FileManager.default.currentDirectoryPath + "/tools/fixtures/fake-dsh.py"
    var env = ProcessInfo.processInfo.environment; env["FIXTURE_MODE"] = mode
    if mode == "start-fail" {
        let why = app.dshServer.ensure(executable: fixture, environment: env, cwd: root) ?? ""
        let shown = why.replacingOccurrences(of: "\n", with: "⏎").prefix(200)
        check(why.contains("YAMLException: missed comma") && why.contains("/fixture/dshhome/cordis.patch.yml") && why.contains("(2:6)"),
              "DH2 启动失败提示保留原因行和配置位置（\(shown)）")
        check(why.contains("Node.js v26.11.1"), "DH2 启动失败提示仍附上 stderr 最后一段")
        // 列表经 dshReady 以主目录为 cwd 启动服务；假服务在写任何文件之前就退出
        setenv("FIXTURE_MODE", mode, 1); app.hooks.cliExecutable = fixture
        let reported = awaitCallback(app, "onConversationsListed") { app.listDeepSeek() }
        check(reported != nil, "DH2 历史列表及时回报")
        let listed = reported ?? [:]
        check((listed["unavailable"] as? String ?? "").contains("YAMLException"), "DH2 服务起不来时列表带出读取失败原因（\(listed["unavailable"] ?? "无")）")
        check(listed["items"] == nil, "DH2 读取失败不发空列表覆盖上次结果（items=\(listed["items"] ?? "无")）")
        exitAfterCleanup(app); return
    }
    TestHooks.dshSessionsRoot = root + "/sessions"
    let start = Date()
    let error = app.dshServer.ensure(executable: fixture, environment: env, cwd: root)
    check(error == nil, "\(mode): 假服务启动 \(error ?? "成功")")
    defer { app.dshServer.shutdown(); Thread.sleep(forTimeInterval: 0.2) }
    // 被堵住时 ensure 自己会在期限到了以后报错（30 秒没报端口、10 秒事件流没握上手），所以「启动成功」本身就说明没被堵住。
    // 不再卡挂钟时间：CI 的慢机器上这两个模式整段要将近 9 秒（本机 0.5 秒），卡 4 秒、8 秒都误报过
    if mode == "stderr" || mode == "early-event" { check(error == nil, "R02 启动不被日志或事件堵住（\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒）"); exitAfterCleanup(app); return }
    guard error == nil else { exitAfterCleanup(app); return }
    if mode == "balance-home" {
        guard URL(fileURLWithPath: app.home).resolvingSymlinksInPath() == URL(fileURLWithPath: root).resolvingSymlinksInPath() else {
            check(false, "额度夹具必须使用临时主目录"); exitAfterCleanup(app); return
        }
        let port = try! String(contentsOfFile: root + "/balance-port", encoding: .utf8)
        for (folder, account) in [(app.home + "/.dsh", "default"), (DshServer.dataRoot, "selected")] {
            try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try! "baseURL: http://127.0.0.1:\(port)/\(account)\napiKeyEnv: FIXTURE_BALANCE_KEY".write(toFile: folder + "/settings.yaml", atomically: true, encoding: .utf8)
            try! "FIXTURE_BALANCE_KEY: \(account)".write(toFile: folder + "/.credentials.yaml", atomically: true, encoding: .utf8)
        }
        app.loadUsage(agent:"deepseek", force:true)
        waitUntil(runLoop: true) { app.procLock.lock(); defer { app.procLock.unlock() }; return app.usageLoading.isEmpty }
        app.procLock.lock(); let value = app.usageCache["deepseek"]?.items.first?["text"] as? String; app.procLock.unlock()
        check(value == "¥22.00", "自定义账户余额实际为 \(value ?? "未查到")")
        check(dshReadableError("invalid key", code:"AUTH").contains(DshServer.dataRoot + "/.credentials.yaml"), "密钥提示指向当前账户")
        exitAfterCleanup(app); return
    }
    if mode.hasPrefix("dg-") { runDeepSeekRequestTests(app, mode: mode, root: root); exitAfterCleanup(app); return }
    func req(_ id: Int = 1, model: String = "", prompt: String = "probe", effort: String = "") -> AskRequest {
        AskRequest(agent: "deepseek", reqId: id, prompt: prompt, model: model, effort: effort, permissionMode: "read-only", workspace: root, conversationId: "probe")
    }
    func log() -> String { (try? String(contentsOfFile: root + "/rpc-" + mode + ".jsonl", encoding: .utf8)) ?? "" }
    func event(_ type: String, _ data: [String: Any] = [:]) -> [String: Any] { ["type":"session/event", "event":["type":type, "data":data]] }
    func end(_ live: DeepSeekLiveTurn) { live.receiveForTest(event("turn/end", ["reason":["kind":"completed"]])) }
    if mode == "completed-lost" {
        let live = DeepSeekLiveTurn(app:app, req:req())
        let done = DispatchSemaphore(value:0)
        var result: AgentReply?
        DispatchQueue.global().async {
            result = withTestAsk(app, live.req.key) { live.run(ready:{ nil }) }; done.signal()
        }
        check(waitUntil { live.finishedForTest }, "事件流已处理本轮结束")
        _ = app.dshServer.call("probe.release")
        check(waitSignal(done) && result?.reply == "已确认的完整回答",
              "回执中断仍显示确认的正文，实际为 \(result?.reply ?? "未结束")")
        live.input.abandon(); exitAfterCleanup(app); return
    }
    if mode == "cancel-held" || mode == "cancel-idle" {
        let acknowledged = DispatchSemaphore(value:0)
        app.hooks.dshCancelAcknowledged = { acknowledged.signal() }
        app.hooks.dshIdleFinishScheduled = { _, expire in expire() }
        let live = DeepSeekLiveTurn(app:app, req:req())
        let consumed = DispatchSemaphore(value:0), done = DispatchSemaphore(value:0)
        app.hooks.dshPromptConsumed = { consumed.signal() }
        var result: AgentReply?
        DispatchQueue.global().async {
            result = withTestAsk(app, live.req.key) { live.run(ready:{ nil }) }; done.signal()
        }
        check(waitSignal(consumed), "服务已接手本轮")
        live.locked { live.interrupt() }
        let finished = waitSignal(done)
        check(finished && result?.cancelled == true, "已确认取消在放行原回执前收尾，实际结束=\(finished)")
        check(result?.restoreDraft == false, "服务已接手的追问停止后不退回草稿")
        _ = app.dshServer.call("probe.release")
        if !finished { _ = waitSignal(done) }
        if mode == "cancel-idle" {
            check(waitSignal(acknowledged), "服务已确认本次取消")
            app.hooks.cliExecutable = fixture
            var page: [String:Any] = [:]
            app.hooks.jsSink = { name,data in if name == "onConversationLoaded" { page = data } }
            app.loadDeepSeek(cid:"probe"); app.deepseekQueue.sync {}
            let running = (page["lastTurn"] as? [String:Any])?["running"] as? Bool
            let outcome = str((page["messages"] as? [[String:Any]])?.last,"outcome")
            check(running == false && outcome == "interrupted", "确认停止但缺少结束事件，重开运行=\(String(describing:running))，结局=\(outcome)")
            check(page["historyError"] == nil, "本机已确认的停止不当成另一实例的状态，实际提示=\(page["historyError"] ?? "无")")
            _ = app.dshServer.call("probe.recover")
            app.loadDeepSeek(cid:"probe"); app.deepseekQueue.sync {}
            check((page["lastTurn"] as? [String:Any])?["running"] as? Bool == true, "新一轮不能借用上次的取消")
        }
        live.input.abandon(); exitAfterCleanup(app); return
    }
    if mode == "cancel-first" {
        app.hooks.cliExecutable = fixture
        app.hooks.dshSessionCreated = { app.cancel(agent: "deepseek", reqId: 71) }
        let done = DispatchSemaphore(value: 0)
        var bound = false, reply: [String: Any] = [:]
        app.hooks.jsSink = { name, data in
            if name == "onAgentConversation" { bound = true }
            if name == "onAgentResponse" { reply = data; done.signal() }
        }
        app.ask(AskRequest(agent:"deepseek", reqId:71, prompt:"保留首问", model:"", effort:"", permissionMode:"read-only", workspace:root, conversationId:""))
        check(waitSignal(done), "新会话提交前停止会及时收尾")
        check(!bound && str(reply,"conversationId").isEmpty && reply["restoreDraft"] as? Bool == true && !log().contains("session.prompt"),
              "未提交首问退回新草稿，实际绑定=\(bound)、编号=\(str(reply,"conversationId"))、退回=\(reply["restoreDraft"] ?? false)")
        app.hooks.dshSessionCreated = nil
        // 已有会话的追问在调 session.prompt 之前停止：dsh 记录里没有它，同样退回（原会话的）草稿
        let follow = DispatchSemaphore(value: 0)
        var followReply: [String: Any] = [:]
        app.hooks.jsSink = { name, data in if name == "onAgentResponse" { followReply = data; follow.signal() } }
        app.hooks.liveRegistered = { _, _ in app.cancel(agent: "deepseek", reqId: 72) }
        app.ask(AskRequest(agent:"deepseek", reqId:72, prompt:"保留追问", model:"", effort:"", permissionMode:"read-only", workspace:root, conversationId:"probe"))
        check(waitSignal(follow), "已有会话提交前停止会及时收尾")
        app.hooks.liveRegistered = nil
        check(str(followReply,"conversationId") == "probe" && followReply["restoreDraft"] as? Bool == true && followReply["cancelled"] as? Bool == true && !log().contains("session.prompt"),
              "未提交的追问退回原会话草稿，实际编号=\(str(followReply,"conversationId"))、退回=\(followReply["restoreDraft"] ?? false)、已提交=\(log().contains("session.prompt"))")
        exitAfterCleanup(app); return
    }
    // 新对话的首问：dsh 明确拒收（建好空会话后拒绝模型设置、拒收图片或日志盘满）时它不留这个空会话，侧栏也不列，
    // 网页不能绑到它上面，要按新对话把原文和附件退回原项目的草稿；回执丢了的可能已经收下，照旧绑定并提示核对；收下的照常绑定
    func firstAsk(_ ask: AskRequest, bindsTo expected: String, _ what: String) {
        app.hooks.cliExecutable = fixture
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var bound = "", reply: [String: Any] = [:]
        app.hooks.jsSink = { name, data in
            lock.lock(); defer { lock.unlock() }
            if name == "onAgentConversation" { bound = str(data, "conversationId") }
            if name == "onAgentResponse" { reply = data; done.signal() }
        }
        app.ask(ask)
        check(waitSignal(done), "\(what)：首问及时收尾")
        lock.lock(); defer { lock.unlock() }
        check(bound == expected && str(reply, "conversationId") == expected,
              "\(what)：会话编号应为「\(expected)」，实际绑定=\(bound)、回执=\(str(reply, "conversationId"))、回复=\(str(reply, "reply").prefix(80))")
        app.hooks.jsSink = { _, _ in }
    }
    if mode == "configure-fail" {
        firstAsk(AskRequest(agent:"deepseek", reqId:93, prompt:"新对话首问", model:"bad", effort:"", permissionMode:"read-only", workspace:root, conversationId:""),
                 bindsTo: "", "新会话设置模型被拒")
    }
    if mode.hasPrefix("image-submit-") {
        TestHooks.dshAttachmentRoot = root + "/attachments"
        defer { TestHooks.dshAttachmentRoot = nil }
        app.hooks.sentImagesDir = root + "/restored/"
        var ask = req()
        let image = root + "/photo.png"
        try! Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: URL(fileURLWithPath: image))
        ask.images = [image]
        if mode == "image-submit-unsupported" {
            let second = root + "/带\n换行.png"
            try! FileManager.default.copyItem(atPath:image, toPath:second)
            // Flash 拒绝的图片块已经转为 JPEG，改发路径时模型读到的仍是 TIFF 文件。
            let tiff = root + "/原图.tiff"
            try! solidImage(64,32,rgb:(0,0,1),type:"public.tiff")!.write(to:URL(fileURLWithPath:tiff))
            ask.images += [second,tiff]
        }
        var first = AskRequest(agent:"deepseek", reqId:94, prompt:"新对话带图首问", model:"", effort:"", permissionMode:"read-only", workspace:root, conversationId:"")
        first.images = ask.images
        let accepted = ["image-submit-lost", "image-submit-unsupported"].contains(mode)
        firstAsk(first, bindsTo: accepted ? "probe" : "", "新会话带图首问（\(mode)）")
        let promptsBefore = log().split(separator: "\n").count
        let live = DeepSeekLiveTurn(app: app, req: ask)
        let result = withTestAsk(app, ask.key) { live.run(ready: { nil }) }
        live.input.abandon()
        let calls = log().split(separator: "\n").dropFirst(promptsBefore).compactMap { app.jsonObject($0) }.filter { str($0, "method") == "session.prompt" }
        if mode == "image-submit-path-full" {
            let files = (try? FileManager.default.contentsOfDirectory(atPath:root + "/attachments/DeepSeek附件")) ?? []
            check(calls.count == 2 && result.reply.contains("ENOSPC") && files.isEmpty, "路径请求明确失败后清掉原图，剩余=\(files.count)")
            check(result.restoreDraft && result.conversationId == "probe", "dsh 明确拒收的追问退回原会话草稿")
            exitAfterCleanup(app); return
        }
        let fallback = mode == "image-submit-unsupported"
        check(calls.count == (fallback ? 2 : 1), "B7 仅明确拒图才重发（实际请求 \(calls.count)）")
        if fallback, let call = calls.last, let payload = call["payload"] as? [String: Any] {
            check(result.turn?["turnKey"] as? String == str(call,"rpcId"), "带图改发路径后改动仍属原提问调用")
            let data: [String: Any] = ["source":["kind":"user","rpcId":str(call,"rpcId")], "content":payload["content"] ?? []]
            let rows: [[String: Any]] = [["event":["type":"user/message","data":data]]]
            let original = try! Data(contentsOf:URL(fileURLWithPath:image))
            try! Data("覆盖后的内容".utf8).write(to:URL(fileURLWithPath:image))
            var changed = dshTurns(rows)
            app.attachChatImages(&changed,payload:["agent":"deepseek","conversationId":"probe","cwd":root])
            let ref = (changed.first?["images"] as? [[String:Any]])?.first?["ref"] as? [String:Any]
            let retry = ref.flatMap(app.restoredImagePath).flatMap { FileManager.default.contents(atPath:$0) }
            check(retry == original, "路径回退覆盖后重试仍是发送时的图，实际字节数=\(retry?.count ?? 0)")
            try! FileManager.default.removeItem(atPath: image)
            var turns = dshTurns(rows)
            app.attachChatImages(&turns, payload:["agent":"deepseek","conversationId":"probe","cwd":root])
            let pics = turns.first?["images"] as? [[String: Any]] ?? []
            if let tiff = ask.images.last, let ref = pics.last?["ref"] as? [String:Any] {
                check(app.chatImageOriginal(ref) == FileManager.default.contents(atPath:tiff), "Flash 路径读到的 TIFF 与历史原图逐字节相同")
            } else { check(false,"Flash 路径回退保留 TIFF 的引用") }
            check(str(turns.first,"text") == ask.prompt && pics.map { str($0,"path") } == ask.images && pics.first?["ref"] != nil,
                  "路径回退重开保留原问和已移走的附件，实际正文=\(str(turns.first,"text"))，附件=\(pics.count)")
        }
        let expected = fallback ? "路径已收到" : (mode == "image-submit-storage" ? "ENOSPC" : "发送状态待确认")
        check(result.reply.contains(expected), "B7 显示真实发送结果（\(result.reply)）")
        // 明确拒收的才退回；回执丢了的 dsh 可能已经收下，照旧提示核对
        eq(result.restoreDraft, mode == "image-submit-storage", "B7 只有明确拒收的追问退回草稿")
        exitAfterCleanup(app); return
    }
    if ["history-pages", "history-cursor", "disk-moved", "search", "deleted", "list-external"].contains(mode) { runDeepSeekHistoryTests(app, args: args, mode: mode, root: root, fixture: fixture, env: env); exitAfterCleanup(app); return }
    let live = DeepSeekLiveTurn(app: app, req: req(model: mode == "configure-fail" || mode == "effort-fail" ? "bad" : "", prompt: mode == "compact" ? "/compact" : "probe", effort: mode == "effort-fail" ? "max" : ""))
    defer { live.input.abandon() }
    if mode == "fallback" {
        let timers = DshFinishTimers(app)
        live.receiveForTest(["type":"host/session-status", "running":true])
        live.receiveForTest(["type":"host/session-status", "running":false])
        let beforeEvent = timers.all.count
        live.receiveForTest(event("turn/start", ["turn":1]))   // 静默中来了事件：兜底从这里重新算
        let afterEvent = timers.all
        // 只看「旧的到点不结束」测不出顺延被去掉：那时只有一个定时器，dropLast 什么都不触发。所以先认定来事件后确实重新安排了一次
        check(afterEvent.count == beforeEvent + 1, "R01 正文/事件使 30 秒兜底顺延（来事件前 \(beforeEvent) 次安排，之后 \(afterEvent.count) 次）")
        afterEvent.dropLast().forEach { $0.expire() }          // 来事件之前安排的兜底到点了
        check(!live.finishedForTest, "R01 来事件之前安排的兜底到点不结束")
        check(timers.last?.delay == live.idleFallback, "R01 顺延后仍按静默 30 秒兜底（实际 \(timers.last?.delay ?? -1) 秒）")
        timers.last?.expire()
        check(live.finishedForTest, "R01 静默满 30 秒才兜底结束")
    } else if mode == "transaction" {
        let a = DeepSeekLiveTurn(app:app, req:req(11, model:"model-a", prompt:"probe-a"))
        let b = DeepSeekLiveTurn(app:app, req:req(12, model:"model-b", prompt:"probe-b"))
        let done = DispatchGroup()
        done.enter(); DispatchQueue.global().async { _ = withTestAsk(app, a.req.key) { a.run(ready: { nil }) }; done.leave() }
        check(waitUntil { log().contains("model-a") }, "C-R08 第一轮配置已进入服务")
        done.enter(); DispatchQueue.global().async { _ = withTestAsk(app, b.req.key) { b.run(ready: { nil }) }; done.leave() }
        check(waitUntil { log().contains("probe-a") && log().contains("probe-b") }, "C-R08 两轮提交均完成")
        let rows = log().split(separator:"\n").compactMap { app.jsonObject(String($0)) }
        let prompts = rows.filter { $0["method"] as? String == "session.prompt" }
        check(prompts.count == 2 && prompts.allSatisfy { row in
            let payload = row["payload"] as? [String:Any] ?? [:]
            let text = (payload["content"] as? [[String:Any]])?.last?["text"] as? String ?? ""
            return row["observedModel"] as? String == text.replacingOccurrences(of:"probe-", with:"model-")
        }, "C-R08 每轮 prompt 都使用自己的配置")
        end(a); end(b)
        check(waitSignal(done), "C-R08 两轮均可结束")
        a.input.abandon(); b.input.abandon()
    } else if mode == "state" {
        let timers = DshFinishTimers(app)
        live.receiveForTest(["type":"host/session-status", "running":true])
        live.receiveForTest(["type":"host/session-status", "running":false])
        check(timers.last?.delay == live.idleFallback, "R01 没点停止时按静默 30 秒兜底，不用停止的短等待（实际 \(timers.last?.delay ?? -1) 秒）")
        check(!live.finishedForTest, "R01 turn/end 迟到数秒仍等待")
        live.receiveForTest(event("assistant/message", ["turn":1,"step":1,"message":["content":[["type":"text","text":"late answer"]]]]))
        end(live)
        check(live.finishedForTest && live.replyForTest.reply == "late answer", "R01 迟到正文完整且以 turn/end 结束")
        let stopped = DeepSeekLiveTurn(app: app, req: req(2))
        stopped.receiveForTest(["type":"host/session-status","running":true]); stopped.markStopping()
        stopped.receiveForTest(["type":"host/session-status","running":false])
        check(timers.last?.delay == 1.5, "R01 停止后按 1.5 秒短等待兜底（实际 \(timers.last?.delay ?? -1) 秒）")
        timers.last?.expire()
        check(stopped.finishedForTest, "R01 停止后短等待到点就结束")
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
        check(waitUntil { log().contains("client-response") }, "R03 自动批准已在途")
        // 假服务把 respond 扣到下面放行才回：停止在放行之前就做完，说明它没等 respond、也没被占着的锁挡住
        let interrupted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { live.locked { live.interrupt() }; interrupted.signal() }
        check(waitSignal(interrupted), "R03 慢 respond 不阻塞停止锁")
        _ = app.dshServer.call("probe.release")
        _ = waitUntil { log().contains("\"respond\":\"released\"") }   // 等扣着的 respond 回完再收尾
    } else if mode == "concurrent-config" {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { app.dshConfigure("probe", req(model:"model-a"), isNew:false); done.signal() }
        check(waitUntil { log().contains("model-a") }, "C-R08 A 配置在途")
        app.dshConfigure("probe", req(model:"model-b"), isNew:false)
        check(waitSignal(done), "C-R08 并行配置完成")
        let model = (app.dshServer.call("probe.state").value as? [String:Any])?["model"] as? String
        check(app.dshApplied["probe"]?.hasPrefix((model ?? "missing") + "|") == true, "C-R08 缓存与服务最终配置一致")
        app.dshConfigure("probe", req(model:"model-a"), isNew:false)
        check((app.dshServer.call("probe.state").value as? [String:Any])?["model"] as? String == "model-a", "C-R08 重选 A 确实生效")
    } else if mode.hasPrefix("dr-") {
        // DR：假服务从事件流推提问、正文和回合结束，App 照真 dsh 的线路答复
        let done = DispatchSemaphore(value: 0); var result: AgentReply?
        let calls = JSSink(app).calls
        func finished() -> Bool {
            if waitSignal(done) { return true }
            end(live); _ = waitSignal(done); return false   // 没修好时回合不会自己结束：替它收尾，免得卡住
        }
        DispatchQueue.global().async { result = withTestAsk(app, live.req.key) { live.run(ready: { nil }) }; done.signal() }
        check(waitUntil { log().contains("session.prompt") }, "DR 初始提问已发")
        if mode == "dr-question" {
            check(waitUntil { !calls("onAgentRequest").isEmpty }, "DR1 DeepSeek 提问时窗口出现作答卡片")
            let card = calls("onAgentRequest").first ?? [:]
            let q = (card["questions"] as? [[String: Any]])?.first
            check(card["kind"] as? String == "question" && q?["question"] as? String == "导出成哪种格式？"
                  && (q?["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } == ["PDF", "PNG"], "DR1 卡片带问题和两个选项 \(card)")
            // 在别处（dsh 自带网页、被取消）了结的问题：收到 question/resolved 就撤卡
            live.receiveForTest(["type": "question/requested", "_rpcId": "q-elsewhere", "questions": [["id": "x", "question": "另一个？"]]])
            let other = calls("onAgentRequest").last?["requestId"] as? String
            live.receiveForTest(["type": "question/resolved", "questionRpcId": "q-elsewhere", "outcome": "cancelled"])
            check(other != nil && other != card["requestId"] as? String && calls("onAgentRequestClosed").contains { $0["requestId"] as? String == other }, "DR1 问题在别处了结后撤卡")
            app.answerRequest(agent: "deepseek", reqId: live.req.reqId, requestId: card["requestId"] as? String ?? "", body: ["decision": "allow", "answers": ["导出成哪种格式？": "PDF"]])
            check(finished(), "DR1 作答后原回合继续并结束")
            let bad = (try? String(contentsOfFile: root + "/bad-response", encoding: .utf8)) ?? ""
            check(result?.reply == "chose PDF" && bad.isEmpty, "DR1 按 rpcId 回传所选答案（回答 \(result?.reply ?? "无")，被拒的答复 \(bad)）")
            check(calls("onAgentRequestClosed").contains { $0["requestId"] as? String == card["requestId"] as? String }, "DR1 作答后撤卡")
        } else if mode == "dr-service-drop" {
            live.receiveForTest(event("assistant/message", ["turn":1, "step":1, "message":["content":[["type":"text","text":"中途正文"]]]]))
            // 假服务先记 rpc 日志、再写 drop-rpc（重起后拼历史要用）；机器慢时只等日志就让它崩，重起后历史是空的
            check(waitUntil { FileManager.default.fileExists(atPath: root + "/drop-rpc") }, "假服务已记下这次提问")
            _ = app.dshServer.call("probe.crash",timeout:3)
            check(finished() && result?.reply == "中途正文", "服务退出时窗口保留已显示正文")
            _ = app.dshServer.ensure(executable:fixture,environment:env,cwd:root)
            app.hooks.cliExecutable = fixture
            app.loadDeepSeek(cid:"probe"); app.deepseekQueue.sync {}
            let turns = calls("onConversationLoaded").last?["messages"] as? [[String: Any]] ?? []
            let bots = turns.filter { str($0,"role") == "bot" }
            let reason = (bots.first?["steps"] as? [[String:Any]] ?? []).last
            check(str(bots.first,"outcome") == "failed" && str(bots.first,"text") == "中途正文" && str(reason,"detail").contains("服务中途退出"),
                  "崩溃重开保留已收正文和原因，实际=\(str(bots.first,"outcome"))/\(str(bots.first,"text"))/\(str(reason,"detail"))")
            check(str(reason,"detail").contains("ENOSPC"), "DeepSeek 崩溃保留标准错误，实际=\(str(reason,"detail"))")
            check(bots.count == 2 && str(bots.last,"outcome") == "interrupted", "相同提问的其他调用仍保留原结局")
        } else if mode == "dr-steer-lost" {
            live.receiveForTest(["type":"host/session-status","running":true])
            check(live.locked { live.steer("只执行一次", images: [], id: "lost") }, "已提交补充")
            check(waitUntil { !calls("onAgentSteer").isEmpty }, "先收到 HTTP 回执处理结果")
            live.receiveForTest(event("user/message", ["source":["kind":"user","rpcId":dshSteerPrefix + "lost"]]))
            end(live)
            check(finished(), "消费补充后正常收尾")
            let states = calls("onAgentSteer").compactMap { $0["state"] as? String }
            check(states == ["uncertain","consumed"], "先失去回执再消费时同一编号只执行一次，实际 \(states)")
        } else if ["dr-steer-image","dr-steer-path-full","dr-steer-accepted"].contains(mode) {
            live.receiveForTest(["type":"host/session-status","running":true])
            let image = root + "/fix.png"
            try! Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!.write(to: URL(fileURLWithPath: image))
            TestHooks.dshAttachmentRoot = root + "/attachments"
            let inputs = mode == "dr-steer-accepted" ? [image, root + "/已移走.png"] : [image]
            check(live.locked { live.steer("附图补充", images: inputs, id: "s1") }, "DR2 接受带图补充")
            if mode == "dr-steer-path-full" {
                check(waitUntil { calls("onAgentSteer").contains { str($0,"state") == "rejected" } }, "路径也被拒绝的补图可退回队列")
                let files = try? FileManager.default.contentsOfDirectory(atPath:root + "/attachments/DeepSeek附件")
                check(files?.isEmpty == true, "明确拒绝补充后清理当次副本")
                end(live); check(finished(), "补图被拒后原轮可正常结束")
                live.input.abandon()
                exitAfterCleanup(app); return
            }
            check(finished(), "DR2 当前回合收到补充后结束")
            let steers = log().split(separator: "\n").compactMap { app.jsonObject(String($0)) }.filter { ($0["payload"] as? [String: Any])?["mode"] as? String == "steer" }
            let last = ((steers.last?["payload"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            if mode == "dr-steer-accepted" {
                let step = (result?.turn?["steps"] as? [[String:Any]])?.first { str($0, "kind") == "user" }
                let thumbs = step?["images"] as? [[String:Any]] ?? []
                check(thumbs.count == 1, "B4-4 服务只收下一张时仅显示一张，实际 \(thumbs.count)")
                let thumb = thumbs.first
                check(str(thumb, "path") == image && !str(thumb, "src").isEmpty, "B4-4 已收下的补充带缩略图，实际路径 \(str(thumb, "path"))")
            } else {
                let original = try! Data(contentsOf:URL(fileURLWithPath:image))
                try! Data("已覆盖".utf8).write(to:URL(fileURLWithPath:image))
                let echoed = (result?.turn?["steps"] as? [[String:Any]])?.first { str($0,"kind") == "user" }
                check(str(echoed,"detail") == "附图补充" && (echoed?["images"] as? [[String:Any]])?.count == 1,
                      "Flash 路径回退的实时补充保留原文和一张实际附件")
                let source = ["kind":"user","rpcId":str(steers.last,"rpcId")]
                var turns = dshTurns([event("turn/start"),event("user/message",["source":source,"content":last]), event("turn/end",["reason":["kind":"completed"]])])
                app.attachChatImages(&turns,payload:["agent":"deepseek","conversationId":"probe","cwd":root])
                let step = (turns.last?["steps"] as? [[String:Any]])?.first { str($0,"kind") == "user" }
                let ref = (step?["images"] as? [[String:Any]])?.first?["ref"] as? [String:Any]
                let bytes = ref.flatMap(app.chatImageOriginal)
                check(bytes == original, "补图路径覆盖后按原记录取回当次字节，实际=\(bytes?.count ?? 0)")
                check(steers.count == 2 && Set(steers.map { str($0,"rpcId") }).count == 1 && str(steers.first,"rpcId").hasPrefix(dshSteerPrefix)
                  && last.count == 1 && (last.first?["text"] as? String ?? "").contains("附图补充") && (last.first?["text"] as? String ?? "").contains(image),
                  "DR2 模型拒收图片时用原补充编号改发文字和路径（steer 调用 \(steers.count) 次）")
            }
            let states = calls("onAgentSteer").compactMap { $0["state"] as? String }
            check(!states.contains("rejected") && states.contains("consumed"), "DR2 补充没退回队列，当前任务收到了 \(states)")
            check(result?.reply == "got it", "DR2 原回合照常结束（\(result?.reply ?? "无")）")
        } else {
            check(finished(), "DR3 回合结束")
            let steps = result?.turn?["steps"] as? [[String: Any]] ?? []
            let why = mode == "dr-max-tokens" ? "上限" : (mode == "dr-blocked" ? "blocked" : "other side closed")
            check(result?.reply == "begin OK", "DR3 出错提示不顶掉已显示的正文（\(result?.reply ?? "无")）")
            check(responseOutcome(agent: "deepseek", turn: result?.turn) as? String == "failed", "DR3 结局 failed 交给网页，显示「重试」")
            check(steps.last?["kind"] as? String == "error" && (steps.last?["detail"] as? String ?? "").contains(why), "DR3 原因放在结束步骤里 \(steps.last ?? [:])")
        }
    } else {
        let done = DispatchSemaphore(value: 0); var result: AgentReply?
        var states: [String] = []; let stateLock = NSLock()
        app.hooks.jsSink = { name, p in if name == "onAgentSteer" { stateLock.lock(); states.append(p["state"] as? String ?? ""); stateLock.unlock() } }
        DispatchQueue.global().async { result = withTestAsk(app, live.req.key) { live.run(ready: { nil }) }; done.signal() }
        if mode == "effort-fail" {   // 模型不认这一档强度：不带强度再设一次，照常提问，不报错
            // 配置已做完、提问已到服务；接下来的回执早晚不影响收尾，直接送本轮结束
            check(waitUntil { log().contains("session.prompt") }, "强度被拒后不带强度重设，照常提问")
            end(live)
            check(waitSignal(done), "强度降级后这一轮正常结束")
            check(result?.reply.contains("设置失败") != true, "强度降级不算配置失败")
            let actual = app.dshApplied["probe"] ?? ""
            let before = log().components(separatedBy:"session.selectModel").count
            _ = app.dshServer.call("probe.recover")
            app.dshConfigure("probe", live.req, isNew:false)
            let retries = log().components(separatedBy:"session.selectModel").count - before
            check(actual == "bad||read-only" && retries == 1, "记下实际采用的强度，下轮重试，实际=\(actual)，重试=\(retries)")
            check((result?.turn?["steps"] as? [[String:Any]] ?? []).contains { str($0,"title").contains("默认思考强度") }, "回合说明实际使用默认强度")
        } else if ["configure-fail", "permission-fail"].contains(mode) {
            check(waitUntil { log().contains(mode == "permission-fail" ? "/permission" : "session.selectModel") }, "R07 配置失败已触发")
            // 配置失败时这一轮自己返回，不用等本轮结束；没返回才替它收尾，免得卡住
            let returned = waitSignal(done)
            if !returned { end(live); _ = waitSignal(done) }
            check(returned, "R07 错误可返回")
            check(!log().contains("session.prompt") && result?.reply.hasPrefix("⚠️") == true, "R07 明确失败阻止提问并提示重试")
            check(result?.restoreDraft == true && result?.conversationId == "probe", "R07 追问没交给 dsh，原话和附件退回原会话草稿")
            check(app.dshApplied["probe"] == nil, "R07 配置失败不缓存")
            _ = app.dshServer.call("probe.recover")
            app.dshConfigure("probe", req(model:"bad"), isNew:false)
            check(app.dshApplied["probe"]?.hasPrefix("bad|") == true, "R07 故障消除后同设置可重试")
        } else if mode == "compact" {
            check(waitUntil { log().contains("/compact") }, "R06 compact 在途")
            live.locked { live.interrupt() }
            check(waitSignal(done) && result?.cancelled == true, "R06 停止后的 compact 返回 cancelled")
            check(log().components(separatedBy:"session.cancel").count >= 3, "R06 在途返回补 cancel")
            let next = DeepSeekLiveTurn(app: app, req: req(75, prompt: "/compact"))
            let success = withTestAsk(app, next.req.key) { next.run(ready: { nil }) }
            check(success.turn?["compacted"] as? Bool == true, "B4-2 压缩成功即时标记 compacted，实际 \(String(describing: success.turn))")
            next.input.abandon()
            var sent = 0, why = ""
            for _ in 0..<2 { why = app.dshConfigure("inner-denied", req(), isNew:false, submit:{ sent += 1 }) ?? "" }
            check(sent == 0 && app.dshApplied["inner-denied"] == nil && why.contains("preset refused"),
                  "内层权限错误阻止提问，实际发送=\(sent)，原因=\(why)")
            _ = app.dshServer.call("probe.recover")
            let cancelled = DeepSeekLiveTurn(app:app, req:req(76,prompt:"/compact"))
            let failed = withTestAsk(app,cancelled.req.key) { cancelled.run(ready:{nil}) }
            check(failed.turn?["outcome"] as? String == "failed" && failed.reply.contains("cancelled"),
                  "服务取消压缩时可重试，实际=\(failed.reply)")
            cancelled.input.abandon()
            app.hooks.cliExecutable = fixture
            var reopened: [[String:Any]] = []
            app.hooks.jsSink = { name,row in if name == "onConversationLoaded" { reopened = row["messages"] as? [[String:Any]] ?? [] } }
            app.loadDeepSeek(cid:"probe"); app.deepseekQueue.sync {}
            let failure = reopened.firstIndex { str($0,"text").contains("cancelled") }
            let saved = failure.map { reopened[$0] }
            check(reopened.firstIndex { str($0,"text") == "之前的回答" } ?? Int.max < (failure ?? -1)
                  && (failure ?? Int.max) < (reopened.firstIndex { str($0,"text") == "之后的回答" } ?? -1), "压缩失败保留在前后两轮之间")
            check(str(saved,"retryPrompt") == "/compact" && str(saved,"text").contains("cancelled"), "DeepSeek 重开压缩失败保留原因和命令，实际=\(str(saved,"text"))/\(str(saved,"retryPrompt"))")
            check(saved?["endingReqId"] as? Int == 76, "隐藏的压缩命令仍带原请求编号，改动不会被同文重试认领")
            let shortAsk = AskRequest(agent:"deepseek",reqId:77,prompt:"/compact",model:"",effort:"",permissionMode:"read-only",workspace:root,conversationId:"short-history")
            let short = DeepSeekLiveTurn(app:app,req:shortAsk)
            let rejected = withTestAsk(app, shortAsk.key) { short.run(ready:{nil}) }
            check(rejected.turn?["outcome"] as? String == "failed" && rejected.reply.contains("对话没有变"), "短历史压缩失败显示中文原因，实际=\(rejected.reply)")
            short.input.abandon()
        } else {
            check(waitUntil { log().contains("session.prompt") }, "R04 初始提问已发")
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
                check(waitUntil { log().contains("steer") }, "R04 steer 在途")
                live.locked { live.interrupt() }
            }
            if mode == "cancel-attachment" {
                // 停止后附件准备完直接放弃，不出任何终态，没有可等的事：只断言没发生，负载下不误报，只会测得弱一些
                Thread.sleep(forTimeInterval:1.5)
            } else {
                // 在途的 steer 回包之后才补发 cancel：等到补发就说明回包已处理完，再看它有没有报成 sent
                check(waitUntil { log().components(separatedBy:"session.cancel").count >= 3 }, "R04 在途 steer 返回补 cancel")
            }
            stateLock.lock(); let sent = states.contains("sent"); stateLock.unlock()
            check(!sent, "R04 停止后不回报 sent")
            if mode == "cancel-attachment" { check(!log().contains("steer"), "R04 附件准备后停止不再提交") }
            end(live); check(waitSignal(done) && result?.cancelled == true, "R04 本轮取消返回")
        }
    }
    check(testAsksEmpty(app), "DeepSeek 测试拥有的回答记录均已删除")
    exitAfterCleanup(app)
}
func exitAfterCleanup(_ app: AppDelegate) {
    app.dshServer.shutdown(); Thread.sleep(forTimeInterval: 0.3)
    print("DeepSeek checks=\(checks) failures=\(failures)"); exit(failures == 0 ? 0 : 1)
}
