// 菜单栏和缩放。
import Cocoa

extension AppDelegate {
    func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 AIPetHub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 AIPetHub", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 AIPetHub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        // 显示：字号缩放（⌘+ / ⌘- / ⌘0），记住上次的大小
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "=").target = self
        let plus = viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        plus.target = self
        plus.isHidden = true
        plus.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "-").target = self
        viewMenu.addItem(withTitle: "实际大小", action: #selector(zoomReset(_:)), keyEquivalent: "0").target = self
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom + 0.1) }

    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom - 0.1) }

    @objc func zoomReset(_ sender: Any?) { setZoom(1) }

    func setZoom(_ value: CGFloat) {
        let z = min(2, max(0.6, (value * 10).rounded() / 10))
        webView.pageZoom = z
        UserDefaults.standard.set(Double(z), forKey: "pageZoom")
    }
}
