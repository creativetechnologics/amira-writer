import Foundation

public extension String {
    /// Returns nil if the string is empty after trimming whitespace and newlines.
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    /// True if the string is empty or contains only whitespace/newlines.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Convenience: `!isBlank`.
    var isPopulated: Bool {
        !isBlank
    }
}
