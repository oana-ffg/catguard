import Testing
@testable import CatGuardCore

@Suite("Physical key letter map")
struct PhysicalKeyLetterMapTests {
    @Test("Maps every ANSI letter position")
    func mapsEveryLetter() {
        let keyCodes: [Int64] = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
            45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        ]

        let letters = keyCodes.compactMap(PhysicalKeyLetterMap.letter)

        #expect(String(letters) == "abcdefghijklmnopqrstuvwxyz")
    }

    @Test("Ignores non-letter keys", arguments: [Int64(36), 48, 49, 51, 53, 123])
    func ignoresNonLetters(keyCode: Int64) {
        #expect(PhysicalKeyLetterMap.letter(forMacVirtualKeyCode: keyCode) == nil)
    }
}
