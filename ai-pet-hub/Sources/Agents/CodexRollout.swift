// 同一份 rollout 可能经历 CLI 升级；只合并同轮的镜像消息，不能按整份文件择一格式。
//
// 普通 Codex rollout 的新旧事件按出现顺序共用回合归组，同轮的两种镜像记录只显示一次；
//
// 带 error 的 `task_complete` 是当前 CLI 的失败记录，按失败显示。
import Foundation

struct CodexRolloutEvent {
    var payload: [String: Any]
    let timestamp: Double?
    let scope: Int
    let message: String?
    let modern: Bool
    let ordinal: Int64
    var latestSourceOrdinal: Int64
}

extension AppDelegate {
    /// 当前 CLI 生成失败时只写带 error 的 task_complete，不再写 turn_failed；纯 rollout 和投影补尾共用这一判据，结局才一致。
    func codexRolloutEnding(_ type: String, _ payload: [String: Any]) -> String {
        if type == "turn_aborted" { return "interrupted" }
        return type == "turn_failed" || payload["error"] is [String: Any] ? "failed" : "completed"
    }

    /// 压缩记录可能有数百 MB。侧栏只要身份、目录和标题，读到首问或确认是子线程就结束解压。
    func compressedRolloutSummary(path: String, mtime: Date) -> [String: Any]? {
        guard let zstd = hooks.cliExecutable ?? findExecutable(["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]) else { return nil }
        let cli = CLIProcess(input: nil, outputLimit: 4096)
        var cid = "", cwd = "", exec = false, ended = false, summary: [String: Any]?
        cli.warmFilter = { [weak cli] line in
            guard !ended, let row = self.jsonObject(line), let p = row["payload"] as? [String: Any] else { return true }
            if row["type"] as? String == "session_meta" {
                cid = (p["id"] ?? p["session_id"]) as? String ?? ""
                cwd = p["cwd"] as? String ?? ""
                exec = p["source"] as? String == "exec"
                ended = !self.isSafeId(cid) || !(p["source"] is String)
            } else if !cid.isEmpty, row["type"] as? String == "event_msg" {
                let text: String
                if p["type"] as? String == "user_message" { text = self.stripPersonaPrefix(p["message"] as? String ?? "") }
                else if p["type"] as? String == "item_completed", let item = p["item"] as? [String: Any], item["type"] as? String == "UserMessage" {
                    text = self.stripPersonaPrefix(self.textBlocks(item["content"]))
                } else { return true }
                if !text.isEmpty {
                    summary = ["id": cid, "cwd": cwd, "title": self.titleFrom(text, fallbackId: cid),
                               "time": self.timeLabel(mtime), "timestamp": mtime.timeIntervalSince1970]
                    if exec { summary?["task"] = true }
                    ended = true
                }
            }
            if ended, let proc = cli?.proc, proc.isRunning { proc.terminate() }
            return true
        }
        guard (try? cli.start(executable: zstd, arguments: ["-dc", path], cwd: home, environment: cliEnvironment())) != nil else { return nil }
        _ = cli.waitForExit(until: .now() + (hooks.toolTimeout ?? 30)) { terminateTree(cli.proc.processIdentifier) }
        return summary
    }

    func rolloutEvents(_ content: String) -> (events: [CodexRolloutEvent], meta: [String: Any]) {
        var events: [CodexRolloutEvent] = [], meta: [String: Any] = [:]
        var scope = 0, activeId = "", taskScoped = false, ended = false, sawAnswer = false
        var lastUser: (text: String, modern: Bool)?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func boundary() { scope += 1; activeId = ""; taskScoped = false; ended = false; sawAnswer = false; lastUser = nil }
        // JSONL 的分隔符是单字节 LF；按字符遍历会把大段图片数据也做一遍 Unicode 分段。
        for (ordinal, line) in content.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            guard let obj = jsonObject(Data(line)), let payload = obj["payload"] as? [String: Any] else { continue }
            if obj["type"] as? String == "session_meta" { if meta.isEmpty { meta = payload }; continue }
            guard obj["type"] as? String == "event_msg", let type = payload["type"] as? String else { continue }
            let id = payload["turn_id"] as? String ?? ""
            let item = payload["item"] as? [String: Any] ?? [:]
            let itemType = item["type"] as? String ?? ""
            let modern = type == "item_completed"
            let isUser = type == "user_message" || (modern && itemType == "UserMessage")
            let isBot = type == "agent_message" || (modern && itemType == "AgentMessage")
            var message: String?
            if isUser || isBot {
                var text = modern ? textBlocks(item["content"]) : trimmed(payload["message"] as? String)
                if isUser { text = stripPersonaPrefix(text) }
                if modern && isUser { text = stripCodexAttachmentHeader(text, images: codexImageSources(item["content"])) }
                message = (isUser ? "user:" : "bot:") + text
            }
            if type == "task_started" { boundary(); activeId = id; taskScoped = true }
            else if !id.isEmpty && id != activeId {
                // 无身份的旧提问紧邻新条目时可配对；已经出现回答则是前一轮，不能吞掉重复提问。
                if !activeId.isEmpty || sawAnswer { boundary() }
                activeId = id
            }
            if isUser {
                if ended || (id.isEmpty && sawAnswer && !taskScoped) { boundary(); activeId = id }
                if activeId.isEmpty, let last = lastUser,
                   last.modern == modern || last.text != message || sawAnswer { boundary() }
                lastUser = (message ?? "", modern)
            }
            if isBot { sawAnswer = true }
            let ts = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }?.timeIntervalSince1970
            events.append(CodexRolloutEvent(payload: payload, timestamp: ts, scope: scope, message: message, modern: modern, ordinal: Int64(ordinal), latestSourceOrdinal: Int64(ordinal)))
            if ["task_complete", "turn_aborted", "turn_failed"].contains(type) { ended = true }
        }
        var old: [String: [Int]] = [:], new: [String: [Int]] = [:]
        for (index, event) in events.enumerated() {
            guard let message = event.message else { continue }
            let key = "\(event.scope):\(message)"
            if event.modern { new[key, default: []].append(index) }
            else { old[key, default: []].append(index) }
        }
        var skipped = Set<Int>()
        for (key, legacy) in old {
            for (a, b) in zip(legacy, new[key] ?? []) {
                // 保留新条目的图片和结构，但放在两份镜像中较早的位置，夹在中间的工具才不会跑到提问前面。
                if a < b { events[a].payload = events[b].payload }
                events[min(a, b)].latestSourceOrdinal = max(events[a].ordinal, events[b].ordinal)
                skipped.insert(max(a, b))
            }
        }
        return (events.enumerated().compactMap { skipped.contains($0.offset) ? nil : $0.element }, meta)
    }

