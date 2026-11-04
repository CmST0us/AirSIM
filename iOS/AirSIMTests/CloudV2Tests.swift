import XCTest
import AVFoundation
import CallKit
import Network
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
    func clear() throws { if fails { throw V2Error.persistence }; value = nil }
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
    @MainActor func testPersistentSessionNeedsNoExpiryOrRefreshAfterLongDormancy() async throws {
        let tokens = V2TestTokens()
        let current = V2Configuration(
            identity: V2Identity(apiOrigin: "https://example.invalid", serverID: v2ID, clientInstallationID: v2ID),
            mediaOrigin: "https://media.example.invalid",
            expiresAt: nil,
            moduleID: v2ID,
            refreshExpiresAt: nil,
            persistentSession: true
        )
        try tokens.save(String(repeating: "a", count: 64), account: current.identity.account)
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": []]))
        }
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now.addingTimeInterval(10 * 365 * 86400) })
        var refreshes = 0
        client.onRefreshConfiguration = { _ in
            refreshes += 1
            XCTFail("a permanent paired session must not refresh")
            return nil
        }
        _ = try await client.connect(current)
        _ = try await client.modules()
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(transport.requests.filter { $0.url?.path == "/v2/modules" }.last?.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 64))
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
            "name": "EG25 QDC507", "short_id": String(v2ID.suffix(8)), "online": true,
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
                "schema_version": 3, "api_origin": "https://example.invalid",
                "media_origin": "https://media.example.invalid", "server_id": v2ID,
                "module_id": v2ID, "client_installation_id": body["client_installation_id"]!,
                "token": String(repeating: "b", count: 64),
                "expires_at": NSNull(), "refresh_expires_at": NSNull(),
                "persistent_session": true,
            ]))
        }
        let pairing = V2PairingClient(origin: "https://example.invalid", store: pairings, transport: transport, now: { v2Now })
        let device = try await pairing.lookup(code: "00427193")
        XCTAssertEqual(device.name, "EG25 QDC507")
        do { _ = try await pairing.claim(code: "00427193", device: device); XCTFail() }
        catch { XCTAssertEqual(error as? V2Error, .transport) }
        XCTAssertNotNil(pairings.state.pending)
        let session = try await pairing.claim(code: "00427193", device: device)
        XCTAssertEqual(session.name, "EG25 QDC507")
        XCTAssertEqual(claims.count, 2)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: claims[0]) as? [String: String],
                       try JSONSerialization.jsonObject(with: claims[1]) as? [String: String])
        XCTAssertEqual(session.configuration.persistentSession, true)
        XCTAssertNil(session.configuration.expiresAt)
        XCTAssertNil(session.configuration.refreshExpiresAt)
        let store = V2ConfigurationStore(tokens: tokens, defaults: defaults, pairings: pairings)
        try store.commitPairedSession(session)
        XCTAssertEqual(try store.load(), session.configuration)
        XCTAssertEqual(defaults.string(forKey: V2LocalPaths.selectionKey(session.configuration.identity)), v2ID)
        defaults.removeObject(forKey: V2LocalPaths.selectionKey(session.configuration.identity))
        let restored = CloudV2Model(defaults: defaults, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), tokens: tokens, pairings: pairings, now: { v2Now })
        XCTAssertEqual(restored.selectedModuleID, v2ID)
        XCTAssertNil(pairings.state.pending)
        XCTAssertEqual(try tokens.read(account: session.configuration.identity.account), session.token)
    }
    func testLegacySchema2PairingSessionRemainsLoadable() throws {
        let response = try V2JSON.decode(V2SessionResponse.self, from: v2Data([
            "schema_version": 2, "api_origin": "https://example.invalid",
            "media_origin": "https://media.example.invalid", "server_id": v2ID,
            "module_id": v2ID, "client_installation_id": v2ID,
            "token": String(repeating: "b", count: 64),
            "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(3600)),
            "refresh_expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(90 * 86400)),
        ]), limit: 16 * 1024)
        let session = try response.session(
            origin: "https://example.invalid", server: v2ID, module: v2ID,
            installation: v2ID, refreshToken: "legacy-refresh", name: "RM500", now: v2Now
        )
        XCTAssertEqual(session.configuration.expiresAt, v2Now.addingTimeInterval(3600))
        XCTAssertNotEqual(session.configuration.persistentSession, true)
    }
    func testStampRejectsPreviousLifetimeAndOtherClient() {
        var gate = V2SessionGate(); let first = gate.start(v2Config()); gate.stop()
        XCTAssertFalse(gate.accepts(first)); let second = gate.start(v2Config())
        XCTAssertFalse(gate.accepts(first)); XCTAssertTrue(gate.accepts(second))
        _ = gate.start(v2Config(client: v2OtherID)); XCTAssertFalse(gate.accepts(second))
    }
    func testSixDigitNumberContract() throws {
        let valid = ["123456", "012345", "+123456", "1234567", "+12025550123", "123456789012345", "+123456789012345"]
        let invalid = ["", "12345", "+12345", "1234567890123456", "１２３４５６", "123 456", "123-456", "123456\n", "123456\r", "123456;", "*123456#", "123456+", "++123456"]
        for action in ["call.dial", "sms.send"] {
            for number in valid {
                var args = ["number": number]
                if action == "sms.send" { args["text"] = "synthetic" }
                let command = try V2Command(binding: v2Binding(), action: action, args: args, now: v2Now)
                let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
                XCTAssertEqual((encoded["args"] as? [String: String])?["number"], number)
            }
            for number in invalid {
                var args = ["number": number]
                if action == "sms.send" { args["text"] = "synthetic" }
                XCTAssertThrowsError(try V2Command(binding: v2Binding(), action: action, args: args, now: v2Now), "\(action): \(number.debugDescription)")
            }
        }
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
    @MainActor func testRouteAlwaysCreatesV2AndPreservesConfiguration() async throws {
        let fixture = try V2PollFixture()
        defer { fixture.model.systemCalls?.stop() }
        addTeardownBlock { await fixture.close() }
        let configuration = fixture.model.configuration
        let selectedModule = fixture.model.selectedModuleID
        var creations = 0
        let router = AppRouteCoordinator(makeCloud: { creations += 1; return fixture.model })
        XCTAssertNil(router.model)
        XCTAssertFalse(LegacyRuntimeGate.allowed)
        router.ensureRuntime()
        router.ensureRuntime()
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(router.model?.isV2 == true)
        XCTAssertTrue(router.cloud === fixture.model)
        XCTAssertEqual(router.cloud?.configuration, configuration)
        XCTAssertEqual(router.cloud?.selectedModuleID, selectedModule)
        XCTAssertFalse(LegacyRuntimeGate.allowed)
    }

    @MainActor func testV2LaunchDoesNotWaitForLegacyReservations() async throws {
        let fixture = try V2PollFixture()
        addTeardownBlock { await fixture.close() }
        let reservation = LegacyBusinessReservations.reserve()
        defer { LegacyBusinessReservations.release(reservation); fixture.model.systemCalls?.stop() }
        LegacyRuntimeGate.configure(true)
        let router = AppRouteCoordinator(makeCloud: { fixture.model })
        router.ensureRuntime()
        XCTAssertTrue(router.model?.isV2 == true)
        XCTAssertFalse(LegacyRuntimeGate.allowed)
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
        try restarted.clearOwnedCall(); XCTAssertNil(owned.value)
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


}

@MainActor private final class V2TestPeer: V2MediaPeer {
    var onState: ((V2PeerState) -> Void)?
    var offerSDP = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\na=candidate:1 1 udp 1 203.0.113.9 50000 typ relay\r\n"
    var offers = 0, closed = 0, accepted: [String] = [], mutes: [Bool] = []
    var connectOnAccept = true
    var stats = V2PeerStatistics()
    var offerGate: CheckedContinuation<Void, Never>?
    var holdOffer = false
    func offer() async throws -> String {
        offers += 1
        if holdOffer { await withCheckedContinuation { offerGate = $0 } }
        return offerSDP
    }
    func releaseOffer() { let gate = offerGate; offerGate = nil; gate?.resume() }
    func accept(answer: String) async throws { accepted.append(answer); if connectOnAccept { onState?(.connected) } }
    func setMuted(_ muted: Bool) { mutes.append(muted) }
    func statistics() async -> V2PeerStatistics { stats }
    func close() { closed += 1; releaseOffer() }
}
@MainActor private final class V2TestAudio: V2MediaAudio {
    var activations = 0, deactivations = 0, callKitActivations = 0, callKitDeactivations = 0
    var activateError: Error?
    var routes: [V2AudioRoute] = [.receiver, .speaker]
    var selected: V2AudioRoute?
    var speaker: Bool { selected?.kind == .speaker }
    var currentRoute: V2AudioRoute? { selected ?? routes.first }
    func activateVoice() throws { if let activateError { throw activateError }; activations += 1 }
    func deactivateVoice() { deactivations += 1 }
    func callKitActivated(_ session: AVAudioSession) { callKitActivations += 1 }
    func callKitDeactivated(_ session: AVAudioSession) { callKitDeactivations += 1 }
    var selections = 0
    func select(_ route: V2AudioRoute) throws { selected = route; selections += 1 }
}
@MainActor private final class V2TestRingback: V2Ringback {
    var playing = false, sessionActivations = 0
    func start(activatingSession: Bool) { if !playing, activatingSession { sessionActivations += 1 }; playing = true }
    func stop() { playing = false }
}
private let v2Answer = "v=0\r\no=- 2 2 IN IP4 0.0.0.0\r\n"
private func v2MediaCreated(id: String = v2ID, expiresAfter: TimeInterval = 30, relay: Bool = true) throws -> V2MediaCreated {
    let servers: [[String: Any]] = relay ? [["urls": ["turn:203.0.113.7:3478?transport=udp", "turn:203.0.113.7:3478?transport=tcp"], "username": "1:\(id):client", "credential": "c2VjcmV0"]] : []
    return try V2JSON.decode(V2MediaCreated.self, from: v2Data(["session_id": id, "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(expiresAfter)), "ice_servers": servers]), limit: 4096)
}
/// A coordinator over fakes. Peers are handed out in order and recorded.
@MainActor private func v2Media(audio: V2TestAudio? = nil, peers: [V2TestPeer] = [], timing: V2MediaTiming = V2MediaTiming(),
                                create: @escaping (V2CallContext, String) async throws -> V2MediaCreated = { _, _ in try v2MediaCreated() },
                                offer: @escaping (V2CallContext, String, String) async throws -> String = { _, _, _ in v2Answer },
                                delete: @escaping (V2CallContext, String) async -> Void = { _, _ in }) -> V2MediaCoordinator {
    var remaining = peers
    return V2MediaCoordinator(audio: audio ?? V2TestAudio(), peerFactory: { _ in remaining.isEmpty ? V2TestPeer() : remaining.removeFirst() }, timing: timing, create: create, offer: offer, delete: delete)
}
@MainActor private func v2Yield(_ count: Int = 40) async { for _ in 0..<count { await Task.yield() } }

extension CloudV2Tests {


    @MainActor func testV2StoppingSignalingCancelsImmediatelyAndCannotAffectReplacement() async throws {
        let old = V2TestPeer(), new = V2TestPeer()
        old.holdOffer = true
        var deleted: [String] = []
        let media = v2Media(peers: [old, new], delete: { _, id in deleted.append(id) })
        media.start(context: V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID), validate: { true })
        await v2Yield(100)
        XCTAssertEqual(media.state, .authenticating); XCTAssertEqual(old.offers, 1)
        await media.stop()
        XCTAssertEqual(media.state, .idle); XCTAssertEqual(old.closed, 1)
        await v2Yield(); XCTAssertEqual(deleted, [v2ID])
        let replacement = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2OtherID)
        media.start(context: replacement, validate: { true })
        await v2Yield(100)
        XCTAssertEqual(media.state, .paired); XCTAssertEqual(media.context, replacement)
        old.onState?(.failed); await v2Yield()
        XCTAssertEqual(media.state, .paired); XCTAssertEqual(new.closed, 0)
        await media.stop()
    }




}

extension CloudV2Tests {
    @MainActor func testHangupReconciliationRequiresFreshScopedEvidence() async throws {
        let transport = V2TestTransport { _ in V2HTTPResponse(status: 200, body: try v2Discovery()) }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(v2Config())
        let cases: [(String, Bool)] = [
            ("disconnected", true), ("reboot", true), ("backend", true), ("reconnected_disconnected", true),
            ("reconnected_active", false), ("missing_call", false), ("other_call", false),
            ("stale", false), ("future", false), ("offline", false), ("directory_offline", false),
            ("directory_mismatch", false), ("not_ready", false), ("calls_unavailable", false),
            ("other_module", false), ("other_client", false), ("other_server", false), ("other_route", false),
            ("sms.send", false), ("call.dial", false), ("call.answer", false), ("call.dtmf", false),
        ]
        for (scenario, resolves) in cases {
            var binding = v2Binding()
            if scenario == "reboot" { binding = V2ControlBinding(identity: binding.identity, moduleID: v2ID, bootID: v2OtherID, backendEpoch: v2ID, connectionEpoch: v2ID) }
            if scenario == "backend" { binding = V2ControlBinding(identity: binding.identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2OtherID, connectionEpoch: v2ID) }
            if scenario.hasPrefix("reconnected") { binding = V2ControlBinding(identity: binding.identity, moduleID: v2ID, bootID: v2ID, backendEpoch: v2ID, connectionEpoch: v2OtherID) }
            if scenario == "other_module" { binding = v2Binding(module: v2OtherID) }
            if scenario == "other_client" { binding = v2Binding(client: v2OtherID) }
            if scenario == "other_route" { binding.usbLocal = true }
            let action = scenario.contains(".") ? scenario : "call.hangup"
            let pending = V2PendingCommand(binding: binding, commandID: v2ID, action: action, generation: v2ID, callID: v2OtherID)
            let store = V2TestPending(); store.value = pending
            let machine = try V2CommandMachine(client: client, store: store)
            var calls = [v2CallObject(state: "disconnected")]
            if ["reboot", "backend", "missing_call"].contains(scenario) { calls = [] }
            if scenario == "reconnected_active" { calls = [v2CallObject()] }
            if scenario == "other_call" { calls = [v2CallObject(id: v2ID, state: "disconnected")] }
            let age: Double = scenario == "stale" ? 9 : scenario == "future" ? -4 : 0
            var object = try JSONSerialization.jsonObject(with: v2SnapshotData(age: age, calls: calls)) as! [String: Any]
            var directory: [String: Any] = ["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]
            if scenario == "offline" { object["online"] = false }
            if scenario == "other_server" { object["server_id"] = v2OtherID }
            if scenario == "directory_offline" { directory["online"] = false }
            if scenario == "directory_mismatch" { directory["connection_epoch"] = v2OtherID }
            if scenario == "not_ready" || scenario == "calls_unavailable" {
                var snapshot = object["snapshot"] as! [String: Any]
                let key = scenario == "not_ready" ? "control" : "calls"
                var section = snapshot[key] as! [String: Any]
                section[scenario == "not_ready" ? "ready" : "available"] = false
                snapshot[key] = section; object["snapshot"] = snapshot
            }
            let response = try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(object), limit: 262144)
            let module = try V2JSON.decode(V2Module.self, from: v2Data(directory), limit: 1024)
            XCTAssertEqual(try machine.reconcileEndedHangup(response, configuration: v2Config(), module: module, now: v2Now, usbLocal: false), resolves, scenario)
            XCTAssertEqual(machine.pending, resolves ? nil : pending, scenario)
            XCTAssertEqual(store.value, resolves ? nil : pending, scenario)
            XCTAssertEqual(machine.phase, resolves ? .idle : .unknown, scenario)
        }
        XCTAssertEqual(transport.requests.filter { $0.httpMethod != "GET" }.count, 0)
    }

    @MainActor func testHangupReconciliationWaitsForReceiptReadAndDurableClear() async throws {
        var continuation: CheckedContinuation<V2HTTPResponse, Error>?
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(v2Config())
        let store = V2TestPending()
        store.value = V2PendingCommand(binding: v2Binding(), commandID: v2ID, action: "call.hangup", generation: v2ID, callID: v2OtherID)
        let machine = try V2CommandMachine(client: client, store: store)
        let response = try V2JSON.decode(V2SnapshotResponse.self, from: v2SnapshotData(calls: [v2CallObject(state: "disconnected")]), limit: 262144)
        let module = try V2JSON.decode(V2Module.self, from: v2Data(["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]), limit: 1024)
        let read = Task { try await machine.recover() }
        await v2Yield()
        XCTAssertNotNil(continuation)
        XCTAssertFalse(try machine.reconcileEndedHangup(response, configuration: v2Config(), module: module, now: v2Now, usbLocal: false))
        continuation?.resume(returning: V2HTTPResponse(status: 200, body: try v2Accepted(id: v2ID, action: "call.hangup", callID: v2OtherID)))
        try await read.value
        XCTAssertEqual(machine.phase, .receipt(serverState: "completed", receiptState: "accepted"))
        store.fails = true
        XCTAssertThrowsError(try machine.reconcileEndedHangup(response, configuration: v2Config(), module: module, now: v2Now, usbLocal: false))
        XCTAssertNotNil(machine.pending); XCTAssertNotNil(store.value)
        store.fails = false
        XCTAssertTrue(try machine.reconcileEndedHangup(response, configuration: v2Config(), module: module, now: v2Now, usbLocal: false))
        XCTAssertNil(machine.pending); XCTAssertNil(store.value)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod != "GET" }.count, 0)
    }

    @MainActor func testRestoredUnknownHangupAfterEngineRestartAllowsDialAndAnswer() async throws {
        for incoming in [false, true] {
            let pending = V2PendingCommand(binding: v2Binding(), commandID: v2ID, action: "call.hangup", generation: v2ID, callID: v2ID)
            let owner = V2CallContext(binding: v2Binding(), callID: v2ID, generation: v2ID)
            let fixture = try V2PollFixture(pushController: nil, restoredOwner: owner, restoredPending: pending)
            addTeardownBlock { await fixture.close() }
            fixture.bootID = v2OtherID
            fixture.commandHTTPStatus = 404 // The old receipt cannot be recovered.
            if incoming {
                var call = v2CallObject(state: "incoming"); call["direction"] = "incoming"; call["ownership"] = "incoming"
                fixture.snapshotCalls = [call]
            }
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.telephonyReady && fixture.model.ownedCall == nil }
            XCTAssertFalse(fixture.model.hasUnresolvedCommand)
            XCTAssertTrue(fixture.model.canAct)
            XCTAssertNil(try V2FilePendingStore(url: fixture.root.appendingPathComponent("pending.json")).load())
            XCTAssertEqual(fixture.writes, 0) // Recovery never resends the hangup.
            fixture.commandHTTPStatus = 200
            if incoming { await fixture.model.answerInApp(try XCTUnwrap(fixture.model.activeCall)) }
            else { fixture.model.number = "00000000001"; await fixture.model.dial() }
            XCTAssertEqual(fixture.writes, 1)
            XCTAssertEqual(fixture.commands.last?["action"] as? String, incoming ? "call.answer" : "call.dial")
            await fixture.close()
        }
    }

    @MainActor func testRestoredOwnerFromPreviousRuntimeReleasesAndAllowsIncomingAnswer() async throws {
        for changedBoot in [true, false] {
            let old = V2CallContext(binding: v2Binding(), callID: v2ID, generation: v2ID)
            let fixture = try V2PollFixture(pushController: nil, restoredOwner: old)
            XCTAssertEqual(fixture.model.ownedCall, old)
            if changedBoot { fixture.bootID = v2OtherID } else { fixture.backendEpoch = v2OtherID }
            fixture.commandHTTPStatus = 200
            var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
            fixture.snapshotCalls = [incoming]
            let system = TestSystemCalls()
            fixture.model.activateSystemIntegration(calls: system)
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.ownedCall == nil }; try await v2SystemRinging(fixture)
            XCTAssertEqual(fixture.model.activeCall?.call_id, v2OtherID)
            XCTAssertNil(try V2FileOwnedCallStore(file: V2ProtectedFile(url: fixture.root.appendingPathComponent("owned-call.json"))).load())
            try await fixture.model.systemCalls?.callKitAnswer(origin: .app)
            XCTAssertEqual(fixture.writes, 1)
            XCTAssertEqual(fixture.commands.last?["action"] as? String, "call.answer")
            XCTAssertEqual(fixture.model.ownedCall?.binding.bootID, fixture.bootID)
            XCTAssertEqual(fixture.model.ownedCall?.binding.backendEpoch, fixture.backendEpoch)
            await fixture.close()
        }
    }

    @MainActor func testRestoredOwnerSurvivesConnectionChangeStaleSnapshotAndDirectoryMismatch() async throws {
        for scenario in 0..<3 {
            let old = V2CallContext(binding: v2Binding(), callID: v2ID, generation: v2ID)
            let fixture = try V2PollFixture(pushController: nil, restoredOwner: old)
            if scenario == 0 { fixture.connectionEpoch = v2OtherID }
            else { fixture.bootID = v2OtherID }
            if scenario == 1 { fixture.snapshotAge = 30 }
            if scenario == 2 { fixture.directoryBootID = v2ID }
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.counts["snapshot", default: 0] >= 2 && fixture.counts["directory", default: 0] > 0 }
            XCTAssertEqual(fixture.model.ownedCall, old)
            XCTAssertEqual(try V2FileOwnedCallStore(file: V2ProtectedFile(url: fixture.root.appendingPathComponent("owned-call.json"))).load(), old)
            XCTAssertEqual(fixture.writes, 0)
            await fixture.close()
        }
    }

    @MainActor func testOwnedCallFollowsModuleReconnect() async throws {
        let old = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        let fixture = try V2PollFixture(pushController: nil, restoredOwner: old)
        fixture.snapshotCalls = [v2CallObject()]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.ownedControlReady }
        fixture.connectionEpoch = v2OtherID
        try await v2PollWait { fixture.model.ownedCall?.binding.connectionEpoch == v2OtherID && fixture.model.ownedControlReady }
        let rebound = try XCTUnwrap(fixture.model.ownedCall)
        XCTAssertTrue(rebound.sameCall(old))
        XCTAssertEqual(try V2FileOwnedCallStore(file: V2ProtectedFile(url: fixture.root.appendingPathComponent("owned-call.json"))).load(), rebound)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }

    @MainActor func testSystemCallAndAudioSurviveModuleOutageAndReconnect() async throws {
        let peer = V2TestPeer()
        var creates = 0
        // The test peer reports no inbound packets; only the control outage is under test.
        var timing = V2MediaTiming(); timing.silence = .seconds(60)
        let media = v2Media(peers: [peer], timing: timing, create: { _, _ in creates += 1; return try v2MediaCreated() })
        let fixture = try V2PollFixture(media: media, pushController: nil)
        addTeardownBlock { await fixture.close() }
        fixture.delayedReceipts = true; fixture.receiptCompletionAfter = 0
        var call = v2CallObject(state: "incoming"); call["direction"] = "incoming"; call["ownership"] = "incoming"
        fixture.snapshotCalls = [call]
        let system = TestSystemCalls()
        fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2SystemRinging(fixture)
        await fixture.model.systemCalls?.callKitAudioSessionDidActivate()
        let answer = Task { try await fixture.model.systemCalls?.callKitAnswer(origin: .system) }
        try await v2PollWait { fixture.commands.count == 1 }
        call["state"] = "active"; call["ownership"] = "managed"; fixture.snapshotCalls = [call]
        try await v2PollWait { media.state == .paired }
        try await answer.value

        // The module loses the server for longer than a snapshot stays fresh.
        fixture.offlineModules.insert(v2ID)
        let polls = fixture.counts["snapshot", default: 0]
        try await v2PollWait { fixture.counts["snapshot", default: 0] >= polls + 3 }
        XCTAssertEqual(system.endings, 0); XCTAssertEqual(media.state, .paired)

        // It reconnects under a new connection epoch with the call still active.
        fixture.offlineModules.remove(v2ID); fixture.connectionEpoch = v2OtherID
        try await v2PollWait { fixture.model.ownedCall?.binding.connectionEpoch == v2OtherID && fixture.model.systemCalls?.authorizedBinding?.connectionEpoch == v2OtherID }
        XCTAssertEqual(system.endings, 0); XCTAssertEqual(media.state, .paired); XCTAssertEqual(creates, 1)
        XCTAssertTrue(fixture.model.ownedControlReady)

        call["state"] = "disconnected"; fixture.snapshotCalls = [call]
        try await v2PollWait { system.endings == 1 && !media.active }
    }

    @MainActor func testRingbackPlaysWhileOurOutgoingCallRings() async throws {
        let ringback = V2TestRingback()
        let owned = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        let fixture = try V2PollFixture(pushController: nil, restoredOwner: owned, ringback: ringback)
        fixture.snapshotCalls = [v2CallObject(state: "dialing")]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { ringback.playing }
        // Without CallKit the tone brings up the voice session itself.
        XCTAssertEqual(ringback.sessionActivations, 1)
        fixture.snapshotCalls = [v2CallObject(state: "alerting")]
        try await v2PollWait { fixture.model.activeCall?.state == "alerting" }
        XCTAssertTrue(ringback.playing)
        fixture.snapshotCalls = [v2CallObject(state: "active")]
        try await v2PollWait { !ringback.playing }
        await fixture.close()
    }

    @MainActor func testForegroundIncomingRingsInAppAndJoinsCallKitWithoutSystemInterface() async throws {
        let peer = V2TestPeer()
        let media = v2Media(peers: [peer])
        let fixture = try V2PollFixture(media: media, pushController: nil)
        addTeardownBlock { await fixture.close() }
        fixture.delayedReceipts = true; fixture.receiptCompletionAfter = 0
        var call = v2CallObject(state: "incoming"); call["direction"] = "incoming"; call["ownership"] = "incoming"
        fixture.snapshotCalls = [call]
        let system = TestSystemCalls()
        fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.activeCall?.state == "incoming" && fixture.counts["snapshot", default: 0] >= 3 }
        // The server holds the call push while the App polls from the foreground.
        XCTAssertEqual(system.reports, 0)
        XCTAssertTrue(fixture.snapshotQueries.allSatisfy { $0 == "presence=foreground" })
        await fixture.model.answerInApp(try XCTUnwrap(fixture.model.activeCall))
        XCTAssertEqual(fixture.commands.last?["action"] as? String, "call.answer")
        call["state"] = "active"; call["ownership"] = "managed"; fixture.snapshotCalls = [call]
        try await v2PollWait { system.adoptions == 1 && fixture.model.systemCalls?.hasSystemCall == true }
        XCTAssertEqual(system.reports, 0)
        await fixture.model.systemCalls?.callKitAudioSessionDidActivate()
        try await v2PollWait { media.state == .paired }
    }

    @MainActor func testRingingCallMovesToSystemWhenAppLeavesForeground() async throws {
        let fixture = try V2PollFixture(pushController: nil)
        addTeardownBlock { await fixture.close() }
        var call = v2CallObject(state: "incoming"); call["direction"] = "incoming"; call["ownership"] = "incoming"
        fixture.snapshotCalls = [call]
        let system = TestSystemCalls()
        fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.activeCall?.state == "incoming" && fixture.model.freshBinding != nil }
        XCTAssertEqual(system.reports, 0)
        await fixture.model.sceneChanged(.background)
        XCTAssertEqual(system.reports, 1); XCTAssertEqual(system.state, "incoming")
        XCTAssertEqual(fixture.model.systemCalls?.currentCallID, v2OtherID)
    }

    @MainActor func testRuntimeReplacementDoesNotClearOrReplayPendingCommand() async throws {
        let old = V2CallContext(binding: v2Binding(), callID: v2ID, generation: v2ID)
        let pending = V2PendingCommand(binding: old.binding, commandID: v2ID, action: "call.dial", generation: v2ID, callID: old.callID)
        let fixture = try V2PollFixture(pushController: nil, restoredOwner: old, restoredPending: pending)
        fixture.bootID = v2OtherID; fixture.commandHTTPStatus = 503
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.ownedCall == nil && fixture.counts["snapshot", default: 0] >= 2 }
        XCTAssertTrue(fixture.model.hasUnresolvedCommand)
        XCTAssertEqual(try V2FilePendingStore(url: fixture.root.appendingPathComponent("pending.json")).load(), pending)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }

    @MainActor func testV2RestoredOwnedActiveCallStartsMediaOnRequestThenRecoversIt() async throws {
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
        let peer = V2TestPeer(), audio = V2TestAudio()
        var creates = 0
        let media = v2Media(audio: audio, peers: [peer, V2TestPeer()], create: { _, _ in creates += 1; return try v2MediaCreated() })
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        let model = CloudV2Model(client: client, media: media, defaults: defaults, root: root, tokens: tokens, ringback: V2TestRingback(), now: { v2Now })
        await model.sceneChanged(.active)
        for _ in 0..<100 where !model.audioReady { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.audioReady); XCTAssertEqual(model.ownedCall, context)
        await v2Yield(); XCTAssertEqual(creates, 0); XCTAssertEqual(peer.offers, 0)
        model.connectAudio(); await v2Yield(); XCTAssertEqual(creates, 1); XCTAssertEqual(media.state, .paired)
        media.setMuted(true); media.setSpeaker(true)
        peer.onState?(.failed)
        for _ in 0..<200 where creates < 2 || media.state != .paired { try await Task.sleep(for: .milliseconds(5)) }
        // The failed session of the owned call is replaced at once and keeps the mute and output choices.
        XCTAssertEqual(creates, 2); XCTAssertEqual(media.state, .paired); XCTAssertTrue(media.muted)
        XCTAssertTrue(media.speaker); XCTAssertEqual(audio.selections, 2)
        model.experimentalAudio = false; await v2Yield()
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(creates, 2); XCTAssertFalse(media.active)
        await model.stop()
    }
    @MainActor func testV2MediaOutlivesStaleSnapshotAndStopsWhenCallLeavesActive() async throws {
        let suite = "airsim.restored.audio.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!, tokens = V2TestTokens()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        defaults.set(true, forKey: "airsim.v2.experimental-audio")
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        try V2FileOwnedCallStore(file: V2ProtectedFile(url: root.appendingPathComponent("owned-call.json"))).save(context)
        var callState = "active"
        let transport = V2TestTransport { request in
            let path = request.url!.path
            if path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            if path == "/v2/modules" { return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": [["module_id": v2ID, "online": true, "last_seen": V2Validation.timestamp(v2Now), "agent_boot_id": v2ID, "backend_epoch": v2ID, "connection_epoch": v2ID]]])) }
            if path.hasSuffix("snapshot") { return V2HTTPResponse(status: 200, body: try v2SnapshotData(calls: [v2CallObject(state: callState)])) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "module_id": v2ID, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": []]))
        }
        let peer = V2TestPeer()
        var creates = 0
        let media = v2Media(peers: [peer, V2TestPeer()], create: { _, _ in creates += 1; return try v2MediaCreated() })
        var currentNow = v2Now
        let client = V2Client(transport: transport, tokens: tokens, now: { v2Now })
        let model = CloudV2Model(client: client, media: media, defaults: defaults, root: root, tokens: tokens, now: { currentNow })
        await model.sceneChanged(.active)
        for _ in 0..<100 where !model.audioReady { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.audioReady); XCTAssertEqual(model.ownedCall, context)
        await v2Yield(); XCTAssertEqual(creates, 0); XCTAssertEqual(peer.offers, 0)
        model.connectAudio(); await v2Yield(); XCTAssertEqual(creates, 1); XCTAssertEqual(media.state, .paired)
        // A stale snapshot means the control link is down, not that the call ended.
        currentNow = v2Now.addingTimeInterval(9)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(media.state, .paired); XCTAssertNil(model.lastEligibilityFailure)
        currentNow = v2Now; callState = "held"
        for _ in 0..<300 where media.active { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(media.active)
        callState = "active"
        for _ in 0..<300 where !model.audioReady { try await Task.sleep(for: .milliseconds(5)) }
        model.connectAudio()
        XCTAssertNil(model.lastEligibilityFailure)
        await v2Yield(); XCTAssertEqual(media.state, .paired); XCTAssertEqual(creates, 2)
        await model.stop()
    }
    @MainActor func testV2ExplicitRecoveryUsesNewRequestSessionAndLateCallbacksCannotStopIt() async throws {
        let first = V2TestPeer(), second = V2TestPeer()
        var requestIDs: [String] = [], deleted: [String] = [], deleteFinished: CheckedContinuation<Void, Never>?
        let media = v2Media(peers: [first, second], create: { _, id in
            requestIDs.append(id); return try v2MediaCreated(id: requestIDs.count == 1 ? v2ID : v2OtherID)
        }, delete: { _, id in
            deleted.append(id)
            if id == v2ID { await withCheckedContinuation { deleteFinished = $0 } }
        })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, validate: { true }); await v2Yield()
        XCTAssertEqual(media.state, .paired)
        let oldState = first.onState
        first.onState?(.failed); await v2Yield(100)
        XCTAssertFalse(media.active); XCTAssertEqual(deleted, [v2ID]); XCTAssertEqual(media.lastFailure?.code, .disconnected)
        media.start(context: context, validate: { true }); await v2Yield()
        XCTAssertEqual(media.state, .paired); XCTAssertEqual(requestIDs.count, 2); XCTAssertNotEqual(requestIDs[0], requestIDs[1])
        oldState?(.closed); deleteFinished?.resume()
        await v2Yield(); XCTAssertEqual(media.state, .paired); XCTAssertTrue(media.active)
        XCTAssertEqual(second.closed, 0)
        await media.stop(); await v2Yield(); await media.stop()
        XCTAssertEqual(deleted, [v2ID, v2OtherID])
    }
}

extension CloudV2Tests {
}

@MainActor private final class V2PollFixture {
    let suite = "airsim.poll.\(UUID())"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let tokens = V2TestTokens()
    private let started = Date()
    var currentNow: Date { v2Now.addingTimeInterval(Date().timeIntervalSince(started)) }
    var defaults: UserDefaults!
    var model: CloudV2Model!
    var transport: V2TestTransport!
    var counts: [String: Int] = [:], inFlight: [String: Int] = [:], maxInFlight: [String: Int] = [:]
    var blocked = Set<String>(), failed = Set<String>()
    var discoveryFailures = 0
    var directoryBlocksAfterFirst = false
    var pending: [String: CheckedContinuation<V2HTTPResponse, Error>] = [:]
    var snapshotCalls: [[String: Any]] = []
    var snapshotQueries: [String?] = []
    var snapshotMessages: [[String: Any]] = []
    var signals: [String: [String: Any]] = [:]
    var offlineModules = Set<String>()
    var connectionEpoch = v2ID
    var bootID = v2ID, backendEpoch = v2ID
    var directoryBootID: String?
    var snapshotAge: TimeInterval = 0
    var writes = 0
    var commandHTTPStatus: Int?
    var delayedReceipts = false
    var receiptReads = 0
    var receiptCompletionAfter = 1
    var receiptFails = false
    var receiptUnknown = false
    var receiptMessageID: String?
    var commands: [[String: Any]] = []
    init(media: V2MediaCoordinator? = nil, pushController: V2PushController? = .shared, restoredOwner: V2CallContext? = nil, restoredPending: V2PendingCommand? = nil, ringback: V2Ringback? = nil) throws {
        defaults = UserDefaults(suiteName: suite)!
        _ = try V2ConfigurationStore(tokens: tokens, defaults: defaults).importConfiguration(v2Data(v2Import()), now: v2Now)
        defaults.set(v2ID, forKey: V2LocalPaths.selectionKey(v2Config().identity))
        if let restoredOwner { try V2FileOwnedCallStore(file: V2ProtectedFile(url: root.appendingPathComponent("owned-call.json"))).save(restoredOwner) }
        if let restoredPending { try V2FilePendingStore(url: root.appendingPathComponent("pending.json")).save(restoredPending) }
        transport = V2TestTransport { [unowned self] request in
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
                if let receiptMessageID {
                    var receipt = result["receipt"] as! [String: Any]; receipt["message_id"] = receiptMessageID; result["receipt"] = receipt
                }
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
            if path == "/.well-known/airsim" {
                counts["discovery", default: 0] += 1
                if discoveryFailures > 0 { discoveryFailures -= 1; throw V2Error.transport }
                return V2HTTPResponse(status: 200, body: try v2Discovery())
            }
            let lane = path == "/v2/modules" ? "directory" : (path.hasSuffix("snapshot") ? "snapshot" : "messages")
            if lane == "snapshot" { snapshotQueries.append(request.url?.query) }
            counts[lane, default: 0] += 1; inFlight[lane, default: 0] += 1
            maxInFlight[lane] = max(maxInFlight[lane, default: 0], inFlight[lane, default: 0])
            defer { inFlight[lane, default: 0] -= 1 }
            if blocked.contains(lane) || (lane == "directory" && directoryBlocksAfterFirst && counts[lane, default: 0] > 1) {
                return try await withCheckedThrowingContinuation { pending[lane] = $0 }
            }
            if failed.contains(lane) { throw V2Error.transport }
            return try response(lane, module: path.contains(v2OtherID) ? v2OtherID : v2ID)
        }
        model = CloudV2Model(client: V2Client(transport: transport, tokens: tokens, now: { [unowned self] in currentNow }), media: media, defaults: defaults, root: root, tokens: tokens, pushController: pushController, ringback: ringback ?? V2TestRingback(), now: { [unowned self] in currentNow })
    }
    func response(_ lane: String, module: String = v2ID) throws -> V2HTTPResponse {
        let body: Data
        if lane == "directory" {
            body = try v2Data(["server_id": v2ID, "modules": [v2ID, v2OtherID].map { id -> [String: Any] in
                var value: [String: Any] = ["module_id": id, "online": !offlineModules.contains(id), "last_seen": V2Validation.timestamp(currentNow), "agent_boot_id": directoryBootID ?? bootID, "backend_epoch": backendEpoch, "connection_epoch": connectionEpoch]
                value["signal"] = signals[id]
                return value
            }])
        } else if lane == "snapshot" { var value = try JSONSerialization.jsonObject(with: v2SnapshotData(module: module, age: snapshotAge - currentNow.timeIntervalSince(v2Now), calls: snapshotCalls)) as! [String: Any]
            value["connection_epoch"] = connectionEpoch
            value["online"] = !offlineModules.contains(module)
            var snapshot = value["snapshot"] as! [String: Any]
            snapshot["signal"] = signals[module]
            snapshot["agent_boot_id"] = bootID; snapshot["backend_epoch"] = backendEpoch
            for section in ["control", "calls"] {
                var value = snapshot[section] as! [String: Any]
                value["agent_boot_id"] = bootID; value["backend_epoch"] = backendEpoch
                snapshot[section] = value
            }
            value["snapshot"] = snapshot
            body = try v2Data(value) }
        else { body = try v2Data(["server_id": v2ID, "module_id": module, "agent_boot_id": v2ID, "backend_epoch": v2ID, "online": true, "inbox_gap": false, "inbox_dropped": 0, "messages": snapshotMessages]) }
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
        XCTAssertEqual(fixture.counts, ["discovery": 1, "snapshot": 1, "messages": 1, "directory": 1])
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
            if status == 503 { XCTAssertNil(fixture.model.error) }
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
    var adoptions = 0
    func adoptAnsweredCall(callID: String, number: String?) async throws { adoptions += 1; currentSystemCallUUID = UUID(); state = "active" }
}
/// Hands the call ringing in the App to the system, as leaving the foreground does.
@MainActor private func v2SystemRinging(_ fixture: V2PollFixture) async throws {
    try await v2PollWait { fixture.model.activeCall?.state == "incoming" && fixture.model.freshBinding != nil }
    fixture.model.systemCalls?.handOverRingingCall()
}

extension CloudV2Tests {
    @MainActor func testForegroundAnswerReceiptAndMediaDoNotWaitForMessages() async throws {
        for messagesBlocked in [true, false] {
            let audio = V2TestAudio(), peer = V2TestPeer()
            var creates = 0
            let media = v2Media(audio: audio, peers: [peer], create: { _, _ in creates += 1; return try v2MediaCreated() })
            let fixture = try V2PollFixture(media: media, pushController: nil)
            addTeardownBlock { await fixture.close() }
            if messagesBlocked { fixture.blocked.insert("messages") } else { fixture.failed.insert("messages") }
            fixture.delayedReceipts = true; fixture.receiptCompletionAfter = 0
            var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
            fixture.snapshotCalls = [incoming]
            let system = TestSystemCalls()
            fixture.model.activateSystemIntegration(calls: system)
            await fixture.model.sceneChanged(.active)
            try await v2SystemRinging(fixture)
            await fixture.model.systemCalls?.callKitAudioSessionDidActivate()
            let answer = Task { try await fixture.model.systemCalls?.callKitAnswer(origin: .system) }
            try await v2PollWait { fixture.commands.count == 1 }
            incoming["state"] = "active"; incoming["ownership"] = "managed"; fixture.snapshotCalls = [incoming]
            try await v2PollWait { media.state == .paired }
            try await answer.value
            XCTAssertNotNil(fixture.model.ownedCall)
            XCTAssertEqual(fixture.receiptReads, 1)
            XCTAssertEqual(fixture.writes, 1); XCTAssertEqual(fixture.commands.count, 1)
            XCTAssertEqual(creates, 1); XCTAssertEqual(peer.offers, 1)
            XCTAssertEqual(audio.callKitActivations, 1); XCTAssertEqual(audio.activations, 0)
            XCTAssertFalse(fixture.model.hasUnresolvedCommand)
            if messagesBlocked { XCTAssertNotNil(fixture.pending["messages"]) }
            await fixture.close()
        }
    }

    @MainActor func testIncomingAudioActivationBeforeAnswerReceiptStartsMediaWhenOwnershipArrives() async throws {
        for background in [false, true] {
            let audio = V2TestAudio(), peer = V2TestPeer()
            var created = 0
            let media = v2Media(audio: audio, peers: [peer], create: { _, _ in created += 1; return try v2MediaCreated() })
            let fixture = try V2PollFixture(media: media)
            fixture.delayedReceipts = true; fixture.receiptCompletionAfter = 1
            var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
            fixture.snapshotCalls = [incoming]
            let system = TestSystemCalls()
            fixture.model.activateSystemIntegration(calls: system)
            await fixture.model.sceneChanged(.active)
            try await v2SystemRinging(fixture)
            if background { await fixture.model.sceneChanged(.background) }
            // CallKit activates after fulfilling answer, before the asynchronous backend receipt.
            await fixture.model.systemCalls?.callKitAudioSessionDidActivate()
            XCTAssertTrue(fixture.model.systemAudioActive)
            XCTAssertEqual(audio.callKitActivations, 1); XCTAssertEqual(peer.offers, 0)
            let answer = Task { try await fixture.model.systemCalls?.callKitAnswer(origin: .system) }
            try await v2PollWait { !fixture.commands.isEmpty }
            incoming["state"] = "active"; incoming["ownership"] = "managed"; fixture.snapshotCalls = [incoming]
            try await answer.value
            try await v2PollWait { media.state == .paired }
            XCTAssertEqual(created, 1)
            XCTAssertEqual(peer.offers, 1); XCTAssertEqual(audio.activations, 0)
            await fixture.close()
        }
    }

    @MainActor func testSystemIncomingDedupAudioActivationAndBackgroundScope() async throws {
        let audio = V2TestAudio(), peer = V2TestPeer()
        let media = v2Media(audio: audio, peers: [peer])
        let fixture = try V2PollFixture(media: media)
        fixture.commandHTTPStatus = 200
        var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls()
        fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2SystemRinging(fixture)
        let uuid = system.currentSystemCallUUID
        fixture.model.systemCalls?.observeSnapshot(); fixture.model.systemCalls?.observeSnapshot()
        XCTAssertEqual(system.reports, 1); XCTAssertEqual(system.currentSystemCallUUID, uuid)
        XCTAssertEqual(peer.offers, 0)
        try await fixture.model.systemCalls?.callKitAnswer(origin: .system)
        incoming["state"] = "active"; incoming["ownership"] = "managed"; fixture.snapshotCalls = [incoming]
        try await v2PollWait { system.state == "active" }
        XCTAssertEqual(peer.offers, 0); XCTAssertFalse(fixture.model.audioReady)
        await fixture.model.systemCalls?.callKitAudioSessionDidActivate()
        try await v2PollWait { media.state == .paired }
        XCTAssertEqual(audio.callKitActivations, 1); XCTAssertEqual(audio.activations, 0)
        await fixture.model.sceneChanged(.background)
        let snapshots = fixture.counts["snapshot", default: 0]
        let directories = fixture.counts["directory", default: 0], messages = fixture.counts["messages", default: 0]
        try await v2PollWait { fixture.counts["snapshot", default: 0] > snapshots }
        XCTAssertEqual(fixture.counts["directory", default: 0], directories)
        XCTAssertEqual(fixture.counts["messages", default: 0], messages)
        XCTAssertEqual(fixture.writes, 1)
        fixture.model.systemCalls?.callKitAudioSessionDidDeactivate()
        try await v2PollWait { !media.active }
        XCTAssertEqual(audio.callKitDeactivations, 1); XCTAssertEqual(peer.closed, 1)
        XCTAssertFalse(fixture.model.systemAudioActive)
        incoming["state"] = "disconnected"; fixture.snapshotCalls = [incoming]
        try await v2PollWait { system.endings == 1 }
        XCTAssertNil(system.currentSystemCallUUID)
        await fixture.close()
    }

    @MainActor func testPushKitIncomingVerifiesFreshDomainBeforeBackgroundAnswerOrReject() async throws {
        for (action, coldStart) in [("call.answer", false), ("call.hangup", false), ("call.answer", true), ("call.hangup", true)] {
            let fixture = try V2PollFixture()
            addTeardownBlock { await fixture.close() }
            fixture.commandHTTPStatus = 200
            let system = TestSystemCalls()
            fixture.model.activateSystemIntegration(calls: system, associationTimeout: .seconds(2))
            if !coldStart {
                await fixture.model.sceneChanged(.active)
                try await v2PollWait { fixture.model.freshBinding != nil }
            }
            await fixture.model.sceneChanged(.background)

            let directoryCount = fixture.counts["directory", default: 0]
            fixture.connectionEpoch = v2OtherID
            let uuid = UUID()
            system.currentSystemCallUUID = uuid
            let now = fixture.currentNow
            let call = try IncomingVoIPCall(userInfo: [
                "protocol_version": 2,
                "event": "incoming_call",
                "server_id": v2ID,
                "client_installation_id": v2ID,
                "registration_id": v2OtherID,
                "module_id": v2ID,
                "connection_epoch": fixture.connectionEpoch,
                "agent_boot_id": v2ID,
                "backend_epoch": v2ID,
                "call_id": v2OtherID,
                "call_uuid": uuid.uuidString,
                "expires_at": V2Validation.timestamp(now.addingTimeInterval(20)),
                "number": "00000000001",
            ], now: now)
            var incoming = v2CallObject(state: "incoming")
            incoming["direction"] = "incoming"
            incoming["ownership"] = "incoming"
            fixture.snapshotCalls = [incoming]
            fixture.model.systemCalls?.callKitDidReceiveIncoming(call)
            do {
                if action == "call.answer" { try await fixture.model.systemCalls?.callKitAnswer(origin: .system) }
                else { try await fixture.model.systemCalls?.callKitEnd() }
            } catch {
                XCTFail("action=\(action) cold=\(coldStart) ended=\(system.endings) directories=\(fixture.counts["directory",default:0]) writes=\(fixture.writes) binding=\(fixture.model.freshBinding != nil) verified=\(fixture.model.systemCalls?.authorizedBinding != nil) error=\(fixture.model.error ?? "none")")
                throw error
            }
            XCTAssertGreaterThan(fixture.counts["directory", default: 0], directoryCount)
            XCTAssertEqual(system.state, "incoming", action)
            XCTAssertEqual(fixture.writes, 1, action)
            XCTAssertEqual(fixture.commands.last?["action"] as? String, action)
            XCTAssertEqual((fixture.commands.last?["args"] as? [String: String])?["call_id"], v2OtherID)
            await fixture.close()
        }
    }

    @MainActor func testPushAfterHandOverKeepsExistingSystemCall() async throws {
        let fixture = try V2PollFixture()
        addTeardownBlock { await fixture.close() }
        fixture.commandHTTPStatus = 200
        var incoming = v2CallObject(state: "incoming")
        incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls()
        fixture.model.activateSystemIntegration(calls: system, associationTimeout: .seconds(2))
        await fixture.model.sceneChanged(.active)
        try await v2SystemRinging(fixture)
        let originalUUID = try XCTUnwrap(system.currentSystemCallUUID)
        let now = fixture.currentNow
        let push = try IncomingVoIPCall(userInfo: [
            "protocol_version": 2, "event": "incoming_call", "server_id": v2ID,
            "client_installation_id": v2ID, "registration_id": v2OtherID, "module_id": v2ID,
            "connection_epoch": v2ID, "agent_boot_id": v2ID, "backend_epoch": v2ID,
            "call_id": v2OtherID, "call_uuid": UUID().uuidString,
            "expires_at": V2Validation.timestamp(now.addingTimeInterval(20))
        ], now: now)
        fixture.model.systemCalls?.callKitDidReceiveIncoming(push)
        try await fixture.model.systemCalls?.callKitAnswer(origin: .app)
        XCTAssertEqual(system.currentSystemCallUUID, originalUUID)
        XCTAssertEqual(system.endings, 0)
        XCTAssertEqual(fixture.writes, 1)
        XCTAssertEqual(fixture.commands.last?["action"] as? String, "call.answer")
    }

    @MainActor func testSystemRejectTargetsTheVerifiedIncomingCall() async throws {
        let fixture = try V2PollFixture(); fixture.commandHTTPStatus = 200
        var incoming = v2CallObject(state: "incoming"); incoming["direction"] = "incoming"; incoming["ownership"] = "incoming"
        fixture.snapshotCalls = [incoming]
        let system = TestSystemCalls(); fixture.model.activateSystemIntegration(calls: system)
        await fixture.model.sceneChanged(.active)
        try await v2SystemRinging(fixture)
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
        try await v2SystemRinging(fixture)
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
    func testV2PushPayloadRetainsVerifiedDomainAndRejectsExpiredCall() throws {
        let callUUID = UUID().uuidString.lowercased()
        func payload(expiresAt: Date) -> [AnyHashable: Any] {
            [
                "protocol_version": 2,
                "event": "incoming_call",
                "server_id": v2ID,
                "client_installation_id": v2ID,
                "registration_id": v2OtherID,
                "module_id": v2OtherID,
                "connection_epoch": v2ID,
                "agent_boot_id": v2ID,
                "backend_epoch": v2ID,
                "call_id": v2OtherID,
                "call_uuid": callUUID,
                "expires_at": V2Validation.timestamp(expiresAt),
                "number": "10000000000",
            ]
        }
        let valid = try IncomingVoIPCall(
            userInfo: payload(expiresAt: v2Now.addingTimeInterval(20)),
            now: v2Now
        )
        XCTAssertEqual(valid.v2Push?.domain.serverID, v2ID)
        XCTAssertEqual(valid.v2Push?.domain.registrationID, v2OtherID)
        XCTAssertEqual(valid.v2Push?.callID, v2OtherID)
        XCTAssertEqual(valid.v2Push?.callUUID.uuidString.lowercased(), callUUID)
        XCTAssertThrowsError(try IncomingVoIPCall(
            userInfo: payload(expiresAt: v2Now.addingTimeInterval(-1)),
            now: v2Now
        )) { error in
            XCTAssertEqual(error as? VoIPPushPayloadError, .expired)
        }
        let legacy = try IncomingVoIPCall(
            userInfo: [
                "event": "incoming_call",
                "call_id": "legacy-call",
                "call_uuid": callUUID,
                "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(20)),
            ],
            now: v2Now
        )
        XCTAssertNil(legacy.v2Push)
    }

    @MainActor func testPushRegistrationUsesAuthenticatedV2IdentityAndDeletesById() async throws {
        let registrationID = "20112233-4455-4677-8899-aabbccddeeff"
        let discovery = try JSONSerialization.jsonObject(with: v2Discovery()) as! [String: Any]
        var pushBody: Data?
        var deletedBody: Data?
        let transport = V2TestTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/.well-known/airsim"):
                return V2HTTPResponse(status: 200, body: try v2Data(discovery))
            case ("PUT", "/v2/push/registration"):
                let body = request.httpBody ?? Data()
                pushBody = body
                let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                return V2HTTPResponse(status: 200, body: try v2Data([
                    "server_id": v2ID,
                    "client_installation_id": v2OtherID,
                    "registration_id": object["registration_id"]!,
                    "module_id": object["module_id"]!,
                    "bundle_id": object["bundle_id"]!,
                    "environment": object["environment"]!,
                ]))
            case ("DELETE", "/v2/push/registration"):
                deletedBody = request.httpBody
                return V2HTTPResponse(status: 204, body: Data())
            default:
                return V2HTTPResponse(status: 404, body: Data())
            }
        }
        let config = v2Config(client: v2OtherID)
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(config)
        let body = V2PushRegistrationBody(
            registrationID: registrationID,
            moduleID: v2OtherID,
            bundleID: "com.example.airsim",
            environment: "sandbox",
            voipToken: String(repeating: "a", count: 64),
            alertToken: String(repeating: "b", count: 64)
        )
        let receipt = try await client.registerPush(body)
        XCTAssertEqual(receipt.server_id, v2ID)
        XCTAssertEqual(receipt.client_installation_id, v2OtherID)
        XCTAssertEqual(receipt.registration_id, registrationID)
        XCTAssertTrue(transport.requests
            .filter { $0.url?.path == "/v2/push/registration" }
            .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64) })
        let encoded = try JSONSerialization.jsonObject(with: try XCTUnwrap(pushBody)) as! [String: String]
        XCTAssertEqual(encoded["registration_id"], registrationID)
        XCTAssertEqual(encoded["module_id"], v2OtherID)
        XCTAssertEqual(encoded["voip_token"], String(repeating: "a", count: 64))
        try await client.unregisterPush(registrationID: registrationID)
        let deleted = try JSONSerialization.jsonObject(with: try XCTUnwrap(deletedBody)) as! [String: String]
        XCTAssertEqual(deleted["registration_id"], registrationID)
    }

    @MainActor func testKnownDiscoveryProfilesWithoutAPNsRetainIdentityAndOriginChecks() async throws {
        for profile in ["airsim-v2-r4.1", "airsim-v2-callkit"] {
            for mismatch in ["none", "server_id", "api_origin", "media_origin", "profile"] {
                var discovery = try JSONSerialization.jsonObject(with: v2Discovery()) as! [String: Any]
                discovery["profile"] = profile
                switch mismatch {
                case "server_id": discovery["server_id"] = v2OtherID
                case "api_origin", "media_origin": discovery[mismatch] = "https://other.example.invalid"
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

    @MainActor func testCallKitDiscoveryAcceptsConfiguredAPNs() async throws {
        var discovery = try JSONSerialization.jsonObject(with: v2Discovery()) as! [String: Any]
        discovery["profile"] = "airsim-v2-callkit"
        var capabilities = discovery["capabilities"] as! [String: Any]
        capabilities["apns"] = true
        discovery["capabilities"] = capabilities
        let transport = V2TestTransport { _ in
            V2HTTPResponse(status: 200, body: try v2Data(discovery))
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        let result = try await client.connect(v2Config())
        XCTAssertEqual(result.profile, "airsim-v2-callkit")
        XCTAssertTrue(result.capabilities.apns)
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
                    try await v2SystemRinging(fixture)
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
        try await v2SystemRinging(fixture)
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


extension CloudV2Tests {
    @MainActor func testInitialConnectionRecoversWithoutUserAction() async throws {
        let fixture = try V2PollFixture()
        fixture.discoveryFailures = 1
        await fixture.model.sceneChanged(.active)
        XCTAssertFalse(fixture.model.connected)
        try await v2PollWait { fixture.model.connected && !fixture.model.modules.isEmpty }
        XCTAssertEqual(fixture.counts["discovery"], 2)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }

    @MainActor func testBackgroundStopsPendingConnectionRetry() async throws {
        let fixture = try V2PollFixture()
        fixture.discoveryFailures = 5
        await fixture.model.sceneChanged(.active)
        await fixture.model.sceneChanged(.background)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(fixture.counts["discovery"], 1)
        XCTAssertFalse(fixture.model.connected)
        await fixture.close()
    }

    @MainActor func testModuleNamePersistsAndDoesNotChangeSelection() async throws {
        let fixture = try V2PollFixture()
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.modules.count == 2 }
        fixture.model.renameModule(v2OtherID, name: "  旅行卡  ")
        XCTAssertEqual(fixture.model.moduleName(v2OtherID), "旅行卡")
        XCTAssertEqual(fixture.model.selectedModuleID, v2ID)
        let restored = CloudV2Model(defaults: fixture.defaults, root: fixture.root, tokens: fixture.tokens, now: { v2Now })
        XCTAssertEqual(restored.moduleName(v2OtherID), "旅行卡")
        XCTAssertEqual(restored.moduleName(v2ID), "模块 · \(v2ID.prefix(8))")
        await restored.stop()
        await fixture.close()
    }
}


extension CloudV2Tests {
    @MainActor func testRefreshNetworkFailureKeepsSessionAvailableForAutomaticRetry() async throws {
        let config = V2Configuration(identity: v2Config().identity, mediaOrigin: v2Config().mediaOrigin,
                                     expiresAt: v2Now.addingTimeInterval(3600), moduleID: v2ID,
                                     refreshExpiresAt: v2Now.addingTimeInterval(86400))
        let tokens = V2TestTokens()
        try tokens.save(String(repeating: "a", count: 64), account: config.identity.account)
        var reads = 0
        let client = V2Client(transport: V2TestTransport { request in
            if request.url?.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            reads += 1
            if reads == 1 { return V2HTTPResponse(status: 401, body: Data()) }
            return V2HTTPResponse(status: 200, body: try v2Data(["server_id": v2ID, "modules": []]))
        }, tokens: tokens, now: { v2Now })
        client.onRefreshConfiguration = { _ in throw V2Error.transport }
        var invalidated = false
        client.onAuthenticationInvalidated = { invalidated = true }
        _ = try await client.connect(config)
        do { _ = try await client.modules(); XCTFail("Expected temporary refresh failure") }
        catch { XCTAssertEqual(error as? V2Error, .transport) }
        XCTAssertFalse(invalidated)
        _ = try await client.modules()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(client.configuration, config)
    }
}

final class V2USBTests: XCTestCase {
    func testHMACBindsTimestampNonceMethodPathAndBody() throws {
        let grant = V2USBAuthorization(server_id: v2ID, module_id: v2ID, client_installation_id: v2ID,
            api_origin: "https://192.168.225.1:8577", certificate_der_base64: "", token: String(repeating: "01", count: 32), expires_at: "")
        var request = URLRequest(url: URL(string: grant.api_origin + "/v2/modules/test/commands")!)
        request.httpMethod = "POST"; request.httpBody = Data("{\"value\":1}".utf8)
        let signed = try grant.sign(request, now: v2Now, nonce: String(repeating: "ab", count: 32))
        XCTAssertEqual(signed.value(forHTTPHeaderField: "X-AirSIM-Signature"), "c31baee46a469fdee52c93010458572b19f5499b85fab95c5efe921864ccfa5d")
        request.httpBody = Data("{\"value\":2}".utf8)
        XCTAssertNotEqual(try grant.sign(request, now: v2Now, nonce: String(repeating: "ab", count: 32)).value(forHTTPHeaderField: "X-AirSIM-Signature"), signed.value(forHTTPHeaderField: "X-AirSIM-Signature"))
        request.url = URL(string: "https://example.invalid/v2/modules/test/commands")
        XCTAssertThrowsError(try grant.sign(request))
    }
    func testUSBInterfaceRejectsWiFiAndVPN() {
        XCTAssertTrue(ModuleUSBInterfaceResolver.isUSBInterface(type: .wiredEthernet, name: "en7"))
        XCTAssertTrue(ModuleUSBInterfaceResolver.isUSBInterface(type: .other, name: "en7"))
        XCTAssertFalse(ModuleUSBInterfaceResolver.isUSBInterface(type: .wifi, name: "en0"))
        XCTAssertFalse(ModuleUSBInterfaceResolver.isUSBInterface(type: .other, name: "utun3"))
        XCTAssertFalse(ModuleUSBInterfaceResolver.isUSBInterface(type: .cellular, name: "pdp_ip0"))
    }
    @MainActor func testPersistedUSBCommandCannotSubmitOrRecoverOverCloud() async throws {
        let transport = V2TestTransport { _ in V2HTTPResponse(status: 200, body: try v2Discovery()) }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(v2Config())
        var binding = v2Binding(); binding.usbLocal = true
        let encoded = try JSONEncoder().encode(binding)
        let restored = try JSONDecoder().decode(V2ControlBinding.self, from: encoded)
        XCTAssertEqual(restored.usbLocal, true)
        let command = try V2Command(binding: restored, action: "sms.send", args: ["number": "+15550000000", "text": "test"], now: v2Now)
        do { _ = try await client.submit(command, binding: restored); XCTFail("changed route") } catch {}
        do { _ = try await client.receipt(binding: restored, commandID: command.command_id); XCTFail("changed receipt route") } catch {}
        XCTAssertEqual(transport.requests.count, 1)
    }
}


extension CloudV2Tests {
    @MainActor func testAccountSMSSwitchesModuleWithoutChangingDefault() async throws {
        let fixture = try V2PollFixture()
        fixture.commandHTTPStatus = 200
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady }
        let app = AppModel(cloudV2: fixture.model)
        let conversation = try XCTUnwrap(app.smsConversation(to: "00000000001", moduleID: v2OtherID))
        app.setSMSDraft("切卡测试", for: conversation)
        let outcome = await app.sendSMS(in: conversation, content: "切卡测试")
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(fixture.writes, 1)
        XCTAssertEqual(fixture.model.selectedModuleID, v2OtherID)
        XCTAssertEqual(app.defaultOutgoingModuleID, v2ID)
        XCTAssertEqual(app.smsDraft(for: conversation), "")
        await fixture.model.selectModule(v2OtherID)
        XCTAssertEqual(app.defaultOutgoingModuleID, v2OtherID)
        await fixture.close()
    }

    @MainActor func testUnknownSMSResolvesBubbleWithoutRestoringSubmittedDraft() async throws {
        for failed in [false, true] {
            let fixture = try V2PollFixture()
            fixture.delayedReceipts = true
            fixture.receiptCompletionAfter = 1000
            fixture.receiptFails = failed
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.messagingReady }
            let app = AppModel(cloudV2: fixture.model)
            let conversation = try XCTUnwrap(app.smsConversation(to: "00000000001"))
            app.setSMSDraft("待核对测试", for: conversation)
            let outcome = await app.sendSMS(in: conversation, content: "待核对测试")
            XCTAssertEqual(outcome, .unknown)
            XCTAssertFalse(app.canSendSMS(in: conversation))
            fixture.receiptCompletionAfter = 0
            await fixture.model.recoverPending()
            app.projectCloudState()
            XCTAssertEqual(app.accountSMSThreads.first?.lastMessage.state, failed ? "failed" : "sent")
            XCTAssertEqual(app.smsDraft(for: conversation), "")
            XCTAssertTrue(app.canSendSMS(in: conversation))
            XCTAssertEqual(fixture.writes, 1)
            await fixture.close()
        }
    }

    @MainActor func testSuccessfulSMSRetryCannotResubmitOriginalFailedRecord() async throws {
        let fixture = try V2PollFixture()
        fixture.commandHTTPStatus = 200
        fixture.snapshotMessages = [["message_id": v2ID, "direction": "outgoing", "sender": "",
            "recipient": "00000000001", "text": "失败重试测试", "state": "failed", "delivery": "unknown",
            "observed_at": V2Validation.timestamp(v2Now)]]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady && !fixture.model.visibleMessages.isEmpty }
        let app = AppModel(cloudV2: fixture.model)
        app.projectCloudState()
        let original = try XCTUnwrap(app.accountSMSThreads.first?.lastMessage)
        let outcome = await app.retrySMS(original)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(app.accountSMSThreads.first?.messages.count, 1)
        XCTAssertEqual(app.accountSMSThreads.first?.lastMessage.canRetry, false)
        let reloadedCloud = CloudV2Model(defaults: fixture.defaults, root: fixture.root, tokens: fixture.tokens, now: { v2Now })
        let reloadedApp = AppModel(cloudV2: reloadedCloud)
        reloadedApp.projectCloudState()
        XCTAssertEqual(reloadedApp.accountSMSThreads.first?.lastMessage.canRetry, false)
        XCTAssertEqual(reloadedCloud.history.outgoingMessages?.first?.storedMessageIDs, [original.id])
        let repeated = await app.retrySMS(original)
        XCTAssertEqual(repeated, .unknown)
        XCTAssertEqual(fixture.writes, 1)
        await fixture.close()
    }
}


extension CloudV2Tests {
    @MainActor func testUnknownSMSRetryRestoresOriginalMessageAssociation() async throws {
        for failed in [false, true] {
            let fixture = try V2PollFixture()
            fixture.delayedReceipts = true
            fixture.receiptCompletionAfter = 1000
            fixture.receiptFails = failed
            fixture.snapshotMessages = [["message_id": v2ID, "direction": "outgoing", "sender": "",
                "recipient": "00000000001", "text": "重启重试测试", "state": "failed", "delivery": "unknown",
                "observed_at": V2Validation.timestamp(v2Now)]]
            await fixture.model.sceneChanged(.active)
            try await v2PollWait { fixture.model.messagingReady && !fixture.model.visibleMessages.isEmpty }
            let app = AppModel(cloudV2: fixture.model)
            app.projectCloudState()
            let original = try XCTUnwrap(app.accountSMSThreads.first?.lastMessage)
            let outcome = await app.retrySMS(original)
            XCTAssertEqual(outcome, .unknown)
            XCTAssertNotNil(fixture.model.history.outgoingMessages?.first?.commandID)
            await fixture.model.stop()
            fixture.receiptCompletionAfter = 0
            let restored = CloudV2Model(client: V2Client(transport: fixture.transport, tokens: fixture.tokens,
                now: { fixture.currentNow }), defaults: fixture.defaults, root: fixture.root,
                tokens: fixture.tokens, now: { fixture.currentNow })
            fixture.model = restored
            let restoredApp = AppModel(cloudV2: restored)
            restoredApp.projectCloudState()
            XCTAssertEqual(restoredApp.accountSMSThreads.first?.lastMessage.canRetry, false)
            await restored.sceneChanged(.active)
            try await v2PollWait { !restored.hasUnresolvedCommand }
            restoredApp.projectCloudState()
            XCTAssertNil(restored.history.pendingMessageRetry)
            XCTAssertEqual(restoredApp.accountSMSThreads.first?.lastMessage.canRetry, failed)
            XCTAssertEqual(restored.history.outgoingMessages?.first?.state, failed ? "failed" : "sent")
            XCTAssertEqual(fixture.writes, 1)
            await fixture.close()
        }
    }
}

extension CloudV2Tests {
    @MainActor func testSMSPresentationSelectionSurvivesModuleSwitchAndRejectsOtherIdentity() async throws {
        let fixture = try V2PollFixture()
        addTeardownBlock { await fixture.close() }
        fixture.snapshotMessages = [["message_id": v2ID, "direction": "incoming", "sender": "00000000001",
            "recipient": "", "text": "会话选择测试", "state": "received", "delivery": "unknown",
            "observed_at": V2Validation.timestamp(v2Now)]]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady && !fixture.model.visibleMessages.isEmpty }
        let app = AppModel(cloudV2: fixture.model)
        let conversation = try XCTUnwrap(app.accountSMSThreads.first?.id)
        app.selectedSMSConversation = conversation
        let originalScope = app.messageScope

        await fixture.model.selectModule(v2OtherID)
        app.reloadMessagesFromLocalStore()
        XCTAssertNotEqual(app.messageScope, originalScope)
        XCTAssertEqual(app.selectedSMSConversation, conversation)

        app.selectedSMSConversation = SMSConversationID(identity: v2Config(client: v2OtherID).identity,
            moduleID: conversation.moduleID, peer: conversation.peer)
        app.reloadMessagesFromLocalStore()
        XCTAssertNil(app.selectedSMSConversation)

        app.selectedSMSConversation = SMSConversationID(identity: conversation.identity,
            moduleID: conversation.moduleID, peer: "00000000002")
        app.reloadMessagesFromLocalStore()
        XCTAssertNil(app.selectedSMSConversation)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }
}


extension CloudV2Tests {
    func testSignalStrengthDecodingLevelsAndFreshness() throws {
        for (rssi, bars) in [(0, 0), (1, 0), (2, 1), (9, 1), (10, 2), (14, 2), (15, 3), (19, 3), (20, 4), (31, 4)] {
            let value = try V2JSON.decode(V2Signal.self, from: v2Data(v2Signal(rssi: rssi)), limit: 1024)
            XCTAssertEqual(value.presentation(now: v2Now), .available(bars: bars))
            XCTAssertEqual(value.presentation(now: v2Now.addingTimeInterval(30)), .available(bars: bars))
            XCTAssertEqual(value.presentation(now: v2Now.addingTimeInterval(31)), .unavailable)
            XCTAssertEqual(value.presentation(now: v2Now.addingTimeInterval(-4)), .unavailable)
        }
        let unknown = try V2JSON.decode(V2Signal.self, from: v2Data(v2Signal(rssi: nil)), limit: 1024)
        XCTAssertEqual(unknown.presentation(now: v2Now), .unavailable)
        for invalid in [v2Signal(rssi: 99), ["available": true, "observed_at": NSNull(), "rssi": 20, "dbm": -73], ["available": false, "observed_at": NSNull(), "rssi": 20, "dbm": -73]] {
            XCTAssertThrowsError(try V2JSON.decode(V2Signal.self, from: v2Data(invalid), limit: 1024))
        }
        var mismatch = v2Signal(rssi: 20); mismatch["dbm"] = -72
        XCTAssertThrowsError(try V2JSON.decode(V2Signal.self, from: v2Data(mismatch), limit: 1024))
    }

    func testSignalSnapshotAcceptsAbsentAndNullMeasurement() throws {
        let data = try v2SnapshotData()
        XCTAssertNil(try V2JSON.decode(V2SnapshotResponse.self, from: data, limit: 16384).snapshot?.signal)
        var response = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var snapshot = response["snapshot"] as! [String: Any]
        snapshot["signal"] = NSNull(); response["snapshot"] = snapshot
        XCTAssertNil(try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(response), limit: 16384).snapshot?.signal)
        snapshot["signal"] = v2Signal(rssi: 10); response["snapshot"] = snapshot
        XCTAssertEqual(try V2JSON.decode(V2SnapshotResponse.self, from: v2Data(response), limit: 16384).snapshot?.signal?.presentation(now: v2Now), .available(bars: 2))
    }

    @MainActor func testModuleSignalFollowsItsModuleUpdatesAndDisconnection() async throws {
        let fixture = try V2PollFixture()
        addTeardownBlock { await fixture.close() }
        fixture.signals = [v2ID: v2Signal(rssi: 24), v2OtherID: v2Signal(rssi: 8)]
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.snapshot?.snapshot?.signal != nil }
        let app = AppModel(cloudV2: fixture.model)
        XCTAssertEqual(app.moduleSignal(moduleID: nil), .available(bars: 4))
        XCTAssertEqual(app.moduleSignal(moduleID: v2OtherID), .available(bars: 1))
        fixture.signals[v2ID] = v2Signal(rssi: 10)
        try await v2PollWait { app.moduleSignal(moduleID: v2ID) == .available(bars: 2) }
        fixture.signals[v2ID] = v2Signal(rssi: nil)
        try await v2PollWait { app.moduleSignal(moduleID: v2ID) == .unavailable }
        await fixture.model.selectModule(v2OtherID)
        try await v2PollWait { fixture.model.snapshot?.module_id == v2OtherID }
        XCTAssertEqual(app.moduleSignal(moduleID: nil), .available(bars: 1))
        XCTAssertEqual(app.moduleSignal(moduleID: v2ID), .unavailable)
        fixture.offlineModules.insert(v2OtherID)
        try await v2PollWait { fixture.model.snapshot?.online == false }
        XCTAssertEqual(app.moduleSignal(moduleID: v2OtherID), .unavailable)
        await fixture.close()
        XCTAssertEqual(app.moduleSignal(moduleID: v2OtherID), .unavailable)
        XCTAssertEqual(fixture.writes, 0)
    }
}

