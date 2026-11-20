// DeepSeek 要人答的请求（approval/requested 审批、question/requested 提问）：卡片怎么摆、答复怎么交回、dsh 不收时怎么办。
// 回答进行中由 DeepSeekLiveTurn 显示。dsh 自己开的一轮（后台任务唤醒、子智能体回报）里发来、App 没有回合在听的，
// 由这里交给网页（reqId 为 0、带会话编号）：网页把会话标成未读、桌宠说一声，点开会话时再弹一次，答复按记下的 rpcId 交回。
//
// dsh 会在 App 收尾之后自己开新的一轮（后台任务结束唤醒、子智能体回报），里面的提问和审批没有超时、也不管有没有人在听。
// 所以 `DshServer` 不论有没有回合在听都记下 `question/requested`、`approval/requested`，resolved 来了再清：有回合开始听这个会话时补发给它；
// 没人听时以 reqId 0、带会话编号交给网页（`DeepSeekRequests.swift`），网页正看着这个会话就把卡片接在对话末尾，否则把会话标成未读，点开读完历史后再发一次。
// 前台和后台的待答请求都会唤醒桌宠，最后一张卡片关闭后解除等待，答复按记下的 rpcId 交回。
// HTTP 回执失败且请求仍待答时，提问、审批和计划卡都会显示回执原因，用户可再次提交。
//
// `/api/respond` 的回执说 bad-response 时提问先退成每题只带用户写的话再交一次，还不收就把卡片重新摆出来；not-pending 按已在别处答过撤卡。
import Cocoa

/// 帧 → 卡片编号：提问按 rpcId，审批按 approvalId（requested 和 resolved 两头都认得出）。
func dshRequestKey(_ frame: [String: Any]) -> String? {
    switch frame["type"] as? String {
    case "question/requested": return (frame["_rpcId"] as? String).map { "dshq-" + $0 }
    case "question/resolved": return (frame["questionRpcId"] as? String).map { "dshq-" + $0 }
    case "approval/requested", "approval/resolved": return (frame["approvalId"] as? String).map { "dsh-" + $0 }
    default: return nil
    }
}

/// exit_plan_mode 交来的计划评审：dsh 用一道带 intent.kind=plan-review 的题来问，detail 是整份计划（Markdown）。
func dshPlanReview(_ frame: [String: Any]) -> (question: [String: Any], approve: String)? {
    guard frame["type"] as? String == "question/requested", let questions = frame["questions"] as? [[String: Any]],
          questions.count == 1, let q = questions.first, let intent = q["intent"] as? [String: Any],
          intent["kind"] as? String == "plan-review", let approve = intent["approve"] as? String else { return nil }
    return (q, approve)
}

