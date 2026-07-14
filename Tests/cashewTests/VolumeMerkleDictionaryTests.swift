import Testing
import Foundation
import ArrayTrie
@testable import cashew

/// Pins the central invariant of ``VolumeMerkleDictionaryImpl``: every header
/// reachable from the root is a ``Volume``. The pin-ledger model of GC — liveness
/// means "some chain's pin set references this Volume root" — only works if every
/// trie-internal link is itself a Volume boundary that can be pinned independently.
/// If a single internal header drops Volume conformance, its subtree becomes
/// inseparable from the nearest outer Volume and cannot be retained or evicted as
/// an independent unit. These tests would catch that.
@Suite("Volume Merkle Dictionary — all headers are Volumes")
struct VolumeMerkleDictionaryTests {

    typealias Dict = VolumeMerkleDictionaryImpl<String>

    // MARK: - Traversal helpers

    /// Walks every header reachable from a root dictionary and runs `visit` on
    /// each. Calls into `children` directly (no resolve) because the tests
    /// construct the trie in-memory — every node is already present.
    static func visitAllHeaders(
        in dict: Dict,
        visit: (any Header) throws -> Void
    ) throws {
        for (_, child) in dict.children {
            try visitHeader(child, visit: visit)
        }
    }

    static func visitHeader(
        _ header: VolumeRadixHeaderImpl<String>,
        visit: (any Header) throws -> Void
    ) throws {
        try visit(header)
        guard let node = header.node else {
            throw TestError.nodeMissing(cid: header.rawCID)
        }
        for (_, child) in node.children {
            try visitHeader(child, visit: visit)
        }
    }

    enum TestError: Error {
        case nodeMissing(cid: String)
    }

    // MARK: - The core invariant

    @Test("Every header in an inserted trie is a Volume (shallow, one key)")
    func shallowIsVolume() throws {
        let dict = try Dict().inserting(key: "alice", value: "v1")

        var count = 0
        try Self.visitAllHeaders(in: dict) { header in
            #expect(header is any Volume,
                    "header at CID \(header.rawCID) is not a Volume")
            count += 1
        }
        #expect(count >= 1, "expected at least one header in the trie")
    }

    @Test("Every header in a branched trie is a Volume")
    func branchedIsVolume() throws {
        // Two keys that share a common prefix force the radix trie to split
        // on the shared edge. Two keys with different leading chars force two
        // distinct top-level children. Together they produce a trie with
        // both branching and path compression — the most likely places for a
        // missing-Volume bug to hide.
        let dict = try Dict()
            .inserting(key: "alice", value: "v1")
            .inserting(key: "alicia", value: "v2")
            .inserting(key: "bob", value: "v3")
            .inserting(key: "carol", value: "v4")

        var count = 0
        try Self.visitAllHeaders(in: dict) { header in
            #expect(header is any Volume,
                    "header at CID \(header.rawCID) is not a Volume")
            count += 1
        }
        // Expect: 3 top-level children (a, b, c) + split under 'a' for alice/alicia.
        #expect(count >= 4,
                "expected at least 4 headers after inserting 4 keys with one shared prefix, got \(count)")
    }

    @Test("Every header in a deep trie is a Volume")
    func deepIsVolume() throws {
        // Build a trie deep enough to exercise many levels of recursion.
        var dict = Dict()
        for i in 0..<50 {
            dict = try dict.inserting(key: "key-\(i)", value: "v\(i)")
        }

        var count = 0
        try Self.visitAllHeaders(in: dict) { header in
            #expect(header is any Volume,
                    "header at CID \(header.rawCID) is not a Volume")
            count += 1
        }
        #expect(count > 0)
    }

    // MARK: - Outer wrapping

    @Test("VolumeImpl<VolumeMerkleDictionaryImpl> is itself a Volume, and every descendant header is a Volume")
    func wrappedRootIsVolume() throws {
        let dict = try Dict()
            .inserting(key: "alice", value: "v1")
            .inserting(key: "bob", value: "v2")

        let outer = try VolumeImpl(node: dict)
        #expect((outer as any Header) is any Volume)

        // Every child header inside is a Volume too.
        try Self.visitAllHeaders(in: outer.node!) { header in
            #expect(header is any Volume)
        }
    }

}

