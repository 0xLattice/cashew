import Testing
import Foundation
import ArrayTrie
import Crypto
@preconcurrency import Multicodec
@testable import cashew

@Suite("Encryption Basics")
struct EncryptionBasicsTests {

    @Suite("AES-GCM Encrypt/Decrypt")
    struct EncryptionHelperTests {
        @Test("encrypt then decrypt round-trip")
        func testEncryptDecryptRoundTrip() throws {
            let key = SymmetricKey(size: .bits256)
            let original = "Hello, World!".data(using: .utf8)!
            let (encrypted, _) = try EncryptionHelper.encrypt(data: original, key: key)
            let decrypted = try EncryptionHelper.decrypt(data: encrypted, key: key)
            #expect(decrypted == original)
        }

        @Test("random IV produces different ciphertexts")
        func testRandomIV() throws {
            let key = SymmetricKey(size: .bits256)
            let data = "same data".data(using: .utf8)!
            let (enc1, iv1) = try EncryptionHelper.encrypt(data: data, key: key)
            let (enc2, iv2) = try EncryptionHelper.encrypt(data: data, key: key)
            #expect(iv1 != iv2)
            #expect(enc1 != enc2)
        }

        @Test("decrypt with wrong key throws")
        func testDecryptWrongKey() throws {
            let key1 = SymmetricKey(size: .bits256)
            let key2 = SymmetricKey(size: .bits256)
            let data = "secret".data(using: .utf8)!
            let (encrypted, _) = try EncryptionHelper.encrypt(data: data, key: key1)
            #expect(throws: (any Error).self) {
                _ = try EncryptionHelper.decrypt(data: encrypted, key: key2)
            }
        }

        @Test("empty data encrypt/decrypt")
        func testEmptyData() throws {
            let key = SymmetricKey(size: .bits256)
            let (encrypted, _) = try EncryptionHelper.encrypt(data: Data(), key: key)
            let decrypted = try EncryptionHelper.decrypt(data: encrypted, key: key)
            #expect(decrypted == Data())
        }
    }

    @Suite("EncryptionInfo Model")
    struct EncryptionInfoTests {
        @Test("init from SymmetricKey and Data")
        func testInitFromKeyAndIV() {
            let key = SymmetricKey(size: .bits256)
            let iv = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
            let info = EncryptionInfo(key: key, iv: iv)

            let keyData = key.withUnsafeBytes { Data($0) }
            let expectedHash = Data(SHA256.hash(data: keyData)).base64EncodedString()
            #expect(info.keyHash == expectedHash)
            #expect(info.iv == iv.base64EncodedString())
        }

        @Test("Codable round-trip")
        func testCodableRoundTrip() throws {
            let key = SymmetricKey(size: .bits256)
            let iv = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
            let info = EncryptionInfo(key: key, iv: iv)
            let encoded = try JSONEncoder().encode(info)
            let decoded = try JSONDecoder().decode(EncryptionInfo.self, from: encoded)
            #expect(info == decoded)
        }

        @Test("Equatable")
        func testEquatable() {
            let info1 = EncryptionInfo(keyHash: "abc", iv: "def")
            let info2 = EncryptionInfo(keyHash: "abc", iv: "def")
            let info3 = EncryptionInfo(keyHash: "abc", iv: "xyz")
            #expect(info1 == info2)
            #expect(info1 != info3)
        }
    }
}

@Suite("Encrypted Headers")
struct EncryptedHeaderTests {
    typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Encrypted HeaderImpl has different CID from plaintext")
    func testEncryptedHeaderDifferentCID() throws {
        let scalar = TestScalar(val: 42)
        let plainHeader = try HeaderImpl(node: scalar)
        let key = SymmetricKey(size: .bits256)
        let encHeader = try HeaderImpl(node: scalar, key: key)
        #expect(plainHeader.rawCID != encHeader.rawCID)
    }

    @Test("encryptionInfo populated after encrypted init")
    func testEncryptionInfoPopulated() throws {
        let key = SymmetricKey(size: .bits256)
        let encHeader = try HeaderImpl(node: TestScalar(val: 1), key: key)
        #expect(encHeader.encryptionInfo != nil)
        let keyData = key.withUnsafeBytes { Data($0) }
        let expectedHash = Data(SHA256.hash(data: keyData)).base64EncodedString()
        #expect(encHeader.encryptionInfo!.keyHash == expectedHash)
    }

    @Test("Plaintext header has nil encryptionInfo")
    func testPlaintextNilEncryptionInfo() throws {
        let header = try HeaderImpl(node: TestScalar(val: 1))
        #expect(header.encryptionInfo == nil)
    }

