import Cocoa
import WebKit
import SQLite3

private func runPreviewFixTests() -> Int {
    NSApplication.shared.setActivationPolicy(.accessory)
    let d = AppDelegate(), fm = FileManager.default
    let dir = ((NSTemporaryDirectory() + "aipethub-fixes-" + UUID().uuidString) as NSString).resolvingSymlinksInPath
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var failures = 0, checks = 0
    func check(_ ok: Bool, _ label: String) {
        checks += 1
        if !ok { failures += 1; print("✗ \(label)") }
    }
    func write(_ name: String, _ content: String) { try! content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
    // 条件一成立就返回，期限只防卡死：机器忙（几个 agent 同时编译、测试）时，起一个假转换器就要好几秒
    func spin(_ seconds: Double = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    func reply(_ name: String, _ trigger: () -> Void) -> [String: Any] {
        let lock = NSLock(); var result: [String: Any]?
        d.jsSink = { n, p in if n == name { lock.lock(); result = p; lock.unlock() } }
        trigger()
        _ = spin { lock.lock(); defer { lock.unlock() }; return result != nil }
        d.jsSink = nil
        return result ?? [:]
    }
    // 假转换器用 `echo pid > 文件` 记下子进程：文件先建出来（空的）才写进内容，所以等到读得出 pid 才算数。
    // 等不到就记一条失败往下走，不用 try! 崩掉整个程序（那样后面的检查都没跑，结果也打不出来）。
    func childPid(_ name: String, _ label: String) -> pid_t? {
        var pid: pid_t?
        check(spin(60) {
            pid = (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }, label)
        return pid
    }
    func git(_ args: [String]) -> String {
        let result = d.runGit(args, in: dir)
        check(result != nil, "fixture git \(args.first ?? "")")
        return result ?? ""
    }
    _ = git(["init", "-q"])
    _ = git(["config", "user.name", "Fixture"]); _ = git(["config", "user.email", "fixture@example.invalid"])
    write("dirty.txt", "base\noriginal\n")
    write("restore.txt", "clean\n")
    write("delete tracked.txt", "tracked\n")
    try! Data([0, 5, 6]).write(to: URL(fileURLWithPath: dir + "/existing.bin"))
    _ = git(["add", "."]); _ = git(["commit", "-qm", "fixture"])
    write("dirty.txt", "user change\noriginal\n")
    _ = git(["add", "dirty.txt"])   // 用户已有的暂存内容也必须保留
    write("restore.txt", "dirty\n")
    write("old untracked.txt", "old content\n")
    let index = try! Data(contentsOf: URL(fileURLWithPath: dir + "/.git/index"))
    let head = git(["rev-parse", "HEAD"])
    let before = d.gitSnapshot(dir)!
    if before.content == nil {
        // 内容快照没拍成（会悄悄退回旧的状态对比，下面几条就会失败）：把是哪一步、git 报了什么打出来。
        // 不同版本的 git 行为不一样，本机过了别的机器不一定过。
        let tmp = NSTemporaryDirectory() + "aipethub-snapdiag-\(getpid())"
        try? fm.createDirectory(atPath: tmp + "/objects/info", withIntermediateDirectories: true)
        let objects = d.runGit(["rev-parse", "--path-format=absolute", "--git-path", "objects"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? (objects + "\n").write(toFile: tmp + "/objects/info/alternates", atomically: true, encoding: .utf8)
        try? fm.copyItem(atPath: dir + "/.git/index", toPath: tmp + "/index")
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_INDEX_FILE"] = tmp + "/index"; env["GIT_OBJECT_DIRECTORY"] = tmp + "/objects"; env["GIT_LITERAL_PATHSPECS"] = "1"
        print("快照诊断：git=\(d.gitPath ?? "无") \(d.runTool(d.gitPath ?? "/usr/bin/git", ["--version"], cwd: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)) objects=\(objects)")
        for args in [["rev-parse", "--path-format=absolute", "--git-path", "index"],
                     ["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
                     ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false", "add", "-u", "--", "."],
                     ["write-tree"], ["ls-files", "-z", "--cached"]] {
            let r = d.runTool(d.gitPath ?? "/usr/bin/git", ["-C", dir] + args, cwd: dir, environment: env, timeout: 30)
            print("快照诊断：git \(args.joined(separator: " ")) → \(r.status) \(r.err.prefix(300).replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        try? fm.removeItem(atPath: tmp)
    }
    write("dirty.txt", "user change\nAI change\n")
    write("restore.txt", "clean\n")
    try! fm.removeItem(atPath: dir + "/old untracked.txt")
    try! fm.removeItem(atPath: dir + "/delete tracked.txt")
    try! Data([0, 7, 8, 9]).write(to: URL(fileURLWithPath: dir + "/existing.bin"))
    try! fm.createDirectory(atPath: dir + "/子目录", withIntermediateDirectories: true)
    write("子目录/新 文件.txt", "new\n")
    try! Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: dir + "/binary.bin"))
    let changes = d.gitChangedFiles(since: before)
    func change(_ name: String) -> [String: Any]? { changes.first { $0["path"] as? String == before.root + "/" + name } }
    let diff = change("dirty.txt")?["diff"] as? String ?? ""
    check(diff.contains("-original") && diff.contains("+AI change") && !diff.contains("+user change") && !diff.contains("-base"), "N02 只算本轮新增差异")
    check(change("restore.txt")?["kind"] as? String == "edit", "N03 改回干净仍报 edit")
    check(change("old untracked.txt")?["kind"] as? String == "delete", "N03 删除原有未跟踪文件")
    check(change("子目录/新 文件.txt")?["kind"] as? String == "create", "N03 空格中文子目录新增")
    check(change("binary.bin")?["kind"] as? String == "create", "N03 二进制新增")
    check(change("existing.bin")?["kind"] as? String == "edit" && change("existing.bin")?["diff"] as? String == "", "N02 二进制修改保持空 diff")
    check(change("delete tracked.txt")?["kind"] as? String == "delete", "N03 已跟踪文件删除")
    check((try! Data(contentsOf: URL(fileURLWithPath: dir + "/.git/index"))) == index, "快照不改变真实 index 字节")
    check(git(["rev-parse", "HEAD"]) == head && git(["stash", "list"]).isEmpty, "快照不改变 HEAD/stash")

    // 大文件走轻量路径，不能落到真实对象库；覆盖大小阈值跨越和删掉大文件。
    let largePath = dir + "/dataset.bin"
    fm.createFile(atPath: largePath, contents: nil)
    let largeHandle = try! FileHandle(forWritingTo: URL(fileURLWithPath: largePath))
    try! largeHandle.truncate(atOffset: 200_000_000); try! largeHandle.close()
    let objectFiles = (fm.enumerator(atPath: dir + "/.git/objects")?.allObjects as? [String] ?? []).sorted()
    let largeBefore = d.gitSnapshot(dir)!
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: largePath)
    let largeChange = d.gitChangedFiles(since: largeBefore).first { ($0["path"] as? String)?.hasSuffix("/dataset.bin") == true }
    check(largeChange?["kind"] as? String == "edit" && largeChange?["diff"] as? String == "", "N02 大文件只报变化")
    check((fm.enumerator(atPath: dir + "/.git/objects")?.allObjects as? [String] ?? []).sorted() == objectFiles, "快照不向真实对象库写文件")
    try! fm.removeItem(atPath: largePath)
    check(d.gitChangedFiles(since: largeBefore).contains { ($0["path"] as? String)?.hasSuffix("/dataset.bin") == true && $0["kind"] as? String == "delete" }, "N03 删除大文件")
    let savedGit = d.gitPath; d.gitPath = nil
    check(d.gitSnapshot(dir) == nil, "git 不可用沿用无快照行为")
    d.gitPath = savedGit

    let budgetRepo = dir + "/budget"
    try! fm.createDirectory(atPath: budgetRepo, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: budgetRepo)
    for i in 0..<17 { try! Data(repeating: 66, count: 1_000_000).write(to: URL(fileURLWithPath: budgetRepo + String(format: "/b%02d", i))) }
    let budgetBefore = d.gitSnapshot(budgetRepo)!
    try! Data(repeating: 65, count: 1_000_000).write(to: URL(fileURLWithPath: budgetRepo + "/a-new"))
    let budgetChanges = d.gitChangedFiles(since: budgetBefore)
    check(budgetChanges.count == 1 && (budgetChanges.first?["path"] as? String)?.hasSuffix("/a-new") == true, "N02 内容预算移动不误报未变化文件")
    // 无仓库与 write-tree 失败都回退；失败夹具只影响本测试的 git wrapper。
    let plain = NSTemporaryDirectory() + "aipethub-plain-" + UUID().uuidString
    try! fm.createDirectory(atPath: plain, withIntermediateDirectories: true)
    check(d.gitSnapshot(plain) == nil, "非 git 仓库沿用无快照行为")
    try! fm.removeItem(atPath: plain)
    let failingGit = dir + "/failing-git"
    try! installFakeCLI(at: failingGit, behavior: "git-write-tree-fail", parameters: [savedGit!])
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingGit)
    d.gitPath = failingGit
    let fallback = d.gitSnapshot(dir)!
    write("fallback-new.txt", "fallback\n")
    check(d.gitChangedFiles(since: fallback).contains { ($0["path"] as? String)?.hasSuffix("/fallback-new.txt") == true }, "快照失败回退旧改动行为")
    d.gitPath = savedGit

    // git clean 过滤器可能写 LFS/工作区；内容快照不得执行它。
    _ = git(["config", "filter.fixture.clean", "touch filter-ran; cat"])
    write(".gitattributes", "*.filtered filter=fixture\n")
    write("sample.filtered", "raw working content\n")
    // 这时工作区里有一个已跟踪的文件被删了（前面删的 delete tracked.txt）：有过滤器时也要拍得成。
    // 装了 Git LFS 的机器全局就带着过滤器，CI 的机器就是这样，这条在那里失败过。
    check(d.gitSnapshot(dir)?.content != nil, "有过滤器、又有已跟踪文件被删时，内容快照照样拍得成")
    check(!fm.fileExists(atPath: dir + "/filter-ran"), "内容快照不运行有副作用的 clean 过滤器")
    // split index 也只在临时文件里操作；真实 index 与已有共享 index 保持逐字节一致。
    _ = git(["update-index", "--split-index"])
    let indexes = ((try? fm.contentsOfDirectory(atPath: dir + "/.git")) ?? []).filter { $0 == "index" || $0.hasPrefix("sharedindex.") }
    let indexData = Dictionary(uniqueKeysWithValues: indexes.map { ($0, try! Data(contentsOf: URL(fileURLWithPath: dir + "/.git/" + $0))) })
    _ = d.gitSnapshot(dir)
    check(indexData.allSatisfy { (try? Data(contentsOf: URL(fileURLWithPath: dir + "/.git/" + $0.key))) == $0.value }, "split index 快照不更改真实 index")

    let filterRepo = dir + "/filter-repo"
    try! fm.createDirectory(atPath: filterRepo, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: filterRepo)
    _ = d.runGit(["config", "filter.upper.clean", "tr a-z A-Z"], in: filterRepo)
    try! "*.filtered filter=upper\n".write(toFile: filterRepo + "/.gitattributes", atomically: true, encoding: .utf8)
    try! "user line\noriginal\n".write(toFile: filterRepo + "/f.filtered", atomically: true, encoding: .utf8)
    _ = d.runGit(["add", "."], in: filterRepo)
    _ = d.runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "filtered"], in: filterRepo)
    let filteredBefore = d.gitSnapshot(filterRepo)!
    try! "user line\nai change\n".write(toFile: filterRepo + "/f.filtered", atomically: true, encoding: .utf8)
    let filteredDiff = d.gitChangedFiles(since: filteredBefore).first?["diff"] as? String ?? ""
    check(filteredDiff.contains("-original") && filteredDiff.contains("+ai change") && !filteredDiff.contains("+user line"), "N02 过滤器仓库也比较两次原始工作区内容")

    write("mixed.jsonl", #"{"type":"user","message":{"role":"user","content":"aBcDeF"}}"#)
    let found = reply("onConversationsSearched") { d.searchConversations(agent: "claude", query: "abcdef", files: [("mixed", dir + "/mixed.jsonl")]) }
    check(found["ids"] as? [String] == ["mixed"], "N04 任意英文大小写")
    var db: OpaquePointer?
    check(sqlite3_open((dir + "/wal.db"), &db) == SQLITE_OK, "WAL 夹具打开")
    sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE steps(idx INTEGER, step_type INTEGER, step_payload BLOB); PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
    sqlite3_exec(db, "INSERT INTO steps VALUES(0,14,X'9a010f120d57614c4f6e6c794e6565646c65'); INSERT INTO steps VALUES(1,15,X'a201080a06616e73776572');", nil, nil, nil)
    let wal = reply("onConversationsSearched") { d.searchConversations(agent: "gemini", query: "walonlyneedle", files: [("wal", dir + "/wal.db")]) }
    check(wal["ids"] as? [String] == ["wal"], "N06 搜到尚未 checkpoint 的 WAL")
    sqlite3_exec(db, "DELETE FROM steps;", nil, nil, nil)
    let deleted = reply("onConversationsSearched") { d.searchConversations(agent: "gemini", query: "walonlyneedle", files: [("wal", dir + "/wal.db")]) }
    check(deleted["ids"] as? [String] == [], "N06 已删除内容不命中")
    sqlite3_close(db)

    write("large.txt", String(repeating: "a", count: 400_001))
    try! fm.createSymbolicLink(atPath: dir + "/alias.txt", withDestinationPath: "large.txt")
    let file = reply("onFileRead") { d.readFileForPreview(path: dir + "/alias.txt", base: "", reqId: 1) }
    check(file["size"] as? Int == 400_001 && file["truncated"] as? Bool == true && file["path"] as? String == dir + "/alias.txt", "N07 链接目标大小和截断，保留原路径")
    write("large.png", String(repeating: "a", count: 8_000_001))
    try! fm.createSymbolicLink(atPath: dir + "/alias.png", withDestinationPath: "large.png")
    let largeImage = reply("onFileRead") { d.readFileForPreview(path: dir + "/alias.png", base: "", reqId: 2) }
    check(largeImage["error"] as? String == "图片太大，无法预览", "N07 链接图片大小限制")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    try! png.write(to: URL(fileURLWithPath: dir + "/small.png"))
    try! fm.createSymbolicLink(atPath: dir + "/thumb.png", withDestinationPath: "small.png")
    check(chatThumbnail(path: dir + "/thumb.png") != nil, "N07 符号链接缩略图")

    d.fileListCache["expired"] = (Date(timeIntervalSinceNow: -30), ["old"])
    for i in 0..<12 {
        let ws = dir + "/ws\(i)"; try! fm.createDirectory(atPath: ws, withIntermediateDirectories: true)
        _ = reply("onFilesListed") { d.listFiles(workspace: ws, query: "", reqId: i) }
    }
    check(d.fileListCache.count <= 8 && d.fileListCache["expired"] == nil, "C-N09 缓存有上限且清除过期项")

    d.container = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
    let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
    d.webView = HubWebView(frame: d.container.frame, configuration: cfg)
    write("A.html", "<title>A</title>A"); write("B.html", "<title>B</title>B")
    d.jsSink = { name, payload in
        // 复现真实前端：有 URL 才导航，空 URL 只切出面板。
        if name == "onBrowserToolOpen", let url = payload["url"] as? String, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d.openInBrowser(["path": url]) }
    }
    var first: [String: Any]?, second: [String: Any]?
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { first = $0 }
    d.browserTool("browser_open", ["url": dir + "/B.html"]) { second = $0 }
    check(spin { first != nil && second != nil }, "N01 两个请求均返回")
    check(first?["error"] as? Bool == true && (first?["text"] as? String ?? "").contains("取代"), "N01 A 明确报告被替代")
    check(second?["error"] as? Bool != true && (second?["text"] as? String ?? "").contains("B.html"), "N01 B 成功绑定自己的页面")
    var userReplaced: [String: Any]?
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { userReplaced = $0 }
    d.openInBrowser(["path": dir + "/B.html"])
    check(spin { userReplaced != nil } && userReplaced?["error"] as? Bool == true, "N01 用户导航取代工具请求")
    var sameFirst: [String: Any]?, sameLast: [String: Any]?
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { sameFirst = $0 }
    d.browserTool("browser_open", ["url": dir + "/A.html"]) { sameLast = $0 }
    check(spin { sameFirst != nil && sameLast != nil } && sameFirst?["error"] as? Bool == true && sameLast?["error"] as? Bool != true, "N01 同 URL 的不同导航也区分代次")
    d.jsSink = nil

    let converter = dir + "/converter"
    try! installFakeCLI(at: converter, behavior: "preview-slow", parameters: [dir])
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: converter)
    TestHooks.quickLookExecutable = converter
    for name in ["running.docx", "queued.docx", "latest.docx"] { write(name, name) }
    d.openDocumentPreview(dir + "/running.docx")
    let child = childPid("child", "N08 运行中转换启动")
    d.openDocumentPreview(dir + "/queued.docx")
    d.openDocumentPreview(dir + "/latest.docx")
    // running.docx 的子进程要睡 30 秒，10 秒内没了只能是被取消的
    check(child.map { pid in spin(10) { kill(pid, 0) != 0 } } ?? false, "N08 取消运行中的转换子进程")
    check(spin(60) { d.docPreviewPending == nil }, "N08 最新转换完成")
    let started = (try? String(contentsOfFile: dir + "/started", encoding: .utf8)) ?? ""
    check(!started.contains("queued.docx"), "N08 过期队列任务从未启动")
    // 独立转换入口超时，清理整个进程树，测试不启动 AppDelegate 来收尾。
    write("timeout.docx", "timeout")
    TestHooks.quickLookTimeout = 0.05
    try? fm.removeItem(atPath: dir + "/child")   // 上面 latest.docx 记下的 pid 早已退出，留着它这条检查就成了空检查
    // 等假转换器记下子进程的 pid 才开始算期限：这样「超时清理子进程」每次都有一个确定活着的子进程可查
    TestHooks.quickLookStarted = { _ = childPid("child", "整理：超时子进程已启动") }
    let timeoutResult = makeDocumentPreview(dir + "/timeout.docx")
    TestHooks.quickLookStarted = nil
    check(timeoutResult.file == nil && timeoutResult.error.contains("超时"), "整理：转换超时仍返回原错误")
    let timeoutChild = (try? String(contentsOfFile: dir + "/child", encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    check(timeoutChild.map { pid in spin(10) { kill(pid, 0) != 0 } } ?? false, "整理：超时清理子进程")
    TestHooks.quickLookTimeout = 60

    try! installFakeCLI(at: converter, behavior: "preview-stubborn", parameters: [dir])
    write("stubborn.docx", "stubborn")
    d.openDocumentPreview(dir + "/stubborn.docx")
    let stubborn = childPid("stubborn-child", "N08 顽固子进程启动")   // 假转换器装好 TERM handler 之后才写这个 pid
    d.cancelDocumentPreview()
    // 先 TERM、3 秒后 KILL；子进程自己永远不退出，期限放宽也分得出来
    check(stubborn.map { pid in spin(30) { kill(pid, 0) != 0 } } ?? false, "N08 忽略 TERM 的子进程最终被 KILL 清理")

    // 10,000 个已跟踪文件 + 24 个 200 MB 稀疏未跟踪文件，测量实际入口。
    let perf = dir + "/perf"
    try! fm.createDirectory(atPath: perf, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: perf)
    for i in 0..<10_000 { try! Data(repeating: 65, count: 512).write(to: URL(fileURLWithPath: perf + "/f\(i).txt")) }
    _ = d.runGit(["add", "."], in: perf)
    _ = d.runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], in: perf)
    for i in 0..<24 {
        let path = perf + "/large\(i).bin"; fm.createFile(atPath: path, contents: nil)
        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.truncate(atOffset: 200_000_000); try! handle.close()
    }
    var timings: [Double] = []
    for _ in 0..<3 {
        let start = Date(); let snapshot = d.gitSnapshot(perf)
        timings.append(Date().timeIntervalSince(start)); check(snapshot?.content != nil, "大仓库内容快照成功（没有退回状态比较）")
    }
    print("Snapshot benchmark: 10,000 tracked + 24 × 200 MB untracked, seconds=\(timings)")
    d.cancelDocumentPreview(); d.browser?.stopLoading()
    d.terminateAllChildren()
    try? fm.removeItem(atPath: dir); try? fm.removeItem(at: docPreviewRoot)
    print("Preview fixes checks=\(checks) failures=\(failures)")
    return failures
}

func runPreviewFixSuite() {
    let failures = runPreviewFixTests()   // 先离开作用域，释放临时内容快照，再退出进程
    exit(failures == 0 ? 0 : 1)
}
