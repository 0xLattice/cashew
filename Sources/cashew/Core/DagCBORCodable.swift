import Foundation

/// A type that reads and writes its own DAG-CBOR in one pass, instead of
/// through `Codable`.
///
/// ``DagCBOR`` uses it for every encode and decode of the type, under the same
/// rule as any other type: decoded bytes must be exactly the bytes writing the
/// result gives back. So a reader need only read correctly; the rule refuses
/// every second spelling. The contract, which
/// ``DagCBOR/encodeThroughCodable(_:)`` and
/// ``DagCBOR/decodeThroughCodable(_:from:)`` let a conformance be tested
/// against:
/// - `writeDagCBOR` writes the bytes `Codable` encoding writes, so a value
///   has one encoding and one CID whichever path wrote it;
/// - `init(dagCBOR:)` reads back every value it writes, and refuses whatever
///   the type's `init(from:)` refuses.
public protocol DagCBORCodable {
    init(dagCBOR reader: inout DagCBORReader) throws
    func writeDagCBOR(to writer: inout DagCBORWriter) throws
}

/// Reads DAG-CBOR items in order from encoded bytes. Heads of any width are
/// read; the shortest-form rule is enforced by re-encoding (see
/// ``DagCBORCodable``).
public struct DagCBORReader {
    public let bytes: [UInt8]
    @usableFromInline var position = 0

    @inlinable public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    @inlinable public var isAtEnd: Bool { position == bytes.count }

    /// The argument of a head of major type `major`.
    @inlinable public mutating func readHead(major: UInt8) throws -> UInt64 {
        guard position < bytes.count else { throw DagCBORError.unexpectedEnd }
        let initial = bytes[position]
        guard initial >> 5 == major else { throw DagCBORError.invalidCBOR }
        let additional = initial & 0x1f
        if additional < 24 {
            position += 1
            return UInt64(additional)
        }
        guard additional <= 27 else { throw DagCBORError.invalidCBOR }
        let width = 1 << Int(additional - 24)
        guard bytes.count - position - 1 >= width else { throw DagCBORError.unexpectedEnd }
        var value: UInt64 = 0
        for index in 1...width {
            value = value << 8 | UInt64(bytes[position + index])
        }
        position += 1 + width
        return value
    }

    /// A map head's entry count, within ``DagCBOR/maxCollectionCount``.
    @inlinable public mutating func readMapCount() throws -> Int {
        let count = try readHead(major: 5)
        guard count <= DagCBOR.maxCollectionCount else { throw DagCBORError.invalidCBOR }
        return Int(count)
    }

    /// A text string. Ill-formed UTF-8 reads as U+FFFD, which writes back
    /// as other bytes, so re-encoding refuses it.
    @inlinable public mutating func readText() throws -> String {
        let length = try readHead(major: 3)
        guard length <= UInt64(bytes.count - position) else { throw DagCBORError.unexpectedEnd }
        let end = position + Int(length)
        let text = String(decoding: bytes[position..<end], as: UTF8.self)
        position = end
        return text
    }

    /// Whether the next item is the text `key`, consuming it if so. A type
    /// reads its map keys in the order it writes them: in any other order the
    /// bytes are not its encoding, which re-encoding would refuse anyway.
    @inlinable public mutating func consumeKey(_ key: StaticString) -> Bool {
        let before = position
        let length = key.utf8CodeUnitCount
        guard (try? readHead(major: 3)) == UInt64(length),
              bytes.count - position >= length,
              (0..<length).allSatisfy({ bytes[position + $0] == key.utf8Start[$0] }) else {
            position = before
            return false
        }
        position += length
        return true
    }

    /// Consumes the map key `key`, which must be next.
    @inlinable public mutating func readKey(_ key: StaticString) throws {
        guard consumeKey(key) else { throw DagCBORError.invalidCBOR }
    }

    @inlinable public mutating func readUInt64() throws -> UInt64 {
        try readHead(major: 0)
    }

    /// An `Int64`: major 0 at or above zero, major 1 with argument `~value`
    /// below it.
    @inlinable public mutating func readInt64() throws -> Int64 {
        guard position < bytes.count else { throw DagCBORError.unexpectedEnd }
        if bytes[position] >> 5 == 1 {
            let argument = try readHead(major: 1)
            guard argument <= UInt64(Int64.max) else { throw DagCBORError.integerOverflow }
            return Int64(bitPattern: ~argument)
        }
        let value = try readHead(major: 0)
        guard value <= UInt64(Int64.max) else { throw DagCBORError.integerOverflow }
        return Int64(value)
    }
}

/// Writes DAG-CBOR items in their canonical form: every head in its shortest
/// form. A map's entries are written in the order the caller writes them,
/// which must be ``DagCBOR/keyPrecedes(_:_:)``.
public struct DagCBORWriter {
    @usableFromInline var storage: [UInt8] = []

    /// The bytes written so far.
    @inlinable public var bytes: [UInt8] { storage }

    @inlinable public init() {
        storage.reserveCapacity(256)
    }

    @inlinable public mutating func writeHead(major: UInt8, _ value: UInt64) {
        let m = major << 5
        switch value {
        case ..<24:
            storage.append(m | UInt8(value))
        case ...0xff:
            storage.append(m | 24)
            storage.append(UInt8(value))
        case ...0xffff:
            storage.append(m | 25)
            appendBigEndian(value, width: 2)
        case ...0xffff_ffff:
            storage.append(m | 26)
            appendBigEndian(value, width: 4)
        default:
            storage.append(m | 27)
            appendBigEndian(value, width: 8)
        }
    }

    @inlinable public mutating func writeMapHeader(count: Int) throws {
        guard UInt64(count) <= DagCBOR.maxCollectionCount else { throw DagCBORError.collectionTooLarge }
        writeHead(major: 5, UInt64(count))
    }

    @inlinable public mutating func writeText(_ text: String) {
        writeHead(major: 3, UInt64(text.utf8.count))
        storage.append(contentsOf: text.utf8)
    }

    @inlinable public mutating func writeUInt64(_ value: UInt64) {
        writeHead(major: 0, value)
    }

    @inlinable public mutating func writeInt64(_ value: Int64) {
        if value >= 0 {
            writeHead(major: 0, UInt64(value))
        } else {
            writeHead(major: 1, ~UInt64(bitPattern: value))
        }
    }

    @inlinable mutating func appendBigEndian(_ value: UInt64, width: Int) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            storage.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

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
