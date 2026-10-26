import XCTest
import AVFoundation
import CallKit
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
    func read(account: String) throws -> String {
        reads += 1
        if fails { throw V2Error.keychain }
        return values[account] ?? String(repeating: "a", count: 64)
    }
    func remove(account: String) throws { values.removeValue(forKey: account) }
}
private final class V2TestPairingStore: V2PairingStore {
    var state = V2PairingState()
    func load() throws -> V2PairingState { state }
    func save(_ state: V2PairingState) throws { self.state = state }
}
private final class V2TestPending: V2PendingStore {
    var value: V2PendingCommand?
    var fails = false
    func load() throws -> V2PendingCommand? { value }
    func save(_ pending: V2PendingCommand) throws { if fails { throw V2Error.persistence }; value = pending }
    func clear() throws { value = nil }
}
@MainActor private final class V2TestTransport: V2HTTPTransport {
    var requests: [URLRequest] = []
    var handler: @MainActor (URLRequest) async throws -> V2HTTPResponse
    init(_ handler: @escaping @MainActor (URLRequest) async throws -> V2HTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse { requests.append(request); return try await handler(request) }
}

final class CloudV2Tests: XCTestCase {
    func testRealKeychainRoundTripWithIsolatedAccount() throws {
        let account = "r5-keychain-test-\(UUID().uuidString)"
        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let store = V2KeychainTokenStore()
        defer { try? store.remove(account: account) }
        try store.save(token, account: account)
        XCTAssertTrue(try store.read(account: account) == token)
        try store.remove(account: account)
        XCTAssertThrowsError(try store.read(account: account))
    }

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
    @MainActor func testPairedAccess401RefreshesOnceAndKeepsInstallationStable() async throws {
        let tokens = V2TestTokens()
        let current = V2Configuration(
            identity: V2Identity(apiOrigin: "https://example.invalid", serverID: v2ID, clientInstallationID: v2ID),
            mediaOrigin: "https://media.example.invalid",
            expiresAt: v2Now.addingTimeInterval(3600),
            moduleID: v2ID,
            refreshExpiresAt: v2Now.addingTimeInterval(90 * 86400)
        )
        try tokens.save(String(repeating: "a", count: 64), account: current.identity.account)
        var moduleReads = 0
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            moduleReads += 1
            if moduleReads == 1 { return V2HTTPResponse(status: 401, body: Data()) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": []]))
        }
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        var refreshes = 0
        client.onRefreshConfiguration = { previous in
            refreshes += 1
            let next = String(repeating: "b", count: 64)
            try tokens.save(next, account: previous.identity.account)
            return V2Configuration(
                identity: previous.identity,
                mediaOrigin: previous.mediaOrigin,
                expiresAt: v2Now.addingTimeInterval(3600),
                moduleID: previous.moduleID,
                refreshExpiresAt: v2Now.addingTimeInterval(90 * 86400)
            )
        }
        _ = try await client.connect(current)
        let modules = try await client.modules()
        XCTAssertTrue(modules.modules.isEmpty)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v2/modules" }.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "b", count: 64))
    }
    @MainActor func testLegacyNearExpiryCredentialDoesNotRequireRefresh() async throws {
        let tokens = V2TestTokens()
        let current = V2Configuration(
            identity: V2Identity(apiOrigin: "https://example.invalid", serverID: v2ID, clientInstallationID: v2ID),
            mediaOrigin: "https://media.example.invalid",
            expiresAt: v2Now.addingTimeInterval(4 * 60)
        )
        try tokens.save(String(repeating: "a", count: 64), account: current.identity.account)
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": []]))
        }
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        _ = try await client.connect(current)
        let modules = try await client.modules()
        XCTAssertTrue(modules.modules.isEmpty)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v2/modules" }.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 64))
    }
    @MainActor func testPairingClaimSurvivesLostResponseAndCommitsSameInstallation() async throws {
        let suite = "airsim.v2.pairing.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = V2TestTokens(), pairings = V2TestPairingStore()
        let lookupObject: [String: Any] = [
            "request_id": v2ID, "server_id": v2ID, "module_id": v2ID,
            "name": "RM500", "short_id": String(v2ID.suffix(8)), "online": true,
            "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(300)),
        ]
        var claims: [Data] = []
        let transport = V2TestTransport { request in
            if request.url!.path == "/v2/pairing/lookup" {
                return V2HTTPResponse(status: 200, body: try v2Data(lookupObject))
            }
            let data = request.httpBody ?? Data()
            claims.append(data)
            if claims.count == 1 { throw V2Error.transport }
            let body = try JSONSerialization.jsonObject(with: data) as! [String: String]
            return V2HTTPResponse(status: 201, body: try v2Data([
                "schema_version": 2, "api_origin": "https://example.invalid",
                "media_origin": "https://media.example.invalid", "server_id": v2ID,
                "module_id": v2ID, "client_installation_id": body["client_installation_id"]!,
                "token": String(repeating: "b", count: 64),
                "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(3600)),
                "refresh_expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(90 * 86400)),
            ]))
        }
        let pairing = V2PairingClient(origin: "https://example.invalid", store: pairings, transport: transport, now: { v2Now })
        let device = try await pairing.lookup(code: "00427193")
        do { _ = try await pairing.claim(code: "00427193", device: device); XCTFail() }
        catch { XCTAssertEqual(error as? V2Error, .transport) }
        XCTAssertNotNil(pairings.state.pending)
        let session = try await pairing.claim(code: "00427193", device: device)
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(claims[0], claims[1])
        let store = V2ConfigurationStore(tokens: tokens, defaults: defaults, pairings: pairings)
        try store.commitPairedSession(session)
        XCTAssertEqual(try store.load(), session.configuration)
        XCTAssertNil(pairings.state.pending)
        XCTAssertEqual(try tokens.read(account: session.configuration.identity.account), session.token)
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
    func testSnapshotCachedDateStillStrictlyRejectsInvalidWireTime() throws {
        let base = try JSONSerialization.jsonObject(with: v2SnapshotData()) as! [String: Any]
        for timestamp in ["2026-02-30T00:00:00Z", "2026-10-24T00:00:00Z\n", "2026-10-24T00:00:00+00:00", "2026-10-24T00:00:00.Z", "invalid"] {
            var object = base, value = object["snapshot"] as! [String: Any]
            value["observed_at"] = timestamp; object["snapshot"] = value
            XCTAssertThrowsError(try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(object), limit: 262144))
        }
        var object = base, value = object["snapshot"] as! [String: Any]
        value["observed_at"] = "2026-10-24T00:00:00.123456789Z"; object["snapshot"] = value
        let decoded = try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(object), limit: 262144)
        let snapshot = try XCTUnwrap(decoded.snapshot)
        XCTAssertEqual(snapshot.observed_at, "2026-10-24T00:00:00.123456789Z")
        XCTAssertEqual(snapshot.observedAt, try V2Validation.date(snapshot.observed_at))
        value["observedAt"] = 0; object["snapshot"] = value
        XCTAssertThrowsError(try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(object), limit: 262144))
    }
    func testSnapshotCachedDateUsesCurrentNowAndKeepsOwnershipGates() throws {
        let moduleObject: [String: Any] = ["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]
        let module = try V2JSON.decode(V2Module.self, from: v2Data(moduleObject), limit: 1024)
        let data = try v2SnapshotData(calls: [v2CallObject()])
        let response = try V2JSON.decode(V2SnapshotResponse.self, from: data, limit: 262144)
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        for age in [-3.001, -3, 0, 8, 8.001, 20] {
            let now = v2Now.addingTimeInterval(age)
            let valid = (-3.0...8.0).contains(age)
            XCTAssertEqual(response.matches(context, now: now), valid)
            if valid { XCTAssertEqual(try response.controlBinding(configuration: v2Config(), module: module, now: now), v2Binding()) }
            else { XCTAssertThrowsError(try response.controlBinding(configuration: v2Config(), module: module, now: now)) }
        }
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in [("online", false as Any), ("connection_epoch", v2OtherID as Any), ("server_id", v2OtherID as Any)] {
            var object = original; object[key] = value
            let changed = try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(object), limit: 262144)
            XCTAssertFalse(changed.matches(context, now: v2Now))
            XCTAssertThrowsError(try changed.controlBinding(configuration: v2Config(), module: module, now: v2Now))
        }
        var offline = moduleObject; offline["online"] = false
        XCTAssertThrowsError(try response.controlBinding(configuration: v2Config(), module: V2JSON.decode(V2Module.self, from: v2Data(offline), limit: 1024), now: v2Now))
        for calls in [[], [v2CallObject(id: v2ID)], [v2CallObject(state: "disconnected")]] {
            let changed = try V2JSON.decode(V2SnapshotResponse.self, from: v2SnapshotData(calls: calls), limit: 262144)
            XCTAssertFalse(changed.matches(context, now: v2Now))
        }
    }
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

