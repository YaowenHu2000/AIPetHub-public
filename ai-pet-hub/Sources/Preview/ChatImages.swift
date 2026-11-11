import Cocoa
import CryptoKit
import UniformTypeIdentifiers

// 对话里的图片。
// 用户消息带的图片有三种来源：Claude Code 记录里内嵌的 base64 图片块、Codex 记录里的本地图片路径（localImage），
// 以及消息文字里写到的图片路径（在 AIPetHub 里粘贴截图，插进输入框的就是路径）。
// 随历史发给网页的只是缩略图（长边最多 640 像素，小图原样）；点开时再按需读原图，不在别处另存副本。

let chatImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
private let thumbMaxPixels = 640
private let maxImagesPerMessage = 12

/// 缩略图缓存（后台同步会反复读同一个会话）：键是内容哈希或「路径 + 修改时间 + 大小」，总量超过上限就整个清空。
private final class ThumbCache {
    private var items: [String: [String: Any]] = [:]
    private var bytes = 0
    private let lock = NSLock()

    func get(_ key: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    func set(_ key: String, _ value: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        let size = (value["src"] as? String)?.utf8.count ?? 0
        if bytes + size > 48_000_000 { items.removeAll(); bytes = 0 }
        items[key] = value
        bytes += size
    }
}

private let thumbCache = ThumbCache()

/// 最近读过的 Codex rollout 里的附图（会话 ID → 原路径 → base64），见 codexRolloutImages。
private var rolloutImageCache: [String: (stamp: String, images: [String: String])] = [:]
private let rolloutImageLock = NSLock()

/// 有没有真正透明的像素：截图大多带 alpha 通道但整张不透明，这种存成 JPEG 能小很多。
private func hasTransparency(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    let w = image.width, h = image.height
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let base = ctx.data else { return true }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
        let row = px + y * ctx.bytesPerRow
        var x = 3
        while x < w * 4 {
            if row[x] != 255 { return true }
            x += 4
        }
    }
    return false
}

/// 解码好的图 → data URL：有透明像素用 PNG，否则 JPEG。
private func encodedDataURL(_ image: CGImage, alpha: Bool) -> String? {
    let out = NSMutableData()
    let type = alpha ? UTType.png : UTType.jpeg
    guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
    let props: [CFString: Any] = alpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return "data:\(alpha ? "image/png" : "image/jpeg");base64,\((out as Data).base64EncodedString())"
}

/// WebKit 能直接显示的格式（按内容判断，不看扩展名）；HEIC、TIFF、BMP 等要转码。
private func webMime(_ source: CGImageSource) -> String? {
    guard let uti = CGImageSourceGetType(source) as String?, let type = UTType(uti) else { return nil }
    if type.conforms(to: .png) { return "image/png" }
    if type.conforms(to: .jpeg) { return "image/jpeg" }
    if type.conforms(to: .gif) { return "image/gif" }
    if type.conforms(to: .webP) { return "image/webp" }
    return nil
}

/// 图片数据 → {src: data URL, w, h}（w、h 是显示方向上的像素）。
/// maxPixels 是缩略图长边上限；nil 表示原图，只在网页显示不了这种格式时转码。
func chatImageData(_ data: Data, maxPixels: Int?) -> [String: Any]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    if ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5 { swap(&w, &h) }   // 旋转了 90°
    guard w > 0, h > 0 else { return nil }
    // 网页能直接显示、而且本来就不大：原样用（动图也还能动；方向 WebKit 会按 EXIF 摆正）
    if let mime = webMime(source), maxPixels.map({ max(w, h) <= $0 && data.count <= 200_000 }) ?? true {
        return ["src": "data:\(mime);base64,\(data.base64EncodedString())", "w": w, "h": h]
    }
    func scaled(_ limit: Int) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: limit]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
    guard var image = scaled(maxPixels ?? max(w, h)) else { return nil }
    let alpha = hasTransparency(image)
    // 带透明的只能存 PNG，体积大不少：缩略图再小一档
    if alpha, let limit = maxPixels, max(image.width, image.height) > limit * 3 / 4, let smaller = scaled(limit * 3 / 4) {
        image = smaller
    }
    guard let src = encodedDataURL(image, alpha: alpha) else { return nil }
    return ["src": src, "w": image.width, "h": image.height]
}

/// 内嵌的 base64 图片 → 缩略图。
func chatThumbnail(base64: String) -> [String: Any]? {
    let key = "b:" + SHA256.hash(data: Data(base64.utf8)).map { String(format: "%02x", $0) }.joined()
    if let hit = thumbCache.get(key) { return hit }
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          let thumb = chatImageData(data, maxPixels: thumbMaxPixels) else { return nil }
    thumbCache.set(key, thumb)
    return thumb
}

