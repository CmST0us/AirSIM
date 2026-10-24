import XCTest
@testable import AirSIM

private let v2ID = "00112233-4455-4677-8899-aabbccddeeff"
private let v2OtherID = "10112233-4455-4677-8899-aabbccddeeff"
private let v2Now = Date(timeIntervalSince1970: 1_790_000_000)
private func v2Data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
private func v2Config(client: String = v2ID) -> V2Configuration {
    V2Configuration(identity: V2Identity(apiOrigin: "https://example.invalid", serverID: v2ID, clientInstallationID: client), mediaOrigin: "https://media.example.invalid", expiresAt: v2Now.addingTimeInterval(3600))
}
private func v2Import() -> [String: Any] {
    ["schema_version": 1, "api_origin": "https://example.invalid/", "media_origin": "https://media.example.invalid", "server_id": v2ID, "client_installation_id": v2ID, "token": String(repeating: "a", count: 64), "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(3600))]
}
private func v2Discovery(server: String = v2ID) throws -> Data {
    try v2Data(["protocol_version": 2, "profile": "airsim-v2-r4.1", "server_id": server, "api_origin": "https://example.invalid", "media_origin": "https://media.example.invalid", "device_origin": "https://device.example.invalid", "capabilities": ["controlled_test_client": true, "telephony": true, "messaging": true, "experimental_audio": true, "apns": false, "interactive_login": false]])
}
private func v2Binding(module: String = v2ID, client: String = v2ID) -> V2ControlBinding {
    V2ControlBinding(identity: v2Config(client: client).identity, moduleID: module, bootID: v2ID, backendEpoch: v2ID, connectionEpoch: v2ID)
}
private final class V2TestTokens: V2TokenStore {
    var fails = false
    var reads = 0
    var values: [String: String] = [:]
    func save(_ token: String, account: String) throws { if fails { throw V2Error.keychain }; values[account] = token }
    func read(account: String) throws -> String { reads += 1; if fails { throw V2Error.keychain }; return String(repeating: "a", count: 64) }
    func remove(account: String) throws { values.removeValue(forKey: account) }
}
private final class V2TestPending: V2PendingStore {
    var value: V2PendingCommand?
    var fails = false
    func load() throws -> V2PendingCommand? { value }
    func save(_ pending: V2PendingCommand) throws { if fails { throw V2Error.persistence }; value = pending }
    func clear() throws { value = nil }
}
private final class V2TestTransport: V2HTTPTransport {
    var requests: [URLRequest] = []
    var handler: (URLRequest) async throws -> V2HTTPResponse
    init(_ handler: @escaping (URLRequest) async throws -> V2HTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse { requests.append(request); return try await handler(request) }
}

final class CloudV2Tests: XCTestCase {
    func testConfigurationStrictFieldsAndOrigin() throws {
        let config = try V2ConfigurationImport.parse(v2Data(v2Import()), now: v2Now)
        XCTAssertEqual(config.configuration.identity.apiOrigin, "https://example.invalid")
        for origin in ["http://example.invalid", "https://u:p@example.invalid", "https://example.invalid/path", "https://example.invalid//", "https://example.invalid?x", "https://example.invalid#x", "https://example.invalid:0", "https://example.invalid:65536"] {
            XCTAssertThrowsError(try V2Validation.origin(origin), origin)
        }
        for field in ["token", "expires_at", "server_id", "api_origin"] {
            var object = v2Import(); object[field] = NSNull()
            XCTAssertThrowsError(try V2ConfigurationImport.parse(v2Data(object), now: v2Now))
        }
        var extra = v2Import(); extra["extra"] = true
        XCTAssertThrowsError(try V2ConfigurationImport.parse(v2Data(extra), now: v2Now))
        var expired = v2Import(); expired["expires_at"] = V2Validation.timestamp(v2Now)
        XCTAssertThrowsError(try V2ConfigurationImport.parse(v2Data(expired), now: v2Now))
        expired["expires_at"] = V2Validation.timestamp(v2Now.addingTimeInterval(3901))
        XCTAssertThrowsError(try V2ConfigurationImport.parse(v2Data(expired), now: v2Now))
        XCTAssertThrowsError(try V2ConfigurationImport.parse(Data(repeating: 32, count: 16385), now: v2Now))
    }
    func testDuplicateEscapedNestedKeysAndTrailingJSON() throws {
        for text in [#"{"error":"a","error":"b"}"#, #"{"error":"a","\u0065rror":"b"}"#, #"{"error":"a"} {}"#, #"{"error":{"x":1,"x":2}}"#] {
            XCTAssertThrowsError(try V2JSON.decode(V2ServerError.self, from: Data(text.utf8), limit: 1024))
        }
        XCTAssertNoThrow(try V2Validation.date("2026-10-24T00:00:00.123456789Z"))
        XCTAssertThrowsError(try V2Validation.date("2026-10-24T00:00:00+00:00"))
    }
    func testKeychainFailureNeverPersistsConfiguration() throws {
        let suite = "airsim.v2.test.\(UUID())", tokens = V2TestTokens()
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        tokens.fails = true
        let store = V2ConfigurationStore(tokens: tokens, defaults: defaults)
        XCTAssertThrowsError(try store.importConfiguration(v2Data(v2Import()), now: v2Now))
        XCTAssertNil(defaults.data(forKey: "airsim.v2.configuration"))
        tokens.fails = false
        let config = try store.importConfiguration(v2Data(v2Import()), now: v2Now)
        XCTAssertEqual(try store.load(), config)
        let persisted = String(data: defaults.data(forKey: "airsim.v2.configuration")!, encoding: .utf8)!
        XCTAssertFalse(persisted.contains(String(repeating: "a", count: 64)))
        XCTAssertNotEqual(config.identity.account, v2Config(client: v2OtherID).identity.account)
    }
    func testStampRejectsPreviousLifetimeAndOtherClient() {
        var gate = V2SessionGate(); let first = gate.start(v2Config()); gate.stop()
        XCTAssertFalse(gate.accepts(first)); let second = gate.start(v2Config())
        XCTAssertFalse(gate.accepts(first)); XCTAssertTrue(gate.accepts(second))
        _ = gate.start(v2Config(client: v2OtherID)); XCTAssertFalse(gate.accepts(second))
    }
    func testCommandArgumentsAndUTF16Boundaries() throws {
        XCTAssertNoThrow(try V2Command(binding: v2Binding(), action: "sms.send", args: ["number": "+12345678901", "text": String(repeating: "😀", count: 35)], now: v2Now))
        XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: "sms.send", args: ["number": "+12345678901", "text": String(repeating: "😀", count: 35) + "a"], now: v2Now))
        for text in ["", "a\0b"] { XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: "sms.send", args: ["number": "+12345678901", "text": text], now: v2Now)) }
        XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: "call.reject", args: ["call_id": v2ID], now: v2Now))
        XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: "call.dtmf", args: ["call_id": v2ID, "tones": "a"], now: v2Now))
        let command = try V2Command(binding: v2Binding(), action: "call.hangup", args: ["call_id": v2ID], now: v2Now)
        XCTAssertEqual(try V2Validation.date(command.deadline).timeIntervalSince(v2Now), 45)
    }
    @MainActor func testDiscoveryFailureNeverLoadsOrSendsToken() async throws {
        let transport = V2TestTransport { _ in V2HTTPResponse(status: 200, body: try v2Discovery(server: v2OtherID)) }
        let tokens = V2TestTokens()
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        do { _ = try await client.connect(v2Config()); XCTFail() } catch {}
        XCTAssertEqual(tokens.reads, 0)
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(client.configuration)
    }
    @MainActor func testUnknownSubmissionRestartQueriesWithoutRepost() async throws {
        let command = try V2Command(binding: v2Binding(), action: "sms.send", args: ["number": "+12345678901", "text": "private test text"], now: v2Now)
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            if request.httpMethod == "POST" { throw V2Error.transport }
            return V2HTTPResponse(status: 404, body: Data())
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(v2Config())
        let store = V2TestPending(), machine = try V2CommandMachine(client: client, store: V2TestPending())
        // Separate persistent instance represents an actual process restart.
        let first = try V2CommandMachine(client: client, store: store)
        try await first.submit(command, binding: v2Binding())
        XCTAssertEqual(first.phase, .unknown); XCTAssertTrue(first.blocksConfigurationChange)
        do { try await first.submit(command, binding: v2Binding()); XCTFail() } catch {}
        let saved = String(data: try JSONEncoder().encode(store.value!), encoding: .utf8)!
        XCTAssertFalse(saved.contains("private test text")); XCTAssertFalse(saved.contains("12345678901"))
        let recovered = try V2CommandMachine(client: client, store: store)
        try await recovered.recover(); try await recovered.recover()
        XCTAssertEqual(recovered.phase, .unknown)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(machine.phase, .idle)
    }
    @MainActor func testPersistenceFailurePreventsPostAnd401InvalidatesSession() async throws {
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            return V2HTTPResponse(status: 401, body: Data())
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(v2Config())
        let store = V2TestPending(); store.fails = true
        let machine = try V2CommandMachine(client: client, store: store)
        do { try await machine.submit(V2Command(binding: v2Binding(), action: "call.dial", args: ["number": "+12345678901"], now: v2Now), binding: v2Binding()); XCTFail() } catch {}
        XCTAssertEqual(transport.requests.count, 1)
        var invalidated = false; client.onAuthenticationInvalidated = { invalidated = true }
        do { _ = try await client.modules(); XCTFail() } catch {}
        XCTAssertTrue(invalidated); XCTAssertNil(client.stamp)
    }
    @MainActor func testModuleClientAndResponseSizeBoundaries() async throws {
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "module_id": v2OtherID, "online": false, "last_seen": NSNull(), "connection_epoch": "", "snapshot": NSNull()]))
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now }); _ = try await client.connect(v2Config())
        do { _ = try await client.snapshot(moduleID: v2ID); XCTFail() } catch {}
        let other = v2Binding(client: v2OtherID)
        do { _ = try await client.receipt(binding: other, commandID: v2ID); XCTFail() } catch {}
        XCTAssertEqual(transport.requests.count, 2)
        transport.handler = { _ in V2HTTPResponse(status: 200, body: Data(repeating: 32, count: 256 * 1024 + 1)) }
        do { _ = try await client.modules(); XCTFail() } catch { XCTAssertEqual(error as? V2Error, .oversized) }
    }
    func testASMPGoCompatibleVectorAndRejectsCorruption() throws {
        // Same header and payload as Fixtures/asmp-vector.go using Go encoding/binary.
        let headerHex = "41534d500101280000112233445546778899aabbccddeeff01000000000000004001000000000000"
        let header = Data(stride(from: 0, to: headerHex.count, by: 2).map { i -> UInt8 in
            let start = headerHex.index(headerHex.startIndex, offsetBy: i)
            return UInt8(headerHex[start..<headerHex.index(start, offsetBy: 2)], radix: 16)!
        })
        let pcm = Data((0..<320).map { UInt8(truncatingIfNeeded: $0) })
        let vector = header + pcm
        XCTAssertEqual(try V2ASMPFrame(sessionID: v2ID, direction: 1, sequence: 1, pcm: pcm).encode(), vector)
        XCTAssertEqual(try V2ASMPFrame.decode(vector, sessionID: v2ID, direction: 1, after: 0).frame.pcm, pcm)
        for index in [0,4,5,6,7,8,32,36,39] {
            var bad = vector; bad[index] ^= 127
            XCTAssertThrowsError(try V2ASMPFrame.decode(bad, sessionID: v2ID, direction: 1, after: 0))
        }
        XCTAssertThrowsError(try V2ASMPFrame.decode(vector, sessionID: v2ID, direction: 1, after: 1))
        XCTAssertThrowsError(try V2ASMPFrame.decode(vector.dropLast(), sessionID: v2ID, direction: 1, after: 0))
        let gap = try V2ASMPFrame(sessionID: v2ID, direction: 2, sequence: 5, pcm: pcm).encode()
        XCTAssertEqual(try V2ASMPFrame.decode(gap, sessionID: v2ID, direction: 2, after: 1).gaps, 3)
    }
    func testQueueBoundsExpirationAndLateGeneration() throws {
        let generation = UUID(); var queue = V2PCMQueue(generation: generation, emptyPolicy: .skip)
        for i in 0..<6 { try queue.enqueue(Data(repeating: UInt8(i), count: 320), at: UInt64(i) * 1_000_000, generation: generation) }
        XCTAssertEqual(queue.count, 5); XCTAssertEqual(queue.queueDrops, 1)
        XCTAssertNil(queue.output(at: 39_000_000, generation: generation))
        XCTAssertEqual(queue.output(at: 40_000_000, generation: generation)?.first, 1)
        let oldDeadline = queue.nextDeadline
        XCTAssertNil(queue.output(at: 60_000_000, generation: UUID())); XCTAssertEqual(queue.nextDeadline, oldDeadline)
        try queue.enqueue(Data(repeating: 0, count: 320), at: 70_000_000, generation: UUID()); XCTAssertEqual(queue.count, 4)
        XCTAssertNil(queue.output(at: 200_000_000, generation: generation)); XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.queueDrops, 5); XCTAssertEqual(queue.nextDeadline, 220_000_000)
    }
    func testQueueClockDoesNotAccumulateDelayOrCatchUp() throws {
        let generation = UUID(); var queue = V2PCMQueue(generation: generation, emptyPolicy: .silence)
        try queue.enqueue(Data(repeating: 1, count: 320), at: 0, generation: generation)
        for i in 0..<100 {
            let target = UInt64(40 + i * 20) * 1_000_000
            XCTAssertNotNil(queue.output(at: target + 3_000_000, generation: generation))
            XCTAssertEqual(queue.nextDeadline, target + 20_000_000)
        }
        XCTAssertEqual(queue.zeroFrames, 99)
        queue.completed(at: 2_081_000_000, generation: generation)
        XCTAssertEqual(queue.nextDeadline, 2_100_000_000)
        XCTAssertNil(queue.output(at: 2_081_000_001, generation: generation))
    }
    func testMinimumOutputSpacingAndCaptureDoesNotInventPCM() throws {
        let generation = UUID(); var queue = V2PCMQueue(generation: generation, emptyPolicy: .silence)
        try queue.enqueue(Data(repeating: 1, count: 320), at: 0, generation: generation)
        XCTAssertNotNil(queue.output(at: 59_000_000, generation: generation))
        XCTAssertNil(queue.output(at: 60_000_000, generation: generation)); XCTAssertEqual(queue.nextDeadline, 80_000_000)
        var capture = V2PCMQueue(generation: generation, emptyPolicy: .skip)
        try capture.enqueue(Data(repeating: 1, count: 320), at: 0, generation: generation)
        XCTAssertNotNil(capture.output(at: 40_000_000, generation: generation))
        XCTAssertNil(capture.output(at: 60_000_000, generation: generation)); XCTAssertEqual(capture.zeroFrames, 0)
    }
}

