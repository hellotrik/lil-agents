import Foundation

/// `agent --mode` values (default is full agent with edits).
enum CursorCLIMode: String, Codable {
    case agent
    case plan
    case ask
}

/// Persisted `--sandbox` override for Cursor CLI.
enum CursorCLISandbox: String, Codable {
    case `default`
    case enabled
    case disabled
}

/// Drives the Cursor CLI (`agent`) in `--print` mode with `stream-json` output.
/// Uses `--resume` with a persisted `session_id` for follow-up turns.
final class CursorAgentSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var emittedAssistantPrefix = ""
    /// Cursor CLI chat id from `stream-json` (`system`/`result`); non-nil ⇒ next `send` uses `--resume`.
    private var remoteSessionId: String?
    /// Set to `WalkerCharacter.videoName` so each character has a separate persisted Cursor chat.
    var persistenceKey: String = ""
    /// Optional `agent --model` override (nil = CLI default).
    private(set) var cursorModel: String?
    private(set) var cursorMode: CursorCLIMode = .agent
    private(set) var cursorSandbox: CursorCLISandbox = .default
    private(set) var isRunning = false
    private(set) var isBusy = false
    private static var binaryPath: String?

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?

    var history: [AgentMessage] = []

    func start() {
        if let cached = Self.binaryPath {
            isRunning = true
            loadPersistedState()
            onSessionReady?()
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        ShellEnvironment.findBinary(name: "agent", fallbackPaths: [
            "\(home)/.local/bin/agent",
            "\(home)/.npm-global/bin/agent",
            "/usr/local/bin/agent",
            "/opt/homebrew/bin/agent"
        ]) { [weak self] path in
            guard let self = self else { return }
            if let binaryPath = path {
                Self.binaryPath = binaryPath
                self.loadPersistedState()
                self.isRunning = true
                self.onSessionReady?()
            } else {
                let msg = "Cursor CLI (agent) not found.\n\n\(AgentProvider.cursor.installInstructions)"
                self.onError?(msg)
                self.history.append(AgentMessage(role: .error, text: msg))
            }
        }
    }

    func send(message: String) {
        guard isRunning, let binaryPath = Self.binaryPath else { return }
        isBusy = true
        history.append(AgentMessage(role: .user, text: message))
        lineBuffer = ""
        emittedAssistantPrefix = ""

        let useResume = remoteSessionId != nil
        let prompt: String
        if useResume {
            prompt = message
        } else {
            prompt = Self.execPrompt(priorMessages: history.dropLast(), latestUserMessage: message)
        }

        var args: [String] = [
            "--print",
            "--output-format", "stream-json",
            "--trust",
            "--yolo",
            "--workspace", FileManager.default.homeDirectoryForCurrentUser.path
        ]
        if let m = cursorModel, !m.isEmpty {
            args.append("--model")
            args.append(m)
        }
        switch cursorMode {
        case .agent:
            break
        case .plan:
            args.append("--plan")
        case .ask:
            args.append("--mode")
            args.append("ask")
        }
        switch cursorSandbox {
        case .default:
            break
        case .enabled:
            args.append("--sandbox")
            args.append("enabled")
        case .disabled:
            args.append("--sandbox")
            args.append("disabled")
        }
        if useResume, let sid = remoteSessionId {
            args.append("--resume")
            args.append(sid)
        }
        args.append(prompt)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args

        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path
        ])

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.process = nil
                if !self.lineBuffer.isEmpty {
                    self.processOutput(self.lineBuffer)
                    self.lineBuffer = ""
                }
                if self.isBusy {
                    self.isBusy = false
                    self.onTurnComplete?()
                }
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let noise = trimmed.hasPrefix("◆") || trimmed.hasPrefix("→") || trimmed.isEmpty
                if !noise {
                    DispatchQueue.main.async {
                        self?.onError?(text)
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
            persistStateIfNeeded()
        } catch {
            isBusy = false
            let msg = "Failed to launch Cursor CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        persistStateIfNeeded()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
        remoteSessionId = nil
    }

    /// Clears the Cursor CLI session id so the next turn starts a new remote chat (e.g. after `/clear`).
    func clearRemoteSession() {
        remoteSessionId = nil
        clearPersistedState()
    }

    private func defaultsBaseKey() -> String? {
        guard !persistenceKey.isEmpty else { return nil }
        return "LilAgents.cursor.\(persistenceKey)"
    }

    private func loadPersistedState() {
        guard let base = defaultsBaseKey() else { return }
        let d = UserDefaults.standard
        if let sid = d.string(forKey: "\(base).remoteSessionId"), !sid.isEmpty {
            remoteSessionId = sid
        }
        if let data = d.data(forKey: "\(base).history"),
           let msgs = try? JSONDecoder().decode([AgentMessage].self, from: data) {
            history = msgs
        }
        if let m = d.string(forKey: "\(base).cursorModel"), !m.isEmpty {
            cursorModel = m
        }
        if let raw = d.string(forKey: "\(base).cursorMode"),
           let mode = CursorCLIMode(rawValue: raw) {
            cursorMode = mode
        }
        if let raw = d.string(forKey: "\(base).cursorSandbox"),
           let sb = CursorCLISandbox(rawValue: raw) {
            cursorSandbox = sb
        }
    }

    private func persistStateIfNeeded() {
        guard let base = defaultsBaseKey() else { return }
        let d = UserDefaults.standard
        if let sid = remoteSessionId, !sid.isEmpty {
            d.set(sid, forKey: "\(base).remoteSessionId")
        } else {
            d.removeObject(forKey: "\(base).remoteSessionId")
        }
        if let data = try? JSONEncoder().encode(history) {
            d.set(data, forKey: "\(base).history")
        }
        if let m = cursorModel, !m.isEmpty {
            d.set(m, forKey: "\(base).cursorModel")
        } else {
            d.removeObject(forKey: "\(base).cursorModel")
        }
        d.set(cursorMode.rawValue, forKey: "\(base).cursorMode")
        d.set(cursorSandbox.rawValue, forKey: "\(base).cursorSandbox")
    }

    private func clearPersistedState() {
        guard let base = defaultsBaseKey() else { return }
        let d = UserDefaults.standard
        d.removeObject(forKey: "\(base).remoteSessionId")
        d.removeObject(forKey: "\(base).history")
    }

    // MARK: - Slash commands (Cursor only)

    /// Runs `agent --list-models` synchronously (call off main thread from UI).
    func runListModels() -> String {
        guard let binaryPath = Self.binaryPath else {
            return "Cursor CLI (agent) not found."
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--list-models"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ShellEnvironment.processEnvironment(extraPaths: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/bin").path
        ])
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return "Failed to run agent --list-models: \(error.localizedDescription)"
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? "(no output)" : combined
    }

    func handleSlashModel(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Current model: \(cursorModel ?? "(CLI default)")"
        }
        let low = trimmed.lowercased()
        if low == "clear" || low == "default" {
            cursorModel = nil
            persistStateIfNeeded()
            return "Model cleared — using CLI default."
        }
        cursorModel = trimmed
        persistStateIfNeeded()
        return "Model set to: \(trimmed)"
    }

    func handleSlashMode(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Current mode: \(cursorMode.rawValue) (agent = edits, plan = read-only plan, ask = Q&A)"
        }
        let low = trimmed.lowercased()
        if low == "default" {
            cursorMode = .agent
            persistStateIfNeeded()
            return "Mode set to: agent (default)"
        }
        guard let mode = CursorCLIMode(rawValue: low) else {
            return "Unknown mode. Use: agent | plan | ask | default"
        }
        cursorMode = mode
        persistStateIfNeeded()
        return "Mode set to: \(mode.rawValue)"
    }

    func handleSlashSandbox(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Current sandbox: \(cursorSandbox.rawValue)"
        }
        let low = trimmed.lowercased()
        let next: CursorCLISandbox
        switch low {
        case "on", "enabled", "true", "yes":
            next = .enabled
        case "off", "disabled", "false", "no":
            next = .disabled
        case "default", "clear":
            next = .default
        default:
            return "Unknown value. Use: on | off | default"
        }
        cursorSandbox = next
        persistStateIfNeeded()
        return "Sandbox set to: \(next.rawValue)"
    }

    private static func execPrompt(priorMessages: ArraySlice<AgentMessage>, latestUserMessage: String) -> String {
        guard !priorMessages.isEmpty else { return latestUserMessage }
        var parts: [String] = []
        for m in priorMessages {
            switch m.role {
            case .user:
                parts.append("User: \(m.text)")
            case .assistant:
                parts.append("Assistant: \(m.text)")
            case .toolUse:
                parts.append("Tool: \(m.text)")
            case .toolResult:
                parts.append("Tool result: \(m.text)")
            case .error:
                parts.append("Error: \(m.text)")
            }
        }
        return """
        Conversation so far (for context; respond only to the follow-up):

        \(parts.joined(separator: "\n\n"))

        ---

        User (follow-up): \(latestUserMessage)
        """
    }

    private func processOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseLine(line)
            }
        }
    }

    private func captureSessionIdIfPresent(_ json: [String: Any]) {
        if let sid = json["session_id"] as? String, !sid.isEmpty {
            remoteSessionId = sid
            persistStateIfNeeded()
        }
    }

    private func parseLine(_ line: String) {
        DebugConsole.shared.append("Cursor <<raw>> \(line)")
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let kind = json["type"] as? String ?? ""

        switch kind {
        case "assistant":
            captureSessionIdIfPresent(json)
            if let full = Self.extractAssistantText(from: json) {
                emitAssistantDelta(full)
            }
        case "result":
            captureSessionIdIfPresent(json)
            let failed = (json["is_error"] as? Bool) == true
            if failed {
                let msg = (json["result"] as? String) ?? "Request failed"
                onError?(msg)
                history.append(AgentMessage(role: .error, text: msg))
                persistStateIfNeeded()
            } else {
                if emittedAssistantPrefix.isEmpty,
                   let r = json["result"] as? String,
                   !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onText?(r)
                    emittedAssistantPrefix = r
                }
                if !emittedAssistantPrefix.isEmpty {
                    history.append(AgentMessage(role: .assistant, text: emittedAssistantPrefix))
                }
                persistStateIfNeeded()
            }
            isBusy = false
            onTurnComplete?()
        case "system":
            captureSessionIdIfPresent(json)
        case "thinking", "user":
            break
        case "error":
            captureSessionIdIfPresent(json)
            let msg = json["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
            persistStateIfNeeded()
        default:
            break
        }
    }

    private func emitAssistantDelta(_ full: String) {
        if full == emittedAssistantPrefix { return }
        let trimNew = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimPrev = emittedAssistantPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimNew.isEmpty && trimNew == trimPrev { return }

        if full.hasPrefix(emittedAssistantPrefix) {
            let suffix = String(full.dropFirst(emittedAssistantPrefix.count))
            if !suffix.isEmpty {
                onText?(suffix)
            }
            emittedAssistantPrefix = full
            return
        }
        if !emittedAssistantPrefix.isEmpty, emittedAssistantPrefix.hasPrefix(full) {
            return
        }
        onText?(full)
        emittedAssistantPrefix = full
    }

    private static func extractAssistantText(from json: [String: Any]) -> String? {
        guard let msg = json["message"] as? [String: Any] else { return nil }
        guard let content = msg["content"] as? [[String: Any]] else { return nil }
        var combined = ""
        for item in content {
            if item["type"] as? String == "text", let t = item["text"] as? String {
                combined += t
            }
        }
        return combined.isEmpty ? nil : combined
    }
}
