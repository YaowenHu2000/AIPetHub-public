// 发送、补充和从历史恢复原图时，交给 CLI 和网页的文件必须指向同一份内容。
//
// 对话里的图片在这里准备。
// 首问和补充都先取得按原路径和内容命名的文件，再交给 CLI。
// 网页保留有序的附件来源，`sentAttachments` 供当前气泡、铅笔、队列转正和重试使用；活动页重载时原生桥补发同一份路径对应关系。
// 历史的 `path` 用于显示与访达定位，`snapshot` 和 `ref` 才指向当次内容，查看器的「用默认应用打开」也交这一份（只在记录里的先落成副本）。
// 铅笔带回的副本在附件栏仍显示原文件名和原路径；再拖入或选中同一原图时，原生按发送的规则冻结它，内容没变就得到同一副本、不重复附上。
// 恢复记录引用时按原附件序号插回，缺图会提示。
// 正文提及的路径只作预览。
// 单次 CLI 的新提问把图片路径放在明确的附件段，旧记录仍可按本机补记核对。
// 单次模式和本机补记的失败轮只在历史里留下路径，这些快照另存在 `~/Library/Application Support/AIPetHub/aipethub-sent-images/`（命名同临时快照），
// 系统清理临时目录后历史仍能打开当时那张。
// Claude、Gemini 收到的大图是缩过的，记录里也只有那份；临时目录里按缩图的内容键另记一个 `<键>.full` 指向完整副本，
// 重开历史点开原图、编辑和重试都和实时一样用完整分辨率（Codex 历史本来就指向副本，DeepSeek 存的是原件）。
import Cocoa
import CryptoKit
import UniformTypeIdentifiers

