import AppKit

enum DockOrientation {
    case bottom
    case left
    case right
    case top
    case unknown
}

class LilAgentsController {
    var characters: [WalkerCharacter] = []
    private var displayLink: CVDisplayLink?
    var debugWindow: NSWindow?
    var pinnedScreenIndex: Int = -1
    private static let onboardingKey = "hasCompletedOnboarding"
    private var isHiddenForEnvironment = false

    func start() {
        let char1 = WalkerCharacter(videoName: "walk-bruce-01")
        char1.accelStart = 3.0
        char1.fullSpeedStart = 3.75
        char1.decelStart = 8.0
        char1.walkStop = 8.5
        char1.walkAmountRange = 0.4...0.65

        let char2 = WalkerCharacter(videoName: "walk-jazz-01")
        char2.accelStart = 3.9
        char2.fullSpeedStart = 4.5
        char2.decelStart = 8.0
        char2.walkStop = 8.75
        char2.walkAmountRange = 0.35...0.6
        char1.yOffset = -3
        char2.yOffset = -7
        char1.characterColor = NSColor(red: 0.4, green: 0.72, blue: 0.55, alpha: 1.0)
        char2.characterColor = NSColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1.0)

        char1.flipXOffset = 0
        char2.flipXOffset = -9

        char1.positionProgress = 0.3
        char2.positionProgress = 0.7

        char1.pauseEndTime = CACurrentMediaTime() + Double.random(in: 0.5...2.0)
        char2.pauseEndTime = CACurrentMediaTime() + Double.random(in: 8.0...14.0)

        char1.setup()
        char2.setup()

        characters = [char1, char2]
        characters.forEach { $0.controller = self }

