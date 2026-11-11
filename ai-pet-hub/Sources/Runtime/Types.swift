// 一次提问和它的结果。
import Foundation

struct CLIResult {
    var out: String
    var err: String
    var status: Int32
    var cancelled: Bool
    var launchError: String?
}

struct AskRequest {
    let agent: String
    let reqId: Int
    let prompt: String
    let model: String
    let effort: String
    let permissionMode: String
    let workspace: String
    let conversationId: String
    /// 随这句话一起发的图片（本机文件路径）：交互式协议里作为真正的图片交给模型；退回一问一答时把路径写在话后面
    var images: [String] = []
    /// 这一轮带不带内置浏览器的工具（BrowserTools.swift）
    var browserTools = true
    /// 这一轮开不开 fast（Claude 的 fast 模式、Codex 的 Fast 档；模型不支持的话网页那边不会传 true）
    var fast = false
    /// 这个会话正开在别的程序里：不接着它写，带着历史分叉出一个新会话（ClaudeSessions.swift）
    var fork = false

    /// 一问一答时用的文字：图片的路径接在话后面，让它自己去读。
    var promptWithImagePaths: String { images.isEmpty ? prompt : prompt + "\n\n" + images.joined(separator: "\n") }

    /// 登记 CLI 进程用的键：同一位可以同时跑多个会话，按每次请求区分。
    var key: String { "\(agent)#\(reqId)" }
}

struct AgentReply {
    var reply: String
    var conversationId: String
    var cancelled: Bool = false
    /// 工作步骤和改动的文件（TurnBuilder.finish 的结果）
    var turn: [String: Any]? = nil
}
