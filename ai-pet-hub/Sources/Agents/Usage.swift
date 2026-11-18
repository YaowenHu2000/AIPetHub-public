// 三位的剩余用量（模型菜单底下那几行）：各自问自己的 CLI，统一成「名字、还剩百分之几、什么时候重置」。
//   Claude：起一个 CLI 进程，发 get_usage 这个控制请求
//   Codex ：起 app-server，initialize 之后一起问 model/list 和 account/rateLimits/read
//   Gemini：`agy -p /usage`，一行一项、用制表符隔开
// 不在点开菜单时才查：App 启动后在后台每 5 分钟查一轮，菜单打开时直接给手头最新的那份（带上是什么时候查的）。
// 这次没查到就留着上一次的；查到的结果记在本机，下次打开 App 马上就有。
import Cocoa

extension AppDelegate {
    private var usageStoreKey: String { "agentUsage" }

    /// App 启动后调一次：先把上次记下的告诉网页，然后马上查一轮，之后每 5 分钟一轮。
    func startUsagePolling() {
        if let saved = UserDefaults.standard.dictionary(forKey: usageStoreKey) {
            procLock.lock()
            for (agent, value) in saved {
                guard let v = value as? [String: Any], let items = v["items"] as? [[String: Any]], let at = v["at"] as? Double else { continue }
                usageCache[agent] = (Date(timeIntervalSince1970: at), items)
            }
            procLock.unlock()
        }
        let all = { [weak self] in ["gemini", "claude", "gpt", "deepseek"].forEach { if self?.enabledAgents.contains($0) == true { self?.refreshUsage(agent: $0) } } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { all() }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in all() }
    }

    /// 网页要这一位的用量：给手头的那份；一份都没有（刚装好、或者测试窗口里没开后台轮询）就现查。force：不管多新都重查。
    func loadUsage(agent: String, force: Bool) {
        procLock.lock(); let cached = usageCache[agent]; procLock.unlock()
        if let c = cached { sendUsage(agent, c.items, at: c.at, error: nil) }
        if cached == nil || force { refreshUsage(agent: agent) }
    }

    private func sendUsage(_ agent: String, _ items: [[String: Any]], at: Date?, error: String?) {
        var payload: [String: Any] = ["agent": agent, "items": items]
        if let at = at { payload["at"] = at.timeIntervalSince1970 }
        if let e = error { payload["error"] = e }
        sendToJS("onAgentUsage", payload)
    }

    private func refreshUsage(agent: String) {
        procLock.lock()
        let busy = usageLoading.contains(agent)
        if !busy { usageLoading.insert(agent) }
        procLock.unlock()
        if busy { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var items: [[String: Any]]?
            for _ in 0..<2 where items == nil {   // 偶尔一次没答复：再试一次
                switch agent {
                case "claude": items = self.claudeUsage()
                case "gpt": items = self.codexUsage()
                case "deepseek": items = self.deepseekUsage()
                default: items = self.geminiUsage()
                }
            }
            let now = Date()
            self.procLock.lock()
            self.usageLoading.remove(agent)
            if let items = items { self.usageCache[agent] = (now, items) }
            let last = self.usageCache[agent]
            let store = self.usageCache.mapValues { ["at": $0.at.timeIntervalSince1970, "items": $0.items] as [String: Any] }
            if items != nil {
                if TestHooks.selfTest { self.hooks.usageStore?(store) }
                else { UserDefaults.standard.set(store, forKey: self.usageStoreKey) }
            }
            self.procLock.unlock()   // 快照与写回保持同一顺序，不能让较早的快照覆盖后来完成的查询
            DispatchQueue.main.async {
                // 这次没查到：有上一次的就接着显示上一次的，一次都没查到过才说没查到
                if let l = last { self.sendUsage(agent, l.items, at: l.at, error: nil) }
                else { self.sendUsage(agent, [], at: nil, error: "没查到（CLI 没登录、或者这个版本不支持）") }
            }
        }
    }

