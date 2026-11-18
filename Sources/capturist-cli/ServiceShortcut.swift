import CapturistCore
import Foundation

/// `capturist setup shortcut`: gives the "Send to Capturist" service a keyboard shortcut
/// (default ⌥⌘7), so selected text in any app that supports Services is saved with one key.
/// The app is sandboxed and can't change system shortcuts; this command (outside the sandbox) can.
enum ServiceShortcut {
    static let defaultKey = "⌥⌘7"
    static let message = "sendToCapturist"
    static var domain: CFString { "pbs" as CFString }
    static var statusKey: CFString { "NSServicesStatus" as CFString }

    /// Each installed Capturist edition registers its own service ("Send to Capturist[ Complete]").
    static var services: [(which: Library.Which, bundle: String, title: String)] {
        Library.installed().map { edition in
            (edition.which, edition.bundleID, edition.which == .complete ? "Send to Capturist Complete" : "Send to Capturist")
        }
    }

    static func entryKey(bundle: String, title: String) -> String { "\(bundle) - \(title) - \(message)" }

    static func run(_ args: Args, remove: Bool, yes: Bool) throws -> Int32 {
        var status = readStatus()
        if remove {
            for service in services { clearKey(in: &status, entry: entryKey(bundle: service.bundle, title: service.title)) }
            writeStatus(status)
            Console.out("Removed the Capturist text shortcut.")
            return 0
        }

        let display = args.options["--key"] ?? defaultKey
        guard let pbsKey = ServiceKey.pbs(from: display) else {
            throw CLIError.badInput("--key needs ⌘ plus one key, e.g. \"⌥⌘7\" (Services shortcuts always include ⌘).")
        }
        let target = try pickService(args.options["--app"])
        let label = ServiceKey.display(fromPBS: pbsKey) ?? display
        guard Setup.confirm(["set \(label) for \"\(target.title)\" (System Settings › Keyboard Shortcuts › Services)"], yes: yes) else { return 2 }

        // One key, one service: take it off the other Capturist editions (and off anything else using it).
        for (entry, value) in status {
            if let dict = value as? [String: Any], dict["key_equivalent"] as? String == pbsKey { clearKey(in: &status, entry: entry) }
        }
        let entry = entryKey(bundle: target.bundle, title: target.title)
        var dict = status[entry] as? [String: Any] ?? [:]
        dict["key_equivalent"] = pbsKey
        dict["enabled_context_menu"] = true
        dict["enabled_services_menu"] = true
        dict["presentation_modes"] = ["ContextMenu": true, "ServicesMenu": true]
        status[entry] = dict
        writeStatus(status)
        Console.out("\(label) now saves selected text to \(target.title.replacingOccurrences(of: "Send to ", with: "")).")
        Console.out("Select text in Safari, Mail, Notes, Chrome… and press \(label). (Apps without Services, like Terminal or VS Code, can't.)")
        return 0
    }

    /// `--app store|complete|dev`, else the edition whose library is in use (running app first).
    static func pickService(_ option: String?) throws -> (which: Library.Which, bundle: String, title: String) {
        let available = services
        guard let first = available.first else {
            throw CLIError.badInput("No Capturist found on this Mac. Install Capturist and open it once.")
        }
        if let option {
            guard ["store", "complete", "dev"].contains(option) else { throw CLIError.badInput("--app must be store, complete or dev") }
            guard let match = available.first(where: { $0.which.rawValue == option }) else {
                throw CLIError.badInput("That Capturist (\(option)) isn't installed, or hasn't been opened yet.")
            }
            return match
        }
        let which = (try? Library.locate(nil).0) ?? first.which
        return available.first { $0.which == which } ?? first
    }

    static func currentSummary() -> String {
        let status = readStatus()
        for service in services {
            if let dict = status[entryKey(bundle: service.bundle, title: service.title)] as? [String: Any],
               let key = dict["key_equivalent"] as? String, !key.isEmpty {
                return "\(ServiceKey.display(fromPBS: key) ?? key) → \(service.title)"
            }
        }
        return "—"
    }

    // MARK: pbs preferences

    static func readStatus() -> [String: Any] {
        CFPreferencesCopyAppValue(statusKey, domain) as? [String: Any] ?? [:]
    }

    static func writeStatus(_ status: [String: Any]) {
        CFPreferencesSetAppValue(statusKey, status as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        // Tell the services daemon to reload, so the key works without logging out.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        process.arguments = ["-update"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func clearKey(in status: inout [String: Any], entry: String) {
        guard var dict = status[entry] as? [String: Any] else { return }
        dict["key_equivalent"] = ""
        status[entry] = dict
    }
}
