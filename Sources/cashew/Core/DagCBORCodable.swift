import Foundation

// MARK: - Links

extension DagCBORCodable where Self: Header {
    /// A link as `HeaderImpl` and `VolumeImpl` encode one: `rawCID`, then
    /// `encryptionInfo` when present.
    @inlinable static func readLink(_ reader: inout DagCBORReader) throws -> Self {
        _ = try reader.readMapCount()
        try reader.readKey("rawCID")
        let rawCID = try reader.readText()
        let encryptionInfo = reader.consumeKey("encryptionInfo") ? try EncryptionInfo(dagCBOR: &reader) : nil
        return Self(rawCID: rawCID, node: nil, encryptionInfo: encryptionInfo)
    }

    @inlinable func writeLink(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: encryptionInfo == nil ? 1 : 2)
        writer.writeText("rawCID")
        writer.writeText(rawCID)
        if let encryptionInfo {
            writer.writeText("encryptionInfo")
            try encryptionInfo.writeDagCBOR(to: &writer)
        }
    }
}

extension HeaderImpl: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        self = try Self.readLink(&reader)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writeLink(to: &writer)
    }
}

extension VolumeImpl: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        self = try Self.readLink(&reader)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writeLink(to: &writer)
    }
}

extension EncryptionInfo: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        _ = try reader.readMapCount()
        try reader.readKey("iv")
        let iv = try reader.readText()
        try reader.readKey("keyHash")
        self.init(keyHash: try reader.readText(), iv: iv)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: 2)
        writer.writeText("iv")
        writer.writeText(iv)
        writer.writeText("keyHash")
        writer.writeText(keyHash)
    }
}

extension FlatDictionary: DagCBORCodable where Value: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        let count = try reader.readMapCount()
        var entries: [String: Value] = [:]
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let key = try reader.readText()
            entries[key] = try Value(dagCBOR: &reader)
        }
        self.init(entries)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: entries.count)
        for key in entries.keys.sorted(by: DagCBOR.keyPrecedes) {
            writer.writeText(key)
            try entries[key]!.writeDagCBOR(to: &writer)
        }
    }
}

// MARK: - Tries

extension RadixHeaderImpl: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        self = try Self.readLink(&reader)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writeLink(to: &writer)
    }
}

extension VolumeRadixHeaderImpl: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        self = try Self.readLink(&reader)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writeLink(to: &writer)
    }
}

extension DagCBORReader {
    /// A trie node's children: an array of `{key, value}` entries, keyed by
    /// each key's first character, as `KeyedDecodingContainer.decodeChildren`
    /// reads them.
    @inlinable mutating func readChildren<Child: DagCBORCodable>(_: Child.Type) throws -> [Character: Child] {
        let count = try readArrayCount()
        var children: [Character: Child] = [:]
        children.reserveCapacity(count)
        for _ in 0..<count {
            _ = try readMapCount()
            try readKey("key")
            let key = try readText()
            try readKey("value")
            let child = try Child(dagCBOR: &self)
            // A repeated first character, or an empty key, leaves fewer
            // children than entries: re-encoding refuses it.
            guard let first = key.first else { continue }
            children[first] = child
        }
        return children
    }
}

extension DagCBORWriter {
    /// A trie node's children as `Codable` encoding writes them: entries
    /// `{key, value}` in `String` order of their keys.
    @inlinable mutating func writeChildren<Child: DagCBORCodable>(_ children: [Character: Child]) throws {
        try writeArrayHeader(count: children.count)
        for (key, child) in children.sorted(by: { String($0.key) < String($1.key) }) {
            try writeMapHeader(count: 2)
            writeText("key")
            writeText(String(key))
            writeText("value")
            try child.writeDagCBOR(to: &self)
        }
    }
}

// Keys in canonical order: "count" before "children"; "value", "prefix",
// then "children".

extension MerkleDictionaryImpl: DagCBORCodable where Value: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        _ = try reader.readMapCount()
        try reader.readKey("count")
        let count = try Int(dagCBOR: &reader)
        try reader.readKey("children")
        self.init(children: try reader.readChildren(ChildType.self), count: count)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: 2)
        writer.writeText("count")
        try count.writeDagCBOR(to: &writer)
        writer.writeText("children")
        try writer.writeChildren(children)
    }
}

extension VolumeMerkleDictionaryImpl: DagCBORCodable where Value: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        _ = try reader.readMapCount()
        try reader.readKey("count")
        let count = try Int(dagCBOR: &reader)
        try reader.readKey("children")
        self.init(children: try reader.readChildren(ChildType.self), count: count)
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: 2)
        writer.writeText("count")
        try count.writeDagCBOR(to: &writer)
        writer.writeText("children")
        try writer.writeChildren(children)
    }
}

extension RadixNodeImpl: DagCBORCodable where Value: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        _ = try reader.readMapCount()
        let value = reader.consumeKey("value") ? try Value(dagCBOR: &reader) : nil
        try reader.readKey("prefix")
        let prefix = try reader.readText()
        try reader.readKey("children")
        self.init(prefix: prefix, value: value, children: try reader.readChildren(ChildType.self))
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: value == nil ? 2 : 3)
        if let value {
            writer.writeText("value")
            try value.writeDagCBOR(to: &writer)
        }
        writer.writeText("prefix")
        writer.writeText(prefix)
        writer.writeText("children")
        try writer.writeChildren(children)
    }
}

extension VolumeRadixNodeImpl: DagCBORCodable where Value: DagCBORCodable {
    @inlinable public init(dagCBOR reader: inout DagCBORReader) throws {
        _ = try reader.readMapCount()
        let value = reader.consumeKey("value") ? try Value(dagCBOR: &reader) : nil
        try reader.readKey("prefix")
        let prefix = try reader.readText()
        try reader.readKey("children")
        self.init(prefix: prefix, value: value, children: try reader.readChildren(ChildType.self))
    }

    @inlinable public func writeDagCBOR(to writer: inout DagCBORWriter) throws {
        try writer.writeMapHeader(count: value == nil ? 2 : 3)
        if let value {
            writer.writeText("value")
            try value.writeDagCBOR(to: &writer)
        }
        writer.writeText("prefix")
        writer.writeText(prefix)
        writer.writeText("children")
        try writer.writeChildren(children)
    }
}
