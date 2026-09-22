import Foundation

enum DownloadTags {
    nonisolated static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    nonisolated static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
            guard !name.isEmpty,
                  name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !name.contains("#"), !name.contains(","),
                  seen.insert(key(name)).inserted else { return nil }
            return name
        }
    }

    nonisolated static func matches(_ tags: [String], selected: Set<String>, matchAll: Bool) -> Bool {
        guard !selected.isEmpty else { return true }
        let keys = Set(tags.map(key))
        return matchAll ? selected.isSubset(of: keys) : !selected.isDisjoint(with: keys)
    }
}
