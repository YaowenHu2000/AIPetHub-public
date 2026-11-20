// MCP 服务器向用户要输入（MCP 的 elicitation/create）：Claude 以 control_request elicitation、Codex 以 mcpServer/elicitation/request 转来，
// 两家外壳不同，卡片和答案的换算在这里共用。form 模式按 requestedSchema 每个字段出一道提问卡的题，url 模式出审批卡、允许时用默认浏览器打开链接。
// 不答复的话 CLI 会替用户回 cancel / decline，MCP 工具就静默失败，用户也不知道它问过。
//
// MCP 交互：Codex 在「每次询问」下调任何 MCP 工具（包括 App 的内置浏览器工具）前发 `mcpServer/elicitation/request`（`_meta.codex_approval_kind` 为 `mcp_tool_call`），
// 用审批卡，「这一轮都允许」答 `persist: session`；MCP 服务器自己要用户输入时，Claude 转来 `control_request` 的 `elicitation`、
// Codex 转来同一个 `mcpServer/elicitation/request`，共用这里：表单按 schema 的简单字段（文字、数字、是否、单选 / 多选枚举）出提问卡，
// 空表单和链接只提供单次确认；链接允许后用默认浏览器打开；数值无效时保留表单供修改；字段认不出、原生收到缺失必填项的答复时回 decline，停止或这一轮结束回 cancel。
// Codex 的 `item/permissions/requestApproval`（额外权限）也用审批卡。
import Cocoa

/// 分别取回选项和自填文字，避免把答案自带的顿号当成分隔符。
func questionAnswerParts(_ body: [String: Any], _ key: String) -> (selected: [String], custom: String)? {
    guard let part = (body["answerParts"] as? [String: [String: Any]])?[key],
          let selected = part["selected"] as? [String] else { return nil }
    return (selected, trimmed(part["custom"] as? String))
}

extension LiveTurn {
    /// 出卡并登记待答。info 里放各家答复时要带回去的东西（rpcId 等）。
    /// 返回 false：表单里有认不出的字段（嵌套对象、无枚举的数组等），没出卡，调用方立即回 decline，别让它一直等。
    func showMCPElicitation(id rid: String, info: [String: Any], server: String, mode: String, message: String,
                            schema: [String: Any]?, order: [String]?, url: String?) -> Bool {
        var pendingInfo = info
        pendingInfo["kind"] = "elicitation"
        if mode == "url" {
            guard let link = url, URL(string: link) != nil else { return false }
            pendingInfo["url"] = link
            pending.add(rid, pendingInfo)
            app.sendRequest(req, id: rid, kind: "permission", ["tool": "mcp", "onceOnly": true, "stepKind": "tool",
                                                                 "title": "\(server) 要你打开一个链接", "detail": message + "\n\n" + link])
            return true
        }
        guard mode == "form", let form = mcpElicitationForm(schema ?? [:], order: order) else { return false }
        pendingInfo["fields"] = form.fields
        pending.add(rid, pendingInfo)
        if form.questions.isEmpty {   // 没有字段：只是要用户确认一下
            app.sendRequest(req, id: rid, kind: "permission", ["tool": "mcp", "onceOnly": true, "stepKind": "tool", "title": "\(server) 请你确认", "detail": message])
        } else {
            app.sendRequest(req, id: rid, kind: "question", ["questions": form.questions, "message": message.isEmpty ? "\(server) 需要你填写" : message])
        }
        return true
    }

    /// 用户的答复换成 MCP 的结果：(action, content)。content 为 nil 时不带内容（decline / cancel、链接模式）。
    func mcpElicitationResult(_ info: [String: Any], _ body: [String: Any]) -> (action: String, content: [String: Any]?) {
        guard body["decision"] as? String != "deny" else { return ("decline", nil) }
        if let link = info["url"] as? String {
            if let u = URL(string: link) {
                if let open = app.hooks.openURL { open(u) } else { NSWorkspace.shared.open(u) }
            }
            return ("accept", nil)
        }
        let fields = info["fields"] as? [[String: Any]] ?? []
        guard let content = mcpElicitationContent(fields, body: body) else { return ("decline", nil) }
        return ("accept", content)
    }

    /// 停止或这一轮结束时还挂着的 MCP 请求：交给 send 回 cancel，卡片撤掉。
    func cancelMCPElicitations(_ send: ([String: Any]) -> Void) {
        for (rid, info) in pending.take(where: { $0["kind"] as? String == "elicitation" }) {
            send(info)
            app.closeRequest(req, id: rid)
        }
    }
}

