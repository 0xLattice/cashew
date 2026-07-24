import Foundation
import ArrayTrie
import CID
import Multicodec
import Multihash
import Crypto

/// Return the single storage-key spelling for a CID. Invalid placeholders are
/// left unchanged; content verification still rejects them.
public func canonicalCIDIfValid(_ rawCID: String) -> String? {
    guard let cid = try? CID(rawCID),
          let canonical = try? CID(
            version: cid.version,
            codec: cid.codec,
            multihash: cid.multihash
          ) else { return nil }
    return canonical.toBaseEncodedString
}

public func canonicalCID(_ rawCID: String) -> String {
    canonicalCIDIfValid(rawCID) ?? rawCID
}

/// A content-addressed reference to a ``Node``.
///
/// A Header pairs a CID (content identifier) with an optionally-loaded node.
/// When `node` is nil the Header is a lazy reference that can be resolved via a
/// ``Fetcher``. When `node` is present the full data is available in memory.
///
/// **Minimal conformance** requires only the designated initializer and the
/// encrypted initializer — all other inits have default implementations:
/// ```swift
/// struct MyHeader: Header {
///     let rawCID: String
///     let node: MyNode?
///     init(rawCID: String, node: MyNode?, encryptionInfo: EncryptionInfo?) { ... }
///     init(node: MyNode, key: SymmetricKey) throws { ... }
/// }
/// ```
/// For most use cases, ``HeaderImpl`` is the ready-made concrete implementation.
public protocol Header: CashewQueryable, Codable, Sendable, LosslessStringConvertible {
    associatedtype NodeType: Node

    /// The content identifier for this node's serialized data.
    var rawCID: String { get }

    /// The deserialized node, or nil if not yet fetched.
    var node: NodeType? { get }

    /// Encryption metadata, or nil if the node is stored in plaintext.
    var encryptionInfo: EncryptionInfo? { get }

    init(rawCID: String)
    init(node: NodeType) throws
    init(node: NodeType, codec: Codecs) throws

    init(rawCID: String, node: NodeType?)
    /// Designated initializer. All other inits delegate to this one.
    init(rawCID: String, node: NodeType?, encryptionInfo: EncryptionInfo?)
    /// Creates an encrypted header by serializing and encrypting the node with the given key.
    init(node: NodeType, key: SymmetricKey) throws

    func resolve(paths: ArrayTrie<ResolutionStrategy>, fetcher: Fetcher) async throws -> Self
    func resolveRecursive(fetcher: Fetcher) async throws -> Self
    func resolve(fetcher: Fetcher) async throws -> Self
    func proof(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self
    func transform(transforms: ArrayTrie<Transform>) throws -> Self?
    func transform(transforms: ArrayTrie<Transform>, keyProvider: KeyProvider?) throws -> Self?
    func removingNode() -> Self
    func encrypt(encryption: ArrayTrie<EncryptionStrategy>) throws -> Self
    func encryptSelf(key: SymmetricKey) throws -> Self
}

public extension Header {
    var encryptionInfo: EncryptionInfo? { nil }

    init(rawCID: String) {
        self = Self(rawCID: rawCID, node: nil, encryptionInfo: nil)
    }

    init(rawCID: String, node: NodeType?) {
        self = Self(rawCID: rawCID, node: node, encryptionInfo: nil)
    }

    init(node: NodeType) throws {
        self = Self(rawCID: try Self.createSyncCID(for: node, codec: Self.defaultCodec), node: node, encryptionInfo: nil)
    }

    init(node: NodeType, codec: Codecs) throws {
        self = Self(rawCID: try Self.createSyncCID(for: node, codec: codec), node: node, encryptionInfo: nil)
    }

    static var defaultCodec: Codecs { .dag_cbor }

    static func create(node: NodeType, codec: Codecs = defaultCodec) async throws -> Self {
        let cid = try computeCID(for: node, codec: codec)
        return Self(rawCID: cid, node: node, encryptionInfo: nil)
    }

    private static func computeCID(for node: NodeType, codec: Codecs) throws -> String {
        guard let data = node.toData() else { throw DataErrors.serializationFailed }
        let multihash = try Multihash(raw: data, hashedWith: .sha2_256)
        let cid = try CID(version: .v1, codec: codec, multihash: multihash)
        return cid.toBaseEncodedString
    }

    static func createSyncCID(for node: NodeType, codec: Codecs) throws -> String {
        try computeCID(for: node, codec: codec)
    }

    static func serializeNode(_ node: NodeType, codec: Codecs) throws -> Data {
        guard let data = node.toData() else { throw DataErrors.serializationFailed }
        return data
    }

