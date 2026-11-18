# capturist-mcp

**Give Claude, ChatGPT, Codex and other AI apps your Mac screenshots.** `capturist` is the command line tool and local MCP server for [Capturist](https://capturist.nodetools.org), the Mac app that keeps your screenshots, saved text and clipboard in one private library and reads the words inside every screenshot on your Mac.

Ask your AI app things like:

- “Fix the failing test from my last screenshot.”
- “Find the screenshot with the Acme invoice and read me the total.”
- “What did the error I captured an hour ago say?”

It's a local server: everything stays on your Mac. macOS 14 Sonoma or later, Apple silicon or Intel. You need [Capturist](https://capturist.nodetools.org) installed: the free beta, Capturist Complete, or Capturist from the Mac App Store.

## Install

```sh
curl -fsSL https://capturist.nodetools.org/install-cli.sh | bash
```

This installs a universal, Developer ID signed and Apple-notarized `capturist` to `~/.local/bin` after checking its checksum and signature. Run it again to update. The same zip is attached to each [GitHub release](../../releases).

Or with Homebrew:

```sh
brew install vortex-303/tap/capturist
```

**Claude desktop, one click:** download `capturist.mcpb` from the [latest release](../../releases/latest) and open it (or Claude › Settings › Extensions › Install Extension).

Listed in the official MCP Registry as `io.github.vortex-303/capturist-mcp`.

Or build it yourself (Swift 6):

```sh
swift build -c release --product capturist
cp .build/release/capturist ~/.local/bin/
```

## Connect your AI apps

```sh
capturist setup detect           # which AI apps are on this Mac, and which are connected
capturist setup detect --all     # connect all of them (shows every file first, asks once)
```

Or one at a time (`--remove` undoes it, `--manual` prints the snippet instead):

| App | Command | Config it changes |
|---|---|---|
| Claude (desktop app) | `capturist setup claude-desktop` | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| ChatGPT (desktop app) | `capturist setup chatgpt` | `~/.codex/config.toml` |
| Claude Code | `capturist setup claude-code` | `claude mcp add --scope user` + skill |
| Codex CLI | `capturist setup codex` | `~/.codex/config.toml` + `AGENTS.md` |
| Hermes Agent | `capturist setup hermes` | `~/.hermes/config.yaml` |
| Gemini CLI | `capturist setup gemini` | `~/.gemini/settings.json` |
| Qwen Code | `capturist setup qwen` | `~/.qwen/settings.json` |
| GitHub Copilot CLI | `capturist setup copilot` | `~/.copilot/mcp-config.json` |
| OpenCode | `capturist setup opencode` | `~/.config/opencode/opencode.json` + `AGENTS.md` |
| Cursor | `capturist setup cursor` | `~/.cursor/mcp.json` |
| Windsurf | `capturist setup windsurf` | `~/.codeium/windsurf/mcp_config.json` |
| VS Code (Copilot) | `capturist setup vscode` | `~/Library/Application Support/Code/User/mcp.json` |
| Cline | `capturist setup cline` | `cline_mcp_settings.json` |
| LM Studio | `capturist setup lmstudio` | `~/.lmstudio/mcp.json` |
| Zed, Goose | `capturist setup zed` / `goose` | prints the steps (Zed's settings allow comments) |

Every change keeps a `.capturist-backup` of the file, and files that aren't plain JSON are never rewritten. Step-by-step guide: https://capturist.nodetools.org/ai/

Then reopen the app. For any other MCP client:

```json
{
  "mcpServers": {
    "capturist": { "command": "capturist", "args": ["mcp"] }
  }
}
```

## Tools

| Tool | What it does |
|---|---|
| `recent_captures` | Newest captures, optionally since a time or of one kind |
| `search_captures` | Search names, source app, window title and the text inside screenshots |
| `get_capture` | One capture: details, the text inside it, and the image |
| `capture_text` | Just the text inside a capture (errors, logs, code) |
| `recent_clips` | Recent clipboard text, if clipboard history is on in Capturist |
| `save_snippet`, `save_image` | Add text or an image to the library, only if you allow it in Capturist |

## How it works

`capturist mcp` is a standard MCP server over stdio.

- **Relay:** when Capturist 1.1 or later is open with Settings › AI Agents on, it forwards every message to the app's own server on `127.0.0.1`, so your AI apps get every tool, under the app's rules.
- **Direct:** when the app is closed, or on Capturist 1.0, it opens your library read-only and reads it itself.

Text inside screenshots is recognized with Apple's on-device Vision framework. See [SECURITY.md](SECURITY.md) for the details of the local connection.

## Command line

```sh
capturist recent --since 30m          # newest captures
capturist search "invoice 502" --json # names, apps, window titles, text inside images
capturist text latest                 # the text inside the latest capture
capturist clips --since 1h            # clipboard history (if turned on)
capturist setup shortcut              # ⌥⌘7 saves selected text to Capturist
capturist doctor                      # check access, index and setup
```

Full reference: [capturist.nodetools.org/cli](https://capturist.nodetools.org/cli/). Exit codes: 0 ok · 1 nothing found · 2 bad input · 3 library missing or not readable.

## Packages

| Module | What it is |
|---|---|
| `capturist` (`Sources/capturist-cli`) | The command line tool and MCP server |
| `CapturistMCP` | MCP tool handler shared by the CLI and the Capturist app |
| `CapturistStore` | Reads (and, in the app, writes) the Capturist library and its text index |
| `CapturistCore` | Shared models |

```sh
swift test
```

## License

MIT © Vortex303. The Capturist app itself is not open source.
