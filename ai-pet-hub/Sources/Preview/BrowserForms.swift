// 内置浏览器的新窗口表单：正文始终留在 WebKit 的原提交里。
//
// 内置浏览器的表单导航都在这里接收。
// GET 保留查询串，POST 始终由 WebKit 把原字段和文件送出。
// 普通顶页在 WebKit 收完字段后才检查按钮、表单和 base 的目标，已有框架继续接收。
// 目标无法确认、事件被页面截住或提交来自子页时，沿用 WebKit 的窗口选择；确实要另开时用它指定的配置接收原提交，在结果页提交导航后接管同一面板。
// 用 WebKit 的免导航接口复制历史，来源页进入原视图的后退缓存。
// 跨过这条历史记录时取回原视图，后退、前进都能沿用已提交的页面。
// 没有结果页的 204 保留原表单。
// 切到别的标签时保留页面，关闭或移出浏览器标签时释放网页及 PDF 视图，停止页面活动。
import WebKit

// WebKit 的公开 interactionState 会同时载入原页。移交表单时只取免导航的历史接口，
// 让后退手势沿用原有记录，也避免为了复制历史把来源页的 POST 再发一次。
@objc private protocol BrowserHistoryTransfer {
    @objc(_sessionState) optional func formSessionState() -> AnyObject?
    @objc(_restoreSessionState:andNavigate:) optional func restoreFormSession(_ state: AnyObject, navigate: Bool) -> AnyObject?
}

// WebKit 组装完字段后才读取最终目标。此时页面的 submit 处理器已运行，
// 直接提交与按钮提交都可以保留同一次导航，包括文件流和返回历史。
let browserFormTarget = """
(() => {
  const {getAttribute, setAttribute, removeAttribute} = Element.prototype;
  const {addEventListener: listen, removeEventListener: unlisten} = EventTarget.prototype;
  const owner = Object.getOwnPropertyDescriptor(Node.prototype, 'ownerDocument').get;
  function routeFormTarget(form, button) {
    const doc = owner.call(form), win = doc.defaultView;
    if (!win || win !== win.top) return;
    const override = button && getAttribute.call(button, 'formtarget') !== null;
    const node = override ? button : form, key = override ? 'formtarget' : 'target';
    const old = getAttribute.call(node, key);
    const target = old ?? Document.prototype.querySelector.call(doc, 'base[target]')?.target;
    if (!target) return;
    if (target.toLowerCase() !== '_blank') {
      if (target.startsWith('_') || (win.opener && !win.opener.closed)) return;
      // 只认实际子窗口；只要有一个框架看不到名字，就把目标交还给 WebKit。
      const frames = [win];
      while (frames.length) {
        const frame = frames.pop();
        try { if (frame.name === target) return; } catch { return; }
        for (let i = 0; i < frame.length; i++) frames.push(frame[i]);
      }
    }
    setAttribute.call(node, key, '_top');
    setTimeout(() => {
      if (getAttribute.call(node, key) !== '_top') return;
      if (old === null) removeAttribute.call(node, key);
      else setAttribute.call(node, key, old);
    }, 0);
  }

  // submitter 只在 submit 上提供，直接 submit() 则跳过该事件。两种入口都在
  // WebKit 收完字段时读属性，页面取消提交、校验失败或单独构造 FormData 都不改目标。
  function prepare(form, button, event) {
    const root = Node.prototype.getRootNode.call(form);
    const last = root.defaultView || root;
    const apply = e => {
      if (e.target === form && (!event || (!event.defaultPrevented && event.eventPhase === Event.NONE))) {
        unlisten.call(last, 'formdata', apply);
        routeFormTarget(form, button);
      }
    };
    listen.call(last, 'formdata', apply);
    return () => unlisten.call(last, 'formdata', apply);
  }
  listen.call(document, 'submit', e => {
    if (e.isTrusted) setTimeout(prepare(e.target, e.submitter, e), 0);
  }, true);
  const proto = HTMLFormElement.prototype, submit = proto.submit;
  proto.submit = function() {
    const cleanup = prepare(this, null, null);
    try { return submit.call(this); } finally { cleanup(); }
  };
})();
"""

