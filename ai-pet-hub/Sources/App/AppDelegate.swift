// 应用本体：窗口、界面所在的 WebView、三位共用的状态；启动和退出。
import Cocoa
import WebKit
import PDFKit

/// 一次回答从收到到答完的状态。键是「agent#reqId」，所有字段由 AppDelegate.procLock 保护。
struct AskState {
    var proc: Process?       // 准备期间、以及走共用服务的 DeepSeek 都没有自己的进程
    var live: LiveTurn?      // 当前交互式回答；重试、回退时可以换掉
    var cancelled = false   // 一旦停止就保持到这次回答结束
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    // MARK: 窗口和界面
    var window: HubWindow!
    var webView: HubWebView!                    // 界面本身（web/index.html）
    var indexURL: URL!
    var container: FlippedView!
    var dragTimer: Timer?                       // 拖动没有标题栏的窗口
    var dragStartMouse = NSPoint.zero
    var dragStartOrigin = NSPoint.zero
    var unseenReplies = 0                       // 在别的 App 里时回答完成的次数，显示在 Dock 图标上
    var terminationSignal: DispatchSourceSignal?   // SIGTERM 走正常退出流程（见 watchTerminationSignal）
    var terminationPrompting = false
    /// 自测（build/selftest，源码在 tools/tests/）时接收原本发给网页的消息。
    var jsSink: ((String, [String: Any]) -> Void)?

    var hooks = TestHooks()   // 只有自测程序会改它（Runtime/TestHooks.swift）

    // MARK: 内置浏览器和预览（Preview/）
    var browser: WKWebView?                     // 内置浏览器（预览本地网页、开发服务器）
    var browserKVO: [NSKeyValueObservation] = []
    var browserFailedURL = ""                   // 打不开时显示错误页，地址栏仍显示原来的网址
    var browserFailedTitle = "打不开"
    var browserPDF: PDFView?                    // 内置浏览器正在看本地 PDF 时盖在它上面：按面板宽度显示（见 Browser.swift 的 notePDF）
    var browserErrorNav: WKNavigation?          // 显示错误页的那次导航（它载入完成时不清掉错误状态）
    var browserSimulating: URL?                 // 正在给这个网址显示错误页：导航策略里放行，不当成文档再转一遍
    var browserPortName: String?                // 智能体用内置浏览器的入口（BrowserTools.swift）
    var browserJobs: [String: Data?] = [:]      // 进行中的浏览器操作：编号 → 结果（没好是 nil）
    let docPreviewQueue = DispatchQueue(label: "aipethub.docpreview")
    var docPreviewToken = 0                     // 每次打开新东西加一：转换完成时已经打开了别的，就不再显示
    var docPreviewPending: String?              // 正在生成预览的原文件：地址栏先显示它，刷新按钮转圈
    var docPreviewSlow = false                  // 转换超过 0.6 秒：面板上先显示「正在生成预览」
    var fileListCache: [String: (at: Date, files: [String])] = [:]   // @ 文件补全：工作空间 → 文件列表（ConversationSearch.swift）

    // MARK: 共用
    let home = NSHomeDirectory()
    let fm = FileManager.default
    let validAgents: Set<String> = ["gemini", "claude", "gpt", "deepseek"]
    /// 只用真正装好的 git（不用 /usr/bin/git：没装开发者工具时它会弹安装窗口）。
    let gitPathLock = NSLock()                  // lazy 的首次初始化也可能被多个后台请求同时触发
    lazy var gitPath: String? = findExecutable([
        "/opt/homebrew/bin/git", "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
    ])

    // MARK: 正在进行的回答（Runtime/）。下面这些都由 procLock 保护
    let procLock = NSLock()
    var asks: [String: AskState] = [:]             // ask 收到时建、完整收尾后删；独立调用 runCLI 时由 runCLI 临时拥有
    var warmProcs: [String: CLIProcess] = [:]       // 按「哪一位」预热、等待接手或过期，不属于某次回答，所以单独保存
    var warmIntents: [String: (key: String, token: UUID, lastTyped: Date?)] = [:]
    var warmAdopted = 0                             // 接手过几次预热的进程（自测看）