private final class V2TestOwned: V2OwnedCallStore {
    var value: V2CallContext?
    var fails = false
    func load() throws -> V2CallContext? { value }
    func save(_ context: V2CallContext) throws { if fails { throw V2Error.persistence }; value = context }
    func clear() throws { value = nil }
}
private func v2CallObject(id: String = v2OtherID, state: String = "active", date: String = V2Validation.timestamp(v2Now)) -> [String: Any] {
    ["call_id": id, "state": state, "ownership": "managed", "direction": "outgoing", "number": "", "observed_at": date, "disconnect_reason": ""]
}
private func v2SnapshotData(module: String = v2ID, age: Double = 0, calls: [[String: Any]] = [], telephony: Bool = true, messaging: Bool = true) throws -> Data {
    try v2Data(["server_id": v2ID, "module_id": module, "online": true, "last_seen": V2Validation.timestamp(v2Now), "connection_epoch": v2ID, "snapshot": [
        "agent_boot_id": v2ID, "backend_epoch": v2ID, "observed_at": V2Validation.timestamp(v2Now.addingTimeInterval(-age)),
        "control": ["schema_version": 1, "agent_boot_id": v2ID, "backend_epoch": v2ID, "ready": true, "reason": "", "scope": "local_control", "voice_ready": false, "telephony_ready": telephony, "messaging_ready": messaging, "inbox_gap": false, "inbox_dropped": 0, "command_capacity_remaining": 100],
        "calls": ["agent_boot_id": v2ID, "backend_epoch": v2ID, "available": true, "calls": calls],
        "audio": ["available": true, "implementation": "implemented", "verification": "unverified", "voice_ready": false, "reason": ""]]])
}
private func v2Accepted(id: String = v2ID, action: String = "call.dial", callID: String? = v2OtherID) throws -> Data {
    var receipt: [String: Any] = ["command_id": id, "action": action, "state": "accepted", "result_code": "", "updated_at": V2Validation.timestamp(v2Now)]
    if let callID { receipt["call_id"] = callID }
    return try v2Data(["command_id": id, "state": "completed", "generation": v2ID, "receipt": receipt])
}
extension CloudV2Tests {
    func testFreshInstallAndEveryLegacyMigrationEvidence() {
        let suite = "airsim.route.test.\(UUID())"
        let store = UserDefaults(suiteName: suite)!; defer { store.removePersistentDomain(forName: suite) }
        XCTAssertNil(CloudVersionPreference.selection(defaults: store))
        XCTAssertEqual(CloudVersionPreference.selection(defaults: store, paired: true), .v1)
        for key in ["airsim.first-connection-complete", LocalModePreference.key, CloudModePreference.key, "airsim.push-relay-url", "airsim.voip-push-token", "airsim.alert-push-token", "airsim.push-device-id", "airsim.live-activity-push-to-start-token", "airsim.watch-voip-push-token", "airsim.watch-bundle-id", "airsim.appearance", "airsim.language"] {
            store.set(false, forKey: key)
            XCTAssertEqual(CloudVersionPreference.selection(defaults: store), .v1, key)
            store.removeObject(forKey: key)
        }
        store.set(true, forKey: LocalModePreference.key)
        XCTAssertEqual(CloudVersionPreference.selection(defaults: store), .local)
        CloudVersionPreference.save(.v2, defaults: store)
        XCTAssertEqual(CloudVersionPreference.selection(defaults: store), .v2)
    }
    @MainActor func testRouteUsesInjectedDefaultsAndReservationsBlockSwitch() async {
        let suite = "airsim.route.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); LegacyRuntimeGate.configure(false) }
        let router = AppRouteCoordinator(defaults: defaults, paired: false)
        XCTAssertNil(router.choice); XCTAssertNil(router.legacy); XCTAssertNil(router.cloud); XCTAssertFalse(LegacyRuntimeGate.allowed)
        let reservation = LegacyBusinessReservations.reserve()
        await router.choose(.v2)
        XCTAssertNil(router.choice); XCTAssertNotNil(router.error)
        LegacyBusinessReservations.release(reservation)
        await router.choose(.v2)
        XCTAssertEqual(router.choice, .v2)
        XCTAssertEqual(CloudVersionPreference.selection(defaults: defaults), .v2)
        XCTAssertNil(router.legacy)
    }
    func testLegacyGateABADropsOldRegistrationWatchAndMediaCompletions() throws {
        defer { LegacyRuntimeGate.configure(false) }
        LegacyRuntimeGate.configure(true)
        let first = try LegacyRuntimeGate.begin(); LegacyRuntimeGate.end()
        LegacyRuntimeGate.configure(false)
        XCTAssertFalse(LegacyRuntimeGate.accepts(first))
        LegacyRuntimeGate.configure(true)
        XCTAssertFalse(LegacyRuntimeGate.accepts(first))
        XCTAssertTrue(LegacyRuntimeGate.accepts(LegacyRuntimeGate.generation))
    }
    func testExpiredPushRoutesToIsolatedReportAndStopsBusinessDispatch() {
        var reports = 0, business = 0
        func receive(allowed: Bool) {
            if LegacyPushRouting.rejectExpired(allowed: allowed, expired: { reports += 1 }) { return }
            business += 1
        }
        receive(allowed: false); XCTAssertEqual(reports, 1); XCTAssertEqual(business, 0)
        receive(allowed: true); XCTAssertEqual(reports, 1); XCTAssertEqual(business, 1)
    }
    func testLegacyUnknownWritesPersistButReadErrorsDoNotCreateFence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); LegacyRuntimeGate.configure(false) }
        let url = root.appendingPathComponent("fence.json")
        LegacyRuntimeGate.configure(true); let stamp = LegacyRuntimeGate.generation
        let fence = LegacySwitchFence(url: url)
        for path in ["api/calls/status", "api/events", "api/sms", "api/push/status"] { XCTAssertFalse(LegacySwitchFence.businessPath(path)) }
        XCTAssertFalse(fence.blocked)
        let id = try fence.begin(service: "local", device: "device", action: "api/calls/dial")
        XCTAssertTrue(fence.blocked)
        let restored = LegacySwitchFence(url: url)
        XCTAssertEqual(restored.pending.first?.id, id)
        let empty = CallStatus(active: nil, history: [], polling: true, eventDriven: true, pollIntervalSeconds: 1, lastPollError: "", revision: 1)
        try restored.observeLocal(empty, service: "local", device: "device", runtime: stamp)
        XCTAssertTrue(restored.blocked) // An empty snapshot cannot disprove an unknown dial.
        LegacyRuntimeGate.configure(false); LegacyRuntimeGate.configure(true)
        try restored.resolve(id, runtime: stamp)
        XCTAssertTrue(restored.blocked)
        try restored.resolve(id, runtime: LegacyRuntimeGate.generation)
        XCTAssertFalse(restored.blocked)
    }
    func testConfirmedLocalHangupWaitsForAuthoritativeIdle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); LegacyRuntimeGate.configure(false) }
        LegacyRuntimeGate.configure(true); let stamp = LegacyRuntimeGate.generation
        let fence = LegacySwitchFence(url: root.appendingPathComponent("fence.json"))
        let id = try fence.begin(service: "local", device: "device", action: "api/calls/hangup", callID: "call")
        try fence.resolve(id, runtime: stamp, awaitIdle: true)
        XCTAssertTrue(fence.blocked)
        let error = CallStatus(active: nil, history: [], polling: true, eventDriven: true, pollIntervalSeconds: 1, lastPollError: "offline", revision: 1)
        try fence.observeLocal(error, service: "local", device: "device", runtime: stamp)
        XCTAssertTrue(fence.blocked)
        let idle = CallStatus(active: nil, history: [], polling: true, eventDriven: true, pollIntervalSeconds: 1, lastPollError: "", revision: 2)
        try fence.observeLocal(idle, service: "other", device: "device", runtime: stamp)
        XCTAssertTrue(fence.blocked)
        try fence.observeLocal(idle, service: "local", device: "device", runtime: stamp)
        XCTAssertFalse(fence.blocked)
    }
    @MainActor func testOwnedContextPersistsBeforePendingReleaseAndRequiresFreshIdentity() async throws {
        let pending = V2TestPending(), owned = V2TestOwned()
        pending.value = V2PendingCommand(binding: v2Binding(), commandID: v2ID, action: "call.dial")
        let transport = V2TestTransport { request in V2HTTPResponse(status: 200, body: try request.url!.path == "/.well-known/airsim" ? v2Discovery() : v2Accepted()) }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now }); _ = try await client.connect(v2Config())
        let machine = try V2CommandMachine(client: client, store: pending, ownedStore: owned)
        owned.fails = true; try await machine.recover()
        XCTAssertEqual(machine.phase, .unknown); XCTAssertNotNil(pending.value); XCTAssertNil(owned.value)
        owned.fails = false; try await machine.recover(); XCTAssertNotNil(owned.value)
        try machine.acknowledgeResolved(); XCTAssertNil(pending.value)
        let restarted = try V2CommandMachine(client: client, store: pending, ownedStore: owned)
        let context = try XCTUnwrap(restarted.ownedCall)
        client.stop(); _ = try await client.connect(v2Config())
        let fresh = try V2JSON.decode(V2SnapshotResponse.self, from: v2SnapshotData(calls: [v2CallObject()]), limit: 262144)
        let stale = try V2JSON.decode(V2SnapshotResponse.self, from: v2SnapshotData(age: 9, calls: [v2CallObject()]), limit: 262144)
        XCTAssertThrowsError(try client.restoreOwnership(context, snapshot: stale))
        XCTAssertNoThrow(try client.restoreOwnership(context, snapshot: fresh))
        client.stop(); _ = try await client.connect(v2Config(client: v2OtherID))
        XCTAssertThrowsError(try client.restoreOwnership(context, snapshot: fresh))
        XCTAssertEqual(restarted.ownedCall, context)
        try restarted.clearDisconnectedOwnedCall(); XCTAssertNil(owned.value)
    }
    @MainActor func testAcceptedDialWithoutCallIDStaysPendingAcrossRestart() async throws {
        let pending = V2TestPending()
        pending.value = V2PendingCommand(binding: v2Binding(), commandID: v2ID, action: "call.dial")
        let transport = V2TestTransport { request in V2HTTPResponse(status: 200, body: try request.url!.path == "/.well-known/airsim" ? v2Discovery() : v2Accepted(callID: nil)) }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now }); _ = try await client.connect(v2Config())
        let first = try V2CommandMachine(client: client, store: pending); try await first.recover()
        XCTAssertEqual(first.phase, .waiting); XCTAssertNil(first.ownedCall)
        XCTAssertThrowsError(try first.acknowledgeResolved())
        let second = try V2CommandMachine(client: client, store: pending); try await second.recover()
        XCTAssertEqual(second.phase, .waiting); XCTAssertNotNil(second.pending)
        XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod != "POST" })
    }
    @MainActor func testBackgroundCancelsConnectingWithoutLateActivationOrBusyLatch() async throws {
        let suite = "airsim.model.test.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!, tokens = V2TestTokens()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        var continuation: CheckedContinuation<V2HTTPResponse, Error>?
        let transport = V2TestTransport { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        let model = CloudV2Model(client: client, defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        XCTAssertEqual(transport.requests.count, 0); XCTAssertNil(model.selectedModuleID)
        let active = Task { await model.sceneChanged(.active) }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(model.busy)
        await model.sceneChanged(.inactive); XCTAssertTrue(model.foreground)
        let background = Task { await model.sceneChanged(.background) }
        while model.foreground { await Task.yield() }
        continuation?.resume(returning: V2HTTPResponse(status: 200, body: try v2Discovery()))
        await active.value; await background.value
        XCTAssertFalse(model.busy); XCTAssertFalse(model.connected); XCTAssertFalse(model.blocksSwitch)
        XCTAssertEqual(tokens.reads, 0); XCTAssertEqual(transport.requests.count, 1)
        await model.stop()
    }
}

extension CloudV2Tests {
    func testHistoryDomainsCapsAndChronologicalFractionOrdering() throws {
        let domain = V2HistoryDomain(identity: v2Config().identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2ID)
        let otherClient = V2HistoryDomain(identity: v2Config(client: v2OtherID).identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2ID)
        let otherModule = V2HistoryDomain(identity: v2Config().identity, moduleID: v2OtherID, bootID: v2ID, backendEpoch: v2ID)
        let otherEpoch = V2HistoryDomain(identity: v2Config().identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2OtherID)
        func message(_ id: String, _ date: String) throws -> V2Message {
            try V2JSON.decode(V2Message.self, from: v2Data(["message_id": id, "direction": "incoming", "sender": "", "recipient": "", "text": "fixture", "state": "received", "delivery": "unknown", "observed_at": date]), limit: 1024)
        }
        let plain = try message(v2ID, "2026-10-24T00:00:00Z"), fraction = try message(v2OtherID, "2026-10-24T00:00:00.5Z")
        var history = V2History()
        history.merge(messages: [V2StoredMessage(domain: domain, message: plain, inboxGap: false, inboxDropped: 0), V2StoredMessage(domain: domain, message: fraction, inboxGap: true, inboxDropped: 2)])
        XCTAssertEqual(history.messages.first?.message.message_id, v2OtherID)
        history.merge(messages: [otherClient, otherModule, otherEpoch].map { V2StoredMessage(domain: $0, message: plain, inboxGap: false, inboxDropped: 0) })
        XCTAssertEqual(history.messages.count, 5)
        var batch: [V2StoredMessage] = []
        for _ in 0..<2001 { batch.append(V2StoredMessage(domain: domain, message: try message(UUID().uuidString.lowercased(), "2026-10-24T00:00:01Z"), inboxGap: false, inboxDropped: 0)) }
        history.merge(messages: batch); XCTAssertEqual(history.messages.count, 2000)
        XCTAssertFalse(history.merge(messages: batch))
        var calls: [V2StoredCall] = []
        for _ in 0..<501 { calls.append(V2StoredCall(domain: domain, call: try V2JSON.decode(V2Call.self, from: v2Data(v2CallObject(id: UUID().uuidString.lowercased())), limit: 1024))) }
        history.merge(calls: calls); XCTAssertEqual(history.calls.count, 500)
        XCTAssertFalse(history.merge(calls: calls))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = V2ProtectedFile<V2History>(url: root.appendingPathComponent("history.json"))
        try file.save(history)
        XCTAssertEqual(try file.load()?.messages.count, 2000)
        XCTAssertEqual(try file.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    @MainActor func testModelReadinessModuleIsolationAndOfflineHistory() async throws {
        let suite = "airsim.model.test.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!, tokens = V2TestTokens()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        var offline = false
        let transport = V2TestTransport { request in
            if offline { throw V2Error.transport }
            let path = request.url!.path
            if path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            if path == "/v2/modules" { return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": [v2ID, v2OtherID].map { ["module_id": $0, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID] }])) }
            let module = path.contains(v2OtherID) ? v2OtherID : v2ID
            if path.hasSuffix("snapshot") { return V2HTTPResponse(status: 200, body: try v2SnapshotData(module: module, calls: [v2CallObject(state: "disconnected")], telephony: module == v2ID, messaging: module != v2ID)) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "module_id": module, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": []]))
        }
        let model = CloudV2Model(client: V2Client(transport: transport, tokens: tokens, now: { v2Now }), defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        await model.sceneChanged(.active)
        for _ in 0..<100 where model.modules.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.selectedModuleID); XCTAssertFalse(model.telephonyReady)
        await model.selectModule(v2ID)
        for _ in 0..<100 where model.messagesResponse == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.telephonyReady); XCTAssertFalse(model.messagingReady); XCTAssertEqual(model.visibleCalls.count, 1)
        await model.selectModule(v2OtherID)
        for _ in 0..<100 where model.messagesResponse == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.telephonyReady); XCTAssertTrue(model.messagingReady)
        XCTAssertEqual(model.history.calls.count, 2); XCTAssertEqual(model.visibleCalls.count, 1)
        offline = true
        // Force a fresh poll through the explicit module change; old history remains available.
        await model.selectModule(v2ID)
        for _ in 0..<100 where model.syncStatus == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.syncStatus); XCTAssertNil(model.error); XCTAssertEqual(model.visibleCalls.count, 1)
        XCTAssertFalse(model.telephonyReady)
        await model.stop()
        XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod != "POST" })
    }
    @MainActor func testInFlightDialBackgroundPreservesOwnedCallWithoutHangup() async throws {
        let suite = "airsim.model.test.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!, tokens = V2TestTokens()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        var dialContinuation: CheckedContinuation<V2HTTPResponse, Error>?
        var dialID = "", hangups: [[String: Any]] = []
        let transport = V2TestTransport { request in
            let path = request.url!.path
            if path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            if request.httpMethod == "POST" {
                let envelope = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let command = envelope["command"] as! [String: Any]
                if command["action"] as? String == "call.dial" {
                    dialID = command["command_id"] as! String
                    return try await withCheckedThrowingContinuation { dialContinuation = $0 }
                }
                hangups.append(command); throw V2Error.transport
            }
            if path == "/v2/modules" { return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": [["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]]])) }
            if path.hasSuffix("snapshot") { return V2HTTPResponse(status: 200, body: try v2SnapshotData()) }
            if path.hasSuffix("messages") { return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "module_id": v2ID, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": []])) }
            return V2HTTPResponse(status: 404, body: Data())
        }
        let model = CloudV2Model(client: V2Client(transport: transport, tokens: tokens, now: { v2Now }), defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        await model.sceneChanged(.active)
        for _ in 0..<100 where !model.telephonyReady { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.telephonyReady)
        model.number = "+12345678901"
        let dial = Task { await model.dial() }
        for _ in 0..<100 where dialContinuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(dialContinuation)
        await model.sceneChanged(.inactive); XCTAssertTrue(model.foreground); XCTAssertTrue(hangups.isEmpty)
        await model.sceneChanged(.background)
        dialContinuation?.resume(returning: V2HTTPResponse(status: 200, body: try v2Accepted(id: dialID)))
        await dial.value
        XCTAssertTrue(hangups.isEmpty)
        XCTAssertFalse(model.hasUnresolvedCommand); XCTAssertEqual(model.ownedCall?.callID, v2OtherID)
        await model.sceneChanged(.active)
        try await Task.sleep(for: .milliseconds(20))
        await model.sceneChanged(.background)
        try await Task.sleep(for: .milliseconds(20))
        await model.stop()
        XCTAssertTrue(hangups.isEmpty)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertNil(try V2FilePendingStore(url: root.appendingPathComponent("pending.json")).load())
    }
}

