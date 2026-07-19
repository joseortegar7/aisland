import Foundation

/// Wire protocol version. Bump on breaking envelope changes.
public let wireProtocolVersion = 1

/// Maximum accepted line length (diff payloads can be large, but bound memory).
public let wireMaxLineBytes = 4 * 1024 * 1024

public enum WireType: String, Codable, Sendable {
    /// shim → app, fire-and-forget lifecycle event (SessionStart, Stop, Notification, …)
    case hookEvent
    /// shim → app, blocking: app must answer with a `gateResponse` on the same connection
    case gateRequest
    /// app → shim
    case gateResponse
    /// SSH-forwarded shim identifying its host
    case remoteHello
    /// islandctl → app: test injection, status dump
    case ctlCommand
}

/// Envelope header, decodable without knowing the body type.
public struct EnvelopeHeader: Codable, Sendable {
    public var v: Int
    public var id: UUID
    public var type: WireType
}

/// Full typed envelope. One envelope per NDJSON line.
public struct Envelope<Body: Codable & Sendable>: Codable, Sendable {
    public var v: Int
    public var id: UUID
    public var type: WireType
    public var body: Body

    public init(id: UUID = UUID(), type: WireType, body: Body) {
        self.v = wireProtocolVersion
        self.id = id
        self.type = type
        self.body = body
    }
}

public enum WireCodec {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Encode an envelope as a single NDJSON line (terminating newline included).
    public static func encodeLine<Body: Codable & Sendable>(_ envelope: Envelope<Body>) throws -> Data {
        var data = try encoder.encode(envelope)
        data.append(0x0A)
        return data
    }

    public static func decodeHeader(_ line: Data) throws -> EnvelopeHeader {
        try decoder.decode(EnvelopeHeader.self, from: line)
    }

    public static func decode<Body: Codable & Sendable>(_ type: Body.Type, from line: Data) throws -> Envelope<Body> {
        try decoder.decode(Envelope<Body>.self, from: line)
    }
}