    func rolloutMessages(_ content: String) -> (messages: [[String: String]], meta: [String: Any]) {
        let parsed = rolloutEvents(content)
        let messages: [[String: String]] = parsed.events.compactMap { event in
            let payload = event.payload, type = payload["type"] as? String ?? ""
            if type == "item_completed", let item = payload["item"] as? [String: Any],
               let kind = item["type"] as? String, ["UserMessage", "AgentMessage"].contains(kind) {
                let text = kind == "UserMessage" ? stripPersonaPrefix(textBlocks(item["content"])) : textBlocks(item["content"])
                return text.isEmpty ? nil : ["role": kind == "UserMessage" ? "user" : "bot", "text": text]
            }
            guard ["user_message", "agent_message"].contains(type), let text = payload["message"] as? String, !trimmed(text).isEmpty else { return nil }
            return ["role": type == "user_message" ? "user" : "bot", "text": trimmed(text)]
        }
        return (messages, parsed.meta)
    }

    func codexRolloutTurns(_ content: String) -> (messages: [[String: Any]], cwd: String, lastTurn: HistoryTurnActivity?) {
        let parsed = rolloutEvents(content)
        var activity: HistoryTurnActivity?, scope: Int?
        var outcome: String?, error: String?, completed = false
        let g = CodexTurnGrouper(app: self, cid:parsed.meta["id"] as? String ?? parsed.meta["session_id"] as? String ?? "", ticksPerSecond: 1) { _, turn, final in
            defer { outcome = nil; error = nil; completed = false }
            return (outcome ?? (final.isEmpty && !turn.isEmpty ? "incomplete" : "completed"), error, completed)
        }
        for event in parsed.events {
            let payload = event.payload, type = payload["type"] as? String ?? ""
            if event.scope != scope { activity = nil; scope = event.scope }
            // 旧版只在 task_started 写编号；同一回合内的正文也需要这个编号来认领本机结局。
            let id = payload["turn_id"] as? String ?? activity?.turnId ?? "", ts = event.timestamp
            if type == "task_started" {
                g.flush()
                activity = HistoryTurnActivity(running: true, startedAt: ts ?? 0, updatedAt: ts ?? 0, turnId: id)
            } else if let ts = ts { activity?.updatedAt = ts }
            if ["task_complete", "turn_aborted", "turn_failed"].contains(type) {
                activity = HistoryTurnActivity(running: false, startedAt: activity?.startedAt ?? 0, updatedAt: ts ?? 0, turnId: id)
                g.enter(id); g.begin(id, at: ts); g.closeToSteers(); g.touch(ts)
                outcome = codexRolloutEnding(type, payload)
                completed = outcome == "completed"
                error = ((payload["error"] as? [String: Any])?["message"] as? String).map(codexReadableError)
            } else if type == "item_completed", let item = payload["item"] as? [String: Any], let kind = item["type"] as? String {
                g.enter(id)
                let started = (payload["started_at_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? ts
                if kind == "UserMessage" { g.userMessage(item["content"], turnId: id, at: started, completed: ts) }
                else { g.item(type: kind, obj: item, turnId: id, at: started, completed: ts, afterAbort: outcome == "interrupted") }
            } else if type == "user_message", let text = payload["message"] as? String {
                g.user(text: trimmed(text), turnId: id, at: ts)
            } else if type == "agent_message", let text = payload["message"] as? String {
                g.enter(id); g.begin(id, at: ts); g.touch(ts)
                g.turn?.add(makeStep("text", "说明", detail: trimmed(text)))
                g.stampSteps(ts)
                outcome = "completed"
            }
        }
        if activity?.running == true {
            // 唯一事件可能只是 task_started，也要给新回合自己的标题，避免把上一轮标成运行中。
            g.begin(activity?.turnId ?? "", at: activity?.startedAt)
            outcome = "incomplete"
        }
        g.flush()
        return (g.out, parsed.meta["cwd"] as? String ?? "", activity)
    }
}
