// 向 DeepSeek 提问：找 dsh、起本机服务、按会话设模型 / 思考强度 / 权限；一次回答见 DeepSeekLive.swift。
import Cocoa

extension AppDelegate {
    /// dsh 装在哪。它是个 npm 包，常见的几处都看一眼，没有再去登录 shell 的 PATH 里找。
    func dshExecutable() -> String? {
        hooks.cliExecutable ?? findExecutable(["\(home)/.local/bin/dsh", "/opt/homebrew/bin/dsh", "/usr/local/bin/dsh"])   // 都没有时 findExecutable 会去登录 shell 的 PATH 里找
    }

    /// 让 dsh 的本机服务跑起来。成功返回 nil，否则是给用户看的原因。第一次起来时顺便问它有哪些模型。
    func dshReady() -> String? {
        guard let exe = dshExecutable() else { return "没有找到 dsh（DeepSeek Harness）。用 npm install -g @deepseek-ai/dsh 装好后再试。" }
        let wasRunning = dshServer.isRunning
        if let err = dshServer.ensure(executable: exe, environment: cliEnvironment(), cwd: home) { return err }
        if !wasRunning { DispatchQueue.global(qos: .utility).async { self.noteDshModels() } }
        return nil
    }

    /// dsh 现在能用的模型和各自的思考强度：模型菜单跟着它走。
    func noteDshModels() {
        guard let groups = (dshServer.call("llm.models").value as? [String: Any])?["groups"] as? [[String: Any]] else { return }
        var providers: [String: String] = [:]
        var models: [[String: Any]] = []
        for g in groups {
            for m in g["models"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String else { continue }
                providers[id] = g["id"] as? String ?? ""
                var item: [String: Any] = ["v": id, "name": m["name"] as? String ?? id, "desc": ""]
                let efforts = ((m["reasoning"] as? [String: Any])?["efforts"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                if !efforts.isEmpty { item["efforts"] = efforts }
                models.append(item)
            }
        }
        guard !models.isEmpty else { return }
        procLock.lock(); dshProviders = providers; procLock.unlock()
        DispatchQueue.main.async { self.sendToJS("onAgentModels", ["agent": "deepseek", "models": models]) }
    }

    func runDeepSeek(_ req: AskRequest) -> AgentReply {
        DeepSeekLiveTurn(app: self, req: req).run()
    }
}

extension AppDelegate {
    /// 给这个会话设好模型、思考强度和权限。和上次给它设的一样就不设（每设一次都是一次调用）。
    /// 注意：dsh 的「选模型」会顺手把它记成以后新会话的默认值（写进 ~/.dsh/settings.yaml）——它自带的界面也是这样，
    /// 在这里选了什么，等于在 dsh 里选了什么。
    @discardableResult
    func dshConfigure(_ sid: String, _ req: AskRequest, isNew: Bool, onDefaultEffort: () -> Void = {}, submit: () -> Void = {}) -> String? {
        dshServer.sessionQueue(sid).sync {
            let perm = ["read-only", "workspace-write", "danger-full-access"].contains(req.permissionMode) ? req.permissionMode : "danger-full-access"
            let effort = ["off", "low", "high", "max"].contains(req.effort) ? req.effort : ""
            let want = "\(req.model)|\(effort)|\(perm)"
            procLock.lock()
            let same = dshApplied[sid] == want
            let provider = dshProviders[req.model] ?? "deepseek-official"
            procLock.unlock()
            if !same {
                // 部分配置成功也不能保留旧缓存；队列保证成功发布前不会插入更新的配置。
                procLock.lock(); dshApplied[sid] = nil; procLock.unlock()
                var applied = want
                if !req.model.isEmpty {
                    var p: [String: Any] = ["sessionId": sid, "provider": provider, "model": req.model]
                    if !effort.isEmpty { p["reasoningEffort"] = effort }
                    var r = dshServer.call("session.selectModel", p)
                    if r.error != nil, !effort.isEmpty {   // 这个模型不认这一档：不带强度再设一次（一直是这样，不算失败）
                        p["reasoningEffort"] = nil
                        r = dshServer.call("session.selectModel", p)
                        applied = "\(req.model)||\(perm)"
                    }
                    if let e = r.error { return "模型设置失败：\(e)" }
                }
                let permission = dshServer.call("commands/execute", ["agentId": sid, "line": "/permission \(perm)"], typert: true)
                if let e = permission.error ?? dshCommandError(permission.value) { return "权限设置失败：\(e)" }
                procLock.lock(); dshApplied[sid] = applied; procLock.unlock()
                if applied != want { onDefaultEffort() }
            }
            submit()
            return nil
        }
    }

}