    func mapToData() throws -> Data {
        guard let node = self.node else { throw DataErrors.nodeNotAvailable }
        return try Self.serializeNode(node, codec: Self.defaultCodec)
    }

    func recreateCID() async throws -> String {
        guard let node = self.node else { return rawCID }
        return try Self.computeCID(for: node, codec: Self.defaultCodec)
    }

    func recreateCID(withCodec codec: Codecs) async throws -> String {
        guard let node = self.node else { throw DataErrors.nodeNotAvailable }
        return try Self.computeCID(for: node, codec: codec)
    }

    var description: String {
        if let info = encryptionInfo {
            return "enc:\(info.keyHash):\(info.iv):\(rawCID)"
        }
        return rawCID
    }

    init?(_ description: String) {
        if description.hasPrefix("enc:") {
            let remainder = description.dropFirst(4)
            let parts = remainder.split(separator: ":", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            let keyHash = String(parts[0])
            let iv = String(parts[1])
            let cid = String(parts[2])
            let info = EncryptionInfo(keyHash: keyHash, iv: iv)
            self = Self(rawCID: cid, node: nil, encryptionInfo: info)
        } else {
            self = Self(rawCID: description, node: nil, encryptionInfo: nil)
        }
    }

    func removingNode() -> Self {
        return Self(rawCID: rawCID, node: nil, encryptionInfo: encryptionInfo)
    }

    func encrypt(encryption: ArrayTrie<EncryptionStrategy>) throws -> Self {
        guard let node = node else { throw DataErrors.nodeNotAvailable }
        let encryptedNode = try node.encrypt(encryption: encryption)
        return try Self(node: encryptedNode)
    }

    func encryptSelf(key: SymmetricKey) throws -> Self {
        guard let node = node else { throw DataErrors.nodeNotAvailable }
        return try Self(node: node, key: key)
    }

    func fetchAndDecodeNode(fetcher: Fetcher) async throws -> NodeType {
        let fetchedData = try await fetcher.fetch(rawCid: rawCID)
        try verifyData(fetchedData, matches: rawCID)
        let decrypted = try decryptIfNeeded(data: fetchedData, fetcher: fetcher)
        guard let node = NodeType(data: decrypted) else { throw CashewDecodingError.decodeFromDataError }
        return node
    }

    func verifyData(_ data: Data, matches rawCID: String) throws {
        try verifyContentAddress(data, matches: rawCID)
    }

    func reEncryptIfNeeded(node: NodeType, keyProvider: KeyProvider?) throws -> Self {
        guard let info = encryptionInfo, let keyProvider = keyProvider else { return try Self(node: node) }
        guard let key = keyProvider.key(for: info.keyHash) else { throw DataErrors.keyNotFound }
        return try Self(node: node, key: key)
    }

    func transform(transforms: ArrayTrie<Transform>) throws -> Self? {
        return try transform(transforms: transforms, keyProvider: nil)
    }

    func transform(transforms: ArrayTrie<Transform>, keyProvider: KeyProvider?) throws -> Self? {
        if transforms.isEmpty { return self }
        guard let node = node else { throw DataErrors.nodeNotAvailable }
        guard let result = try node.transform(transforms: transforms, keyProvider: keyProvider) else { return nil }
        return try reEncryptIfNeeded(node: result, keyProvider: keyProvider)
    }

    func decryptIfNeeded(data: Data, fetcher: Fetcher) throws -> Data {
        guard let info = encryptionInfo else { return data }
        guard let keyProvider = fetcher as? KeyProvider else {
            throw DataErrors.keyNotFound
        }
        guard let key = keyProvider.key(for: info.keyHash) else {
            throw DataErrors.keyNotFound
        }
        return try EncryptionHelper.decrypt(data: data, key: key)
    }
}

func verifyContentAddress(_ data: Data, matches rawCID: String) throws {
    let expectedCID = try CID(rawCID)
    guard let hashAlgorithm = expectedCID.multihash.algorithm,
          let digestLength = expectedCID.multihash.length,
          digestLength > 0 else {
        throw DataErrors.cidCreationFailed
    }
    let actualMultihash = try Multihash(
        raw: data,
        hashedWith: hashAlgorithm,
        customByteLength: hashAlgorithm == .identity ? nil : digestLength
    )
    let actualCID = try CID(
        version: expectedCID.version,
        codec: expectedCID.codec,
        multihash: actualMultihash
    )
    guard actualCID == expectedCID else { throw DataErrors.cidMismatch }
}
