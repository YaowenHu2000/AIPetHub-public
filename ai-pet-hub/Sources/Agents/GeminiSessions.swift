// agy 会把内存中的会话写回 SQLite。续接前检查真正持有同一个库的进程，空闲的 ACP 客户端也算。
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
        case "Antigravity": expected = "/Applications/Antigravity.app/Contents/MacOS/Antigravity"
        case "language_server": expected = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
        default: continue
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(p.kp_proc.p_pid, &path, UInt32(path.count)) > 0 else {
            if errno == ESRCH { continue }
            return nil
        }
        if String(cString: path) == expected { return true }
    }
    return false
}

extension AppDelegate {
    func geminiDesktopReadOnly(_ cid: String) -> Bool {
        guard cid.hasPrefix("desktop:") else { return false }
        return (hooks.geminiDesktopRunning ?? antigravityRunning)() != false
    }

    func geminiDesktopSendBlock(_ cid: String) -> String? {
        geminiDesktopReadOnly(cid) ? desktopSendWarning : nil
    }

    /// nil 表示系统未能检查。App 读历史等普通 SQLite 读者可以共存。
    func geminiSessionHeld(_ cid: String, includingOwn: Bool = false, databasePath: String? = nil) -> Bool? {
        guard !cid.isEmpty, validConversationId(cid, agent: "gemini") else { return false }
        let db = databasePath ?? geminiConversationDb(cid)
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
                        if includingOwn || !ChildProcesses.shared.owns(pid) { return true }
                    case "language_server":
                        var path = [CChar](repeating: 0, count: 4096)
                        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
                        if String(cString: path).hasSuffix("/Antigravity.app/Contents/Resources/bin/language_server") { return true }
                    default:
                        continue
                    }
                }
                if used < bytes { break }
                pids += Array(repeating: 0, count: pids.count)
            }
        }
        return false
    }

    func geminiResumeBlock(_ cid: String) -> String? {
        if let reason = geminiDesktopSendBlock(cid) { return reason }
        if geminiStore(cid).desktop && !fm.fileExists(atPath: geminiConversationDb(cid)) {
            return "⚠️ 找不到这个 Gemini 桌面会话的数据库。"
        }
        switch geminiSessionHeld(cid) {
        case true: return "⚠️ 这个 Gemini 会话正在其他客户端打开。请先在那里关闭会话，再重试发送。"
        case false: return nil
        default: return "⚠️ 无法确认这个 Gemini 会话是否由其他客户端持有，请稍后重试。"
        }
    }
}
