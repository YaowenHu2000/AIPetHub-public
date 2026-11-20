// dsh 对接手过的会话只认内存、不回头看磁盘：这里记下本服务写完时会话日志的样子、持有跨实例写锁，
// 续写或重读前判断是否被别处的 dsh 续写过、要不要重起服务按磁盘重载。
//
// 常驻服务对接手过的会话只认内存，用户在别的 dsh 里续写同一会话后，App 在旧内存上接着写会让日志序号断层、整段读不出来；所以续写、重开和搜索正文前比对会话日志文件（inode、
// 大小、修改时间）和本服务自己写完时记下的样子，被别处改过就重起服务按磁盘重新载入；每个接手续写的会话由当前 App 持有跨实例写锁，覆盖 dsh 自行唤醒的后台轮次。
// 移走会话目录或旧服务退出后释放相应写锁，新服务续写时重新获取。
// 外部 `dsh web` 或 `dsh --profile web` 还可能持有磁盘上这版记录时，先提示退出该服务再续写。
import Cocoa

extension DshServer {
    // 用户自己开的 dsh（网页、终端）也会续写同一份会话日志。dsh 对已接手的会话只认内存、不回头看磁盘，
    // 在旧内存上接着写会让日志出现序号断层，整段会话再也读不出来（0.1.0-rc.7 实测）。所以记下本服务
    // 自己写完时日志文件的样子，续写和重读前比一比；换一代服务就清空（新服务按磁盘现读）。
    // dsh 答完仍能从后台任务唤醒会话，因此写锁要跟着服务保留，不能在 turn/end 时交给另一个 App。
    func claimSession(_ sid: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let claim = sessionLock(sid)
        writeLocks[sid] = claim.handle
        return claim.error
    }

    /// 删除需要持锁到移走目录为止；只读核对后即可释放，避免占住下一位写者。
    func sessionLock(_ sid: String) -> (handle: FileHandle?, error: String?) {
        lock.lock(); defer { lock.unlock() }
        if let owned = writeLocks[sid] { return (owned, nil) }
        let root = TestHooks.dshSessionsRoot.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIPetHub")
        let dir = root.appendingPathComponent("dsh-locks")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return (nil, "无法建立 dsh 会话写锁：\(error.localizedDescription)") }
        let fd = open(dir.appendingPathComponent(sid).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return (nil, "无法打开 dsh 会话写锁。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return (nil, "这个会话正在另一个 AIPetHub 里打开。请先退出那边的 AIPetHub，再在这里续写。") }
        return (handle, nil)
    }

    /// dsh 没有卸载接口。所有仍在运行的实例都要按被移走的源目录核对旧内存，恢复到原处后立即重新可用。
    static func deletedDirectoryKey(_ sid: String) -> String { "dshDeletedDirectory:" + sessionsRoot + "/" + sid }
    func markDeleted(_ sid: String, directory: String) {
        UserDefaults.standard.set(directory, forKey:Self.deletedDirectoryKey(sid))
        lock.lock(); writeLocks[sid] = nil; lock.unlock()
    }

    func isDeleted(_ sid: String) -> Bool {
        lock.lock(); let prefix = deletedDirectoryPrefix; lock.unlock()
        guard let prefix, let dir = UserDefaults.standard.string(forKey:prefix + sid) else { return false }
        return access(dir,F_OK) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    /// 本服务往这个会话里写了一条（每条都会出现在事件流上）。停笔落盘后记下日志的样子，作为「自己写完」的基准。
    func noteWrite(_ sid: String) {
        let at = Date()
        lock.lock(); let gen = generation; lastWrite[sid] = at; lock.unlock()
        eventQueue.asyncAfter(deadline: .now() + writeSettle) { [weak self] in
            guard let self = self else { return }
            let mark = DshServer.logMark(sid)
            self.lock.lock()
            let current = self.generation == gen && self.lastWrite[sid] == at
            if current { self.diskMarks[sid] = mark }
            self.lock.unlock()
            if current { TestHooks.dshDiskMarked?(sid) }
        }
    }

    /// 这个会话的日志在本服务写完之后被别的进程改过（本服务内存落后于磁盘）。本服务没接手过的会话 dsh 会现读磁盘，不算。
    /// attaching：马上要往里写（设置、提问）；还没有基准的先记下现在的样子，dsh 接手时读到的就是它。
    func changedElsewhere(_ sid: String, attaching: Bool) -> Bool {
        let now = DshServer.logMark(sid)
        lock.lock(); defer { lock.unlock() }
        // 本服务自己的写还在落盘，这时文件变了说明不了什么；停笔后计时器会补记
        if let at = lastWrite[sid], Date().timeIntervalSince(at) < writeSettle { return false }
        guard let mark = diskMarks[sid] else {
            if attaching { diskMarks[sid] = now }
            return false
        }
        return mark != now
    }

    /// 这一代服务的编号：停掉、重起都会换，旧服务内存里读到的东西只在它那一代作数。
    var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// 日志现在的样子出自本服务：自己的写还在落盘，或停笔后记下的基准就是它。这时本服务的内存就是最新的。
    func wroteLast(_ sid: String, mark: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let at = lastWrite[sid], Date().timeIntervalSince(at) < writeSettle { return true }
        return diskMarks[sid] == mark
    }

    /// 各会话里还没结束的后台任务名（去重）；重起服务会把它们全部结束。
    var runningJobs: [String] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return activeJobs.values.joined().filter { seen.insert($0).inserted }
    }

    /// 服务以用户主目录为工作目录，因而相对路径及波浪号也要按 dsh 的规则展开。
    static var dataRoot: String {
        let home = NSHomeDirectory()
        guard let configured = ProcessInfo.processInfo.environment["DSH_HOME"],
              !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return home + "/.dsh" }
        let base = URL(fileURLWithPath: home, isDirectory: true)
        if configured == "~" { return home }
        let relative = configured.hasPrefix("~/") || configured.hasPrefix("~\\") ? String(configured.dropFirst(2)) : configured
        return URL(fileURLWithPath: relative, relativeTo: base).standardizedFileURL.path
    }

