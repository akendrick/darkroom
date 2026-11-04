import Foundation

/// A JSON value. The server (PHP + MySQL) sends numbers either as numbers or
/// as strings ("12", "40.0"), so rows are kept as JSON and read through the
/// lenient accessors below rather than decoded into strict types.
enum JSON: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }

    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }

    var string: String? {
        switch self {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0.rounded()) } }
    /// MySQL flags arrive as 0/1, "0"/"1" or true/false.
    var flag: Bool { (double ?? 0) != 0 }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(integerLiteral v: Int) { self = .number(Double(v)) }
    init(floatLiteral v: Double) { self = .number(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(nilLiteral: ()) { self = .null }
}

extension JSON {
    static func from(_ v: String?) -> JSON { v.map { .string($0) } ?? .null }
    static func from(_ v: Int?) -> JSON { v.map { .number(Double($0)) } ?? .null }
    static func from(_ v: Double?) -> JSON { v.map { .number($0) } ?? .null }
}
