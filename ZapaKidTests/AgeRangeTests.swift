import Testing
@testable import ZapaKidKit

struct AgeRangeTests {
    @Test(arguments: [
        (AgeRange.shared(lower: 18, upper: nil, platformStatus: nil), false),
        (AgeRange.shared(lower: nil, upper: 17, platformStatus: nil), true),
        (AgeRange.shared(lower: 13, upper: 15, platformStatus: nil), true),
        (AgeRange.shared(lower: 16, upper: nil, platformStatus: nil), true), // "16 and up" doesn't show 18+
        (AgeRange.shared(lower: 18, upper: 18, platformStatus: nil), false),
        (AgeRange.declined(platformStatus: nil), false),
        (AgeRange.unavailable, false),
    ])
    func notAnAdultOnlyWhenASharedRangeDoesNotShow18Plus(range: AgeRange, notAdult: Bool) {
        #expect(range.isMinor == notAdult)
    }
}

struct SignInNonceTests {
    @Test func hashIsLowercaseHexSHA256OfTheRawNonce() {
        #expect(SignInNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
