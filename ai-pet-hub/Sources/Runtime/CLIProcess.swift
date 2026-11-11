// 跑 CLI 进程：启动、一行一行读输出、往标准输入写、停止（连同它启动的命令）。
import Cocoa

/// 子进程 stdout / stderr 的线程安全缓冲。
final class OutputBuffer {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
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

    init() { signal(SIGPIPE, SIG_IGN) }   // CLI 已经退出时再写：返回失败，而不是整个 App 被信号结束

    @discardableResult
    func send(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        lock.lock(); defer { lock.unlock() }
        if closed { return false }
        do { try pipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A])); return true } catch { return false }
    }

    /// 关掉输入：CLI 把手头的事做完就退出。
    func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; try? pipe.fileHandleForWriting.close() }
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
    var stage = 0
    /// 预热阶段看每一行输出：返回 true = 这一行是开场白的答复，已经处理掉，不留给接手的回答
    var warmFilter: ((String) -> Bool)?

    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let outBuf = OutputBuffer()
    private let errBuf = OutputBuffer()
    private let splitter = LineSplitter()
    private let lock = NSLock()
    private var pending: [String] = []
    private var handler: ((String) -> Void)?
    private let exited = DispatchSemaphore(value: 0)
    private let outDone = DispatchSemaphore(value: 0)
    private let errDone = DispatchSemaphore(value: 0)

    init(input: LiveInput?) { self.input = input }

    func start(executable: String, arguments: [String], cwd: String, environment: [String: String]) throws {
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = environment
        proc.standardInput = input?.pipe ?? FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.terminationHandler = { [exited] _ in exited.signal() }
        try proc.run()
        startedAt = Date()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self = self else { handle.readabilityHandler = nil; return }
            if chunk.isEmpty { handle.readabilityHandler = nil; self.outDone.signal(); return }
            self.outBuf.append(chunk)
            self.deliver(self.splitter.feed(chunk))
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self = self else { handle.readabilityHandler = nil; return }
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
    func adopt(before: (() -> Void)? = nil, _ onLine: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        warmFilter = nil
        before?()
        let backlog = pending
        pending = []
        handler = onLine
        backlog.forEach(onLine)
    }

    /// 等进程退出，返回全部 stdout / stderr。
    func waitForExit() -> (out: String, err: String) {
        exited.wait()
        // 进程退出后管道应很快读完；若有后台孙进程还占着管道，最多再等 3 秒。
        let deadline = DispatchTime.now() + 3
        _ = outDone.wait(timeout: deadline)
        _ = errDone.wait(timeout: deadline)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = splitter.flush() { deliver([rest]) }
        return (outBuf.string, errBuf.string)
    }
}

extension AppDelegate {
    /// 跑一个 CLI 到它退出，stdout 一行一行交给 onStdoutLine。agent 是登记进程用的键（回答时是「agent#reqId」）。
    /// input：交互式回答时的标准输入（LiveTurn.swift / Prewarm.swift），不给就是关着的。
    /// warm：一个已经预热好、在等着的进程（见 LiveTurn.swift / Prewarm.swift 的预热）——给了就接手它，不另起；它已经死了就照常新起一个。
    /// onAdopt：接手那一刻、处理任何输出之前做的事（比如预热只做到一半时，把剩下的开场白发出去）。
    func runCLI(agent: String, executable: String, arguments: [String], cwd: String,
                extraEnv: [String: String] = [:], input: LiveInput? = nil, warm: CLIProcess? = nil,
                onAdopt: (() -> Void)? = nil, onStdoutLine: ((String) -> Void)? = nil) -> CLIResult {
        let adopted = warm.flatMap { $0.proc.isRunning ? $0 : nil }
        let cli = adopted ?? CLIProcess(input: input)

        // 先登记再启动：停止按钮可能在进程启动前就按下了（cancel 会先记下这个键）
        procLock.lock()
        if cancelledAgents.remove(agent) != nil {
            procLock.unlock()
            if let w = adopted { terminateTree(w.proc.processIdentifier) }
            return CLIResult(out: "", err: "", status: -1, cancelled: true, launchError: nil)
        }
        runningProcs[agent] = cli.proc
        procLock.unlock()
        if adopted == nil {
            do {
                try cli.start(executable: executable, arguments: arguments, cwd: cwd, environment: cliEnvironment(extraEnv))
            } catch {
                procLock.lock()
                if runningProcs[agent] === cli.proc { runningProcs[agent] = nil }
                let cancelled = cancelledAgents.remove(agent) != nil
                procLock.unlock()
                return CLIResult(out: "", err: "", status: -1, cancelled: cancelled,
                                 launchError: cancelled ? nil : error.localizedDescription)
            }
        }
        // 登记后、启动完成前按下的停止：那时进程还没跑起来，cancel 杀不到，这里补上
        procLock.lock()
        let stopNow = cancelledAgents.contains(agent)
        procLock.unlock()
        if stopNow { terminateTree(cli.proc.processIdentifier) }

        cli.adopt(before: onAdopt, onStdoutLine ?? { _ in })
        let (out, err) = cli.waitForExit()

        procLock.lock()
        if runningProcs[agent] === cli.proc { runningProcs[agent] = nil }
        let cancelled = cancelledAgents.remove(agent) != nil
        procLock.unlock()

        return CLIResult(out: out, err: err, status: cli.proc.terminationStatus, cancelled: cancelled, launchError: nil)
    }

    /// CLI 的环境变量：PATH 里补上常见的安装位置。
    func cliEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let basePath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { basePath + ":" + $0 } ?? basePath
        extra.forEach { env[$0.key] = $0.value }
        return env
    }

    /// 停止一次回答（给 reqId）或这一位的全部回答。进程按「agent#reqId」登记，同一位可以同时跑好几个会话。
    func cancel(agent: String, reqId: Int? = nil) {
        procLock.lock()
        var keys = runningProcs.keys.filter { k in
            if let r = reqId { return k == "\(agent)#\(r)" }
            return k == agent || k.hasPrefix(agent + "#")
        }
        // 指定了哪一次回答、它还在准备（进程没登记）：也先记下，runCLI 启动时会看到
        if let r = reqId, activeAsks.contains("\(agent)#\(r)") { keys = ["\(agent)#\(r)"] }
        let procs = keys.compactMap { k in runningProcs[k].map { (proc: $0, live: liveTurns[k]) } }
        // 没有自己的进程的回答（DeepSeek 走共用的本机服务）：直接请那一轮停
        let liveOnly = liveTurns.filter { k, _ in
            runningProcs[k] == nil && (reqId.map { k == "\(agent)#\($0)" } ?? (k.hasPrefix(agent + "#")))
        }.map { $0.value }
        keys.forEach { cancelledAgents.insert($0) }
        procLock.unlock()
        liveOnly.forEach { live in live.locked { live.interrupt() } }
        for (p, live) in procs where p.isRunning {
            // 交互式回答：先请它自己停（会话记录收尾得干净），4 秒后还没退出再连同它启动的命令一起结束
            guard let live = live else { terminateTree(p.processIdentifier); continue }
            live.locked { live.interrupt() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
                if p.isRunning { self?.terminateTree(p.processIdentifier) }
            }
        }
    }

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
        guard let p = runningProcs[key], p.isRunning else { return nil }
        return p.processIdentifier
    }
}
