// 完整离线套件；保持原执行顺序，退出测试必须最后运行；build/selftest offline。
// 新加的组登记在下面的组表里：tools/test.sh 的 --only 和分片都按组名选，不在表里的组不会被跑到；慢组再在耗时表里补一条。
import Foundation
import Cocoa
import SQLite3

func runOfflineSuite() -> Never {
    // 组表按原执行顺序；分片和筛选只挑选、不改顺序，退出测试（ShutdownDuringDshStartup）始终是所在那一份的最后一组。
    let groups: [(String, () -> Void)] = [
        ("HistoryContext", testHistoryContext),
        ("AssignedHistoryFixes", testAssignedHistoryFixes),
        ("SessionOwnership", testSessionOwnership),
        ("GeminiTransientHolder", testGeminiTransientHolder),
        ("TypingResume", testTypingResume),
        ("CodexWriterBusy", testCodexWriterBusy),
        ("HistoryActivity", testHistoryActivity),
        ("HistoryFailureTail", testHistoryFailureTail),
        ("ConversationSearch", testConversationSearch),
        ("ConversationSearchDisk", testConversationSearchDisk),
        ("Helpers", testHelpers),
        ("TurnBuilder", testTurnBuilder),
        ("Claude", testClaude),
        ("Codex", testCodex),
        ("Agy", testAgy),
        ("GeminiHistoryRegressions", testGeminiHistoryRegressions),
        ("GLGeminiDeleteReleasesWarm", testGLGeminiDeleteReleasesWarm),
        ("ClaudeCapabilityRefresh", testClaudeCapabilityRefresh),
        ("ClaudeHistory", testClaudeHistory),
        ("CodexHistory", testCodexHistory),
        ("CodexMixedHistory", testCodexMixedHistory),
        ("CodexConfiguredHome", testCodexConfiguredHome),
        ("CodexProjectionFreshness", testCodexProjectionFreshness),
        ("HistoryReadEfficiency", testHistoryReadEfficiency),
        ("SteerImages", testSteerImages),
        ("CodexSentImages", testCodexSentImages),
        ("CodexImageRecords", testCodexImageRecords),
        ("OneShotImagesDurable", testOneShotImagesDurable),
        ("LargeSentImageOriginals", testLargeSentImageOriginals),
        ("UnwritableSnapshotDir", testUnwritableSnapshotDir),
        ("CodexApp", testCodexApp),
        ("CodexRetryLogs", testCodexRetryLogs),
        ("CodexRetryTiming", testCodexRetryTiming),
        ("Acp", testAcp),
        ("QCQuestionCards", testQuestionCards),
        ("MEMcpElicitation", testMCPElicitation),
        ("GGGeminiDeleteLeftovers", testGGGeminiDeleteLeftovers),
        ("GGGeminiSteer", testGGGeminiSteer),
        ("Dsh", testDsh),
        ("Compact", testCompact),
        ("LineSplitter", testLineSplitter),
        ("BackendBoundaries", testBackendBoundaries),
        ("AcpResponses", testAcpResponses),
        ("AcpModelSelection", testAcpModelSelection),
        ("AcpWarmResponses", testAcpWarmResponses),
        ("DeadWarmRetry", testDeadWarmRetry),
        ("ExitAfterAdopt", testExitAfterAdopt),
        ("WarmExitNoReplay", testWarmExitNoReplay),
        ("WarmStopBeforeAdopt", testWarmStopBeforeAdopt),
        ("LiveInitialization", testLiveInitialization),
        ("CodexSkillsByWorkspace", testCodexSkillsByWorkspace),
        ("DeepSeekDelayedFinish", testDeepSeekDelayedFinish),
        ("GeminiCancelOrphan", testGeminiCancelOrphan),
        ("GeminiStopTail", testGeminiStopTail),
        ("LPStopOrphans", testLPStopOrphans),
        ("UnsentFollowUpStop", testUnsentFollowUpStop),
        ("ProcessBoundaries", testProcessBoundaries),
        ("AskStateLifecycle", testAskStateLifecycle),
        ("MalformedStreams", testMalformedStreams),
        ("PreviewTimeoutAndQuit", testPreviewTimeoutAndQuit),
        ("OfflineCLI", testOfflineCLI),
        ("DshStreamOrders", testDshStreamOrders),
        ("GitFileNames", testGitFileNames),
        ("PreviewSpecialFile", testPreviewSpecialFile),
        ("UsageNumbers", testUsageNumbers),
        ("UsageEarlyExit", testUsageEarlyExit),
        ("ShutdownDuringDshStartup", testShutdownDuringDshStartup)
    ]
    // 各组单独一个进程、8 路并行时测得的秒数（2026-11-19），只用来分片：按序号取模分片会把几个慢组凑进同一份，
    // 那一份就成了整套 tools/test.sh 最慢的一步。新加的慢组补一条；不补也只是回到不太均衡，不会出错。没列的按 1 秒算。
    let cost: [String: Double] = [
        "MEMcpElicitation": 26.5, "LiveInitialization": 21.4, "GeminiHistoryRegressions": 20.1, "QCQuestionCards": 18.4,
        "PreviewTimeoutAndQuit": 13.3, "OfflineCLI": 12.1, "AskStateLifecycle": 11.0, "GGGeminiSteer": 9.4,
        "GeminiTransientHolder": 9.4, "SessionOwnership": 8.8, "GLGeminiDeleteReleasesWarm": 8.7, "TypingResume": 7.3,
        "ConversationSearch": 5.8, "GeminiCancelOrphan": 5.7, "ClaudeCapabilityRefresh": 5.0, "LPStopOrphans": 4.1,
        "AssignedHistoryFixes": 4.0, "ProcessBoundaries": 3.5, "GeminiStopTail": 3.3, "ShutdownDuringDshStartup": 2.9,
        "UsageNumbers": 2.8, "HistoryActivity": 2.7, "CodexSkillsByWorkspace": 2.7, "CodexRetryTiming": 2.4,
        "WarmStopBeforeAdopt": 2.3, "WarmExitNoReplay": 2.1, "HistoryContext": 2.1, "DeadWarmRetry": 2.0
    ]
    let env = ProcessInfo.processInfo.environment
    // AIPETHUB_OFFLINE_SHARD=i/N：tools/test.sh 并行起 N 份，各跑第 i 份。分法：按耗时从大到小（相同的按序号）逐个放进当前最轻的一份，
    // 每份选中的组仍按序号执行。
    // AIPETHUB_OFFLINE_ONLY=词1,词2：只跑名字（不区分大小写）含任一个词的组，改代码时只测相关的。
    var picked = Array(groups.enumerated())
    if let shard = env["AIPETHUB_OFFLINE_SHARD"]?.split(separator: "/").compactMap({ Int($0) }), shard.count == 2, shard[1] > 0 {
        var load = [Double](repeating: 0, count: shard[1]), mine = Set<Int>()
        for g in picked.sorted(by: { (cost[$0.element.0] ?? 1, $1.offset) > (cost[$1.element.0] ?? 1, $0.offset) }) {
            let lightest = load.indices.min { load[$0] < load[$1] }!
            load[lightest] += cost[g.element.0] ?? 1
            if lightest == shard[0] { mine.insert(g.offset) }
        }
        picked = picked.filter { mine.contains($0.offset) }
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

