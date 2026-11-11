// 人不在 AIPetHub 时的提醒：只动 Dock 图标（跳一下、角标显示没看的回答数），不发系统通知。
// （试过系统通知：回答多的时候横幅不停地弹出来，很打扰，去掉了。）
import Cocoa

extension AppDelegate {
    /// 回答完成时人不在 AIPetHub：Dock 图标跳一下并显示未看的数量。
    func noteReplyArrived(agent: String = "", text: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let app = NSApp, !app.isActive, !UITest.active else { return }
            self.unseenReplies += 1
            app.dockTile.badgeLabel = "\(self.unseenReplies)"
            app.requestUserAttention(.informationalRequest)
        }
    }

    /// 回答进行中有事等用户决定（审批 / 提问 / 计划）：人不在就让 Dock 图标跳一下，不然会一直干等。
    func noteNeedsAttention(agent: String, text: String) {
        DispatchQueue.main.async {
            guard let app = NSApp, !app.isActive, !UITest.active else { return }
            app.requestUserAttention(.informationalRequest)
        }
    }
}
