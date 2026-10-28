import Foundation
@testable import UntoldSharePlay
import XCTest

struct TimeoutError: Error {}

/// Polls on the main actor until the condition holds or the timeout passes.
@MainActor
func waitUntil(
    _ timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        if ProcessInfo.processInfo.systemUptime > deadline {
            XCTFail("timed out after \(timeout) s", file: file, line: line)
            throw TimeoutError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Collects the session's events for assertions.
@MainActor
final class EventLog {
    private(set) var events: [SharePlayEvent] = []

    func attach(to session: SharePlaySession) {
        session.addEventHandler { [weak self] event in
            self?.events.append(event)
        }
    }

    func contains(_ event: SharePlayEvent) -> Bool {
        events.contains(event)
    }
}

struct Pose: Codable, Sendable, Equatable {
    var x: Float
    var y: Float
}

enum Command: Codable, Sendable, Equatable {
    case start
    case undo(player: Int)
}

/// Fixed participant ids, so host election and sort order are predictable.
func participantID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}
