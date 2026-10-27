import Foundation
import Testing
@testable import ZapaChat

/// What goes inside a sealed message, attachment encryption and the encrypted store on the phone.
struct ChatCryptoTests {
    @Test func contentRoundTripsForTextImageAndVoice() throws {
        let attachment = AttachmentPointer(
            id: "a_1", key: Data(repeating: 7, count: 32), digest: Data(repeating: 9, count: 32), size: 10,
            mimeType: "image/jpeg", duration: nil
        )
        for content in [
            ChatContent(id: "m1", sentAt: Date(timeIntervalSince1970: 1000), body: .text("Salut!")),
            ChatContent(id: "m2", sentAt: Date(timeIntervalSince1970: 1000), body: .image(attachment)),
            ChatContent(id: "m3", sentAt: Date(timeIntervalSince1970: 1000), body: .voice(attachment)),
            ChatContent(id: "m4", sentAt: Date(timeIntervalSince1970: 1000), body: .call(callId: "call-1")),
        ] {
            #expect(try ChatContent.decode(content.encoded()) == content)
        }
    }

    @Test func unknownContentVersionsAreRefused() {
        #expect(throws: (any Error).self) { try ChatContent.decode(Data(#"{"v":99,"id":"m","sentAt":0}"#.utf8)) }
    }

    @Test func textIsCappedAt4000Characters() {
        #expect(ChatContent.isValidText(String(repeating: "a", count: 4000)))
        #expect(!ChatContent.isValidText(String(repeating: "a", count: 4001)))
        #expect(!ChatContent.isValidText("   \n "))
    }

    @Test func attachmentsRoundTripAndTamperingFails() throws {
        let plain = Data((0 ..< 5000).map { UInt8($0 % 251) })

        let sealed = try AttachmentCrypto.encrypt(plain)
        let opened = try AttachmentCrypto.decrypt(sealed.ciphertext, key: sealed.key, digest: sealed.digest)

        #expect(opened == plain)
        #expect(sealed.ciphertext.range(of: plain.prefix(64)) == nil)
        var tampered = sealed.ciphertext
        tampered[tampered.startIndex + 20] ^= 1
        #expect(throws: (any Error).self) {
            try AttachmentCrypto.decrypt(tampered, key: sealed.key, digest: sealed.digest)
        }
    }

    @Test func theStoreKeepsMessagesEncryptedOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 3, count: 32)
        let store = try EncryptedChatStore(directory: directory, key: key)
        let message = ChatMessage(
            id: "m1", conversationId: "c_1", senderAccountId: "acc-m", isMine: true,
            content: ChatContent(id: "m1", sentAt: Date(timeIntervalSince1970: 5), body: .text("secret pancakes")),
            status: .sent
        )

        try await store.save([message], in: "c_1")
        let reopened = try EncryptedChatStore(directory: directory, key: key)
        let loaded = try await reopened.messages(in: "c_1")

        #expect(loaded == [message])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let raw = try Data(contentsOf: file)
            #expect(raw.range(of: Data("secret pancakes".utf8)) == nil)
            #expect(raw.range(of: Data("c_1".utf8)) == nil, "file names and contents don't show the conversation")
        }
        let wrongKey = try EncryptedChatStore(directory: directory, key: Data(repeating: 4, count: 32))
        #expect(try await wrongKey.messages(in: "c_1").isEmpty, "another key can't find or read the history")
    }

    @Test func deletingAConversationRemovesItsFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try EncryptedChatStore(directory: directory, key: Data(repeating: 3, count: 32))
        try await store.save([], in: "c_1")

        try await store.delete("c_1")

        #expect(try await store.messages(in: "c_1").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
