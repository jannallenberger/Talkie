import XCTest

/// Every UI string has a translation in all ten catalogs, and each translation
/// keeps the English key's format specifiers. A missing key silently renders
/// English on that locale, so this is the guard that German (and the rest) stay
/// complete when new copy lands.
final class LocalizationCatalogParityTests: XCTestCase {
    static let locales = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "zh-Hans"]

    static func catalog(_ locale: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/Localizations/\(locale).lproj/Localizable.strings")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "\(locale) catalog did not parse")
        return dict
    }

    func testEveryCatalogHasEveryEnglishKey() throws {
        let en = try Self.catalog("en")
        XCTAssertGreaterThan(en.count, 1000)
        for locale in Self.locales.dropFirst() {
            let other = try Self.catalog(locale)
            let missing = Set(en.keys).subtracting(other.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(locale) is missing \(missing.count): \(missing.prefix(5))")
            let empty = other.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty && !(en[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            XCTAssertTrue(empty.isEmpty, "\(locale) has empty values: \(empty.keys.prefix(5))")
        }
    }

    func testTranslationsKeepFormatSpecifiers() throws {
        let rx = try NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:lld|ld|d|@|\\.1f|f|%)")
        func specs(_ s: String) -> [String] {
            rx.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]) }
                .map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
                .sorted()
        }
        let en = try Self.catalog("en")
        for locale in Self.locales.dropFirst() {
            let other = try Self.catalog(locale)
            for (key, value) in other where en[key] != nil {
                XCTAssertEqual(specs(key), specs(value), "\(locale): \(key)")
            }
        }
    }

    func testWebsiteLinkLabelIsTranslated() throws {
        for locale in Self.locales.dropFirst() {
            XCTAssertNotNil(try Self.catalog(locale)["See the latest version"], locale)
        }
    }
}