private func v2Signal(rssi: Int?) -> [String: Any] {
    ["available": rssi != nil, "observed_at": V2Validation.timestamp(v2Now),
     "rssi": rssi.map { $0 as Any } ?? NSNull(),
     "dbm": rssi.map { (-113 + 2 * $0) as Any } ?? NSNull()]
}

extension CloudV2Tests {



}

extension CloudV2Tests {

    @MainActor func testMediaCreationRequestsOpusAndSubmitsCompleteOffer() async throws {
        var offered: URLRequest?
        let transport = V2TestTransport { request in
            if request.url!.path == "/.well-known/airsim" { return V2HTTPResponse(status: 200, body: try v2Discovery()) }
            XCTAssertEqual(request.httpMethod, "POST")
            if request.url!.path.hasSuffix("/offer") {
                offered = request
                return V2HTTPResponse(status: 200, body: try v2Data(["sdp": v2Answer]))
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(body["codec"], "opus")
            XCTAssertEqual(Set(body.keys), Set(["codec", "request_id", "connection_epoch", "generation"]))
            return V2HTTPResponse(status: 201, body: try v2Data(["session_id": v2ID, "expires_at": V2Validation.timestamp(v2Now.addingTimeInterval(30)), "ice_servers": [["urls": ["turn:203.0.113.7:3478?transport=udp"], "username": "1:\(v2ID):client", "credential": "c2VjcmV0"]]]))
        }
        let client = V2Client(transport: transport, tokens: V2TestTokens(), now: { v2Now })
        _ = try await client.connect(v2Config())
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        let snapshot = try V2JSON.decode(V2SnapshotResponse.self, from: v2SnapshotData(calls: [v2CallObject()]), limit: 262144)
        try client.restoreOwnership(context, snapshot: snapshot)
        let created = try await client.createMedia(context: context, requestID: v2ID)
        XCTAssertEqual(created.ice_servers, [V2ICEServer(urls: ["turn:203.0.113.7:3478?transport=udp"], username: "1:\(v2ID):client", credential: "c2VjcmV0")])
        let offer = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"
        let answer = try await client.offerMedia(context: context, sessionID: created.session_id, sdp: offer)
        XCTAssertEqual(answer, v2Answer)
        let request = try XCTUnwrap(offered)
        XCTAssertEqual(request.url?.path, "/v2/modules/\(v2ID)/calls/\(v2OtherID)/media-sessions/\(v2ID)/offer")
        XCTAssertEqual(request.timeoutInterval, 20)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["sdp": offer])
    }

