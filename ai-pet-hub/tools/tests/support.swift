// 离线断言共用工具；tools/test.sh 编译，build/selftest offline 运行。
import Foundation
import Cocoa
import SQLite3

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)（\(file):\(line)）") }
}

func eq<T: Equatable>(_ got: T, _ want: T, _ what: String, file: String = #fileID, line: Int = #line) {
    check(got == want, "\(what)：应为 \(want)，实际 \(got)", file: file, line: line)
}

// 等「某件事发生」的统一上限（用户 2026-11-18 定）：条件一成立就返回，正常路径一点不多等，只有出错时才等满。
// 取 60 秒是为了机器满载（离线主体 8 份并行、旁边还在编译）时也不误报；本地调试想快点看到失败，用 AIPETHUB_TEST_WAIT=10。
// 假进程的坏路径（fake-cli.py、fake-dsh.py 里挂着不动的 sleep / wait）必须比它长，否则「被收走」「没卡住」类断言会因为进程自然结束而白白通过。
// 调用处不写数字；断言「某事没发生」的不用它，用 TestHooks 卡位或比两件事的先后。
let testWaitLimit: TimeInterval = ProcessInfo.processInfo.environment["AIPETHUB_TEST_WAIT"].flatMap(TimeInterval.init) ?? 60
// 钩子里卡位（等测试放行）的上限：要比 testWaitLimit 长，坏实现卡在这里时不能靠卡位自己到点放行而蒙混过关；只防测试中途失败没放行时永远挂住。
let testHoldLimit = 2 * testWaitLimit

/// 轮询到条件成立或到上限。runLoop 为 true 时转当前 RunLoop：要等的回调排在主线程（WebKit、主队列）上时用，否则主线程被睡住就永远等不到。
@discardableResult
func waitUntil(limit: TimeInterval = testWaitLimit, runLoop: Bool = false, interval: TimeInterval = 0.01, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(limit)
    while !condition(), Date() < end {
        if runLoop { RunLoop.current.run(until: Date().addingTimeInterval(interval)) } else { Thread.sleep(forTimeInterval: interval) }
    }
    return condition()
}

/// 等一个信号量，期限同上。
func waitSignal(_ s: DispatchSemaphore, limit: TimeInterval = testWaitLimit) -> Bool {
    s.wait(timeout: .now() + limit) == .success
}
func waitSignal(_ g: DispatchGroup, limit: TimeInterval = testWaitLimit) -> Bool {
    g.wait(timeout: .now() + limit) == .success
}

/// 记下发给网页的每条消息、按函数名取出；jsSink 在各个线程上被调用，所以带锁。用法：let calls = JSSink(app).calls
final class JSSink {
    private let lock = NSLock()
    private var sent: [(String, [String: Any])] = []
    init(_ app: AppDelegate) { app.hooks.jsSink = { [self] name, payload in lock.lock(); sent.append((name, payload)); lock.unlock() } }
    func calls(_ name: String) -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return sent.filter { $0.0 == name }.map { $0.1 } }
}

/// 装上临时 sink 等名为 name（且满足 match）的回调：先 trigger，等到有一条为止，再还原原来的 sink，返回到那时为止最后一条（等不到为 nil）。
/// 等待期间原来的 sink 照收每一条，记录类的 sink 不会漏掉这一段。runLoop 同 waitUntil：回调排在主线程上（WebKit、主队列）时要转 RunLoop，
/// 否则信号量把主线程睡住就永远等不到。
func awaitCallback(_ app: AppDelegate, _ name: String, limit: TimeInterval = testWaitLimit, runLoop: Bool = false,
                   where match: @escaping ([String: Any]) -> Bool = { _ in true }, _ trigger: () -> Void) -> [String: Any]? {
    let old = app.hooks.jsSink, lock = NSLock(), arrived = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    app.hooks.jsSink = { n, p in
        old?(n, p)
        guard n == name, match(p) else { return }
        lock.lock(); result = p; lock.unlock(); arrived.signal()
    }
    trigger()
    if runLoop { _ = waitUntil(limit: limit, runLoop: true) { lock.lock(); defer { lock.unlock() }; return result != nil } } else { _ = waitSignal(arrived, limit: limit) }
    app.hooks.jsSink = old
    lock.lock(); defer { lock.unlock() }
    return result
}

