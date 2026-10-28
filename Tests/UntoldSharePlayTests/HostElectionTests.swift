import Foundation
@testable import UntoldSharePlay
import XCTest

final class HostElectionTests: XCTestCase {
    func testNoneElectsNobody() {
        XCTAssertNil(HostElection.none.elect(among: [participantID(1), participantID(2)]))
    }

    func testLowestIDWinsAndIsRecomputedOnLeave() {
        let one = participantID(1), two = participantID(2), three = participantID(3)
        XCTAssertEqual(HostElection.lowestParticipantID.elect(among: [three, one, two]), one)
        XCTAssertEqual(HostElection.lowestParticipantID.elect(among: [three, two]), two)
        XCTAssertNil(HostElection.lowestParticipantID.elect(among: []))
    }

    func testLowestIDComparesStrings() throws {
        // Oche's rule compares the id strings, as every device must agree.
        let a = try XCTUnwrap(UUID(uuidString: "A0000000-0000-0000-0000-000000000000"))
        let b = try XCTUnwrap(UUID(uuidString: "90000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(HostElection.lowestParticipantID.elect(among: [a, b]), b)
    }
}
