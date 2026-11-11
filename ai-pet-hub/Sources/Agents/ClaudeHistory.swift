// Claude Code 的历史会话：直接读它的 JSONL 记录。
import Cocoa

extension AppDelegate {
    func claudeProjectRoots() -> [String] {
        // 没装 reclaude、用标准 claude 时：读它的配置目录（CLAUDE_CONFIG_DIR，默认 ~/.claude）
        if let cmd = claudeCommand(), !cmd.reclaude {
            let env = trimmed(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])
            let p = (env.isEmpty ? "\(home)/.claude" : (env as NSString).expandingTildeInPath) + "/projects"
            return isDirectory(p) ? [p] : []
        }
        var roots: [String] = []
        let accounts = "\(home)/.rec/claude/accounts"
        for acc in ((try? fm.contentsOfDirectory(atPath: accounts)) ?? []).sorted() where !acc.hasPrefix(".") {
            let p = "\(accounts)/\(acc)/config/projects"
            if isDirectory(p) { roots.append(p) }
        }
        // 装了 reclaude 时克劳蒂娜只用 reclaude：历史会话只读 ~/.rec/claude/accounts/*/config/projects，不再看 ~/.claude-pro、~/.claude
        return roots
    }

    func findClaudeSession(cid: String) -> String? {
        if let cached = claudeCache[cid], fm.fileExists(atPath: cached.path) { return cached.path }
        for root in claudeProjectRoots() {
            for proj in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let candidate = "\(root)/\(proj)/\(cid).jsonl"
                if fm.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    /// 一行会话记录对应的可展示文字；工具调用、子代理、元信息等返回 nil。
    func claudeDisplayText(_ obj: [String: Any]) -> String? {
        for flag in ["isSidechain", "isMeta", "isApiErrorMessage", "isCompactSummary"] where (obj[flag] as? Bool) == true {
            return nil
        }
        // 只有 origin.kind == "human" 才是用户亲手输入；后台任务通知等由 Claude Code 插入的记录也标成 user，要排除
        if obj["type"] as? String == "user", let kind = (obj["origin"] as? [String: Any])?["kind"] as? String, kind != "human" {
            return nil
        }
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        let text = stripTagBlocks(textBlocks(msg["content"]), tags: ["system-reminder"])
        if text.isEmpty { return nil }
        for prefix in ["<local-command", "<command-name>", "<command-message>", "<bash-input>", "<bash-stdout>",
                       "<bash-stderr>", "<task-notification>", "Caveat: The messages below"] where text.hasPrefix(prefix) {
            return nil
        }
        return text
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
                return jsonObject(data[r.lowerBound..<end])
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

        var firstUser = "", cwd = ""
        let scanLimit = data.startIndex + min(data.count, 4_000_000)
        forEachLine(data) { line in
            guard line.startIndex < scanLimit else { return false }
            guard let obj = jsonObject(line) else { return true }
            if cwd.isEmpty, let c = obj["cwd"] as? String, !c.isEmpty, c != "/" { cwd = c }
            if obj["type"] as? String == "user", let text = claudeDisplayText(obj) { firstUser = text }
            return firstUser.isEmpty
        }
        if firstUser.isEmpty && title.isEmpty { return nil }
        return ["id": cid, "title": titleFrom(title.isEmpty ? firstUser : title, fallbackId: cid),
                "time": timeLabel(mtime), "timestamp": mtime.timeIntervalSince1970, "cwd": cwd]
    }

    /// 所有 Claude 会话文件，最新的在前。
    func claudeSessionFiles() -> [(cid: String, path: String, mtime: Date)] {
        var files: [(cid: String, path: String, mtime: Date)] = []
        for root in claudeProjectRoots() {
            for proj in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !proj.hasPrefix(".") {
                let dir = "\(root)/\(proj)"
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
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
        if let cached = claudeCache[f.cid], cached.path == f.path, abs(cached.mtime - ts) < 0.001 { return cached.item }
        let item = claudeSummary(path: f.path, cid: f.cid, mtime: f.mtime)
        claudeCache[f.cid] = (ts, item, f.path)
        return item
    }

    func listClaude() {
        claudeQueue.async { [self] in
            var items: [[String: Any]] = []
            var seen = Set<String>()
            for f in claudeSessionFiles() where items.count < historyListLimit && !seen.contains(f.cid) {
                seen.insert(f.cid)
                if let item = claudeItem(f) { items.append(item) }
            }
            sendToJS("onConversationsListed", ["agent": "claude", "items": items])
        }
    }

    /// 目录是 target 的全部会话（和列表一样，同一个会话 ID 只算最新的那份）。
    func claudeIds(inWorkspace target: String) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for f in claudeSessionFiles() where !seen.contains(f.cid) {
            seen.insert(f.cid)
            if let cwd = claudeItem(f)?["cwd"] as? String, trimmedPath(cwd) == target { ids.append(f.cid) }
        }
        return ids
    }

    func loadClaude(cid: String) {
        claudeQueue.async { [self] in
            var messages: [[String: Any]] = []
            var cwd = ""
            let sessionPath = findClaudeSession(cid: cid)
            if let path = sessionPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
                (messages, cwd) = claudeTurns(data)
            }
            sendToJS("onConversationLoaded", recentHistory(messages, into: [
                "agent": "claude", "conversationId": cid, "cwd": cwd, "missing": sessionPath == nil
            ]))
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

    /// 会话 jsonl → 一问一答的回合：用户消息 + （工作步骤、正式回答、改动的文件）。
    func claudeTurns(_ data: Data) -> ([[String: Any]], String) {
        var messages: [[String: Any]] = []
        var cwd = ""
        var turn: TurnBuilder?
        var pending: [String: PendingFile] = [:]
        var turnStart: Date?
        var lastTime: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let userMark = Data("\"type\":\"user\"".utf8)
        let botMark = Data("\"type\":\"assistant\"".utf8)
        let queuedMark = Data("\"queued_command\"".utf8)   // 回答进行中补充的话：记录里是一条附件，不是普通的用户消息

        func flush() {
            guard let t = turn else { return }
            var bot = t.finish(finalText: nil)
            if let s = turnStart, let e = lastTime, e > s { bot["duration"] = e.timeIntervalSince(s) }
            if !trimmed(bot["text"] as? String).isEmpty || !((bot["steps"] as? [Any]) ?? []).isEmpty {
                bot["role"] = "bot"
                messages.append(bot)
            }
            turn = nil
            pending = [:]
        }

        let sideBranch = claudeSideBranch(data)   // 分叉出去的旁支不显示
        forEachLine(data) { line in
            if !sideBranch.isEmpty, let id = claudeLineUuid(line), sideBranch.contains(id) { return true }
            // 回答进行中补充的话：算在这一轮里，显示成工作过程里的「你补充说」（和当时看到的一样）
            if line.range(of: queuedMark) != nil, let obj = jsonObject(line), obj["type"] as? String == "attachment",
               let att = obj["attachment"] as? [String: Any], att["type"] as? String == "queued_command", (obj["isSidechain"] as? Bool) != true {
                let said = (att["prompt"] as? String) ?? (att["prompt"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                if let t = turn, !trimmed(said).isEmpty { t.add(makeStep("user", "你补充说", detail: trimmed(said))) }
                return true
            }
            let isUser = line.range(of: userMark) != nil
            guard isUser || line.range(of: botMark) != nil, let obj = jsonObject(line),
                  let type = obj["type"] as? String, (obj["isSidechain"] as? Bool) != true else { return true }
            if cwd.isEmpty, let c = obj["cwd"] as? String, !c.isEmpty, c != "/" { cwd = c }
            let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if type == "user" {
                let images = claudeImageSources(obj)
                if let text = claudeDisplayText(obj) ?? (images.isEmpty ? nil : "") {   // 只发了图片也算一句
                    flush()
                    messages.append(images.isEmpty ? ["role": "user", "text": text] : ["role": "user", "text": text, "imageSources": images])
                    turn = TurnBuilder()
                    turnStart = ts
                    lastTime = ts
                } else if let t = turn {
                    blocks.filter { $0["type"] as? String == "tool_result" }.forEach { claudeToolResult($0, turn: t, pending: &pending) }
                    if let ts = ts { lastTime = ts }
                }
            } else if type == "assistant", (obj["isApiErrorMessage"] as? Bool) != true {
                if turn == nil { turn = TurnBuilder(); turnStart = ts }
                if let t = turn { blocks.forEach { claudeBlock($0, turn: t, pending: &pending) } }
                if let ts = ts { lastTime = ts }
            }
            return true
        }
        flush()
        return (messages, cwd)
    }
}
