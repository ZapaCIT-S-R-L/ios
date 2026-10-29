import Testing
@testable import ZapaKid

/// Archived chats are kept per phone as a comma-separated id list.
struct ArchivedChatsTests {
    @Test func theIdsSurviveARoundTrip() {
        let ids: Set<String> = ["c_2", "c_1"]

        #expect(ArchivedChats.decode(ArchivedChats.encode(ids)) == ids)
    }

    @Test func anEmptyStoreMeansNothingIsArchived() {
        #expect(ArchivedChats.decode("").isEmpty)
    }
}
