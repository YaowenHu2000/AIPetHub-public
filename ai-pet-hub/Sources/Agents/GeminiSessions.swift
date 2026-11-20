// agy 会把内存中的会话写回 SQLite。续接前检查真正持有同一个库的进程，空闲的 ACP 客户端也算。
//
// Gemini 开始打字才提前续接已有会话，停打 90 秒释放；发送前核对续接成功时的记录指纹，变化就重新续接，还会核对外部持库进程（隔约 1 秒仍是同一进程开着才算：别的 agy 起会话、
// 查模型时会顺手打开最近用过的别的会话库约 0.1 秒）；删除 Gemini 会话时先结束该会话空闲的预热、等它退出，再做连本 App 也算的持库检查，正在回答的仍会拦住；
//
// 只读历史用单次持库采样，2 秒内可复用；发送前和提问卡等待作答期间检查目标库是否由外部 agy 或 Antigravity 的 language_server 持有；确认冲突后撤卡并提示核对历史。
import Cocoa

private let desktopSendWarning = "⚠️ 反重力桌面版可能用内存中的旧记录覆盖这里发送的内容。请在桌面版继续，或先退出桌面版再在这里聊。"

/// 桌面版切走会话后仍可能把缓存写回。只查当前用户的进程表，并核对候选进程的可执行文件路径。
private func antigravityRunning() -> Bool? {
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
    var bytes = 0
    guard sysctl(&mib, 4, nil, &bytes, nil, 0) == 0 else { return nil }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: bytes / stride + 32)
    bytes = procs.count * stride
    guard sysctl(&mib, 4, &procs, &bytes, nil, 0) == 0 else { return nil }
    for var p in procs.prefix(bytes / stride) {
        let name = withUnsafeBytes(of: &p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let expected: String
        switch name {
        case "Antigravity": expected = "/Antigravity.app/Contents/MacOS/Antigravity"
        case "language_server": expected = "/Antigravity.app/Contents/Resources/bin/language_server"
        default: continue
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(p.kp_proc.p_pid, &path, UInt32(path.count)) > 0 else {
            if errno == ESRCH { continue }
            return nil
        }
        if String(cString: path).hasSuffix(expected) { return true }
    }
    return false
}

extension AppDelegate {
    /// 一次扫描要 0.1–0.2 秒（遍历全部进程；持库检查还要查每个进程打开的文件）。打字预热每个按键都会问、输入框提示每 8 秒问一次，
    /// 每次都扫会一直抢 CPU，在桌面版会话里打字发卡（用户 2026-11-18 碰到）。这些地方传 fresh: false，2 秒内复用上次结果；
    /// 发送、删除前用默认的现查：反重力刚启动的那一两秒里不能写它的会话。
    private func geminiProbe(_ key: String, fresh: Bool, _ scan: () -> Bool?) -> Bool? {
        if !fresh {
            procLock.lock(); let cached = geminiProbes[key]; procLock.unlock()
            if let c = cached, Date().timeIntervalSince(c.at) < (hooks.geminiProbeTTL ?? 2) { return c.value }
        }
        let value = scan()
        procLock.lock(); geminiProbes[key] = (Date(), value); procLock.unlock()
        return value
    }

    func geminiDesktopReadOnly(_ cid: String, fresh: Bool = true) -> Bool {
        guard cid.hasPrefix("desktop:") else { return false }
        return geminiProbe("desktop-running", fresh: fresh) { (hooks.geminiDesktopRunning ?? antigravityRunning)() } != false
    }

    func geminiDesktopSendBlock(_ cid: String, fresh: Bool = true) -> String? {
        geminiDesktopReadOnly(cid, fresh: fresh) ? desktopSendWarning : nil
    }

    /// nil 表示系统未能检查。App 读历史等普通 SQLite 读者可以共存。
    func geminiSessionHeld(_ cid: String, includingOwn: Bool = false, databasePath: String? = nil, fresh: Bool = true, confirm: Bool = true) -> Bool? {
        geminiProbe("held:\(cid):\(includingOwn):\(databasePath ?? ""):\(confirm)", fresh: fresh) {
            geminiSessionHeldScan(cid, includingOwn: includingOwn, databasePath: databasePath, confirm: confirm)
        }
    }

    /// 别的 agy 开着库不一定在用这个会话：agy 起会话（session/new）和 `agy models` 时会顺手打开最近用过的另一个会话库，约 0.1 秒就关
    /// （agy 1.5.x 实测）。别的 App 实例、终端里的 agy 刚好这时启动，发送就被误拦成「正在其他客户端打开」（窗口测试 2026-11-18 碰到两次）。
    /// 真在用这个会话的客户端会一直开着库，所以外面的进程要隔约 1 秒还是同一个 pid 开着才算；本 App 自己的进程不用等。
    private func geminiSessionHeldScan(_ cid: String, includingOwn: Bool, databasePath: String?, confirm: Bool) -> Bool? {
        guard !cid.isEmpty, validConversationId(cid, agent: "gemini") else { return false }
        let db = databasePath ?? geminiConversationDb(cid)
        guard let first = geminiDatabaseHolders(db) else { return nil }
        if includingOwn && first.own { return true }
        if !confirm { return !first.outside.isEmpty }
        var outside = first.outside
        let deadline = Date().addingTimeInterval(1)
        while !outside.isEmpty {
            if Date() >= deadline { return true }
            hooks.geminiHeldRecheck?()
            Thread.sleep(forTimeInterval: 0.1)
            guard let again = geminiDatabaseHolders(db) else { return nil }
            if includingOwn && again.own { return true }
            outside.formIntersection(again.outside)
        }
        return false
    }

    /// 这一刻开着库的 agy / 反重力 language_server：own 是本 App 启动的 agy，outside 是其余的 pid。nil 表示系统未能检查。
    private func geminiDatabaseHolders(_ db: String) -> (own: Bool, outside: Set<pid_t>)? {
        var own = false, outside = Set<pid_t>()
        for path in [db, db + "-wal"] where fm.fileExists(atPath: path) {
            var pids = [pid_t](repeating: 0, count: 16)
            while true {
                let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
                let used = proc_listpidspath(UInt32(PROC_UID_ONLY), getuid(), path,
                                             UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY), &pids, bytes)
                if used < 0 {
                    if errno == ENOENT { break }
                    return nil
                }
                for pid in pids.prefix(Int(used) / MemoryLayout<pid_t>.stride) {
                    var name = [CChar](repeating: 0, count: 64)
                    guard proc_name(pid, &name, UInt32(name.count)) > 0 else {
                        if errno == ESRCH { continue }
                        return nil
                    }
                    switch String(cString: name) {
                    case "agy":
                        if ChildProcesses.shared.owns(pid) { own = true } else { outside.insert(pid) }
                    case "language_server":
                        var path = [CChar](repeating: 0, count: 4096)
                        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
                        if String(cString: path).hasSuffix("/Antigravity.app/Contents/Resources/bin/language_server") { outside.insert(pid) }
                    default:
                        continue
                    }
                }
                if used < bytes { break }
                pids += Array(repeating: 0, count: pids.count)
            }
        }
        return (own, outside)
    }

    func geminiResumeBlock(_ cid: String, fresh: Bool = true) -> String? {
        if let reason = geminiDesktopSendBlock(cid, fresh: fresh) { return reason }
        if geminiStore(cid).desktop && !fm.fileExists(atPath: geminiConversationDb(cid)) {
            return "⚠️ 找不到这个 Gemini 桌面会话的数据库。"
        }
        switch geminiSessionHeld(cid, fresh: fresh) {
        case true: return "⚠️ 这个 Gemini 会话正在其他客户端打开。请先在那里关闭会话，再重试发送。"
        case false: return nil
        default: return "⚠️ 无法确认这个 Gemini 会话是否由其他客户端持有，请稍后重试。"
        }
    }
}
