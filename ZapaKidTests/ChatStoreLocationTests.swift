import Foundation
import Testing
@testable import ZapaKid

/// Review (gemini-zpc, ios #53): ending a kid session wipes only the kid's chat store, never a parent's history on
/// the same phone.
@MainActor
struct ChatStoreLocationTests {
    @Test func aParentKeepsTheExistingStoreAndAKidGetsItsOwn() {
        let root = URL(fileURLWithPath: "/tmp/zk")
        #expect(ChatStoreLocation.directory(accountId: "ana", kid: false, root: root).lastPathComponent == "chats")
        #expect(ChatStoreLocation.keychainAccount(accountId: "ana", kid: false) == "key")
        let kidDirectory = ChatStoreLocation.directory(accountId: "k1", kid: true, root: root)
        #expect(kidDirectory.lastPathComponent == "chats-kid-k1")
        #expect(ChatStoreLocation.keychainAccount(accountId: "k1", kid: true) == "key-kid-k1")
    }

    @Test func wipingAKidLeavesTheParentsChats() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chat-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = ChatStoreLocation.directory(accountId: "ana", kid: false, root: root)
        let kid = ChatStoreLocation.directory(accountId: "k1", kid: true, root: root)
        for directory in [parent, kid] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appending(path: "m"))
        }
        var cleared: [String] = []

        ChatStoreLocation.wipeKid(accountId: "k1", root: root) { cleared.append($0) }

        #expect(FileManager.default.fileExists(atPath: parent.appending(path: "m").path))
        #expect(!FileManager.default.fileExists(atPath: kid.path))
        #expect(cleared == ["key-kid-k1"])
    }
}
