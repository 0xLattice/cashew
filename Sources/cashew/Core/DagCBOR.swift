import Foundation

public enum DagCBORError: Error {
    case unsupportedType
    case integerOverflow
    case unexpectedEnd
    case invalidCBOR
}

public struct DagCBOR {
    fileprivate enum CBORValue {
        case uint(UInt64)
        case nint(UInt64)
        case string(String)
        case bytes(Data)
        case array([CBORValue])
        case map([(String, CBORValue)])
        case bool(Bool)
        case double(Double)
        case null
    }

    // MARK: - Encode

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let root = CBOREncodingStorage()
        try value.encode(to: DagCBOREncoder(storage: root, codingPath: []))
        let cborValue = try root.toCBORValue()
        var output = Data(capacity: 256)
        try serializeValue(cborValue, to: &output)
        return output
    }

    // MARK: - Decode

    /// Decodes exactly one CBOR item. Bytes after that item are rejected.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // The parser indexes from zero; rebase a slice so it cannot trap.
        let data = data.startIndex == 0 ? data : Data(data)
        var offset = 0
        let value = try parseValue(data, offset: &offset)
        guard offset == data.count else { throw DagCBORError.invalidCBOR }
        return try T(from: DagCBORDecoder(value: value, codingPath: []))
    }

    // MARK: - CBOR Parser

    /// Maximum nesting depth for CBOR arrays and maps. Deeper structures are
    /// rejected to prevent stack overflow from recursive parseValue calls.
    private static let maxDepth = 64
    /// Maximum number of elements in a single CBOR array or map. Prevents
    /// Int(UInt64) overflow on reserveCapacity and OOM from huge counts.
    private static let maxCollectionCount: UInt64 = 65_536

    private static func parseValue(_ data: Data, offset: inout Int, depth: Int = 0) throws -> CBORValue {
        guard depth < maxDepth else { throw DagCBORError.invalidCBOR }
        guard offset < data.count else { throw DagCBORError.unexpectedEnd }
        let initial = data[offset]
        let majorType = initial >> 5
        let additional = initial & 0x1f
        offset += 1

        switch majorType {
        case 0:
            return try .uint(readArgument(additional, data: data, offset: &offset))
        case 1:
            return try .nint(readArgument(additional, data: data, offset: &offset))
        case 2:
            let len = try readArgument(additional, data: data, offset: &offset)
            // Guard before Int() cast: UInt64 > Int.max traps; also ensure data exists.
            guard len <= UInt64(data.count - offset) else { throw DagCBORError.unexpectedEnd }
            let safeLen = Int(len)
            let end = offset + safeLen
            let bytes = Data(data[offset..<end])
            offset = end
            return .bytes(bytes)
        case 3:
            let len = try readArgument(additional, data: data, offset: &offset)
            guard len <= UInt64(data.count - offset) else { throw DagCBORError.unexpectedEnd }
            let safeLen = Int(len)
            let end = offset + safeLen
            guard let str = String(data: data[offset..<end], encoding: .utf8) else {
                throw DagCBORError.invalidCBOR
            }
            offset = end
            return .string(str)
        case 4:
            let count = try readArgument(additional, data: data, offset: &offset)
            guard count <= maxCollectionCount else { throw DagCBORError.invalidCBOR }
            var array: [CBORValue] = []
            array.reserveCapacity(Int(count))
            for _ in 0..<count {
                try array.append(parseValue(data, offset: &offset, depth: depth + 1))
            }
            return .array(array)
        case 5:
            let count = try readArgument(additional, data: data, offset: &offset)
            guard count <= maxCollectionCount else { throw DagCBORError.invalidCBOR }
            var entries: [(String, CBORValue)] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                let key = try parseValue(data, offset: &offset, depth: depth + 1)
                guard case .string(let keyStr) = key else { throw DagCBORError.invalidCBOR }
                let value = try parseValue(data, offset: &offset, depth: depth + 1)
                entries.append((keyStr, value))
            }
            return .map(entries)
        case 7:
            switch additional {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .null
            case 25:
                guard offset + 2 <= data.count else { throw DagCBORError.unexpectedEnd }
                let bits = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
                offset += 2
                return .double(float16ToDouble(bits))
            case 26:
                guard offset + 4 <= data.count else { throw DagCBORError.unexpectedEnd }
                var bits: UInt32 = 0
                bits |= UInt32(data[offset]) << 24
                bits |= UInt32(data[offset + 1]) << 16
                bits |= UInt32(data[offset + 2]) << 8
                bits |= UInt32(data[offset + 3])
                offset += 4
                return .double(Double(Float(bitPattern: bits)))
            case 27:
                guard offset + 8 <= data.count else { throw DagCBORError.unexpectedEnd }
                var bits: UInt64 = 0
                for i in 0..<8 {
                    bits |= UInt64(data[offset + i]) << (56 - i * 8)
                }
                offset += 8
                return .double(Double(bitPattern: bits))
            default:
                throw DagCBORError.invalidCBOR
            }
        default:
            throw DagCBORError.invalidCBOR
        }
    }

    private static func readArgument(_ additional: UInt8, data: Data, offset: inout Int) throws -> UInt64 {
        if additional < 24 {
            return UInt64(additional)
        }
        switch additional {
        case 24:
            guard offset < data.count else { throw DagCBORError.unexpectedEnd }
            let val = data[offset]
            offset += 1
            return UInt64(val)
        case 25:
            guard offset + 2 <= data.count else { throw DagCBORError.unexpectedEnd }
            let val = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
            offset += 2
            return UInt64(val)
        case 26:
            guard offset + 4 <= data.count else { throw DagCBORError.unexpectedEnd }
            var val: UInt32 = 0
            for i in 0..<4 {
                val |= UInt32(data[offset + i]) << (24 - i * 8)
            }
            offset += 4
            return UInt64(val)
        case 27:
            guard offset + 8 <= data.count else { throw DagCBORError.unexpectedEnd }
            var val: UInt64 = 0
            for i in 0..<8 {
                val |= UInt64(data[offset + i]) << (56 - i * 8)
            }
            offset += 8
            return val
        default:
            throw DagCBORError.invalidCBOR
        }
    }

    private static func float16ToDouble(_ bits: UInt16) -> Double {
        let sign = (bits >> 15) & 1
        let exp = (bits >> 10) & 0x1f
        let frac = bits & 0x3ff
        let signMultiplier: Double = sign == 0 ? 1.0 : -1.0
        if exp == 0 {
            return signMultiplier * Double(frac) * pow(2.0, -24.0)
        } else if exp == 31 {
            return frac == 0 ? signMultiplier * .infinity : .nan
        }
        return signMultiplier * pow(2.0, Double(Int(exp) - 15)) * (1.0 + Double(frac) / 1024.0)
    }

    // MARK: - CBOR Serializer

    private static func serializeValue(_ value: CBORValue, to output: inout Data) throws {
        switch value {
        case .null:
            output.append(0xf6)
        case .bool(let bool):
            output.append(bool ? 0xf5 : 0xf4)
        case .uint(let value):
            writeUnsigned(value, majorType: 0, to: &output)
        case .nint(let argument):
            writeUnsigned(argument, majorType: 1, to: &output)
        case .double(let value):
            writeFloat64(value, to: &output)
        case .bytes(let data):
            writeUnsigned(UInt64(data.count), majorType: 2, to: &output)
            output.append(data)
        case .string(let string):
            let utf8 = Data(string.utf8)
            writeUnsigned(UInt64(utf8.count), majorType: 3, to: &output)
            output.append(utf8)
        case .array(let array):
            writeUnsigned(UInt64(array.count), majorType: 4, to: &output)
            for element in array {
                try serializeValue(element, to: &output)
            }
        case .map(let entries):
            let sortedEntries = entries.sorted { a, b in
                let aLen = a.0.utf8.count
                let bLen = b.0.utf8.count
                if aLen != bLen { return aLen < bLen }
                return a.0 < b.0
            }
            writeUnsigned(UInt64(sortedEntries.count), majorType: 5, to: &output)
            for (key, value) in sortedEntries {
                let keyBytes = Data(key.utf8)
                writeUnsigned(UInt64(keyBytes.count), majorType: 3, to: &output)
                output.append(keyBytes)
                try serializeValue(value, to: &output)
            }
        }
    }

    private static func writeUnsigned(_ value: UInt64, majorType: UInt8, to output: inout Data) {
        let major = majorType << 5
        if value < 24 {
            output.append(major | UInt8(value))
        } else if value <= UInt8.max {
            output.append(major | 24)
            output.append(UInt8(value))
        } else if value <= UInt16.max {
            output.append(major | 25)
            var be = UInt16(value).bigEndian
            output.append(Data(bytes: &be, count: 2))
        } else if value <= UInt32.max {
            output.append(major | 26)
            var be = UInt32(value).bigEndian
            output.append(Data(bytes: &be, count: 4))
        } else {
            output.append(major | 27)
            var be = value.bigEndian
            output.append(Data(bytes: &be, count: 8))
        }
    }

    private static func writeFloat64(_ value: Double, to output: inout Data) {
        output.append(0xfb)
        var be = value.bitPattern.bigEndian
        output.append(Data(bytes: &be, count: 8))
    }
}

