// 跑 CLI 进程：启动、一行一行读输出、往标准输入写、停止（连同它启动的命令）。App 侧怎么用（runCLI / runTool、环境、停止）在 RunCLI.swift。
import Cocoa

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
        // pending 已经扫过且不含换行，只在新到的字节里找分隔符。
        var rest = chunk[...]
        var lines: [String] = []
        while let nl = rest.firstIndex(of: 0x0A) {
            pending.append(rest[..<nl])
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: true)
            rest = rest[(nl + 1)...]
        }
        pending.append(rest)
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

    /// onExit：进程一退出就调（在退出通知的线程上），让还在等答复的一方不必等满期限。
    func start(executable: String, arguments: [String], cwd: String, environment: [String: String], onExit: @escaping () -> Void = {}) throws {
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = environment
        proc.standardInput = input?.pipe ?? FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try ChildProcesses.shared.start(proc) { [exited] in exited.signal(); onExit() } }
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

/// 进程的启动时间（微秒）。过一阵再按 pid 动手前要核对它：原进程退出后 pid 可能已经给了别的进程。
func processStartTime(_ pid: pid_t) -> Int64? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    return Int64(t.tv_sec) * 1_000_000 + Int64(t.tv_usec)
}

func processIdentities(_ pids: [pid_t]) -> [(pid: pid_t, start: Int64)] {
    pids.compactMap { pid in processStartTime(pid).map { (pid, $0) } }
}

/// 结束事先记下、现在仍是原来那个的进程，连同它们后来启动的命令；规则同 terminateTree（先 TERM，3 秒后 KILL）。
/// 只认名单里的进程：同一 pid 换了启动时间就是别人的，不碰。
func terminateRecorded(_ recorded: [(pid: pid_t, start: Int64)]) {
    let alive = recorded.filter { processStartTime($0.pid) == $0.start }
    guard !alive.isEmpty else { return }
    let tree = alive + processIdentities(alive.flatMap { descendants(of: $0.pid) })
    tree.forEach { kill($0.pid, SIGTERM) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        for p in tree where processStartTime(p.pid) == p.start { kill(p.pid, SIGKILL) }
    }
}