    func testHelperActualAcceptsOpusMetadata() throws {
        let event = try V2JSON.decode(V2HelperEvent.self, from: v2Data(["type": "ready", "codec": "opus", "codec_frame_us": 20000, "sample_rate": 16000, "channels": 1, "sample_format": "s16le", "frame_samples": 320]), limit: 2048)
        XCTAssertEqual(event.codec, "opus"); XCTAssertEqual(event.codec_frame_us, 20000); XCTAssertNil(event.codec_frame_bytes)
    }

    func testMediaSessionAndAnswerValidation() throws {
        func created(_ servers: Any) throws -> V2MediaCreated {
            try V2JSON.decode(V2MediaCreated.self, from: v2Data(["session_id": v2ID, "expires_at": V2Validation.timestamp(v2Now), "ice_servers": servers]), limit: 4096)
        }
        XCTAssertEqual(try created([]).ice_servers, [])
        let valid: [String: Any] = ["urls": ["turn:203.0.113.7:3478?transport=udp"], "username": "u", "credential": "c"]
        XCTAssertEqual(try created([valid]).ice_servers.count, 1)
        for bad: [String: Any] in [
            ["urls": ["stun:203.0.113.7:3478"], "username": "u", "credential": "c"],
            ["urls": [], "username": "u", "credential": "c"],
            ["urls": ["turn:203.0.113.7:3478"], "username": "", "credential": "c"],
            ["urls": ["turn:203.0.113.7:3478"], "username": "u", "credential": "c", "extra": 1],
        ] { XCTAssertThrowsError(try created([bad])) }
        XCTAssertThrowsError(try created(Array(repeating: valid, count: 5)))
        XCTAssertThrowsError(try V2JSON.decode(V2MediaCreated.self, from: v2Data(["session_id": v2ID, "expires_at": V2Validation.timestamp(v2Now), "ice_servers": [], "ticket": String(repeating: "a", count: 64)]), limit: 4096))
        XCTAssertEqual(try V2JSON.decode(V2MediaAnswer.self, from: v2Data(["sdp": v2Answer]), limit: 4096).sdp, v2Answer)
        XCTAssertThrowsError(try V2JSON.decode(V2MediaAnswer.self, from: v2Data(["sdp": "not sdp"]), limit: 4096))
    }
}

