import AppKit
import WebKit

@main
enum DSHShellMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate

        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    /// 调整这里，然后按 ⌘R：同时控制网页左上角避让距离和原生拖动带高度。
    private static let titlebarSafeAreaHeight: CGFloat = 14

    private var window: NSWindow!
    private var splashView: SplashView!
    private var webView: WKWebView!
    private var updateButton: NSButton!
    private var runtime: DSHRuntime?
    private var launchTask: Task<Void, Never>?
    private var consoleWindowController: DSHConsoleWindowController?
    private var newConversationMenuItem: NSMenuItem!
    private var restartServerMenuItem: NSMenuItem!
    private var showConsoleMenuItem: NSMenuItem!
    private var runtimePrepared = false
    private var serviceOperationInProgress = false
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        launchTask = Task { await launchDSH() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime != nil, !terminationPending else { return .terminateNow }
        terminationPending = true
        launchTask?.cancel()
        Task {
            await runtime?.stop()
            runtime = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.center()

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.safeAreaScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        splashView = SplashView()
        splashView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        window.contentView = container
        container.addSubview(webView)
        container.addSubview(splashView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            splashView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splashView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splashView.topAnchor.constraint(equalTo: container.topAnchor),
            splashView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        updateButton = NSButton(title: "更新", target: self, action: #selector(confirmUpdate))
        updateButton.bezelStyle = .roundRect
        updateButton.controlSize = .small
        updateButton.isHidden = true
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(updateButton, positioned: .above, relativeTo: splashView)
        NSLayoutConstraint.activate([
            updateButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 78),
            updateButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
        ])

        let dragView = WindowDragView()
        dragView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dragView, positioned: .above, relativeTo: updateButton)
        NSLayoutConstraint.activate([
            // The matching injected titlebar inset leaves this strip genuinely
            // empty. Keep its leading edge clear of traffic lights and Update.
            dragView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 140),
            dragView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -80),
            dragView.topAnchor.constraint(equalTo: container.topAnchor),
            dragView.heightAnchor.constraint(equalToConstant: Self.titlebarSafeAreaHeight),
        ])

        webView.isHidden = true
        window.makeKeyAndOrderFront(nil)
    }

    private func launchDSH() async {
        do {
            splashView.setStatus("正在准备…")
            let runtime = try DSHRuntime()
            self.runtime = runtime
            showConsoleMenuItem.isEnabled = true
            let tag = try await runtime.prepare { [weak self] text, progress in
                self?.splashView.setStatus(text, progress: progress)
            }
            runtimePrepared = true
            updateServiceMenuState()
            try Task.checkCancellation()
            let authenticatedURL = try await runtime.startServer { [weak self] text, progress in
                self?.splashView.setStatus(text, progress: progress)
            }
            try Task.checkCancellation()
            splashView.setStatus("正在载入界面…")
            webView.load(URLRequest(url: authenticatedURL))
            let next = await runtime.fetchNewVersion(comparedTo: tag)
            if let next {
                updateButton.toolTip = "发现新版本 \(next)"
                updateButton.isHidden = false
            }
        } catch is CancellationError {
            return
        } catch {
            await recordLaunchError(error)
            showLaunchError(error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        splashView.setStatus("启动完成")
        webView.isHidden = false
        splashView.isHidden = true
        newConversationMenuItem.isEnabled = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.host == "127.0.0.1" || url.host == "localhost" { return .allow }
        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    @objc private func confirmUpdate() {
        let alert = NSAlert()
        alert.messageText = "更新 DSH？"
        alert.informativeText = "App 将重新启动，并在启动过程中切换、构建新的 DSH 版本。"
        alert.addButton(withTitle: "更新并重启")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateButton.isEnabled = false
        Task {
            await runtime?.stop()
            runtime = nil
            relaunch()
        }
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            Task {
                await recordLaunchError(error)
                showLaunchError(error)
            }
        }
    }

    private func showLaunchError(_ error: Error) {
        splashView.status = "启动失败"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DSH 启动失败"
        alert.informativeText = "\(briefDescription(for: error))\n\n完整信息请在“DSH → 显示 Console”中查看。"
        alert.addButton(withTitle: "打开 Console")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            showConsole()
        }
    }

    private func briefDescription(for error: Error) -> String {
        if let runtimeError = error as? RuntimeError {
            return runtimeError.briefDescription
        }
        let cocoaError = error as NSError
        return "发生了 \(cocoaError.domain) 错误（\(cocoaError.code)）。"
    }

    private func recordLaunchError(_ error: Error) async {
        if let runtimeError = error as? RuntimeError {
            switch runtimeError {
            case .commandFailed, .serverExited:
                return // Their complete output is already in the Console file.
            default:
                break
            }
        }
        await runtime?.recordDiagnostic(error.localizedDescription)
    }

    private func updateServiceMenuState() {
        restartServerMenuItem.isEnabled = runtimePrepared && !serviceOperationInProgress
    }

    @objc private func restartServer() {
        guard runtimePrepared, !serviceOperationInProgress, let runtime else { return }
        launchTask?.cancel()
        serviceOperationInProgress = true
        updateServiceMenuState()
        newConversationMenuItem.isEnabled = false
        webView.stopLoading()
        webView.isHidden = true
        splashView.isHidden = false
        splashView.setStatus("正在重新启动 Server…")

        launchTask = Task {
            defer {
                serviceOperationInProgress = false
                updateServiceMenuState()
            }
            do {
                await runtime.stop()
                try Task.checkCancellation()
                let authenticatedURL = try await runtime.startServer { [weak self] text, progress in
                    self?.splashView.setStatus(text, progress: progress)
                }
                try Task.checkCancellation()
                splashView.setStatus("正在载入界面…")
                webView.load(URLRequest(url: authenticatedURL))
            } catch is CancellationError {
                return
            } catch {
                await recordLaunchError(error)
                showLaunchError(error)
            }
        }
    }

    @objc private func showConsole() {
        guard let logURL = runtime?.consoleOutputURL else { return }
        let controller = consoleWindowController ?? DSHConsoleWindowController()
        consoleWindowController = controller
        controller.show(logURL: logURL)
    }

    @objc private func startNewConversation() {
        guard !webView.isHidden else {
            NSSound.beep()
            return
        }
        Task {
            do {
                let result = try await webView.evaluateJavaScript(Self.newConversationScript)
                guard result as? Bool == true else {
                    NSSound.beep()
                    await runtime?.recordDiagnostic(
                        "New Conversation menu action could not find DSH's accessible New Session button."
                    )
                    return
                }
            } catch {
                NSSound.beep()
                await runtime?.recordDiagnostic("New Conversation menu action failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func centerActiveWindow() {
        (NSApp.keyWindow ?? NSApp.mainWindow ?? window)?.center()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DeepSeek Harness"
        appItem.title = appName
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        fileItem.title = "文件"
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        newConversationMenuItem = fileMenu.addItem(
            withTitle: "新对话",
            action: #selector(startNewConversation),
            keyEquivalent: "n"
        )
        newConversationMenuItem.target = self
        newConversationMenuItem.isEnabled = false
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "关闭",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileItem.submenu = fileMenu

        let dshItem = NSMenuItem()
        dshItem.title = "DSH"
        main.addItem(dshItem)
        let dshMenu = NSMenu(title: "DSH")
        restartServerMenuItem = dshMenu.addItem(
            withTitle: "重新启动 Server",
            action: #selector(restartServer),
            keyEquivalent: "r"
        )
        restartServerMenuItem.target = self
        restartServerMenuItem.keyEquivalentModifierMask = [.command, .shift]
        restartServerMenuItem.isEnabled = false
        showConsoleMenuItem = dshMenu.addItem(
            withTitle: "显示 Console",
            action: #selector(showConsole),
            keyEquivalent: "l"
        )
        showConsoleMenuItem.target = self
        showConsoleMenuItem.keyEquivalentModifierMask = [.command, .option]
        showConsoleMenuItem.isEnabled = false
        dshItem.submenu = dshMenu

        let editItem = NSMenuItem()
        editItem.title = "编辑"
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        windowItem.title = "窗口"
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        let centerItem = windowMenu.addItem(
            withTitle: "居中",
            action: #selector(centerActiveWindow),
            keyEquivalent: "c"
        )
        centerItem.target = self
        centerItem.keyEquivalentModifierMask = [.control, .option]
        let fullScreenItem = windowMenu.addItem(
            withTitle: "进入全屏幕",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(.separator())
        let bringAllToFrontItem = windowMenu.addItem(
            withTitle: "全部置于顶层",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        bringAllToFrontItem.target = NSApp
        windowItem.submenu = windowMenu

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private static let newConversationScript = #"""
    (() => {
      const button = document.querySelector(
        'button[aria-label="新建会话"], button[aria-label="New session"]'
      );
      if (!(button instanceof HTMLButtonElement) || button.disabled) return false;
      button.click();
      return true;
    })();
    """#

    private static let safeAreaScript = #"""
    (() => {
      const MARK = 'data-dsh-macos-titlebar';
      let observer;
      const style = document.createElement('style');
      style.id = 'dsh-macos-shell-style';
      style.textContent = `
        [${MARK}] { margin-top: \#(titlebarSafeAreaHeight)px !important; }

        html, body {
          -webkit-user-select: none !important;
          user-select: none !important;
        }

        input,
        textarea,
        [role="alert"],
        [role="status"],
        [role="dialog"] p,
        [data-composer-input][contenteditable="true"],
        [data-chat-flow-key],
        [data-pending-steering],
        [data-submission-echo] {
          -webkit-user-select: text !important;
          user-select: text !important;
        }

        button,
        [role="button"],
        [role="tab"],
        summary,
        [data-composer-placeholder] {
          -webkit-user-select: none !important;
          user-select: none !important;
        }
      `;
      document.head.appendChild(style);

      function mark() {
        document.querySelectorAll(`[${MARK}]`).forEach(node => node.removeAttribute(MARK));
        const logo = [...document.querySelectorAll('svg[viewBox]')].find(svg =>
          svg.getAttribute('viewBox')?.replaceAll(',', ' ').replace(/\s+/g, ' ').trim() === '0 0 23.16 17.04'
        );
        const button = logo?.closest('button');
        const row = button?.parentElement;
        if (!row) return;
        row.setAttribute(MARK, '');
      }

      let queued = false;
      function queueMark() {
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; mark(); });
      }

      observer = new MutationObserver(queueMark);
      observer.observe(document.documentElement, { childList: true, subtree: true });
      window.addEventListener('resize', queueMark);
      mark();
    })();
    """#
}

@MainActor
final class SplashView: NSView {
    private let statusLabel = NSTextField(labelWithString: "正在启动…")
    private let progressIndicator = NSProgressIndicator()

    var status: String {
        get { statusLabel.stringValue }
        set { setStatus(newValue) }
    }

    func setStatus(_ text: String, progress: Double? = nil) {
        statusLabel.stringValue = text
        progressIndicator.isHidden = progress == nil
        if let progress {
            progressIndicator.doubleValue = min(max(progress, 0), 1)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let logo = NSImageView()
        if let url = Bundle.main.url(forResource: "FishLogo", withExtension: "svg") {
            logo.image = NSImage(contentsOf: url)
        }
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = true
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let stack = NSStackView(views: [logo, statusRow, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 74),
            logo.heightAnchor.constraint(equalToConstant: 55),
            progressIndicator.widthAnchor.constraint(equalToConstant: 260),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// A transparent titlebar drag strip constrained to the page's genuinely empty top inset.
@MainActor
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
