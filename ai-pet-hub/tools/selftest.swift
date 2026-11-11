// 后端自测：不开窗口，直接调用 AppDelegate 的历史读取 / 进程管理 / CLI 调用。
// 编译：tools/test.sh（编译并跑离线测试），或 swiftc -D HUB_SELFTEST Sources/**/*.swift tools/selftest.swift tools/parsertest.swift tools/livetest.swift -o build/selftest -framework Cocoa -framework WebKit -lsqlite3
// 用法：build/selftest parsers         离线：解析器测试，不需要 CLI 和会话记录
//      build/selftest list            三位的历史列表 + 打开第一条
//      build/selftest proc            子进程输出 / 停止 / 后台孙进程
//      build/selftest ask <agent> <权限> <提示词>   真实调用一次 CLI，再接着同一会话问一次
//      build/selftest project <agent> <工作空间>     只读：统计这个工作空间里的全部会话
//      build/selftest docpreview <文档>…            Word / Excel / PPT 转预览网页（第二次应命中缓存）
//      build/selftest docbrowser <docx> <临时目录>  真的走内置浏览器：地址栏回报、改了刷新、坏文件、停止、后退
//      build/selftest weberror <空闲端口> <临时目录> 错误页：刷新重试不多占历史、服务器起来后恢复、后退
import Cocoa

private func waitFor(_ d: AppDelegate, _ fn: String, timeout: TimeInterval = 120, _ trigger: () -> Void) -> [String: Any]? {
    let sem = DispatchSemaphore(value: 0)
    var got: [String: Any]?
    d.jsSink = { name, payload in
        if name == fn, got == nil { got = payload; sem.signal() }
    }
    trigger()
    _ = sem.wait(timeout: .now() + timeout)
    d.jsSink = nil
    return got
}

/// 打印一条消息；回答会附带工作步骤和改动文件的摘要。
private func printMessage(_ m: [String: Any]) {
    let role = m["role"] as? String ?? ""
    print("     \(role): \(preview(m["text"] as? String ?? ""))")
    for im in m["images"] as? [[String: Any]] ?? [] {   // 用户消息里的图片：缩略图大小、来源
        let kb = ((im["src"] as? String)?.utf8.count ?? 0) / 1024
        let from = im["missing"] != nil ? "文件已不在" : im["ref"] != nil ? "内嵌" : "文件"
        print("        图片 \(im["w"] ?? "-")×\(im["h"] ?? "-") \(kb)KB \(from) \(im["path"] ?? "")\(im["match"] != nil ? "（文字里换成短标签）" : "")")
    }
    let steps = m["steps"] as? [[String: Any]] ?? []
    let files = m["files"] as? [[String: Any]] ?? []
    if role == "bot", !steps.isEmpty || !files.isEmpty {
        let kinds = steps.map { $0["kind"] as? String ?? "?" }
        let dur = (m["duration"] as? Double).map { String(format: "%.0fs", $0) } ?? "-"
        print("        步骤 \(steps.count)（\(kinds.prefix(12).joined(separator: ","))） 用时 \(dur)")
        for st in steps.prefix(3) { print("          · [\(st["kind"] ?? "")] \(preview(st["title"] as? String ?? "", 40)) \(st["status"] ?? "")") }
        for f in files.prefix(3) { print("          ▸ 文件 \(f["path"] ?? "") +\(f["added"] ?? 0) −\(f["removed"] ?? 0) \(f["kind"] ?? "")") }
    }
}

private func preview(_ s: String, _ n: Int = 60) -> String {
    let one = s.replacingOccurrences(of: "\n", with: " ⏎ ")
    return one.count > n ? String(one.prefix(n)) + "…" : one
}