extension CloudV2Tests {


}


extension CloudV2Tests {
    func testMediaFailureDiagnosticClassifiesOnlyAllowedOSDomains() {
        for (domain, number, code) in [(NSURLErrorDomain, -1005, V2MediaFailureCode.urlSession), (NSPOSIXErrorDomain, 54, .posix), (NSCocoaErrorDomain, 4097, .cocoa), (NSOSStatusErrorDomain, 560557684, .audioSession)] {
            let error = NSError(domain: domain, code: number, userInfo: [NSLocalizedDescriptionKey: "private payload must not be retained"])
            let diagnostic = V2MediaFailureDiagnostic(error: error, stage: .signaling)
            XCTAssertEqual(diagnostic.code, code); XCTAssertEqual(diagnostic.numericCode, number)
            XCTAssertEqual(diagnostic.domain, code == .audioSession ? nil : domain)
            XCTAssertEqual(diagnostic.stage, .signaling)
        }
        let unrecognized = V2MediaFailureDiagnostic(error: NSError(domain: "private-domain", code: 123, userInfo: [NSLocalizedDescriptionKey: "private payload"]), stage: .streaming)
        XCTAssertEqual(unrecognized.code, .unknown)
        XCTAssertNil(unrecognized.domain); XCTAssertNil(unrecognized.numericCode)
        let http = V2MediaFailureDiagnostic(error: V2HTTPFailure(status: 502), stage: .signaling)
        XCTAssertEqual(http.code, .http); XCTAssertEqual(http.numericCode, 502); XCTAssertNil(http.domain)
        XCTAssertEqual(V2MediaFailureDiagnostic(error: V2PeerError.gathering, stage: .gathering).code, .gathering)
    }

