import XCTest
@testable import MeshLLM

final class EventStreamTests: XCTestCase {
    func testChatStreamEmitsCompletedEvent() async throws {
        let node = try makeTestNode()
        let request = ChatRequest(model: "test", messages: [])

        var events: [Event] = []
        for try await event in node.inference.chatStream(request) {
            events.append(event)
        }

        XCTAssertFalse(events.isEmpty)
        let hasCompleted = events.contains { if case .completed = $0 { return true }; return false }
        XCTAssertTrue(hasCompleted, "Stream should emit Completed event")
    }

    func testResponsesStreamEmitsCompletedEvent() async throws {
        let node = try makeTestNode()
        let request = ResponsesRequest(model: "test", input: "hello")

        var events: [Event] = []
        for try await event in node.inference.responsesStream(request) {
            events.append(event)
        }

        XCTAssertFalse(events.isEmpty)
        let hasCompleted = events.contains { if case .completed = $0 { return true }; return false }
        XCTAssertTrue(hasCompleted, "Stream should emit Completed event")
    }

    func testCancelOnTermination() async throws {
        let node = try makeTestNode()
        let request = ChatRequest(model: "test", messages: [])

        for try await _ in node.inference.chatStream(request) {
            break
        }
    }
}