/// 本机图片文件 → 缩略图；不是图片或读不到时返回 nil。
func chatThumbnail(path: String) -> [String: Any]? {
    guard chatImageExts.contains((path as NSString).pathExtension.lowercased()),
          let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= 80_000_000 else { return nil }
    let key = "f:\(path)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(size)"
    if let hit = thumbCache.get(key) { return hit }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
          let thumb = chatImageData(data, maxPixels: thumbMaxPixels) else { return nil }
    thumbCache.set(key, thumb)
    return thumb
}

/// 原图给查看器：太大的（超过 12 MB）缩到长边 4096，免得一次给网页几十 MB。
func fullImageDataURL(_ data: Data) -> String? {
    chatImageData(data, maxPixels: data.count > 12_000_000 ? 4096 : nil)?["src"] as? String
}

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
    /// Claude Code 记录里用户亲手附上的图片（消息内容里的 image 块）；工具结果、元信息里的图片不算。
    func claudeImageSources(_ obj: [String: Any]) -> [[String: Any]] {
        guard obj["type"] as? String == "user" else { return [] }
        for flag in ["isSidechain", "isMeta", "isApiErrorMessage", "isCompactSummary"] where (obj[flag] as? Bool) == true {
            return []
        }
        if let kind = (obj["origin"] as? [String: Any])?["kind"] as? String, kind != "human" { return [] }
        guard let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        let uuid = obj["uuid"] as? String ?? ""
        return blocks.enumerated().compactMap { i, b in
            guard b["type"] as? String == "image", let data = (b["source"] as? [String: Any])?["data"] as? String else { return nil }
            return ["data": data, "ref": "\(uuid)#\(i)"]
        }
    }

    /// 发给网页前给用户消息配上图片（只处理要显示的那几百条）；解析时记下的原始数据（imageSources）不发出去。
    /// ref 是「去哪找原图」：{agent, conversationId, id}，id 在 Claude 是「行 uuid#块序号」，在 Codex 是附图原来的路径。
    func attachChatImages(_ messages: inout [[String: Any]], payload: [String: Any]) {
        let base = payload["cwd"] as? String ?? ""
        let agent = payload["agent"] as? String ?? ""
        let cid = payload["conversationId"] as? String ?? ""
        var rollout: [String: String]?   // Codex：有附图文件不在了才去读 rollout
        for i in messages.indices where messages[i]["role"] as? String == "user" {
            let sources = messages[i].removeValue(forKey: "imageSources") as? [[String: Any]] ?? []
            var images = chatImages(sources: sources, text: messages[i]["text"] as? String ?? "", base: base) { path in
                guard agent == "gpt" else { return nil }
                if rollout == nil { rollout = codexRolloutImages(cid: cid) }
                return rollout?[path]
            }
            for k in images.indices {
                guard let id = images[k]["ref"] as? String else { continue }
                images[k]["ref"] = ["agent": agent, "conversationId": cid, "id": id]
            }
            if !images.isEmpty { messages[i]["images"] = images }
        }
    }

    /// 一条用户消息的图片：附件在前，然后是文字里写到的（同一个文件只出现一次）。
    /// 每张是 {src, w, h, path?, ref?, name?, match?}；附件文件不在了、也找不回来时是 {missing, path}。
    /// recover：附件文件不在了时，按原路径从会话记录里找回图片（base64）。
    func chatImages(sources: [[String: Any]], text: String, base: String,
                    recover: (String) -> String? = { _ in nil }) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var shown: [String: Int] = [:]   // 路径 → 在 out 里的位置
        for s in sources where out.count < maxImagesPerMessage {
            if let b64 = s["data"] as? String {
                guard var t = chatThumbnail(base64: b64) else { continue }
                if let ref = s["ref"] { t["ref"] = ref }
                out.append(t)
            } else if let raw = s["path"] as? String {
                let path = resolvePath(raw, base: base)
                guard shown[path] == nil else { continue }
                shown[path] = out.count
                if var t = chatThumbnail(path: path) {
                    t["path"] = path
                    out.append(t)
                } else if let b64 = recover(raw), var t = chatThumbnail(base64: b64) {
                    t["ref"] = raw
                    t["name"] = fileBaseName(raw)
                    out.append(t)
                } else {
                    out.append(["missing": true, "path": path])
                }
            }
        }
        for (match, raw) in imagePathMentions(text) {
            let path = resolvePath(raw, base: base)
            if let k = shown[path] {   // 已经作为附件显示了：文字里的写法也可以换成短标签
                if out[k]["match"] == nil, isAttachmentPath(path) { out[k]["match"] = match }
                continue
            }
            guard out.count < maxImagesPerMessage, var t = chatThumbnail(path: path) else { continue }
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
        return path.hasPrefix(pasted) || ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"].contains { path.hasPrefix($0) }
    }

    /// 点开对话里的图片：文件还在就直接读，否则按 ref 从会话记录里取（见 attachChatImages）。
    func fullChatImage(_ body: [String: Any]) -> String? {
        if let raw = body["path"] as? String, !raw.isEmpty {
            let path = resolvePath(raw, base: "")
            if chatImageExts.contains((path as NSString).pathExtension.lowercased()),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) {
                return fullImageDataURL(data)
            }
        }
        guard let ref = body["ref"] as? [String: Any], let cid = ref["conversationId"] as? String, isSafeId(cid),
              let id = ref["id"] as? String else { return nil }
        switch ref["agent"] as? String {
        case "claude":
            return claudeEmbeddedImage(cid: cid, id: id).flatMap(fullImageDataURL)
        case "gpt":
            return codexRolloutImages(cid: cid)[id].flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }.flatMap(fullImageDataURL)
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
               let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]], blocks.indices.contains(index),
               let b64 = (blocks[index]["source"] as? [String: Any])?["data"] as? String {
                return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            }
            from = lineEnd
        }
        return nil
    }

    /// Codex 的 rollout 里每张附图都存了一份（紧跟在 `<image … path="…">` 后面的 input_image）：原路径 → base64。
    /// 剪贴板截图存在临时目录，几天后会被系统清掉，那时只能从这里找回来。按 rollout 的修改时间缓存最近几个会话。
    func codexRolloutImages(cid: String) -> [String: String] {
        var hint = ""
        _ = withReadableSQLite("\(codexHome)/state_5.sqlite") { db in
            queryRows(db, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1;", [cid]) { s in hint = columnText(s, 0) }
        }
        guard let path = findRollout(cid: cid, hint: hint) else { return [:] }
        let stamp = "\(path)|\(modificationDate(path)?.timeIntervalSince1970 ?? 0)"
        rolloutImageLock.lock()
        let cached = rolloutImageCache[cid]
        rolloutImageLock.unlock()
        if let c = cached, c.stamp == stamp { return c.images }

        var images: [String: String] = [:]
        for line in (readRollout(path) ?? "").split(separator: "\n") where line.contains("\"input_image\"") {
            guard let obj = jsonObject(line), obj["type"] as? String == "response_item",
                  let item = obj["payload"] as? [String: Any], item["role"] as? String == "user",
                  let blocks = item["content"] as? [[String: Any]] else { continue }
            var pendingPath: String?
            for b in blocks {
                if b["type"] as? String == "input_text", let t = b["text"] as? String, t.hasPrefix("<image "),
                   let r = t.range(of: "path=\"[^\"]+\"", options: .regularExpression) {
                    pendingPath = String(t[r].dropFirst(6).dropLast())
                } else if b["type"] as? String == "input_image", let p = pendingPath,
                          let url = b["image_url"] as? String, let comma = url.firstIndex(of: ",") {
                    images[p] = String(url[url.index(after: comma)...])
                    pendingPath = nil
                }
            }
        }
        rolloutImageLock.lock()
        if rolloutImageCache.count >= 4 { rolloutImageCache.removeAll() }
        rolloutImageCache[cid] = (stamp, images)
        rolloutImageLock.unlock()
        return images
    }

    /// 网页的两种请求：chatThumbs（刚发出的消息里写到的图片）、chatImage（查看原图）。
    func handleChatImageRequest(_ action: String, _ body: [String: Any]) {
        guard let reqId = (body["reqId"] as? NSNumber)?.intValue else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if action == "chatThumbs" {
                let images = chatImages(sources: [], text: body["text"] as? String ?? "", base: body["base"] as? String ?? "")
                sendToJS("onChatThumbs", ["reqId": reqId, "images": images])
            } else if let src = fullChatImage(body) {
                sendToJS("onChatImage", ["reqId": reqId, "image": src])
            } else {
                sendToJS("onChatImage", ["reqId": reqId, "error": "原图读不到了（文件可能已被移动或删除）"])
            }
        }
    }
}

// MARK: - 随提问一起发的图片（真正的附件）

extension AppDelegate {
    /// 能当附件发的图片：文件在、是常见图片格式。
    func isAttachableImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"].contains(ext) && fm.fileExists(atPath: path)
    }

    /// 图片读成 base64。常见格式、不太大的原样发；太大或者模型不认的格式（HEIC、TIFF…）缩到长边 2000 像素、转成 JPEG。
    func attachmentData(_ path: String) -> (mime: String, base64: String)? {
        let ext = (path as NSString).pathExtension.lowercased()
        let mimes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        guard let data = fm.contents(atPath: path), !data.isEmpty else { return nil }
        if let mime = mimes[ext], data.count <= 3_500_000 { return (mime, data.base64EncodedString()) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2000] as CFDictionary),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return ("image/jpeg", jpeg.base64EncodedString())
    }
}
