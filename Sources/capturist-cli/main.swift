import CapturistCore
import CapturistStore
import CapturistMCP
import Foundation

struct Args {
    var command: String?
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    static let valueOptions: Set<String> = ["--library", "--since", "--kind", "--limit", "--app", "--key"]

    init(_ raw: [String]) throws {
        var items = raw[...]
        while let item = items.popFirst() {
            if Self.valueOptions.contains(item) {
                guard let value = items.popFirst() else { throw CLIError.badInput("\(item) needs a value") }
                options[item] = value
            } else if item.hasPrefix("--") {
                flags.insert(item)
            } else if command == nil {
                command = item
            } else {
                positional.append(item)
            }
        }
    }

    var json: Bool { flags.contains("--json") }

    func limit(default value: Int) throws -> Int {
        guard let text = options["--limit"] else { return value }
        guard let number = Int(text), number > 0 else { throw CLIError.badInput("--limit must be a positive number") }
        return number
    }

    func kind() throws -> CaptureKind? {
        guard let text = options["--kind"] else { return nil }
        guard let kind = CaptureKind(rawValue: text) else { throw CLIError.badInput("--kind must be image, text, pdf, file or video") }
        return kind
    }

    func since() throws -> Date? { try options["--since"].map(Output.since) }
}

func printCaptures(_ captures: [Capture], library: Library, json: Bool) {
    if json {
        Console.out(Output.encode(captures.map { Output.json($0, path: library.fileURL($0)) }))
    } else {
        captures.forEach { Console.out(Output.line($0)) }
    }
}

func run(_ args: Args) async throws -> Int32 {
    switch args.command {
    case nil where args.flags.contains("--version"), "version":
        Console.out(Guide.version)
        return 0
    case nil, "help", "--help", "-h":
        Console.out(Guide.usage)
        return 0
    case "guide":
        Console.out(Guide.agentGuide)
        return 0
    case "setup":
        return try Setup.run(args)
    case "doctor":
        return await Setup.doctor(args)
    case "mcp":
        let library = try Library.open(args.options["--library"])
        await MCPServer(library: library).run()
        return 0
    default:
        break
    }

    let library = try Library.open(args.options["--library"])
    switch args.command {
    case "recent":
        if !args.flags.contains("--no-index") { try await library.refreshIndex() }
        let list = try await library.store.captures(kind: try args.kind(), since: try args.since(), limit: try args.limit(default: 20))
        if args.flags.contains("--brief") {
            // One line for session-start hooks; silent when there's nothing new.
            guard let latest = list.first else { return 0 }
            let window = args.options["--since"].map { " in the last \($0)" } ?? ""
            Console.out("Capturist: \(list.count) new capture\(list.count == 1 ? "" : "s")\(window) (latest: \"\(latest.displayName)\"\(latest.sourceApp.map { ", \($0)" } ?? ""), \(Output.ago(latest.createdAt))). Use the capturist skill/CLI to look at them.")
            return 0
        }
        if list.isEmpty { if !args.json { Console.err("No captures found.") } else { Console.out("[]") }; return 1 }
        printCaptures(list, library: library, json: args.json)
        return 0

    case "search":
        let query = args.positional.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError.badInput("Usage: capturist search <words…>") }
        if !args.flags.contains("--no-index") { try await library.refreshIndex(verbose: !args.json) }
        let list = try await library.search(query, kind: try args.kind(), limit: try args.limit(default: 20))
        if list.isEmpty { if !args.json { Console.err("Nothing matches '\(query)'.") } else { Console.out("[]") }; return 1 }
        printCaptures(list, library: library, json: args.json)
        return 0

    case "show":
        let capture = try await library.resolve(args.positional.first ?? "latest")
        let text = try await library.text(for: capture)
        let path = library.fileURL(capture)
        if args.json {
            Console.out(Output.encode(Output.json(capture, path: path, text: text)))
        } else {
            Console.out(Output.line(capture))
            Console.out("id:      \(capture.id.uuidString.lowercased())")
            Console.out("created: \(Output.iso.string(from: capture.createdAt))")
            if let title = capture.sourceTitle { Console.out("window:  \(title)") }
            if let url = capture.sourceURL { Console.out("url:     \(url)") }
            if capture.width > 0 { Console.out("size:    \(capture.width)×\(capture.height) px, \(capture.byteSize) bytes") }
            if let share = capture.activeShareURL { Console.out("shared:  \(share.absoluteString)") }
            Console.out("path:    \(path.path)")
            if !text.isEmpty { Console.out("text:\n\(text)") }
        }
        return 0

    case "text":
        let capture = try await library.resolve(args.positional.first ?? "latest")
        let text = try await library.text(for: capture)
        if args.json {
            Console.out(Output.encode(["id": Output.short(capture.id), "text": text]))
        } else {
            Console.out(text)
        }
        return text.isEmpty ? 1 : 0

    case "clips":
        let clips = try await library.context.clips(since: try args.since(), limit: try args.limit(default: 50))
        if clips.isEmpty { if !args.json { Console.err("No clipboard history (is it turned on in Capturist?).") } else { Console.out("[]") }; return 1 }
        if args.json {
            Console.out(Output.encode(clips.map(Output.json)))
        } else {
            for clip in clips {
                Console.out("\(Output.short(clip.id))  \(Output.ago(clip.created))  \(clip.sourceApp ?? "")  \(clip.title)")
            }
        }
        return 0

    case "index":
        let progress = try await library.refreshIndex(force: args.flags.contains("--force"), verbose: !args.json)
        let summary = ["indexed": progress.indexed, "unchanged": progress.skipped, "failed": progress.failed, "removed": progress.removed, "total": library.index.count]
        Console.out(args.json ? Output.encode(summary) : "Indexed \(progress.indexed), unchanged \(progress.skipped), failed \(progress.failed), removed \(progress.removed). \(library.index.count) captures searchable.")
        return 0

    default:
        throw CLIError.badInput("Unknown command '\(args.command ?? "")'. Run `capturist help`.")
    }
}

do {
    let args = try Args(Array(CommandLine.arguments.dropFirst()))
    exit(try await run(args))
} catch let error as CLIError {
    Console.err(error.message)
    exit(error.exitCode)
} catch let error as LookupError {
    Console.err(error.message)
    if case .notFound = error { exit(1) } else { exit(2) }
} catch {
    Console.err("Error: \(error)")
    exit(1)
}
