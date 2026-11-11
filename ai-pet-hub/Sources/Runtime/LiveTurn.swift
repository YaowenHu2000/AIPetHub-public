// 回答进行中能做的事：中途补充一句、请它停下来、答复它的请求（审批 / 提问 / 计划）。各位的协议不同，这里是共用的部分。
import Cocoa

/// 一次交互式回答：CLI 的标准输入开着，回答进行中可以中途补充、请它停下来、答复它的请求。
/// 三位的协议不同，各有一个子类（Agents/ 下的 ClaudeLive / CodexLive / GeminiLive）；这里是共用的状态和流程。
/// 登记在 AppDelegate.liveTurns（键是「agent#reqId」），网页发来的补充、停止、答复按这个键找到它。
class LiveTurn {
    unowned let app: AppDelegate
    let req: AskRequest
    /// 预热好的进程（Prewarm.swift）：有就接手它，没有就新起
    let warm: CLIProcess?
    let input: LiveInput
    /// 这一轮的工作步骤（每新增 / 更新一步就推给网页）
    let builder: TurnBuilder
    let pending = PendingRequests()
    /// 这一轮的状态会被两个线程碰：读 CLI 输出的线程（handle）和主线程（网页发来的补充、停止、答复）。
    /// 这几个入口都先拿这把锁，所以子类里的状态、解析器里的会话 ID 之类不会被两边同时读写。可重入：入口里面还可以再 locked。
    let lock = NSRecursiveLock()
    private let announceConversation: (String) -> Void
    private var stopRequested = false

    init(app: AppDelegate, req: AskRequest) {
        self.app = app
        self.req = req
        warm = app.takeWarm(req)
        input = warm?.input ?? LiveInput()
        builder = app.turnBuilder(for: req)
        announceConversation = app.conversationWatcher(req)
    }

    // MARK: 子类实现

    /// 中途补充一句（可以带图片）。返回 false：这位不支持、或者已经来不及了（网页会把这句留到回答结束后再发）。
    func steer(_ text: String, images: [String], id: String) -> Bool { false }
    /// 请它停下来。
    func interrupt() {}
    /// 用户对一个请求（审批 / 提问 / 计划）的答复。
    func answer(_ requestId: String, _ body: [String: Any]) {}
    /// CLI 输出的一行。
    func handle(line: String) {}
    /// 接手预热的进程那一刻、处理任何输出之前。
    func adopted() {}

    // MARK: 共用

    /// 跑到 CLI 退出。登记自己、收尾时把还没答复的请求都撤掉。
    func run(executable: String, arguments: [String], cwd: String) -> CLIResult {
        app.registerLive(req.key, self)
        defer {
            app.unregisterLive(req.key)
            input.close()
            pending.takeAll().forEach { app.closeRequest(req, id: $0) }
        }
        return app.runCLI(agent: req.key, executable: executable, arguments: arguments, cwd: cwd, input: input, warm: warm,
                          onAdopt: { [weak self] in self?.locked { self?.adopted() } },
                          onStdoutLine: { [weak self] line in self?.locked { self?.handle(line: line) } })
    }

    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var stopping: Bool { locked { stopRequested } }
    func markStopping() { locked { stopRequested = true } }

    /// CLI 一报出会话 ID 就告诉网页。
    func noteConversation(_ id: String) { announceConversation(id) }

    /// 补充的话送出去了 / 它看到了（看到时作为一步「你补充说」记进工作过程）/ 没送进去。
    func noteSteer(_ id: String, _ state: String) {
        app.sendToJS("onAgentSteer", ["agent": req.agent, "reqId": req.reqId, "steerId": id, "state": state])
    }

    func noteSteerConsumed(_ id: String, text: String) {
        builder.add(makeStep("user", "你补充说", detail: text))
        noteSteer(id, "consumed")
    }
}

/// 等用户答复的请求：记着原始参数，答复时要带回去。线程安全。
final class PendingRequests {
    private let lock = NSLock()
    private var items: [String: [String: Any]] = [:]
    private var allowed: Set<String> = []   // 用户选了「这一轮都允许」的操作种类

    func add(_ id: String, _ info: [String: Any]) { lock.lock(); items[id] = info; lock.unlock() }
    func take(_ id: String) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return items.removeValue(forKey: id) }
    func drain() -> [(id: String, info: [String: Any])] { lock.lock(); defer { lock.unlock() }; let all = items.map { (id: $0.key, info: $0.value) }; items = [:]; return all }
    func takeAll() -> [String] { lock.lock(); defer { lock.unlock() }; let ids = Array(items.keys); items = [:]; return ids }
    func allowAll(_ kind: String) { lock.lock(); allowed.insert(kind); lock.unlock() }
    func isAllowed(_ kind: String) -> Bool { lock.lock(); defer { lock.unlock() }; return allowed.contains(kind) }
}

extension AppDelegate {
    func registerLive(_ key: String, _ live: LiveTurn) {
        procLock.lock(); liveTurns[key] = live; procLock.unlock()
    }

    func unregisterLive(_ key: String) {
        procLock.lock(); liveTurns[key] = nil; procLock.unlock()
    }

    func liveTurn(agent: String, reqId: Int) -> LiveTurn? {
        procLock.lock(); defer { procLock.unlock() }
        return liveTurns["\(agent)#\(reqId)"]
    }

    /// 网页：回答进行中又发来一句（可以带图片）。
    func steer(agent: String, reqId: Int, text: String, images: [String], steerId: String) {
        let live = liveTurn(agent: agent, reqId: reqId)
        let accepted = live?.locked { live?.steer(text, images: images, id: steerId) } ?? false
        if !accepted { sendToJS("onAgentSteer", ["agent": agent, "reqId": reqId, "steerId": steerId, "state": "rejected"]) }
    }

    /// 网页：用户答复了一个请求。
    func answerRequest(agent: String, reqId: Int, requestId: String, body: [String: Any]) {
        let live = liveTurn(agent: agent, reqId: reqId)
        live?.locked { live?.answer(requestId, body) }
    }

    /// 告诉网页有一件事等用户决定。kind：permission（审批）/ question（提问）/ plan（计划）。
    func sendRequest(_ req: AskRequest, id: String, kind: String, _ fields: [String: Any]) {
        var payload = fields
        payload["agent"] = req.agent
        payload["reqId"] = req.reqId
        payload["requestId"] = id
        payload["kind"] = kind
        sendToJS("onAgentRequest", payload)
        noteNeedsAttention(agent: req.agent, text: kind == "question" ? "有问题要问你" : (kind == "plan" ? "计划写好了，等你批准" : "等你批准一个操作"))
    }

    /// 请求不用答了（已经答复、被取消、回答结束）。
    func closeRequest(_ req: AskRequest, id: String) {
        sendToJS("onAgentRequestClosed", ["agent": req.agent, "reqId": req.reqId, "requestId": id])
    }
}
