import Foundation

/// 느슨한 JSON 표현. Codex app-server 메시지는 버전마다 필드가 조금씩 달라서
/// 엄격한 구조체 대신 이 타입으로 받아서 필요한 키만 꺼내 씁니다.
enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "알 수 없는 JSON 값")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let list) = self, list.indices.contains(index) { return list[index] }
        return nil
    }

    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    var intValue: Int? { doubleValue.map { Int($0) } }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var isNull: Bool { self == .null }

    /// 문자열이면 그대로, 숫자/불리언이면 문자열로 바꿔서 돌려줍니다.
    var displayString: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.rounded() == v ? String(Int(v)) : String(v)
        case .bool(let v): return v ? "true" : "false"
        case .null: return "null"
        case .array, .object: return (try? compactJSON()) ?? ""
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    func compactJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    func prettyJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 두 객체를 합칩니다. 오른쪽 값이 우선합니다.
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        var dict = objectValue ?? [:]
        for (k, v) in other { dict[k] = v }
        return .object(dict)
    }
}