    @Test("removingNode preserves encryptionInfo")
    func testRemovingNodePreservesEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let encHeader = try HeaderImpl(node: TestScalar(val: 1), key: key)
        let stripped = encHeader.removingNode()
        #expect(stripped.encryptionInfo == encHeader.encryptionInfo)
        #expect(stripped.node == nil)
    }

    @Test("LosslessStringConvertible round-trip plaintext")
    func testDescriptionRoundTripPlaintext() throws {
        let header = try HeaderImpl(node: TestScalar(val: 1))
        let desc = header.description
        let restored = HeaderImpl<TestScalar>(desc)
        #expect(restored != nil)
        #expect(restored!.rawCID == header.rawCID)
        #expect(restored!.encryptionInfo == nil)
    }

    @Test("LosslessStringConvertible round-trip encrypted")
    func testDescriptionRoundTripEncrypted() throws {
        let key = SymmetricKey(size: .bits256)
        let encHeader = try HeaderImpl(node: TestScalar(val: 1), key: key)
        let desc = encHeader.description
        #expect(desc.hasPrefix("enc:"))
        let restored = HeaderImpl<TestScalar>(desc)
        #expect(restored != nil)
        #expect(restored!.rawCID == encHeader.rawCID)
        #expect(restored!.encryptionInfo?.keyHash == encHeader.encryptionInfo?.keyHash)
        #expect(restored!.encryptionInfo?.iv == encHeader.encryptionInfo?.iv)
    }

    @Test("Codable round-trip encrypted HeaderImpl")
    func testCodableEncryptedHeaderImpl() throws {
        let key = SymmetricKey(size: .bits256)
        let encHeader = try HeaderImpl(node: TestScalar(val: 1), key: key)
        let encoded = try JSONEncoder().encode(encHeader)
        let decoded = try JSONDecoder().decode(HeaderImpl<TestScalar>.self, from: encoded)
        #expect(decoded.rawCID == encHeader.rawCID)
        #expect(decoded.encryptionInfo == encHeader.encryptionInfo)
    }

    @Test("Encrypted store and resolve round-trip")
    func testEncryptedStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        let scalar = TestScalar(val: 42)
        let encHeader = try HeaderImpl(node: scalar, key: key)
        try await encHeader.storeAsVolume(storer: fetcher)

        let cidOnly = HeaderImpl<TestScalar>(rawCID: encHeader.rawCID, node: nil, encryptionInfo: encHeader.encryptionInfo)
        let resolved = try await cidOnly.resolve(fetcher: fetcher)
        #expect(resolved.node != nil)
        #expect(resolved.node!.val == 42)
    }

    @Test("Resolve encrypted header without KeyProvidingFetcher throws")
    func testResolveWithoutKeyProviderThrows() async throws {
        let key = SymmetricKey(size: .bits256)
        let storeFetcher = TestKeyProvidingStoreFetcher()
        storeFetcher.registerKey(key)

        let encHeader = try HeaderImpl(node: TestScalar(val: 1), key: key)
        try await encHeader.storeAsVolume(storer: storeFetcher)

        let plainFetcher = TestStoreFetcher()
        let encryptedData = try await storeFetcher.fetch(rawCid: encHeader.rawCID)
        plainFetcher.storeRaw(rawCid: encHeader.rawCID, data: encryptedData)

        let cidOnly = HeaderImpl<TestScalar>(rawCID: encHeader.rawCID, node: nil, encryptionInfo: encHeader.encryptionInfo)
        await #expect(throws: DataErrors.self) {
            _ = try await cidOnly.resolve(fetcher: plainFetcher)
        }
    }

    @Test("Plaintext resolve works with KeyProvidingFetcher")
    func testPlaintextResolveWithKeyProvider() async throws {
        let fetcher = TestKeyProvidingStoreFetcher()
        let scalar = TestScalar(val: 99)
        let header = try HeaderImpl(node: scalar)
        try await header.storeAsVolume(storer: fetcher)

        let cidOnly = HeaderImpl<TestScalar>(rawCID: header.rawCID)
        let resolved = try await cidOnly.resolve(fetcher: fetcher)
        #expect(resolved.node!.val == 99)
    }

    @Test("Encrypted RadixHeaderImpl store and resolve")
    func testEncryptedRadixHeaderStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        typealias RH = RadixHeaderImpl<HeaderImpl<TestScalar>>
        let valueHeader = try HeaderImpl(node: TestScalar(val: 7))
        let node = RH.NodeType(prefix: "test", value: valueHeader, children: [:])
        let encHeader = try RH(node: node, key: key)
        try await encHeader.storeAsVolume(storer: fetcher)

        let cidOnly = RH(rawCID: encHeader.rawCID, node: nil, encryptionInfo: encHeader.encryptionInfo)
        let resolved = try await cidOnly.resolve(fetcher: fetcher)
        #expect(resolved.node != nil)
        #expect(resolved.node!.prefix == "test")
    }

    @Test("Encrypted resolution works over the batched ContentSource API")
    func testEncryptedResolveOverContentSource() async throws {
        // Regression: CoalescingFetcher must forward KeyProvider to the source,
        // or resolve(source:) silently fails to decrypt encrypted nodes.
        let key = SymmetricKey(size: .bits256)
        let source = TestKeyProvidingStoreFetcher()
        source.registerKey(key)

        let encHeader = try HeaderImpl(node: TestScalar(val: 42), key: key)
        try await encHeader.storeAsVolume(storer: source)

        let cidOnly = HeaderImpl<TestScalar>(rawCID: encHeader.rawCID, node: nil, encryptionInfo: encHeader.encryptionInfo)
        let resolved = try await cidOnly.resolve(source: source)
        #expect(resolved.node?.val == 42)
    }

    @Test("Encrypted resolution over a keyless ContentSource still fails closed")
    func testEncryptedResolveOverKeylessContentSourceThrows() async throws {
        let key = SymmetricKey(size: .bits256)
        let keyed = TestKeyProvidingStoreFetcher()
        keyed.registerKey(key)
        let encHeader = try HeaderImpl(node: TestScalar(val: 7), key: key)
        try await encHeader.storeAsVolume(storer: keyed)

        // A plain source carries no keys — decryption must throw, not silently pass.
        let plain = TestStoreFetcher()
        let encData = try await keyed.fetch(rawCid: encHeader.rawCID)
        plain.storeRaw(rawCid: encHeader.rawCID, data: encData)

        let cidOnly = HeaderImpl<TestScalar>(rawCID: encHeader.rawCID, node: nil, encryptionInfo: encHeader.encryptionInfo)
        await #expect(throws: DataErrors.self) {
            _ = try await cidOnly.resolve(source: plain)
        }
    }
}

@Suite("Targeted Strategy")
struct TargetedEncryptionTests {
    typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Targeted encryption encrypts value at path")
    func testTargetedEncryptsValue() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["alice"], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        let aliceValue = try encDict.get(key: "alice")
        #expect(aliceValue != nil)
        #expect(aliceValue!.encryptionInfo != nil)

        let bobValue = try encDict.get(key: "bob")
        #expect(bobValue != nil)
        #expect(bobValue!.encryptionInfo == nil)
    }

    @Test("Targeted encryption store/resolve round-trip")
    func testTargetedStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["alice"], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["alice"], value: .targeted)
        paths.set(["bob"], value: .targeted)
        let resolved = try await encrypted.removingNode().resolve(paths: paths, fetcher: fetcher)

        let aliceVal = try resolved.node!.get(key: "alice")
        #expect(aliceVal != nil)
        let aliceResolved = try await aliceVal!.resolve(fetcher: fetcher)
        #expect(aliceResolved.node!.val == 1)

        let bobVal = try resolved.node!.get(key: "bob")
        #expect(bobVal != nil)
        let bobResolved = try await bobVal!.resolve(fetcher: fetcher)
        #expect(bobResolved.node!.val == 2)
    }

    @Test("Root targeted encryption encrypts trie structure")
    func testRootTargetedEncryptsTrieStructure() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        for (_, child) in encDict.children {
            #expect(child.encryptionInfo != nil)
        }
    }

    @Test("Root targeted encryption does NOT encrypt values without sub-path override")
    func testRootTargetedDoesNotEncryptValues() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        let aliceVal = try encDict.get(key: "alice")
        #expect(aliceVal != nil)
        #expect(aliceVal!.encryptionInfo == nil)

        let bobVal = try encDict.get(key: "bob")
        #expect(bobVal != nil)
        #expect(bobVal!.encryptionInfo == nil)
    }

    @Test("Root targeted with sub-path override encrypts trie and targeted value")
    func testRootTargetedWithSubPathOverride() throws {
        let key = SymmetricKey(size: .bits256)
        let aliceKey = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .targeted(key))
        encryption.set(["alice"], value: .targeted(aliceKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        for (_, child) in encDict.children {
            #expect(child.encryptionInfo != nil)
        }

        let aliceVal = try encDict.get(key: "alice")
        #expect(aliceVal != nil)
        #expect(aliceVal!.encryptionInfo != nil)

        let bobVal = try encDict.get(key: "bob")
        #expect(bobVal != nil)
        #expect(bobVal!.encryptionInfo == nil)
    }

    @Test("Root targeted store/resolve round-trip")
    func testRootTargetedStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([""], value: .list)
        paths.set(["alice"], value: .targeted)
        paths.set(["bob"], value: .targeted)
        let resolved = try await encrypted.removingNode().resolve(paths: paths, fetcher: fetcher)

        let aliceVal = try resolved.node!.get(key: "alice")
        #expect(aliceVal != nil)
        let aliceResolved = try await aliceVal!.resolve(fetcher: fetcher)
        #expect(aliceResolved.node!.val == 1)

        let bobVal = try resolved.node!.get(key: "bob")
        #expect(bobVal != nil)
        let bobResolved = try await bobVal!.resolve(fetcher: fetcher)
        #expect(bobResolved.node!.val == 2)
    }
}

@Suite("List Strategy")
struct ListEncryptionTests {
    typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("List encryption encrypts RadixHeaders but not values")
    func testListEncryptsStructureNotValues() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .list(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        for (_, child) in encDict.children {
            #expect(child.encryptionInfo != nil)
        }

        let aliceValue = try encDict.get(key: "alice")
        #expect(aliceValue != nil)
        #expect(aliceValue!.encryptionInfo == nil)
    }

    @Test("List encryption store/resolve round-trip")
    func testListStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .list(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set([""], value: .list)
        paths.set(["alice"], value: .targeted)
        paths.set(["bob"], value: .targeted)
        let cidOnly = encrypted.removingNode()
        let resolved = try await cidOnly.resolve(paths: paths, fetcher: fetcher)

        let aliceVal = try resolved.node!.get(key: "alice")
        #expect(aliceVal != nil)
        let aliceResolved = try await aliceVal!.resolve(fetcher: fetcher)
        #expect(aliceResolved.node!.val == 1)
    }
}

