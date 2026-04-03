import AVFoundation
import AppKit

class WalkerCharacter {
    let videoName: String
    var window: NSWindow!
    var playerLayer: AVPlayerLayer!
    var queuePlayer: AVQueuePlayer!
    var looper: AVPlayerLooper!

    let videoWidth: CGFloat = 1080
    let videoHeight: CGFloat = 1920
    let displayHeight: CGFloat = 200
    var displayWidth: CGFloat { displayHeight * (videoWidth / videoHeight) }

    // Walk timing (per-character, from frame analysis)
    let videoDuration: CFTimeInterval = 10.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var walkAmountRange: ClosedRange<CGFloat> = 0.25...0.5
    var yOffset: CGFloat = 0
    var flipXOffset: CGFloat = 0
    var characterColor: NSColor = .gray

    // Walk state
    var playCount = 0
    var walkStartTime: CFTimeInterval = 0
    var positionProgress: CGFloat = 0.0
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartPos: CGFloat = 0.0
    var walkEndPos: CGFloat = 0.0
    var currentTravelDistance: CGFloat = 500.0
    // Walk endpoints stored in pixels for consistent speed across screen switches
    var walkStartPixel: CGFloat = 0.0
    var walkEndPixel: CGFloat = 0.0

    // Onboarding
    var isOnboarding = false

    // Popover state
    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?
    var session: (any AgentSession)?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    var currentStreamingText = ""
    weak var controller: LilAgentsController?
    var themeOverride: PopoverTheme?
    var isAgentBusy: Bool { session?.isBusy ?? false }
    var thinkingBubbleWindow: NSWindow?
    private(set) var isManuallyVisible = true
    /// Screen-space offset from automatic dock position (user drag).
    var userDragOffsetX: CGFloat = 0
    var userDragOffsetY: CGFloat = 0
    private var environmentHiddenAt: CFTimeInterval?
    private var wasPopoverVisibleBeforeEnvironmentHide = false
    private var wasBubbleVisibleBeforeEnvironmentHide = false

    init(videoName: String) {
        self.videoName = videoName
    }

    // MARK: - Setup

    func setup() {
        guard let videoURL = Bundle.main.url(forResource: videoName, withExtension: "mov") else {
            print("Video \(videoName) not found")
            return
        }

        let asset = AVAsset(url: videoURL)
        queuePlayer = AVQueuePlayer()
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(asset: asset))

        playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        // Initial placement is best-effort; final placement will be updated every tick
        // based on Dock orientation and geometry from `LilAgentsController`.
        let screen = NSScreen.main!
        let orientation = currentDockOrientation()
        let overlapY = displayHeight * 0.15
        let overlapX = displayWidth * 0.15

        let initialYCenter = screen.frame.minY + (screen.frame.height - displayHeight) / 2.0
        let initialXCenter = screen.frame.minX + (screen.frame.width - displayWidth) / 2.0

        let y: CGFloat
        let x: CGFloat
        switch orientation {
        case .bottom:
            y = screen.visibleFrame.origin.y - overlapY + yOffset
            x = initialXCenter
        case .top:
            y = screen.visibleFrame.maxY - displayHeight + overlapY + yOffset
            x = initialXCenter
        case .left:
            y = initialYCenter + yOffset
            x = screen.visibleFrame.origin.x - overlapX
        case .right:
            y = initialYCenter + yOffset
            x = screen.visibleFrame.maxX - displayWidth + overlapX
        case .unknown:
            y = screen.visibleFrame.origin.y - overlapY + yOffset
            x = initialXCenter
        }