private final class V2LocalURLProtocol: URLProtocol {
    static var mode = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.mode == 2 {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.invalid"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://other.invalid")!), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8))
        if Self.mode == 1 { client?.urlProtocol(self, didLoad: Data([66])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension CloudV2Tests {
    func testTransportEnforcesStreamingLimitAndRejectsRedirect() async throws {
        let transport = V2URLSessionTransport(protocolClasses: [V2LocalURLProtocol.self])
        let request = URLRequest(url: URL(string: "https://offline.invalid")!)
        V2LocalURLProtocol.mode = 0
        let response = try await transport.send(request, limit: 8)
        XCTAssertEqual(response.body.count, 8)
        V2LocalURLProtocol.mode = 1
        do { _ = try await transport.send(request, limit: 8); XCTFail() } catch { XCTAssertEqual(error as? V2Error, .oversized) }
        V2LocalURLProtocol.mode = 2
        do { _ = try await transport.send(request, limit: 8); XCTFail() } catch { XCTAssertEqual(error as? V2Error, .redirect) }
    }
    @MainActor func testLateDiscoveryCannotAuthenticateReplacementSession() async throws {
        var continuation: CheckedContinuation<V2HTTPResponse, Error>?
        let transport = V2TestTransport { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let tokens = V2TestTokens()
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        let task = Task { try await client.connect(v2Config()) }
        while continuation == nil { await Task.yield() }
        client.stop()
        continuation?.resume(returning: V2HTTPResponse(status: 200, body: try v2Discovery()))
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? V2Error, .stale) }
        XCTAssertEqual(tokens.reads, 0); XCTAssertNil(client.stamp)
    }
    @MainActor func testRecoveredReceiptPreservesStateAndCallOwnership() async throws {
        let store = V2TestPending()
        store.value = V2PendingCommand(binding: v2Binding(), commandID: v2ID, action: "call.dial", generation: nil, callID: nil)
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            return V2HTTPResponse(status: 200, body: try v2Data(["command_id": v2ID, "state": "completed", "generation": v2ID, "receipt": ["command_id": v2ID, "action": "call.dial", "state": "accepted", "result_code": "", "call_id": v2OtherID, "updated_at": "2026-10-24T00:00:00Z"]]))
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now }); _ = try await client.connect(v2Config())
        let machine = try V2CommandMachine(client: client, store: store); try await machine.recover()
        XCTAssertEqual(machine.phase, .receipt(serverState: "completed", receiptState: "accepted"))
        XCTAssertEqual(machine.ownedCall?.callID, v2OtherID); XCTAssertEqual(store.value?.generation, v2ID)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 0)
        try machine.acknowledgeResolved(); XCTAssertNil(store.value)
    }
    func testNullableSnapshotAndStrictNestedResponseFields() throws {
        let empty: [String: Any] = ["server_id": v2ID, "module_id": v2ID, "online": false, "last_seen": NSNull(), "connection_epoch": "", "snapshot": NSNull()]
        XCTAssertNil(try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(empty), limit: 262144).snapshot)
        var bad = empty; bad["unknown"] = 1
        XCTAssertThrowsError(try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(bad), limit: 262144))
        let negative: [String: Any] = ["server_id": v2ID, "module_id": v2ID, "agent_boot_id": "", "backend_epoch": "", "online": false, "inbox_gap": false, "inbox_dropped": -1, "messages": []]
        XCTAssertThrowsError(try V2JSON.decode(V2MessagesResponse.self, from: v2Data(negative), limit: 2097152))
        let receipt: [String: Any] = ["command_id": v2ID, "state": "pending", "generation": v2ID, "receipt": NSNull()]
        XCTAssertNil(try V2JSON.decode(V2CommandRecord.self, from: v2Data(receipt), limit: 262144).receipt)
    }
}

