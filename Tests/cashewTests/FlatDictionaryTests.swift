import Testing
import Foundation
import CID
import Multibase
@testable import cashew

@Suite("FlatDictionary and strict DAG-CBOR maps")
struct FlatDictionaryTests {
    @Test("A flat map round-trips with the same bytes in any insertion order")
    func testFlatMapRoundTripIsCanonical() throws {
        let one = try ScalarHeader(node: TestScalar(val: 1))
        let two = try ScalarHeader(node: TestScalar(val: 2))
        let three = try ScalarHeader(node: TestScalar(val: 3))

        var forward = FlatDictionary<ScalarHeader>()
        forward.entries["Payments"] = one
        forward.entries["Games"] = two
        forward.entries["a"] = three
        var reversed = FlatDictionary<ScalarHeader>()
        reversed.entries["a"] = three
        reversed.entries["Games"] = two
        reversed.entries["Payments"] = one

        let bytes = try #require(forward.toData())
        #expect(reversed.toData() == bytes)
        #expect(try HeaderImpl(node: forward).rawCID == HeaderImpl(node: reversed).rawCID)

        // A plain DAG-CBOR map: the same bytes as the bare dictionary.
        #expect(try DagCBOR.encode(forward.entries) == bytes)
        let decoded = try #require(FlatDictionary<ScalarHeader>(data: bytes))
        #expect(decoded.entries.mapValues(\.rawCID) == forward.entries.mapValues(\.rawCID))
        #expect(decoded.toData() == bytes)

        #expect(decoded.properties() == ["Payments", "Games", "a"])
        #expect(decoded.get(property: "Games")?.rawCID == two.rawCID)
        #expect(decoded.get(property: "missing") == nil)
        let updated = decoded.set(properties: ["Games": one])
        #expect(updated["Games"]?.rawCID == one.rawCID)
    }

    @Test("A map with a repeated key is not DAG-CBOR")
    func testDuplicateKeysRejected() {
        // {"a": 1, "a": 2}
        let bytes = Data([0xa2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02])
        #expect(throws: DagCBORError.self) { try DagCBOR.decode([String: Int].self, from: bytes) }
    }

    @Test("A map whose keys are out of canonical order is not DAG-CBOR")
    func testOutOfOrderKeysRejected() throws {
        // {"a": 1, "b": 2} decodes; the same entries reversed do not.
        let canonical = Data([0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02])
        #expect(try DagCBOR.decode([String: Int].self, from: canonical) == ["a": 1, "b": 2])
        let bytewise = Data([0xa2, 0x61, 0x62, 0x01, 0x61, 0x61, 0x02])
        #expect(throws: DagCBORError.self) { try DagCBOR.decode([String: Int].self, from: bytewise) }
        // Shorter keys come first: {"bb": 1, "a": 2} is out of order.
        let lengthFirst = Data([0xa2, 0x62, 0x62, 0x62, 0x01, 0x61, 0x61, 0x02])
        #expect(throws: DagCBORError.self) { try DagCBOR.decode([String: Int].self, from: lengthFirst) }
    }

    @Test("A collection longer than the decoder's limit is rejected")
    func testCollectionOverLimitRejected() throws {
        func array(count: UInt64) -> Data {
            var bytes = Data([0x9a])
            withUnsafeBytes(of: UInt32(count).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(Data(repeating: 0x00, count: Int(count)))
            return bytes
        }
        let limit = DagCBOR.maxCollectionCount
        #expect(try DagCBOR.decode([Int].self, from: array(count: limit)).count == Int(limit))
        #expect(throws: DagCBORError.self) { try DagCBOR.decode([Int].self, from: array(count: limit + 1)) }
        #expect(throws: DagCBORError.collectionTooLarge) {
            try DagCBOR.encode([Int](repeating: 0, count: Int(limit) + 1))
        }
    }
}

/// Two children under one key are corrupt data: decoding throws, never traps.
@Suite("Trie nodes refuse duplicate child keys")
struct DuplicateChildKeyTests {
    struct Ref: Codable { let rawCID: String }
    struct Entry: Codable { let key: String; let value: Ref }
    struct CountedWire: Codable { let count: Int; let children: [Entry] }
    struct RadixWire: Codable { let prefix: String; let children: [Entry] }

