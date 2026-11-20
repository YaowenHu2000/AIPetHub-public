// 上行：POST /api/<方法>、/api/respond（帧格式见 DeepSeekServer.swift 开头）。已删的会话在这里统一挡掉，列表、历史、搜索不必各自判断；
// dsh 网页归档的、dsh 派出的子代理的会话也在这里从列表里去掉，侧栏、搜索和删除项目的候选共用。
import Cocoa

extension DshServer {
    /// 调一个方法，等它答复。typert：那一批参数要包在 args 里的端点（commands/execute 等）。
    /// rpcId：自己指定这次调用的编号（发出去的话会带着它出现在事件里，用来认出这句是 App 自己发的）。
    func call(_ method: String, _ payload: [String: Any] = [:], typert: Bool = false, rpcId: String? = nil, timeout: TimeInterval = 60, onTask: ((URLSessionDataTask) -> Void)? = nil) -> (value: Any?, error: String?, code: String) {
        lock.lock(); let port = self.port; lock.unlock()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else { return (nil, "dsh 的本机服务没有在运行", "not-running") }
        // 已删的会话在这里统一挡掉：列表、历史、搜索和删除项目都不再看到它，按「找不到会话」走原来的处理
        if let sid = (payload["sessionId"] ?? payload["agentId"]) as? String, isDeleted(sid) {
            return (nil, "这个会话已经删除了", "session-not-found")
        }
        let wrapped: [String: Any] = typert ? ["args": payload] : payload
        let body: [String: Any] = ["type": "client-request", "rpcId": rpcId ?? "aph-" + UUID().uuidString, "method": method, "payload": wrapped]
        let res = post(url, body, timeout: timeout, onTask: onTask)
        guard let obj = res.json else { return (nil, res.error ?? "dsh 没有答复", "transport") }
        let result = obj["result"] as? [String: Any] ?? [:]
        if result["ok"] as? Bool == true {
            if method == "session.list", var value = result["value"] as? [String: Any], let items = value["items"] as? [[String: Any]] {
                // 照 dsh 网页侧栏（dsh-client-ui-workspace）的规则：归档的和子代理（origin "subagent"）的会话不列出；
                // 用户自己分叉的会话也带 parentSessionId，照常列出
                let archived = Self.archivedSessionIds()
                value["items"] = items.filter {
                    let sid = $0["sessionId"] as? String ?? ""
                    return !isDeleted(sid) && !archived.contains(sid) && $0["origin"] as? String != "subagent"
                }
                return (value, nil, "")
            }
            return (result["value"], nil, "")
        }
        let e = result["error"] as? [String: Any] ?? [:]
        return (nil, e["message"] as? String ?? "dsh 拒绝了这次调用", e["code"] as? String ?? "error")
    }

    /// 答复一个要人决定的帧（审批、提问）。返回 dsh 不收的原因：nil 是收下了（回执里没说也算）；
    /// "bad-response"（答复不合它的校验，请求还挂着）、"not-pending"（没有这个请求，多半在别处答过了），或连不上的说明。
    @discardableResult
    func respond(rpcId: String, value: [String: Any]) -> String? {
        respond(rpcId: rpcId, result: ["ok": true, "value": value])
    }

    /// result 原样交回：{"ok":true,"value":…}，或以 cancelled 作答的 {"ok":false,"error":{code,message,details}}。
    @discardableResult
    func respond(rpcId: String, result: [String: Any]) -> String? {
        lock.lock(); let port = self.port; lock.unlock()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/api/respond") else { return "dsh 的本机服务没有在运行" }
        let res = post(url, ["type": "client-response", "rpcId": rpcId, "result": result], timeout: 20)
        guard let receipt = res.json else { return res.error ?? "dsh 没有答复" }
        return receipt["accepted"] as? Bool == false ? receipt["reason"] as? String ?? "bad-response" : nil
    }

    private func post(_ url: URL, _ body: [String: Any], timeout: TimeInterval, onTask: ((URLSessionDataTask) -> Void)? = nil) -> (json: [String: Any]?, error: String?) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        var json: [String: Any]?, error: String?
        let task = http.dataTask(with: req) { data, response, err in
            if let e = err { error = e.localizedDescription }
            else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { error = "dsh 返回了 HTTP \(code)" }
            else if let d = data { json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
            done.signal()
        }
        onTask?(task)
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) != .success { return (nil, "dsh 没有在 \(Int(timeout)) 秒内答复") }
        return (json, error)
    }
}