extension AppDelegate {
    /// 能当附件发的图片：文件在、是常见图片格式。
    func isAttachableImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        var directory: ObjCBool = false
        return chatImageExts.contains(ext) && fm.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && fm.isReadableFile(atPath: path)
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
        let base64 = jpeg.base64EncodedString()
        // Claude、Gemini 的记录里只存下缩过的这份；按它的内容键记下发送时的完整副本，重开历史点开原图仍是完整分辨率（fullSentImage）
        if isSentImageFile(path) { try? path.write(toFile: sentImagesRoot + chatImageKey(base64) + ".full", atomically: true, encoding: .utf8) }
        return ("image/jpeg", base64)
    }

    /// attachmentData 缩过的图按内容键找回发送时的完整副本。CLI 落库时又重编码过、或系统清掉了临时目录时找不到，
    /// 查看器照旧显示记录里那份。
    func fullSentImage(key: String) -> String? {
        guard let path = try? String(contentsOfFile: sentImagesRoot + key + ".full", encoding: .utf8),
              isSentImageFile(path), fm.isReadableFile(atPath: path) else { return nil }
        return path
    }

    private var sentImagesRoot: String { hooks.sentImagesDir ?? NSTemporaryDirectory() + "aipethub-sent-images/" }

    /// 图片字节写成临时文件：Codex 只收文件路径。按内容（和原路径）命名，同一张图重发不会越积越多；放系统临时目录，由系统清理。
    /// origin：这张图原来的路径，记在旁边的 .origin 文件里，历史里按它显示原文件名和路径（sentImageOrigin）。
    /// directory：放到别处（单次模式的持久副本，见 durableImagePaths）；不给就是系统临时目录。
    func temporaryImageFile(_ data: Data, ext: String, origin: String? = nil, directory: String? = nil) -> String? {
        let dir = directory ?? hooks.sentImagesDir ?? NSTemporaryDirectory() + "aipethub-sent-images/"
        var hash = SHA256()
        hash.update(data:Data((origin ?? "").utf8))
        hash.update(data:data)
        let name = hash.finalize().map { String(format:"%02x", $0) }.joined()
        let path = dir + name + "." + ext
        if fm.fileExists(atPath:path), origin == nil || fm.fileExists(atPath:path + ".origin") { return path }
        do {
            try fm.createDirectory(atPath:dir, withIntermediateDirectories:true)
            // 两个实例可能同时发送同一张图，先公布显示名，读到快照的那一方才能立即还原原路径。
            if let origin { try origin.write(toFile:path + ".origin", atomically:true, encoding:.utf8) }
            if !fm.fileExists(atPath:path) { try data.write(to:URL(fileURLWithPath:path), options:.atomic) }
            return path
        } catch { return nil }
    }

    /// 单次模式（Claude、Codex、Gemini 退回单次 CLI）的历史只有提问里写的路径，临时目录被系统清掉后就再也找不回那张图；
    /// 这时把快照另存一份到不会被清理的目录。命名规则同临时快照，同一张图重发不会越积越多。
    /// 存不下时沿用原来那份，这一轮照常发送。
    var durableSentImagesDir: String {
        hooks.durableSentImagesDir ?? "\(home)/Library/Application Support/AIPetHub/aipethub-sent-images/"
    }

    func durableImagePaths(_ paths: [String]) -> [String] {
        paths.map { path in
            guard isSentImageFile(path), let data = fm.contents(atPath: path) else { return path }
            return temporaryImageFile(data, ext: (path as NSString).pathExtension, origin: sentImageOrigin(path),
                                      directory: durableSentImagesDir) ?? path
        }
    }

    /// temporaryImageFile 写出的文件原来是哪张图；不是它写的、或没记原路径时为 nil。
    func sentImageOrigin(_ path: String) -> String? {
        guard path.contains("/aipethub-sent-images/") else { return nil }
        return (try? String(contentsOfFile: path + ".origin", encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Codex 自己认得、不用转换就能发的格式（中途补图据此决定要不要放到后台转，见 CodexLiveTurn.steer）。
    func codexReadsImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
    }

    /// 交给 Codex 的图片路径：它认不出 HEIC、TIFF、BMP（只收到「图片无法处理」的占位文字），这些先按 attachmentData 转成 JPEG。
    /// 转不了返回 nil，由调用方在发送前告诉用户。
    func codexImagePath(_ path: String) -> String? {
        if codexReadsImage(path) { return path }
        hooks.codexImageConverting?()
        guard let jpeg = attachmentData(path).flatMap({ Data(base64Encoded: $0.base64) }) else { return nil }
        return temporaryImageFile(jpeg, ext: "jpg", origin: sentImageOrigin(path) ?? path)
    }

    /// 单次 CLI 只保存文字。新记录有明确的附件段，旧记录须与本机补记的完整提问和路径一致才可认领。
    func restorePathAttachments(_ message: inout [String:Any], textKey: String, ending: [String:Any]? = nil) {
        guard (message["imageSources"] as? [[String:Any]])?.isEmpty != false,
              let text = message[textKey] as? String else { return }
        let paths: [String]
        if let range = text.range(of:AskRequest.imagePathHeader, options:.backwards) {
            paths = text[range.upperBound...].components(separatedBy:"\n")
            guard paths.allSatisfy(isSentImageFile) else { return }
            message[textKey] = String(text[..<range.lowerBound])
        } else if let prompt = ending?["prompt"] as? String, let saved = ending?["images"] as? [String], !saved.isEmpty,
                  text == prompt + "\n\n" + saved.joined(separator:"\n") {
            paths = saved
            message[textKey] = prompt
        } else { return }
        message["imageSources"] = paths.map { ["path":$0] }
    }

    /// 首问、补充和编辑共用同一份按内容命名的文件；显示名只用于界面，不能再拿它读原图。
    func sentImagePaths(_ paths: [String]) -> [String:String]? {
        var copies = [String:String]()
        for path in paths where copies[path] == nil {
            if isSentImageFile(path), fm.isReadableFile(atPath:path) {
                copies[path] = path
            } else {
                guard isAttachableImage(path), let data = fm.contents(atPath:path),
                      let copy = temporaryImageFile(data, ext:(path as NSString).pathExtension, origin:path) else { return nil }
                copies[path] = copy
            }
        }
        return copies
    }

    func isSentImageFile(_ path: String) -> Bool {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        let root = hooks.sentImagesDir ?? NSTemporaryDirectory() + "aipethub-sent-images/"
        let dir = URL(fileURLWithPath:path).deletingLastPathComponent().standardizedFileURL.path
        return [root, durableSentImagesDir].contains { dir == URL(fileURLWithPath:$0).standardizedFileURL.path }
    }

    func readableSnapshot(_ ref: [String:Any]) -> String? {
        guard let path = ref["snapshot"] as? String, isSentImageFile(path), fm.isReadableFile(atPath:path) else { return nil }
        return path
    }

    /// 外部 CLI 内嵌的数据和从记录中恢复的原图都没有可依赖的文件扩展名。
    func temporaryImageFile(_ data: Data, origin: String? = nil) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) as String?,
              let ext = UTType(uti)?.preferredFilenameExtension else { return nil }
        return temporaryImageFile(data, ext:ext, origin:origin)
    }

    /// 原路径通过指纹校验时仍要冻结后再交给编辑器，用户可能隔很久才按发送。
    func restoredImagePath(_ ref: [String: Any]) -> String? {
        if let copy = readableSnapshot(ref) { return copy }
        guard let data = sentImageData(ref) else { return nil }
        let id = ref["id"] as? String
        let codexPath = id?.replacingOccurrences(of: "#\\d+(@[^/]*)?$", with:"", options:.regularExpression)
        let path = ref["path"] as? String ?? (ref["agent"] as? String == "gpt" && codexPath?.hasPrefix("/") == true ? codexPath : nil)
        return temporaryImageFile(data, origin:path.map { sentImageOrigin($0) ?? $0 })
    }

    /// 老页面只附引用，新页面记录混合来源的原位置。发送和铅笔共用这个顺序，缺一张就整句失败。
    func resolveImageRefs(_ refs: [[String:Any]], among paths: [String]) -> (paths:[String], restored:[String])? {
        var ordered = paths, restored = [String]()
        for ref in refs {
            guard let path = restoredImagePath(ref) else { return nil }
            ordered.insert(path, at:max(0,min(ref["index"] as? Int ?? ordered.count,ordered.count)))
            restored.append(path)
        }
        return (ordered,restored)
    }
}
