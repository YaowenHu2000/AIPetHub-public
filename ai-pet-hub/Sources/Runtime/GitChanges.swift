// 用 git 找出一轮回答里被命令改动的文件（CLI 只报「改文件工具」的改动）。
import Cocoa

extension AppDelegate {
    // CLI 只会把「改文件工具」的改动报出来；用 sed、脚本、cat > 之类命令改的文件，靠回答前后的 git status 对比补上。
    struct GitSnapshot {
        let root: String
        let entries: [String: String]   // 相对路径 → 状态码|修改时间|大小
    }

    func runGit(_ args: [String], in dir: String) -> String? {
        guard let git = gitPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    func gitSnapshot(_ dir: String?) -> GitSnapshot? {
        guard let dir = dir,
              let root = runGit(["rev-parse", "--show-toplevel"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty, root != home,   // 整个主目录是仓库时不扫
              let status = runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root) else { return nil }
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
            if entries.count > 3000 { return nil }   // 改动多得离谱（比如构建产物没忽略）就不管了
        }
        return GitSnapshot(root: root, entries: entries)
    }

    /// 和回答前比，新出现或又变过的文件，带上 diff（新文件把内容当作新增行）。
    func gitChangedFiles(since before: GitSnapshot) -> [[String: Any]] {
        guard let after = gitSnapshot(before.root) else { return [] }
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