    /// 起一个 CLI，发几行话，等到 done 说够了（或者超时）就结束它。每来一行输出交给 onLine。
    private func askCLI(_ executable: String, _ arguments: [String], cwd: String? = nil, send lines: [[String: Any]], timeout: TimeInterval,
                        onLine: @escaping (String, LiveInput) -> Bool) {
        let cli = CLIProcess(input: LiveInput())
        let done = DispatchSemaphore(value: 0)
        var finished = false
        // weak：cli 拿着这个闭包，闭包再拿着 cli 的话两边谁也放不掉，三根管道就一直开着，
        // 每 5 分钟漏几个，攒到系统给的 256 个上限后 Pipe() 建不出来，下一次往里写就崩。
        cli.warmFilter = { [weak cli] line in
            guard !finished, let input = cli?.input else { return true }
            if onLine(line, input) { finished = true; done.signal() }
            return true
        }
        guard (try? cli.start(executable: executable, arguments: arguments, cwd: cwd ?? home, environment: cliEnvironment())) != nil else { cli.input?.abandon(); return }
        lines.forEach { cli.input?.send($0) }
        _ = done.wait(timeout: .now() + timeout)
        if cli.proc.isRunning { terminateTree(cli.proc.processIdentifier) }
        _ = cli.waitForExit()   // 等它真的退出（terminateTree 最多 3 秒后强杀），顺便停掉读输出的监听
        cli.input?.close()
    }

    /// 一个会话的上下文用了多少（Claude 答完一轮后问 get_context_usage，Codex 每轮都会报）：告诉网页，模型面板里显示。
    /// parts：是什么占的（每项 id / name / tokens；kind 为 "buffer" 的是留给自动压缩的，不算已用）。各家给得出什么就报什么，给不出就是空的。
    /// estimated：明细是估算的（加起来不一定等于已用）。
    func noteContext(agent: String, conversationId: String, used: Int, max: Int, parts: [[String: Any]] = [], estimated: Bool = false, seq: Int? = nil) {
        guard !conversationId.isEmpty, max > 0 else { return }
        var data: [String: Any] = ["agent": agent, "conversationId": conversationId, "used": used, "max": max,
                                   "parts": parts, "estimated": estimated, "at": Date().timeIntervalSince1970 * 1000]
        data["seq"] = seq
        DispatchQueue.main.async {
            self.sendToJS("onAgentContext", data)
        }
    }

    private func usageItem(_ label: String, used: Double, resets: Double?) -> [String: Any] {
        guard used.isFinite else { return ["label": label, "text": "未知"] }
        var item: [String: Any] = ["label": label, "left": Int(max(0, min(100, 100 - used)).rounded())]
        if let r = resets, r > 0 { item["resetsAt"] = r }
        return item
    }