@Suite("Recursive Strategy")
struct RecursiveEncryptionTests {
    typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Recursive encryption encrypts entire subtree")
    func testRecursiveEncryptsAll() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        for (_, child) in encDict.children {
            #expect(child.encryptionInfo != nil)
        }
        let aliceVal = try encDict.get(key: "alice")
        #expect(aliceVal!.encryptionInfo != nil)
        let bobVal = try encDict.get(key: "bob")
        #expect(bobVal!.encryptionInfo != nil)
    }

    @Test("Recursive encryption store/resolve round-trip")
    func testRecursiveStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: fetcher)
        let aliceVal = try resolved.node!.get(key: "alice")
        #expect(aliceVal != nil)
        let aliceResolved = try await aliceVal!.resolve(fetcher: fetcher)
        #expect(aliceResolved.node!.val == 1)
    }

    @Test("Recursive with longer-path override")
    func testRecursiveWithOverride() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key1))
        encryption.set(["bob"], value: .recursive(key2))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        let aliceVal = try encDict.get(key: "alice")
        #expect(aliceVal!.encryptionInfo != nil)

        let key1Data = key1.withUnsafeBytes { Data($0) }
        let key1Hash = Data(SHA256.hash(data: key1Data)).base64EncodedString()
        #expect(aliceVal!.encryptionInfo!.keyHash == key1Hash)

        let bobVal = try encDict.get(key: "bob")
        #expect(bobVal!.encryptionInfo != nil)

        let key2Data = key2.withUnsafeBytes { Data($0) }
        let key2Hash = Data(SHA256.hash(data: key2Data)).base64EncodedString()
        #expect(bobVal!.encryptionInfo!.keyHash == key2Hash)
    }
}

@Suite("Mixed Strategies")
struct MixedEncryptionTests {
    typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Sibling paths with different keys")
    func testSiblingDifferentKeys() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["alice"], value: .targeted(key1))
        encryption.set(["bob"], value: .targeted(key2))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        let aliceVal = try encDict.get(key: "alice")
        let bobVal = try encDict.get(key: "bob")

        let key1Data = key1.withUnsafeBytes { Data($0) }
        let key1Hash = Data(SHA256.hash(data: key1Data)).base64EncodedString()
        let key2Data = key2.withUnsafeBytes { Data($0) }
        let key2Hash = Data(SHA256.hash(data: key2Data)).base64EncodedString()

        #expect(aliceVal!.encryptionInfo!.keyHash == key1Hash)
        #expect(bobVal!.encryptionInfo!.keyHash == key2Hash)
    }

    @Test("Sibling paths with different keys store/resolve")
    func testSiblingDifferentKeysStoreResolve() async throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key1)
        fetcher.registerKey(key2)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["alice"], value: .targeted(key1))
        encryption.set(["bob"], value: .targeted(key2))
        let encrypted = try header.encrypt(encryption: encryption)
        try await encrypted.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["alice"], value: .targeted)
        paths.set(["bob"], value: .targeted)
        let resolved = try await encrypted.removingNode().resolve(paths: paths, fetcher: fetcher)

        let aliceVal = try resolved.node!.get(key: "alice")!
        let aliceResolved = try await aliceVal.resolve(fetcher: fetcher)
        #expect(aliceResolved.node!.val == 1)

        let bobVal = try resolved.node!.get(key: "bob")!
        let bobResolved = try await bobVal.resolve(fetcher: fetcher)
        #expect(bobResolved.node!.val == 2)
    }

    @Test("Mixed encrypted and plaintext tree")
    func testMixedEncryptedPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "secret", value: try HeaderImpl(node: TestScalar(val: 42)))
        dict = try dict.inserting(key: "public", value: try HeaderImpl(node: TestScalar(val: 99)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["secret"], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let encDict = encrypted.node!
        let secretVal = try encDict.get(key: "secret")
        #expect(secretVal!.encryptionInfo != nil)
        let publicVal = try encDict.get(key: "public")
        #expect(publicVal!.encryptionInfo == nil)
    }
}

@Suite("Encryption with Transforms")
struct TransformEncryptionTests {
    typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Transform then encrypt")
    func testTransformThenEncrypt() throws {
        let key = SymmetricKey(size: .bits256)
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        dict = try dict.inserting(key: "charlie", value: try HeaderImpl(node: TestScalar(val: 3)))
        let header = try HeaderImpl(node: dict)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["charlie"], value: .delete)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["bob"], value: .targeted(key))

        let result = try header.transform(transforms: transforms, encryption: encryption)
        #expect(result != nil)

        let bobVal = try result!.node!.get(key: "bob")
        #expect(bobVal != nil)
        #expect(bobVal!.encryptionInfo != nil)

        let aliceVal = try result!.node!.get(key: "alice")
        #expect(aliceVal != nil)
        #expect(aliceVal!.encryptionInfo == nil)

        let charlieVal = try result!.node!.get(key: "charlie")
        #expect(charlieVal == nil)
    }

    @Test("Transform without encryption is unchanged")
    func testTransformWithoutEncryption() throws {
        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        let header = try HeaderImpl(node: dict)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["bob"], value: .insert("HeaderImpl<TestScalar>(val: 2)"))

        let encryption = ArrayTrie<EncryptionStrategy>()
        let result = try header.transform(transforms: transforms, encryption: encryption)
        #expect(result != nil)
        let bobVal = try result!.node!.get(key: "bob")
        #expect(bobVal != nil)
        #expect(bobVal!.encryptionInfo == nil)
    }

    @Test("Top-level header re-encrypted after transform")
    func testTopLevelHeaderReEncrypted() throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))

        let plainHeader = try HeaderImpl(node: dict)
        let encHeader = try HeaderImpl(node: dict, key: key)
        #expect(encHeader.encryptionInfo != nil)

        let originalKeyHash = encHeader.encryptionInfo!.keyHash
        let originalCID = encHeader.rawCID

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .delete)
        let result = try encHeader.transform(transforms: transforms, keyProvider: fetcher)
        #expect(result != nil)
        #expect(result!.encryptionInfo != nil)
        #expect(result!.encryptionInfo!.keyHash == originalKeyHash)
        #expect(result!.rawCID != originalCID)
        #expect(result!.rawCID != plainHeader.rawCID)
    }

    @Test("Delete value in encrypted dict")
    func testDeleteInEncryptedDict() throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .delete)
        let result = try encrypted.transform(transforms: transforms, keyProvider: fetcher)
        #expect(result != nil)

        let aliceVal = try result!.node!.get(key: "alice")
        #expect(aliceVal == nil)

        let bobVal = try result!.node!.get(key: "bob")
        #expect(bobVal != nil)
        #expect(bobVal!.encryptionInfo != nil)
    }

    @Test("Insert into encrypted dict does NOT auto-encrypt")
    func testInsertNotAutoEncrypted() throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["alice"], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["charlie"], value: .insert(try HeaderImpl<TestScalar>(node: TestScalar(val: 3)).description))
        let result = try encrypted.transform(transforms: transforms, keyProvider: fetcher)
        #expect(result != nil)

        let charlieVal = try result!.node!.get(key: "charlie")
        #expect(charlieVal != nil)
        #expect(charlieVal!.encryptionInfo == nil)

        let aliceVal = try result!.node!.get(key: "alice")
        #expect(aliceVal != nil)
        #expect(aliceVal!.encryptionInfo != nil)
    }

    @Test("Encrypted RadixHeader preserved through child mutation")
    func testRadixHeaderEncryptionPreserved() throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .list(key))
        let encrypted = try header.encrypt(encryption: encryption)

        for (_, child) in encrypted.node!.children {
            #expect(child.encryptionInfo != nil)
        }

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .delete)
        let result = try encrypted.transform(transforms: transforms, keyProvider: fetcher)
        #expect(result != nil)

        for (_, child) in result!.node!.children {
            #expect(child.encryptionInfo != nil)
        }
    }

    @Test("Transform + store + resolve round-trip on encrypted data")
    func testTransformStoreResolveRoundTrip() async throws {
        let key = SymmetricKey(size: .bits256)
        let fetcher = TestKeyProvidingStoreFetcher()
        fetcher.registerKey(key)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "bob", value: try HeaderImpl(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .delete)
        let transformed = try encrypted.transform(transforms: transforms, keyProvider: fetcher)!

        try await transformed.storeAsVolume(storer: fetcher)

        let resolved = try await transformed.removingNode().resolveRecursive(fetcher: fetcher)
        let bobVal = try resolved.node!.get(key: "bob")
        #expect(bobVal != nil)
        let bobResolved = try await bobVal!.resolve(fetcher: fetcher)
        #expect(bobResolved.node!.val == 2)
    }

    @Test("Transform without keyProvider strips encryption (backward compat)")
    func testTransformWithoutKeyProviderStripsEncryption() throws {
        let key = SymmetricKey(size: .bits256)

        var dict = DictType()
        dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["alice"], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let aliceBefore = try encrypted.node!.get(key: "alice")!
        #expect(aliceBefore.encryptionInfo != nil)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["bob"], value: .insert(try HeaderImpl<TestScalar>(node: TestScalar(val: 2)).description))
        let result = try encrypted.transform(transforms: transforms)

        #expect(result != nil)
        #expect(result!.encryptionInfo == nil)
    }
}

