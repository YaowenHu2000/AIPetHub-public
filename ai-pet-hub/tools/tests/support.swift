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