/// A node with both HeaderImpl (non-Volume) and VolumeImpl children.
/// Mimics Block's structure where `spec` is HeaderImpl and `frontier` is VolumeImpl.
private struct MixedNode: Node, Sendable {
    typealias Dict = VolumeMerkleDictionaryImpl<String>
    let label: HeaderImpl<Dict>
    let data: VolumeImpl<Dict>

    static let LABEL = "label"
    static let DATA = "data"

    func properties() -> Set<String> { [Self.LABEL, Self.DATA] }
    func get(property: String) -> (any Header)? {
        switch property {
        case Self.LABEL: return label
        case Self.DATA: return data
        default: return nil
        }
    }
    func set(properties: [String: any Header]) -> MixedNode {
        MixedNode(
            label: properties[Self.LABEL] as? HeaderImpl<Dict> ?? label,
            data: properties[Self.DATA] as? VolumeImpl<Dict> ?? data
        )
    }
}

// MARK: - Multi-level Volume hierarchy with custom nodes

/// A division of a company. Its `teams` are each their own Volume, so a
/// Division owning a Volume boundary nests a second layer of Volumes underneath.
private struct Division: Node, Sendable {
    var teams: [String: VolumeImpl<VolumeMerkleDictionaryImpl<String>>]

    init(teams: [String: VolumeImpl<VolumeMerkleDictionaryImpl<String>>] = [:]) {
        self.teams = teams
    }

    func properties() -> Set<String> { Set(teams.keys) }
    func get(property: String) -> (any Header)? { teams[property] }
    func set(properties: [String: any Header]) -> Division {
        var copy = self
        for (k, v) in properties {
            if let vol = v as? VolumeImpl<VolumeMerkleDictionaryImpl<String>> {
                copy.teams[k] = vol
            }
        }
        return copy
    }
}

/// A company holding several divisions. Each division is a Volume (second level),
/// and each division's teams are Volume-wrapped Volume-aware dictionaries
/// (third level), whose internal radix headers are also Volumes (fourth level).
private struct Company: Node, Sendable {
    var divisions: [String: VolumeImpl<Division>]

    init(divisions: [String: VolumeImpl<Division>] = [:]) {
        self.divisions = divisions
    }

    func properties() -> Set<String> { Set(divisions.keys) }
    func get(property: String) -> (any Header)? { divisions[property] }
    func set(properties: [String: any Header]) -> Company {
        var copy = self
        for (k, v) in properties {
            if let vol = v as? VolumeImpl<Division> {
                copy.divisions[k] = vol
            }
        }
        return copy
    }
}


// MARK: - Store → Fetch round-trip tests

/// A complete-Volume sink used by round-trip and proof tests.
private final class VolumeGroupingStore: VolumeStorer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var volumes: [String: [String: Data]] = [:]

    var providedRoots: [String] {
        lock.withLock { Array(volumes.keys) }
    }

    func store(volume: SerializedVolume) async throws {
        lock.withLock {
            volumes[volume.root] = volume.entries
        }
    }

    func allData() -> [String: Data] {
        lock.withLock {
            var all: [String: Data] = [:]
            for (_, entries) in volumes {
                for (cid, data) in entries {
                    all[cid] = data
                }
            }
            return all
        }
    }
}

/// Fetcher that serves from a VolumeGroupingStore's grouped volumes and records
/// which CIDs it was asked for (so proof-minimality tests can assert that
/// untouched branches were never fetched).
private final class VolumeGroupingFetcher: Fetcher, @unchecked Sendable {
    private let store: VolumeGroupingStore
    private let lock = NSLock()
    private(set) var fetchedCIDs: [String] = []

    init(store: VolumeGroupingStore) { self.store = store }

    func fetch(rawCid: String) async throws -> Data {
        lock.withLock { fetchedCIDs.append(rawCid) }
        guard let data = store.allData()[rawCid] else { throw FetchError.notFound }
        return data
    }
}

@Suite("Store → Fetch round-trip")
struct VolumeRoundTripTests {