// MARK: - Encoder

private final class CBOREncodingStorage {
    private enum Kind {
        case empty
        case value(DagCBOR.CBORValue)
        case array([CBOREncodingStorage])
        case map([String: CBOREncodingStorage])
    }

    private var kind: Kind = .empty
    private var error: Error?

    func setValue(_ value: DagCBOR.CBORValue, codingPath: [CodingKey]) throws {
        guard error == nil else { throw error! }
        switch kind {
        case .empty:
            kind = .value(value)
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "Attempted to encode multiple CBOR values into a single container"
            ))
        }
    }

    func beginArray(codingPath: [CodingKey]) {
        switch kind {
        case .empty:
            kind = .array([])
        case .array:
            break
        default:
            recordContainerError("Attempted to create an unkeyed CBOR container after another container was already created", codingPath: codingPath)
        }
    }

    func appendChild(codingPath: [CodingKey]) -> CBOREncodingStorage {
        beginArray(codingPath: codingPath)
        let child = CBOREncodingStorage()
        switch kind {
        case .array(var children):
            children.append(child)
            kind = .array(children)
        default:
            child.error = error
        }
        return child
    }

    func arrayCount() -> Int {
        guard case .array(let children) = kind else { return 0 }
        return children.count
    }

    func beginMap(codingPath: [CodingKey]) {
        switch kind {
        case .empty:
            kind = .map([:])
        case .map:
            break
        default:
            recordContainerError("Attempted to create a keyed CBOR container after another container was already created", codingPath: codingPath)
        }
    }

    func setMapChild(_ key: String, child: CBOREncodingStorage, codingPath: [CodingKey]) {
        beginMap(codingPath: codingPath)
        switch kind {
        case .map(var children):
            children[key] = child
            kind = .map(children)
        default:
            child.error = error
        }
    }

    func toCBORValue() throws -> DagCBOR.CBORValue {
        if let error { throw error }
        switch kind {
        case .empty:
            return .null
        case .value(let value):
            return value
        case .array(let children):
            return try .array(children.map { try $0.toCBORValue() })
        case .map(let children):
            return try .map(children.map { key, value in (key, try value.toCBORValue()) })
        }
    }

    private func recordContainerError(_ description: String, codingPath: [CodingKey]) {
        if error == nil {
            error = EncodingError.invalidValue(description, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: description
            ))
        }
    }
}