    // MARK: 历史会话（Agents/*History.swift）
    /// 左栏每位最多列多少条历史会话（太少的话，隔一阵没碰的项目会整组从列表里消失）。
    let historyListLimit = 300
    var usageCache: [String: (at: Date, items: [[String: Any]])] = [:]   // 三位的剩余用量：后台每 5 分钟查一次（Usage.swift）
    var usageLoading: Set<String> = []
    var claudeLiveCache: (at: Date, sessions: [(sid: String, status: String, name: String)])?   // 别处开着的 Claude 会话（ClaudeSessions.swift）
    var pathLookupCache: [String: (path: String?, at: Date)] = [:]   // 在登录 shell 的 PATH 里找过的命令（AgentSetup.swift）
    var enabledAgents: Set<String> = ["gemini", "claude", "gpt"]     // 界面上启用着的几位（网页告诉的）：后台只给它们查用量
    var geminiModelIds = Set<String>()            // agy models 的原始 ID，单次提问回退也使用同一目录，由 procLock 保护
    var geminiModelsFromCLI = false                 // 已经从 `agy models` 拿到过模型列表（之后不再用会话报上来的那份，免得两份来回换）
    var claudeModelsComplete = false                // 已经拿到过 Claude 完整的模型列表（见 noteClaudeInitialize）
    var historyLimits: [String: Int] = [:]          // 点过「显示更早的」的会话：会话 ID → 显示最近多少条
    var geminiResuming = Set<String>()   // 同一会话从检查到进程结束只能有一个发送者，由 procLock 保护
    var geminiProbes: [String: (at: Date, value: Bool?)] = [:]   // 打字预热、输入框提示用的进程扫描结果，2 秒内复用（GeminiSessions.swift），由 procLock 保护
    let geminiQueue = DispatchQueue(label: "aipethub.gemini")
    var geminiCache: [String: (mtime: TimeInterval, item: [String: Any]?)] = [:]
    let claudeQueue = DispatchQueue(label: "aipethub.claude")
    var claudeCache: [String: (mtime: TimeInterval, item: [String: Any]?, path: String)] = [:]
    let codexQueue = DispatchQueue(label: "aipethub.gpt")
    let deepseekQueue = DispatchQueue(label: "aipethub.deepseek")
    let dshServer = DshServer()                      // DeepSeek：dsh 的本机服务，所有会话共用（DeepSeekServer.swift）
    var dshProviders: [String: String] = [:]         // 模型 → 它属于哪个提供方（选模型时要带上）
    var dshApplied: [String: String] = [:]           // 会话 → 上次给它设的「模型|强度|权限」（一样就不用再设）
    var dshCwds: [String: String] = [:]              // 会话 → 工作目录（列表时记下，读会话时用）
    var deepseekHistoryWindow: DeepSeekHistoryWindow?   // 仅由 deepseekQueue 使用，换会话就释放旧页
    let packedContextQueue = DispatchQueue(label: "aipethub.gpt.packed-context", qos: .utility)
    var packedContextCache: [String: (stamp: Date, context: [String: Any]?)] = [:]
    var codexRolloutCache: [String: (mtime: TimeInterval, item: [String: Any]?)] = [:]

    // MARK: 各位 CLI 的能力
    /// 旧版 Claude 不认 --include-partial-messages；按可执行文件指纹缓存，升级后重新探测。
    var partialSupport: [String: Bool] = [:]
    var codexSkills: [String: String] = [:]         // Codex 的技能：名字 → 路径（/技能名 时用）
}

