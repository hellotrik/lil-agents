import Foundation

extension Notification.Name {
    /// 界面语言（菜单、气泡提示、引导文案）已切换。
    static let lilAgentsAppLanguageDidChange = Notification.Name("LilAgents.appLanguageDidChange")
}

/// 应用界面语言（与系统语言独立，仅影响菜单、小人气泡与首次引导文案）。
enum AppLanguage: String, CaseIterable {
    case english
    case chineseSimplified

    private static let userDefaultsKey = "LilAgents.appLanguage"

    static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
                  let v = AppLanguage(rawValue: raw) else { return .english }
            return v
        }
        set {
            guard newValue != readStored() else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
            NotificationCenter.default.post(name: .lilAgentsAppLanguageDidChange, object: nil)
        }
    }

    private static func readStored() -> AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
              let v = AppLanguage(rawValue: raw) else { return .english }
        return v
    }

    var menuTitleLanguage: String {
        switch self {
        case .english: return "Language"
        case .chineseSimplified: return "语言"
        }
    }

    var menuSounds: String {
        switch self {
        case .english: return "Sounds"
        case .chineseSimplified: return "音效"
        }
    }

    var menuProvider: String {
        switch self {
        case .english: return "Provider"
        case .chineseSimplified: return "提供商"
        }
    }

    var menuStyle: String {
        switch self {
        case .english: return "Style"
        case .chineseSimplified: return "样式"
        }
    }

    var menuDisplay: String {
        switch self {
        case .english: return "Display"
        case .chineseSimplified: return "显示器"
        }
    }

    var menuAutoMainDisplay: String {
        switch self {
        case .english: return "Auto (Main Display)"
        case .chineseSimplified: return "自动（主显示器）"
        }
    }

    var menuCheckForUpdates: String {
        switch self {
        case .english: return "Check for Updates…"
        case .chineseSimplified: return "检查更新…"
        }
    }

    var menuQuit: String {
        switch self {
        case .english: return "Quit"
        case .chineseSimplified: return "退出"
        }
    }

    /// 语言子菜单中展示的名称（固定用语，便于识别）。
    var languagePickerLabel: String {
        switch self {
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }

    var onboardingHi: String {
        switch self {
        case .english: return "hi!"
        case .chineseSimplified: return "嗨！"
        }
    }

    var onboardingWelcome: String {
        switch self {
        case .english:
            return """
            hey! we're bruce and jazz — your lil dock agents.

            click either of us to open a Claude AI chat. we'll walk around while you work and let you know when Claude's thinking.

            check the menu bar icon (top right) for themes, sounds, and more options.

            click anywhere outside to dismiss, then click us again to start chatting.
            """
        case .chineseSimplified:
            return """
            嗨！我们是 Bruce 和 Jazz —— 你的桌面小助手。

            点我们任意一个就能打开 Claude AI 聊天。你工作时我们会在旁边走动，并在 Claude 思考时用气泡提醒你。

            右上角菜单栏图标里可以换主题、音效等更多选项。

            点窗口外任意处关闭，再点我们一次即可开始聊天。
            """
        }
    }

    var thinkingPhrases: [String] {
        switch self {
        case .english:
            return [
                "hmm...", "thinking...", "one sec...", "ok hold on",
                "let me check", "working on it", "almost...", "bear with me",
                "on it!", "gimme a sec", "brb", "processing...",
                "hang tight", "just a moment", "figuring it out",
                "crunching...", "reading...", "looking...",
                "cooking...", "vibing...", "digging in",
                "connecting dots", "give me a sec",
                "don't rush me", "calculating...", "assembling\u{2026}"
            ]
        case .chineseSimplified:
            return [
                "嗯…", "在想呢…", "稍等…", "等一下",
                "让我看看", "处理中…", "快了…", "别急",
                "马上", "稍候", "正在想…", "处理中…",
                "等等", "马上好", "正在读…",
                "加载中…", "思考中…", "别急嘛",
                "算一下…", "别催我", "计算中…", "组装中…"
            ]
        }
    }

    var completionPhrases: [String] {
        switch self {
        case .english:
            return [
                "done!", "all set!", "ready!", "here you go", "got it!",
                "finished!", "ta-da!", "voila!",
                "boom!", "there ya go!", "check it out!"
            ]
        case .chineseSimplified:
            return [
                "好了！", "搞定！", "完成！", "给你！", "收到！",
                "完成啦！", "当当！", "瞧！",
                "成了！", "你看！", "来！"
            ]
        }
    }

    func randomThinkingPhrase(excluding: String?) -> String {
        let pool = thinkingPhrases
        guard pool.count > 0 else { return "…" }
        var next = pool.randomElement() ?? "…"
        if let ex = excluding, pool.count > 1 {
            var guardCount = 0
            while next == ex && guardCount < 32 {
                next = pool.randomElement() ?? next
                guardCount += 1
            }
        }
        return next
    }

    func randomCompletionPhrase() -> String {
        completionPhrases.randomElement() ?? "done!"
    }
}
