import Foundation

/// Pure helpers for adding/removing an MCP server entry in AI agents' config files.
/// The CLI does the file I/O (backups, refusing unreadable files); this only transforms content.
public enum AgentConfig {
    public enum ConfigError: Error, Equatable {
        case notAnObject(String)        // a key on the path exists but isn't an object
        case unsupportedYAML(String)    // YAML we won't edit by hand (flow style, tabs…)
    }

    // MARK: JSON

    /// Returns `config` with `path…[name] = entry` (or removed when `entry` is nil), creating objects on the way.
    public static func setJSON(_ config: [String: Any], path: [String], name: String, entry: Any?) throws -> [String: Any] {
        guard let first = path.first else {
            var copy = config
            copy[name] = entry
            return copy
        }
        var copy = config
        let child: [String: Any]
        switch config[first] {
        case nil: child = [:]
        case let object as [String: Any]: child = object
        default: throw ConfigError.notAnObject(first)
        }
        if entry == nil, config[first] == nil { return config }
        copy[first] = try setJSON(child, path: Array(path.dropFirst()), name: name, entry: entry)
        return copy
    }

    public static func hasJSON(_ config: [String: Any], path: [String], name: String) -> Bool {
        var node: Any = config
        for key in path {
            guard let object = node as? [String: Any], let next = object[key] else { return false }
            node = next
        }
        return (node as? [String: Any])?[name] != nil
    }

    // MARK: YAML (block style only, e.g. Hermes ~/.hermes/config.yaml)

    /// Adds `name:` with `fields` under the top-level `section:` mapping, replacing an existing entry of that name.
    /// `fields` are already-rendered YAML lines without indentation (e.g. `command: "/x"`).
    public static func setYAML(_ text: String, section: String, name: String, fields: [String]?) throws -> String {
        if text.contains("\t") { throw ConfigError.unsupportedYAML("tabs") }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let header = lines.firstIndex { $0.hasPrefix("\(section):") }
        if let header, lines[header].trimmingCharacters(in: .whitespaces) != "\(section):" {
            let rest = lines[header].dropFirst(section.count + 1).trimmingCharacters(in: .whitespaces)
            if !(rest.isEmpty || rest.hasPrefix("#")) {
                // `mcp_servers: {}` is fine to replace when we're adding; anything else is flow style we won't touch.
                if rest == "{}" { lines[header] = "\(section):" } else { throw ConfigError.unsupportedYAML("\(section) is not a block mapping") }
            }
        }

        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func isContent(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }

        guard let header else {
            guard let fields else { return text }
            var out = lines
            out.append("\(section):")
            out.append("  \(name):")
            out += fields.map { "    \($0)" }
            return out.joined(separator: "\n") + "\n"
        }

        // End of the section = next content line at indent 0.
        var end = header + 1
        while end < lines.count, !(isContent(lines[end]) && indent(lines[end]) == 0) { end += 1 }
        let childIndent = (header + 1..<end).first { isContent(lines[$0]) }.map { indent(lines[$0]) } ?? 2
        let pad = String(repeating: " ", count: childIndent)

        // Remove the existing entry, if any.
        if let start = (header + 1..<end).first(where: { lines[$0] == "\(pad)\(name):" || lines[$0].hasPrefix("\(pad)\(name): ") }) {
            var stop = start + 1
            while stop < end, !(isContent(lines[stop]) && indent(lines[stop]) <= childIndent) { stop += 1 }
            // Keep trailing blank/comment lines that belong to what follows.
            while stop - 1 > start, !isContent(lines[stop - 1]) { stop -= 1 }
            lines.removeSubrange(start..<stop)
            end -= stop - start
        }
        if let fields {
            let block = ["\(pad)\(name):"] + fields.map { "\(pad)  \($0)" }
            // Insert after the last content line of the section.
            var at = end
            while at - 1 > header, !isContent(lines[at - 1]) { at -= 1 }
            lines.insert(contentsOf: block, at: at)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func hasYAML(_ text: String, section: String, name: String) -> Bool {
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("\(section):") { inSection = true; continue }
            if inSection, let c = line.first, c != " ", c != "#" { inSection = false }
            if inSection, line.trimmingCharacters(in: .whitespaces) == "\(name):", line.hasPrefix(" ") { return true }
        }
        return false
    }

    /// Double-quoted YAML scalar.
    public static func yamlQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
