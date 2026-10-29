import Foundation
import Testing
import ZapaChat

/// The new message kinds (video, document, contact, location) must survive the sealed JSON round trip.
struct ChatContentBodiesTests {
    private let pointer = AttachmentPointer(
        id: "att_1", key: Data([1, 2, 3]), digest: Data([4, 5]), size: 10, mimeType: "video/mp4", duration: 12
    )

    private func roundTrip(_ body: ChatContent.Body) throws -> ChatContent.Body {
        let content = ChatContent(id: "m_1", sentAt: Date(timeIntervalSince1970: 1_700_000_000), body: body)
        return try ChatContent.decode(content.encoded()).body
    }

    @Test func aVideoSurvivesTheRoundTrip() throws {
        #expect(try roundTrip(.video(pointer)) == .video(pointer))
    }

    @Test func aDocumentKeepsItsName() throws {
        #expect(try roundTrip(.document(pointer, name: "contract.pdf")) == .document(pointer, name: "contract.pdf"))
    }

    @Test func aContactKeepsItsNumbersAndEmails() throws {
        let card = ContactCard(name: "Ana Pop", phones: ["+40 721 000 000"], emails: ["ana@example.com"])
        #expect(try roundTrip(.contact(card)) == .contact(card))
    }

    @Test func aLocationKeepsItsCoordinates() throws {
        let place = Location(latitude: 44.4268, longitude: 26.1025)
        #expect(try roundTrip(.location(place)) == .location(place))
    }
}
