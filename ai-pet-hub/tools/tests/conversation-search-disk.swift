// 重建内存缓存后仍应复用可见正文；自测的缓存始终位于临时目录。
import Foundation
import SQLite3
import Darwin

func testConversationSearchDisk() {
    print("· 正文搜索磁盘缓存")
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aipethub-search-disk-" + UUID().uuidString)
    let fm = FileManager.default, disk = ConversationSearchDiskCache(root: root)
    defer { disk.flush(); TestHooks.conversationSearchDiskWillWrite = nil; try? fm.removeItem(at: root) }
    func restarted() -> ConversationSearchCache { ConversationSearchCache(disk: ConversationSearchDiskCache(root: root)) }
    let key = "restart-" + UUID().uuidString
    let first = ConversationSearchCache(disk: disk)
    first.put(key, stamp: "same", texts: ["重启后仍然可见"], item: ["id": "fixture"])
    disk.flush()
    let firstReader = restarted()
    eq(firstReader.get(key, stamp: "same")?.texts, ["重启后仍然可见"], "重建内存缓存后从磁盘读取正文")
    check(restarted().get(key, stamp: "changed") == nil, "来源指纹变化后不得复用磁盘正文")
    let dependent = root.appendingPathComponent("image.png").path
    let dependencies = [dependent: conversationSearchFileStamp(dependent)]
    first.put("dependencies", stamp: "same", texts: ["缺失图片标签"], item: [:], dependencies: dependencies,
              individualStamp: "individual", databaseRevision: "revision")
    disk.flush()
    let restored = restarted()
    eq(restored.revalidationCandidate("dependencies", individualStamp: "individual")?.databaseRevision, "revision", "重启后保留会话级摘要用于共享数据库复核")
    try! Data([1]).write(to: URL(fileURLWithPath: dependent))
    check(restarted().get("dependencies", stamp: "same") == nil, "图片或引用文件创建后磁盘正文失效")
    check(restarted().revalidationCandidate("dependencies", individualStamp: "individual") == nil, "依赖变化时也不能走数据库摘要复用")

    // 命中会延迟更新文件时间；先等旧读者写完，否则损坏检测取得的指纹可能在删除前变化。
    firstReader.disk?.flush()
    let original = try! Data(contentsOf: disk.file(key))
    for field in ["formatVersion", "renderVersion", "key", "sha256"] {
        var header = try! PropertyListSerialization.propertyList(from: original, format: nil) as! [String: Any]
        header[field] = field.hasSuffix("Version") ? 999 : (field == "key" ? "another-key" : Data())
        try! PropertyListSerialization.data(fromPropertyList: header, format: .binary, options: 0).write(to: disk.file(key), options: .atomic)
        let cache = restarted()
        check(cache.get(key, stamp: "same") == nil, "\(field) 不匹配时丢弃磁盘缓存")
        cache.disk?.flush()
        check(!fm.fileExists(atPath: disk.file(key).path), "\(field) 不匹配的缓存已删除")
    }
    try! Data("broken cache".utf8).write(to: disk.file(key))
    check(restarted().get(key, stamp: "same") == nil, "损坏缓存静默回退")
    // 即使坏缓存的删除尚未执行，新写入也不能被旧删除任务抹掉。
    first.put(key, stamp: "same", texts: ["新正文"], item: [:]); disk.flush()
    eq(restarted().get(key, stamp: "same")?.texts, ["新正文"], "坏缓存后可以重新生成并复用")
    let huge = disk.file("huge")
    fm.createFile(atPath: huge.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: huge)
    try! handle.truncate(atOffset: 96 * 1024 * 1024 + 1); try! handle.close()
    check(restarted().get("huge", stamp: "same") == nil, "过大的损坏缓存先检查大小，不读取全文")
    let fifo = disk.file("fifo")
    check(mkfifo(fifo.path, 0o600) == 0, "损坏缓存的 FIFO 夹具建立")
    check(restarted().get("fifo", stamp: "same") == nil, "缓存不是普通文件时直接回退，不等待管道")

    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let writeLock = NSLock(); var blocked = false
    TestHooks.conversationSearchDiskWillWrite = { candidate in
        guard candidate == "blocked" else { return }
        writeLock.lock(); let shouldBlock = !blocked; blocked = true; writeLock.unlock()
        if shouldBlock { entered.signal(); _ = release.wait(timeout: .now() + testHoldLimit) }
    }
    first.put("blocked", stamp: "same", texts: ["旧正文"], item: [:])
    check(waitSignal(entered), "后台写盘停在确定位置")
    let readDone = DispatchSemaphore(value: 0)
    var unblocked = false
    DispatchQueue.global().async {
        first.put("blocked", stamp: "same", texts: ["最终正文"], item: [:])
        unblocked = first.get("blocked", stamp: "same")?.texts == ["最终正文"]
            && restarted().get(key, stamp: "same")?.texts == ["新正文"]
        readDone.signal()
    }
    // 被写盘卡住的话要等到测试放行（上面 release 的期限比等待上限长），所以等不到就说明被卡住了
    check(waitSignal(readDone) && unblocked, "后台写盘阻塞时，内存和其它磁盘读取仍完成")
    release.signal(); disk.flush(); TestHooks.conversationSearchDiskWillWrite = nil
    eq(restarted().get("blocked", stamp: "same")?.texts, ["最终正文"], "同键的连续更新和访问合并后仍保存最后正文")

    let lruRoot = root.appendingPathComponent("lru")
    let sample = ConversationSearchDiskCache(root: lruRoot)
    let sampleCache = ConversationSearchCache(disk: sample)
    let text = String(repeating: "x", count: 1000)
    sampleCache.put("a", stamp: "same", texts: [text], item: [:]); sample.flush()
    let oneSize = (try! fm.attributesOfItem(atPath: sample.file("a").path)[.size] as! NSNumber).intValue
    let lru = ConversationSearchDiskCache(root: lruRoot, limit: oneSize * 2 + 10)
    let memory = ConversationSearchCache(limit: 1500, disk: lru)
    memory.put("b", stamp: "same", texts: [text], item: [:]); lru.flush()
    check(memory.get("a", stamp: "same") != nil, "内存淘汰的正文仍能从磁盘恢复")
    lru.flush()
    memory.put("c", stamp: "same", texts: [text], item: [:]); lru.flush()
    check(!fm.fileExists(atPath: lru.file("b").path) && fm.fileExists(atPath: lru.file("a").path), "超过磁盘上限时淘汰最久未使用的正文")
    let total = (try! fm.contentsOfDirectory(at: lruRoot, includingPropertiesForKeys: nil)).reduce(0) {
        $0 + ((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0)
    }
    check(total <= lru.limit, "磁盘总大小不超过上限")
    let unwritable = root.appendingPathComponent("not-directory")
    try! Data().write(to: unwritable)
    let failingDisk = ConversationSearchDiskCache(root: unwritable), usable = ConversationSearchCache(disk: failingDisk)
    usable.put("key", stamp: "same", texts: ["内存正常"], item: [:]); failingDisk.flush()
    eq(usable.get("key", stamp: "same")?.texts, ["内存正常"], "写盘失败不影响搜索的内存缓存")
    failingDisk.flush(); sample.flush(); lru.flush()
    testConversationSearchDiskInvalidation(root.appendingPathComponent("history"))
    testConversationSearchDiskDependencies(root.appendingPathComponent("references"))
}

private func testConversationSearchDiskInvalidation(_ root: URL) {
    let fm = FileManager.default, app = AppDelegate()
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    let diskRoot = root.appendingPathComponent("cache"), path = root.appendingPathComponent("history.sqlite").path
    var db: OpaquePointer?; sqlite3_open(path, &db)
    defer { sqlite3_close(db) }
    func sql(_ text: String) { check(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK, "跨重启失效夹具 SQL 成功") }
    sql("PRAGMA journal_mode=WAL; CREATE TABLE thread_items(thread_id TEXT,item_type TEXT,item_json TEXT,created_at_ms INTEGER,completed_at_ms INTEGER,rollout_ordinal INTEGER);")
    sql("INSERT INTO thread_items VALUES('db-only','userMessage','{\"content\":[{\"type\":\"text\",\"text\":\"original-needle\"}]}',0,0,0);")
    var loads = 0
    app.hooks.conversationSearchLoaded = { _, _ in loads += 1 }
    func search(_ query: String) -> [String: Any] {
        let disk = ConversationSearchDiskCache(root: diskRoot)
        app.hooks.conversationSearchCache = ConversationSearchCache(disk: disk)
        let done = DispatchSemaphore(value: 0); var result: [String: Any] = [:]
        app.hooks.jsSink = { name, payload in
            if name == "onConversationsSearched", payload["complete"] as? Bool == true { result = payload; done.signal() }
        }
        app.searchConversations(agent: "gpt", query: query, files: [("db-only", path)])
        check(waitSignal(done), "重启后的搜索及时返回")
        disk.flush(); app.hooks.jsSink = nil
        check(result["unavailable"] == nil, "磁盘缓存问题不报告为来源读取失败")
        return result
    }
    eq(search("original-needle")["ids"] as? [String], ["db-only"], "首次计算真实读取器的正文")
    eq(search("original-needle")["ids"] as? [String], ["db-only"], "重启后直接使用落盘正文")
    eq(loads, 1, "重启后命中磁盘不再解析消息")
    let stored = ConversationSearchDiskCache(root: diskRoot).file("gpt:db-only:" + path)
    try! Data("damaged".utf8).write(to: stored, options: .atomic)
    eq(search("original-needle")["ids"] as? [String], ["db-only"], "坏缓存由正常历史读取器重新生成，不漏结果")
    eq(loads, 2, "坏缓存确实重新解析正文")
    sql("INSERT INTO thread_items VALUES('other','userMessage','{}',0,0,0);")
    eq(search("original-needle")["ids"] as? [String], ["db-only"], "重启后共享 WAL 有无关写入仍能复核命中")
    eq(loads, 2, "共享 WAL 的无关更新没有触发历史解析")
    sql("UPDATE thread_items SET item_json='{\"content\":[{\"type\":\"text\",\"text\":\"updated-needle\"}]}' WHERE thread_id='db-only';")
    eq(search("updated-needle")["ids"] as? [String], ["db-only"], "同 ordinal 正文更新使落盘缓存失效")
    eq(loads, 3, "正文更新后确实重新解析")
    eq(search("original-needle")["ids"] as? [String], [], "旧正文没有在下一次重启后复活")
}

private func testConversationSearchDiskDependencies(_ root: URL) {
    let fm = FileManager.default, app = AppDelegate()
    let directory = root.appendingPathComponent("unique-cache-reference-directory")
    try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    for isImage in [true, false] {
        let name = isImage ? "photo.png" : "file.swift"
        let target = directory.appendingPathComponent(name)
        try! (isImage ? png : Data("content".utf8)).write(to: target)
        let row: [String: Any] = isImage
            ? ["type": "user", "message": ["content": target.path]]
            : ["type": "assistant", "message": ["content": [["type": "text", "text": "`" + target.path + "`"]]]]
        let history = root.appendingPathComponent(name + ".jsonl")
        try! JSONSerialization.data(withJSONObject: row).write(to: history)
        let diskRoot = root.appendingPathComponent(name + "-cache")
        var loads = 0
        app.hooks.conversationSearchLoaded = { _, _ in loads += 1 }
        func search() -> [String] {
            let disk = ConversationSearchDiskCache(root: diskRoot)
            app.hooks.conversationSearchCache = ConversationSearchCache(disk: disk)
            let done = DispatchSemaphore(value: 0); var ids: [String] = []
            app.hooks.jsSink = { name, payload in
                if name == "onConversationsSearched", payload["complete"] as? Bool == true { ids = payload["ids"] as? [String] ?? []; done.signal() }
            }
            app.searchConversations(agent: "claude", query: "unique-cache-reference-directory", files: [("dependency", history.path)])
            check(waitSignal(done), "外部依赖重启搜索及时完成")
            disk.flush(); app.hooks.jsSink = nil
            return ids
        }
        eq(search(), [], "\(name) 存在时页面短标签隐藏父目录")
        eq(search(), [], "\(name) 未变化时重启后继续使用磁盘结果")
        eq(loads, 1, "\(name) 未变化时只解析一次")
        try! fm.removeItem(at: target)
        eq(search(), ["dependency"], "\(name) 删除后旧磁盘结果失效，完整路径重新可搜")
        try! (isImage ? png : Data("new content".utf8)).write(to: target)
        eq(search(), [], "\(name) 恢复后再失效，目录不会继续误命中")
        eq(loads, 3, "\(name) 的删除和恢复各重算一次")
    }
}