// Deliberately ignores cancellation, matching the observed SDK suspension.
@MainActor
private final class StubbornActivitySource: LegacyActivitySource {
    var pushToken: Data? = Data([1])
    var activities: [LegacyActivitySnapshot] = []
    var pushEmit: ((Data) -> Void)?
    var activityEmit: ((LegacyActivitySnapshot) -> Void)?
    var tokenEmit: [String: (Data) -> Void] = [:]
    var endEmit: [String: () -> Void] = [:]
    var globalContinuations: [CheckedContinuation<Void, Never>] = []
    var activityContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    var globalStarts = 0
    var activityStarts: [String: Int] = [:]
    func pushTokens(_ emit: @escaping @MainActor (Data) -> Void) async {
        globalStarts += 1; pushEmit = emit
        await withCheckedContinuation { globalContinuations.append($0) }
    }
    func activityUpdates(_ emit: @escaping @MainActor (LegacyActivitySnapshot) -> Void) async {
        globalStarts += 1; activityEmit = emit
        await withCheckedContinuation { globalContinuations.append($0) }
    }
    func observe(_ id: String, token: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor () -> Void) async {
        activityStarts[id, default: 0] += 1; tokenEmit[id] = token; endEmit[id] = ended
        await withCheckedContinuation { activityContinuations[id] = $0 }
    }
    func complete(_ id: String) { activityContinuations.removeValue(forKey: id)?.resume() }
    func finishAll() {
        for continuation in globalContinuations { continuation.resume() }; globalContinuations.removeAll()
        for continuation in activityContinuations.values { continuation.resume() }; activityContinuations.removeAll()
    }
}
extension CloudV2Tests {
    @MainActor func testActivityRuntimeSubscriptionsFinishWhileSourcesIgnoreCancellation() async throws {
        let source = StubbornActivitySource(), hub = LegacyActivityEvents(source: StubbornActivitySource())
        // A new v2-only process never starts either global observer.
        XCTAssertEqual(hub.globalCount, 0); XCTAssertEqual(hub.subscriptionCount, 0)
        let events = LegacyActivityEvents(source: source)
        let suite = "airsim.activity.test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); source.finishAll(); LegacyRuntimeGate.configure(false) }
        var businessWrites = 0
        for cycle in 0..<24 {
            LegacyRuntimeGate.configure(true); let stamp = LegacyRuntimeGate.generation
            let id = "activity-\(cycle)"
            source.activities = [LegacyActivitySnapshot(id: id, callID: "fixture", token: Data([2]))]
            let subscription = events.subscribe()
            let ended = expectation(description: "consumer stopped \(cycle)")
            let consumer = Task { @MainActor in
                for await _ in subscription.stream {
                    guard !Task.isCancelled, LegacyRuntimeGate.accepts(stamp) else { break }
                    businessWrites += 1; defaults.set(businessWrites, forKey: "writes")
                }
                ended.fulfill()
            }
            for _ in 0..<10 { await Task.yield() }
            LegacyRuntimeGate.configure(false)
            events.unsubscribe(subscription.id); consumer.cancel()
            await fulfillment(of: [ended], timeout: 1)
            await consumer.value
            let stoppedWrites = businessWrites
            source.pushEmit?(Data([3]))
            source.activityEmit?(LegacyActivitySnapshot(id: "late-\(cycle)", callID: "fixture", token: Data([4])))
            source.tokenEmit[id]?(Data([5]))
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(businessWrites, stoppedWrites)
            XCTAssertEqual(defaults.integer(forKey: "writes"), stoppedWrites)
            XCTAssertEqual(events.subscriptionCount, 0)
            XCTAssertEqual(events.globalCount, 2)
            XCTAssertLessThanOrEqual(events.activityCount, 16)
            XCTAssertEqual(events.retiredCount, events.activityCount)
        }
        XCTAssertEqual(source.globalStarts, 2)
        XCTAssertEqual(source.activityStarts.count, 16)
        XCTAssertTrue(events.limitReached)
        XCTAssertTrue(source.activityStarts.values.allSatisfy { $0 == 1 })
        source.finishAll()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events.activityCount, 0); XCTAssertEqual(events.globalCount, 0)
        XCTAssertTrue(events.limitReached) // Restart-required diagnostic remains latched.
    }
    @MainActor func testRetiredActivityKeepsLedgerUntilActualExitAndDoesNotRestartSameID() async {
        let source = StubbornActivitySource(), events: LegacyActivityEvents
        events = LegacyActivityEvents(source: source)
        source.activities = [LegacyActivitySnapshot(id: "same", callID: "fixture", token: nil)]
        let first = events.subscribe()
        for _ in 0..<10 { await Task.yield() }
        source.endEmit["same"]?()
        XCTAssertEqual(events.activityCount, 1); XCTAssertEqual(events.retiredCount, 1)
        events.unsubscribe(first.id)
        let second = events.subscribe()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(source.activityStarts["same"], 1)
        source.tokenEmit["same"]?(Data([9]))
        XCTAssertNil(events.currentActivities["same"]?.token)
        events.unsubscribe(second.id)
        source.complete("same")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(events.activityCount, 0); XCTAssertEqual(events.retiredCount, 0)
        source.finishAll()
    }
}

extension CloudV2Tests {
    @MainActor func testActivityEventsReconcileBoundedAuthoritativeSnapshotWithoutResurrection() async {
        let source = StubbornActivitySource(), events: LegacyActivityEvents
        events = LegacyActivityEvents(source: source)
        let live = LegacyActivitySnapshot(id: "live", callID: "fixture", token: Data([1]))
        source.activities = [live]
        let subscription = events.subscribe()
        var registeredIDs: [String] = []
        let consumer = Task { @MainActor in
            for await _ in subscription.stream {
                for activity in events.currentActivities.values where activity.token != nil { registeredIDs.append(activity.id) }
            }
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(source.activityStarts["live"], 1)
        registeredIDs.removeAll()
        // No ended callback arrives, but the system list has already removed the activity.
        source.activities = []
        source.activityEmit?(live)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(events.currentActivities.isEmpty)
        XCTAssertEqual(events.retiredCount, 1); XCTAssertEqual(events.activityCount, 1)
        for i in 0..<100 {
            source.activityEmit?(LegacyActivitySnapshot(id: "historical-\(i)", callID: "fixture", token: Data([2])))
        }
        source.tokenEmit["live"]?(Data([3]))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(events.currentActivities.isEmpty); XCTAssertTrue(registeredIDs.isEmpty)
        XCTAssertEqual(source.activityStarts.count, 1)
        source.complete("live")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(events.activityCount, 0)
        source.activities = (0..<40).map { LegacyActivitySnapshot(id: "current-\($0)", callID: "fixture", token: nil) }
        events.refreshCurrentActivities()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(events.currentActivities.count, 16)
        XCTAssertEqual(events.activityCount, 16); XCTAssertTrue(events.limitReached)
        source.activities = []
        events.refreshCurrentActivities()
        XCTAssertTrue(events.currentActivities.isEmpty)
        XCTAssertEqual(events.activityCount, 16); XCTAssertEqual(events.retiredCount, 16)
        events.unsubscribe(subscription.id); consumer.cancel(); await consumer.value
        source.finishAll()
    }
}

extension CloudV2Tests {
    @MainActor func testV2RealSimulatorEnginePrepareAndStopWithoutNetwork() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["AIRSIM_OPT_IN_HARDWARE_AUDIO_TEST"] == "1" else {
            throw XCTSkip("Hardware audio is verified by the explicit foreground local probe; XCTest RemoteIO previously aborted.")
        }
        let audio = V2AudioEngine()
        do {
            try await audio.prepare(microphone: true)
            try await Task.sleep(for: .milliseconds(300))
            _ = audio.takeCaptured()
            let metrics = audio.metrics
            NSLog("[AirSIM V2 Engine Test] rate=%.0f channels=%d voice_processing=%d captured=%llu running=%d", metrics.sampleRate, metrics.channels, metrics.voiceProcessing ? 1 : 0, metrics.captured, metrics.running ? 1 : 0)
            XCTAssertTrue(metrics.running); XCTAssertTrue(metrics.voiceProcessing)
        } catch {
            NSLog("[AirSIM V2 Engine Test] unavailable=%@", (error as? V2AudioError)?.message ?? String(describing: type(of: error)))
            if case V2AudioError.voiceProcessing = error {} else { XCTFail("Unexpected engine error: \(error)") }
        }
        await audio.stop(); await audio.stop()
        XCTAssertFalse(audio.metrics.running); XCTAssertEqual(audio.metrics.queuedPlayback, 0)
#endif
    }
}

