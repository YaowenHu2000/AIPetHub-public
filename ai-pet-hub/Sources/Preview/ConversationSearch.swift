// 搜索会话正文：⌘F 除了标题和工作空间，也在三位的会话记录文件里找这段文字。
// 直接在文件的字节里找（Claude、Codex 是 JSONL，Gemini 是 SQLite，文字都是明文 UTF-8），不解析内容，几百个会话也只要零点几秒。
import Cocoa

extension AppDelegate {
    /// 每位的会话记录文件：会话 ID → 路径。
    private func conversationFiles(_ agent: String) -> [(cid: String, path: String)] {
        switch agent {
        case "claude":
            return claudeSessionFiles().map { ($0.cid, $0.path) }
        case "deepseek":
            return []   // 它的记录是 zstd 压缩的，系统自带的库解不开；搜正文先不支持
        case "gpt":
            // rollout-<时间>-<会话ID>.jsonl：会话 ID 是文件名最后 36 个字符
            return plainRollouts().compactMap { r in
                let name = ((r.path as NSString).lastPathComponent as NSString).deletingPathExtension
                return name.count >= 36 ? (String(name.suffix(36)), r.path) : nil
            }
        default:
            let dir = "\(geminiCliDir)/conversations"
            return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".db") }
                .map { (String($0.dropLast(3)), "\(dir)/\($0)") }
        }
    }

    func searchConversations(agent: String, query: String) {
        let q = trimmed(query)
        guard q.count >= 2 else { sendToJS("onConversationsSearched", ["agent": agent, "query": query, "ids": [String]()]); return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // 英文不分大小写：原样、全小写、全大写、首字母大写各找一遍
            var needles = [q, q.lowercased(), q.uppercased(), q.capitalized]
            needles = Array(Set(needles))
            let patterns = needles.map { Data($0.utf8) }
            var ids: [String] = []
            for f in conversationFiles(agent) {
                guard let size = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? Int, size > 0, size < 60_000_000,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: f.path), options: .mappedIfSafe) else { continue }
                if patterns.contains(where: { data.range(of: $0) != nil }) { ids.append(f.cid) }
            }
            sendToJS("onConversationsSearched", ["agent": agent, "query": query, "ids": ids])
        }
    }
}

// MARK: - 输入框里 @ 文件：在工作空间里按名字找文件

extension AppDelegate {
    /// 工作空间里的文件（相对路径）。git 仓库用 git 列（自动跳过忽略的文件），否则自己走一遍目录。缓存 15 秒。
    private func workspaceFiles(_ ws: String) -> [String] {
        procLock.lock()
        if let c = fileListCache[ws], Date().timeIntervalSince(c.at) < 15 { procLock.unlock(); return c.files }
        procLock.unlock()
        var files: [String] = []
        if let listed = runGit(["ls-files", "--cached", "--others", "--exclude-standard"], in: ws) {
            files = listed.split(separator: "\n").map(String.init)
        } else if let walker = fm.enumerator(atPath: ws) {
            let skip: Set<String> = ["node_modules", "build", "dist", ".git", "DerivedData", "__pycache__", ".venv", "venv"]
            while let rel = walker.nextObject() as? String, files.count < 8000 {
                let name = (rel as NSString).lastPathComponent
                if name.hasPrefix(".") || skip.contains(name) { walker.skipDescendants(); continue }
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular { files.append(rel) }
            }
        }
        if files.count > 20_000 { files = Array(files.prefix(20_000)) }
        procLock.lock(); fileListCache[ws] = (Date(), files); procLock.unlock()
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
