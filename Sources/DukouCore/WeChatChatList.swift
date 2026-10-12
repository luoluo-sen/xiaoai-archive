import Foundation

/// A snapshot of the conversation rows exposed by one WeChat window.
/// The list location does not establish whether a row is a group chat.
public struct WeChatChatList: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case conversations
        case folded
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        /// Unique within this snapshot, including rows with the same name.
        /// This is not a persistent WeChat conversation identifier.
        public let id: String
        public let name: String
        public let isConfirmedGroup: Bool
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case missingName
        case unexpectedRow
    }

    public let scope: Scope
    public let entries: [Entry]

    public var confirmedGroupCount: Int {
        entries.filter(\.isConfirmedGroup).count
    }

    public var unverifiedCount: Int {
        entries.count - confirmedGroupCount
    }

    /// Identifiers must come from the session list, rather than the app's
    /// entire accessibility tree. A separate current-chat member count label
    /// confirms only an unambiguous exact name match in this snapshot.
    public static func make(
        scope: Scope,
        identifiers: [String],
        currentChatName: String?,
        currentChatMemberCount: String?
    ) throws -> Self {
        let prefix = "session_item_"
        var names: [(id: String, name: String)] = []
        for (offset, identifier) in identifiers.enumerated() {
            guard identifier.hasPrefix(prefix) else { throw Error.unexpectedRow }
            let name = String(identifier.dropFirst(prefix.count))
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.missingName
            }
            names.append((id: "\(offset):\(identifier)", name: name))
        }

        let matchingCount = names.filter { $0.name == currentChatName }.count
        let canConfirm = matchingCount == 1 && isMemberCountLabel(currentChatMemberCount)
        return Self(scope: scope, entries: names.map { row in
            Entry(id: row.id, name: row.name,
                  isConfirmedGroup: canConfirm && row.name == currentChatName)
        })
    }

    private static func isMemberCountLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "(", value.last == ")" else { return false }
        let digits = value.dropFirst().dropLast()
        guard !digits.isEmpty,
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(digits), count > 0 else { return false }
        return true
    }
}
