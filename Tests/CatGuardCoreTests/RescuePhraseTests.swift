import Testing

@testable import CatGuardCore

@Test("Rescue phrases are normalized before use")
func rescuePhrasesAreNormalized() {
    #expect(RescuePhrase("  CatGuard\n")?.value == "catguard")
}

@Test(
    "Rescue phrases reject values that cannot be typed by the matcher",
    arguments: ["", "cat", "cat guard", "cat1234", "cätguard", String(repeating: "a", count: 33)]
)
func rescuePhrasesRejectInvalidValues(candidate: String) {
    #expect(RescuePhrase(candidate) == nil)
}
