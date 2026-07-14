import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) } else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) } else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var doubleValue: Double? { if case .number(let value) = self { value } else { nil } }
    var intValue: Int? { doubleValue.map(Int.init) }
    subscript(_ key: String) -> JSONValue? { objectValue?[key] }
}

struct RPCResponse: Decodable, Sendable { let id: Int?; let result: JSONValue?; let error: JSONValue?; let method: String?; let params: JSONValue? }
enum RPCError: Error { case timeout, disconnected, server(JSONValue), malformed }
extension RPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .timeout: "请求超时"
        case .disconnected: "App Server 已断开"
        case .malformed: "App Server 返回了无法解析的响应"
        case .server(let value): value["code"]?.intValue.map { "App Server 请求失败（错误码 \($0)）" } ?? "App Server 请求失败"
        }
    }
}

extension RPCError {
    var shouldReconnect: Bool {
        switch self {
        case .timeout, .disconnected: true
        case .server, .malformed: false
        }
    }

    var shouldRetryWithoutReconnect: Bool {
        guard case .server(let value) = self else { return false }
        return value["code"]?.intValue == -32603
    }
}

struct RPCRequestRetryPolicy: Sendable {
    var delays: [TimeInterval] = [0.75, 2, 5]

    func delay(afterFailure failureIndex: Int, error: Error) -> TimeInterval? {
        guard (error as? RPCError)?.shouldRetryWithoutReconnect == true,
              delays.indices.contains(failureIndex) else { return nil }
        return delays[failureIndex]
    }
}
