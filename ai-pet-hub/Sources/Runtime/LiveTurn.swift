// 回答进行中能做的事：中途补充一句、请它停下来、答复它的请求（审批 / 提问 / 计划）。各位的协议不同，这里是共用的部分。
//
// 每次提问用一个对应的 CLI 进程，用它的双向协议对话（标准输入开着）：`claude -p --input-format stream-json`、`codex app-server`（JSON-RPC）、
// `agy acp`（Agent Client Protocol）。
// 中途补充、停止、它提的问题、审批都走这条通道。
// 提问和补充共用发送时的图片副本（查看和恢复见 Preview/SentImages.swift、ChatImages.swift 开头）。
// 这一轮答完就关掉输入让进程退出；CLI 版本太旧不支持时自动退回一问一答（`claude -p`、`codex exec`、`agy -p`）。
// Claude 和 Codex 选了「每次询问」时，单次模式无法接审批卡，原问退回草稿。
// 已有会话的追问在交给 CLI 前就被停止时，CLI 的记录里没有它，切走再回来只剩上一轮：确认没提交的才退回原会话草稿
// （Claude 看这一轮会话记录里有没有写进 user，Codex 看 turn/start 有没有发出，DeepSeek 看 session.prompt 有没有调用）；
// 已提交的照常按停止显示，免得重开时记录里一份、草稿里又一份。Gemini 靠本机补记在重开时补回这一轮，不退回。
// 追问还没交给 CLI 就被拒发的（Claude 无法确认会话占用、Codex 写锁被占、Gemini 拦在提问前、DeepSeek 设置失败或明确拒收）同样退回原会话草稿，
// 这几种没有本机补记，不退回的话切走再回来原话、附件和「重试」都没了。
// 事件流统一转换为「工作步骤 + 正文 + 改动文件」后推送到界面。
//
// Codex / Gemini 的交互式初始化每个有效阶段最多静默等待 300 秒，推进后重新计时，重复消息不续期；仅在提问尚未排入输入时超时回退一问一答。
// 提问或压缩命令一旦排队，就永久取消这轮初始化期限，慢回答不会被重发。
//
// 它向用户提的问题都用网页的提问卡作答：Claude 是 `AskUserQuestion` 的 `can_use_tool`（最高权限下也会来问），Codex 是 `item/tool/requestUserInput`（App 用的默认协作模式里 Codex 没有这个工具，
// 只会用文字问；用户在 `config.toml` 开了 `features.default_mode_request_user_input` 才会来），agy 是 `ask_question`（App 在 initialize 声明了 `elicitation.form`，
// 它才以 `elicitation/create` 表单发来，否则把问题写进正文就结束这一轮），DeepSeek 是 `question/requested`（计划模式下 `exit_plan_mode` 交来的计划评审带 `intent.kind=plan-review`，
// 用和 Claude / Codex 同一张计划卡显示计划正文，批准回 `selected:[intent.approve]`，「先改计划」回 custom；停止时等着的提问以 cancelled 作答，
// error 必须带 `details:{}`）。
// 题目带 id 的（Codex、Gemini、DeepSeek、MCP 表单）网页按 id 交回答案。
//
// 四位遇到不认识的请求回「不支持」（Codex 的 `item/tool/call` 回一个失败的工具结果、Claude 的 `hook_callback` 回空对象，让它接着做），
// 并往 stderr 记一行方法名，CLI 升级加了新回调时能发现。
//
// 回答进行中补充一句：Claude 是再写一条 user 消息（回显时算它看到了），Codex 是 `turn/steer`，agy 是再发一条 `session/prompt`（收下时立刻用 end_turn 答复上一条，
// 这一轮由最新那条的答复结束；等审批或提问的答复时拒收，这句话留在队列里等这一轮结束再发），DeepSeek 用它的插话模式。
// 看到后在工作过程里记一步「你补充说」。
// 历史把补充单独记成用户消息时，按已消费的补充核对改动和中断所在段，重试沿用原问及其附件。
import Cocoa

/// 已有会话的追问没交给 CLI 就停了：退回草稿时桌宠说的话，也是这一轮当场显示的正文。
let unsentFollowUpReply = "追问还没发出，已退回草稿。"

