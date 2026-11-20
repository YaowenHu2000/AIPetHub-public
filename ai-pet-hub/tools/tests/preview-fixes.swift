// 预览与改动归因的离线测试分三段：git（快照与改动归因，含大仓库快照）、browser（搜索、读文件、内置浏览器、表单提交）、
// docs（文档转换的取消和超时）。每段用自己的夹具（AppDelegate 和临时目录），段与段之间不共享状态，
// tools/test.sh 才能把三段分开并行跑；模拟装了 Git LFS 的那一遍也只需重跑会调 git 的 git 段。
import Cocoa
import WebKit

final class PreviewFixture {
    let d = AppDelegate(), fm = FileManager.default
    let dir = ((NSTemporaryDirectory() + "aipethub-fixes-" + UUID().uuidString) as NSString).resolvingSymlinksInPath
    init() { try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    func write(_ name: String, _ content: String) { try! content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
    func reply(_ name: String, _ trigger: () -> Void) -> [String: Any] { awaitCallback(d, name, runLoop: true, trigger) ?? [:] }
    // 假转换器用 `echo pid > 文件` 记下子进程：文件先建出来（空的）才写进内容，所以等到读得出 pid 才算数。
    // 等不到就记一条失败往下走，不用 try! 崩掉整个程序（那样后面的检查都没跑，结果也打不出来）。
    func childPid(_ name: String, _ label: String) -> pid_t? {
        var pid: pid_t?
        check(waitUntil(runLoop: true) {
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
    // 结束全部子进程会让 App 进入退出状态、之后不再起新进程，所以只在本进程最后一段跑完时做
    func cleanUp(endChildren: Bool) {
        d.cancelDocumentPreview(); d.browser?.stopLoading()
        if endChildren { d.terminateAllChildren() }
        try? fm.removeItem(atPath: dir); try? fm.removeItem(at: docPreviewRoot)
    }
}

func runPreviewFixSuite(_ parts: [String]) {
    let all = ["git", "browser", "docs"]
    guard parts.allSatisfy(all.contains) else { print("用法：build/selftest preview-fixes [git] [browser] [docs]（不写就按顺序全跑）"); exit(2) }
    NSApplication.shared.setActivationPolicy(.accessory)
    let chosen = parts.isEmpty ? all : parts
    for (i, part) in chosen.enumerated() {
        let fixture = PreviewFixture()   // 每段自己的夹具；段里的临时内容快照随函数返回释放，全部跑完再退出进程
        switch part {
        case "git": runPreviewGitTests(fixture)
        case "browser": runPreviewBrowserTests(fixture)
        default: runPreviewDocsTests(fixture)
        }
        fixture.cleanUp(endChildren: i == chosen.count - 1)
    }
    print("Preview fixes checks=\(checks) failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}

func runPreviewDocsTests(_ f: PreviewFixture) {
    let (d, fm, dir) = (f.d, f.fm, f.dir), write = f.write, childPid = f.childPid
    // 转换好的文档在内置浏览器里打开，要先有放网页的视图（全跑时原本由前面的 browser 段建好）
    d.container = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
    let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
    d.webView = HubWebView(frame: d.container.frame, configuration: cfg)
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
    check(child.map { pid in waitUntil(runLoop: true) { kill(pid, 0) != 0 } } ?? false, "N08 取消运行中的转换子进程")
    check(waitUntil(runLoop: true) { d.docPreviewPending == nil }, "N08 最新转换完成")
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
    check(timeoutChild.map { pid in waitUntil(runLoop: true) { kill(pid, 0) != 0 } } ?? false, "整理：超时清理子进程")
    TestHooks.quickLookTimeout = 60

    try! installFakeCLI(at: converter, behavior: "preview-stubborn", parameters: [dir])
    write("stubborn.docx", "stubborn")
    d.openDocumentPreview(dir + "/stubborn.docx")
    let stubborn = childPid("stubborn-child", "N08 顽固子进程启动")   // 假转换器装好 TERM handler 之后才写这个 pid
    d.cancelDocumentPreview()
    // 先 TERM、3 秒后 KILL；子进程自己永远不退出，期限放宽也分得出来
    check(stubborn.map { pid in waitUntil(runLoop: true) { kill(pid, 0) != 0 } } ?? false, "N08 忽略 TERM 的子进程最终被 KILL 清理")
}