@MainActor private final class V2TestMediaClock: V2MediaClock {
    var now: UInt64 = 0
    private var sleepers: [UUID: (UInt64, CheckedContinuation<Void, Error>)] = [:]
    func sleep(until: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { sleepers[id] = (until, continuation) }
            }
        } onCancel: { Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) } }
    }
    func advance(_ value: UInt64, wake: Bool = true) {
        now = value
        if wake { for (id, entry) in sleepers where entry.0 <= now { sleepers.removeValue(forKey: id)?.1.resume() } }
    }
}
@MainActor private final class V2TestAudioIO: V2AudioIO {
    var metrics = V2AudioMetrics()
    var onFailure: ((V2AudioError) -> Void)?
    var prepares = 0, stops = 0, plays = 0
    var frames: [Data] = []
    var prepareError: Error?
    var prepareBlock: (() async -> Void)?
    var stopBlock: (() async -> Void)?
    func prepare(microphone: Bool) async throws { prepares += 1; await prepareBlock?(); if let prepareError { throw prepareError }; metrics.running = true }
    func takeCaptured() -> [Data] { let result = frames; frames.removeAll(); metrics.captured += UInt64(result.count); return result }
    func play(_ pcm: Data) -> Bool { plays += 1; return true }
    func setMuted(_ value: Bool) {}
    func setSpeaker(_ value: Bool) throws {}
    func stop() async { stops += 1; await stopBlock?(); metrics.running = false }
}
@MainActor private final class V2TestMediaSocket: V2MediaSocket {
    var selected: String? = "airsim.media.v2"
    var messages: [URLSessionWebSocketTask.Message] = []
    var sent: [URLSessionWebSocketTask.Message] = []
    var limits: [Int] = [], cancelled = 0, writes = 0, maxWrites = 0
    var blockWrites = false
    private var reader: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var writer: CheckedContinuation<Void, Error>?
    func open(_ url: URL) async throws -> String? { selected }
    func limit(_ bytes: Int) { limits.append(bytes) }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        writes += 1; maxWrites = max(maxWrites, writes); sent.append(message)
        defer { writes -= 1 }
        if blockWrites { try await withCheckedThrowingContinuation { writer = $0 } }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
    func deliver(_ message: URLSessionWebSocketTask.Message) {
        if let reader { self.reader = nil; reader.resume(returning: message) } else { messages.append(message) }
    }
    func cancel() {
        cancelled += 1
        let reader = reader, writer = writer; self.reader = nil; self.writer = nil
        reader?.resume(throwing: CancellationError()); writer?.resume(throwing: CancellationError())
    }
}
private func v2MediaCreated(id: String = v2ID) throws -> V2MediaCreated {
    try V2JSON.decode(V2MediaCreated.self, from: v2Data(["session_id": id, "ticket": String(repeating: "a", count: 64), "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(30)), "media_url": "wss://media.example.invalid/v2/media", "format": ["sample_rate": 8000, "channels": 1, "sample_format": "s16le", "frame_samples": 160]]), limit: 4096)
}
private func v2HandshakeMessages() -> [URLSessionWebSocketTask.Message] {
    [.string("{\"type\":\"waiting\",\"session_id\":\"\(v2ID)\"}"), .string("{\"type\":\"paired\",\"session_id\":\"\(v2ID)\",\"format\":{\"sample_rate\":8000,\"channels\":1,\"sample_format\":\"s16le\",\"frame_samples\":160}}")]
}
@MainActor private func v2Yield(_ count: Int = 40) async { for _ in 0..<count { await Task.yield() } }

extension CloudV2Tests {
    func testV2PersistentResampling44100And48000HasCorrectFrequencyAndFragmentContinuity() throws {
        for rate in [44100.0, 48000.0] {
            func converted(chunk: Int) throws -> [Int16] {
                let converter = try V2PCMConverter(rate: rate)
                var output = Data()
                let total = Int(rate)
                for start in stride(from: 0, to: total, by: chunk) {
                    let samples = (start..<min(start + chunk, total)).map { Float(sin(Double($0) * 2 * .pi * 400 / rate) * 0.5) }
                    for frame in try samples.withUnsafeBufferPointer({ try converter.convert(samples: $0) }) { output.append(frame) }
                }
                return stride(from: 0, to: output.count, by: 2).map { Int16(bitPattern: UInt16(output[$0]) | UInt16(output[$0 + 1]) << 8) }
            }
            let fragmented = try converted(chunk: 257), regular = try converted(chunk: Int(rate * 0.02))
            XCTAssertGreaterThanOrEqual(fragmented.count, 7840); XCTAssertLessThanOrEqual(fragmented.count, 8000)
            XCTAssertEqual(fragmented.count, regular.count)
            let delta = zip(fragmented, regular).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThan(delta, 20)
            let samples = Array(fragmented.dropFirst(320))
            let rising = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            XCTAssertEqual(Double(rising) / (Double(samples.count) / 8000), 400, accuracy: 3)
        }
    }
    func testV2PlaybackWindowRejectsFourthBufferAndStaleCompletions() {
        var window = V2PlaybackWindow()
        let first = window.reserve()!
        XCTAssertNotNil(window.reserve()); XCTAssertNotNil(window.reserve()); XCTAssertNil(window.reserve())
        XCTAssertEqual(window.pending, 3)
        XCTAssertTrue(window.complete(first)); XCTAssertEqual(window.pending, 2)
        window.reset(); _ = window.reserve()
        XCTAssertFalse(window.complete(first)); XCTAssertEqual(window.pending, 1)
    }
    @MainActor func testV2DiagnosticEnergyMeasuresPCMAndEchoWithoutCountingPadding() throws {
#if DEBUG
        var pcm = Data()
        // Alternating -32768 and +256 verifies signed little endian and safe abs.
        for _ in 0..<80 { pcm.append(contentsOf: [0, 128, 0, 1]) }
        let silence = Data(repeating: 0, count: 320)
        let diagnostic = V2DiagnosticAudio()
        diagnostic.start(at: 0)
        diagnostic.receive(pcm, at: 0); diagnostic.receive(silence, at: 0)
        let expected = sqrt((Double(32768) * 32768 + Double(256) * 256) / 4)
        XCTAssertEqual(diagnostic.receivedEnergy.frames, 2)
        XCTAssertEqual(diagnostic.receivedEnergy.nonzeroFrames, 1)
        XCTAssertEqual(diagnostic.receivedEnergy.peak, 32768)
        XCTAssertEqual(diagnostic.receivedEnergy.rms, expected, accuracy: 0.0001)
        for tick in 0..<20 { _ = diagnostic.output(at: UInt64(tick) * 20_000_000) }
        XCTAssertEqual(diagnostic.echoEnergy.frames, 0)
        XCTAssertEqual(diagnostic.output(at: 400_000_000), pcm)
        XCTAssertEqual(diagnostic.output(at: 420_000_000), silence)
        XCTAssertEqual(diagnostic.echoEnergy, diagnostic.receivedEnergy)
        _ = diagnostic.output(at: 440_000_000)
        XCTAssertEqual(diagnostic.echoEnergy.frames, 2) // Synthetic silence is not echo.
        let received = diagnostic.receivedEnergy, echo = diagnostic.echoEnergy
        diagnostic.stop(); diagnostic.stop()
        XCTAssertEqual(diagnostic.receivedEnergy, received); XCTAssertEqual(diagnostic.echoEnergy, echo)
        diagnostic.start(at: 1_000_000_000)
        XCTAssertEqual(diagnostic.receivedEnergy, V2PCMEnergySummary())
        XCTAssertEqual(diagnostic.echoEnergy, V2PCMEnergySummary())
#endif
    }
    @MainActor func testV2DiagnosticEchoDoesNotStarveOrReplayPromptPeriodAndIsBounded() {
        let pcm = Data(repeating: 17, count: 320), prompt = Data(repeating: 31, count: 320)
        let diagnostic = V2DiagnosticAudio(prompt: [prompt, prompt])
        diagnostic.start(at: 0)
        diagnostic.receive(pcm, at: 0); XCTAssertEqual(diagnostic.echoCount, 0)
        XCTAssertEqual(diagnostic.output(at: 0), prompt)
        diagnostic.receive(pcm, at: 20_000_000); XCTAssertEqual(diagnostic.output(at: 20_000_000), prompt)
        var real = 0
        for i in 2..<502 {
            let now = UInt64(i) * 20_000_000
            diagnostic.receive(pcm, at: now) // Receive happens first at every 50fps boundary.
            if diagnostic.output(at: now) == pcm { real += 1 }
            XCTAssertLessThanOrEqual(diagnostic.echoCount, 20)
        }
        XCTAssertGreaterThan(real, 400)
        _ = diagnostic.output(at: 12_000_000_000)
        XCTAssertEqual(diagnostic.echoCount, 0)
        XCTAssertNotEqual(diagnostic.output(at: 12_020_000_000), pcm)
        XCTAssertGreaterThan(diagnostic.echoDrops, 0)
    }
    @MainActor func testV2DeadlineRejectsLateResponseEvenBeforeTimerRuns() async {
        let clock = V2TestMediaClock()
        var response: CheckedContinuation<Int, Error>?, cancels = 0
        let task = Task {
            try await V2MediaDeadline<Int>().run(clock: clock, until: 100, cancel: { cancels += 1 }) {
                try await withCheckedThrowingContinuation { response = $0 }
            }
        }
        await v2Yield()
        clock.advance(101, wake: false); response?.resume(returning: 7)
        do { _ = try await task.value; XCTFail("Late response must time out") } catch { XCTAssertTrue(error is V2MediaFailure) }
        XCTAssertGreaterThan(cancels, 0)
    }
    @MainActor func testV2HandshakeRejectsWrongProtocolOrderAndOversizedAuthentication() async throws {
        for scenario in 0..<4 {
            let audio = V2TestAudioIO(), socket = V2TestMediaSocket(), clock = V2TestMediaClock()
            socket.messages = v2HandshakeMessages()
            if scenario == 0 { socket.selected = "wrong" }
            if scenario == 1 { socket.messages.removeFirst() }
            if scenario == 2 { socket.messages[0] = .string(String(repeating: "x", count: 2049)) }
            if scenario == 3 { socket.messages[1] = socket.messages[0] }
            var deletes = 0
            let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in deletes += 1 })
            media.start(context: V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID), diagnosticMode: false, validate: { true })
            await v2Yield(100)
            if case .failed = media.state {} else { XCTFail("Expected failure: \(scenario) \(media.state)") }
            XCTAssertFalse(media.active); XCTAssertFalse(audio.metrics.running); XCTAssertEqual(deletes, 1)
            await media.stop(); XCTAssertEqual(deletes, 1)
        }
    }
    @MainActor func testV2AuthWaitingDeadlineIsThreeSecondsAndNeverCreatesAgain() async throws {
        let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
        var creates = 0
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in creates += 1; return try v2MediaCreated() }, delete: { _, _ in })
        media.start(context: V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID), diagnosticMode: false, validate: { true })
        await v2Yield(); clock.advance(3_000_000_000); await v2Yield(100)
        if case .failed = media.state {} else { XCTFail() }
        XCTAssertEqual(creates, 1); XCTAssertGreaterThan(socket.cancelled, 0)
        await media.stop()
    }
    @MainActor func testV2SerialWriteDeadlineCancelsAndKeepsOneInFlight() async throws {
        let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
        socket.messages = v2HandshakeMessages()
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
        media.start(context: V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID), diagnosticMode: false, validate: { true })
        await v2Yield(); XCTAssertEqual(media.state, .paired)
        socket.blockWrites = true; audio.frames = [Data(repeating: 1, count: 320)]
        clock.advance(5_000_000); await v2Yield()
        clock.advance(45_000_000); await v2Yield()
        XCTAssertEqual(socket.writes, 1)
        clock.advance(145_000_000); await v2Yield(100)
        XCTAssertEqual(socket.maxWrites, 1); XCTAssertEqual(media.statistics.writeTimeouts, 1)
        XCTAssertFalse(media.active); XCTAssertFalse(audio.metrics.running)
        await media.stop()
    }
    @MainActor func testV2DownlinkFailureEvidenceSurvivesStopAndResetsOnNewStart() async throws {
        let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
        socket.messages = v2HandshakeMessages()
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, diagnosticMode: false, validate: { true })
        await v2Yield(); XCTAssertEqual(media.state, .paired)
        clock.advance(500_000_000)
        socket.deliver(.data(try V2ASMPFrame(sessionID: v2ID, direction: 2, sequence: 1, pcm: Data(repeating: 0, count: 320)).encode()))
        await v2Yield()
        audio.frames = [Data(repeating: 0, count: 320)]
        clock.advance(2_500_000_000); await v2Yield(100)
        let failure = try XCTUnwrap(media.lastFailure)
        XCTAssertEqual(failure.code, .downlinkStopped)
        XCTAssertEqual(failure.stage, .ticking)
        XCTAssertEqual(failure.downlinkAgeMilliseconds, 2000)
        XCTAssertNil(failure.domain); XCTAssertNil(failure.numericCode)
        await media.stop()
        XCTAssertEqual(media.lastFailure, failure)
        media.requestStop(); await v2Yield(100)
        XCTAssertEqual(media.lastFailure, failure)
        socket.messages = v2HandshakeMessages()
        media.start(context: context, diagnosticMode: false, validate: { true })
        XCTAssertNil(media.lastFailure)
        await v2Yield(); XCTAssertEqual(media.state, .paired)
        await media.stop()
    }
    func testV2RouteCategoriesAreFixedDeduplicatedAndHandleEmpty() {
#if DEBUG
        XCTAssertEqual(V2AudioPortCategory.categories([]), [.none])
        XCTAssertEqual(V2AudioPortCategory.categories([.builtInMic, .builtInReceiver, .builtInSpeaker]), [.builtInMicrophone, .receiver, .speaker])
        XCTAssertEqual(V2AudioPortCategory.categories([.headphones, .headsetMic, .usbAudio, .lineIn, .lineOut]), [.wired])
        XCTAssertEqual(V2AudioPortCategory.categories([.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]), [.bluetooth])
        XCTAssertEqual(V2AudioPortCategory.classify(AVAudioSession.Port(rawValue: "unrecognized")), .other)
#endif
    }
    @MainActor func testV2RealPathEnergyFreezesAndResetsWithSilentSend() async throws {
#if DEBUG
        let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
        socket.messages = v2HandshakeMessages()
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, diagnosticMode: false, validate: { true })
        await v2Yield()
        audio.frames = [Data(repeating: 0, count: 320)]
        socket.deliver(.data(try V2ASMPFrame(sessionID: v2ID, direction: 2, sequence: 1, pcm: Data(repeating: 1, count: 320)).encode()))
        clock.advance(5_000_000); await v2Yield()
        clock.advance(45_000_000); await v2Yield()
        await media.stop()
        let sent = media.statistics.sentPCMEnergy, received = media.statistics.receivedPCMEnergy
        XCTAssertEqual(sent.frames, 1); XCTAssertEqual(sent.nonzeroFrames, 0)
        XCTAssertEqual(sent.rms, 0); XCTAssertEqual(sent.peak, 0)
        XCTAssertEqual(received.frames, 1); XCTAssertEqual(received.nonzeroFrames, 1)
        XCTAssertEqual(received.rms, 257); XCTAssertEqual(received.peak, 257)
        await media.stop(); media.requestStop(); await v2Yield(100)
        XCTAssertEqual(media.statistics.sentPCMEnergy, sent); XCTAssertEqual(media.statistics.receivedPCMEnergy, received)
        socket.messages = v2HandshakeMessages()
        media.start(context: context, diagnosticMode: false, validate: { true })
        XCTAssertEqual(media.statistics.sentPCMEnergy, V2PCMEnergySummary())
        XCTAssertEqual(media.statistics.receivedPCMEnergy, V2PCMEnergySummary())
        await v2Yield(); await media.stop()
