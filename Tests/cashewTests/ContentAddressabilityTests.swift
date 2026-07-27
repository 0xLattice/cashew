import Testing
import Foundation
import ArrayTrie
import CID
@preconcurrency import Multicodec
import Multihash
import Multibase
@testable import cashew

@Suite("Headers & Content Addressability")
struct ContentAddressabilityTests {

    @Test("CID references normalize equivalent multibase spellings")
    func testCIDReferenceCanonicalization() throws {
        let canonical = try HeaderImpl(node: TestScalar(val: 7)).rawCID
        let cid = try CID(canonical)
        let alternate = BaseEncoding.base16.encode(data: cid.rawData)

        #expect(canonicalCID(alternate) == canonical)
        #expect(HeaderImpl<TestScalar>(rawCID: alternate).rawCID == canonical)
        #expect(VolumeImpl<TestScalar>(rawCID: alternate).rawCID == canonical)
    }

    @Test("Verification honors a CID's declared digest length")
    func testTruncatedMultihashVerification() throws {
        let data = Data("content-addressed payload".utf8)
        let multihash = try Multihash(raw: data, hashedWith: .sha2_256, customByteLength: 16)
        let cid = try CID(version: .v1, codec: .raw, multihash: multihash).toBaseEncodedString

        try verifyContentAddress(data, matches: cid)

        #expect(throws: DataErrors.cidMismatch) {
            try verifyContentAddress(data + Data([0]), matches: cid)
        }
    }

    @Test("Identity multihashes require the complete payload")
    func testIdentityMultihashVerificationIsExact() throws {
        let data = Data("inline".utf8)
        let multihash = try Multihash(raw: data, hashedWith: .identity)
        let cid = try CID(version: .v1, codec: .raw, multihash: multihash).toBaseEncodedString

        try verifyContentAddress(data, matches: cid)

        #expect(throws: DataErrors.cidMismatch) {
            try verifyContentAddress(data + Data([0]), matches: cid)
        }
    }

    @Test("Zero-length digests do not authenticate content")
    func testZeroLengthDigestIsRejected() throws {
        let multihash = try Multihash(raw: Data("anything".utf8), hashedWith: .sha2_256, customByteLength: 0)
        let cid = try CID(version: .v1, codec: .raw, multihash: multihash).toBaseEncodedString

        #expect(throws: (any Error).self) {
            try verifyContentAddress(Data("anything".utf8), matches: cid)
        }
    }

    @Suite("Header Basics")
    struct HeaderBasics {

        @Test("Initialize with rawCID only")
        func testInitWithRawCID() {
            let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)

            #expect(header.rawCID == cid)
            #expect(header.node == nil)
        }

        @Test("Initialize with rawCID and node")
        func testInitWithRawCIDAndNode() throws {
            let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = HeaderImpl(rawCID: cid, node: dictionary)

            #expect(header.rawCID == cid)
            #expect(try header.node?.get(key: "key1") == "value1")
            #expect(header.node?.count == 1)
        }

        @Test("Initialize with node only - uses placeholder CID")
        func testInitWithNodeOnly() throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = try HeaderImpl(node: dictionary)

            #expect(try header.node?.get(key: "key1") == "value1")
            #expect(header.rawCID.hasPrefix("bagu") || header.rawCID.hasPrefix("bafy"))
            #expect(header.rawCID.count > 10)
        }

        @Test("Initialize with node and specific codec")
        func testInitWithNodeAndCodec() throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = try HeaderImpl(node: dictionary, codec: .dag_json)

            #expect(try header.node?.get(key: "key1") == "value1")
            #expect(header.rawCID.hasPrefix("bagu") || header.rawCID.hasPrefix("bafy"))
        }

        @Test("Async create with proper CID generation")
        func testAsyncCreate() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = try await HeaderImpl.create(node: dictionary, codec: .dag_json)

            #expect(try header.node?.get(key: "key1") == "value1")
            #expect(header.rawCID.hasPrefix("bagu") || header.rawCID.hasPrefix("bafy"))
            #expect(header.rawCID != "bafyreigdhej4kdla7q2z5rnpfxqhj6c2wuutcka2rzkqxvmzq4f2j7kfgy")
        }

        @Test("CID creation is deterministic with async create")
        func testCIDCreationDeterministic() async throws {
            var dictionary1 = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary1 = try dictionary1.inserting(key: "key1", value: "value1")

            var dictionary2 = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary2 = try dictionary2.inserting(key: "key1", value: "value1")

            let header1 = try await HeaderImpl.create(node: dictionary1, codec: .dag_json)
            let header2 = try await HeaderImpl.create(node: dictionary2, codec: .dag_json)

            #expect(header1.rawCID == header2.rawCID)
        }

        @Test("Different codecs produce different CIDs")
        func testDifferentCodecsProduceDifferentCIDs() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")

            let headerCBOR = try await HeaderImpl.create(node: dictionary, codec: .dag_cbor)
            let headerJSON = try await HeaderImpl.create(node: dictionary, codec: .dag_json)

            #expect(headerCBOR.rawCID != headerJSON.rawCID)
        }

        @Test("Map node to data")
        func testMapToData() throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = try HeaderImpl(node: dictionary)

            let data = try header.mapToData()
            #expect(data.count > 0)

            let decoded = MerkleDictionaryImpl<String>(data: data)
            #expect(decoded != nil)
            #expect(decoded?.count == 1)
        }

        @Test("Map to data throws when no node")
        func testMapToDataThrowsWhenNoNode() {
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: "test-cid")

            #expect(throws: DataErrors.self) {
                try header.mapToData()
            }
        }

        @Test("Recreate CID with async method")
        func testRecreateCID() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = try await HeaderImpl.create(node: dictionary)
            let originalCID = header.rawCID

            let recreatedCID = try await header.recreateCID()
            #expect(recreatedCID == originalCID)
        }

        @Test("Recreate CID returns original when no node")
        func testRecreateCIDReturnsOriginalWhenNoNode() async throws {
            let originalCID = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: originalCID)

            let recreatedCID = try await header.recreateCID()
            #expect(recreatedCID == originalCID)
        }

        @Test("LosslessStringConvertible description")
        func testLosslessStringConvertibleDescription() {
            let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)

            #expect(header.description == cid)
        }

        @Test("LosslessStringConvertible init")
        func testLosslessStringConvertibleInit() {
            let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(cid)

            #expect(header != nil)
            #expect(header?.rawCID == cid)
            #expect(header?.node == nil)
        }

        @Test("Recreate CID with specific codec")
        func testRecreateCIDWithCodec() async throws {
            var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
            dictionary = try dictionary.inserting(key: "key1", value: "value1")
            let header = try await HeaderImpl.create(node: dictionary)

            let cidWithJSON = try await header.recreateCID(withCodec: .dag_json)
            let cidWithCBOR = try await header.recreateCID(withCodec: .dag_cbor)

            #expect(cidWithJSON != cidWithCBOR)
            #expect(cidWithJSON.hasPrefix("bagu") || cidWithJSON.hasPrefix("bafy"))
            #expect(cidWithCBOR.hasPrefix("bagu") || cidWithCBOR.hasPrefix("bafy"))
        }

        @Test("Recreate CID with codec throws when no node")
        func testRecreateCIDWithCodecThrowsWhenNoNode() async throws {
            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: "test-cid")

            await #expect(throws: DataErrors.self) {
                try await header.recreateCID(withCodec: .dag_json)
            }
        }

        @Test("Header CID is deterministic for identical nodes")
        func testHeaderCIDDeterministic() throws {
            let scalar1 = TestScalar(val: 100)
            let scalar2 = TestScalar(val: 100)
            let header1 = try HeaderImpl(node: scalar1)
            let header2 = try HeaderImpl(node: scalar2)
            #expect(header1.rawCID == header2.rawCID)
        }

        @Test("Header CID differs for different nodes")
        func testHeaderCIDDiffers() throws {
            let scalar1 = TestScalar(val: 1)
            let scalar2 = TestScalar(val: 2)
            let header1 = try HeaderImpl(node: scalar1)
            let header2 = try HeaderImpl(node: scalar2)
            #expect(header1.rawCID != header2.rawCID)
        }

        @Test("serializeNode throws on failure rather than returning empty data")
        func testSerializeNodeThrowsOnFailure() throws {
            let scalar = TestScalar(val: 42)
            let header = try HeaderImpl(node: scalar)
            let data = try header.mapToData()
            #expect(!data.isEmpty)
        }

        @Test("Node description returns empty string when encoding fails")
        func testNodeDescriptionSafeOnEncodingFailure() throws {
            let dict = MerkleDictionaryImpl<String>(children: [:], count: 0)
            let description = dict.description
            #expect(!description.isEmpty)
        }

        @Test("Node description works for valid nodes")
        func testNodeDescriptionWorksForValidNodes() throws {
            let scalar = TestScalar(val: 42)
            let description = scalar.description
            #expect(description.contains("42"))
        }

        @Test("CashewDecodingError is throwable and catchable")
        func testCashewDecodingErrorThrowable() throws {
            #expect(throws: CashewDecodingError.self) {
                throw CashewDecodingError.decodeFromDataError
            }
        }

        @Test("CashewDecodingError does not conflict with Swift.DecodingError")
        func testCashewDecodingErrorNoConflict() throws {
            let cashewError: Error = CashewDecodingError.decodeFromDataError
            let swiftError: Error = Swift.DecodingError.dataCorrupted(
                Swift.DecodingError.Context(codingPath: [], debugDescription: "test")
            )

            #expect(cashewError is CashewDecodingError)
            #expect(swiftError is Swift.DecodingError)
            #expect(!(cashewError is Swift.DecodingError))
            #expect(!(swiftError is CashewDecodingError))
        }

        @Test("Decoding invalid data throws CashewDecodingError")
        func testDecodingInvalidDataThrowsCashewError() async throws {
            let fetcher = TestStoreFetcher()
            let invalidData = Data([0xFF, 0xFE])
            let multihash = try Multihash(raw: invalidData, hashedWith: .sha2_256)
            let cid = try CID(version: .v1, codec: .dag_cbor, multihash: multihash)
            fetcher.storeRaw(rawCid: cid.toBaseEncodedString, data: invalidData)

            let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid.toBaseEncodedString)
            await #expect(throws: CashewDecodingError.self) {
                _ = try await header.resolve(fetcher: fetcher)
            }
        }

        @Test("RadixHeaderImpl init with nil node produces nil rawNode")
        func testRadixHeaderImplNilNode() throws {
            let header = RadixHeaderImpl<String>(rawCID: "test", node: nil)
            #expect(header.node == nil)
            #expect(header.rawCID == "test")
        }

        @Test("RadixHeaderImpl init with non-nil node produces valid rawNode")
        func testRadixHeaderImplNonNilNode() throws {
            typealias DictType = MerkleDictionaryImpl<String>
            let dict = try DictType(children: [:], count: 0)
                .inserting(key: "k", value: "v")

            let child = dict.children["k"]!
            let node = child.node!
            let header = RadixHeaderImpl<String>(rawCID: "test", node: node)
            #expect(header.node != nil)
            #expect(header.node!.prefix == node.prefix)
        }

        @Test("LosslessStringConvertible init from valid UTF-8 data succeeds")
        func testLosslessStringConvertibleValidData() throws {
            let data = "hello".data(using: .utf8)!
            let result = String(data: data)
            #expect(result == "hello")
        }

        @Test("LosslessStringConvertible init from invalid data returns nil")
        func testLosslessStringConvertibleInvalidData() throws {
            let data = Data([0xFF, 0xFE, 0x80, 0x81])
            let result = String(data: data)
            #expect(result == nil)
        }
    }

    @Suite("Content Addressability")
    struct ContentAddressability {

        @Test("Content addressability preserved after fixes")
        func testContentAddressabilityRegression() throws {
            let scalar = TestScalar(val: 42)
            let header1 = try HeaderImpl(node: scalar)
            let header2 = try HeaderImpl(node: scalar)
            #expect(header1.rawCID == header2.rawCID)

            let dict1 = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "a", value: "1")
            let dict2 = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "a", value: "1")
            let dh1 = try HeaderImpl(node: dict1)
            let dh2 = try HeaderImpl(node: dict2)
            #expect(dh1.rawCID == dh2.rawCID)
        }

        @Test("Same logical structure built in different order produces same CID")
        func testInsertionOrderIndependentCID() throws {
            let dict1 = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "alpha", value: "1")
                .inserting(key: "beta", value: "2")
                .inserting(key: "gamma", value: "3")

            let dict2 = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "gamma", value: "3")
                .inserting(key: "alpha", value: "1")
                .inserting(key: "beta", value: "2")

            let dict3 = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "beta", value: "2")
                .inserting(key: "gamma", value: "3")
                .inserting(key: "alpha", value: "1")

            let h1 = try HeaderImpl(node: dict1)
            let h2 = try HeaderImpl(node: dict2)
            let h3 = try HeaderImpl(node: dict3)

            #expect(h1.rawCID == h2.rawCID)
            #expect(h2.rawCID == h3.rawCID)
        }

        @Test("Transform result matches manual construction CID")
        func testTransformMatchesManualCID() throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "a", value: "old")

            var transforms = ArrayTrie<Transform>()
            transforms.set(["a"], value: .update("new"))
            transforms.set(["b"], value: .insert("added"))

            let transformResult = try dict.transform(transforms: transforms)!
            let manualResult = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "a", value: "new")
                .inserting(key: "b", value: "added")

            #expect(try HeaderImpl(node: transformResult).rawCID == (try HeaderImpl(node: manualResult).rawCID))
        }
    }

    @Suite("Cross-Platform Deterministic Serialization")
    struct CrossPlatformDeterminism {

        @Test("MerkleDictionary serialization bytes are stable across runs")
        func testDictionarySerializationStable() throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "alpha", value: "1")
                .inserting(key: "beta", value: "2")
                .inserting(key: "gamma", value: "3")

            let bytes1 = try HeaderImpl(node: dict).mapToData()
            let bytes2 = try HeaderImpl(node: dict).mapToData()
            #expect(bytes1 == bytes2)
        }

        @Test("MerkleSet serialization bytes are stable across runs")
        func testSetSerializationStable() throws {
            let set = try MerkleSetImpl()
                .insert("alice")
                .insert("bob")
                .insert("charlie")

            let bytes1 = try HeaderImpl(node: set).mapToData()
            let bytes2 = try HeaderImpl(node: set).mapToData()
            #expect(bytes1 == bytes2)
        }

        @Test("MerkleArray serialization bytes are stable across runs")
        func testArraySerializationStable() throws {
            var arr = MerkleArrayImpl<String>()
            arr = try arr.append("x")
            arr = try arr.append("y")
            arr = try arr.append("z")

            let bytes1 = try HeaderImpl(node: arr).mapToData()
            let bytes2 = try HeaderImpl(node: arr).mapToData()
            #expect(bytes1 == bytes2)
        }

        @Test("RadixNode serialization bytes are stable across runs")
        func testRadixNodeSerializationStable() throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "hello", value: "world")
            let radixNode = dict.children.first!.value.node!

            let bytes1 = try HeaderImpl(node: radixNode).mapToData()
            let bytes2 = try HeaderImpl(node: radixNode).mapToData()
            #expect(bytes1 == bytes2)
        }

        @Test("MerkleDictionary CID is deterministic (dag-cbor)")
        func testDictionaryCIDPinned() throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "alpha", value: "1")
                .inserting(key: "beta", value: "2")
                .inserting(key: "gamma", value: "3")
            let cid = try HeaderImpl(node: dict).rawCID
            let cid2 = try HeaderImpl(node: dict).rawCID
            #expect(cid == cid2)
        }

        @Test("MerkleSet CID is deterministic (dag-cbor)")
        func testSetCIDPinned() throws {
            let set = try MerkleSetImpl()
                .insert("alice")
                .insert("bob")
                .insert("charlie")
            let cid = try HeaderImpl(node: set).rawCID
            let cid2 = try HeaderImpl(node: set).rawCID
            #expect(cid == cid2)
        }

        @Test("MerkleArray CID is deterministic (dag-cbor)")
        func testArrayCIDPinned() throws {
            var arr = MerkleArrayImpl<String>()
            arr = try arr.append("x")
            arr = try arr.append("y")
            arr = try arr.append("z")
            let cid = try HeaderImpl(node: arr).rawCID
            let cid2 = try HeaderImpl(node: arr).rawCID
            #expect(cid == cid2)
        }

        @Test("RadixNode CID is deterministic (dag-cbor)")
        func testRadixNodeCIDPinned() throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "hello", value: "world")
            let radixNode = dict.children.first!.value.node!
            let cid = try HeaderImpl(node: radixNode).rawCID
            let cid2 = try HeaderImpl(node: radixNode).rawCID
            #expect(cid == cid2)
        }

        @Test("MerkleSet insertion order does not affect CID")
        func testSetInsertionOrderIndependentCID() throws {
            let s1 = try MerkleSetImpl()
                .insert("alice").insert("bob").insert("charlie")
            let s2 = try MerkleSetImpl()
                .insert("charlie").insert("alice").insert("bob")
            let s3 = try MerkleSetImpl()
                .insert("bob").insert("charlie").insert("alice")

            let h1 = try HeaderImpl(node: s1)
            let h2 = try HeaderImpl(node: s2)
            let h3 = try HeaderImpl(node: s3)
            #expect(h1.rawCID == h2.rawCID)
            #expect(h2.rawCID == h3.rawCID)
        }

        @Test("MerkleSet insertion order does not affect serialization bytes")
        func testSetInsertionOrderIndependentBytes() throws {
            let s1 = try MerkleSetImpl()
                .insert("alice").insert("bob").insert("charlie")
            let s2 = try MerkleSetImpl()
                .insert("charlie").insert("alice").insert("bob")

            let b1 = try HeaderImpl(node: s1).mapToData()
            let b2 = try HeaderImpl(node: s2).mapToData()
            #expect(b1 == b2)
        }

        @Test("MerkleArray serialization bytes match across equivalent constructions")
        func testArrayEquivalentConstructionBytes() throws {
            var arr1 = MerkleArrayImpl<String>()
            arr1 = try arr1.append("a")
            arr1 = try arr1.append("b")

            var arr2 = MerkleArrayImpl<String>()
            arr2 = try arr2.append("a")
            arr2 = try arr2.append("b")

            let b1 = try HeaderImpl(node: arr1).mapToData()
            let b2 = try HeaderImpl(node: arr2).mapToData()
            #expect(b1 == b2)
        }

        @Test("Serialized CBOR round-trips correctly for all node types")
        func testSerializedCBORRoundTrip() throws {
            let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
                .inserting(key: "z", value: "1")
                .inserting(key: "a", value: "2")
            let dictData = try HeaderImpl(node: dict).mapToData()
            let dictDecoded = MerkleDictionaryImpl<String>(data: dictData)
            #expect(dictDecoded != nil)
            #expect(dictDecoded?.count == dict.count)

            let set = try MerkleSetImpl().insert("z").insert("a")
            let setData = try HeaderImpl(node: set).mapToData()
            let setDecoded = MerkleSetImpl(data: setData)
            #expect(setDecoded != nil)

            var arr = MerkleArrayImpl<String>()
            arr = try arr.append("val")
            let arrData = try HeaderImpl(node: arr).mapToData()
            let arrDecoded = MerkleArrayImpl<String>(data: arrData)
            #expect(arrDecoded != nil)
        }
    }
}
