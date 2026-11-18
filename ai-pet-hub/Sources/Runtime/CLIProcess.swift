// 跑 CLI 进程：启动、一行一行读输出、往标准输入写、停止（连同它启动的命令）。
import Cocoa
import CFNetwork

/// 所有子进程共用登记：启动和退出标记在同一把锁下，退出时不会漏掉刚启动的进程。
final class ChildProcesses {
    static let shared = ChildProcesses()
    private let lock = NSLock()
    private var roots = Set<pid_t>()
    private var quitting = false

    func start(_ proc: Process, onExit: @escaping () -> Void = {}) throws {
        lock.lock(); defer { lock.unlock() }
        guard !quitting else {
            throw NSError(domain: "AIPetHub", code: 1, userInfo: [NSLocalizedDescriptionKey: "App 正在退出"])
        }
        proc.terminationHandler = { [self] p in
            lock.lock(); roots.remove(p.processIdentifier); lock.unlock()
            onExit()
        }
        try proc.run()
        roots.insert(proc.processIdentifier)
    }

    func owns(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return roots.contains(pid)
    }

    func beginShutdown() -> [pid_t] {
        lock.lock(); defer { lock.unlock() }
        quitting = true
        return Array(roots)
    }
}

/// 子进程 stdout / stderr 的线程安全缓冲。
final class OutputBuffer {
    private var data = Data()
    private let lock = NSLock()
    private let limit: Int?
    init(limit: Int? = nil) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if let limit = limit, data.count > limit { data.removeFirst(data.count - limit) }
    }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 把子进程的输出切成整行，交给实时解析。
final class LineSplitter {
    private var pending = Data()
    private let lock = NSLock()

    func feed(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let rest = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return rest
    }
}

/// 往 CLI 的标准输入一行一行写 JSON。
final class LiveInput {
    let pipe = Pipe()
    private let lock = NSLock()
    private var closed = false
    private var abandoned = false
    private let writes = DispatchQueue(label: "AIPetHub.liveInput")

    init() { signal(SIGPIPE, SIG_IGN) }   // CLI 已经退出时再写：返回失败，而不是整个 App 被信号结束

    @discardableResult
    func send(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        // 只承诺排队；CLI 尚未启动或暂时不读输入时，不能卡住调用线程。
        writes.async { [self] in
            lock.lock(); let skip = abandoned; lock.unlock()
            guard !skip else { return }
            do { try pipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A])) }
            catch { lock.lock(); closed = true; lock.unlock() }
        }
        return true
    }

    /// 关掉输入：CLI 把手头的事做完就退出。
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        writes.async { [self] in try? pipe.fileHandleForWriting.close() }
    }

    /// 启动失败时没有子进程替我们关读端，必须主动关掉，让已堵住的写入以 EPIPE 返回。
    func abandon() {
        lock.lock()
        closed = true
        abandoned = true
        lock.unlock()
        try? pipe.fileHandleForReading.close()
        close()
    }
}

/// 一个 CLI 进程：启动、读它的输出、等它退出。平时由 runCLI 现起现用；
/// 也可以先起好等着（预热）——这时到的输出先存着，等回答接手（adopt）时原样补给它。
final class CLIProcess {
    let proc = Process()
    let input: LiveInput?
    /// 预热时：这个进程是按什么设置起的（会话、模型、权限…），接手前要对得上
    var warmKey = ""
    /// 预热时接的那个会话的记录文件（接手前看它有没有被别处改过）
    var warmFile: String?
    var startedAt = Date()
    /// 预热做到哪一步了（各位自己定义；0 = 只是起来了）
    // 2 表示 resume 已发出，3 表示已收到答复。答复留给接手者处理，避免重复 resume。
    var stage = 0
    var warmBaseline: [String]?
    private var pendingResume: (() -> Bool)?

    func requestWarmResume(_ resume: @escaping () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        guard warmFilter != nil, stage < 2 else { return }
        pendingResume = resume
        resumeWhenReady()
    }

