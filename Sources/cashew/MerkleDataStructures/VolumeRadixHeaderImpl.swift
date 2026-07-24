import Foundation
import Multicodec
import Multihash
import CID
import Crypto

/// Default concrete implementation of ``VolumeRadixHeader``.
///
/// Structurally identical to ``RadixHeaderImpl`` but additionally conforms to
/// ``Volume``, so every trie-internal link is an independently addressable
/// Volume boundary (used for per-subtree retention/grouping on the store side).
public struct VolumeRadixHeaderImpl<Value>: VolumeRadixHeader
where Value: Codable, Value: Sendable, Value: LosslessStringConvertible {
    public typealias NodeType = VolumeRadixNodeImpl<Value>

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
extension VolumeRadixHeaderImpl: Codable {
    enum CodingKeys: String, CodingKey {
        case rawCID
        case encryptionInfo
    }

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
}
