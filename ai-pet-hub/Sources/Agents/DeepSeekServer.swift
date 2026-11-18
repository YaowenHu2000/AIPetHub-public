// DeepSeek Harness（dsh）的本机服务。另外三位是「一次回答一个 CLI 进程」，dsh 不一样：它的无界面模式只能一问一答
// （看不到过程、不能接着聊），完整的能力在「网页模式」里——`dsh web` 起一个只听本机的服务，它自带的浏览器界面就是靠这套接口。
// 这里起一个这样的服务常驻着，所有会话共用：
//   · 上行：POST http://127.0.0.1:<端口>/api/<方法名>，请求体 {"type":"client-request","rpcId","method","payload"}，
//     答复 {"type":"server-response","rpcId","result":{"ok":true,"value":…} 或 {"ok":false,"error":{"code","message"}}}（出错也是 HTTP 200）。
//   · 下行：两条只收不发的 WebSocket，每帧一个 JSON {"type":"server-request","rpcId","method","payload"}。
//     /api/events.mux 是所有会话的事件（按 payload.sessionId 分），/api/events.host 是会话的运行状态和出错。
//   · 要人答复的帧（审批）：POST /api/respond，rpcId 原样带回去。
// 没有登录和订阅，连上就收全部；它只认回环地址来的请求。接口没有公开文档，是照着 0.1.0-rc.7 实测的——dsh 升级后这里可能要跟着改。
import Cocoa

final class DshServer {
    private let lock = NSRecursiveLock()
    private var proc: Process?
    private var port = 0
    private var sockets: [URLSessionWebSocketTask] = []
    private var generation = 0
    private var listeners: [String: [Int: ([String: Any]) -> Void]] = [:]
    private var nextToken = 0
    private var ready = false
    private let startupQueue = DispatchQueue(label: "aipethub.dsh.start")
    private let eventQueue = DispatchQueue(label: "aipethub.dsh.events")
    private var sessionQueues: [String: DispatchQueue] = [:]
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
    private let http = DshServer.localSession()
    private let streams = DshServer.localSession()

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return ready && proc?.isRunning == true }

    /// 服务没在跑就起一个并连上两条事件流。成功返回 nil，否则是出错的原因。
    func ensure(executable: String, environment: [String: String], cwd: String) -> String? {
        startupQueue.sync { start(executable: executable, environment: environment, cwd: cwd) }
    }

    private func start(executable: String, environment: [String: String], cwd: String) -> String? {
        if isRunning { return nil }
        shutdown()
        lock.lock(); let gen = generation; lock.unlock()
        let p = Process()
        // 套一层 sh：App 正常退出时会来结束它（SIGTERM → 连 dsh 一起结束）；App 被强制结束、崩了的话没人来通知，
        // 所以它自己每两秒看一眼 App 还在不在，不在了就把 dsh 结束掉，不留下没人管的服务。
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"""
            "$1" web --port 0 --host 127.0.0.1 & c=$!
            trap 'kill $c 2>/dev/null' TERM INT HUP
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
        let outputLock = NSLock(), stderrTail = OutputBuffer(limit: 1500)
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
        if current { proc = p }
        lock.unlock()
        guard current else { if p.isRunning { p.terminate() }; return "dsh 启动已取消" }
        // 等端口/握手时不拿 server 锁，日志和事件回调才能继续排空。
        let reported = found.wait(timeout: .now() + 30) == .success
        outputLock.lock(); let announcedPort = got; outputLock.unlock()
        guard reported, announcedPort > 0 else {
            let why = trimmed(stderrTail.string)
            shutdown(generation: gen)
            return "dsh 的本机服务没有启动起来" + (why.isEmpty ? (reported ? "（还没报出端口就退出了）" : "（30 秒内没有报出端口）") : "：\(String(why.suffix(300)))")
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

    private func pump(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                self.eventQueue.async { self.disconnected(gen) }
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let d = data, let frame = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   var payload = frame["payload"] as? [String: Any] {
                    payload["_rpcId"] = frame["rpcId"]   // 答复审批时要原样带回去
                    let event = payload
                    self.eventQueue.async {
                        self.lock.lock(); let current = self.generation == gen; self.lock.unlock()
                        if current { self.dispatch(event) }
                    }
                }
                self.pump(task, gen)
            }
        }
    }

    private func dispatch(_ payload: [String: Any]) {
        guard let sid = payload["sessionId"] as? String else { return }
        lock.lock()
        let handlers = listeners[sid].map { Array($0.values) } ?? []
        lock.unlock()
        handlers.forEach { $0(payload) }
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
    func shutdown(generation expected: Int? = nil) {
        lock.lock()
        guard expected == nil || expected == generation else { lock.unlock(); return }
        generation += 1
        let oldSockets = sockets, oldProc = proc
        sockets = []
        port = 0
        ready = false
        proc = nil
        lock.unlock()
        oldSockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
        if let p = oldProc, p.isRunning { p.terminate() }
    }

    /// 盯一个会话的事件（两条流上带这个 sessionId 的帧都会来）。返回的号用来取消。
    func listen(_ sessionId: String, _ handler: @escaping ([String: Any]) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextToken += 1
        listeners[sessionId, default: [:]][nextToken] = handler
        return nextToken
    }

    func unlisten(_ sessionId: String, _ token: Int) {
        lock.lock(); defer { lock.unlock() }
        listeners[sessionId]?[token] = nil
        if listeners[sessionId]?.isEmpty == true { listeners[sessionId] = nil }
    }

    /// 调一个方法，等它答复。typert：那一批参数要包在 args 里的端点（commands/execute 等）。
    /// rpcId：自己指定这次调用的编号（发出去的话会带着它出现在事件里，用来认出这句是 App 自己发的）。
    func call(_ method: String, _ payload: [String: Any] = [:], typert: Bool = false, rpcId: String? = nil, timeout: TimeInterval = 60) -> (value: Any?, error: String?, code: String) {
        lock.lock(); let port = self.port; lock.unlock()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else { return (nil, "dsh 的本机服务没有在运行", "not-running") }
        let wrapped: [String: Any] = typert ? ["args": payload] : payload
        let body: [String: Any] = ["type": "client-request", "rpcId": rpcId ?? "aph-" + UUID().uuidString, "method": method, "payload": wrapped]
        let res = post(url, body, timeout: timeout)
        guard let obj = res.json else { return (nil, res.error ?? "dsh 没有答复", "transport") }
        let result = obj["result"] as? [String: Any] ?? [:]
        if result["ok"] as? Bool == true { return (result["value"], nil, "") }
        let e = result["error"] as? [String: Any] ?? [:]
        return (nil, e["message"] as? String ?? "dsh 拒绝了这次调用", e["code"] as? String ?? "error")
    }

    /// 答复一个要人决定的帧（审批）。
    func respond(rpcId: String, value: [String: Any]) {
        lock.lock(); let port = self.port; lock.unlock()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/api/respond") else { return }
        _ = post(url, ["type": "client-response", "rpcId": rpcId, "result": ["ok": true, "value": value]], timeout: 20)
    }

    private func post(_ url: URL, _ body: [String: Any], timeout: TimeInterval) -> (json: [String: Any]?, error: String?) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        var json: [String: Any]?, error: String?
        http.dataTask(with: req) { data, response, err in
            if let e = err { error = e.localizedDescription }
            else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { error = "dsh 返回了 HTTP \(code)" }
            else if let d = data { json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 5) != .success { return (nil, "dsh 没有在 \(Int(timeout)) 秒内答复") }
        return (json, error)
    }
}