// Gemini 会话库是 protobuf：测试夹具手拼长度前缀字段（wire type 2）和整数，只用到这三样
func protoVarint(_ value: Int) -> Data {
    var value = value, data = Data()
    repeat { let byte = value & 127; value >>= 7; data.append(UInt8(byte | (value == 0 ? 0 : 128))) } while value > 0
    return data
}
func protoField(_ number: Int, _ data: Data) -> Data { protoVarint(number * 8 + 2) + protoVarint(data.count) + data }
func protoText(_ number: Int, _ value: String) -> Data { protoField(number, Data(value.utf8)) }

func json(_ s: String) -> [String: Any] {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else {
        fatalError("测试用的 JSON 写错了：\(s)")
    }
    return obj
}

func str(_ d: [String: Any]?, _ k: String) -> String { d?[k] as? String ?? "" }
func int(_ d: [String: Any]?, _ k: String) -> Int { d?[k] as? Int ?? -1 }

// 只在临时目录生成入口；行为集中在 fake-cli.py，exec 不增加常驻父进程。
func installFakeCLI(at path: String, behavior: String, parameters: [String] = []) throws {
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    let fixture = FileManager.default.currentDirectoryPath + "/tools/fixtures/fake-cli.py"
    let command = (["/usr/bin/python3", fixture, behavior, path] + parameters).map(quote).joined(separator: " ")
    try ("#!/bin/sh\nexec " + command + " \"$@\"\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// 低层测试绕过 ask() 时，测试调用方就是这条记录的唯一主人。
func withTestAsk<T>(_ app: AppDelegate, _ key: String, _ body: () -> T) -> T {
    app.procLock.lock(); app.asks[key] = AskState(); app.procLock.unlock()
    defer { app.procLock.lock(); app.asks[key] = nil; app.procLock.unlock() }
    return body()
}

func testAskState(_ app: AppDelegate, _ key: String) -> AskState? {
    app.procLock.lock(); defer { app.procLock.unlock() }
    return app.asks[key]
}

func testAsksEmpty(_ app: AppDelegate) -> Bool {
    app.procLock.lock(); defer { app.procLock.unlock() }
    return app.asks.isEmpty
}

// 只有测试直接往 DeepSeek 的回合里喂帧；产品里帧都从 DshServer 的事件流来。
// 放在测试这边，产品源码就不用为它加 #if HUB_SELFTEST（DeepSeekLive.swift 里被读写的几个成员因此不是 private）。
extension DeepSeekLiveTurn {
    func receiveForTest(_ frame: [String: Any]) { locked { asked = true; own = true; handle(frame) } }
    var finishedForTest: Bool { locked { finished } }
    var replyForTest: AgentReply { locked { reply() } }
}

/// DeepSeek 的兜底定时器交给测试：记下每次安排的延时和到点要做的事，到点由测试触发，不靠睡过定时器碰时机。
final class DshFinishTimers {
    private let lock = NSLock()
    private var timers: [(delay: TimeInterval, expire: () -> Void)] = []
    init(_ app: AppDelegate) {
        app.hooks.dshIdleFinishScheduled = { [self] delay, expire in lock.lock(); timers.append((delay, expire)); lock.unlock() }
    }
    var all: [(delay: TimeInterval, expire: () -> Void)] { lock.lock(); defer { lock.unlock() }; return timers }
    var last: (delay: TimeInterval, expire: () -> Void)? { all.last }
}

// 测试直接塞一个预热好的进程（把原来那个换掉）；产品里预热进程只经 prewarm() 放进 warmProcs。
extension AppDelegate {
    func keepWarm(_ agent: String, _ cli: CLIProcess) {
        procLock.lock()
        let old = warmProcs[agent]
        warmProcs[agent] = cli
        procLock.unlock()
        if let o = old, o.proc.isRunning { terminateTree(o.proc.processIdentifier) }
    }
}
