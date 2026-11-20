// 只给自测程序（tools/tests，用 -D HUB_SELFTEST 编译）用的开关，全在这一处。
// 正式运行时它们都是默认值（nil），各处读到默认值就走正常路径——所以用到的地方不需要再写 #if。
import Cocoa

struct TestHooks {
    /// 是不是自测程序。自测时不碰用户的东西：用量和浏览器工具的状态不写进 UserDefaults，
    /// 文档预览的缓存放临时目录，内置浏览器用临时的网站数据。
    static let selfTest: Bool = {
        #if HUB_SELFTEST
        return true
        #else
        return false
        #endif
    }()

    // 文档预览的转换、解析历史、DshServer 都不经过 AppDelegate，所以下面几个 static 是全局的
    static var quickLookExecutable: String?        // 冒充 qlmanage
    static var quickLookTimeout: TimeInterval?     // 把 60 秒的转换期限调短
    static var quickLookStarted: (() -> Void)?     // 转换已启动、期限还没开始算：等假转换器把进程树建好，机器再忙也不会还没起来就超时
    static var chatThumbnailRequested: (() -> Void)?  // 证明搜索只检查图片标签，不走缩略图
    static var conversationSearchDiskRoot: URL?       // 跨进程性能测量也只能指定临时缓存目录
    static var conversationSearchDiskWillWrite: ((String) -> Void)?  // 卡住后台写盘，验证搜索不等待它
    static var dshAttachmentRoot: String?             // dsh 图片附件目录换成临时目录（解析历史不经过 AppDelegate），不读真实的 ~/.dsh
    static var dshPushNow: (() -> Date)?              // 固定显示节流的时刻，重放取消前连续到达的两段正文
    static var dshSessionsRoot: String?               // dsh 会话日志的根目录换成临时目录（DshServer 不经过 AppDelegate），不看真实的 ~/.dsh
    static var dshReconnectWait: ((String, TimeInterval) -> TimeInterval)?  // 记下事件流重连前算出的间隔（流名、秒），返回实际要等多久：退避测试不用真等满
    static var dshStreamStableAfter: TimeInterval?    // 连上多久算稳定、退避回到起点（默认 30 秒）
    static var dshDiskMarked: ((String) -> Void)?     // 本服务自己的写已落盘、记下了这个会话日志的样子：不用按时长猜它什么时候记好

    static var defaultConversationSearchDiskRoot: URL {
        if let root = conversationSearchDiskRoot { return root }
        if selfTest {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aipethub-search-cache-test-\(getpid())", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPetHub/ConversationSearch", isDirectory: true)
    }

    static var geminiIndexBackupRoot: URL?   // 桌面版索引的删除前备份放哪（GeminiDesktopIndex.swift）
    static var defaultGeminiIndexBackupRoot: URL {
        if let root = geminiIndexBackupRoot { return root }
        if selfTest { return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aipethub-gemini-index-test-\(getpid())", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPetHub/GeminiIndexBackup", isDirectory: true)
    }

