// 用 git 找出一轮回答里被命令改动的文件（CLI 只报「改文件工具」的改动）。
//
// 显式选择的普通目录最多检查 2048 个条目，比对单个最多 1 MB、合计 16 MB 的普通文件；改回原文且权限相同的工具路径从改动卡剔除，其余标为工具累计编辑。
// 撤销 Git 忽略规则后，原来在忽略范围内的文件标为「本轮纳入比较」，不计新增行；忽略项随状态按 `--ignored=matching` 列出，目录里只是恰好全是被忽略的文件时，
// 旁边新建的文件仍算新建。
// 拍摄 Git 工作区快照时，干净且没有过滤文件的叶子子模块直接使用提交树，保留从干净到修改时的完整补丁。
//
// 改动卡片：CLI 的改文件工具报告的文件，加上工作目录是 git 仓库时回答前后各拍一张内容快照、取两者之差（仅由快照发现的路径标为「同期工作区改动」，其中也可能包含用户自己保存的文件；
// 回答之前就有的未提交修改不算进来，改回干净、删掉未跟踪文件也能报出）。
//
// 快照用临时的 index 和对象目录，不碰仓库的 index、HEAD、stash；大的未跟踪文件只记指纹，只暂存或只取消暂存、内容和模式没变的大文件不报。
// 已签出的子模块单独拍工作树快照，按子模块内的文件路径报告本轮改动。
// 完整快照通过 Git numstat 汇总所有路径的增删行数，超过 60 个文件时，卡片和预览注明总数并展示前 60 个。
import Cocoa
import CryptoKit

extension AppDelegate {
    // CLI 只会把「改文件工具」的改动报出来；命令改的文件用前后内容快照补上，失败再退回状态对比。
    struct GitSnapshot {
        let root: String
        let entries: [String: String]   // 快照失败时仍沿用旧的状态对比
        var content: GitContentSnapshot? = nil
    }

    func runGit(_ args: [String], in dir: String, environment: [String: String] = [:]) -> String? {
        gitPathLock.lock(); let executable = gitPath; gitPathLock.unlock()
        guard let git = executable else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"   // status 不得顺手刷新用户的真实 index
        env.merge(environment) { _, new in new }
        let res = runTool(git, ["-C", dir] + args, cwd: home,
                          environment: env, timeout: 60)
        return res.status == 0 ? res.out : nil
    }

