import CapturistCore
import CapturistStore
import CapturistMCP
import Foundation

/// Finds and opens a Capturist library (read-only) plus the CLI's own text index.
struct Library {
    enum Which: String { case store, complete, dev, custom }

    let which: Which
    let root: URL
    let store: CaptureStore
    let index: TextIndex

    /// A Capturist edition installed on this Mac, found by its sandbox container.
    struct Installed {
        let which: Which
        let bundleID: String
        let root: URL
    }

    static var containersURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers", isDirectory: true)
    }

    static func root(inContainer container: URL) -> URL {
        container.appendingPathComponent("Data/Library/Application Support/Capturist", isDirectory: true)
    }

    /// Every Capturist library on this Mac. Each edition (App Store, Complete, dev build) is a
    /// sandboxed app with its own container; a container is Capturist's when it holds a Capturist
    /// library. The edition comes from the container name (".complete", ".dev", else App Store).
    static func installed() -> [Installed] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: containersURL.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.lowercased().contains(".capturist") else { return nil }
            let root = root(inContainer: containersURL.appendingPathComponent(name, isDirectory: true))
            guard exists(root) else { return nil }
            let which: Which = name.hasSuffix(".complete") ? .complete : name.hasSuffix(".dev") ? .dev : .store
            return Installed(which: which, bundleID: name, root: root)
        }
    }

    static func exists(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("library.sqlite").path)
    }

    /// `--library store|complete|dev|<path>`, else `CAPTURIST_LIBRARY`, else the library whose app is
    /// running with AI Agents on (it can be relayed to), else the one written to most recently.
    static func locate(_ option: String?) throws -> (Which, URL) {
        let choice = option ?? ProcessInfo.processInfo.environment["CAPTURIST_LIBRARY"]
        let all = installed()
        if let choice {
            if let edition = Which(rawValue: choice), edition != .custom {
                guard let match = all.first(where: { $0.which == edition }) else { throw CLIError.noLibrary }
                return (match.which, match.root)
            }
            return (.custom, URL(fileURLWithPath: (choice as NSString).expandingTildeInPath, isDirectory: true))
        }
        let found = all.map { ($0.which, $0.root) }
        if let live = found.first(where: { AgentEndpoint.read(from: $0.1)?.processIsAlive == true }) {
            return live
        }
        // Several installed (App Store, Complete, dev): use the one written to most recently.
        guard let newest = found.max(by: { lastWrite($0.1) < lastWrite($1.1) }) else { throw CLIError.noLibrary }
        return newest
    }

    static func lastWrite(_ root: URL) -> Date {
        ["library.sqlite", "library.sqlite-wal"].compactMap { name in
            try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.modificationDate] as? Date
        }.max() ?? .distantPast
    }

    static func open(_ option: String?) throws -> Library {
        let (which, root) = try locate(option)
        guard exists(root) else { throw CLIError.noLibraryAt(root.path) }
        let store: CaptureStore
        do {
            store = try CaptureStore(readOnlyRoot: root)
        } catch {
            throw CLIError.noAccess(root.path, String(describing: error))
        }
        let name = which == .custom ? "custom-\(stableHash(root.path))" : which.rawValue
        let index = try TextIndex(path: indexDirectory.appendingPathComponent("index-\(name).sqlite"))
        return Library(which: which, root: root, store: store, index: index)
    }

    /// FNV-1a: stable across runs (Swift's hashValue isn't).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    static var indexDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".capturist", isDirectory: true)
    }

    var context: CaptureContext { CaptureContext(store: store, index: index) }

    func fileURL(_ capture: Capture) -> URL { store.fileURL(for: capture) }

    @discardableResult
    func refreshIndex(force: Bool = false, verbose: Bool = false) async throws -> TextIndex.Progress {
        try await context.refreshIndex(force: force) { capture in
            if verbose { Console.err("Reading text: \(capture.displayName)") }
        }
    }

    func resolve(_ reference: String) async throws -> Capture { try await context.resolve(reference) }
    func text(for capture: Capture) async throws -> String { try await context.text(for: capture) }
    func search(_ query: String, kind: CaptureKind?, limit: Int) async throws -> [Capture] {
        try await context.search(query, kind: kind, limit: limit)
    }
}

enum CLIError: Error {
    case noLibrary
    case noLibraryAt(String)
    case noAccess(String, String)
    case notFound(String)
    case badInput(String)

    var exitCode: Int32 {
        switch self {
        case .notFound: return 1
        case .badInput: return 2
        case .noLibrary, .noLibraryAt, .noAccess: return 3
        }
    }

    var message: String {
        switch self {
        case .noLibrary:
            return "No Capturist library found. Is Capturist installed and opened at least once? Try --library dev for the dev build."
        case .noLibraryAt(let path):
            return "No Capturist library at \(path)."
        case .noAccess(let path, let detail):
            return "Can't read the Capturist library at \(path) (\(detail)). If macOS asked to allow access to data from other apps, allow it, or grant this terminal Full Disk Access."
        case .notFound(let ref):
            return "No capture matches '\(ref)'. Try `capturist recent`."
        case .badInput(let text):
            return text
        }
    }
}

enum Console {
    static func out(_ text: String) { print(text) }
    static func err(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}
