import Foundation

/// Drives the Cursor CLI (`agent`) in `--print` mode with `stream-json` output, matching other
/// one-shot providers (e.g. Codex): each user message spawns a process; multi-turn context is
/// flattened via a shared prompt format.
final class CursorAgentSession: AgentSession {
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var emittedAssistantPrefix = ""
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

        let prompt = Self.execPrompt(priorMessages: history.dropLast(), latestUserMessage: message)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "--print",
            "--output-format", "stream-json",
            "--trust",
            "--yolo",
            "--workspace", FileManager.default.homeDirectoryForCurrentUser.path,
            prompt
        ]

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
        } catch {
            isBusy = false
            let msg = "Failed to launch Cursor CLI: \(error.localizedDescription)"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
        }
    }

    func terminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        isRunning = false
        isBusy = false
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

    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let kind = json["type"] as? String ?? ""

        switch kind {
        case "assistant":
            if let full = Self.extractAssistantText(from: json) {
                emitAssistantDelta(full)
            }
        case "result":
            let failed = (json["is_error"] as? Bool) == true
            if failed {
                let msg = (json["result"] as? String) ?? "Request failed"
                onError?(msg)
                history.append(AgentMessage(role: .error, text: msg))
            } else if !emittedAssistantPrefix.isEmpty {
                history.append(AgentMessage(role: .assistant, text: emittedAssistantPrefix))
            }
            isBusy = false
            onTurnComplete?()
        case "thinking", "user", "system":
            break
        case "error":
            let msg = json["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            onError?(msg)
            history.append(AgentMessage(role: .error, text: msg))
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
        if emittedAssistantPrefix.isEmpty {
            onText?(full)
            emittedAssistantPrefix = full
        }
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