    private func claudeUsage() -> [[String: Any]]? {
        guard let cmd = claudeCommand() else { return nil }
        var result: [[String: Any]]?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let when: (Any?) -> Double? = { ($0 as? String).flatMap { iso.date(from: $0) }?.timeIntervalSince1970 }
        let args = cmd.prefix + ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        // 顺便在这里问模型列表：Claude Code 在主目录下启动时只报 5 个模型（别的目录下是全的，带旧版本），
        // 不绑定工作空间的对话正是在主目录下跑的，所以完整的列表从这个在临时目录里起的进程拿。
        var gotModels = false, gotUsage = false
        askCLI(cmd.executable, args, cwd: NSTemporaryDirectory(), send: [claudeInitializeRequest,
               ["type": "control_request", "request_id": "aipethub-usage", "request": ["subtype": "get_usage"]]], timeout: 45) { line, _ in
            guard let obj = self.jsonObject(line), obj["type"] as? String == "control_response",
                  let resp = obj["response"] as? [String: Any] else { return false }
            if resp["request_id"] as? String == claudeInitializeId {
                gotModels = true
                DispatchQueue.main.async { self.noteClaudeInitialize(obj, complete: true) }
                return gotUsage
            }
            guard resp["request_id"] as? String == "aipethub-usage" else { return false }
            gotUsage = true
            guard let limits = (resp["response"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return gotModels }
            var items: [[String: Any]] = []
            for l in limits["limits"] as? [[String: Any]] ?? [] {
                guard let percent = (l["percent"] as? NSNumber)?.doubleValue else { continue }
                let scope = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let label: String
                switch l["kind"] as? String {
                case "session": label = "5 小时"
                case "weekly_all": label = "每周"
                default: label = "每周 · \(scope ?? (l["kind"] as? String ?? "其他"))"
                }
                items.append(self.usageItem(label, used: percent, resets: when(l["resets_at"])))
            }
            if items.isEmpty {   // CLI 手头是几分钟前存下的那份时没有 limits，只有这几项
                for (key, label) in [("five_hour", "5 小时"), ("seven_day", "每周")] {
                    guard let l = limits[key] as? [String: Any], let u = (l["utilization"] as? NSNumber)?.doubleValue else { continue }
                    items.append(self.usageItem(label, used: u, resets: when(l["resets_at"])))
                }
                for m in limits["model_scoped"] as? [[String: Any]] ?? [] {   // 单独给某个模型算的周额度（比如 Fable）
                    guard let u = (m["utilization"] as? NSNumber)?.doubleValue else { continue }
                    items.append(self.usageItem("每周 · \(m["display_name"] as? String ?? "其他")", used: u, resets: when(m["resets_at"])))
                }
            }
            result = items
            return gotModels
        }
        return result
    }

    private func codexUsage() -> [[String: Any]]? {
        guard let codex = codexExecutable() else { return nil }
        var result: [[String: Any]]?
        var gotModels = false, gotUsage = false
        askCLI(codex, ["app-server"], send: [codexInitialize], timeout: 45) { line, input in
            guard let obj = self.jsonObject(line), obj["method"] == nil, let id = (obj["id"] as? NSNumber)?.intValue else { return false }
            if id == 1 {
                guard obj["error"] == nil else { return true }
                self.codexInitialized(input)
                input.send(["id": 7, "method": "account/rateLimits/read"])
                return false
            }
            if id == 8 {
                self.noteCodexModels(obj["result"] as? [String: Any] ?? [:])
                gotModels = true
                return gotUsage
            }
            guard id == 7 else { return false }
            gotUsage = true
            guard let limits = (obj["result"] as? [String: Any])?["rateLimits"] as? [String: Any] else { return gotModels }
            var items: [[String: Any]] = []
            for key in ["primary", "secondary"] {
                guard let w = limits[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                let mins = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
                let label = mins >= 10080 ? "每周" : (mins >= 1440 ? "\(mins / 1440) 天" : (mins >= 60 ? "\(mins / 60) 小时" : "\(mins) 分钟"))
                items.append(self.usageItem(label, used: used, resets: (w["resetsAt"] as? NSNumber)?.doubleValue))
            }
            if let credits = limits["credits"] as? [String: Any], (credits["hasCredits"] as? Bool) == true {
                let value = Double(credits["balance"] as? String ?? "") ?? 0
                let balance = (credits["unlimited"] as? Bool) == true ? "不限" : (value.isFinite ? String(format: "%.0f", value.rounded()) : "未知")
                items.append(["label": "额外额度", "text": balance])
            }
            // 手里还有几次「把额度重置回满」（Codex 时不时送的）
            if let resets = ((obj["result"] as? [String: Any])?["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? NSNumber, resets.intValue > 0 {
                items.append(["label": "重置次数", "text": "\(resets.intValue) 次可用"])
            }
            result = items
            return gotModels
        }
        return result
    }

    private func geminiUsage() -> [[String: Any]]? {
        guard let setup = geminiSetup(AskRequest(agent: "gemini", reqId: 0, prompt: "", model: "", effort: "", permissionMode: "", workspace: "", conversationId: "")) else { return nil }
        // 先跑 `agy models` 探路：它失败时只会安静退出，不会像 `agy -p` 一样在代理抖动/断网时直接拉起浏览器要求重登
        guard refreshGeminiModels(setup.agy) else { return nil }
        let res = runTool(setup.agy, ["-p", "/usage", "--print-timeout", "40s"], cwd: home, timeout: 45)
        guard res.status == 0 else { return nil }
        let iso = ISO8601DateFormatter()
        var items: [[String: Any]] = []
        for line in res.out.split(separator: "\n") {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count >= 3, cols[2].hasSuffix("%"), let left = Double(cols[2].dropLast()) else { continue }
            let window = cols[1].contains("Five Hour") ? "5 小时" : (cols[1].contains("Weekly") ? "每周" : cols[1])
            let group = cols[0].hasPrefix("Gemini") ? "" : " · " + cols[0].replacingOccurrences(of: " models", with: "").replacingOccurrences(of: " and ", with: " / ")
            items.append(usageItem(window + group, used: 100 - left, resets: cols.count > 3 ? iso.date(from: cols[3])?.timeIntervalSince1970 : nil))
        }
        return items.isEmpty ? nil : items
    }

    /// agy 现在能用的模型（`agy models`，一行一个「模型-强度 <tab> 名字 (强度)」）：按模型归拢，强度收成这个模型支持的档位。
    /// 跟着用量一起每 5 分钟查一次，所以 agy 那边出了新模型，不用发话、不用重开，菜单里自己就有。
    /// 返回是否成功拿到模型列表（网络不通或鉴权失效时返回 false，供 `geminiUsage` 熔断跳过会弹浏览器的 `agy -p`）。
    @discardableResult
    func refreshGeminiModels(_ agy: String) -> Bool {
        let res = runTool(agy, ["models"], cwd: home, timeout: 30)
        guard res.status == 0 else { return false }
        let choices = res.out.split(separator: "\n").compactMap { line -> (String, String)? in
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, !cols[0].isEmpty, !cols[0].contains(" ") else { return nil }
            return (cols[0], cols[1])
        }
        guard !choices.isEmpty else { return false }
        procLock.lock(); geminiModelIds = Set(choices.map { $0.0 }); procLock.unlock()
        let models = geminiMenuModels(choices)
        DispatchQueue.main.async {
            self.geminiModelsFromCLI = true
            self.sendToJS("onAgentModels", ["agent": "gemini", "models": models])
        }
        return true
    }

    /// DeepSeek 是按量计费的，没有「额度还剩百分之几」，看的是账户里还剩多少钱（DeepSeek 开放平台的 /user/balance）。
    /// 用的是 dsh 自己在用的那把密钥：先看它配置里指定的环境变量（llm-deepseek.apiKeyEnv，默认 DEEPSEEK_API_KEY），
    /// 环境里没有再读 ~/.dsh/.credentials.yaml 里同名的那一行。密钥只用来发这一个请求，不记到别处。
    private func deepseekUsage() -> [[String: Any]]? {
        let settings = (try? String(contentsOfFile: "\(home)/.dsh/settings.yaml", encoding: .utf8)) ?? ""
        let field = { (name: String, text: String) -> String? in
            guard let r = text.range(of: "(?m)^\\s*\(name):\\s*(\\S.*)$", options: .regularExpression) else { return nil }
            var v = String(text[r]).components(separatedBy: ":").dropFirst().joined(separator: ":")
            if let hash = v.range(of: " #") { v = String(v[..<hash.lowerBound]) }
            return v.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        let env = ProcessInfo.processInfo.environment
        let keyName = field("apiKeyEnv", settings) ?? "DEEPSEEK_API_KEY"
        let creds = (try? String(contentsOfFile: "\(home)/.dsh/.credentials.yaml", encoding: .utf8)) ?? ""
        guard let key = env[keyName].flatMap({ $0.isEmpty ? nil : $0 }) ?? field(NSRegularExpression.escapedPattern(for: keyName), creds), !key.isEmpty else { return nil }
        let base = (field("baseURL", settings) ?? env["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/user/balance") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var body: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            body = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 25) == .success, let infos = body?["balance_infos"] as? [[String: Any]], !infos.isEmpty else { return nil }
        var items: [[String: Any]] = []
        for b in infos {
            let unit = (b["currency"] as? String) == "CNY" ? "¥" : ((b["currency"] as? String).map { $0 + " " } ?? "")
            let money = { (k: String) -> String in unit + ((b[k] as? String) ?? "\(b[k] ?? "0")") }
            items.append(["label": "账户余额", "text": money("total_balance")])
            if let g = b["granted_balance"] as? String, (Double(g) ?? 0) > 0 {
                items.append(["label": "其中赠送", "text": money("granted_balance")])
            }
        }
        if body?["is_available"] as? Bool == false { items.append(["label": "状态", "text": "余额不足，暂时不能调用"]) }
        return items
    }
}
