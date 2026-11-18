import CapturistCore
import CapturistMCP
import Foundation

/// Every AI app `capturist setup` knows: how to tell it's on this Mac, whether Capturist is connected,
/// and how to connect/disconnect it. One table so `setup <agent>`, `setup detect` and `doctor` agree.
struct Agent {
    let id: String
    let name: String
    /// Short description of what `add` changes, for the confirmation prompt.
    let plan: () -> [String]
    let installed: () -> Bool
    let connected: () -> Bool
    /// Connects; returns what to tell the user. `nil` add = manual only (we print `manual`).
    let add: (() throws -> String)?
    let remove: (() throws -> String)?
    /// Copy-paste config for people who'd rather edit it by hand (and for manual-only agents).
    let manual: () -> String
    /// Shares its config with another target (ChatGPT and Codex): skipped by `detect --all` when that one runs.
    var sameConfigAs: String? = nil
}

enum Agents {
    static var home: URL { Setup.home }
    static var bin: String { Setup.binaryPath }
    static func path(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func app(_ name: String) -> Bool {
        exists(URL(fileURLWithPath: "/Applications/\(name).app")) || exists(path("Applications/\(name).app"))
    }
    static func onPath(_ tool: String) -> Bool {
        ([path(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init))
            .contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") }
    }

    static var standard: [String: Any] { ["command": bin, "args": ["mcp"]] }
    static func pretty(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// An agent whose config is a JSON file with servers under `key`.
    static func json(_ id: String, _ name: String, files: @escaping () -> [URL], key: @escaping (URL) -> [String] = { _ in ["mcpServers"] },
                     entry: @escaping () -> [String: Any] = { standard }, installed: @escaping () -> Bool, restart: String) -> Agent {
        Agent(
            id: id, name: name,
            plan: { files().map { "add the \"capturist\" MCP server to \($0.path) (backup kept)" } },
            installed: installed,
            connected: { files().contains { Setup.jsonHasServer(in: $0, key: key($0)) } },
            add: {
                for file in files() { try Setup.setJSONServer(entry(), in: file, key: key(file), snippet: manualJSON(key(file), entry())) }
                return "\(name) is set up. \(restart)"
            },
            remove: {
                for file in files() { try Setup.setJSONServer(nil, in: file, key: key(file), snippet: "") }
                return "Removed Capturist from \(name). Restart it to apply."
            },
            manual: { "In \(files().first?.path ?? "its MCP config"):\n\n" + manualJSON(key(files().first ?? home), entry()) }
        )
    }

    static func manualJSON(_ key: [String], _ entry: [String: Any]) -> String {
        var object: [String: Any] = ["capturist": entry]
        for part in key.reversed() { object = [part: object] }
        return pretty(object)
    }

    // MARK: the table

    static var all: [Agent] {
        [
            json("claude-desktop", "Claude (desktop app)", files: { [Setup.claudeDesktopConfigURL] },
                 installed: { app("Claude") || exists(path("Library/Application Support/Claude")) },
                 restart: "Quit and reopen Claude, then ask it about your screenshots."),

            Agent(
                id: "chatgpt", name: "ChatGPT (desktop app)",
                plan: { ["add [mcp_servers.capturist] to \(Setup.codexConfigURL.path) (shared by ChatGPT desktop's Codex and the Codex CLI; backup kept)"] },
                installed: { app("ChatGPT") },
                connected: { Setup.tomlInstalled },
                add: {
                    try Setup.setTOMLServer(enabled: true, in: Setup.codexConfigURL)
                    return """
                    ChatGPT desktop is set up for Codex (and the Codex CLI). Quit and reopen ChatGPT.
                    For regular ChatGPT chats, if your plan offers local MCP servers: ChatGPT › Settings ›
                    Connectors (or Apps) › Advanced › add a local server with
                      command: \(bin)
                      arguments: mcp
                    """
                },
                remove: {
                    try Setup.setTOMLServer(enabled: false, in: Setup.codexConfigURL)
                    return "Removed Capturist from \(Setup.codexConfigURL.path). Restart ChatGPT to apply."
                },
                manual: { "In ~/.codex/config.toml:\n\n[mcp_servers.capturist]\ncommand = \"\(bin)\"\nargs = [\"mcp\"]" },
                sameConfigAs: "codex"
            ),

            Agent(
                id: "claude-code", name: "Claude Code",
                plan: { ["write \(Setup.skillURL.path)", "register the MCP server: claude mcp add --scope user capturist -- \(bin) mcp"] },
                installed: { onPath("claude") || exists(path(".claude")) },
                connected: { Setup.jsonHasServer(in: path(".claude.json"), key: ["mcpServers"]) },
                add: { try Setup.addClaudeCode(notify: false) },
                remove: {
                    try? FileManager.default.removeItem(at: Setup.skillURL.deletingLastPathComponent())
                    try Setup.setNotifyHook(enabled: false)
                    Setup.runClaude(["mcp", "remove", "--scope", "user", "capturist"], quiet: true)
                    return "Removed Capturist (skill, tools and session notice) from Claude Code."
                },
                manual: { "claude mcp add --scope user capturist -- \(bin) mcp" }
            ),

            Agent(
                id: "codex", name: "Codex CLI",
                plan: { ["add [mcp_servers.capturist] to \(Setup.codexConfigURL.path) (backup kept)",
                         "add a Capturist block to \(Setup.agentsFiles["codex"]!.path)"] },
                installed: { onPath("codex") || exists(path(".codex")) },
                connected: { Setup.tomlInstalled },
                add: {
                    try Setup.setTOMLServer(enabled: true, in: Setup.codexConfigURL)
                    try Setup.writeBlock(Guide.agentGuide, to: Setup.agentsFiles["codex"]!)
                    return "Codex is set up (~/.codex/config.toml + AGENTS.md). Start a new Codex session."
                },
                remove: {
                    try Setup.setTOMLServer(enabled: false, in: Setup.codexConfigURL)
                    try Setup.writeBlock(nil, to: Setup.agentsFiles["codex"]!)
                    return "Removed Capturist from Codex."
                },
                manual: { "In ~/.codex/config.toml:\n\n[mcp_servers.capturist]\ncommand = \"\(bin)\"\nargs = [\"mcp\"]" }
            ),

            Agent(
                id: "hermes", name: "Hermes Agent",
                plan: { ["add capturist under mcp_servers in \(hermesConfig.path) (backup kept)"] },
                installed: { onPath("hermes") || exists(path(".hermes")) },
                connected: { AgentConfig.hasYAML((try? String(contentsOf: hermesConfig, encoding: .utf8)) ?? "", section: "mcp_servers", name: "capturist") },
                add: {
                    try Setup.setYAMLServer(hermesFields, in: hermesConfig, section: "mcp_servers", snippet: hermesManual)
                    return "Hermes is set up. Check it with `hermes mcp test capturist`, then start a new Hermes session (restart the gateway if you use one: `hermes gateway restart`)."
                },
                remove: {
                    try Setup.setYAMLServer(nil, in: hermesConfig, section: "mcp_servers", snippet: "")
                    return "Removed Capturist from \(hermesConfig.path)."
                },
                manual: { "In ~/.hermes/config.yaml:\n\n" + hermesManual }
            ),

            json("gemini", "Gemini CLI", files: { [path(".gemini/settings.json")] },
                 installed: { onPath("gemini") || exists(path(".gemini")) },
                 restart: "Start a new Gemini CLI session; `/mcp` lists the Capturist tools."),

            json("qwen", "Qwen Code", files: { [path(".qwen/settings.json")] },
                 installed: { onPath("qwen") || exists(path(".qwen")) },
                 restart: "Start a new Qwen Code session; `/mcp` lists the Capturist tools."),

            json("cursor", "Cursor", files: { [path(".cursor/mcp.json")] },
                 installed: { app("Cursor") || exists(path(".cursor")) },
                 restart: "Restart Cursor; Capturist shows up in Settings › MCP."),

            json("windsurf", "Windsurf", files: { [path(".codeium/windsurf/mcp_config.json")] },
                 installed: { app("Windsurf") || exists(path(".codeium/windsurf")) },
                 restart: "Restart Windsurf, or press Refresh in Cascade › MCP servers."),

            json("vscode", "VS Code (GitHub Copilot)", files: { [vscodeUser.appendingPathComponent("mcp.json")] }, key: { _ in ["servers"] },
                 entry: { ["type": "stdio", "command": bin, "args": ["mcp"]] },
                 installed: { app("Visual Studio Code") || exists(vscodeUser) },
                 restart: "Reload VS Code; Capturist appears under MCP Servers in the Extensions view (start it there if asked)."),

            json("copilot", "GitHub Copilot CLI", files: { [copilotHome.appendingPathComponent("mcp-config.json")] },
                 entry: { ["type": "stdio", "command": bin, "args": ["mcp"], "tools": ["*"]] },
                 installed: { onPath("copilot") || exists(copilotHome) },
                 restart: "Start a new Copilot session; `/mcp` lists Capturist."),

            json("cline", "Cline", files: { clineFiles },
                 entry: { ["command": bin, "args": ["mcp"], "disabled": false] },
                 installed: { clineFiles.contains { exists($0.deletingLastPathComponent().deletingLastPathComponent()) } },
                 restart: "Capturist appears in Cline › MCP Servers › Installed."),

            Agent(
                id: "opencode", name: "OpenCode",
                plan: { ["add the \"capturist\" MCP server to \(opencodeConfig.path) (backup kept)",
                         "add a Capturist block to \(Setup.agentsFiles["opencode"]!.path)"] },
                installed: { onPath("opencode") || exists(path(".config/opencode")) },
                connected: { Setup.jsonHasServer(in: opencodeConfig, key: opencodeKey) },
                add: {
                    if !exists(opencodeConfig), exists(path(".config/opencode/opencode.jsonc")) {
                        throw CLIError.badInput("OpenCode uses opencode.jsonc (comments); not editing it. Add this yourself:\n\n" + manualJSON(opencodeKey, opencodeEntry))
                    }
                    try Setup.setJSONServer(opencodeEntry, in: opencodeConfig, key: opencodeKey, snippet: manualJSON(opencodeKey, opencodeEntry))
                    try Setup.writeBlock(Guide.agentGuide, to: Setup.agentsFiles["opencode"]!)
                    return "OpenCode is set up. Start a new OpenCode session; `opencode mcp list` shows Capturist."
                },
                remove: {
                    try Setup.setJSONServer(nil, in: opencodeConfig, key: opencodeKey, snippet: "")
                    try Setup.writeBlock(nil, to: Setup.agentsFiles["opencode"]!)
                    return "Removed Capturist from OpenCode."
                },
                manual: { "In ~/.config/opencode/opencode.json:\n\n" + manualJSON(opencodeKey, opencodeEntry) }
            ),

            json("lmstudio", "LM Studio", files: { [path(".lmstudio/mcp.json")] },
                 installed: { app("LM Studio") || exists(path(".lmstudio")) },
                 restart: "LM Studio reloads mcp.json; turn on capturist in a chat's Integrations menu."),

            Agent(
                id: "zed", name: "Zed",
                plan: { [] }, installed: { app("Zed") || exists(path(".config/zed")) },
                connected: { ((try? String(contentsOf: path(".config/zed/settings.json"), encoding: .utf8)) ?? "").contains("\"capturist\"") },
                add: nil, remove: nil,
                manual: { "Zed › Settings › open settings file (~/.config/zed/settings.json), add:\n\n" + manualJSON(["context_servers"], standard) }
            ),

            Agent(
                id: "goose", name: "Goose",
                plan: { [] }, installed: { onPath("goose") || app("Goose") || exists(path(".config/goose")) },
                connected: { ((try? String(contentsOf: path(".config/goose/config.yaml"), encoding: .utf8)) ?? "").contains("capturist") },
                add: nil, remove: nil,
                manual: {
                    """
                    Run `goose configure` › Add Extension › Command-line Extension, name capturist, command:
                      \(bin) mcp
                    (or in the Goose app: Extensions › Add custom extension, type STDIO, same command)
                    """
                }
            ),
        ]
    }

    static func find(_ id: String) -> Agent? {
        let aliases = ["claude": "claude-desktop", "gemini-cli": "gemini", "qwen-code": "qwen", "copilot-cli": "copilot",
                       "code": "vscode", "vs-code": "vscode", "lm-studio": "lmstudio", "hermes-agent": "hermes"]
        let key = aliases[id] ?? id
        return all.first { $0.id == key }
    }

    // MARK: per-agent details

    static var hermesHome: URL {
        if let custom = ProcessInfo.processInfo.environment["HERMES_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return path(".hermes")
    }
    static var hermesConfig: URL { hermesHome.appendingPathComponent("config.yaml") }
    static var hermesFields: [String] { ["command: \(AgentConfig.yamlQuote(bin))", "args: [\"mcp\"]", "enabled: true"] }
    static var hermesManual: String { "mcp_servers:\n  capturist:\n" + hermesFields.map { "    \($0)" }.joined(separator: "\n") }

    static var vscodeUser: URL { path("Library/Application Support/Code/User") }
    static var copilotHome: URL {
        if let custom = ProcessInfo.processInfo.environment["COPILOT_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return path(".copilot")
    }
    static var clineFiles: [URL] {
        let cli = path(".cline/data/settings/cline_mcp_settings.json")
        let ext = vscodeUser.appendingPathComponent("globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
        let present = [cli, ext].filter { exists($0.deletingLastPathComponent().deletingLastPathComponent()) }
        return present.isEmpty ? [cli] : present
    }

    static var opencodeConfig: URL { path(".config/opencode/opencode.json") }
    /// OpenCode ≤1.x keeps servers directly under "mcp"; newer configs nest them under "mcp.servers".
    static var opencodeNested: Bool {
        guard let data = try? Data(contentsOf: opencodeConfig),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcp = config["mcp"] as? [String: Any] else { return false }
        return mcp["servers"] is [String: Any]
    }
    static var opencodeKey: [String] { opencodeNested ? ["mcp", "servers"] : ["mcp"] }
    static var opencodeEntry: [String: Any] {
        opencodeNested ? ["type": "local", "command": [bin, "mcp"]] : ["type": "local", "command": [bin, "mcp"], "enabled": true]
    }
}