    /// ps 的命令列没有 DSH_HOME；只对候选服务读取启动环境，保留路径里的空格。
    static func usesOtherRoot(_ pid: pid_t) -> Bool {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return false }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return false }
        guard let pathEnd = bytes[4..<size].firstIndex(of: 0),
              let start = bytes[pathEnd..<size].firstIndex(where: { $0 != 0 }) else { return false }
        let fields = bytes[start..<size].split(separator: 0, omittingEmptySubsequences: false).dropFirst(argc)
        let environment = fields.prefix { !$0.isEmpty }
        func value(_ key: String) -> String? {
            environment.first { $0.starts(with: key.utf8) }.map { String(decoding: $0.dropFirst(key.utf8.count), as: UTF8.self) }
        }
        let configured = value("DSH_HOME=").flatMap { trimmed($0).isEmpty ? nil : $0 } ?? value("HOME=").map { $0 + "/.dsh" } ?? ""
        // 相对路径取决于对方的启动目录，无法确认时保留占用提示。
        guard configured.hasPrefix("/") || configured.hasPrefix("~/") else { return false }
        let root = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        return root.resolvingSymlinksInPath().standardizedFileURL.path != URL(fileURLWithPath: dataRoot).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static var sessionsRoot: String { TestHooks.dshSessionsRoot ?? dataRoot + "/sessions" }

    /// dsh 网页「归档」（workspace.archiveSession）的会话：dsh 把编号单独记在数据目录的 storages/workspace.json，session.list 照样列出。
    /// 按磁盘读：运行中的服务只认自己内存里的清单，看不到另一个 dsh 刚做的归档；读不到就当没有归档。
    static func archivedSessionIds() -> Set<String> {
        let path = URL(fileURLWithPath: sessionsRoot).deletingLastPathComponent().appendingPathComponent("storages/workspace.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return Set((json["global"] as? [String: Any])?["archivedSessionIds"] as? [String] ?? [])
    }

    /// 会话日志（数据根目录/sessions/<目录编码>/<会话编号>/session.jsonl[.zstd]）的设备内 inode、大小和纳秒级修改时间；找不到是空串。
    static func logMark(_ sid: String) -> String {
        let root = sessionsRoot
        for group in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            for name in ["session.jsonl.zstd", "session.jsonl"] {
                var st = stat()
                if stat("\(root)/\(group)/\(sid)/\(name)", &st) == 0 {
                    return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
                }
            }
        }
        return ""
    }

    /// 全部会话的 logMark，一次扫完：列表刷新要逐条比对，逐个调用 logMark 会把目录编码那一层重复列很多遍。
    static func logMarks() -> [String: String] {
        let root = sessionsRoot, fm = FileManager.default
        var marks: [String: String] = [:]
        for group in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for sid in (try? fm.contentsOfDirectory(atPath: "\(root)/\(group)")) ?? [] where marks[sid] == nil {
                for name in ["session.jsonl.zstd", "session.jsonl"] {
                    var st = stat()
                    if stat("\(root)/\(group)/\(sid)/\(name)", &st) == 0 {
                        marks[sid] = "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
                        break
                    }
                }
            }
        }
        return marks
    }
}

