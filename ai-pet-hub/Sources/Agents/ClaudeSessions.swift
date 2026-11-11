// Claude 的同一个会话可能正开在别的程序里（Claude 桌面端、终端里的 claude）。
// 那个进程把对话放在内存里，不会回头读记录文件；这边要是照常「继续这个会话」，就成了同一个编号、同一份记录文件上的两个副本，
// 各干各的、互相看不到，记录也搅在一起。所以：会话在别处活着时，这边发的话改成「分叉」——带着到这一刻为止的历史新开一个会话
// （claude --resume <id> --fork-session），有自己的编号和记录文件；原来那个留给那边接着用。
import Cocoa

extension AppDelegate {
    /// 这个会话是不是正在别的程序里开着。是：返回那边的状态（busy / idle）和它的名字；不是（或者查不出来）：nil。
    /// 用的是 CLI 自己的清单（claude agents --json）；我们自己起的进程（提问、预热）也在清单里，按父进程排除掉。结果记 4 秒。
    func claudeLiveElsewhere(_ cid: String) -> (status: String, name: String)? {
        guard !cid.isEmpty, let cmd = claudeCommand() else { return nil }
        procLock.lock()
        let cached = claudeLiveCache
        procLock.unlock()
        var sessions = cached?.sessions ?? []
        if cached == nil || Date().timeIntervalSince(cached!.at) > 4 {
            let res = runOnce(cmd.executable, cmd.prefix + ["agents", "--json"], cwd: home, timeout: 8)
            guard let start = res.out.firstIndex(of: "["), let data = String(res.out[start...]).data(using: .utf8),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            let mine = ownDescendants()
            sessions = list.compactMap { s in
                guard let sid = s["sessionId"] as? String, let pid = (s["pid"] as? NSNumber)?.int32Value, !mine.contains(pid) else { return nil }
                return (sid, s["status"] as? String ?? "", s["name"] as? String ?? "")
            }
            procLock.lock()
            claudeLiveCache = (Date(), sessions)
            procLock.unlock()
        }
        return sessions.first { $0.sid == cid }.map { ($0.status, $0.name) }
    }

    /// 这个 App 起的所有进程（子进程、孙进程……）的进程号。
    private func ownDescendants() -> Set<Int32> {
        let res = runOnce("/bin/ps", ["-axo", "pid=,ppid="], cwd: home, timeout: 5)
        var children: [Int32: [Int32]] = [:]
        for line in res.out.split(separator: "\n") {
            let cols = line.split(separator: " ").compactMap { Int32($0) }
            if cols.count == 2 { children[cols[1], default: []].append(cols[0]) }
        }
        var out: Set<Int32> = [], queue = [ProcessInfo.processInfo.processIdentifier]
        while let p = queue.popLast() {
            for c in children[p] ?? [] where out.insert(c).inserted { queue.append(c) }
        }
        return out
    }

    /// 网页问：打开着的这个会话是不是在别处开着（输入框上面要不要提示「在这里发会另开一个分支」）。
    func checkSessionLive(agent: String, cid: String) {
        guard agent == "claude", !cid.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let live = self.claudeLiveElsewhere(cid)
            DispatchQueue.main.async {
                self.sendToJS("onSessionLive", ["agent": agent, "conversationId": cid, "live": live != nil,
                                                "status": live?.status ?? "", "name": live?.name ?? ""])
            }
        }
    }
}