private struct DagCBOREncoder: Encoder {
    let storage: CBOREncodingStorage
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        storage.beginMap(codingPath: codingPath)
        return KeyedEncodingContainer(CBORKeyedEncodingContainer<Key>(storage: storage, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        storage.beginArray(codingPath: codingPath)
        return CBORUnkeyedEncodingContainer(storage: storage, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        CBORSingleValueEncodingContainer(storage: storage, codingPath: codingPath)
    }
}

private struct CBORKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let storage: CBOREncodingStorage
    let codingPath: [CodingKey]

    mutating func encodeNil(forKey key: Key) throws {
        try encodeCBORValue(.null, forKey: key)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try encodeCBORValue(.bool(value), forKey: key)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try encodeCBORValue(.string(value), forKey: key)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try encodeCBORValue(.double(value), forKey: key)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try encodeCBORValue(.double(Double(value)), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try encodeCBORValue(Self.intValue(Int64(value)), forKey: key)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try encodeCBORValue(Self.intValue(Int64(value)), forKey: key)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try encodeCBORValue(Self.intValue(Int64(value)), forKey: key)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try encodeCBORValue(Self.intValue(Int64(value)), forKey: key)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try encodeCBORValue(Self.intValue(value), forKey: key)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try encodeCBORValue(.uint(UInt64(value)), forKey: key)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try encodeCBORValue(.uint(UInt64(value)), forKey: key)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try encodeCBORValue(.uint(UInt64(value)), forKey: key)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try encodeCBORValue(.uint(UInt64(value)), forKey: key)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try encodeCBORValue(.uint(value), forKey: key)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func encode(_ value: UInt128, forKey key: Key) throws {
        try encodeCBORValue(cborValue(uint128: value), forKey: key)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func encode(_ value: Int128, forKey key: Key) throws {
        try encodeCBORValue(cborValue(int128: value), forKey: key)
    }

    mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
        if let data = value as? Data {
            // Compatibility: JSONEncoder encoded Data as a base64 text string,
            // and existing CIDs depend on that layout. Do not encode major-2 bytes here.
            try encodeCBORValue(.string(data.base64EncodedString()), forKey: key)
            return
        }
        let child = CBOREncodingStorage()
        storage.setMapChild(key.stringValue, child: child, codingPath: codingPath)
        try value.encode(to: DagCBOREncoder(storage: child, codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let child = CBOREncodingStorage()
        storage.setMapChild(key.stringValue, child: child, codingPath: codingPath)
        return DagCBOREncoder(storage: child, codingPath: codingPath + [key]).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = CBOREncodingStorage()
        storage.setMapChild(key.stringValue, child: child, codingPath: codingPath)
        return DagCBOREncoder(storage: child, codingPath: codingPath + [key]).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let key = DagCBORCodingKey(stringValue: "super")!
        return superEncoder(forKey: key as! Key)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let child = CBOREncodingStorage()
        storage.setMapChild(key.stringValue, child: child, codingPath: codingPath)
        return DagCBOREncoder(storage: child, codingPath: codingPath + [key])
    }

    private func encodeCBORValue(_ value: DagCBOR.CBORValue, forKey key: Key) throws {
        let child = CBOREncodingStorage()
        try child.setValue(value, codingPath: codingPath + [key])
        storage.setMapChild(key.stringValue, child: child, codingPath: codingPath)
    }

    private static func intValue(_ value: Int64) -> DagCBOR.CBORValue {
        value >= 0 ? .uint(UInt64(value)) : .nint(UInt64(~value))
    }
}

private struct CBORUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let storage: CBOREncodingStorage
    let codingPath: [CodingKey]

    var count: Int { storage.arrayCount() }

    mutating func encodeNil() throws {
        try encodeCBORValue(.null)
    }

    mutating func encode(_ value: Bool) throws {
        try encodeCBORValue(.bool(value))
    }

    mutating func encode(_ value: String) throws {
        try encodeCBORValue(.string(value))
    }

    mutating func encode(_ value: Double) throws {
        try encodeCBORValue(.double(value))
    }

    mutating func encode(_ value: Float) throws {
        try encodeCBORValue(.double(Double(value)))
    }

    mutating func encode(_ value: Int) throws {
        try encodeCBORValue(Self.intValue(Int64(value)))
    }

    mutating func encode(_ value: Int8) throws {
        try encodeCBORValue(Self.intValue(Int64(value)))
    }

    mutating func encode(_ value: Int16) throws {
        try encodeCBORValue(Self.intValue(Int64(value)))
    }

    mutating func encode(_ value: Int32) throws {
        try encodeCBORValue(Self.intValue(Int64(value)))
    }

    mutating func encode(_ value: Int64) throws {
        try encodeCBORValue(Self.intValue(value))
    }

    mutating func encode(_ value: UInt) throws {
        try encodeCBORValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt8) throws {
        try encodeCBORValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt16) throws {
        try encodeCBORValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt32) throws {
        try encodeCBORValue(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt64) throws {
        try encodeCBORValue(.uint(value))
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func encode(_ value: UInt128) throws {
        try encodeCBORValue(cborValue(uint128: value))
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func encode(_ value: Int128) throws {
        try encodeCBORValue(cborValue(int128: value))
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        if let data = value as? Data {
            // Compatibility: JSONEncoder encoded Data as a base64 text string,
            // and existing CIDs depend on that layout. Do not encode major-2 bytes here.
            try encodeCBORValue(.string(data.base64EncodedString()))
            return
        }
        let index = count
        let child = storage.appendChild(codingPath: codingPath)
        try value.encode(to: DagCBOREncoder(storage: child, codingPath: codingPath + [DagCBORCodingKey(intValue: index)!]))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        let index = count
        let child = storage.appendChild(codingPath: codingPath)
        return DagCBOREncoder(storage: child, codingPath: codingPath + [DagCBORCodingKey(intValue: index)!]).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let index = count
        let child = storage.appendChild(codingPath: codingPath)
        return DagCBOREncoder(storage: child, codingPath: codingPath + [DagCBORCodingKey(intValue: index)!]).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        let index = count
        let child = storage.appendChild(codingPath: codingPath)
        return DagCBOREncoder(storage: child, codingPath: codingPath + [DagCBORCodingKey(intValue: index)!])
    }

    private func encodeCBORValue(_ value: DagCBOR.CBORValue) throws {
        let index = count
        let child = storage.appendChild(codingPath: codingPath)
        try child.setValue(value, codingPath: codingPath + [DagCBORCodingKey(intValue: index)!])
    }

    private static func intValue(_ value: Int64) -> DagCBOR.CBORValue {
        value >= 0 ? .uint(UInt64(value)) : .nint(UInt64(~value))
    }
}

private struct CBORSingleValueEncodingContainer: SingleValueEncodingContainer {
    let storage: CBOREncodingStorage
    let codingPath: [CodingKey]

    mutating func encodeNil() throws {
        try storage.setValue(.null, codingPath: codingPath)
    }

    mutating func encode(_ value: Bool) throws {
        try storage.setValue(.bool(value), codingPath: codingPath)
    }

    mutating func encode(_ value: String) throws {
        try storage.setValue(.string(value), codingPath: codingPath)
    }

    mutating func encode(_ value: Double) throws {
        try storage.setValue(.double(value), codingPath: codingPath)
    }

    mutating func encode(_ value: Float) throws {
        try storage.setValue(.double(Double(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: Int) throws {
        try storage.setValue(Self.intValue(Int64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: Int8) throws {
        try storage.setValue(Self.intValue(Int64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: Int16) throws {
        try storage.setValue(Self.intValue(Int64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: Int32) throws {
        try storage.setValue(Self.intValue(Int64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: Int64) throws {
        try storage.setValue(Self.intValue(value), codingPath: codingPath)
    }

    mutating func encode(_ value: UInt) throws {
        try storage.setValue(.uint(UInt64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: UInt8) throws {
        try storage.setValue(.uint(UInt64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: UInt16) throws {
        try storage.setValue(.uint(UInt64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: UInt32) throws {
        try storage.setValue(.uint(UInt64(value)), codingPath: codingPath)
    }

    mutating func encode(_ value: UInt64) throws {
        try storage.setValue(.uint(value), codingPath: codingPath)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func encode(_ value: UInt128) throws {
        try storage.setValue(cborValue(uint128: value), codingPath: codingPath)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func encode(_ value: Int128) throws {
        try storage.setValue(cborValue(int128: value), codingPath: codingPath)
    }

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        if let data = value as? Data {
            // Compatibility: JSONEncoder encoded Data as a base64 text string,
            // and existing CIDs depend on that layout. Do not encode major-2 bytes here.
            try storage.setValue(.string(data.base64EncodedString()), codingPath: codingPath)
            return
        }
        try value.encode(to: DagCBOREncoder(storage: storage, codingPath: codingPath))
    }

    private static func intValue(_ value: Int64) -> DagCBOR.CBORValue {
        value >= 0 ? .uint(UInt64(value)) : .nint(UInt64(~value))
    }
}

// MARK: - Decoder

private struct DagCBORDecoder: Decoder {
    let value: DagCBOR.CBORValue
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        guard case .map(let entries) = value else {
            throw typeMismatch([String: Any].self, value: value, codingPath: codingPath)
        }
        var values: [String: DagCBOR.CBORValue] = [:]
        for (key, value) in entries {
            values[key] = value
        }
        return KeyedDecodingContainer(CBORKeyedDecodingContainer<Key>(
            values: values,
            codingPath: codingPath
        ))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let values) = value else {
            throw typeMismatch([Any].self, value: value, codingPath: codingPath)
        }
        return CBORUnkeyedDecodingContainer(values: values, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        CBORSingleValueDecodingContainer(value: value, codingPath: codingPath)
    }
}

private struct CBORKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let values: [String: DagCBOR.CBORValue]
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        values.keys.compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        values[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = values[key.stringValue] else { throw keyNotFound(key) }
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        guard case .bool(let value) = try value(forKey: key) else {
            throw typeMismatch(type, value: try value(forKey: key), codingPath: codingPath + [key])
        }
        return value
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        guard case .string(let value) = try value(forKey: key) else {
            throw typeMismatch(type, value: try value(forKey: key), codingPath: codingPath + [key])
        }
        return value
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeDouble(try value(forKey: key), type: type, codingPath: codingPath + [key])
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        Float(try decodeDouble(try value(forKey: key), type: type, codingPath: codingPath + [key]))
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        let value = try decodeInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value >= Int64(Int.min), value <= Int64(Int.max) else { throw DagCBORError.integerOverflow }
        return Int(value)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        let value = try decodeInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value >= Int64(Int8.min), value <= Int64(Int8.max) else { throw DagCBORError.integerOverflow }
        return Int8(value)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        let value = try decodeInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value >= Int64(Int16.min), value <= Int64(Int16.max) else { throw DagCBORError.integerOverflow }
        return Int16(value)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        let value = try decodeInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { throw DagCBORError.integerOverflow }
        return Int32(value)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeInt64(try value(forKey: key), codingPath: codingPath + [key])
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        let value = try decodeUInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value <= UInt64(UInt.max) else { throw DagCBORError.integerOverflow }
        return UInt(value)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        let value = try decodeUInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value <= UInt64(UInt8.max) else { throw DagCBORError.integerOverflow }
        return UInt8(value)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        let value = try decodeUInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value <= UInt64(UInt16.max) else { throw DagCBORError.integerOverflow }
        return UInt16(value)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        let value = try decodeUInt64(try value(forKey: key), codingPath: codingPath + [key])
        guard value <= UInt64(UInt32.max) else { throw DagCBORError.integerOverflow }
        return UInt32(value)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        try decodeUInt64(try value(forKey: key), codingPath: codingPath + [key])
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    func decode(_ type: UInt128.Type, forKey key: Key) throws -> UInt128 {
        try decodeUInt128(try value(forKey: key), codingPath: codingPath + [key])
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    func decode(_ type: Int128.Type, forKey key: Key) throws -> Int128 {
        try decodeInt128(try value(forKey: key), codingPath: codingPath + [key])
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
        let value = try value(forKey: key)
        if type == Data.self {
            return try decodeData(value, codingPath: codingPath + [key]) as! T
        }
        return try T(from: DagCBORDecoder(value: value, codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try DagCBORDecoder(value: value(forKey: key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try DagCBORDecoder(value: value(forKey: key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        let key = DagCBORCodingKey(stringValue: "super")!
        return try superDecoder(forKey: key as! Key)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        try DagCBORDecoder(value: value(forKey: key), codingPath: codingPath + [key])
    }

    private func value(forKey key: Key) throws -> DagCBOR.CBORValue {
        guard let value = values[key.stringValue] else { throw keyNotFound(key) }
        return value
    }

    private func keyNotFound(_ key: Key) -> DecodingError {
        DecodingError.keyNotFound(key, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "No value associated with key \(key.stringValue)"
        ))
    }
}

private struct CBORUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let values: [DagCBOR.CBORValue]
    let codingPath: [CodingKey]
    var currentIndex: Int = 0
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw valueNotFound(Any.self) }
        if case .null = values[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let (value, path) = try nextValue(type)
        guard case .bool(let decoded) = value else { throw typeMismatch(type, value: value, codingPath: path) }
        return decoded
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let (value, path) = try nextValue(type)
        guard case .string(let decoded) = value else { throw typeMismatch(type, value: value, codingPath: path) }
        return decoded
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let (value, path) = try nextValue(type)
        return try decodeDouble(value, type: type, codingPath: path)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let (value, path) = try nextValue(type)
        return Float(try decodeDouble(value, type: type, codingPath: path))
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let (value, path) = try nextValue(type)
        let decoded = try decodeInt64(value, codingPath: path)
        guard decoded >= Int64(Int.min), decoded <= Int64(Int.max) else { throw DagCBORError.integerOverflow }
        return Int(decoded)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let (value, path) = try nextValue(type)
        let decoded = try decodeInt64(value, codingPath: path)
        guard decoded >= Int64(Int8.min), decoded <= Int64(Int8.max) else { throw DagCBORError.integerOverflow }
        return Int8(decoded)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let (value, path) = try nextValue(type)
        let decoded = try decodeInt64(value, codingPath: path)
        guard decoded >= Int64(Int16.min), decoded <= Int64(Int16.max) else { throw DagCBORError.integerOverflow }
        return Int16(decoded)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let (value, path) = try nextValue(type)
        let decoded = try decodeInt64(value, codingPath: path)
        guard decoded >= Int64(Int32.min), decoded <= Int64(Int32.max) else { throw DagCBORError.integerOverflow }
        return Int32(decoded)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let (value, path) = try nextValue(type)
        return try decodeInt64(value, codingPath: path)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let (value, path) = try nextValue(type)
        let decoded = try decodeUInt64(value, codingPath: path)
        guard decoded <= UInt64(UInt.max) else { throw DagCBORError.integerOverflow }
        return UInt(decoded)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let (value, path) = try nextValue(type)
        let decoded = try decodeUInt64(value, codingPath: path)
        guard decoded <= UInt64(UInt8.max) else { throw DagCBORError.integerOverflow }
        return UInt8(decoded)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let (value, path) = try nextValue(type)
        let decoded = try decodeUInt64(value, codingPath: path)
        guard decoded <= UInt64(UInt16.max) else { throw DagCBORError.integerOverflow }
        return UInt16(decoded)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let (value, path) = try nextValue(type)
        let decoded = try decodeUInt64(value, codingPath: path)
        guard decoded <= UInt64(UInt32.max) else { throw DagCBORError.integerOverflow }
        return UInt32(decoded)
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let (value, path) = try nextValue(type)
        return try decodeUInt64(value, codingPath: path)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func decode(_ type: UInt128.Type) throws -> UInt128 {
        let (value, path) = try nextValue(type)
        return try decodeUInt128(value, codingPath: path)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    mutating func decode(_ type: Int128.Type) throws -> Int128 {
        let (value, path) = try nextValue(type)
        return try decodeInt128(value, codingPath: path)
    }

    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        let (value, path) = try nextValue(type)
        if type == Data.self {
            return try decodeData(value, codingPath: path) as! T
        }
        return try T(from: DagCBORDecoder(value: value, codingPath: path))
    }

    mutating func nestedContainer<NestedKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        let (value, path) = try nextValue(type)
        return try DagCBORDecoder(value: value, codingPath: path).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let (value, path) = try nextValue([Any].self)
        return try DagCBORDecoder(value: value, codingPath: path).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        let (value, path) = try nextValue(Any.self)
        return DagCBORDecoder(value: value, codingPath: path)
    }

    private mutating func nextValue<T>(_ type: T.Type) throws -> (DagCBOR.CBORValue, [CodingKey]) {
        guard !isAtEnd else { throw valueNotFound(type) }
        let index = currentIndex
        currentIndex += 1
        return (values[index], codingPath + [DagCBORCodingKey(intValue: index)!])
    }

    private func valueNotFound<T>(_ type: T.Type) -> DecodingError {
        DecodingError.valueNotFound(type, DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Unkeyed CBOR container is at end"
        ))
    }
}

private struct CBORSingleValueDecodingContainer: SingleValueDecodingContainer {
    let value: DagCBOR.CBORValue
    let codingPath: [CodingKey]

    func decodeNil() -> Bool {
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let decoded) = value else { throw typeMismatch(type, value: value, codingPath: codingPath) }
        return decoded
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let decoded) = value else { throw typeMismatch(type, value: value, codingPath: codingPath) }
        return decoded
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decodeDouble(value, type: type, codingPath: codingPath)
    }

    func decode(_ type: Float.Type) throws -> Float {
        Float(try decodeDouble(value, type: type, codingPath: codingPath))
    }

    func decode(_ type: Int.Type) throws -> Int {
        let decoded = try decodeInt64(value, codingPath: codingPath)
        guard decoded >= Int64(Int.min), decoded <= Int64(Int.max) else { throw DagCBORError.integerOverflow }
        return Int(decoded)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        let decoded = try decodeInt64(value, codingPath: codingPath)
        guard decoded >= Int64(Int8.min), decoded <= Int64(Int8.max) else { throw DagCBORError.integerOverflow }
        return Int8(decoded)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        let decoded = try decodeInt64(value, codingPath: codingPath)
        guard decoded >= Int64(Int16.min), decoded <= Int64(Int16.max) else { throw DagCBORError.integerOverflow }
        return Int16(decoded)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        let decoded = try decodeInt64(value, codingPath: codingPath)
        guard decoded >= Int64(Int32.min), decoded <= Int64(Int32.max) else { throw DagCBORError.integerOverflow }
        return Int32(decoded)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeInt64(value, codingPath: codingPath)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        let decoded = try decodeUInt64(value, codingPath: codingPath)
        guard decoded <= UInt64(UInt.max) else { throw DagCBORError.integerOverflow }
        return UInt(decoded)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        let decoded = try decodeUInt64(value, codingPath: codingPath)
        guard decoded <= UInt64(UInt8.max) else { throw DagCBORError.integerOverflow }
        return UInt8(decoded)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        let decoded = try decodeUInt64(value, codingPath: codingPath)
        guard decoded <= UInt64(UInt16.max) else { throw DagCBORError.integerOverflow }
        return UInt16(decoded)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        let decoded = try decodeUInt64(value, codingPath: codingPath)
        guard decoded <= UInt64(UInt32.max) else { throw DagCBORError.integerOverflow }
        return UInt32(decoded)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        try decodeUInt64(value, codingPath: codingPath)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    func decode(_ type: UInt128.Type) throws -> UInt128 {
        try decodeUInt128(value, codingPath: codingPath)
    }

    @available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
    func decode(_ type: Int128.Type) throws -> Int128 {
        try decodeInt128(value, codingPath: codingPath)
    }

    func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
        if type == Data.self {
            return try decodeData(value, codingPath: codingPath) as! T
        }
        return try T(from: DagCBORDecoder(value: value, codingPath: codingPath))
    }
}

private struct DagCBORCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "Index \(intValue)"
        self.intValue = intValue
    }
}

private func decodeUInt64(_ value: DagCBOR.CBORValue, codingPath: [CodingKey]) throws -> UInt64 {
    guard case .uint(let decoded) = value else {
        throw typeMismatch(UInt64.self, value: value, codingPath: codingPath)
    }
    return decoded
}

// MARK: - 128-bit integer support
//
// UInt128/Int128 are used by downstream consensus types (e.g. nonce counters).
// CBOR's plain integer encoding (major 0/1) only spans the 64-bit argument, so
// values are encoded with a fits-in-64-bit fast path that is byte-identical to
// the 64-bit encoders (small nonces -> major-0, matching the prior JSON-laundered
// encoder for all values <= Int64.max, so existing CIDs are unchanged). Values
// beyond the 64-bit range are physically unreachable for the counters in use and
// are rejected fail-closed (throw) rather than trapped or silently truncated.

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
private func cborValue(uint128 value: UInt128) throws -> DagCBOR.CBORValue {
    guard value <= UInt128(UInt64.max) else { throw DagCBORError.integerOverflow }
    return .uint(UInt64(value))
}

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
private func cborValue(int128 value: Int128) throws -> DagCBOR.CBORValue {
    if value >= 0 {
        guard value <= Int128(UInt64.max) else { throw DagCBORError.integerOverflow }
        return .uint(UInt64(value))
    }
    // CBOR negative integer argument = -1 - value (== ~value at fixed width).
    let argument = -1 - value
    guard argument <= Int128(UInt64.max) else { throw DagCBORError.integerOverflow }
    return .nint(UInt64(argument))
}

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
private func decodeUInt128(_ value: DagCBOR.CBORValue, codingPath: [CodingKey]) throws -> UInt128 {
    guard case .uint(let decoded) = value else {
        throw typeMismatch(UInt128.self, value: value, codingPath: codingPath)
    }
    return UInt128(decoded)
}

@available(macOS 15, iOS 18, watchOS 11, tvOS 18, *)
private func decodeInt128(_ value: DagCBOR.CBORValue, codingPath: [CodingKey]) throws -> Int128 {
    switch value {
    case .uint(let decoded):
        return Int128(decoded)
    case .nint(let argument):
        return -1 - Int128(argument)
    default:
        throw typeMismatch(Int128.self, value: value, codingPath: codingPath)
    }
}

private func decodeInt64(_ value: DagCBOR.CBORValue, codingPath: [CodingKey]) throws -> Int64 {
    switch value {
    case .uint(let decoded):
        guard decoded <= UInt64(Int64.max) else { throw DagCBORError.integerOverflow }
        return Int64(decoded)
    case .nint(let argument):
        guard argument <= UInt64(Int64.max) else { throw DagCBORError.integerOverflow }
        return Int64(bitPattern: ~argument)
    default:
        throw typeMismatch(Int64.self, value: value, codingPath: codingPath)
    }
}

private func decodeDouble<T>(_ value: DagCBOR.CBORValue, type: T.Type, codingPath: [CodingKey]) throws -> Double {
    guard case .double(let decoded) = value else {
        throw typeMismatch(type, value: value, codingPath: codingPath)
    }
    return decoded
}

private func decodeData(_ value: DagCBOR.CBORValue, codingPath: [CodingKey]) throws -> Data {
    switch value {
    case .string(let string):
        guard let data = Data(base64Encoded: string) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Invalid base64 Data string"
            ))
        }
        return data
    case .bytes(let data):
        return data
    default:
        throw typeMismatch(Data.self, value: value, codingPath: codingPath)
    }
}

private func typeMismatch<T>(_ type: T.Type, value: DagCBOR.CBORValue, codingPath: [CodingKey]) -> DecodingError {
    DecodingError.typeMismatch(type, DecodingError.Context(
        codingPath: codingPath,
        debugDescription: "Expected \(type), found \(value)"
    ))
}
