import CapturistCore
import CapturistStore
import CapturistMCP
import Foundation

/// `capturist setup …` and `capturist doctor`: tell agents Capturist exists, and check everything works.
enum Setup {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let startMarker = "<!-- capturist:start -->"
    static let endMarker = "<!-- capturist:end -->"

    static var binaryPath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
    }

    static var skillURL: URL { home.appendingPathComponent(".claude/skills/capturist/SKILL.md") }
    static var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var agentsFiles: [String: URL] {
        [
            "opencode": home.appendingPathComponent(".config/opencode/AGENTS.md"),
            "codex": home.appendingPathComponent(".codex/AGENTS.md"),
        ]
    }

    static var skillText: String {
        "---\nname: capturist\ndescription: \(Guide.skillDescription)\n---\n\n\(Guide.agentGuide)\n"
    }

    static var notifyCommand: String { "\(binaryPath) recent --since 2h --brief" }

    // MARK: setup

    static func run(_ args: Args) throws -> Int32 {
        if args.flags.contains("--list") || args.command == "setup" && args.positional.isEmpty {
            printList()
            if args.positional.isEmpty && !args.flags.contains("--list") {
                Console.out("\nUsage: capturist setup <claude-code|opencode|codex|claude-desktop|cursor|chatgpt|shortcut> [--remove] [--notify] [--yes]")
            }
            return 0
        }
        let agent = args.positional[0]
        let remove = args.flags.contains("--remove")
        let yes = args.flags.contains("--yes")

        switch agent {
        case "claude-code":
            if remove {
                try? FileManager.default.removeItem(at: skillURL.deletingLastPathComponent())
                try setNotifyHook(enabled: false)
                Console.out("Removed the Capturist skill (and session notice, if any) from Claude Code.")
                return 0
            }
            var plan = ["write \(skillURL.path)"]
            if args.flags.contains("--notify") { plan.append("add a SessionStart hook to \(claudeSettingsURL.path): \(notifyCommand)") }
            plan.append("register the MCP server: claude mcp add --scope user capturist -- \(binaryPath) mcp")
            guard confirm(plan, yes: yes) else { return 2 }
            try FileManager.default.createDirectory(at: skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skillText.write(to: skillURL, atomically: true, encoding: .utf8)
            if args.flags.contains("--notify") { try setNotifyHook(enabled: true) }
            Console.out("Claude Code now knows about Capturist (skill installed).")
            runClaude(["mcp", "remove", "--scope", "user", "capturist"], quiet: true)   // replace any older entry
            if runClaude(["mcp", "add", "--scope", "user", "capturist", "--", binaryPath, "mcp"], quiet: false) == 0 {
                Console.out("Capturist tools added to Claude Code (restart open sessions).")
            } else {
                Console.out("Add the tools yourself:  claude mcp add --scope user capturist -- \(binaryPath) mcp")
            }
            return 0

        case "opencode", "codex":
            if agent == "codex", !remove { try? setTOMLServer(enabled: true, in: codexConfigURL) }
            if agent == "codex", remove { try? setTOMLServer(enabled: false, in: codexConfigURL) }
            let file = agentsFiles[agent]!
            if remove {
                try writeBlock(nil, to: file)
                Console.out("Removed the Capturist block from \(file.path).")
                return 0
            }
            guard confirm(["add a Capturist block to \(file.path) (between \(startMarker) and \(endMarker))"], yes: yes) else { return 2 }
            try writeBlock(Guide.agentGuide, to: file)
            Console.out("\(agent) now knows about Capturist (\(file.path)).")
            return 0

        case "claude-desktop":
            let file = claudeDesktopConfigURL
            if remove {
                try setJSONServer(nil, in: file)
                Console.out("Removed Capturist from \(file.path). Restart Claude to apply.")
                return 0
            }
            guard confirm(["add the \"capturist\" MCP server to \(file.path) (backup kept)"], yes: yes) else { return 2 }
            try setJSONServer(["command": binaryPath, "args": ["mcp"]], in: file)
            Console.out("Claude (desktop app) is set up. Quit and reopen Claude, then ask it about your screenshots.")
            return 0

        case "chatgpt":
            let file = codexConfigURL
            if remove {
                try setTOMLServer(enabled: false, in: file)
                Console.out("Removed Capturist from \(file.path). Restart ChatGPT to apply.")
                return 0
            }
            guard confirm(["add [mcp_servers.capturist] to \(file.path) (shared by the ChatGPT desktop app's Codex and the Codex CLI; backup kept)"], yes: yes) else { return 2 }
            try setTOMLServer(enabled: true, in: file)
            Console.out("""
            ChatGPT desktop is set up for Codex (and the Codex CLI). Quit and reopen ChatGPT.
            For regular ChatGPT chats, if your plan offers local MCP servers: ChatGPT › Settings ›
            Connectors (or Apps) › Advanced › add a local server with
              command: \(binaryPath)
              arguments: mcp
            """)
            return 0

        case "shortcut":
            return try ServiceShortcut.run(args, remove: remove, yes: yes)

        case "cursor":
            Console.out("Add this MCP server in ~/.cursor/mcp.json:\n")
            Console.out("""
            {
              "mcpServers": {
                "capturist": { "command": "\(binaryPath)", "args": ["mcp"] }
              }
            }
            """)
            Console.out("\nThen restart the app. Tools: recent_captures, search_captures, get_capture, capture_text, recent_clips.")
            return 0

        default:
            throw CLIError.badInput("Unknown target '\(agent)'. Use claude-code, opencode, codex, claude-desktop, cursor, chatgpt or shortcut.")
        }
    }

    // MARK: desktop app configs

    static var claudeDesktopConfigURL: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    static let tomlStart = "# capturist:start"
    static let tomlEnd = "# capturist:end"

    /// Sets (or removes, `nil`) `mcpServers.capturist` in a JSON config, keeping everything else.
    static func setJSONServer(_ server: [String: Any]?, in url: URL) throws {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.badInput("\(url.path) isn't a JSON object; not changing it.")
            }
            config = parsed
            try? data.write(to: url.appendingPathExtension("capturist-backup"))
        } else if server == nil {
            return
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["capturist"] = server
        config["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Adds/removes our marked `[mcp_servers.capturist]` block in Codex's config.toml.
    static func setTOMLServer(enabled: Bool, in url: URL) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty { try? text.write(to: url.appendingPathExtension("capturist-backup"), atomically: true, encoding: .utf8) }
        if let start = text.range(of: tomlStart), let end = text.range(of: tomlEnd, range: start.upperBound..<text.endIndex) {
            var upper = end.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            text.removeSubrange(start.lowerBound..<upper)
        } else if text.contains("[mcp_servers.capturist]") {
            throw CLIError.badInput("\(url.path) already has a [mcp_servers.capturist] entry; edit it by hand.")
        }
        if enabled {
            let path = binaryPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            if !text.isEmpty && !text.hasSuffix("\n\n") { text += "\n" }
            text += "\(tomlStart)\n[mcp_servers.capturist]\ncommand = \"\(path)\"\nargs = [\"mcp\"]\n\(tomlEnd)\n"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs `claude …` if Claude Code is installed; returns the exit code (-1 when it isn't found).
    @discardableResult
    static func runClaude(_ arguments: [String], quiet: Bool) -> Int32 {
        let candidates = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func confirm(_ plan: [String], yes: Bool) -> Bool {
        Console.out("capturist setup will:")
        plan.forEach { Console.out("  • \($0)") }
        if yes { return true }
        guard isatty(STDIN_FILENO) != 0 else {
            Console.err("Not a terminal: re-run with --yes to confirm.")
            return false
        }
        print("Continue? [y/N] ", terminator: "")
        let answer = readLine()?.lowercased() ?? ""
        return answer == "y" || answer == "yes"
    }

    /// Inserts, replaces (`text`) or removes (`nil`) the marked Capturist block in an AGENTS.md file.
    static func writeBlock(_ text: String?, to file: URL) throws {
        var content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let start = content.range(of: startMarker), let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex) {
            var lower = start.lowerBound
            if lower > content.startIndex, content[content.index(before: lower)] == "\n" { lower = content.index(before: lower) }
            content.removeSubrange(lower..<end.upperBound)
        }
        if let text {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            content += "\n\(startMarker)\n\(text)\n\(endMarker)\n"
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Adds/removes our SessionStart hook in ~/.claude/settings.json, keeping everything else (backup first).
    static func setNotifyHook(enabled: Bool) throws {
        let url = claudeSettingsURL
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.badInput("\(url.path) isn't a JSON object; not changing it.")
            }
            settings = parsed
            try? data.write(to: url.appendingPathExtension("capturist-backup"))
        } else if !enabled {
            return
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var sessionStart = (hooks["SessionStart"] as? [[String: Any]] ?? []).filter { group in
            let commands = (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            return !commands.contains { $0.contains("capturist") && $0.contains("--brief") }
        }
        if enabled {
            sessionStart.append(["hooks": [["type": "command", "command": notifyCommand]]])
        }
        hooks["SessionStart"] = sessionStart.isEmpty ? nil : sessionStart
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static var notifyInstalled: Bool {
        guard let text = try? String(contentsOf: claudeSettingsURL, encoding: .utf8) else { return false }
        return text.contains("recent --since") && text.contains("--brief") && text.contains("capturist")
    }

    static func blockInstalled(_ file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8))?.contains(startMarker) ?? false
    }

    static func printList() {
        let skill = FileManager.default.fileExists(atPath: skillURL.path)
        Console.out("claude-code   skill: \(skill ? "installed" : "—")   session notice: \(notifyInstalled ? "on" : "off")")
        for (agent, file) in agentsFiles.sorted(by: { $0.key < $1.key }) {
            Console.out("\(agent.padding(toLength: 13, withPad: " ", startingAt: 0)) AGENTS.md block: \(blockInstalled(file) ? "installed" : "—")")
        }
        let desktop = (try? String(contentsOf: claudeDesktopConfigURL, encoding: .utf8))?.contains("\"capturist\"") ?? false
        let codex = (try? String(contentsOf: codexConfigURL, encoding: .utf8))?.contains(tomlStart) ?? false
        Console.out("claude-desktop MCP server: \(desktop ? "added" : "—")")
        Console.out("chatgpt/codex  MCP server (~/.codex/config.toml): \(codex ? "added" : "—")")
        Console.out("shortcut       save selected text: \(ServiceShortcut.currentSummary())")
    }

    // MARK: doctor

    static func doctor(_ args: Args) async -> Int32 {
        var problems = 0
        Console.out("capturist \(Guide.version) at \(binaryPath)")
        let installed = Library.installed()
        if installed.isEmpty {
            problems += 1
            Console.out("✗ no Capturist library found (install Capturist and open it once)")
        }
        for edition in installed {
            let which = edition.which
            do {
                let library = try Library.open(which.rawValue)
                let stats = try await library.store.stats()
                Console.out("✓ \(which.rawValue) library: \(stats.captureCount) captures, readable")
                Console.out("  text index: \(library.index.count) of \(stats.captureCount) captures (run `capturist index --library \(which.rawValue)` to update)")
            } catch let error as CLIError {
                problems += 1
                Console.out("✗ \(which.rawValue) library: \(error.message)")
            } catch {
                problems += 1
                Console.out("✗ \(which.rawValue) library: \(error)")
            }
        }
        if (try? Library.locate(args.options["--library"])) == nil {
            problems += 1
            Console.out("✗ No library found. Install and open Capturist once.")
        }
        printList()
        return problems == 0 ? 0 : 3
    }
}
