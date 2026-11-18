// 固定种子的随机分块、畸形字段、损坏历史文件与双流交错：解析器面对坏输入不崩、不丢字节；build/selftest offline。
import Foundation
import Cocoa
import SQLite3

func testMalformedStreams() {
    print("· 固定种子的分块、截断、畸形字段与历史文件")
    var seed: UInt64 = 0xA1B2C3D4
    func next(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(bound))
    }
    let d = AppDelegate()
    let fixture = [#"{"type":"system","session_id":"s"}"#, #"{"type":"result","result":"中文🙂"}"#, "not json", ""]
    let bytes = Array((fixture.joined(separator: "\n") + "尾行").utf8)
    // 每轮各记一项会把断言总数撑大几百；整个循环只记一项，失败时带上第一处的轮次、该轮开始时的种子和输入，够复现
    var splitFailure: String?
    for round in 0..<200 {
        let roundSeed = seed
        let length = next(bytes.count + 1), splitter = LineSplitter()
        var pos = 0, lines: [String] = [], ends: [Int] = []
        while pos < length {
            let end = min(length, pos + 1 + next(17))
            lines += splitter.feed(Data(bytes[pos..<end]))
            pos = end
            ends.append(end)
        }
        if let tail = splitter.flush() { lines.append(tail) }
        let expected = String(decoding: bytes.prefix(length), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let wants = length == 0 ? [] : (bytes[length - 1] == 10 ? Array(expected.dropLast()) : expected)
        let again = splitter.flush()
        if splitFailure == nil && (lines != wants || again != nil) {
            splitFailure = "第 \(round) 轮（种子 0x\(String(roundSeed, radix: 16))，截到 \(length) 字节，各块终点 \(ends)）：应为 \(wants)，实际 \(lines)，再 flush 得到 \(again ?? "nil")"
        }
    }
    check(splitFailure == nil, "随机分块和截断不改变字节顺序、flush 后无重复尾行：\(splitFailure ?? "")")
    let long = LineSplitter(), text = String(repeating: "中文🙂", count: 150_000)
    eq(long.feed(Data((text + "\n").utf8)), [text], "超过 1 MB 的合法单行完整保留")

    let shapes: [Any] = [NSNull(), true, -1, "bad", [], ["unexpected": "field"]]
    var shapeFailure: String?   // 同上：只记一项，带第一处失败的轮次、种子和字段
    for round in 0..<500 {
        let roundSeed = seed
        let c = ClaudeStreamParser(turn: TurnBuilder()), x = CodexAppParser(turn: TurnBuilder())
        let a = AcpParser(turn: TurnBuilder()), s = DshParser(turn: TurnBuilder())
        var obj: [String: Any] = [:]
        for key in ["message", "content", "event", "data", "item", "turn", "id", "index", "delta", "error"] { obj[key] = shapes[next(shapes.count)] }
        for type in ["assistant", "user", "stream_event", "result", "system"] { obj["type"] = type; c.feed(obj) }
        for method in ["item/started", "item/completed", "item/agentMessage/delta", "turn/completed", "error"] { x.notify(method, obj) }
        for type in ["tool_call", "tool_call_update", "agent_message_chunk", "plan", "usage_update"] { obj["sessionUpdate"] = type; a.update(obj) }
        for type in ["tool/call", "tool/result", "assistant/chunk", "assistant/message", "turn/end"] { obj["type"] = type; s.feed(obj) }
        if ![c.turn, x.turn, a.turn, s.turn].allSatisfy({ JSONSerialization.isValidJSONObject($0.finish(finalText: nil)) }) && shapeFailure == nil {
            shapeFailure = "第 \(round) 轮（种子 0x\(String(roundSeed, radix: 16))），字段 \(obj)"
        }
        let damaged = Data((0..<next(80)).map { _ in UInt8(next(256)) })
        _ = PBMessage(damaged).lengthFields()
        _ = agyDbTurns([(14, damaged), (15, damaged), (132, damaged)], cleanUser: { $0 })
    }
    check(shapeFailure == nil, "畸形字段仍产出可序列化结果：\(shapeFailure ?? "")")

    let path = NSTemporaryDirectory() + "aipethub-damaged-" + UUID().uuidString
    defer { try? FileManager.default.removeItem(atPath: path) }
    try! Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))
    check(d.withReadableSQLite(path) { _ in true } == nil, "损坏 SQLite 不进入读取回调")
    let history = #"{"type":"event_msg","payload":{"type":"user_message","message":"保留"}}"# + "\n{bad}\n{\"type\":"
    eq(d.rolloutMessages(history).messages.first?["text"], "保留", "坏 JSONL 与半写尾行不影响已有消息")

    if let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        let raw = path + ".jsonl", compressed = raw + ".zst"
        defer {
            try? FileManager.default.removeItem(atPath: raw)
            try? FileManager.default.removeItem(atPath: compressed)
        }
        try! Data(history.utf8).write(to: URL(fileURLWithPath: raw))
        let result = d.runTool(zstd, ["-q", "-o", compressed, raw], cwd: NSTemporaryDirectory(),
                               environment: ProcessInfo.processInfo.environment, timeout: 5)
        eq(result.status, 0, "生成压缩历史夹具")
        eq(d.readRollout(compressed), history, "zst 历史完整还原")
        let data = try! Data(contentsOf: URL(fileURLWithPath: compressed))
        try! data.prefix(data.count / 2).write(to: URL(fileURLWithPath: compressed))
        check(d.readRollout(compressed) == nil, "截断 zst 返回读取失败，不把半份解压结果当完整历史")
    } else { print("  未安装 zstd，跳过压缩文件用例") }
}

