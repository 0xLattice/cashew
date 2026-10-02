import Testing
import Foundation
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
    }
}