        setupDebugLine()
        startDisplayLink()

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }
    }

    private func triggerOnboarding() {
        guard let bruce = characters.first else { return }
        bruce.isOnboarding = true
        // Show "hi!" bubble after a short delay so the character is visible first
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let hi = AppLanguage.current.onboardingHi
            bruce.currentPhrase = hi
            bruce.showingCompletion = true
            bruce.completionBubbleExpiry = CACurrentMediaTime() + 600 // stays until clicked
            bruce.showBubble(text: hi, isCompletion: true)
            bruce.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        characters.forEach { $0.isOnboarding = false }
    }

    func applyLanguageChange() {
        characters.forEach { $0.applyLanguageChange() }
    }

    // MARK: - Debug

    private func setupDebugLine() {
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 2),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.red
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        win.orderOut(nil)
        debugWindow = win
    }

    private func updateDebugLine(orientation: DockOrientation, travelStart: CGFloat, travelLength: CGFloat, fixedEdge: CGFloat) {
        guard let win = debugWindow, win.isVisible else { return }
        switch orientation {
        case .bottom, .top:
            win.setFrame(CGRect(x: travelStart, y: fixedEdge, width: travelLength, height: 2), display: true)
        case .left, .right:
            win.setFrame(CGRect(x: fixedEdge, y: travelStart, width: 2, height: travelLength), display: true)
        case .unknown:
            break
        }
    }

    // MARK: - Dock Geometry

    private func dockOrientation() -> DockOrientation {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        guard let raw = dockDefaults?.object(forKey: "orientation") else { return .bottom }

        // com.apple.dock usually stores it as a string: "bottom" | "left" | "right" | "top"
        if let s = raw as? String {
            switch s.lowercased() {
            case "bottom": return .bottom
            case "left": return .left
            case "right": return .right
            case "top": return .top
            default: return .unknown
            }
        }

        // Fallback: try number mapping if format differs across versions.
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

    private func dockIconTravelLength() -> CGFloat {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = CGFloat(dockDefaults?.double(forKey: "tilesize") ?? 48)
        // Each dock slot is the icon + padding. The padding scales with tile size.
        // At default 48pt: slot ≈ 58pt. At 37pt: slot ≈ 47pt. Roughly tileSize * 1.25.
        let slotLength = tileSize * 1.25

        let persistentApps = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        let persistentOthers = dockDefaults?.array(forKey: "persistent-others")?.count ?? 0

        // Only count recent apps if show-recents is enabled
        let showRecents = dockDefaults?.bool(forKey: "show-recents") ?? true
        let recentApps = showRecents ? (dockDefaults?.array(forKey: "recent-apps")?.count ?? 0) : 0
        let totalIcons = persistentApps + persistentOthers + recentApps

        var dividers = 0
        if persistentApps > 0 && (persistentOthers > 0 || recentApps > 0) { dividers += 1 }
        if persistentOthers > 0 && recentApps > 0 { dividers += 1 }
        // show-recents adds its own divider
        if showRecents && recentApps > 0 { dividers += 1 }

        let dividerLength: CGFloat = 12.0
        var dockLength = slotLength * CGFloat(totalIcons) + CGFloat(dividers) * dividerLength

        let magnificationEnabled = dockDefaults?.bool(forKey: "magnification") ?? false
        if magnificationEnabled, dockDefaults?.object(forKey: "largesize") != nil {
            // Magnification only affects the hovered area; at rest the dock is normal size.
            // Don't inflate the travel length — characters should stay within the at-rest bounds.
        }

        // Small fudge factor for dock edge padding
        dockLength *= 1.1
        return dockLength
    }

    private func dockAutohideEnabled() -> Bool {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        return dockDefaults?.bool(forKey: "autohide") ?? false
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let controller = Unmanaged<LilAgentsController>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    var activeScreen: NSScreen? {
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[pinnedScreenIndex]
        }
        return NSScreen.main
    }

    private func screenHasDock(_ screen: NSScreen, dockOrientation: DockOrientation) -> Bool {
        let f = screen.frame
        let vf = screen.visibleFrame
        let eps: CGFloat = 0.5

        switch dockOrientation {
        case .bottom:
            // visibleFrame.origin.y lifts above the dock.
            return vf.origin.y > f.origin.y + eps
        case .left:
            return vf.origin.x > f.origin.x + eps
        case .right:
            return vf.maxX < f.maxX - eps
        case .top:
            // visibleFrame.maxY is reduced by both menu bar and dock (if present).
            let menuBarThickness = NSStatusBar.system.thickness
            if menuBarThickness <= 0.5 {
                return vf.maxY < f.maxY - eps
            }
            return vf.maxY < f.maxY - menuBarThickness - 1.0
        case .unknown:
            // Conservative fallback: only detect bottom/side docks we can infer safely.
            return (vf.origin.y > f.origin.y + eps)
                || (vf.origin.x > f.origin.x + eps)
                || (vf.maxX < f.maxX - eps)
        }
    }

    private func shouldShowCharacters(on screen: NSScreen) -> Bool {
        let orientation = dockOrientation()
        if screenHasDock(screen, dockOrientation: orientation) {
            return true
        }

        // With dock auto-hide enabled on the active desktop, the dock can still be
        // present even though visibleFrame starts at the screen origin. In fullscreen
        // spaces, both the dock and menu bar are absent, so visibleFrame matches frame.
        let menuBarVisible = screen.visibleFrame.maxY < screen.frame.maxY
        return dockAutohideEnabled() && screen == NSScreen.main && menuBarVisible
    }

    @discardableResult
    private func updateEnvironmentVisibility(for screen: NSScreen) -> Bool {
        let shouldShow = shouldShowCharacters(on: screen)
        guard shouldShow != !isHiddenForEnvironment else { return shouldShow }

        isHiddenForEnvironment = !shouldShow

        if shouldShow {
            characters.forEach { $0.showForEnvironmentIfNeeded() }
        } else {
            debugWindow?.orderOut(nil)
            characters.forEach { $0.hideForEnvironment() }
        }

        return shouldShow
    }

    func tick() {
        guard let screen = activeScreen else { return }
        guard updateEnvironmentVisibility(for: screen) else { return }

        let orientation = dockOrientation()
        let travelLength = dockIconTravelLength()

        // Dock is on this screen — constrain to dock area
        let frame = screen.frame
        let visible = screen.visibleFrame

        let travelStart: CGFloat
        let fixedEdge: CGFloat
        switch orientation {
        case .bottom:
            travelStart = frame.minX + (frame.width - travelLength) / 2.0
            fixedEdge = visible.origin.y
        case .top:
            travelStart = frame.minX + (frame.width - travelLength) / 2.0
            fixedEdge = visible.maxY
        case .left:
            travelStart = frame.minY + (frame.height - travelLength) / 2.0
            fixedEdge = visible.origin.x
        case .right:
            travelStart = frame.minY + (frame.height - travelLength) / 2.0
            fixedEdge = visible.maxX
        case .unknown:
            // Fall back to the historical bottom-dock behavior.
            travelStart = frame.minX + (frame.width - travelLength) / 2.0
            fixedEdge = visible.origin.y
        }

        updateDebugLine(orientation: orientation, travelStart: travelStart, travelLength: travelLength, fixedEdge: fixedEdge)

        let activeChars = characters.filter { $0.window.isVisible && $0.isManuallyVisible }

        let now = CACurrentMediaTime()
        let anyWalking = activeChars.contains { $0.isWalking }
        for char in activeChars {
            if char.isIdleForPopover { continue }
            if char.isPaused && now >= char.pauseEndTime && anyWalking {
                char.pauseEndTime = now + Double.random(in: 5.0...10.0)
            }
        }
        for char in activeChars {
            char.update(dockOrientation: orientation, travelStart: travelStart, travelLength: travelLength, fixedEdge: fixedEdge)
        }

        let sorted = activeChars.sorted { $0.positionProgress < $1.positionProgress }
        for (i, char) in sorted.enumerated() {
            char.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + i)
        }
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
