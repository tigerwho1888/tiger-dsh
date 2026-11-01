import Foundation

/// A loosely typed JSON value. DSH's host API is wide and changes between versions, so the app reads
/// only the fields it needs and ignores the rest, the same way the old web app did.
enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        // Strings and keys are copied into native Swift storage: JSONSerialization hands back Objective-C strings,
        // and those then travel the whole app, across threads, as lazily bridged objects.
        case let s as String: self = .string(JSON.native(s))
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any]:
            var d = [String: JSON](minimumCapacity: o.count)
            for (k, v) in o { d[JSON.native(k)] = JSON(any: v) }
            self = .object(d)
        default: self = .null
        }
    }

    private static func native(_ s: String) -> String { String(decoding: s.utf8, as: UTF8.self) }

    static func parse(_ data: Data) throws -> JSON {
        JSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 9e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    func data() -> Data { (try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed])) ?? Data("null".utf8) }
    var compact: String { String(decoding: data(), as: UTF8.self) }

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }
    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var str: String { string ?? "" }
    var double: Double? { if case .number(let n) = self { return n }; if case .string(let s) = self { return Double(s) }; return nil }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { if case .null = self { return true }; return false }
    var isObject: Bool { if case .object = self { return true }; return false }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    init(stringLiteral v: String) { self = .string(v) }
    init(integerLiteral v: Int) { self = .number(Double(v)) }
    init(floatLiteral v: Double) { self = .number(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }
}

extension JSON {
    static func str(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    /// Object literal that drops nil values, for optional request fields.
    static func obj(_ pairs: [(String, JSON?)]) -> JSON {
        var o: [String: JSON] = [:]
        for (k, v) in pairs { if let v, !v.isNull { o[k] = v } }
        return .object(o)
    }
}
