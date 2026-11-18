import Foundation

/// Key equivalents for macOS Services, as stored in the `pbs` preferences (NSServicesStatus):
/// `@` ⌘, `~` ⌥, `^` ⌃, `$` ⇧, then the key (lowercase). "⌥⌘7" ⇄ "@~7".
public enum ServiceKey {
    private static let symbols: [(display: Character, pbs: Character)] = [("⌃", "^"), ("⌥", "~"), ("⇧", "$"), ("⌘", "@")]

    /// "⌥⌘7" → "@~7". Needs ⌘ (Services ignore keys without it) and exactly one key.
    public static func pbs(from display: String) -> String? {
        var modifiers = Set<Character>()
        var key = ""
        for character in display.replacingOccurrences(of: " ", with: "") {
            if let match = symbols.first(where: { $0.display == character }) {
                modifiers.insert(match.pbs)
            } else {
                key.append(character)
            }
        }
        guard modifiers.contains("@"), key.count == 1 else { return nil }
        let ordered = ["@", "~", "^", "$"].filter { modifiers.contains(Character($0)) }.joined()
        return ordered + key.lowercased()
    }

    /// "@~7" → "⌥⌘7" (macOS display order ⌃⌥⇧⌘).
    public static func display(fromPBS value: String) -> String? {
        guard let key = value.last, value.count >= 2 else { return nil }
        let modifiers = Set(value.dropLast())
        let text = symbols.filter { modifiers.contains($0.pbs) }.map { String($0.display) }.joined()
        return text + String(key).uppercased()
    }
}
