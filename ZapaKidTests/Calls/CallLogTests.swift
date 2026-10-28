import Foundation
import Testing
@testable import ZapaCalls

/// The call log: newest first, missed calls marked, metadata only (no audio, ever).
struct CallLogTests {
    let mama = CallPeer(accountId: "acc-m", deviceId: "dev-m", displayName: "Mama", avatar: "robot-1", role: .parent)

    @Test func endedCallsBecomeLogEntriesNewestFirst() async {
        let log = InMemoryCallLog()
        let start = Date(timeIntervalSince1970: 1000)

        await log.record(CallLogEntry(
            id: "c_1", peers: [mama], direction: .outgoing, startedAt: start, duration: 65, outcome: .answered
        ))
        await log.record(CallLogEntry(
            id: "c_2", peers: [mama], direction: .incoming, startedAt: start + 100, duration: 0, outcome: .missed
        ))

        let entries = await log.entries()
        #expect(entries.map(\.id) == ["c_2", "c_1"])
        #expect(entries.first?.isMissed == true)
    }

    @Test func outcomesFollowHowTheCallEnded() {
        #expect(CallLogEntry.Outcome(endReason: .missed, wasConnected: false) == .missed)
        #expect(CallLogEntry.Outcome(endReason: .noAnswer, wasConnected: false) == .noAnswer)
        #expect(CallLogEntry.Outcome(endReason: .declined, wasConnected: false) == .declined)
        #expect(CallLogEntry.Outcome(endReason: .hungUp, wasConnected: true) == .answered)
        #expect(CallLogEntry.Outcome(endReason: .hungUp, wasConnected: false) == .cancelled)
    }

    @Test func avatarsAreOneOfTwelveRobots() {
        #expect(RobotAvatarStyle(avatar: "robot-3").index == 3)
        #expect(RobotAvatarStyle(avatar: "robot-99").index == 1, "unknown avatars fall back to robot 1")
        #expect(RobotAvatarStyle(avatar: "").index == 1)
        #expect(RobotAvatarStyle.all.count == 12)
    }
}
