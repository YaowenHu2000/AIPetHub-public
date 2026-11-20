// App 这一侧怎么跑 CLI：一次性辅助命令（runTool）、一问一答的 CLI（runCLI）、子进程环境与系统代理、停止某位的回答、退出时结束所有子进程。
// 和 CLIProcess.swift 分开：那边的类型和进程树不依赖 AppDelegate，这边是用到 App 状态的运行策略。
//
// 「停止」先通过协议请它中断（`interrupt` / `turn/interrupt` / `session/cancel`），4 秒内没退出再按进程树结束它以及它启动的命令；CLI 收到中断可能自己先退出、
// 留下它启动的命令，所以中断前先记下这一轮的子孙进程（pid 和启动时间），4 秒后仍是原进程的照样结束。
// 退出 App 时所有子进程（回答、预热、查用量、辅助命令）一起按进程树结束：先请它们收尾，约 1 秒后还在的强杀；随后删掉本实例还没释放的 Git 快照临时目录。
import Cocoa
import CFNetwork

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
        hooks.cliAdopting?(agent, cli.proc)

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
    /// App 起的 Claude 在会话记录里写 entrypoint = aipethub-session，和别的工具派出去的 `claude -p`（sdk-cli）分开，
    /// 侧栏据此把后者归进「任务会话」（ClaudeHistory.swift 的 claudeSummary）。
    var claudeEntrypointEnv: [String: String] { ["CLAUDE_CODE_ENTRYPOINT": "aipethub-session"] }

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
            // CLI 收到中断可能自己先退出，它启动的命令被系统收养，到点时按它的 pid 就找不到了：中断前先记下这一轮的子孙进程
            let started = processIdentities(descendants(of: p.processIdentifier))
            let grace = {
                if p.isRunning { terminateTree(p.processIdentifier) }
                terminateRecorded(started)
            }
            if let schedule = hooks.stopGraceScheduled { schedule(grace) }
            else { DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: grace) }
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
