// DeepSeek Harness（dsh）的本机服务。另外三位是「一次回答一个 CLI 进程」，dsh 不一样：它的无界面模式只能一问一答
// （看不到过程、不能接着聊），完整的能力在「网页模式」里——`dsh web` 起一个只听本机的服务，它自带的浏览器界面就是靠这套接口。
// 这里起一个这样的服务常驻着，所有会话共用：
//   · 上行：POST http://127.0.0.1:<端口>/api/<方法名>，请求体 {"type":"client-request","rpcId","method","payload"}，
//     答复 {"type":"server-response","rpcId","result":{"ok":true,"value":…} 或 {"ok":false,"error":{"code","message"}}}（出错也是 HTTP 200）。
//   · 下行：两条只收不发的 WebSocket，每帧一个 JSON {"type":"server-request","rpcId","method","payload"}。
//     /api/events.mux 是所有会话的事件（按 payload.sessionId 分），/api/events.host 是会话的运行状态和出错。
//   · 要人答复的帧（审批、提问）：POST /api/respond，rpcId 原样带回去；回执 {"accepted":true} 或 {"accepted":false,"reason":"bad-response"|"not-pending"}。
// 没有登录和订阅，连上就收全部；它只认回环地址来的请求。接口没有公开文档，是照着 0.1.0-rc.7 实测的——dsh 升级后这里可能要跟着改。
//
// 事件流连续 5 次重连不成才当服务没了，重连确认成功（或收到一帧）就重新计数；连上又马上断的流重连间隔从 0.3 秒翻倍、封顶 5 秒，收到业务帧或连稳 30 秒后回到 0.3 秒，
// 等待期间漏的事件由重连后的历史核对补上。
//
// 能确认数据目录不同的服务可继续运行；历史不能重载时，聊天页显示原因。
// 此时还有提问或审批等用户处理、另有 DeepSeek 回答在进行、或还有后台任务在跑（事件流的 `session/jobs`，dsh 退出时会把它们一起结束），则保留服务，发送会解释原因，
// 正文搜索标明未搜全并跳过这份缓存写入。
// 注意：在 AIPetHub 里给 DeepSeek 选模型和思考强度时，dsh 会把它记成自己以后新会话的默认值（写进 `~/.dsh/settings.yaml`），和它自带的网页界面行为一致。
// 服务只接受默认思考强度时，在本轮步骤中说明，下次仍会尝试所选档位。
// 旁观服务报告近期中断时核对持久日志的回合边界，无法确认结束则提示并保留会话。
// 单删和批删都会现查占用，Claude 在外部打开或 DeepSeek 被另一实例持锁、有进行中的回合时会返回原因。
// dsh 没有卸载单个会话的接口。
// 删除时按数据根目录和会话编号记下移进废纸篓的目录。
// 各实例的 `DshServer.isDeleted` 核对原目录，列表、搜索、分页载入、待答提醒和续问用同一结果。
// 恢复目录后正常续接。
// 历史正文读取失败时保留已显示或已读到的消息，显示原因和重新加载入口。
// 服务起不来时历史列表保留上次结果、左栏写明原因，启动提示先放 stderr 里含 Error / Exception 的原因行和配置摘录，再附最后一段。
//
// 一条事件流出错（`stream/error`）或断开而 dsh 还活着时只重连这一条（dsh 会重放没答的请求，已交过的不再交），连续 5 次连不上才当成服务没了。
import Cocoa

final class DshServer {
    // 没写 private 的状态（lock、port、generation、writeLocks、diskMarks 等）只给 DeepSeekSessionFiles.swift、
    // DeepSeekServerCalls.swift 两个扩展用：Swift 跨文件的扩展看不到 private。别处不要直接碰，读写都在 lock 下。
    let lock = NSRecursiveLock()
    private var proc: Process?
    var port = 0
    private var sockets: [URLSessionWebSocketTask] = []
    var generation = 0
    private var listeners: [String: [Int: ([String: Any]) -> Void]] = [:]
    private var nextToken = 0
    private var errorOutput = OutputBuffer(limit:16384)
    func currentErrorOutput() -> OutputBuffer {
        lock.lock(); defer { lock.unlock() }
        return errorOutput
    }
    private var ready = false
    private let startupQueue = DispatchQueue(label: "aipethub.dsh.start")
    let eventQueue = DispatchQueue(label: "aipethub.dsh.events")
    private var sessionQueues: [String: DispatchQueue] = [:]
    private var launch: (executable: String, environment: [String: String], cwd: String)?   // 重起时沿用
    var writeLocks: [String: FileHandle] = [:]   // 接手续写的会话的跨实例写锁，为什么要有见 DeepSeekSessionFiles.swift 的 claimSession

