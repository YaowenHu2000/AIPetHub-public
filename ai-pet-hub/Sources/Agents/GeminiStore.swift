// 桌面版和终端各自维护摘要和转写。界面中的桌面会话带来源，传给 agy 的始终是原始 ID。
import Foundation

struct GeminiStore {
    let root: String
    let desktop: Bool
    var summaries: String { root + "/conversation_summaries.db" }
    var brain: String { root + "/brain" }

    func key(_ id: String) -> String { desktop ? "desktop:" + id : id }
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
        guard acquired else { return false }
        defer { procLock.lock(); geminiResuming.remove(key); procLock.unlock() }
        guard validConversationId(key, agent: "gemini"), geminiSessionHeld(key, includingOwn: true) == false else { return false }

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
            geminiCache.removeValue(forKey: entry.key(id))
        }
        return removed || indexRemoved   // 文件早已不在、只剩桌面版索引里的坏条目时，清掉索引也算删成了
    }
}
