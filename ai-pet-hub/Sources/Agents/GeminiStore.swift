// 桌面版和终端各自维护摘要和转写。界面中的桌面会话带来源，传给 agy 的始终是原始 ID。
//
// 删除时连 agy 另存的 `conversations/<id>.pb`、`annotations/<id>.pbtxt`（桌面版还有 `chapter_titles/<id>.pb`）一起移进废纸篓，
// 否则 agy 的会话列表里还会列出它。
//
// Gemini 合并 agy CLI 和 Antigravity 桌面版的历史。
// 桌面会话在 App 内用 `desktop:<id>` 区分来源，交给 `agy acp --app-data-dir antigravity` 时使用原始 ID。
// 单次模式不支持选择桌面目录，桌面续接失败时保留原会话并提示。
// 桌面版运行期间（含无法确认进程状态时），桌面会话可查看和搜索，发送、打字预热续接和删除均被拦住，避免内存缓存写回覆盖更改。
// 新会话沿用 CLI 目录。
// agy 新建会话时 `<id>.db` 若被别的进程挡住（平时是一直打开着 CLI 会话目录的桌面版 language_server），会把这一轮写进加密的 `<id>.pb`、之后续聊又写回 .db，
// 同一段会话被拆开且 App 和 agy 都只读得到 .db 那半；所以 App 在 `session/new` 答复后查这个 agy 进程自己的日志，建库失败就删掉那个 0 字节空库、
// 换一个新会话再提问（最多两次）。
import Foundation

struct GeminiStore {
    let root: String
    let desktop: Bool
    var summaries: String { root + "/conversation_summaries.db" }
    var brain: String { root + "/brain" }

    func key(_ id: String) -> String { desktop ? "desktop:" + id : id }
    func deletedIndexKey(_ id: String) -> String { "geminiDeletedIndex:" + root + "/" + id }
    func database(_ id: String) -> String { root + "/conversations/" + id + ".db" }
}

func geminiRawId(_ key: String) -> String {
    key.hasPrefix("desktop:") ? String(key.dropFirst("desktop:".count)) : key
}

extension AppDelegate {
    var geminiStores: [GeminiStore] {
        let cli = hooks.geminiCliDir ?? "\(home)/.gemini/antigravity-cli"
        return [GeminiStore(root: cli, desktop: false),
                GeminiStore(root: (cli as NSString).deletingLastPathComponent + "/antigravity", desktop: true)]
    }

    func geminiStore(_ key: String) -> GeminiStore { geminiStores[key.hasPrefix("desktop:") ? 1 : 0] }
    func geminiConversationDb(_ key: String) -> String { geminiStore(key).database(geminiRawId(key)) }

    /// agy 新建会话时 <id>.db 被别的进程挡住约 5 秒以上，会照样建会话，但这一轮写进加密的 <id>.pb；之后续聊又写回 .db，
    /// 同一段会话被拆成两半，App 和 agy 自己都只读得到 .db 那半（2026-11-19 实测：另一个进程对新库持读锁就能复现；
    /// 平时一直打开着 CLI 会话目录和其中各库的是反重力桌面版的 language_server）。失败那行在 session/new 答复之前已写进这个 agy 进程自己的日志，
    /// 还没提问时认出来换一个会话，就不会拆开。
    func geminiStoreFailed(_ sid: String, pid: pid_t?) -> Bool {
        guard let pid, isSafeId(sid), let log = geminiAcpLog(pid), let data = fm.contents(atPath: log) else { return false }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains {
            $0.contains("failed to create persistent trajectory") && $0.contains("/\(sid).db")
        }
    }