    typealias Dict = VolumeMerkleDictionaryImpl<String>

    @Test("Store and resolve a single-key dictionary round-trips correctly")
    func singleKeyRoundTrip() async throws {
        let dict = try Dict().inserting(key: "alice", value: "v1")
        let outer = try VolumeImpl(node: dict)

        let store = VolumeGroupingStore()
        try await outer.storeRecursively(storer: store)

        #expect(!store.volumes.isEmpty, "storeRecursively should produce at least one volume")
        #expect(store.volumes[outer.rawCID] != nil, "outer Volume root should have its own volume group")

        let stripped = VolumeImpl<Dict>(rawCID: outer.rawCID, node: nil, encryptionInfo: nil)
        let fetcher = VolumeGroupingFetcher(store: store)
        let resolved = try await stripped.resolveRecursive(fetcher: fetcher)

        #expect(resolved.node != nil, "resolved node should not be nil")
        let value = try resolved.node?.get(key: "alice")
        #expect(value == "v1", "round-tripped value should match")
    }

    @Test("Store and resolve a branched dictionary round-trips all values")
    func branchedRoundTrip() async throws {
        let dict = try Dict()
            .inserting(key: "alice", value: "v1")
            .inserting(key: "alicia", value: "v2")
            .inserting(key: "bob", value: "v3")
        let outer = try VolumeImpl(node: dict)

        let store = VolumeGroupingStore()
        try await outer.storeRecursively(storer: store)

        #expect(store.volumes.count >= 2, "branched trie should produce multiple volume groups")

        let stripped = VolumeImpl<Dict>(rawCID: outer.rawCID, node: nil, encryptionInfo: nil)
        let fetcher = VolumeGroupingFetcher(store: store)
        let resolved = try await stripped.resolveRecursive(fetcher: fetcher)

        #expect(try resolved.node?.get(key: "alice") == "v1")
        #expect(try resolved.node?.get(key: "alicia") == "v2")
        #expect(try resolved.node?.get(key: "bob") == "v3")
    }

    @Test("Deletion proofs materialize collapse witnesses without recursive Volume availability")
    func deletionProofMaterializesCollapseWitnessWithoutRecursiveVolumeAvailability() async throws {
        let deletedKey = "bafyreidemander/500/1781"
        let survivingKey = "bafyreidemander/500/1782"
        try await expectDeletionProof(
            entries: [(deletedKey, "500"), (survivingKey, "500")],
            deleting: [deletedKey],
            survivors: [survivingKey: "500"]
        )
    }

    @Test("Deletion proof can delete the only key in a Volume-backed trie")
    func deletionProofDeletesOnlyKey() async throws {
        try await expectDeletionProof(
            entries: [("solo", "v1")],
            deleting: ["solo"],
            survivors: [:]
        )
    }

    @Test("Deletion proof keeps a branch when multiple siblings remain")
    func deletionProofKeepsBranchWithMultipleSurvivors() async throws {
        try await expectDeletionProof(
            entries: [("route/a", "a"), ("route/b", "b"), ("route/c", "c")],
            deleting: ["route/b"],
            survivors: ["route/a": "a", "route/c": "c"]
        )
    }

    @Test("Deletion proof preserves a terminal value that is also a path prefix")
    func deletionProofPreservesTerminalPrefixSibling() async throws {
        try await expectDeletionProof(
            entries: [("alpha", "root-value"), ("alphabet", "child-value")],
            deleting: ["alphabet"],
            survivors: ["alpha": "root-value"]
        )
    }

    @Test("Deletion proof collapses a deep shared prefix into the surviving branch")
    func deletionProofCollapsesDeepSharedPrefix() async throws {
        try await expectDeletionProof(
            entries: [
                ("shared/prefix/left/deleted", "delete-me"),
                ("shared/prefix/right/survivor", "keep-me")
            ],
            deleting: ["shared/prefix/left/deleted"],
            survivors: ["shared/prefix/right/survivor": "keep-me"]
        )
    }