/// 一次交互式回答：CLI 的标准输入开着，回答进行中可以中途补充、请它停下来、答复它的请求。
/// 四位的协议不同，各有一个子类（Agents/ 下的 ClaudeLive / CodexLive / GeminiLive / DeepSeekLive）；这里是共用的状态和流程。
/// 挂在 AppDelegate.asks 的 live 字段（键是「agent#reqId」），网页发来的补充、停止、答复按这个键找到它。
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
    private(set) var warmDied = false
    private var initializationProcess: Process?
    private var initializationTimer: DispatchWorkItem?
    private var initializationGeneration = 0
    private var initializationStages = Set<String>()
    private(set) var initializationTimedOut = false
    private(set) var initialPromptSubmitted = false

    init(app: AppDelegate, req: AskRequest) {
        self.app = app
        self.req = req
        warm = app.takeWarm(req)
        input = warm?.input ?? LiveInput()
        builder = app.turnBuilder(for: req)
        announceConversation = app.conversationWatcher(req)
        app.hooks.liveTurnCreated?(self)
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
    /// Claude 会立即把用户消息排进输入，不处于可安全重发的握手等待阶段。
    var waitsForInitialization: Bool { false }

    // MARK: 共用

    /// 跑到 CLI 退出。登记自己、收尾时把还没答复的请求都撤掉。
    func run(executable: String, arguments: [String], cwd: String) -> CLIResult {
        app.registerLive(req.key, self)
        defer {
            locked { cancelInitializationDeadline(); initializationProcess = nil }
            app.unregisterLive(req.key)
            input.close()
            pending.takeAll().forEach { app.closeRequest(req, id: $0) }
        }
        let result = app.runCLI(agent: req.key, executable: executable, arguments: arguments, cwd: cwd, input: input, warm: warm,
                          onAdopt: { [weak self] in self?.locked {
                              self?.beginInitializationDeadline()
                              self?.adopted()
                          } },
                          onStdoutLine: { [weak self] line in self?.locked { self?.handle(line: line) } })
        warmDied = result.warmDied
        return result
    }

    func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var stopping: Bool { locked { stopRequested } }
    func markStopping() {
        locked {
            guard !stopRequested else { return }
            stopRequested = true
            builder.interruptRunningTools()
            cancelInitializationDeadline()
        }
    }

    /// 必须等本次进程完成登记和启动再计时；预热接手也从这里重新给足等待时间。
    private func beginInitializationDeadline() {
        guard waitsForInitialization, !stopping, !initialPromptSubmitted else { return }
        app.procLock.lock(); initializationProcess = app.asks[req.key]?.proc; app.procLock.unlock()
        scheduleInitializationDeadline()
    }

    private func cancelInitializationDeadline() {
        initializationGeneration += 1
        initializationTimer?.cancel()
        initializationTimer = nil
    }

    private func scheduleInitializationDeadline() {
        guard let process = initializationProcess, process.isRunning else { return }
        cancelInitializationDeadline()
        let generation = initializationGeneration
        let expire = { [weak self, weak process] in
            guard let self = self, let process = process else { return }
            self.locked {
                guard self.initializationGeneration == generation, self.initializationProcess === process,
                      !self.stopping, !self.initialPromptSubmitted, !self.initializationTimedOut, process.isRunning else { return }
                self.initializationTimedOut = true
                self.cancelInitializationDeadline()
                self.input.close()
                // 只操作捕获的本次进程，不能在回退后再按 reqId 查到一问一答的新进程。
                terminateTree(process.processIdentifier)
            }
        }
        let timer = DispatchWorkItem(block: expire)
        initializationTimer = timer
        if let schedule = app.hooks.liveInitializationScheduled { schedule(expire) }
        else { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300, execute: timer) }
    }

    /// 只有真正推进的阶段才能延长等待；重复 ACK、日志和未知握手不能无限续期。
    @discardableResult
    func initializationProgress(_ stage: String) -> Bool {
        locked {
            guard !stopping, !initialPromptSubmitted, !initializationTimedOut,
                  initializationStages.insert(stage).inserted else { return false }
            scheduleInitializationDeadline()
            return true
        }
    }

    /// send 只保证成功排队，但这已经可能被 CLI 消费；提交和超时必须互斥，不能等待 ACK 才禁止重发。
    @discardableResult
    func submitInitialPrompt(_ send: () -> Bool) -> Bool {
        locked {
            guard !stopping, !initialPromptSubmitted, !initializationTimedOut, send() else { return false }
            initialPromptSubmitted = true
            cancelInitializationDeadline()
            return true
        }
    }

    /// CLI 一报出会话 ID 就告诉网页。
    func noteConversation(_ id: String) { announceConversation(id) }

    /// 补充的话送出去了 / 它看到了（看到时作为一步「你补充说」记进工作过程）/ 没送进去。
    func noteSteer(_ id: String, _ state: String) {
        app.sendToJS("onAgentSteer", ["agent": req.agent, "reqId": req.reqId, "steerId": id, "state": state])
    }

    func noteSteerConsumed(_ id: String, text: String, images: [String] = []) {
        var step = makeStep("user", "你补充说", detail: text)
        let thumbs = app.chatImages(sources: images.map { ["path": $0] }, text: text, base: req.workspace)
        if !thumbs.isEmpty { step["images"] = thumbs }
        builder.add(step)
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
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return items[id] != nil }
    func drain() -> [(id: String, info: [String: Any])] { lock.lock(); defer { lock.unlock() }; let all = items.map { (id: $0.key, info: $0.value) }; items = [:]; return all }
    func take(where match: ([String: Any]) -> Bool) -> [(id: String, info: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        let hit = items.filter { match($0.value) }.map { (id: $0.key, info: $0.value) }
        hit.forEach { items[$0.id] = nil }
        return hit
    }
    func takeAll() -> [String] { lock.lock(); defer { lock.unlock() }; let ids = Array(items.keys); items = [:]; return ids }
    func allowAll(_ kind: String) { lock.lock(); allowed.insert(kind); lock.unlock() }
    func isAllowed(_ kind: String) -> Bool { lock.lock(); defer { lock.unlock() }; return allowed.contains(kind) }
}