#endif
    }

    @MainActor func testV2TimingAggregatesFreezeAndResetWithoutChangingClockPolicy() async throws {
#if DEBUG
        let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
        socket.messages = v2HandshakeMessages()
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, diagnosticMode: false) {
            clock.advance(clock.now + 250_000, wake: false); return true
        }
        await v2Yield()
        XCTAssertEqual(media.state, .paired)
        clock.advance(clock.now + 25_000_000); await v2Yield()
        await media.stop()
        let final = media.statistics
        XCTAssertEqual(final.validationCount, 2)
        XCTAssertEqual(final.validationTotalNanoseconds, 500_000)
        XCTAssertEqual(final.validationMaxMicroseconds, 250)
        XCTAssertEqual(final.tickIntervalsAtLeast20ms, 1)
        XCTAssertEqual(final.maxTickIntervalMilliseconds, 25)
        XCTAssertEqual(final.pairedElapsedMilliseconds, 25)
        func timing(_ value: V2MediaStatistics) -> [UInt64] {
            [value.pairedElapsedMilliseconds, value.validationCount, value.validationTotalNanoseconds,
             value.validationMaxMicroseconds, value.tickIntervalsAtLeast20ms, value.maxTickIntervalMilliseconds,
             value.maxSuccessfulWriteMilliseconds]
        }
        clock.advance(clock.now + 1_000_000_000)
        await media.stop(); media.requestStop(); await v2Yield(100)
        XCTAssertEqual(timing(media.statistics), timing(final))
        socket.messages = v2HandshakeMessages()
        media.start(context: context, diagnosticMode: false, validate: { true })
        XCTAssertEqual(timing(media.statistics), timing(V2MediaStatistics()))
        await v2Yield(); await media.stop()
#endif
    }

    @MainActor func testV2RepeatedStopPreservesNonzeroFinalQueueStatistics() async throws {
        let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
        let pcm = Data(repeating: 1, count: 320)
        socket.messages = v2HandshakeMessages()
        for sequence in 1...7 {
            socket.messages.append(.data(try V2ASMPFrame(sessionID: v2ID, direction: 2, sequence: UInt64(sequence), pcm: pcm).encode()))
        }
        audio.frames = Array(repeating: pcm, count: 7)
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, diagnosticMode: false, validate: { true })
        await v2Yield(100); XCTAssertEqual(media.state, .paired)
        // Overflow both five-frame queues, then skip expired slots and render silence.
        clock.advance(200_000_000); await v2Yield()
        clock.advance(220_000_000); await v2Yield()
        await media.stop()
        let final = media.statistics
        XCTAssertGreaterThan(final.queueDrops, 0)
        XCTAssertGreaterThan(final.skippedSlots, 0)
        XCTAssertGreaterThan(final.playbackZero, 0)
#if DEBUG
        XCTAssertGreaterThan(final.upQueueDrops, 0); XCTAssertGreaterThan(final.downQueueDrops, 0)
        XCTAssertEqual(final.queueDrops, final.upQueueDrops + final.downQueueDrops + final.captureOutputDrops + final.playbackDrops)
        XCTAssertEqual(final.skippedSlots, final.upSkippedSlots + final.downSkippedSlots)
#endif
        func counts(_ value: V2MediaStatistics) -> [UInt64] {
            var result = [value.received, value.sent, value.sequenceGaps, value.queueDrops, value.skippedSlots,
                          value.playbackZero, value.rendered, value.captureFrames, value.writeTimeouts, value.diagnosticZero]
#if DEBUG
            result += [value.upQueueDrops, value.downQueueDrops, value.upSkippedSlots, value.downSkippedSlots, value.captureOutputDrops, value.playbackDrops]
#endif
            return result
        }
        await media.stop()
        XCTAssertEqual(counts(media.statistics), counts(final))
        media.requestStop(); await v2Yield(100)
        XCTAssertEqual(counts(media.statistics), counts(final))
        await media.stop()
        XCTAssertEqual(counts(media.statistics), counts(final))
        socket.messages = v2HandshakeMessages()
        media.start(context: context, diagnosticMode: false, validate: { true })
        XCTAssertEqual(counts(media.statistics), counts(V2MediaStatistics()))
        await v2Yield(); await media.stop()
    }

    @MainActor func testV2TwoSecondWatchdogRequiresRealCaptureAndValidDownlink() async throws {
        for missingInput in [true, false] {
            let socket = V2TestMediaSocket(), clock = V2TestMediaClock(), audio = V2TestAudioIO()
            socket.messages = v2HandshakeMessages()
            let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
            media.start(context: V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID), diagnosticMode: false, validate: { true })
            await v2Yield()
            if missingInput { socket.deliver(.data(try V2ASMPFrame(sessionID: v2ID, direction: 2, sequence: 1, pcm: Data(repeating: 0, count: 320)).encode())) }
            else { audio.frames = [Data(repeating: 0, count: 320)] }
            clock.advance(1_000_000_000); await v2Yield()
            clock.advance(2_000_000_000); await v2Yield(100)
            if case .failed = media.state {} else { XCTFail() }
            XCTAssertFalse(media.active); await media.stop()
        }
    }
    @MainActor func testV2StopBarrierRejectsNewAttemptUntilOldPreparationAndDrainExit() async throws {
        let audio = V2TestAudioIO(), socket = V2TestMediaSocket(), clock = V2TestMediaClock()
        var preparation: CheckedContinuation<Void, Never>?, drain: CheckedContinuation<Void, Never>?
        audio.prepareBlock = { await withCheckedContinuation { preparation = $0 } }
        audio.stopBlock = { await withCheckedContinuation { drain = $0 } }
        var creates: [String] = []
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, id in creates.append(id); return try v2MediaCreated() }, delete: { _, _ in })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, diagnosticMode: false, validate: { true }); await v2Yield()
        let stopped = Task { await media.stop() }; await v2Yield()
        XCTAssertTrue(media.active); XCTAssertEqual(media.state, .stopping)
        media.start(context: context, diagnosticMode: false, validate: { true })
        XCTAssertEqual(audio.prepares, 1)
        preparation?.resume(); drain?.resume(); await stopped.value
        XCTAssertTrue(creates.isEmpty)
        audio.prepareBlock = nil; audio.stopBlock = nil; socket.messages = v2HandshakeMessages()
        media.start(context: context, diagnosticMode: false, validate: { true }); await v2Yield()
        XCTAssertEqual(media.state, .paired); XCTAssertEqual(creates.count, 1)
        await media.stop(); XCTAssertFalse(media.active)
    }
    @MainActor func testV2EnginePermissionAndDrainLateCompletionCannotStopReplacement() async throws {
        var callbacks: [(Bool) -> Void] = [], drain: CheckedContinuation<Void, Never>?
        var shouldDelay = true
        let audio = V2AudioEngine(requestPermission: { callbacks.append($0) }, drainHook: {
            if shouldDelay { await withCheckedContinuation { drain = $0 } }
        })
        let first = Task { try await audio.prepare(microphone: true) }; await v2Yield()
        XCTAssertEqual(callbacks.count, 1)
        let stop = Task { await audio.stop() }; await v2Yield()
        let second = Task { try await audio.prepare(microphone: true) }; await v2Yield()
        XCTAssertEqual(callbacks.count, 1)
        callbacks[0](true) // Already retired permission response must not touch AVAudioEngine.
        shouldDelay = false; drain?.resume(); await stop.value; await v2Yield()
        XCTAssertEqual(callbacks.count, 2)
        callbacks[1](false)
        do { try await first.value; XCTFail() } catch {}
        do { try await second.value; XCTFail() } catch { if case V2AudioError.permission = error {} else { XCTFail() } }
        XCTAssertFalse(audio.metrics.running); await audio.stop()
    }
}

extension CloudV2Tests {
    @MainActor func testV2RestoredOwnedActiveCallNeverAutomaticallyCreatesMedia() async throws {
        let suite = "airsim.restored.audio.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!, tokens = V2TestTokens()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        defaults.set(true, forKey: "airsim.v2.experimental-audio")
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        try V2FileOwnedCallStore(file: V2ProtectedFile(url: root.appendingPathComponent("owned-call.json"))).save(context)
        let transport = V2TestTransport { request in
            let path = request.url!.path
            if path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            if path == "/v2/modules" { return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": [["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]]])) }
            if path.hasSuffix("snapshot") { return V2HTTPResponse(status: 200, body: try v2SnapshotData(calls: [v2CallObject()])) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "module_id": v2ID, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": []]))
        }
        let audio = V2TestAudioIO(), socket = V2TestMediaSocket(), clock = V2TestMediaClock()
        socket.messages = v2HandshakeMessages()
        var creates = 0
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in creates += 1; return try v2MediaCreated() }, delete: { _, _ in })
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        let model = CloudV2Model(client: client, media: media, defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        await model.sceneChanged(.active)
        for _ in 0..<100 where !model.audioReady { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.audioReady); XCTAssertEqual(model.ownedCall, context)
        await v2Yield(); XCTAssertEqual(creates, 0); XCTAssertEqual(audio.prepares, 0)
        model.connectAudio(); await v2Yield(); XCTAssertEqual(creates, 1); XCTAssertEqual(media.state, .paired)
        socket.cancel(); await v2Yield(100)
        model.experimentalAudio = false; await v2Yield(); model.experimentalAudio = true
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(creates, 1) // Neither polling nor the off/on switch bypasses manual recovery.
        await model.stop()
    }
    @MainActor func testV2ExpiredSnapshotEligibilityEvidenceSurvivesStopAndResetsOnNewStart() async throws {
        let suite = "airsim.restored.audio.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!, tokens = V2TestTokens()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        defaults.set(true, forKey: "airsim.v2.experimental-audio")
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        try V2FileOwnedCallStore(file: V2ProtectedFile(url: root.appendingPathComponent("owned-call.json"))).save(context)
        let transport = V2TestTransport { request in
            let path = request.url!.path
            if path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            if path == "/v2/modules" { return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": [["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]]])) }
            if path.hasSuffix("snapshot") { return V2HTTPResponse(status: 200, body: try v2SnapshotData(calls: [v2CallObject()])) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "module_id": v2ID, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": []]))
        }
        let audio = V2TestAudioIO(), socket = V2TestMediaSocket(), clock = V2TestMediaClock()
        socket.messages = v2HandshakeMessages()
        var creates = 0
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in creates += 1; return try v2MediaCreated() }, delete: { _, _ in })
        var currentNow = v2Now
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        let model = CloudV2Model(client: client, media: media, defaults: defaults, root: root, tokens: tokens, now: { currentNow })
        await model.sceneChanged(.active)
        for _ in 0..<100 where !model.audioReady { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.audioReady); XCTAssertEqual(model.ownedCall, context)
        await v2Yield(); XCTAssertEqual(creates, 0); XCTAssertEqual(audio.prepares, 0)
        model.connectAudio(); await v2Yield(); XCTAssertEqual(creates, 1); XCTAssertEqual(media.state, .paired)
        currentNow = v2Now.addingTimeInterval(9)
        clock.advance(5_000_000); await v2Yield(100)
        let failure = try XCTUnwrap(model.lastEligibilityFailure)
        XCTAssertEqual(failure.reason, .snapshotExpired)
        XCTAssertEqual(try XCTUnwrap(failure.snapshotAgeSeconds), 9, accuracy: 0.001)
        await media.stop()
        XCTAssertEqual(model.lastEligibilityFailure, failure)
        currentNow = v2Now
        socket.messages = v2HandshakeMessages()
        model.connectAudio()
        XCTAssertNil(model.lastEligibilityFailure)
        await v2Yield(); XCTAssertEqual(media.state, .paired)
        await model.stop()
    }
    @MainActor func testV2ExplicitRecoveryUsesNewRequestSessionAndLateCallbacksCannotStopIt() async throws {
        let audio = V2TestAudioIO(), clock = V2TestMediaClock()
        let first = V2TestMediaSocket(), second = V2TestMediaSocket()
        first.messages = v2HandshakeMessages()
        second.messages = v2HandshakeMessages().map { message in
            if case .string(let text) = message { return .string(text.replacingOccurrences(of: v2ID, with: v2OtherID)) }
            return message
        }
        var requestIDs: [String] = [], deleted: [String] = [], deleteFinished: CheckedContinuation<Void, Never>?
        var socketIndex = 0
        let media = V2MediaCoordinator(audio: audio, socketFactory: { defer { socketIndex += 1 }; return socketIndex == 0 ? first : second }, clock: clock, now: { v2Now }, create: { _, id in
            requestIDs.append(id); return try v2MediaCreated(id: requestIDs.count == 1 ? v2ID : v2OtherID)
        }, delete: { _, id in
            deleted.append(id)
            if id == v2ID { await withCheckedContinuation { deleteFinished = $0 } }
        })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, diagnosticMode: false, validate: { true }); await v2Yield()
        let oldAudioFailure = audio.onFailure
        first.cancel(); await v2Yield(100)
        XCTAssertFalse(media.active); XCTAssertEqual(deleted, [v2ID])
        media.start(context: context, diagnosticMode: false, validate: { true }); await v2Yield()
        XCTAssertEqual(media.state, .paired); XCTAssertEqual(requestIDs.count, 2); XCTAssertNotEqual(requestIDs[0], requestIDs[1])
        oldAudioFailure?(.interrupted); first.deliver(.string("late")); deleteFinished?.resume()
        await v2Yield(); XCTAssertEqual(media.state, .paired); XCTAssertTrue(media.active)
        XCTAssertEqual(second.cancelled, 0)
        await media.stop(); await v2Yield(); await media.stop()
        XCTAssertEqual(deleted, [v2ID, v2OtherID])
    }
    func testV2SoftwareCaptureCapacityMuteAndLatePushAfterStop() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for channel in 0..<2 { for i in 0..<48000 { buffer.floatChannelData![channel][i] = channel == 0 ? 0.8 : 0.2 } }
        let capture = try V2CaptureBuffer(rate: 48000)
        capture.setMuted(true)
        for _ in 0..<8 { capture.push(buffer) }
        try await Task.sleep(for: .milliseconds(20))
        let muted = capture.pull()
        XCTAssertGreaterThan(muted.metrics.inputDrops, 0)
        XCTAssertGreaterThan(muted.metrics.captured, 0)
        XCTAssertLessThanOrEqual(muted.frames.count, 5)
        XCTAssertTrue(muted.frames.allSatisfy { $0 == Data(repeating: 0, count: 320) })
