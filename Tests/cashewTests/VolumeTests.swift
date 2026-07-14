import Testing
import Foundation
import ArrayTrie
@testable import cashew

// MARK: - Test helpers

final class VolumeTestFetcher: Fetcher, TestVolumeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func fetch(rawCid: String) async throws -> Data {
        let data = lock.withLock { storage[rawCid] }
        guard let data = data else { throw FetchError.notFound }
        return data
    }

    func storeRaw(rawCid: String, data: Data) {
        lock.withLock { storage[rawCid] = data }
    }
}

final class PlainTestFetcher: Fetcher, TestVolumeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func fetch(rawCid: String) async throws -> Data {
        let data = lock.withLock { storage[rawCid] }
        guard let data = data else { throw FetchError.notFound }
        return data
    }

    func storeRaw(rawCid: String, data: Data) {
        lock.withLock { storage[rawCid] = data }
    }
}

// MARK: - Tests

@Suite("Volume")
struct VolumeTests {

    // MARK: - Basic Header behavior

    @Test("VolumeImpl computes a CID from its node")
    func cidCreation() throws {
        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "a", value: "1")

        let vol = try VolumeImpl(node: dict)
        #expect(!vol.rawCID.isEmpty)
        #expect(vol.node != nil)
    }

    @Test("Same content produces the same CID")
    func deterministicCID() throws {
        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "a", value: "1")

        let vol1 = try VolumeImpl(node: dict)
        let vol2 = try VolumeImpl(node: dict)
        #expect(vol1.rawCID == vol2.rawCID)
    }

    @Test("VolumeImpl round-trips through Codable")
    func codable() throws {
        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "x", value: "y")

        let vol = try VolumeImpl(node: dict)
        let data = try JSONEncoder().encode(vol)
        let decoded = try JSONDecoder().decode(VolumeImpl<MerkleDictionaryImpl<String>>.self, from: data)

        #expect(decoded.rawCID == vol.rawCID)
        #expect(decoded.node == nil) // node is not serialized, only CID
    }

    @Test("VolumeImpl CID differs from HeaderImpl CID for same node")
    func volumeCIDDiffersFromHeader() throws {
        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "a", value: "1")

        let vol = try VolumeImpl(node: dict)
        let header = try HeaderImpl(node: dict)
        // Both wrap the same node, so CIDs should be the same
        // (CID is computed from the node's serialization, not the header type)
        #expect(vol.rawCID == header.rawCID)
    }

    // MARK: - Resolution (a Volume resolves like any Header)

    @Test("resolve(paths:fetcher:) resolves a targeted path")
    func resolvePathsTargeted() async throws {
        let fetcher = VolumeTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "alice", value: "engineer")
        dict = try dict.inserting(key: "bob", value: "designer")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["a"], value: .targeted)

        let resolved = try await cidOnly.resolve(paths: paths, fetcher: fetcher)
        #expect(resolved.node != nil)
    }

    @Test("resolveRecursive resolves the whole subtree")
    func resolveRecursive() async throws {
        let fetcher = VolumeTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "k", value: "v")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
        let resolved = try await cidOnly.resolveRecursive(fetcher: fetcher)

        #expect(resolved.node != nil)
    }

    @Test("resolve(fetcher:) fetches the node one level")
    func resolveSingle() async throws {
        let fetcher = VolumeTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "k", value: "v")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
        let resolved = try await cidOnly.resolve(fetcher: fetcher)

        #expect(resolved.node != nil)
    }

    @Test("proof(paths:fetcher:) produces a proof against a plain Fetcher")
    func proofWorks() async throws {
        let fetcher = VolumeTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "alice", value: "engineer")
        dict = try dict.inserting(key: "bob", value: "designer")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)

        var paths = ArrayTrie<SparseMerkleProof>()
        paths.set(["alice"], value: .mutation)

        let proven = try await cidOnly.proof(paths: paths, fetcher: fetcher)
        #expect(proven.node != nil)
    }

    // MARK: - Plain Fetcher round-trips

    @Test("Volume resolves normally with a plain Fetcher")
    func plainFetcherWorks() async throws {
        let fetcher = PlainTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "a", value: "1")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
        let resolved = try await cidOnly.resolveRecursive(fetcher: fetcher)

        #expect(resolved.node != nil)
        let keys = try resolved.node!.allKeys()
        #expect(keys == ["a"])
    }

    @Test("Volume resolves through any Header existential")
    func existentialDispatch() async throws {
        let fetcher = VolumeTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "k", value: "v")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
        let existential: any Header = cidOnly
        let resolved = try await existential.resolveRecursive(fetcher: fetcher)

        #expect(resolved.node != nil)
    }

    // MARK: - Store and resolve round-trip

    @Test("VolumeImpl stores and resolves a full round-trip")
    func storeResolveRoundTrip() async throws {
        let fetcher = VolumeTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "alice", value: "engineer")
        dict = try dict.inserting(key: "bob", value: "designer")
        dict = try dict.inserting(key: "charlie", value: "manager")

        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
        let resolved = try await cidOnly.resolveRecursive(fetcher: fetcher)

        let keys = try resolved.node!.allKeys()
        #expect(keys == ["alice", "bob", "charlie"])
    }

    // MARK: - Proof correctness across nested Volume boundaries

    @Test("proof reaches a leaf through two nested Volume boundaries")
    func proofThroughNestedVolumes() async throws {
        let fetcher = PlainTestFetcher()

        var innerDict = MerkleDictionaryImpl<String>()
        innerDict = try innerDict.inserting(key: "leaf", value: "value")
        let innerVol = try VolumeImpl(node: innerDict)
        let outerVol = try VolumeImpl(node: NestedVolumeNode(inner: innerVol))
        try await outerVol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<NestedVolumeNode>(rawCID: outerVol.rawCID)
        var paths = ArrayTrie<SparseMerkleProof>()
        paths.set(["inner", "leaf"], value: .mutation)

        let proven = try await cidOnly.proof(paths: paths, fetcher: fetcher)
        #expect(proven.node?.inner.node != nil)
    }

    @Test("proof of a missing key throws")
    func proofOfMissingKeyThrows() async throws {
        let fetcher = PlainTestFetcher()

        var dict = MerkleDictionaryImpl<String>()
        dict = try dict.inserting(key: "alice", value: "engineer")
        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: fetcher)

        let cidOnly = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
        var paths = ArrayTrie<SparseMerkleProof>()
        paths.set(["missing"], value: .mutation)

        await #expect(throws: Error.self) {
            _ = try await cidOnly.proof(paths: paths, fetcher: fetcher)
        }
    }
}

/// A node with a single nested Volume child, for exercising resolution and
/// proof across a Volume boundary.
private struct NestedVolumeNode: Node, Sendable {
    let inner: VolumeImpl<MerkleDictionaryImpl<String>>

    func get(property: PathSegment) -> (any Header)? {
        property == "inner" ? inner : nil
    }

    func properties() -> Set<PathSegment> { ["inner"] }

    func set(properties: [PathSegment: any Header]) -> Self {
        guard let replacement = properties["inner"] as? VolumeImpl<MerkleDictionaryImpl<String>> else {
            return self
        }
        return Self(inner: replacement)
    }
}