    func entries(_ keys: [String]) throws -> [Entry] {
        let cid = try HeaderImpl(node: TestScalar(val: 1)).rawCID
        return keys.map { Entry(key: $0, value: Ref(rawCID: cid)) }
    }

    /// The single-entry wire decodes, so only the duplicate is refused.
    func check<T: Codable>(_ type: T.Type, _ wire: ([Entry]) throws -> some Encodable) throws {
        #expect(throws: Never.self) { try DagCBOR.decode(type, from: DagCBOR.encode(wire(entries(["a"])))) }
        #expect(throws: DecodingError.self) { try DagCBOR.decode(type, from: DagCBOR.encode(wire(entries(["a", "a"])))) }
    }

    @Test func merkleDictionary() throws {
        try check(MerkleDictionaryImpl<String>.self) { CountedWire(count: 1, children: $0) }
    }
    @Test func merkleArray() throws {
        try check(MerkleArrayImpl<String>.self) { CountedWire(count: 1, children: $0) }
    }
    @Test func merkleSet() throws {
        try check(MerkleSetImpl.self) { CountedWire(count: 1, children: $0) }
    }
    @Test func volumeMerkleDictionary() throws {
        try check(VolumeMerkleDictionaryImpl<String>.self) { CountedWire(count: 1, children: $0) }
    }
    @Test func radixNode() throws {
        try check(RadixNodeImpl<String>.self) { RadixWire(prefix: "", children: $0) }
    }
    @Test func volumeRadixNode() throws {
        try check(VolumeRadixNodeImpl<String>.self) { RadixWire(prefix: "", children: $0) }
    }
}

@Suite("DAG-CBOR encoding is linear in collection size")
struct EncoderScalingTests {
    /// Best of three runs, in seconds.
    func seconds(_ body: () throws -> Void) rethrows -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return best
    }

    @Test("8x the elements costs far less than 64x the time, for arrays and maps")
    func testEncodeScalesLinearly() throws {
        let large = Int(DagCBOR.maxCollectionCount)
        let small = large / 8
        let array = { (n: Int) in [Int](repeating: 0, count: n) }
        let map = { (n: Int) in Dictionary(uniqueKeysWithValues: (0..<n).map { ("k\($0)", 0) }) }

        let smallArray = array(small), largeArray = array(large)
        let arrayRatio = try seconds { _ = try DagCBOR.encode(largeArray) }
            / seconds { _ = try DagCBOR.encode(smallArray) }
        let smallMap = map(small), largeMap = map(large)
        let mapRatio = try seconds { _ = try DagCBOR.encode(largeMap) }
            / seconds { _ = try DagCBOR.encode(smallMap) }

        // Linear is ~8x; the old copy-per-append encoder was ~64x.
        #expect(arrayRatio < 24, "array encode ratio \(arrayRatio)")
        #expect(mapRatio < 24, "map encode ratio \(mapRatio)")
    }
}

/// Every second spelling of a value is refused: the decoder accepts bytes
/// only if they are exactly what the decoded value encodes to.
@Suite("DAG-CBOR decodes only canonical bytes")
struct CanonicalDecodeTests {
    struct IntRecord: Codable { let a: Int }
    struct TextRecord: Codable { let s: String }
    struct OptionalRecord: Codable { let a: Int? }
    struct DoubleRecord: Codable { let d: Double }
    struct DataRecord: Codable { let payload: Data }
    struct RawRef: Codable { let rawCID: String }
    struct RefRecord<H: Codable>: Codable { let h: H }

    func rejects<T: Codable>(_ type: T.Type, _ bytes: Data) {
        #expect(throws: (any Error).self) { try DagCBOR.decode(type, from: bytes) }
    }

    @Test("Trailing bytes after the top-level item")
    func testTrailingBytes() throws {
        let bytes = try DagCBOR.encode(IntRecord(a: 1))
        #expect(try DagCBOR.decode(IntRecord.self, from: bytes).a == 1)
        rejects(IntRecord.self, bytes + Data([0x00]))
    }

