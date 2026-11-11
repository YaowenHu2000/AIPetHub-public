import Cocoa
import WebKit

// 文档预览：Word、Excel、PPT 等先用系统的 Quick Look 转成网页（rtf、odt 用系统文本引擎转），
// 再放进内置浏览器显示——和访达里按空格看到的一样，文字可以选中复制。
// 转出来的网页缓存在 ~/Library/Caches/AIPetHub/DocPreview：原文件没变就直接用，变了重新生成，旧的自动清掉。

/// Quick Look（系统自带的 Office 预览器）能转成网页的格式。
/// .dot、.pot、.key 不算：常见的是 Graphviz、翻译模板、密钥这些文本文件，照常按文本预览。
let quickLookDocExts: Set<String> = ["doc", "docx", "docm", "dotx", "dotm", "xls", "xlsx", "xlsm", "xlt", "xltx", "xltm",
                                     "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "potx", "potm"]
/// Quick Look 不转网页的富文本，用 NSAttributedString 转。
let richTextDocExts: Set<String> = ["rtf", "odt"]
private let wordLikeExts: Set<String> = ["doc", "docx", "docm", "dotx", "dotm", "rtf", "odt"]
private let slideLikeExts: Set<String> = ["ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "potx", "potm"]

func isPreviewDocument(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return quickLookDocExts.contains(ext) || richTextDocExts.contains(ext)
}

let docPreviewRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AIPetHub/DocPreview", isDirectory: true)
private let docPreviewVersion = "v2"                  // 改了加进网页的样式就加一，旧缓存自动作废
private let docPreviewKeep = 12                       // 最多留几份
private let docPreviewMaxAge: TimeInterval = 3 * 86400   // 几天没看就删

/// 加进预览网页的东西：不联网（文档里的外链图片之类不加载，和 Quick Look 一样）。
private let previewCSP = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src file: data: blob: 'unsafe-inline' 'unsafe-eval'\">"
/// 比面板宽就整体缩小到面板宽度（Word 页面、PPT 幻灯片是固定宽度的）。
private let previewFit = "<script>(function(){function fit(){var b=document.body;if(!b)return;b.style.zoom='';"
    + "var d=document.documentElement,w=Math.max(d.scrollWidth,b.scrollWidth),v=d.clientWidth;"
    + "if(w>v+1)b.style.zoom=String(Math.max(0.2,Math.floor((v-2)/w*1000)/1000));}"
    + "document.addEventListener('DOMContentLoaded',fit);addEventListener('load',fit);addEventListener('resize',fit);})();</script>"
/// 文档阅读器的样子：深色底上居中的白色页面 / 幻灯片。
private let wordStyle = "<style>html{background:#2a2838}body{margin:0!important;padding:14px 0}"
    + "body>div:first-of-type{margin:0 auto!important;background:#fff;box-shadow:0 2px 10px rgba(0,0,0,.35)}</style>"
private let slideStyle = "<style>html,body{background:#2a2838!important}body{margin:0;padding:6px 0}"
    + "div.slide{background:#fff;margin-left:auto!important;margin-right:auto!important;margin-bottom:10px;box-shadow:0 2px 10px rgba(0,0,0,.35)!important}</style>"

private func fnv1a(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}

/// 把几段标记插到 <head> 最前面（没有 head 就放在 <html> 后面，都没有就放最前面）。
func injectHead(_ html: String, _ extra: String) -> String {
    for tag in ["<head", "<html"] {
        var from = html.startIndex
        while let r = html.range(of: tag, options: .caseInsensitive, range: from..<html.endIndex) {
            if let c = html[r.upperBound...].first, c == ">" || c.isWhitespace, let end = html[r.upperBound...].firstIndex(of: ">") {
                let after = html.index(after: end)
                return String(html[..<after]) + extra + String(html[after...])
            }
            from = r.upperBound   // <header> 之类，接着找
        }
    }
    return extra + html
}

/// 生成（或直接用缓存的）预览，返回在浏览器里打开的文件；失败返回原因。在后台队列调用。
func makeDocumentPreview(_ path: String) -> (file: URL?, error: String) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path) else { return (nil, "文件不存在") }
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    try? fm.createDirectory(at: docPreviewRoot, withIntermediateDirectories: true)
    let dir = docPreviewRoot.appendingPathComponent(fnv1a("\(docPreviewVersion)|\(path)|\(mtime)|\(size)"), isDirectory: true)
    if let file = previewEntry(in: dir) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)   // 刚用过，清理时留着
        return (file, "")
    }
    try? fm.removeItem(at: dir)   // 残缺的旧缓存

    let tmp = docPreviewRoot.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let ext = (path as NSString).pathExtension.lowercased()
    let stage: URL
    if richTextDocExts.contains(ext) {
        guard let html = richTextHTML(path, ext: ext) else { return (nil, "读不出这个文档的内容") }
        stage = tmp.appendingPathComponent("doc", isDirectory: true)
        try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
        guard (try? html.write(to: stage.appendingPathComponent("Preview.html"), atomically: true, encoding: .utf8)) != nil else { return (nil, "写不了缓存") }
    } else {
        switch runQuickLook(path, into: tmp) {
        case .success(let out): stage = out
        case .failure(let e): return (nil, e.message)
        }
        guard previewEntry(in: stage) != nil else { return (nil, "系统预览没有给出可显示的内容") }
        decorateQuickLookHTML(in: stage, ext: ext)
    }
    try? path.write(to: stage.appendingPathComponent(".origin"), atomically: true, encoding: .utf8)
    if (try? fm.moveItem(at: stage, to: dir)) == nil, previewEntry(in: dir) == nil { return (nil, "写不了缓存") }   // 同时生成的另一份先到了也算成功
    pruneDocumentPreviews()
    return (previewEntry(in: dir), "")
}

