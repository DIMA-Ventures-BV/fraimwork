// Fraim Queue.app: the fraim review queue in its own native window (WebKit, no browser).
// Built on the Mac by `fraim queue app` with swiftc; no Xcode project, no dependencies.
//
// Contents/Resources/queue.url holds the page address with its token, and queue.label the
// launchd label of the tunnel that `fraim queue keep` keeps open. The page tells this shell
// its inbox count (Dock badge) and new items (macOS notifications) through window.webkit.
import Cocoa
import UserNotifications
import WebKit

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
  WKScriptMessageHandler, UNUserNotificationCenterDelegate
{
  var window: NSWindow!
  var web: WKWebView!
  var home: URL!
  var origin = ""
  var loaded = false

  func resource(_ name: String) -> String {
    let file = Bundle.main.resourceURL!.appendingPathComponent(name)
    return ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    guard let url = URL(string: resource("queue.url")), let host = url.host else {
      fail("This app has no queue address. Ask Claude to run: fraim queue app")
      return
    }
    home = url
    origin = "\(url.scheme ?? "http")://\(host):\(url.port ?? 80)"
    buildMenu()

    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "fraim")
    config.websiteDataStore = .default()
    web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.allowsBackForwardNavigationGestures = false
    web.setValue(false, forKey: "drawsBackground")

    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Fraim Queue"
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(red: 0.063, green: 0.067, blue: 0.075, alpha: 1)
    window.contentView = web
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    window.setFrameAutosaveName("FraimQueueWindow")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

    showMessage("Connecting to your server...")
    wakeTunnelThenLoad(tries: 0)
  }

  // The kept tunnel (launchd) may sleep after the Mac slept: wake it, then wait for /health.
  func wakeTunnelThenLoad(tries: Int) {
    if tries == 0 {
      let label = resource("queue.label")
      if !label.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        try? p.run()
      }
    }
    var req = URLRequest(url: URL(string: origin + "/health")!)
    req.timeoutInterval = 2
    URLSession.shared.dataTask(with: req) { _, res, _ in
      DispatchQueue.main.async {
        if (res as? HTTPURLResponse)?.statusCode == 200 {
          self.web.load(URLRequest(url: self.home))
        } else if tries < 40 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.wakeTunnelThenLoad(tries: tries + 1) }
        } else {
          self.showMessage("Your server does not answer. Check the internet connection, or ask Claude: is my fraim server up?", retry: true)
        }
      }
    }.resume()
  }

  func showMessage(_ text: String, retry: Bool = false) {
    let safe = text.replacingOccurrences(of: "<", with: "&lt;")
    let button = retry ? "<p><a href=\"fraim-retry:\" style=\"color:#6f7bf0\">Try again</a></p>" : ""
    web.loadHTMLString(
      "<html><body style=\"background:#101113;color:#868a93;font:14px -apple-system;display:grid;place-items:center;height:96vh;text-align:center\"><div><p>\(safe)</p>\(button)</div></body></html>",
      baseURL: nil)
  }

  func fail(_ text: String) {
    let alert = NSAlert()
    alert.messageText = "Fraim Queue"
    alert.informativeText = text
    alert.runModal()
    NSApp.terminate(nil)
  }

  // Page -> app: {count, fresh: [{id, title, body}]}.
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any] else { return }
    if let count = body["count"] as? Int {
      NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
    for item in (body["fresh"] as? [[String: Any]]) ?? [] {
      let content = UNMutableNotificationContent()
      content.title = (item["title"] as? String) ?? "New in your queue"
      content.body = (item["body"] as? String) ?? ""
      content.sound = .default
      content.userInfo = ["id": (item["id"] as? String) ?? ""]
      UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }

  // A click on a notice opens the window on that item.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler done: @escaping () -> Void
  ) {
    let id = (response.notification.request.content.userInfo["id"] as? String) ?? ""
    DispatchQueue.main.async {
      self.window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      if id.range(of: "^q[0-9]+$", options: .regularExpression) != nil {
        self.web.evaluateJavaScript("view = 'inbox'; showDone = false; load('\(id)')")
      }
    }
    done()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    done(window.isKeyWindow ? [] : [.banner, .sound])
  }

  // The queue stays in this window; every other link opens in the default browser.
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    if url.scheme == "fraim-retry" {
      decisionHandler(.cancel)
      showMessage("Connecting to your server...")
      wakeTunnelThenLoad(tries: 0)
      return
    }
    if url.absoluteString.hasPrefix(origin) || url.scheme == "about" || action.targetFrame?.isMainFrame == false {
      return decisionHandler(.allow)
    }
    NSWorkspace.shared.open(url)
    decisionHandler(.cancel)
  }

  func webView(
    _ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration, for action: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url { NSWorkspace.shared.open(url) }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if webView.url?.absoluteString.hasPrefix(origin) == true { loaded = true }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { lost() }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    lost()
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { web.load(URLRequest(url: home)) }

  func lost() {
    loaded = false
    showMessage("Connecting to your server...")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.wakeTunnelThenLoad(tries: 0) }
  }

  // Dictation in the composer uses the microphone.
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(origin.host == home.host ? .grant : .deny)
  }

  // Coming back to the window shows the newest state at once, not after the next 30s refresh.
  func applicationDidBecomeActive(_ note: Notification) {
    if loaded { web?.evaluateJavaScript("typeof load === 'function' && !rec && load(items[sel] && (items[sel].id || items[sel].name))") }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    window.makeKeyAndOrderFront(nil)
    return true
  }

  // Closing the window hides it; the app keeps its badge and notices until Cmd+Q.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }

  @objc func reload(_ sender: Any?) {
    if loaded { web.reload() } else { wakeTunnelThenLoad(tries: 0) }
  }

  @objc func openInBrowser(_ sender: Any?) {
    NSWorkspace.shared.open(home)
  }

  func buildMenu() {
    let main = NSMenu()
    func add(_ title: String, _ items: [NSMenuItem]) {
      let top = NSMenuItem()
      let menu = NSMenu(title: title)
      items.forEach { menu.addItem($0) }
      top.submenu = menu
      main.addItem(top)
    }
    func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
      i.keyEquivalentModifierMask = mods
      return i
    }
    add(
      "Fraim Queue",
      [
        item("Hide Fraim Queue", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        .separator(),
        item("Quit Fraim Queue", #selector(NSApplication.terminate(_:)), "q"),
      ])
    add(
      "Edit",
      [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
      ])
    let reload = item("Reload", #selector(reload(_:)), "r")
    reload.target = self
    let browser = item("Open in Browser", #selector(openInBrowser(_:)), "o", [.command, .shift])
    browser.target = self
    add("View", [reload, browser, .separator(), item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
    add(
      "Window",
      [
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      ])
    NSApp.mainMenu = main
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