    @Test("Deletion proof batch can collapse two removed siblings into one survivor")
    func deletionProofBatchCollapsesToSingleSurvivor() async throws {
        try await expectDeletionProof(
            entries: [
                ("batch/shared/1", "one"),
                ("batch/shared/2", "two"),
                ("batch/shared/3", "three")
            ],
            deleting: ["batch/shared/1", "batch/shared/2"],
            survivors: ["batch/shared/3": "three"]
        )
    }

    @Test("Deletion proof batch expands each affected level for cascading collapse")
    func deletionProofBatchExpandsEachAffectedLevelForCascadingCollapse() async throws {
        try await expectDeletionProof(
            entries: [
                ("batch/tree/left/1", "left-one"),
                ("batch/tree/left/2", "left-two"),
                ("batch/tree/right/deep/keep", "right-keep"),
                ("batch/tree/right/deep/remove", "right-remove")
            ],
            deleting: [
                "batch/tree/left/1",
                "batch/tree/left/2",
                "batch/tree/right/deep/remove"
            ],
            survivors: ["batch/tree/right/deep/keep": "right-keep"]
        )
    }

    @Test("Deletion proof skips expansion when fewer than n-1 branches are touched")
    func deletionProofSkipsExpansionWhenFewerThanNMinusOneBranchesAreTouched() async throws {
        let dict = try Dict()
            .inserting(key: "a/deleted", value: "delete-me")
            .inserting(key: "b/keep", value: "b-keep")
            .inserting(key: "c/keep", value: "c-keep")
        let bCID = try #require(dict.children["b"]?.rawCID)
        let cCID = try #require(dict.children["c"]?.rawCID)
        let outer = try VolumeImpl(node: dict)

        let store = VolumeGroupingStore()
        try await outer.storeRecursively(storer: store)

        let stripped = VolumeImpl<Dict>(rawCID: outer.rawCID, node: nil, encryptionInfo: nil)
        let fetcher = VolumeGroupingFetcher(store: store)
        var proofPaths = ArrayTrie<SparseMerkleProof>()
        proofPaths.set(["a/deleted"], value: .deletion)

        let proof = try await stripped.proof(paths: proofPaths, fetcher: fetcher)
        let maybeTransformed = try proof.transform(transforms: [["a/deleted"]: .delete])
        let transformed = try #require(maybeTransformed)
        let fetchedBeforeVerification = fetcher.fetchedCIDs
        let resolvedTransformed = try await transformed.resolveRecursive(fetcher: fetcher)

        #expect(try resolvedTransformed.node?.get(key: "a/deleted") == nil)
        #expect(try resolvedTransformed.node?.get(key: "b/keep") == "b-keep")
        #expect(try resolvedTransformed.node?.get(key: "c/keep") == "c-keep")
        #expect(!fetchedBeforeVerification.contains(bCID), "untouched branch b should not be fetched when fewer than n-1 branches are touched")
        #expect(!fetchedBeforeVerification.contains(cCID), "untouched branch c should not be fetched when fewer than n-1 branches are touched")
    }

    private func expectDeletionProof(
        entries: [(String, String)],
        deleting deletedKeys: [String],
        survivors: [String: String]
    ) async throws {
        var dict = Dict()
        for (key, value) in entries {
            dict = try dict.inserting(key: key, value: value)
        }
        let outer = try VolumeImpl(node: dict)

        let store = VolumeGroupingStore()
        try await outer.storeRecursively(storer: store)

        let stripped = VolumeImpl<Dict>(rawCID: outer.rawCID, node: nil, encryptionInfo: nil)
        let fetcher = VolumeGroupingFetcher(store: store)
        var proofPaths = ArrayTrie<SparseMerkleProof>()
        var transforms = ArrayTrie<Transform>()
        for key in deletedKeys {
            proofPaths.set([key], value: .deletion)
            transforms.set([key], value: .delete)
        }

        let proof = try await stripped.proof(paths: proofPaths, fetcher: fetcher)
        let maybeTransformed = try proof.transform(transforms: transforms)
        let transformed = try #require(maybeTransformed)
        let resolvedTransformed = try await transformed.resolveRecursive(fetcher: fetcher)

        for key in deletedKeys {
            #expect(try resolvedTransformed.node?.get(key: key) == nil)
        }
        for (key, value) in survivors {
            #expect(try resolvedTransformed.node?.get(key: key) == value)
        }
    }