/// 要人答的帧 → 网页卡片的种类和字段。审批的标题和详情能从对应那一步取就取（step），取不到用工具名和原因。
func dshCard(_ frame: [String: Any], step: [String: Any] = [:]) -> (kind: String, fields: [String: Any]) {
    if frame["type"] as? String == "question/requested" {
        // 计划评审用和 Claude / Codex 同一张计划卡、把计划正文摆出来；当成普通提问的话用户只看得到一句「批准这个计划吗」
        if let review = dshPlanReview(frame) { return ("plan", ["plan": review.question["detail"] as? String ?? ""]) }
        let shown = (frame["questions"] as? [[String: Any]] ?? []).map { q -> [String: Any] in
            ["id": q["id"] as? String ?? "", "question": q["question"] as? String ?? "", "header": q["header"] as? String ?? "",
             "multiSelect": q["multiSelect"] as? Bool ?? false, "options": q["options"] as? [[String: Any]] ?? []]
        }
        var fields: [String:Any] = ["questions":shown]
        fields["answerParts"] = frame["answerParts"]
        return ("question", fields)
    }
    let tool = frame["toolName"] as? String ?? "tool"
    var fields: [String: Any] = ["tool": tool, "title": step["title"] ?? "调用 \(tool)", "stepKind": step["kind"] ?? "tool"]
    let detail = [step["detail"] as? String, frame["reason"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    if !detail.isEmpty { fields["detail"] = detail }
    if let p = step["path"] { fields["path"] = p }
    return ("permission", fields)
}

/// 用户在卡片上的答复 → 交回 dsh 的 value。审批里「这一轮都允许」也是答这一次（回合里另记，同一轮再来就替用户答）。
func dshAnswerValue(_ frame: [String: Any], sid: String, _ body: [String: Any]) -> [String: Any] {
    let allowed = ["allow", "allowAll"].contains(body["decision"] as? String ?? "")
    guard frame["type"] as? String == "question/requested" else {
        return ["sessionId": sid, "approvalId": frame["approvalId"] as? String ?? "", "outcome": allowed ? "allowed-once" : "rejected"]
    }
    if let review = dshPlanReview(frame) {
        var item: [String: Any] = ["id": review.question["id"] as? String ?? "", "selected": [review.approve]]
        if !allowed {
            // 先改计划：不选「批准」、只附修改意见（单选题两样不能同时带），它留在计划模式里改。custom 不能是空白
            let said = trimmed(body["message"] as? String)
            item["selected"] = [String]()
            item["custom"] = said.isEmpty ? "计划需要修改，请先和我确认。" : said
        }
        return ["sessionId": sid, "answer": ["answers": [item]]]
    }
    return ["sessionId": sid, "answer": ["answers": dshQuestionAnswers(frame["questions"] as? [[String: Any]] ?? [], body)]]
}

/// dsh 不收第一次的答复时退成的答法：每题只带用户写的话（选的和写的连起来放进 custom），没写的留空，都过得了它的校验。
/// 计划评审不退：把「批准」写成 custom 会被当成修改意见。
func dshCustomOnly(_ frame: [String: Any], _ value: [String: Any]) -> [String: Any]? {
    guard dshPlanReview(frame) == nil, var answer = value["answer"] as? [String: Any], let items = answer["answers"] as? [[String: Any]] else { return nil }
    answer["answers"] = items.map { item -> [String: Any] in
        let said = trimmed(((item["selected"] as? [String] ?? []) + [item["custom"] as? String ?? ""]).filter { !$0.isEmpty }.joined(separator: "、"))
        var out: [String: Any] = ["id": item["id"] ?? "", "selected": [String]()]
        if !said.isEmpty { out["custom"] = said }
        return out
    }
    var v = value
    v["answer"] = answer
    return v
}

/// 以 cancelled 作答（停止时等着的提问）。error 少了 details，dsh 的回执就是 bad-response，模型会一直等下去（实测）。
let dshCancelledResult: [String: Any] = ["ok": false, "error": ["code": "cancelled", "message": "用户停止了这一轮", "details": [String: Any]()]]

extension AppDelegate {
    /// 把答复交回 dsh 并看回执。不收（bad-response）时提问先退成只带 custom 再交一次；还不收返回原因，调用方把卡片重新摆出来。
    /// not-pending：已在别处（dsh 自带网页、停止）答过，卡片照常撤掉，也不再当它挂着。
    func dshDeliver(_ frame: [String: Any], value: [String: Any]) -> String? {
        guard let rpcId = frame["_rpcId"] as? String else { return nil }
        var why = dshServer.respond(rpcId: rpcId, value: value)
        if why == "bad-response", let retry = dshCustomOnly(frame, value) { why = dshServer.respond(rpcId: rpcId, value: retry) }
        if why == "not-pending", let id = dshRequestKey(frame) { dshServer.forget(id) }
        if why != nil, why != "not-pending", let id = dshRequestKey(frame),
           let answers = (value["answer"] as? [String:Any])?["answers"] as? [[String:Any]] {
            var parts: [String:Any] = [:]
            for answer in answers { if let key = answer["id"] as? String { parts[key] = answer } }
            dshServer.rememberAnswers(id, parts:parts)
        }
        return why == "not-pending" ? nil : why.map { "答复尚未确认（\($0)），请重试。" }
    }

    /// DshServer.unattended：没有回合在听的会话里来了要人答的请求（frame），或者它了结了、交给了回合（nil）。
    func dshUnattended(_ sid: String, _ id: String, _ frame: [String: Any]?) {
        guard let frame = frame else { sendToJS("onAgentRequestClosed", ["agent": "deepseek", "reqId": 0, "requestId": id]); return }
        guard !dshServer.isDeleted(sid) else { return }
        dshShowUnattended(sid, id, frame)
        noteNeedsAttention(agent: "deepseek", text: "有问题要问你")
    }

    /// reqId 0 表示没有回合：网页按会话编号摆卡片（正看着这个会话时接在对话末尾，否则标成未读，点开时这里再发一次）。
    func dshShowUnattended(_ sid: String, _ id: String, _ frame: [String: Any], reason: String? = nil) {
        let card = dshCard(frame)
        var payload = card.fields
        payload["message"] = reason
        payload["agent"] = "deepseek"
        payload["reqId"] = 0
        payload["requestId"] = id
        payload["kind"] = card.kind
        payload["conversationId"] = sid
        sendToJS("onAgentRequest", payload)
    }

    /// 点开会话（读完历史）后：还挂着、没有回合在听的请求再弹一次卡。
    func dshShowUnattended(_ sid: String) {
        dshServer.unattendedRequests(sid).forEach { dshShowUnattended(sid, $0.id, $0.frame) }
    }

    /// 用户答了没有回合在听时摆出来的卡片（或回合已经结束、dsh 还在等的卡片）：按记下的 rpcId 交回。
    func dshAnswerUnattended(_ id: String, _ body: [String: Any]) {
        sendToJS("onAgentRequestClosed", ["agent": "deepseek", "reqId": 0, "requestId": id])
        guard let w = dshServer.waitingRequest(id) else { return }
        let value = dshAnswerValue(w.frame, sid: w.sid, body)
        DispatchQueue.global().async { [weak self] in
            guard let self = self, let reason = self.dshDeliver(w.frame, value: value) else { return }
            // dsh 不收：卡片重新摆出来（这期间有回合开始听了的话，由回合显示）
            if let retry = self.dshServer.unattendedRequests(w.sid).first(where: { $0.id == id }) { self.dshShowUnattended(w.sid, id, retry.frame, reason: reason) }
        }
    }
}

/// 提问卡的答复（每题一个字符串，多选用「、」连起来，可能夹着用户自己写的）→ dsh 要的 [{id, selected, custom?}]。
/// dsh 会逐题核对：selected 只能是选项标签，单选题不能同时带 custom，custom 不能是空白；不合要求它就不收，模型会一直等。
func dshQuestionAnswers(_ questions: [[String: Any]], _ body: [String: Any]) -> [[String: Any]] {
    let given = body["answers"] as? [String: Any] ?? [:]
    let skipped = body["decision"] as? String == "deny"
    return questions.map { q in
        var item: [String: Any] = ["id": q["id"] as? String ?? "", "selected": [String]()]
        // 用户点了「不回答」：把网页给的那句说明交给模型，让它自己拿主意
        let said = trimmed(skipped ? body["message"] as? String : (given[q["id"] as? String ?? ""] ?? given[q["question"] as? String ?? ""]) as? String)
        guard !said.isEmpty else { return item }
        let labels = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        if !skipped, let parts = questionAnswerParts(body, q["id"] as? String ?? "") {
            item["selected"] = parts.selected.filter(labels.contains)
            if !parts.custom.isEmpty { item["custom"] = parts.custom }
            return item
        }
        if !skipped, labels.contains(said) { item["selected"] = [said]; return item }
        if !skipped, q["multiSelect"] as? Bool == true {
            let parts = said.components(separatedBy: "、")
            var picked: [String] = []
            for p in parts where labels.contains(p) && !picked.contains(p) { picked.append(p) }
            let rest = parts.filter { !labels.contains($0) }.joined(separator: "、")
            item["selected"] = picked
            if !trimmed(rest).isEmpty { item["custom"] = trimmed(rest) }
            return item
        }
        item["custom"] = said
        return item
    }
}