// MARK: - 启动和退出

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(UITest.active ? .accessory : .regular)   // 自动化测试（UITest.swift）时不进 Dock

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1280, visible.width - 60), height: min(800, visible.height - 40))
        let rect = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)

        window = HubWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AIPetHub"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.067, green: 0.059, blue: 0.118, alpha: 1)
        window.minSize = NSSize(width: 1000, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !UITest.active { window.setFrameAutosaveName("AIPetHubMainWindow") }   // 测试不改平时窗口的位置

        let controller = WKUserContentController()
        controller.add(self, name: "hubBridge")
        let config = WKWebViewConfiguration()
        if UITest.active { config.websiteDataStore = .nonPersistent() }   // 测试不动平时的设置和草稿
        if UITest.active {   // 页面知道自己在测试窗口里（第一次打开的引导页就不弹，否则每个测试都被它挡住；要测引导页的脚本自己打开）
            controller.addUserScript(WKUserScript(source: "window.__uitest = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // 桌宠骨骼动画（web/rig）用 WebGL 画本地的图层图片：file:// 下要允许页面读同目录的文件，不然图片会被当成跨域、画不出来
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController = controller

        webView = HubWebView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.onFileDrop = { [weak self] paths in self?.sendToJS("onFilesDropped", ["paths": paths]) }
        let savedZoom = UserDefaults.standard.double(forKey: "pageZoom")
        if savedZoom > 0 { webView.pageZoom = CGFloat(savedZoom) }
        let container = FlippedView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        container.autoresizingMask = [.width, .height]
        // 网页下面垫一层系统的毛玻璃（侧边栏材质，透出窗口后面的桌面）：网页自己不画底，
        // 左栏的底是半透明的，所以左栏带一点桌面的颜色；别的栏是不透明的，盖住它（feel.css 的「材质」）
        let glass = NSVisualEffectView(frame: container.bounds)
        glass.autoresizingMask = [.width, .height]
        // 界面只有深色一套：窗口固定用深色外观。不固定的话系统是浅色模式时这层材质是浅灰的，
        // 透上来把左栏洗成一片发白的灰，字也看不清
        window.appearance = NSAppearance(named: .darkAqua)
        glass.material = .underWindowBackground   // 比 .sidebar 深、更吃桌面的颜色，不发灰
        glass.blendingMode = .behindWindow
        glass.state = .active                     // 窗口不在前面时也保持，不要变成一块不透明的灰
        container.addSubview(glass)
        webView.frame = container.bounds
        container.addSubview(webView)
        window.contentView = container
        self.container = container

        indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("web/index.html")
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())

        setupMainMenu()
        if UITest.active {
            window.orderBack(nil)   // 测试：窗口放在后面，不抢焦点
            window.ignoresMouseEvents = true   // 点不到：免得被当成平时用的那个窗口去操作，打乱测试
            if UITest.real {
                // 真实窗口模式：照常画出来，推到屏幕外（系统会留一个小角在屏幕边上，见 UITest.real）
                let far = NSScreen.screens.map { $0.frame.minX }.min() ?? 0
                window.setFrameOrigin(NSPoint(x: far - 20000, y: -20000))
            } else {
                window.alphaValue = 0          // 完全透明：不挡屏幕（照常渲染，截图也照常能截）
            }
            window.title = "AIPetHub 自动化测试"
            uiTestStart()   // 测试窗口里不开用量的后台轮询，用到时现查
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            startUsagePolling()
        }
        docPreviewQueue.async { pruneDocumentPreviews() }
        watchTerminationSignal()
        setupBrowserTools()
        startWarmReaper()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        unseenReplies = 0
        NSApp.dockTile.badgeLabel = nil
    }

    /// 收到 SIGTERM（build.sh 安装新版本时用 pkill 关掉旧的，或者别处 kill）时走和 ⌘Q 一样的退出流程：
    /// 有回答正在进行就先弹窗确认，选「取消」就不退出。以前 SIGTERM 直接结束进程、不经过确认，
    /// 别的会话一重新安装，正在进行的回答就莫名其妙停了。（SIGKILL 拦不住，也不该拦。）
    func watchTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self, !self.terminationPrompting else { return }   // 确认框开着时又来一次：不重复弹
            self.terminationPrompting = true
            NSApp.terminate(nil)               // 确定退出时不会返回
            self.terminationPrompting = false   // 选了「取消」
        }
        source.resume()
        terminationSignal = source
    }

    /// 有回答正在进行时退出（⌘Q、Dock 菜单、安装新版本）先确认，免得长任务被误停。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        procLock.lock()
        let running = Array(Set(asks.keys.map { String($0.split(separator: "#").first ?? "") })).sorted()
        procLock.unlock()
        guard !running.isEmpty else { return .terminateNow }
        if let reply = hooks.terminationReply { return reply == .alertFirstButtonReturn ? .terminateNow : .terminateCancel }
        NSApp.activate(ignoringOtherApps: true)   // 由安装脚本触发时 App 可能在后台：把确认框拿到前面
        let names = ["gemini": "极其猫", "claude": "克劳蒂娜", "gpt": "吉佩缇", "deepseek": "大肥鱼"]
        let alert = NSAlert()
        alert.messageText = "\(running.compactMap { names[$0] }.joined(separator: "、"))还在回答，确定退出吗？"
        alert.informativeText = "退出会停止正在进行的回答，以及它启动的命令。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminateAllChildren()
        // 进程和套接字随 App 退出一起释放；不再等 DshServer 的启动锁，
        // 否则刚杀掉尚未报端口的服务，还要等 ensure 的 30 秒超时才能退出。
    }
}
