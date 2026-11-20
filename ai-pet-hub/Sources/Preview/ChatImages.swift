// 对话里的图片。
// 用户消息带的图片有五种来源：Claude Code 记录里内嵌的 base64 图片块、Codex 记录里的本地图片路径（localImage）、
// dsh 附件目录里的图片（事件里只记附件编号）、agy 会话库用户步骤里的图片附件，
// 以及消息文字里写到的图片路径（在 AIPetHub 里粘贴截图，插进输入框的就是路径）。
// 随历史发给网页的只是缩略图（长边最多 640 像素，小图原样；编码在 ChatThumbnails.swift）；点开时读原图（按 ref 回查记录在 ChatImageOriginals.swift）；
// 没有可回查编号的附件从同一份数据保留快照。
//
// 历史提问、补充与分段失败的原问都在这里生成缩略图。
// Claude 按行 UUID 和内容块读，Gemini 按步骤和附件序号读，DeepSeek 按对象或回退调用编号读。
// Codex 在文件指纹与发送时间相符时直接读文件，变化后按回合和附件序号批量查 rollout，回退分段仍可向前找。
// 外部 Codex 只写内嵌图、没有块编号时，从同一份字节生成缩略图和快照。
// 点开、编辑与重试共用原图读取规则。
// 只有路径的旧记录在打开时保留仍能取得的那份，原路径已经换过且 CLI 从未存图时，无法追溯发送时的字节。
// 搜索只取可见标签，缩略图留在内存，送给前端的原图按需读取。
import Cocoa

private let maxImagesPerMessage = 12

private let imagePathPattern: NSRegularExpression = {
    let ext = "\\.(?:png|jpe?g|gif|webp|heic|heif|bmp|tiff?)"
    let start = "(?:~|file://)?/"
    let pattern = "\"(\(start)[^\"\\n]*?\(ext))\""                                       // "带 空格 的/路径.png"
        + "|'(\(start)[^'\\n]*?\(ext))'"
        + "|(?<![A-Za-z0-9_.~/:-])(\(start)[^\\s\"'<>`|]*?\(ext))(?![A-Za-z0-9_])"      // 不带引号：到空白或标点为止
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

/// 文字里写到的图片路径（绝对路径或 ~ 开头；含空格的要带引号，AIPetHub 插入路径时就是这样）：[(原文写法, 路径)]。
func imagePathMentions(_ text: String) -> [(match: String, path: String)] {
    guard text.contains("/") else { return [] }
    let ns = text as NSString
    var out: [(match: String, path: String)] = []
    for m in imagePathPattern.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 200_000))) {
        if let g = (1...3).first(where: { m.range(at: $0).location != NSNotFound }) {
            out.append((ns.substring(with: m.range), ns.substring(with: m.range(at: g))))
        }
        if out.count >= 24 { break }
    }
    return out
}

/// Codex 用户消息里的图片：本地图片（localImage / local_image 的路径）或内嵌的 data URL。
func codexImageSources(_ content: Any?) -> [[String: Any]] {
    guard let blocks = content as? [[String: Any]] else { return [] }
    return blocks.compactMap { b in
        switch b["type"] as? String ?? "" {
        case "localImage", "local_image":
            return (b["path"] as? String).map { ["path": $0] }
        case "image", "input_image":
            guard let url = (b["url"] ?? b["image_url"]) as? String, url.hasPrefix("data:image/"),
                  let comma = url.firstIndex(of: ",") else { return nil }
            return ["data": String(url[url.index(after: comma)...])]
        default:
            return nil
        }
    }
}

/// Codex 桌面版把附件写在提问前面（「# Files mentioned by the user: … ## My request: …」）；
/// 提到的文件都是这条消息另外附上的图片时，只留提问本身。
func stripCodexAttachmentHeader(_ text: String, images: [[String: Any]]) -> String {
    guard text.hasPrefix("# Files mentioned by the user:"), let r = text.range(of: "\n## My request:") else { return text }
    let attached = Set(images.compactMap { $0["path"] as? String })
    let mentioned = text[..<r.lowerBound].split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("## "), let sep = line.range(of: ": /") else { return nil }
        return String(line[line.index(after: sep.lowerBound)...]).trimmingCharacters(in: .whitespaces)
    }
    guard !mentioned.isEmpty, mentioned.allSatisfy({ attached.contains($0) }) else { return text }
    return text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
}

