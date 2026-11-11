// 窗口和网页之间要对齐的几件事：红绿灯的位置、全屏、在不在前台。
import Cocoa

/// 三栏顶栏的高度（和 CSS 里 .sidebar-top / #chat-header / .ed-tabs 的 44px 一致）：红绿灯竖直居中在这一条里。
let topBarHeight: CGFloat = 44

extension AppDelegate {
    // 窗口的状态告诉网页（给 body 加 / 去掉一个类），样式跟着变：
    //   window-inactive：窗口不在前台——选中项和桌宠卡片的彩色光晕收一收，眼角余光不被它抢走（feel.css）
    //   fullscreen：全屏——左上角没有红绿灯了，给它们留的那块空位收回去（base.css 的 --lights）
    func windowDidBecomeKey(_ notification: Notification) { setBodyClass("window-inactive", false); layoutTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { setBodyClass("window-inactive", true); layoutTrafficLights() }
    func windowWillEnterFullScreen(_ notification: Notification) { setBodyClass("fullscreen", true) }
    func windowWillExitFullScreen(_ notification: Notification) { setBodyClass("fullscreen", false) }
    func windowDidEnterFullScreen(_ notification: Notification) { setBodyClass("fullscreen", true) }
    func windowDidExitFullScreen(_ notification: Notification) { setBodyClass("fullscreen", false); layoutTrafficLights() }
    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }   // 系统重排标题栏时会把红绿灯放回原位

    /// 页面刚载入时调一次：窗口可能一打开就是全屏、或者不在前台。
    func syncWindowStateToPage() {
        setBodyClass("fullscreen", window.styleMask.contains(.fullScreen))
        setBodyClass("window-inactive", !window.isKeyWindow && !UITest.active)
        layoutTrafficLights()
    }

    private func setBodyClass(_ name: String, _ on: Bool) {
        webView.evaluateJavaScript("document.body.classList.toggle('\(name)', \(on))", completionHandler: nil)
    }

    /// 把红绿灯往下、往右挪一点，竖直落在 44pt 顶栏的正中（系统默认把它们放在标题栏的正中，离顶 16pt，
    /// 比顶栏里的搜索框、标题高 6pt）。只挪按钮自己，而且不挪出装着它们的那一条标题栏——
    /// 上一次是把标题栏容器加高，结果真实窗口里红绿灯整个不见了；这一版用 tools/uitest/e2e-chrome.js 在真实窗口里量过、截过图。
    func layoutTrafficLights() {
        guard let window = window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let titlebar = first.superview else { return }
        // 按钮中心要离窗口顶 topBarHeight / 2；换成标题栏里的坐标（从下往上算），并且不低于标题栏的下边
        let y = max(0, titlebar.frame.height - topBarHeight / 2 - first.frame.height / 2)
        let spacing = buttons.count > 1 ? buttons[1].frame.origin.x - buttons[0].frame.origin.x : 23
        for (i, b) in buttons.enumerated() {
            b.setFrameOrigin(NSPoint(x: 15 + CGFloat(i) * spacing, y: y))   // 离顶 15pt，左边也留 15pt
        }
    }
}