@Suite("Encryption Scenarios")
struct EncryptionScenarioTests {

    typealias ScalarHeader = HeaderImpl<TestScalar>
    typealias ScalarDict = MerkleDictionaryImpl<ScalarHeader>
    typealias AcceptanceInnerDict = MerkleDictionaryImpl<String>
    typealias AcceptanceOuterDict = MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>

    @Test("Multi-tenant: each tenant's data encrypted with own key, shared store")
    func testMultiTenantIsolation() async throws {
        let aliceKey = SymmetricKey(size: .bits256)
        let bobKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(aliceKey)
        store.registerKey(bobKey)

        let aliceData = try AcceptanceInnerDict()
            .inserting(key: "name", value: "Alice")
            .inserting(key: "email", value: "alice@example.com")
            .inserting(key: "ssn", value: "123-45-6789")
        let bobData = try AcceptanceInnerDict()
            .inserting(key: "name", value: "Bob")
            .inserting(key: "email", value: "bob@example.com")
            .inserting(key: "ssn", value: "987-65-4321")

        let aliceHeader = try HeaderImpl(node: aliceData, key: aliceKey)
        let bobHeader = try HeaderImpl(node: bobData, key: bobKey)

        var tenants = AcceptanceOuterDict()
        tenants = try tenants.inserting(key: "alice", value: aliceHeader)
        tenants = try tenants.inserting(key: "bob", value: bobHeader)
        let root = try HeaderImpl(node: tenants)

        try await root.storeAsVolume(storer: store)

        let resolved = try await root.removingNode().resolveRecursive(fetcher: store)
        let aliceResolved = try await resolved.node!.get(key: "alice")!.resolve(fetcher: store)
        #expect(try aliceResolved.node!.get(key: "ssn") == "123-45-6789")

        let bobResolved = try await resolved.node!.get(key: "bob")!.resolve(fetcher: store)
        #expect(try bobResolved.node!.get(key: "name") == "Bob")

        let aliceKeyData = aliceKey.withUnsafeBytes { Data($0) }
        let bobKeyData = bobKey.withUnsafeBytes { Data($0) }
        let aliceKeyHash = Data(SHA256.hash(data: aliceKeyData)).base64EncodedString()
        let bobKeyHash = Data(SHA256.hash(data: bobKeyData)).base64EncodedString()
        #expect(aliceResolved.encryptionInfo!.keyHash == aliceKeyHash)
        #expect(bobResolved.encryptionInfo!.keyHash == bobKeyHash)
        #expect(aliceResolved.encryptionInfo!.keyHash != bobResolved.encryptionInfo!.keyHash)
    }

