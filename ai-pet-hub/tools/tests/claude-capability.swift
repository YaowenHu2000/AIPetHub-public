// 同一个 App 实例里的能力缓存要跟 CLI 升级失效；包装器没换不代表它调用的 CLI 没换。
import Foundation
import Cocoa

func testClaudeCapabilityRefresh() {
    print("· Claude 升级后的 partial-messages 能力探测")
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "aipethub-claude-capability-" + UUID().uuidString
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let cli = dir + "/cli"
    try! installFakeCLI(at: cli, behavior: "backend")
    func mode(_ value: String, in base: String) { try! value.write(toFile: base + "/mode", atomically: true, encoding: .utf8) }
    let app = AppDelegate()
    mode("help-missing", in: dir)
    check(!app.claudeSupportsPartial(cli, prefix: []), "旧 CLI 没有可选参数")
    let before = try! String(contentsOfFile: cli, encoding: .utf8)
    try! (before + "\n# upgraded\n").write(toFile: cli, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    mode("ok", in: dir)
    check(app.claudeSupportsPartial(cli, prefix: []), "相同路径的 CLI 升级后重新探测")
    mode("help-missing", in: dir)
    check(app.claudeSupportsPartial(cli, prefix: []), "二进制没有变化时仍使用直接 CLI 的能力缓存")

    let recovering = AppDelegate()
    mode("help-failed", in: dir)
    check(!recovering.claudeSupportsPartial(cli,prefix:[]), "探测失败时本次保守发送")
    mode("ok", in: dir)
    check(recovering.claudeSupportsPartial(cli,prefix:[]), "标准 Claude 恢复后重新请求流式正文")
    mode("help-missing", in: dir)
    let wrapperApp = AppDelegate()
    check(!wrapperApp.claudeSupportsPartial(cli, prefix: ["cli"]), "包装器底层旧 CLI 不支持")
    mode("ok", in: dir)
    check(wrapperApp.claudeSupportsPartial(cli, prefix: ["cli"]), "包装器自身不变、底层 CLI 升级也重新探测")

    let first = dir + "/v1", second = dir + "/v2", alias = dir + "/alias"
    try! fm.createDirectory(atPath: first, withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: second, withIntermediateDirectories: true)
    try! installFakeCLI(at: first + "/cli", behavior: "backend")
    try! installFakeCLI(at: second + "/cli", behavior: "backend")
    mode("help-missing", in: first); mode("ok", in: second)
    let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
    try! fm.setAttributes([.modificationDate: fixedTime], ofItemAtPath: first + "/cli")
    try! fm.setAttributes([.modificationDate: fixedTime], ofItemAtPath: second + "/cli")
    try! fm.createSymbolicLink(atPath: alias, withDestinationPath: first + "/cli")
    let aliases = AppDelegate()
    check(!aliases.claudeSupportsPartial(alias, prefix: []), "符号链接指向旧版")
    try! fm.removeItem(atPath: alias)
    try! fm.createSymbolicLink(atPath: alias, withDestinationPath: second + "/cli")
    check(aliases.claudeSupportsPartial(alias, prefix: []), "链接切到同大小同时间的新目标也重新探测")
}
