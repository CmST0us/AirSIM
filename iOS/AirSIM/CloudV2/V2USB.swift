import Foundation
import Network
import Security
import CryptoKit

struct V2USBAuthorization: Codable, Equatable {
    let server_id: String
    let module_id: String
    let client_installation_id: String
    let api_origin: String
    let certificate_der_base64: String
    let token: String
    let expires_at: String

    func validate(configuration: V2Configuration, now: Date) throws {
        guard server_id == configuration.identity.serverID,
              module_id == configuration.moduleID,
              client_installation_id == configuration.identity.clientInstallationID,
              let url = URL(string: api_origin), url.scheme == "https", url.host == "192.168.225.1",
              url.port == 8577, url.path.isEmpty, url.query == nil, url.fragment == nil, url.user == nil,
              let certificate = Data(base64Encoded: certificate_der_base64), certificate.count <= 8192,
              SecCertificateCreateWithData(nil, certificate as CFData) != nil,
              V2Validation.matches(token, "^[0-9a-f]{64}$") else { throw V2Error.invalidIdentity }
        let remaining = try V2Validation.date(expires_at).timeIntervalSince(now)
        guard remaining > 0, remaining <= 86405 else { throw V2Error.expired }
    }
    var certificate: Data { Data(base64Encoded: certificate_der_base64)! }
    func sign(_ request: URLRequest, now: Date = Date(), nonce: String? = nil) throws -> URLRequest {
        guard let url = request.url, url.absoluteString.hasPrefix(api_origin + "/") else { throw V2Error.invalidIdentity }
        var request = request
        let timestamp = String(Int64(now.timeIntervalSince1970))
        var random = [UInt8](repeating: 0, count: 32)
        if nonce == nil, SecRandomCopyBytes(kSecRandomDefault, random.count, &random) != errSecSuccess { throw V2Error.keychain }
        let nonce = nonce ?? random.map { String(format: "%02x", $0) }.joined()
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        var message = Data("\(timestamp)\n\(nonce)\n\(request.httpMethod ?? "GET")\n\(path)\n".utf8)
        message.append(request.httpBody ?? Data())
        let key = stride(from: 0, to: token.count, by: 2).map { index -> UInt8 in
            let start = token.index(token.startIndex, offsetBy: index)
            return UInt8(token[start..<token.index(start, offsetBy: 2)], radix: 16)!
        }
        let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(timestamp, forHTTPHeaderField: "X-AirSIM-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-AirSIM-Nonce")
        request.setValue(signature, forHTTPHeaderField: "X-AirSIM-Signature")
        return request
    }
}

struct V2USBSaved: Codable { let authorization: V2USBAuthorization; let discovery: Data }
struct V2USBStore {
    private func query(_ configuration: V2Configuration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cc.eric3u.airsim.usb.v2", kSecAttrAccount as String: configuration.identity.account + ":" + (configuration.moduleID ?? ""), kSecAttrSynchronizable as String: false]
    }
    func load(_ configuration: V2Configuration, now: Date) -> V2USBSaved? {
        var q = query(configuration); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(V2USBSaved.self, from: data),
              (try? value.authorization.validate(configuration: configuration, now: now)) != nil else { return nil }
        return value
    }
    func save(_ value: V2USBSaved, configuration: V2Configuration) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(configuration) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(configuration).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw V2Error.keychain }
        } else if status != errSecSuccess { throw V2Error.keychain }
    }
}

enum V2USBTLS {
    static func options(certificate: Data, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                  SecCertificateCopyData(leaf) as Data == certificate else { complete(false); return }
            // The exact module certificate was delivered by the authenticated ECS session.
            SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)
        return options
    }
}
