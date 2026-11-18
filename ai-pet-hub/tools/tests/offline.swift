// 完整离线套件；保持原执行顺序，退出测试必须最后运行；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func runOfflineSuite() -> Never {
    // 组表按原执行顺序；分片和筛选只挑选、不改顺序，退出测试（ShutdownDuringDshStartup）始终是所在那一份的最后一组。
    let groups: [(String, () -> Void)] = [
        ("HistoryContext", testHistoryContext),
        ("AssignedHistoryFixes", testAssignedHistoryFixes),
        ("SessionOwnership", testSessionOwnership),
        ("TypingResume", testTypingResume),
        ("HistoryActivity", testHistoryActivity),
        ("ConversationSearch", testConversationSearch),
        ("ConversationSearchDisk", testConversationSearchDisk),
        ("Helpers", testHelpers),
        ("TurnBuilder", testTurnBuilder),
        ("Claude", testClaude),
        ("Codex", testCodex),
        ("Agy", testAgy),
        ("GeminiHistoryRegressions", testGeminiHistoryRegressions),
        ("ClaudeCapabilityRefresh", testClaudeCapabilityRefresh),
        ("ClaudeHistory", testClaudeHistory),
        ("CodexHistory", testCodexHistory),
        ("CodexMixedHistory", testCodexMixedHistory),
        ("CodexConfiguredHome", testCodexConfiguredHome),
        ("CodexProjectionFreshness", testCodexProjectionFreshness),
        ("HistoryReadEfficiency", testHistoryReadEfficiency),
        ("SteerImages", testSteerImages),
        ("CodexApp", testCodexApp),
        ("CodexRetryLogs", testCodexRetryLogs),
        ("CodexRetryTiming", testCodexRetryTiming),
        ("Acp", testAcp),
        ("Dsh", testDsh),
        ("Compact", testCompact),
        ("LineSplitter", testLineSplitter),
        ("BackendBoundaries", testBackendBoundaries),
        ("AcpResponses", testAcpResponses),
        ("AcpModelSelection", testAcpModelSelection),
        ("AcpWarmResponses", testAcpWarmResponses),
        ("DeadWarmRetry", testDeadWarmRetry),
        ("ExitAfterAdopt", testExitAfterAdopt),
        ("LiveInitialization", testLiveInitialization),
        ("DeepSeekDelayedFinish", testDeepSeekDelayedFinish),
        ("GeminiCancelOrphan", testGeminiCancelOrphan),
        ("ProcessBoundaries", testProcessBoundaries),
        ("AskStateLifecycle", testAskStateLifecycle),
        ("MalformedStreams", testMalformedStreams),
        ("PreviewTimeoutAndQuit", testPreviewTimeoutAndQuit),
        ("OfflineCLI", testOfflineCLI),
        ("DshStreamOrders", testDshStreamOrders),
        ("GitFileNames", testGitFileNames),
        ("PreviewSpecialFile", testPreviewSpecialFile),
        ("UsageNumbers", testUsageNumbers),
        ("ShutdownDuringDshStartup", testShutdownDuringDshStartup)
    ]
    let env = ProcessInfo.processInfo.environment
    if env["AIPETHUB_W4_ONLY"] == "1" {   // 只跑开头两组（W4 回归）
        groups.prefix(2).forEach { $0.1() }
        print("W4：\(failures) / \(checks) 项没通过")
        exit(failures == 0 ? 0 : 1)
    }
    // AIPETHUB_OFFLINE_SHARD=i/N：tools/test.sh 并行起 N 份，各跑序号 % N == i 的组。
    // AIPETHUB_OFFLINE_ONLY=词1,词2：只跑名字（不区分大小写）含任一个词的组，改代码时只测相关的。
    var picked = Array(groups.enumerated())
    if let shard = env["AIPETHUB_OFFLINE_SHARD"]?.split(separator: "/").compactMap({ Int($0) }), shard.count == 2, shard[1] > 0 {
        picked = picked.filter { $0.offset % shard[1] == shard[0] }
    }
    if let only = env["AIPETHUB_OFFLINE_ONLY"]?.lowercased().split(separator: ",").map(String.init), !only.isEmpty {
        picked = picked.filter { g in only.contains { g.element.0.lowercased().contains($0) } }
        print("只跑：\(picked.map(\.element.0).joined(separator: "、"))")
        if picked.isEmpty { print("没有名字含「\(only.joined(separator: "、"))」的组"); exit(1) }
    }
    picked.forEach { $0.element.1() }
    let part = env["AIPETHUB_OFFLINE_SHARD"].map { "分片 \($0)：" } ?? ""
    print(part + (failures == 0 ? "全部通过（\(checks) 项）" : "\(failures) / \(checks) 项没通过"))
    exit(failures == 0 ? 0 : 1)
}

