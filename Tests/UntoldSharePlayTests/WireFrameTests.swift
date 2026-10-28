import Foundation
@testable import UntoldSharePlay
import XCTest

final class WireFrameTests: XCTestCase {
    func testRoundTrip() throws {
        let frame = WireFrame(kind: .event, channelID: "poses/ñ", sequence: 4_000_000_000, sentUptime: 1234.5678, payload: Data([1, 2, 3, 250]))
        let decoded = try WireFrame.decode(frame.encoded())
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(frame.encoded().count, 16 + "poses/ñ".utf8.count + 4)
    }

    func testEmptyChannelAndPayload() throws {
        let frame = WireFrame(kind: .state, channelID: "", sequence: 0, sentUptime: 0, payload: Data())
        XCTAssertEqual(try WireFrame.decode(frame.encoded()), frame)
    }

    func testRejectsShortAndForeignData() {
        XCTAssertThrowsError(try WireFrame.decode(Data([1, 0, 0]))) { error in
            XCTAssertEqual(error as? WireFrame.DecodingError, .tooShort)
        }
        var foreign = WireFrame(kind: .state, channelID: "a", sequence: 1, sentUptime: 0, payload: Data()).encoded()
        foreign[0] = 9
        XCTAssertThrowsError(try WireFrame.decode(foreign)) { error in
            XCTAssertEqual(error as? WireFrame.DecodingError, .unsupportedVersion(9))
        }
        var badKind = WireFrame(kind: .state, channelID: "a", sequence: 1, sentUptime: 0, payload: Data()).encoded()
        badKind[1] = 7
        XCTAssertThrowsError(try WireFrame.decode(badKind)) { error in
            XCTAssertEqual(error as? WireFrame.DecodingError, .badKind(7))
        }
        // A channel id length that runs past the data.
        var truncated = WireFrame(kind: .state, channelID: "abc", sequence: 1, sentUptime: 0, payload: Data()).encoded()
        truncated[2] = 200
        XCTAssertThrowsError(try WireFrame.decode(truncated))
    }

    func testNewerWithWrapAround() {
        XCTAssertTrue(WireFrame.isNewer(2, than: 1))
        XCTAssertFalse(WireFrame.isNewer(1, than: 2))
        XCTAssertFalse(WireFrame.isNewer(5, than: 5))
        XCTAssertTrue(WireFrame.isNewer(0, than: UInt32.max))
        XCTAssertTrue(WireFrame.isNewer(3, than: UInt32.max - 2))
        XCTAssertFalse(WireFrame.isNewer(UInt32.max - 2, than: 3))
    }
}