    /// 这个 agy 进程自己的 acp-server 日志。agy 从不清理日志、进程号会复用，同号的旧日志不能算（2026-11-19 本机 1438 份里已有 15 个进程号各两份，
    /// 目录顺序和时间无关）。文件名是它第一次写日志的本地时刻（和首行时间一致，紧跟在启动之后），所以先按启动时刻逐秒试名字，
    /// 不必每个新会话都列一遍四千多个文件（约 8ms）；日志名的时区和 App 不同等原因试不中时，才列目录，取同号里创建不早于启动的最新一份。
    func geminiAcpLog(_ pid: pid_t) -> String? {
        guard let start = processStartTime(pid) else { return nil }
        let dir = geminiStores[0].root + "/log", suffix = "-\(pid).log"
        let since = (Double(start) / 1_000_000).rounded(.down)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd_HHmmss"
        for second in 0...30 {
            let path = dir + "/acp-server-" + stamp.string(from: Date(timeIntervalSince1970: since + Double(second))) + suffix
            if fm.fileExists(atPath: path) { return path }
        }
        let own = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("acp-server-") && $0.hasSuffix(suffix) }
            .compactMap { name -> (String, Date)? in
                let path = dir + "/" + name
                guard let created = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date,
                      created.timeIntervalSince1970 >= since else { return nil }
                return (path, created)
            }
        return own.max { $0.1 < $1.1 }?.0
    }

    /// 换掉的那个会话没有任何内容（库是 0 字节、没有 .pb、不进摘要索引），直接删掉，免得留下空文件。
    func discardFailedGeminiStore(_ sid: String) {
        guard isSafeId(sid) else { return }
        let db = geminiStores[0].database(sid)
        if (try? fm.attributesOfItem(atPath: db))?[.size] as? Int == 0 { try? fm.removeItem(atPath: db) }
    }

    /// 已经打开过源文件或明确删除过的会话，不能靠残留索引或本机结局复活。早期只有索引的会话仍能阅读。
    func geminiSourceMissing(_ key: String, remember: Bool = false) -> Bool {
        let store = geminiStore(key), id = geminiRawId(key), marker = store.deletedIndexKey(id)
        let known = UserDefaults.standard.bool(forKey:marker)
        guard known || remember else { return false }
        let database = store.database(id)
        if fm.fileExists(atPath:database) || fm.fileExists(atPath:geminiTranscriptPath(key))
            || fm.fileExists(atPath:store.root + "/conversations/" + id + ".pb") {
            if remember && !known { UserDefaults.standard.set(true, forKey:marker) }
            return false
        }
        return known && historyAccessError(database) == nil && historyAccessError(geminiTranscriptPath(key)) == nil
            && historyAccessError(store.root + "/conversations/" + id + ".pb") == nil
    }

    func validConversationId(_ key: String, agent: String) -> Bool {
        isSafeId(agent == "gemini" ? geminiRawId(key) : key)
    }

    /// 同一个原始 ID 可能是两份独立历史。只有设备号和 inode 同时相同，才能合并或清理另一个入口。
    func geminiSharedDatabase(_ id: String) -> Bool {
        let stores = geminiStores
        var a = stat(), b = stat()
        return stat(stores[0].database(id), &a) == 0 && stat(stores[1].database(id), &b) == 0
            && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    func geminiKey(_ id: String, in store: GeminiStore) -> String {
        guard geminiSharedDatabase(id) else { return store.key(id) }
        let cli = geminiStores[0]
        if (try? fm.destinationOfSymbolicLink(atPath: cli.database(id))) != nil { return geminiStores[1].key(id) }
        return cli.key(id)
    }

    func deleteGemini(_ key: String, onBlocked: (String) -> Void) -> Bool {
        // 桌面版的会话：它开着时不能删（内存里有一份，会把索引和记录写回去）；关着时连它的索引一起清（GeminiDesktopIndex.swift）。
        let desktopBlocked = "⚠️ 反重力桌面版正在运行。请先退出反重力再从这里删除，或者直接在反重力里删。"
        let desktop = geminiStore(key).desktop
        if desktop, geminiDesktopReadOnly(key) { onBlocked(desktopBlocked); return false }
        procLock.lock()
        let acquired = geminiResuming.insert(key).inserted
        procLock.unlock()
        guard acquired else { onBlocked("⚠️ 这个 Gemini 会话正有一轮在发送，等它结束后再删除。"); return false }
        defer { procLock.lock(); geminiResuming.remove(key); procLock.unlock() }
        guard validConversationId(key, agent: "gemini") else { return false }
        // 已拿到这个会话的占用，新的发送进不来；先放掉本 App 自己空闲的打字预热，否则下面连自己也算的持库检查会被它挡住。
        releaseWarm(agent: "gemini", cid: key)
        switch geminiSessionHeld(key, includingOwn: true) {
        case false: break
        case true:
            onBlocked("⚠️ 这个 Gemini 会话正被 agy 或反重力打开（正在回答，或在别的客户端里）。等它结束或关掉后再删除。")
            return false
        default:
            onBlocked("⚠️ 无法确认这个 Gemini 会话是否正被别的进程打开，请稍后重试。")
            return false
        }

        let id = geminiRawId(key), store = geminiStore(key)
        var indexRemoved = false
        if desktop {
            // 刚才查过之后桌面版可能刚好启动了：动索引前再查一次
            guard !geminiDesktopReadOnly(key) else { onBlocked(desktopBlocked); return false }
            guard removeFromDesktopIndex(id, root: store.root) else {
                onBlocked("⚠️ 没能更新反重力桌面版的索引，这个会话没有删除。")
                return false
            }
            indexRemoved = true
        }
        var stores = [store]
        if geminiSharedDatabase(id) {
            // 先移走链接，再移真库，否则链接悬空后无法按正常路径移入废纸篓。
            stores = geminiStores.sorted {
                (try? fm.destinationOfSymbolicLink(atPath: $0.database(id))) != nil
                    && (try? fm.destinationOfSymbolicLink(atPath: $1.database(id))) == nil
            }
        }
        var removed = false
        for entry in stores {
            let db = entry.database(id)
            if fm.fileExists(atPath: db) {
                guard trash(db) else { return false }
                removed = true
            }
            _ = trash(db + "-wal")
            _ = trash(db + "-shm")
            removed = trash(entry.brain + "/" + id) || removed
            // agy 另存的整段会话（.pb）和标题（annotations），桌面版还有分章标题：留着的话 agy 的 session/list、/resume
            // 还会列出这个会话（agy 1.5.11 实测）。presence/<id>.lock 是空的锁文件，agy 自己管，不动。
            for extra in ["/conversations/\(id).pb", "/annotations/\(id).pbtxt", "/chapter_titles/\(id).pb"] {
                removed = trash(entry.root + extra) || removed
            }
            // 索引可能在删除回执之后才写入。各实例按源文件是否恢复决定能否再读它。
            if removed || indexRemoved { UserDefaults.standard.set(true, forKey:entry.deletedIndexKey(id)) }
            geminiCache.removeValue(forKey: entry.key(id))
        }
        return forgetLocalEndings("gemini", key) || removed || indexRemoved   // 文件早已不在、只剩桌面版索引里的坏条目时，清掉索引也算删成了
    }
}
