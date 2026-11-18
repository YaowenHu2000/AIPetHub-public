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

    // 文档预览的转换不经过 AppDelegate，所以这两个是全局的
    static var quickLookExecutable: String?        // 冒充 qlmanage
    static var quickLookTimeout: TimeInterval?     // 把 60 秒的转换期限调短
    static var quickLookStarted: (() -> Void)?     // 转换已启动、期限还没开始算：等假转换器把进程树建好，机器再忙也不会还没起来就超时
    static var chatThumbnailRequested: (() -> Void)?  // 证明搜索只检查图片标签，不走缩略图
    static var conversationSearchDiskRoot: URL?       // 跨进程性能测量也只能指定临时缓存目录
    static var conversationSearchDiskWillWrite: ((String) -> Void)?  // 卡住后台写盘，验证搜索不等待它
    static var dshAttachmentRoot: String?             // dsh 图片附件目录换成临时目录（解析历史不经过 AppDelegate），不读真实的 ~/.dsh

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

    var conversationSearchLoaded: ((String, String) -> Void)?  // 证明共享数据库别的会话更新不会重解析当前正文
    var conversationSearchCache: ConversationSearchCache?     // 用新的内存层模拟重启，沿用同一份临时磁盘缓存
    var codexLegacyArchiveLocated: (() -> Void)?  // 在找到旧 rollout 后模拟桌面端补索引
    var claudeTaskSince: Date?                     // 固定「Claude 任务会话」的分界时间，不读写真实的 UserDefaults
    var codexProjectionRead: (() -> Void)?         // 卡在条目和投影游标之间，验证两者属于同一 SQLite 读取快照
    var codexEnvironment: [String: String]?       // 用临时 CODEX_HOME 隔离真实历史，默认沿用 App 的环境
    // 离线、窗口测试和随后的会话清理可以共用临时 Gemini 目录，避免读取真实桌面历史。
    var geminiProbeTTL: TimeInterval?              // Gemini 进程扫描结果复用多久（默认 2 秒）；测续接逻辑的测试设 0，每次现查
    var geminiCliDir: String? = (selfTest || UITest.active) ? ProcessInfo.processInfo.environment["AIPETHUB_TEST_GEMINI_CLI_DIR"] : nil
    var geminiDesktopRunning: (() -> Bool?)?       // 模拟当前用户的桌面进程查询，返回 nil 表示查询失败
    var cliExecutable: String?                     // 冒充 claude / codex / agy / zstd 的假 CLI
    var toolTimeout: TimeInterval?                 // 把辅助命令（runTool）的期限调短
    var toolStarted: (() -> Void)?                 // 辅助命令已启动、还没开始等：卡在这里期限照走，放开时已过期就立即结束整棵树
    var terminationReply: NSApplication.ModalResponse?   // 退出确认框：不弹窗，直接当作点了哪个按钮
    var browserJobLifetime: TimeInterval?          // 浏览器工具的结果没人领时多久释放（平时 60 秒）
    var usageStore: (([String: Any]) -> Void)?     // 用量本来要写进 UserDefaults 的那份，交给测试看
    var codexBrowserStates: [String: Bool]? = TestHooks.selfTest ? [:] : nil   // 代替 UserDefaults 里的那本小本子
    var warmTypingIdle: TimeInterval?                 // 打字停下后释放旧会话的期限
    var liveInitializationScheduled: ((@escaping () -> Void) -> Void)?   // 直接执行同一超时闭包，覆盖已起跑、取消已来不及的旧期限
    var liveTurnCreated: ((LiveTurn) -> Void)?     // 卡在「取走预热进程之后、接手之前」，用来固定这一段的竞态
    var askReceived: ((AskRequest) -> Void)?       // 已建回答记录，还没派到后台
    var cliRegistered: ((String, Process) -> Void)?   // 进程已挂到记录，还没启动
    var cliStarted: ((String, Process) -> Void)?      // 已启动，还没接手输出
    var cliExited: ((String, Process) -> Void)?       // 已退出，还没读取本轮的停止标记
    var liveRegistered: ((String, LiveTurn) -> Void)?  // 交互式已挂到记录，进程还没登记
    var liveUnregistered: ((String) -> Void)?     // 交互式已摘下，尚未决定是否回退
    var askFinishing: ((AskRequest) -> Void)?     // 回答和文件改动已收齐，还没发最终结果
    // 窗口测试在主线程暂存读完的历史，等实时节点画好再按原顺序交付。
    var heldHistoryReplies: [() -> Void]?
}
