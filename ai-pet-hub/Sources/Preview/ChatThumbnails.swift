// 随历史发给网页的只是缩略图（长边最多 640 像素，小图原样）：后台同步会反复读同一个会话，所以同一份字节按内容键缓存；
// 搜索只要知道图片可读，标签模式只取尺寸不编码。消息里图片的来源和组装见 ChatImages.swift。
import Cocoa
import CryptoKit
import UniformTypeIdentifiers

let chatImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
private let thumbMaxPixels = 640

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

func chatImageKey(_ base64: String) -> String {
    SHA256.hash(data: Data(base64.utf8)).map { String(format: "%02x", $0) }.joined()
}

extension LiveTurn {
    /// 三家的历史只留附件编号。用本轮实际送出的图片字节对位，转换过的大图也能和记录相认。
    func notePromptImages(_ blocks: [[String: Any]]) {
        let keys = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "image" else { return nil }
            return ((block["source"] as? [String: Any] ?? block)["data"] as? String).map(chatImageKey)
        }
        if !keys.isEmpty { app.sendToJS("onAgentImageKeys", ["agent":req.agent, "reqId":req.reqId, "keys":keys]) }
    }
}

/// 内嵌的 base64 图片 → 缩略图。
func chatThumbnail(base64: String, freeze: ((Data) -> String?)? = nil) -> [String: Any]? {
    TestHooks.chatThumbnailRequested?()
    let identity = chatImageKey(base64), key = "b:\(freeze != nil):" + identity
    if let hit = thumbCache.get(key), freeze == nil || (hit["snapshot"] as? String).map(FileManager.default.isReadableFile(atPath:)) == true { return hit }
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          var thumb = chatImageData(data, maxPixels: thumbMaxPixels) else { return nil }
    if let freeze {
        guard let copy = freeze(data) else { return ["missing":true] }
        thumb["snapshot"] = copy
    }
    thumb["imageKey"] = identity
    thumbCache.set(key, thumb)
    return thumb
}

/// 本机图片文件 → 缩略图；不是图片或读不到时返回 nil。
func chatThumbnail(path: String, stamp: String? = nil, freeze: ((Data) -> String?)? = nil) -> [String: Any]? {
    TestHooks.chatThumbnailRequested?()
    let path = (path as NSString).resolvingSymlinksInPath
    guard chatImageExts.contains((path as NSString).pathExtension.lowercased()),
          let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          attrs[.type] as? FileAttributeType == .typeRegular,
          let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= 80_000_000 else { return nil }
    let key = "f:\(path)|\(stamp ?? "")|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(size)|\(freeze != nil)"
    if let hit = thumbCache.get(key), freeze == nil || (hit["snapshot"] as? String).map(FileManager.default.isReadableFile(atPath:)) == true { return hit }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: freeze == nil ? .alwaysMapped : []),
          var thumb = chatImageData(data, maxPixels:thumbMaxPixels) else { return nil }
    // 存不下副本（快照目录不可写）不等于原图不在：照样显示，只是没有冻结的那份，查看和重发沿用原路径；
    // 缓存命中时会因为没有副本而重试冻结，目录恢复可写后自动补上
    if let freeze, let copy = freeze(data) { thumb["snapshot"] = copy }
    thumbCache.set(key, thumb)
    return thumb
}

/// 搜索只需判断图片是否可读；不缩放、不检查透明像素，也不编码 data URL。
func chatImageLabel(_ data: Data) -> [String: Any]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, w > 0,
          let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, h > 0 else { return nil }
    if webMime(source) != nil, max(w, h) <= thumbMaxPixels, data.count <= 200_000 { return [:] }
    // 只有尺寸头、像素数据已损坏的文件也可能报出宽高；沿用解码条件，但不生成缩略图。
    guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
    return [:]
}

func chatImageLabel(path: String) -> [String: Any]? {
    let target = (path as NSString).resolvingSymlinksInPath
    guard chatImageExts.contains((target as NSString).pathExtension.lowercased()),
          let attrs = try? FileManager.default.attributesOfItem(atPath: target),
          attrs[.type] as? FileAttributeType == .typeRegular,
          let size = (attrs[.size] as? NSNumber)?.intValue, size > 0, size <= 80_000_000,
          let data = try? Data(contentsOf: URL(fileURLWithPath: target), options: .alwaysMapped) else { return nil }
    return chatImageLabel(data)
}

/// 原图给查看器：太大的（超过 12 MB）缩到长边 4096，免得一次给网页几十 MB。
func fullImageDataURL(_ data: Data) -> String? {
    chatImageData(data, maxPixels: data.count > 12_000_000 ? 4096 : nil)?["src"] as? String
}
