import CapturistCore
import CapturistStore
import CapturistMCP
import Foundation

/// `capturist setup …` and `capturist doctor`: tell agents Capturist exists, and check everything works.
enum Setup {
    /// `$HOME` when set (so tests and wrappers can point it elsewhere), else the account's home.
    static let home: URL = {
        if let value = ProcessInfo.processInfo.environment["HOME"], value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    static let startMarker = "<!-- capturist:start -->"
    static let endMarker = "<!-- capturist:end -->"

    static var binaryPath: String {
        let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        // Homebrew: point configs at the stable bin link, not the versioned Cellar path (gone after `brew upgrade`).
        if let cellar = resolved.range(of: "/Cellar/") {
            let link = String(resolved[..<cellar.lowerBound]) + "/bin/capturist"
            if URL(fileURLWithPath: link).resolvingSymlinksInPath().path == resolved { return link }
        }
        return resolved
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

    static let usage = "Usage: capturist setup <agent|detect|shortcut> [--remove] [--yes]\n       capturist setup detect [--all] [--yes]   find the AI apps on this Mac (--all connects them)\nAgents: " + Agents.all.map(\.id).joined(separator: ", ")

    static func run(_ args: Args) throws -> Int32 {
        if args.flags.contains("--list") || args.positional.isEmpty {
            printList()
            if !args.flags.contains("--list") { Console.out("\n" + usage) }
            return 0
        }
        let target = args.positional[0]
        let remove = args.flags.contains("--remove")
        let yes = args.flags.contains("--yes")

        if target == "shortcut" { return try ServiceShortcut.run(args, remove: remove, yes: yes) }
        if target == "detect" { return try detect(all: args.flags.contains("--all"), yes: yes) }
        guard let agent = Agents.find(target) else {
            throw CLIError.badInput("Unknown target '\(target)'.\n" + usage)
        }
        if args.flags.contains("--manual") {
            Console.out(agent.manual())
            return 0
        }
        if remove {
            guard let removeAgent = agent.remove else { Console.out("Remove Capturist from \(agent.name) by hand:\n\n" + agent.manual()); return 0 }
            Console.out(try removeAgent())
            return 0
        }
        guard let add = agent.add else {
            Console.out("\(agent.name) is set up by hand:\n\n" + agent.manual())
            return 0
        }
        if agent.id == "claude-code" {
            var plan = agent.plan()
            let notify = args.flags.contains("--notify")
            if notify { plan.insert("add a SessionStart hook to \(claudeSettingsURL.path): \(notifyCommand)", at: 1) }
            guard confirm(plan, yes: yes) else { return 2 }
            Console.out(try addClaudeCode(notify: notify))
            return 0
        }
        guard confirm(agent.plan(), yes: yes) else { return 2 }
        Console.out(try add())
        return 0
    }

    /// `setup detect [--all]`: which AI apps are on this Mac and whether Capturist is connected to each.
    static func detect(all: Bool, yes: Bool) throws -> Int32 {
        let agents = Agents.all
        let found = agents.filter { $0.installed() }
        Console.out("AI apps on this Mac:")
        if found.isEmpty { Console.out("  none found") }
        for agent in found {
            let state = agent.connected() ? "✓ connected" : (agent.add == nil ? "— set up by hand: capturist setup \(agent.id)" : "— not connected: capturist setup \(agent.id)")
            Console.out("  \(agent.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(state)")
        }
        var todo = found.filter { !$0.connected() && $0.add != nil }
        // ChatGPT and Codex share ~/.codex/config.toml: let Codex do it when both are here.
        let ids = Set(todo.map(\.id))
        todo.removeAll { agent in agent.sameConfigAs.map(ids.contains) ?? false }
        guard all else {
            if !todo.isEmpty { Console.out("\nConnect all of them: capturist setup detect --all") }
            return 0
        }
        guard !todo.isEmpty else { Console.out("\nNothing to connect."); return 0 }
        guard confirm(todo.flatMap { $0.plan() }, yes: yes) else { return 2 }
        var failures = 0
        for agent in todo {
            do {
                let message = agent.id == "claude-code" ? try addClaudeCode(notify: false) : try agent.add!()
                Console.out("✓ " + message)
            } catch let error as CLIError {
                failures += 1
                Console.out("✗ \(agent.name): \(error.message)")
            }
        }
        Console.out("\nReopen those apps (or start a new session) to pick up Capturist.")
        return failures == 0 ? 0 : 1
    }

    static func addClaudeCode(notify: Bool) throws -> String {
        try FileManager.default.createDirectory(at: skillURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skillText.write(to: skillURL, atomically: true, encoding: .utf8)
        if notify { try setNotifyHook(enabled: true) }
        runClaude(["mcp", "remove", "--scope", "user", "capturist"], quiet: true)   // replace any older entry
        if runClaude(["mcp", "add", "--scope", "user", "capturist", "--", binaryPath, "mcp"], quiet: true) == 0 {
            return "Claude Code is set up (skill + tools). Restart open sessions."
        }
        return "Claude Code skill installed. Add the tools yourself:  claude mcp add --scope user capturist -- \(binaryPath) mcp"
    }

    // MARK: desktop app configs

    static var claudeDesktopConfigURL: URL { home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }
    static var codexConfigURL: URL { home.appendingPathComponent(".codex/config.toml") }
    static let tomlStart = "# capturist:start"
    static let tomlEnd = "# capturist:end"

    /// Sets (or removes, `nil`) `<key…>.capturist` in a JSON config, keeping everything else (backup first).
    /// Files we can't parse (JSONC with comments, trailing commas) are left alone and `snippet` is shown instead.
    static func setJSONServer(_ server: [String: Any]?, in url: URL, key: [String] = ["mcpServers"], snippet: String = "") throws {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.badInput("\(url.path) isn't plain JSON (comments?); not changing it." + (snippet.isEmpty ? "" : " Add this yourself:\n\n" + snippet))
            }
            config = parsed
            if server == nil, !AgentConfig.hasJSON(config, path: key, name: "capturist") { return }
            try? data.write(to: url.appendingPathExtension("capturist-backup"))
        } else if server == nil {
            return
        }
        do {
            config = try AgentConfig.setJSON(config, path: key, name: "capturist", entry: server)
        } catch {
            throw CLIError.badInput("\(url.path) has an unexpected \(key.joined(separator: ".")) value; not changing it.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func jsonHasServer(in url: URL, key: [String]) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return AgentConfig.hasJSON(config, path: key, name: "capturist")
    }

    /// Same for a block-style YAML config (Hermes).
    static func setYAMLServer(_ fields: [String]?, in url: URL, section: String, snippet: String) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if fields == nil, !AgentConfig.hasYAML(text, section: section, name: "capturist") { return }
        let updated: String
        do {
            updated = try AgentConfig.setYAML(text, section: section, name: "capturist", fields: fields)
        } catch {
            throw CLIError.badInput("\(url.path) uses a YAML style we don't edit; not changing it." + (snippet.isEmpty ? "" : " Add this yourself:\n\n" + snippet))
        }
        if !text.isEmpty { try? text.write(to: url.appendingPathExtension("capturist-backup"), atomically: true, encoding: .utf8) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    static var tomlInstalled: Bool { (try? String(contentsOf: codexConfigURL, encoding: .utf8))?.contains(tomlStart) ?? false }

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
        for agent in Agents.all {
            let state = agent.connected() ? "connected" : (agent.installed() ? "not connected" : "—")
            Console.out("\(agent.id.padding(toLength: 15, withPad: " ", startingAt: 0)) \(agent.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(state)")
        }
        Console.out("\("shortcut".padding(toLength: 15, withPad: " ", startingAt: 0)) \("Save selected text".padding(toLength: 26, withPad: " ", startingAt: 0)) \(ServiceShortcut.currentSummary())")
        if notifyInstalled { Console.out("(Claude Code session notice is on)") }
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
