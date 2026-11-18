// 正文搜索先粗筛来源，再用打开历史的解析器和网页 Markdown 渲染确认；不建立磁盘索引。
import Cocoa
import SQLite3

extension AppDelegate {
    func searchConversations(agent: String, query: String, files: [(cid: String, path: String)]? = nil) {
        let q = trimmed(query)
        let request = ConversationSearchRequests.shared.begin(self, agent: agent)
        guard q.count >= 2 else {
            sendToJS("onConversationsSearched", ["agent": agent, "query": query, "ids": [String](), "complete": true]); return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let renderer = ConversationSearchText(app: self)
            var ids: [String] = [], items: [[String: Any]] = [], problems: [String] = []
            var sent = Date(), scanned = 0
            func current() -> Bool { ConversationSearchRequests.shared.current(self, agent: agent, request: request) }
            func publish(_ complete: Bool) {
                guard current() else { return }
                var payload: [String: Any] = ["agent": agent, "query": query, "ids": ids, "items": items, "complete": complete, "scanned": scanned]
                if !problems.isEmpty { payload["unavailable"] = Array(Set(problems)).sorted().joined(separator: "；") }
                sendToJS("onConversationsSearched", payload)
                sent = Date()
            }
            guard renderer.available else { problems.append("这一位没搜：正文渲染器读取失败"); publish(true); return }
            let found = searchSources(agent: agent, files: files)
            if let error = found.error { problems.append("这一位没搜：" + error) }
            let cache = hooks.conversationSearchCache ?? ConversationSearchCache.shared
            for source in found.sources {
                guard current() else { return }
                scanned += 1
                let key = agent + ":" + source.cid + ":" + source.paths.joined(separator: "|")
                let stamp = searchStamp(source)
                let shared = searchSharedDatabases(source)
                let individualStamp = shared.isEmpty ? nil : searchStamp(source, excluding: shared)
                var cachedValue = cache.get(key, stamp: stamp)
                if cachedValue == nil, let individual = individualStamp,
                   let previous = cache.revalidationCandidate(key, individualStamp: individual),
                   let revision = searchDatabaseRevision(source), revision == previous.databaseRevision,
                   stamp == searchStamp(source) {
                    // 只有共享库变化、本会话原始内容没变：保留渲染结果，更新文件指纹。
                    cache.put(key, stamp: stamp, texts: previous.texts, item: previous.item, dependencies: previous.dependencies,
                              individualStamp: individual, databaseRevision: revision)
                    cachedValue = previous
                }
                var texts: [String], item: [String: Any]
                if let cached = cachedValue {
                    texts = cached.texts; item = cached.item
                } else {
                    let candidate = searchCandidate(source, query: q)
                    if let error = candidate.error { problems.append(error) }
                    guard candidate.possible else {
                        if Date().timeIntervalSince(sent) >= 0.3 { publish(false) }
                        continue
                    }
                    let databaseRevision = individualStamp == nil ? nil : searchDatabaseRevision(source)
                    hooks.conversationSearchLoaded?(agent, source.cid)
                    let loaded = searchHistory(source, agent: agent, explicit: files != nil)
                    if let error = loaded.error { problems.append(error) }
                    renderer.prepare(loaded.messages, cwd: loaded.cwd)
                    var visible = loaded.messages
                    attachChatImages(&visible, payload: ["agent": agent, "conversationId": source.cid, "cwd": loaded.cwd], labelsOnly: true)
                    texts = renderer.messages(visible)
                    item = source.item
                    if (item["title"] as? String ?? "").isEmpty {
                        let first = loaded.messages.first { $0["role"] as? String == "user" }?["text"] as? String ?? ""
                        item["title"] = titleFrom(first, fallbackId: source.cid)
                    }
                    if (item["cwd"] as? String ?? "").isEmpty { item["cwd"] = loaded.cwd }
                    // 解析期间本会话被追加则不能缓存；只有共享库的无关写入可用会话指纹复核。
                    let after = searchStamp(source)
                    var unchanged = stamp == after
                    if !unchanged, let individual = individualStamp, let revision = databaseRevision,
                       individual == searchStamp(source, excluding: shared),
                       revision == searchDatabaseRevision(source), after == searchStamp(source) { unchanged = true }
                    if loaded.error == nil, unchanged {
                        cache.put(key, stamp: after, texts: texts, item: item, dependencies: renderer.dependencies,
                                  individualStamp: individualStamp, databaseRevision: databaseRevision)
                    }
                }
                if let hit = texts.lastIndex(where: { $0.range(of: q, options: .caseInsensitive) != nil }) {
                    ids.append(source.cid)
                    item["searchLimit"] = max(300, texts.count - hit)
                    if let range = texts[hit].range(of: q, options: .caseInsensitive) {
                        item["searchMatch"] = String(texts[hit][range])
                    }
                    items.append(item)
                }
                if Date().timeIntervalSince(sent) >= 0.3 { publish(false) }
            }
            publish(true)
        }
    }
}

// MARK: - 输入框里 @ 文件：在工作空间里按名字找文件

extension AppDelegate {
    /// 工作空间里的文件（相对路径）。git 仓库用 git 列（自动跳过忽略的文件），否则自己走一遍目录。缓存 15 秒。
    private func workspaceFiles(_ ws: String) -> [String] {
        procLock.lock()
        fileListCache = fileListCache.filter { Date().timeIntervalSince($0.value.at) < 15 }
        if let c = fileListCache[ws] { procLock.unlock(); return c.files }
        procLock.unlock()
        var files: [String] = []
        if let listed = runGit(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: ws) {
            files = listed.split(separator: "\0").map(String.init)
        } else if let walker = fm.enumerator(atPath: ws) {
            let skip: Set<String> = ["node_modules", "build", "dist", ".git", "DerivedData", "__pycache__", ".venv", "venv"]
            while let rel = walker.nextObject() as? String, files.count < 8000 {
                let name = (rel as NSString).lastPathComponent
                if name.hasPrefix(".") || skip.contains(name) { walker.skipDescendants(); continue }
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular { files.append(rel) }
            }
        }
        if files.count > 20_000 { files = Array(files.prefix(20_000)) }
        procLock.lock()
        fileListCache = fileListCache.filter { Date().timeIntervalSince($0.value.at) < 15 }
        fileListCache[ws] = (Date(), files)
        while fileListCache.count > 8, let oldest = fileListCache.min(by: { $0.value.at < $1.value.at })?.key {
            fileListCache.removeValue(forKey: oldest)
        }
        procLock.unlock()
        return files
    }

    /// 名字开头对得上的排最前，其次名字里有，再次路径里有；同一档里路径短的在前。
    func listFiles(workspace: String, query: String, reqId: Int) {
        guard let ws = validWorkspace(workspace) else { sendToJS("onFilesListed", ["reqId": reqId, "files": [String]()]); return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let q = query.lowercased()
            var scored: [(Int, String)] = []
            for f in workspaceFiles(ws) {
                let lower = f.lowercased()
                let name = (lower as NSString).lastPathComponent
                let rank = q.isEmpty ? 2 : (name.hasPrefix(q) ? 0 : (name.contains(q) ? 1 : (lower.contains(q) ? 2 : -1)))
                if rank >= 0 { scored.append((rank * 10_000 + min(f.count, 9_999), f)) }
            }
            let top = scored.sorted { $0.0 < $1.0 }.prefix(12).map { $0.1 }
            sendToJS("onFilesListed", ["reqId": reqId, "files": top])
        }
    }
}
