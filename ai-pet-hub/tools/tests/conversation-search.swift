// 正文搜索必须和打开历史看到的内容一致；所有夹具都留在临时目录。
import Cocoa
import SQLite3

func testConversationSearch() {
    let app = AppDelegate(), fm = FileManager.default
    let root = NSTemporaryDirectory() + "aipethub-search-" + UUID().uuidString
    try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    func write(_ name: String, _ content: String) -> String {
        let path = root + "/" + name
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    func search(_ query: String, _ paths: [(String, String)]?, agent: String = "claude") -> [String: Any] {
        let done = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        app.hooks.jsSink = { name, payload in
            if name == "onConversationsSearched", payload["complete"] as? Bool != false { result = payload; done.signal() }
        }
        app.searchConversations(agent: agent, query: query, files: paths)
        check(waitSignal(done), "正文搜索及时返回")
        app.hooks.jsSink = nil
        return result
    }
    do {
        let original = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", root, 1)
        let fake = root + "/claude"
        try! installFakeCLI(at:fake, behavior:"backend")
        _ = write("agents.json","[]")
        app.hooks.cliExecutable = fake
        app.hooks.geminiCliDir = root + "/gemini/cli"
        defer {
            if let original { setenv("CLAUDE_CONFIG_DIR", original, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
            app.hooks.cliExecutable = nil
        }
        for agent in ["claude","gemini"] {
            let cid = UUID().uuidString
            let req = AskRequest(agent:agent,reqId:1,prompt:"首问",model:"",effort:"",permissionMode:"",workspace:root,conversationId:"")
            app.rememberLocalEnding(req,cid:cid,text:"断点桃花",outcome:"failed",position:0)
            var items = [[String:Any]]()
            app.hooks.jsSink = { name, data in if name == "onConversationsListed" { items = data["items"] as? [[String:Any]] ?? [] } }
            app.listConversations(agent:agent); app.queue(for:agent).sync {}
            let listed = items.filter { str($0,"id") == cid }
            eq(listed.map { str($0,"cwd") }, [root], agent+" 未建记录的首问可从原项目打开")
            eq(search("断点桃花",nil,agent:agent)["ids"] as? [String], [cid], agent+" 未建记录的首问可按中断正文搜索")
            var project = [String]()
            app.hooks.jsSink = { name,data in if name == "onProjectConversations" { project = data["ids"] as? [String] ?? [] } }
            app.projectConversations(agent:agent, workspace:root); app.queue(for:agent).sync {}
            eq(project, [cid], agent+" 首问也在所属项目的会话清单中")
            if agent == "gemini" {
                app.hooks.localEndings?[0].removeValue(forKey:"newWorkspace")
                eq(search("断点桃花",nil,agent:agent)["ids"] as? [String], [cid], "旧版未记目录的 Gemini 首问仍可找回")
            }
            check(app.deleteOne(agent:agent,cid:cid), agent+" 仅有本机记录的首问可手动删除")
            eq(search("断点桃花",nil,agent:agent)["ids"] as? [String], [], agent+" 明确删除后首问从搜索消失")
            app.hooks.localEndings = []
        }
        app.hooks.localEndings = []
    }
    let pendingId = UUID().uuidString
    let pendingPath = write("pending.jsonl", #"{"type":"user","message":{"content":"开头记录"}}"# + "\n")
    _ = search("开头记录",[(pendingId,pendingPath)])
    app.hooks.geminiCliDir = root + "/gemini/cli"
    let gemPath = root + "/pending.sqlite"
    var gemDB: OpaquePointer?
    sqlite3_open(gemPath, &gemDB)
    sqlite3_exec(gemDB,"CREATE TABLE steps(idx INTEGER, step_type INTEGER, step_payload BLOB);",nil,nil,nil)
    sqlite3_close(gemDB)
    _ = search("半截桃子", [(pendingId,gemPath)], agent:"gemini")
    let savedRoot = TestHooks.dshSessionsRoot
    TestHooks.dshSessionsRoot = root + "/dsh"
    for agent in ["claude","gemini","deepseek","gpt"] {
        let source = ConversationSearchSource(cid:pendingId,paths:[pendingPath],kind:agent,item:[:])
        let before = app.searchStamp(source)
        if agent == "gpt" {
            app.noteCodexKnownEnding(turnId:"fixture-turn",outcome:"failed",text:"半截桃子",error:"fixture")
        } else {
            let req = AskRequest(agent:agent,reqId:12,prompt:"后来的问题",model:"",effort:"",permissionMode:"",workspace:root,conversationId:pendingId)
            app.rememberLocalEnding(req,cid:pendingId,text:"半截桃子",outcome:"failed", position:0)
        }
        check(app.searchStamp(source) != before, agent + " 本机结局更新使正文缓存失效")
    }
    TestHooks.dshSessionsRoot = savedRoot
    eq(search("半截桃子",[(pendingId,pendingPath)])["ids"] as? [String], [pendingId], "缓存过的 Claude 历史能搜到本机补记的半截回答")
    eq(search("半截桃子", [(pendingId,gemPath)], agent:"gemini")["ids"] as? [String], [pendingId], "缓存过的 Gemini 历史能搜到本机补记的半截回答")
    let meta = write("old-meta.jsonl", #"{"type":"user","cwd":"/project/山谷","message":{"content":"只有正文"}}"# + "\n" + #"{"type":"custom-title","customTitle":"北岸记录"}"# + "\n")
    for term in ["北岸", "山谷", "岸"] {
        let result = search(term, [("old-meta",meta)])
        eq((result["items"] as? [[String:Any]])?.compactMap { $0["id"] as? String } ?? [], ["old-meta"], "B3-15 全量候选按标题或工作空间搜索 " + term)
        eq(result["ids"] as? [String], [], "仅标题或目录命中时无需跳正文")
    }
    app.hooks.codexEnvironment = ["CODEX_HOME":root]
    try! fm.createDirectory(atPath:root + "/sessions", withIntermediateDirectories:true)
    let oldCodex = UUID().uuidString
    _ = write("sessions/rollout-old-" + oldCodex + ".jsonl",
              #"{"type":"session_meta","payload":{"id":"\#(oldCodex)","cwd":"/山谷","source":"exec"}}"# + "\n" +
              #"{"type":"event_msg","payload":{"type":"user_message","message":"稻谷回访"}}"# + "\n")
    let oldItem = app.searchSources(agent:"gpt", files:nil).sources.first { $0.cid == oldCodex }?.item
    eq(str(oldItem,"title"), "稻谷回访", "单字搜索的旧 rollout 候选带首问")
    eq(str(oldItem,"cwd"), "/山谷", "单字搜索的旧 rollout 候选带目录")
    eq(oldItem?["task"] as? Bool, true, "独立 exec 搜索命中仍归任务")
    let indexed = UUID().uuidString, stateDB = root + "/state_5.sqlite"
    var indexDB: OpaquePointer?
    sqlite3_open(stateDB,&indexDB)
    sqlite3_exec(indexDB,"CREATE TABLE threads(id,title,first_user_message,cwd,updated_at,rollout_path,archived,source); INSERT INTO threads VALUES('\(indexed)','','白鹭观察','',1,'',0,'cli');",nil,nil,nil)
    sqlite3_exec(indexDB,"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<301) INSERT INTO threads SELECT printf('new-%04d',i),'近期会话','白鹭','',i+1,'',0,'cli' FROM n;",nil,nil,nil)
    sqlite3_close(indexDB)
    var walks = 0
    app.hooks.rolloutLookupWalk = { walks += 1 }
    let matches = search("鹭",nil,agent:"gpt")["items"] as? [[String:Any]] ?? []
    check(walks <= 1, "单字查标题不会逐条遍历 rollout，实际=\(walks)")
    app.hooks.rolloutLookupWalk = nil
    eq(matches.count, 1, "有标题的近期会话仍只按显示标题匹配单字")
    eq(matches.first { str($0,"id") == indexed }?["title"] as? String, "白鹭观察", "Codex 全量单字搜索使用空标题会话的首问")
    sqlite3_open(stateDB,&indexDB)
    sqlite3_exec(indexDB,"INSERT INTO threads VALUES('legacy-short','旧标题','','',1,'/旧目录/rollout-test-legacy-short.jsonl',0,'cli');",nil,nil,nil)
    sqlite3_close(indexDB)
    let moved = write("sessions/rollout-test-legacy-short.jsonl", #"{"type":"session_meta","payload":{"id":"legacy-short"}}"#)
    let located = app.searchSources(agent:"gpt",files:nil).sources.first { $0.cid == "legacy-short" }?.paths ?? []
    check(located.contains(moved), "迁移后短编号仍可按文件名找到，实际=\(located)")
    // 当前 Codex 改名只写 threads.name，title 仍是首问；侧栏和搜索都要显示新名称。
    sqlite3_open(stateDB,&indexDB)
    sqlite3_exec(indexDB,"ALTER TABLE threads ADD COLUMN name TEXT; UPDATE threads SET name='苍鹭改名' WHERE id='new-0301'; UPDATE threads SET name='' WHERE id='\(indexed)';",nil,nil,nil)
    sqlite3_close(indexDB)
    let renamed = search("苍鹭改名",nil,agent:"gpt")["items"] as? [[String:Any]] ?? []
    eq(renamed.map { str($0,"id") }, ["new-0301"], "Codex 按改后的名称能搜到")
    eq(renamed.first.map { str($0,"title") }, "苍鹭改名", "Codex 搜索结果显示改后的名称")
    eq(search("白鹭观察",nil,agent:"gpt")["items"].flatMap { ($0 as? [[String:Any]])?.first { str($0,"id") == indexed } }.map { str($0,"title") }, "白鹭观察", "名称为空时仍用首问")
    var codexListed = [[String:Any]]()
    app.hooks.jsSink = { name, data in if name == "onConversationsListed" { codexListed = data["items"] as? [[String:Any]] ?? [] } }
    app.listCodex(); app.codexQueue.sync {}
    app.hooks.jsSink = nil
    eq(codexListed.first { str($0,"id") == "new-0301" }.map { str($0,"title") }, "苍鹭改名", "Codex 侧栏显示改后的名称")
    eq(codexListed.first { str($0,"id") == "new-0300" }.map { str($0,"title") }, "近期会话", "没改名的仍用原标题")
    try? fm.removeItem(atPath:stateDB)
    let child = UUID().uuidString
    _ = write("sessions/rollout-child-" + child + ".jsonl",
              #"{"type":"session_meta","payload":{"id":"\#(child)","source":{"subagent":"fixture"}}}"# + "\n")
    check(!app.searchSources(agent:"gpt", files:nil).sources.contains { $0.cid == child }, "Codex 搜索排除孤立子代理 rollout")
    var fullReads = 0
    app.hooks.codexFullRolloutRead = { path in if path.contains(child) { fullReads += 1 } }
    let childPath = root + "/sessions/rollout-child-" + child + ".jsonl"
    for _ in 0..<2 { _ = app.cachedRolloutSummary(childPath, Date(timeIntervalSince1970:1)) }
    eq(fullReads, 0, "刷新侧栏跳过子代理正文")
    app.hooks.codexFullRolloutRead = nil
    app.hooks.geminiCliDir = root + "/gemini/cli"
    let gemStore = app.geminiStores[0]
    try! fm.createDirectory(atPath:gemStore.root + "/conversations", withIntermediateDirectories:true)
    _ = fm.createFile(atPath:gemStore.database(child), contents:Data())
    var summariesDB: OpaquePointer?
    sqlite3_open(gemStore.summaries, &summariesDB)
    sqlite3_exec(summariesDB, "CREATE TABLE conversation_summaries(conversation_id,title,preview,last_modified_time,workspace_uris,nesting_depth,parent_conversation_id); INSERT INTO conversation_summaries VALUES('\(child)','child','','','',1,'parent');",nil,nil,nil)
    sqlite3_close(summariesDB)
    check(!app.searchSources(agent:"gemini", files:nil).sources.contains { $0.cid == child }, "Gemini 搜索排除摘要已标记的子代理数据库")
    let parent = "ordinary-legacy"
    let logs = gemStore.brain + "/" + parent + "/.system_generated/logs"
    try! fm.createDirectory(atPath:logs, withIntermediateDirectories:true)
    _ = fm.createFile(atPath:logs + "/transcript.jsonl",contents:Data())
    _ = fm.createFile(atPath:gemStore.database(parent),contents:Data())
    check(app.searchSources(agent:"gemini",files:nil).sources.contains { $0.cid == parent }, "普通旧会话没有摘要标题时仍可搜索数据库")
    let escaped = write("escaped.jsonl", #"{"type":"user","message":{"content":"\u4e2d\u6587 Hello\nWorld \"quoted\""}}"# + "\n")
    eq(search("中文", [("escaped", escaped)])["ids"] as? [String], ["escaped"], "JSON 转义中文搜索")
    eq(search("Hello\nWorld", [("escaped", escaped)])["ids"] as? [String], ["escaped"], "JSON 转义换行搜索")
    eq(search("\"quoted\"", [("escaped", escaped)])["ids"] as? [String], ["escaped"], "JSON 转义引号搜索")
    let hidden = write("hidden.jsonl", #"{"type":"user","protocol":"response_item","message":{"content":"Visible aBcDeF"}}"# + "\n")
    eq(search("response_item", [("hidden", hidden)])["ids"] as? [String], [], "协议字段不算可见正文")
    eq(search("abcdef", [("hidden", hidden)])["ids"] as? [String], ["hidden"], "可见正文保留不分大小写")
    let unicode = write("unicode.jsonl", #"{"type":"user","message":{"content":"Straße ΟΣ"}}"# + "\n")
    eq((search("strasse", [("unicode", unicode)])["items"] as? [[String: Any]])?.first?["searchMatch"] as? String, "Straße", "Unicode大小写命中携带实际可见原文")
    eq((search("οσ", [("unicode", unicode)])["items"] as? [[String: Any]])?.first?["searchMatch"] as? String, "ΟΣ", "希腊sigma变体继续采用原生不分大小写规则")
    let markdown = write("markdown.jsonl", #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello **world** [shown](https://hidden-target.invalid)"}]}}"# + "\n")
    eq(search("hello world", [("md", markdown)])["ids"] as? [String], ["md"], "按 Markdown 渲染后的可见文字确认")
    eq(search("hidden-target", [("md", markdown)])["ids"] as? [String], [], "链接目标不是页面文字")
    let phantom = write("phantom.jsonl", #"{"type":"assistant","message":{"content":[{"type":"text","text":"$\\phantom{ghostneedle}$ $\\hphantom{\\text{hiddenwidth}}$ $\\vphantom{\\frac{hiddenheight}{x}}$ $\\smash{\\text{shownneedle}}$ visibleoutside"}]}}"# + "\n")
    eq(search("ghostneedle", [("phantom", phantom)])["ids"] as? [String], [], "透明公式占位文字不是正文")
    eq(search("shownneedle", [("phantom", phantom)])["ids"] as? [String], ["phantom"], "smash 的零高度文字仍然可见")
    let phantomText = ConversationSearchText(app: app).messages([["role": "bot", "text": #"$\hphantom{\text{hiddenwidth}}$ $\vphantom{\frac{hiddenheight}{x}}$ visibleoutside"#]]).joined()
    check(!phantomText.contains("hiddenwidth") && !phantomText.contains("hiddenheight") && phantomText.contains("visibleoutside"), "横纵透明占位只排除自身，不吞旁边正文")
    let colored = ConversationSearchText(app: app).messages([["role": "bot", "text": #"$\color{transparent}{hidden\color{red}{shown}}$ $\phantom{\color{red}{ghost}}$"#]]).joined()
    check(colored.contains("shown") && !colored.contains("hidden") && !colored.contains("ghost"), "透明颜色继承允许子节点显式恢复，phantom仍隐藏彩色内容")
    let chipPath = root + "/aipethub-nonexistent-unique/foo.swift"
    let chip = write("chip.jsonl", "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"`" + chipPath + "`\"}]}}\n")
    eq(search("aipethub-nonexistent-unique", [("chip", chip)])["ids"] as? [String], ["chip"], "不存在的行内文件显示完整路径，目录名可以搜索")
    try! fm.createDirectory(atPath: (chipPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! "exists".write(toFile: chipPath, atomically: true, encoding: .utf8)
    eq(search("aipethub-nonexistent-unique", [("chip", chip)])["ids"] as? [String], [], "引用文件创建后显示短标签，旧路径缓存失效")
    try! fm.removeItem(atPath: chipPath)
    eq(search("aipethub-nonexistent-unique", [("chip", chip)])["ids"] as? [String], ["chip"], "引用文件删除后重新显示完整路径")
    let referencedImage = root + "/referenced-image.png"
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: referencedImage))
    let markdownImage = root + "/markdown-reference.png"
    let markdownImageHistory = write("markdown-image.jsonl", "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"![deletedneedle](" + markdownImage + ")\"}]}}\n")
    eq(search("deletedneedle", [("markdown-image", markdownImageHistory)])["ids"] as? [String], ["markdown-image"], "回答本地图片缺失后的可见标签可搜索")
    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: markdownImage))
    eq(search("deletedneedle", [("markdown-image", markdownImageHistory)])["ids"] as? [String], [], "回答图片恢复后隐藏alt文字，图片依赖使缓存失效")
    try! fm.removeItem(atPath: markdownImage)
    eq(search("deletedneedle", [("markdown-image", markdownImageHistory)])["ids"] as? [String], ["markdown-image"], "回答图片删除后缺图标签重新可搜")
    fm.createFile(atPath: markdownImage, contents: nil)
    let oversized = try! FileHandle(forWritingTo: URL(fileURLWithPath: markdownImage))
    try! oversized.truncate(atOffset: 8_000_001); try! oversized.close()
    eq(search("deletedneedle", [("markdown-image", markdownImageHistory)])["ids"] as? [String], ["markdown-image"], "过大图片沿用预览的缺图标签")
    let nonImage = write("not-image.txt", "plain text")
    let nonImageHistory = write("unsupported-image.jsonl", "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"![unsupportedneedle](" + nonImage + ")\"}]}}\n")
    eq(search("unsupportedneedle", [("unsupported", nonImageHistory)])["ids"] as? [String], ["unsupported"], "不是预览支持的图片格式也显示标签")
    let imageHistory = write("image-path.jsonl", "{\"type\":\"user\",\"message\":{\"content\":\"" + referencedImage + "\"}}\n")
    eq(search("aipethub-search-", [("image-path", imageHistory)])["ids"] as? [String], [], "临时图片存在时原目录被短标签替换")
    try! fm.removeItem(atPath: referencedImage)
    eq(search("aipethub-search-", [("image-path", imageHistory)])["ids"] as? [String], ["image-path"], "图片删除后原路径重新可见，缓存随外部文件失效")
    let renderer = ConversationSearchText(app: app)
    let cwdFile = root + "/nested/foo.swift"
    try! fm.createDirectory(atPath: (cwdFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! "exists".write(toFile: cwdFile, atomically: true, encoding: .utf8)
    let relative: [[String: Any]] = [["role": "bot", "text": "`nested/foo.swift`"]]
    renderer.prepare(relative, cwd: root)
    check(!renderer.messages(relative).joined().contains("nested/"), "相对文件按会话工作目录核对")
    let hinted: [[String: Any]] = [["role": "bot", "text": "`" + root + "/` `nested/foo.swift`"]]
    renderer.prepare(hinted, cwd: root + "/elsewhere")
    check(!renderer.messages(hinted).joined().contains("nested/"), "回答里的目录提示参与相对文件核对")
    let changed: [[String: Any]] = [["role": "bot", "text": "`missing/file.swift`", "files": [["path": root + "/missing/file.swift"]]]]
    renderer.prepare(changed, cwd: root)
    check(!renderer.messages(changed).joined().contains("missing/"), "本轮改过的文件即使不在仍保留可打开的短标签")
    // hunt9 uncovered：./x 按工作目录比完整路径，子目录里改过的同名文件不算它；不存在就和页面一样还原成写出的路径
    let nestedOnly: [[String: Any]] = [["role": "bot", "text": "`./gone/file.swift`", "files": [["path": root + "/sub/gone/file.swift"]]]]
    renderer.prepare(nestedOnly, cwd: root)
    check(renderer.messages(nestedOnly).joined().contains("./gone/file.swift"), "子目录改过的同名文件不让根目录的 ./ 路径保留短标签，实际 \(renderer.messages(nestedOnly))")
    // 相对子目录写的路径（工作目录下没有 gone2/，改的是 app/gone2/file.swift）仍按结尾配上改动，搜索也保留可打开的短标签
    let subRelative: [[String: Any]] = [["role": "bot", "text": "`gone2/file.swift`", "files": [["path": root + "/app/gone2/file.swift"]]]]
    renderer.prepare(subRelative, cwd: root)
    check(!renderer.messages(subRelative).joined().contains("gone2/"), "子目录里改过的文件按结尾配上，保留短标签，实际 \(renderer.messages(subRelative))")
    let large = root + "/large.jsonl"
    fm.createFile(atPath: large, contents: nil)
    let fh = try! FileHandle(forWritingTo: URL(fileURLWithPath: large))
    try! fh.write(contentsOf: Data(repeating: 0x20, count: 60_000_000))
    try! fh.write(contentsOf: Data(("\n" + #"{"type":"user","message":{"content":"large-visible-needle"}}"# + "\n").utf8))
    try! fh.close()
    eq(search("large-visible-needle", [("large", large)])["ids"] as? [String], ["large"], "超过 60MB 仍搜正文")
    _ = write("hidden.jsonl", #"{"type":"user","message":{"content":"changed-visible"}}"# + "\n")
    eq(search("abcdef", [("hidden", hidden)])["ids"] as? [String], [], "历史文件变化后缓存失效")
    let mixed = write("mixed.jsonl", #"{"type":"user","message":{"content":"中\u6587 \u0041Bc \ud83d\ude80 \/alpha/beta \\u4e2d"}}"# + "\n")
    eq(search("中文", [("mix", mixed)])["ids"] as? [String], ["mix"], "一个词内混合 Unicode 转义")
    eq(search("abc", [("mix", mixed)])["ids"] as? [String], ["mix"], "转义英文保留大小写规则")
    eq(search("🚀 /alpha/beta", [("mix", mixed)])["ids"] as? [String], ["mix"], "代理对与部分斜杠转义")
    eq(search(#"\u4e2d"#, [("mix", mixed)])["ids"] as? [String], ["mix"], "字面 Unicode 转义不能被粗筛抹掉")
    let boundary = write("boundary.jsonl", String(repeating: " ", count: 1_048_560) + "\n" + #"{"type":"user","message":{"content":"中文跨块needle"}}"# + "\n")
    eq(search("中文跨块needle", [("boundary", boundary)])["ids"] as? [String], ["boundary"], "分块边界保留完整关键词")
    let compact = write("compact.jsonl", #"{"type":"user","message":{"content":"/compress"}}"# + "\n")
    eq(search("compress", [("compact", compact)])["ids"] as? [String], [], "页面隐藏的压缩命令不命中")
    let step = write("step.jsonl", #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"echo command-needle"}}]}}"# + "\n")
    eq(search("运行命令", [("step", step)])["ids"] as? [String], ["step"], "界面生成的工具标题也可搜索")
    eq(search("command-needle", [("step", step)])["ids"] as? [String], ["step"], "折叠工具详情也可搜索")
    let missing = search("needle", [("missing", root + "/missing.jsonl")])
    check(!(missing["unavailable"] as? String ?? "").isEmpty, "无法读取的来源明确返回没搜")
    let database = root + "/history.sqlite"
    var db: OpaquePointer?
    sqlite3_open(database, &db)
    sqlite3_exec(db, "CREATE TABLE thread_items(thread_id TEXT,item_type TEXT,item_json TEXT,created_at_ms INTEGER,completed_at_ms INTEGER,rollout_ordinal INTEGER);", nil, nil, nil)
    sqlite3_exec(db, "INSERT INTO thread_items VALUES('db-only','userMessage','{\"content\":[{\"type\":\"text\",\"text\":\"database-visible-needle\"}]}',0,0,0);", nil, nil, nil)
    sqlite3_close(db)
    eq(search("database-visible-needle", [("db-only", database)], agent: "gpt")["ids"] as? [String], ["db-only"], "只有数据库的 Codex 正文")
    // 旧 schema 没有投影/回合表，也必须按当前会话的真实内容复核，不能拿全库 WAL 变化代替。
    var databaseLoads = 0
    app.hooks.conversationSearchLoaded = { agent, cid in if agent == "gpt" && cid == "db-only" { databaseLoads += 1 } }
    sqlite3_open(database, &db)
    func sql(_ statement: String) { check(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "缓存回归数据库写入成功") }
    sql("PRAGMA journal_mode=WAL;")
    _ = search("database-visible-needle", [("db-only", database)], agent: "gpt")
    let beforeUnrelatedWrite = databaseLoads
    sql("INSERT INTO thread_items VALUES('another-session','userMessage','{\"content\":[{\"type\":\"text\",\"text\":\"another-body\"}]}',0,0,0);")
    eq(search("database-visible-needle", [("db-only", database)], agent: "gpt")["ids"] as? [String], ["db-only"], "别的会话写WAL后当前正文仍命中")
    eq(databaseLoads, beforeUnrelatedWrite, "共享数据库只有别的会话更新时不重解析正文")
    sql("UPDATE thread_items SET item_json='{\"content\":[{\"type\":\"text\",\"text\":\"same-ordinal-new-body\"}]}' WHERE thread_id='db-only';")
    eq(search("same-ordinal-new-body", [("db-only", database)], agent: "gpt")["ids"] as? [String], ["db-only"], "同ordinal正文变化使缓存失效")
    check(databaseLoads > beforeUnrelatedWrite, "当前会话正文更新确实重新解析")
    sql("INSERT INTO thread_items VALUES('db-only','commandExecution','{\"command\":\"echo fixture\",\"aggregatedOutput\":\"old-tool-output\",\"status\":\"completed\"}',0,0,1);")
    _ = search("old-tool-output", [("db-only", database)], agent: "gpt")
    let beforeToolUpdate = databaseLoads
    sql("UPDATE thread_items SET item_json='{\"command\":\"echo fixture\",\"aggregatedOutput\":\"new-tool-output\",\"status\":\"failed\"}' WHERE thread_id='db-only' AND rollout_ordinal=1;")
    eq(search("new-tool-output", [("db-only", database)], agent: "gpt")["ids"] as? [String], ["db-only"], "同ordinal工具结果变化也使缓存失效")
    check(databaseLoads > beforeToolUpdate, "当前工具结果更新确实重新解析")
    sqlite3_close(db); db = nil
    _ = write("history.sqlite", "damaged database")
    let damagedResult = search("same-ordinal-new-body", [("db-only", database)], agent: "gpt")
    check((damagedResult["ids"] as? [String] ?? []).isEmpty && !(damagedResult["unavailable"] as? String ?? "").isEmpty, "数据库损坏后不得沿用旧缓存命中")
    app.hooks.conversationSearchLoaded = nil
    let packed = write("rollout.jsonl.zst", "compressed fixture")
    _ = write("rollout.jsonl.zst.plain", #"{"type":"event_msg","payload":{"type":"user_message","message":"compressed-visible-needle"}}"# + "\n")
    let executable = root + "/zstd"
    try! installFakeCLI(at: executable, behavior: "zstd-read")
    app.hooks.cliExecutable = executable
    eq(search("compressed-visible-needle", [("packed", packed)], agent: "gpt")["ids"] as? [String], ["packed"], "压缩 Codex 会话通过现成解压器搜索")
    app.hooks.cliExecutable = nil
    let corrupt = write("corrupt.db", "not a SQLite database")
    check(!(search("needle", [("corrupt", corrupt)], agent: "gemini")["unavailable"] as? String ?? "").isEmpty, "损坏数据库不能静默当成空正文")
    let oldest = #"{"type":"user","message":{"content":"very-old-search-needle"}}"# + "\n"
    let recent = #"{"type":"user","message":{"content":"recent visible message"}}"# + "\n"
    let longHistory = write("long.jsonl", oldest + String(repeating: recent, count: 5000))
    let longHit = search("very-old-search-needle", [("long", longHistory)])
    eq((longHit["items"] as? [[String: Any]])?.first?["searchLimit"] as? Int, 5001, "深历史命中携带完整展开范围")
    let duplicateId = UUID().uuidString
    let currentCopy = write("current-copy.jsonl", #"{"type":"user","message":{"content":"current-copy-visible"}}"# + "\n")
    let obsoleteCopy = write("obsolete-copy.jsonl", #"{"type":"user","message":{"content":"obsolete-copy-needle"}}"# + "\n")
    app.claudeQueue.sync { _ = app.claudeItem((cid: duplicateId, path: currentCopy, mtime: Date())) }
    eq(search("obsolete-copy-needle", [(duplicateId, currentCopy), (duplicateId, obsoleteCopy)])["ids"] as? [String], [], "同cid旧副本的正文不能冒充当前打开的会话")
    eq(search("current-copy-visible", [(duplicateId, obsoleteCopy), (duplicateId, currentCopy)])["ids"] as? [String], [duplicateId], "同cid只搜实际打开路径且命中ID不重复")
    let openedCopy = awaitCallback(app, "onConversationLoaded") { app.loadClaude(cid: duplicateId) }
    check(openedCopy != nil, "同cid副本实际打开完成")
    eq((openedCopy?["messages"] as? [[String: Any]])?.first?["text"] as? String, "current-copy-visible", "搜索和实际打开仍是相同副本")
    let cache = ConversationSearchCache(limit: 100, disk: nil)
    cache.put("a", stamp: "one", texts: [String(repeating: "a", count: 60)], item: [:])
    cache.put("b", stamp: "two", texts: [String(repeating: "b", count: 60)], item: [:])
    check(cache.bytes <= 100 && cache.get("a", stamp: "one") == nil && cache.get("b", stamp: "two") != nil, "可见文字缓存按总字节淘汰")
    check(cache.get("b", stamp: "changed") == nil, "缓存指纹改变必须重读")
    print("正文搜索回归完成：累计 \(failures) / \(checks) 项未通过")
}

func runConversationSearchBenchmark() {
    let app = AppDelegate(), lock = NSLock()
    let query = CommandLine.arguments.dropFirst(2).first ?? "测试"
    // 显式给临时目录才能在两个独立进程间测磁盘复用；自测不能写用户的真实缓存。
    if let path = CommandLine.arguments.dropFirst(3).first {
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard root.path.hasPrefix(temporary) else { print("性能测量缓存必须放在临时目录内"); return }
        TestHooks.conversationSearchDiskRoot = root
    }
    let cache = ConversationSearchCache.shared
    defer { cache.disk?.flush(); app.dshServer.shutdown() }
    for pass in 1...2 {
        let start = Date(), done = DispatchSemaphore(value: 0)
        var finished = Set<String>(), first: [String: Double] = [:], loads: [String: Int] = [:]
        app.hooks.conversationSearchLoaded = { agent, _ in
            lock.lock(); loads[agent, default: 0] += 1; lock.unlock()
        }
        app.hooks.jsSink = { name, payload in
            guard name == "onConversationsSearched", let agent = payload["agent"] as? String else { return }
            lock.lock(); defer { lock.unlock() }
            let elapsed = Date().timeIntervalSince(start)
            if first[agent] == nil { first[agent] = elapsed }
            if payload["complete"] as? Bool == true, finished.insert(agent).inserted {
                print(String(format: "pass=%d agent=%@ seconds=%.3f first_batch=%.3f scanned=%d hits=%d loaded=%d unavailable=%@", pass, agent, elapsed, first[agent] ?? elapsed,
                    payload["scanned"] as? Int ?? 0, (payload["ids"] as? [String] ?? []).count, loads[agent] ?? 0, payload["unavailable"] as? String ?? "none"))
                fflush(stdout)
                if finished.count == 4 { done.signal() }
            }
        }
        for agent in ["claude", "gpt", "gemini", "deepseek"] { app.searchConversations(agent: agent, query: query) }
        if done.wait(timeout: .now() + 1200) != .success { print("搜索性能测试超时"); break }
        print(String(format: "pass=%d total_seconds=%.3f cache_bytes=%d cache_limit=%d", pass, Date().timeIntervalSince(start), ConversationSearchCache.shared.bytes, ConversationSearchCache.shared.limit))
        fflush(stdout)
        cache.disk?.flush()
        if let disk = cache.disk {
            let files = (try? FileManager.default.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: nil)) ?? []
            let bytes = files.reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? Int) ?? 0) }
            print("disk_bytes=\(bytes) disk_limit=\(disk.limit)")
        }
    }
    app.hooks.jsSink = nil
    app.hooks.conversationSearchLoaded = nil
}
