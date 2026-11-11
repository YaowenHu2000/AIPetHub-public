// 文件预览：把回答里写的路径解析成真实路径，读内容给预览面板。
import Cocoa

extension AppDelegate {
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
            var payload: [String: Any] = ["reqId": reqId, "path": p]
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: p, isDirectory: &isDir) {
                payload["error"] = "文件不存在（可能已被移动或删除）"
            } else if isDir.boolValue {
                payload["error"] = "这是一个文件夹"
                payload["isDir"] = true
            } else {
                let size = ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.intValue ?? 0
                payload["size"] = size
                let images = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                              "webp": "image/webp", "svg": "image/svg+xml"]
                if let mime = images[(p as NSString).pathExtension.lowercased()] {
                    if size <= 8_000_000, let data = fm.contents(atPath: p) {
                        payload["image"] = "data:\(mime);base64,\(data.base64EncodedString())"
                    } else {
                        payload["error"] = "图片太大，无法预览"
                    }
                } else if let handle = FileHandle(forReadingAtPath: p) {
                    let limit = 400_000
                    let data = handle.readData(ofLength: limit)
                    try? handle.close()
                    if data.contains(0) {
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
