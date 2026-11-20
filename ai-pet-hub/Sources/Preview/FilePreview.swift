// 文件预览：把回答里写的路径解析成真实路径，读内容给预览面板。
import Cocoa

private let previewImageMIMEs = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                                  "webp": "image/webp", "svg": "image/svg+xml"]

extension AppDelegate {
    /// 回答里的缺图标签和预览必须沿用同一读取条件，否则搜索命中后页面没有对应文字。
    func previewImageData(at path: String) -> Data? {
        let target = (path as NSString).resolvingSymlinksInPath
        guard previewImageMIMEs[(target as NSString).pathExtension.lowercased()] != nil,
              let attrs = try? fm.attributesOfItem(atPath: target),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 8_000_000 else { return nil }
        return fm.contents(atPath: target)
    }

    func resolvePath(_ raw: String, base: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://"), let url = URL(string: p) { return url.path }
        let absolute: (String) -> String = { [self] q in
            var q = q
            if q.hasPrefix("~/") { q = home + String(q.dropFirst(1)) }
            if !q.hasPrefix("/") { q = (base.isEmpty ? home : base) + "/" + q }
            return (q as NSString).standardizingPath
        }
        // 先按原样找：文件名里本来就可能有「#」「%」（report#1.md、100%20done.md）
        let literal = absolute(p)
        if fm.fileExists(atPath: literal) { return literal }
        // 找不到再当成链接：去掉 #片段、解开 %编码
        if let hash = p.firstIndex(of: "#") { p = String(p[..<hash]) }
        if p.contains("%"), let decoded = p.removingPercentEncoding { p = decoded }
        p = absolute(p)
        if fm.fileExists(atPath: p) { return p }
        // 还找不到：去掉结尾的「:行号(:列号)」（原样和解码后的都试）
        for cand in [literal, p] {
            if let r = cand.range(of: ":[0-9]+(:[0-9]+)?$", options: .regularExpression) {
                let q = String(cand[..<r.lowerBound])
                if fm.fileExists(atPath: q) { return q }
            }
        }
        return p
    }

    /// 文件预览：文本最多读 400KB，图片转成 data URL。
    func readFileForPreview(path: String, base: String, reqId: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let p = resolvePath(path, base: base)
            let target = (p as NSString).resolvingSymlinksInPath
            let attrs = try? fm.attributesOfItem(atPath: target)
            var payload: [String: Any] = ["reqId": reqId, "path": p]
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: target, isDirectory: &isDir) {
                payload["error"] = "文件不存在（可能已被移动或删除）"
            } else if isDir.boolValue {
                payload["error"] = "这是一个文件夹"
                payload["isDir"] = true
            } else if attrs?[.type] as? FileAttributeType != .typeRegular {
                payload["error"] = "不是普通文件，无法预览"
            } else {
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                payload["size"] = size
                if let mime = previewImageMIMEs[(target as NSString).pathExtension.lowercased()] {
                    if let data = previewImageData(at: target) {
                        payload["image"] = "data:\(mime);base64,\(data.base64EncodedString())"
                    } else {
                        payload["error"] = "图片太大，无法预览"
                    }
                } else if let handle = FileHandle(forReadingAtPath: target) {
                    let limit = 400_000
                    defer { try? handle.close() }
                    guard let data = try? (handle.read(upToCount: limit) ?? Data()) else {
                        payload["error"] = "无法读取这个文件"
                        sendToJS("onFileRead", payload)
                        return
                    }
                    // 带 BOM 的 UTF-16 文本（Windows 记事本「Unicode」存的）每个 ASCII 字符都带零字节，先按 BOM 认出来，免得判成二进制
                    if data.count >= 2, (data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF) {
                        let bytes = data.dropFirst(2)
                        let units = stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2).map {
                            data[0] == 0xFF ? UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
                        }
                        payload["content"] = String(decoding: units, as: UTF16.self)
                        payload["truncated"] = size > limit
                    } else if data.contains(0) {
                        payload["error"] = "二进制文件，无法预览"
                    } else {
                        payload["content"] = String(decoding: data, as: UTF8.self)
                        payload["truncated"] = size > limit
                    }
                } else {
                    payload["error"] = "无法读取这个文件"
                }
            }
            sendToJS("onFileRead", payload)
        }
    }
}
