import AppKit

/// A small native, modeless tail window for the managed DSH process output.
@MainActor
final class DSHConsoleWindowController: NSWindowController, NSWindowDelegate {
    private static let maximumVisibleCharacters = 1_500_000

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var refreshTimer: Timer?
    private var logURL: URL?
    private var fileIdentity: UInt64?
    private var readOffset: UInt64 = 0
    private var showingPlaceholder = true

    init() {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek Harness Console"
        window.minSize = NSSize(width: 520, height: 280)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = scrollView
        window.setFrameAutosaveName("DSHConsoleWindow")

        self.textView = textView
        self.scrollView = scrollView
        super.init(window: window)
        window.delegate = self
        showPlaceholder()
    }

    required init?(coder: NSCoder) { nil }

    func show(logURL: URL) {
        self.logURL = logURL
        fileIdentity = nil
        readOffset = 0
        showPlaceholder()
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        startRefreshing()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        guard let logURL else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
            let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if fileIdentity != identity || size < readOffset {
                fileIdentity = identity
                readOffset = 0
                textView.string = ""
                showingPlaceholder = false
            }
            guard size > readOffset else {
                if size == 0 { showPlaceholder() }
                return
            }

            let wasFollowingTail = showingPlaceholder || isNearBottom
            let handle = try FileHandle(forReadingFrom: logURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            readOffset += UInt64(data.count)
            guard !data.isEmpty else { return }

            if showingPlaceholder {
                textView.string = ""
                showingPlaceholder = false
            }
            textView.string += displayText(for: data)
            trimVisibleTextIfNeeded()
            if wasFollowingTail { textView.scrollToEndOfDocument(nil) }
        } catch {
            textView.string = "无法读取 Console：\(error.localizedDescription)"
            showingPlaceholder = true
        }
    }

    private var isNearBottom: Bool {
        let visibleBottom = scrollView.contentView.bounds.maxY
        let documentBottom = scrollView.documentView?.bounds.maxY ?? 0
        return documentBottom - visibleBottom < 40
    }

    private func trimVisibleTextIfNeeded() {
        let text = textView.string
        guard text.count > Self.maximumVisibleCharacters else { return }
        textView.string = "…较早的输出已从窗口中隐藏…\n" + text.suffix(Self.maximumVisibleCharacters)
    }

    private func displayText(for data: Data) -> String {
        String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: #"([?&]token=)[^\s&)]*"#,
            with: "$1<redacted>",
            options: .regularExpression
        )
    }

    private func showPlaceholder() {
        textView.string = "尚无 DSH Console 输出。"
        showingPlaceholder = true
    }
}