    func resumeWhenReady() {
        guard stage == 1, let resume = pendingResume else { return }
        pendingResume = nil
        if resume() { stage = 2 }
    }

    func withWarmLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    /// 预热阶段看每一行输出：返回 true = 这一行是开场白的答复，已经处理掉，不留给接手的回答
    var warmFilter: ((String) -> Bool)?

    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let outBuf: OutputBuffer
    private let errBuf: OutputBuffer
    private let splitter = LineSplitter()
    private let readLock = NSLock()
    private var readingStopped = false
    private let lock = NSLock()
    private var pending: [String] = []
    private var handler: ((String) -> Void)?
    private let exited = DispatchSemaphore(value: 0)
    private let outDone = DispatchSemaphore(value: 0)
    private let errDone = DispatchSemaphore(value: 0)

    private let streamsOutput: Bool

    // 流式回答已逐行消费，整份缓冲只留兜底尾部；查询和辅助命令显式保留完整输出。
    init(input: LiveInput?, outputLimit: Int? = 1 << 20, streamsOutput: Bool = true) {
        self.input = input
        self.streamsOutput = streamsOutput
        outBuf = OutputBuffer(limit: outputLimit)
        errBuf = OutputBuffer(limit: outputLimit)
    }

    func start(executable: String, arguments: [String], cwd: String, environment: [String: String]) throws {
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = environment
        proc.standardInput = input?.pipe ?? FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try ChildProcesses.shared.start(proc) { [exited] in exited.signal() } }
        catch { input?.abandon(); throw error }
        startedAt = Date()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { handle.readabilityHandler = nil; return }
            self.readLock.lock(); defer { self.readLock.unlock() }
            guard !self.readingStopped else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; self.outDone.signal(); return }
            self.outBuf.append(chunk)
            if self.streamsOutput { self.deliver(self.splitter.feed(chunk)) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { handle.readabilityHandler = nil; return }
            self.readLock.lock(); defer { self.readLock.unlock() }
            guard !self.readingStopped else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; self.errDone.signal(); return }
            self.errBuf.append(chunk)
        }
    }

    /// 有人接手了就直接给它；还没有就过一遍预热的筛子，剩下的存着。一直拿着锁，保证顺序不乱。
    private func deliver(_ lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        if let h = handler { lines.forEach(h); return }
        for line in lines where warmFilter?(line) != true { pending.append(line) }
    }

    /// 回答接手这个进程：先做 before，再把存着的输出按顺序补给它，之后新到的直接给它。
    @discardableResult
    func adopt(when valid: () -> Bool = { true }, before: (() -> Void)? = nil, _ onLine: @escaping (String) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid() else { return false }
        warmFilter = nil
        pendingResume = nil
        before?()
        let backlog = pending
        pending = []
        handler = onLine
        backlog.forEach(onLine)
        return true
    }

    /// 辅助命令：期限只限制进程退出，退出后读输出最多再等 3 秒。
    func waitForExit(until deadline: DispatchTime, onTimeout: () -> Void) -> (out: String, err: String, timedOut: Bool) {
        let timedOut = exited.wait(timeout: deadline) != .success
        if timedOut {
            onTimeout()
        } else {
            let outputDeadline = DispatchTime.now() + 3
            _ = outDone.wait(timeout: outputDeadline)
            _ = errDone.wait(timeout: outputDeadline)
        }
        stopReading()
        return (outBuf.string, errBuf.string, timedOut)
    }

    private func stopReading() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // 与已经进入的回调同步，返回之后不再修改缓冲，也不让孙进程继续占着读端。
        readLock.lock(); defer { readLock.unlock() }
        readingStopped = true
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        if let rest = splitter.flush() { deliver([rest]) }
    }

    /// 等进程退出，返回 stdout / stderr。
    func waitForExit() -> (out: String, err: String) {
        exited.wait()
        // 进程退出后管道应很快读完；若有后台孙进程还占着管道，最多再等 3 秒。
        let deadline = DispatchTime.now() + 3
        _ = outDone.wait(timeout: deadline)
        _ = errDone.wait(timeout: deadline)
        stopReading()
        return (outBuf.string, errBuf.string)
    }
}