    var wrapperPid: pid_t? { lock.lock(); defer { lock.unlock() }; return proc?.processIdentifier }

    var diskMarks: [String: String] = [:]
    var lastWrite: [String: Date] = [:]
    /// dsh 攒 200 毫秒一批写盘；事件流上停了这么久才把磁盘上的样子当成自己写完的。
    let writeSettle: TimeInterval = 2
    // DeepSeek 用后台 bash 等起的任务（开发服务器之类）回答结束后还在跑，dsh 退出时会把所有会话的一起结束；
    // 按会话记下还没结束的（session/jobs 帧每次给这个会话的全部任务），有就不能为了重新载入去重起服务。
    var activeJobs: [String: [String]] = [:]
    // dsh 的提问和审批没有超时，也不管有没有人在听：它自己开的一轮（后台任务唤醒、子智能体回报）里发来的，
    // App 没有回合在听就会一直挂着，用户再发一句就排在后面一直转圈（0.1.0-rc.7 实测）。所以不论有没有人在听都记下，
    // resolved 来了再清；有回合开始听这个会话就补发给它，没人听时交给 unattended 提示用户。键是卡片编号（dshRequestKey）。
    private var waiting: [String: (sid: String, seq: Int, frame: [String: Any])] = [:]
    private var waitingSeq = 0
    /// 没有回合在听的会话来了要人答的请求（frame），或者这样的请求了结了、交给回合了（nil）。AppDelegate 初始化时接上。
    var unattended: ((_ sid: String, _ id: String, _ frame: [String: Any]?) -> Void)?
    private var streamFailures = 0   // 事件流连续断了几次（收到一帧或重连确认成功就清零）：重连一直不成就当成服务没了
    // 每条流上次重连等了多久、这次连上（确认握手）是什么时候。连得上却马上又断的流按指数退避，
    // 不然它每 0.3 秒重连一次、永不停止；收到业务帧或连稳 30 秒后回到起点
    private var reconnectDelay: [String: TimeInterval] = [:]
    private var streamUpSince: [String: Date] = [:]
    // 队列 → 短持 server 锁；先释放 server 锁才进回合锁，回合锁内不等 RPC/队列/I/O。
    /// 同一会话的配置和提交不能穿插；等待答复正文不占这条队列。
    func sessionQueue(_ sid: String) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = sessionQueues[sid] { return q }
        let q = DispatchQueue(label: "aipethub.dsh.session.\(sid)")
        sessionQueues[sid] = q
        return q
    }
    private static func localSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.connectionProxyDictionary = [:]   // 本机服务：不走系统代理
        return URLSession(configuration: c)
    }
    /// HTTP 与事件流各用一个会话；事件分发再移到 eventQueue，避免监听者拖住握手和接收回调。
    let http = DshServer.localSession()
    private let streams = DshServer.localSession()

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return ready && proc?.isRunning == true }

    var deletedDirectoryPrefix: String?   // 用法见 DeepSeekSessionFiles.swift 的 isDeleted

    /// 服务没在跑就起一个并连上两条事件流。成功返回 nil，否则是出错的原因。
    func ensure(executable: String, environment: [String: String], cwd: String) -> String? {
        startupQueue.sync { start(executable: executable, environment: environment, cwd: cwd) }
    }

    /// 用上次的参数重起：内存里的会话全部丢掉，之后用到时 dsh 按磁盘重新载入。
    func restart() -> String? {
        startupQueue.sync {
            lock.lock(); let last = launch; lock.unlock()
            guard let l = last else { return "dsh 的本机服务没有在运行" }
            guard shutdown(preservePending: true) else { return "DeepSeek 还有待处理的提问或审批，请处理后再重载会话。" }
            return start(executable: l.executable, environment: l.environment, cwd: l.cwd)
        }
    }

    private func start(executable: String, environment: [String: String], cwd: String) -> String? {
        if isRunning { return nil }
        shutdown()
        lock.lock(); launch = (executable, environment, cwd); deletedDirectoryPrefix = Self.deletedDirectoryKey(""); lock.unlock()
        lock.lock(); let gen = generation; lock.unlock()
        let p = Process()
        // 套一层 sh：App 正常退出时会来结束它（SIGTERM → 连 dsh 一起结束）；App 被强制结束、崩了的话没人来通知，
        // 所以它自己每两秒看一眼 App 还在不在，不在了就把 dsh 结束掉，不留下没人管的服务。
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"""
            "$1" web --port 0 --host 127.0.0.1 & c=$!
            trap 'kill $c 2>/dev/null; wait $c' TERM INT HUP
            ( while kill -0 "$0" 2>/dev/null; do sleep 2; done; kill $c 2>/dev/null ) & w=$!
            wait $c; kill $w 2>/dev/null
            """#, String(ProcessInfo.processInfo.processIdentifier), executable]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // 端口只在标准输出的那一行里：dsh web: http://127.0.0.1:50814
        let found = DispatchSemaphore(value: 0)
        // 原因行在调用栈前面；配置路径一长、栈一深，1500 字节就只剩栈，看不到原因
        let outputLock = NSLock(), stderrTail = OutputBuffer(limit: 16384)
        var buffer = "", got = 0
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            outputLock.lock(); defer { outputLock.unlock() }
            guard got == 0 else { return }   // 端口找到后仍读走输出，但不再攒常驻服务的日志
            buffer += String(decoding: d, as: UTF8.self)
            if got == 0, let r = buffer.range(of: #"http://[^\s:/]+:(\d+)"#, options: .regularExpression),
               let n = Int(buffer[r].split(separator: ":").last ?? "") {
                got = n
                buffer = ""
                found.signal()
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            stderrTail.append(d)
        }
        // 进程（sh 包装）退出就别再等端口：dsh 不存在或一启动就崩时立刻报错，不让用户干等 30 秒。
        do { try ChildProcesses.shared.start(p, onExit: { found.signal() }) } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return "dsh 启动不了：\(error.localizedDescription)"
        }
        lock.lock()
        let current = generation == gen
        if current { proc = p; errorOutput = stderrTail }
        lock.unlock()
        guard current else { if p.isRunning { p.terminate() }; return "dsh 启动已取消" }
        // 等端口/握手时不拿 server 锁，日志和事件回调才能继续排空。
        let reported = found.wait(timeout: .now() + 30) == .success
        outputLock.lock(); let announcedPort = got; outputLock.unlock()
        guard reported, announcedPort > 0 else {
            let why = trimmed(stderrTail.string)
            shutdown(generation: gen)
            return "dsh 的本机服务没有启动起来" + (why.isEmpty ? (reported ? "（还没报出端口就退出了）" : "（30 秒内没有报出端口）") : "：\(Self.startupFailure(why))")
        }
        lock.lock()
        guard generation == gen else { lock.unlock(); return "dsh 启动已取消" }
        port = announcedPort
        lock.unlock()
        // 两条事件流都连上再算好：发一个 ping，收到回音说明握手完成了（之后的事件不会漏）
        let opened = DispatchGroup()
        let pingLock = NSLock()
        var failed = false
        for path in ["events.mux", "events.host"] {
            let task = streams.webSocketTask(with: URL(string: "ws://127.0.0.1:\(announcedPort)/api/\(path)")!)
            task.maximumMessageSize = 64 << 20   // 一帧里可能带着整份系统提示词、大段命令输出
            lock.lock()
            guard generation == gen else { lock.unlock(); task.cancel(with: .goingAway, reason: nil); return "dsh 启动已取消" }
            sockets.append(task)
            lock.unlock()
            task.resume()
            opened.enter()
            task.sendPing { e in
                pingLock.lock(); if e != nil { failed = true }; pingLock.unlock()
                opened.leave()
            }
            pump(task, gen)
        }
        let openedInTime = opened.wait(timeout: .now() + 10) == .success
        pingLock.lock(); let pingFailed = failed; pingLock.unlock()
        if !openedInTime || pingFailed {
            shutdown(generation: gen)
            return "连不上 dsh 的本机服务（事件流没有握上手）"
        }
        lock.lock(); defer { lock.unlock() }
        guard generation == gen, p.isRunning, sockets.count == 2 else { return "dsh 启动已取消" }
        ready = true
        return nil
    }

    /// 启动失败时 stderr 的末尾是 Node 的调用栈和版本号，真正的原因（Error: … YAMLException: … 带配置文件路径和行列号，
    /// 下面跟着出错处的摘录）在前面；只截最后 300 字会从半个路径开始。先放原因行和摘录，再附最后一段。
    static func startupFailure(_ stderr: String) -> String {
        let lines = stderr.components(separatedBy: "\n")
        let isReason = { (line: String) in line.range(of: #"(Error|Exception):"#, options: .regularExpression) != nil }
        guard let first = lines.firstIndex(where: isReason) else { return String(stderr.suffix(300)) }
        var reason = [lines[first]]
        // 摘录到调用栈为止；之后再出现的原因行（如 [cause]）也留下
        var i = first + 1
        while i < lines.count, lines[i].range(of: #"^\s+at "#, options: .regularExpression) == nil, reason.count < 12 { reason.append(lines[i]); i += 1 }
        reason += lines[i...].filter(isReason).prefix(4)
        var text = trimmed(reason.joined(separator: "\n"))
        if text.count > 1200 { text = String(text.prefix(1200)) + "…" }
        // 最后一段从整行开始，不再从半个路径开始
        var tail = Substring(stderr.suffix(300))
        if tail.count == 300, let nl = tail.firstIndex(of: "\n") { tail = tail[tail.index(after: nl)...] }
        let last = trimmed(String(tail))
        return last.isEmpty || text.contains(last) ? text : text + "\n…\n" + last
    }

    private func pump(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                self.eventQueue.async { self.streamLost(task, gen) }
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let d = data, let frame = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   var payload = frame["payload"] as? [String: Any] {
                    // 这条流在服务端出错了：它发完这一帧就关掉 socket。不再等关闭，直接重连这一条
                    if payload["type"] as? String == "stream/error" {
                        self.eventQueue.async { self.streamLost(task, gen) }
                        return
                    }
                    payload["_rpcId"] = frame["rpcId"]   // 答复审批时要原样带回去
                    let event = payload
                    self.eventQueue.async {
                        self.lock.lock()
                        let current = self.generation == gen
                        // 事件流每次（重新）连上，dsh 都先推一组快照：每个已载入会话的 session/subscribed，
                        // 待答提问 / 审批的重放（dispatch 会按已交过去重），有排队和后台任务时的 session/queue、session/jobs。
                        // 这些不算流在正常送事件：有待答卡片的会话每次重连都先来这几帧，算进去退避就永远涨不上去。
                        // queue / jobs 平时的更新也因此不清零，退避等新的会话事件或连稳一段时间（streamLost）再恢复
                        let type = event["type"] as? String ?? ""
                        let replay = ["session/subscribed", "session/queue", "session/jobs"].contains(type)
                            || (type.hasSuffix("/requested") && dshRequestKey(event).map { self.waiting[$0] != nil } == true)
                        if current && !replay {
                            self.streamFailures = 0
                            if let name = task.originalRequest?.url?.lastPathComponent { self.reconnectDelay[name] = nil }   // 流在正常送事件
                        }
                        self.lock.unlock()
                        if current { self.dispatch(event) }
                    }
                }
                self.pump(task, gen)
            }
        }
    }

    private func dispatch(_ payload: [String: Any]) {
        guard let sid = payload["sessionId"] as? String else { return }
        if payload["type"] as? String == "session/event" { noteWrite(sid) }
        if payload["type"] as? String == "session/jobs", let jobs = payload["jobs"] as? [[String: Any]] {
            let running = jobs.filter { ["running", "stopping"].contains($0["status"] as? String ?? "") }.map { $0["label"] as? String ?? "" }
            lock.lock(); activeJobs[sid] = running.isEmpty ? nil : running; lock.unlock()
        }
        lock.lock()
        let handlers = listeners[sid].map { Array($0.values) } ?? []
        var deliver = true, notify: (id: String, frame: [String: Any]?)?
        if let id = dshRequestKey(payload) {
            if (payload["type"] as? String ?? "").hasSuffix("/requested") {
                // 事件流重连后 dsh 会把还没答的重放一遍：已经交过的不再交
                if waiting[id] != nil { deliver = false }
                else {
                    waitingSeq += 1
                    waiting[id] = (sid, waitingSeq, payload)
                    if handlers.isEmpty { notify = (id, payload) }
                }
            } else if waiting.removeValue(forKey: id) != nil, handlers.isEmpty {
                notify = (id, nil)
            }
        }
        let tell = unattended
        lock.unlock()
        if let n = notify { tell?(sid, n.id, n.frame) }
        if deliver { handlers.forEach { $0(payload) } }
    }

    /// 还挂着、没有回合在听的请求（点开会话时再弹一次卡）。有回合在听时由回合自己显示。
    func unattendedRequests(_ sid: String) -> [(id: String, frame: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        guard listeners[sid] == nil else { return [] }
        return waiting.filter { $0.value.sid == sid }.sorted { $0.value.seq < $1.value.seq }.map { ($0.key, $0.value.frame) }
    }

    /// 一个还挂着的请求（按卡片编号找）。
    func waitingRequest(_ id: String) -> (sid: String, frame: [String: Any])? {
        lock.lock(); defer { lock.unlock() }
        return waiting[id].map { ($0.sid, $0.frame) }
    }

    func rememberAnswers(_ id: String, parts: [String:Any]) {
        lock.lock(); defer { lock.unlock() }
        waiting[id]?.frame["answerParts"] = parts
    }

    /// 交回去时 dsh 说没有这个请求（not-pending）：在别处答过、了结帧没收到，别再当它挂着。
    func forget(_ id: String) { lock.lock(); waiting[id] = nil; lock.unlock() }

    /// 一条事件流断了（服务端这条流出错、socket 关了）。dsh 还活着就只重连这一条：重连后它会重放还没答的提问和审批；
    /// 结束整个服务的话，所有回答都会失败，后台任务（开发服务器等）也会被一起结束。重连一直不成才当成服务没了。
    private func streamLost(_ task: URLSessionWebSocketTask, _ gen: Int) {
        lock.lock()
        guard gen == generation, let i = sockets.firstIndex(where: { $0 === task }) else { lock.unlock(); return }
        streamFailures += 1
        // 握手后 originalRequest 里是 http:// 的地址，按端口和流名重新拼
        guard ready, proc?.isRunning == true, streamFailures <= 5, let name = task.originalRequest?.url?.lastPathComponent,
              let url = URL(string: "ws://127.0.0.1:\(port)/api/\(name)") else {
            lock.unlock(); disconnected(gen); return
        }
        sockets.remove(at: i)
        let interrupted = name == "events.mux" ? listeners.values.flatMap { $0.values } : []
        // 稍等再连：dsh 正在退出时进程还没收尾，马上重连只会白白失败几次。
        // 断开前已连稳的从 0.3 秒起；刚连上又断就翻倍，封顶 5 秒（等待期间漏的事件由重连后的历史核对补上）
        let stable = streamUpSince[name].map { Date().timeIntervalSince($0) >= (TestHooks.dshStreamStableAfter ?? 30) } ?? false
        let delay = stable ? 0.3 : min((reconnectDelay[name] ?? 0.15) * 2, 5)
        reconnectDelay[name] = delay
        streamUpSince[name] = nil
        lock.unlock()
        interrupted.forEach { $0(["type": "_streamGap"]) }
        task.cancel(with: .goingAway, reason: nil)
        let wait = TestHooks.dshReconnectWait?(name, delay) ?? delay
        eventQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self else { return }
            let fresh = self.streams.webSocketTask(with: url)
            fresh.maximumMessageSize = 64 << 20
            self.lock.lock()
            guard self.generation == gen else { self.lock.unlock(); return }
            self.sockets.append(fresh)
            self.lock.unlock()
            fresh.resume()
            self.pump(fresh, gen)
            // 重连成功就清零：事件稀疏时一直等不到业务帧，几次各自恢复了的断流不能累计成「连续失败」把健康的服务停掉
            fresh.sendPing { error in
                guard error == nil else { return }
                self.eventQueue.async {
                    self.lock.lock()
                    let current = self.generation == gen && self.sockets.contains(fresh)
                    if current { self.streamFailures = 0; self.streamUpSince[name] = Date() }
                    let handlers = current && name == "events.mux" ? self.listeners.values.flatMap { $0.values } : []
                    self.lock.unlock()
                    handlers.forEach { $0(["type": "_streamReady"]) }
                }
            }
        }
    }

    /// 事件流断了（服务退出、崩了）：告诉正在等的回答，下次用的时候重新起。
    private func disconnected(_ gen: Int) {
        lock.lock()
        guard gen == generation, !sockets.isEmpty else { lock.unlock(); return }
        let all = listeners.values.flatMap { Array($0.values) }
        lock.unlock()
        shutdown(generation: gen)
        all.forEach { $0(["type": "_disconnected"]) }
    }

    /// 停掉服务（App 退出、事件流断了）。SIGTERM 它半秒内就退。
    @discardableResult
    func shutdown(generation expected: Int? = nil, preservePending: Bool = false) -> Bool {
        lock.lock()
        guard expected == nil || expected == generation, !preservePending || waiting.isEmpty else { lock.unlock(); return false }
        generation += 1
        let oldSockets = sockets, oldProc = proc, oldLocks = writeLocks
        writeLocks = [:]
        sockets = []
        port = 0
        ready = false
        proc = nil
        diskMarks = [:]
        lastWrite = [:]
        activeJobs = [:]
        reconnectDelay = [:]
        streamUpSince = [:]
        deletedDirectoryPrefix = nil
        let dropped = waiting.filter { listeners[$0.value.sid] == nil }.map { (sid: $0.value.sid, id: $0.key) }
        waiting = [:]
        let tell = unattended
        lock.unlock()
        oldSockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
        // 包装进程等 dsh 退出才结束；这之前旧服务仍可能写盘。
        withExtendedLifetime(oldLocks) {
            if let p = oldProc, p.isRunning { p.terminate(); p.waitUntilExit() }
        }
        dropped.forEach { tell?($0.sid, $0.id, nil) }   // 服务没了，挂着的请求也跟着没了：没人听时摆出来的卡片撤掉
        return true
    }

    /// 盯一个会话的事件（两条流上带这个 sessionId 的帧都会来）。返回的号用来取消。
    /// 这个会话里已经挂着的提问和审批（dsh 自己开的一轮发的）先补发给它，没人听时摆出来的卡片撤掉。
    /// 登记和补发都在事件队列上做：和分发互不穿插，同一个请求不会补发了又再交一次。不能在事件队列上调用。
    func listen(_ sessionId: String, _ handler: @escaping ([String: Any]) -> Void) -> Int {
        eventQueue.sync {
            lock.lock()
            let alone = listeners[sessionId] == nil
            nextToken += 1
            let token = nextToken
            listeners[sessionId, default: [:]][token] = handler
            let replay = waiting.filter { $0.value.sid == sessionId }.sorted { $0.value.seq < $1.value.seq }
            let tell = unattended
            lock.unlock()
            for (id, w) in replay {
                if alone { tell?(sessionId, id, nil) }
                handler(w.frame)
            }
            return token
        }
    }

    func unlisten(_ sessionId: String, _ token: Int) {
        lock.lock()
        listeners[sessionId]?[token] = nil
        if listeners[sessionId]?.isEmpty == true { listeners[sessionId] = nil }
        let alone = listeners[sessionId] == nil && waiting.contains { $0.value.sid == sessionId }
        lock.unlock()
        guard alone else { return }
        // 回合结束了 dsh 那边还在等（比如回合靠空闲兜底收的尾）：交回给「没人听」的提示，不让它悄悄挂着。
        // 停止时答掉的审批，了结帧可能比回合收尾晚一点到：等一秒再看，免得闪一下「在等你回答」
        eventQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let left = self.listeners[sessionId] != nil ? [] : self.waiting.filter { $0.value.sid == sessionId }
                .sorted { $0.value.seq < $1.value.seq }.map { (id: $0.key, frame: $0.value.frame) }
            let tell = self.unattended
            self.lock.unlock()
            left.forEach { tell?(sessionId, $0.id, $0.frame) }
        }
    }

}