#if DEBUG
        var mutedEnergy = V2PCMEnergySummary()
        muted.frames.forEach { mutedEnergy.record($0) }
        XCTAssertGreaterThan(mutedEnergy.frames, 0)
        XCTAssertEqual(mutedEnergy.nonzeroFrames, 0); XCTAssertEqual(mutedEnergy.rms, 0); XCTAssertEqual(mutedEnergy.peak, 0)
#endif
        XCTAssertTrue(capture.pull().frames.isEmpty) // Mute does not synthesize frames without capture.
        capture.setMuted(false); capture.push(buffer)
        try await Task.sleep(for: .milliseconds(20))
        let unmuted = capture.pull()
        XCTAssertFalse(unmuted.frames.isEmpty); XCTAssertLessThanOrEqual(unmuted.frames.count, 5)
        XCTAssertTrue(unmuted.frames.contains { $0 != Data(repeating: 0, count: 320) })
        await capture.stop(); capture.push(buffer)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(capture.pull().frames.isEmpty)
        await capture.stop()
    }
}

extension CloudV2Tests {
    @MainActor func testV2SpeechPromptMemorySmokeOnIOS27() async throws {
#if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { throw XCTSkip("Speech smoke is limited to the approved iOS 27 audio simulator") }
        let diagnostic = V2DiagnosticAudio()
        do { try await diagnostic.prepare() }
        catch { XCTFail("Speech prepare failed: format=\(diagnostic.sourceFormat) error=\(error)"); diagnostic.stop(); return }
        diagnostic.start(at: 0)
        var promptFrames = 0, nonzero = false
        // Stop at the first injection gap: echoes are empty, and prompt output precedes zeros.
        for i in 0..<1501 {
            let before = diagnostic.zeroFrames
            let frame = diagnostic.output(at: UInt64(i) * 20_000_000)
            if diagnostic.zeroFrames > before { break }
            if let frame { promptFrames += 1; nonzero = nonzero || frame.contains(where: { $0 != 0 }) }
        }
        NSLog("[AirSIM V2 Speech Test] frames=%d duration_ms=%d nonzero=%d", promptFrames, promptFrames * 20, nonzero ? 1 : 0)
        XCTAssertGreaterThan(promptFrames, 0); XCTAssertLessThanOrEqual(promptFrames, 1500)
        XCTAssertGreaterThan(promptFrames * 20, 1000); XCTAssertTrue(nonzero)
        diagnostic.stop()
#endif
    }
}

@MainActor private final class V2PollFixture {
    let suite = "airsim.poll.\(UUID())"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let tokens = V2TestTokens()
    private let started = Date()
    var currentNow: Date { v2Now.addingTimeInterval(Date().timeIntervalSince(started)) }
    var defaults: UserDefaults!
    var model: CloudV2Model!
    var counts: [String: Int] = [:], inFlight: [String: Int] = [:], maxInFlight: [String: Int] = [:]
    var blocked = Set<String>(), failed = Set<String>()
    var directoryBlocksAfterFirst = false
    var pending: [String: CheckedContinuation<V2HTTPResponse, Error>] = [:]
    var snapshotCalls: [[String: Any]] = []
    var writes = 0
    var commandHTTPStatus: Int?
    var delayedReceipts = false
    var receiptReads = 0
    var receiptCompletionAfter = 1
    var receiptFails = false
    var receiptUnknown = false
    var commands: [[String: Any]] = []
    init(media: V2MediaCoordinator? = nil) throws {
        defaults = UserDefaults(suiteName: suite)!
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        let transport = V2TestTransport { [unowned self] request in
            if request.httpMethod != "GET" { writes += 1 }
            let path = request.url!.path
            if path.contains("commands"), delayedReceipts {
                if request.httpMethod == "POST", let data = request.httpBody,
                   let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let command = wrapper["command"] as? [String: Any] {
                    commands.append(command)
                    return V2HTTPResponse(status: 202, body: try v2Data(["command_id": command["command_id"]!, "state": "pending", "generation": v2ID, "receipt": NSNull()]))
                }
                receiptReads += 1
                let command = commands.last!
                let id = command["command_id"] as! String
                if receiptReads <= receiptCompletionAfter {
                    return V2HTTPResponse(status: 200, body: try v2Data(["command_id": id, "state": receiptUnknown ? "outcome_unknown" : "pending", "generation": v2ID, "receipt": NSNull()]))
                }
                var result = try JSONSerialization.jsonObject(with: v2Accepted(id: id, action: command["action"] as! String)) as! [String: Any]
                if receiptFails {
                    var receipt = result["receipt"] as! [String: Any]; receipt["state"] = "failed"; result["receipt"] = receipt
                }
                return V2HTTPResponse(status: 200, body: try v2Data(result))
            }
            if path.contains("commands"), let status = commandHTTPStatus {
                if status == 200, let data = request.httpBody,
                   let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let command = wrapper["command"] as? [String: Any], let id = command["command_id"] as? String {
                    commands.append(command)
                    return V2HTTPResponse(status: 200, body: try v2Accepted(id: id, action: command["action"] as! String, callID: command["action"] as? String == "sms.send" ? nil : v2OtherID))
                }
                return V2HTTPResponse(status: status, body: Data())
            }
            if path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            let lane = path == "/v2/modules" ? "directory" : (path.hasSuffix("snapshot") ? "snapshot" : "messages")
            counts[lane, default: 0] += 1; inFlight[lane, default: 0] += 1
            maxInFlight[lane] = max(maxInFlight[lane, default: 0], inFlight[lane, default: 0])
            defer { inFlight[lane, default: 0] -= 1 }
            if blocked.contains(lane) || (lane == "directory" && directoryBlocksAfterFirst && counts[lane, default: 0] > 1) {
                return try await withCheckedThrowingContinuation { pending[lane] = $0 }
            }
            if failed.contains(lane) { throw V2Error.transport }
            return try response(lane, module: path.contains(v2OtherID) ? v2OtherID : v2ID)
        }
        model = CloudV2Model(client: V2Client(transport: transport, tokens: tokens, now: { [unowned self] in currentNow }), media: media, defaults: defaults, root: root, tokens: tokens, now: { [unowned self] in currentNow })
    }
    func response(_ lane: String, module: String = v2ID) throws -> V2HTTPResponse {
        let body: Data
        if lane == "directory" {
            body = try v2Data(["server_id": v2ID, "modules": [v2ID, v2OtherID].map { ["module_id": $0, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID] }])
        } else if lane == "snapshot" { body = try v2SnapshotData(module: module, age: -currentNow.timeIntervalSince(v2Now), calls: snapshotCalls) }
        else { body = try v2Data(["server_id": v2ID, "module_id": module, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": []]) }
        return V2HTTPResponse(status: 200, body: body)
    }
    func release(_ lane: String, status: Int = 200) throws {
        pending.removeValue(forKey: lane)?.resume(returning: status == 200 ? try response(lane) : V2HTTPResponse(status: status, body: Data()))
    }
    private var closed = false
    func close() async {
        guard !closed else { return }; closed = true
        let stop = Task { await model.stop() }
        await v2Yield()
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        await stop.value
        defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
    }
}
@MainActor private func v2PollWait(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Polling condition did not complete within ten seconds")
}
extension CloudV2Tests {
    @MainActor func testIndependentPollingKeepsSnapshotsFlowingWhileOtherLanesBlock() async throws {
        for lane in ["messages", "directory"] {
            let fixture = try V2PollFixture()
            if lane == "directory" { fixture.directoryBlocksAfterFirst = true }
            else { fixture.blocked.insert(lane) }
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.pending[lane] != nil }
            let before = fixture.counts["snapshot", default: 0]
            try await v2PollWait { fixture.counts["snapshot", default: 0] >= before + 2 }
            XCTAssertTrue(fixture.model.telephonyReady)
            XCTAssertLessThan(fixture.currentNow.timeIntervalSince(try XCTUnwrap(fixture.model.snapshot?.snapshot?.observedAt)), 2)
            XCTAssertEqual(fixture.maxInFlight[lane], 1)
            XCTAssertTrue(fixture.maxInFlight.values.allSatisfy { $0 == 1 })
            XCTAssertEqual(fixture.writes, 0)
            await fixture.close()
        }
    }
    @MainActor func testPollingInactiveActiveDoesNotRestartOrCancelLiveLanes() async throws {
        let fixture = try V2PollFixture(); fixture.blocked = ["snapshot", "messages", "directory"]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.pending.count == 3 }
        await fixture.model.sceneChanged(.inactive)
        await fixture.model.sceneChanged(.active)
        XCTAssertEqual(fixture.counts, ["snapshot": 1, "messages": 1, "directory": 1])
        fixture.blocked.removeAll()
        for lane in ["snapshot", "messages", "directory"] { try fixture.release(lane) }
        try await v2PollWait { fixture.model.telephonyReady && fixture.model.messagesResponse != nil }
        await fixture.close()
    }
    @MainActor func testPollingLaneFailureIsNotHiddenBySnapshotSuccess() async throws {
        let fixture = try V2PollFixture(); fixture.failed.insert("messages")
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.counts["snapshot", default: 0] >= 3 }
        XCTAssertTrue(fixture.model.telephonyReady)
        XCTAssertTrue(fixture.model.syncStatus?.contains("短信") == true)
        fixture.failed.remove("messages")
        try await v2PollWait { fixture.model.messagesResponse != nil && fixture.model.syncStatus == nil }
        await fixture.close()
    }
    @MainActor func testPollingBackgroundWaitsForAllLanesAndRejectsLateResults() async throws {
        let fixture = try V2PollFixture(); fixture.blocked = ["snapshot", "messages", "directory"]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.pending.count == 3 }
        var finished = false
        let background = Task { await fixture.model.sceneChanged(.background); finished = true }
        await v2Yield(); XCTAssertFalse(finished)
        for lane in ["snapshot", "messages", "directory"] { try fixture.release(lane) }
        await background.value
        XCTAssertNil(fixture.model.snapshot); XCTAssertNil(fixture.model.messagesResponse)
        XCTAssertTrue(fixture.model.modules.isEmpty); XCTAssertTrue(fixture.model.history.calls.isEmpty)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }
    @MainActor func testPollingModuleSwitchJoinsOldLanesBeforeApplyingNewModule() async throws {
        let fixture = try V2PollFixture(); fixture.blocked = ["snapshot", "messages"]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.pending.count == 2 && fixture.model.modules.count == 2 }
        var finished = false
        let change = Task { await fixture.model.selectModule(v2OtherID); finished = true }
        await v2Yield(); XCTAssertFalse(finished)
        fixture.blocked.removeAll()
        try fixture.release("snapshot", status: 401); try fixture.release("messages")
        await change.value
        try await v2PollWait { fixture.model.snapshot?.module_id == v2OtherID && fixture.model.messagesResponse?.module_id == v2OtherID }
        XCTAssertTrue(fixture.model.connected)
        XCTAssertEqual(fixture.model.selectedModuleID, v2OtherID)
        XCTAssertTrue(fixture.maxInFlight.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }
    @MainActor func testPolling401CancelsAllLanesWithoutLateStateOrStatusOverwrite() async throws {
        let fixture = try V2PollFixture(); fixture.blocked = ["snapshot", "messages", "directory"]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.pending.count == 3 }
        try fixture.release("messages", status: 401)
        try await v2PollWait { !fixture.model.connected }
        let status = fixture.model.syncStatus
        try fixture.release("snapshot"); try fixture.release("directory")
        await v2Yield(100)
        XCTAssertNil(fixture.model.snapshot); XCTAssertNil(fixture.model.messagesResponse)
        XCTAssertTrue(fixture.model.modules.isEmpty); XCTAssertEqual(fixture.model.syncStatus, status)
        XCTAssertTrue(status?.contains("凭据") == true); XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }
}