        let contentRect = CGRect(x: x, y: y, width: displayWidth, height: displayHeight)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.moveToActiveSpace, .stationary]

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.addSublayer(playerLayer)

        window.contentView = hostView
        if Self.loadPersistedVisibility(videoName: videoName) {
            window.orderFrontRegardless()
        } else {
            setManuallyVisible(false)
        }
    }

    /// UserDefaults key for menu "Bruce/Jazz" visibility (per character video asset).
    private static func characterVisibilityDefaultsKey(videoName: String) -> String {
        "LilAgents.characterVisible.\(videoName)"
    }

    /// Default visible when the key is absent (first launch).
    private static func loadPersistedVisibility(videoName: String) -> Bool {
        let key = characterVisibilityDefaultsKey(videoName: videoName)
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func persistVisibility(videoName: String, visible: Bool) {
        UserDefaults.standard.set(visible, forKey: characterVisibilityDefaultsKey(videoName: videoName))
    }

    // MARK: - Visibility

    func setManuallyVisible(_ visible: Bool) {
        isManuallyVisible = visible
        if visible {
            if environmentHiddenAt == nil {
                window.orderFrontRegardless()
            }
        } else {
            queuePlayer.pause()
            window.orderOut(nil)
            popoverWindow?.orderOut(nil)
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    func hideForEnvironment() {
        guard environmentHiddenAt == nil else { return }

        environmentHiddenAt = CACurrentMediaTime()
        wasPopoverVisibleBeforeEnvironmentHide = popoverWindow?.isVisible ?? false
        wasBubbleVisibleBeforeEnvironmentHide = thinkingBubbleWindow?.isVisible ?? false

        queuePlayer.pause()
        window.orderOut(nil)
        popoverWindow?.orderOut(nil)
        thinkingBubbleWindow?.orderOut(nil)
    }

    func showForEnvironmentIfNeeded() {
        guard let hiddenAt = environmentHiddenAt else { return }

        let hiddenDuration = CACurrentMediaTime() - hiddenAt
        environmentHiddenAt = nil
        walkStartTime += hiddenDuration
        pauseEndTime += hiddenDuration
        completionBubbleExpiry += hiddenDuration
        lastPhraseUpdate += hiddenDuration

        guard isManuallyVisible else { return }

        window.orderFrontRegardless()
        if isWalking {
            queuePlayer.play()
        }

        if isIdleForPopover && wasPopoverVisibleBeforeEnvironmentHide {
            updatePopoverPosition()
            popoverWindow?.orderFrontRegardless()
            popoverWindow?.makeKey()
            if let terminal = terminalView {
                popoverWindow?.makeFirstResponder(terminal.inputField)
            }
        }

        if wasBubbleVisibleBeforeEnvironmentHide {
            updateThinkingBubble()
        }
    }

    // MARK: - Click Handling & Popover

    func handleClick() {
        if isOnboarding {
            openOnboardingPopover()
            return
        }
        if isIdleForPopover {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openOnboardingPopover() {
        showingCompletion = false
        hideBubble()

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        queuePlayer.pause()
        queuePlayer.seek(to: .zero)

        if popoverWindow == nil {
            createPopoverWindow()
        }

        // Show static welcome message instead of Claude terminal
        terminalView?.inputField.isEditable = false
        terminalView?.inputField.placeholderString = ""
        let welcome = AppLanguage.current.onboardingWelcome
        terminalView?.appendStreamingText(welcome)
        terminalView?.endStreaming()

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()

        // Set up click-outside to dismiss and complete onboarding
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closeOnboarding()
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeOnboarding(); return nil }
            return event
        }
    }

    private func closeOnboarding() {
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        isIdleForPopover = false
        isOnboarding = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 1.0...3.0)
        queuePlayer.seek(to: .zero)
        controller?.completeOnboarding()
    }

    func openPopover() {
        // Close any other open popover
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self && sibling.isIdleForPopover {
                sibling.closePopover()
            }
        }

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        queuePlayer.pause()
        queuePlayer.seek(to: .zero)

        // Always clear any bubble (thinking or completion) when popover opens
        showingCompletion = false
        hideBubble()

        if session == nil {
            let newSession = AgentProvider.current.createSession()
            if let cursor = newSession as? CursorAgentSession {
                cursor.persistenceKey = videoName
            }
            session = newSession
            wireSession(newSession)
            newSession.start()
        }

        if popoverWindow == nil {
            createPopoverWindow()
        }

        if let terminal = terminalView, let session = session, !session.history.isEmpty {
            terminal.replayHistory(session.history)
        }

        updatePopoverPosition()
        popoverWindow?.orderFrontRegardless()
        popoverWindow?.makeKey()

        if let terminal = terminalView {
            popoverWindow?.makeFirstResponder(terminal.inputField)
            terminal.cursorAgentSession = session as? CursorAgentSession
        }

        // Remove old monitors before adding new ones
        removeEventMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.popoverWindow else { return }
            let popoverFrame = popover.frame
            let charFrame = self.window.frame
            if !popoverFrame.contains(NSEvent.mouseLocation) && !charFrame.contains(NSEvent.mouseLocation) {
                self.closePopover()
            }
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    func closePopover() {
        guard isIdleForPopover else { return }

        popoverWindow?.orderOut(nil)
        removeEventMonitors()

        isIdleForPopover = false

        // If still waiting for a response, show thinking bubble immediately
        // If completion came while popover was open, show completion bubble
        if showingCompletion {
            // Reset expiry so user gets the full 3s from now
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            // Force a fresh phrase pick and show immediately
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 2.0...5.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    var resolvedTheme: PopoverTheme {
        (themeOverride ?? PopoverTheme.current).withCharacterColor(characterColor).withCustomFont()
    }

    func createPopoverWindow() {
        let t = resolvedTheme
        let popoverWidth: CGFloat = 420
        let popoverHeight: CGFloat = 310

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        win.minSize = NSSize(width: 320, height: 240)
        win.maxSize = NSSize(width: 1400, height: 1000)
        win.setFrameAutosaveName("lilagents-terminal")
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = PopoverChromeView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBar = NSView(frame: NSRect(x: 0, y: popoverHeight - 28, width: popoverWidth, height: 28))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        container.addSubview(titleBar)

        let titleLabel = NSTextField(labelWithString: t.titleString)
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.frame = NSRect(x: 12, y: 6, width: popoverWidth - 100, height: 16)
        titleBar.addSubview(titleLabel)

        let minusBtn = NSButton(frame: NSRect(x: popoverWidth - 76, y: 5, width: 22, height: 16))
        minusBtn.tag = 12
        minusBtn.title = "A−"
        minusBtn.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        minusBtn.bezelStyle = .inline
        minusBtn.isBordered = false
        minusBtn.contentTintColor = t.titleText.withAlphaComponent(0.85)
        minusBtn.toolTip = "Smaller text"
        minusBtn.target = self
        minusBtn.action = #selector(adjustTerminalFontSize(_:))
        titleBar.addSubview(minusBtn)

        let plusBtn = NSButton(frame: NSRect(x: popoverWidth - 52, y: 5, width: 22, height: 16))
        plusBtn.tag = 13
        plusBtn.title = "A+"
        plusBtn.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        plusBtn.bezelStyle = .inline
        plusBtn.isBordered = false
        plusBtn.contentTintColor = t.titleText.withAlphaComponent(0.85)
        plusBtn.toolTip = "Larger text"
        plusBtn.target = self
        plusBtn.action = #selector(adjustTerminalFontSize(_:))
        titleBar.addSubview(plusBtn)

        let copyBtn = NSButton(frame: NSRect(x: popoverWidth - 28, y: 5, width: 16, height: 16))
        copyBtn.tag = 11
        copyBtn.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        copyBtn.target = self
        copyBtn.action = #selector(copyLastResponseFromButton)
        titleBar.addSubview(copyBtn)

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - 29, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        container.addSubview(sep)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - 29))
        terminal.characterColor = characterColor
        terminal.themeOverride = themeOverride
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self] message in
            let provider = AgentProvider.current.displayName
            DebugConsole.shared.append("\(provider) >> \(message)")
            self?.session?.send(message: message)
        }
        terminal.onClearRequested = { [weak self] in
            self?.session?.history.removeAll()
            (self?.session as? CursorAgentSession)?.clearRemoteSession()
            DebugConsole.shared.append("UI >> /clear")
        }
        container.addSubview(terminal)

        container.titleBarView = titleBar
        container.separatorView = sep
        container.terminalViewRef = terminal
        container.titleLabelField = titleLabel
        container.fontMinusButton = minusBtn
        container.fontPlusButton = plusBtn
        container.copyButton = copyBtn

        win.contentView = container
        popoverWindow = win
        terminalView = terminal
    }

    @objc func adjustTerminalFontSize(_ sender: NSButton) {
        let delta: CGFloat = sender.tag == 12 ? -1 : 1
        PopoverTheme.customFontSize = PopoverTheme.customFontSize + delta
        terminalView?.refreshFontsFromTheme()
    }

    private func wireSession(_ session: any AgentSession, providerName: String = AgentProvider.current.displayName) {
        session.onText = { [weak self] text in
            self?.currentStreamingText += text
            self?.terminalView?.appendStreamingText(text)
            DebugConsole.shared.append("\(providerName) <<delta>> \(text)")
        }

        session.onTurnComplete = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.playCompletionSound()
            self?.showCompletionBubble()
            if let full = self?.currentStreamingText, !full.isEmpty {
                DebugConsole.shared.append("\(providerName) << \(full)")
            }
            self?.currentStreamingText = ""
        }

        session.onError = { [weak self] text in
            self?.terminalView?.appendError(text)
            DebugConsole.shared.append("\(providerName) <<error>> \(text)")
        }

        session.onToolUse = { [weak self] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            self.terminalView?.appendToolUse(toolName: toolName, summary: summary)
            DebugConsole.shared.append("\(providerName) <<tool>> \(toolName) \(summary)")
        }

        session.onToolResult = { [weak self] summary, isError in
            self?.terminalView?.appendToolResult(summary: summary, isError: isError)
            DebugConsole.shared.append("\(providerName) <<toolResult>> \(isError ? "ERROR" : "OK") \(summary)")
        }

        session.onProcessExit = { [weak self] in
            self?.terminalView?.endStreaming()
            self?.terminalView?.appendError("\(providerName) session ended.")
            DebugConsole.shared.append("\(providerName) <<exit>> session ended")
        }
    }

    @objc func copyLastResponseFromButton() {
        // Trigger the /copy slash command via the terminal view
        terminalView?.handleSlashCommandPublic("/copy")
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let pattern = input["pattern"] as? String { return pattern }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        guard let screen = NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        let y = charFrame.maxY - 15

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    // MARK: - Thinking Bubble

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26
    private var phraseAnimating = false

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            if isIdleForPopover {
                completionBubbleExpiry += 1.0 / 60.0
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase && !oldPhrase.isEmpty && !phraseAnimating {
                animatePhraseChange(to: currentPhrase, isCompletion: false)
            } else if !phraseAnimating {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false {
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    private func animatePhraseChange(to newText: String, isCompletion: Bool) {
        guard let win = thinkingBubbleWindow, win.isVisible,
              let label = win.contentView?.viewWithTag(100) as? NSTextField else {
            showBubble(text: newText, isCompletion: isCompletion)
            return
        }
        phraseAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            label.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.showBubble(text: newText, isCompletion: isCompletion)
            label.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                label.animator().alphaValue = 1.0
            }, completionHandler: {
                self?.phraseAnimating = false
            })
        })
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil {
            createThinkingBubble()
        }

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        let x = charFrame.midX - bubbleW / 2
        let y = charFrame.origin.y + charFrame.height * 0.88
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        let lang = AppLanguage.current
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            currentPhrase = lang.randomThinkingPhrase(excluding: currentPhrase)
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = AppLanguage.current.randomCompletionPhrase()
        showingCompletion = true
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        phraseAnimating = false
        if !isIdleForPopover {
            showBubble(text: currentPhrase, isCompletion: true)
        }
    }

    /// 菜单中切换界面语言后，刷新气泡与引导弹窗文案。
    func applyLanguageChange() {
        refreshLocalizedBubbleTexts()
        refreshOnboardingWelcomeIfNeeded()
    }

    private func refreshOnboardingWelcomeIfNeeded() {
        guard isOnboarding, isIdleForPopover, terminalView != nil else { return }
        terminalView?.setOnboardingWelcomeText(AppLanguage.current.onboardingWelcome)
    }

    private func refreshLocalizedBubbleTexts() {
        let lang = AppLanguage.current
        if showingCompletion {
            if isOnboarding {
                currentPhrase = lang.onboardingHi
                showBubble(text: currentPhrase, isCompletion: true)
            } else if !isIdleForPopover {
                currentPhrase = lang.randomCompletionPhrase()
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }
        if isAgentBusy && !isIdleForPopover {
            currentPhrase = lang.randomThinkingPhrase(excluding: currentPhrase)
            lastPhraseUpdate = CACurrentMediaTime()
            showBubble(text: currentPhrase, isCompletion: false)
        }
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true

    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx

        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Walking

    func startWalk() {
        isPaused = false
        isWalking = true
        playCount = 0
        walkStartTime = CACurrentMediaTime()

        if positionProgress > 0.85 {
            goingRight = false
        } else if positionProgress < 0.15 {
            goingRight = true
        } else {
            goingRight = Bool.random()
        }

        walkStartPos = positionProgress
        // Walk a fixed pixel distance (~200-325px) regardless of screen width.
        let referenceWidth: CGFloat = 500.0
        let walkPixels = CGFloat.random(in: walkAmountRange) * referenceWidth
        let walkAmount = currentTravelDistance > 0 ? walkPixels / currentTravelDistance : 0.3
        if goingRight {
            walkEndPos = min(walkStartPos + walkAmount, 1.0)
        } else {
            walkEndPos = max(walkStartPos - walkAmount, 0.0)
        }
        // Store pixel positions so walk speed stays consistent if screen changes mid-walk
        walkStartPixel = walkStartPos * currentTravelDistance
        walkEndPixel = walkEndPos * currentTravelDistance

        let minSeparation: CGFloat = 0.12
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self {
                let sibPos = sibling.positionProgress
                if abs(walkEndPos - sibPos) < minSeparation {
                    if goingRight {
                        walkEndPos = max(walkStartPos, sibPos - minSeparation)
                    } else {
                        walkEndPos = min(walkStartPos, sibPos + minSeparation)
                    }
                }
            }
        }

        updateFlip()
        queuePlayer.seek(to: .zero)
        queuePlayer.play()
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        queuePlayer.pause()
        queuePlayer.seek(to: .zero)
        let delay = Double.random(in: 5.0...12.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if goingRight {
            playerLayer.transform = CATransform3DIdentity
        } else {
            playerLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        }
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        CATransaction.commit()
    }

    var currentFlipCompensation: CGFloat {
        goingRight ? 0 : flipXOffset
    }

    func movementPosition(at videoTime: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if videoTime <= accelStart {
            return 0.0
        } else if videoTime <= fullSpeedStart {
            let t = videoTime - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if videoTime <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = videoTime - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if videoTime <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = videoTime - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else {
            return 1.0
        }
    }

    // MARK: - Frame Update

    func update(dockOrientation: DockOrientation, travelStart: CGFloat, travelLength: CGFloat, fixedEdge: CGFloat) {
        let overlapY = displayHeight * 0.15
        let overlapX = displayWidth * 0.15

        // Bottom/Top: travel along X; Left/Right: travel along Y.
        switch dockOrientation {
        case .bottom, .top:
            currentTravelDistance = max(travelLength - displayWidth, 0)
        case .left, .right:
            currentTravelDistance = max(travelLength - displayHeight, 0)
        case .unknown:
            currentTravelDistance = max(travelLength - displayWidth, 0)
        }

        func setFrameOriginForProgress(_ progress: CGFloat) {
            let effectiveTravel = currentTravelDistance * progress

            let x: CGFloat
            let y: CGFloat

            switch dockOrientation {
            case .bottom:
                x = travelStart + effectiveTravel + currentFlipCompensation + userDragOffsetX
                y = fixedEdge - overlapY + yOffset + userDragOffsetY
            case .top:
                x = travelStart + effectiveTravel + currentFlipCompensation + userDragOffsetX
                y = fixedEdge - displayHeight + overlapY + yOffset + userDragOffsetY
            case .left:
                y = travelStart + effectiveTravel + yOffset + userDragOffsetY
                x = fixedEdge - overlapX + currentFlipCompensation + userDragOffsetX
            case .right:
                y = travelStart + effectiveTravel + yOffset + userDragOffsetY
                x = fixedEdge - displayWidth + overlapX + currentFlipCompensation + userDragOffsetX
            case .unknown:
                x = travelStart + effectiveTravel + currentFlipCompensation + userDragOffsetX
                y = fixedEdge - overlapY + yOffset + userDragOffsetY
            }

            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        if isIdleForPopover {
            setFrameOriginForProgress(positionProgress)
            updatePopoverPosition()
            updateThinkingBubble()
            return
        }

        let now = CACurrentMediaTime()

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            } else {
                setFrameOriginForProgress(positionProgress)
                return
            }
        }

        if isWalking {
            let elapsed = now - walkStartTime
            let videoTime = min(elapsed, videoDuration)
            let travelDistance = currentTravelDistance

            // Interpolate in pixel space for consistent speed across screen changes.
            let walkNorm = elapsed >= videoDuration ? 1.0 : movementPosition(at: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            // Convert pixel position back to progress for the current screen.
            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            if elapsed >= videoDuration {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            setFrameOriginForProgress(positionProgress)
        }

        updateThinkingBubble()
    }

    private func currentDockOrientation() -> DockOrientation {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        guard let raw = dockDefaults?.object(forKey: "orientation") else { return .bottom }

        if let s = raw as? String {
            switch s.lowercased() {
            case "bottom": return .bottom
            case "left": return .left
            case "right": return .right
            case "top": return .top
            default: return .unknown
            }
        }

        if let i = raw as? Int {
            switch i {
            case 0: return .bottom
            case 1: return .left
            case 2: return .right
            case 3: return .top
            default: return .unknown
            }
        }

        return .bottom
    }
}

private final class PopoverChromeView: NSView {
    weak var titleBarView: NSView?
    weak var separatorView: NSView?
    weak var terminalViewRef: NSView?
    weak var titleLabelField: NSTextField?
    weak var fontMinusButton: NSButton?
    weak var fontPlusButton: NSButton?
    weak var copyButton: NSButton?

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        titleBarView?.frame = NSRect(x: 0, y: h - 28, width: w, height: 28)
        separatorView?.frame = NSRect(x: 0, y: h - 29, width: w, height: 1)
        terminalViewRef?.frame = NSRect(x: 0, y: 0, width: w, height: h - 29)
        guard let titleBar = titleBarView else { return }
        titleLabelField?.frame = NSRect(x: 12, y: 6, width: max(80, w - 100), height: 16)
        fontMinusButton?.frame = NSRect(x: w - 76, y: 5, width: 22, height: 16)
        fontPlusButton?.frame = NSRect(x: w - 52, y: 5, width: 22, height: 16)
        copyButton?.frame = NSRect(x: w - 28, y: 5, width: 16, height: 16)
    }
}