func testDshStreamOrders() {
    print("· DeepSeek 双流顺序与缺字段状态帧")
    let d = AppDelegate(); d.jsSink = { _, _ in }
    let req = AskRequest(agent: "deepseek", reqId: 301, prompt: "", model: "", effort: "", permissionMode: "", workspace: "", conversationId: "")
    let mux: [[String: Any]] = [
        ["type":"session/event", "event":["type":"turn/start", "data":["turn":1]]],
        ["type":"session/event", "event":["type":"assistant/message", "data":["turn":1,"step":1,"message":["content":[["type":"text","text":"complete"]]]]]],
        ["type":"session/event", "event":["type":"turn/end", "data":["reason":["kind":"completed"]]]]]
    let host: [[String: Any]] = [["type":"host/session-status","running":true], ["type":"host/session-status","running":false]]
    func orders(_ a: Int, _ b: Int, _ frames: [[String: Any]]) {
        if a == mux.count && b == host.count {
            let live = DeepSeekLiveTurn(app:d, req:req)
            frames.forEach { live.receiveForTest($0) }
            check(live.finishedForTest, "保持各流内部顺序的交错都能结束")
            check(live.replyForTest.reply == "complete", "交错流保留完整回答")
            live.input.abandon()
            return
        }
        if a < mux.count { orders(a+1,b,frames+[mux[a]]) }
        if b < host.count { orders(a,b+1,frames+[host[b]]) }
    }
    for model in ["", "fixture"] {
        let configure = AskRequest(agent: "deepseek", reqId: 302, prompt: "", model: model, effort: "low", permissionMode: "read-only", workspace: "", conversationId: "")
        d.dshConfigure("disconnected-" + model, configure, isNew: false)
        check(d.dshApplied["disconnected-" + model] == nil, "断线时配置失败不能缓存为成功")
    }
    orders(0,0,[])
    let live = DeepSeekLiveTurn(app:d,req:req)
    live.receiveForTest(host[0])
    live.receiveForTest(["type":"host/session-status"])
    live.receiveForTest(["type":"host/session-status","running":"unknown"])
    Thread.sleep(forTimeInterval:1.8)
    check(!live.finishedForTest, "缺失/类型错误的 running 不能当作停止")
    live.input.abandon()
}

