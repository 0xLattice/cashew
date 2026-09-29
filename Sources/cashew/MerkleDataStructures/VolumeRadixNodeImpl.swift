import Foundation

/// Radix-trie node whose children link out through ``VolumeRadixHeaderImpl`` —
/// i.e. every edge crosses a Volume boundary. Structurally identical to
/// ``RadixNodeImpl``; differs only in ``ChildType``. All mutation logic
/// (`inserting`, `deleting`, `mutating`) is inherited from ``RadixNode``'s
/// protocol extensions and reuses the Volume-aware header type automatically.
public struct VolumeRadixNodeImpl<Value>: RadixNode
where Value: Codable, Value: Sendable, Value: LosslessStringConvertible {
    public typealias ValueType = Value
    public typealias ChildType = VolumeRadixHeaderImpl<Value>

    public var prefix: String
    public var value: ValueType?
    public var children: [Character: ChildType]

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

        let sorted = children.sorted { String($0.key) < String($1.key) }
            .map { SortedEntry(key: String($0.key), value: $0.value) }
        try container.encode(sorted, forKey: .children)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prefix = try container.decode(String.self, forKey: .prefix)
        value = try container.decodeIfPresent(ValueType.self, forKey: .value)

        children = try container.decodeChildMap(ChildType.self, forKey: .children)
    }
}