extension CloudV2Tests {
    func testHistoryCachedDatesWireEqualityAndNoChangeNormalization() throws {
        let domain = V2HistoryDomain(identity: v2Config().identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2ID)
        let callWire = v2CallObject(state: "disconnected", date: "2026-10-24T00:00:00.25Z")
        let messageWire: [String: Any] = ["message_id": v2ID, "direction": "incoming", "sender": "", "recipient": "", "text": "fixture", "state": "received", "delivery": "unknown", "observed_at": "2026-10-24T00:00:00.5Z"]
        let call = try V2JSON.decode(V2Call.self, from: v2Data(callWire), limit: 1024)
        let message = try V2JSON.decode(V2Message.self, from: v2Data(messageWire), limit: 1024)
        XCTAssertEqual(call.observedAt, try V2Validation.date(call.observed_at))
        XCTAssertEqual(message.observedAt, try V2Validation.date(message.observed_at))
        let encodedCall = try JSONEncoder().encode(call), encodedMessage = try JSONEncoder().encode(message)
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: encodedCall) as! [String: Any]).keys), Set(callWire.keys))
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: encodedMessage) as! [String: Any]).keys), Set(messageWire.keys))
        XCTAssertEqual(try JSONDecoder().decode(V2Call.self, from: encodedCall), call)
        XCTAssertEqual(try JSONDecoder().decode(V2Message.self, from: encodedMessage), message)
        for badDate in ["2026-02-30T00:00:00Z", "2026-10-24T00:00:00Z\n", "2026-10-24T00:00:00+00:00"] {
            var badCall = callWire, badMessage = messageWire
            badCall["observed_at"] = badDate; badMessage["observed_at"] = badDate
            XCTAssertThrowsError(try V2JSON.decode(V2Call.self, from: v2Data(badCall), limit: 1024))
            XCTAssertThrowsError(try V2JSON.decode(V2Message.self, from: v2Data(badMessage), limit: 1024))
        }
        let storedCall = V2StoredCall(domain: domain, call: call)
        let storedMessage = V2StoredMessage(domain: domain, message: message, inboxGap: false, inboxDropped: 0)
        var history = V2History()
        XCTAssertTrue(history.merge(calls: [storedCall])); XCTAssertTrue(history.merge(messages: [storedMessage]))
        XCTAssertFalse(history.merge(calls: [storedCall])); XCTAssertFalse(history.merge(messages: [storedMessage]))
        XCTAssertFalse(history.merge(calls: [])); XCTAssertFalse(history.merge(messages: []))
        for key in callWire.keys where key != "call_id" {
            var wire = callWire; wire[key] = key == "observed_at" ? "2026-10-24T00:00:00.26Z" : "changed"
            let changed = V2StoredCall(domain: domain, call: try V2JSON.decode(V2Call.self, from: v2Data(wire), limit: 1024))
            XCTAssertNotEqual(changed, storedCall); XCTAssertTrue(history.merge(calls: [changed]))
            XCTAssertTrue(history.merge(calls: [storedCall]))
        }
        for key in messageWire.keys where key != "message_id" {
            var wire = messageWire; wire[key] = key == "observed_at" ? "2026-10-24T00:00:00.6Z" : "changed"
            let changed = V2StoredMessage(domain: domain, message: try V2JSON.decode(V2Message.self, from: v2Data(wire), limit: 1024), inboxGap: false, inboxDropped: 0)
            XCTAssertNotEqual(changed, storedMessage); XCTAssertTrue(history.merge(messages: [changed]))
            XCTAssertTrue(history.merge(messages: [storedMessage]))
        }
        XCTAssertTrue(history.merge(messages: [V2StoredMessage(domain: domain, message: message, inboxGap: true, inboxDropped: 0)]))
        XCTAssertTrue(history.merge(messages: [V2StoredMessage(domain: domain, message: message, inboxGap: true, inboxDropped: 2)]))
        let other = V2StoredCall(domain: V2HistoryDomain(identity: domain.identity, moduleID: v2OtherID, bootID: v2ID, backendEpoch: v2ID), call: call)
        XCTAssertTrue(history.merge(calls: [other]))
        XCTAssertEqual(history.calls.map(\.id), [storedCall.id, other.id].sorted())
        history.calls.append(storedCall)
        XCTAssertTrue(history.merge(calls: [])); XCTAssertEqual(history.calls.count, 2)
        // A transient incoming change followed by the original leaves the final history unchanged.
        var changedWire = callWire; changedWire["number"] = "changed"
        let transient = V2StoredCall(domain: domain, call: try V2JSON.decode(V2Call.self, from: v2Data(changedWire), limit: 1024))
        XCTAssertFalse(history.merge(calls: [transient, storedCall]))
        let legacyRoundTrip = try JSONDecoder().decode(V2History.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(legacyRoundTrip.calls, history.calls); XCTAssertEqual(legacyRoundTrip.messages, history.messages)
    }
    @MainActor func testUnchangedPollingHistoryDoesNotRewriteFile() async throws {
        let fixture = try V2PollFixture(); fixture.snapshotCalls = [v2CallObject(state: "disconnected")]
        await fixture.model.sceneChanged(.active)
        let url = fixture.root.appendingPathComponent("history.json")
        try await v2PollWait { FileManager.default.fileExists(atPath: url.path) }
        let sentinel = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let snapshots = fixture.counts["snapshot", default: 0], messages = fixture.counts["messages", default: 0]
        try await v2PollWait { fixture.counts["snapshot", default: 0] >= snapshots + 2 && fixture.counts["messages", default: 0] >= messages + 2 }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(fixture.model.history.calls.count, 1)
        await fixture.close()
    }
    @MainActor func testHistoryWriteFailureRetriesUnchangedResponse() async throws {
        let fixture = try V2PollFixture(); fixture.snapshotCalls = [v2CallObject(state: "disconnected")]
        fixture.blocked.insert("messages")
        let url = fixture.root.appendingPathComponent("history.json")
        // Created after model loading: forces the first atomic file write to fail.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.history.calls.count == 1 && fixture.model.syncStatus?.contains("通话状态") == true }
        let original = fixture.model.history.calls
        try FileManager.default.removeItem(at: url)
        try await v2PollWait { FileManager.default.fileExists(atPath: url.path) && fixture.model.syncStatus == nil }
        let persisted = try V2ProtectedFile<V2History>(url: url).load()
        XCTAssertEqual(persisted?.calls, original)
        XCTAssertEqual(fixture.model.history.calls, original)
        XCTAssertGreaterThanOrEqual(fixture.counts["snapshot", default: 0], 2)
        await fixture.close()
    }
}

extension CloudV2Tests {
    @MainActor func testProjectionAndLocalClearRemainDomainScoped() async throws {
        let suite = "airsim.ui.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let tokens = V2TestTokens()
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        func message(_ module: String, id: String = v2ID) throws -> V2StoredMessage {
            let value = try V2JSON.decode(V2Message.self, from: v2Data(["message_id": id, "direction": "incoming", "sender": "00000000001", "recipient": "", "text": "fixture", "state": "received", "delivery": "unknown", "observed_at": V2Validation.timestamp(v2Now)]), limit: 1024)
            return V2StoredMessage(domain: V2HistoryDomain(identity: v2Config().identity, moduleID: module, bootID: v2ID, backendEpoch: v2ID), message: value, inboxGap: false, inboxDropped: 0)
        }
        let first = try message(v2ID), other = try message(v2OtherID), fresh = try message(v2ID, id: v2OtherID)
        var history = V2History(); history.merge(messages: [first, other])
        let file = V2ProtectedFile<V2History>(url: root.appendingPathComponent("history.json"))
        try file.save(history)
        let cloud = CloudV2Model(defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        let app = AppModel(cloudV2: cloud)
        XCTAssertEqual(app.messages.map(\.deliveryID), [first.id])
        XCTAssertNil(cloud.error)
        XCTAssertFalse(cloud.busy); XCTAssertFalse(cloud.hasUnresolvedCommand)
        XCTAssertNil(cloud.ownedCall); XCTAssertNil(cloud.activeCall)
        try await v2PollWait { !cloud.media.active }
        XCTAssertFalse(app.blocksRuntimeSwitch)
        cloud.clearCurrentMessages(); app.projectCloudState()
        XCTAssertTrue(app.messages.isEmpty)
        var saved = try XCTUnwrap(file.load())
        XCTAssertEqual(saved.messages.map(\.id), [other.id])
        XCTAssertFalse(saved.merge(messages: [first, other]))
        XCTAssertTrue(saved.merge(messages: [fresh]))
        XCTAssertEqual(Set(saved.messages.map(\.id)), Set([other.id, fresh.id]))
        let oldData = try v2Data(["messages": [], "calls": []])
        XCTAssertNil(try JSONDecoder().decode(V2History.self, from: oldData).clearedMessageIDs)
    }

    @MainActor func testFailedLocalClearPreservesVisibleMessages() throws {
        let suite = "airsim.ui.clear." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let tokens = V2TestTokens()
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        let message = try V2JSON.decode(V2Message.self, from: v2Data(["message_id": v2ID, "direction": "incoming", "sender": "00000000001", "recipient": "", "text": "fixture", "state": "received", "delivery": "unknown", "observed_at": V2Validation.timestamp(v2Now)]), limit: 1024)
        let stored = V2StoredMessage(domain: V2HistoryDomain(identity: v2Config().identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2ID), message: message, inboxGap: false, inboxDropped: 0)
        var history = V2History(); history.merge(messages: [stored])
        let file = V2ProtectedFile<V2History>(url: root.appendingPathComponent("history.json"))
        try file.save(history)
        let cloud = CloudV2Model(defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        try file.clear()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("history.json"), withIntermediateDirectories: true)
        cloud.clearCurrentMessages()
        XCTAssertEqual(cloud.visibleMessages, [stored])
        XCTAssertNotNil(cloud.error)
        XCTAssertNil(cloud.history.clearedMessageIDs)
    }
}

// The displayed composer result follows the command receipt, never transport success alone.
extension CloudV2Tests {
    @MainActor func testSMSCompletedFailureAndUnknownResults() async throws {
        for status in [200, 409, 503] {
            let fixture = try V2PollFixture()
            fixture.commandHTTPStatus = status
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.messagingReady }
            let app = AppModel(cloudV2: fixture.model)
            let sent = await app.sendSMS(to: "00000000001", content: "QA 测试消息")
            XCTAssertEqual(sent, status == 200)
            XCTAssertEqual(fixture.model.hasUnresolvedCommand, status == 503)
            XCTAssertEqual(fixture.writes, 1)
            XCTAssertEqual(fixture.model.smsText, "QA 测试消息")
            await fixture.close()
        }
    }
}

extension CloudV2Tests {
    func testSystemHandlerEpochRejectsPreviousOwner() {
        let gate = SystemCallActionGate(), old = SystemCallActionGate()
        let stamp = gate.generation
        gate.advance()
        XCTAssertFalse(gate.accepts(stamp)); XCTAssertTrue(old.accepts(stamp))
    }
}

@MainActor private final class TestSystemCalls: V2SystemCallReporting {
    weak var handler: (any CallKitActionHandling)?
    var currentSystemCallUUID: UUID?
    var reports = 0, endings = 0
    var state: String?
    func setEnabled(_ enabled: Bool) { if !enabled { currentSystemCallUUID = nil } }
    func synchronize(call: CallRecord?, previous: CallRecord?, callerName: String?) {
        guard let call else { return }
        if currentSystemCallUUID == nil { currentSystemCallUUID = UUID(); reports += 1 }
        state = call.state
    }
    func reportCurrentCallEnded(reason: CXCallEndedReason) { endings += 1; currentSystemCallUUID = nil }
    func reportCurrentOutgoingConnected() { state = "active" }
}

