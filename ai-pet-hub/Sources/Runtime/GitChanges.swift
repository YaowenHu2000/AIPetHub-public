// 用 git 找出一轮回答里被命令改动的文件（CLI 只报「改文件工具」的改动）。
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

    func gitSnapshot(_ dir: String?) -> GitSnapshot? {
        guard let dir = dir,
              let root = runGit(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty, root != home,   // 整个主目录是仓库时不扫
              let status = runGit(["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root) else { return nil }
        var entries: [String: String] = [:]
        let parts = status.split(separator: "\0").map(String.init)
        var i = 0
        while i < parts.count {
            let item = parts[i]
            i += 1
            guard item.count > 3 else { continue }
            let code = String(item.prefix(2))
            let path = String(item.dropFirst(3))
            if code.hasPrefix("R") || code.hasPrefix("C") { i += 1 }   // 重命名后面跟着原路径
            let attrs = try? fm.attributesOfItem(atPath: root + "/" + path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            entries[path] = "\(code)|\(mtime)|\(attrs?[.size] as? Int ?? -1)"

        }
        return GitSnapshot(root: root, entries: entries, content: gitContentSnapshot(root, entries: entries))
    }

    /// 和回答前比，新出现或又变过的文件，带上 diff（新文件把内容当作新增行）。
    func gitChangedFiles(since before: GitSnapshot) -> [[String: Any]] {
        guard let after = gitSnapshot(before.root) else { return [] }
        if let old = before.content, let new = after.content,
           let changes = gitContentChanges(root: before.root, before: old, after: new) { return changes }
        var out: [[String: Any]] = []
        for (path, stamp) in after.entries.sorted(by: { $0.key < $1.key }) where before.entries[path] != stamp {
            let code = String(stamp.prefix(2))
            let full = before.root + "/" + path
            let kind = code.contains("?") || code.contains("A") ? "create" : code.contains("D") ? "delete" : "edit"
            var diff = ""
            if kind == "create" {
                if let size = (try? fm.attributesOfItem(atPath: full))?[.size] as? Int, size < 200_000,
                   let text = try? String(contentsOfFile: full, encoding: .utf8) {
                    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    if text.hasSuffix("\n") { lines.removeLast() }   // 结尾换行不算一行
                    diff = lines.isEmpty ? "" : "@@ -0,0 +1,\(lines.count) @@\n" + lines.prefix(3000).map { "+" + $0 }.joined(separator: "\n")
                }
            } else {
                let raw = runGit(["diff", "--no-color", "--no-ext-diff", "HEAD", "--", path], in: before.root)
                    ?? runGit(["diff", "--no-color", "--no-ext-diff", "--", path], in: before.root) ?? ""
                if let r = raw.range(of: "\n@@") { diff = String(raw[raw.index(after: r.lowerBound)...]) } else if raw.hasPrefix("@@") { diff = raw }
            }
            if diff.count > maxDiff { diff = String(diff.prefix(maxDiff)) }
            let c = diffCounts(diff)
            out.append(["path": full, "kind": kind, "added": c.added, "removed": c.removed, "diff": diff])
            if out.count >= 60 { break }
        }
        return out
    }
}

/// 树和 index 只存在临时目录；对象也不写进用户的 .git，回答结束释放快照即清理。
final class GitContentSnapshot {
    let directory: URL
    var tree = ""
    var paths = Set<String>()
    var large: [String: String] = [:]
    var smallUntracked: [String: String] = [:]
    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aipethub-git-" + UUID().uuidString)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension AppDelegate {
    private func gitContentSnapshot(_ root: String, entries: [String: String]) -> GitContentSnapshot? {
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
                var stamp = "\(size)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
                // 小文件即使因总预算落选，也用内容比较；预算边界移动不能把没改的文件算成 edit。
                // 链接只哈希链接文字，不能跟随它读入一个巨大的目标。
                if size <= 1_000_000 {
                    let data: Data?
                    if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                        data = (try? fm.destinationOfSymbolicLink(atPath: root + "/" + path)).map { Data($0.utf8) }
                    } else { data = fm.contents(atPath: root + "/" + path) }
                    guard let data = data else { return nil }
                    stamp = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    snapshot.smallUntracked[path] = stamp
                }
                if size > 1_000_000 || size > budget {
                    snapshot.large[path] = stamp
                    continue
                }
                budget -= size
                add.append(path)
            }
        }
        // 拍的是工作区内容，不能调用 clean/process 过滤器写 LFS 等外部状态。
        var config = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false"]
        let filters = runGit(["config", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process|required)$"], in: root) ?? ""
        for key in filters.split(separator: "\n") {
            config += ["-c", String(key) + (key.hasSuffix(".required") ? "=false" : "=")]
        }
        // -u 更新已跟踪文件（含删除、恢复干净）；未跟踪文件单独限额后再加入。
        // 有过滤器时重新读取基线，避免 index 中已过滤的内容与本轮原始内容混比。
        // 先普通更新一遍（把删除也记进去），有过滤器再重新规范化：--renormalize 碰到已经被删掉的已跟踪文件会直接报错退出。
        // 装了 Git LFS 的机器全局就带着过滤器，所以这条路并不少见。
        guard runGit(config + ["add", "-u", "--", "."], in: root, environment: env) != nil else { return nil }
        if !filters.isEmpty {
            guard runGit(config + ["add", "--renormalize", "-u", "--", "."], in: root, environment: env) != nil else { return nil }
        }
        if !add.isEmpty {
            let list = temp.appendingPathComponent("paths")
            guard (try? Data((add.joined(separator: "\0") + "\0").utf8).write(to: list)) != nil,
                  runGit(config + ["add", "--pathspec-from-file=" + list.path, "--pathspec-file-nul"], in: root, environment: env) != nil else { return nil }
        }
        // write-tree 写回 index 时会重新核对刚加进去的文件（修改时间和 index 一样新的那些），核对就要读文件、过过滤器：
        // 所以这两条也要带上「过滤器置空」的配置，否则有副作用的过滤器还是会被运行。
        guard let tree = runGit(config + ["write-tree"], in: root, environment: env)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let paths = runGit(config + ["ls-files", "-z", "--cached"], in: root, environment: env) else { return nil }
        snapshot.tree = tree
        snapshot.paths = Set(paths.split(separator: "\0").map(String.init)).union(snapshot.large.keys)
        return snapshot
    }

    private func gitContentChanges(root: String, before: GitContentSnapshot, after: GitContentSnapshot) -> [[String: Any]]? {
        // 并发回合各用自己的前后快照；重叠期间的改动可以归到双方，这是有意的取舍。
        let env = ["GIT_OBJECT_DIRECTORY": before.directory.appendingPathComponent("objects").path,
                   "GIT_ALTERNATE_OBJECT_DIRECTORIES": after.directory.appendingPathComponent("objects").path,
                   "GIT_LITERAL_PATHSPECS": "1"]
        let args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", before.tree, after.tree]
        guard let names = runGit(args + ["--name-only", "-z"], in: root, environment: env) else { return nil }
        var changed = Set(names.split(separator: "\0").map(String.init))
        for path in Set(before.large.keys).union(after.large.keys) where before.large[path] != after.large[path] { changed.insert(path) }
        for (path, hash) in before.smallUntracked where after.smallUntracked[path] == hash { changed.remove(path) }
        var out: [[String: Any]] = []
        for path in changed.sorted().prefix(60) {
            let kind = !before.paths.contains(path) ? "create" : !after.paths.contains(path) ? "delete" : "edit"
            var diff = ""
            if before.large[path] == nil && after.large[path] == nil {
                guard let raw = runGit(args + ["--", path], in: root, environment: env) else { return nil }
                if let r = raw.range(of: "\n@@") { diff = String(raw[raw.index(after: r.lowerBound)...].prefix(maxDiff)) }
            }
            let counts = diffCounts(diff)
            out.append(["path": root + "/" + path, "kind": kind, "added": counts.added, "removed": counts.removed, "diff": diff])
        }
        return out
    }
}