extension CloudV2Tests {
    func testSnapshotFreshnessAndNestedEpochBinding() throws {
        let module = try V2JSON.decode(V2Module.self, from: v2Data(["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]), limit: 1024)
        func snapshot(age: Double, boot: String = v2ID, online: Bool = true) throws -> V2SnapshotResponse {
            let object: [String: Any] = ["server_id": v2ID, "module_id": v2ID, "online": online, "last_seen": V2Validation.timestamp(v2Now), "connection_epoch": v2ID, "snapshot": [
                "agent_boot_id": v2ID, "backend_epoch": v2ID, "observed_at": V2Validation.timestamp(v2Now.addingTimeInterval(-age)),
                "control": ["schema_version": 1, "agent_boot_id": boot, "backend_epoch": v2ID, "ready": true, "reason": "", "scope": "local_control", "voice_ready": false, "telephony_ready": true, "messaging_ready": true, "inbox_gap": false, "inbox_dropped": 0, "command_capacity_remaining": 100],
                "calls": ["agent_boot_id": v2ID, "backend_epoch": v2ID, "available": true, "calls": []],
                "audio": ["available": true, "implementation": "implemented", "verification": "unverified", "voice_ready": false, "reason": ""]]]
            return try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(object), limit: 262144)
        }
        for age in [-3.0, 0, 8] {
            XCTAssertEqual(try snapshot(age: age).controlBinding(configuration: v2Config(), module: module, now: v2Now), v2Binding())
        }
        for age in [-4.0, 9] { XCTAssertThrowsError(try snapshot(age: age).controlBinding(configuration: v2Config(), module: module, now: v2Now)) }
        XCTAssertThrowsError(try snapshot(age: 0, online: false).controlBinding(configuration: v2Config(), module: module, now: v2Now))
        XCTAssertThrowsError(try snapshot(age: 0, boot: v2OtherID))
    }
    func testMediaHandshakeRejectsIdentityFormatAndUnknownFields() throws {
        let paired: [String: Any] = ["type": "paired", "session_id": v2ID, "format": ["sample_rate": 8000, "channels": 1, "sample_format": "s16le", "frame_samples": 160]]
        XCTAssertNoThrow(try V2MediaServerMessage.parse(v2Data(paired), sessionID: v2ID))
        XCTAssertThrowsError(try V2MediaServerMessage.parse(v2Data(paired), sessionID: v2OtherID))
        var bad = paired; bad["format"] = ["sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 160]
        XCTAssertThrowsError(try V2MediaServerMessage.parse(v2Data(bad), sessionID: v2ID))
        bad = paired; bad["extra"] = true
        XCTAssertThrowsError(try V2MediaServerMessage.parse(v2Data(bad), sessionID: v2ID))
    }
    func testBackoffIsBoundedAndSuccessResets() {
        var backoff = V2PollBackoff()
        XCTAssertEqual((0..<7).map { _ in backoff.failed() }, [1,2,4,8,15,15,15])
        XCTAssertEqual(backoff.succeeded(), 1); XCTAssertEqual(backoff.failed(), 1)
    }
}

extension CloudV2Tests {
    func testValidationRequiresWholeStringWithoutSurroundingWhitespace() throws {
        let timestamp = "2026-10-24T00:00:00Z"
        let token = String(repeating: "a", count: 64)
        let number = "+12345678901"
        let tones = "123A*#"
        func receipt(_ code: String) throws -> V2Receipt {
            try V2JSON.decode(V2Receipt.self, from: v2Data([
                "command_id": v2ID, "action": "call.dial", "state": "accepted",
                "result_code": code, "updated_at": timestamp
            ]), limit: 1024)
        }
        XCTAssertNoThrow(try V2Validation.uuid(v2ID))
        XCTAssertNoThrow(try V2Validation.date(timestamp))
        XCTAssertNoThrow(try V2ConfigurationImport.parse(v2Data(v2Import()), now: v2Now))
        XCTAssertNoThrow(try V2Command(binding: v2Binding(), action: "call.dial", args: ["number": number], now: v2Now))
        XCTAssertNoThrow(try V2Command(binding: v2Binding(), action: "call.dtmf", args: ["call_id": v2ID, "tones": tones], now: v2Now))
        XCTAssertNoThrow(try receipt("accepted"))
        XCTAssertNoThrow(try receipt(""))
        let wrappers = [("", "\n"), ("", "\r\n"), (" ", ""), ("", " "), ("\t", ""), ("", "\t"), (" ", " ")]
        for (prefix, suffix) in wrappers {
            XCTAssertThrowsError(try V2Validation.uuid(prefix + v2ID + suffix))
            XCTAssertThrowsError(try V2Validation.date(prefix + timestamp + suffix))
            var imported = v2Import(); imported["token"] = prefix + token + suffix
            XCTAssertThrowsError(try V2ConfigurationImport.parse(v2Data(imported), now: v2Now))
            XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: "call.dial", args: ["number": prefix + number + suffix], now: v2Now))
            XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: "call.dtmf", args: ["call_id": v2ID, "tones": prefix + tones + suffix], now: v2Now))
            XCTAssertThrowsError(try receipt(prefix + "accepted" + suffix))
        }
    }
}
