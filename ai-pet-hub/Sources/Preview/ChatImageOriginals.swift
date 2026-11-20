// 点开、编辑、重试时按 ref 从各位的会话记录里取发送时的原图字节：路径上的文件可能已被覆盖或清掉，记录里那份才是当时发的。
// Codex 按「原路径#次序@回合」在 rollout 里找，并缓存最近几个会话要的那几张，免得同步时反复读整份 rollout。
import Cocoa

/// 最近读过的 Codex rollout 里的附图（会话 ID → 找过哪些编号、找到的编号 → base64），见 codexRolloutImages。
private var rolloutImageCache: [String: (stamp: String, wanted: Set<String>, images: [String: String])] = [:]
private let rolloutImageLock = NSLock()

extension AppDelegate {
    /// 按 ref 从会话记录里取原图的字节（查看原图、重试时还原附件共用）。
    func chatImageOriginal(_ ref: [String: Any]) -> Data? {
        // Gemini 桌面会话的 ID 带「desktop:」前缀，按各位自己的规则校验
        guard let cid = ref["conversationId"] as? String, validConversationId(cid, agent: ref["agent"] as? String ?? ""),
              let id = ref["id"] as? String else { return nil }
        switch ref["agent"] as? String {
        case "claude":
            return claudeEmbeddedImage(cid: cid, id: id)
        case "gpt":
            return codexRolloutImages(cid: cid, wanted: [id])[id].flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        case "deepseek":   // id 是 dsh 的附件编号（DeepSeekEvents.swift 的 dshImageSources）
            if let url = dshFallbackImageURL(id) { return try? Data(contentsOf:url) }
            return dshAttachmentPath(id).flatMap { FileManager.default.contents(atPath: $0) }
        case "gemini":   // id 是「步骤序号#附件序号」，图片字节在会话库那一步里（GeminiDatabase.swift 的 agyImageSources）
            return geminiAttachedImage(cid: cid, id: id)
        default:
            return nil
        }
    }

