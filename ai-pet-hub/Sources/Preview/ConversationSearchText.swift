// 搜索复用网页的 Markdown 渲染，避免把链接地址、排版标记当成页面上的正文。
import Cocoa
import JavaScriptCore

final class ConversationSearchText {
    // 历史解析、Markdown/公式或图片标签改变可见文字时加一，使旧的落盘正文重新计算。
    static let version = 9
    private let context: JSContext?
    private unowned let app: AppDelegate
    private var cwd = ""
    private(set) var dependencies: [String: String] = [:]
    init(app: AppDelegate) {
        self.app = app
        let ctx = JSContext()
        let root = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web")
        ctx?.evaluateScript("var window = this; var UI = {file: '', copy: ''}; function baseName(s) { return s.split('/').pop(); } function dirOf(p) { return p.replace(/\\/[^/]*$/, '') || '/'; } function cleanPath(p) { return p.replace(/^file:\\/\\//, '').replace(/:\\d+(:\\d+)?$/, ''); }")
        for file in ["vendor/katex/katex.min.js", "vendor/katex/contrib/mhchem.min.js", "js/chat/messages.js", "js/preview/highlight.js", "js/core/markdown.js"] {
            guard let source = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { context = nil; return }
            ctx?.evaluateScript(source)
            if ctx?.exception != nil { context = nil; return }
        }
        ctx?.evaluateScript(#"""
            function searchDecode(text) {
              return text.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (all, ent) => {
                if (ent[0] === '#') return String.fromCodePoint(parseInt(ent.slice(ent[1].toLowerCase() === 'x' ? 2 : 1), ent[1].toLowerCase() === 'x' ? 16 : 10));
                return ({amp:'&',lt:'<',gt:'>',quot:'"',apos:"'",nbsp:'\u00a0'})[ent.toLowerCase()] || all;
              });
            }
            function searchVisibleHTMLText(html) {
              const transparent = [];
              return searchDecode(html.replace(/<span class="katex-mathml">[\s\S]*?<\/math><\/span>/g, '')
                .replace(/<[^>]*>|[^<]+/g, part => {
                  if (/^<span\b/.test(part)) {
                    const style = part.match(/\bstyle="([^"]*)"/)?.[1] || '';
                    // phantom 只留空间；普通透明父节点内显式换回颜色的文字仍可见。
                    const color = style.match(/(?:^|;)\s*color\s*:\s*([^;]+)/i)?.[1];
                    transparent.push(color === undefined ? !!transparent.at(-1) : color.trim().toLowerCase() === 'transparent');
                    return '';
                  }
                  if (/^<\/span\b/.test(part)) { transparent.pop(); return ''; }
                  return transparent.at(-1) || part.startsWith('<') ? '' : part;
                }));
            }
            var searchDirs = [], searchFiles = [], searchCwd = '';
            function searchBeginMessage(files, cwd) { searchDirs = []; searchFiles = files; searchCwd = cwd; }
            function searchRichText(text, loadImages) {
              const html = renderRich(text).replace(/<pre\b[\s\S]*?<\/pre>|<code\b[^>]*>([\s\S]*?)<\/code>|<span class="file-chip"([^>]*)>([\s\S]*?)<\/span><\/span>|<span class="file-maybe"([^>]*)>([\s\S]*?)<\/span>/g,
                (whole, code, chipAttrs, chipBody, maybeAttrs) => {
                  if (whole.startsWith('<pre')) return whole;
                  if (code !== undefined) { noteCodeDirectory(searchDirs, searchDecode(code.replace(/<[^>]*>/g, ''))); return whole; }
                  const attrs = chipAttrs ?? maybeAttrs;
                  const path = searchDecode(attrs.match(/data-path="([^"]*)"/)?.[1] || '');
                  const plan = fileReferencePlan(path, chipAttrs !== undefined, searchFiles, searchDirs, searchCwd);
                  if (plan.edited || chipAttrs === undefined || searchFileExists(path, plan.dirs)) return whole;
                  return /data-src="link"/.test(attrs) ? whole : '<code>' + escapeHtml(path) + '</code>';
                });
              const visible = loadImages ? html.replace(/<img\b[^>]*>/g, tag => {
                const raw = tag.match(/\bdata-local="([^"]*)"/)?.[1];
                if (raw === undefined || searchImageReadable(searchDecode(raw))) return tag;
                const alt = tag.match(/\balt="([^"]*)"/)?.[1] || raw;
                return '［图片：' + alt + '］';
              }) : html;
              return searchVisibleHTMLText(visible);
            }
            """#)
        context = ctx?.exception == nil ? ctx : nil
        let exists: @convention(block) (String, [String]) -> Bool = { [weak self] raw, dirs in
            guard let self = self else { return false }
            for base in [self.cwd] + dirs.map({ self.app.resolvePath($0, base: self.cwd) }) {
                self.record(raw, base: base)
                let path = self.app.resolvePath(raw, base: base)
                var directory: ObjCBool = false
                if self.app.fm.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue { return true }
            }
            return false
        }
        context?.setObject(exists, forKeyedSubscript: "searchFileExists" as NSString)
        let imageReadable: @convention(block) (String) -> Bool = { [weak self] raw in
            guard let self = self else { return false }
            self.record(raw, base: self.cwd)
            let path = (self.app.resolvePath(raw, base: self.cwd) as NSString).resolvingSymlinksInPath
            self.record(path, base: self.cwd)
            return self.app.previewImageData(at: path) != nil
        }
        context?.setObject(imageReadable, forKeyedSubscript: "searchImageReadable" as NSString)
    }
    /// resolvePath 会依次尝试原样、链接片段/编码、行号；创建任一候选都能改变最终可见标签。
    private func record(_ raw: String, base: String) {
        func absolute(_ value: String) -> String {
            if value.hasPrefix("file://"), let url = URL(string: value) { return url.path }
            let expanded = (value as NSString).expandingTildeInPath
            return ((expanded.hasPrefix("/") ? expanded : (base.isEmpty ? app.home : base) + "/" + expanded) as NSString).standardizingPath
        }
        let clean = trimmed(raw)
        let linked = String(clean.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        for candidate in [absolute(clean), absolute(linked.removingPercentEncoding ?? linked), app.resolvePath(raw, base: base)] {
            dependencies[candidate] = conversationSearchFileStamp(candidate)
            let withoutLine = candidate.replacingOccurrences(of: #":[0-9]+(:[0-9]+)?$"#, with: "", options: .regularExpression)
            dependencies[withoutLine] = conversationSearchFileStamp(withoutLine)
        }
    }
    /// 图片是否存在会决定路径保留原文还是换成短标签；解析前先记录来源，之后的缩略图不会带齐缺失路径。
    func prepare(_ messages: [[String: Any]], cwd: String) {
        self.cwd = cwd
        dependencies = [:]
        func images(_ message: [String: Any], text: String) {
            for source in message["imageSources"] as? [[String: Any]] ?? [] {
                if let path = source["path"] as? String { record(path, base: cwd) }
            }
            for mention in imagePathMentions(text) { record(mention.path, base: cwd) }
        }
        for message in messages {
            if message["role"] as? String == "user" { images(message, text: message["text"] as? String ?? "") }
            for step in message["steps"] as? [[String: Any]] ?? [] where step["kind"] as? String == "user" {
                images(step, text: step["detail"] as? String ?? "")
            }
        }
    }
    var available: Bool { context != nil }
    private func rich(_ text: String, loadImages: Bool = false) -> String {
        context?.objectForKeyedSubscript("searchRichText")?.call(withArguments: [text, loadImages])?.toString() ?? text
    }
    private func user(_ message: [String: Any], key: String) -> String {
        var text = message[key] as? String ?? ""
        let images = message["images"] as? [[String: Any]] ?? []
        var missing: [String] = []
        for image in images {
            let name = (image["name"] as? String) ?? ((image["path"] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
            if image["missing"] as? Bool == true { missing.append("图片已不在：" + (name.isEmpty ? "原文件已删除" : name)) }
            if let match = image["match"] as? String { text = text.replacingOccurrences(of: match, with: name.isEmpty ? match : name) }
        }
        return (missing + [text]).joined(separator: "\n")
    }
    /// 和定位选中的正文节点一致：工具标题、详情、输出包含在内，拷贝等控件标签不参与。
    func messages(_ messages: [[String: Any]]) -> [String] {
        messages.map { message in
            context?.objectForKeyedSubscript("searchBeginMessage")?.call(withArguments: [message["files"] as? [[String: Any]] ?? [], cwd])
            let text = message["text"] as? String ?? ""
            if message["role"] as? String == "user" {
                if trimmed(text).range(of: #"^/(compact|compress)$"#, options: .regularExpression) != nil { return "" }
                return user(message, key: "text")
            }
            var pieces: [String] = []
            for step in message["steps"] as? [[String: Any]] ?? [] {
                let kind = step["kind"] as? String ?? ""
                let detail = step["detail"] as? String ?? ""
                if kind == "text" { pieces.append(rich(detail)); continue }
                if kind == "user" { pieces += ["你补充说", user(step, key: "detail")]; continue }
                pieces.append(step["title"] as? String ?? "")
                if kind == "command", !detail.isEmpty { pieces.append(String(detail.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")) }
                if !detail.isEmpty, kind != "command" || detail.contains("\n") { pieces.append(detail) }
                if let output = step["output"] as? String, !output.isEmpty { pieces.append(output) }
            }
            if !text.isEmpty { pieces.append(rich(text, loadImages: true)) }
            return pieces.joined(separator: "\n")
        }
    }

}

func conversationSearchFileStamp(_ path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
    return "\(attributes[.type] ?? ""):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes[.size] ?? 0)"
}

/// 按会话和来源指纹保存可见文字；不同查询共享结果，容量按 UTF-8 总字节限制。
final class ConversationSearchCache {
    static let shared = ConversationSearchCache()
    struct Entry {
        let stamp: String
        let texts: [String]
        let item: [String: Any]
        let dependencies: [String: String]
        let individualStamp: String?
        let databaseRevision: String?
        let bytes: Int
        var used: UInt64
        init(stamp: String, texts: [String], item: [String: Any], dependencies: [String: String],
             individualStamp: String?, databaseRevision: String?) {
            self.stamp = stamp; self.texts = texts; self.item = item; self.dependencies = dependencies
            self.individualStamp = individualStamp; self.databaseRevision = databaseRevision; used = 0
            bytes = texts.reduce(0) { $0 + $1.utf8.count } + stamp.utf8.count
                + (individualStamp?.utf8.count ?? 0) + (databaseRevision?.utf8.count ?? 0)
                + ((try? JSONSerialization.data(withJSONObject: item).count) ?? 0)
                + dependencies.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0
    let limit: Int
    let disk: ConversationSearchDiskCache?
    init(limit: Int = 96 * 1024 * 1024, disk: ConversationSearchDiskCache? = ConversationSearchDiskCache()) {
        self.limit = limit; self.disk = disk
    }
    private func store(_ key: String, _ value: Entry) {
        if let old = entries.removeValue(forKey: key) { bytes -= old.bytes + key.utf8.count }
        let size = value.bytes + key.utf8.count
        guard size <= limit else { return }
        while bytes + size > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            bytes -= entries.removeValue(forKey: oldest)!.bytes + oldest.utf8.count
        }
        clock += 1
        var entry = value; entry.used = clock; entries[key] = entry; bytes += size
    }
    private func load(_ key: String) {
        lock.lock(); let present = entries[key] != nil; lock.unlock()
        guard !present, let entry = disk?.read(key) else { return }
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil { store(key, entry) }
    }
    func get(_ key: String, stamp: String) -> Entry? {
        load(key)
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key], entry.stamp == stamp,
              entry.dependencies.allSatisfy({ conversationSearchFileStamp($0.key) == $0.value }) else { return nil }
        clock += 1; entry.used = clock; entries[key] = entry
        disk?.touch(key)
        return entry
    }
    func revalidationCandidate(_ key: String, individualStamp: String) -> Entry? {
        load(key)
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[key], entry.databaseRevision != nil, entry.individualStamp == individualStamp,
              entry.dependencies.allSatisfy({ conversationSearchFileStamp($0.key) == $0.value }) else { return nil }
        return entry
    }
    func put(_ key: String, stamp: String, texts: [String], item: [String: Any], dependencies: [String: String] = [:],
             individualStamp: String? = nil, databaseRevision: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(stamp: stamp, texts: texts, item: item, dependencies: dependencies,
                          individualStamp: individualStamp, databaseRevision: databaseRevision)
        store(key, entry)
        disk?.write(key, entry: entry)
    }
}

/// 输入换词时旧搜索马上让位，避免它占用各家的历史载入串行队列。
final class ConversationSearchRequests {
    static let shared = ConversationSearchRequests()
    private let lock = NSLock()
    private var latest: [String: UUID] = [:]
    private func key(_ app: AppDelegate, _ agent: String) -> String { "\(ObjectIdentifier(app)):\(agent)" }
    func begin(_ app: AppDelegate, agent: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let request = UUID(); latest[key(app, agent)] = request; return request
    }
    func current(_ app: AppDelegate, agent: String, request: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return latest[key(app, agent)] == request
    }
}
