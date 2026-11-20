// DeepSeek 的历史读取：分页和游标、会话在磁盘上被挪走、正文搜索、删除。从 deepseek-lifecycle.swift 按模式分出来，
// 由那边的 runDeepSeekTests 分发（python3 tools/test-deepseek.py history-pages history-cursor disk-moved search deleted list-external）。
import Cocoa

func runDeepSeekHistoryTests(_ app: AppDelegate, args: [String], mode: String, root: String, fixture: String, env: [String: String]) {
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
                let result = awaitCallback(app, "onConversationLoaded") { app.loadDeepSeek(cid: cid) }
                check(result != nil, "C1 历史载入及时返回")
                return result ?? [:]
            }
            let beforeFirst = Date().timeIntervalSince1970 * 1000
            let first = load()
            check(first["hasMore"] as? Bool == true && calls().count == 60, "C1 默认读取60页后如实带出hasMore")
            check((first["readAt"] as? Double).map { $0 >= beforeFirst && $0 <= Date().timeIntervalSince1970 * 1000 } == true, "C1 回包带上开始读取的时刻")
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
            // 流式片段多的长会话：命中离末尾不到 300 条，搜索给的范围就是 300，可 60 页原始事件只够 190 来条
            let long = "long-fixture"
            let searched = awaitCallback(app, "onConversationsSearched", where: { $0["complete"] as? Bool != false }) {
                app.searchConversations(agent: "deepseek", query: "old-body-needle", files: [(long, root)])
            }
            check(searched != nil, "C1 长会话正文搜索返回")
            let found = searched ?? [:]
            let searchLimit = (found["items"] as? [[String: Any]])?.first?["searchLimit"] as? Int
            check(found["ids"] as? [String] == [long] && searchLimit == 300, "C1 长会话搜到早期正文，范围按可见消息给 300，实际=\(found["ids"] ?? "nil")、\(searchLimit ?? -1)")
            let hit = { (data: [String: Any]) in (data["messages"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "old-body-needle" } }
            let plain = load(long, limit: 300)
            check(!hit(plain) && plain["hasMore"] as? Bool == true, "C1 普通打开长会话仍只读 60 页")
            for (label, reset) in [("已打开时", false), ("首次", true)] {
                if reset { _ = load("other") }
                app.procLock.lock(); app.historySearchOpens.insert(long); app.procLock.unlock()
                let opened = load(long, limit: searchLimit ?? 300)
                check(hit(opened) && opened["hasMore"] as? Bool == false, "C1 从搜索结果\(label)打开长会话沿游标读到命中，实际消息=\((opened["messages"] as? [Any])?.count ?? -1)")
            }
            app.procLock.lock(); app.historyLimits[long] = nil; app.procLock.unlock()
            _ = load("other")
            let again = load(long)
            check(!hit(again), "C1 搜索打开只管那一次，之后普通打开仍是 60 页")
            TestHooks.dshSessionsRoot = root + "/sessions"
            let folder = root + "/sessions/group/session-active"
            try! FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
            try! Data().write(to:URL(fileURLWithPath:folder + "/session.jsonl.zstd"))
            var reason = ""
            let deleted = app.deleteOne(agent:"deepseek",cid:"session-active") { reason = $0 }
            check(!deleted && !reason.isEmpty && FileManager.default.fileExists(atPath:folder), "B2-12 DeepSeek 外部回合在进行时拒删，实际删除=\(deleted)，原因=\(reason)")
            let peer = DshServer(), sid = "session-peer-" + UUID().uuidString
            let peerFolder = root + "/sessions/group/" + sid
            try! FileManager.default.createDirectory(atPath: peerFolder, withIntermediateDirectories: true)
            try! Data("fixture".utf8).write(to: URL(fileURLWithPath: peerFolder + "/session.jsonl"))
            check(peer.claimSession(sid) == nil, "另一个实例取得待答会话写锁")
            let peerHistory = load(sid)
            let peerBot = (peerHistory["messages"] as? [[String: Any]])?.last
            check(peerHistory["historyError"] != nil && peerBot?["outcome"] as? String != "interrupted",
                  "另一实例持锁时保留待答状态的不确定性，实际 \(peerBot?["outcome"] ?? "无")")
            reason = ""
            let peerDeleted = app.deleteOne(agent: "deepseek", cid: sid) { reason = $0 }
            check(!peerDeleted && reason.contains("AIPetHub") && FileManager.default.fileExists(atPath: peerFolder),
                  "不能删除别的实例正在使用的会话，实际删除=\(peerDeleted)，原因=\(reason)")
            if peerDeleted, let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(sid))
            }
            withExtendedLifetime(peer) {}
            let external = "session-peer-" + UUID().uuidString
            let dir = root + "/sessions/group/" + external
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try! #"{"type":"turn/start","seq":1,"data":{"turn":1}}"#.write(toFile: dir + "/session.jsonl", atomically: true, encoding: .utf8)
            let watching = load(external)
            reason = ""
            let removedExternal = app.deleteOne(agent: "deepseek", cid: external) { reason = $0 }
            check(watching["historyError"] != nil && !removedExternal && !reason.isEmpty,
                  "独立 dsh 的回合缺少落盘结局时保留会话，实际删除=\(removedExternal)，状态=\(watching["historyError"] ?? "已确认")")
            if removedExternal, let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(external))
            }
            TestHooks.dshSessionsRoot = nil
            let custom = root + "/另一个 dsh 目录", cid = "session-" + UUID().uuidString
            let oldHome = ProcessInfo.processInfo.environment["DSH_HOME"]
            setenv("DSH_HOME", custom, 1)
            let customFolder = custom + "/sessions/project/" + cid
            try! FileManager.default.createDirectory(atPath: customFolder, withIntermediateDirectories: true)
            try! Data("fixture".utf8).write(to: URL(fileURLWithPath: customFolder + "/session.jsonl"))
            let mark = DshServer.logMark(cid)
            let upwards = String(repeating:"../", count:NSHomeDirectory().split(separator:"/").count)
            let relative = upwards + custom.dropFirst()
            for configured in [relative, "~/" + relative, custom + "/未创建/.."] {
                setenv("DSH_HOME", configured, 1)
                check(!mark.isEmpty && DshServer.logMark(cid) == mark, "B4-24 相对与波浪号形式定位到同一日志")
            }
            setenv("DSH_HOME", custom, 1)
            let removed = app.trashDeepSeek(cid: cid)
            check(!mark.isEmpty && removed && !FileManager.default.fileExists(atPath:customFolder),
                  "B4-24 自定义目录的日志指纹与删除一致，实际指纹「\(mark)」、删除 \(removed)")
            if removed, let trashDir = try? FileManager.default.url(for:.trashDirectory, in:.userDomainMask, appropriateFor:URL(fileURLWithPath:custom), create:false) {
                try? FileManager.default.removeItem(at:trashDir.appendingPathComponent(cid))
            }
            if let oldHome = oldHome { setenv("DSH_HOME", oldHome, 1) } else { unsetenv("DSH_HOME") }
            for (cid, expected) in [("active", true), ("ended", false)] {
                let state = load(cid)["lastTurn"] as? [String: Any]
                check(state?["running"] as? Bool == expected, "DeepSeek 当前回合按 turn/start、turn/end 明确运行状态")
            }
        }
        exitAfterCleanup(app); return
    }
    if mode == "disk-moved" {
        // DV：另一个 dsh 续写了磁盘上的会话日志，本服务内存里还是旧的；在旧状态上接着写会留下序号断层，整段会话读不出来
        app.hooks.cliExecutable = fixture
        let logFile = root + "/sessions/grp/probe/session.jsonl.zstd"
        try? FileManager.default.createDirectory(atPath: root + "/sessions/grp/probe", withIntermediateDirectories: true)
        try? Data("a\n".utf8).write(to: URL(fileURLWithPath: logFile))
        TestHooks.dshSessionsRoot = root + "/sessions"
        func elsewhere() { let h = FileHandle(forWritingAtPath: logFile)!; h.seekToEndOfFile(); h.write(Data("b\n".utf8)); h.closeFile() }
        func pid() -> String { (try? String(contentsOfFile: root + "/fake-disk-moved.pid", encoding: .utf8)) ?? "" }
        func count(_ s: String) -> Int { log().components(separatedBy: s).count - 1 }
        func turn(_ id: Int) -> AgentReply? {
            let t = DeepSeekLiveTurn(app: app, req: req(id, prompt: "probe-\(id)"))
            defer { t.input.abandon() }
            var result: AgentReply?
            let done = DispatchSemaphore(value: 0), returned = NSLock()
            var over = false
            DispatchQueue.global().async {
                let r = withTestAsk(app, t.req.key) { t.run(ready: { nil }) }
                returned.lock(); result = r; over = true; returned.unlock(); done.signal()
            }
            _ = waitUntil { returned.lock(); defer { returned.unlock() }; return over || log().contains("probe-\(id)") }
            end(t)
            return waitSignal(done) ? result : nil
        }
        // 只认本测试自己起的进程（下面的 root/dsh web 和「无关服务」都是）：同时在跑的另一份 disk-moved、用户开着的 dsh web 不算
        app.hooks.dshPeerProcessFilter = { descendants(of: getpid()).contains($0) }
        let first = turn(1), pid1 = pid()
        check(first != nil && count("probe-1") == 1 && count("/permission") == 1, "DV 磁盘没被别处动过时照常提问")
        let peer = AppDelegate()
        let peerReason = peer.dshReloadIfChangedElsewhere("probe", attaching: true)
        check(peerReason?.contains("AIPetHub") == true, "B3-1 第二个后端不能接手同一会话，实际原因=\(peerReason ?? "无")")
        for (arguments, blockedId) in [(["web"], 42), (["--profile", "web"], 44)] {
            let external = Process()
            let program = root + "/dsh"
            try! "#!/bin/sh\nprintf ready\nread answer\n".write(toFile: program, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program)
            let pipe = Pipe()
            external.executableURL = URL(fileURLWithPath: program)
            external.arguments = arguments
            let online = Pipe()
            external.standardOutput = online
            external.standardInput = pipe
            try! external.run()
            check(online.fileHandleForReading.availableData == Data("ready".utf8), "B3-1 原网页服务已启动")
            if arguments == ["web"] {
                // 用户常开着一个 dsh web 做别的会话：磁盘没被别处推进过时，它在不在都不该挡住这里的续写
                let allowed = turn(41)
                check(count("probe-41") == 1 && allowed?.reply.contains("别的 dsh") != true, "B3-1 别处开着 dsh web、但这个会话没被别处推进时照常续写，实际发送=\(count("probe-41"))，答复=\(allowed?.reply ?? "无")")
            }
            elsewhere()
            let blocked = turn(blockedId)
            check(count("probe-\(blockedId)") == 0 && blocked?.reply.contains("别的 dsh") == true, "B3-1 \(arguments) 原网页还开着时提示关闭其服务，实际发送=\(count("probe-\(blockedId)"))，答复=\(blocked?.reply ?? "无")")
            pipe.fileHandleForWriting.closeFile()
            external.waitUntilExit()
        }
        // 系统自带的 sh 会隐藏环境变量；这里按 dsh 使用第三方解释器的方式启动。
        try! "#!/usr/bin/env python3\nimport sys\nprint('ready', end='', flush=True)\nsys.stdin.read()\n".write(toFile: root + "/dsh", atomically: false, encoding: .utf8)
        let unrelated = Process(), input = Pipe(), online = Pipe()
        unrelated.executableURL = URL(fileURLWithPath: root + "/dsh")
        unrelated.arguments = ["web"]
        unrelated.environment = env.merging(["DSH_HOME": root + "/另一个 数据目录"]) { _, b in b }
        unrelated.standardInput = input; unrelated.standardOutput = online
        try! unrelated.run()
        check(online.fileHandleForReading.availableData == Data("ready".utf8), "无关服务已启动")
        let second = turn(2), pid2 = pid()
        input.fileHandleForWriting.closeFile(); unrelated.waitUntilExit()
        check(pid2 != pid1 && count("probe-2") == 1, "DV 磁盘被别处续写后，先重起服务（按磁盘重新载入）再续写（服务 \(pid1)→\(pid2)，提问 \(count("probe-2")) 次，\(second?.reply ?? "无答复")）")
        check(count("/permission") == 2, "DV 重起后重新设置会话（/permission 共 \(count("/permission")) 次）")
        elsewhere()
        let busy = withTestAsk(app, "deepseek#99") { turn(3) }
        check(busy?.reply.hasPrefix("⚠️") == true && busy?.reply.contains("别处") == true && count("probe-3") == 0 && pid() == pid2,
              "DV 另有 DeepSeek 回答在进行时不重起也不续写，提示用户（\(busy?.reply ?? "无答复")，提问 \(count("probe-3")) 次，服务 \(pid2)→\(pid())）")
        check(awaitCallback(app, "onConversationLoaded") { app.loadDeepSeek(cid: "probe") } != nil, "DV 历史载入及时返回")
        let pid3 = pid()
        check(pid3 != pid2, "DV 重开会话时也按磁盘重新载入（服务 \(pid2)→\(pid3)）")
        let reopened = peer.dshServer.sessionLock("probe").error
        check(reopened == nil, "只读重载后旧服务交出写锁，实际=\(reopened ?? "可接手")")
        _ = turn(4); _ = turn(5)
        check(peer.dshServer.sessionLock("probe").error != nil, "新服务续写后重新持锁")
        check(pid() == pid3 && count("probe-5") == 1, "DV 磁盘没变时连续续写不重起服务（服务 \(pid3)→\(pid())）")
        // 本服务自己写的（事件流上有这个会话的事件）落盘后改变了日志，不能当成别处更新
        let seen = DispatchSemaphore(value: 0), marked = DispatchSemaphore(value: 0)
        TestHooks.dshDiskMarked = { if $0 == "probe" { marked.signal() } }
        let token = app.dshServer.listen("probe") { if $0["type"] as? String == "session/event" { seen.signal() } }
        _ = app.dshServer.call("probe.emit", ["sessionId": "probe"])
        check(waitSignal(seen), "DV 假服务的写事件已到")
        app.dshServer.unlisten("probe", token)
        elsewhere()
        _ = turn(6)
        check(pid() == pid3 && count("probe-6") == 1, "DV 本服务刚写、还在落盘时不算别处更新（服务 \(pid3)→\(pid())）")
        check(waitSignal(marked), "DV 本服务的写落盘后记下日志的样子")
        _ = turn(7)
        check(pid() == pid3 && count("probe-7") == 1, "DV 落盘后以本服务自己写完的样子为准，不误判（服务 \(pid3)→\(pid())）")
        // 别的会话里 DeepSeek 起的后台任务（开发服务器等）回答结束后还在跑；重起服务会把它们一起结束
        func jobs(_ status: String) {
            let got = DispatchSemaphore(value: 0)
            let token = app.dshServer.listen("other") { if $0["type"] as? String == "session/jobs" { got.signal() } }
            _ = app.dshServer.call("probe.emit", ["frame": ["sessionId": "other", "type": "session/jobs",
                "jobs": [["id": "bash-1", "kind": "bash", "label": "npm run dev", "status": status, "startedAt": 1]]]])
            check(waitSignal(got), "DV 假服务的后台任务帧（\(status)）已到")
            app.dshServer.unlisten("other", token)
        }
        func search(_ word: String) -> [String: Any] {
            let done = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]
            app.hooks.jsSink = { name, data in
                if name == "onConversationsSearched", data["complete"] as? Bool == true { result = data; done.signal() }
            }
            app.searchConversations(agent: "deepseek", query: word)
            check(waitSignal(done), "DV 搜索返回")
            app.hooks.jsSink = { _, _ in }
            return result
        }
        check(search("old-body")["ids"] as? [String] == ["probe"], "B4-12 外部续写前已有正文搜索缓存")
        jobs("running")
        let externalText = FileHandle(forWritingAtPath: logFile)!
        externalText.seekToEndOfFile(); externalText.write(Data("new-body".utf8)); externalText.closeFile()
        let held = turn(8)
        check(held?.reply.hasPrefix("⚠️") == true && held?.reply.contains("npm run dev") == true && count("probe-8") == 0 && pid() == pid3,
              "DV 别的会话还有后台任务在跑时不重起也不续写，提示用户（\(held?.reply ?? "无答复")，提问 \(count("probe-8")) 次，服务 \(pid3)→\(pid())）")
        let stale = awaitCallback(app, "onConversationLoaded") { app.loadDeepSeek(cid: "probe") }
        check(stale != nil, "DV 历史载入及时返回")
        let staleReason = str(stale, "historyError")
        check(staleReason.contains("npm run dev"), "无法重载时说明旧历史的原因，实际=\(staleReason)")
        check(pid() == pid3, "DV 有后台任务在跑时重开会话也不重起服务（服务 \(pid3)→\(pid())）")
        let blockedSearch = search("old-body")
        check(str(blockedSearch, "unavailable").contains("npm run dev") && (blockedSearch["ids"] as? [String]) == [],
              "B4-12 受阻时无旧正文命中并提示具体原因，实际 \(blockedSearch)")
        jobs("completed")
        _ = app.dshServer.call("probe.emit", ["frame":["type":"approval/requested","sessionId":"other","approvalId":"等待确认"]])
        check(waitUntil { app.dshServer.waitingRequest("dsh-等待确认") != nil }, "另一会话的审批已出现")
        let blockedRead = app.dshReloadIfChangedElsewhere("probe", attaching:false)
        check(blockedRead != nil && app.dshServer.waitingRequest("dsh-等待确认") != nil && pid() == pid3,
              "读历史保留另一会话的审批，原因=\(blockedRead ?? "无")，待答=\(app.dshServer.waitingRequest("dsh-等待确认") != nil)")
        app.dshServer.forget("dsh-等待确认")
        let updated = search("new-body")["ids"] as? [String]
        check(updated == ["probe"] && pid() != pid3, "B4-12 后台任务结束后正文搜索命中外部新内容，实际 \(String(describing:updated))")
        check(search("old-body")["ids"] as? [String] == [], "B4-12 重新加载后旧正文不再命中")
        _ = turn(9)
        check(pid() != pid3 && count("probe-9") == 1, "DV 后台任务结束后照常重新载入再续写（服务 \(pid3)→\(pid())，提问 \(count("probe-9")) 次）")
        // 删除会话就是把它的目录移走：日志「变了」，但那不是别处续写。不能为此重起服务——重起会清掉「这次删掉的会话」名单，
        // 删掉的会话就又能打开（窗口测试 e2e-deepseek 偶发「已删会话打开报告不存在」失败）
        let pid4 = pid()
        try? FileManager.default.moveItem(atPath: root + "/sessions/grp/probe", toPath: root + "/trashed-probe")
        app.dshServer.markDeleted("probe", directory:root + "/sessions/grp/probe")
        check(awaitCallback(app, "onConversationLoaded") { app.loadDeepSeek(cid: "probe") } != nil, "DV 删掉的会话载入及时返回")
        check(pid() == pid4 && app.dshServer.isDeleted("probe"), "DV 删掉会话后打开它不重起服务，也不丢掉已删名单（服务 \(pid4)→\(pid())）")
        let removed = peer.dshServer.sessionLock("probe").error
        check(removed == nil, "移走目录后释放写锁，实际=\(removed ?? "可接手")")
        UserDefaults.standard.removeObject(forKey:DshServer.deletedDirectoryKey("probe"))
        TestHooks.dshDiskMarked = nil
        check(testAsksEmpty(app), "DeepSeek 测试拥有的回答记录均已删除")
        exitAfterCleanup(app); return
    }
    if mode == "search" {
        app.hooks.cliExecutable = fixture
        func search(_ query: String) -> [String: Any] {
            let done = DispatchSemaphore(value: 0)
            var result: [String: Any] = [:]
            app.hooks.jsSink = { name, payload in
                if name == "onConversationsSearched", payload["complete"] as? Bool != false {
                    result = payload; done.signal()
                }
            }
            app.searchConversations(agent: "deepseek", query: query)
            check(waitSignal(done), "A DeepSeek 搜索有最终回调")
            app.hooks.jsSink = { _, _ in }
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
        check(!(search("changed-visible-needle")["unavailable"] as? String ?? "").isEmpty, "A 服务不可用明确报告这一位没搜")
        // dsh 一启动就退出（这里是程序不存在）时立刻报错，不等满 30 秒的端口超时（门槛取一半）
        check(Date().timeIntervalSince(t0) < 15, "A dsh 起不来时不等满端口超时（\(Int(Date().timeIntervalSince(t0))) 秒）")
        exitAfterCleanup(app); return
    }
    if mode == "list-external" {
        // 别的 dsh 续写或改名后，本服务的列表仍是旧标题、旧时间；侧栏和搜索都要按末页投影显示和排序，
        // 但只为别处改过或缺标题的会话各读一次末页。
        app.hooks.cliExecutable = fixture
        func checked() -> [String] {
            log().split(separator: "\n").compactMap { app.jsonObject(String($0)) }
                .filter { $0["method"] as? String == "session.history" && ($0["payload"] as? [String: Any])?["maxMessages"] as? Int == 1 }
                .compactMap { ($0["payload"] as? [String: Any])?["sessionId"] as? String }
        }
        func touch(_ sid: String) {
            let dir = root + "/sessions/grp/" + sid
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let old = (try? String(contentsOfFile: dir + "/session.jsonl", encoding: .utf8)) ?? ""
            try! (old + "{\"seq\":\(old.count)}\n").write(toFile: dir + "/session.jsonl", atomically: false, encoding: .utf8)
        }
        func listed() -> [[String: Any]] {
            let result = awaitCallback(app, "onConversationsListed") { app.listDeepSeek() }
            check(result != nil, "列表及时返回")
            return result?["items"] as? [[String: Any]] ?? []
        }
        func titles(_ items: [[String: Any]]) -> [String] { items.map { str($0, "id") + "=" + str($0, "title") } }
        for sid in ["ext-a", "ext-b", "untitled"] { touch(sid) }
        eq(titles(listed()), ["ext-a=甲旧标题", "ext-b=乙旧标题", "untitled=补上的标题"], "DeepSeek 列表缺标题的会话用末页投影补上")
        eq(checked(), ["untitled"], "第一次运行（还没有存档）只为缺标题的会话读末页")
        _ = listed()
        eq(checked(), ["untitled"], "日志没变的会话再刷新不重复读末页")
        _ = app.dshServer.call("probe.fresh", ["sessionId": "ext-b", "title": "乙新标题", "lastPromptAt": 4000])
        touch("ext-b")
        let after = listed()
        eq(titles(after), ["ext-b=乙新标题", "ext-a=甲旧标题", "untitled=补上的标题"], "DeepSeek 在别处续写、改名后侧栏按新时间排序、显示新标题")
        eq(after.first?["timestamp"] as? Double, 4, "侧栏时间取末页的最后提问时刻")
        eq(checked(), ["untitled", "ext-b"], "只为日志在别处变过的会话读末页")
        let sources = app.searchSources(agent: "deepseek", files: nil).sources
        let found = sources.first { $0.cid == "ext-b" }?.item
        eq(found.map { str($0, "title") + "@" + String($0["timestamp"] as? Double ?? 0) }, "乙新标题@4.0", "搜索用同一份核对结果")
        eq(checked(), ["untitled", "ext-b"], "搜索复用侧栏的核对结果，不再发请求")
        app.dshServer.noteWrite("ext-a"); touch("ext-a")
        eq(titles(listed()).first, "ext-b=乙新标题", "核对过的结果在日志不变时继续沿用")
        eq(checked(), ["untitled", "ext-b"], "本服务自己写的会话照用列表，不读末页")
        // App 重开（新的 dsh 服务，核对结果从存档读回）：日志没变的照用存档、不再读末页；App 关着时别处改过名的、
        // 第一次见到的会话即使列表有标题也核对一次（列表来自 dsh 的投影缓存，写它的 dsh 没来得及落盘就退出时是旧的）
        check(app.dshServer.restart() == nil, "重起假服务")
        app.dshListChecks = nil
        _ = app.dshServer.call("probe.fresh", ["sessionId": "ext-a", "title": "甲新标题", "lastPromptAt": 3000])
        touch("ext-a")
        _ = app.dshServer.call("probe.add", ["sessionId": "ext-c", "listTitle": "丙旧标题", "title": "丙新标题", "lastPromptAt": 500])
        touch("ext-c")
        eq(titles(listed()), ["ext-b=乙新标题", "ext-a=甲新标题", "untitled=补上的标题", "ext-c=丙新标题"],
           "App 重开后别处改过名、第一次见到的会话显示末页的标题，核对过的沿用存档")
        eq(checked().dropFirst(2).sorted(), ["ext-a", "ext-c"], "App 重开后只为日志变过和第一次见到的会话读末页")
        // 本服务内存里接手过的会话又被别处改名：旧服务给的末页还是旧的，只在这一代服务里作数，重起服务（打开会话时）后重新核对
        _ = app.dshServer.changedElsewhere("ext-b", attaching: true)
        _ = app.dshServer.call("probe.hold", ["sessionId": "ext-b"])
        _ = app.dshServer.call("probe.fresh", ["sessionId": "ext-b", "title": "乙第三标题", "lastPromptAt": 4000])
        touch("ext-b")
        _ = listed()
        check(app.dshServer.restart() == nil, "重起假服务")
        eq(titles(listed()).first, "ext-b=乙第三标题", "重起服务后按磁盘重新核对，不沿用旧服务内存给的标题")
        let renamed = app.searchSources(agent: "deepseek", files: nil).sources.first { $0.cid == "ext-b" }?.item
        eq(renamed.map { str($0, "title") }, "乙第三标题", "搜索按新标题")
        let reads = checked().count
        _ = listed()
        eq(checked().count, reads, "日志没变时再刷新不多发请求")
        // dsh 网页归档（workspace.archiveSession）的会话：dsh 单独记在数据目录的 storages/workspace.json，session.list 照样列出
        try! FileManager.default.createDirectory(atPath: root + "/storages", withIntermediateDirectories: true)
        try! #"{"unit":{"name":"workspace","version":2},"global":{"initialized":true,"workspaceIds":[],"archivedSessionIds":["ext-c"]},"tables":{"workspaces":{}}}"#
            .write(toFile: root + "/storages/workspace.json", atomically: true, encoding: .utf8)
        eq(titles(listed()), ["ext-b=乙第三标题", "ext-a=甲新标题", "untitled=补上的标题"], "dsh 网页归档的会话侧栏不列")
        eq(app.searchSources(agent: "deepseek", files: nil).sources.map(\.cid).sorted(), ["ext-a", "ext-b", "untitled"], "搜索不列归档的会话")
        app.procLock.lock(); let fixtureCwd = app.dshCwds["ext-a"] ?? ""; app.procLock.unlock()
        eq(app.deepseekIds(inWorkspace: app.trimmedPath(fixtureCwd)).sorted(), ["ext-a", "ext-b", "untitled"], "删除项目的候选不含归档的会话")
        // 还开着的聊天页：单条刷新也要认归档（网页按「会话不在了」退出空闲的页面，和外部删除一样），没归档的照常读
        for (cid, gone) in [("ext-c", true), ("ext-a", false)] {
            let loaded = awaitCallback(app, "onConversationLoaded", where: { str($0, "conversationId") == cid }) { app.loadDeepSeek(cid: cid) }
            eq(loaded?["missing"] as? Bool, gone, "单条刷新 \(cid) 按归档清单答缺失")
        }
        // 刷新前就点了发送：不往归档的会话里续写，提示已归档，原话和附件退回草稿
        let sentBefore = log().count
        let archivedAsk = AskRequest(agent: "deepseek", reqId: 91, prompt: "归档后追问", model: "", effort: "", permissionMode: "read-only",
                                     workspace: root, conversationId: "ext-c")
        let archivedLive = DeepSeekLiveTurn(app: app, req: archivedAsk)
        // 放进去写了的话这个夹具不会答完：放在后台等，没返回就记为失败
        var refused: AgentReply?
        let sentDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { refused = withTestAsk(app, archivedAsk.key) { archivedLive.run(ready: { nil }) }; sentDone.signal() }
        let returned = waitSignal(sentDone)
        archivedLive.input.abandon()
        let touched = String(log().dropFirst(sentBefore))
        check(returned && refused?.reply.contains("归档") == true && refused?.restoreDraft == true && refused?.conversationId == "ext-c" && !touched.contains("ext-c"),
              "归档的会话发送前拦下并退回草稿，实际返回=\(returned)、\(refused?.reply ?? "")、退回=\(refused?.restoreDraft ?? false)、调用=\(touched.prefix(200))")
        // dsh 派出的子代理会话（origin: "subagent"）不单列；用户自己分叉的会话也带 parentSessionId，照常列出
        _ = app.dshServer.call("probe.add", ["sessionId": "sub-1", "listTitle": "子代理内部提问", "title": "子代理内部提问", "lastPromptAt": 3500,
                                             "fields": ["origin": "subagent", "parentSessionId": "ext-a"]])
        _ = app.dshServer.call("probe.add", ["sessionId": "fork-1", "listTitle": "分叉出来的会话", "title": "分叉出来的会话", "lastPromptAt": 3400,
                                             "fields": ["parentSessionId": "ext-a"]])
        touch("sub-1"); touch("fork-1")
        eq(titles(listed()), ["ext-b=乙第三标题", "fork-1=分叉出来的会话", "ext-a=甲新标题", "untitled=补上的标题"], "子代理会话侧栏不列，用户分叉的照常列出")
        eq(app.searchSources(agent: "deepseek", files: nil).sources.map(\.cid).sorted(), ["ext-a", "ext-b", "fork-1", "untitled"], "搜索不列子代理会话")
        eq(app.deepseekIds(inWorkspace: app.trimmedPath(fixtureCwd)).sorted(), ["ext-a", "ext-b", "fork-1", "untitled"], "删除项目的候选不含子代理会话")
        exitAfterCleanup(app); return
    }
    if mode == "deleted" {
        app.hooks.cliExecutable = fixture
        if let state = args.dropFirst(2).first {
            let restored = state == "restored"
            let sources = app.searchSources(agent:"deepseek",files:nil).sources.map(\.cid)
            let history = app.readDeepSeekHistory(cid:"probe",pageLimit:1)
            check(sources.contains("probe") == restored && history.missing == !restored,
                  "独立进程的列表与正文 \(state) 来源=\(sources) missing=\(history.missing)")
            exitAfterCleanup(app); return
        }
        func listed() -> [String] {
            let done = DispatchSemaphore(value: 0); var ids: [String] = []
            app.hooks.jsSink = { name, payload in
                if name == "onConversationsListed" { ids = (payload["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }; done.signal() }
            }
            app.listDeepSeek()
            check(waitSignal(done), "DH1 列表及时返回")
            app.hooks.jsSink = { _, _ in }
            return ids
        }
        func load(_ cid: String) -> [String: Any] {
            let result = awaitCallback(app, "onConversationLoaded") { app.loadDeepSeek(cid: cid) }
            check(result != nil, "DH1 载入及时返回")
            return result ?? [:]
        }
        check(listed() == ["probe", "kept"], "DH1 删除前两条都列出")
        var sidebarTasks = [String](), projectTasks = [String]()
        app.hooks.jsSink = { name, payload in
            if name == "onConversationsListed" {
                sidebarTasks = (payload["items"] as? [[String: Any]] ?? []).filter { $0["task"] as? Bool == true }.compactMap { $0["id"] as? String }
            }
            if name == "onProjectConversations" { projectTasks = payload["taskIds"] as? [String] ?? [] }
        }
        app.listDeepSeek(); app.deepseekQueue.sync {}
        app.projectConversations(agent:"deepseek", workspace:app.dshCwds["probe"]!); app.deepseekQueue.sync {}
        check(sidebarTasks == ["probe"] && projectTasks == ["probe"], "B4-23 DeepSeek headless 首问和 RPC 首问分开，实际 \(sidebarTasks) / \(projectTasks)")

        check(!((load("probe")["messages"] as? [[String: Any]]) ?? []).isEmpty, "DH1 删除前能载入")
        // 删除只挪走磁盘目录（trashDeepSeek 成功后记下），服务仍把会话留在内存里照常列出
        let peer = AppDelegate()
        peer.hooks.cliExecutable = fixture
        check(peer.dshServer.ensure(executable:fixture, environment:env, cwd:root) == nil, "另一实例的假服务启动")
        app.dshServer.markDeleted("probe", directory:root + "/sessions/grp/probe")
        let folder = root + "/sessions/grp/probe"
        for restored in [false, true] {
            if restored {
                try! FileManager.default.createDirectory(atPath:folder, withIntermediateDirectories:true)
                try! Data("已恢复".utf8).write(to:URL(fileURLWithPath:folder+"/session.jsonl"))
            }
            let process = app.runTool(Bundle.main.executablePath!, ["deepseek","deleted",root,restored ? "restored" : "missing"],
                                      cwd:FileManager.default.currentDirectoryPath,timeout:testWaitLimit)
            check(process.status == 0, "跨进程删除矩阵 restored=\(restored)，\(process.out)\(process.err)")
            for (name, reader) in [("原实例",app), ("另一实例",peer)] {
                let sources = reader.searchSources(agent:"deepseek", files:nil).sources.map(\.cid)
                let history = reader.readDeepSeekHistory(cid:"probe",pageLimit:1)
                check(sources.contains("probe") == restored && history.missing == !restored && sources.contains("kept"),
                      "DeepSeek 删除矩阵 \(name) restored=\(restored) 搜索=\(sources) missing=\(history.missing)")
            }
        }
        try! FileManager.default.removeItem(atPath:folder)
        peer.dshServer.shutdown()
        let after = listed()
        check(after == ["kept"], "DH1 删除后刷新不再列出（实际 \(after)）")
        app.procLock.lock(); let fixtureCwd = app.dshCwds["kept"] ?? ""; app.procLock.unlock()
        check(app.deepseekIds(inWorkspace: app.trimmedPath(fixtureCwd)) == ["kept"], "DH1 删除项目时也不再算上已删会话")
        let reopened = load("probe")
        check(reopened["missing"] as? Bool == true && ((reopened["messages"] as? [[String: Any]]) ?? []).isEmpty,
              "DH1 已删会话载入报告不存在（missing=\(reopened["missing"] ?? "无")，\((reopened["messages"] as? [Any])?.count ?? 0) 条）")
        let before = log()
        let resumed = DeepSeekLiveTurn(app: app, req: req(21, prompt: "after-delete"))
        let done = DispatchSemaphore(value: 0); var reply: AgentReply?
        DispatchQueue.global().async { reply = withTestAsk(app, resumed.req.key) { resumed.run(ready: { nil }) }; done.signal() }
        let returned = waitSignal(done)
        if !returned { end(resumed); _ = waitSignal(done) }
        let sent = String(log().dropFirst(before.count))
        check(returned && reply?.reply.hasPrefix("⚠️") == true && reply?.reply.contains("删除") == true,
              "DH1 续问已删会话直接说明已删除（\(reply?.reply ?? "没有返回")）")
        check(!sent.contains("session.prompt") && !sent.contains("session.selectModel") && !sent.contains("commands/execute"),
              "DH1 续问已删会话不再向 dsh 发设置和提问")
        resumed.input.abandon()
        check(testAsksEmpty(app), "DeepSeek 测试拥有的回答记录均已删除")
        // 服务重建也按磁盘决定；恢复后不能再受上一次删除的影响。
        app.dshServer.shutdown()
        check(!app.dshServer.isDeleted("probe"), "DH1 服务重建后清空已删名单")
        try! FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
        check(app.dshServer.ensure(executable:fixture,environment:env,cwd:root) == nil && !app.dshServer.isDeleted("probe"), "DH1 服务重建后磁盘上恢复的会话可用")
        UserDefaults.standard.removeObject(forKey:DshServer.deletedDirectoryKey("probe"))
        exitAfterCleanup(app); return
    }
}