    var dshGapChecked: (() -> Void)?                  // 重连后的首次历史核对完成，测试才能决定何时放行结束记录。
    var dshCancelAcknowledged: (() -> Void)?
    var dshPromptConsumed: (() -> Void)?              // 在服务接手本轮之后、原提问回执放行之前停止。
    var dshSessionCreated: (() -> Void)?              // 在新会话尚无首问时确定地停止。
    var dshIdleFinishScheduled: ((TimeInterval, @escaping () -> Void) -> Void)?   // 兜底定时器交给测试（带上本该等的秒数）：到点由测试触发，不靠睡过定时器碰时机。
    var dshPeerProcessFilter: ((pid_t) -> Bool)?      // 查别处的 dsh web 时只看哪些进程：自测只看自己起的，免得扫到同时在跑的另一份测试或用户开着的 dsh web
    var jsSink: ((String, [String: Any]) -> Void)?  // 自测时接收原本发给网页的消息，不经 WKWebView
    var rolloutLookupWalk: (() -> Void)?  // 单字标题搜索不能为每条失效的旧路径遍历一次目录。
    var conversationSearchLoaded: ((String, String) -> Void)?  // 证明共享数据库别的会话更新不会重解析当前正文
    var conversationSearchCache: ConversationSearchCache?     // 用新的内存层模拟重启，沿用同一份临时磁盘缓存
    var codexLegacyArchiveLocated: (() -> Void)?  // 在找到旧 rollout 后模拟桌面端补索引
    var claudeTaskSince: Date?                     // 固定「Claude 任务会话」的分界时间，不读写真实的 UserDefaults
    var codexProjectionRead: (() -> Void)?         // 卡在条目和投影游标之间，验证两者属于同一 SQLite 读取快照
    var codexEnvironment: [String: String]?       // 用临时 CODEX_HOME 隔离真实历史，默认沿用 App 的环境
    var codexFullRolloutRead: ((String) -> Void)?    // 侧栏能从首行排除的子代理不应反复读完整记录
    var codexRolloutImagesRead: (() -> Void)?      // 证明原图文件还在、没被改过时历史配图不去读整份 rollout
    var codexImageConverting: (() -> Void)?        // 卡在 HEIC 等转 JPEG 之前：看中途补图的转换是不是在主线程、占着这一轮的锁
    var pastedImageDirectory: String?             // 自测在临时目录复现截图写盘失败。
    var sentImagesDir: String?                     // 转换、还原出来的临时图片放哪（默认系统临时目录下的 aipethub-sent-images/），测试放自己的临时目录
    // 单次模式附图的持久副本放哪（默认 ~/Library/Application Support/AIPetHub/aipethub-sent-images/）；自测不写用户目录
    var durableSentImagesDir: String? = TestHooks.selfTest ? NSTemporaryDirectory() + "aipethub-durable-images-test-\(getpid())/aipethub-sent-images/" : nil
    var geminiProbeTTL: TimeInterval?              // Gemini 进程扫描结果复用多久（默认 2 秒）；测续接逻辑的测试设 0，每次现查
    // 离线、窗口测试和随后的会话清理可以共用临时 Gemini 目录，避免读取真实桌面历史。
    var geminiCliDir: String? = (selfTest || UITest.active) ? ProcessInfo.processInfo.environment["AIPETHUB_TEST_GEMINI_CLI_DIR"] : nil
    var geminiDesktopRunning: (() -> Bool?)?       // 模拟当前用户的桌面进程查询，返回 nil 表示查询失败
    var geminiQuestionCheckScheduled: ((@escaping () -> Void) -> Void)?  // 等提问卡出现再让第二个 agy 持库，直接触发本次检查
    var geminiHeldRecheck: (() -> Void)?           // 看到别的 agy 开着会话库、复查之前：测试在这里让冒充的 agy 关掉库，模拟 agy 新建会话时顺手打开别的库那一下
    var geminiTranscriptRead: (() -> Void)?        // 证明长会话只在有状态 5 的步骤时读一次转写
    var cliExecutable: String? = UITest.active ? ProcessInfo.processInfo.environment["AIPETHUB_TEST_CLI"] : nil
    var toolTimeout: TimeInterval?                 // 把辅助命令（runTool）的期限调短
    var toolStarted: (() -> Void)?                 // 辅助命令已启动、还没开始等：卡在这里期限照走，放开时已过期就立即结束整棵树
    var terminationReply: NSApplication.ModalResponse?   // 退出确认框：不弹窗，直接当作点了哪个按钮
    var openURL: ((URL) -> Void)?                   // MCP 要用户去打开的链接、查看器外部打开的图片交给测试，不开用户的默认应用
    var browserJobLifetime: TimeInterval?          // 浏览器工具的结果没人领时多久释放（平时 60 秒）
    var usageStore: (([String: Any]) -> Void)?     // 用量本来要写进 UserDefaults 的那份，交给测试看
    var codexBrowserStates: [String: Bool]? = TestHooks.selfTest ? [:] : nil   // 代替 UserDefaults 里的那本小本子
    var codexKnownEndings: [String: [String: Any]]? = TestHooks.selfTest ? [:] : nil   // 代替 UserDefaults 里本机确认的 Codex 结局
    var localEndings: [[String: Any]]? = TestHooks.selfTest ? [] : nil   // 自测的已知结局留在内存
    var dshListStore: [String: [String: Any]]?        // 自测和窗口测试时代替 UserDefaults 里 DeepSeek 列表核对的存档；nil 是还没存过（第一次运行）
    var warmTypingIdle: TimeInterval?                 // 打字停下后释放旧会话的期限
    var prewarmWithoutBundle = false                  // 自测程序没有 bundle，平时会跳过预热；测预热的组在这里打开
    var liveInitializationScheduled: ((@escaping () -> Void) -> Void)?   // 直接执行同一超时闭包，覆盖已起跑、取消已来不及的旧期限
    var stopGraceScheduled: ((@escaping () -> Void) -> Void)?   // 停止后 4 秒宽限期到点要做的事交给测试，等根进程确实退出后再执行
    var stopSignalSent: ((pid_t) -> Void)?         // Gemini 停止时每给一个命令进程发完 TERM：测试在这里停一下，固定住机器忙时两次信号之间的间隔
    var liveTurnCreated: ((LiveTurn) -> Void)?     // 卡在「取走预热进程之后、接手之前」，用来固定这一段的竞态
    var askReceived: ((AskRequest) -> Void)?       // 已建回答记录，还没派到后台
    var cliRegistered: ((String, Process) -> Void)?   // 进程已挂到记录，还没启动
    var cliStarted: ((String, Process) -> Void)?      // 已启动，还没接手输出
    var cliAdopting: ((String, Process) -> Void)?     // 过了启动后的停止检查、还没接手（预热进程的提问还没写）：测试在这里点停止
    var cliExited: ((String, Process) -> Void)?       // 已退出，还没读取本轮的停止标记
    var liveRegistered: ((String, LiveTurn) -> Void)?  // 交互式已挂到记录，进程还没登记
    var liveUnregistered: ((String) -> Void)?     // 交互式已摘下，尚未决定是否回退
    var askFinishing: ((AskRequest) -> Void)?     // 回答和文件改动已收齐，还没发最终结果
    // 窗口测试在主线程暂存读完的历史，等实时节点画好再按原顺序交付。
    var heldHistoryReplies: [() -> Void]?
}
