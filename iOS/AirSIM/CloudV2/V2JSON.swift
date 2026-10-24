import Foundation

// Stable errors only: no underlying network error, URL, payload or credential descriptions.
enum V2Error: String, Error { case invalidJSON, invalidValue, invalidIdentity, expired, keychain, transport, redirect, oversized, unauthorized, stale, busy, persistence, protocolViolation }

enum V2Validation {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }
    static func uuid(_ value: String, empty: Bool = false) throws {
        guard (empty && value.isEmpty) || matches(value, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$") else { throw V2Error.invalidIdentity }
    }
    static func date(_ value: String) throws -> Date {
        guard matches(value, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$") else { throw V2Error.invalidValue }
        let formatter = ISO8601DateFormatter()
        let whole = String(value.prefix(19)) + "Z"
        guard let base = formatter.date(from: whole), formatter.string(from: base) == whole else { throw V2Error.invalidValue }
        if let dot = value.firstIndex(of: ".") {
            let fraction = String(value[dot..<value.index(before: value.endIndex)])
            guard let seconds = Double("0" + fraction) else { throw V2Error.invalidValue }
            return base.addingTimeInterval(seconds)
        }
        return base
    }
    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func origin(_ value: String) throws -> String {
        guard let c = URLComponents(string: value), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.percentEncodedPath == "" || c.percentEncodedPath == "/",
              c.port == nil || (1...65535).contains(c.port!), c.url != nil,
              !value.contains("\\"), !value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(":"), !value.contains(where: { $0.isWhitespace }) else { throw V2Error.invalidValue }
        var normalized = c
        normalized.host = host.lowercased()
        normalized.path = ""
        guard let result = normalized.string else { throw V2Error.invalidValue }
        return result
    }
}

// JSONDecoder alone discards duplicate keys. This bounded scanner checks every object,
// including escaped spellings of a key, before Foundation performs full JSON decoding.
struct V2JSONScanner {
    private let bytes: [UInt8]
    private var index = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func check() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw V2Error.invalidJSON }
    }
    private mutating func whitespace() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    private mutating func take(_ byte: UInt8) throws { whitespace(); guard index < bytes.count, bytes[index] == byte else { throw V2Error.invalidJSON }; index += 1 }
    private mutating func string() throws -> String {
        try take(34)
        let start = index - 1
        while index < bytes.count {
            let b = bytes[index]; index += 1
            if b == 92 { guard index < bytes.count else { throw V2Error.invalidJSON }; index += 1 }
            else if b == 34 {
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw V2Error.invalidJSON }
                return result
            }
        }
        throw V2Error.invalidJSON
    }
    private mutating func value(depth: Int) throws {
        guard depth < 32 else { throw V2Error.invalidJSON }
        whitespace(); guard index < bytes.count else { throw V2Error.invalidJSON }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var keys = Set<String>()
            if index < bytes.count, bytes[index] == 125 { index += 1; return }
            while true {
                let key = try string(); guard keys.insert(key).inserted else { throw V2Error.invalidJSON }
                try take(58); try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw V2Error.invalidJSON }
                if bytes[index] == 125 { index += 1; return }; try take(44)
            }
        case 91:
            index += 1; whitespace()
            if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace(); guard index < bytes.count else { throw V2Error.invalidJSON }
                if bytes[index] == 93 { index += 1; return }; try take(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw V2Error.invalidJSON }
        }
    }
}

struct V2Key: CodingKey { let stringValue: String; var intValue: Int? { nil }; init(_ s: String) { stringValue = s }; init?(stringValue: String) { self.init(stringValue) }; init?(intValue: Int) { return nil } }
extension Decoder {
    func v2Fields(_ required: String, optional: String = "") throws -> KeyedDecodingContainer<V2Key> {
        let c = try container(keyedBy: V2Key.self)
        let r = Set(required.split(separator: " ").map(String.init)), o = Set(optional.split(separator: " ").map(String.init))
        let actual = Set(c.allKeys.map(\.stringValue))
        guard r.isSubset(of: actual), actual.isSubset(of: r.union(o)) else { throw V2Error.invalidJSON }
        return c
    }
}
extension KeyedDecodingContainer where Key == V2Key {
    func get<T: Decodable>(_ key: String) throws -> T { try decode(T.self, forKey: V2Key(key)) }
    func optional<T: Decodable>(_ key: String) throws -> T? {
        guard contains(V2Key(key)) else { return nil }
        return try decode(T.self, forKey: V2Key(key)) // optional does not mean nullable
    }
    func nullable<T: Decodable>(_ key: String) throws -> T? { try decodeIfPresent(T.self, forKey: V2Key(key)) }
}
enum V2JSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, limit: Int) throws -> T {
        guard data.count <= limit else { throw V2Error.oversized }
        do { var scanner = V2JSONScanner(data); try scanner.check(); return try JSONDecoder().decode(type, from: data) }
        catch let error as V2Error { throw error }
        catch { throw V2Error.invalidJSON }
    }
}