/// 预览文件夹里要打开的那个文件。
func previewEntry(in dir: URL) -> URL? {
    let fm = FileManager.default
    for name in ["Preview.html", "Preview.pdf", "Preview.png", "Preview.jpg", "Preview.jpeg", "Preview.gif", "Preview.tiff"] {
        let u = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: u.path) { return u }
    }
    return nil
}

/// 这个网址是哪个原文件的预览（不是预览就返回 nil）。
func documentPreviewOrigin(_ url: URL?) -> String? {
    guard let url = url, url.isFileURL else { return nil }
    let root = docPreviewRoot.standardizedFileURL.path + "/"
    let p = url.standardizedFileURL.path
    guard p.hasPrefix(root), let key = p.dropFirst(root.count).split(separator: "/").first else { return nil }
    let origin = try? String(contentsOf: docPreviewRoot.appendingPathComponent(String(key)).appendingPathComponent(".origin"), encoding: .utf8)
    return origin?.isEmpty == false ? origin : nil
}

private struct PreviewFailure: Error { let message: String }

/// qlmanage -p -o：Quick Look 的命令行入口，把预览输出成文件（Preview.html + 附件）而不弹窗。
private func runQuickLook(_ path: String, into tmp: URL) -> Result<URL, PreviewFailure> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    p.arguments = ["-p", "-o", tmp.path, path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return .failure(PreviewFailure(message: "调用不了系统预览（qlmanage）")) }
    if done.wait(timeout: .now() + 60) == .timedOut {
        p.terminate()
        return .failure(PreviewFailure(message: "生成预览超时（文件太大或格式异常）"))
    }
    guard let name = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.first(where: { $0.hasSuffix(".qlpreview") }) else {
        return .failure(PreviewFailure(message: "系统预览打不开这个文件（可能已损坏或格式不支持）"))
    }
    return .success(tmp.appendingPathComponent(name, isDirectory: true))
}

/// Quick Look 给的网页加上不联网的限制；主页面再加缩放和阅读器样式。
private func decorateQuickLookHTML(in dir: URL, ext: String) {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.lowercased().hasSuffix(".html") {
        let u = dir.appendingPathComponent(name)
        guard let html = try? String(contentsOf: u, encoding: .utf8) else { continue }
        var extra = previewCSP
        if name == "Preview.html" {
            extra += previewFit
            if wordLikeExts.contains(ext) { extra += wordStyle }
            if slideLikeExts.contains(ext) { extra += slideStyle }
        }
        try? injectHead(html, extra).write(to: u, atomically: true, encoding: .utf8)
    }
}

/// rtf、odt：用系统文本引擎读出来再存成网页。
private func richTextHTML(_ path: String, ext: String) -> String? {
    let type: NSAttributedString.DocumentType = ext == "odt" ? .openDocument : .rtf
    guard let s = try? NSAttributedString(url: URL(fileURLWithPath: path), options: [.documentType: type], documentAttributes: nil),
          let data = try? s.data(from: NSRange(location: 0, length: s.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                      .characterEncoding: String.Encoding.utf8.rawValue]),
          let html = String(data: data, encoding: .utf8) else { return nil }
    let page = "<style>html{background:#2a2838}body{box-sizing:border-box;width:760px;max-width:100%;min-height:calc(100vh - 28px);"
        + "margin:14px auto!important;padding:48px 56px;background:#fff;color:#000;box-shadow:0 2px 10px rgba(0,0,0,.35)}</style>"
    return injectHead(html, previewCSP + page)
}

/// 清掉旧的预览：最多留 docPreviewKeep 份，几天没看的删掉；没生成完的临时文件夹也清掉。
func pruneDocumentPreviews() {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: docPreviewRoot.path) else { return }
    var entries: [(url: URL, date: Date)] = []
    for n in names {
        let u = docPreviewRoot.appendingPathComponent(n)
        let date = ((try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date) ?? .distantPast
        if n.hasPrefix(".tmp-") {
            if Date().timeIntervalSince(date) > 600 { try? fm.removeItem(at: u) }
            continue
        }
        if n.hasPrefix(".") { continue }
        entries.append((u, date))
    }
    entries.sort { $0.date > $1.date }
    for (i, e) in entries.enumerated() where i >= docPreviewKeep || Date().timeIntervalSince(e.date) > docPreviewMaxAge {
        try? fm.removeItem(at: e.url)
    }
}
