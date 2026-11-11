// AIPetHub：把极其猫（Gemini）/ 克劳蒂娜（Claude）/ 吉佩缇（Codex）放进同一个普通窗口里的 App。
// 界面是网页（web/：index.html + js/ + css/），原生这边负责窗口、调用三个本机 CLI、读写历史会话。源码分五块：
//   App/      窗口、菜单、网页 ↔ 原生的消息桥、启动和退出
//   Runtime/  一次提问的流程、CLI 进程、交互式回答的共用部分、预热、git 改动对比、历史会话的分发
//   Agents/   三位各自的实现：提问（交互式 + 一问一答）和历史会话
//   Parsing/  各家 CLI 的事件 → 统一的「工作步骤 + 正文 + 改动文件」
//   Preview/  文件预览、内置浏览器（含给智能体用的工具）、文档预览、对话里的图片、搜索
//
// 程序入口：平时启动应用；带 --mcp-browser 时当 MCP 服务器（给 CLI 用内置浏览器），带 --uitest 时跑真实窗口的自动化测试，
// 带 --check-permissions 时只检查磁盘访问权限。自测程序（HUB_SELFTEST）走 tools/selftest.swift。
import Cocoa
/// 诊断：`AIPetHub --check-permissions 输出.json` 用 App 自己的身份试读几处只有「完全磁盘访问权限」才能读的位置，
/// 把结果写进文件就退出（不开窗口，也不会弹授权窗口），用来确认权限有没有给上。
func checkPermissionsAndExit(_ out: String) -> Never {
    var result: [String: String] = [:]
    for rel in ["Library/Safari", "Library/Mail", "Library/Messages", "Library/Suggestions"] {
        let path = NSHomeDirectory() + "/" + rel
        guard FileManager.default.fileExists(atPath: path) else { result[rel] = "不存在"; continue }
        result[rel] = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil ? "可读" : "被拒绝"
    }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: out))
    }
    exit(0)
}

#if HUB_SELFTEST
runSelfTest()
#else
if let i = CommandLine.arguments.firstIndex(of: "--check-permissions"), i + 1 < CommandLine.arguments.count {
    checkPermissionsAndExit(CommandLine.arguments[i + 1])
}
if let i = CommandLine.arguments.firstIndex(of: "--mcp-browser"), i + 1 < CommandLine.arguments.count {
    runBrowserMCP(CommandLine.arguments[i + 1])   // 被 CLI 拉起来当 MCP 服务器：不开窗口
}
UITest.parseArguments()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
#endif
