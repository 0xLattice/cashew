import Foundation
import Multicodec
import Multihash
import CID
import Crypto

/// Generic concrete implementation of ``Header``.
///
/// Wraps any ``Node`` type with a CID and optional encryption metadata.
/// The node is stored in a ``Box`` to allow the struct to remain `Sendable`
/// while holding a reference to the (potentially large) deserialized node.
///
/// ```swift
/// typealias UserHeader = HeaderImpl<UserNode>
/// let header = UserHeader(node: myUser)       // computes CID automatically
/// let lazy   = UserHeader(rawCID: someCID)    // node loaded on resolve
/// ```
public struct HeaderImpl<NodeType: Node>: Header {
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

extension HeaderImpl: Codable where NodeType: Codable {
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


/// Heap-allocated wrapper that lets value-type ``Header`` structs hold a
/// potentially large ``Node`` by reference, avoiding repeated copies.
public final class Box<T: Sendable>: Sendable {
   let boxed: T
   init(_ thingToBox: T) { boxed = thingToBox }
}

extension Box: Codable where T: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(boxed)
    }

    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(T.self)
        self.init(value)
    }
}
