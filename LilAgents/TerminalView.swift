import AppKit

class PaddedTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 2)
    var fieldBackgroundColor: NSColor?
    var fieldCornerRadius: CGFloat = 4

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let bg = fieldBackgroundColor {
            let path = NSBezierPath(roundedRect: cellFrame, xRadius: fieldCornerRadius, yRadius: fieldCornerRadius)
            bg.setFill()
            path.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        return base.insetBy(dx: inset.width, dy: inset.height)
    }

    private func configureEditor(_ textObj: NSText) {
        if let color = textColor {
            textObj.textColor = color
        }
        if let tv = textObj as? NSTextView {
            tv.insertionPointColor = textColor ?? .textColor
            tv.drawsBackground = false
            tv.backgroundColor = .clear
        }
        textObj.font = font
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        configureEditor(textObj)
        super.edit(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        configureEditor(textObj)
        super.select(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

class TerminalView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let inputField = NSTextField()
    var onSendMessage: ((String) -> Void)?
    var onClearRequested: (() -> Void)?
    /// Set when provider is Cursor so `/model`, `/list-models`, etc. work.
    weak var cursorAgentSession: CursorAgentSession?

    private var currentAssistantText = ""
    private var lastAssistantText = ""
    private var isStreaming = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    var characterColor: NSColor?
    var themeOverride: PopoverTheme?
    var theme: PopoverTheme {
        var t = themeOverride ?? PopoverTheme.current
        if let color = characterColor { t = t.withCharacterColor(color) }
        t = t.withCustomFont()
        return t
    }

    // MARK: - Setup

    private func setupViews() {
        let t = theme
        let inputHeight: CGFloat = 30
        let padding: CGFloat = 10

        scrollView.frame = NSRect(
            x: padding, y: inputHeight + padding + 6,
            width: frame.width - padding * 2,
            height: frame.height - inputHeight - padding - 10
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = t.textPrimary
        textView.font = t.font
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        inputField.frame = NSRect(
            x: padding, y: 6,
            width: frame.width - padding * 2,
            height: inputHeight
        )
        inputField.autoresizingMask = [.width]
        inputField.focusRingType = .none
        let paddedCell = PaddedTextFieldCell(textCell: "")
        paddedCell.isEditable = true
        paddedCell.isScrollable = true
        paddedCell.font = t.font
        paddedCell.textColor = t.textPrimary
        paddedCell.drawsBackground = false
        paddedCell.isBezeled = false
        paddedCell.fieldBackgroundColor = nil
        paddedCell.fieldCornerRadius = 0
        paddedCell.placeholderAttributedString = NSAttributedString(
            string: AgentProvider.current.inputPlaceholder,
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
        inputField.cell = paddedCell
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        addSubview(inputField)
    }

    /// Re-applies `theme` fonts after `PopoverTheme.customFontSize` changes.
    func refreshFontsFromTheme() {
        let t = theme
        textView.font = t.font
        textView.textColor = t.textPrimary
        if let cell = inputField.cell as? PaddedTextFieldCell {
            cell.font = t.font
            cell.textColor = t.textPrimary
            cell.placeholderAttributedString = NSAttributedString(
                string: AgentProvider.current.inputPlaceholder,
                attributes: [.font: t.font, .foregroundColor: t.textDim]
            )
        }
        inputField.needsDisplay = true
        textView.needsDisplay = true
    }

    // MARK: - Input

    @objc private func inputSubmitted() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""

        if handleSlashCommand(text) { return }

        appendUser(text)
        isStreaming = true
        currentAssistantText = ""
        onSendMessage?(text)
    }

    // MARK: - Slash Commands

    func handleSlashCommandPublic(_ text: String) {
        _ = handleSlashCommand(text)
    }

    private func slashHeadAndRest(_ text: String) -> (head: String, rest: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return ("", "") }
        let head = String(first).lowercased()
        let rest = parts.count > 1 ? String(parts[1]) : ""
        return (head, rest)
    }

    private func appendSystemLine(_ text: String) {
        let t = theme
        ensureNewline()
        textView.textStorage?.append(NSAttributedString(
            string: "  \(text)\n",
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        ))
        scrollToBottom()
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let (head, rest) = slashHeadAndRest(text)

        if AgentProvider.current == .cursor, let cursor = cursorAgentSession {
            switch head {
            case "/model":
                let msg = cursor.handleSlashModel(rest)
                appendSystemLine(msg)
                return true
            case "/list-models":
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let msg = cursor.runListModels()
                    DispatchQueue.main.async {
                        self?.appendSystemLine(msg)
                    }
                }
                return true
            case "/mode":
                let msg = cursor.handleSlashMode(rest)
                appendSystemLine(msg)
                return true
            case "/sandbox":
                let msg = cursor.handleSlashSandbox(rest)
                appendSystemLine(msg)
                return true
            default:
                break
            }
        }

        switch head {
        case "/clear":
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            onClearRequested?()
            return true

        case "/copy":
            let toCopy = lastAssistantText.isEmpty ? "nothing to copy yet" : lastAssistantText
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toCopy, forType: .string)
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  ✓ copied to clipboard\n",
                attributes: [.font: t.font, .foregroundColor: t.successColor]
            ))
            scrollToBottom()
            return true

        case "/help":
            let t = theme
            let help = NSMutableAttributedString()
            help.append(NSAttributedString(string: "  lil agents — slash commands\n",
                attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
            help.append(NSAttributedString(string: "  /clear  ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "clear chat history\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            help.append(NSAttributedString(string: "  /copy   ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "copy last response\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            help.append(NSAttributedString(string: "  /help   ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "show this message\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            if AgentProvider.current == .cursor {
                help.append(NSAttributedString(string: "\n  — Cursor CLI —\n", attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
                let dim: [NSAttributedString.Key: Any] = [.font: t.font, .foregroundColor: t.textDim]
                let cmd: [NSAttributedString.Key: Any] = [.font: t.fontBold, .foregroundColor: t.textPrimary]
                help.append(NSAttributedString(string: "  /model\n", attributes: cmd))
                help.append(NSAttributedString(string: "      (no args)     show current model (or default)\n", attributes: dim))
                help.append(NSAttributedString(string: "      <name>        set agent --model <name>\n", attributes: dim))
                help.append(NSAttributedString(string: "      clear|default clear model override\n", attributes: dim))
                help.append(NSAttributedString(string: "  /list-models\n", attributes: cmd))
                help.append(NSAttributedString(string: "      run agent --list-models (available models)\n", attributes: dim))
                help.append(NSAttributedString(string: "  /mode\n", attributes: cmd))
                help.append(NSAttributedString(string: "      (no args)     show current mode\n", attributes: dim))
                help.append(NSAttributedString(string: "      agent         full agent (edits/tools)\n", attributes: dim))
                help.append(NSAttributedString(string: "      plan          read-only planning (--plan)\n", attributes: dim))
                help.append(NSAttributedString(string: "      ask           Q&A only (--mode ask)\n", attributes: dim))
                help.append(NSAttributedString(string: "      default       same as agent\n", attributes: dim))
                help.append(NSAttributedString(string: "  /sandbox\n", attributes: cmd))
                help.append(NSAttributedString(string: "      (no args)     show current sandbox setting\n", attributes: dim))
                help.append(NSAttributedString(string: "      on|enabled    --sandbox enabled\n", attributes: dim))
                help.append(NSAttributedString(string: "      off|disabled  --sandbox disabled\n", attributes: dim))
                help.append(NSAttributedString(string: "      default|clear use CLI default\n", attributes: dim))
            }
            textView.textStorage?.append(help)
            scrollToBottom()
            return true

        default:
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  unknown command: \(text) (try /help)\n",
                attributes: [.font: t.font, .foregroundColor: t.errorColor]
            ))
            scrollToBottom()
            return true
        }
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        ensureNewline()
        let para = messageSpacing
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        let body = NSMutableAttributedString(attributedString: renderInlineMarkdown(text, theme: t))
        body.addAttributes([.paragraphStyle: para], range: NSRange(location: 0, length: body.length))
        // Keep user text visually distinct, but preserve link attributes.
        if body.length > 0 {
            body.enumerateAttribute(.font, in: NSRange(location: 0, length: body.length)) { value, range, _ in
                if value != nil {
                    body.addAttribute(.font, value: t.fontBold, range: range)
                } else {
                    body.addAttribute(.font, value: t.fontBold, range: range)
                }
            }
        }
        body.addAttributes([.foregroundColor: t.textPrimary], range: NSRange(location: 0, length: body.length))
        attributed.append(body)
        attributed.append(NSAttributedString(string: "\n", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary, .paragraphStyle: para]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        if !cleaned.isEmpty {
            textView.textStorage?.append(renderMarkdown(cleaned))
            scrollToBottom()
        }
    }

    func endStreaming() {
        if isStreaming {
            isStreaming = false
            if !currentAssistantText.isEmpty {
                lastAssistantText = currentAssistantText
            }
            currentAssistantText = ""
        }
    }

    func appendError(_ text: String) {
        let t = theme
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        endStreaming()
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let color = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: t.fontBold, .foregroundColor: color
        ]))
        block.append(NSAttributedString(string: "\(summary.isEmpty ? "" : summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    /// 首次引导弹窗打开时切换语言，替换欢迎正文（保持输入区仍为不可编辑引导态）。
    func setOnboardingWelcomeText(_ text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        currentAssistantText = ""
        isStreaming = false
        appendStreamingText(text)
        endStreaming()
    }

    func replayHistory(_ messages: [AgentMessage]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
            case .error:
                appendError(msg.text)
            case .toolUse:
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: isErr ? t.errorColor : t.successColor
                ]))
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeLines.joined(separator: "\n")
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
                    result.append(NSAttributedString(string: codeText + "\n", attributes: [
                        .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                    codeBlockLang = String(line.dropFirst(3))
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("## ") {
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 1, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 2, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "  \u{2022} ", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
                result.append(renderInlineMarkdown(content + suffix, theme: t))
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: t))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            let codeText = codeLines.joined(separator: "\n")
            let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
            result.append(NSAttributedString(string: codeText + "\n", attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
            ]))
        }

        return result
    }

    private func renderInlineMarkdown(_ text: String, theme t: PopoverTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 0.5, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                    ]))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let bold = String(text[start..<range.lowerBound])
                    result.append(NSAttributedString(string: bold, attributes: [
                        .font: t.fontBold, .foregroundColor: t.textPrimary
                    ]))
                    i = range.upperBound
                    continue
                }
            }
            // Image link preview: [![alt](thumbUrl)](fullUrl) -> render thumbnail attachment linked to fullUrl
            if text[i] == "[",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "!",
               text.index(i, offsetBy: 2, limitedBy: text.endIndex) != nil,
               text[text.index(i, offsetBy: 2)] == "[" {
                let openOuter = i
                let altStart = text.index(i, offsetBy: 3)
                if altStart < text.endIndex,
                   let altEnd = text[altStart...].firstIndex(of: "]") {
                    let alt = String(text[altStart..<altEnd])
                    // Expect (thumbUrl)
                    let thumbParenStart = text.index(after: altEnd)
                    if thumbParenStart < text.endIndex, text[thumbParenStart] == "(" {
                        let thumbUrlStart = text.index(after: thumbParenStart)
                        if thumbUrlStart < text.endIndex,
                           let thumbUrlEnd = text[thumbUrlStart...].firstIndex(of: ")") {
                            // Expect ](fullUrl)
                            let closeInnerBracket = text.index(after: thumbUrlEnd)
                            if closeInnerBracket < text.endIndex, text[closeInnerBracket] == "]" {
                                let fullParenStart = text.index(after: closeInnerBracket)
                                if fullParenStart < text.endIndex, text[fullParenStart] == "(" {
                                    let fullUrlStart = text.index(after: fullParenStart)
                                    if fullUrlStart < text.endIndex,
                                       let fullUrlEnd = text[fullUrlStart...].firstIndex(of: ")") {
                                        let fullUrlStr = String(text[fullUrlStart..<fullUrlEnd])
                                        let thumbUrlStr = String(text[thumbUrlStart..<thumbUrlEnd])
                                        if let thumbURL = URL(string: thumbUrlStr),
                                           let fullURL = URL(string: fullUrlStr) {
                                            result.append(makeLinkedImageAttachment(thumbURL: thumbURL, linkURL: fullURL, alt: alt, theme: t))
                                        } else {
                                            // Fallback to link text if URLs are invalid
                                            let label = alt.isEmpty ? "preview" : alt
                                            var attrs: [NSAttributedString.Key: Any] = [
                                                .font: t.fontBold,
                                                .foregroundColor: t.accentColor,
                                                .underlineStyle: NSUnderlineStyle.single.rawValue
                                            ]
                                            if let url = URL(string: fullUrlStr) {
                                                attrs[.link] = url
                                                attrs[.cursor] = NSCursor.pointingHand
                                            }
                                            result.append(NSAttributedString(string: label, attributes: attrs))
                                        }
                                        i = text.index(after: fullUrlEnd)
                                        continue
                                    }
                                }
                            }
                        }
                    }
                }
                // If parsing failed, fall through and render as plain text.
                i = text.index(after: openOuter)
                continue
            }
            // Image: ![alt](url) -> render attachment linked to url
            if text[i] == "!",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "[" {
                let altStart = text.index(i, offsetBy: 2)
                if altStart < text.endIndex,
                   let altEnd = text[altStart...].firstIndex(of: "]") {
                    let parenStart = text.index(after: altEnd)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let urlStart = text.index(after: parenStart)
                        if urlStart < text.endIndex,
                           let urlEnd = text[urlStart...].firstIndex(of: ")") {
                            let alt = String(text[altStart..<altEnd])
                            let urlStr = String(text[urlStart..<urlEnd])
                            if let url = URL(string: urlStr) {
                                result.append(makeLinkedImageAttachment(thumbURL: url, linkURL: url, alt: alt, theme: t))
                            } else {
                                let label = alt.isEmpty ? "image" : alt
                                var attrs: [NSAttributedString.Key: Any] = [
                                    .font: t.font,
                                    .foregroundColor: t.accentColor,
                                    .underlineStyle: NSUnderlineStyle.single.rawValue
                                ]
                                if let url = URL(string: urlStr) {
                                    attrs[.link] = url
                                    attrs[.cursor] = NSCursor.pointingHand
                                }
                                result.append(NSAttributedString(string: label, attributes: attrs))
                            }
                            i = text.index(after: urlEnd)
                            continue
                        }
                    }
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: t.font,
                                .foregroundColor: t.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                                attrs[.cursor] = NSCursor.pointingHand
                            }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: t.font,
                        .foregroundColor: t.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlStr) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: t.font, .foregroundColor: t.textPrimary
            ]))
            i = text.index(after: i)
        }
        return result
    }

    private static let imageCache = NSCache<NSURL, NSImage>()

    private func makeLinkedImageAttachment(thumbURL: URL, linkURL: URL, alt: String, theme t: PopoverTheme) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: alt) ?? NSImage()
        attachment.image = placeholder

        // Make the attachment reasonably small for chat.
        let maxH: CGFloat = 90
        let maxW: CGFloat = 160
        let phSize = placeholder.size
        let scale = min(maxW / max(phSize.width, 1), maxH / max(phSize.height, 1), 1.0)
        attachment.bounds = CGRect(x: 0, y: -2, width: round(phSize.width * scale), height: round(phSize.height * scale))

        let attr = NSMutableAttributedString(attachment: attachment)
        // Link attribute on attachment range makes it clickable in NSTextView.
        attr.addAttributes([
            .link: linkURL,
            .cursor: NSCursor.pointingHand
        ], range: NSRange(location: 0, length: attr.length))

        // Async load thumbnail and swap attachment image.
        if let cached = Self.imageCache.object(forKey: thumbURL as NSURL) {
            applyImage(cached, to: attachment, maxW: maxW, maxH: maxH)
        } else {
            URLSession.shared.dataTask(with: thumbURL) { [weak self] data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                Self.imageCache.setObject(img, forKey: thumbURL as NSURL)
                DispatchQueue.main.async {
                    self?.applyImage(img, to: attachment, maxW: maxW, maxH: maxH)
                }
            }.resume()
        }

        return attr
    }

    private func applyImage(_ img: NSImage, to attachment: NSTextAttachment, maxW: CGFloat, maxH: CGFloat) {
        attachment.image = img
        let size = img.size
        let scale = min(maxW / max(size.width, 1), maxH / max(size.height, 1), 1.0)
        attachment.bounds = CGRect(x: 0, y: -2, width: round(size.width * scale), height: round(size.height * scale))
        textView.needsDisplay = true
        textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.string.count), actualCharacterRange: nil)
    }
}