    private func snapshotConfig(_ root: String) -> [String] {
        var config = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false", "-c", "diff.ignoreSubmodules=dirty"]
        let filters = runGit(["config", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"], in: root) ?? ""
        for key in filters.split(separator: "\n") {
            config += ["-c", String(key) + (key.hasSuffix(".required") ? "=false" : "=")]
        }
        return config
    }

    func gitSnapshot(_ dir: String?, submodule: Bool = false) -> GitSnapshot? {
        guard let dir = dir,
              let root = runGit(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty, root != home else { return nil }   // 整个主目录是仓库时不扫
        let config = snapshotConfig(root)
        // 忽略项随状态一起列出，撤掉规则时才能说明比较范围变了。matching 只在目录本身匹配规则时记目录名（不遍历构建产物）；
        // 目录里碰巧只有被忽略的文件时逐个列出，旁边新建的文件就不会被当成原先就在忽略范围里。
        guard let status = runGit(config + ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"], in: root) else { return nil }
        let parts = status.split(separator: "\0").map(String.init)
        let ignored = Set(parts.filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) })
        // 干净的叶子模块已有不可变的提交树，可省去复制索引、重建对象和写树。
        // 嵌套模块还要递归，使用过滤器的文件也仍须按工作树原文比较。
        if submodule, parts.allSatisfy({ $0.hasPrefix("!! ") }),
           !config.contains(where: { $0.hasPrefix("filter.") }) || runGit(config + ["ls-files", "-z", "--", ":(exclude,attr:!filter)"], in:root) == "",
           let tree = runGit(["rev-parse","--verify","HEAD^{tree}"], in:root)?.trimmingCharacters(in:.whitespacesAndNewlines),
           let listing = runGit(["ls-tree","-rz",tree], in:root) {
            let records = listing.split(separator:"\0")
            if !records.contains(where: { $0.hasPrefix("160000 ") }) {
                let content = GitContentSnapshot()
                content.tree = tree
                content.committed = true
                content.ignored = ignored
                content.paths = Set(records.compactMap { $0.split(separator:"\t", maxSplits:1).last.map(String.init) })
                return GitSnapshot(root:root, entries:[:], content:content)
            }
        }
        var entries: [String: String] = [:]
        var i = 0
        while i < parts.count {
            let item = parts[i]
            i += 1
            guard item.count > 3 else { continue }
            let code = String(item.prefix(2))
            if code == "!!" { continue }
            let path = String(item.dropFirst(3))
            if code.hasPrefix("R") || code.hasPrefix("C") { i += 1 }   // 重命名后面跟着原路径
            let attrs = try? fm.attributesOfItem(atPath: root + "/" + path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            entries[path] = "\(code)|\(mtime)|\(attrs?[.size] as? Int ?? -1)"

        }
        let content = gitContentSnapshot(root, entries: entries, config: config)
        content?.ignored = ignored
        return GitSnapshot(root: root, entries: entries, content: content)
    }

    /// 普通目录没有 Git 对象可对照。只记录有限数量的小文件，避免对数据集或主目录做全量读取。
    func plainFileMarks(_ workspace: String?) -> [String: String] {
        guard let workspace else { return [:] }
        let root = (workspace as NSString).resolvingSymlinksInPath
        guard root != home, root != "/", let walk = fm.enumerator(at:URL(fileURLWithPath:root), includingPropertiesForKeys:nil,
                                                                  options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { return [:] }
        var marks: [String:String] = [:], budget = 16_000_000
        var visited = 0
        for case let file as URL in walk {
            visited += 1
            if visited > 2048 { break }
            if ["node_modules","build",".venv"].contains(file.lastPathComponent) { walk.skipDescendants(); continue }
            if let mark = plainFileMark(file.path, budget:&budget) {
                // Foundation 枚举 /var 时可能返回 /private/var，工具路径也会先标准化。
                marks[(file.path as NSString).standardizingPath] = mark
            }
            if budget <= 0 { break }
        }
        return marks
    }

    func plainFileMark(_ path: String, budget: inout Int) -> String? {
        var info = stat()
        guard lstat(path,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= min(budget,1_000_000) else { return nil }
        let fd = open(path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor:fd, closeOnDealloc:true)
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= min(budget,1_000_000) else { return nil }
        let bytes: Data
        do { bytes = try handle.read(upToCount:Int(info.st_size)+1) ?? Data() } catch { return nil }
        guard bytes.count == info.st_size else { return nil }
        budget -= bytes.count
        return "\(info.st_mode):\(SHA256.hash(data:bytes))"
    }

    private func nowIgnored(_ path: String, in root: String) -> Bool {
        var info = stat()
        let full = (root + "/" + path) as NSString
        guard lstat(full.fileSystemRepresentation, &info) == 0 else { return false }
        return runGit(["check-ignore", "-q", "--", "./" + full.lastPathComponent], in:full.deletingLastPathComponent) != nil
    }

    /// 和回答前比，新出现或又变过的文件，带上 diff（新文件把内容当作新增行）。
    func gitChangedFiles(since before: GitSnapshot, toolPaths: Set<String> = [], compared: (Set<String>) -> Void = { _ in }) -> [[String: Any]] {
        guard let after = gitSnapshot(before.root) else { return [] }
        if let old = before.content, let new = after.content,
           let changes = gitContentChanges(root: before.root, before: old, after: new, toolPaths: toolPaths) {
            let prefix = (before.root as NSString).resolvingSymlinksInPath + "/"
            compared(toolPaths.filter { full in
                guard full.hasPrefix(prefix) else { return false }
                let path = String(full.dropFirst(prefix.count))
                guard old.large[path] == nil && new.large[path] == nil else { return false }
                if old.comparable(path) && !new.comparable(path) && nowIgnored(path, in:before.root) { return false }
                if old.comparable(path) || new.comparable(path) { return true }
                var info = stat()
                guard lstat(full, &info) != 0, errno == ENOENT, let git = gitPath else { return false }
                // 两次快照都没有的工具路径可能是先创建再撤销；忽略规则之外才属于快照的范围。
                return runTool(git, ["-C", before.root, "check-ignore", "-q", "--", path], cwd: home, timeout: 10).status == 1
            })
            return changes
        }
        let config = snapshotConfig(before.root)
        var out: [[String: Any]] = []
        for (path, stamp) in after.entries.sorted(by: { $0.key < $1.key }) where before.entries[path] != stamp {
            let code = String(stamp.prefix(2))
            let full = before.root + "/" + path
            let kind = code.contains("?") || code.contains("A") ? "create" : code.contains("D") ? "delete" : "edit"
            var diff = "", createdLines: Int?
            if kind == "create" {
                if let size = (try? fm.attributesOfItem(atPath: full))?[.size] as? Int, size < 200_000,
                   let text = try? String(contentsOfFile: full, encoding: .utf8) {
                    createdLines = lineCount(text)
                    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    if text.hasSuffix("\n") { lines.removeLast() }   // 结尾换行不算一行
                    diff = lines.isEmpty ? "" : "@@ -0,0 +1,\(lines.count) @@\n" + lines.prefix(3000).map { "+" + $0 }.joined(separator: "\n")
                }
            } else {
                let raw = runGit(config + ["diff", "--no-color", "--no-ext-diff", "HEAD", "--", path], in: before.root)
                    ?? runGit(config + ["diff", "--no-color", "--no-ext-diff", "--", path], in: before.root) ?? ""
                if let r = raw.range(of: "\n@@") { diff = String(raw[raw.index(after: r.lowerBound)...]) } else if raw.hasPrefix("@@") { diff = raw }
            }
            let c = createdLines.map { (added: $0, removed: 0) } ?? diffCounts(diff)
            let truncated = diff.count > maxDiff || (createdLines ?? 0) > 3000
            diff = out.count < 60 || toolPaths.contains(full) ? String(diff.prefix(maxDiff)) : ""
            out.append(["path": full, "kind": kind, "added": c.added, "removed": c.removed, "diff": diff, "truncated": truncated])
        }
        return out
    }
}

/// 树和 index 只存在临时目录；对象也不写进用户的 .git，回答结束释放快照即清理。
final class GitContentSnapshot {
    let directory: URL
    var tree = ""
    var committed = false
    var paths = Set<String>()
    var modules: [String: GitContentSnapshot] = [:]
    func comparable(_ path: String) -> Bool {
        if paths.contains(path) { return large[path] == nil }
        for (name, sub) in modules where path.hasPrefix(name + "/") {
            return sub.comparable(String(path.dropFirst(name.count + 1)))
        }
        return false
    }
    var ignored = Set<String>()
    func wasIgnored(_ path: String) -> Bool {
        if ignored.contains(path) { return true }
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if ignored.contains(parent + "/") { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }
    var large: [String: String] = [:]
    var stagedLarge: [String: String] = [:]
    var smallUntracked: [String: String] = [:]
    // 退出时回答线程可能还拿着快照，App 强杀子进程后直接结束，等不到 deinit；按名单删。
    // 只记本实例建的：别的 AIPetHub（窗口测试的副本等）的同名前缀目录可能正在用。
    private static let activeLock = NSLock()
    private static var active = Set<URL>()

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aipethub-git-" + UUID().uuidString)
        Self.activeLock.lock(); Self.active.insert(directory); Self.activeLock.unlock()
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        Self.activeLock.lock(); Self.active.remove(directory); Self.activeLock.unlock()
    }

    /// App 退出、子进程都已结束后调用：删掉还没释放的快照目录。
    static func removeActive() {
        activeLock.lock(); let dirs = active; activeLock.unlock()
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

extension AppDelegate {
    private func gitContentSnapshot(_ root: String, entries: [String: String], config: [String]) -> GitContentSnapshot? {
        let snapshot = GitContentSnapshot()
        let temp = snapshot.directory
        let objects = temp.appendingPathComponent("objects")
        guard let objectPath = runGit(["rev-parse", "--path-format=absolute", "--git-path", "objects"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let indexPath = runGit(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        do {
            try fm.createDirectory(at: objects.appendingPathComponent("info"), withIntermediateDirectories: true)
            try (objectPath + "\n").write(to: objects.appendingPathComponent("info/alternates"), atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: indexPath) { try fm.copyItem(atPath: indexPath, toPath: temp.appendingPathComponent("index").path) }
        } catch { return nil }
        let env = ["GIT_INDEX_FILE": temp.appendingPathComponent("index").path, "GIT_OBJECT_DIRECTORY": objects.path,
                   "GIT_LITERAL_PATHSPECS": "1"]
        // 未跟踪文件每个最多 1 MB，合计最多 16 MB；数据集只记轻量指纹，不批量写对象。
        var budget = 16_000_000
        var add: [String] = []
        for (path, status) in entries.sorted(by: { $0.key < $1.key }) {
            if status.hasPrefix("??") {
                guard let attrs = try? fm.attributesOfItem(atPath: root + "/" + path) else { return nil }
                // 未跟踪的目录只会是嵌套的仓库。不交给 git add：里面一次提交都没有时它直接报错，整张快照就拍不成。
                // 只记一个指纹（目录和它的 index 的修改时间），变了就报「变了」，不出 diff。
                if attrs[.type] as? FileAttributeType == .typeDirectory {
                    let inner = (try? fm.attributesOfItem(atPath: root + "/" + path + ".git/index"))?[.modificationDate] as? Date
                    snapshot.large[path] = "dir|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(inner?.timeIntervalSince1970 ?? 0)"
                    continue
                }
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                let link = attrs[.type] as? FileAttributeType == .typeSymbolicLink
                let executable = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o100 != 0
                let mode = link ? "120000" : executable ? "100755" : "100644"
                var stamp = "\(mode)|\(size)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                // 小文件即使因总预算落选，也用内容比较；预算边界移动不能把没改的文件算成 edit。
                // 链接只哈希链接文字，不能跟随它读入一个巨大的目标。
                if size <= 1_000_000 {
                    let data: Data?
                    if link {
                        data = (try? fm.destinationOfSymbolicLink(atPath: root + "/" + path)).map { Data($0.utf8) }
                    } else { data = fm.contents(atPath: root + "/" + path) }
                    guard let data = data else { return nil }
                    stamp = mode + "|" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    snapshot.smallUntracked[path] = stamp
                }
                if size > 1_000_000 || size > budget {
                    snapshot.large[path] = stamp
                    continue
                }
                budget -= size
                add.append(path)
            } else if (Int(status.split(separator: "|").last ?? "") ?? 0) > 1_000_000,
                      let attrs = try? fm.attributesOfItem(atPath: root + "/" + path),
                      attrs[.type] as? FileAttributeType == .typeRegular {
                // 取消暂存后它会改记成未跟踪大文件的指纹；先按同样格式记下，内容和模式没变时认得出是同一份。
                let mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o100 != 0 ? "100755" : "100644"
                snapshot.stagedLarge[path] = "\(mode)|\((attrs[.size] as? NSNumber)?.intValue ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
        }
        // -u 更新已跟踪文件（含删除、恢复干净）；未跟踪文件单独限额后再加入。
        // 有过滤器时重新读取基线，避免 index 中已过滤的内容与本轮原始内容混比。
        // 先普通更新一遍（把删除也记进去），有过滤器再重新规范化：--renormalize 碰到已经被删掉的已跟踪文件会直接报错退出。
        // 装了 Git LFS 的机器全局就带着过滤器，所以这条路并不少见。
        // status 已忽略子模块内部脏状态；对整棵树 add -u 会让 Git 再次进入子模块执行它自己的过滤器。
        let tracked = entries.filter { !$0.value.hasPrefix("??") && $0.value.dropFirst().first != " " }.map(\.key)
        let modules = tracked.filter { fm.fileExists(atPath: root + "/" + $0 + "/.git") }
        if !modules.isEmpty, runGit(config + ["update-index", "--remove", "--"] + modules, in:root, environment:env) == nil { return nil }
        let files = Set(tracked).subtracting(modules)
        if !files.isEmpty {
            let list = temp.appendingPathComponent("tracked")
            guard (try? Data((files.joined(separator:"\0") + "\0").utf8).write(to:list)) != nil,
                  runGit(config + ["add","-u","--pathspec-from-file=" + list.path,"--pathspec-file-nul"], in:root, environment:env) != nil else { return nil }
        }
        if config.contains(where: { $0.hasPrefix("filter.") }) {
            guard runGit(config + ["add", "--renormalize", "-u"], in: root, environment: env) != nil else { return nil }
        }
        if !add.isEmpty {
            let list = temp.appendingPathComponent("paths")
            guard (try? Data((add.joined(separator: "\0") + "\0").utf8).write(to: list)) != nil,
                  runGit(config + ["add", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"], in: root, environment: env) != nil else { return nil }
        }
        // write-tree 写回 index 时会重新核对刚加进去的文件（修改时间和 index 一样新的那些），核对就要读文件、过过滤器：
        // 所以这两条也要带上「过滤器置空」的配置，否则有副作用的过滤器还是会被运行。
        guard let tree = runGit(config + ["write-tree"], in: root, environment: env)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let paths = runGit(config + ["ls-files", "-z", "--stage"], in: root, environment: env) else { return nil }
        snapshot.tree = tree
        snapshot.paths = Set(snapshot.large.keys)
        for record in paths.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let path = String(record[record.index(after: tab)...])
            snapshot.paths.insert(path)
            // gitlink 只记录提交号，子模块已签出的工作树另拍前后快照才能分出本轮改动。
            if record.hasPrefix("160000 "), fm.fileExists(atPath: root + "/" + path + "/.git") {
                snapshot.modules[path] = gitSnapshot(root + "/" + path, submodule:true)?.content
            }
        }
        return snapshot
    }

    private func gitContentChanges(root: String, before: GitContentSnapshot, after: GitContentSnapshot, toolPaths: Set<String>) -> [[String: Any]]? {
        // 并发回合各用自己的前后快照；重叠期间的改动可以归到双方，这是有意的取舍。
        var env = ["GIT_LITERAL_PATHSPECS": "1"]
        let stores = [before, after].filter { !$0.committed }.map { $0.directory.appendingPathComponent("objects").path }
        env["GIT_OBJECT_DIRECTORY"] = stores.first
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = stores.dropFirst().first
        let args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", before.tree, after.tree]
        // numstat 只跑一次，统计覆盖全部文件；逐文件补丁仍受展示上限约束。
        guard let stats = runGit(args + ["--numstat", "-z"], in: root, environment: env) else { return nil }
        var counts: [String: (Int, Int)] = [:]
        for row in stats.split(separator: "\0") {
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3 { counts[String(fields[2])] = (Int(fields[0]) ?? 0, Int(fields[1]) ?? 0) }
        }
        var changed = Set(counts.keys)
        for path in Set(before.large.keys).union(after.large.keys) where before.large[path] != after.large[path] { changed.insert(path) }
        for (path, hash) in before.smallUntracked where after.smallUntracked[path] == hash { changed.remove(path) }
        // 大文件暂存后改由树保存；沿用拍前快照时的模式、大小和修改时间核对同一文件。
        for (path, stamp) in before.large where after.large[path] == nil && after.paths.contains(path) {
            guard let attrs = try? fm.attributesOfItem(atPath:root + "/" + path),
                  attrs[.type] as? FileAttributeType == .typeRegular else { continue }
            let mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o100 == 0 ? "100644" : "100755"
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if stamp == "\(mode)|\(size)|\(modified)" { changed.remove(path) }
        }
        // 反方向：只取消暂存的大文件改记指纹，和拍前记下的指纹相同就是同一份内容。
        for (path, stamp) in after.large where before.large[path] == nil && before.stagedLarge[path] == stamp { changed.remove(path) }
        var out: [[String: Any]] = []
        let normalizedRoot = (root as NSString).resolvingSymlinksInPath
        // 消失的路径可能只是被新规则排除。限制每批参数长度，补丁名额留给确实有变化的文件。
        let missing = changed.filter { !after.paths.contains($0) }.sorted()
        for start in stride(from: 0, to: missing.count, by: 64) {
            let batch = Array(missing[start..<min(start + 64, missing.count)])
            if let ignored = runGit(["--literal-pathspecs", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--"] + batch, in:root) {
                changed.subtract(ignored.split(separator:"\0").map(String.init))
            }
        }
        for path in changed.sorted() {
            let kind = !before.paths.contains(path) ? (before.wasIgnored(path) ? "included" : "create") : !after.paths.contains(path) ? "delete" : "edit"
            var diff = ""
            var truncated = false
            let known = kind != "included" && before.large[path] == nil && after.large[path] == nil
            if known && (out.count < 60 || toolPaths.contains(normalizedRoot + "/" + path)) {
                guard let raw = runGit(args + ["--", path], in: root, environment: env) else { return nil }
                if let r = raw.range(of: "\n@@") {
                    let patch = raw[raw.index(after: r.lowerBound)...]
                    truncated = patch.count > maxDiff
                    diff = String(patch.prefix(maxDiff))
                }
            }
            let lines = known ? counts[path] ?? (0, 0) : (0, 0)
            out.append(["path": root + "/" + path, "kind": kind, "added": lines.0, "removed": lines.1, "diff": diff, "truncated": truncated])
        }
        for (name, sub) in before.modules {
            if let next = after.modules[name],
               let changes = gitContentChanges(root: root + "/" + name, before: sub, after: next, toolPaths: toolPaths) {
                out += changes
            }
        }
        return out
    }
}
