struct SortedEntry<Value: Codable>: Codable {
    let key: String
    let value: Value
}

extension KeyedDecodingContainer {
    /// Decodes a trie node's children, keyed by each entry's first character.
    /// Two entries for one character are corrupt data: throw, never trap.
    func decodeChildren<Child: Codable>(_ type: Child.Type, forKey key: Key) throws -> [Character: Child] {
        let entries = try decode([SortedEntry<Child>].self, forKey: key)
        return try Dictionary(entries.compactMap { entry in
            entry.key.first.map { ($0, entry.value) }
        }, uniquingKeysWith: { _, _ in
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "duplicate child key")
        })
    }
}