extension AppDelegate {
    /// 普通提问和 queued_command 补充都保存原内容块序号，点原图时才能回到同一块。
    func claudeImageSources(_ obj: [String: Any]) -> [[String: Any]] {
        let attachment = obj["attachment"] as? [String: Any] ?? [:]
        let queued = obj["type"] as? String == "attachment" && attachment["type"] as? String == "queued_command"
        guard obj["type"] as? String == "user" || queued else { return [] }
        for flag in ["isSidechain", "isMeta", "isApiErrorMessage", "isCompactSummary"] where (obj[flag] as? Bool) == true {
            return []
        }
        let origin = (queued ? attachment : obj)["origin"] as? [String: Any]
        if let kind = origin?["kind"] as? String, kind != "human" { return [] }
        guard let blocks = (queued ? attachment["prompt"] : (obj["message"] as? [String: Any])?["content"]) as? [[String: Any]] else { return [] }
        let uuid = obj["uuid"] as? String ?? ""
        return blocks.enumerated().compactMap { i, b in
            guard b["type"] as? String == "image", let data = (b["source"] as? [String: Any])?["data"] as? String else { return nil }
            return ["data": data, "ref": "\(uuid)#\(i)"]
        }
    }

    /// 普通提问和「你补充说」走同一缩略图 / 原图机制；原始数据（imageSources）不发出去。
    /// ref 是「去哪找原图」：{agent, conversationId, id}，id 在 Claude 是「行 uuid#块序号」，
    /// 在 Codex 是「原路径#这一回合里第几次发送@回合」（codexImageRecordId；没有回合和次序的来源只有原路径，取最后一次）。
    func attachChatImages(_ messages: inout [[String: Any]], payload: [String: Any], labelsOnly: Bool = false) {
        let base = payload["cwd"] as? String ?? ""
        let agent = payload["agent"] as? String ?? ""
        let cid = payload["conversationId"] as? String ?? ""
        // 同一份附件可出现在提问、补充和重试中。一页内只解析一次路径及其显示名，文件内容仍按各次发送校验。
        var locations = [String:(String,String?)]()
        func locate(_ raw: String) -> (String,String?) {
            if let hit = locations[raw] { return hit }
            let path = resolvePath(raw,base:base)
            let result = (path,sentImageOrigin(path))
            locations[raw] = result
            return result
        }
        // Codex：先挑出原文件已不在、或发送之后被改过的附图；真要读 rollout 时只取这几张（读一次，整段历史共用）
        var wanted = Set<String>()
        if agent == "gpt" {
            func collect(_ message: [String: Any]) {
                for s in message["imageSources"] as? [[String: Any]] ?? [] {
                    guard let raw = s["path"] as? String else { continue }
                    let (sentPath, _) = locate(raw)
                    if let id = codexImageRecordId(s) {
                        if imageFileStamp(sentPath, sentAt:s["at"] as? Double ?? 0) == nil { wanted.insert(id) }
                    } else if !fm.fileExists(atPath:sentPath) { wanted.insert(raw) }
                }
            }
            for m in messages {
                if let ask = m["retryUser"] as? [String:Any] { collect(ask) }
                if m["role"] as? String == "user" { collect(m) }
                for step in m["steps"] as? [[String: Any]] ?? [] where step["kind"] as? String == "user" { collect(step) }
            }
        }
        var rollout: [String: String]?
        func attach(_ message: inout [String: Any], textKey: String) {
            restorePathAttachments(&message, textKey:textKey)
            let sources = message.removeValue(forKey:"imageSources") as? [[String:Any]] ?? []
            var images = chatImages(sources: sources, text: message[textKey] as? String ?? "", base: base, labelsOnly: labelsOnly, locate:locate) { id in
                guard agent == "gpt" else { return nil }
                // 文件也可能在预检后才被替换；实际需要的编号必须参与本次回查。
                let added = wanted.insert(id).inserted
                if rollout == nil || added { rollout = codexRolloutImages(cid:cid, wanted:wanted) }
                return rollout?[id]
            }
            for k in images.indices {
                guard let id = images[k]["ref"] as? String else { continue }
                var ref: [String: Any] = ["agent": agent, "conversationId": cid, "id": id]
                if let path = images[k].removeValue(forKey: "sentPath") as? String, let stamp = images[k].removeValue(forKey: "stamp") {
                    ref["path"] = path
                    ref["stamp"] = stamp
                }
                images[k]["ref"] = ref
            }
            if !images.isEmpty { message["images"] = images }
        }
        for i in messages.indices {
            if var ask = messages[i]["retryUser"] as? [String:Any] {
                attach(&ask, textKey:"text"); messages[i]["retryUser"] = ask
            }
            if messages[i]["role"] as? String == "user" { attach(&messages[i], textKey: "text") }
            if var steps = messages[i]["steps"] as? [[String: Any]] {
                for j in steps.indices where steps[j]["kind"] as? String == "user" { attach(&steps[j], textKey: "detail") }
                messages[i]["steps"] = steps
            }
        }
    }

