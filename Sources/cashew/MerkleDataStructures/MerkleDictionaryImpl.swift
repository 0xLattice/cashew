/// Default concrete implementation of ``MerkleDictionary``.
public struct MerkleDictionaryImpl<Value>: MerkleDictionary where Value: Codable, Value: Sendable, Value: LosslessStringConvertible {
    public typealias ValueType = Value
    public typealias ChildType = RadixHeaderImpl<Value>

    public var count: Int
    public var children: [Character : ChildType]

    public init(children: [Character : ChildType], count: Int) {
        self.children = children
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case children, count
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)

        // Encode as sorted array of key-value pairs for deterministic serialization across platforms
        let sorted = children.sorted { String($0.key) < String($1.key) }
            .map { SortedEntry(key: String($0.key), value: $0.value) }
        try container.encode(sorted, forKey: .children)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)

        children = try container.decodeChildMap(ChildType.self, forKey: .children)
    }
}
