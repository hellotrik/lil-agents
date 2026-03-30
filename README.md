# lil agents

![lil agents](hero-thumbnail.png)

Tiny AI companions that live on your macOS dock.

**Bruce** and **Jazz** walk back and forth above your dock. Click one to open an AI terminal. They walk, they think, they vibe.

Supports **Claude Code**, **OpenAI Codex**, **GitHub Copilot**, **Google Gemini**, and **Cursor CLI** (`agent`) — switch between them from the menubar.

**[Download for macOS](https://lilagents.xyz)** · [Website](https://lilagents.xyz)

## features

- Animated characters rendered from transparent HEVC video
- Click a character to chat with AI in a themed popover terminal
- Switch between Claude, Codex, Copilot, Gemini, and Cursor from the menubar
- Four visual themes: Peach, Midnight, Cloud, Moss
- Slash commands: `/clear`, `/copy`, `/help` in the chat input
- Copy last response button in the title bar
- Thinking bubbles with playful phrases while your agent works
- Sound effects on completion
- First-run onboarding with a friendly welcome
- Sparkle updates (automatic checks disabled; appcast URL is local in `Info.plist` — serve `appcast.xml` yourself when testing)

## requirements

- macOS Sonoma (14.0+) — including Sequoia (15.x)
- **Universal binary** — runs natively on both Apple Silicon and Intel Macs
- At least one supported CLI installed:
  - [Claude Code](https://claude.ai/download) — `curl -fsSL https://claude.ai/install.sh | sh`
  - [OpenAI Codex](https://github.com/openai/codex) — `npm install -g @openai/codex`
  - [GitHub Copilot](https://github.com/github/copilot-cli) — `brew install copilot-cli`
  - [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) — `npm install -g @google/gemini-cli`
  - [Cursor CLI](https://cursor.com/docs/cli/overview) — `curl https://cursor.com/install -fsS | bash` (then `agent login` or `CURSOR_API_KEY`)

## building

Open `lil-agents.xcodeproj` in Xcode and hit run.

## privacy

lil agents runs entirely on your Mac and sends no personal data anywhere.

- **Your data stays local.** The app plays bundled animations and calculates your dock size to position the characters. No project data, file paths, or personal information is collected or transmitted.
- **AI providers.** Conversations are handled entirely by the CLI process you choose (Claude, Codex, Copilot, Gemini, or Cursor) running locally. lil agents does not intercept, store, or transmit your chat content. Any data sent to the provider is governed by their respective terms and privacy policies (for Cursor CLI, that includes Cursor’s services when your request is processed by their agent).
- **No accounts in lil agents.** The app itself has no login or user database. Some CLIs (including Cursor CLI) may require their own account or API key in your environment.
- **Updates.** Sparkle is configured with **no automatic background checks**. The update feed URL is **`http://127.0.0.1:8080/appcast.xml`** (see `LilAgents/Info.plist`). When you use **Check for Updates…**, Sparkle requests that URL and sends your app version and macOS version to whatever server is listening there — typically only your own machine during local testing.

## license

MIT License. See [LICENSE](LICENSE) for details.
