// 真实窗口的自动化测试：`AIPetHub --uitest <脚本.js> <结果.json>`
// 照常开窗口、载入界面（网页 ↔ 原生 ↔ CLI 整条链路都是真的），页面好了以后在页面里跑脚本（async 函数体，return 的东西写进结果文件），
// 跑完就退出。窗口完全透明、点不到、不抢焦点、不进 Dock（屏幕上看不见它）；网页的本地存储用临时的，不会动到平时用的设置和草稿。
// 脚本里可以 `postNative('testSnapshot', { path })` 把当时的界面存成 PNG。
import Cocoa
import WebKit

enum UITest {
    static var script: String?
    static var out = ""
    static var active: Bool { script != nil }
    /// 「真实窗口」模式（AIPETHUB_UITEST_REAL=1）：窗口不再是全透明，而是照常画出来、推到屏幕外面——
    /// 系统不让窗口完全出屏，会留一个几十像素的角在副屏（没有副屏就是主屏）的边上，压在别的窗口后面。
    /// 这样它是真的合成出来的，能把整个窗口截下来（连红绿灯、毛玻璃）。
    /// （试过放到桌面壁纸下面一层：完全看不见，但系统认为它被挡住了，网页就不画了。全透明的话截出来也是透明的。）
    static let real = ProcessInfo.processInfo.environment["AIPETHUB_UITEST_REAL"] == "1"

    static func parseArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--uitest"), i + 2 < args.count,
              let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else { return }
        script = text
        out = args[i + 2]
    }
}

extension AppDelegate {
    func uiTestStart() {
        guard UITest.active else { return }
        // 页面脚本都载入、桌宠建好了再开始
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            self?.webView.evaluateJavaScript("typeof flushQueue === 'function' && typeof pets === 'object' && !!pets.claude") { ok, _ in
                guard (ok as? Bool) == true, timer.isValid else { return }
                timer.invalidate()
                self?.uiTestRun()
            }
        }
    }

    private func uiTestRun() {
        guard let script = UITest.script else { return }
        // 界面上方盖一条说明：这是测试窗口（里面的权限、模型是测试脚本设的，和平时用的无关）
        if !UITest.real { webView.evaluateJavaScript("""
            (() => { const b = document.createElement('div'); b.textContent = '自动化测试窗口：脚本在自动操作，权限和模型是测试设的，跑完会自己关掉';
              b.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:99999;padding:5px;text-align:center;font-size:12px;background:#d9534f;color:#fff;pointer-events:none';
              document.body.appendChild(b); })();
            """, completionHandler: nil) }   // 真实窗口模式不盖（窗口本来就在屏幕外，盖了反而挡住要看的顶栏）
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            var payload: [String: Any]
            switch result {
            case .success(let value): payload = ["ok": true, "result": value]
            case .failure(let error): payload = ["ok": false, "error": "\(error)"]
            }
            if !JSONSerialization.isValidJSONObject(payload) { payload = ["ok": false, "error": "结果不能写成 JSON"] }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: UITest.out))
            }
            // 还在跑的 CLI 连同它启动的命令一起结束，再退出
            self.procLock.lock(); let procs = Array(self.runningProcs.values) + self.warmProcs.values.map { $0.proc }; self.procLock.unlock()
            procs.filter { $0.isRunning }.forEach { self.terminateTree($0.processIdentifier) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (procs.isEmpty ? 0.2 : 1.5)) { exit(0) }
        }
    }

    /// 把当时的界面存成 PNG（只在测试时可用）。
    func uiTestSnapshot(_ path: String) {
        guard UITest.active else { return }
        webView.takeSnapshot(with: nil) { image, _ in
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: 真实窗口模式才有的：整窗截图、真实的鼠标点击、红绿灯的位置

    /// 把整个窗口截成 PNG：连标题栏、红绿灯、原生的毛玻璃一起，是系统真正合成出来的样子
    /// （testSnapshot 只截网页内容，而且截不出背景模糊）。截自己的窗口不需要屏幕录制权限。
    /// CGWindowListCreateImage 在新的 SDK 里标成了不可用，但函数还在，这里按名字找出来调。
    func uiTestWindowShot(_ path: String) {
        guard UITest.active, UITest.real else { return }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // 只截这一个窗口（8 = 只包含指定窗口），不带阴影（1），按屏幕的实际分辨率（8）
        guard let image = capture(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// 在网页的 (x, y)（CSS 像素，左上角为原点）上真的点一下：先按窗口的规矩找出这个位置上是哪个视图
    /// （标题栏、原生的毛玻璃这些要是盖在网页上面，找到的就是它们），再把鼠标按下、松开交给它。
    /// 脚本里 element.click() 是直接调网页的，绕过了这一层，原生视图挡没挡住按钮它点不出来。
    /// 点到的是哪种视图会写进日志。
    func uiTestClick(x: Double, y: Double) {
        guard UITest.active, let frameView = window.contentView?.superview else { return }
        let inWindow = webView.convert(NSPoint(x: x, y: webView.isFlipped ? y : Double(webView.bounds.height) - y), to: nil)
        guard let target = frameView.hitTest(inWindow) else { fputs("AIPetHub：点 (\(x), \(y))：没有视图接\n", stderr); return }
        fputs("AIPetHub：点 (\(Int(x)), \(Int(y)))：落在 \(type(of: target)) 上\n", stderr)
        let event: (NSEvent.EventType) -> NSEvent? = { type in
            NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let down = event(.leftMouseDown) { target.mouseDown(with: down) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { if let up = event(.leftMouseUp) { target.mouseUp(with: up) } }
    }

    /// 把窗口改成这么大（红绿灯挪过位置以后，改窗口大小、系统重排标题栏时不能跑回去）。
    func uiTestResize(width: Double, height: Double) {
        guard UITest.active else { return }
        var f = window.frame
        f.size = NSSize(width: width, height: height)
        window.setFrame(f, display: true)
    }

    /// 红绿灯在窗口里的位置（CSS 像素，左上角为原点），告诉网页（window.onTestChrome），用来量它们和顶栏对没对齐。
    func uiTestChrome() {
        guard UITest.active else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let rects = buttons.map { b -> [String: Double] in
            let r = b.convert(b.bounds, to: nil)
            let inside = b.superview.map { $0.bounds.contains(b.frame) } ?? false   // 整个按钮还在标题栏里（出了界会被裁掉）
            return ["left": Double(r.minX), "right": Double(r.maxX), "centerY": Double(window.frame.height - r.midY),
                    "hidden": b.isHidden || b.superview == nil || !inside ? 1 : 0]
        }
        sendToJS("onTestChrome", ["lights": rects, "fullscreen": window.styleMask.contains(.fullScreen)])
    }
}