    /// 一条用户消息的图片：附件在前，然后是文字里写到的（同一个文件只出现一次）。
    /// 每张是 {src, w, h, path?, ref?, name?, match?, changed?}；附件文件不在了、也找不回来时是 {missing, path}。
    /// changed：路径上的文件在发送之后被改过，显示的是记录里当时那张（重试按 ref 发它，见 message-sync.js 的 historyRetry）。
    /// recover：按 ref 的 id 从会话记录里取图片（base64）；附件文件不在了、或发送之后被改过时才用。
    func chatImages(sources: [[String: Any]], text: String, base: String, labelsOnly: Bool = false,
                    locate: ((String) -> (String,String?))? = nil,
                    recover: (String) -> String? = { _ in nil }) -> [[String: Any]] {
        func local(_ path: String, stamp: String? = nil, freeze: Bool = false) -> [String: Any]? {
            if labelsOnly { return chatImageLabel(path:path) }
            guard freeze else { return chatThumbnail(path:path, stamp:stamp) }
            // 旧格式只记了路径，缩略图和之后的编辑至少应共用本次打开能读到的那一份。
            return chatThumbnail(path:path, stamp:imageFileStamp(path)) { data in
                self.temporaryImageFile(data, ext:(path as NSString).pathExtension, origin:path)
            }
        }
        func embedded(_ base64: String, freeze: Bool = false) -> [String: Any]? {
            if !labelsOnly { return chatThumbnail(base64:base64, freeze:freeze ? { self.temporaryImageFile($0) } : nil) }
            return Data(base64Encoded: base64, options: .ignoreUnknownCharacters).flatMap(chatImageLabel)
        }
        var out: [[String: Any]] = []
        var shown: [String: Int] = [:]   // 路径 → 在 out 里的位置
        for s in sources where out.count < maxImagesPerMessage {
            if let b64 = s["data"] as? String {
                guard var t = embedded(b64, freeze:s["ref"] == nil) else {
                    if let ref = s["ref"] { out.append(["ref":ref,"missing":true]) }
                    continue
                }
                if let ref = s["ref"] {
                    t["ref"] = ref
                    // 发送时缩过的大图：点开、编辑和重试用当时的完整副本，和实时那一轮一样（SentImages.swift 的 fullSentImage）
                    if !labelsOnly, let key = t["imageKey"] as? String, let full = fullSentImage(key: key) { t["snapshot"] = full }
                }
                if let sentPath = s["path"] as? String {
                    let path = sentImageOrigin(sentPath) ?? sentPath
                    t["path"] = path; t["name"] = fileBaseName(path); t["changed"] = true
                    shown[path] = out.count
                }
                out.append(t)
            } else if let raw = s["path"] as? String {
                // 发给 Codex 前转换过的照片（codexImagePath）：记录里是临时 JPEG，显示和对位都用原来的照片路径
                let (sentPath, origin) = locate?(raw) ?? {
                    let path = resolvePath(raw,base:base)
                    return (path,sentImageOrigin(path))
                }()
                let path = origin ?? sentPath
                shown[path] = out.count
                shown[sentPath] = out.count
                // 同一路径的文件可能被覆盖过（Codex 记下了这是哪一回合的第几张，见 CodexTurnGrouper）：文件还在、发送之后没改过就直接用它，
                // 不读 rollout（几十 MB 的记录每次打开、同步都整份读一遍要零点几秒）；改过或不在了才以记录里当时那张为准。
                let record = codexImageRecordId(s)
                let stamp = record == nil ? nil : imageFileStamp(sentPath, sentAt:s["at"] as? Double ?? 0)
                func recovered(_ id: String) -> [String: Any]? {
                    guard let b64 = recover(id), var t = embedded(b64) else { return nil }
                    t["ref"] = id
                    t["name"] = fileBaseName(path)
                    return t
                }
                if record == nil || stamp != nil, var t = local(sentPath, stamp:stamp, freeze:locate != nil && record == nil && origin == nil && !isSentImageFile(sentPath)),
                   record == nil || imageFileStamp(sentPath) == stamp {
                    t["path"] = path
                    if origin != nil && record == nil { t["snapshot"] = sentPath }
                    if let record, !labelsOnly {
                        t["ref"] = record
                        t["sentPath"] = sentPath
                        t["stamp"] = stamp
                    }
                    out.append(t)
                } else if let id = record, var t = recovered(id) {
                    // 文件还在就照旧带上路径：「在访达中显示」、实时那一轮和历史对位都用它；点开原图、重试按 ref 用当时那张
                    if fm.fileExists(atPath: path) { t["path"] = path; t["changed"] = true }
                    out.append(t)
                } else if origin != nil, var t = local(sentPath) {
                    t["path"] = path; t["snapshot"] = sentPath
                    out.append(t)
                } else if record == nil, let t = recovered(raw) {
                    out.append(t)
                } else {
                    var missing: [String:Any] = ["missing": true, "path": path]
                    missing["ref"] = record
                    if origin != nil { missing["snapshot"] = sentPath }
                    out.append(missing)
                }
            } else if let ref = s["ref"] {
                out.append(["ref":ref,"missing":true])
            }
        }
        for (match, raw) in imagePathMentions(text) {
            let path = resolvePath(raw, base: base)
            if let k = shown[path] {   // 已经作为附件显示了：文字里的写法也可以换成短标签
                if out[k]["match"] == nil, isAttachmentPath(path) { out[k]["match"] = match }
                continue
            }
            guard out.count < maxImagesPerMessage, var t = local(path) else { continue }
            t["mentioned"] = true
            t["path"] = path
            if isAttachmentPath(path) { t["match"] = match }
            shown[path] = out.count
            out.append(t)
        }
        return out
    }

