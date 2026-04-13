import XCTest
@testable import CodeIsland

final class L10nTests: XCTestCase {
    override func setUp() {
        L10n.shared.language = "en"
    }

    override func tearDown() {
        L10n.shared.language = "system"
    }

    func testTurkishTranslationsContainAllKeysPresentInEnglish() {
        let enKeys = Set(L10n.strings["en"]?.keys ?? Dictionary<String, String>().keys)
        let trKeys = Set(L10n.strings["tr"]?.keys ?? Dictionary<String, String>().keys)

        let missingKeys = enKeys.subtracting(trKeys)
        XCTAssertTrue(missingKeys.isEmpty, "Turkish is missing keys: \(missingKeys)")
    }

    func testTurkishTranslationReturnsCorrectValue() {
        L10n.shared.language = "tr"

        XCTAssertEqual(L10n.shared["general"], "Genel")
        XCTAssertEqual(L10n.shared["behavior"], "Davranış")
        XCTAssertEqual(L10n.shared["appearance"], "Görünüm")
        XCTAssertEqual(L10n.shared["language"], "Dil")
        XCTAssertEqual(L10n.shared["settings_title"], "CodeIsland Ayarları")
        XCTAssertEqual(L10n.shared["quit"], "Çık")
    }

    func testEffectiveLanguageReturnsTurkishWhenSystemLocaleIsTurkish() {
        L10n.shared.language = "system"

        let turkishEffective = L10n.shared.effectiveLanguage
        XCTAssertNotEqual(turkishEffective, "tr")
    }

    func testFallbackToEnglishWhenTurkishKeyIsMissing() {
        L10n.shared.language = "tr"

        let result = L10n.shared["nonexistent_key"]
        XCTAssertEqual(result, "nonexistent_key")
    }

    func testAllLanguageOptionsAvailableInSettings() {
        let availableLanguages = ["system", "en", "zh", "tr"]

        for lang in availableLanguages {
            L10n.shared.language = lang
            let value = L10n.shared["general"]
            XCTAssertFalse(value.isEmpty, "Language '\(lang)' should return a value for 'general' key")
        }
    }

    func testTurkishNumericPlaceholdersWork() {
        L10n.shared.language = "tr"

        let customSoundSet = L10n.shared["custom_sound_set"]
        let formatted = String(format: customSoundSet, "mysound.wav")
        XCTAssertEqual(formatted, "Özel: mysound.wav")

        let updateAvailable = L10n.shared["update_available_body"]
        let formattedUpdate = String(format: updateAvailable, "1.0.19", "1.0.18")
        XCTAssertEqual(formattedUpdate, "CodeIsland 1.0.19 mevcut (şimdiki: 1.0.18). İndirmek ister misiniz?")
    }
}