// 进程树：不依赖 App 的任何状态，所以是普通函数（文档预览那样没有 AppDelegate 的地方也用得上）。

/// pid 的所有子孙进程（深的在前），从系统进程表里找。
func descendants(of root: pid_t) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    var children: [pid_t: [pid_t]] = [:]
    for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
        children[p.kp_eproc.e_ppid, default: []].append(p.kp_proc.p_pid)
    }
    var out: [pid_t] = []
    func walk(_ pid: pid_t, depth: Int) {
        guard depth < 64 else { return }
        for c in children[pid] ?? [] where c != pid { walk(c, depth: depth + 1); out.append(c) }
    }
    walk(root, depth: 0)
    return out
}

/// 结束 CLI 以及它启动的所有命令（测试、编译、服务器……），否则这些命令会在后台一直跑下去。
/// 先 SIGTERM，3 秒后还活着的 SIGKILL。名单要在发信号前取：父进程退出后子进程会被系统收养，就找不到了。
func terminateTree(_ root: pid_t) {
    let tree = descendants(of: root) + [root]
    tree.forEach { kill($0, SIGTERM) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

extension AppDelegate {
    /// 跑一个辅助命令等它结束（找命令、做验证、git、解压……），拿完整输出；不登记到「正在回答」里。
    /// 最多等 timeout 秒，超时就结束整棵进程树（timedOut，status 是 -2）；启动不了 status 是 -1、原因在 err 里。
    /// environment 不给就用 CLI 的那套环境（补了 PATH 和系统代理）。
    func runTool(_ executable: String, _ arguments: [String], cwd: String, environment: [String: String]? = nil,
                 timeout: TimeInterval) -> (out: String, err: String, status: Int32, timedOut: Bool) {
        let cli = CLIProcess(input: nil, outputLimit: nil, streamsOutput: false)
        let deadline = DispatchTime.now() + (hooks.toolTimeout ?? timeout)
        do { try cli.start(executable: executable, arguments: arguments, cwd: cwd, environment: environment ?? cliEnvironment()) }
        catch { return ("", error.localizedDescription, -1, false) }
        hooks.toolStarted?()
        let result = cli.waitForExit(until: deadline) { terminateTree(cli.proc.processIdentifier) }
        return (result.out, result.err, result.timedOut ? -2 : cli.proc.terminationStatus, result.timedOut)
    }

    /// 跑一个 CLI 到它退出，stdout 一行一行交给 onStdoutLine。agent 是登记进程用的键（回答时是「agent#reqId」）。
    /// input：交互式回答时的标准输入（LiveTurn.swift / Prewarm.swift），不给就是关着的。
    /// warm：一个已经预热好、在等着的进程（见 LiveTurn.swift / Prewarm.swift 的预热）——给了就接手它，不另起；它已经死了就返回 warmDied，由调用方重建这一轮。
    /// onAdopt：接手那一刻、处理任何输出之前做的事（比如预热只做到一半时，把剩下的开场白发出去）。
    func runCLI(agent: String, executable: String, arguments: [String], cwd: String,
                extraEnv: [String: String] = [:], input: LiveInput? = nil, warm: CLIProcess? = nil,
                onAdopt: (() -> Void)? = nil, onStdoutLine: ((String) -> Void)? = nil) -> CLIResult {
        // 正常回答的记录归 ask 所有；自测等直接调用没有外层回答，这条临时记录归 runCLI 自己所有。
        procLock.lock()
        let ownsAsk = asks[agent] == nil
        if ownsAsk { asks[agent] = AskState() }
        procLock.unlock()
        defer {
            if ownsAsk {
                procLock.lock(); asks[agent] = nil; procLock.unlock()
            }
        }
        if let warm = warm, !warm.proc.isRunning {
            warm.input?.abandon()
            // 还没接手、没向活进程提问：停止标记仍在回答记录上，冷启动的那一轮也能看到。
            return CLIResult(out: "", err: "", status: -1, cancelled: false, launchError: nil, warmDied: true)
        }
        let adopted = warm
        let cli = adopted ?? CLIProcess(input: input, outputLimit: onStdoutLine == nil ? nil : 1 << 20,
                                        streamsOutput: onStdoutLine != nil)

        // 先登记再启动：停止按钮可能在进程启动前就按下了（cancel 会先记下这个键）
        procLock.lock()
        if asks[agent]?.cancelled == true {
            procLock.unlock()
            if let w = adopted { terminateTree(w.proc.processIdentifier) } else { cli.input?.abandon() }
            return CLIResult(out: "", err: "", status: -1, cancelled: true, launchError: nil)
        }
        asks[agent]?.proc = cli.proc
        procLock.unlock()
        hooks.cliRegistered?(agent, cli.proc)
        if adopted == nil {
            do {
                try cli.start(executable: executable, arguments: arguments, cwd: cwd,
                              environment: cliEnvironment(agent.hasPrefix("claude#") ? extraEnv.merging(claudeEntrypointEnv) { a, _ in a } : extraEnv))
            } catch {
                cli.input?.abandon()
                procLock.lock()
                if asks[agent]?.proc === cli.proc { asks[agent]?.proc = nil }
                let cancelled = asks[agent]?.cancelled == true
                procLock.unlock()
                return CLIResult(out: "", err: "", status: -1, cancelled: cancelled,
                                 launchError: cancelled ? nil : error.localizedDescription)
            }
        }
        hooks.cliStarted?(agent, cli.proc)
        // 登记后、启动完成前按下的停止：那时进程还没跑起来，cancel 杀不到，这里补上
        procLock.lock()
        let stopNow = asks[agent]?.cancelled == true
        procLock.unlock()
        if stopNow { terminateTree(cli.proc.processIdentifier) }

        // 从取走进程到真正接手之间，resume 回复和外部写入都可能刚到。
        let usable = cli.adopt(when: { cli.warmBaseline == nil || !self.changedElsewhere(cli) }, before: onAdopt, onStdoutLine ?? { _ in })
        if !usable { terminateTree(cli.proc.processIdentifier) }
        let (out, err) = cli.waitForExit()
        hooks.cliExited?(agent, cli.proc)

        procLock.lock()
        if asks[agent]?.proc === cli.proc { asks[agent]?.proc = nil }
        let cancelled = asks[agent]?.cancelled == true
        procLock.unlock()

        return CLIResult(out: out, err: err, status: cli.proc.terminationStatus, cancelled: cancelled, launchError: nil, warmDied: !usable && !cancelled)
    }

    /// CLI 的环境变量：PATH 里补上常见的安装位置，并把 macOS 系统代理同步给子进程（不覆盖已显式设置的值）。
    /// App 起的 Claude 在会话记录里写 entrypoint = aipethub，和别的工具派出去的 `claude -p`（sdk-cli）分开，
    /// 侧栏据此把后者归进「任务会话」（ClaudeHistory.swift 的 claudeSummary）。
    var claudeEntrypointEnv: [String: String] { ["CLAUDE_CODE_ENTRYPOINT": "aipethub"] }

    func cliEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let basePath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { basePath + ":" + $0 } ?? basePath
        mergeSystemProxy(into: &env)
        extra.forEach { env[$0.key] = $0.value }
        return env
    }

    /// 从 macOS 系统代理设置读取 HTTP/HTTPS/SOCKS 代理与绕过列表，注入到 CLI 环境变量。
    /// 图形界面 App 启动时不会继承终端里的代理变量，而 Go/Node 等 CLI 默认不读系统代理，会导致静默刷新超时。
    private func mergeSystemProxy(into env: inout [String: String]) {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return }

        func setIfMissing(_ keys: [String], _ value: String) {
            guard keys.allSatisfy({ (env[$0] ?? "").isEmpty }) else { return }
            for k in keys { env[k] = value }
        }

        func proxyURL(enableKey: String, hostKey: String, portKey: String, scheme: String) -> String? {
            guard (settings[enableKey] as? NSNumber)?.boolValue == true,
                  let host = settings[hostKey] as? String, !host.isEmpty,
                  let port = (settings[portKey] as? NSNumber)?.intValue, port > 0 else { return nil }
            return "\(scheme)://\(host):\(port)"
        }

        if let url = proxyURL(enableKey: kCFNetworkProxiesHTTPEnable as String,
                              hostKey: kCFNetworkProxiesHTTPProxy as String,
                              portKey: kCFNetworkProxiesHTTPPort as String,
                              scheme: "http") {
            setIfMissing(["HTTP_PROXY", "http_proxy"], url)
        }
        if let url = proxyURL(enableKey: kCFNetworkProxiesHTTPSEnable as String,
                              hostKey: kCFNetworkProxiesHTTPSProxy as String,
                              portKey: kCFNetworkProxiesHTTPSPort as String,
                              scheme: "http") {
            setIfMissing(["HTTPS_PROXY", "https_proxy"], url)
        }
        if let url = proxyURL(enableKey: kCFNetworkProxiesSOCKSEnable as String,
                              hostKey: kCFNetworkProxiesSOCKSProxy as String,
                              portKey: kCFNetworkProxiesSOCKSPort as String,
                              scheme: "socks5") {
            setIfMissing(["ALL_PROXY", "all_proxy"], url)
        }
        if let exceptions = settings[kCFNetworkProxiesExceptionsList as String] as? [String] {
            let list = exceptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !list.isEmpty {
                setIfMissing(["NO_PROXY", "no_proxy"], list.joined(separator: ","))
            }
        }
    }

    /// 停止一次回答（给 reqId）或这一位的全部回答。进程按「agent#reqId」登记，同一位可以同时跑好几个会话。
    func cancel(agent: String, reqId: Int? = nil) {
        procLock.lock()
        let keys = asks.keys.filter { k in
            if let r = reqId { return k == "\(agent)#\(r)" }
            return k == agent || k.hasPrefix(agent + "#")
        }
        let procs = keys.compactMap { k in asks[k]?.proc.map { (proc: $0, live: asks[k]?.live) } }
        // 没有自己的进程的回答（DeepSeek 走共用的本机服务）：直接请那一轮停
        let liveOnly = keys.compactMap { k in asks[k]?.proc == nil ? asks[k]?.live : nil }
        // 还在准备、或进程已退但回答尚未收尾的记录也保留停止标记。
        keys.forEach { asks[$0]?.cancelled = true }
        procLock.unlock()
        liveOnly.forEach { live in live.locked { live.interrupt() } }
        for (p, live) in procs where p.isRunning {
            // 交互式回答：先请它自己停（会话记录收尾得干净），4 秒后还没退出再连同它启动的命令一起结束
            guard let live = live else { terminateTree(p.processIdentifier); continue }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if p.isRunning { terminateTree(p.processIdentifier) }
            }
            live.locked { live.interrupt() }
        }
    }

    /// App 退出不会再执行延迟回调，名单先取全，再同步给所有进程最多一秒收尾。
    func terminateAllChildren() {
        let roots = ChildProcesses.shared.beginShutdown()
        let tree = Set(roots.flatMap { descendants(of: $0) + [$0] })
        tree.forEach { kill($0, SIGTERM) }
        let deadline = DispatchTime.now() + 1
        while DispatchTime.now() < deadline, tree.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    func fallbackReply(_ res: CLIResult, cli: String, preferStderr: Bool = false) -> String {
        let out = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = res.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty && !(preferStderr && !err.isEmpty) { return out }
        if !err.isEmpty { return "⚠️ \(cli) 出错（退出码 \(res.status)）：\n" + String(err.suffix(3000)) }
        return "⚠️ \(cli) 没有返回内容（退出码 \(res.status)）。"
    }

    /// 登记着的 CLI 进程号。
    func runningPid(_ key: String) -> pid_t? {
        procLock.lock(); defer { procLock.unlock() }
        guard let p = asks[key]?.proc, p.isRunning else { return nil }
        return p.processIdentifier
    }
}
