import Foundation

/// Default concrete implementation of ``RadixNode``.
public struct RadixNodeImpl<Value>: RadixNode where Value: Codable, Value: Sendable, Value: LosslessStringConvertible {
    public typealias ValueType = Value
    public typealias ChildType = RadixHeaderImpl<Value>

    public var prefix: String
    public var value: ValueType?
    public var children: [Character : ChildType]

    public init(prefix: String, value: ValueType?, children: [Character: ChildType]) {
        self.prefix = prefix
        self.value = value
        self.children = children
    }

    enum CodingKeys: String, CodingKey {
        case prefix, value, children
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prefix, forKey: .prefix)
        try container.encodeIfPresent(value, forKey: .value)

        // Encode as sorted array of key-value pairs for deterministic serialization across platforms
        let sorted = children.sorted { String($0.key) < String($1.key) }
            .map { SortedEntry(key: String($0.key), value: $0.value) }
        try container.encode(sorted, forKey: .children)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefix = try container.decode(String.self, forKey: .prefix)
        value = try container.decodeIfPresent(ValueType.self, forKey: .value)

        children = try container.decodeChildren(ChildType.self, forKey: .children)
    }
}