func runSelfTest() {
    let args = Array(CommandLine.arguments.dropFirst())
    let d = AppDelegate()
    switch args.first ?? "list" {
    case "live":   // 交互式回答：审批、拒绝、中途补充、停止（tools/livetest.swift，要用真的 CLI）
        runLiveTests(args)
    case "parsers":   // 离线：固定的流式 JSON 喂给解析器（tools/parsertest.swift），不需要 CLI 和会话记录
        runParserTests()
    case "list":
        for agent in ["gemini", "claude", "gpt", "deepseek"] where args.count < 3 || args[2] == agent {
            let t0 = Date()
            guard let listed = waitFor(d, "onConversationsListed", { d.listConversations(agent: agent) }),
                  let items = listed["items"] as? [[String: Any]] else { print("[\(agent)] 列表超时"); continue }
            print("[\(agent)] \(items.count) 条历史，用时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            // list <N>：多列几条，并带上会话 ID（清理测试会话时用）
            let n = args.count >= 2 ? (Int(args[1]) ?? 4) : 4
            for item in items.prefix(n) {
                print("   · \(item["time"] ?? "") | \(preview(item["title"] as? String ?? "", 40)) | count=\(item["count"] ?? "-") | cwd=\(item["cwd"] ?? "")\(n > 4 ? " | id=\(item["id"] ?? "")" : "")")
            }
            guard let first = items.first, let cid = first["id"] as? String else { continue }
            if let loaded = waitFor(d, "onConversationLoaded", { d.loadConversation(agent: agent, cid: cid) }) {
                let msgs = loaded["messages"] as? [[String: Any]] ?? []
                print("   打开第一条：\(msgs.count) 条消息，missing=\(loaded["missing"] ?? "?")，cwd=\(loaded["cwd"] ?? "")")
                msgs.prefix(4).forEach(printMessage)
            }
            if let missing = waitFor(d, "onConversationLoaded", { d.loadConversation(agent: agent, cid: "no-such-id-123") }) {
                print("   不存在的会话：missing=\(missing["missing"] ?? "?")")
            }
        }
    case "load":
        guard args.count >= 3 else { print("用法：load <agent> <会话ID>"); return }
        let t0 = Date()
        if let loaded = waitFor(d, "onConversationLoaded", { d.loadConversation(agent: args[1], cid: args[2]) }) {
            let msgs = loaded["messages"] as? [[String: Any]] ?? []
            print("\(msgs.count) 条消息（最多 300），用时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s，cwd=\(loaded["cwd"] ?? "")")
            msgs.suffix(4).forEach(printMessage)
            if args.count >= 4 {   // 可选：统计含某关键字的用户消息条数
                let hits = msgs.filter { ($0["role"] as? String) == "user" && (($0["text"] as? String) ?? "").contains(args[3]) }
                print("含「\(args[3])」的用户消息：\(hits.count) 条（共 \(msgs.filter { ($0["role"] as? String) == "user" }.count) 条用户消息）")
            }
        }
    case "delete":
        guard args.count >= 3 else { print("用法：delete <agent> <会话ID>"); return }
        let res = waitFor(d, "onConversationDeleted") { d.deleteConversation(agent: args[1], cid: args[2]) }
        print("删除 \(args[1]) \(args[2])：ok=\(res?["ok"] ?? "超时")")
    case "project":   // 只读：统计某个工作空间里的全部会话（「删除项目」确认框里的数字）
        guard args.count >= 3 else { print("用法：project <agent> <工作空间路径>"); return }
        let t0 = Date()
        let res = waitFor(d, "onProjectConversations") { d.projectConversations(agent: args[1], workspace: args[2]) }
        let ids = res?["ids"] as? [String] ?? []
        print("\(args[1]) 在 \(args[2]) 的会话：\(ids.count) 个，用时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        ids.prefix(5).forEach { print("   · \($0)") }
    case "e2e":   // 真实 CLI 端到端：默认（最高）权限在给定目录建文件 → 同一会话追问 → 中途停止
        guard args.count >= 3 else { print("用法：e2e <agent> <空目录>"); return }
        let agent = args[1], ws = args[2]
        let defaults: [String: (model: String, effort: String, perm: String)] = [
            "gemini": ("gemini-4-argon", "medium", "bypassPermissions"),
            "claude": ("claude-opus-5-5", "low", "bypassPermissions"),
            "gpt": ("gpt-6-astra", "low", "danger-full-access"),
        ]
        guard let cfg = defaults[agent] else { print("未知 agent"); return }
        var seq = 100
        typealias Run = (res: [String: Any], steps: Int, secs: Double, early: (cid: String, secs: Double)?)
        func run(_ prompt: String, conv: String, cancelAfter: Double? = nil) -> Run {
            seq += 1
            let req = AskRequest(agent: agent, reqId: seq, prompt: prompt, model: cfg.model, effort: cfg.effort,
                                 permissionMode: cfg.perm, workspace: ws, conversationId: conv)
            let sem = DispatchSemaphore(value: 0)
            var steps = 0
            var final: [String: Any] = [:]
            var early: (cid: String, secs: Double)?
            let t0 = Date()
            d.jsSink = { name, payload in
                if name == "onAgentStep" { steps += 1 }
                // 会话 ID 一报出来就转给网页（新对话靠它马上变成正式会话），不等回答结束
                if name == "onAgentConversation", (payload["reqId"] as? Int) == req.reqId {
                    early = (payload["conversationId"] as? String ?? "", Date().timeIntervalSince(t0))
                }
                if name == "onAgentResponse", (payload["reqId"] as? Int) == req.reqId { final = payload; sem.signal() }
            }
            d.ask(req)
            if let after = cancelAfter { DispatchQueue.global().asyncAfter(deadline: .now() + after) { d.cancel(agent: agent) } }
            _ = sem.wait(timeout: .now() + 600)
            d.jsSink = nil
            return (final, steps, Date().timeIntervalSince(t0), early)
        }
        /// 新对话：会话 ID 要在回答结束前就报出来，而且和最后的一致；续接的会话 ID 不变，不该再报。
        func earlyCheck(_ r: Run, expectNew: Bool) -> String {
            let finalId = r.res["conversationId"] as? String ?? ""
            guard let e = r.early else { return expectNew ? "会话 ID 没有提前报出 ✗" : "续接时没有多报会话 ID ✓" }
            guard expectNew else { return "续接时多报了会话 ID（\(e.cid)）✗" }
            return "会话 ID 在第 \(String(format: "%.1f", e.secs))s 报出（回答用了 \(String(format: "%.0f", r.secs))s）"
                + (e.cid == finalId && e.secs < r.secs ? " ✓" : " ✗（提前报的 \(e.cid)，最后的 \(finalId)）")
        }
        func show(_ title: String, _ r: Run) {
            let files = (r.res["files"] as? [[String: Any]] ?? []).map { "\(($0["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?")" }
            print("[\(agent)] \(title)：\(String(format: "%.0f", r.secs))s，实时步骤 \(r.steps) 个，cancelled=\(r.res["cancelled"] ?? "-")，"
                  + "conv=\(r.res["conversationId"] ?? "")，改动文件=\(files)")
            print("    回复：\(preview(r.res["reply"] as? String ?? "（无）", 120))")
        }
        let r1 = run("请在当前目录创建文件 hello.txt，内容只有 hi 两个字母。然后只回复当前目录的绝对路径。", conv: "")
        show("1 建文件", r1)
        let content = (try? String(contentsOfFile: ws + "/hello.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        print("    检查：hello.txt \(content == nil ? "不存在 ✗" : "内容=\(content!) \(content == "hi" ? "✓" : "✗")")；回复里有工作目录 \((r1.res["reply"] as? String ?? "").contains((ws as NSString).lastPathComponent) ? "✓" : "✗")；\(earlyCheck(r1, expectNew: true))")
        let conv = r1.res["conversationId"] as? String ?? ""
        let r2 = run("我刚才让你创建的文件叫什么名字？只回复文件名。", conv: conv)
        show("2 续接会话", r2)
        print("    检查：记得文件名 \((r2.res["reply"] as? String ?? "").contains("hello.txt") ? "✓" : "✗")；会话 ID 不变 \((r2.res["conversationId"] as? String ?? "") == conv ? "✓" : "✗（\(r2.res["conversationId"] ?? "")）")；\(earlyCheck(r2, expectNew: false))")
        let r3 = run("请执行 shell 命令 sleep 45，等它结束后回复 done。", conv: "", cancelAfter: 10)
        show("3 中途停止", r3)
        print("    检查：已停止 \((r3.res["cancelled"] as? Bool) == true ? "✓" : "✗")，用时 \(String(format: "%.0f", r3.secs))s \(r3.secs < 25 ? "✓" : "✗")；\(earlyCheck(r3, expectNew: true))")
        print("[\(agent)] 测试会话：\(conv) \(r3.res["conversationId"] ?? "")")
    case "orphan":   // 命令正在跑的时候点停止：CLI 启动的命令也要一起结束
        guard args.count >= 4 else { print("用法：orphan <agent> <目录> <秒数>"); return }
        let agent = args[1], ws = args[2], secs = args[3]
        let perms = ["gemini": "bypassPermissions", "claude": "bypassPermissions", "gpt": "danger-full-access"]
        let req = AskRequest(agent: agent, reqId: 900, prompt: "请执行 shell 命令 sleep \(secs)，等它结束后回复 done。", model: "",
                             effort: "low", permissionMode: perms[agent] ?? "", workspace: ws, conversationId: "")
        let sem = DispatchSemaphore(value: 0)
        var cancelAt: Date?
        var final: [String: Any] = [:]
        d.jsSink = { name, payload in
            if name == "onAgentStep", cancelAt == nil, let st = payload["step"] as? [String: Any],
               st["kind"] as? String == "command", st["status"] as? String == "running" {
                cancelAt = Date()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { d.cancel(agent: agent) }   // 命令开始 3 秒后停止
            }
            if name == "onAgentResponse" { final = payload; sem.signal() }
        }
        d.ask(req)
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if cancelAt == nil { d.cancel(agent: agent) } }
        _ = sem.wait(timeout: .now() + 180)
        d.jsSink = nil
        Thread.sleep(forTimeInterval: 5)   // 等 SIGTERM / SIGKILL 生效
        let pg = Process()
        pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pg.arguments = ["-f", "sleep \(secs)"]
        let pipe = Pipe()
        pg.standardOutput = pipe
        try? pg.run()
        pg.waitUntilExit()
        let left = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").filter { !$0.isEmpty } ?? []
        print("[\(agent)] 命令开始后停止：\(cancelAt == nil ? "没看到命令开始（90 秒后强制停止）" : "已停止")，cancelled=\(final["cancelled"] ?? "-")，"
              + "残留的 sleep \(secs) 进程：\(left.isEmpty ? "无 ✓" : "\(left) ✗")，conv=\(final["conversationId"] ?? "")")
    case "models":   // 模型菜单里的每个模型用默认思考强度发一句（只读模式），看 CLI 认不认
        guard args.count >= 3 else { print("用法：models <agent> <目录>"); return }
        let agent = args[1], ws = args[2]
        let lists: [String: (models: [String], effort: String, perm: String)] = [
            "gemini": (["gemini-4-argon", "gemini-3.8-flash", "claude-opus-5-5", "claude-sonnet-5-5", "gpt-oss-120b"], "medium", "plan"),
            "claude": (["claude-opus-5-5", "claude-fable-5-1[1m]", "claude-sonnet-5-5", "haiku"], "medium", "plan"),
            "gpt": (["gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-reserve"], "ultra", "read-only"),
        ]
        guard let cfg = lists[agent] else { print("未知 agent"); return }
        var convs: [String] = []
        for (k, model) in cfg.models.enumerated() {
            let req = AskRequest(agent: agent, reqId: 500 + k, prompt: "只回复 OK 两个字母。", model: model, effort: cfg.effort,
                                 permissionMode: cfg.perm, workspace: ws, conversationId: "")
            let t0 = Date()
            guard let res = waitFor(d, "onAgentResponse", timeout: 300, { d.ask(req) }) else { print("[\(agent)] \(model)：超时 ✗"); continue }
            let reply = (res["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = reply.uppercased().contains("OK") && !reply.hasPrefix("⚠️")
            if let c = res["conversationId"] as? String, !c.isEmpty { convs.append(c) }
            print("[\(agent)] \(model)：\(ok ? "✓" : "✗") \(String(format: "%.0f", Date().timeIntervalSince(t0)))s  \(preview(reply, 160))")
        }
        print("[\(agent)] 测试会话：\(convs.joined(separator: " "))")
    case "parallel":   // 同一位同时跑两个会话：B 先回答完，A 还在跑；再单独停止 A，B 不受影响
        guard args.count >= 3 else { print("用法：parallel <agent> <目录>"); return }
        let agent = args[1], ws = args[2]
        let perms = ["gemini": "bypassPermissions", "claude": "bypassPermissions", "gpt": "danger-full-access"]
        let lock = NSLock()
        var done: [Int: (res: [String: Any], at: Date)] = [:]
        let sem = DispatchSemaphore(value: 0)
        d.jsSink = { name, payload in
            guard name == "onAgentResponse", let r = payload["reqId"] as? Int else { return }
            lock.lock(); done[r] = (payload, Date()); lock.unlock()
            sem.signal()
        }
        let t0 = Date()
        let a = AskRequest(agent: agent, reqId: 1, prompt: "请执行 shell 命令 sleep 30，结束后回复 A。", model: "", effort: "low",
                           permissionMode: perms[agent] ?? "", workspace: ws, conversationId: "")
        let b = AskRequest(agent: agent, reqId: 2, prompt: "只回复字母 B。", model: "", effort: "low",
                           permissionMode: perms[agent] ?? "", workspace: ws, conversationId: "")
        d.ask(a)
        d.ask(b)
        _ = sem.wait(timeout: .now() + 180)   // 等第一个回答（应该是 B）
        lock.lock(); let firstDone = done.keys.sorted(); lock.unlock()
        d.cancel(agent: agent, reqId: 1)   // 只停 A
        _ = sem.wait(timeout: .now() + 60)
        lock.lock(); let all = done; lock.unlock()
        d.jsSink = nil
        let rb = all[2]?.res, ra = all[1]?.res
        print("[\(agent)] 先完成的：\(firstDone == [2] ? "B ✓" : "\(firstDone) ✗")；"
              + "B 回复=\(preview(rb?["reply"] as? String ?? "（无）", 30)) 用时 \(String(format: "%.0f", (all[2]?.at ?? Date()).timeIntervalSince(t0)))s，"
              + "A cancelled=\(ra?["cancelled"] ?? "-") 用时 \(String(format: "%.0f", (all[1]?.at ?? Date()).timeIntervalSince(t0)))s")
        print("[\(agent)] 两个会话不同：\((ra?["conversationId"] as? String ?? "a") != (rb?["conversationId"] as? String ?? "a") ? "✓" : "✗")  conv A=\(ra?["conversationId"] ?? "") B=\(rb?["conversationId"] ?? "")")
    case "docpreview":   // 文档预览：每个文件转一次（第二次应该直接用缓存），打印生成的文件和用时
        guard args.count >= 2 else { print("用法：docpreview <文件>…"); return }
        for path in args.dropFirst() {
            for round in ["生成", "缓存"] {
                let t0 = Date()
                let r = makeDocumentPreview(path)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let origin = documentPreviewOrigin(r.file)
                print("[\((path as NSString).lastPathComponent)] \(round) \(ms)ms → \(r.file?.lastPathComponent ?? "失败：\(r.error)")"
                      + (r.file == nil ? "" : "  原文件对得上：\(origin == path ? "✓" : "✗ \(origin ?? "nil")")  目录：\(r.file!.deletingLastPathComponent().path)"))
            }
        }
    case "docbrowser":   // 真的走内置浏览器：openInBrowser → 转换 → 载入；看地址栏回报、选字、改了文件刷新会重新生成、坏文件的提示、停止
        guard args.count >= 3 else { print("用法：docbrowser <文档> <临时目录>"); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        d.container = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        win.contentView = d.container
        var states: [[String: Any]] = []
        d.jsSink = { name, payload in if name == "onBrowserState" { states.append(payload) } }
        func spin(_ timeout: TimeInterval, until cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return cond()
        }
        func js(_ code: String) -> Any? {
            var out: Any?, done = false
            d.browser?.evaluateJavaScript(code) { r, e in out = r ?? e; done = true }
            _ = spin(10) { done }
            return out
        }
        let ok = { (b: Bool) in b ? "✓" : "✗" }
        let tmp = args[2]
        let doc = tmp + "/预览测试 文档.docx"   // 带空格和中文的文件名
        try? FileManager.default.removeItem(atPath: doc)
        try? FileManager.default.copyItem(atPath: args[1], toPath: doc)
        let std = { (p: String) in (p as NSString).standardizingPath }   // /private/tmp 会被系统写成 /tmp，比较前统一
        let docURL = URL(fileURLWithPath: std(doc)).absoluteString
        // 1. 打开：地址栏显示原文件，标签是文件名，浏览器里是缓存的预览网页
        d.openInBrowser(["path": doc])
        let loaded = spin(15) { (states.last?["url"] as? String) == docURL && states.last?["loading"] as? Bool == false && d.browser?.url?.path.hasSuffix("Preview.html") == true }
        let st = states.last ?? [:]
        print("打开 \(ok(loaded))：url 对得上 \(ok(st["url"] as? String == docURL))，title=\(st["title"] ?? "")，file 对得上 \(ok(st["file"] as? String == std(doc)))，error=\(st["error"] ?? "")")
        print("   中间回报过「正在生成预览…」：\(ok(states.contains { $0["title"] as? String == "正在生成预览…" }))；浏览器实际载入：\(d.browser?.url?.deletingLastPathComponent().lastPathComponent ?? "")/Preview.html")
        _ = spin(1.5) { false }
        let sel = js("(() => { const s = getSelection(); s.removeAllRanges(); const r = document.createRange(); r.selectNodeContents(document.body); s.addRange(r); const n = s.toString().length; s.removeAllRanges(); return n + ' 字，缩放 ' + (document.body.style.zoom || '1'); })()")
        print("   选中全文：\(sel ?? "nil")")
        // 2. 文件被改了：刷新 → 重新生成（换了缓存目录）
        let firstDir = d.browser?.url?.deletingLastPathComponent().path ?? ""
        Thread.sleep(forTimeInterval: 1.1)   // 修改时间要变
        if let h = FileHandle(forWritingAtPath: doc) { h.seekToEndOfFile(); h.write(Data(" ".utf8)); h.closeFile() }   // zip 末尾多一个空格，仍能打开
        states.removeAll()
        d.browserCommand("reload")
        let reloaded = spin(15) { d.browser?.url?.deletingLastPathComponent().path != firstDir && d.browser?.isLoading == false && d.browser?.url?.path.hasSuffix("Preview.html") == true }
        print("改了再刷新 \(ok(reloaded))：新目录 \(d.browser?.url?.deletingLastPathComponent().lastPathComponent ?? "")，地址栏仍是原文件 \(ok(states.last?["url"] as? String == docURL))")
        // 3. 坏文件：错误页，地址栏显示它，file 也给（「用默认应用打开」能用）
        let bad = tmp + "/坏掉的.docx"
        try? "not a zip".write(toFile: bad, atomically: true, encoding: .utf8)
        states.removeAll()
        d.openInBrowser(["path": bad])
        let failed = spin(15) { states.last?["error"] as? Bool == true }
        let fs = states.last ?? [:]
        print("坏文件 \(ok(failed))：title=\(fs["title"] ?? "")，url 对得上 \(ok(fs["url"] as? String == URL(fileURLWithPath: std(bad)).absoluteString))，file 对得上 \(ok(fs["file"] as? String == std(bad)))")
        // 4. 刷新坏文件：重试一次，还是错误页
        states.removeAll()
        d.browserCommand("reload")
        print("   刷新重试 \(ok(spin(15) { states.last?["error"] as? Bool == true }))")
        // 5. 生成中点停止：不再显示那个文档，地址栏回到当前页
        let other = tmp + "/另一个.docx"
        try? FileManager.default.removeItem(atPath: other)
        try? FileManager.default.copyItem(atPath: args[1], toPath: other)
        Thread.sleep(forTimeInterval: 1.1)
        if let h = FileHandle(forWritingAtPath: other) { h.seekToEndOfFile(); h.write(Data("  ".utf8)); h.closeFile() }   // 保证没有缓存
        d.openInBrowser(["path": other])
        d.browserCommand("stop")
        _ = spin(2) { false }
        print("生成中停止 \(ok(d.browser?.url.flatMap { documentPreviewOrigin($0) } != std(other)))：最后回报 title=\(states.last?["title"] ?? "")，loading=\(states.last?["loading"] ?? "")")
        // 5b. 转换很慢（面板上盖着「正在生成预览」）时点停止：去掉遮盖，留在原来的页面，不被转换结果覆盖
        Thread.sleep(forTimeInterval: 1.1)
        if let h = FileHandle(forWritingAtPath: other) { h.seekToEndOfFile(); h.write(Data(" ".utf8)); h.closeFile() }
        let before = d.browser?.url
        states.removeAll()
        d.openInBrowser(["path": other])
        d.docPreviewSlow = true; d.sendBrowserState()   // 模拟超过 0.6 秒的情形（中间不转 run loop，转换结果还没回来）
        let slowReported = states.last?["slow"] as? Bool == true
        d.browserCommand("stop")
        let st5 = states.last ?? [:]
        _ = spin(1.5) { false }
        print("慢的时候停止 \(ok(slowReported && st5["slow"] as? Bool == false && st5["loading"] as? Bool == false))：回报过 slow \(ok(slowReported))，停止后 slow=\(st5["slow"] ?? "")，loading=\(st5["loading"] ?? "")")
        print("   停止后留在原来的页面 \(ok(d.browser?.url == before))")
        states.removeAll()
        d.openInBrowser(["path": other])
        print("   再打开正常生成 \(ok(spin(15) { d.browser.flatMap { documentPreviewOrigin($0.url) } == std(other) && states.last?["loading"] as? Bool == false }))")
        // 6. 后退回到改过的那份预览：地址栏还是原文件
        let hist = { () -> String in
            guard let b = d.browser else { return "" }
            let name = { (u: URL) -> String in documentPreviewOrigin(u).map { ($0 as NSString).lastPathComponent } ?? u.absoluteString }
            return (b.backForwardList.backList.map { name($0.url) } + ["【\(b.url.map(name) ?? "")】"]).suffix(5).joined(separator: " → ")
        }
        states.removeAll()
        d.openInBrowser(["path": doc])
        _ = spin(15) { (states.last?["url"] as? String) == docURL && states.last?["loading"] as? Bool == false && d.browser?.url?.path.hasSuffix("Preview.html") == true }
        _ = spin(15) { d.browser?.isLoading == false && (d.browser?.estimatedProgress ?? 0) >= 1 }
        _ = spin(0.5) { false }   // 等真正载入完成（进了历史记录）再开下一个
        print("   6.1 之后：\(hist())  状态：\(states.suffix(4).map { "\($0["title"] ?? "")/\($0["loading"] ?? "")" })")
        d.openInBrowser(["path": bad])
        _ = spin(15) { states.last?["error"] as? Bool == true }
        _ = spin(0.5) { false }
        print("   6.2 之后：\(hist())")
        print("   后退前的历史：\(hist())")
        d.browserCommand("back")
        let back = spin(10) { (states.last?["url"] as? String) == docURL && states.last?["error"] as? Bool == false }
        print("后退回到文档预览 \(ok(back))：title=\(states.last?["title"] ?? "")")
        d.jsSink = nil
    case "weberror":   // 内置浏览器的错误页：打不开 → 刷新还打不开（不多占历史）→ 服务器起来后刷新 → 正常显示、错误状态清掉
        guard args.count >= 3, let port = Int(args[1]) else { print("用法：weberror <空闲端口> <临时目录>"); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        d.container = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        win.contentView = d.container
        var states: [[String: Any]] = []
        d.jsSink = { name, payload in if name == "onBrowserState" { states.append(payload) } }
        func spin(_ timeout: TimeInterval, until cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return cond()
        }
        let ok = { (b: Bool) in b ? "✓" : "✗" }
        let site = "http://127.0.0.1:\(port)/"
        let first = args[2] + "/first.html"
        try? "<meta charset=\"utf-8\"><title>第一页</title><p>first</p>".write(toFile: first, atomically: true, encoding: .utf8)
        d.openInBrowser(["path": first])
        _ = spin(10) { d.browser?.url?.lastPathComponent == "first.html" && d.browser?.isLoading == false }
        _ = spin(0.5) { false }
        d.openInBrowser(["url": site])
        let failed = spin(15) { states.last?["error"] as? Bool == true && states.last?["url"] as? String == site }
        _ = spin(10) { d.browser?.url?.absoluteString == site && d.browser?.isLoading == false }   // 错误页真正载入（进了历史）
        let backCount = d.browser?.backForwardList.backList.count ?? -1
        let short = { (u: URL) in u.isFileURL ? u.lastPathComponent : u.absoluteString }
        let hist = { () -> String in guard let b = d.browser else { return "" }; return (b.backForwardList.backList.map { short($0.url) } + ["【\(b.url.map(short) ?? "nil")】"] + b.backForwardList.forwardList.map { short($0.url) }).joined(separator: " → ") }
        print("   历史：\(hist())")
        print("打不开 \(ok(failed))：title=\(states.last?["title"] ?? "")，地址栏 \(states.last?["url"] ?? "")，历史里前一页还在 \(ok(d.browser?.backForwardList.backItem?.url.lastPathComponent == "first.html"))")
        d.browserCommand("reload")
        _ = spin(3) { false }
        print("刷新还是打不开 \(ok(states.last?["error"] as? Bool == true))：没多占历史 \(ok((d.browser?.backForwardList.backList.count ?? -2) == backCount))")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", args[2]]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try? server.run()
        _ = spin(2) { false }
        states.removeAll()
        d.browserCommand("reload")
        let up = spin(15) { states.last?["error"] as? Bool == false && states.last?["loading"] as? Bool == false && (states.last?["title"] as? String ?? "").contains("Directory") }
        print("服务器起来后刷新 \(ok(up))：title=\(states.last?["title"] ?? "")，error=\(states.last?["error"] ?? "")，没多占历史 \(ok((d.browser?.backForwardList.backList.count ?? -2) == backCount))")
        print("   刷新后历史：\(hist())")
        d.browserCommand("back")
        print("后退回到前一页 \(ok(spin(10) { states.last?["title"] as? String == "第一页" }))：\(hist())  最后几次回报：\(states.suffix(3).map { "\($0["title"] ?? "")|\($0["url"] ?? "")" })")
        server.terminate()
        d.jsSink = nil
    case "dump":   // 导出最近会话的消息（JSON），给网页渲染测试用；会话内容只写到本地文件
        guard args.count >= 2 else { print("用法：dump <输出.json> [每位条数]"); return }
        let limit = args.count >= 3 ? Int(args[2]) ?? 12 : 12
        var all: [[String: Any]] = []
        for agent in ["gemini", "claude", "gpt"] {
            guard let listed = waitFor(d, "onConversationsListed", { d.listConversations(agent: agent) }),
                  let items = listed["items"] as? [[String: Any]] else { continue }
            for item in items.prefix(limit) {
                guard let cid = item["id"] as? String else { continue }
                let t0 = Date()
                guard let loaded = waitFor(d, "onConversationLoaded", { d.loadConversation(agent: agent, cid: cid) }) else { continue }
                all.append(["agent": agent, "id": cid, "title": item["title"] ?? "", "loadSecs": Date().timeIntervalSince(t0),
                            "messages": loaded["messages"] ?? []])
            }
        }
        // 找出不能转成 JSON 的会话（例如 NaN），跳过并报告
        let ok = all.filter { conv in
            if JSONSerialization.isValidJSONObject(conv) { return true }
            print("  ✗ 不能转成 JSON：\(conv["agent"] ?? "") \(conv["id"] ?? "") \(conv["title"] ?? "")")
            return false
        }
        do {
            try JSONSerialization.data(withJSONObject: ok).write(to: URL(fileURLWithPath: args[1]))
        } catch { print("写入失败：\(error)") }
        print("导出 \(ok.count)/\(all.count) 个会话")
    case "deleteproject":   // 和界面里「删除项目」走同一条路：先统计这个工作空间的全部会话，再一起删
        guard args.count >= 3 else { print("用法：deleteproject <agent> <工作空间路径>"); return }
        let found = waitFor(d, "onProjectConversations") { d.projectConversations(agent: args[1], workspace: args[2]) }
        let ids = found?["ids"] as? [String] ?? []
        guard !ids.isEmpty else { print("\(args[1])：\(args[2]) 里没有会话"); return }
        let res = waitFor(d, "onConversationsDeleted") { d.deleteConversations(agent: args[1], ids: ids) }
        let deleted = res?["deleted"] as? [String] ?? [], failed = res?["failed"] as? [String] ?? []
        let left = (waitFor(d, "onProjectConversations") { d.projectConversations(agent: args[1], workspace: args[2]) })?["ids"] as? [String] ?? []
        print("\(args[1])：找到 \(ids.count) 个，删除 \(deleted.count) 个，失败 \(failed.count) 个，删除后还剩 \(left.count) 个")
    case "deletemany":
        guard args.count >= 3 else { print("用法：deletemany <agent> <会话ID>…"); return }
        let res = waitFor(d, "onConversationsDeleted") { d.deleteConversations(agent: args[1], ids: Array(args.dropFirst(2))) }
        print("批量删除 \(args[1])：deleted=\(res?["deleted"] ?? "超时") failed=\(res?["failed"] ?? "-")")
    case "proc":
        var t0 = Date()
        var r = d.runCLI(agent: "gemini", executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], cwd: d.home)
        print("普通：out=\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) err=\(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) status=\(r.status) \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

        t0 = Date()
        r = d.runCLI(agent: "gemini", executable: "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' x; echo"], cwd: d.home)
        print("大输出：\(r.out.count) 字节 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

        t0 = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { d.cancel(agent: "claude") }
        r = d.runCLI(agent: "claude", executable: "/bin/sleep", arguments: ["30"], cwd: d.home)
        print("停止：cancelled=\(r.cancelled) status=\(r.status) \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

        t0 = Date()
        r = d.runCLI(agent: "gpt", executable: "/bin/sh", arguments: ["-c", "sleep 8 & echo hi"], cwd: d.home)
        print("后台孙进程占着管道：out=\(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) \(String(format: "%.2f", Date().timeIntervalSince(t0)))s（应约 3s 而不是 8s）")
    case "ask":
        guard args.count >= 4 else { print("用法：ask <agent> <权限> <提示词> [工作空间]"); return }
        let agent = args[1], perm = args[2], prompt = args[3]
        let workspace = args.count >= 5 ? args[4] : ""
        let req = AskRequest(agent: agent, reqId: 1, prompt: prompt, model: args.count >= 6 ? args[5] : "", effort: "low", permissionMode: perm,
                             workspace: workspace, conversationId: "")
        let sem = DispatchSemaphore(value: 0)
        var liveSteps: [String] = []
        var final: [String: Any] = [:]
        d.jsSink = { name, payload in
            if name == "onAgentStep", let st = payload["step"] as? [String: Any] {
                liveSteps.append("#\(payload["index"] ?? "?") [\(st["kind"] ?? "")] \(st["title"] ?? "") \(st["status"] ?? "")")
            } else if name == "onAgentResponse" {
                final = payload
                sem.signal()
            }
        }
        let t0 = Date()
        d.ask(req)
        _ = sem.wait(timeout: .now() + 300)
        d.jsSink = nil
        print("实时步骤事件 \(liveSteps.count) 个：")
        liveSteps.prefix(12).forEach { print("   \($0)") }
        print("用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s conv=\(final["conversationId"] ?? "")")
        var bot = final
        bot["role"] = "bot"
        bot["text"] = final["reply"]
        printMessage(bot)
    default:
        print("未知子命令")
    }
}