    @Test("Non-minimal integers and lengths")
    func testNonMinimalHeads() throws {
        #expect(try DagCBOR.encode(IntRecord(a: 1)) == Data([0xa1, 0x61, 0x61, 0x01]))
        rejects(IntRecord.self, Data([0xa1, 0x61, 0x61, 0x18, 0x01]))       // 1 as uint8
        rejects(IntRecord.self, Data([0xa1, 0x78, 0x01, 0x61, 0x01]))       // key length as uint8
        rejects(IntRecord.self, Data([0xb8, 0x01, 0x61, 0x61, 0x01]))       // map length as uint8
    }

    @Test("A UTF-8 byte-order mark is not stripped into the same text")
    func testByteOrderMark() throws {
        #expect(try DagCBOR.encode(TextRecord(s: "a")) == Data([0xa1, 0x61, 0x73, 0x61, 0x61]))
        rejects(TextRecord.self, Data([0xa1, 0x61, 0x73, 0x64, 0xef, 0xbb, 0xbf, 0x61]))
    }

    @Test("A CID in a non-canonical base")
    func testNonCanonicalCIDBase() throws {
        let canonical = try HeaderImpl(node: TestScalar(val: 7)).rawCID
        let alternate = BaseEncoding.base16.encode(data: try CID(canonical).rawData)
        typealias Record = RefRecord<HeaderImpl<TestScalar>>
        #expect(try DagCBOR.decode(Record.self, from: DagCBOR.encode(RefRecord(h: RawRef(rawCID: canonical)))).h.rawCID == canonical)
        rejects(Record.self, try DagCBOR.encode(RefRecord(h: RawRef(rawCID: alternate))))
    }

    @Test("Unknown map keys")
    func testUnknownKeys() {
        rejects(IntRecord.self, Data([0xa2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x02]))
    }

    @Test("Explicit null or undefined for an absent field")
    func testNullUndefinedMissing() throws {
        #expect(try DagCBOR.encode(OptionalRecord(a: nil)) == Data([0xa0]))
        #expect(try DagCBOR.decode(OptionalRecord.self, from: Data([0xa0])).a == nil)
        rejects(OptionalRecord.self, Data([0xa1, 0x61, 0x61, 0xf6]))
        rejects(OptionalRecord.self, Data([0xa1, 0x61, 0x61, 0xf7]))
    }

    @Test("Half- and single-precision floats")
    func testShortFloats() throws {
        let canonical = try DagCBOR.encode(DoubleRecord(d: 1.5))
        #expect(try DagCBOR.decode(DoubleRecord.self, from: canonical).d == 1.5)
        rejects(DoubleRecord.self, Data([0xa1, 0x61, 0x64, 0xf9, 0x3e, 0x00]))
        rejects(DoubleRecord.self, Data([0xa1, 0x61, 0x64, 0xfa, 0x3f, 0xc0, 0x00, 0x00]))
    }

    @Test("Data as raw bytes, or as non-canonical base64")
    func testDataSpellings() throws {
        let canonical = try DagCBOR.encode(DataRecord(payload: Data([0x01])))
        #expect(try DagCBOR.decode(DataRecord.self, from: canonical).payload == Data([0x01]))
        let key: [UInt8] = [0xa1, 0x67] + Array("payload".utf8)
        rejects(DataRecord.self, Data(key + [0x41, 0x01]))                     // raw byte string
        rejects(DataRecord.self, Data(key + [0x64] + Array("AR==".utf8)))      // non-zero pad bits
        rejects(DataRecord.self, Data(key + [0x62] + Array("AQ".utf8)))        // unpadded
    }

    @Test("A node never decodes from JSON")
    func testNoJSONFallback() throws {
        let node = TestScalar(val: 1)
        #expect(TestScalar(data: try #require(node.toData()))?.val == 1)
        #expect(TestScalar(data: try #require(node.toJSON())) == nil)
    }
}