    @MainActor func testV2MediaNegotiatesThroughSignalingAndStopsCleanly() async throws {
        let audio = V2TestAudio(), peer = V2TestPeer()
        var servers: [V2ICEServer] = [], offered: [String] = [], deleted: [String] = []
        let media = V2MediaCoordinator(audio: audio, peerFactory: { servers = $0; return peer }, create: { _, _ in try v2MediaCreated() }, offer: { _, session, sdp in
            XCTAssertEqual(session, v2ID); offered.append(sdp); return v2Answer
        }, delete: { _, id in deleted.append(id) })
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        media.start(context: context, validate: { true }); await v2Yield(100)
        XCTAssertEqual(media.state, .paired)
        XCTAssertEqual(servers.first?.urls.first, "turn:203.0.113.7:3478?transport=udp")
        XCTAssertEqual(offered, [peer.offerSDP]); XCTAssertEqual(peer.accepted, [v2Answer])
        // Without CallKit the coordinator owns the voice session for the call.
        XCTAssertEqual(audio.activations, 1)
        media.setMuted(true); XCTAssertEqual(peer.mutes, [false, true]); XCTAssertTrue(media.muted)
        media.setSpeaker(true); XCTAssertTrue(audio.speaker); XCTAssertTrue(media.speaker)
        peer.stats.packetsReceived = 50; peer.stats.candidate = "relay"
        await media.stop(); await v2Yield()
        XCTAssertEqual(media.state, .idle); XCTAssertFalse(media.active)
        XCTAssertEqual(peer.closed, 1); XCTAssertEqual(deleted, [v2ID]); XCTAssertEqual(audio.deactivations, 1)
        XCTAssertEqual(media.statistics.peer.candidate, "relay")
    }

