// Claude Code 的历史会话：直接读它的 JSONL 记录。
//
// Claude 续聊期间出现已回答的旁支时，工作步骤保留同期旁支的可见文字。
//
// Claude 停止时保留已显示的正文，重开时跳过 CLI 的合成占位句，并保留已完成的工具步骤。
// 本机记录的崩溃或输出上限优先于仅凭工具结束推断的成功。
//
// Claude 输出中崩溃时也在本机保留提问、附件路径和已显示的正文；重开按会话和提问时间补回，CLI 后来写全同轮时使用原记录。
//
// Claude 首问崩溃时若会话文件尚未创建，重开仍显示原问和失败正文，重试会新建会话。
//
// 认领本机结局的一轮，工作时长算到本机记下的结束时刻：失败或停止前的等待不会写进记录。
import Cocoa

extension AppDelegate {
    func claudeProjectRoots(onError: (String) -> Void = { _ in }) -> [String] {
        // 没装 reclaude、用标准 claude 时：读它的配置目录（CLAUDE_CONFIG_DIR，默认 ~/.claude）
        if let cmd = claudeCommand(), !cmd.reclaude {
            let env = trimmed(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])
            let p = (env.isEmpty ? "\(home)/.claude" : (env as NSString).expandingTildeInPath) + "/projects"
            return [p]
        }
        var roots: [String] = []
        let accounts = "\(home)/.rec/claude/accounts"
        if let error = historyAccessError(accounts, mode: R_OK | X_OK) { onError(error) }
        for acc in ((try? fm.contentsOfDirectory(atPath: accounts)) ?? []).sorted() where !acc.hasPrefix(".") {
            let p = "\(accounts)/\(acc)/config/projects"
            roots.append(p)
        }
        // 装了 reclaude 时克劳蒂娜只用 reclaude：历史会话只读 ~/.rec/claude/accounts/*/config/projects，不再看 ~/.claude-pro、~/.claude
        return roots
    }

    /// 调用方在 claudeQueue 上；同 ID 的副本先沿用列表确定的路径，没有缓存时和列表一样取最新。
    func findClaudeSession(cid: String, files: [(cid: String, path: String, mtime: Date)]? = nil, onError: (String) -> Void = { _ in }) -> String? {
        if let cached = claudeCache[cid], fm.fileExists(atPath: cached.path) { return cached.path }
        if let cached = claudeCache[cid], let error = historyAccessError(cached.path) { onError(error) }
        return (files ?? claudeSessionFiles(onError: onError)).first { $0.cid == cid && fm.fileExists(atPath: $0.path) }?.path
    }

    /// 一行会话记录对应的可展示文字；工具调用、子代理、元信息等返回 nil。
    /// 点了停止之后 Claude Code 自己往记录里写的一条「用户消息」（[Request interrupted by user] / … for tool use）：
    /// 它不是用户说的话，是「这一轮被中断了」的标记。
    func claudeInterruptMarker(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Request interrupted by user")
    }

    private func isClaudePlaceholder(_ message: [String:Any]?) -> Bool {
        message?["model"] as? String == "<synthetic>" && trimmed(textBlocks(message?["content"])) == "No response requested."
    }

    func claudeDisplayText(_ obj: [String: Any]) -> String? {
        for flag in ["isSidechain", "isMeta", "isApiErrorMessage", "isCompactSummary"] where (obj[flag] as? Bool) == true {
            return nil
        }
        // 只有 origin.kind == "human" 才是用户亲手输入；后台任务通知等由 Claude Code 插入的记录也标成 user，要排除
        if obj["type"] as? String == "user", let kind = (obj["origin"] as? [String: Any])?["kind"] as? String, kind != "human" {
            return nil
        }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if isClaudePlaceholder(msg) { return nil }
        let text = stripTagBlocks(textBlocks(msg["content"]), tags: ["system-reminder"])
        if text.isEmpty || claudeInterruptMarker(text) { return nil }
        for prefix in ["<local-command", "<command-name>", "<command-message>", "<bash-input>", "<bash-stdout>",
                       "<bash-stderr>", "<task-notification>", "Caveat: The messages below"] where text.hasPrefix(prefix) {
            return nil
        }
        return text.replacingOccurrences(of: #"</?pasted_content\b[^>]*>"#, with: "", options: .regularExpression)
    }

    /// 逐行遍历（不把整个文件转成字符串）；body 返回 false 时停止。
    func forEachLine(_ data: Data, from start: Data.Index? = nil, _ body: (Data) -> Bool) {
        var lineStart = start ?? data.startIndex
        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            if lineEnd > lineStart, !body(data[lineStart..<lineEnd]) { return }
            lineStart = lineEnd + 1
        }
    }

    /// 文件里最后一行以 marker 开头的 JSON（Claude Code 的标题行是追加写入的）。
    func lastLine(startingWith marker: String, in data: Data) -> [String: Any]? {
        let needle = Data(marker.utf8)
        var searchEnd = data.endIndex
        for _ in 0..<50 {
            guard let r = data.range(of: needle, options: .backwards, in: data.startIndex..<searchEnd) else { return nil }
            if r.lowerBound == data.startIndex || data[r.lowerBound - 1] == 0x0A {
                let end = data[r.lowerBound...].firstIndex(of: 0x0A) ?? data.endIndex
                // 文件可能正写到一半：跳过坏尾行，继续找上一条完整记录。
                if let obj = jsonObject(data[r.lowerBound..<end]) { return obj }
            }
            searchEnd = r.lowerBound
        }
        return nil
    }

    /// 列表只需要标题、目录和第一条消息：标题从文件末尾找，首条消息只看开头，避免解析几十 MB 的会话。
    func claudeSummary(path: String, cid: String, mtime: Date) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        var title = ""
        if let t = lastLine(startingWith: "{\"type\":\"custom-title\"", in: data)?["customTitle"] as? String {
            title = t
        } else if let t = lastLine(startingWith: "{\"type\":\"ai-title\"", in: data)?["aiTitle"] as? String {
            title = t
        }

        var firstUser = "", cwd = "", entrypoint = "", started: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let scanLimit = data.startIndex + min(data.count, 4_000_000)
        forEachLine(data) { line in
            guard line.startIndex < scanLimit else { return false }
            guard let obj = jsonObject(line) else { return true }
            if cwd.isEmpty, let c = obj["cwd"] as? String, !c.isEmpty, c != "/" { cwd = c }
            if entrypoint.isEmpty, let e = obj["entrypoint"] as? String { entrypoint = e }
            if started == nil, let t = obj["timestamp"] as? String { started = iso.date(from: t) }
            if obj["type"] as? String == "user" {
                if let text = claudeDisplayText(obj) { firstUser = text }
                else if (obj["isSidechain"] as? Bool) != true, (obj["isMeta"] as? Bool) != true,
                        ((obj["origin"] as? [String: Any])?["kind"] as? String ?? "human") == "human",
                        !claudeImageSources(obj).isEmpty { firstUser = "图片对话" }
            }
            return firstUser.isEmpty
        }
        if firstUser.isEmpty && title.isEmpty { return nil }
        title = title.replacingOccurrences(of: #"</?pasted_content\b[^>]*>"#, with: "", options: .regularExpression)
        var item: [String: Any] = ["id": cid, "title": titleFrom(title.isEmpty ? firstUser : title, fallbackId: cid),
                                   "time": timeLabel(mtime), "timestamp": mtime.timeIntervalSince1970, "cwd": cwd]
        // 别的工具派出去的 `claude -p`（entrypoint 为 sdk-cli）归进「任务会话」。App 自己起的 Claude 从这个版本起写 aipethub；
        // 在那之前 App 的会话也是 sdk-cli、分不出来，所以只认分界时间之后开始的。
        if entrypoint == "sdk-py" || entrypoint == "sdk-ts" { item["task"] = true }
        if entrypoint == "sdk-cli", let t = started, t >= claudeTaskSince { item["task"] = true }
        // 子任务继承启动环境，所以新版入口还要核对首次握手时 CLI 报给 App 的会话编号。
        if entrypoint == "aipethub-session", !UserDefaults.standard.bool(forKey: "claudeDirectSession." + cid) { item["task"] = true }
        return item
    }

    /// 「App 的 Claude 会话写 entrypoint = aipethub」从哪一刻开始生效：新版第一次读历史时记下，之后不变。
    var claudeTaskSince: Date {
        if let d = hooks.claudeTaskSince { return d }
        let key = "claudeEntrypointSince"
        if let t = UserDefaults.standard.object(forKey: key) as? Double { return Date(timeIntervalSince1970: t) }
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: key)
        return Date(timeIntervalSince1970: now)
    }

    /// 所有 Claude 会话文件，最新的在前。
    func claudeSessionFiles(matching cid: String? = nil, onError: (String) -> Void = { _ in }) -> [(cid: String, path: String, mtime: Date)] {
        var files: [(cid: String, path: String, mtime: Date)] = []
        for root in claudeProjectRoots(onError: onError) {
            if let error = historyAccessError(root, mode: R_OK | X_OK) { onError(error) }
            for proj in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !proj.hasPrefix(".") {
                let dir = "\(root)/\(proj)"
                if isDirectory(dir), let error = historyAccessError(dir, mode: R_OK | X_OK) { onError(error) }
                let names = cid.map { [$0 + ".jsonl"] } ?? (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                for name in names where name.hasSuffix(".jsonl") {
                    let path = "\(dir)/\(name)"
                    if let m = modificationDate(path) { files.append((String(name.dropLast(6)), path, m)) }
                }
            }
        }
        return files.sorted { $0.mtime > $1.mtime }
    }

    /// 列表项（带缓存）：文件没变就不重新读。
    func claudeItem(_ f: (cid: String, path: String, mtime: Date)) -> [String: Any]? {
        let ts = f.mtime.timeIntervalSince1970
        if let cached = claudeCache[f.cid], cached.path == f.path, abs(cached.mtime - ts) < 0.001,
           cached.item?["task"] as? Bool != true || !UserDefaults.standard.bool(forKey: "claudeDirectSession." + f.cid) { return cached.item }
        let item = claudeSummary(path: f.path, cid: f.cid, mtime: f.mtime)
        if let item { claudeCache[f.cid] = (ts, item, f.path) }
        return item
    }

    func listClaude() {
        claudeQueue.async { [self] in
            var items: [[String: Any]] = []
            var seen = Set<String>()
            var reason: String?
            let files = claudeSessionFiles(onError:{ reason = $0 })
            if let reason { sendToJS("onConversationsListed",["agent":"claude","unavailable":reason]); return }
            for f in files where items.count < historyListLimit && !seen.contains(f.cid) {
                seen.insert(f.cid)
                if let item = claudeItem(f) { items.append(item) }
            }
            items += localFirstItems("claude", excluding:seen)
            items.sort { ($0["timestamp"] as? Double ?? 0) > ($1["timestamp"] as? Double ?? 0) }
            sendToJS("onConversationsListed", ["agent": "claude", "items": Array(items.prefix(historyListLimit))])
        }
    }

    /// 目录是 target 的全部会话（和列表一样，同一个会话 ID 只算最新的那份）。
    /// onTask 收到其中别的工具派出去的（侧栏的「任务会话」），删除项目时网页据此跳过。
    func claudeIds(inWorkspace target: String, onTask: (String) -> Void = { _ in }) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for f in claudeSessionFiles() where !seen.contains(f.cid) {
            seen.insert(f.cid)
            guard let item = claudeItem(f), let cwd = item["cwd"] as? String, trimmedPath(cwd) == target else { continue }
            ids.append(f.cid)
            if item["task"] as? Bool == true { onTask(f.cid) }
        }
        for item in localFirstItems("claude", excluding:seen) where trimmedPath(item["cwd"] as? String ?? "") == target {
            if let cid = item["id"] as? String { ids.append(cid) }
        }
        return ids
    }

    func loadClaude(cid: String, reqId: Int? = nil) {
        claudeQueue.async { [self] in
            let readAt = historyReadAt()
            var messages: [[String: Any]] = []
            var cwd = ""
            var context: [String: Any]?
            var readError: String?
            var terminal = false
            let sessionPath = findClaudeSession(cid: cid) { readError = $0 }
            if let path = sessionPath {
                readError = nil
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
                    (messages, cwd) = claudeTurns(data, cid: cid, endedTail:{ terminal = $0 }) { message, timestamp in
                        context = claudeHistoryContext(message, timestamp: timestamp)
                    }
                } catch { readError = error.localizedDescription }
            }
            if sessionPath == nil, readError == nil,
               let workspace = localEndings(agent:"claude", cid:cid).last?["newWorkspace"] as? String {
                messages = claudeTurns(Data(), cid:cid, endedTail:{ terminal = $0 }).0
                cwd = workspace
            }
            var payload: [String: Any] = [
                "agent": "claude", "conversationId": cid, "cwd": cwd, "missing": sessionPath == nil && readError == nil && messages.isEmpty, "readAt": readAt
            ]
            payload["historyError"] = readError
            if terminal || ["failed","interrupted"].contains(messages.last?["outcome"] as? String ?? "") {
                payload["lastTurn"] = ["running":false]
            }
            payload["context"] = context
            sendToJS("onConversationLoaded", recentHistory(messages, into: payload, reqId: reqId))
        }
    }

    /// 记录行自己的编号：行里最后一个 "uuid":"…"（它排在 message 后面；message 里引用的别的编号都在它前面）。
    func claudeLineUuid(_ line: Data) -> String? {
        guard let r = line.range(of: Data("\"uuid\":\"".utf8), options: .backwards), line.endIndex - r.upperBound >= 36 else { return nil }
        return String(data: line[r.upperBound..<r.upperBound + 36], encoding: .utf8)
    }

    /// 不在主线上的记录（编号）。会话记录是一棵树：每一行记着它接在哪一行后面。正常是一条线；
    /// 但同一个会话被两个进程同时接着写过（或者在 CLI 里回退重来过）就会分叉——从主线上岔出去、后面没人再接的那几段是旁支。
    /// 主线 = 文件里最后一条记录一路往上找到头的那条线（和 CLI 继续会话时认的一样）。旁支不显示，否则两条线的话会按时间混在一起。
    /// 和主线连不上的更早的段落（压缩上下文之前的）不算旁支，照常显示。
    func claudeSideBranch(_ data: Data) -> Set<String> {
        let head = Data("{\"parentUuid\":".utf8), side = Data("\"isSidechain\":true".utf8)
        var parent: [String: String] = [:]
        var order: [String] = []
        var answers = Set<String>()
        var leaf: String?
        let answerMark = Data("\"type\":\"assistant\"".utf8), uuidMark = Data("\"uuid\":\"".utf8)
        forEachLine(data) { line in
            guard line.starts(with: head), let id = claudeLineUuid(line) else { return true }
            // 是不是一条回答：新版本的记录里 "type" 紧挨在 "uuid" 前面（message 排在更前面），老的排在开头，两处都看
            if let r = line.range(of: uuidMark, options: .backwards),
               line[line.startIndex..<r.lowerBound].suffix(answerMark.count + 1).starts(with: answerMark) || line.prefix(400).range(of: answerMark) != nil {
                answers.insert(id)
            }
            let p = line[(line.startIndex + head.count)...]
            parent[id] = p.first == 0x22 && p.count > 37 ? (String(data: p[(p.startIndex + 1)..<(p.startIndex + 37)], encoding: .utf8) ?? "") : ""
            order.append(id)
            if line.prefix(160).range(of: side) == nil { leaf = id }
            return true
        }
        var main = Set<String>()
        var cur = leaf
        while let c = cur, !c.isEmpty, main.insert(c).inserted { cur = parent[c] }
        if main.count == order.count { return [] }
        // 每条不在主线上的记录，往上找它是从主线的哪里岔出去的：记下这一支的「根」（紧挨着主线的那一条）；连不上主线的记 ""
        var rootOf: [String: String] = [:]
        for id in order where !main.contains(id) {
            var path: [String] = []
            var c = id
            var root = ""
            while true {
                if let r = rootOf[c] { root = r; break }
                path.append(c)
                guard let p = parent[c], !p.isEmpty, path.count < 200_000 else { break }   // 找到头了也没碰到主线：更早的段落
                if main.contains(p) { root = c; break }                                     // c 接在主线上，自己却不在主线上
                guard parent[p] != nil else { break }
                c = p
            }
            path.forEach { rootOf[$0] = root }
        }
        // 只有里面有回答的那一支才算另一条线。一次并行调几个工具时，几条结果各自接在同一条回答后面，
        // 其中只有一条在主线上，别的看起来也像岔出去——它们是这一轮的工具输出，要留着。
        let withAnswer = Set(rootOf.compactMap { !$0.value.isEmpty && answers.contains($0.key) ? $0.value : nil })
        return Set(rootOf.filter { withAnswer.contains($0.value) }.keys)
    }

    /// 同期旁支单列在工作步骤中，保留终端的问答，也避免把它当成 CLI 下轮可见的上下文。
    func claudeBranchNotes(_ data: Data, ids: Set<String>) -> [(at: Date, text: String)] {
        guard !ids.isEmpty else { return [] }
        var notes: [(Date, String)] = []
        forEachLine(data) { line in
            if let id = claudeLineUuid(line), ids.contains(id), let obj = jsonObject(line),
               let ms = contextTime(obj["timestamp"] as? String), let text = claudeDisplayText(obj) {
                notes.append((Date(timeIntervalSince1970: ms / 1000), (obj["type"] as? String == "user" ? "用户：" : "Claude：") + text))
            }
            return true
        }
        return notes
    }

    func claudeBranchStep(_ text: [String]) -> [String: Any] {
        makeStep("tool", "同时有其他客户端续写，查看主线以外的记录", detail: text.joined(separator: "\n\n"))
    }

    /// 会话 jsonl → 一问一答的回合：用户消息 + （工作步骤、正式回答、改动的文件）。
    func claudeTurns(_ data: Data, cid: String = "", endedTail: ((Bool) -> Void)? = nil, lastUsage: (([String: Any], String?) -> Void)? = nil) -> ([[String: Any]], String) {
        var messages: [[String: Any]] = []
        var cwd = ""
        var turn: TurnBuilder?
        var pending: [String: PendingFile] = [:]
        var turnStart: Date?
        var lastTime: Date?
        var interrupted = false   // 这一轮是被用户停下的（记录里有中断标记）
        var confirmed = Set<Int>(), ended = false
        var prefaces: [Int:(index:Int, step:[String:Any])] = [:]
        var apiError: String?     // 这一轮以 API 报错收尾（记录里是一条 isApiErrorMessage 的回答）
        let endings = localEndings(agent: "claude", cid: cid)
        var questions: [(index: Int, at: Double)] = []
        var pendingAutoCompact = false   // 自动压缩落在两轮之间：记到下一轮的工作过程里
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let userMark = Data("\"type\":\"user\"".utf8)
        let botMark = Data("\"type\":\"assistant\"".utf8)
        let queuedMark = Data("\"queued_command\"".utf8)   // 回答进行中补充的话：记录里是一条附件，不是普通的用户消息
        let compactMark = Data("\"compact_boundary\"".utf8)   // 压缩：手动的是一条提示，自动的是那一轮里的一步（和实时一样）
        func compactStep(_ t: TurnBuilder) { t.add(makeStep("tool", "压缩上下文", status: "ok")); pendingAutoCompact = false }

        let sideBranch = claudeSideBranch(data)
        let branchNotes = claudeBranchNotes(data, ids: sideBranch)
        func flush() {
            guard let t = turn else { return }
            if !branchNotes.isEmpty, let start = turnStart, let end = lastTime {
                let concurrent = branchNotes.filter { $0.at >= start && $0.at <= end }.map(\.text)
                if !concurrent.isEmpty { t.add(claudeBranchStep(concurrent)) }
            }
            if !endings.isEmpty, let i = t.steps.lastIndex(where: { $0["kind"] as? String == "text" }),
               t.steps.dropFirst(i + 1).contains(where: { !["text","think"].contains($0["kind"] as? String ?? "") }) {
                prefaces[messages.count] = (i, t.steps[i])
            }
            let unfinished = t.steps.contains { $0["status"] as? String == "running" }
            let outcome = apiError != nil ? "failed" : interrupted ? "interrupted" : (unfinished ? "incomplete" : "completed")
            var bot = t.finish(finalText: nil, outcome: outcome, error: apiError)
            if ended { confirmed.insert(messages.count) }
            ended = false; interrupted = false; apiError = nil
            if let s = turnStart, let e = lastTime, e > s { bot["duration"] = e.timeIntervalSince(s) }
            if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
                bot["role"] = "bot"
                messages.append(bot)
            }
            turn = nil
            pending = [:]
        }

        var lastAnswer: [String: Any]?
        forEachLine(data) { line in
            if !sideBranch.isEmpty, let id = claudeLineUuid(line), sideBranch.contains(id) { return true }
            // 回答进行中补充的话：算在这一轮里，显示成工作过程里的「你补充说」（和当时看到的一样）
            if line.range(of: queuedMark) != nil, let obj = jsonObject(line), obj["type"] as? String == "attachment",
               let att = obj["attachment"] as? [String: Any], att["type"] as? String == "queued_command", (obj["isSidechain"] as? Bool) != true {
                let said = ((att["prompt"] as? String) ?? (att["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n"))
                    .replacingOccurrences(of: #"</?pasted_content\b[^>]*>"#, with: "", options: .regularExpression)
                // 同样的附件也用来送后台任务完成之类的系统通知：那不是用户说的话，不显示
                let origin = (att["origin"] as? [String: Any])?["kind"] as? String
                let fromUser = origin.map { $0 == "human" } ?? !trimmed(said).hasPrefix("<")
                let images = claudeImageSources(obj)
                if let t = turn, fromUser, !trimmed(said).isEmpty || !images.isEmpty {
                    var step = makeStep("user", "你补充说", detail: trimmed(said))
                    if !images.isEmpty { step["imageSources"] = images }
                    t.add(step)
                }
                return true
            }
            if line.range(of: compactMark) != nil, let obj = jsonObject(line), obj["subtype"] as? String == "compact_boundary",
               (obj["isSidechain"] as? Bool) != true {
                if (obj["compactMetadata"] as? [String: Any])?["trigger"] as? String == "auto" {
                    if let t = turn { compactStep(t) } else { pendingAutoCompact = true }
                } else {
                    flush()
                    messages.append(["role": "compact", "text": claudeCompactDoneNote])
                }
                return true
            }
            let isUser = line.range(of: userMark) != nil
            guard isUser || line.range(of: botMark) != nil, let obj = jsonObject(line),
                  let type = obj["type"] as? String, (obj["isSidechain"] as? Bool) != true else { return true }
            if cwd.isEmpty, let c = obj["cwd"] as? String, !c.isEmpty, c != "/" { cwd = c }
            let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if type == "user" {
                // 中断标记：不是一句提问，不开新的一轮；记在手头这一轮上，收尾时显示「已中断」
                if claudeInterruptMarker(textBlocks((obj["message"] as? [String: Any])?["content"])) {
                    if turn == nil { turn = TurnBuilder(); turnStart = ts }
                    interrupted = true
                    if let ts = ts { lastTime = ts }
                    return true
                }
                let images = claudeImageSources(obj)
                if let text = claudeDisplayText(obj) ?? (images.isEmpty ? nil : "") {   // 只发了图片也算一句
                    flush()
                    if !endings.isEmpty { questions.append((messages.count, ts?.timeIntervalSince1970 ?? 0)) }
                    messages.append(images.isEmpty ? ["role": "user", "text": text] : ["role": "user", "text": text, "imageSources": images])
                    messages[messages.count - 1]["turnKey"] = obj["uuid"]
                    messages[messages.count - 1]["createdAt"] = ts?.timeIntervalSince1970
                    turn = TurnBuilder()
                    turnStart = ts
                    lastTime = ts
                    if pendingAutoCompact, let t = turn { compactStep(t) }
                } else if let t = turn {
                    let results = blocks.filter { $0["type"] as? String == "tool_result" }
                    results.forEach { claudeToolResult($0, turn: t, pending: &pending) }
                    // 只有工具结果算这一轮的进展；/compact 命令行、压缩摘要、命令输出这些不能延长它的工作时长
                    if !results.isEmpty, let ts = ts { lastTime = ts }
                }
            } else if type == "assistant", (obj["isApiErrorMessage"] as? Bool) == true {
                // API 报错：实时会显示错误和「重试」，重开也要还原成出错的一轮（以前整条跳过，只剩提问）
                if turn == nil { turn = TurnBuilder(); turnStart = ts }
                let said = trimmed(textBlocks((obj["message"] as? [String: Any])?["content"]))
                apiError = said.isEmpty ? "这一轮出错了。" : said
                if let ts = ts { lastTime = ts }
            } else if type == "assistant" {
                // CLI 续问时为中断轮补写的空答复不能盖过已显示的正文。
                if isClaudePlaceholder(obj["message"] as? [String:Any]) { return true }
                let stop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                if stop == "end_turn" || stop == "stop_sequence" { ended = true }
                if stop == "max_tokens" { apiError = outputLimitHint }
                if turn == nil, pendingAutoCompact { turn = TurnBuilder(); turnStart = ts; if let t = turn { compactStep(t) } }
                if lastUsage != nil, let message = obj["message"] as? [String: Any], message["usage"] is [String: Any],
                   message["model"] as? String != "<synthetic>" { lastAnswer = obj }
                if turn == nil { turn = TurnBuilder(); turnStart = ts }
                if let t = turn { blocks.forEach { claudeBlock($0, turn: t, pending: &pending) } }
                if let ts = ts { lastTime = ts }
            }
            return true
        }
        flush()
        var terminal = confirmed.contains(messages.count - 1)
        // 从后往前插入，后轮不会改变前轮的位置；CLI 后来写全了同一问，就直接使用记录。
        let recordEnd = messages.count
        for ending in endings.reversed() {
            guard let start = ending["start"] as? Double, let end = ending["end"] as? Double,
                  let prompt = ending["prompt"] as? String else { continue }
            let next = questions.first { $0.at >= start - 0.001 }
            let at = next?.index ?? recordEnd
            if let next, next.at <= end + 0.001 { restorePathAttachments(&messages[at], textKey:"text", ending:ending) }
            let matched = next.map { $0.at <= end + 0.001 && messages[$0.index]["text"] as? String == prompt } ?? false
            let savedText = ending["text"] as? String ?? ""
            let savedOutcome = ending["outcome"] as? String ?? "failed"
            var bot = TurnBuilder().finish(finalText: savedText, outcome: savedOutcome, error: ending["reason"] as? String)
            bot["role"] = "bot"
            bot["endingReqId"] = ending["reqId"]
            // 失败、停止前的等待没写进记录：工作时长从提问算到本机记下的结束时刻，和实时一样
            func stretch(_ i: Int) {
                guard let asked = next?.at, end > asked else { return }
                messages[i]["duration"] = max(messages[i]["duration"] as? Double ?? 0, end - asked)
            }
            if matched {
                if messages.indices.contains(at + 1), messages[at + 1]["role"] as? String == "bot" {
                    let disk = messages[at + 1], outcome = disk["outcome"] as? String
                    let text = trimmed(disk["text"] as? String)
                    // 只有工具回执时“完成”只是推测。已明确结束或后来补齐的正文仍以 CLI 记录为准。
                    if outcome == savedOutcome {
                        messages[at + 1]["text"] = restoredEndingText(recorded:text, saved:savedText)
                        messages[at + 1]["endingReqId"] = ending["reqId"]
                        stretch(at + 1)
                    }
                    if outcome == "incomplete" || (outcome == "completed" && !confirmed.contains(at + 1) && (text.isEmpty || savedText.hasPrefix(text) || prefaces[at + 1] != nil)) {
                        var steps = disk["steps"] as? [[String: Any]] ?? []
                        if outcome == "incomplete", steps.last?["title"] as? String == "未完成" { steps.removeLast() }
                        // 回执没落盘的步骤和实时一样按整轮结局收尾；已有回执的保留原状态。
                        for j in steps.indices where steps[j]["status"] as? String == "running" {
                            if savedOutcome == "interrupted" { steps[j]["status"] = "interrupted" }
                            else if savedOutcome == "failed" { steps[j]["status"] = "error" }
                        }
                        if let preface = prefaces[at + 1], !savedText.isEmpty, savedText != text {
                            steps.insert(preface.step, at:min(preface.index, steps.count))
                        }
                        messages[at + 1]["steps"] = steps + (bot["steps"] as? [[String: Any]] ?? [])
                        if at + 1 == messages.count - 1 { terminal = true }
                        messages[at + 1]["outcome"] = savedOutcome
                        messages[at + 1]["text"] = restoredEndingText(recorded:text, saved:savedText)
                        messages[at + 1]["endingReqId"] = ending["reqId"]
                        stretch(at + 1)
                    }
                } else {
                    if at + 1 == messages.count { terminal = true }
                    messages.insert(bot, at: at + 1)
                    stretch(at + 1)
                }
            } else {
                if at == messages.count { terminal = true }
                let images = (ending["images"] as? [String] ?? []).map { ["path": $0] }
                if end > start { bot["duration"] = end - start }
                messages.insert(contentsOf: [["role":"user", "text":prompt, "imageSources":images], bot], at: at)
            }
        }
        endedTail?(terminal)
        if let row = lastAnswer, let message = row["message"] as? [String: Any] { lastUsage?(message, row["timestamp"] as? String) }
        return (messages, cwd)
    }
}
