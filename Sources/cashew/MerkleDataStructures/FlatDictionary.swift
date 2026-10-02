/// A flat map of references in one node: each key names a child header.
///
/// Encoded as a plain DAG-CBOR map; the decoder accepts only its canonical
/// bytes, so one map has one CID.
public struct FlatDictionary<Value: Header>: Node {
    public var entries: [String: Value]

    public init(_ entries: [String: Value] = [:]) {
        self.entries = entries
    }

    public subscript(key: String) -> Value? {
        entries[key]
    }

    public var count: Int { entries.count }

    public func get(property: PathSegment) -> (any Header)? {
        entries[property]
    }

    public func properties() -> Set<PathSegment> {
        Set(entries.keys)
    }

    public func set(properties: [PathSegment: any Header]) -> Self {
        var updated = entries
        for (key, header) in properties {
            guard let child = header as? Value else {
                preconditionFailure("FlatDictionary<\(Value.self)> given a \(type(of: header)) at '\(key)'")
            }
            updated[key] = child
        }
        return Self(updated)
    }

    public init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([String: Value].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}
