// 选用哪几位 AI：找本机装了哪些 CLI，添加之前真的发一句话验证它答得上来。
import Cocoa

extension AppDelegate {
    /// 在登录 shell 的 PATH 里找一个命令（固定的几个安装位置里没有时用：别人可能装在 nvm、volta、自己的目录里）。
    /// 起一次登录 shell 要零点几秒，所以结果记下来；没找到的只记一分钟（可能刚装上）。
    func lookupOnPath(_ name: String) -> String? {
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        procLock.lock()
        let cached = pathLookupCache[name]
        procLock.unlock()
        if let c = cached, c.path != nil || Date().timeIntervalSince(c.at) < 60 { return c.path }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { fm.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let res = runOnce(shell, ["-lc", "command -v \(name)"], cwd: home, timeout: 8)
        let found = res.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
        procLock.lock()
        pathLookupCache[name] = (found, Date())
        procLock.unlock()
        return found
    }

    /// 跑一个命令等它结束，最多等 timeout 秒（超时就结束它）。只用来找命令、做验证，不登记到「正在回答」里。
    func runOnce(_ executable: String, _ arguments: [String], cwd: String, timeout: TimeInterval) -> (out: String, err: String, status: Int32, timedOut: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.environment = cliEnvironment()
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        do { try proc.run() } catch { return ("", error.localizedDescription, -1, false) }
        // 两个管道各用一个线程读完：输出多的时候不读会把管道填满，进程就卡住不退了
        group.enter(); DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            if group.wait(timeout: .now() + 3) == .timedOut { kill(proc.processIdentifier, SIGKILL); _ = group.wait(timeout: .now() + 2) }
        }
        proc.waitUntilExit()
        return (String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "", proc.terminationStatus, timedOut)
    }

    /// 这一位的 CLI 在哪，以及验证时怎么让它答一句话。没装返回 nil。
    func agentProbe(_ agent: String) -> (path: String, verify: [String], hint: String)? {
        let ask = "只回复两个字母：OK"
        switch agent {
        case "gemini":
            guard let s = geminiSetup(AskRequest(agent: "gemini", reqId: 0, prompt: "", model: "", effort: "", permissionMode: "", workspace: "", conversationId: "")) else { return nil }
            return (s.agy, ["-p", ask, "--print-timeout", "80s"], "")
        case "claude":
            guard let c = claudeCommand() else { return nil }
            return (c.executable, c.prefix + ["-p", ask], "")
        case "gpt":
            guard let c = codexExecutable() else { return nil }
            return (c, ["exec", "--skip-git-repo-check", ask], "")
        case "deepseek":
            guard let d = dshExecutable() else { return nil }
            return (d, ["--profile", "headless", ask], "")
        default:
            return nil
        }
    }

    /// 每一位装没装：网页打开「添加」菜单、以及第一次启动时问。
    func probeAgents(_ agents: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let items: [[String: Any]] = agents.map { a in
                let p = self.agentProbe(a)
                return ["agent": a, "found": p != nil, "path": p?.path ?? ""]
            }
            DispatchQueue.main.async { self.sendToJS("onAgentsProbed", ["items": items]) }
        }
    }

    /// 添加之前：真的让它答一句话。答得上来才算能用（装了但没登录、额度用完、网络不通都会在这里露出来）。
    func verifyAgent(_ agent: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            var payload: [String: Any] = ["agent": agent, "ok": false]
            if let p = self.agentProbe(agent), agent == "gpt",
               self.runOnce(p.path, ["login", "status"], cwd: self.home, timeout: 15).status != 0 {
                // Codex 没登录时 exec 会一直等，验证要白等 100 秒：先问它登录了没有（零点几秒）
                payload["path"] = p.path
                payload["error"] = "Codex 还没有登录：在终端运行 codex login 登录后再试"
            } else if let p = self.agentProbe(agent) {
                let dir = NSTemporaryDirectory() + "aipethub-verify"
                try? self.fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let res = self.runOnce(p.path, p.verify, cwd: dir, timeout: 100)
                let reply = res.out.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = res.status == 0 && !res.timedOut && !reply.isEmpty
                payload["ok"] = ok
                payload["path"] = p.path
                payload["reply"] = String(reply.suffix(200))
                if !ok {
                    let err = res.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    let raw = res.timedOut ? "等了 100 秒没有答复（网络不通，或者它在等登录）"
                        : (err.isEmpty ? (reply.isEmpty ? "它没有输出任何内容（退出码 \(res.status)）" : String(reply.suffix(300))) : String(err.suffix(300)))
                    payload["error"] = self.readableSetupError(agent, raw)
                }
            } else {
                payload["error"] = "没有在这台电脑上找到它的命令行工具"
            }
            payload["seconds"] = Date().timeIntervalSince(started)
            DispatchQueue.main.async { self.sendToJS("onAgentVerified", payload) }
        }
    }

    /// 验证失败的原因换成看得懂的话（最常见的是装了没登录），后面附上原文。
    func readableSetupError(_ agent: String, _ raw: String) -> String {
        let lower = raw.lowercased()
        let login = ["gemini": "在终端运行 agy 按提示登录", "claude": "在终端运行 claude 登录",
                     "gpt": "在终端运行 codex login 登录", "deepseek": "按 dsh 的说明配置 DeepSeek 的 API 密钥"][agent] ?? ""
        if lower.contains("not logged in") || lower.contains("/login") || lower.contains("missing_credential")
            || lower.contains("no api key") || lower.contains("unauthorized") || lower.contains("authentication") {
            return "还没有登录或没有配置密钥：\(login)。（\(String(raw.prefix(120))))"
        }
        return raw
    }
}
