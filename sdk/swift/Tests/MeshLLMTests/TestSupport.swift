import XCTest
@testable import MeshLLM

func makeOwnerKeypairBytesHex() -> String {
    generateOwnerKeypairHex()
}

func makeTestNode() throws -> Node {
    Node(handle: TestMeshNodeHandle())
}

final class TestMeshNodeHandle: MeshNodeHandle, @unchecked Sendable {
    private let requestId = "test-request"
    private(set) var cancelledRequestIds: [String] = []
    private var connected = false

    init() {
        super.init(noHandle: MeshNodeHandle.NoHandle())
    }

    required init(unsafeFromHandle handle: UInt64) {
        super.init(unsafeFromHandle: handle)
    }

    override func chat(request: ChatRequestNative, listener: EventListener) throws -> String {
        listener.onEvent(event: .tokenDelta(requestId: requestId, delta: "hello"))
        listener.onEvent(event: .completed(requestId: requestId))
        return requestId
    }

    override func responses(request: ResponsesRequestNative, listener: EventListener) throws -> String {
        listener.onEvent(event: .tokenDelta(requestId: requestId, delta: "hello"))
        listener.onEvent(event: .completed(requestId: requestId))
        return requestId
    }

    override func cancel(requestId: String) throws {
        cancelledRequestIds.append(requestId)
    }

    override func reconnect() throws {
        connected = true
    }

    override func start() throws {
        connected = true
    }

    override func status() -> ClientStatus {
        ClientStatus(connected: connected, peerCount: connected ? 1 : 0)
    }

    override func stop() throws {
        connected = false
    }
}