extension AppDelegate {
    /// 只有 WebKit 判定确实要另开窗口，才会到这里。流式表单的文件属于原导航，
    /// 交给按原配置创建的网页接收；等有结果页再接管同一个面板。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === browser else { return nil }
        cancelDocumentPreview()
        browserNavigation.begin()
        if ["GET", "HEAD"].contains(navigationAction.request.httpMethod) {
            browserNavigation.navigation = webView.load(navigationAction.request)
            return nil
        }
        let next = BrowserWebView(frame: webView.frame, configuration: configuration)
        next.navigationDelegate = self
        next.uiDelegate = self
        browserNavigation.pendingForm = next
        sendBrowserState()
        return next
    }

    func copyFormHistory(to result: WKWebView) {
        if let source = browser, let history = (source as AnyObject).formSessionState?() {
            _ = (result as AnyObject).restoreFormSession?(history, navigate: false)
        }
    }

    func finishPendingBrowserForm() {
        browserNavigation.pendingForm?.navigationDelegate = nil
        browserNavigation.pendingForm?.uiDelegate = nil
        browserNavigation.pendingForm = nil
        browserNavigation.finished = true
        sendBrowserState()
    }
}

// 两份历史里的网址可以相同，只有对应的历史项才表示跨网页视图的那一步。
// 只从当前一侧持有另一侧，关闭标签或新导航剪掉前进记录时可以一起释放。
private var formHistoryKey: UInt8 = 0
private final class FormHistoryStep: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let back: Bool
    private(set) var failed = false
    var whenParked: (() -> Void)?
    init(_ view: WKWebView, back: Bool) { self.view = view; self.back = back }

    func park(returning: Bool = false) {
        view.navigationDelegate = self
        if returning { view.goForward() }
        else { view.load(URLRequest(url: URL(string: "about:blank")!)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        complete()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed = true
        complete()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failed = true
        complete()
    }

    private func complete() {
        view.navigationDelegate = nil
        let resume = whenParked
        whenParked = nil
        resume?()
    }
}

extension AppDelegate {
    func preserveFormSource(_ source: WKWebView, result: WKWebView) {
        guard let item = result.backForwardList.backItem else { return }
        let step = FormHistoryStep(source, back: true)
        objc_setAssociatedObject(item, &formHistoryKey, step, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // 本地空白响应让来源页进入自己的 WebKit 后退缓存，既不重发 POST，也不在后台运行来源页。
        step.park()
    }

    func traverseFormHistory(_ current: WKWebView, item: WKBackForwardListItem?) -> Bool {
        guard let item, let step = objc_getAssociatedObject(item, &formHistoryKey) as? FormHistoryStep else { return false }
        if step.failed {
            objc_setAssociatedObject(item, &formHistoryKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return false
        }
        let other = step.view
        if other.navigationDelegate === step {
            let generation = browserNavigation.generation
            step.whenParked = { [weak self, weak current, weak item] in
                guard let self, let current, let item, current === self.browser, self.browserNavigation.generation == generation else { return }
                if !self.traverseFormHistory(current, item: item) { self.browserNavigation.navigation = current.go(to: item) }
            }
            return true
        }
        let returnItem = step.back ? other.backForwardList.currentItem : other.backForwardList.backItem
        guard let returnItem else { return false }
        cancelDocumentPreview()
        browserNavigation.begin()
        objc_setAssociatedObject(item, &formHistoryKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let reverse = FormHistoryStep(current, back: !step.back)
        objc_setAssociatedObject(returnItem, &formHistoryKey, reverse, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        installBrowser(other)
        if step.back {
            browserNavigation.navigation = other.goBack()
        } else {
            reverse.park(returning: true)
            browserNavigation.finished = true
        }
        notePDF(other)
        sendBrowserState()
        return true
    }

    // 系统后退手势和页面的 history.back() 也可能跨过表单边界。
    @objc(_webView:shouldGoToBackForwardListItem:inPageCache:completionHandler:)
    func decideFormHistory(_ view: WKWebView, item: WKBackForwardListItem, inPageCache: Bool, completionHandler: @escaping (Bool) -> Void) {
        guard view === browser, traverseFormHistory(view, item: item) else { completionHandler(true); return }
        completionHandler(false)
    }
}