extension AppDelegate {
    /// 续写或重读一个会话之前：它在别处（另一个 dsh）续写过、本服务内存里还是旧的，就重起服务让 dsh 按磁盘重新载入。
    /// dsh 没有让单个会话退出内存的接口，只能整个重起；别的 DeepSeek 回答正在进行、或者还有后台任务在跑时，
    /// 重起会把它们一起断掉，所以这时不重起，返回给用户看的原因（这次不发，提问留着；重读则照旧按内存给）。
    /// except：发起检查的这次提问自己。nil 表示可以继续。
    func dshReloadIfChangedElsewhere(_ sid: String, attaching: Bool, except key: String? = nil) -> String? {
        // 已知的目录删除由会话读取直接报告，避免无谓地重启仍在服务其他会话的 dsh。
        guard !sid.isEmpty, !dshServer.isDeleted(sid) else { return nil }
        guard isSafeId(sid) else { return "dsh 会话编号无效。" }
        let changed = dshServer.changedElsewhere(sid, attaching: false)
        // 只在有证据时才查别的 dsh：磁盘确实被别处推进过（changed）。不能每次续写都查——用户常开着一个 dsh web 做别的会话，
        // 「它早于这份日志末次写入启动」几乎总成立，那样每次发送都会被误拦（2026-11-18 审阅时发现，改成只看 changed）。
        // 代价：第一次接手一个从网页写过来、本机还没有指纹的会话时，若网页那边的 dsh 之后还写，仍可能冲突——根子在 dsh 写入端没有锁。
        if changed {
            var own = Set(dshServer.wrapperPid.map { descendants(of: $0) + [$0] } ?? [])
            let list = runTool("/bin/ps", ["-ww", "-U", NSUserName(), "-o", "pid=,command="], cwd: home, timeout: 4)
            guard list.status == 0 else { return "无法确认别的 dsh 是否仍在运行，请稍后重试。" }
            let lines = list.out.split(separator: "\n")
            // 其他 App 的托管服务遵守同一份 flock，不能因它在用另一个会话而挡住这次发送。
            for line in lines where line.range(of: #"^\s*\d+\s+(?:/bin/)?sh -c\s+"\$1" web --port 0 --host 127\.0\.0\.1 & c=\$!"#, options: .regularExpression) != nil {
                if let field = line.split(whereSeparator: { $0.isWhitespace }).first, let wrapper = pid_t(field) {
                    own.formUnion(descendants(of: wrapper))
                }
            }
            for line in lines {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 3, let pid = pid_t(fields[0]), !own.contains(pid),
                      let cli = fields.dropFirst().prefix(2).firstIndex(where: {
                          $0 == "dsh" || $0.hasSuffix("/dsh") || $0.hasSuffix("/dsh/lib/bin.js")
                      }) else { continue }
                let arguments = fields.dropFirst(cli + 1)
                guard arguments.first == "web" || arguments.starts(with: ["--profile", "web"]),
                      !DshServer.usesOtherRoot(pid), hooks.dshPeerProcessFilter?(pid) ?? true else { continue }
                return "这个会话可能正在别的 dsh 里打开。请先退出终端里的 dsh web 服务（只关网页标签还不够），再在这里续写。"
            }
        }
        if attaching, let error = dshServer.claimSession(sid) { return error }
        guard dshServer.changedElsewhere(sid, attaching: attaching) else { return nil }
        procLock.lock()
        let busy = asks.keys.contains { $0.hasPrefix("deepseek#") && $0 != key }
        procLock.unlock()
        if busy { return "这个会话在别处更新过，等正在进行的 DeepSeek 回答结束后再发。" }
        let jobs = dshServer.runningJobs
        if !jobs.isEmpty {
            return "这个会话在别处更新过，要重启 dsh 的本机服务才能接着写，但 DeepSeek 还有后台任务在跑（\(jobs.map { $0.isEmpty ? "未命名" : $0 }.joined(separator: "、"))），重启会把它们一起结束。等它们结束后再发。"
        }
        if let error = dshServer.restart() { return error }
        if attaching, let error = dshServer.claimSession(sid) { return error }
        // 模型和思考强度只在旧服务的内存里，重起后每个会话都要重新设
        procLock.lock(); dshApplied = [:]; procLock.unlock()
        _ = dshServer.changedElsewhere(sid, attaching: attaching)   // 新服务马上要接手：以现在的磁盘为基准
        return nil
    }
}
