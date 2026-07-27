import Foundation
import Multicodec
import Multihash
import CID
import Crypto

/// A storage and retention boundary in a content-addressed DAG.
///
/// A Volume has the same CID and resolution behavior as any other ``Header``.
/// Its distinct role is on the storage side: Cashew serializes the Volume root
/// plus all ordinary descendants up to the next Volume boundary as one complete
/// ``SerializedVolume``.
///
/// Volumes may be nested. The enclosing node commits to the nested Volume's CID,
/// while the nested Volume's bytes remain independently available, retainable, and
/// evictable. Storing an outer Volume does not store a separate relationship to the
/// nested Volume; that relationship remains encoded in the content-addressed node.
/// Volumes are persisted through ``VolumeStorer``.
///
/// ```swift
/// typealias UserVolume = VolumeImpl<MerkleDictionaryImpl<String>>
/// let volume = try UserVolume(node: users)
/// try await volume.storeRecursively(storer: volumeStore)
/// ```
public protocol Volume: Header { }

/// Default concrete implementation of ``Volume``.
public struct VolumeImpl<NodeType: Node>: Volume {
    public let rawCID: String
    public let rawNode: Box<NodeType>?
    public let encryptionInfo: EncryptionInfo?

    public var node: NodeType? {
        return rawNode?.boxed
    }

    public init(rawCID: String, node: NodeType?, encryptionInfo: EncryptionInfo?) {
        self.rawCID = canonicalCID(rawCID)
        self.rawNode = node.map { Box($0) }
        self.encryptionInfo = encryptionInfo
    }

    public init(node: NodeType, key: SymmetricKey) throws {
        let plaintext = try Self.serializeNode(node, codec: Self.defaultCodec)
        let (encrypted, iv) = try EncryptionHelper.encrypt(data: plaintext, key: key)
        let multihash = try Multihash(raw: encrypted, hashedWith: .sha2_256)
        let cid = try CID(version: .v1, codec: Self.defaultCodec, multihash: multihash)
        self.rawCID = cid.toBaseEncodedString
        self.rawNode = Box(node)
        self.encryptionInfo = EncryptionInfo(key: key, iv: iv)
    }
}

// MARK: - Codable
extension VolumeImpl: Codable where NodeType: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawCID, forKey: .rawCID)
        try container.encodeIfPresent(encryptionInfo, forKey: .encryptionInfo)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawCID = canonicalCID(try container.decode(String.self, forKey: .rawCID))
        encryptionInfo = try container.decodeIfPresent(EncryptionInfo.self, forKey: .encryptionInfo)
        rawNode = nil
    }

    private enum CodingKeys: String, CodingKey {
        case rawCID
        case encryptionInfo
    }
}