    @MainActor func testV2CallKitManagedMediaNeverActivatesVoiceSession() async throws {
        let audio = V2TestAudio()
        let media = v2Media(audio: audio)
        media.useCallKitAudioSession()
        media.callKitAudioActivated(AVAudioSession.sharedInstance())
        media.start(context: V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID), validate: { true }); await v2Yield(100)
        XCTAssertEqual(media.state, .paired)
        await media.stop()
        media.callKitAudioDeactivated(AVAudioSession.sharedInstance())
        XCTAssertEqual(audio.activations, 0); XCTAssertEqual(audio.deactivations, 0)
        XCTAssertEqual(audio.callKitActivations, 1); XCTAssertEqual(audio.callKitDeactivations, 1)
    }

    @MainActor func testV2MediaWatchdogsEndSilentDisconnectedOrUnconnectedMedia() async throws {
        let fast = V2MediaTiming(period: .milliseconds(10), connect: .milliseconds(80), disconnected: .milliseconds(40), silence: .milliseconds(150))
        let context = V2CallContext(binding: v2Binding(), callID: v2OtherID, generation: v2ID)
        func run(_ peer: V2TestPeer, _ act: (V2TestPeer) -> Void = { _ in }) async throws -> V2MediaFailureDiagnostic? {
            let media = v2Media(peers: [peer], timing: fast)
            media.start(context: context, validate: { true }); await v2Yield(100)
            act(peer)
            try await v2PollWait { !media.active }
            return media.lastFailure
        }
        // Inbound packets keep media alive until they stop.
        let flowing = V2TestPeer()
        let media = v2Media(peers: [flowing], timing: fast)
        media.start(context: context, validate: { true }); await v2Yield(100)
        for _ in 0..<15 { flowing.stats.packetsReceived += 5; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(media.state, .paired)
        try await v2PollWait { !media.active }
        XCTAssertEqual(media.lastFailure?.code, .downlinkStopped)
        let disconnected = try await run(V2TestPeer()) { $0.onState?(.disconnected) }
        XCTAssertEqual(disconnected?.code, .disconnected)
        let unconnected = V2TestPeer(); unconnected.connectOnAccept = false
        let failure = try await run(unconnected)
        XCTAssertEqual(failure?.code, .timeout); XCTAssertEqual(failure?.stage, .connecting)
        var valid = true
        let revoked = v2Media(timing: fast)
        revoked.start(context: context, validate: { valid }); await v2Yield(100)
        valid = false
        try await v2PollWait { !revoked.active }
        XCTAssertEqual(revoked.lastFailure?.code, .stale)
    }
}