    /// Claude 记录里内嵌的图片原图：id 是「行 uuid#块序号」，按 uuid 找到那一行再取出来。
    func claudeEmbeddedImage(cid: String, id: String) -> Data? {
        let parts = id.split(separator: "#")
        guard parts.count == 2, isSafeId(String(parts[0])), let index = Int(parts[1]),
              // claudeCache 只在 Claude 的队列上读写（这里在全局后台队列，不会和它互相等待）
              let file = queue(for: "claude").sync(execute: { findClaudeSession(cid: cid) }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped) else { return nil }
        let uuid = String(parts[0])
        let needle = Data("\"uuid\":\"\(uuid)\"".utf8)
        var from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) {
            let lineStart = data[..<r.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
            let lineEnd = data[r.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let obj = jsonObject(data[lineStart..<lineEnd]), obj["uuid"] as? String == uuid,
               let blocks = ((obj["message"] as? [String: Any])?["content"] ?? (obj["attachment"] as? [String: Any])?["prompt"]) as? [[String: Any]], blocks.indices.contains(index),
               let b64 = (blocks[index]["source"] as? [String: Any])?["data"] as? String {
                return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            }
            from = lineEnd
        }
        return nil
    }

    /// Codex 附图在 rollout 里的编号：「原路径#这一回合里第几次发送@回合」（CodexTurnGrouper 记下的 send、turn）；没记这两项的来源为 nil。
    func codexImageRecordId(_ s: [String: Any]) -> String? {
        guard let raw = s["path"] as? String, let send = s["send"] as? Int else { return nil }
        return "\(raw)#\(send)@\(s["turn"] as? String ?? "")"
    }

    /// Codex 的 rollout 里每张附图都存了一份（紧跟在 `<image … path="…">` 后面的 input_image）：按 codexImageRecordId 的编号取，
    /// 另有「原路径」→ 最后一次（没有回合和次序的来源用）。同一路径的文件会被覆盖、剪贴板截图几天后会被系统清掉，按编号才能还原每一轮当时那张。
    /// 次序按 `<image>` 标签数，图片没能处理、没留下 input_image 的那次也占一个序号，和历史里的次序对得上。
    /// 按回合计数：thread/revert 之后 rollout_path 指向新的一段（文件名多一个「_段号」，开头的 history_base 指回旧的一段），
    /// 里面只有回滚点之后的回合；从头计数会和数据库从第一轮算起的次序错开，把新的一段里的图对到旧回合上。新的一段里没有的再去读旧的几段。
    /// 只取 wanted 里的那几张，缓存（按最新一段的修改时间，最近几个会话）也只留这几张，不把整份记录的图片都留在内存里。
    func codexRolloutImages(cid: String, wanted: Set<String>) -> [String: String] {
        guard !wanted.isEmpty else { return [:] }
        var hint = ""
        _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
            queryRows(db, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1;", [cid]) { s in hint = columnText(s, 0) }
        }
        guard let path = findRollout(cid: cid, hint: hint) else { return [:] }
        let stamp = "\(path)|\(modificationDate(path)?.timeIntervalSince1970 ?? 0)"
        rolloutImageLock.lock()
        let cached = rolloutImageCache[cid].flatMap { $0.stamp == stamp ? $0 : nil }
        rolloutImageLock.unlock()
        if let c = cached, wanted.isSubset(of: c.wanted) { return c.images.filter { wanted.contains($0.key) } }

        hooks.codexRolloutImagesRead?()
        var images = rolloutImages(path, wanted: wanted)
        if images.count < wanted.count, (path as NSString).lastPathComponent.contains("-\(cid)_"),
           let walker = fm.enumerator(atPath: "\(codexHome)/sessions") {
            while let rel = walker.nextObject() as? String, images.count < wanted.count {
                let name = (rel as NSString).lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"),
                      name.contains("-\(cid).jsonl") || name.contains("-\(cid)_"), "\(codexHome)/sessions/\(rel)" != path else { continue }
                images.merge(rolloutImages("\(codexHome)/sessions/\(rel)", wanted: wanted)) { latest, _ in latest }
            }
        }
        rolloutImageLock.lock()
        if rolloutImageCache[cid] == nil, rolloutImageCache.count >= 4 { rolloutImageCache.removeAll() }
        rolloutImageCache[cid] = (stamp, wanted.union(cached?.wanted ?? []), images.merging(cached?.images ?? [:]) { new, _ in new })
        rolloutImageLock.unlock()
        return images
    }

    /// 一个 rollout 文件里 wanted 要的那几张附图（编号见 codexImageRecordId）。
    private func rolloutImages(_ path: String, wanted: Set<String>) -> [String: String] {
        var images: [String: String] = [:]
        var sends: [String: Int] = [:]   // 「回合|原路径」→ 这一回合里已经发过几次
        var turn = ""
        let marker = Data("<image ".utf8), turnId = Data("\"turn_id\":\"".utf8)
        let turnStarts = [Data("\"type\":\"turn_context\"".utf8), Data("\"type\":\"task_started\"".utf8)]
        for line in (readRollout(path) ?? "").utf8.split(separator: 0x0A) {
            let data = Data(line)
            // 回合开头（task_started、turn_context 的类型都在行首附近）：之后的用户消息属于这一回合，回合 ID 是行里第一个 turn_id
            if turnStarts.contains(where: { data.prefix(240).range(of: $0) != nil }) {
                turn = data.range(of: turnId).flatMap { r in
                    data[r.upperBound...].firstIndex(of: 0x22).map { String(decoding: data[r.upperBound..<$0], as: UTF8.self) }
                } ?? ""
                continue
            }
            guard data.range(of: marker) != nil, let obj = jsonObject(data), obj["type"] as? String == "response_item",
                  let item = obj["payload"] as? [String: Any], item["role"] as? String == "user",
                  let blocks = item["content"] as? [[String: Any]] else { continue }
            var pending: (path: String, id: String)?
            for b in blocks {
                if b["type"] as? String == "input_text", let t = b["text"] as? String, t.hasPrefix("<image "),
                   let r = t.range(of: "path=\"[^\"]+\"", options: .regularExpression) {
                    let p = String(t[r].dropFirst(6).dropLast())
                    pending = (p, "\(p)#\(sends["\(turn)|\(p)", default: 0])@\(turn)")
                    sends["\(turn)|\(p)", default: 0] += 1
                } else if b["type"] as? String == "input_image", let p = pending,
                          let url = b["image_url"] as? String, let comma = url.firstIndex(of: ",") {
                    if wanted.contains(p.id) || wanted.contains(p.path) {
                        let b64 = String(url[url.index(after: comma)...])
                        if wanted.contains(p.id) { images[p.id] = b64 }
                        if wanted.contains(p.path) { images[p.path] = b64 }
                    }
                    pending = nil
                } else if b["type"] as? String == "input_text", b["text"] as? String == "</image>" {
                    pending = nil
                }
            }
        }
        return images
    }
}
