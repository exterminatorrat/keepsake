import Foundation
import Testing
@testable import Keepsake

struct AuthInputTests {
    @Test(arguments: [
        ("harry@example.com", "harry@example.com"),
        ("  harry@example.com \n", "harry@example.com"),
        ("harry.jin+keepsake@mail.example.co", "harry.jin+keepsake@mail.example.co"),
        ("HARRY@EXAMPLE.COM", "HARRY@EXAMPLE.COM"),
        ("harry@sub.example.com", "harry@sub.example.com")
    ])
    func normalizesSensibleEmail(_ raw: String, _ expected: String) {
        #expect(AuthInput.normalizedEmail(raw) == expected)
    }

    @Test(arguments: [
        "",
        "   \n",
        "harry",
        "harry@",
        "@example.com",
        "harry@@example.com",
        "harry@example@com",
        "harry@example",
        "harry@.example.com",
        "harry@example.com.",
        "harry@exa..mple.com",
        "har ry@example.com",
        "harry@exa mple.com",
        "harry@example.com\u{0007}"
    ])
    func rejectsMalformedEmail(_ raw: String) {
        #expect(AuthInput.normalizedEmail(raw) == nil)
    }

    @Test func boundsEmailLength() {
        let overlongLocalPart = String(repeating: "a", count: 65)
        #expect(AuthInput.normalizedEmail("\(overlongLocalPart)@example.com") == nil)

        let overlongDomain = String(repeating: "a", count: 300)
        #expect(AuthInput.normalizedEmail("harry@\(overlongDomain).com") == nil)

        let longestLocalPart = String(repeating: "a", count: 64)
        #expect(AuthInput.normalizedEmail("\(longestLocalPart)@example.com") == "\(longestLocalPart)@example.com")
    }

    @Test(arguments: ["123456", "000000", " 123456\n", "\t654321 "])
    func normalizesSixDigitCode(_ raw: String) {
        #expect(AuthInput.normalizedCode(raw) == raw.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(AuthInput.normalizedCode(raw)?.count == 6)
    }

    @Test(arguments: [
        "",
        "   ",
        "12345",
        "1234567",
        "12345a",
        "12 3456",
        "123-456",
        "+12345",
        "١٢٣٤٥٦",
        "１２３４５６",
        "123456\n7"
    ])
    func rejectsMalformedCode(_ raw: String) {
        #expect(AuthInput.normalizedCode(raw) == nil)
    }

    @Test func boundsCodeLength() {
        #expect(AuthInput.normalizedCode(String(repeating: "1", count: 1_024)) == nil)
    }
}