/// 按 schema 出题：string（可带 enum / enumNames / oneOf）、number、integer、boolean、带枚举 items 的 array。
/// 每题的 id 就是字段名，网页按 id 交回答案。JSON 对象解出来不保序：有 property_order 用它，没有按字段名排。
func mcpElicitationForm(_ schema: [String: Any], order: [String]?) -> (questions: [[String: Any]], fields: [[String: Any]])? {
    guard let props = (schema["properties"] ?? [String: Any]()) as? [String: Any] else { return nil }
    let required = Set(schema["required"] as? [String] ?? [])
    let keys = (order ?? []).filter { props[$0] != nil } + props.keys.filter { !(order ?? []).contains($0) }.sorted()
    var questions: [[String: Any]] = [], fields: [[String: Any]] = []
    for key in keys {
        guard let p = props[key] as? [String: Any], let type = p["type"] as? String else { return nil }
        var options: [(label: String, value: Any)] = []
        func enumOptions(_ holder: [String: Any]) -> [(label: String, value: Any)] {
            if let values = holder["enum"] as? [String] {
                let names = holder["enumNames"] as? [String] ?? []
                return values.enumerated().map { ($0.offset < names.count ? names[$0.offset] : $0.element, $0.element) }
            }
            return ((holder["oneOf"] ?? holder["anyOf"]) as? [[String: Any]] ?? []).compactMap { c in
                guard let v = c["const"] as? String else { return nil }
                return (c["title"] as? String ?? v, v)
            }
        }
        switch type {
        case "string": options = enumOptions(p)
        case "boolean": options = [("是", true), ("否", false)]
        case "number", "integer": break
        case "array":
            options = enumOptions(p["items"] as? [String: Any] ?? [:])
            if options.isEmpty { return nil }
        default: return nil
        }
        let title = p["title"] as? String ?? key
        let desc = p["description"] as? String ?? ""
        questions.append(["id": key, "question": desc.isEmpty || desc == title ? title : "\(title)（\(desc)）", "header": "",
                          "multiSelect": type == "array", "isOther": options.isEmpty, "valueType": type, "required": required.contains(key),
                          "options": options.map { ["label": $0.label, "description": ""] }])
        fields.append(["key": key, "type": type, "required": required.contains(key),
                       "options": options.map { ["label": $0.label, "value": $0.value] }])
    }
    return (questions, fields)
}

/// 网页按题目 id 交回的一句话（多选用「、」连着）换成 schema 要的类型。必填项没填、数字填得不对：返回 nil，按 decline 交回，
/// 不合 schema 的 accept 会被 MCP 服务器当成错误，不如明确说没填。
func mcpElicitationContent(_ fields: [[String: Any]], body: [String: Any]) -> [String: Any]? {
    let answers = body["answers"] as? [String: Any] ?? [:]
    var content: [String: Any] = [:]
    for f in fields {
        guard let key = f["key"] as? String else { continue }
        let text = trimmed(answers[key] as? String)
        let options = f["options"] as? [[String: Any]] ?? []
        let value = { (label: String) in options.first { $0["label"] as? String == label }?["value"] }
        var got: Any?
        if !text.isEmpty {
            switch f["type"] as? String {
            case "array":
                // 整句就是一个选项（选项文字里本来就可能有「、」）；否则拆开逐个认
                let picked = questionAnswerParts(body, key)?.selected.compactMap(value) ?? value(text).map { [$0] } ?? text.components(separatedBy: "、").compactMap { value(trimmed($0)) }
                got = picked.isEmpty ? nil : picked
            case "boolean": got = value(text)
            case "integer": got = Int(text)
            case "number": got = Double(text)
            default: got = options.isEmpty ? text : value(text)
            }
            if got == nil { return nil }   // 填了但认不出：不交一个错的值
        }
        if let g = got { content[key] = g } else if f["required"] as? Bool == true { return nil }
    }
    return content
}

/// Codex MCP 工具审批的参数：tool_params_display 是给人看的（每项有 display_name / name 和 value），没有就用 tool_params 原样。
func mcpToolParamsText(_ meta: [String: Any]) -> String {
    func text(_ v: Any) -> String {
        if let s = v as? String { return s }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: d, as: UTF8.self)
        }
        return "\(v)"
    }
    if let display = meta["tool_params_display"] as? [[String: Any]], !display.isEmpty {
        return display.map { "\($0["display_name"] as? String ?? $0["name"] as? String ?? ""): \(text($0["value"] ?? ""))" }.joined(separator: "\n")
    }
    if let params = meta["tool_params"], !(params is NSNull), (params as? [String: Any])?.isEmpty != true { return text(params) }
    return ""
}
