import ArrayTrie
import Foundation
import Multicodec

/// A content-addressed tree node in a Merkle data structure.
///
/// Nodes form the internal structure of Merkle tries. Each node can hold child
/// references (as ``Header`` values) and supports immutable updates via
/// copy-on-write semantics. Leaf nodes with no children conform via ``Scalar``.
///
/// **Minimal conformance** requires only three members:
/// ```swift
/// struct MyNode: Node {
///     func get(property: PathSegment) -> (any Header)? { ... }
///     func properties() -> Set<PathSegment> { ... }
///     func set(properties: [PathSegment: any Header]) -> Self { ... }
/// }
/// ```
/// All other methods (`resolve`, `transform`, `proof`, `encrypt`, `storeVolumes`)
/// have default implementations provided by protocol extensions.
/// `Codable` and `LosslessStringConvertible` are auto-synthesized from JSON serialization.
public protocol Node: CashewQueryable, Codable, LosslessStringConvertible, Sendable {
    typealias PathSegment = String

    /// Returns the child header at the given property key, or nil if absent.
    func get(property: PathSegment) -> (any Header)?

    /// Returns the set of all property keys that have children.
    func properties() -> Set<PathSegment>

    /// Returns a new node with the given properties replaced.
    func set(properties: [PathSegment: any Header]) -> Self

    func resolve(paths: ArrayTrie<ResolutionStrategy>, fetcher: Fetcher) async throws -> Self
    func storeVolumes(paths: ArrayTrie<StorageStrategy>, storer: any VolumeStorer) async throws
    func transform(transforms: ArrayTrie<Transform>) throws -> Self?
    func transform(transforms: ArrayTrie<Transform>, keyProvider: KeyProvider?) throws -> Self?
    func proof(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self
    func encrypt(encryption: ArrayTrie<EncryptionStrategy>) throws -> Self
}

private let sharedJSONDecoder = JSONDecoder()
private let sharedJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

public extension Node {
    init?(data: Data) {
       if let decoded = try? DagCBOR.decode(Self.self, from: data) {
           self = decoded
       } else if let decoded = try? sharedJSONDecoder.decode(Self.self, from: data) {
           self = decoded
       } else {
           return nil
       }
    }

    func toData() -> Data? {
        return try? DagCBOR.encode(self)
    }

    func toJSON() -> Data? {
        return try? sharedJSONEncoder.encode(self)
    }

    init?(_ description: String) {
        guard let data = description.data(using: .utf8) else { return nil }
        guard let newNode = Self(data: data) else { return nil }
        self = newNode
    }

    var description: String {
        guard let data = toJSON() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Node {
    @inline(__always)
    func compareSlices(_ slice1: ArraySlice<Character>, _ slice2: ArraySlice<Character>) -> Int {
        if (slice1.elementsEqual(slice2)) { return 0 }
        if (slice1.starts(with: slice2)) { return 1 }
        if (slice2.starts(with: slice1)) { return 2 }
        else { return 3 }
    }
    
    @inline(__always)
    func commonPrefixString(_ slice1: ArraySlice<Character>, _ slice2: ArraySlice<Character>) -> String {
        return commonPrefix(slice1, slice2)
    }
    
    func commonPrefix(_ slice1: ArraySlice<Character>, _ slice2: ArraySlice<Character>) -> String {
        let maxLength = min(slice1.count, slice2.count)
        var result = ""
        result.reserveCapacity(maxLength)
        
        let pairs = zip(slice1, slice2)
        for (char1, char2) in pairs {
            if char1 == char2 {
                result.append(char1)
            } else {
                break
            }
        }
        
        return result
    }
}