    @Test("Store emits one complete payload at every Volume boundary")
    func storeEmitsCompleteVolumeBoundaries() async throws {
        let dict = try Dict()
            .inserting(key: "alice", value: "v1")
            .inserting(key: "bob", value: "v2")
        let outer = try VolumeImpl(node: dict)

        let store = VolumeGroupingStore()
        try await outer.storeRecursively(storer: store)

        #expect(store.volumes[outer.rawCID] != nil,
                "the outer Volume root should be emitted during store")

        var headerCIDs: Set<String> = []
        try VolumeMerkleDictionaryTests.visitAllHeaders(in: dict) { header in
            headerCIDs.insert(header.rawCID)
        }
        for cid in headerCIDs {
            #expect(store.volumes[cid] != nil,
                    "internal Volume \(cid) should be emitted during store")
        }
    }

    @Test("Non-Volume children are stored inside enclosing Volume's group, not lost")
    func nonVolumeChildrenInEnclosingVolume() async throws {
        let store = VolumeGroupingStore()
        let labelDict = try VolumeMerkleDictionaryImpl<String>().inserting(key: "name", value: "test")
        let dataDict = VolumeMerkleDictionaryImpl<String>()
        let mixed = MixedNode(
            label: try HeaderImpl(node: labelDict),
            data: try VolumeImpl(node: dataDict)
        )
        let root = try VolumeImpl(node: mixed)
        try await root.storeRecursively(storer: store)

        let rootVolume = store.volumes[root.rawCID]
        #expect(rootVolume != nil, "root volume should exist")

        let labelCID = mixed.label.rawCID
        #expect(rootVolume?[labelCID] != nil,
                "HeaderImpl child (label) must be stored inside the enclosing Volume's group, not lost when a sibling Volume boundary seals the buffer first")
    }

    @Test("Every VolumeRadixHeader in a VolumeMerkleDictionary gets its own volume root")
    func radixHeadersAreVolumeRoots() async throws {
        let dict = try VolumeMerkleDictionaryImpl<String>()
            .inserting(key: "alice", value: "100")
            .inserting(key: "bob", value: "200")

        let outer = try VolumeImpl(node: dict)
        let store = VolumeGroupingStore()
        try await outer.storeRecursively(storer: store)

        #expect(store.volumes[outer.rawCID] != nil, "outer VolumeImpl must be a volume root")

        var allHeaderCIDs: Set<String> = []
        try VolumeMerkleDictionaryTests.visitAllHeaders(in: dict) { header in
            allHeaderCIDs.insert(header.rawCID)
        }

        for cid in allHeaderCIDs {
            #expect(store.volumes[cid] != nil,
                    "VolumeRadixHeader \(String(cid.prefix(16)))… must have its own volume root")
        }
    }

    @Test("4-level custom hierarchy round-trips through volume-grouped store")
    func multiLevelRoundTrip() async throws {
        let eng = Division(teams: [
            "backend": try VolumeImpl(node: try Dict()
                .inserting(key: "alice", value: "lead")
                .inserting(key: "bob", value: "senior")),
        ])
        let company = Company(divisions: [
            "eng": try VolumeImpl(node: eng),
        ])
        let root = try VolumeImpl(node: company)

        let store = VolumeGroupingStore()
        try await root.storeRecursively(storer: store)

        #expect(store.volumes.count >= 3, "4-level hierarchy should produce multiple volume groups")

        let stripped = VolumeImpl<Company>(rawCID: root.rawCID, node: nil, encryptionInfo: nil)
        let fetcher = VolumeGroupingFetcher(store: store)
        let resolved = try await stripped.resolveRecursive(fetcher: fetcher)

        let engDiv = resolved.node?.divisions["eng"]
        #expect(engDiv != nil, "eng division should resolve")
        let backend = engDiv?.node?.teams["backend"]
        #expect(backend != nil, "backend team should resolve")
        let alice = try backend?.node?.get(key: "alice")
        #expect(alice == "lead", "alice's value should round-trip correctly")
    }
}
