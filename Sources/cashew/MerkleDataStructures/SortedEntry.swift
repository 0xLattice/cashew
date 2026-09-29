struct SortedEntry<Value: Codable>: Codable {
    let key: String
    let value: Value
}

extension KeyedDecodingContainer {
    /// Decodes a trie node's child list into a map keyed by single character.
    ///
    /// Node bytes are attacker-authored, so this fails closed: an entry whose
    /// key is not exactly one character, or a key that repeats, throws a
    /// decoding error instead of being dropped or trapping.
    func decodeChildMap<Child: Codable>(
        _ type: Child.Type,
        forKey key: Key
    ) throws -> [Character: Child] {
        let entries = try decode([SortedEntry<Child>].self, forKey: key)
        var children: [Character: Child] = [:]
        children.reserveCapacity(entries.count)
        for entry in entries {
            guard entry.key.count == 1, let character = entry.key.first else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: self,
                    debugDescription: "child key must be exactly one character"
                )
            }
            guard children.updateValue(entry.value, forKey: character) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: self,
                    debugDescription: "duplicate child key"
                )
            }
        }
        return children
    }
}
