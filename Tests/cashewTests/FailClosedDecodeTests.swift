import Testing
import Foundation
import CID
@preconcurrency import Multicodec
import Multihash
import Multibase
@testable import cashew

/// Node bytes are attacker-authored. Decoding must throw (or return nil) on
/// malformed or non-canonical input, never trap.
@Suite("Fail-closed node decoding")
struct FailClosedDecodeTests {

    // MARK: - Byte helpers

    /// CBOR text-string encoding of a short string (< 256 bytes).
    static func cborText(_ string: String) -> Data {
        let utf8 = Data(string.utf8)
        precondition(utf8.count < 256)
        var out = Data()
        if utf8.count < 24 {
            out.append(0x60 | UInt8(utf8.count))
        } else {
            out.append(0x78)
            out.append(UInt8(utf8.count))
        }
        out.append(utf8)
        return out
    }

    /// Replaces the single occurrence of `old` with `new`.
    static func replacing(_ old: Data, with new: Data, in data: Data) throws -> Data {
        let range = try #require(data.range(of: old))
        #expect(data[range.upperBound...].range(of: old) == nil, "pattern must be unique")
        var out = data
        out.replaceSubrange(range, with: new)
        return out
    }

    /// Turns the child entry keyed "b" into a second entry keyed "a".
    static func duplicatingChildKey(_ data: Data) throws -> Data {
        try replacing(cborText("key") + cborText("b"), with: cborText("key") + cborText("a"), in: data)
    }

    static func radixHeader(_ prefix: String) throws -> RadixHeaderImpl<String> {
        try RadixHeaderImpl(node: RadixNodeImpl<String>(prefix: prefix, value: prefix, children: [:]))
    }

    static func volumeRadixHeader(_ prefix: String) throws -> VolumeRadixHeaderImpl<String> {
        try VolumeRadixHeaderImpl(node: VolumeRadixNodeImpl<String>(prefix: prefix, value: prefix, children: [:]))
    }

