import AppKit

final class DebugConsole {
    static let shared = DebugConsole()

    private let enabledDefaultsKey = "LilAgents.debugConsoleEnabled"
    private let maxBufferChars = 250_000

    private var window: NSWindow?
    private var textView: NSTextView?

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            show()
        } else {
            hide()
        }
    }

    func show() {
        DispatchQueue.main.async {
            if self.window == nil {
                self.createWindow()
            }
            self.window?.orderFrontRegardless()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
        }
    }

    func append(_ line: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            if self.window == nil {
                self.createWindow()
            }
            guard let tv = self.textView else { return }

            let ts = Self.timestamp()
            let msg = "[\(ts)] \(line)\n"
            tv.textStorage?.append(NSAttributedString(string: msg))
            self.trimIfNeeded(tv)
            tv.scrollToEndOfDocument(nil)
        }
    }

    private func trimIfNeeded(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let len = storage.length
        guard len > maxBufferChars else { return }
        let overflow = len - maxBufferChars
        storage.deleteCharacters(in: NSRange(location: 0, length: overflow))
    }

    private func createWindow() {
        let w: CGFloat = 720
        let h: CGFloat = 420
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "lil agents — Debug Log"
        win.level = .floating
        win.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: w, height: h))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: scroll.contentView.bounds)
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 10, height: 10)

        scroll.documentView = tv
        win.contentView = scroll

        window = win
        textView = tv
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