extension CloudV2Tests {
    @MainActor func testSMSBubbleAppearsBeforeNetworkAndFailureRetriesSameRow() async throws {
        let fixture = try V2PollFixture()
        fixture.commandHTTPStatus = 409
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady }
        let app = AppModel(cloudV2: fixture.model)
        let conversation = try XCTUnwrap(app.smsConversation(to: "000000"))
        app.setSMSDraft("optimistic fixture", for: conversation)
        XCTAssertTrue(app.submitSMS(in: conversation, content: "optimistic fixture"))
        let bubble = try XCTUnwrap(app.accountSMSThreads.first?.lastMessage)
        XCTAssertEqual(bubble.text, "optimistic fixture")
        XCTAssertEqual(bubble.state, "pending")
        XCTAssertFalse(bubble.canRetry)
        XCTAssertEqual(fixture.writes, 0)
        XCTAssertEqual(app.smsDraft(for: conversation), "")
        XCTAssertFalse(app.submitSMS(in: conversation, content: "duplicate tap"))
        app.setSMSDraft("next draft", for: conversation)
        try await v2PollWait { app.canSendSMS(in: conversation) }
        XCTAssertNil(app.errorMessage)
        let failed = try XCTUnwrap(app.accountSMSThreads.first?.lastMessage)
        XCTAssertEqual(failed.id, bubble.id)
        XCTAssertTrue(failed.canRetry)
        let restored = CloudV2Model(defaults: fixture.defaults, root: fixture.root, tokens: fixture.tokens, now: { v2Now })
        let restoredApp = AppModel(cloudV2: restored)
        restoredApp.projectCloudState()
        XCTAssertEqual(restoredApp.accountSMSThreads.first?.lastMessage, failed)
        fixture.commandHTTPStatus = 200
        let result = await app.retrySMS(failed)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(app.accountSMSThreads.first?.messages.count, 1)
        XCTAssertEqual(app.accountSMSThreads.first?.lastMessage.id, bubble.id)
        XCTAssertFalse(app.accountSMSThreads.first!.lastMessage.canRetry)
        XCTAssertEqual(app.smsDraft(for: conversation), "next draft")
        let duplicate = await app.retrySMS(failed)
        XCTAssertEqual(duplicate, .unknown)
        XCTAssertEqual(fixture.writes, 2)
        await fixture.close()
    }

    @MainActor func testSMSUnknownSurvivesRestartAndReceiptDeduplicatesOnlyExactMessage() async throws {
        let fixture = try V2PollFixture()
        fixture.delayedReceipts = true
        fixture.receiptCompletionAfter = 1000
        fixture.receiptMessageID = v2OtherID
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady }
        let app = AppModel(cloudV2: fixture.model)
        let conversation = try XCTUnwrap(app.smsConversation(to: "000000"))
        let result = await app.sendSMS(in: conversation, content: "same text")
        XCTAssertEqual(result, .unknown)
        let bubble = try XCTUnwrap(app.accountSMSThreads.first?.lastMessage)
        XCTAssertFalse(bubble.canRetry)
        XCTAssertNil(app.errorMessage)
        await fixture.model.stop()
        fixture.receiptCompletionAfter = 0
        // The same body can occur twice; only the ID from the receipt is collapsed.
        fixture.snapshotMessages = [v2ID, v2OtherID].map {
            ["message_id": $0, "direction": "outgoing", "sender": "", "recipient": "000000",
             "text": "same text", "state": "sent", "delivery": "unknown", "observed_at": V2Validation.timestamp(v2Now)]
        }
        let restored = CloudV2Model(client: V2Client(transport: fixture.transport, tokens: fixture.tokens,
            now: { fixture.currentNow }), defaults: fixture.defaults, root: fixture.root,
            tokens: fixture.tokens, now: { fixture.currentNow })
        fixture.model = restored
        let restoredApp = AppModel(cloudV2: restored)
        restoredApp.projectCloudState()
        XCTAssertEqual(restoredApp.accountSMSThreads.first?.lastMessage.id, bubble.id)
        XCTAssertFalse(restoredApp.accountSMSThreads.first!.lastMessage.canRetry)
        await restored.sceneChanged(.active)
        try await v2PollWait { !restored.hasUnresolvedCommand && restored.visibleMessages.count == 2 }
        restoredApp.projectCloudState()
        XCTAssertEqual(restoredApp.accountSMSThreads.first?.messages.count, 2)
        XCTAssertEqual(restoredApp.accountSMSThreads.first?.messages.filter { $0.id == bubble.id }.count, 1)
        XCTAssertEqual(restored.history.outgoingMessages?.first?.state, "sent")
        restored.clearCurrentMessages()
        restoredApp.projectCloudState()
        XCTAssertTrue(restoredApp.accountSMSThreads.isEmpty)
        XCTAssertTrue(restored.history.outgoingMessages?.isEmpty == true)
        XCTAssertEqual(restored.history.clearedMessageIDs?.count, 2)
        XCTAssertEqual(fixture.writes, 1)
        let journal = try? Data(contentsOf: fixture.root.appendingPathComponent("pending.json"))
        XCTAssertNil(journal)
        await fixture.close()
    }
}

