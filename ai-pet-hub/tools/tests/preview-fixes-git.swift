// 夹具和三段的分工见 preview-fixes.swift。
import Foundation

func runPreviewGitTests(_ f: PreviewFixture) {
    let (d, fm, dir) = (f.d, f.fm, f.dir), write = f.write, reply = f.reply, git = f.git
    _ = git(["init", "-q"])
    _ = git(["config", "user.name", "Fixture"]); _ = git(["config", "user.email", "fixture@example.invalid"])
    write("dirty.txt", "base\noriginal\n")
    write("restore.txt", "clean\n")
    write("delete tracked.txt", "tracked\n")
    try! Data([0, 5, 6]).write(to: URL(fileURLWithPath: dir + "/existing.bin"))
    _ = git(["add", "."]); _ = git(["commit", "-qm", "fixture"])
    write("dirty.txt", "user change\noriginal\n")
    _ = git(["add", "dirty.txt"])   // 用户已有的暂存内容也必须保留
    write("restore.txt", "dirty\n")
    write("old untracked.txt", "old content\n")
    let index = try! Data(contentsOf: URL(fileURLWithPath: dir + "/.git/index"))
    let head = git(["rev-parse", "HEAD"])
    let before = d.gitSnapshot(dir)!
    if before.content == nil {
        // 内容快照没拍成（会悄悄退回旧的状态对比，下面几条就会失败）：把是哪一步、git 报了什么打出来。
        // 不同版本的 git 行为不一样，本机过了别的机器不一定过。
        let tmp = NSTemporaryDirectory() + "aipethub-snapdiag-\(getpid())"
        try? fm.createDirectory(atPath: tmp + "/objects/info", withIntermediateDirectories: true)
        let objects = d.runGit(["rev-parse", "--path-format=absolute", "--git-path", "objects"], in: dir)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? (objects + "\n").write(toFile: tmp + "/objects/info/alternates", atomically: true, encoding: .utf8)
        try? fm.copyItem(atPath: dir + "/.git/index", toPath: tmp + "/index")
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_INDEX_FILE"] = tmp + "/index"; env["GIT_OBJECT_DIRECTORY"] = tmp + "/objects"; env["GIT_LITERAL_PATHSPECS"] = "1"
        print("快照诊断：git=\(d.gitPath ?? "无") \(d.runTool(d.gitPath ?? "/usr/bin/git", ["--version"], cwd: dir, timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines)) objects=\(objects)")
        for args in [["rev-parse", "--path-format=absolute", "--git-path", "index"],
                     ["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
                     ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false", "add", "-u", "--", "."],
                     ["write-tree"], ["ls-files", "-z", "--cached"]] {
            let r = d.runTool(d.gitPath ?? "/usr/bin/git", ["-C", dir] + args, cwd: dir, environment: env, timeout: 30)
            print("快照诊断：git \(args.joined(separator: " ")) → \(r.status) \(r.err.prefix(300).replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        try? fm.removeItem(atPath: tmp)
    }
    write("dirty.txt", "user change\nAI change\n")
    write("restore.txt", "clean\n")
    try! fm.removeItem(atPath: dir + "/old untracked.txt")
    try! fm.removeItem(atPath: dir + "/delete tracked.txt")
    try! Data([0, 7, 8, 9]).write(to: URL(fileURLWithPath: dir + "/existing.bin"))
    try! fm.createDirectory(atPath: dir + "/子目录", withIntermediateDirectories: true)
    write("子目录/新 文件.txt", "new\n")
    try! Data([0, 1, 2, 3]).write(to: URL(fileURLWithPath: dir + "/binary.bin"))
    let changes = d.gitChangedFiles(since: before)
    func change(_ name: String) -> [String: Any]? { changes.first { $0["path"] as? String == before.root + "/" + name } }
    var compared = Set<String>()
    let transient = (before.root as NSString).resolvingSymlinksInPath + "/created-then-removed"
    _ = d.gitChangedFiles(since: before, toolPaths:[transient], compared:{ compared = $0 })
    check(compared.contains(transient), "前后都不存在的工具路径已确认净差异为零，实际=\(compared)")
    let diff = change("dirty.txt")?["diff"] as? String ?? ""
    check(diff.contains("-original") && diff.contains("+AI change") && !diff.contains("+user change") && !diff.contains("-base"), "N02 只算本轮新增差异")
    check(change("restore.txt")?["kind"] as? String == "edit", "N03 改回干净仍报 edit")
    check(change("old untracked.txt")?["kind"] as? String == "delete", "N03 删除原有未跟踪文件")
    check(change("子目录/新 文件.txt")?["kind"] as? String == "create", "N03 空格中文子目录新增")
    check(change("binary.bin")?["kind"] as? String == "create", "N03 二进制新增")
    check(change("existing.bin")?["kind"] as? String == "edit" && change("existing.bin")?["diff"] as? String == "", "N02 二进制修改保持空 diff")
    check(change("delete tracked.txt")?["kind"] as? String == "delete", "N03 已跟踪文件删除")
    check((try! Data(contentsOf: URL(fileURLWithPath: dir + "/.git/index"))) == index, "快照不改变真实 index 字节")
    check(git(["rev-parse", "HEAD"]) == head && git(["stash", "list"]).isEmpty, "快照不改变 HEAD/stash")

    try! Data(repeating:0,count:1_000_001).write(to: URL(fileURLWithPath:dir + "/stage.bin"))
    let beforeStage = d.gitSnapshot(dir)!
    _ = git(["add","stage.bin"])
    let staged = d.gitChangedFiles(since:beforeStage).first { str($0,"path").hasSuffix("/stage.bin") }
    check(staged == nil, "大文件只暂存时没有改动卡，实际=\(str(staged,"kind"))")
    let beforeUnstage = d.gitSnapshot(dir)!
    _ = git(["rm","-q","--cached","--","stage.bin"])
    let unstaged = d.gitChangedFiles(since:beforeUnstage).first { str($0,"path").hasSuffix("/stage.bin") }
    check(unstaged == nil, "大文件只取消暂存、内容不变时没有改动卡，实际=\(str(unstaged,"kind"))")
    _ = git(["add","stage.bin"])
    let beforeRealEdit = d.gitSnapshot(dir)!
    _ = git(["rm","-q","--cached","--","stage.bin"])
    try! Data(repeating:1,count:1_000_002).write(to: URL(fileURLWithPath:dir + "/stage.bin"))
    let edited = d.gitChangedFiles(since:beforeRealEdit).first { str($0,"path").hasSuffix("/stage.bin") }
    check(str(edited,"kind") == "edit", "取消暂存后又改了内容的大文件仍报改动，实际=\(str(edited,"kind"))")
    try! Data(repeating:0,count:1_000_001).write(to: URL(fileURLWithPath:dir + "/stage.bin"))
    _ = git(["add","stage.bin"])
    write("draft-output.csv", "仍在\n")
    for i in 0..<65 { write("artifact-\(i)", "产物") }
    write("zzz.txt", "旧\n")
    let beforeIgnore = d.gitSnapshot(dir)!
    write(".gitignore", "draft-output.csv\nartifact-*\n")
    write("zzz.txt", "新\n")
    let ignored = d.gitChangedFiles(since:beforeIgnore)
    let keptPatch = ignored.first { str($0,"path").hasSuffix("/zzz.txt") }
    check(str(keptPatch,"diff").contains("+新"), "新增忽略规则后保留实际改动的补丁，实际=\(str(keptPatch,"diff"))")
    let vanished = ignored.first { str($0,"path").hasSuffix("/draft-output.csv") }
    check(vanished == nil && ignored.contains { str($0,"path").hasSuffix("/.gitignore") }, "新忽略的现存文件不报删除，实际 \(str(vanished,"kind"))")
    let beforeReveal = d.gitSnapshot(dir)!
    write(".gitignore", "artifact-*\n")
    let revealed = d.gitChangedFiles(since:beforeReveal).first { str($0,"path").hasSuffix("/draft-output.csv") }
    check(str(revealed,"kind") == "included" && int(revealed,"added") == 0 && str(revealed,"diff").isEmpty,
          "撤销忽略只标为纳入比较，实际=\(str(revealed,"kind"))/+\(int(revealed,"added"))")
    // 目录里只有被忽略的文件时 Git 会把整个目录合并列出；旁边新建的未忽略文件仍是本轮新建，要有补丁。
    try! fm.createDirectory(atPath: dir + "/public", withIntermediateDirectories: true)
    write("public/existing.tmp", "旧产物\n")
    write(".gitignore", "artifact-*\npublic/*.tmp\n")
    let beforeSibling = d.gitSnapshot(dir)!
    write("public/new.js", "console.log(1)\n")
    let sibling = d.gitChangedFiles(since:beforeSibling).first { str($0,"path").hasSuffix("/public/new.js") }
    check(str(sibling,"kind") == "create" && str(sibling,"diff").contains("+console.log(1)"),
          "忽略文件旁新建的文件仍是新建并带补丁，实际=\(str(sibling,"kind"))/\(str(sibling,"diff"))")
    let beforeDirReveal = d.gitSnapshot(dir)!
    write(".gitignore", "artifact-*\n")
    let dirRevealed = d.gitChangedFiles(since:beforeDirReveal).first { str($0,"path").hasSuffix("/public/existing.tmp") }
    check(str(dirRevealed,"kind") == "included" && str(dirRevealed,"diff").isEmpty,
          "撤销规则后目录里原有的忽略文件标为纳入比较，实际=\(str(dirRevealed,"kind"))")
    try! fm.removeItem(atPath: dir + "/public")
    write("mixed.txt", "start\n")
    try! fm.createSymbolicLink(atPath: dir + "/mixed-link", withDestinationPath: "dirty.txt")
    write("mode", "mixed-edits")
    let mixedCLI = dir + "/mixed-cli"
    try! installFakeCLI(at: mixedCLI, behavior: "backend")
    d.hooks.cliExecutable = mixedCLI
    let mixed = reply("onAgentResponse") {
        d.ask(AskRequest(agent:"claude", reqId:78, prompt:"编辑并追加", model:"haiku", effort:"",
                         permissionMode:"default", workspace:dir, conversationId:"", browserTools:false))
    }
    d.hooks.cliExecutable = nil
    let card = (mixed["files"] as? [[String: Any]])?.first { str($0, "path").hasSuffix("/mixed.txt") }
    let names = (mixed["files"] as? [[String: Any]] ?? []).map { fileBaseName(str($0,"path")) }
    check(names.contains("mixed-link") && names.contains("mixed.txt"), "B3-17 软链接与目标文件分别显示，实际 \(names)")
    let observed = (mixed["files"] as? [[String: Any]])?.first { str($0,"path").hasSuffix("/mixed-link") }
    check(observed?["workspaceOnly"] as? Bool == true && card?["workspaceOnly"] as? Bool != true,
          "只靠快照发现的路径单列为同期工作区改动，标记=\(String(describing:observed?["workspaceOnly"]))")
    let patch = str(card, "diff")
    check(patch.contains("-start") && patch.contains("+EDIT") && patch.contains("+shell") && int(card, "added") == 2,
          "B6 文件卡显示编辑和命令的净改动，实际 \(patch)")
    let edit = (mixed["steps"] as? [[String: Any]])?.first { str($0, "kind") == "edit" }
    check(int(edit, "added") == 1 && int(edit, "removed") == 1, "B6 编辑步骤仍只显示自己的差异")

    let undoWorkspace = ((NSTemporaryDirectory() + "aipethub-undo-" + UUID().uuidString) as NSString).resolvingSymlinksInPath
    try! fm.createDirectory(atPath:undoWorkspace, withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:undoWorkspace) }
    try! "start\n".write(toFile:undoWorkspace + "/mixed.txt", atomically:true, encoding:.utf8)
    let undoCLI = undoWorkspace + "/cli"
    try! installFakeCLI(at:undoCLI, behavior:"backend")
    try! "undo-edits".write(toFile:undoWorkspace + "/mode", atomically:true, encoding:.utf8)
    d.hooks.cliExecutable = undoCLI
    let undo = reply("onAgentResponse") {
        d.ask(AskRequest(agent:"claude",reqId:79,prompt:"还原",model:"haiku",effort:"",permissionMode:"default",workspace:undoWorkspace,conversationId:"",browserTools:false))
    }
    let edits = undo["files"] as? [[String:Any]] ?? []
    check(edits.isEmpty && (undo["unchangedPaths"] as? [String])?.contains { ($0 as NSString).standardizingPath == undoWorkspace + "/mixed.txt" } == true,
          "普通目录同轮改回原文不留改动卡，实际增删=\(edits.map { [int($0,"added"),int($0,"removed")] })")
    d.hooks.cliExecutable = mixedCLI
    let changedPlain = reply("onAgentResponse") {
        d.ask(AskRequest(agent:"claude",reqId:80,prompt:"改动",model:"haiku",effort:"",permissionMode:"default",workspace:undoWorkspace,conversationId:"",browserTools:false))
    }
    d.hooks.cliExecutable = nil
    let reported = (changedPlain["files"] as? [[String:Any]])?.first { str($0,"path").hasSuffix("/mixed.txt") }
    check(reported?["toolTotal"] as? Bool == true && int(reported,"added") == 1, "普通目录保留实际改动并标注工具累计行数")
    // 大文件走轻量路径，不能落到真实对象库；覆盖大小阈值跨越和删掉大文件。
    let largePath = dir + "/dataset.bin"
    fm.createFile(atPath: largePath, contents: nil)
    let largeHandle = try! FileHandle(forWritingTo: URL(fileURLWithPath: largePath))
    try! largeHandle.truncate(atOffset: 200_000_000); try! largeHandle.close()
    let objectFiles = (fm.enumerator(atPath: dir + "/.git/objects")?.allObjects as? [String] ?? []).sorted()
    let largeBefore = d.gitSnapshot(dir)!
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: largePath)
    let largeChange = d.gitChangedFiles(since: largeBefore).first { ($0["path"] as? String)?.hasSuffix("/dataset.bin") == true }
    check(largeChange?["kind"] as? String == "edit" && largeChange?["diff"] as? String == "", "N02 大文件只报变化")
    check((fm.enumerator(atPath: dir + "/.git/objects")?.allObjects as? [String] ?? []).sorted() == objectFiles, "快照不向真实对象库写文件")
    try! fm.removeItem(atPath: largePath)
    check(d.gitChangedFiles(since: largeBefore).contains { ($0["path"] as? String)?.hasSuffix("/dataset.bin") == true && $0["kind"] as? String == "delete" }, "N03 删除大文件")
    let savedGit = d.gitPath; d.gitPath = nil
    check(d.gitSnapshot(dir) == nil, "git 不可用沿用无快照行为")
    d.gitPath = savedGit

    // 父仓库的 gitlink 不动，子模块的工作树在回答前已经脏了。
    let parent = dir + "/submodule-fixture", moduleDir = parent + "/module"
    try! fm.createDirectory(atPath: moduleDir, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: parent)
    _ = d.runGit(["init", "-q"], in: moduleDir)
    let source = moduleDir + "/source.txt"
    try! "base\n".write(toFile: source, atomically: true, encoding: .utf8)
    _ = d.runGit(["add","."], in: moduleDir)
    _ = d.runGit(["-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","moduleDir"], in: moduleDir)
    _ = d.runGit(["add","module"], in: parent)
    let clean = d.gitSnapshot(parent)!
    let cleanModule = clean.content?.modules["module"]
    let wroteIndex = cleanModule.map { fm.fileExists(atPath:$0.directory.appendingPathComponent("index").path) } ?? false
    check(cleanModule != nil && !wroteIndex, "干净子模块直接使用已提交的树，实际写临时索引=\(wroteIndex)")
    try! "dirty\n".write(toFile: source, atomically: true, encoding: .utf8)
    let firstEdit = d.gitChangedFiles(since:clean).first { str($0,"path").hasSuffix("/module/source.txt") }
    check(str(firstEdit,"diff").contains("-base") && str(firstEdit,"diff").contains("+dirty"), "干净子模块开始修改时保留完整补丁")
    let subBefore = d.gitSnapshot(parent)!
    try! "changed\n".write(toFile: source, atomically: true, encoding: .utf8)
    let subChanges = d.gitChangedFiles(since: subBefore)
    let subfile = subChanges.first { str($0, "path").hasSuffix("/module/source.txt") }
    check(str(subfile, "diff").contains("-dirty") && str(subfile, "diff").contains("+changed"),
          "B3-16 父项目记录子模块里本轮改动，实际 \(subChanges.map { str($0, "path") })")
    _ = d.runGit(["config","filter.subcheck.clean","touch subfilter-ran; cat"], in:moduleDir)
    try! "source.txt filter=subcheck\n".write(toFile:moduleDir+"/.gitattributes",atomically:true,encoding:.utf8)
    try! "BASE\n".write(toFile:source,atomically:true,encoding:.utf8)
    _ = d.gitSnapshot(parent)
    let ran = fm.fileExists(atPath:moduleDir+"/subfilter-ran")
    check(!ran,"父级快照不运行子模块过滤器，实际执行=\(ran)")
    let bulk = dir + "/bulk-fixture"
    try! fm.createDirectory(atPath: bulk, withIntermediateDirectories: true)
    _ = d.runGit(["init","-q"], in: bulk)
    let oldPlan = bulk + "/plan", obsolete = bulk + "/obsolete"
    try! "一\n二\n三\n".write(toFile:oldPlan, atomically:true, encoding:.utf8)
    try! "旧\n".write(toFile:obsolete, atomically:true, encoding:.utf8)
    let initial = d.gitSnapshot(bulk)!
    try! "一\n改\n三\n".write(toFile:oldPlan, atomically:true, encoding:.utf8)
    try! fm.removeItem(atPath:obsolete)
    let firstDiff = d.gitChangedFiles(since:initial)
    let plan = firstDiff.first { str($0,"path").hasSuffix("/plan") }
    check(str(plan,"kind") == "edit" && int(plan,"added") == 1 && int(plan,"removed") == 1 &&
          firstDiff.contains { str($0,"path").hasSuffix("/obsolete") && str($0,"kind") == "delete" },
          "空索引仓库保留修改和删除，实际=\(firstDiff)")
    try! fm.removeItem(atPath:oldPlan)
    let script = bulk + "/tool.sh"
    try! "echo test\n".write(toFile:script, atomically:true, encoding:.utf8)
    try! fm.setAttributes([.posixPermissions:0o644],ofItemAtPath:script)
    let modeBefore = d.gitSnapshot(bulk)!
    try! fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:script)
    let modeFiles = d.gitChangedFiles(since:modeBefore)
    check(modeFiles.count == 1 && str(modeFiles.first,"kind") == "edit" && int(modeFiles.first,"added") == 0 && int(modeFiles.first,"removed") == 0, "未跟踪脚本执行位变化，实际=\(modeFiles)")
    try! fm.removeItem(atPath:script)
    let bulkBefore = d.gitSnapshot(bulk)!
    for i in 0..<65 {
        try! String(repeating: "1234567890\n", count: i == 0 ? 7000 : 1)
            .write(toFile: bulk + String(format:"/file%02d",i), atomically:true, encoding:.utf8)
    }
    let bulkFiles = d.gitChangedFiles(since: bulkBefore), count = bulkFiles.reduce(0) { $0 + int($1, "added") }
    let longPatch = bulkFiles.first { int($0,"added") == 7000 }
    check(longPatch?["truncated"] as? Bool == true, "七千行改动必须标明截断，实际 " + String(describing:longPatch?["truncated"]))
    check(bulkFiles.count == 65 && count == 7064 && bulkFiles.filter { !str($0,"diff").isEmpty }.count == 60,
          "B3-18 完整文件数和行数独立于补丁预览上限，实际 \(bulkFiles.count) / \(count)")
    let budgetRepo = dir + "/budget"
    try! fm.createDirectory(atPath: budgetRepo, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: budgetRepo)
    for i in 0..<17 { try! Data(repeating: 66, count: 1_000_000).write(to: URL(fileURLWithPath: budgetRepo + String(format: "/b%02d", i))) }
    let budgetBefore = d.gitSnapshot(budgetRepo)!
    try! Data(repeating: 65, count: 1_000_000).write(to: URL(fileURLWithPath: budgetRepo + "/a-new"))
    let budgetChanges = d.gitChangedFiles(since: budgetBefore)
    check(budgetChanges.count == 1 && (budgetChanges.first?["path"] as? String)?.hasSuffix("/a-new") == true, "N02 内容预算移动不误报未变化文件")
    // 无仓库与 write-tree 失败都回退；失败夹具只影响本测试的 git wrapper。
    let plain = NSTemporaryDirectory() + "aipethub-plain-" + UUID().uuidString
    try! fm.createDirectory(atPath: plain, withIntermediateDirectories: true)
    check(d.gitSnapshot(plain) == nil, "非 git 仓库沿用无快照行为")
    try! fm.removeItem(atPath: plain)
    let failingGit = dir + "/failing-git"
    try! installFakeCLI(at: failingGit, behavior: "git-write-tree-fail", parameters: [savedGit!])
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingGit)
    d.gitPath = failingGit
    let fallback = d.gitSnapshot(dir)!
    write("fallback-new.txt", "fallback\n")
    check(d.gitChangedFiles(since: fallback).contains { ($0["path"] as? String)?.hasSuffix("/fallback-new.txt") == true }, "快照失败回退旧改动行为")
    d.gitPath = savedGit

    // git clean 过滤器可能写 LFS/工作区；内容快照不得执行它。
    _ = git(["config", "filter.fixture.clean", "touch filter-ran; cat"])
    write(".gitattributes", "*.filtered filter=fixture\n")
    write("sample.filtered", "raw working content\n")
    // 这时工作区里有一个已跟踪的文件被删了（前面删的 delete tracked.txt）：有过滤器时也要拍得成。
    // 装了 Git LFS 的机器全局就带着过滤器，CI 的机器就是这样，这条在那里失败过。
    check(d.gitSnapshot(dir)?.content != nil, "有过滤器、又有已跟踪文件被删时，内容快照照样拍得成")
    check(!fm.fileExists(atPath: dir + "/filter-ran"), "内容快照不运行有副作用的 clean 过滤器")
    // split index 也只在临时文件里操作；真实 index 与已有共享 index 保持逐字节一致。
    _ = git(["update-index", "--split-index"])
    let indexes = ((try? fm.contentsOfDirectory(atPath: dir + "/.git")) ?? []).filter { $0 == "index" || $0.hasPrefix("sharedindex.") }
    let indexData = Dictionary(uniqueKeysWithValues: indexes.map { ($0, try! Data(contentsOf: URL(fileURLWithPath: dir + "/.git/" + $0))) })
    _ = d.gitSnapshot(dir)
    check(indexData.allSatisfy { (try? Data(contentsOf: URL(fileURLWithPath: dir + "/.git/" + $0.key))) == $0.value }, "split index 快照不更改真实 index")

    let filterRepo = dir + "/filter-repo"
    try! fm.createDirectory(atPath: filterRepo, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: filterRepo)
    _ = d.runGit(["config", "filter.upper.clean", "tr a-z A-Z"], in: filterRepo)
    try! "*.filtered filter=upper\n".write(toFile: filterRepo + "/.gitattributes", atomically: true, encoding: .utf8)
    try! "user line\noriginal\n".write(toFile: filterRepo + "/f.filtered", atomically: true, encoding: .utf8)
    _ = d.runGit(["add", "."], in: filterRepo)
    _ = d.runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "filtered"], in: filterRepo)
    let trace = dir + "/filter-trace.json", oldTrace = ProcessInfo.processInfo.environment["GIT_TRACE2_EVENT"]
    try! "user line\nORIGINAL\n".write(toFile: filterRepo + "/f.filtered", atomically:true, encoding:.utf8)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: filterRepo + "/f.filtered")
    setenv("GIT_TRACE2_EVENT", trace, 1)
    _ = d.gitSnapshot(filterRepo)
    if let old = oldTrace { setenv("GIT_TRACE2_EVENT", old, 1) } else { unsetenv("GIT_TRACE2_EVENT") }
    let filtersRun = (try? String(contentsOfFile:trace, encoding:.utf8))?.split(separator:"\n").compactMap { d.jsonObject(String($0)) }.filter {
        str($0,"event") == "child_start" && ($0["argv"] as? [String])?.contains("tr a-z A-Z") == true
    }.count
    check(filtersRun == 0, "初始状态检查跳过 clean 过滤器，启动次数=\(String(describing:filtersRun))")
    try! "user line\noriginal\n".write(toFile: filterRepo + "/f.filtered", atomically:true, encoding:.utf8)
    let filteredBefore = d.gitSnapshot(filterRepo)!
    try! "user line\nai change\n".write(toFile: filterRepo + "/f.filtered", atomically: true, encoding: .utf8)
    let filteredDiff = d.gitChangedFiles(since: filteredBefore).first?["diff"] as? String ?? ""
    check(filteredDiff.contains("-original") && filteredDiff.contains("+ai change") && !filteredDiff.contains("+user line"), "N02 过滤器仓库也比较两次原始工作区内容")

    // 10,000 个已跟踪文件 + 24 个 200 MB 稀疏未跟踪文件，测量实际入口。
    let perf = dir + "/perf"
    try! fm.createDirectory(atPath: perf, withIntermediateDirectories: true)
    _ = d.runGit(["init", "-q"], in: perf)
    for i in 0..<10_000 { try! Data(repeating: 65, count: 512).write(to: URL(fileURLWithPath: perf + "/f\(i).txt")) }
    _ = d.runGit(["add", "."], in: perf)
    _ = d.runGit(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], in: perf)
    for i in 0..<24 {
        let path = perf + "/large\(i).bin"; fm.createFile(atPath: path, contents: nil)
        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.truncate(atOffset: 200_000_000); try! handle.close()
    }
    var timings: [Double] = []
    for _ in 0..<3 {
        let start = Date(); let snapshot = d.gitSnapshot(perf)
        timings.append(Date().timeIntervalSince(start)); check(snapshot?.content != nil, "大仓库内容快照成功（没有退回状态比较）")
    }
    print("Snapshot benchmark: 10,000 tracked + 24 × 200 MB untracked, seconds=\(timings)")
}
