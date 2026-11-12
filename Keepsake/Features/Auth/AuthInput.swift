import Foundation

enum AuthInput {
    private static let maximumRawByteCount = 4_096
    private static let maximumEmailByteCount = 254
    private static let maximumLocalPartByteCount = 64
    private static let maximumCodeByteCount = 64

    static func normalizedEmail(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumRawByteCount else { return nil }

        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.utf8.count <= maximumEmailByteCount else { return nil }
        guard !email.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else {
            return nil
        }

        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let localPart = String(parts[0])
        let domain = String(parts[1])
        guard !localPart.isEmpty, localPart.utf8.count <= maximumLocalPartByteCount else { return nil }
        guard !domain.isEmpty,
              domain.contains("."),
              !domain.hasPrefix("."),
              !domain.hasSuffix("."),
              !domain.contains("..") else {
            return nil
        }

        return email
    }

    static func normalizedCode(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumCodeByteCount else { return nil }

        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count == 6,
              code.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }

        return code
    }
}