extension AppDelegate {
    /// 跑一轮交互式回答。预热的进程在接手前就死了（warmDied）：提问没送到活着的进程，重建这一轮走一次冷启动。
    /// 只重试一次；第二次还是这样就按普通失败返回。三位的入口共用。
    func runLive<T: LiveTurn>(_ make: () -> T, _ run: (T) -> AgentReply?) -> AgentReply? {
        let live = make()
        let reply = run(live)
        return live.warmDied ? run(make()) : reply
    }

    func registerLive(_ key: String, _ live: LiveTurn) {
        procLock.lock()
        asks[key]?.live = live
        let stopped = asks[key]?.cancelled == true
        procLock.unlock()
        // DeepSeek 没有 runCLI 替它接手登记前的停止。
        if stopped { live.markStopping() }
        hooks.liveRegistered?(key, live)
    }

    func unregisterLive(_ key: String) {
        procLock.lock(); asks[key]?.live = nil; procLock.unlock()
        hooks.liveUnregistered?(key)
    }

    func liveTurn(agent: String, reqId: Int) -> LiveTurn? {
        procLock.lock(); defer { procLock.unlock() }
        return asks["\(agent)#\(reqId)"]?.live
    }

    /// 网页：回答进行中又发来一句（可以带图片）。
    func steer(agent: String, reqId: Int, text: String, images: [String], steerId: String) {
        let event: [String:Any] = ["agent":agent,"reqId":reqId,"steerId":steerId,"state":"rejected"]
        procLock.lock(); let state = asks["\(agent)#\(reqId)"]; procLock.unlock()
        guard let state else { sendToJS("onAgentSteer",event); return }
        state.supplementQueue.async { [self] in
            guard let copies = sentImagePaths(images) else {
                var failure = event
                failure["reason"] = "⚠️ 无法保存当次图片，这句话没有发送。"
                failure["restoreDraft"] = true
                sendToJS("onAgentSteer", failure)
                return
            }
            let sent = images.map { copies[$0] ?? $0 }
            if !images.isEmpty {
                sendToJS("onAgentSentImages", ["agent":agent,"reqId":reqId,"steerId":steerId,"paths":copies])
            }
            guard let live = state.live, liveTurn(agent:agent,reqId:reqId) === live,
                  live.locked({ !live.stopping && live.steer(text, images:sent, id:steerId) }) else {
                sendToJS("onAgentSteer", event)
                return
            }
        }
    }

    /// 网页：用户答复了一个请求。
    func answerRequest(agent: String, reqId: Int, requestId: String, body: [String: Any]) {
        let live = liveTurn(agent: agent, reqId: reqId)
        // DeepSeek 的请求可能没有回合接着（dsh 自己开的一轮里来问，卡片的 reqId 是 0）：按记下的 rpcId 直接交回
        if live == nil, agent == "deepseek" { dshAnswerUnattended(requestId, body); return }
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
