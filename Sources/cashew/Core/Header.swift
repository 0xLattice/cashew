import Foundation
import ArrayTrie
import CID
import Multicodec
import Multihash
import Crypto

/// Returns the single storage-key spelling for a CID. Invalid placeholders are
/// left unchanged; content verification still rejects them.
func canonicalCID(_ rawCID: String) -> String {
    // Already the canonical text of a dag-cbor sha2-256 CID: the parse and
    // re-encode below would give back these exact bytes.
    if isCanonicalDagCBORSHA256CID(rawCID) { return rawCID }
    guard let cid = try? CID(rawCID),
          let canonical = try? CID(
            version: cid.version,
            codec: cid.codec,
            multihash: cid.multihash
          ) else { return rawCID }
    return cidText(canonical)
}

/// The text of a CID built by `CID(version:codec:multihash:)`, which gives a
/// v1 CID the base32 multibase: byte for byte `toBaseEncodedString`.
func cidText(_ cid: CID) -> String {
    cid.version == .v1 ? base32Multibase(cid.rawBuffer) : cid.toBaseEncodedString
}

private let base32Digits: StaticString = "abcdefghijklmnopqrstuvwxyz234567"

/// Multibase base32: "b", then RFC 4648 base32, lowercase and unpadded — the
/// text `CID.toBaseEncodedString` gives every v1 CID. Encoded here, straight
/// into the string's storage, because the library's encoder pads and then
/// strips the padding one character at a time.
func base32Multibase(_ bytes: [UInt8]) -> String {
    String(unsafeUninitializedCapacity: 1 + (bytes.count * 8 + 4) / 5) { out in
        let digits = base32Digits.utf8Start
        out[0] = UInt8(ascii: "b")
        var position = 1
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out[position] = digits[Int(buffer >> UInt32(bits) & 31)]
                position += 1
            }
        }
        if bits > 0 {
            out[position] = digits[Int(buffer << UInt32(5 - bits) & 31)]
            position += 1
        }
        return position
    }
}

/// Whether `text` is the canonical text of a CIDv1, dag-cbor, sha2-256 CID
/// with a 32-byte digest — "b", then the lowercase unpadded base32 of
/// `01 71 12 20` and the digest, with the two bits past the last byte zero.
/// No other text spells these bytes, and `canonicalCID` maps such text to
/// itself.
func isCanonicalDagCBORSHA256CID(_ text: String) -> Bool {
    var text = text
    return text.withUTF8 { utf8 in
        // "b" and 58 digits: 36 bytes is 288 bits, 2 short of 58 digits.
        guard utf8.count == 59, utf8[0] == UInt8(ascii: "b") else { return false }
        var buffer: UInt32 = 0
        var bits = 0
        var index = 0
        for position in 1..<59 {
            let character = utf8[position]
            let value: UInt32
            switch character {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(character &- UInt8(ascii: "a"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"): value = UInt32(character &- UInt8(ascii: "2")) &+ 26
            default: return false
            }
            buffer = buffer << 5 | value
            bits += 5
            guard bits >= 8 else { continue }
            bits -= 8
            if index < 4 {
                let byte = UInt8(truncatingIfNeeded: buffer >> UInt32(bits))
                let prefix: UInt8 = index == 0 ? 0x01 : index == 1 ? 0x71 : index == 2 ? 0x12 : 0x20
                guard byte == prefix else { return false }
            }
            index += 1
        }
        return index == 36 && bits == 2 && buffer & 0b11 == 0
    }
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
        return cidText(cid)
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

/// Only a full SHA-256 digest authenticates content: a weak or truncated
/// digest lets one CID name several byte strings, so different fetchers could
/// decode different nodes under the same reference.
func verifyContentAddress(_ data: Data, matches rawCID: String) throws {
    let expectedCID = try CID(rawCID)
    guard expectedCID.multihash.algorithm == .sha2_256,
          expectedCID.multihash.length == 32 else {
        throw DataErrors.cidCreationFailed
    }
    let actualMultihash = try Multihash(raw: data, hashedWith: .sha2_256)
    let actualCID = try CID(
        version: expectedCID.version,
        codec: expectedCID.codec,
        multihash: actualMultihash
    )
    guard actualCID == expectedCID else { throw DataErrors.cidMismatch }
}