extension CloudV2Tests {
    @MainActor func testSystemIncomingDedupAudioActivationAndBackgroundScope() async throws {
        let audio = V2TestAudioIO(), socket = V2TestMediaSocket(), clock = V2TestMediaClock()
        socket.messages = v2HandshakeMessages()
        let media = V2MediaCoordinator(audio: audio, socketFactory: { socket }, clock: clock, now: { v2Now }, create: { _, _ in try v2MediaCreated() }, delete: { _, _ in })
        let fixture = try V2PollFixture(media: media)
        fixture.commandHTTPStatus = 200
        var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls()
        fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { system.reports == 1 }
        let uuid = system.currentSystemCallUUID
        fixture.model.systemCalls?.observeSnapshot(); fixture.model.systemCalls?.observeSnapshot()
        XCTAssertEqual(system.reports, 1); XCTAssertEqual(system.currentSystemCallUUID, uuid)
        XCTAssertEqual(audio.prepares, 0)
        try await fixture.model.systemCalls?.callKitAnswer(origin: .system)
        incoming["state"] = "active"; incoming["ownership"] = "managed"; fixture.snapshotCalls = [incoming]
        try await v2PollWait { system.state == "active" }
        XCTAssertEqual(audio.prepares, 0); XCTAssertFalse(fixture.model.audioReady)
        await fixture.model.systemCalls?.callKitAudioSessionDidActivate()
        try await v2PollWait { audio.prepares == 1 }
        await fixture.model.sceneChanged(.background)
        let snapshots = fixture.counts["snapshot", default: 0]
        let directories = fixture.counts["directory", default: 0], messages = fixture.counts["messages", default: 0]
        try await v2PollWait { fixture.counts["snapshot", default: 0] > snapshots }
        XCTAssertEqual(fixture.counts["directory", default: 0], directories)
        XCTAssertEqual(fixture.counts["messages", default: 0], messages)
        XCTAssertEqual(fixture.writes, 1)
        fixture.model.systemCalls?.callKitAudioSessionDidDeactivate()
        try await v2PollWait { !audio.metrics.running }
        XCTAssertFalse(fixture.model.systemAudioActive)
        incoming["state"] = "disconnected"; fixture.snapshotCalls = [incoming]
        try await v2PollWait { system.endings == 1 }
        XCTAssertNil(system.currentSystemCallUUID)
        await fixture.close()
    }

    @MainActor func testSystemRejectTargetsTheVerifiedIncomingCall() async throws {
        let fixture = try V2PollFixture(); fixture.commandHTTPStatus = 200
        var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls(); fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { system.reports == 1 }
        try await fixture.model.systemCalls?.callKitEnd()
        XCTAssertEqual(fixture.writes, 1)
        XCTAssertEqual(fixture.commands.last?["action"] as? String, "call.hangup")
        XCTAssertEqual((fixture.commands.last?["args"] as? [String: String])?["call_id"], v2OtherID)
        XCTAssertTrue(fixture.model.hasUnresolvedCommand)
        XCTAssertNil(fixture.model.ownedCall)
        await fixture.close()
    }
}

extension CloudV2Tests {
    @MainActor func testProviderResetSubmitsOneOwnedHangup() async throws {
        let fixture = try V2PollFixture(); fixture.commandHTTPStatus = 200
        fixture.model.experimentalAudio = false
        var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls(); fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { system.reports == 1 }
        try await fixture.model.systemCalls?.callKitAnswer(origin: .system)
        incoming["state"] = "active"; incoming["ownership"] = "managed"; fixture.snapshotCalls = [incoming]
        try await v2PollWait { fixture.model.ownedControlReady && system.state == "active" }
        await fixture.model.systemCalls?.callKitProviderDidReset()
        await fixture.model.systemCalls?.callKitProviderDidReset()
        let hangups = fixture.commands.filter { $0["action"] as? String == "call.hangup" }
        XCTAssertEqual(hangups.count, 1)
        XCTAssertEqual((hangups.first?["args"] as? [String: String])?["call_id"], v2OtherID)
        XCTAssertFalse(fixture.model.systemAudioActive)
        await fixture.close()
    }
}

extension CloudV2Tests {
    @MainActor func testMessageGapUsesOnlySelectedModuleHistory() throws {
        let suite = "airsim.ui.gap." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let tokens = V2TestTokens()
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        let message = try V2JSON.decode(V2Message.self, from: v2Data(["message_id": v2ID, "direction": "incoming", "sender": "00000000001", "recipient": "", "text": "QA 测试消息", "state": "received", "delivery": "unknown", "observed_at": V2Validation.timestamp(v2Now)]), limit: 1024)
        let gap = V2StoredMessage(domain: V2HistoryDomain(identity: v2Config().identity, moduleID: v2OtherID, bootID: v2ID, backendEpoch: v2ID), message: message, inboxGap: true, inboxDropped: 1)
        var history = V2History(); history.merge(messages: [gap])
        try V2ProtectedFile<V2History>(url: root.appendingPathComponent("history.json")).save(history)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        let first = CloudV2Model(defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        XCTAssertFalse(first.hasMessageGap)
        defaults.set(v2OtherID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        let second = CloudV2Model(defaults: defaults, root: root, tokens: tokens, now: { v2Now })
        XCTAssertTrue(second.hasMessageGap)
        second.clearCurrentMessages()
        XCTAssertFalse(second.hasMessageGap)
    }
}


extension CloudV2Tests {
    @MainActor func testKnownDiscoveryProfilesWithoutAPNsRetainIdentityAndOriginChecks() async throws {
        for profile in ["airsim-v2-r4.1", "airsim-v2-callkit"] {
            for mismatch in ["none", "server_id", "api_origin", "media_origin", "apns", "profile"] {
                var discovery = try JSONSerialization.jsonObject(with: v2Discovery()) as! [String: Any]
                discovery["profile"] = profile
                switch mismatch {
                case "server_id": discovery["server_id"] = v2OtherID
                case "api_origin", "media_origin": discovery[mismatch] = "https://other.example.invalid"
                case "apns":
                    var capabilities = discovery["capabilities"] as! [String: Any]
                    capabilities["apns"] = true; discovery["capabilities"] = capabilities
                case "profile": discovery["profile"] = "airsim-v2-unknown"
                default: break
                }
                let body = try v2Data(discovery)
                let tokens = V2TestTokens()
                let transport = V2TestTransport { _ in V2HTTPResponse(status: 200, body: body) }
                let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
                do {
                    let result = try await client.connect(v2Config())
                    XCTAssertEqual(mismatch, "none")
                    XCTAssertEqual(result.profile, profile)
                    XCTAssertFalse(result.capabilities.apns)
                } catch {
                    XCTAssertNotEqual(mismatch, "none", "Known no-push profile must connect")
                    XCTAssertEqual(tokens.reads, 0)
                    XCTAssertNil(client.configuration)
                }
                XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
            }
        }
    }
}

extension CloudV2Tests {
    @MainActor func testSystem202AssociatesOriginalCommandInForegroundAndBackground() async throws {
        for background in [false, true] {
            for answer in [false, true] {
                let fixture = try V2PollFixture(); fixture.delayedReceipts = true
                addTeardownBlock { await fixture.close() }
                if answer {
                    var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
                    fixture.snapshotCalls = [incoming]
                }
                let system = TestSystemCalls()
                fixture.model.activateSystemIntegration(calls: system, associationTimeout: .seconds(5))
                await fixture.model.sceneChanged(.active)
                try await v2PollWait { fixture.model.freshBinding != nil }
                if answer {
                    try await v2PollWait { system.currentSystemCallUUID != nil }
                } else { system.currentSystemCallUUID = UUID() }
                let uuid = try XCTUnwrap(system.currentSystemCallUUID)
                let controller = try XCTUnwrap(fixture.model.systemCalls)
                let start = Task {
                    if answer { try await controller.callKitAnswer(origin: .system) }
                    else { try await controller.callKitStart(number: "00000000001") }
                }
                addTeardownBlock { start.cancel(); _ = await start.result }
                try await v2PollWait { fixture.writes == 1 }
                XCTAssertEqual(controller.authorizedBinding, fixture.model.freshBinding)
                if background { await fixture.model.sceneChanged(.background) }
                let directoryCount = fixture.counts["directory", default: 0]
                let messagesCount = fixture.counts["messages", default: 0]
                try await start.value
                XCTAssertGreaterThanOrEqual(fixture.receiptReads, 2)
                XCTAssertEqual(system.currentSystemCallUUID, uuid)
                XCTAssertEqual(fixture.model.ownedCall?.callID, v2OtherID)
                XCTAssertEqual(fixture.writes, 1); XCTAssertFalse(fixture.model.hasUnresolvedCommand)
                XCTAssertNil(fixture.model.error)
                if background {
                    XCTAssertEqual(fixture.counts["directory", default: 0], directoryCount)
                    XCTAssertEqual(fixture.counts["messages", default: 0], messagesCount)
                }
                await fixture.close()
            }
        }
    }
    @MainActor func testSystem202FailureClearsPendingAndTimeoutPreservesItWithoutReplay() async throws {
        for failure in [false, true] {
            let fixture = try V2PollFixture(); fixture.delayedReceipts = true
            addTeardownBlock { await fixture.close() }
            fixture.receiptFails = failure; fixture.receiptCompletionAfter = failure ? 0 : Int.max
            fixture.receiptUnknown = !failure
            let system = TestSystemCalls()
            fixture.model.activateSystemIntegration(calls: system, associationTimeout: .seconds(2))
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.freshBinding != nil }
            system.currentSystemCallUUID = UUID()
            do { try await fixture.model.systemCalls?.callKitStart(number: "00000000001"); XCTFail("Expected failed association") }
            catch { }
            XCTAssertEqual(fixture.model.hasUnresolvedCommand, !failure); XCTAssertNil(fixture.model.ownedCall)
            XCTAssertEqual(fixture.model.canAct, failure)
            XCTAssertEqual(fixture.writes, 1)
            await fixture.close()
        }
    }
    @MainActor func testSystemEndBeforeAssociationWaitsForDirectedHangup() async throws {
        for resolves in [false, true] {
            let fixture = try V2PollFixture(); fixture.delayedReceipts = true
            addTeardownBlock { await fixture.close() }
            fixture.receiptCompletionAfter = resolves ? 1 : Int.max
            let system = TestSystemCalls()
            fixture.model.activateSystemIntegration(calls: system, associationTimeout: .seconds(5), endAssociationTimeout: resolves ? .seconds(4) : .milliseconds(100))
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.freshBinding != nil }
            system.currentSystemCallUUID = UUID()
            let controller = try XCTUnwrap(fixture.model.systemCalls)
            let start = Task { try await controller.callKitStart(number: "00000000001") }
            addTeardownBlock { start.cancel(); _ = await start.result }
            try await v2PollWait { fixture.writes == 1 }
            if resolves { fixture.snapshotCalls = [v2CallObject(state: "active")] }
            try await controller.callKitEnd()
            XCTAssertEqual(fixture.writes, resolves ? 2 : 1)
            if resolves {
                XCTAssertEqual(fixture.commands.last?["action"] as? String, "call.hangup")
                XCTAssertEqual((fixture.commands.last?["args"] as? [String: String])?["call_id"], v2OtherID)
            }
            XCTAssertTrue(fixture.model.hasUnresolvedCommand)
            controller.callKitCallDidEnd(); system.currentSystemCallUUID = nil
            try await start.value
            await fixture.close()
        }
    }
    @MainActor func testSystemOldAssociationCannotTakeOverReplacementUUID() async throws {
        let fixture = try V2PollFixture(); fixture.delayedReceipts = true
        addTeardownBlock { await fixture.close() }
        let system = TestSystemCalls(); fixture.model.activateSystemIntegration(calls: system, associationTimeout: .seconds(4))
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.freshBinding != nil }
        system.currentSystemCallUUID = UUID()
        let controller = try XCTUnwrap(fixture.model.systemCalls)
        let start = Task { try await controller.callKitStart(number: "00000000001") }
        addTeardownBlock { start.cancel(); _ = await start.result }
        try await v2PollWait { fixture.writes == 1 }
        let replacement = UUID(); system.currentSystemCallUUID = replacement
        try await start.value
        XCTAssertEqual(system.currentSystemCallUUID, replacement); XCTAssertEqual(system.endings, 0)
        XCTAssertEqual(fixture.writes, 1)
        await fixture.close()
    }
}

extension CloudV2Tests {
    @MainActor func testSystemDTMF202RetainsPendingWithoutFailure() async throws {
        let fixture = try V2PollFixture(); fixture.commandHTTPStatus = 200
        addTeardownBlock { await fixture.close() }
        var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls(); fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { system.currentSystemCallUUID != nil }
        let controller = try XCTUnwrap(fixture.model.systemCalls)
        try await controller.callKitAnswer(origin: .system)
        fixture.snapshotCalls = [v2CallObject(state: "active")]
        try await v2PollWait { fixture.model.activeCall?.state == "active" }
        fixture.delayedReceipts = true
        try await controller.callKitPlayDTMF("1")
        XCTAssertEqual(fixture.writes, 2); XCTAssertTrue(fixture.model.hasUnresolvedCommand)
        XCTAssertEqual(fixture.commands.last?["action"] as? String, "call.dtmf")
        XCTAssertNil(fixture.model.error)
        await fixture.close()
    }
}

extension CloudV2Tests {
    @MainActor func testSystemExplicitRejectionReleasesPending() async throws {
        let fixture = try V2PollFixture(); fixture.commandHTTPStatus = 409
        addTeardownBlock { await fixture.close() }
        let system = TestSystemCalls(); fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.freshBinding != nil }
        system.currentSystemCallUUID = UUID()
        do { try await fixture.model.systemCalls?.callKitStart(number: "00000000001"); XCTFail("Expected explicit rejection") }
        catch { }
        XCTAssertFalse(fixture.model.hasUnresolvedCommand); XCTAssertTrue(fixture.model.canAct)
        XCTAssertNil(fixture.model.ownedCall); XCTAssertEqual(fixture.writes, 1)
        await fixture.close()
    }
}