    @Test("Multi-tenant: holder of one key cannot decrypt other tenant's data")
    func testMultiTenantKeyIsolation() async throws {
        let aliceKey = SymmetricKey(size: .bits256)
        let bobKey = SymmetricKey(size: .bits256)

        let fullStore = TestKeyProvidingStoreFetcher()
        fullStore.registerKey(aliceKey)
        fullStore.registerKey(bobKey)

        let aliceHeader = try ScalarHeader(node: TestScalar(val: 42), key: aliceKey)
        let bobHeader = try ScalarHeader(node: TestScalar(val: 99), key: bobKey)

        try await aliceHeader.storeAsVolume(storer: fullStore)
        try await bobHeader.storeAsVolume(storer: fullStore)

        let aliceOnlyStore = TestKeyProvidingStoreFetcher()
        aliceOnlyStore.registerKey(aliceKey)
        let aliceData = try await fullStore.fetch(rawCid: aliceHeader.rawCID)
        aliceOnlyStore.storeRaw(rawCid: aliceHeader.rawCID, data: aliceData)
        let bobData = try await fullStore.fetch(rawCid: bobHeader.rawCID)
        aliceOnlyStore.storeRaw(rawCid: bobHeader.rawCID, data: bobData)

        let aliceResolved = try await aliceHeader.removingNode().resolve(fetcher: aliceOnlyStore)
        #expect(aliceResolved.node!.val == 42)

        await #expect(throws: (any Error).self) {
            _ = try await bobHeader.removingNode().resolve(fetcher: aliceOnlyStore)
        }
    }

    @Test("Selective disclosure: public fields readable, private fields encrypted")
    func testSelectiveDisclosure() async throws {
        let privacyKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(privacyKey)

        var userProfile = ScalarDict()
        userProfile = try userProfile.inserting(key: "username", value: try ScalarHeader(node: TestScalar(val: 1001)))
        userProfile = try userProfile.inserting(key: "display_name", value: try ScalarHeader(node: TestScalar(val: 1002)))
        userProfile = try userProfile.inserting(key: "email", value: try ScalarHeader(node: TestScalar(val: 2001)))
        userProfile = try userProfile.inserting(key: "phone", value: try ScalarHeader(node: TestScalar(val: 2002)))
        userProfile = try userProfile.inserting(key: "address", value: try ScalarHeader(node: TestScalar(val: 2003)))
        let header = try HeaderImpl(node: userProfile)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["email"], value: .targeted(privacyKey))
        encryption.set(["phone"], value: .targeted(privacyKey))
        encryption.set(["address"], value: .targeted(privacyKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let publicUsername = try encrypted.node!.get(key: "username")!
        let publicDisplayName = try encrypted.node!.get(key: "display_name")!
        #expect(publicUsername.encryptionInfo == nil)
        #expect(publicDisplayName.encryptionInfo == nil)
        #expect(publicUsername.node!.val == 1001)

        let encEmail = try encrypted.node!.get(key: "email")!
        let encPhone = try encrypted.node!.get(key: "phone")!
        let encAddress = try encrypted.node!.get(key: "address")!
        #expect(encEmail.encryptionInfo != nil)
        #expect(encPhone.encryptionInfo != nil)
        #expect(encAddress.encryptionInfo != nil)

        try await encrypted.storeAsVolume(storer: store)
        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: store)
        let emailResolved = try await resolved.node!.get(key: "email")!.resolve(fetcher: store)
        #expect(emailResolved.node!.val == 2001)
    }

    @Test("Two-level nesting: inner values encrypted per-key, store and resolve all")
    func testTwoLevelNestedEncryption() async throws {
        let outerKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(outerKey)

        let departments = try AcceptanceInnerDict()
            .inserting(key: "engineering", value: "50 people")
            .inserting(key: "marketing", value: "20 people")
            .inserting(key: "sales", value: "30 people")
        let departmentHeader = try HeaderImpl(node: departments, key: outerKey)

        let budgets = try AcceptanceInnerDict()
            .inserting(key: "q1", value: "1000000")
            .inserting(key: "q2", value: "1200000")
        let budgetHeader = try HeaderImpl(node: budgets, key: outerKey)

        var company = MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>()
        company = try company.inserting(key: "departments", value: departmentHeader)
        company = try company.inserting(key: "budgets", value: budgetHeader)
        let root = try HeaderImpl(node: company)

        let deptVal = try root.node!.get(key: "departments")!
        #expect(deptVal.encryptionInfo != nil)
        let budgetVal = try root.node!.get(key: "budgets")!
        #expect(budgetVal.encryptionInfo != nil)

        try await root.storeAsVolume(storer: store)
        let resolved = try await root.removingNode().resolveRecursive(fetcher: store)
        let deptResolved = try await resolved.node!.get(key: "departments")!.resolve(fetcher: store)
        #expect(try deptResolved.node!.get(key: "engineering") == "50 people")
        #expect(try deptResolved.node!.get(key: "sales") == "30 people")

        let budgetResolved = try await resolved.node!.get(key: "budgets")!.resolve(fetcher: store)
        #expect(try budgetResolved.node!.get(key: "q1") == "1000000")
    }

    @Test("Two-level nesting: different keys per branch")
    func testTwoLevelDifferentKeysPerBranch() async throws {
        let publicKey = SymmetricKey(size: .bits256)
        let financeKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(publicKey)
        store.registerKey(financeKey)

        let publicInfo = try AcceptanceInnerDict()
            .inserting(key: "mission", value: "Build great software")
            .inserting(key: "founded", value: "2020")
        let publicHeader = try HeaderImpl(node: publicInfo, key: publicKey)

        let financeInfo = try AcceptanceInnerDict()
            .inserting(key: "revenue", value: "5000000")
            .inserting(key: "burn_rate", value: "200000")
        let financeHeader = try HeaderImpl(node: financeInfo, key: financeKey)

        var company = MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>()
        company = try company.inserting(key: "public", value: publicHeader)
        company = try company.inserting(key: "finance", value: financeHeader)
        let root = try HeaderImpl(node: company)

        let publicKeyData = publicKey.withUnsafeBytes { Data($0) }
        let financeKeyData = financeKey.withUnsafeBytes { Data($0) }
        let publicKeyHash = Data(SHA256.hash(data: publicKeyData)).base64EncodedString()
        let financeKeyHash = Data(SHA256.hash(data: financeKeyData)).base64EncodedString()

        let encPublic = try root.node!.get(key: "public")!
        let encFinance = try root.node!.get(key: "finance")!
        #expect(encPublic.encryptionInfo!.keyHash == publicKeyHash)
        #expect(encFinance.encryptionInfo!.keyHash == financeKeyHash)

        try await root.storeAsVolume(storer: store)
        let resolved = try await root.removingNode().resolveRecursive(fetcher: store)
        let pubResolved = try await resolved.node!.get(key: "public")!.resolve(fetcher: store)
        #expect(try pubResolved.node!.get(key: "mission") == "Build great software")
        let finResolved = try await resolved.node!.get(key: "finance")!.resolve(fetcher: store)
        #expect(try finResolved.node!.get(key: "revenue") == "5000000")
    }

    @Test("Full lifecycle: recursive encrypt, delete, store, resolve")
    func testFullLifecycleDeleteFromEncrypted() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "alice", value: try ScalarHeader(node: TestScalar(val: 10)))
        dict = try dict.inserting(key: "bob", value: try ScalarHeader(node: TestScalar(val: 20)))
        dict = try dict.inserting(key: "charlie", value: try ScalarHeader(node: TestScalar(val: 30)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        let aliceVal = try encrypted.node!.get(key: "alice")!
        #expect(aliceVal.encryptionInfo != nil)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .delete)
        let transformed = try encrypted.transform(transforms: transforms, keyProvider: store)!

        #expect(transformed.node!.count == 2)
        #expect(try transformed.node!.get(key: "alice") == nil)

        let bobVal = try transformed.node!.get(key: "bob")!
        #expect(bobVal.encryptionInfo != nil)

        try await transformed.storeAsVolume(storer: store)

        let resolved = try await transformed.removingNode().resolveRecursive(fetcher: store)
        let bobResolved = try await resolved.node!.get(key: "bob")!.resolve(fetcher: store)
        #expect(bobResolved.node!.val == 20)

        let charlieResolved = try await resolved.node!.get(key: "charlie")!.resolve(fetcher: store)
        #expect(charlieResolved.node!.val == 30)
    }

    @Test("Full lifecycle: encrypt values directly, mutate dict, store, resolve")
    func testFullLifecycleDirectMutate() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "counter", value: try ScalarHeader(node: TestScalar(val: 0), key: key))
        dict = try dict.inserting(key: "label", value: try ScalarHeader(node: TestScalar(val: 100), key: key))
        let header = try HeaderImpl(node: dict)

        try await header.storeAsVolume(storer: store)

        let newCounter = try ScalarHeader(node: TestScalar(val: 42), key: key)
        let mutated = try dict.mutating(key: "counter", value: newCounter)
        let mutatedHeader = try HeaderImpl(node: mutated)
        try await mutatedHeader.storeAsVolume(storer: store)

        let resolved = try await mutatedHeader.removingNode().resolveRecursive(fetcher: store)
        let counterResolved = try await resolved.node!.get(key: "counter")!.resolve(fetcher: store)
        #expect(counterResolved.node!.val == 42)

        let labelResolved = try await resolved.node!.get(key: "label")!.resolve(fetcher: store)
        #expect(labelResolved.node!.val == 100)
    }

    @Test("Full lifecycle: encrypt, insert new encrypted value, store, resolve")
    func testFullLifecycleInsertEncryptedValue() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "existing", value: try ScalarHeader(node: TestScalar(val: 1), key: key))
        let header = try HeaderImpl(node: dict)

        let newVal = try ScalarHeader(node: TestScalar(val: 99), key: key)
        let withInsert = try dict.inserting(key: "added", value: newVal)
        let insertedHeader = try HeaderImpl(node: withInsert)

        let addedVal = try insertedHeader.node!.get(key: "added")!
        #expect(addedVal.encryptionInfo != nil)

        try await insertedHeader.storeAsVolume(storer: store)
        let resolved = try await insertedHeader.removingNode().resolveRecursive(fetcher: store)
        let addedResolved = try await resolved.node!.get(key: "added")!.resolve(fetcher: store)
        #expect(addedResolved.node!.val == 99)

        let existingResolved = try await resolved.node!.get(key: "existing")!.resolve(fetcher: store)
        #expect(existingResolved.node!.val == 1)
    }

    @Test("Multiple sequential transforms preserve encryption on values")
    func testRepeatedTransformsPreserveEncryption() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        for i in 1...5 {
            dict = try dict.inserting(key: "item\(i)", value: try ScalarHeader(node: TestScalar(val: i)))
        }
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        var current = try header.encrypt(encryption: encryption)

        for (_, child) in current.node!.children {
            #expect(child.encryptionInfo != nil)
        }

        var transforms1 = ArrayTrie<Transform>()
        transforms1.set(["item1"], value: .delete)
        current = try current.transform(transforms: transforms1, keyProvider: store)!
        #expect(current.node!.count == 4)
        let item2After1 = try current.node!.get(key: "item2")!
        #expect(item2After1.encryptionInfo != nil)

        let newItem3 = try ScalarHeader(node: TestScalar(val: 300))
        try await newItem3.storeAsVolume(storer: store)
        var transforms2 = ArrayTrie<Transform>()
        transforms2.set(["item3"], value: .update(newItem3.description))
        current = try current.transform(transforms: transforms2, keyProvider: store)!
        #expect(current.node!.count == 4)

        current = try await current.resolveRecursive(fetcher: store)
        try await current.storeAsVolume(storer: store)
        let resolved = try await current.removingNode().resolveRecursive(fetcher: store)

        #expect(try resolved.node!.get(key: "item1") == nil)
        let item2 = try await resolved.node!.get(key: "item2")!.resolve(fetcher: store)
        #expect(item2.node!.val == 2)
        let item3 = try await resolved.node!.get(key: "item3")!.resolve(fetcher: store)
        #expect(item3.node!.val == 300)
    }

    @Test("50-key encrypted dictionary: full encrypt, store, resolve cycle")
    func testLargeEncryptedDictionary() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        for i in 0..<50 {
            dict = try dict.inserting(
                key: "record_\(String(format: "%03d", i))",
                value: try ScalarHeader(node: TestScalar(val: i * 7))
            )
        }
        #expect(dict.count == 50)
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        try await encrypted.storeAsVolume(storer: store)

        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: store)
        #expect(resolved.node!.count == 50)

        for i in [0, 10, 25, 40, 49] {
            let k = "record_\(String(format: "%03d", i))"
            let val = try resolved.node!.get(key: k)!
            #expect(val.encryptionInfo != nil)
            let valResolved = try await val.resolve(fetcher: store)
            #expect(valResolved.node!.val == i * 7)
        }
    }

    @Test("50-key encrypted dictionary: delete subset, store, resolve survivors")
    func testLargeEncryptedDictDeleteSubset() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        for i in 0..<50 {
            dict = try dict.inserting(
                key: "r\(String(format: "%03d", i))",
                value: try ScalarHeader(node: TestScalar(val: i))
            )
        }
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        for i in stride(from: 0, to: 50, by: 5) {
            transforms.set(["r\(String(format: "%03d", i))"], value: .delete)
        }

        let result = try encrypted.transform(transforms: transforms, keyProvider: store)!
        #expect(result.node!.count == 40)

        try await result.storeAsVolume(storer: store)
        let resolved = try await result.removingNode().resolveRecursive(fetcher: store)

        #expect(try resolved.node!.get(key: "r000") == nil)
        #expect(try resolved.node!.get(key: "r005") == nil)

        let r001 = try await resolved.node!.get(key: "r001")!.resolve(fetcher: store)
        #expect(r001.node!.val == 1)
        let r049 = try await resolved.node!.get(key: "r049")!.resolve(fetcher: store)
        #expect(r049.node!.val == 49)
    }

    @Test("Encrypted header description round-trips through store/resolve")
    func testEncryptedDescriptionRoundTrip() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        let scalar = TestScalar(val: 777)
        let encrypted = try ScalarHeader(node: scalar, key: key)
        try await encrypted.storeAsVolume(storer: store)

        let description = encrypted.description
        #expect(description.hasPrefix("enc:"))

        let restored = ScalarHeader(description)!
        #expect(restored.rawCID == encrypted.rawCID)
        #expect(restored.encryptionInfo == encrypted.encryptionInfo)
        #expect(restored.node == nil)

        let resolved = try await restored.resolve(fetcher: store)
        #expect(resolved.node!.val == 777)
    }

    @Test("Encrypted nested dict headers serialize/deserialize correctly within parent")
    func testEncryptedNestedSerialization() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        let inner = try AcceptanceInnerDict()
            .inserting(key: "a", value: "1")
            .inserting(key: "b", value: "2")
        let innerEncrypted = try HeaderImpl(node: inner, key: key)

        var outer = AcceptanceOuterDict()
        outer = try outer.inserting(key: "encrypted_child", value: innerEncrypted)
        outer = try outer.inserting(key: "plain_child", value: try HeaderImpl(node: try AcceptanceInnerDict().inserting(key: "c", value: "3")))
        let root = try HeaderImpl(node: outer)

        try await root.storeAsVolume(storer: store)

        let resolved = try await root.removingNode().resolveRecursive(fetcher: store)

        let encChild = try resolved.node!.get(key: "encrypted_child")!
        #expect(encChild.encryptionInfo != nil)
        let encChildResolved = try await encChild.resolve(fetcher: store)
        #expect(try encChildResolved.node!.get(key: "a") == "1")

        let plainChild = try resolved.node!.get(key: "plain_child")!
        #expect(plainChild.encryptionInfo == nil)
        let plainChildResolved = try await plainChild.resolve(fetcher: store)
        #expect(try plainChildResolved.node!.get(key: "c") == "3")
    }

    @Test("Mixed strategies: targeted encryption on specific fields, rest plaintext")
    func testMixedStrategiesOnSameTree() async throws {
        let targetKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(targetKey)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "public_a", value: try ScalarHeader(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "public_b", value: try ScalarHeader(node: TestScalar(val: 2)))
        dict = try dict.inserting(key: "secret_x", value: try ScalarHeader(node: TestScalar(val: 100)))
        dict = try dict.inserting(key: "secret_y", value: try ScalarHeader(node: TestScalar(val: 200)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["secret_x"], value: .targeted(targetKey))
        encryption.set(["secret_y"], value: .targeted(targetKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let pubA = try encrypted.node!.get(key: "public_a")!
        #expect(pubA.encryptionInfo == nil)
        #expect(pubA.node!.val == 1)

        let secX = try encrypted.node!.get(key: "secret_x")!
        #expect(secX.encryptionInfo != nil)

        try await encrypted.storeAsVolume(storer: store)
        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: store)
        let secXResolved = try await resolved.node!.get(key: "secret_x")!.resolve(fetcher: store)
        #expect(secXResolved.node!.val == 100)
    }

    @Test("Encryption preserves correctness with keys sharing common prefixes")
    func testEncryptionWithSharedPrefixKeys() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "user", value: try ScalarHeader(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "username", value: try ScalarHeader(node: TestScalar(val: 2)))
        dict = try dict.inserting(key: "user_profile", value: try ScalarHeader(node: TestScalar(val: 3)))
        dict = try dict.inserting(key: "user_settings", value: try ScalarHeader(node: TestScalar(val: 4)))
        dict = try dict.inserting(key: "user_settings_theme", value: try ScalarHeader(node: TestScalar(val: 5)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        for k in ["user", "username", "user_profile", "user_settings", "user_settings_theme"] {
            let val = try encrypted.node!.get(key: k)
            #expect(val != nil)
            #expect(val!.encryptionInfo != nil)
        }

        try await encrypted.storeAsVolume(storer: store)
        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: store)

        for (k, expected) in [("user", 1), ("username", 2), ("user_profile", 3), ("user_settings", 4), ("user_settings_theme", 5)] {
            let val = try await resolved.node!.get(key: k)!.resolve(fetcher: store)
            #expect(val.node!.val == expected)
        }
    }

    @Test("Auditor can enumerate keys and verify CIDs without decryption (targeted)")
    func testAuditabilityWithoutKeys() throws {
        let key = SymmetricKey(size: .bits256)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "record1", value: try ScalarHeader(node: TestScalar(val: 100)))
        dict = try dict.inserting(key: "record2", value: try ScalarHeader(node: TestScalar(val: 200)))
        dict = try dict.inserting(key: "record3", value: try ScalarHeader(node: TestScalar(val: 300)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set(["record1"], value: .targeted(key))
        encryption.set(["record2"], value: .targeted(key))
        encryption.set(["record3"], value: .targeted(key))
        let encrypted = try header.encrypt(encryption: encryption)

        #expect(encrypted.node!.count == 3)

        let record1 = try encrypted.node!.get(key: "record1")!
        #expect(record1.encryptionInfo != nil)
        #expect(record1.rawCID.isEmpty == false)

        let record2 = try encrypted.node!.get(key: "record2")!
        #expect(record2.rawCID != record1.rawCID)

        let keys = try encrypted.node!.allKeys()
        #expect(keys.count == 3)
        #expect(keys.contains("record1"))
        #expect(keys.contains("record2"))
        #expect(keys.contains("record3"))
    }

    @Test("Re-encrypting same data produces different CIDs (random IV)")
    func testReEncryptionProducesDifferentCIDs() throws {
        let key = SymmetricKey(size: .bits256)
        let scalar = TestScalar(val: 42)

        let enc1 = try ScalarHeader(node: scalar, key: key)
        let enc2 = try ScalarHeader(node: scalar, key: key)

        #expect(enc1.rawCID != enc2.rawCID)
        #expect(enc1.encryptionInfo!.keyHash == enc2.encryptionInfo!.keyHash)
        #expect(enc1.encryptionInfo!.iv != enc2.encryptionInfo!.iv)
    }

    @Test("Single-entry encrypted dict: delete only entry via recursive encrypt")
    func testSingleEntryEncryptedDelete() throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "only", value: try ScalarHeader(node: TestScalar(val: 42)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let encrypted = try header.encrypt(encryption: encryption)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["only"], value: .delete)
        let result = try encrypted.transform(transforms: transforms, keyProvider: store)!

        #expect(result.node!.count == 0)
    }

    @Test("Single-entry dict: encrypt value directly, mutate, store, resolve")
    func testSingleEntryEncryptedMutateStoreResolve() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "only", value: try ScalarHeader(node: TestScalar(val: 1), key: key))
        let header = try HeaderImpl(node: dict)

        let onlyBefore = try header.node!.get(key: "only")!
        #expect(onlyBefore.encryptionInfo != nil)

        let newVal = try ScalarHeader(node: TestScalar(val: 999), key: key)
        let mutated = try dict.mutating(key: "only", value: newVal)
        let mutatedHeader = try HeaderImpl(node: mutated)

        try await mutatedHeader.storeAsVolume(storer: store)

        let resolved = try await mutatedHeader.removingNode().resolveRecursive(fetcher: store)
        let onlyResolved = try await resolved.node!.get(key: "only")!.resolve(fetcher: store)
        #expect(onlyResolved.node!.val == 999)
    }

    @Test("Plaintext operations still work identically without encryption")
    func testPlaintextBackwardCompatibility() async throws {
        let store = TestKeyProvidingStoreFetcher()

        var dict = ScalarDict()
        dict = try dict.inserting(key: "a", value: try ScalarHeader(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "b", value: try ScalarHeader(node: TestScalar(val: 2)))
        let header = try HeaderImpl(node: dict)

        try await header.storeAsVolume(storer: store)

        let resolved = try await header.removingNode().resolveRecursive(fetcher: store)
        #expect(resolved.node!.count == 2)
        let aResolved = try await resolved.node!.get(key: "a")!.resolve(fetcher: store)
        #expect(aResolved.node!.val == 1)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["c"], value: .insert(try ScalarHeader(node: TestScalar(val: 3)).description))
        let transformed = try header.transform(transforms: transforms)!
        #expect(transformed.encryptionInfo == nil)
        #expect(transformed.node!.count == 3)
    }

    @Test("Three-level nesting: encrypted values at each level, store, resolve all")
    func testThreeLevelNestedEncryption() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        let leaf1 = try AcceptanceInnerDict()
            .inserting(key: "color", value: "red")
            .inserting(key: "size", value: "large")
        let leaf2 = try AcceptanceInnerDict()
            .inserting(key: "color", value: "blue")
            .inserting(key: "weight", value: "10kg")

        let mid = try MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>()
            .inserting(key: "itemA", value: try HeaderImpl(node: leaf1, key: key))
            .inserting(key: "itemB", value: try HeaderImpl(node: leaf2, key: key))

        let top = try MerkleDictionaryImpl<HeaderImpl<MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>>>()
            .inserting(key: "warehouse", value: try HeaderImpl(node: mid, key: key))

        let root = try HeaderImpl(node: top)

        let warehouseVal = try root.node!.get(key: "warehouse")!
        #expect(warehouseVal.encryptionInfo != nil)

        try await root.storeAsVolume(storer: store)

        let resolved = try await root.removingNode().resolveRecursive(fetcher: store)
        let warehouseResolved = try await resolved.node!.get(key: "warehouse")!.resolve(fetcher: store)
        let itemAResolved = try await warehouseResolved.node!.get(key: "itemA")!.resolve(fetcher: store)
        #expect(try itemAResolved.node!.get(key: "color") == "red")
        #expect(try itemAResolved.node!.get(key: "size") == "large")

        let itemBResolved = try await warehouseResolved.node!.get(key: "itemB")!.resolve(fetcher: store)
        #expect(try itemBResolved.node!.get(key: "weight") == "10kg")
    }

    @Test("Three-level nesting: different keys at different levels")
    func testThreeLevelDifferentKeysPerLevel() async throws {
        let outerKey = SymmetricKey(size: .bits256)
        let leafKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(outerKey)
        store.registerKey(leafKey)

        let leaf = try AcceptanceInnerDict()
            .inserting(key: "secret", value: "classified")

        let mid = try MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>()
            .inserting(key: "data", value: try HeaderImpl(node: leaf, key: leafKey))

        var outer = MerkleDictionaryImpl<HeaderImpl<MerkleDictionaryImpl<HeaderImpl<AcceptanceInnerDict>>>>()
        outer = try outer.inserting(key: "branch", value: try HeaderImpl(node: mid, key: outerKey))
        let root = try HeaderImpl(node: outer)

        let branchVal = try root.node!.get(key: "branch")!
        #expect(branchVal.encryptionInfo != nil)

        let outerKeyData = outerKey.withUnsafeBytes { Data($0) }
        let outerKeyHash = Data(SHA256.hash(data: outerKeyData)).base64EncodedString()
        #expect(branchVal.encryptionInfo!.keyHash == outerKeyHash)

        try await root.storeAsVolume(storer: store)
        let resolved = try await root.removingNode().resolveRecursive(fetcher: store)
        let branchResolved = try await resolved.node!.get(key: "branch")!.resolve(fetcher: store)
        let dataVal = try branchResolved.node!.get(key: "data")!

        let leafKeyData = leafKey.withUnsafeBytes { Data($0) }
        let leafKeyHash = Data(SHA256.hash(data: leafKeyData)).base64EncodedString()
        #expect(dataVal.encryptionInfo!.keyHash == leafKeyHash)

        let dataResolved = try await dataVal.resolve(fetcher: store)
        #expect(try dataResolved.node!.get(key: "secret") == "classified")
    }

    @Test("Recursive encryption with per-user key overrides")
    func testRecursiveWithPerUserOverrides() async throws {
        let teamKey = SymmetricKey(size: .bits256)
        let aliceKey = SymmetricKey(size: .bits256)
        let bobKey = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(teamKey)
        store.registerKey(aliceKey)
        store.registerKey(bobKey)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "alice", value: try ScalarHeader(node: TestScalar(val: 10)))
        dict = try dict.inserting(key: "bob", value: try ScalarHeader(node: TestScalar(val: 20)))
        dict = try dict.inserting(key: "shared", value: try ScalarHeader(node: TestScalar(val: 30)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(teamKey))
        encryption.set(["alice"], value: .recursive(aliceKey))
        encryption.set(["bob"], value: .recursive(bobKey))
        let encrypted = try header.encrypt(encryption: encryption)

        let aliceKeyData = aliceKey.withUnsafeBytes { Data($0) }
        let aliceKeyHash = Data(SHA256.hash(data: aliceKeyData)).base64EncodedString()
        let bobKeyData = bobKey.withUnsafeBytes { Data($0) }
        let bobKeyHash = Data(SHA256.hash(data: bobKeyData)).base64EncodedString()
        let teamKeyData = teamKey.withUnsafeBytes { Data($0) }
        let teamKeyHash = Data(SHA256.hash(data: teamKeyData)).base64EncodedString()

        let aliceVal = try encrypted.node!.get(key: "alice")!
        #expect(aliceVal.encryptionInfo!.keyHash == aliceKeyHash)
        let bobVal = try encrypted.node!.get(key: "bob")!
        #expect(bobVal.encryptionInfo!.keyHash == bobKeyHash)
        let sharedVal = try encrypted.node!.get(key: "shared")!
        #expect(sharedVal.encryptionInfo!.keyHash == teamKeyHash)

        try await encrypted.storeAsVolume(storer: store)
        let resolved = try await encrypted.removingNode().resolveRecursive(fetcher: store)

        let aliceResolved = try await resolved.node!.get(key: "alice")!.resolve(fetcher: store)
        #expect(aliceResolved.node!.val == 10)
        let bobResolved = try await resolved.node!.get(key: "bob")!.resolve(fetcher: store)
        #expect(bobResolved.node!.val == 20)
        let sharedResolved = try await resolved.node!.get(key: "shared")!.resolve(fetcher: store)
        #expect(sharedResolved.node!.val == 30)
    }

    @Test("List-encrypted dict: transform preserves RadixHeader encryption")
    func testListEncryptionPreservedThroughTransform() throws {
        let key = SymmetricKey(size: .bits256)
        let store = TestKeyProvidingStoreFetcher()
        store.registerKey(key)

        var dict = ScalarDict()
        dict = try dict.inserting(key: "alpha", value: try ScalarHeader(node: TestScalar(val: 1)))
        dict = try dict.inserting(key: "beta", value: try ScalarHeader(node: TestScalar(val: 2)))
        dict = try dict.inserting(key: "gamma", value: try ScalarHeader(node: TestScalar(val: 3)))
        let header = try HeaderImpl(node: dict)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .list(key))
        let encrypted = try header.encrypt(encryption: encryption)

        for (_, child) in encrypted.node!.children {
            #expect(child.encryptionInfo != nil)
        }

        var transforms = ArrayTrie<Transform>()
        transforms.set(["alpha"], value: .delete)
        let transformed = try encrypted.transform(transforms: transforms, keyProvider: store)!

        for (_, child) in transformed.node!.children {
            #expect(child.encryptionInfo != nil)
        }

        #expect(transformed.node!.count == 2)
        #expect(try transformed.node!.get(key: "alpha") == nil)

        let betaVal = try transformed.node!.get(key: "beta")!
        #expect(betaVal.encryptionInfo == nil)
        #expect(betaVal.node!.val == 2)
    }

    @Test("Same plaintext encrypted twice produces different CIDs (no dedup)")
    func testNoDeduplicationWithEncryption() throws {
        let key = SymmetricKey(size: .bits256)

        var dict1 = ScalarDict()
        dict1 = try dict1.inserting(key: "x", value: try ScalarHeader(node: TestScalar(val: 1)))
        var dict2 = ScalarDict()
        dict2 = try dict2.inserting(key: "x", value: try ScalarHeader(node: TestScalar(val: 1)))

        let plain1 = try HeaderImpl(node: dict1)
        let plain2 = try HeaderImpl(node: dict2)
        #expect(plain1.rawCID == plain2.rawCID)

        var encryption = ArrayTrie<EncryptionStrategy>()
        encryption.set([""], value: .recursive(key))
        let enc1 = try plain1.encrypt(encryption: encryption)
        let enc2 = try plain2.encrypt(encryption: encryption)

        let val1 = try enc1.node!.get(key: "x")!
        let val2 = try enc2.node!.get(key: "x")!
        #expect(val1.rawCID != val2.rawCID)
        #expect(val1.encryptionInfo!.keyHash == val2.encryptionInfo!.keyHash)
    }

    @Test("Resolve encrypted data with wrong key throws")
    func testResolveWithWrongKeyThrows() async throws {
        let correctKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)

        let correctStore = TestKeyProvidingStoreFetcher()
        correctStore.registerKey(correctKey)

        let scalar = TestScalar(val: 42)
        let encrypted = try ScalarHeader(node: scalar, key: correctKey)
        try await encrypted.storeAsVolume(storer: correctStore)

        let wrongStore = TestKeyProvidingStoreFetcher()
        wrongStore.registerKey(wrongKey)
        let encData = try await correctStore.fetch(rawCid: encrypted.rawCID)
        wrongStore.storeRaw(rawCid: encrypted.rawCID, data: encData)

        let cidOnly = ScalarHeader(
            rawCID: encrypted.rawCID,
            node: nil,
            encryptionInfo: encrypted.encryptionInfo
        )
        await #expect(throws: (any Error).self) {
            _ = try await cidOnly.resolve(fetcher: wrongStore)
        }
    }

    @Test("Store encrypted data without KeyProvider throws")
    func testStoreWithoutKeyProviderThrows() async throws {
        let key = SymmetricKey(size: .bits256)
        let encrypted = try ScalarHeader(node: TestScalar(val: 42), key: key)

        let plainStore = TestStoreFetcher()
        await #expect(throws: DataErrors.self) {
            try await encrypted.storeAsVolume(storer: plainStore)
        }
    }
}


