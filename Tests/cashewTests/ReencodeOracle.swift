import Foundation
@testable import cashew

/// The canonical check as cashew 5.0.6 shipped it, kept only to test the
/// one-pass check against: parse leniently, decode, re-encode, compare bytes.
/// The parser below is that release's, verbatim.
enum ReencodeOracle {
    typealias CBORValue = DagCBOR.CBORValue
    private static let maxDepth = 64
    private static let maxCollectionCount = DagCBOR.maxCollectionCount

    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        var offset = 0
        let value = try parseValue(data, offset: &offset)
        let decoded = try DagCBOR.decode(type, fromParsed: value)
        guard try DagCBOR.encode(decoded) == data else { throw DagCBORError.nonCanonical }
        return decoded
    }

    /// The tree `data` parses to, ignoring anything after it.
    static func parse(_ data: Data) throws -> CBORValue {
        var offset = 0
        return try parseValue(data, offset: &offset)
    }

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
            guard let str = String(exactUTF8: data[offset..<end]) else {
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
}
