// 窗口和几个自定义视图：主窗口、翻转坐标的容器、界面的 WebView（接收拖进来的文件）、内置浏览器的 WebView。
import Cocoa
import WebKit

final class HubWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 窗口的内容视图：界面 WKWebView 铺满，内置浏览器盖在预览面板的位置上。左上角为原点。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 内置浏览器：在里面拖动是选文字 / 拖网页元素，不能拖动整个窗口。
final class BrowserWebView: WKWebView {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class HubWebView: WKWebView {
    /// 从访达拖进来的文件交给网页插入路径；不交给 WebKit，否则它会直接打开文件、把整个界面换掉。
    var onFileDrop: (([String]) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    private func droppedFiles(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        if files.isEmpty { return super.performDragOperation(sender) }
        onFileDrop?(files)
        return true
    }

    /// 右键菜单去掉「重新载入」「后退 / 前进」、在新窗口打开、下载这类会把界面换掉或没有意义的项，保留拷贝、查询等。
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let blocked = ["Reload", "GoBack", "GoForward", "NewWindow", "Download", "OpenFrame", "OpenLink", "OpenImage", "OpenMedia"]
        for item in menu.items where blocked.contains(where: { item.identifier?.rawValue.contains($0) == true }) {
            menu.removeItem(item)
        }
        // 删掉后留下的多余分隔线
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        super.willOpenMenu(menu, with: event)
    }
}
