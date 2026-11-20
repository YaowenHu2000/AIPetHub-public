// 一次提问和它的结果。
import Foundation

struct CLIResult {
    var out: String
    var err: String
    var status: Int32
    var cancelled: Bool
    var launchError: String?
    var warmDied = false   // 接手前已退出；由入口重建 LiveTurn，完整冷启动一次
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
    /// 重试历史消息时，原文件已不在或发送之后被覆盖、只能从会话记录里取回的图片（{agent, conversationId, id}，见 ChatImages.swift 的 ref）
    var imageRefs: [[String: Any]] = []
    /// 这一轮带不带内置浏览器的工具（BrowserTools.swift）
    var browserTools = true
    /// 这一轮开不开 fast（Claude 的 fast 模式、Codex 的 Fast 档；模型不支持的话网页那边不会传 true）
    var fast = false
    /// 这个会话正开在别的程序里：不接着它写，带着历史分叉出一个新会话（ClaudeSessions.swift）
    var fork = false
    let startedAt = Date()

    /// 一问一答时用的文字：图片的路径接在话后面，让它自己去读。
    static let imagePathHeader = "\n\n[AIPetHub 图片附件]\n"
    var promptWithImagePaths: String { images.isEmpty ? prompt : prompt + Self.imagePathHeader + images.joined(separator: "\n") }

    /// 登记 CLI 进程用的键：同一位可以同时跑多个会话，按每次请求区分。
    var key: String { "\(agent)#\(reqId)" }
}

/// CLI 明确记录的最后一轮。时间统一为 Unix 秒，网页用本轮最后写入时间识别崩溃遗留的开始标记。
struct HistoryTurnActivity {
    let running: Bool
    let startedAt: Double
    var updatedAt: Double
    /// 只在原生层用：核对本机是否已确认这一轮的结局，不发给网页。
    var turnId = ""

    var payload: [String: Any] { ["running": running, "startedAt": startedAt, "updatedAt": updatedAt] }
}

struct AgentReply {
    var reply: String
    var conversationId: String
    var cancelled: Bool = false
    /// 工作步骤和改动的文件（TurnBuilder.finish 的结果）
    var restoreDraft = false
    var turn: [String: Any]? = nil
}