    /// Asserts canonical bytes round-trip, and that duplicating a child key
    /// makes both the raw decoder throw and the node entry point reject.
    static func expectDuplicateChildKeyRejected<N: Node>(_ node: N) throws {
        let canonical = try #require(node.toData())
        let roundTripped = try #require(N(data: canonical))
        #expect(roundTripped.toData() == canonical)

        let duplicated = try duplicatingChildKey(canonical)
        #expect(throws: DecodingError.self) {
            _ = try DagCBOR.decode(N.self, from: duplicated)
        }
        #expect(N(data: duplicated) == nil)
    }

    // MARK: - Duplicate child keys, one per node type

    @Test("RadixNodeImpl: duplicate child key throws")
    func radixNodeDuplicateKey() throws {
        try Self.expectDuplicateChildKeyRejected(RadixNodeImpl<String>(
            prefix: "p", value: nil,
            children: ["a": Self.radixHeader("a"), "b": Self.radixHeader("b")]
        ))
    }

    @Test("MerkleDictionaryImpl: duplicate child key throws")
    func merkleDictionaryDuplicateKey() throws {
        try Self.expectDuplicateChildKeyRejected(MerkleDictionaryImpl<String>(
            children: ["a": Self.radixHeader("a"), "b": Self.radixHeader("b")], count: 2
        ))
    }

    @Test("MerkleArrayImpl: duplicate child key throws")
    func merkleArrayDuplicateKey() throws {
        try Self.expectDuplicateChildKeyRejected(MerkleArrayImpl<String>(
            children: ["a": Self.radixHeader("a"), "b": Self.radixHeader("b")], count: 2
        ))
    }

    @Test("MerkleSetImpl: duplicate child key throws")
    func merkleSetDuplicateKey() throws {
        try Self.expectDuplicateChildKeyRejected(MerkleSetImpl(
            children: ["a": Self.radixHeader("a"), "b": Self.radixHeader("b")], count: 2
        ))
    }

    @Test("VolumeMerkleDictionaryImpl: duplicate child key throws")
    func volumeMerkleDictionaryDuplicateKey() throws {
        try Self.expectDuplicateChildKeyRejected(VolumeMerkleDictionaryImpl<String>(
            children: ["a": Self.volumeRadixHeader("a"), "b": Self.volumeRadixHeader("b")], count: 2
        ))
    }

    @Test("VolumeRadixNodeImpl: duplicate child key throws")
    func volumeRadixNodeDuplicateKey() throws {
        try Self.expectDuplicateChildKeyRejected(VolumeRadixNodeImpl<String>(
            prefix: "p", value: nil,
            children: ["a": Self.volumeRadixHeader("a"), "b": Self.volumeRadixHeader("b")]
        ))
    }

    @Test("Child keys that are not exactly one character throw")
    func childKeyNotOneCharacter() throws {
        let node = MerkleDictionaryImpl<String>(children: ["a": try Self.radixHeader("a")], count: 1)
        let canonical = try #require(node.toData())
        for bad in ["", "ab"] {
            let data = try Self.replacing(
                Self.cborText("key") + Self.cborText("a"),
                with: Self.cborText("key") + Self.cborText(bad),
                in: canonical
            )
            #expect(throws: DecodingError.self) {
                _ = try DagCBOR.decode(MerkleDictionaryImpl<String>.self, from: data)
            }
            #expect(MerkleDictionaryImpl<String>(data: data) == nil)
        }
    }

    @Test("Fetched node with duplicate child key fails with a decode error")
    func fetchedDuplicateKeyThrows() async throws {
        let node = MerkleDictionaryImpl<String>(
            children: ["a": try Self.radixHeader("a"), "b": try Self.radixHeader("b")], count: 2
        )
        let bytes = try Self.duplicatingChildKey(try #require(node.toData()))
        let cid = try CID(
            version: .v1, codec: .dag_cbor,
            multihash: Multihash(raw: bytes, hashedWith: .sha2_256)
        ).toBaseEncodedString
        let fetcher = TestStoreFetcher()
        fetcher.storeRaw(rawCid: cid, data: bytes)

        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)
        await #expect(throws: CashewDecodingError.self) {
            _ = try await header.fetchAndDecodeNode(fetcher: fetcher)
        }
    }

    // MARK: - Non-canonical encodings

    static func canonicalDictionary() throws -> (MerkleDictionaryImpl<String>, Data) {
        let node = MerkleDictionaryImpl<String>(children: ["a": try radixHeader("a")], count: 1)
        return (node, try #require(node.toData()))
    }

    @Test("Canonical nodes round-trip through init?(data:)")
    func canonicalRoundTrip() throws {
        var dict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        for key in ["alpha", "beta", "gamma", "alphabet", "b"] {
            dict = try dict.inserting(key: key, value: "v-\(key)")
        }
        let header = try HeaderImpl(node: dict)
        let data = try header.mapToData()
        let decoded = try #require(MerkleDictionaryImpl<String>(data: data))
        #expect(decoded.count == dict.count)
        #expect(decoded.toData() == data)
        #expect(try HeaderImpl(node: decoded).rawCID == header.rawCID)

        let scalar = TestScalar(val: 1_000_000)
        let scalarData = try #require(scalar.toData())
        #expect(TestScalar(data: scalarData)?.val == 1_000_000)
    }

    @Test("Non-minimal integer is rejected")
    func nonMinimalIntegerRejected() throws {
        let (_, canonical) = try Self.canonicalDictionary()
        // count = 1 is canonically the single byte 0x01; spell it as 0x18 0x01.
        let data = try Self.replacing(
            Self.cborText("count") + Data([0x01]),
            with: Self.cborText("count") + Data([0x18, 0x01]),
            in: canonical
        )
        // The raw parser accepts it; the node entry point must not.
        #expect((try? DagCBOR.decode(MerkleDictionaryImpl<String>.self, from: data)) != nil)
        #expect(MerkleDictionaryImpl<String>(data: data) == nil)
    }

    @Test("Unsorted map keys are rejected")
    func unsortedKeysRejected() throws {
        let (_, canonical) = try Self.canonicalDictionary()
        // Top-level map: 0xa2, then "count" (shorter, first), then "children".
        #expect(canonical.first == 0xa2)
        let countEntry = Self.cborText("count") + Data([0x01])
        #expect(canonical[1..<(1 + countEntry.count)] == countEntry)
        let childrenEntry = canonical[(1 + countEntry.count)...]
        let unsorted = Data([0xa2]) + childrenEntry + countEntry

        #expect((try? DagCBOR.decode(MerkleDictionaryImpl<String>.self, from: unsorted)) != nil)
        #expect(MerkleDictionaryImpl<String>(data: unsorted) == nil)
    }

    @Test("Duplicate map keys are rejected")
    func duplicateMapKeysRejected() throws {
        let (_, canonical) = try Self.canonicalDictionary()
        let countEntry = Self.cborText("count") + Data([0x01])
        let childrenEntry = canonical[(1 + countEntry.count)...]
        let duplicated = Data([0xa3]) + countEntry + countEntry + childrenEntry
        #expect(MerkleDictionaryImpl<String>(data: duplicated) == nil)
    }

    @Test("Trailing bytes are rejected")
    func trailingBytesRejected() throws {
        let (_, canonical) = try Self.canonicalDictionary()
        let data = canonical + Data([0x00])
        #expect(throws: DagCBORError.self) {
            _ = try DagCBOR.decode(MerkleDictionaryImpl<String>.self, from: data)
        }
        #expect(MerkleDictionaryImpl<String>(data: data) == nil)
    }

    @Test("Non-canonical CID spelling in a child reference is rejected")
    func nonCanonicalCIDRejected() throws {
        let (node, canonical) = try Self.canonicalDictionary()
        let rawCID = try #require(node.children["a"]).rawCID
        let alternate = BaseEncoding.base16.encode(data: try CID(rawCID).rawData)
        #expect(alternate != rawCID)
        let data = try Self.replacing(Self.cborText(rawCID), with: Self.cborText(alternate), in: canonical)
        #expect(MerkleDictionaryImpl<String>(data: data) == nil)
    }

    @Test("JSON bytes are not accepted as node bytes")
    func jsonBytesRejected() throws {
        let (node, _) = try Self.canonicalDictionary()
        let json = try #require(node.toJSON())
        #expect(MerkleDictionaryImpl<String>(data: json) == nil)
        // The LosslessStringConvertible form is JSON and still round-trips.
        #expect(MerkleDictionaryImpl<String>(node.description)?.count == 1)
    }

    @Test("Decoding a Data slice does not trap")
    func sliceDecodes() throws {
        let (_, canonical) = try Self.canonicalDictionary()
        let padded = Data([0xff, 0xff]) + canonical
        let slice = padded[2...]
        #expect(slice.startIndex != 0)
        #expect(MerkleDictionaryImpl<String>(data: slice)?.count == 1)
    }
}