extension CloudV2Tests {
    @MainActor func testSMSHistoryWriteFailureKeepsDraftAndDoesNotPost() async throws {
        let fixture = try V2PollFixture()
        fixture.commandHTTPStatus = 200
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady }
        let app = AppModel(cloudV2: fixture.model)
        let conversation = try XCTUnwrap(app.smsConversation(to: "000000"))
        app.setSMSDraft("unsaved fixture", for: conversation)
        let file = fixture.root.appendingPathComponent("history.json")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertFalse(app.submitSMS(in: conversation, content: "unsaved fixture"))
        XCTAssertEqual(app.smsDraft(for: conversation), "unsaved fixture")
        XCTAssertTrue(app.accountSMSThreads.isEmpty)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }

    @MainActor func testSMSStagedBeforeJournalCanRetryAfterRestart() async throws {
        let fixture = try V2PollFixture()
        await fixture.model.sceneChanged(.active)
        try await v2PollWait { fixture.model.messagingReady }
        let row = V2OutgoingMessage(id: v2OtherID, identity: v2Config().identity, moduleID: v2ID,
            recipient: "000000", text: "interrupted fixture", timestamp: v2Now)
        XCTAssertTrue(fixture.model.stageOutgoingMessage(row))
        let restored = CloudV2Model(defaults: fixture.defaults, root: fixture.root, tokens: fixture.tokens, now: { v2Now })
        let app = AppModel(cloudV2: restored)
        app.projectCloudState()
        XCTAssertEqual(app.accountSMSThreads.first?.lastMessage.id, row.id)
        XCTAssertTrue(app.accountSMSThreads.first!.lastMessage.canRetry)
        XCTAssertEqual(fixture.writes, 0)
        await fixture.close()
    }
}
