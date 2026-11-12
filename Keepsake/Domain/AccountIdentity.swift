import Foundation

struct AccountID: Hashable, Codable, Sendable {
    let rawValue: UUID
}

struct GroupID: Hashable, Codable, Sendable {
    let rawValue: UUID
}

struct AccountIdentity: Equatable, Sendable {
    let id: AccountID
    let email: String?
}

struct AccountContext: Equatable, Sendable {
    let accountID: AccountID
    let generation: UUID
}

struct SoloGroup: Identifiable, Equatable, Sendable {
    let id: GroupID
    let ownerID: AccountID
    let name: String
    let createdAt: Date
}

struct GroupCreateIntent: Equatable, Sendable {
    let operationID: UUID
    let normalizedName: String
}

enum GroupNameInput {
    static func normalize(_ raw: String) -> String? {
        guard raw.utf8.count <= 4_096 else { return nil }
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " "))
            .precomposedStringWithCanonicalMapping
        guard !name.isEmpty,
              name.unicodeScalars.count <= 80,
              name.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return name
    }
}