@Test("DEBUG: Trace alice storage")
func debugAliceStorage() async throws {
    let key = SymmetricKey(size: .bits256)
    let fetcher = TestKeyProvidingStoreFetcher()
    fetcher.registerKey(key)
    
    typealias DT = MerkleDictionaryImpl<HeaderImpl<TestScalar>>
    var dict = DT()
    dict = try dict.inserting(key: "alice", value: try HeaderImpl(node: TestScalar(val: 1)))
    let header = try HeaderImpl(node: dict)
    
    var enc = ArrayTrie<EncryptionStrategy>()
    enc.set([""], value: .targeted(key))
    let encrypted = try header.encrypt(encryption: enc)
    
    // Get alice's header BEFORE store
    let encNode = encrypted.node!
    let aliceHeader = try encNode.get(key: "alice")!
    print("alice rawCID:", aliceHeader.rawCID)
    print("alice encryptionInfo:", (aliceHeader as? HeaderImpl<TestScalar>)?.encryptionInfo != nil)
    
    try await encrypted.storeAsVolume(storer: fetcher)
    
    // Check what's stored at alice's CID
    let aliceCID = aliceHeader.rawCID
    if let storedData = try? await fetcher.fetch(rawCid: aliceCID) {
        print("Stored at alice CID: \(storedData.count) bytes")
        // Try to decode as plain TestScalar
        if let plain = TestScalar(data: storedData) {
            print("Stored as PLAIN (encryption broken!): val=\(plain.val)")
        } else {
            print("Stored as encrypted (good — not plain decodable)")
            // Try to decrypt
            do {
                let dec = try EncryptionHelper.decrypt(data: storedData, key: key)
                print("Decrypted to \(dec.count) bytes")
                if let ts = TestScalar(data: dec) {
                    print("Decoded after decrypt: val=\(ts.val)")
                }
            } catch {
                print("Decrypt failed:", error)
            }
        }
    } else {
        print("alice CID NOT FOUND in storage!")
    }
}
