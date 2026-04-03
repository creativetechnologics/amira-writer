import Foundation

enum ObjectAttachmentTargetKind: String, Codable, Sendable, Hashable, CaseIterable {
    case character
    case object
    case world
}

struct ObjectAttachmentReference: Codable, Sendable, Hashable {
    var kind: ObjectAttachmentTargetKind
    var targetName: String
    var anchor: String?

    init(
        kind: ObjectAttachmentTargetKind,
        targetName: String,
        anchor: String? = nil
    ) {
        self.kind = kind
        self.targetName = targetName
        self.anchor = anchor
    }

    var encodedString: String {
        var components = [kind.rawValue, targetName]
        if let anchor, !anchor.isEmpty {
            components.append(anchor)
        }
        return components.joined(separator: ":")
    }

    static func parse(_ raw: String?) -> ObjectAttachmentReference? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if isClearDirective(raw) {
            return nil
        }

        let parts = raw
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let first = parts.first, !first.isEmpty else { return nil }
        let normalizedFirst = first.lowercased()

        if let kind = ObjectAttachmentTargetKind(rawValue: normalizedFirst) {
            guard parts.count >= 2 else { return nil }
            let targetName = parts[1]
            guard !targetName.isEmpty else { return nil }
            let anchor = parts.count >= 3 ? parts[2] : nil
            return ObjectAttachmentReference(kind: kind, targetName: targetName, anchor: anchor?.isEmpty == true ? nil : anchor)
        }

        // Legacy / compact form: bare value means "attach to character".
        return ObjectAttachmentReference(kind: .character, targetName: raw, anchor: nil)
    }

    static func isClearDirective(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return false
        }
        return raw == "none" || raw == "clear" || raw == "detach" || raw == "detached"
    }
}
