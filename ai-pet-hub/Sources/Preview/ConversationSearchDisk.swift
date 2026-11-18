// 可见文字的磁盘层：读取不等待后台写入，文件原子替换，失效仍交给内存层和会话摘要复核。
import Foundation
import CryptoKit

final class ConversationSearchDiskCache {
    static let formatVersion = 1
    let root: URL
    let limit: Int
    private let entryLimit = 96 * 1024 * 1024
    // 所有实例共用一条队列：删坏文件是「比对指纹 → 删除」两步，写新内容是原子替换；两者若在不同队列上，
    // 替换可能恰好落在两步之间，新文件被当成坏文件删掉（并行跑测试、机器很忙时测出来过）。排在同一条队列上就不会交错。
    private static let sharedQueue = DispatchQueue(label: "aipethub.search-cache.disk", qos: .utility)
    private var queue: DispatchQueue { Self.sharedQueue }
    private let lock = NSLock()
    private struct Pending {
        var entry: ConversationSearchCache.Entry?
        var date: Date
    }
    private var pending: [String: Pending] = [:]
    private var scheduled = false

    init(root: URL = TestHooks.defaultConversationSearchDiskRoot, limit: Int = 256 * 1024 * 1024) {
        self.root = root; self.limit = limit
    }

    func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name + ".cache")
    }

    func read(_ key: String) -> ConversationSearchCache.Entry? {
        let url = file(key), fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let stamp = conversationSearchFileStamp(url.path)
        func discard() -> ConversationSearchCache.Entry? {
            queue.async {
                // 读坏文件时可能已有新内容排队写入；不能误删刚替换的那一份。
                if conversationSearchFileStamp(url.path) == stamp { try? fm.removeItem(at: url) }
            }
            return nil
        }
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size > 0, size <= min(entryLimit, limit),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let header = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              header["formatVersion"] as? Int == Self.formatVersion,
              header["renderVersion"] as? Int == ConversationSearchText.version,
              header["key"] as? String == key,
              let body = header["body"] as? Data, let digest = header["sha256"] as? Data,
              digest == Data(SHA256.hash(data: body)),
              let value = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any],
              let sourceStamp = value["stamp"] as? String, let texts = value["texts"] as? [String],
              let item = value["item"] as? [String: Any], JSONSerialization.isValidJSONObject(item),
              let dependencies = value["dependencies"] as? [String: String],
              value["individualStamp"] == nil || value["individualStamp"] is String,
              value["databaseRevision"] == nil || value["databaseRevision"] is String else { return discard() }
        return ConversationSearchCache.Entry(stamp: sourceStamp, texts: texts, item: item, dependencies: dependencies,
            individualStamp: value["individualStamp"] as? String, databaseRevision: value["databaseRevision"] as? String)
    }

    func write(_ key: String, entry: ConversationSearchCache.Entry) { submit(key, entry: entry) }
    func touch(_ key: String) { submit(key, entry: nil) }

    private func submit(_ key: String, entry: ConversationSearchCache.Entry?) {
        lock.lock(); defer { lock.unlock() }
        // 同一条正文的后续访问只更新使用时间，不能覆盖尚未写出的新内容。
        pending[key] = Pending(entry: entry ?? pending[key]?.entry, date: Date())
        if !scheduled {
            scheduled = true
            queue.asyncAfter(deadline: .now() + 0.1) { self.drain() }
        }
    }

    private func drain() {
        lock.lock()
        let batch = pending; pending = [:]; scheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        let fm = FileManager.default
        for (key, operation) in batch {
            let url = file(key)
            if let entry = operation.entry {
                TestHooks.conversationSearchDiskWillWrite?(key)
                var value: [String: Any] = ["stamp": entry.stamp, "texts": entry.texts, "item": entry.item, "dependencies": entry.dependencies]
                value["individualStamp"] = entry.individualStamp; value["databaseRevision"] = entry.databaseRevision
                guard entry.bytes <= entryLimit,
                      let body = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
                      let data = try? PropertyListSerialization.data(fromPropertyList: [
                        "formatVersion": Self.formatVersion, "renderVersion": ConversationSearchText.version,
                        "key": key, "body": body, "sha256": Data(SHA256.hash(data: body))
                      ], format: .binary, options: 0), data.count <= min(entryLimit, limit) else { continue }
                do {
                    try fm.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch { continue }
            }
            try? fm.setAttributes([.modificationDate: operation.date], ofItemAtPath: url.path)
        }
        prune()
    }

    /// 单次批量写入后再清理；使用时间也包含内存命中，重启后继续沿用同一淘汰顺序。
    private func prune() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        for url in urls where url.pathExtension == "cache" {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else { continue }
            entries.append((url, size, attrs[.modificationDate] as? Date ?? .distantPast))
        }
        var size = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where size > limit {
            if (try? fm.removeItem(at: entry.url)) != nil { size -= entry.size }
        }
    }

    /// 性能测量在进程退出前等待已提交的写入；搜索本身不调用这个屏障。
    func flush() { queue.sync { drain() } }
}