    /// 粘贴截图、剪贴板图片这类临时存下的文件：路径本身没有意义，消息文字里显示成短标签（match）。
    func isAttachmentPath(_ path: String) -> Bool {
        let pasted = "\(home)/Library/Application Support/AIPetHub/粘贴的图片/"
        return path.hasPrefix(pasted) || path.hasPrefix(durableSentImagesDir) || ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"].contains { path.hasPrefix($0) }
    }

    /// 有记录引用时显示路径只用于定位文件，取不到该次原图就交给查看器提示。
    func fullChatImage(_ body: [String: Any]) -> String? {
        if let ref = body["ref"] as? [String:Any] { return sentImageData(ref).flatMap(fullImageDataURL) }
        if let raw = (body["snapshot"] ?? body["path"]) as? String, !raw.isEmpty {
            let path = resolvePath(raw, base: "")
            if chatImageExts.contains((path as NSString).pathExtension.lowercased()),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
                return fullImageDataURL(data)
            }
        }
        return nil
    }

    /// 修改时间可随旧文件一起移回来，ctime 会留下本次替换的时间。时间精度不足时回查记录。
    private func imageFileStamp(_ path: String, sentAt: Double? = nil) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        if let at = sentAt {
            let m = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            let c = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9
            guard max(m,c) <= at else { return nil }
        }
        return "\(info.st_ino):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    func verifiedImagePath(_ ref: [String: Any]) -> String? {
        guard let path = ref["path"] as? String, let stamp = ref["stamp"] as? String,
              imageFileStamp(path) == stamp else { return nil }
        return path
    }

    /// 查看、编辑和重试采用同一来源。读完再复核指纹，防止恰好在读取期间替换文件。
    func sentImageData(_ ref: [String:Any]) -> Data? {
        if let copy = readableSnapshot(ref), let data = fm.contents(atPath:copy) { return data }
        if let path = verifiedImagePath(ref), let data = fm.contents(atPath:path), verifiedImagePath(ref) != nil { return data }
        return chatImageOriginal(ref)
    }

    /// 网页的两种请求：chatThumbs（刚发出的消息里写到的图片）、chatImage（查看原图）。
    func handleChatImageRequest(_ action: String, _ body: [String: Any]) {
        guard let reqId = (body["reqId"] as? NSNumber)?.intValue else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if action == "chatThumbs" {
                let paths = body["snapshots"] as? [String] ?? []
                let images = chatImages(sources: paths.map { ["path":$0] }, text: body["text"] as? String ?? "", base: body["base"] as? String ?? "")
                sendToJS("onChatThumbs", ["reqId": reqId, "images": images])
            } else if action == "editChatImages" {
                // freeze：编辑带回的是发送时的副本，再附同一原图时按发送的规则冻结，内容没变就得到同一路径、网页按路径去重。
                var paths = body["paths"] as? [String] ?? []
                if body["freeze"] as? Bool == true { paths = paths.map { sentImagePaths([$0])?[$0] ?? $0 } }
                if let result = resolveImageRefs(body["refs"] as? [[String:Any]] ?? [], among:paths) {
                    sendToJS("onFilesDropped", ["pasteId":reqId, "paths":result.paths])
                } else {
                    sendToJS("onFilesDropped", ["pasteId":reqId, "error":"会话记录里的原图读不到了"])
                }
            } else if let src = fullChatImage(body) {
                sendToJS("onChatImage", ["reqId": reqId, "image": src])
            } else {
                sendToJS("onChatImage", ["reqId": reqId, "error": "原图读不到了（文件可能已被移动或删除）"])
            }
        }
    }
}
